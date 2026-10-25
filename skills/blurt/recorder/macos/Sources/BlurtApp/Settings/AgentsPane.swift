// Settings → Agents (a page of SettingsKit lines; its sections are in SettingsCatalog): which coding agents Blurt uses — organizing recordings and organizing cards (each with its own model), AI fill-in —
// (record.agents, in order — drag to reorder, untick to leave one out) and which can run in Blurt's sessions
// (sessions.py doctor), each one's state (agents.py detect). The rows are there at once (agents.json, "Checking…"),
// then a quick look, then the sign-in check — "Runs first" only once the sign-in check is in, so it never jumps from one
// agent to another. Only what stops Blurt is red; amber exactly where a row shows the command that fixes it (a ticked
// agent tried before the one that runs); an agent that isn't installed can't be ticked. Connect installs the blurt skill + MCP server into
// an agent (agents.py install: a --dry-run preview first, applied only after the user confirms) and is offered only
// while they are missing (a dry run per installed agent says so). The current project's default agent for sessions
// (projects.json default_agent); a test run. Agents without a command line (ZCode) are listed apart. Each installed
// agent says whether the blurt skill + MCP are in it: a "Skill + MCP" badge, or Connect… whose tooltip says they are
// not in it yet (no grey label repeated down the list).
// "Ask your agent" (agents.ask) ends the page: three requests in plain words, each copyable — sending items anywhere
// (Slack, Feishu, Linear…) is the agent's job with its own tools, so there are no connector settings here; this is
// where the old Export pane's links land (SettingsCatalog.moved).
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BlurtCore

@MainActor
final class AgentsModel: ObservableObject {
    static let shared = AgentsModel()

    @Published var rows: [CoreAgent] = []
    @Published var enabled = Set<String>()
    @Published var pick: String?
    /// a full check (with the sign-in probe) has come back: `pick` is final (the quick look can't tell who is signed in)
    @Published var signInChecked = false
    @Published var loading = false
    @Published var error: String?
    @Published var plan: (agent: CoreAgent, plan: InstallPlan, applied: Bool)?
    @Published var installing: String?
    @Published var testing: String?
    @Published var tests: [String: (ok: Bool, text: String)] = [:]
    @Published var doctor: SessionsDoctor?
    @Published var projectAgent: String = ""
    /// Each installed agent's models (agents.py models), for "Model for organizing".
    @Published var models: [String: AgentModels] = [:]

    var headless: [CoreAgent] { rows.filter(\.headless) }
    var manual: [CoreAgent] { rows.filter { !$0.headless } }
    var project: Project? { ProjectStore.shared.current }
    func sessions(_ a: CoreAgent) -> Bool { doctor?.agents[a.id] ?? false }

    /// Their skill + MCP are in place (agents.py install --dry-run would change nothing): no Connect button. nil = not
    /// checked yet.
    @Published var connected: [String: Bool] = [:]

    /// The pane opens at once: before the first check, the registry's agents in the saved order, each "Checking…";
    /// then the quick look (no sign-in probe), then the full one. Later opens show what the last check found.
    func open() async {
        if rows.isEmpty {
            rows = Self.registry()
            enabled = Set(Agents.shared.order ?? rows.filter(\.headless).map(\.id))
            await load(login: false)
        }
        await load()
        await checkConnected()
    }

    /// agents.json (the skill's, else the copy in the app) as placeholder rows.
    static func registry() -> [CoreAgent] {
        var urls = [BlurtPaths.scripts.appendingPathComponent("agents.json")]
        if let u = Bundle.main.url(forResource: "agents", withExtension: "json") { urls.append(u) }
        for u in urls {
            guard let d = try? Data(contentsOf: u), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let list = o["agents"] as? [[String: Any]] else { continue }
            let rows = list.compactMap { a -> CoreAgent? in
                guard let id = a["id"] as? String else { return nil }
                var r = CoreAgent(id: id, name: a["name"] as? String ?? id, installed: false, state: "checking")
                r.headless = a["headless"] as? Bool != false
                return r
            }
            let order = Agents.shared.order ?? []
            return rows.sorted { (order.firstIndex(of: $0.id) ?? 1000) < (order.firstIndex(of: $1.id) ?? 1000) }
        }
        return []
    }

