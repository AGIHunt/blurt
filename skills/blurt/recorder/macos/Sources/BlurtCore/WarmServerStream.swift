// A take's audio streamed to the warm speech server while it is said (transcribe.py `serve` cmd "stream"; docs/design/
// dictation.md §Cloud recognition): one connection per take — one JSON line (the request), then the microphone's samples
// as raw 16 kHz s16 mono PCM, then this side shut for writing at key-up and one JSON line back, a note's answer. The
// server passes the audio on to a recogniser that hears it as it comes (Volcengine Seed-ASR 2.0), so at key-up only the
// end of the take is left to recognise (~0.5 s however long the take, against 1.5 s for a minute-long take sent whole).
//
// The connection opens once the request is complete (`release`: the field's text is read a moment after key-down) and
// the server is up (it may still be starting at key-down): until then the samples wait here, and go out in one write.
// `finish` (blocking, off the main thread) answers nil when the stream couldn't be used — never opened, or the
// connection broke — and the caller sends the take whole instead; else the server's answer, a failure (a refused key,
// a quota) included. `cancel` resets the connection: the server ends the session without answering.
import Foundation

public final class WarmServerStream {
    public let server: String
    private let q = DispatchQueue(label: "blurt.warm-stream", qos: .userInitiated)
    private var header: [String: Any]
    private var held: Bool
    private var fd: Int32 = -1
    private var pending = Data()
    private var broken = false
    private var done = false
    private var lastTry: TimeInterval = 0
    /// bytes of PCM handed to the server
    public private(set) var sent = 0

    /// `header`: the request's fields (model_id, language, vocab, app, hint, before…); `hold`: wait for `release`
    /// before opening (the rest of the request is still being read).
    public init(server: String, header: [String: Any], hold: Bool) {
        self.server = server; self.header = header; self.held = hold
    }

    deinit { if fd >= 0 { close(fd) } }

    /// Fields added to the request before it goes out (after it went, nothing changes).
    public func update(_ fields: [String: Any]) {
        q.async { self.header.merge(fields) { _, b in b } }
    }

    /// The request is complete: open as soon as the server is there.
    public func release() {
        q.async { self.held = false; self.lastTry = 0; self.tryOpen() }
    }

    /// The microphone's samples (-1…1), in order. Returns at once; the work is on the stream's queue.
    public func append(_ x: [Float]) {
        guard !x.isEmpty else { return }
        q.async {
            guard !self.done, !self.broken else { return }
            let pcm = WarmServerStream.pcm(x)
            if self.fd < 0 { self.pending.append(pcm); self.tryOpen() } else { self.write(pcm) }
        }
    }

    /// Opened: the server has the request and the audio so far.
    public var opened: Bool { q.sync { fd >= 0 && !broken } }

    /// Key-up: the rest of the audio, the end, and the server's answer within `timeout` s. nil: the stream couldn't be
    /// used (send the take whole). Blocking.
    public func finish(timeout: Double) -> [String: Any]? {
        let ready: Bool = q.sync {
            held = false
            lastTry = 0
            tryOpen()           // the last chance: the server came up late, or the request was still held
            done = true         // nothing opens after this (a late setContext, an append in flight)
            guard fd >= 0, !broken else { return false }
            if !pending.isEmpty { write(pending); pending = Data() }
            guard !broken else { return false }
            shutdown(fd, SHUT_WR)
            return true
        }
        guard ready else { return nil }
        let answer = readLine(timeout: timeout)
        q.sync { if fd >= 0 { close(fd); fd = -1 } }
        return answer
    }

    /// The take was cancelled: the connection is reset, nothing more is sent, the server answers nothing.
    public func cancel() {
        q.async {
            self.done = true
            self.pending = Data()
            guard self.fd >= 0 else { return }
            var l = linger(l_onoff: 1, l_linger: 0)
            setsockopt(self.fd, SOL_SOCKET, SO_LINGER, &l, socklen_t(MemoryLayout<linger>.size))
            close(self.fd)
            self.fd = -1
        }
    }

    // MARK: the connection (the stream's queue)

    private func tryOpen() {
        guard fd < 0, !held, !broken, !done else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastTry >= 0.25 else { return }       // the run file is read at most four times a second
        lastTry = now
        guard let (port, token) = WarmServer.info(server) else { return }
        var body = header
        body["cmd"] = "stream"
        body["token"] = token
        guard var line = try? JSONSerialization.data(withJSONObject: body) else { broken = true; return }
        line.append(0x0A)
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // a server that stops reading must not hold the microphone's queue: a write waits 2 s at most
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { close(s); return }
        fd = s
        write(line, audio: false)
        if !pending.isEmpty, !broken { write(pending); pending = Data() }
    }

    private func write(_ d: Data, audio: Bool = true) {
        guard fd >= 0, !broken else { return }
        let n = d.withUnsafeBytes { p -> Int in
            var off = 0
            while off < d.count {
                let r = send(fd, p.baseAddress! + off, d.count - off, 0)
                if r > 0 { off += r; continue }
                if r < 0, errno == EINTR { continue }
                return off
            }
            return off
        }
        if n < d.count { broken = true; return }
        if audio { sent += n }
    }

    private func readLine(timeout: Double) -> [String: Any]? {
        let s: Int32 = q.sync { fd }
        guard s >= 0 else { return nil }
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        let until = Date().addingTimeInterval(timeout)
        while buf.last != 0x0A && Date() < until {
            let n = recv(s, &chunk, chunk.count, 0)
            if n > 0 { buf.append(contentsOf: chunk[0..<n]); continue }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
            break
        }
        guard buf.last == 0x0A else { return nil }
        return try? JSONSerialization.jsonObject(with: buf) as? [String: Any]
    }

    // MARK: pure

    /// Samples (-1…1) → 16-bit little-endian PCM.
    public static func pcm(_ x: [Float]) -> Data {
        var out = Data(count: x.count * 2)
        out.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for (i, v) in x.enumerated() {
                let c = max(-1, min(1, v))
                p[i] = Int16(c * 32767).littleEndian
            }
        }
        return out
    }
}
