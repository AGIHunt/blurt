// The app's local control endpoint (docs/design/agent-setup.md §1): a unix domain socket in $BLURT_HOME/run (0700),
// the socket file itself 0600, and every connection's peer checked with getpeereid — a process of another user is
// closed on before a byte is read. One JSON line in, one JSON line out, then the connection closes; each connection
// is answered on its own queue, so a long request (a test dictation) never holds up a status.
//
// Nothing here knows what the requests mean: the app hands a handler (App/AgentSetupServer.swift). A second app on the
// same BLURT_HOME finds the socket answering and leaves it alone (`inUse`); a socket file left by a crashed app is
// replaced.
import Foundation

public final class ControlSocket {
    public struct Peer: Equatable {
        public let uid: uid_t
        /// 0 when the system didn't say
        public let pid: pid_t
    }
    public typealias Handler = (_ request: [String: Any], _ peer: Peer) -> [String: Any]

    public enum StartError: Error, Equatable {
        case tooLong
        /// another app answers on this socket (a second Blurt on the same BLURT_HOME)
        case inUse
        /// the socket's folder isn't this user's alone
        case unsafeFolder(String)
        case system(String, Int32)
    }

    public let path: String
    private let handler: Handler
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var running = false
    private let work = DispatchQueue(label: "blurt.control", attributes: .concurrent)

    public init(path: String, handler: @escaping Handler) {
        self.path = path; self.handler = handler
    }

    deinit { stop() }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    public func start() throws {
        guard path.utf8.count <= AgentSetup.maxSocketPath else { throw StartError.tooLong }
        let dir = (path as NSString).deletingLastPathComponent
        try Self.privateFolder(dir)
        if FileManager.default.fileExists(atPath: path) {
            if Self.answers(path) { throw StartError.inUse }
            unlink(path)
        }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw StartError.system("socket", errno) }
        var addr = sockaddr_un()
        guard Self.fill(&addr, path) else { close(s); throw StartError.tooLong }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { let e = errno; close(s); throw StartError.system("bind", e) }
        // the folder is 0700 already; the file itself too, before anyone can reach it through a looser folder later
        chmod(path, 0o600)
        guard listen(s, 16) == 0 else { let e = errno; close(s); unlink(path); throw StartError.system("listen", e) }
        lock.lock(); fd = s; running = true; lock.unlock()
        let t = Thread { [weak self] in self?.acceptLoop(s) }
        t.name = "blurt.control.accept"
        t.start()
    }

    public func stop() {
        lock.lock()
        let s = fd
        let was = running
        fd = -1; running = false
        lock.unlock()
        guard was else { return }
        shutdown(s, SHUT_RDWR)
        close(s)
        unlink(path)
    }

    private func acceptLoop(_ s: Int32) {
        while true {
            let c = accept(s, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                return      // closed by stop()
            }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            guard let peer = Self.peer(c), peer.uid == getuid() else { close(c); continue }
            work.async { [weak self] in
                defer { close(c) }
                guard let self = self else { return }
                let answer: [String: Any]
                switch Self.readLine(c, max: AgentSetup.maxRequest) {
                case .tooLong: answer = AgentSetupError("too_long", "a request is one line of at most \(AgentSetup.maxRequest) bytes").json
                case .none: return
                case .line(let d):
                    if let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        answer = self.handler(o, peer)
                    } else {
                        answer = AgentSetupError("bad_request", "not a JSON object").json
                    }
                }
                Self.write(c, answer)
            }
        }
    }

    // MARK: the pieces (also the client tests and the app use)

    /// The folder holds only this user's things: made 0700 when missing; refused when it is a link, another user's, or
    /// open to others (a /tmp fallback folder someone else made first).
    static func privateFolder(_ dir: String) throws {
        var st = stat()
        if lstat(dir, &st) != 0 {
            guard (try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                             attributes: [.posixPermissions: 0o700])) != nil else {
                throw StartError.unsafeFolder(dir)
            }
            guard lstat(dir, &st) == 0 else { throw StartError.unsafeFolder(dir) }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { throw StartError.unsafeFolder(dir) }
        if st.st_mode & 0o077 != 0 {
            guard chmod(dir, 0o700) == 0 else { throw StartError.unsafeFolder(dir) }
        }
    }

    static func fill(_ addr: inout sockaddr_un, _ path: String) -> Bool {
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return true
    }

    /// The connected process: its user (getpeereid) and its pid (LOCAL_PEERPID).
    static func peer(_ c: Int32) -> Peer? {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(c, &uid, &gid) == 0 else { return nil }
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        if getsockopt(c, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) != 0 { pid = 0 }
        return Peer(uid: uid, pid: pid)
    }

    enum Read { case line(Data), tooLong, none }

    static func readLine(_ c: Int32, max: Int, timeout: Double = 10) -> Read {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(c, &buf, buf.count, 0)
            if n <= 0 { return data.isEmpty ? .none : .line(data) }
            if let nl = buf[0..<n].firstIndex(of: 0x0A) {
                data.append(contentsOf: buf[0..<nl])
                return data.count > max ? .tooLong : .line(data)
            }
            data.append(contentsOf: buf[0..<n])
            if data.count > max { return .tooLong }
        }
    }

    static func write(_ c: Int32, _ o: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: o) else { return }
        d.append(0x0A)
        d.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = send(c, raw.baseAddress! + off, raw.count - off, 0)
                if n <= 0 { return }
                off += n
            }
        }
    }

    /// Something accepts connections there.
    static func answers(_ path: String) -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        var addr = sockaddr_un()
        guard fill(&addr, path) else { return false }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    /// A client: one request, its answer (nil: nothing listens, or no answer within `timeout`).
    public static func call(_ path: String, _ req: [String: Any], timeout: Double) -> [String: Any]? {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        defer { close(s) }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        guard fill(&addr, path) else { return nil }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return nil }
        write(s, req)
        guard case .line(let d) = readLine(s, max: 4 * 1024 * 1024, timeout: timeout) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
}
