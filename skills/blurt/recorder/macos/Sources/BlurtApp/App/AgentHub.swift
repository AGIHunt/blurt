// Which coding agent processes a recording, headless — with automatic fallback and errors that say why.
//
// The registry is agents.json (skills/blurt/scripts/agents.json, bundled into Blurt.app/Contents/Resources; agents.py
// implements the same rules for the scripts and the tests). Order: config record.agents (default: the registry's order
// — Claude Code, Codex, Kimi Code, OpenCode, Gemini CLI); record.agent_defs adds or overrides an agent.
// The first one that is installed and not known to be logged out runs. If it fails before items.json exists for a
// reason another agent wouldn't share (login, quota, model), the next one gets the recording. Every attempt and every
// skipped agent is written to <session>/agent.log and meta.json → "agent"; the toasts say the same in one line, for
// every switch (before the run or during it), once per job — and the job itself keeps it (`organizer`: its detail says
// "由 Codex 整理（Claude Code 没登录）"). A run the app starts re-checks every agent that wasn't ready (a probe spends no
// tokens): logging in and pressing Retry works at once, never "no usable agent" from a minute-old answer. With none
// usable, the job says each agent of the user's order with its own fix.
// Every run here is unattended on recording-derived text, so it gets the least privilege (BlurtCore UnattendedRun):
// cwd = the session folder (AI fill-in: a scratch folder under $BLURT_HOME/tmp), never the project, whose code the
// prompt names for reading only; Claude / Gemini may run only the skill's scripts by absolute path; Codex's sandbox
// may write the item stores and its own uv cache, nothing in $BLURT_HOME — so the app re-indexes and records the
// job's items itself after the run.
// An organising run is its own process group (ProcessGroup, its id on the job as agent_pgid): it stops with the app
// (AppDelegate asks first), a crashed app's leftover is stopped at the next launch (Housekeeping), and a recording
// already being organised is never started twice (process() returns the job at it).
// BLURT_AGENT_PATH (tests): directories searched for agent CLIs before the user's PATH.

import AppKit
import BlurtCore

struct AgentDef {
    let id: String
    let name: String
    let bins: [String]
    let verified: String
    let status: [String: Any]
    let run: [String]
    let fix: [String: String]
    let install: [String: String]

    init?(_ o: [String: Any]) {
        guard let id = o["id"] as? String else { return nil }
        self.id = id
        name = o["name"] as? String ?? id
        bins = o["bins"] as? [String] ?? [id]
        verified = o["verified"] as? String ?? "docs"
        status = o["status"] as? [String: Any] ?? [:]
        run = o["run"] as? [String] ?? ["{prompt}"]
        fix = o["fix"] as? [String: String] ?? [:]
        install = o["install"] as? [String: String] ?? [:]
        headless = o["headless"] as? Bool ?? true
        modelArgs = o["model_args"] as? [String: [String]] ?? [:]
        processingDefault = o["processing"]
        modelsSpec = o["models"] as? [String: Any] ?? [:]
        usageSpec = o["usage"] as? [String: Any] ?? [:]
        desktop = (o["interactive"] as? [String: Any])?["desktop"] as? [String: Any]
    }
    /// interactive.desktop: the agent's desktop app as a hand-off target (Claude) — name, url, app {macos: bundle id}.
    let desktop: [String: Any]?
    /// false = an app / interactive-only entry (WP2's zcode): never in the background chain or its menus.
    let headless: Bool
    let modelArgs: [String: [String]]
    /// agents.json `processing`: per kind (recording / cards), or v0.8's one {model, effort} (ProcessingSpec)
    let processingDefault: Any?
    let modelsSpec: [String: Any]
    let usageSpec: [String: Any]
    var fixText: String { Loc.pick(fix) ?? "" }
    var installText: String { Loc.pick(install) ?? "" }

    /// The headless command line for the shell (cwd = the session or a scratch folder); `extra` goes after the run
    /// arguments. Every headless run is unattended on recording-derived text, so `run` asks for the least privilege
    /// (agents.json, UnattendedRun.args): "{scripts}" = the only scripts it may run, "{writable}" = one `--add-dir` per
    /// folder it may write besides its cwd (AgentHub.writableDirs; codex's sandbox).
    func command(bin: String, prompt: String, extra: [String] = [], writable: [String] = AgentHub.writableDirs()) -> String {
        let args = UnattendedRun.args(run, prompt: prompt, scripts: BlurtPaths.scripts.path, writable: writable)
        return ([bin] + args + extra).map(shq).joined(separator: " ")
    }

    /// Runs in a sandbox that keeps $BLURT_HOME read-only (codex): it needs its own uv cache and no index writes.
    var sandboxEnv: [String: String] { run.contains("{writable}") ? UnattendedRun.sandboxEnv(home: BlurtPaths.home) : [:] }

    // MARK: the processing model (same rules as agents.py processing / models / parse_usage)

    static let efforts = ["low", "medium", "high", "xhigh", "max"]
    private static let cheapWords = try! NSRegularExpression(pattern: #"\b(affordable|cheap|cheapest|fast|efficient|mini|nano|small|lite|flash|haiku)\b"#,
                                                             options: [.caseInsensitive])