    /// For each installed agent: would installing the skill + MCP change anything? (a dry run, one at a time)
    func checkConnected() async {
        for a in rows where a.installed && connected[a.id] == nil {
            if let p = try? await Agents.shared.install(a.id, dryRun: true) {
                connected[a.id] = !p.changes.contains(where: \.changesSomething)
            }
        }
    }

    func load(login: Bool = true) async {
        loading = true
        defer { loading = false }
        async let doc = try? AgentSessions.shared.doctor()
        do {
            let d = try await Agents.shared.detectAll(login: login)
            var fresh = d.agents
            if !login {
                // a quick re-read (after a reorder or a tick) can't tell who is logged in: keep what the last full
                // check found, or every row turns into "unknown"
                let known = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for i in fresh.indices {
                    // still being checked: the quick look can't tell who is signed in, so it stays "Checking…"
                    if known[fresh[i].id]?.state == "checking", fresh[i].installed, fresh[i].state == "unknown" { fresh[i].state = "checking"; continue }
                    guard let old = known[fresh[i].id], old.installed == fresh[i].installed, old.state != "unknown" else { continue }
                    fresh[i].state = old.state
                    fresh[i].why = old.why
                    fresh[i].fix = old.fix
                    fresh[i].login = old.login
                }
            }
            rows = fresh
            // the first usable one in the shown order (the same rule as agents.py detect)
            let order = d.order
            pick = ["ready", "configured", "unknown"].lazy.compactMap { want in
                order.first { id in fresh.contains { $0.id == id && $0.headless && $0.state == want } }
            }.first ?? d.pick
            enabled = Set(Agents.shared.order ?? d.agents.filter(\.headless).map(\.id))
            if enabled.isEmpty { enabled = Set(d.order) }
            if login { signInChecked = true }
            error = nil
        } catch {
            self.error = peopleText(error, context: "agents detect")
            rows = rows.map { var r = $0; if r.state == "checking" { r.state = "unknown" }; return r }    // no spinner for good
        }
        doctor = await doc
        projectAgent = project?.defaultAgent ?? ""
        for a in rows where a.headless && a.installed {
            if let m = try? await Agents.shared.models(a.id), !m.models.isEmpty { models[a.id] = m }
        }
    }

    /// "cheapest" | "default" (the CLI's own setting) | a model id — per kind of run: a recording (shipped: the CLI's
    /// own model) or a batch of cards and AI fill-in (shipped: the cheapest). ProcessingSpec has the rules.
    func processingModel(_ id: String, _ kind: ProcessingKind) -> String {
        Agents.shared.processingSetting(id, kind: kind).model ?? shipped(id, kind).model
    }
    func processingEffort(_ id: String, _ kind: ProcessingKind) -> String {
        Agents.shared.processingSetting(id, kind: kind).effort ?? shipped(id, kind).effort
    }
    /// agents.json's default for this agent and kind (the models answer carries it), else what Blurt ships with.
    func shipped(_ id: String, _ kind: ProcessingKind) -> (model: String, effort: String) {
        ProcessingSpec.wanted(base: AgentHub.shared.def(id)?.processingDefault, over: nil, kind: kind)
    }

    func setProcessing(_ id: String, _ kind: ProcessingKind, model: String? = nil, effort: String? = nil) {
        let cur = Agents.shared.processingSetting(id, kind: kind)
        let m = model ?? cur.model, e = effort ?? cur.effort
        let base = shipped(id, kind)
        // the shipped defaults are stored as nothing, so a better default later reaches everyone
        Agents.shared.setProcessing(id, kind: kind, model: m == base.model ? nil : m, effort: e == base.effort ? nil : e)
        emit(["event": "processing_model", "agent": id, "kind": kind.rawValue, "model": m ?? base.model, "effort": e ?? base.effort])
        objectWillChange.send()
    }

