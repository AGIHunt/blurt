// K5 agent sessions, through sessions.py (P2). The app never builds a tmux or agent command line itself: dispatch,
// attach-cmd, open-external, send, stop and finish are all sessions.py subcommands, and their argv / env is what the
// embedded terminal runs. Live state comes from the job files (JobStore), not from polling the CLI.
//
//   tmux: a private server, `tmux -L $BLURT_TMUX_SOCKET` (default "blurt"); one session per project (blurt-<slug>), one
//   window per dispatch. Each embedded terminal attaches through its own grouped view session, so two panes can show
//   two windows of the same project without moving each other.
import Foundation

public enum DispatchMode: String { case together, parallel }
public enum WorktreeChoice: String { case on, off, auto }

public struct DispatchWarning {
    public let code: String              // concurrent_edit | no_git | no_tmux | draft_confirmed
    public let jobs: [String]
    public let items: [String]
}

/// `launch` rows: only for the app runner (no tmux) — the app runs these argv in its own pty.
public struct AppLaunch {
    public let job: String
    public let argv: [String]
    public let env: [String: String]
    public let cwd: URL
    public init(job: String, argv: [String], env: [String: String], cwd: URL) {
        self.job = job; self.argv = argv; self.env = env; self.cwd = cwd
    }
}

public struct DispatchResult {
    public let jobs: [String]
    public let warnings: [DispatchWarning]
    // beyond the G0 signature
    public let launch: [AppLaunch]
    /// Per job: project, window, worktree, branch, cwd, items (as sessions.py printed them).
    public let rows: [[String: Any]]
}

/// sessions.py said {"ok": false, "code": …}. The UI shows `code` localized (Terminal table `error.<code>`).
public struct SessionsError: Error, CustomStringConvertible {
    public let code: String
    public let message: String
    public var description: String { "\(code): \(message)" }
}

/// sessions.py doctor
public struct SessionsDoctor {
    public let tmuxPath: String?
    public let tmuxVersion: String?
    public let socket: String
    /// agent id → has an interactive session command
    public let agents: [String: Bool]
}

public final class AgentSessions {
    public static let shared = AgentSessions()
    public init() {}

    /// The private tmux socket name (-L).
    public var socket: String { ProcessInfo.processInfo.environment["BLURT_TMUX_SOCKET"] ?? "blurt" }

    /// tmux ≥ 3.2 on the user's PATH (checked once; `refreshTmux()` after the user installed it).
    public var tmuxAvailable: Bool { tmux.version.map { Self.atLeast($0, 3, 2) } ?? false }
    public var tmuxPath: String? { tmux.path }
    public var tmuxVersion: String? { tmux.version }
    private lazy var tmux: (path: String?, version: String?) = Self.probeTmux()
    public func refreshTmux() { tmux = Self.probeTmux() }

