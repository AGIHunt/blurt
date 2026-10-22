// A client for the skill's warm model servers (transcribe.py serve, polish.py serve): $BLURT_HOME/run/<name>.json
// holds {"pid","port","token"}; the protocol is one JSON line in, one JSON line out over 127.0.0.1. Talking to them
// directly skips a `uv run` per request (~0.2–0.4 s), which is most of what a dictation waits for once the models
// are warm. Blocking: call it off the main thread.
import Foundation

public enum WarmServer {
    public static func infoURL(_ name: String) -> URL { BlurtPaths.home.appendingPathComponent("run/\(name).json") }

    /// The server's address, when its file is there and its process is alive.
    public static func info(_ name: String) -> (port: UInt16, token: String)? {
        guard let d = try? Data(contentsOf: infoURL(name)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let port = o["port"] as? Int, port > 0, port < 65536 else { return nil }
        if let pid = o["pid"] as? Int, kill(pid_t(pid), 0) != 0 && errno == ESRCH { return nil }
        return (UInt16(port), o["token"] as? String ?? "")
    }

    public static func running(_ name: String) -> Bool { info(name) != nil }

    /// One request → the server's answer; nil when there is no server, it refused, or `timeout` (s) passed.
    public static func call(_ name: String, _ req: [String: Any], timeout: Double) -> [String: Any]? {
        guard let (port, token) = info(name) else { return nil }
        var body = req
        body["token"] = token
        guard var data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        data.append(0x0A)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { return nil }
        let sent = data.withUnsafeBytes { send(fd, $0.baseAddress, data.count, 0) }
        guard sent == data.count else { return nil }
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(timeout)
        while buf.last != 0x0A && Date() < deadline {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            buf.append(contentsOf: chunk[0..<n])
        }
        guard buf.last == 0x0A else { return nil }
        return try? JSONSerialization.jsonObject(with: buf) as? [String: Any]
    }
}