    /// record.agents = the ticked headless agents in the shown order.
    func save() {
        let ids = headless.map(\.id).filter { enabled.contains($0) }
        Agents.shared.order = ids.isEmpty ? nil : ids
        Task { await load(login: false) }
    }

    func move(from: IndexSet, to: Int) {
        var h = headless
        h.move(fromOffsets: from, toOffset: to)
        rows = h + manual
        save()
    }
    func moveUp(_ id: String) {
        guard let i = headless.firstIndex(where: { $0.id == id }), i > 0 else { return }
        move(from: IndexSet(integer: i), to: i - 1)
    }
    func toggle(_ id: String, _ on: Bool) {
        if on { enabled.insert(id) } else { enabled.remove(id) }
        save()
    }

    func setProjectAgent(_ id: String) {
        guard let p = project else { return }
        projectAgent = id
        Task {
            do { try await ProjectStore.shared.update(p.id, ["default_agent": id.isEmpty ? NSNull() : id]) }
            catch { self.error = peopleText(error, context: "project default agent") }
        }
    }

    /// Step 1: the preview. Nothing is written.
    func preview(_ a: CoreAgent) async {
        installing = a.id
        defer { installing = nil }
        do {
            let p = try await Agents.shared.install(a.id, dryRun: true)
            plan = (a, p, false)
            emit(["event": "install_preview", "agent": a.id, "changes": p.changes.map { InstallSheet.summary($0, agent: a.id) }])
        } catch { self.error = peopleText(error, context: "install preview") }
    }

    /// Step 2, after the user said yes.
    func apply() async {
        guard let cur = plan else { return }
        installing = cur.agent.id
        defer { installing = nil }
        do {
            let p = try await Agents.shared.install(cur.agent.id, dryRun: false)
            plan = (cur.agent, p, true)
            connected[cur.agent.id] = p.applied ? true : nil
            emit(["event": "install_applied", "agent": cur.agent.id, "applied": p.applied])
        } catch { self.error = peopleText(error, context: "install") }
    }

    /// One tiny headless prompt through the agent's real command line: proves it runs and is logged in (costs a
    /// few tokens).
    func test(_ a: CoreAgent) async {
        testing = a.id
        defer { testing = nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-agent-test")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        do {
            let c = try await Agents.shared.command(a.id, mode: "headless", prompt: "Reply with exactly the word: ok", repo: tmp, events: false)
            guard let argv = c.argv, let exe = argv.first else { tests[a.id] = (false, TL("agents.test.no_command")); return }
            let env = SkillCLI.shared.environment().merging(c.env) { _, n in n }
            let t0 = Date()
            let r = await Task.detached { ShellEnv.runCapture(exe, Array(argv.dropFirst()), env: env, timeout: 120) }.value
            let out = String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let secs = Date().timeIntervalSince(t0)
            if r.status == 0, out.lowercased().contains("ok") {
                let f = NumberFormatter()
                f.locale = Loc.locale
                f.maximumFractionDigits = 1
                f.minimumFractionDigits = 1
                tests[a.id] = (true, TL("agents.test.ok", f.string(from: secs as NSNumber) ?? "\(secs)"))
            } else {
                // its reason in words (login, quota, network… with the fix), never an exit code or raw output (logged)
                NSLog("blurt agent test %@: status %@: %@", a.id, r.status.map { "\($0)" } ?? "timeout", String(out.suffix(600)))
                let def = AgentHub.shared.def(a.id)
                let why = r.status == nil ? TL("agents.test.timeout")
                    : def.flatMap { d in AgentHub.shared.classify(out).map { $0.reasonText(d) } } ?? TL("agents.test.failed", a.name)
                tests[a.id] = (false, why)
            }
        } catch { tests[a.id] = (false, peopleText(error, context: "agent test")) }
    }
}