    /// The cheap model: the first one marked cheap in agents.json's list, or (Codex) in the CLI's own model cache —
    /// the picker's models, best first, whose description says fast / affordable.
    func cheapestModel(env: [String: String]) -> String? {
        if let list = modelsSpec["list"] as? [[String: Any]] {
            return list.first { $0["cheap"] as? Bool == true }?["id"] as? String
        }
        guard let cache = modelsSpec["cache"] as? String,
              let d = FileManager.default.contents(atPath: AgentDef.expand(cache, env: env)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let listed = (o["models"] as? [[String: Any]] ?? []).filter { ($0["visibility"] as? String ?? "list") == "list" && $0["slug"] is String }
            .sorted { ($0["priority"] as? Double ?? 999) < ($1["priority"] as? Double ?? 999) }
        return listed.first { m in
            let s = m["description"] as? String ?? ""
            return AgentDef.cheapWords.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }?["slug"] as? String
    }

    /// record.agent_processing.<id>.<kind> over agents.json `processing`: model id | "cheapest" | "default", effort |
    /// "default". A recording: the CLI's own model at low effort; cards and AI fill-in: the cheapest (ProcessingSpec).
    func processing(env: [String: String], kind: ProcessingKind) -> (model: String?, effort: String?) {
        let over = (recordConfig()["agent_processing"] as? [String: Any])?[id]
        let want = ProcessingSpec.wanted(base: processingDefault, over: over, kind: kind)
        var model: String?
        if !want.model.isEmpty, want.model != "default" { model = want.model == "cheapest" ? cheapestModel(env: env) : want.model }
        let effort = AgentDef.efforts.contains(want.effort) ? want.effort : nil
        return (modelArgs["model"] == nil ? nil : model, modelArgs["effort"] == nil ? nil : effort)
    }

    /// The flags an unattended organising run adds: model, effort, and the ones that make the CLI report its usage.
    func processingArgs(env: [String: String], kind: ProcessingKind) -> (args: [String], model: String?, effort: String?) {
        let p = processing(env: env, kind: kind)
        var out: [String] = []
        if let m = p.model { out += (modelArgs["model"] ?? []).map { $0.replacingOccurrences(of: "{model}", with: m) } }
        if let e = p.effort { out += (modelArgs["effort"] ?? []).map { $0.replacingOccurrences(of: "{effort}", with: e) } }
        out += usageSpec["args"] as? [String] ?? []
        return (out, p.model, p.effort)
    }

    /// The tokens a run reported in its output: usage.pattern (Codex's "tokens used 24,953"), else a JSON result
    /// line with a usage object (Claude's --output-format json).
    func tokensUsed(in raw: String) -> Int? {
        let text = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        if let p = usageSpec["pattern"] as? String,
           let re = try? NSRegularExpression(pattern: p.replacingOccurrences(of: "(?im)", with: ""), options: [.caseInsensitive, .anchorsMatchLines]),
           let m = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).last, m.numberOfRanges > 1,
           let r = Range(m.range(at: 1), in: text) {
            let digits = text[r].filter(\.isNumber)
            if let n = Int(digits) { return n }
        }
        var total: Int?
        for line in text.split(separator: "\n") where line.hasPrefix("{") && line.contains("\"usage\"") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let u = o["usage"] as? [String: Any] else { continue }
            let n = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
                .compactMap { (u[$0] as? NSNumber)?.intValue }.reduce(0, +)
            guard n > 0 else { continue }
            if o["type"] as? String == "result" { total = n }
            else if o["type"] as? String == "turn.completed" { total = (total ?? 0) + n }
        }
        return total
    }

    /// ~ and ${VAR:-default} / $VAR (agents.py expand).
    static func expand(_ path: String, env: [String: String]) -> String {
        var s = path
        let re = try! NSRegularExpression(pattern: #"\$\{(\w+)(?::-([^}]*))?\}|\$(\w+)"#)
        for m in re.matches(in: path, range: NSRange(path.startIndex..., in: path)).reversed() {
            let name = Range(m.range(at: 1), in: path).map { String(path[$0]) } ?? Range(m.range(at: 3), in: path).map { String(path[$0]) } ?? ""
            let def = Range(m.range(at: 2), in: path).map { String(path[$0]) }
            let v = env[name].flatMap { $0.isEmpty ? nil : $0 } ?? def ?? ""
            if let r = Range(m.range, in: s) { s.replaceSubrange(r, with: v) }
        }
        return (s as NSString).expandingTildeInPath
    }
}

struct FailureDef {
    let id: String
    let short: [String: String]
    let reason: [String: String]
    let patterns: [NSRegularExpression]

    var shortText: String { Loc.pick(short) ?? id }
    func reasonText(_ a: AgentDef) -> String {
        (Loc.pick(reason) ?? id).replacingOccurrences(of: "{name}", with: a.name).replacingOccurrences(of: "{fix}", with: a.fixText)
    }
}

enum AgentState: String {
    case ready, configured, loggedOut = "logged_out", unknown, notInstalled = "not_installed", checking
    var usable: Bool { self == .ready || self == .configured || self == .unknown }
}

struct AgentStatus {
    let def: AgentDef
    let bin: String?
    let state: AgentState
    let at: Date

