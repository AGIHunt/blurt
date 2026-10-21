// Runs the skill's Python CLIs (items.py, index.py, agents.py, live.py, transcribe.py — contracts C2/C3/C5) with uv,
// in the user's login-shell environment: what a new terminal has, minus variables a coding-agent session leaked into
// ours (ShellEnv). The app never bundles uv: it uses the one on the user's PATH, else ~/.blurt/bin/uv (onboarding
// installs it there).
import Foundation

// MARK: - The environment for everything the app launches

public enum ShellEnv {
    /// Variables a coding-agent session (Claude Code, the Claude / Codex desktop apps, codex) exports to its children.
    /// When the app itself was opened from inside such a session (the skill does that), they leak into every agent the
    /// app launches later, long after that session is gone: CLAUDE_CODE_SIMPLE=1 puts `claude -p` in bare mode, which
    /// never reads the keychain login ("Not logged in · Please run /login"); ANTHROPIC_BASE_URL points at that session's
    /// local auth proxy; USE_STAGING_OAUTH, CLAUDECODE, session ids, CODEX_SANDBOX… make the child act like a nested
    /// agent. None of them are the user's own settings — whatever their shell profile sets comes back via `loginShell`.
    public static func isAgentSessionVar(_ k: String) -> Bool {
        if isUserConfigVar(k) { return false }
        for prefix in ["CLAUDE", "ANTHROPIC_", "CODEX_", "MCP_", "OTEL_"] where k.hasPrefix(prefix) { return true }
        return ["AI_AGENT", "BAGGAGE", "USE_LOCAL_OAUTH", "USE_STAGING_OAUTH", "API_TIMEOUT_MS", "DISABLE_AUTOUPDATER",
                "DISABLE_MICROCOMPACT", "BLURT_APP"].contains(k)
    }

    /// Where the user keeps an agent's config — their setting, not a session leak: never dropped (agents.py
    /// _USER_CONFIG_VARS, plus any other *_HOME / *_CONFIG_DIR locator).
    public static let userConfigVars: Set<String> = ["CODEX_HOME", "CLAUDE_CONFIG_DIR", "KIMI_CODE_HOME"]
    public static func isUserConfigVar(_ k: String) -> Bool {
        userConfigVars.contains(k) || k.hasSuffix("_HOME") || k.hasSuffix("_CONFIG_DIR")
    }

    /// Our own environment minus anything an agent session leaked into it.
    public static let inherited: [String: String] = ProcessInfo.processInfo.environment.filter { !isAgentSessionVar($0.key) }

    /// What a new terminal would have. Apps opened from Finder get launchd's bare env, and people set PATH, API keys,
    /// CLAUDE_CONFIG_DIR, proxies… in ~/.zshrc — so ask the user's login shell once (interactive, with a timeout).
    public static let loginShell: [String: String] = {
        var sh = inherited["SHELL"] ?? "/bin/zsh"
        if !sh.hasPrefix("/") || !FileManager.default.isExecutableFile(atPath: sh) { sh = "/bin/zsh" }
        let marker = Data("\n__BLURT_ENV__\n".utf8)
        let (_, data) = runCapture(sh, ["-ilc", "printf '\\n__BLURT_ENV__\\n'; /usr/bin/env -0"], env: inherited, timeout: 8)
        guard let r = data.range(of: marker) else { return [:] }
        var env: [String: String] = [:]
        for entry in data[r.upperBound...].split(separator: 0) {
            guard let s = String(data: Data(entry), encoding: .utf8), let eq = s.firstIndex(of: "="), eq != s.startIndex else { continue }
            let k = String(s[..<eq])
            if ["SHLVL", "_", "PWD", "OLDPWD"].contains(k) { continue }
            env[k] = String(s[s.index(after: eq)...])
        }
        return env
    }()

    /// The user's PATH — login shell first, so we run the same `claude` / `codex` / `uv` their terminal runs — plus the
    /// usual install locations (and ~/.blurt/bin) in case the shell probe failed.
    public static let path: String = {
        let home = NSHomeDirectory()
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin",
                     "\(home)/.cargo/bin", "\(home)/.volta/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                     BlurtPaths.home.appendingPathComponent("bin").path]
        let found = (loginShell["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (found + extra).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }()

    /// The environment for everything the app launches (the agent, review.py, live.py, items.py…): the login the user
    /// has in their terminal, not whatever session happened to open the app. Inherited BLURT_* (BLURT_HOME /
    /// BLURT_WORKSPACE) win.
    public static func agentEnvironment() -> [String: String] {
        var env = inherited.merging(loginShell) { _, fromShell in fromShell }
        for (k, v) in inherited where k.hasPrefix("BLURT_") { env[k] = v }
        env["PATH"] = path
        env["BLURT_APP"] = "1"
        return env
    }

    public static func findExecutable(_ name: String) -> String? {
        for dir in path.split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Run a program, capture stdout+stderr, give up after `timeout` seconds. Reads concurrently so a chatty child
    /// never blocks on a full pipe. status nil = could not start, or timed out.
    public static func runCapture(_ exe: String, _ args: [String], env: [String: String]? = nil, timeout: Double) -> (status: Int32?, out: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let env = env { p.environment = env }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (nil, Data()) }
        var data = Data()
        let lock = NSLock()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                lock.lock(); data.append(chunk); lock.unlock()
            }
            drained.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(30_000) }
        let finished = !p.isRunning
        if !finished { p.terminate() }
        _ = drained.wait(timeout: .now() + 1)      // a background job started by the shell may hold the pipe; don't wait on it
        lock.lock(); defer { lock.unlock() }
        return (finished ? p.terminationStatus : nil, data)
    }
}

// MARK: - ScriptRunner

public enum ScriptError: Error, CustomStringConvertible {
    case uvMissing                                   // no uv on PATH or in ~/.blurt/bin
    case scriptMissing(String)                       // <skill>/scripts/<name> not found
    case failed(status: Int32, stdout: Data, stderr: String)   // non-zero exit; C2 CLIs still print {"ok":false,…}
    case timeout(TimeInterval)
    case notImplemented

