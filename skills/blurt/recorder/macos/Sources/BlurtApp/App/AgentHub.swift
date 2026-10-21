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
    var fixText: String { fix[opts.lang] ?? fix["en"] ?? "" }
    var installText: String { install[opts.lang] ?? install["en"] ?? "" }

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

    var shortText: String { short[opts.lang] ?? short["en"] ?? id }
    func reasonText(_ a: AgentDef) -> String {
        (reason[opts.lang] ?? reason["en"] ?? id).replacingOccurrences(of: "{name}", with: a.name).replacingOccurrences(of: "{fix}", with: a.fixText)
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
        case .ready: return L("已登录", "logged in")
        case .configured: return L("已配置（无法预先验证）", "configured (can't verify in advance)")
        case .unknown: return L("登录状态未知，会直接试", "login unknown — will just try")
        case .loggedOut: return L("没登录", "not logged in") + (def.fixText.isEmpty ? "" : " — " + def.fixText)
        case .notInstalled: return L("没安装", "not installed") + (def.installText.isEmpty ? "" : " — " + def.installText)
        case .checking: return L("检查中…", "checking…")
        }
    }
    /// For "Claude Code 没登录，这次用 Codex 整理"
    var shortWhy: String {
        switch state {
        case .loggedOut: return L(" 没登录", " isn't logged in")
        case .notInstalled: return L(" 没安装", " isn't installed")
        default: return L(" 用不了", " can't be used")
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
    return a["short"] as? String ?? L("失败", "failed")
}

extension App {
    /// Hand the recording to a coding agent in the workspace, headless. `only`: that agent, no fallback (the user picked
    /// it in the menu). The agent writes the outputs next to the recording; the app opens the review page.
    func process(_ dir: URL, only: String? = nil) {
        guard !processing.contains(dir.path) else { return }
        processing.append(dir.path)
        refreshStatus()
        let hub = AgentHub.shared
        hub.reload()
        let order = only.flatMap { hub.def($0) }.map { [$0] } ?? hub.order()
        let log = dir.appendingPathComponent("agent.log")
        hub.check(order) { [weak self] statuses in
            guard let self = self else { return }
            let skipped = Array(statuses.prefix { !$0.state.usable })
            let queue = statuses.filter { $0.state.usable }
            guard !queue.isEmpty else { return self.noAgent(dir, statuses) }
            if !skipped.isEmpty {
                appendLog(log, "── blurt \(nowStamp()) · " + skipped.map { "\($0.def.name)：\($0.why)" }.joined(separator: " · ") + "\n")
            }
            self.attempt(dir, queue: queue, skipped: skipped.map { ($0.def, $0.def.name + $0.shortWhy) })
        }
    }

    func noAgent(_ dir: URL, _ statuses: [AgentStatus]) {
        processing.removeAll { $0 == dir.path }
        refreshStatus()
        let lines = statuses.map { "\($0.def.name)：\($0.why)" }
        appendLog(dir.appendingPathComponent("agent.log"), "── blurt \(nowStamp()) · " + L("没有能用的 agent，没整理：", "no usable agent, not processed:") + "\n"
                  + lines.map { "   " + $0 }.joined(separator: "\n") + "\n")
        updateMeta(dir) { m in
            m["agent"] = ["result": "none", "short": L("没有能用的 agent", "no usable agent"), "at": nowStamp(),
                          "agents": statuses.map { ["id": $0.def.id, "state": $0.state.rawValue, "why": $0.why] }]
        }
        perch.hatched(id: dir.path, ok: false)
        // installed-but-unusable first, then everything not installed on one line
        let notInstalled = statuses.filter { $0.state == .notInstalled }
        var shown = statuses.filter { $0.state != .notInstalled }.map { "\($0.def.name)：\($0.why)" }
        if notInstalled.count > 1 && !shown.isEmpty {
            shown.append(notInstalled.map(\.def.name).joined(separator: " / ") + L("：没安装", ": not installed"))
        } else {
            shown += notInstalled.map { "\($0.def.name)：\($0.why)" }
        }
        toast(L("没法后台整理，没有能用的 agent：", "Can't process this — no usable agent:") + "\n" + shown.joined(separator: "\n")
              + "\n" + L("弄好后在菜单「最近的录制」里重新整理", "Fix one, then Recent recordings → Process"), seconds: 16)
    }

    /// Run queue[0]; on a failure another agent wouldn't share (login, quota, model), move on to the next.
    func attempt(_ dir: URL, queue: [AgentStatus], skipped: [(AgentDef, String)]) {
        guard let a = queue.first, let bin = a.bin else { return noAgent(dir, queue) }
        let ws = currentWorkspace()
        // name the skill's path: the agent's own skill list may lack blurt (installed for one CLI only) or hold another
        // version than the one this app was built from
        let skillHint = (readConfig()["skill_dir"] as? String).map { "\n" + L("blurt skill：\($0)/SKILL.md", "The blurt skill: \($0)/SKILL.md") } ?? ""
        let prompt = (shotsPrompt(dir) ?? L("用 blurt skill 处理这段录屏：\(dir.path)\n这是口喷鸡 App 发起的无人值守后台运行：不要提问，也不要启动审核页（items.json 一出现 App 就会打开它）；写好 items.json 后用两三句话总结。",
                       "Use the blurt skill to process this recording: \(dir.path)\nThis is an unattended background run started by the Blurt app: don't ask questions and don't start the review page (the app opens it as soon as items.json appears); write items.json, then summarise in 2–3 sentences.")) + skillHint
        let cmd = a.def.command(bin: bin, prompt: prompt)
        let log = dir.appendingPathComponent("agent.log")
        let fromWhy = skipped.map(\.1)
        appendLog(log, "── blurt \(nowStamp()) · " + L("用 \(a.def.name) 整理", "processing with \(a.def.name)") + " (\(bin))"
                  + (fromWhy.isEmpty ? "" : " · " + L("跳过：", "skipped: ") + fromWhy.joined(separator: "; ")) + "\n")
        let started = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0
        updateMeta(dir) { m in
            var rec: [String: Any] = ["id": a.def.id, "name": a.def.name, "result": "running", "at": nowStamp()]
            if !skipped.isEmpty { rec["fallback_from"] = skipped.map { ["id": $0.0.id, "why": $0.1] } }
            m["agent"] = rec
        }
        if skipped.isEmpty {
            toast(L("\(a.def.name) 正在后台整理…", "\(a.def.name) is processing it in the background…"))
        } else {
            toast(L("\(skipped[0].1)，这次用 \(a.def.name) 整理", "\(skipped[0].1) — processing with \(a.def.name) this time"), seconds: 7)
        }
        perch.hatch(id: dir.path, kinds: draftKinds(in: dir))
        // text-first runs: items.json appears long before the agent exits → open the review page right then
        var reviewOpen = false
        let watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self = self, FileManager.default.fileExists(atPath: dir.appendingPathComponent("items.json").path) else { return }
            t.invalidate()
            reviewOpen = self.openReview(dir)
            perch.hatched(id: dir.path, ok: true)
            if reviewOpen { self.toast(L("条目已就绪，审核页已打开（截图还在补）", "Items are ready — the review page is open (frames still coming)")) }
        }
        refreshStatus()
        shell(cmd, cwd: ws, log: log, append: true) { [weak self] status in
            guard let self = self else { return }
            watch.invalidate()
            let hasItems = FileManager.default.fileExists(atPath: dir.appendingPathComponent("items.json").path)
            let ok = status == 0 && hasItems
            if ok || (hasItems && reviewOpen) {
                self.processing.removeAll { $0 == dir.path }
                perch.hatched(id: dir.path, ok: true)
                updateMeta(dir) { m in m["agent"] = (m["agent"] as? [String: Any] ?? [:]).merging(["result": "ok", "done_at": nowStamp()]) { _, n in n } }
                appendLog(log, "── blurt \(nowStamp()) · \(a.def.name) " + L("完成", "done") + (ok ? "" : " (exit \(status))") + "\n")
                if reviewOpen { self.toast(L("整理完了，审核页里的截图都补齐了", "Done — every frame is on the review page")) }
                else if self.openReview(dir) { self.toast(L("整理好了，审核页已打开", "Done — the review page is open")) }
                else { self.toast(L("整理好了（items.json 已生成）", "Done — items.json is ready")) }
                self.refreshStatus()
                return
            }
            let tail = (try? Data(contentsOf: log)).map { d in String(decoding: d.dropFirst(min(started, d.count)), as: UTF8.self) } ?? ""
            let f = AgentHub.shared.classify(tail)
            let reason = f?.reasonText(a.def) ?? L("\(a.def.name) 没整理完（退出码 \(status)）", "\(a.def.name) didn't finish (exit \(status))")
            appendLog(log, "── blurt \(nowStamp()) · " + L("失败", "failed") + "：\(reason)\n")
            if f?.id == "auth" { AgentHub.shared.invalidate(a.def.id, as: .loggedOut) }
            let next = Array(queue.dropFirst())
            if !hasItems, ["auth", "quota", "model"].contains(f?.id ?? ""), !next.isEmpty {
                self.attempt(dir, queue: next, skipped: skipped + [(a.def, "\(a.def.name) " + (f?.shortText ?? ""))])
                return
            }
            self.processing.removeAll { $0 == dir.path }
            perch.hatched(id: dir.path, ok: false)
            updateMeta(dir) { m in
                m["agent"] = (m["agent"] as? [String: Any] ?? [:]).merging(
                    ["result": "failed", "class": f?.id ?? "unknown", "short": f?.shortText ?? L("失败", "failed"), "reason": reason,
                     "exit": Int(status), "done_at": nowStamp()]) { _, n in n }
            }
            self.toast(L("后台整理失败：", "Processing failed: ") + reason + "\n" + L("详见录屏文件夹里的 agent.log", "Details: agent.log in the recording's folder"), seconds: 12)
            self.refreshStatus()
        }
    }

    // MARK: menu: the agent order with each one's status

    func addAgentMenu(_ menu: NSMenu) {
        let hub = AgentHub.shared
        hub.reload()
        let order = hub.order()
        let first = order.first(where: { hub.cached($0.id)?.state.usable ?? true })
        let item = NSMenuItem(title: L("整理用的 agent", "Agent") + (first.map { "：\($0.name)" } ?? ""), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let head = NSMenuItem(title: L("按顺序试，第一个能用的来整理", "Tried in this order; the first usable one runs"), action: nil, keyEquivalent: "")
        head.isEnabled = false
        sub.addItem(head)
        var rows: [String: NSMenuItem] = [:]
        for (i, d) in order.enumerated() {
            let it = NSMenuItem(title: "", action: #selector(mPreferAgent(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = d.id
            it.toolTip = i == 0 ? nil : L("点一下设为首选", "Click to try it first")
            setAgentRow(it, index: i, status: hub.cached(d.id))
            rows[d.id] = it
            sub.addItem(it)
        }
        sub.addItem(.separator())
        let recheck = NSMenuItem(title: L("重新检查登录状态", "Check again"), action: #selector(mRecheckAgents), keyEquivalent: "")
        recheck.target = self
        sub.addItem(recheck)
        item.submenu = sub
        menu.addItem(item)
        // fill in / refresh the statuses while the menu is open
        hub.check(order) { statuses in
            for (i, s) in statuses.enumerated() { if let it = rows[s.def.id] { self.setAgentRow(it, index: i, status: s) } }
            let f = statuses.first { $0.state.usable }
            item.title = L("整理用的 agent", "Agent") + (f.map { "：\($0.def.name)" } ?? L("：没有能用的", ": none usable"))
        }
    }

    func setAgentRow(_ it: NSMenuItem, index: Int, status: AgentStatus?) {
        guard let d = AgentHub.shared.def(it.representedObject as? String ?? "") else { return }
        let why = status?.why ?? L("检查中…", "checking…")
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