    static func probeTmux() -> (path: String?, version: String?) {
        guard let p = ShellEnv.findExecutable("tmux") else { return (nil, nil) }
        let (st, out) = ShellEnv.runCapture(p, ["-V"], timeout: 5)
        guard st == 0 else { return (p, nil) }
        // "tmux 3.6a", "tmux next-3.7"
        let s = String(decoding: out, as: UTF8.self)
        let v = s.range(of: #"\d+\.\d+[a-z]?"#, options: .regularExpression).map { String(s[$0]) }
        return (p, v)
    }

    static func atLeast(_ v: String, _ major: Int, _ minor: Int) -> Bool {
        let nums = v.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard let a = nums.first else { return false }
        return a > major || (a == major && (nums.dropFirst().first ?? 0) >= minor)
    }

    var lang: String { Loc.language.hasPrefix("zh") ? "zh" : "en" }

    /// One sessions.py call → its JSON line. A non-zero exit with {"ok": false} throws SessionsError.
    func call(_ args: [String], timeout: TimeInterval = 60) async throws -> [String: Any] {
        let out: Data
        do {
            out = try await ScriptRunner.shared.run("sessions.py", args, timeout: timeout)
        } catch ScriptError.failed(let status, let stdout, let stderr) {
            let o = Self.lastJSON(stdout)
            throw SessionsError(code: o["code"] as? String ?? (status == 4 ? "missing_dependency" : "failed"),
                                message: o["error"] as? String ?? String(stderr.suffix(400)))
        } catch ScriptError.scriptMissing(let p) {
            throw SessionsError(code: "no_sessions_cli", message: "missing \(p)")
        } catch ScriptError.uvMissing {
            throw SessionsError(code: "uv_missing", message: "uv not found")
        } catch ScriptError.timeout(let t) {
            throw SessionsError(code: "timeout", message: "sessions.py timed out after \(Int(t)) s")
        }
        let o = Self.lastJSON(out)
        if o["ok"] as? Bool == false {
            throw SessionsError(code: o["code"] as? String ?? "failed", message: o["error"] as? String ?? "")
        }
        return o
    }

    static func lastJSON(_ d: Data) -> [String: Any] {
        let text = String(decoding: d, as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.hasPrefix("{") {
            if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] { return o }
        }
        return [:]
    }

    // MARK: K5 CLI

    public func dispatch(items: [String], agent: String?, mode: DispatchMode, worktree: WorktreeChoice, dryRun: Bool) async throws -> DispatchResult {
        var args = ["dispatch", "--items"] + items + ["--mode", mode.rawValue, "--worktree", worktree.rawValue, "--lang", lang]
        if let a = agent, !a.isEmpty { args += ["--agent", a] }
        if dryRun { args.append("--dry-run") }
        let o = try await call(args, timeout: dryRun ? 60 : 120)
        let rows = o["jobs"] as? [[String: Any]] ?? []
        let warnings = (o["warnings"] as? [[String: Any]] ?? []).map {
            DispatchWarning(code: $0["code"] as? String ?? "", jobs: $0["jobs"] as? [String] ?? [], items: $0["items"] as? [String] ?? [])
        }
        let launch = (o["launch"] as? [[String: Any]] ?? []).compactMap { l -> AppLaunch? in
            guard let job = l["job"] as? String, let argv = l["argv"] as? [String], !argv.isEmpty else { return nil }
            return AppLaunch(job: job, argv: argv, env: l["env"] as? [String: String] ?? [:],
                             cwd: URL(fileURLWithPath: l["cwd"] as? String ?? NSHomeDirectory()))
        }
        return DispatchResult(jobs: rows.compactMap { $0["id"] as? String }, warnings: warnings, launch: launch, rows: rows)
    }

    public func attachCommand(job: String) async throws -> (argv: [String], env: [String: String]) {
        let o = try await call(["attach-cmd", job], timeout: 30)
        guard let argv = o["argv"] as? [String], !argv.isEmpty else { throw SessionsError(code: "no_window", message: "no argv") }
        return (argv, o["env"] as? [String: String] ?? [:])
    }

    public func openExternal(job: String, terminal: String?) async throws {
        _ = try await call(["open-external", job, "--terminal", terminal ?? "auto"], timeout: 30)
    }

    public func send(job: String, text: String, enter: Bool) async throws {
        _ = try await call(["send", job, "--text", text] + (enter ? ["--enter"] : []), timeout: 30)
    }

    public func stop(job: String, kill: Bool) async throws {
        _ = try await call(["stop", job] + (kill ? ["--kill"] : []), timeout: 30)
    }

    /// diff | merge | pr | discard | keep → the CLI's JSON (diff: base, branch, stat, patch, uncommitted).
    public func finish(job: String, action: String) async throws -> [String: Any] {
        try await call(["finish", job, "--action", action], timeout: action == "pr" ? 180 : 90)
    }

    /// The app runner's pty exited (`sessions.py event --event pane-dead`): the job and the items move on (K3).
    public func reportExit(job: String, status: Int32) async {
        _ = try? await call(["event", "--job", job, "--event", "pane-dead", "--exit", String(status)], timeout: 30)
    }

    /// sessions.py list: windows still alive (and, as a side effect, one monitor pass).
    public func list(project: String? = nil, all: Bool = false) async throws -> [[String: Any]] {
        var args = ["list"]
        if let p = project { args += ["--project", p] }
        if all { args.append("--all") }
        return try await call(args, timeout: 30)["sessions"] as? [[String: Any]] ?? []
    }

    public func doctor() async throws -> SessionsDoctor {
        let o = try await call(["doctor"], timeout: 60)
        let t = o["tmux"] as? [String: Any]
        var agents: [String: Bool] = [:]
        for a in o["agents"] as? [[String: Any]] ?? [] { if let id = a["id"] as? String { agents[id] = a["session"] as? Bool ?? false } }
        return SessionsDoctor(tmuxPath: t?["path"] as? String, tmuxVersion: t?["version"] as? String,
                              socket: o["socket"] as? String ?? socket, agents: agents)
    }
}
