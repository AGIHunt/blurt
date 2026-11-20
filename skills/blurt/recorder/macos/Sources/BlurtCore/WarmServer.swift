// A client for the skill's warm model servers (transcribe.py serve, polish.py serve): $BLURT_HOME/run/<name>.json
// holds {"pid","port","token","parent","started"}; the protocol is one JSON line in, one JSON line out over 127.0.0.1.
// Talking to them directly skips a `uv run` per request (~0.2–0.4 s), which is most of what a dictation waits for once
// the models are warm. Blocking: call it off the main thread.
//
// A server that stopped answering (v0.9 dogfood): a run file can name a process that is alive but stuck — three
// servers of apps long gone sat deadlocked in Python's teardown for hours, one still listening with its file in place,
// and every dictation waited ~20 s for it and then ran the CLI (~9 s), relaunches included. `health` tells a server
// that answers or is busy (its CPU time moves: loading, decoding) from one that is gone, isn't a server any more (the
// pid was reused) or is stuck; `end` removes a stuck one. A request can also be given up on while it waits (`call`
// with `giveUp`): a hang is told by the server's behaviour (no CPU for a while), not by the audio's length.
import Foundation

public enum WarmServer {
    public static func infoURL(_ name: String) -> URL { BlurtPaths.home.appendingPathComponent("run/\(name).json") }

    /// What the run file says (the process is not looked at).
    public struct Record: Equatable {
        public var pid: Int32?
        public var port: Int
        public var token: String
        /// the app that started it (it ends when that app is gone); nil: started by hand, the Lab, the CLI
        public var parent: Int32?
        public var started: Date?
        /// its model has been loading since then (transcribe.py serve_loading): no answer meanwhile is no hang
        public var loadingSince: Date? = nil
    }

