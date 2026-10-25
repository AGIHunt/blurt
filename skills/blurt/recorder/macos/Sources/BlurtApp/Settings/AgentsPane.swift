// Settings → Agents (a page of SettingsKit lines; its sections are in SettingsCatalog). One focus: which agent Blurt
// uses and whether it works. The page's lead says the rule (the first agent that works, top to bottom); the list is
// one calm row per agent — status dot, name, one line of state in words, and at most two controls at rest: a fix
// (Sign In… / Install…) where the agent needs the user, and a switch (record.agents: on = tried, in the shown order).
// The drag handle (to reorder) and a ⋯ menu (Models…, Test, Connect Skill and MCP…, Move Up / Down, Check Again)
// appear on hover; the same menu is the row's context menu. "In use" marks the agent that runs (only once the sign-in
// check is in, so it never jumps), and an agent above it that is on but can't run says it is skipped, and why.
// One status rule everywhere (§3.3): ok = it can run, attn = installed but needs you, err = nothing can run, a hollow
// ring = off or not installed — the own-app agents (ZCode) too.
// Per-agent settings live in a sheet (AgentDetailSheet, from Models… or a double-click): the processing model and
// effort for recordings and for cards (fixed columns, the agent's own model names, never a raw id), Codex's trust
// note, the blurt skill + MCP (Connect: agents.py install, a --dry-run preview first, applied only after the user
// confirms), a test run, whether it can run in sessions, its version.
// Sessions: whether they outlive Blurt (tmux), the current project's default agent, where Claude hand-offs start
// (the recommended value marked inside the menu), and once, which agents can run in sessions.
// "Ask your agent" (agents.ask) is one line with Examples… (a popover of three requests, copy on hover): sending items
// anywhere is the agent's job with its own tools; this is where the old Export pane's links land (SettingsCatalog.moved).
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
    /// the install sheet's Details (the exact commands and paths), closed for every new preview
    @Published var installDetails = false
    /// test commands only (`install ID keylook`): the sheet drawn as in a key window, for background screenshots
    @Published var testKeyLook = false
    @Published var testing: String?
    @Published var tests: [String: (ok: Bool, text: String)] = [:]
    @Published var doctor: SessionsDoctor?
    @Published var projectAgent: String = ""
    /// Each installed agent's models (agents.py models), for its details sheet.
    @Published var models: [String: AgentModels] = [:]
    /// The row under the pointer (its drag handle and ⋯ menu show), the agent whose details sheet is open, the one
    /// whose Sign In… / Install… popover is open, and the Examples… popover — kept here, not in the view, so the
    /// self-test channel can open them for a screenshot.
    @Published var hovered: String?
    @Published var details: String?
    @Published var fixFor: String?
    @Published var examplesShown = false

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
    func moveDown(_ id: String) {
        guard let i = headless.firstIndex(where: { $0.id == id }), i < headless.count - 1 else { return }
        move(from: IndexSet(integer: i), to: i + 2)
    }
    /// Check Again: every agent's state, sign-in and connection, afresh.
    func recheck() {
        Task { connected = [:]; await load(); await checkConnected() }
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
            installDetails = false
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
        // the list's section is named like the page (Agents): no heading of its own, the lead says how it works
        SettingsPage(.agents, subtitle: TL("agents.lead")) {
            SettingsGroup("agents.list", content: {
                // one stack: the untitled group hides only the first row's hairline (not every row's)
                VStack(alignment: .leading, spacing: 0) {
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
                    listFooter
                }
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
        // Connect's preview; from the details sheet it opens over that sheet instead (AgentDetailSheet)
        .sheet(isPresented: Binding(get: { m.plan != nil && m.details == nil }, set: { if !$0 { m.plan = nil } })) {
            if let p = m.plan { InstallSheet(m: m, agent: p.agent, plan: p.plan, applied: p.applied) }
        }
        .background {
            Color.clear.sheet(isPresented: Binding(get: { m.details != nil }, set: { if !$0 { m.details = nil } })) {
                if let id = m.details { AgentDetailSheet(m: m, id: id) }
            }
        }
    }

    /// Under the list: what the agents do, in one line, and Check Again (a spinner beside it while a check runs).
    var listFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let e = m.error {
                Text(e).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandErr)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(TL("agents.footer")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                if m.loading { BrandSpinnerView(size: 10, label: TL("agents.state.checking")).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 } }
                Button(TL("agents.check_again")) { m.recheck() }
                    .buttonStyle(.plain).font(.system(size: SettingsMetrics.detailSize))
                    .foregroundStyle(m.loading ? Color.secondary : Color.brandInk)
                    .disabled(m.loading)
            }
        }
        .padding(.top, 8)
    }

    // MARK: the agent row

    /// Every check is in: only then is one marked as the one in use (no badge that jumps).
    var checked: Bool { m.signInChecked && !m.rows.contains { $0.state == "checking" } }

    func on(_ a: CoreAgent, ordered: Bool) -> Bool { !ordered || m.enabled.contains(a.id) }

    /// One rule for every row (§3.3): ok = it can run (signed in, or set up where sign-in can't be checked); attn =
    /// installed and on, but it needs the user (not signed in); err = the same while no agent can run at all; a hollow
    /// ring = off, not installed, or not known yet.
    func tone(_ a: CoreAgent, ordered: Bool) -> Tone {
        guard a.installed, a.state != "checking" else { return .off }
        guard ordered else { return .good }                         // an app of its own: installed is all it needs
        guard on(a, ordered: ordered) else { return .off }
        switch a.state {
        case "ready", "configured": return .good
        case "unknown": return .off
        case "logged_out": return m.pick == nil && checked ? .bad : .warn
        default: return .warn
        }
    }

    /// On, installed, can't run: Sign In… is its one inline action.
    func needsSignIn(_ a: CoreAgent, ordered: Bool) -> Bool {
        ordered && a.installed && on(a, ordered: true) && a.state == "logged_out"
    }

    /// On, but tried before the one in use and passed over: said on its own line, so the order and "In use" agree.
    func skipped(_ a: CoreAgent) -> Bool {
        guard checked, let pick = m.pick, m.enabled.contains(a.id), !a.usable,
              let p = m.headless.firstIndex(where: { $0.id == pick }), let i = m.headless.firstIndex(where: { $0.id == a.id }) else { return false }
        return i < p
    }

    @ViewBuilder
    func agentRow(_ a: CoreAgent, ordered: Bool) -> some View {
        let hover = m.hovered == a.id
        SettingsLine(padding: 8) {
            HStack(alignment: .center, spacing: 14) {
                StatusDot(tone: tone(a, ordered: ordered)).frame(width: SettingsMetrics.leadingWidth)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(a.name).font(.system(size: SettingsMetrics.titleSize, weight: .medium))
                            .foregroundStyle(on(a, ordered: ordered) && (a.installed || a.state == "checking") ? .primary : .secondary)
                            .help(a.version.map { TL("agents.details.version", shortVersion($0)) } ?? "")
                        if ordered && a.id == m.pick && checked { Badge(TL("agents.in_use")) }
                    }
                    subtitle(a, ordered: ordered).font(.system(size: SettingsMetrics.detailSize)).lineLimit(1)
                    if let t = m.tests[a.id] {
                        Label(t.text, systemImage: t.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(t.ok ? Color.brandOk : Color.brandErr)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if hasDetails(a) { m.details = a.id } }
                trailing(a, ordered: ordered, hover: hover)
            }
            .frame(minHeight: 32)
        }
        // the handle in the page's margin, on hover only: every name stays at one x
        .overlay(alignment: .leading) {
            if ordered && hover {
                Image(systemName: "line.3.horizontal").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                    .offset(x: -20).help(TL("agents.drag")).accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { m.hovered = a.id } else if m.hovered == a.id { m.hovered = nil }
        }
        .contextMenu { menuItems(a, ordered: ordered) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(a.name)
    }

    /// The state in words — in attention ink where the user has something to do — then why it is passed over, if it is.
    func subtitle(_ a: CoreAgent, ordered: Bool) -> Text {
        let state = Text(stateText(a))
        if ordered && !on(a, ordered: true) && a.installed {
            return Text(TL("agents.state.off")).foregroundColor(.secondary) + Text(" · ").foregroundColor(.secondary)
                + state.foregroundColor(.secondary)
        }
        var t: Text
        switch tone(a, ordered: ordered) {
        case .warn: t = state.foregroundColor(Color.brandAttnInk)
        case .bad: t = state.foregroundColor(Color.brandErr)
        default: t = state.foregroundColor(.secondary)
        }
        if ordered && skipped(a) { t = t + Text(" · " + TL("agents.state.skipped")).foregroundColor(.secondary) }
        return t
    }

    /// At rest: the one fix (Sign In… / Install… / Get ZCode… / an app's Connect…), then the switch; on hover the ⋯ menu
    /// before them. Every row's controls end at the page's trailing edge.
    @ViewBuilder
    func trailing(_ a: CoreAgent, ordered: Bool, hover: Bool) -> some View {
        HStack(spacing: 10) {
            if m.installing == a.id || m.testing == a.id {
                BrandSpinnerView(size: 10, label: TL(m.testing == a.id ? "agents.test" : "agents.install"))
            } else {
                moreMenu(a, ordered: ordered).opacity(hover ? 1 : 0)
            }
            fixButton(a, ordered: ordered)
            if ordered && (a.installed || a.state == "checking") {
                Toggle(TL("agents.use", a.name), isOn: Binding(get: { m.enabled.contains(a.id) }, set: { m.toggle(a.id, $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .help(TL(m.enabled.contains(a.id) ? "agents.use.on.help" : "agents.use.off.help"))
            }
        }
    }

    @ViewBuilder
    func fixButton(_ a: CoreAgent, ordered: Bool) -> some View {
        if needsSignIn(a, ordered: ordered) {
            Button(TL("agents.sign_in")) { m.fixFor = a.id }.controlSize(.small)
                .popover(isPresented: fixBinding(a.id), arrowEdge: .leading) { AgentFixPopover(m: m, agent: a, install: false) }
        } else if !a.installed && a.state != "checking" {
            if !a.headless, let url = AgentFix.site(AgentHub.shared.def(a.id)?.installText ?? "") {
                Button(TL("agents.get_app", a.name)) {
                    NSWorkspace.shared.open(url)
                    emit(["event": "agents_get_app", "agent": a.id, "url": url.absoluteString])
                }
                .controlSize(.small).help(url.host ?? url.absoluteString)
            } else {
                Button(TL("agents.install_cli")) { m.fixFor = a.id }.controlSize(.small)
                    .popover(isPresented: fixBinding(a.id), arrowEdge: .leading) { AgentFixPopover(m: m, agent: a, install: true) }
            }
        } else if !a.headless && a.installed {
            // an app of its own: Connect is the one thing to do here (the blurt skill + MCP, by hand in its settings)
            Button(TL("agents.install")) { Task { await m.preview(a) } }.controlSize(.small).help(TL("agents.install.help"))
        }
    }

    func fixBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { m.fixFor == id }, set: { if !$0, m.fixFor == id { m.fixFor = nil } })
    }

    func hasDetails(_ a: CoreAgent) -> Bool { a.headless && a.installed }

    func moreMenu(_ a: CoreAgent, ordered: Bool) -> some View {
        Menu { menuItems(a, ordered: ordered) } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(TL("agents.more")).accessibilityLabel(TL("agents.more.named", a.name))
    }

    /// The ⋯ menu and the row's context menu: the rarer actions, in the order people reach for them.
    @ViewBuilder
    func menuItems(_ a: CoreAgent, ordered: Bool) -> some View {
        if hasDetails(a) {
            Button(TL("agents.models")) { m.details = a.id }
            Button(TL("agents.test")) { Task { await m.test(a) } }.disabled(m.testing != nil)
        }
        if a.installed && a.headless {
            if m.connected[a.id] == true {
                Button(TL("agents.connected.menu")) {}.disabled(true)
            } else {
                Button(TL("agents.connect.menu")) { Task { await m.preview(a) } }.disabled(m.installing != nil)
            }
        }
        if needsSignIn(a, ordered: ordered) { Button(TL("agents.sign_in")) { m.fixFor = a.id } }
        if ordered {
            Divider()
            let i = m.headless.firstIndex { $0.id == a.id } ?? 0
            Button(TL("agents.move_up")) { m.moveUp(a.id) }.disabled(i == 0)
            Button(TL("agents.move_down")) { m.moveDown(a.id) }.disabled(i >= m.headless.count - 1)
        }
        Divider()
        Button(TL("agents.check_again")) { m.recheck() }.disabled(m.loading)
    }

    func stateText(_ a: CoreAgent) -> String { AgentFix.stateText(a) }

    // MARK: sessions

    @ViewBuilder
    var sessionsSection: some View {
        let s = AgentSessions.shared
        SettingsGroup("agents.sessions", footer: sessionsFooter) {
            // whether sessions outlive Blurt (tmux): a fact, not a choice — its state on the right, the fix only when missing
            let version = s.tmuxAvailable ? s.tmuxVersion : nil
            SettingRow("agents.keep_sessions",
                       detail: version.map { TL("agents.keep_sessions.ok", $0) }
                           ?? TL(s.tmuxPath == nil ? "agents.keep_sessions.missing" : "agents.keep_sessions.old"),
                       detailColor: version == nil ? .brandAttnInk : nil) {
                if version != nil {
                    Text(TL("agents.keep_sessions.on")).font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        CommandText(text: "brew install tmux")
                        Button { s.refreshTmux(); Task { await m.load(login: false) } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help(TL("agents.check_again")).accessibilityLabel(TL("agents.check_again"))
                    }
                }
            }
            if let p = m.project {
                SettingRow("agents.project_agent", title: TL("agents.project_agent", p.name)) {
                    RowPicker(label: TL("agents.project_agent", p.name), selection: Binding(get: { m.projectAgent }, set: { m.setProjectAgent($0) })) {
                        Text(TL("agents.project_agent.default")).tag("")
                        ForEach(m.rows.filter { m.sessions($0) && $0.installed }) { Text($0.name).tag($0.id) }
                    }
                }
            }
            ForEach(m.rows.filter { $0.installed && m.sessions($0) && DesktopApp.supports($0.id) }) { a in
                let installed = DesktopApp.available(a.id)
                // Where an agent's hand-offs start (Claude): Blurt's terminal (recommended, said inside the menu so the
                // closed button stays short) or its desktop app — config sessions.target, the key the sheet remembers.
                SettingRow("agents.handoff", title: TL("agents.handoff_target", a.name),
                           detail: installed ? TL("agents.handoff_target.hint") : TL("agents.handoff_target.no_app", DesktopApp.name(a.id))) {
                    RowPicker(label: TL("agents.handoff_target", a.name),
                              selection: Binding(get: { DesktopApp.target(a.id) },
                                                 set: { DesktopApp.remember(a.id, $0); m.objectWillChange.send() })) {
                        Section(TL("agents.handoff.recommended")) {
                            Text(TL("agents.handoff.terminal")).tag(HandoffTarget.terminal)
                        }
                        Section {
                            Text(TL("agents.handoff.desktop", DesktopApp.name(a.id))).tag(HandoffTarget.desktop)
                        }
                    }
                    .disabled(!installed)
                }
            }
        }
    }

    /// Once, for the section: which agents can work on items in a session (no badge repeated on every row).
    var sessionsFooter: String? {
        let names = m.rows.filter { $0.installed && m.sessions($0) }.map(\.name)
        guard !names.isEmpty else { return nil }
        let f = ListFormatter()
        f.locale = Loc.locale
        return TL("agents.sessions.footer", f.string(from: names) ?? names.joined(separator: ", "))
    }

    // MARK: ask your agent

    /// "Ask your agent": one line — sending items somewhere is the agent's job, with the tools it already has (Blurt
    /// has no connectors to set up) — and Examples…, three requests in plain words, each copyable.
    @ViewBuilder
    var askSection: some View {
        SettingsGroup("agents.ask") {
            SettingsLine {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(TL("agents.ask.line")).font(.system(size: SettingsMetrics.titleSize))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(TL("agents.ask.examples")) { m.examplesShown = true }
                        .buttonStyle(.plain).foregroundStyle(Color.brandInk)
                }
                // over the whole line, so it opens above it inside the window (the button sits at the page's edge)
                .popover(isPresented: $m.examplesShown, arrowEdge: .top) { AskExamples() }
            }
        }
    }

    static let askExamples = ["agents.ask.1", "agents.ask.2", "agents.ask.3"]

    /// A request as said: “…” in English, 「…」 in Chinese (the app's own quotes).
    static func quoted(_ s: String) -> String { Loc.isChinese ? "「\(s)」" : "“\(s)”" }
}

/// The three example requests, each copyable (the copy button shows on the line under the pointer), and how items
/// reach other people.
struct AskExamples: View {
    @State private var hover: String?
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(TL("agents.ask.header")).font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(AgentsPane.askExamples, id: \.self) { key in
                    HStack(spacing: 10) {
                        Text(AgentsPane.quoted(TL(key))).font(.system(size: SettingsMetrics.titleSize)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(TL(key), forType: .string)
                            copied = key
                            emit(["event": "agents_ask_copied", "example": key])
                        } label: { Image(systemName: copied == key ? "checkmark" : "doc.on.doc") }
                            .buttonStyle(.borderless).help(TL("agents.ask.copy")).accessibilityLabel(TL("agents.ask.copy"))
                            .opacity(hover == key || copied == key ? 1 : 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hover == key ? 0.05 : 0)))
                    .contentShape(Rectangle())
                    .onHover { if $0 { hover = key } else if hover == key { hover = nil } }
                }
            }
            .padding(.horizontal, -8)
            Text(TL("agents.ask.footer")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 400)
    }
}