    /// ✓ / ✗ in menus and lists: check (green) or x (red); nil while checking (shown as "…").
    var markIcon: BlurtIcon? { state == .checking ? nil : state.usable ? .check : .x }
    /// "没登录 — 在终端运行 codex login"
    var why: String {
        switch state {
        case .ready: return T("app.agent.logged")
        case .configured: return T("app.agent.configured_can_verify_advance")
        case .unknown: return T("app.agent.login_unknown_will_just")
        case .loggedOut: return T("app.agent.not_logged") + (def.fixText.isEmpty ? "" : " — " + def.fixText)
        case .notInstalled: return T("app.agent.not_installed") + (def.installText.isEmpty ? "" : " — " + def.installText)
        case .checking: return T("app.agent.checking")
        }
    }
    /// For "Claude Code 没登录，这次用 Codex 整理"
    var shortWhy: String {
        switch state {
        case .loggedOut: return T("app.agent.isn_logged")
        case .notInstalled: return T("app.agent.isn_installed")
        default: return T("app.agent.can_be_used")
        }
    }
}

final class AgentHub {
    static let shared = AgentHub()
    private(set) var defs: [AgentDef] = []
    private(set) var failures: [FailureDef] = []
    private var cache: [String: AgentStatus] = [:]
    private var inFlight: [String: [(AgentStatus) -> Void]] = [:]

    init() { reload() }

    func reload() {
        var reg: [String: Any] = [:]
        var urls: [URL] = []
        if let u = Bundle.main.url(forResource: "agents", withExtension: "json") { urls.append(u) }
        if let s = readConfig()["skill_dir"] as? String { urls.append(URL(fileURLWithPath: s).appendingPathComponent("scripts/agents.json")) }
        for u in urls {
            if let d = try? Data(contentsOf: u), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { reg = o; break }
        }
        var list = (reg["agents"] as? [[String: Any]] ?? AgentHub.fallback).compactMap(AgentDef.init)
        for (k, v) in recordConfig()["agent_defs"] as? [String: Any] ?? [:] {
            guard var o = v as? [String: Any] else { continue }
            o["id"] = k
            if let i = list.firstIndex(where: { $0.id == k }) {
                var base = (reg["agents"] as? [[String: Any]])?.first { $0["id"] as? String == k } ?? [:]
                base.merge(o) { _, new in new }
                if let d = AgentDef(base) { list[i] = d }
            } else if let d = AgentDef(o) { list.append(d) }
        }
        defs = list
        failures = (reg["failures"] as? [[String: Any]] ?? []).compactMap { f in
            guard let id = f["id"] as? String else { return nil }
            let pats = (f["patterns"] as? [String] ?? []).compactMap {
                try? NSRegularExpression(pattern: $0, options: [.caseInsensitive, .anchorsMatchLines])
            }
            return FailureDef(id: id, short: f["short"] as? [String: String] ?? [:], reason: f["reason"] as? [String: String] ?? [:], patterns: pats)
        }
    }

    /// Used only if agents.json can't be found at all.
    static let fallback: [[String: Any]] = [
        ["id": "claude", "name": "Claude Code", "bins": ["claude"],
         "status": ["args": ["auth", "status", "--json"], "json_key": "loggedIn", "logged_out": ["not logged in"]],
         "run": ["-p", "{prompt}", "--permission-mode", "acceptEdits", "--allowedTools", "Bash(uv run {scripts}/transcribe.py:*)",
                 "Bash(uv run {scripts}/frames.py:*)", "Bash(uv run {scripts}/items.py:*)", "Bash(uv run {scripts}/projects.py list:*)",
                 "Bash(uv run {scripts}/index.py search:*)", "Read", "Glob", "Grep"],
         "fix": ["zh": "在终端运行 claude，然后输入 /login", "en": "run `claude` in a terminal and /login"]],
        ["id": "codex", "name": "Codex", "bins": ["codex"],
         "status": ["args": ["login", "status"], "logged_out": ["not logged in"], "ok_if": ["logged in"]],
         "run": ["exec", "--skip-git-repo-check", "--sandbox", "workspace-write", "-c", "sandbox_workspace_write.network_access=true",
                 "{writable}", "{prompt}"],
         "fix": ["zh": "在终端运行 codex login", "en": "run `codex login` in a terminal"]],
    ]

    func def(_ id: String) -> AgentDef? { defs.first { $0.id == id } }

    /// What an unattended run may write besides its cwd (agents.json "{writable}", the same list as agents.py
    /// writable_dirs): the inbox store, every project's store that exists, its own uv cache — not $BLURT_HOME.
    static func writableDirs() -> [String] {
        let ps = ProjectStore.shared
        return UnattendedRun.writableDirs(inbox: ps.inbox.store, projectStores: ps.projects.map(\.store), home: BlurtPaths.home)
    }

    /// The project's code, for the prompt: the agent may read it (code_refs), but its cwd and writes are elsewhere.
    static func codeHint(_ project: Project?) -> String {
        guard let p = project, !p.isInbox, p.exists else { return "" }
        return "\nThe project's code (read it, change nothing there): \(p.path.path)"
    }