    public static func record(_ name: String) -> Record? {
        guard let d = try? Data(contentsOf: infoURL(name)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let port = o["port"] as? Int, port > 0, port < 65536 else { return nil }
        let iso = ISO8601DateFormatter()
        return Record(pid: (o["pid"] as? NSNumber)?.int32Value, port: port, token: o["token"] as? String ?? "",
                      parent: (o["parent"] as? NSNumber)?.int32Value,
                      started: (o["started"] as? String).flatMap { iso.date(from: $0) },
                      loadingSince: (o["loading_since"] as? String).flatMap { iso.date(from: $0) })
    }

    /// A load is believed this long at most (a 1.7B speech model loaded in 15 s from a busy disk): a server that says
    /// it has been loading for longer is judged like any other.
    public static let loadTrusted = 90.0

    /// The run file says its model is loading, and not for implausibly long (pure: WarmServerTests).
    public static func loading(_ r: Record?, now: Date = Date()) -> Bool {
        guard let since = r?.loadingSince else { return false }
        return now.timeIntervalSince(since) < loadTrusted
    }

    public static func loading(_ name: String) -> Bool { loading(record(name)) }

    /// The server's address, when its file is there and its process is alive.
    public static func info(_ name: String) -> (port: UInt16, token: String)? {
        guard let r = record(name) else { return nil }
        if let pid = r.pid, kill(pid, 0) != 0 && errno == ESRCH { return nil }
        return (UInt16(r.port), r.token)
    }

    public static func running(_ name: String) -> Bool { info(name) != nil }

    /// The process that wrote the server's file (nil: no file, or none named) — which server an answer came from.
    public static func pid(_ name: String) -> Int32? { record(name)?.pid }

    /// One request → the server's answer; nil when there is no server, it refused, or `timeout` (s) passed.
    public static func call(_ name: String, _ req: [String: Any], timeout: Double) -> [String: Any]? {
        call(name, req, timeout: timeout, giveUp: nil).answer
    }

    /// The same, asking `giveUp` (with the seconds waited so far) about every quarter second while no answer has
    /// come: true ends the wait at once (`gaveUp`).
    public static func call(_ name: String, _ req: [String: Any], timeout: Double,
                            giveUp: ((Double) -> Bool)?) -> (answer: [String: Any]?, gaveUp: Bool) {
        guard let (port, token) = info(name) else { return (nil, false) }
        var body = req
        body["token"] = token
        guard var data = try? JSONSerialization.data(withJSONObject: body) else { return (nil, false) }
        data.append(0x0A)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return (nil, false) }
        defer { close(fd) }
        let slice = giveUp == nil ? timeout : min(timeout, 0.25)
        var tv = timeval(tv_sec: Int(slice), tv_usec: Int32((slice - floor(slice)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var stv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &stv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { return (nil, false) }
        let sent = data.withUnsafeBytes { send(fd, $0.baseAddress, data.count, 0) }
        guard sent == data.count else { return (nil, false) }
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        let t0 = Date()
        let deadline = t0.addingTimeInterval(timeout)
        while buf.last != 0x0A && Date() < deadline {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n > 0 { buf.append(contentsOf: chunk[0..<n]); continue }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR, let g = giveUp {
                if g(Date().timeIntervalSince(t0)) { return (nil, true) }
                continue
            }
            break
        }
        guard buf.last == 0x0A else { return (nil, false) }
        return (try? JSONSerialization.jsonObject(with: buf) as? [String: Any], false)
    }

    // MARK: a server that doesn't answer

    public enum Health: Equatable {
        /// it answered a ping
        case answers
        /// no answer yet, but its CPU time moves (a model loading, a long decode), or it can't be told: left alone
        case working
        /// no run file, or its process is gone (the file is stale)
        case gone
        /// the pid now belongs to something else (reused): the file is stale, the process is not ours
        case notAServer
        /// alive, a server of ours, no answer and no CPU: stuck. `orphaned`: the app that started it is gone
        case stuck(orphaned: Bool)
    }

    /// The verdict from the facts (pure: WarmServerTests). `argv`: the process's command line (nil: unreadable);
    /// `cpu`: the CPU seconds it used while the ping waited (nil: unreadable).
    public static func verdict(record: Record?, alive: Bool, argv: [String]?, script: String, processStarted: Date?,
                               answered: Bool, cpu: Double?, parentAlive: Bool, loading: Bool = false) -> Health {
        guard let r = record, r.pid != nil else { return .gone }
        guard alive else { return .gone }
        if answered { return .answers }
        guard let a = argv else { return .working }
        let isServer = a.contains { $0 == script || $0.hasSuffix("/" + script) } && a.contains("serve")
        // a process that started well after its file was written isn't the one that wrote it
        let reused = r.started.flatMap { s in processStarted.map { $0.timeIntervalSince(s) > 5 } } ?? false
        if !isServer || reused { return .notAServer }
        // its model loading: no answer until it is done, and a load waiting on the disk or the GPU shows no CPU
        if loading { return .working }
        guard let c = cpu, c < 0.01 else { return .working }
        return .stuck(orphaned: !parentAlive)
    }

    /// Asks the server (a ping of `timeout` s) and looks at its process. Blocking (up to `timeout`).
    public static func health(_ name: String, script: String, timeout: Double = 0.5) -> Health {
        guard let r = record(name), let pid = r.pid else { return .gone }
        let alive = ProcessProbe.alive(pid)
        guard alive else { return .gone }
        let c0 = ProcessProbe.cpuSeconds(pid)
        let t0 = Date()
        let answered = (call(name, ["cmd": "ping"], timeout: timeout)?["ok"] as? Bool) == true
        // a ping refused at once (nobody listening) still gets the whole window to show CPU
        let left = timeout - Date().timeIntervalSince(t0)
        if !answered, left > 0 { usleep(useconds_t(left * 1_000_000)) }
        let c1 = ProcessProbe.cpuSeconds(pid)
        let cpu = c0.flatMap { a in c1.map { $0 - a } }
        return verdict(record: r, alive: alive, argv: ProcessProbe.arguments(pid), script: script,
                       processStarted: ProcessProbe.started(pid), answered: answered, cpu: cpu,
                       parentAlive: r.parent.map(ProcessProbe.alive) ?? false, loading: loading(r))
    }

    /// The run file goes when it still names `pid` (a newer server's file is left alone).
    public static func forget(_ name: String, pid: Int32?) {
        guard let p = pid, record(name)?.pid == p else { return }
        try? FileManager.default.removeItem(at: infoURL(name))
    }

    /// Ends a stuck server (SIGKILL: a stopped or deadlocked process takes nothing else) and removes its file. Only
    /// what `health` called stuck — a server process of this home, by its command line and start time. true when it
    /// is gone.
    @discardableResult
    public static func end(_ name: String, pid: Int32) -> Bool {
        guard pid > 1, pid != getpid() else { return false }
        kill(pid, SIGKILL)
        let until = Date().addingTimeInterval(1.5)
        while ProcessProbe.alive(pid) && Date() < until { usleep(20_000) }
        forget(name, pid: pid)
        return !ProcessProbe.alive(pid)
    }
}

/// How long a server's CPU time has stood still: the hang check of a request in flight (DictationASRFailure.hung).
public final class CPUWatch {
    private let pid: Int32
    private var last: Double?
    private var since: Date
    public init(pid: Int32, now: Date = Date()) {
        self.pid = pid
        since = now
        last = ProcessProbe.cpuSeconds(pid)
    }
    /// Seconds without CPU time; 0 when it can't be read (nothing is concluded from that).
    public func idle(now: Date = Date()) -> Double {
        guard let c = ProcessProbe.cpuSeconds(pid) else { return 0 }
        if let l = last, c - l < 0.005 { return now.timeIntervalSince(since) }
        last = c
        since = now
        return 0
    }
}

/// How long a polish request waits for the warm polish server (Dictation.polish / structure). The Polish time limit
/// (`timeout`) is the server's, applied to the generation once its model is loaded; the client waits a second more
/// for the answer to come back. `loadBudget` (a model still loading) is added only when a load may be ahead of the
/// request — a stopped server whose model was loaded long ago held a take 3 + 12 + 1 = 16 s although Settings says
/// 3 s (dogfood 2026-11-21).
/// `loaded`: the server's answer to a ping (`loaded`; nil: it didn't answer); `health`: asked only when it didn't.
public enum PolishWait: Equatable {
    /// wait this many seconds for the answer
    case wait(Double)
    /// no answer and no CPU (stuck), or no server: don't ask it; the text goes in unpolished
    case giveUp

    public static func decide(loaded: Bool?, health: WarmServer.Health?, timeout: Double, loadBudget: Double,
                              extra: Double = 0) -> PolishWait {
        let quick = timeout + 1 + extra, long = timeout + loadBudget + 1 + extra
        if let l = loaded { return .wait(l ? quick : long) }
        switch health {
        case .stuck?, .gone?, .notAServer?: return .giveUp
        // busy with a request that needs it (a cold load, another take's polish), or it can't be told
        case .answers?, .working?, nil: return .wait(long)
        }
    }
}