/// How to sign in to an agent, or to install it: the agent's own words (agents.json), its command in a copyable chip,
/// or its site as a link — one treatment in both languages — and Check Again.
struct AgentFixPopover: View {
    @ObservedObject var m: AgentsModel
    var agent: CoreAgent
    var install: Bool

    var body: some View {
        let def = AgentHub.shared.def(agent.id)
        VStack(alignment: .leading, spacing: 10) {
            Text(TL(install ? "agents.fix.install_title" : "agents.fix.sign_in_title", agent.name)).font(.headline)
            if install {
                let text = def?.installText ?? ""
                if AgentFix.isCommand(text) {
                    Text(TL("agents.fix.run")).font(.system(size: SettingsMetrics.titleSize))
                    CommandText(text: AgentFix.command(text))
                } else if let url = AgentFix.site(text) {
                    Text(TL("agents.fix.site")).font(.system(size: SettingsMetrics.titleSize))
                    Link(url.host.map { $0 + url.path } ?? url.absoluteString, destination: url).foregroundStyle(Color.brandInk)
                } else if !text.isEmpty {
                    Text(text).font(.system(size: SettingsMetrics.titleSize)).textSelection(.enabled)
                }
            } else {
                Text(AgentFix.sentence(agent.fix.isEmpty ? def?.fixText ?? "" : agent.fix)).font(.system(size: SettingsMetrics.titleSize))
                    .fixedSize(horizontal: false, vertical: true)
                if let c = AgentFix.signInCommand(agent.id, fallback: agent.fix) { CommandText(text: c) }
            }
            Text(TL("agents.fix.then")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(TL("agents.check_again")) { m.fixFor = nil; m.recheck() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

/// One agent's settings, from Models… or a double-click on its row: the processing model and effort per kind of run
/// (fixed columns, so they line up whatever the model is called), the blurt skill + MCP, a test run, sessions, its
/// version.
struct AgentDetailSheet: View {
    @ObservedObject var m: AgentsModel
    var id: String
    var agent: CoreAgent? { m.rows.first { $0.id == id } }

    static let modelWidth: CGFloat = 250
    static let effortWidth: CGFloat = 110

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let a = agent {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(a.name).font(.system(size: 17, weight: .semibold))
                    if let v = a.version {
                        Text(TL("agents.details.version", shortVersion(v))).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(AgentFix.stateText(a)).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                }
                section(TL("agents.details.models")) {
                    if let ms = m.models[a.id] { grid(a, ms) } else { Hint(TL("agents.details.no_models")) }
                    Hint(TL("agents.details.models.note"))
                    if a.id == "codex" { Hint(TL("agents.codex_trust")) }
                }
                section(nil) {
                    line(TL("agents.details.skill"),
                         detail: TL(m.connected[a.id] == true ? "agents.connected.help" : "agents.not_connected.help")) {
                        if m.installing == a.id { BrandSpinnerView(size: 14) }
                        else if m.connected[a.id] == true { Text(TL("agents.details.connected")).foregroundStyle(.secondary) }
                        else { Button(TL("agents.install")) { Task { await m.preview(a) } } }
                    }
                    Divider()
                    line(TL("agents.details.test"), detail: TL("agents.test.help"), result: m.tests[a.id]) {
                        if m.testing == a.id { BrandSpinnerView(size: 14) }
                        else { Button(TL("agents.test")) { Task { await m.test(a) } }.disabled(m.testing != nil) }
                    }
                    Divider()
                    line(TL("agents.details.sessions"), detail: TL(m.sessions(a) ? "agents.sessions_badge.help" : "agents.details.no_sessions")) {
                        EmptyView()
                    }
                }
            }
            HStack {
                Spacer()
                Button(TL("common.done")) { m.details = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .sheet(isPresented: Binding(get: { m.plan != nil }, set: { if !$0 { m.plan = nil } })) {
            if let p = m.plan { InstallSheet(m: m, agent: p.agent, plan: p.plan, applied: p.applied) }
        }
    }

    @ViewBuilder
    func section<C: View>(_ title: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let t = title { Text(t).font(.system(size: SettingsMetrics.titleSize, weight: .semibold)) }
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }

    /// Two kinds of run × model and effort: one label column, then two pickers of fixed widths.
    func grid(_ a: CoreAgent, _ ms: AgentModels) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Text(TL("agents.details.model")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                if !ms.efforts.isEmpty { Text(TL("agents.effort")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
            }
            ForEach(ProcessingKind.allCases, id: \.self) { k in
                GridRow {
                    Text(TL("agents.processing.\(k.rawValue)")).font(.system(size: SettingsMetrics.titleSize))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(TL("agents.processing.\(k.rawValue).help"))
                    Picker(TL("agents.processing.\(k.rawValue)"),
                           selection: Binding(get: { m.processingModel(a.id, k) }, set: { m.setProcessing(a.id, k, model: $0) })) {
                        // by the model's name from the agent's own list; one it doesn't list goes unnamed (never its raw id)
                        Text(ms.name(ms.cliDefault).map { TL("agents.processing.default_named", $0) } ?? TL("agents.processing.default")).tag("default")
                        Text(ms.name(ms.cheapest).map { TL("agents.processing.cheapest_named", $0) } ?? TL("agents.processing.cheapest")).tag("cheapest")
                        Divider()
                        ForEach(ms.models) { x in Text(x.name).tag(x.id) }
                    }
                    .labelsHidden().frame(width: Self.modelWidth, alignment: .leading)
                    if !ms.efforts.isEmpty {
                        Picker(TL("agents.effort"),
                               selection: Binding(get: { m.processingEffort(a.id, k) }, set: { m.setProcessing(a.id, k, effort: $0) })) {
                            Text(TL("agents.effort.default")).tag("default")
                            Divider()
                            ForEach(ms.efforts, id: \.self) { e in Text(TL("agents.effort.\(e)")).tag(e) }
                        }
                        .labelsHidden().frame(width: Self.effortWidth, alignment: .leading)
                    }
                }
            }
        }
    }

    func line<C: View>(_ title: String, detail: String, result: (ok: Bool, text: String)? = nil, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: SettingsMetrics.titleSize))
                Text(detail).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let r = result {
                    Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(r.ok ? Color.brandOk : Color.brandErr)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
    }
}

/// An agent's state and fixes in words, the same on the row, the details sheet and the fix popover.
enum AgentFix {
    static func stateText(_ a: CoreAgent) -> String {
        if !a.headless { return TL(a.installed ? "agents.state.manual" : "agents.state.not_installed") }
        // a state the app has words for is said in the app's words (one wording on every surface: 未安装 / 未登录),
        // whatever the script's `why` says; its `why` only for a state the app doesn't know
        switch a.state {
        case "not_installed": return TL("agents.state.not_installed")
        case "ready": return TL("agents.state.ready")
        case "checking": return TL("agents.state.checking")
        case "unknown": return TL("agents.state.unknown")
        case "configured": return TL("agents.state.configured")
        case "logged_out": return TL("agents.state.logged_out")
        default: return a.why.isEmpty ? TL("agents.state.unknown") : a.why
        }
    }

    /// a `command` in backticks, or a bare install line ("npm i -g …") — not prose like "see zcode.z.ai"
    static func isCommand(_ s: String) -> Bool {
        s.contains("`") || ["npm ", "curl ", "brew ", "pip ", "uv ", "npx "].contains { s.hasPrefix($0) }
    }

    /// "run `codex login` in a terminal" → "codex login"; plain commands stay as they are.
    static func command(_ s: String) -> String {
        if let r = s.range(of: "`[^`]+`", options: .regularExpression) { return String(s[r].dropFirst().dropLast()) }
        return s
    }

    /// The command that signs in: the first `command` of the agent's fix — read from its English text, where agents.json
    /// marks commands, so both languages copy the same one.
    static func signInCommand(_ id: String, fallback: String) -> String? {
        for s in [AgentHub.shared.def(id)?.fix["en"] ?? "", fallback] where s.contains("`") { return command(s) }
        return nil
    }

    /// The agent's own fix as a sentence: no backticks, a capital first letter.
    static func sentence(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
        guard let f = t.first else { return t }
        return f.uppercased() + String(t.dropFirst()) + (t.hasSuffix(".") || t.hasSuffix("。") || !f.isASCII ? "" : ".")
    }

    /// "see zcode.z.ai" → https://zcode.z.ai (a site to get it from, when there is no command).
    static func site(_ s: String) -> URL? {
        guard !isCommand(s), let r = s.range(of: #"(https?://)?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(/[^\s，。)）]*)?"#, options: .regularExpression)
        else { return nil }
        let host = String(s[r])
        return URL(string: host.hasPrefix("http") ? host : "https://" + host)
    }
}

/// Connect's confirmation (a dry run, nothing written yet) and, after Connect, its result. It reads like the Mac's own
/// "install this" sheets: who is connected to what (Blurt's icon, the agent's app as a badge), one line on what the
/// user gets, a few rows in plain words — what Connect adds first, then what needs the user, then what is already in
/// place — and the exact commands and paths only under Details (mono, selectable, one line each, scrolling sideways,
/// with a Copy button). Amber only where the user has to do something, and that row says what. The one primary is the
/// native default button (↩), accent-filled.
struct InstallSheet: View {
    @ObservedObject var m: AgentsModel
    var agent: CoreAgent
    var plan: InstallPlan
    var applied: Bool

    /// One change, in words: what it is (the Blurt skill, the Blurt MCP server), what it does or why it stays, and the
    /// agent's own fix where the user has to act — in the user's language, never the script's English, an argv or a
    /// raw error (errors go to the log; the command and paths go to Details).
    struct Row {
        enum Tone { case add, added, inPlace, attn, err }
        var change: InstallChange
        var group: InstallChange.Group
        var tone: Tone
        var title: String
        var detail: String?
        /// a conflict with a different skill: Show in Finder on that folder
        var reveal: String?
    }

    static func row(_ c: InstallChange, agent: String, applied: Bool, otherIsBlurt: Bool? = nil) -> Row {
        let name = AgentNames.name(agent)
        let skill = c.subject == .skill
        let group = c.group(otherIsBlurt: otherIsBlurt ?? c.conflictIsBlurt)
        let about = TL(skill ? "install.row.about.skill" : "install.row.about.mcp", name)
        let inPlaceTitle = TL(skill ? "install.row.in_place.skill" : "install.row.in_place.mcp")
        if c.action == "manual" {
            let fix = AgentHub.shared.def(agent).map(\.fixText).flatMap { $0.isEmpty ? nil : $0 } ?? c.how.flatMap { $0.isEmpty ? nil : $0 }
            return Row(change: c, group: group, tone: .attn, title: TL(skill ? "install.row.manual.skill" : "install.row.manual.mcp"),
                       detail: fix ?? TL("install.row.manual.none", name))
        }
        if c.action == "error" {
            NSLog("blurt install: %@ %@: %@", c.action, c.path ?? "", c.error ?? "")
            return Row(change: c, group: group, tone: .err, title: TL(skill ? "install.row.failed.skill" : "install.row.failed.mcp"),
                       detail: c.path.map { TL("install.error.path", InstallChange.tilde($0)) } ?? TL("install.error"))
        }
        if c.ok == false {
            NSLog("blurt install: %@ %@: %@ %@", c.action, c.path ?? "", c.error ?? "", c.output ?? "")
            return Row(change: c, group: group, tone: .err, title: TL(skill ? "install.row.failed.skill" : "install.row.failed.mcp"),
                       detail: TL("install.row.failed.detail", name))
        }
        switch c.action {
        case "symlink", "run", "json_merge":
            let done = applied && c.ok == true
            return Row(change: c, group: group, tone: done ? .added : .add,
                       title: TL(done ? (skill ? "install.row.added.skill" : "install.row.added.mcp")
                                      : (skill ? "install.row.add.skill" : "install.row.add.mcp")),
                       detail: about)
        case "conflict" where group == .inPlace:
            return Row(change: c, group: group, tone: .inPlace, title: inPlaceTitle,
                       detail: TL("install.row.other_copy", InstallChange.tilde(c.otherCopy ?? "?")))
        case "conflict":
            return Row(change: c, group: group, tone: .attn, title: TL("install.row.conflict.title"),
                       detail: TL("install.row.conflict", InstallChange.tilde(c.path ?? "?")), reveal: c.path)
        default:
            return Row(change: c, group: group, tone: .inPlace, title: inPlaceTitle, detail: TL("install.row.exists"))
        }
    }

    /// The localized one-liner of a change (the self-test channel's install_preview event): the row's title and detail.
    static func summary(_ c: InstallChange, agent: String = "") -> String {
        let r = row(c, agent: agent, applied: false)
        return [r.title, r.detail].compactMap { $0 }.joined(separator: " · ")
    }

    var rows: [Row] {
        plan.changes.map { Self.row($0, agent: agent.id, applied: applied) }
            .enumerated().sorted { ($0.element.group, $0.offset) < ($1.element.group, $1.offset) }.map(\.element)
    }
    /// Nothing for Connect to do: every row is in place or needs the user.
    var nothingToDo: Bool { !applied && !plan.changesSomething }
    var failed: Bool { applied && !plan.applied }

    var title: String {
        if applied { return TL(failed ? "install.title.failed" : "install.title.applied", agent.name) }
        return TL(nothingToDo ? "install.title.nothing" : "install.title", agent.name)
    }
    var subtitle: String {
        if applied { return failed ? TL("install.benefit.failed") : TL("install.benefit.applied", agent.name) }
        return TL(nothingToDo ? "install.benefit.nothing" : "install.benefit", agent.name)
    }

    /// The exact lines under Details: one per change that has a command or a path.
    var technical: [(label: String, line: String)] {
        rows.compactMap { r in r.change.technicalLine().map { (r.title, $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            list.padding(.top, 18)
            if !technical.isEmpty { details.padding(.top, 14) }
            footer.padding(.top, 16)
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)
        .frame(width: 480)
        .modifier(TestKeyLook(on: BrandRowView.testKeyLook || m.testKeyLook))
    }

    // MARK: header: who connects to what, and what the user gets

    var header: some View {
        HStack(alignment: .center, spacing: 12) {
            InstallMark(agent: agent.id)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: the rows: what Connect adds, what needs the user, what stays as it is

    var list: some View {
        let rows = rows
        let showInPlaceLabel = rows.contains { $0.group != .inPlace } && rows.contains { $0.group == .inPlace }
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                if showInPlaceLabel, r.group == .inPlace, i == 0 || rows[i - 1].group != .inPlace {
                    Text(TL("install.group.in_place")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.top, 4).accessibilityAddTraits(.isHeader)
                }
                rowView(r)
            }
        }
    }

    func rowView(_ r: Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol(r.tone)).font(.system(size: 13)).foregroundStyle(tint(r.tone))
                .frame(width: 18, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.system(size: 13))
                if let d = r.detail {
                    Text(d).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let p = r.reveal {
                    Button(T("action.reveal_in_finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                    }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.brandInk).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    func symbol(_ t: Row.Tone) -> String {
        switch t {
        case .add: return "plus.circle.fill"
        case .added: return "checkmark.circle.fill"
        case .inPlace: return "checkmark.circle"
        case .attn: return "exclamationmark.triangle.fill"
        case .err: return "xmark.octagon.fill"
        }
    }
    func tint(_ t: Row.Tone) -> Color {
        switch t {
        case .add: return .brandInk           // blurt about to act for you
        case .added: return .brandOk
        case .inPlace: return .secondary
        case .attn: return .brandAttn
        case .err: return .brandErr
        }
    }

    // MARK: Details: the exact commands and paths, on request

    var details: some View {
        DisclosureGroup(isExpanded: $m.installDetails) {
            InstallDetailsWell(lines: technical).padding(.top, 8)
        } label: {
            Text(TL("install.details")).font(.system(size: 12)).foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { m.installDetails.toggle() } }
        }
    }

    // MARK: footer: the promise, Cancel and the one default

    var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            if m.installing != nil {
                BrandSpinnerView(size: 14, label: TL("install.working"))
                Text(TL("install.working")).font(.system(size: 12)).foregroundStyle(.secondary)
            } else if !applied && !nothingToDo {
                Text(TL("install.footnote")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if applied || nothingToDo {
                Button(TL("common.done")) { m.plan = nil; Task { await m.load() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                Button(TL("common.cancel")) { m.plan = nil }.keyboardShortcut(.cancelAction)
                    .disabled(m.installing != nil)
                Button(TL("install.confirm")) { Task { await m.apply() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(m.installing != nil)
            }
        }
        .controlSize(.regular)
    }
}

/// Screenshots of a test build launched in the background (test commands only, like BLURT_TEST_KEY_LOOK for the
/// list selection): the sheet draws as it does in the key window people see it in, its default button filled.
struct TestKeyLook: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        if on { content.environment(\.controlActiveState, .key) } else { content }
    }
}

/// Blurt's app icon (the thing being connected), with the agent's own app icon as a badge when it has a desktop app
/// (Claude); a command-line-only agent shows Blurt's icon alone. Decoration: the title names both.
struct InstallMark: View {
    var agent: String
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: BrandMark.image).resizable().interpolation(.high).frame(width: 44, height: 44)
            if let url = DesktopApp.appURL(agent) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high)
                    .frame(width: 22, height: 22).offset(x: 4, y: 3)
            }
        }
        .frame(width: 48, height: 48, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// Details: one mono line per change (label above it in the system font), never wrapped — a long command scrolls
/// sideways — selectable, on a quiet 5 % well with no stroke (it is not a field), and a Copy button for all of it.
struct InstallDetailsWell: View {
    var lines: [(label: String, line: String)]
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l.label).font(.system(size: 11)).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(l.line).font(.system(size: 11, design: .monospaced))
                                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                .textSelection(.enabled)
                                .padding(.trailing, 16)
                        }
                        // a long line fades out at the edge instead of being cut mid-letter: it scrolls
                        .mask(HStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                        })
                    }
                }
            }
            .padding(.leading, 10).padding(.vertical, 9).padding(.trailing, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.map(\.line).joined(separator: "\n"), forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                    .foregroundStyle(copied ? Color.brandOk : .secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(copied ? TL("install.copied") : T("settings.kit.copy"))
            .accessibilityLabel(T("settings.kit.copy"))
            .padding(5)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
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
