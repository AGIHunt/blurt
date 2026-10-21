import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import ServiceManagement

// MARK: - Launching the user's agent CLI (claude / codex) and other tools

/// Run a program, capture stdout+stderr, give up after `timeout` seconds. Reads concurrently so a chatty child never
/// blocks on a full pipe. status nil = could not start, or timed out.
func runCapture(_ exe: String, _ args: [String], env: [String: String]? = nil, timeout: Double) -> (status: Int32?, out: Data) {
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

/// Variables a coding-agent session (Claude Code, the Claude / Codex desktop apps, codex) exports to its children.
/// When the app itself was opened from inside such a session (the skill does that), they leak into every agent the app
/// launches later, long after that session is gone: CLAUDE_CODE_SIMPLE=1 puts `claude -p` in bare mode, which never
/// reads the keychain login ("Not logged in · Please run /login"); ANTHROPIC_BASE_URL points at that session's local
/// auth proxy; USE_STAGING_OAUTH, CLAUDECODE, session ids, CODEX_SANDBOX… make the child act like a nested agent.
/// None of them are the user's own settings — whatever their shell profile sets comes back via `loginShellEnv`.
func isAgentSessionVar(_ k: String) -> Bool {
    if userAgentConfigVars.contains(k) { return false }     // where the user keeps an agent's config: theirs, keep it
    for prefix in ["CLAUDE", "ANTHROPIC_", "CODEX_", "MCP_", "OTEL_"] where k.hasPrefix(prefix) { return true }
    return ["AI_AGENT", "BAGGAGE", "USE_LOCAL_OAUTH", "USE_STAGING_OAUTH", "API_TIMEOUT_MS", "DISABLE_AUTOUPDATER",
            "DISABLE_MICROCOMPACT", "BLURT_APP"].contains(k)
}

let userAgentConfigVars: Set<String> = ["CODEX_HOME", "CLAUDE_CONFIG_DIR", "KIMI_CODE_HOME"]

/// Our own environment minus anything an agent session leaked into it.
let inheritedEnv: [String: String] = ProcessInfo.processInfo.environment.filter { !isAgentSessionVar($0.key) }

/// What a new terminal would have. Apps opened from Finder get launchd's bare env, and people set PATH, API keys,
/// CLAUDE_CONFIG_DIR, proxies… in ~/.zshrc — so ask the user's login shell once (interactive, with a timeout).
let loginShellEnv: [String: String] = {
    var sh = inheritedEnv["SHELL"] ?? "/bin/zsh"
    if !sh.hasPrefix("/") || !FileManager.default.isExecutableFile(atPath: sh) { sh = "/bin/zsh" }
    let marker = Data("\n__BLURT_ENV__\n".utf8)
    let (_, data) = runCapture(sh, ["-ilc", "printf '\\n__BLURT_ENV__\\n'; /usr/bin/env -0"], env: inheritedEnv, timeout: 8)
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

/// The user's PATH — login shell first, so we run the same `claude` / `codex` their terminal runs — plus the usual
/// install locations in case the shell probe failed.
let userPATH: String = {
    let home = NSHomeDirectory()
    let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin",
                 "\(home)/.cargo/bin", "\(home)/.volta/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    let found = (loginShellEnv["PATH"] ?? "").split(separator: ":").map(String.init)
    var seen = Set<String>()
    return (found + extra).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
}()

/// The environment for everything the app launches (the agent, review.py, live.py…): the login the user has in their
/// terminal, not whatever session happened to open the app. Inherited BLURT_* (BLURT_HOME / BLURT_WORKSPACE) win.
func agentEnvironment() -> [String: String] {
    var env = inheritedEnv.merging(loginShellEnv) { _, fromShell in fromShell }
    for (k, v) in inheritedEnv where k.hasPrefix("BLURT_") { env[k] = v }
    env["PATH"] = userPATH
    env["BLURT_APP"] = "1"
    return env
}

func findExecutable(_ name: String) -> String? {
    for dir in userPATH.split(separator: ":") {
        let path = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    return nil
}

func shell(_ cmd: String, cwd: URL, log: URL, append: Bool = false, done: @escaping (Int32) -> Void) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", cmd]
    p.environment = agentEnvironment()
    p.standardInput = FileHandle.nullDevice   // codex exec otherwise waits for more prompt on stdin
    p.currentDirectoryURL = cwd
    if !append || !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
    let fh = try? FileHandle(forWritingTo: log)
    fh?.seekToEndOfFile()
    p.standardOutput = fh
    p.standardError = fh
    p.terminationHandler = { pr in DispatchQueue.main.async { done(pr.terminationStatus) } }
    try? p.run()
}

func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
