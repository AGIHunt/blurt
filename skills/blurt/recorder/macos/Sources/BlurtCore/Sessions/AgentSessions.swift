// K5 agent sessions, through sessions.py (P2). The app never builds a tmux or agent command line itself: dispatch,
// attach-cmd, open-external, send, stop and finish are all sessions.py subcommands, and their argv / env is what the
// embedded terminal runs. Live state comes from the job files (JobStore), not from polling the CLI.
//
//   tmux: a private server, `tmux -L $BLURT_TMUX_SOCKET` (default "blurt"); one session per project (blurt-<slug>), one
//   window per dispatch. Each embedded terminal attaches through its own grouped view session, so two panes can show
//   two windows of the same project without moving each other.
//   desktop: the agent's desktop app (Claude: `dispatch --runner desktop`). sessions.py makes the worktree and the note
//   and returns a claude:// link per job (DesktopLink) for the app to open; nothing runs here, and the job's items move
//   only when the agent reports. `continueInDesktop` moves a running terminal session there.
import Foundation

public enum DispatchMode: String { case together, parallel }
public enum WorktreeChoice: String { case on, off, auto }

public struct DispatchWarning {
    public let code: String              // concurrent_edit | no_git | no_tmux | draft_confirmed | taken_back
    public let jobs: [String]
    public let items: [String]

    /// The Terminal.strings key of its sentence in the panel: one item or several read differently ("this item" /
    /// "these items"; Chinese has no plural form to pick from, so the count picks the key).
    public var noteKey: String { code == "taken_back" && items.count == 1 ? "warning.taken_back.one" : "warning.\(code)" }
    /// A note about what will happen anyway (unreviewed items become To Do) is a check; one that is worth reading
    /// before Start (no git, no tmux, items taken back from an ended session) is the info mark.
    public var symbol: String { code == "draft_confirmed" ? "checkmark.circle" : "info.circle" }
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
    /// --runner desktop: each job's link into the desktop app, in job order (only links DesktopLink accepts).
    public var links: [(job: String, url: URL)] = []
    /// A desktop dry run: is the blurt MCP installed for the agent (false = nothing reports progress; nil = unknown).
    public var mcp: Bool? = nil
}

/// The claude:// link a desktop hand-off opens. Only the desktop app's own scheme is ever opened from a sessions.py
/// answer — never a web or file URL.
public enum DesktopLink {
    public static let schemes: Set<String> = ["claude"]

    public static func url(_ s: String?) -> URL? {
        guard let s = s, let u = URL(string: s), let sc = u.scheme?.lowercased(), schemes.contains(sc) else { return nil }
        return u
    }

    /// The folder and prompt a link carries (self-tests and logs say what was opened without the whole prompt).
    public static func parts(_ u: URL) -> (folder: String?, prompt: String?) {
        let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return (q.first { $0.name == "folder" }?.value, q.first { $0.name == "q" }?.value)
    }
}

/// sessions.py desktop-check: may a running terminal session continue in the desktop app.
public struct DesktopContinueCheck: Equatable {
    public let available: Bool
    /// unsupported | not_installed | version | login
    public let reason: String?
    public let version: String?
    /// Is the blurt MCP installed for the agent (nil = can't tell)? false: the desktop app would have nothing to report
    /// progress with — the confirmation says the items then need marking by hand and offers Install.
    public let mcp: Bool?
    public init(available: Bool, reason: String?, version: String?, mcp: Bool? = nil) {
        self.available = available; self.reason = reason; self.version = version; self.mcp = mcp
    }
}

/// sessions.py said {"ok": false, "code": …}. The UI shows `code` localized (Terminal table `error.<code>`).
public struct SessionsError: Error, CustomStringConvertible {
    public let code: String
    public let message: String
    /// The session it is about (already_dispatched: the one the item is with).
    public var job: String? = nil
    /// What sessions.py adds for people: auth's fix ("run `claude` and log in"), the item id it is about (BA-12), the
    /// agent. The message itself is for the log only.
    public var fix: String? = nil, itemID: String? = nil, agent: String? = nil
    /// outdated: the installed version and the one hand-offs need ("0.157.0", "0.164.0").
    public var version: String? = nil, need: String? = nil
    public var description: String { "\(code): \(message)" }

    public init(code: String, message: String, job: String? = nil, fix: String? = nil, itemID: String? = nil, agent: String? = nil) {
        self.code = code; self.message = message; self.job = job; self.fix = fix; self.itemID = itemID; self.agent = agent
    }