    /// record.agents, else the registry order with a legacy record.process = "claude" | "codex" first.
    func order() -> [AgentDef] {
        let rec = recordConfig()
        var want: [String] = rec["agents"] as? [String] ?? []
        if let s = rec["agents"] as? String { want = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        var seen = Set<String>()
        let listed = want.compactMap { id -> AgentDef? in seen.insert(id).inserted ? def(id) : nil }.filter(\.headless)
        if !listed.isEmpty { return listed }
        var all = defs.filter(\.headless)
        if let legacy = rec["process"] as? String, let i = all.firstIndex(where: { $0.id == legacy }) { all.insert(all.remove(at: i), at: 0) }
        return all
    }

    /// Put `id` first in record.agents (the menu's "use first").
    func prefer(_ id: String) {
        var ids = order().map(\.id).filter { $0 != id }
        ids.insert(id, at: 0)
        setRecordConfig("agents", ids)
    }

    func cached(_ id: String) -> AgentStatus? { cache[id] }

    /// Statuses in order; fresh ones from the cache (OK: 10 min, anything else: 1 min), the rest checked in parallel.
    /// `recheck`: anything not ready is checked again whatever its age (a run about to start: the user may just have
    /// logged in).
    func check(_ list: [AgentDef], force: Bool = false, recheck: Bool = false, then: @escaping ([AgentStatus]) -> Void) {
        let group = DispatchGroup()
        for d in list {
            if !force, let c = cache[d.id], !(recheck && c.state != .ready),
               Date().timeIntervalSince(c.at) < (c.state == .ready ? 600 : 60) { continue }
            group.enter()
            if inFlight[d.id] != nil { inFlight[d.id]!.append { _ in group.leave() }; continue }
            inFlight[d.id] = [{ _ in group.leave() }]
            DispatchQueue.global().async {
                let s = AgentHub.probe(d)
                DispatchQueue.main.async {
                    self.cache[d.id] = s
                    for cb in self.inFlight.removeValue(forKey: d.id) ?? [] { cb(s) }
                }
            }
        }
        group.notify(queue: .main) { then(list.map { self.cache[$0.id] ?? AgentStatus(def: $0, bin: nil, state: .unknown, at: Date()) }) }
    }

    func invalidate(_ id: String, as state: AgentState? = nil) {
        if let s = state, let c = cache[id] { cache[id] = AgentStatus(def: c.def, bin: c.bin, state: s, at: Date()) } else { cache[id] = nil }
    }

    static func locate(_ d: AgentDef) -> String? {
        for b in d.bins {
            for dir in (ProcessInfo.processInfo.environment["BLURT_AGENT_PATH"] ?? "").split(separator: ":") {
                let p = "\(dir)/\(b)"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
            if let p = findExecutable(b) { return p }
        }
        return nil
    }

    /// Off the main thread: is it installed, and logged in in the env it will get? Spends no tokens.
    static func probe(_ d: AgentDef) -> AgentStatus {
        guard let bin = locate(d) else { return AgentStatus(def: d, bin: nil, state: .notInstalled, at: Date()) }
        var code: Int32?
        var text = ""
        let env = agentEnvironment()
        if let args = d.status["args"] as? [String] {
            let r = runCapture(bin, args, env: env, timeout: 15)
            code = r.status
            text = String(data: r.out, encoding: .utf8) ?? ""
        }
        return AgentStatus(def: d, bin: bin, state: parseStatus(d, code: code, text: text, env: env), at: Date())
    }

    /// Same rules as agents.py parse_status.
    static func parseStatus(_ d: AgentDef, code: Int32?, text: String, env: [String: String]) -> AgentState {
        let st = d.status
        let low = text.lowercased()
        if let key = st["json_key"] as? String, let s = text.firstIndex(of: "{"),
           let j = try? JSONSerialization.jsonObject(with: Data(text[s...].utf8), options: [.fragmentsAllowed]) as? [String: Any],
           let b = j[key] as? Bool {
            return b ? .ready : .loggedOut
        }
        if let key = st["json_key"] as? String, let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"), s < e,
           let j = try? JSONSerialization.jsonObject(with: Data(text[s...e].utf8)) as? [String: Any], let b = j[key] as? Bool {
            return b ? .ready : .loggedOut
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        func expand(_ p: String) -> String { p.hasPrefix("~/") ? home.appendingPathComponent(String(p.dropFirst(2))).path : p }
        // a credentials file whose tokens are all empty (kimi: provider listed, `kimi -p` fails "no credential configured")
        if let cj = st["creds_json"] as? [String: Any], let p = cj["path"] as? String,
           let d = FileManager.default.contents(atPath: expand(p)), let creds = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           !(cj["keys"] as? [String] ?? []).contains(where: { k in
               if let s = creds[k] as? String { return !s.isEmpty }
               return creds[k] != nil && !(creds[k] is NSNull)
           }) {
            return .loggedOut
        }
        if (st["logged_out"] as? [String] ?? []).contains(where: { low.contains($0) }) { return .loggedOut }
        if code == 0, (st["ok_if"] as? [String] ?? []).contains(where: { low.contains($0) }) { return .ready }
        if let re = st["configured_if"] as? String, text.range(of: re, options: [.regularExpression, .caseInsensitive]) != nil { return .configured }
        if (st["env_any"] as? [String] ?? []).contains(where: { !(env[$0] ?? "").isEmpty }) { return .configured }
        if (st["files_any"] as? [String] ?? []).contains(where: { FileManager.default.fileExists(atPath: expand($0)) }) { return .configured }
        if st["otherwise"] as? String == "logged_out" && (code != nil || st["args"] == nil) { return .loggedOut }
        return .unknown
    }

    /// A failed run's log → its failure class: error-looking lines of the tail first, then the whole tail (as agents.py).
    func classify(_ raw: String) -> FailureDef? {
        let clean = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        let tail = clean.suffix(6000).split(separator: "\n", omittingEmptySubsequences: false).suffix(80).joined(separator: "\n")
        let errorish = tail.split(separator: "\n").filter {
            $0.range(of: "error|fail|fatal|exception|denied|invalid|expired|unauthori|limit|not logged|quota|refused|not found|couldn't|could not|unable|错误|失败",
                     options: [.regularExpression, .caseInsensitive]) != nil
        }.joined(separator: "\n")
        for scope in [errorish, tail] {
            let r = NSRange(scope.startIndex..., in: scope)
            for f in failures where f.patterns.contains(where: { $0.firstMatch(in: scope, range: r) != nil }) { return f }
        }
        return nil
    }
}

// MARK: - the session's record of who processed it (meta.json → "agent", agent.log)

func updateMeta(_ dir: URL, _ change: (inout [String: Any]) -> Void) {
    let f = dir.appendingPathComponent("meta.json")
    var meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: f))) as? [String: Any] ?? [:]
    change(&meta)
    if let d = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: f) }
}