struct AgentsPane: View {
    @ObservedObject var m = AgentsModel.shared
    /// the agent being dragged to a new place in the order, and the row it is over (where the insertion line shows)
    @State var dragging: String?
    @State var dropTarget: String?

    /// Dragged down the list, the agent lands after the row it's over; dragged up, before it.
    func insertsBelow(_ target: String) -> Bool {
        guard let d = dragging, let from = m.headless.firstIndex(where: { $0.id == d }),
              let to = m.headless.firstIndex(where: { $0.id == target }) else { return false }
        return from < to
    }

    var body: some View {
        SettingsPage(.agents) {
            SettingsGroup("agents.list", footer: TL("agents.footer"), content: {
                ForEach(m.headless) { a in
                    agentRow(a, ordered: true)
                        .overlay(alignment: insertsBelow(a.id) ? .bottom : .top) {
                            if dropTarget == a.id, let d = dragging, d != a.id {
                                Capsule().fill(Color.brandInk).frame(height: 2).offset(y: insertsBelow(a.id) ? 1 : -1)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onDrag { dragging = a.id; return NSItemProvider(object: a.id as NSString) }
                        .onDrop(of: [.text], delegate: AgentDrop(target: a.id, m: m, dragging: $dragging, over: $dropTarget))
                }
                if let e = m.error { Text(e).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandErr).padding(.top, 6) }
            }, accessory: {
                if m.loading { ProgressView().controlSize(.mini) }
                Button { Task { m.connected = [:]; await m.load(); await m.checkConnected() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help(TL("agents.check_again")).accessibilityLabel(TL("agents.check_again"))
            })

            sessionsSection

            if !m.manual.isEmpty {
                SettingsGroup("agents.manual", footer: TL("agents.manual.footer")) {
                    ForEach(m.manual) { a in agentRow(a, ordered: false) }
                }
            }

            askSection
        }
        .task { await m.open() }
        .sheet(isPresented: Binding(get: { m.plan != nil }, set: { if !$0 { m.plan = nil } })) {
            if let p = m.plan { InstallSheet(m: m, agent: p.agent, plan: p.plan, applied: p.applied) }
        }
    }

    /// "Ask your agent": three things people ask for, in their own words — sending items somewhere is the agent's
    /// job, with the tools it already has (Blurt has no connectors to set up). Each can be copied.
    @ViewBuilder
    var askSection: some View {
        SettingsGroup("agents.ask", footer: TL("agents.ask.footer")) {
            ForEach(Self.askExamples, id: \.self) { key in
                SettingsLine {
                    HStack(spacing: 10) {
                        Text(Self.quoted(TL(key))).font(.system(size: SettingsMetrics.titleSize)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(TL(key), forType: .string)
                            emit(["event": "agents_ask_copied", "example": key])
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help(TL("agents.ask.copy")).accessibilityLabel(TL("agents.ask.copy"))
                    }
                }
            }
        }
    }

    static let askExamples = ["agents.ask.1", "agents.ask.2", "agents.ask.3"]

    /// A request as said: “…” in English, 「…」 in Chinese (the app's own quotes).
    static func quoted(_ s: String) -> String { Loc.isChinese ? "「\(s)」" : "“\(s)”" }

    @ViewBuilder
    var sessionsSection: some View {
        SettingsGroup("agents.sessions") {
            SettingsLine {
                HStack(spacing: 14) {
                    StatusDot(tone: AgentSessions.shared.tmuxAvailable ? .good : .warn).frame(width: SettingsMetrics.leadingWidth)
                    VStack(alignment: .leading, spacing: 3) {
                        if let v = AgentSessions.shared.tmuxVersion, AgentSessions.shared.tmuxAvailable {
                            Text(TL("agents.tmux.ok", v)).font(.system(size: SettingsMetrics.titleSize))
                            Text(TL("agents.tmux.ok.detail")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(TL(AgentSessions.shared.tmuxPath == nil ? "agents.tmux.missing" : "agents.tmux.old")).font(.system(size: SettingsMetrics.titleSize))
                            Text(TL("agents.tmux.missing.detail")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if !AgentSessions.shared.tmuxAvailable {
                        CommandText(text: "brew install tmux")
                        Button { AgentSessions.shared.refreshTmux(); Task { await m.load(login: false) } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help(TL("agents.check_again")).accessibilityLabel(TL("agents.check_again"))
                    }
                }
            }
            if let p = m.project {
                SettingsLine {
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(TL("agents.project_agent", p.name)).font(.system(size: SettingsMetrics.titleSize))
                            Text(TL("agents.project_agent.hint")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        RowPicker(label: TL("agents.project_agent", p.name), selection: Binding(get: { m.projectAgent }, set: { m.setProjectAgent($0) })) {
                            Text(TL("agents.project_agent.default")).tag("")
                            ForEach(m.rows.filter { m.sessions($0) && $0.installed }) { Text($0.name).tag($0.id) }
                        }
                    }
                }
            }
            ForEach(m.rows.filter { $0.installed && m.sessions($0) && DesktopApp.supports($0.id) }) { a in handoffTargetRow(a) }
        }
    }

    /// Where an agent's hand-offs run (an agent with a desktop app: Claude): Blurt's terminal (recommended) or the
    /// desktop app — the hand-off sheet starts with this (config sessions.target, the same key the sheet remembers).
    @ViewBuilder
    func handoffTargetRow(_ a: CoreAgent) -> some View {
        let installed = DesktopApp.available(a.id)
        SettingsLine {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(TL("agents.handoff_target", a.name)).font(.system(size: SettingsMetrics.titleSize))
                    Text(installed ? TL("agents.handoff_target.hint") : TL("agents.handoff_target.no_app", DesktopApp.name(a.id)))
                        .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                RowPicker(label: TL("agents.handoff_target", a.name),
                          selection: Binding(get: { DesktopApp.target(a.id) },
                                             set: { DesktopApp.remember(a.id, $0); m.objectWillChange.send() })) {
                    Text(TL("dispatch.run_in.terminal")).tag(HandoffTarget.terminal)
                    Text(TL("dispatch.run_in.desktop", DesktopApp.name(a.id))).tag(HandoffTarget.desktop)
                }
                .disabled(!installed)
            }
        }
    }

    /// Red only for a problem that stops Blurt: a ticked agent that can't run while no agent can. An agent the user
    /// doesn't use (not installed, not signed in, a fallback below the one that runs) is a quiet grey.
    /// Amber exactly where the row shows a fix to do (the colour and the message agree); "configured, can't check
    /// ahead" needs nothing from the user: quiet.
    func tone(_ a: CoreAgent, ordered: Bool = true) -> Tone {
        switch a.state {
        case "ready": return .good
        case "logged_out" where m.enabled.contains(a.id) && m.pick == nil: return .bad
        default: return showsFix(a, ordered: ordered) && a.state != "checking" ? .warn : .off
        }
    }

    /// Every row's check is in: only then is one marked as the one that runs first (no badge that jumps).
    var checked: Bool { m.signInChecked && !m.rows.contains { $0.state == "checking" } }

    /// The fix (sign in, install) only where it matters: a ticked agent tried before the one that runs, or any
    /// ticked one while none can run. Fallbacks below the one that runs say their state and nothing more.
    func showsFix(_ a: CoreAgent, ordered: Bool) -> Bool {
        guard !a.fix.isEmpty else { return false }
        guard ordered else { return true }
        guard m.enabled.contains(a.id) else { return false }
        guard let pick = m.pick, let p = m.headless.firstIndex(where: { $0.id == pick }) else { return true }
        return (m.headless.firstIndex(where: { $0.id == a.id }) ?? Int.max) < p
    }

    @ViewBuilder
    func agentRow(_ a: CoreAgent, ordered: Bool) -> some View {
        let on = m.enabled.contains(a.id)
        SettingsLine {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if ordered {
                    Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help(TL("agents.drag"))
                    // not installed: nothing to tick (it couldn't run)
                    Toggle("", isOn: Binding(get: { on && (a.installed || a.state == "checking") }, set: { m.toggle(a.id, $0) }))
                        .labelsHidden().toggleStyle(.checkbox).disabled(!a.installed && a.state != "checking")
                }
                StatusDot(tone: tone(a, ordered: ordered))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(a.name).font(.system(size: SettingsMetrics.titleSize, weight: .medium)).foregroundStyle(on || !ordered ? .primary : .secondary)
                        if let v = a.version { Text(shortVersion(v)).font(.caption).foregroundStyle(.secondary) }
                        if ordered && a.id == m.pick && checked { badge(TL("agents.runs_first"), nil) }
                        if a.installed && m.sessions(a) {
                            badge(TL("agents.sessions_badge"), Color.secondary).help(TL("agents.sessions_badge.help"))
                        }
                        // the blurt skill + MCP: in place (it can read and update your items), or not yet
                        if a.installed && m.connected[a.id] == true {
                            badge(TL("agents.connected"), Color.secondary).help(TL("agents.connected.help"))
                        }
                    }
                    Text(stateText(a)).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                }
                Spacer()
                if a.state == "checking" { ProgressView().controlSize(.mini) }
                // the blurt skill + MCP: Connect only while they are missing (manual agents: always offered)
                if (a.installed && m.connected[a.id] == false) || !a.headless {
                    // not connected yet: said on the button's tooltip, not as one more grey label on every row
                    if m.installing == a.id { ProgressView().controlSize(.small) }
                    else {
                        Button(TL("agents.install")) { Task { await m.preview(a) } }.controlSize(.small)
                            .help(TL(a.headless ? "agents.not_connected.help" : "agents.install.help"))
                    }
                }
                if a.headless && a.installed {
                    if m.testing == a.id { ProgressView().controlSize(.small) }
                    else { Button(TL("agents.test")) { Task { await m.test(a) } }.controlSize(.small).help(TL("agents.test.help")) }
                }
            }
            if showsFix(a, ordered: ordered) {
                HStack(spacing: 6) {
                    Text(TL(a.installed ? "agents.fix" : "agents.install_hint")).font(.caption).foregroundStyle(.secondary)
                    if looksLikeCommand(a.fix) { CommandText(text: commandPart(a.fix)) }
                    else { Text(a.fix).font(.caption).textSelection(.enabled) }
                }.padding(.leading, ordered ? 44 : 17)
            }
            if ordered, a.installed, let ms = m.models[a.id] { processingRow(a, ms) }
            if a.id == "codex" && a.installed {
                Text(TL("agents.codex_trust")).font(.caption).foregroundStyle(.secondary).padding(.leading, ordered ? 44 : 17)
            }
            if let t = m.tests[a.id] {
                Label(t.text, systemImage: t.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(t.ok ? Color.brandOk : Color.brandErr).padding(.leading, ordered ? 44 : 17)
            }
        }
        }
        .contextMenu {
            if ordered { Button(TL("agents.move_up")) { m.moveUp(a.id) } }
        }
    }

    /// The models organizing runs use, one line per kind: "Recordings" (shipped: the CLI's own model at low effort —
    /// a recording is long and its items need judgement) and "Cards" (snaps, voice notes and AI fill-in: the cheapest
    /// model, low effort — plenty for a note and a picture, at a fraction of the tokens).
    @ViewBuilder
    func processingRow(_ a: CoreAgent, _ ms: AgentModels) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ProcessingKind.allCases, id: \.self) { k in processingLine(a, ms, k) }
        }
        .padding(.leading, 44)
    }

    @ViewBuilder
    func processingLine(_ a: CoreAgent, _ ms: AgentModels, _ k: ProcessingKind) -> some View {
        HStack(spacing: 8) {
            Text(TL("agents.processing.\(k.rawValue)")).font(.caption).foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .leading)
            Picker("", selection: Binding(get: { m.processingModel(a.id, k) }, set: { m.setProcessing(a.id, k, model: $0) })) {
                Text(ms.cheapest.map { c in TL("agents.processing.cheapest_named", ms.models.first { $0.id == c }?.name ?? c) }
                     ?? TL("agents.processing.cheapest")).tag("cheapest")
                Text(ms.cliDefault.map { TL("agents.processing.default_named", $0) } ?? TL("agents.processing.default")).tag("default")
                Divider()
                ForEach(ms.models) { x in Text(x.name).tag(x.id) }
            }
            .labelsHidden().fixedSize().controlSize(.small)
            .accessibilityLabel(TL("agents.processing.\(k.rawValue)"))
            if !ms.efforts.isEmpty {
                Picker("", selection: Binding(get: { m.processingEffort(a.id, k) }, set: { m.setProcessing(a.id, k, effort: $0) })) {
                    Text(TL("agents.effort.default")).tag("default")
                    Divider()
                    ForEach(ms.efforts, id: \.self) { e in Text(TL("agents.effort.\(e)")).tag(e) }
                }
                .labelsHidden().fixedSize().controlSize(.small)
                .accessibilityLabel(TL("agents.effort"))
            }
        }
        .help(TL("agents.processing.\(k.rawValue).help"))
    }

    /// `c` nil: the brand badge ("Runs first"), brand ink on the brand tint (§3.4)
    func badge(_ s: String, _ c: Color?) -> some View {
        Text(s).font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(c == nil ? Color.brandInk : Color.primary)
            .background(Capsule().fill(c.map { $0.opacity(0.16) } ?? Color.brandTint))
    }

    func stateText(_ a: CoreAgent) -> String {
        if !a.headless { return TL(a.installed ? "agents.state.manual" : "agents.state.not_installed") }
        if a.why.isEmpty {
            switch a.state {
            case "not_installed": return TL("agents.state.not_installed")
            case "ready": return TL("agents.state.ready")
            case "checking": return TL("agents.state.checking")
            case "unknown": return TL("agents.state.unknown")
            case "configured": return TL("agents.state.configured")
            case "logged_out": return TL("agents.state.logged_out")
            default: return a.state
            }
        }
        return a.why
    }

    /// a `command` in backticks, or a bare install line ("npm i -g …") — not prose like "run claude, then /login"
    func looksLikeCommand(_ s: String) -> Bool {
        s.contains("`") || ["npm ", "curl ", "brew ", "pip ", "uv ", "npx "].contains { s.hasPrefix($0) }
    }

    /// "run `codex login` in a terminal" → "codex login"; plain commands stay as they are.
    func commandPart(_ s: String) -> String {
        if let r = s.range(of: "`[^`]+`", options: .regularExpression) { return String(s[r].dropFirst().dropLast()) }
        return s
    }
}

struct InstallSheet: View {
    @ObservedObject var m: AgentsModel
    var agent: CoreAgent
    var plan: InstallPlan
    var applied: Bool