    /// From sessions.py's {"ok": false, "code", "error", …} line.
    public init(json o: [String: Any], fallback: String) {
        self.init(code: o["code"] as? String ?? fallback, message: o["error"] as? String ?? "", job: o["job"] as? String,
                  fix: (o["fix"] as? String).flatMap { $0.isEmpty ? nil : $0 }, itemID: (o["id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                  agent: o["agent"] as? String)
        version = o["version"] as? String
        need = o["need"] as? String
    }
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
            var e = SessionsError(json: o, fallback: status == 4 ? "missing_dependency" : "failed")
            if o["error"] == nil { e = SessionsError(code: e.code, message: String(stderr.suffix(400)), job: e.job) }
            throw e
        } catch ScriptError.scriptMissing(let p) {
            throw SessionsError(code: "no_sessions_cli", message: "missing \(p)")
        } catch ScriptError.uvMissing {
            throw SessionsError(code: "uv_missing", message: "uv not found")
        } catch ScriptError.timeout(let t) {
            throw SessionsError(code: "timeout", message: "sessions.py timed out after \(Int(t)) s")
        }
        let o = Self.lastJSON(out)
        if o["ok"] as? Bool == false { throw SessionsError(json: o, fallback: "failed") }
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

    /// `model`: the agent's model (Agents.models); nil / "" = whatever the CLI is set to. `loginChecked`: the caller
    /// already knows the agent is logged in (the dispatch panel won't start otherwise) — sessions.py skips its own
    /// login check (--force); without it, a logged-out agent fails with code auth.
    /// `desktop`: the agent's desktop app instead of a terminal (`--runner desktop`): the result's `links` are for the
    /// caller to open.
    public func dispatch(items: [String], agent: String?, mode: DispatchMode, worktree: WorktreeChoice, dryRun: Bool,
                         model: String? = nil, loginChecked: Bool = false, desktop: Bool = false) async throws -> DispatchResult {
        var args = ["dispatch", "--items"] + items + ["--mode", mode.rawValue, "--worktree", worktree.rawValue, "--lang", lang]
        if desktop { args += ["--runner", "desktop"] }
        if loginChecked && !dryRun { args.append("--force") }
        if let a = agent, !a.isEmpty { args += ["--agent", a] }
        if let m = model, !m.isEmpty { args += ["--model", m] }
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
        var r = DispatchResult(jobs: rows.compactMap { $0["id"] as? String }, warnings: warnings, launch: launch, rows: rows)
        r.links = Self.links(rows)
        r.mcp = o["mcp"] as? Bool
        return r
    }

    static func links(_ rows: [[String: Any]]) -> [(job: String, url: URL)] {
        rows.compactMap { r in
            guard let j = r["id"] as? String, let u = DesktopLink.url(r["url"] as? String) else { return nil }
            return (j, u)
        }
    }

    /// A running terminal session moves to the desktop app (`sessions.py continue-desktop`): its agent ends here.
    /// withoutMCP: the user agreed to go on with no blurt MCP there (items marked by hand); else that is refused.
    public func continueInDesktop(job: String, withoutMCP: Bool = false) async throws {
        _ = try await call(["continue-desktop", job] + (withoutMCP ? ["--without-mcp"] : []), timeout: 60)
    }

    /// May terminal sessions of `agent` continue in its desktop app (CLI version, a subscription login)? Probes only.
    public func desktopCheck(agent: String) async throws -> DesktopContinueCheck {
        let o = try await call(["desktop-check", "--agent", agent], timeout: 45)
        return DesktopContinueCheck(available: o["available"] as? Bool ?? false, reason: o["reason"] as? String,
                                    version: o["version"] as? String, mcp: o["mcp"] as? Bool)
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

    /// diff | merge | pr | discard | keep → the CLI's JSON (diff: base, branch, stat, patch, uncommitted, alive,
    /// reviewed). `expect` (merge / pr): diff's `reviewed` token — what the user saw; anything else fails with code
    /// changed, so nothing lands unreviewed.
    public func finish(job: String, action: String, expect: String? = nil) async throws -> [String: Any] {
        try await call(["finish", job, "--action", action] + (expect.map { ["--expect", $0] } ?? []),
                       timeout: action == "pr" ? 180 : 90)
    }

    /// 收回 (`sessions.py take-back`): its items back to To Do; an ended session with no change also goes (window,
    /// worktree, branch). → has changes left in its worktree (they stay, for review).
    public func takeBack(job: String) async throws -> Bool {
        let o = try await call(["take-back", job], timeout: 60)
        return o["has_changes"] != nil
    }

    /// After items were taken back elsewhere (items.py): `sessions.py clean-up` — an ended session cleans up only once
    /// none of its items is still with it; it takes nothing back. → true when it kept a worktree with changes.
    public func cleanUp(job: String) async throws -> Bool {
        let o = try await call(["clean-up", job], timeout: 60)
        return o["has_changes"] != nil
    }

    /// The same items, agent and model in a fresh session (`sessions.py restart`): for one that ended without
    /// changes. The old window, worktree and branch go.
    public func restart(job: String) async throws -> DispatchResult {
        let o = try await call(["restart", job, "--lang", lang], timeout: 120)
        let rows = o["jobs"] as? [[String: Any]] ?? []
        let launch = (o["launch"] as? [[String: Any]] ?? []).compactMap { l -> AppLaunch? in
            guard let job = l["job"] as? String, let argv = l["argv"] as? [String], !argv.isEmpty else { return nil }
            return AppLaunch(job: job, argv: argv, env: l["env"] as? [String: String] ?? [:],
                             cwd: URL(fileURLWithPath: l["cwd"] as? String ?? NSHomeDirectory()))
        }
        var r = DispatchResult(jobs: rows.compactMap { $0["id"] as? String }, warnings: [], launch: launch, rows: rows)
        r.links = Self.links(rows)
        return r
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