func appendLog(_ log: URL, _ text: String) {
    if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
    guard let fh = try? FileHandle(forWritingTo: log) else { return }
    fh.seekToEndOfFile()
    fh.write(Data(text.utf8))
    try? fh.close()
}

func nowStamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: Date())
}

/// What the recent-recordings row says about a session that has no items.json: "✗ 登录失效" etc.
func agentFailureNote(_ dir: URL) -> String? {
    let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meta.json")))) as? [String: Any]
    guard let a = meta?["agent"] as? [String: Any], let r = a["result"] as? String, r != "ok", r != "running" else { return nil }
    return a["short"] as? String ?? T("app.agent.failed")
}

extension App {
    /// Organise a capture session with a coding agent, headless, as a process job (K4) the main window, the island
    /// and the menu bar follow. `captures`: only these shots.jsonl entries (nil = the whole session); `project`: file
    /// the items there (nil = the session's own project, or Unassigned — then the run is told the projects and may
    /// suggest one per item; nothing moves). `only`: that agent, no fallback.
    /// Nothing opens when it finishes — JobNotifier says so quietly (K4 notification rules).
    /// → the job organising it: the new one, or the one already at it — one organiser per recording, whatever asks
    /// (a Retry, a second batch, a relaunch), checked against the job files, not only this run's memory.
    @discardableResult
    func process(_ dir: URL, only: String? = nil, captures: [Int]? = nil, project: String? = nil) -> String? {
        JobStore.shared.rescan()
        let path = dir.standardizedFileURL.path
        if let running = JobStore.shared.active.first(where: { $0.type == .process && $0.session?.standardizedFileURL.path == path }) {
            emit(["event": "process_already_running", "job": running.id, "session": dir.path])
            return running.id
        }
        guard !processing.contains(dir.path) else { return nil }
        processing.append(dir.path)
        refreshStatus()
        let store = ProjectStore.shared
        let pid = project ?? store.project(containing: dir).map(\.id)
        let job = JobWriter(type: .process, project: pid, session: dir)
        if let c = captures { job.setCaptures(c) }
        job.step("prepare", .running)
        // tests: BLURT_TEST_PROCESS=done|failed plays the job out in ~4 s instead of starting an agent (K7 details)
        if let outcome = ProcessInfo.processInfo.environment["BLURT_TEST_PROCESS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { job.step("prepare", .done); job.step("write", .running, progress: 0.4) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                job.setItems((captures ?? [0]).map { "test-\($0)" })
                job.step("write", outcome == "done" ? .done : .failed)
                job.finish(outcome == "done" ? .done : .failed,
                           error: outcome == "done" ? nil : JobError(code: "unknown", message: "processing failed (test)"))
                self?.processing.removeAll { $0 == dir.path }
                self?.refreshStatus()
            }
            return job.id
        }
        let hub = AgentHub.shared
        hub.reload()
        let order = only.flatMap { hub.def($0) }.map { [$0] } ?? hub.order()
        let log = dir.appendingPathComponent("agent.log")
        hub.check(order, recheck: true) { [weak self] statuses in
            guard let self = self else { return }
            let skipped = Array(statuses.prefix { !$0.state.usable })
            let queue = statuses.filter { $0.state.usable }
            guard !queue.isEmpty else { return self.noAgent(dir, statuses, job: job) }
            if !skipped.isEmpty {
                appendLog(log, "── blurt \(nowStamp()) · " + skipped.map { "\($0.def.name): \($0.why)" }.joined(separator: " · ") + "\n")
                self.noteFallback(skipped.map { $0.def.name + $0.shortWhy }, using: queue[0].def, job: job)
            }
            // an Unassigned capture: the run is told the projects, so it can leave a suggestion per item (nothing moves)
            self.candidates(for: dir, project: project) { text in
                job.step("prepare", .done)
                self.attempt(dir, queue: queue, skipped: skipped.map { ($0.def, $0.def.name + $0.shortWhy) }, job: job, captures: captures,
                             project: project, candidates: text)
            }
        }
        return job.id
    }

    /// `projects.py candidates` → its prompt text, when the capture has no project (OrganizerPrompt.wantsCandidates);
    /// nil otherwise, or when it can't be had (the run then simply suggests nothing). Main thread.
    func candidates(for dir: URL, project: String?, then: @escaping (String?) -> Void) {
        let sessionProject = ProjectStore.shared.project(containing: dir)?.id
        guard OrganizerPrompt.wantsCandidates(runProject: project, sessionProject: sessionProject),
              !ProjectStore.shared.projects.isEmpty else { return then(nil) }
        Scripts.call("projects.py", ["candidates"], timeout: 30) { r in
            var text: String?
            if case .success(let o) = r { text = o["text"] as? String }
            emit(["event": "organize_candidates", "session": dir.path, "projects": ProjectStore.shared.projects.count,
                  "chars": text?.count ?? 0])
            then(text)
        }
    }

    /// Another agent organises instead of the first in the user's order (it couldn't run, or stopped on login, quota
    /// or model during the run): say so on the island — every switch, once per job — and keep it on the job, whose
    /// detail says who organised it instead of whom. `why`: "Claude Code 没登录", one per agent passed over.
    func noteFallback(_ why: [String], using: AgentDef, job: JobWriter) {
        let key = why.joined(separator: ",") + ">" + using.id
        guard App.fallbackNoted[job.id] != key else { return }
        App.fallbackNoted[job.id] = key
        job.set("organizer", ["agent": using.id, "instead_of": why] as [String: Any])
        emit(["event": "organize_fallback", "job": job.id, "agent": using.id, "instead_of": why])
        AppEnvironment.island?.toast(T("app.agent.fallback_notice", why.joined(separator: T("app.agent.list_sep")), using.name),
                                     actionTitle: nil, action: nil)
    }
    /// job id → the switch already said for it
    static var fallbackNoted: [String: String] = [:]

    /// "还没有能用的 Agent：Claude Code 没登录 — 在终端运行 claude，然后输入 /login；Codex 没安装 — …" — each agent of the
    /// user's order with its own fix, never a fixed list.
    static func noAgentReason(_ statuses: [AgentStatus]) -> String {
        T("main.job.no_agent", statuses.map { "\($0.def.name) \($0.why)" }.joined(separator: T("main.job.no_agent.sep")))
    }

    func noAgent(_ dir: URL, _ statuses: [AgentStatus], job: JobWriter) {
        processing.removeAll { $0 == dir.path }
        refreshStatus()
        let lines = statuses.map { "\($0.def.name): \($0.why)" }
        appendLog(dir.appendingPathComponent("agent.log"), "── blurt \(nowStamp()) · no usable agent, not processed:\n"
                  + lines.map { "   " + $0 }.joined(separator: "\n") + "\n")
        updateMeta(dir) { m in
            m["agent"] = ["result": "none", "short": T("app.agent.none_short"), "at": nowStamp(),
                          "agents": statuses.map { ["id": $0.def.id, "state": $0.state.rawValue, "why": $0.why] }]
        }
        job.finish(.failed, error: JobError(code: "auth", message: lines.joined(separator: "; "), reason: App.noAgentReason(statuses)))
        Refile.runEnded(dir)
    }

    /// The agent's instructions for an unattended run (English: agents read it, the user never does).
    func processPrompt(_ dir: URL, captures: [Int]?, project: String? = nil, candidates: String? = nil) -> String {
        OrganizerPrompt.with(basePrompt(dir, captures: captures, project: project), candidates: candidates)
    }

    private func basePrompt(_ dir: URL, captures: [Int]?, project: String?) -> String {
        let what = isShotsSession(dir)
            ? "Use the blurt skill to process this batch of captures: \(dir.path)\nIt is a shots session (no video): each shot "
              + "anchors one item and is that item's primary frame; voice notes are transcribed first; .marked.png files carry the user's ink."
            : "Use the blurt skill to process this recording: \(dir.path)"
        let only = captures.map { "\nOnly these captures (shots.jsonl n): " + $0.map(String.init).joined(separator: ", ") + "." } ?? ""
        let skill = "\nThe blurt skill: \(BlurtPaths.skillDir.path)/SKILL.md" + UnattendedRun.scriptsHint(BlurtPaths.scripts.path)
        return what + only + "\nThis is an unattended background run started by the Blurt app: don't ask questions and don't start the "
            + "review page. Write items.json and run items.py ingest as SKILL.md says, then summarise in 2–3 sentences." + skill
            + AgentHub.codeHint(project.flatMap { ProjectStore.shared.project(id: $0) } ?? ProjectStore.shared.project(containing: dir))
    }

    /// Run queue[0]; on a failure another agent wouldn't share (login, quota, model), move on to the next.
    func attempt(_ dir: URL, queue: [AgentStatus], skipped: [(AgentDef, String)], job: JobWriter, captures: [Int]?, project: String?,
                 candidates: String? = nil) {
        guard let a = queue.first, let bin = a.bin else { return noAgent(dir, queue, job: job) }
        let cwd = dir  // never the project: what an injected run could change there is the user's code
        // the processing model for this kind of run (Settings → Agents): a recording with the CLI's own model at low
        // effort, a batch of cards with the cheapest one
        let kind = ProcessingSpec.kind(forSession: dir, isShots: isShotsSession(dir))
        let pa = a.def.processingArgs(env: agentEnvironment(), kind: kind)
        let cmd = a.def.command(bin: bin, prompt: processPrompt(dir, captures: captures, project: project, candidates: candidates), extra: pa.args)
        let log = dir.appendingPathComponent("agent.log")
        let withCandidates: String = candidates == nil ? "" : " · with the candidate projects"
        let model: String = " · model \(pa.model ?? "CLI default")" + (pa.effort.map { ", effort \($0)" } ?? "")
        let skips: String = skipped.isEmpty ? "" : " · skipped: " + skipped.map(\.1).joined(separator: "; ")
        appendLog(log, "── blurt \(nowStamp()) · processing (\(kind.rawValue)) with \(a.def.name) (\(bin))" + withCandidates + model
                  + skips + " · job \(job.id)\n")
        let started = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0
        updateMeta(dir) { m in
            var rec: [String: Any] = ["id": a.def.id, "name": a.def.name, "result": "running", "at": nowStamp(), "job": job.id]
            if !skipped.isEmpty { rec["fallback_from"] = skipped.map { ["id": $0.0.id, "why": $0.1] } }
            m["agent"] = rec
        }
        job.step("transcribe", .running)
        refreshStatus()
        var env = a.def.sandboxEnv.merging(["BLURT_JOB": job.id, "BLURT_RUN_ID": job.id, "BLURT_AGENT": a.def.id]) { _, n in n }
        if let p = project { env["BLURT_PROJECT"] = p }
        let group: ProcessGroup
        do {
            group = try shellGroup(cmd, cwd: cwd, log: log, append: true, env: env) { [weak self] status in
                self?.organisers[job.id] = nil
                self?.attemptEnded(dir, status: status, a: a, pa: pa, started: started, queue: queue, skipped: skipped, job: job,
                                   captures: captures, project: project, candidates: candidates)
            }
        } catch {
            // it never started: say so on the job instead of leaving it "running" and the recording blocked
            processing.removeAll { $0 == dir.path }
            appendLog(log, "── blurt \(nowStamp()) · couldn't start \(a.def.name): \(error)\n")
            job.finish(.failed, error: JobError(code: "unknown", message: "\(a.def.name): \(error)", reason: T("app.agent.couldnt_start", a.def.name)))
            Refile.runEnded(dir)
            refreshStatus()
            return
        }
        organisers[job.id] = group.pgid
        job.set("agent_pgid", Int(group.pgid))     // a later launch stops it if this one crashes…
        if let t = group.started { job.set("agent_pgid_start", NSNumber(value: t)) }  // …and it is still this group
    }

    /// What one organising run left: its items, or the reason it failed (and the next agent, for a reason another
    /// wouldn't share).
    private func attemptEnded(_ dir: URL, status: Int32, a: AgentStatus, pa: (args: [String], model: String?, effort: String?),
                              started: Int, queue: [AgentStatus], skipped: [(AgentDef, String)], job: JobWriter,
                              captures: [Int]?, project: String?, candidates: String?) {
        let log = dir.appendingPathComponent("agent.log")
        do {
            let tail = (try? Data(contentsOf: log)).map { d in String(decoding: d.dropFirst(min(started, d.count)), as: UTF8.self) } ?? ""
            let tokens = a.def.tokensUsed(in: tail)
            job.setUsage(tokens: tokens, agent: a.def.id, model: pa.model, effort: pa.effort)
            emit(["event": "process_usage", "job": job.id, "agent": a.def.id, "model": pa.model ?? NSNull(), "tokens": tokens ?? NSNull()])
            // items.py ingest turns items.json into Markdown (renaming it) and writes batch.json
            let fm = FileManager.default
            let hasItems = ["batch.json", "items.json", "items.ingested.json"].contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
            if hasItems {
                self.processing.removeAll { $0 == dir.path }
                updateMeta(dir) { m in m["agent"] = (m["agent"] as? [String: Any] ?? [:]).merging(["result": "ok", "done_at": nowStamp()]) { _, n in n } }
                appendLog(log, "── blurt \(nowStamp()) · \(a.def.name) done" + (status == 0 ? "" : " (exit \(status))") + "\n")
                for s in ["transcribe", "write", "frames"] { job.step(s, .done) }
                // a sandboxed run can't append to its job (ingest's event names the items): the batch does
                if let uids = (try? Data(contentsOf: dir.appendingPathComponent("batch.json")))
                    .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["items"] as? [String], !uids.isEmpty {
                    job.setItems(uids)
                }
                job.finish(.done)
                Scripts.indexUpdate([dir])
                // a recording re-filed while it ran ("Filed to X · Change"): its items go where the user said
                Refile.organized(dir)
                self.refreshStatus()
                return
            }
            let f = AgentHub.shared.classify(tail)
            let reason = f?.reasonText(a.def) ?? T("app.agent.unfinished", a.def.name, Int(status))
            appendLog(log, "── blurt \(nowStamp()) · failed: \(reason)\n")
            if f?.id == "auth" { AgentHub.shared.invalidate(a.def.id, as: .loggedOut) }
            let next = Array(queue.dropFirst())
            if ["auth", "quota", "model"].contains(f?.id ?? ""), !next.isEmpty {
                // switching agents mid-run is said like a switch before it (and kept on the job)
                let passed = skipped + [(a.def, "\(a.def.name) " + (f?.shortText ?? ""))]
                self.noteFallback(passed.map(\.1), using: next[0].def, job: job)
                self.attempt(dir, queue: next, skipped: passed, job: job, captures: captures, project: project, candidates: candidates)
                return
            }
            self.processing.removeAll { $0 == dir.path }
            updateMeta(dir) { m in
                m["agent"] = (m["agent"] as? [String: Any] ?? [:]).merging(
                    ["result": "failed", "class": f?.id ?? "unknown", "short": f?.shortText ?? T("job.state.failed"), "reason": reason,
                     "exit": Int(status), "done_at": nowStamp()]) { _, n in n }
            }
            let code = OrganizeSteps.agentLevel.contains(f?.id ?? "") ? f!.id : "unknown"
            let transcribed = FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path)
            for (s, st) in OrganizeSteps.onFailure(failureClass: f?.id, transcribed: transcribed) { job.step(s, st) }
            job.finish(.failed, error: JobError(code: code, message: reason, hintKey: nil, reason: reason))
            Refile.runEnded(dir)
            self.refreshStatus()
        }
    }

    // MARK: AI fill-in: items filed from the user's own notes, enriched in one run

    /// "AI fill-in" for some items (the ones a note became without an agent carry `enrich: pending`): one agent run
    /// for all of them, with the processing model — kind, steps, code refs, a clearer title. A process job (K4)
    /// without a session; its output goes to jobs/<id>.log.
    @discardableResult
    func enrich(_ uids: [String], project: String?) -> String? {
        guard !uids.isEmpty else { return nil }
        let job = JobWriter(type: .process, project: project, session: nil, title: T("job.title.enrich"))
        job.setItems(uids)
        job.step("prepare", .running)
        let hub = AgentHub.shared
        hub.reload()
        hub.check(hub.order(), recheck: true) { statuses in
            guard let a = statuses.first(where: { $0.state.usable }), let bin = a.bin else {
                job.finish(.failed, error: JobError(code: "auth", message: statuses.map { "\($0.def.name): \($0.why)" }.joined(separator: "; "),
                                                    reason: App.noAgentReason(statuses)))
                return
            }
            job.step("prepare", .done)
            job.step("write", .running)
            let pa = a.def.processingArgs(env: agentEnvironment(), kind: .cards)
            // a scratch cwd: never the project (the prompt names its code for reading)
            let cwd = BlurtPaths.home.appendingPathComponent("tmp/\(job.id)")
            try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            let items = "uv run \(BlurtPaths.scripts.path)/items.py"
            let prompt = "Use the blurt skill. These items were filed straight from the user's own notes, without an agent "
                + "(they carry `enrich: pending`): " + uids.joined(separator: ", ") + ".\nFor each one: `\(items) get <uid>`, "
                + "read it and look at its frames; then set the right kind (issue / idea / note / task), a clear title, and "
                + "what that kind's lens asks for (for an issue: steps, expected / actual, code_refs found in the project's code) with "
                + "`\(items) patch <uid> --set key=VALUE … --unset enrich`. Keep the user's words in quote; don't change status, "
                + "project or work. This is an unattended background run started by the Blurt app: don't ask questions and "
                + "don't open the review page. Finish with one sentence." + UnattendedRun.scriptsHint(BlurtPaths.scripts.path)
                + AgentHub.codeHint(project.flatMap { ProjectStore.shared.project(id: $0) })
            let log = JobFiles.log(job.id)
            appendLog(log, "── blurt \(nowStamp()) · AI fill-in with \(a.def.name) · model \(pa.model ?? "CLI default")\n")
            let cmd = a.def.command(bin: bin, prompt: prompt, extra: pa.args)
            let env = a.def.sandboxEnv.merging(["BLURT_JOB": job.id, "BLURT_RUN_ID": job.id, "BLURT_AGENT": a.def.id]) { _, n in n }
            emit(["event": "enrich", "job": job.id, "items": uids, "agent": a.def.id, "model": pa.model ?? NSNull()])
            let files = ((try? IndexReader(url: BlurtPaths.indexDB)).flatMap { try? $0.items(uids: uids) } ?? []).map { URL(fileURLWithPath: $0.path) }
            let started = try? shellGroup(cmd, cwd: cwd, log: log, append: true, env: env) { [weak self] status in
                self?.organisers[job.id] = nil
                try? FileManager.default.removeItem(at: cwd)
                Scripts.indexUpdate(files)  // the sandboxed run doesn't touch index.db
                let tokens = a.def.tokensUsed(in: (try? String(contentsOf: log, encoding: .utf8)) ?? "")
                job.setUsage(tokens: tokens, agent: a.def.id, model: pa.model, effort: pa.effort)
                emit(["event": "process_usage", "job": job.id, "agent": a.def.id, "model": pa.model ?? NSNull(), "tokens": tokens ?? NSNull()])
                job.step("write", status == 0 ? .done : .failed)
                for s in ["transcribe", "frames"] { job.step(s, .skipped) }
                job.finish(status == 0 ? .done : .failed,
                           error: status == 0 ? nil : JobError(code: AgentHub.shared.classify((try? String(contentsOf: log, encoding: .utf8)) ?? "")?.id ?? "unknown",
                                                               message: T("app.agent.unfinished", a.def.name, Int(status)), hintKey: nil))
            }
            if let g = started {
                self.organisers[job.id] = g.pgid
                job.set("agent_pgid", Int(g.pgid))
                if let t = g.started { job.set("agent_pgid_start", NSNumber(value: t)) }
            } else {
                job.finish(.failed, error: JobError(code: "unknown", message: "\(a.def.name) couldn't start", reason: T("app.agent.couldnt_start", a.def.name)))
            }
        }
        return job.id
    }
}