    /// One line per change for the confirmation sheet — in words: what ("the Blurt skill", "the blurt MCP") and the
    /// agent's own fix in the user's language, never the script's English or a raw error.
    static func summary(_ c: InstallChange, agent: String = "") -> String {
        switch c.action {
        case "symlink": return TL("install.symlink", c.path ?? "", c.target ?? "")
        case "exists": return TL("install.exists", c.path ?? c.argv?.joined(separator: " ") ?? "")
        case "conflict": return TL("install.conflict", c.path ?? "", c.pointsTo ?? "?")
        case "run": return TL("install.run", (c.argv ?? []).joined(separator: " "))
        case "json_merge": return TL("install.json_merge", (c.key ?? []).joined(separator: "."), c.path ?? "")
        case "manual":
            let what = c.what.map { TL("install.what.\($0)") } ?? ""
            let fix = AgentHub.shared.def(agent).map(\.fixText).flatMap { $0.isEmpty ? nil : $0 } ?? c.how ?? ""
            return TL("install.manual", what, fix)
        default:
            NSLog("blurt install: %@ %@: %@", c.action, c.path ?? "", c.error ?? "")
            return c.path.map { TL("install.error.path", ($0 as NSString).abbreviatingWithTildeInPath) } ?? TL("install.error")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TL(applied ? "install.title.applied" : "install.title", agent.name)).font(.headline)
            Text(TL(applied ? "install.result" : "install.preview")).font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(plan.changes.enumerated()), id: \.offset) { _, c in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: icon(c)).foregroundStyle(color(c))
                        Text(Self.summary(c, agent: agent.id)).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let e = c.error { Text(e).font(.caption).foregroundStyle(Color.brandErr).padding(.leading, 22) }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            HStack {
                if m.installing != nil { ProgressView().controlSize(.small) }
                Spacer()
                if applied {
                    Button(TL("common.done")) { m.plan = nil; Task { await m.load() } }.keyboardShortcut(.defaultAction)
                } else {
                    Button(TL("common.cancel")) { m.plan = nil }.keyboardShortcut(.cancelAction)
                    Button(TL("install.confirm")) { Task { await m.apply() } }.keyboardShortcut(.defaultAction)
                        .disabled(!plan.changes.contains(where: \.changesSomething) || m.installing != nil)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    func icon(_ c: InstallChange) -> String {
        if c.ok == false || c.action == "error" { return "xmark.octagon.fill" }
        switch c.action {
        case "exists": return "checkmark.circle"
        case "conflict", "manual": return "exclamationmark.triangle"
        default: return applied ? "checkmark.circle.fill" : "plus.circle"
        }
    }
    func color(_ c: InstallChange) -> Color {
        if c.ok == false || c.action == "error" { return .brandErr }
        switch c.action {
        case "conflict", "manual": return .brandAttn
        case "exists": return .secondary
        default: return applied ? .brandOk : .brandInk
        }
    }
}

extension InstallChange {
    /// The localized one-liner (Settings → Agents, the self-test channel).
    var summary: String { InstallSheet.summary(self) }
}

/// Drag an agent onto another to put it there (the order Blurt tries them in); a brand-ink line shows where it lands.
/// What moves is the agent the drop itself names, not what was last picked up: a drag cancelled outside the list leaves
/// `dragging` set, and a later drop of some other text must not reorder anything.
struct AgentDrop: DropDelegate {
    let target: String
    let m: AgentsModel
    @Binding var dragging: String?
    @Binding var over: String?

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }
    func dropEntered(info: DropInfo) { over = target }
    func dropExited(info: DropInfo) { if over == target { over = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        over = nil
        guard let p = info.itemProviders(for: [.text]).first, p.canLoadObject(ofClass: NSString.self) else { return false }
        let target = target, m = m
        _ = p.loadObject(ofClass: NSString.self) { s, _ in
            guard let d = s as? String else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard d != target, let from = m.headless.firstIndex(where: { $0.id == d }),
                          let to = m.headless.firstIndex(where: { $0.id == target }) else { return }
                    m.move(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
                }
            }
        }
        return true
    }
}

/// "2.1.259 (Claude Code)" / "codex-cli 0.157.0" → "2.1.259" / "0.157.0"
func shortVersion(_ v: String) -> String {
    if let r = v.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) { return String(v[r]) }
    return String(v.prefix(16))
}