    public var description: String {
        switch self {
        case .uvMissing: return "uv not found"
        case .scriptMissing(let s): return "script not found: \(s)"
        case .failed(let st, _, let err): return "exit \(st): \(err.suffix(500))"
        case .timeout(let t): return "timed out after \(Int(t)) s"
        case .notImplemented: return "not implemented"
        }
    }
}

/// What one run() collects, behind a lock (pipes are drained on background queues).
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data(), timedOut = false
    var cont: CheckedContinuation<Data, Error>?

    func append(_ d: Data, out isOut: Bool) { lock.lock(); if isOut { out.append(d) } else { err.append(d) }; lock.unlock() }
    func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }
    func snapshot() -> (Data, Data, Bool) { lock.lock(); defer { lock.unlock() }; return (out, err, timedOut) }
    func finish(_ r: Result<Data, Error>) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(with: r)
    }
}

public final class ScriptRunner {
    public static let shared = ScriptRunner()
    public init() {}

    /// uv on the user's PATH (login shell), else ~/.blurt/bin/uv. Looked up each time: onboarding may install it.
    public var uvPath: String? {
        if let p = ShellEnv.findExecutable("uv") { return p }
        let mine = BlurtPaths.home.appendingPathComponent("bin/uv").path
        return FileManager.default.isExecutableFile(atPath: mine) ? mine : nil
    }

    public var uvAvailable: Bool { uvPath != nil }

    /// "items.py" → <skill>/scripts/items.py; absolute paths as they are.
    public func scriptURL(_ script: String) throws -> URL {
        let u = script.hasPrefix("/") ? URL(fileURLWithPath: script) : BlurtPaths.scripts.appendingPathComponent(script)
        guard FileManager.default.fileExists(atPath: u.path) else { throw ScriptError.scriptMissing(u.path) }
        return u
    }

    func process(_ script: String, _ args: [String]) throws -> Process {
        guard let uv = uvPath else { throw ScriptError.uvMissing }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: uv)
        p.arguments = ["run", "-q", try scriptURL(script).path] + args
        p.environment = ShellEnv.agentEnvironment()
        return p
    }

    /// `uv run -q <script> args…` → stdout. Throws .failed on a non-zero exit (stdout kept: the C2 CLIs explain
    /// themselves there), .timeout after `timeout` seconds (the process is terminated).
    public func run(_ script: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval = 60) async throws -> Data {
        let p = try process(script, args)
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
        let st = RunState()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            st.cont = cont
            let group = DispatchGroup()
            for (pipe, isOut) in [(out, true), (err, false)] {
                group.enter()
                DispatchQueue.global().async {
                    while true {
                        let chunk = pipe.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        st.append(chunk, out: isOut)
                    }
                    group.leave()
                }
            }
            p.terminationHandler = { pr in
                _ = group.wait(timeout: .now() + 2)
                let (o, e, t) = st.snapshot()
                if t { st.finish(.failure(ScriptError.timeout(timeout))); return }
                st.finish(pr.terminationStatus == 0 ? .success(o)
                          : .failure(ScriptError.failed(status: pr.terminationStatus, stdout: o, stderr: String(decoding: e, as: UTF8.self))))
            }
            do { try p.run() } catch { st.finish(.failure(error)); return }
            if let d = stdin {
                DispatchQueue.global().async {
                    try? inp.fileHandleForWriting.write(contentsOf: d)
                    try? inp.fileHandleForWriting.close()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard p.isRunning else { return }
                st.markTimedOut()
                p.terminate()
            }
        }
    }

    /// Long-running script (live.py, a watcher…): stdout+stderr lines delivered on the main queue as they arrive.
    /// The process is already running when this returns; the caller owns it (terminate(), terminationHandler).
    public func spawn(_ script: String, _ args: [String], onLine: @escaping (String) -> Void) throws -> Process {
        let p = try process(script, args)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        var buf = Data()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil }
            buf.append(chunk)
            var lines: [String] = []
            while let nl = buf.firstIndex(of: 0x0A) {
                lines.append(String(decoding: buf[buf.startIndex..<nl], as: UTF8.self))
                buf.removeSubrange(buf.startIndex...nl)
            }
            if chunk.isEmpty, !buf.isEmpty { lines.append(String(decoding: buf, as: UTF8.self)); buf.removeAll() }
            if !lines.isEmpty { DispatchQueue.main.async { lines.forEach(onLine) } }
        }
        try p.run()
        return p
    }

    /// run() and decode the one-line JSON object the CLIs print (C2: {"ok": true, …}). A non-zero exit with a JSON
    /// error line still throws .failed — callers read `stdout` for the message.
    public func json(_ script: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval = 60) async throws -> [String: Any] {
        let d = try await run(script, args, stdin: stdin, timeout: timeout)
        let line = String(decoding: d, as: UTF8.self).split(separator: "\n").last(where: { $0.hasPrefix("{") }).map(String.init) ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
    }
}
