// Which coding agent processes a recording, headless — with automatic fallback and errors that say why.
//
// The registry is agents.json (skills/blurt/scripts/agents.json, bundled into Blurt.app/Contents/Resources; agents.py
// implements the same rules for the scripts and the tests). Order: config record.agents (default: the registry's order
// — Claude Code, Codex, Kimi Code, OpenCode, Gemini CLI); record.agent_defs adds or overrides an agent.
// The first one that is installed and not known to be logged out runs. If it fails before items.json exists for a
// reason another agent wouldn't share (login, quota, model), the next one gets the recording. Every attempt and every
// skipped agent is written to <session>/agent.log and meta.json → "agent"; the toasts say the same in one line.
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
    }
    /// false = an app / interactive-only entry (WP2's zcode): never in the background chain or its menus.
    let headless: Bool
    var fixText: String { Loc.pick(fix) ?? "" }
    var installText: String { Loc.pick(install) ?? "" }

    /// The headless command line for the shell (cwd = the workspace).
    func command(bin: String, prompt: String) -> String {
        ([bin] + run.map { $0 == "{prompt}" ? prompt : $0.replacingOccurrences(of: "{prompt}", with: prompt) }).map(shq).joined(separator: " ")
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
         "run": ["-p", "{prompt}", "--permission-mode", "acceptEdits", "--allowedTools", "Bash", "Read", "Write", "Edit", "Glob", "Grep"],
         "fix": ["zh": "在终端运行 claude，然后输入 /login", "en": "run `claude` in a terminal and /login"]],
        ["id": "codex", "name": "Codex", "bins": ["codex"],
         "status": ["args": ["login", "status"], "logged_out": ["not logged in"], "ok_if": ["logged in"]],
         "run": ["exec", "--skip-git-repo-check", "--sandbox", "danger-full-access", "{prompt}"],
         "fix": ["zh": "在终端运行 codex login", "en": "run `codex login` in a terminal"]],
    ]

    func def(_ id: String) -> AgentDef? { defs.first { $0.id == id } }

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
    func check(_ list: [AgentDef], force: Bool = false, then: @escaping ([AgentStatus]) -> Void) {
        let group = DispatchGroup()
        for d in list {
            if !force, let c = cache[d.id], Date().timeIntervalSince(c.at) < (c.state == .ready ? 600 : 60) { continue }
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
    /// the items there (nil = the session's own project, or the AI routes each item). `only`: that agent, no fallback.
    /// Nothing opens when it finishes — JobNotifier says so quietly (K4 notification rules).
    func process(_ dir: URL, only: String? = nil, captures: [Int]? = nil, project: String? = nil) {
        guard !processing.contains(dir.path) else { return }
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
            return
        }
        let hub = AgentHub.shared
        hub.reload()
        let order = only.flatMap { hub.def($0) }.map { [$0] } ?? hub.order()
        let log = dir.appendingPathComponent("agent.log")
        hub.check(order) { [weak self] statuses in
            guard let self = self else { return }
            let skipped = Array(statuses.prefix { !$0.state.usable })
            let queue = statuses.filter { $0.state.usable }
            guard !queue.isEmpty else { return self.noAgent(dir, statuses, job: job) }
            if !skipped.isEmpty {
                appendLog(log, "── blurt \(nowStamp()) · " + skipped.map { "\($0.def.name): \($0.why)" }.joined(separator: " · ") + "\n")
                self.noteFallback(skipped, using: queue[0])
            }
            job.step("prepare", .done)
            self.attempt(dir, queue: queue, skipped: skipped.map { ($0.def, $0.def.name + $0.shortWhy) }, job: job, captures: captures,
                         project: project)
        }
    }

    /// The first agent in the user's order can't run (not logged in, not installed): say once, on the island, which
    /// one organises instead — otherwise the switch is only in agent.log. Again only when the reason changes.
    func noteFallback(_ skipped: [AgentStatus], using: AgentStatus) {
        let key = skipped.map { "\($0.def.id):\($0.state.rawValue)" }.joined(separator: ",") + ">" + using.def.id
        guard App.fallbackNoted != key else { return }
        App.fallbackNoted = key
        let why = skipped.map { $0.def.name + $0.shortWhy }.joined(separator: T("app.agent.list_sep"))
        AppEnvironment.island?.toast(T("app.agent.fallback_notice", why, using.def.name), actionTitle: nil, action: nil)
    }
    static var fallbackNoted: String?

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
        job.finish(.failed, error: JobError(code: "auth", message: lines.joined(separator: "; "), hintKey: "main.job.hint.no_agent"))
    }

    /// The agent's instructions for an unattended run (English: agents read it, the user never does).
    func processPrompt(_ dir: URL, captures: [Int]?) -> String {
        let what = isShotsSession(dir)
            ? "Use the blurt skill to process this batch of captures: \(dir.path)\nIt is a shots session (no video): each shot "
              + "anchors one item and is that item's primary frame; voice notes are transcribed first; .marked.png files carry the user's ink."
            : "Use the blurt skill to process this recording: \(dir.path)"
        let only = captures.map { "\nOnly these captures (shots.jsonl n): " + $0.map(String.init).joined(separator: ", ") + "." } ?? ""
        let skill = (readConfig()["skill_dir"] as? String).map { "\nThe blurt skill: \($0)/SKILL.md" } ?? ""
        return what + only + "\nThis is an unattended background run started by the Blurt app: don't ask questions and don't start the "
            + "review page. Write items.json and run items.py ingest as SKILL.md says, then summarise in 2–3 sentences." + skill
    }

    /// Run queue[0]; on a failure another agent wouldn't share (login, quota, model), move on to the next.
    func attempt(_ dir: URL, queue: [AgentStatus], skipped: [(AgentDef, String)], job: JobWriter, captures: [Int]?, project: String?) {
        guard let a = queue.first, let bin = a.bin else { return noAgent(dir, queue, job: job) }
        let cwd = ProjectStore.shared.project(containing: dir).flatMap { $0.isInbox ? nil : $0.path } ?? defaultWorkspace
        let cmd = a.def.command(bin: bin, prompt: processPrompt(dir, captures: captures))
        let log = dir.appendingPathComponent("agent.log")
        appendLog(log, "── blurt \(nowStamp()) · processing with \(a.def.name) (\(bin))"
                  + (skipped.isEmpty ? "" : " · skipped: " + skipped.map(\.1).joined(separator: "; ")) + " · job \(job.id)\n")
        let started = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0
        updateMeta(dir) { m in
            var rec: [String: Any] = ["id": a.def.id, "name": a.def.name, "result": "running", "at": nowStamp(), "job": job.id]
            if !skipped.isEmpty { rec["fallback_from"] = skipped.map { ["id": $0.0.id, "why": $0.1] } }
            m["agent"] = rec
        }
        job.step("transcribe", .running)
        refreshStatus()
        var env = ["BLURT_JOB": job.id, "BLURT_RUN_ID": job.id, "BLURT_AGENT": a.def.id]
        if let p = project { env["BLURT_PROJECT"] = p }
        shell(cmd, cwd: cwd, log: log, append: true, env: env) { [weak self] status in
            guard let self = self else { return }
            // items.py ingest turns items.json into Markdown (renaming it) and writes batch.json
            let fm = FileManager.default
            let hasItems = ["batch.json", "items.json", "items.ingested.json"].contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
            if hasItems {
                self.processing.removeAll { $0 == dir.path }
                updateMeta(dir) { m in m["agent"] = (m["agent"] as? [String: Any] ?? [:]).merging(["result": "ok", "done_at": nowStamp()]) { _, n in n } }
                appendLog(log, "── blurt \(nowStamp()) · \(a.def.name) done" + (status == 0 ? "" : " (exit \(status))") + "\n")
                for s in ["transcribe", "write", "frames"] { job.step(s, .done) }
                // a filed capture needs no routing; otherwise ingest has handed the inbox items to their own route job
                job.step("route", project != nil ? .skipped : .done)
                job.finish(.done)
                Scripts.indexUpdate([dir])
                self.refreshStatus()
                return
            }
            let tail = (try? Data(contentsOf: log)).map { d in String(decoding: d.dropFirst(min(started, d.count)), as: UTF8.self) } ?? ""
            let f = AgentHub.shared.classify(tail)
            let reason = f?.reasonText(a.def) ?? T("app.agent.unfinished", a.def.name, Int(status))
            appendLog(log, "── blurt \(nowStamp()) · failed: \(reason)\n")
            if f?.id == "auth" { AgentHub.shared.invalidate(a.def.id, as: .loggedOut) }
            let next = Array(queue.dropFirst())
            if ["auth", "quota", "model"].contains(f?.id ?? ""), !next.isEmpty {
                self.attempt(dir, queue: next, skipped: skipped + [(a.def, "\(a.def.name) " + (f?.shortText ?? ""))], job: job,
                             captures: captures, project: project)
                return
            }
            self.processing.removeAll { $0 == dir.path }
            updateMeta(dir) { m in
                m["agent"] = (m["agent"] as? [String: Any] ?? [:]).merging(
                    ["result": "failed", "class": f?.id ?? "unknown", "short": f?.shortText ?? T("job.state.failed"), "reason": reason,
                     "exit": Int(status), "done_at": nowStamp()]) { _, n in n }
            }
            let code = ["auth", "quota", "network", "model"].contains(f?.id ?? "") ? f!.id : "unknown"
            job.finish(.failed, error: JobError(code: code, message: reason, hintKey: nil))
            self.refreshStatus()
        }
    }

    // MARK: menu: the agent order with each one's status

    func addAgentMenu(_ menu: NSMenu) {
        let hub = AgentHub.shared
        hub.reload()
        let order = hub.order()
        let first = order.first(where: { hub.cached($0.id)?.state.usable ?? true })
        let item = NSMenuItem(title: first.map { T("app.agent.agent_named", $0.name) } ?? T("app.agent.agent"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let head = NSMenuItem(title: T("app.agent.tried_this_order_first"), action: nil, keyEquivalent: "")
        head.isEnabled = false
        sub.addItem(head)
        var rows: [String: NSMenuItem] = [:]
        for (i, d) in order.enumerated() {
            let it = NSMenuItem(title: "", action: #selector(mPreferAgent(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = d.id
            it.toolTip = i == 0 ? nil : T("app.agent.click_try_first")
            setAgentRow(it, index: i, status: hub.cached(d.id))
            rows[d.id] = it
            sub.addItem(it)
        }
        sub.addItem(.separator())
        let recheck = NSMenuItem(title: T("app.agent.check_again"), action: #selector(mRecheckAgents), keyEquivalent: "")
        recheck.target = self
        sub.addItem(recheck)
        item.submenu = sub
        menu.addItem(item)
        // fill in / refresh the statuses while the menu is open
        hub.check(order) { statuses in
            for (i, s) in statuses.enumerated() { if let it = rows[s.def.id] { self.setAgentRow(it, index: i, status: s) } }
            let f = statuses.first { $0.state.usable }
            item.title = f.map { T("app.agent.agent_named", $0.def.name) } ?? T("app.agent.agent") + T("app.agent.none_usable")
        }
    }

    func setAgentRow(_ it: NSMenuItem, index: Int, status: AgentStatus?) {
        guard let d = AgentHub.shared.def(it.representedObject as? String ?? "") else { return }
        let why = status?.why ?? T("app.agent.checking")
        let mf = NSFont.menuFont(ofSize: 0)
        let s = NSMutableAttributedString(string: "\(index + 1). ", attributes: [.font: mf])
        if let ic = status?.markIcon {
            s.append(ic.attributed(font: mf, color: ic == .check ? .systemGreen : .systemRed, preferSymbol: true))
        } else {
            s.append(NSAttributedString(string: "…", attributes: [.font: mf]))
        }
        s.append(NSAttributedString(string: "  \(d.name)", attributes: [.font: mf]))
        s.append(NSAttributedString(string: "   " + why, attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        it.attributedTitle = s
    }

    @objc func mPreferAgent(_ it: NSMenuItem) { if let id = it.representedObject as? String { AgentHub.shared.prefer(id) } }
    @objc func mRecheckAgents() { let hub = AgentHub.shared; hub.check(hub.order(), force: true) { _ in } }
}
