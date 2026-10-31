// The dispatch panel (AppEnvironment.dispatch, TerminalHosting.newSession): hand items to Claude Code / Codex in a new
// session — which agent, together (one conversation) or in parallel (a window each), in a worktree or in the project
// folder. Every change re-runs `sessions.py dispatch --dry-run`, which says what would happen (branch, folder) and
// warns — never blocks — when another session is already editing the same folder without a worktree (K5 wording).
// What does block — an agent that isn't signed in, one too old for hand-offs (its version, the update command, Check
// Again), items already in a running session, no agent, a check that failed — is said once, under the items, and the
// way out takes Start's place as the default (Use Codex / Sign In…, Open Its Session, Open Agents Settings…, Try Again).
// Sign-in: the panel opens on the agent the last check (Agents.loginCache) says works, probes that one agent at once
// (a second or two) and every agent behind it; Start waits until the chosen agent's state is known, and the choice
// never moves under the user once the panel is up — a signed-out agent is said in the notice, Use Codex beside it.
// Where it runs, for an agent with a desktop app that is installed (Claude): Blurt's terminal (recommended) or the
// desktop app, remembered per agent (HandoffTarget, config sessions.target) — a rare choice, under Options with the
// model. The desktop app still gets Blurt's worktree; Start opens its claude:// link (DesktopApp) and the footer says
// once that the user confirms the folder and presses Send there. Without the blurt MCP for that agent nothing reports
// progress: a notice says the items then need marking by hand and offers Install (the Settings → Agents installer).
// The project (its default agent, the remembered model, the header) is the items' own — never the sidebar's current
// one; the current project only seeds New Session's picker. A dry run that fails keeps Start off, its reason in the
// one notice look (Settings', never a raw code: sessionsErrorText); a start that fails says why in the same notice
// and leaves Start on, to try again.
import AppKit
import SwiftUI
import BlurtCore

struct DispatchItem: Identifiable, Hashable {
    let uid: String
    let ref: String         // BA-12, or a uid prefix while unknown
    let title: String
    var kind = "issue"      // its icon in the panel, as in the list it came from
    var id: String { uid }
}

@MainActor
final class DispatchModel: ObservableObject {
    struct AgentChoice: Identifiable, Hashable { let id: String; let name: String; let installed: Bool; let session: Bool
        var loggedOut = false; var fix = "" }
    enum Phase: Equatable { case idle, checking, starting, failed(String) }

    @Published var items: [DispatchItem]
    let pickItems: Bool                         // New Session: the user picks the items
    @Published var projectID: String?
    @Published var candidates: [DispatchItem] = []
    @Published var chosen = Set<String>()
    /// Several items: the list under "6 items" is open.
    @Published var itemsOpen = false
    @Published var loadingCandidates = false
    @Published var candidatesError: String?

    @Published var agents: [AgentChoice] = []
    /// The quick detect answered: until then the Agent row says it is checking, not "none installed".
    @Published var agentsLoaded = false
    @Published var agent = ""
    var agentTouched = false                    // the user picked one: login results no longer move it
    /// The chosen agent's models (agents.py models) and the pick: "" = whatever the CLI is set to. Remembered per
    /// project and agent (config sessions.models.<project>.<agent>).
    @Published var models: [AgentModels.Model] = []
    @Published var cliDefault: String?
    @Published var model = ""
    @Published var mode: DispatchMode = .together
    /// Blurt's terminal, or the agent's desktop app (only when `desktopAvailable`).
    @Published var target: HandoffTarget = .terminal
    /// A desktop dry run: is the blurt MCP installed for the agent (false = items need marking by hand).
    @Published var desktopMCP: Bool?
    var desktopAvailable: Bool { !agent.isEmpty && DesktopApp.available(agent) }
    var desktop: Bool { target == .desktop && desktopAvailable }
    @Published var worktree: WorktreeChoice = .auto
    @Published var warnings: [DispatchWarning] = []
    @Published var preview: [[String: Any]] = []
    @Published var phase: Phase = .idle
    /// The dry run with the current choices failed: starting would fail the same way. A real start that failed (a
    /// timeout, tmux) leaves Start on, so the user can just try again.
    @Published private(set) var checkFailed = false
    /// Agents whose sign-in a probe in this panel answered, and the ones only the last check (the cache) knows.
    @Published private(set) var probed = Set<String>()
    @Published private(set) var cachedKnown = Set<String>()
    /// The chosen agent's sign-in state is known (a probe here, or the last check): until then Start waits, so it never
    /// starts a signed-out agent.
    var loginChecked: Bool { probed.contains(agent) || cachedKnown.contains(agent) }
    /// A probe here said so: sessions.py needn't check again (--force); the Agent row then says "signed in".
    var loginVerified: Bool { probed.contains(agent) }
    /// The dry run said the chosen agent is too old for hand-offs (sessions.py outdated): its version, the minimum,
    /// the update command.
    @Published private(set) var outdated: SessionsError?
    /// The session the items are already with (sessions.py already_dispatched): the failure offers to open it.
    @Published var busyJob: String?
    private var checkGen = 0

    init(items: [String], project: String?) {
        self.items = items.map(DispatchModel.label)
        pickItems = items.isEmpty
        projectID = Self.projectOf(items: items, given: project, current: ProjectStore.shared.currentID,
                                   first: ProjectStore.shared.projects.first?.id) { IndexLookup.item(uid: $0)?.projectID }
    }

    /// The items' own project (the first one the index knows); without items (New Session), the one given, else the
    /// current one.
    static func projectOf(items: [String], given: String?, current: String?, first: String?,
                          lookup: (String) -> String?) -> String? {
        if let p = items.lazy.compactMap(lookup).first { return p }
        return given ?? current ?? first
    }

    static func label(_ uid: String) -> DispatchItem {
        if let it = IndexLookup.item(uid: uid) { return DispatchItem(uid: uid, ref: it.itemID, title: it.title, kind: it.kind) }
        return DispatchItem(uid: uid, ref: "", title: "")          // filled in by loadLabels (items.py get)
    }

    /// Item ids and titles from the store (`items.py get`), for items the index doesn't know yet.
    func loadLabels() async {
        let todo = items.filter { $0.title.isEmpty }.map(\.uid)
        guard !todo.isEmpty else { return }
        let found = await withTaskGroup(of: DispatchItem?.self) { g -> [String: DispatchItem] in
            for u in todo {
                g.addTask {
                    guard let o = try? await ScriptRunner.shared.json("items.py", ["get", u], timeout: 30),
                          let it = o["item"] as? [String: Any] else { return nil }
                    return DispatchItem(uid: u, ref: it["id"] as? String ?? "", title: it["title"] as? String ?? "",
                                        kind: it["kind"] as? String ?? "issue")
                }
            }
            var out: [String: DispatchItem] = [:]
            for await r in g { if let r = r { out[r.uid] = r } }
            return out
        }
        items = items.map { found[$0.uid] ?? $0 }
    }

    var selected: [String] { pickItems ? candidates.filter { chosen.contains($0.uid) }.map(\.uid) : items.map(\.uid) }
    var count: Int { selected.count }
    var projectName: String {
        if let p = preview.first?["project"] as? String, let pr = ProjectStore.shared.project(id: p) { return pr.name }
        return projectID.flatMap { ProjectStore.shared.project(id: $0)?.name } ?? ""
    }
    var worktreeOn: Bool {
        if mode == .parallel { return true }
        if worktree != .auto { return worktree == .on }
        return preview.first.map { ($0["worktree"] as? String).map { !$0.isEmpty } ?? false } ?? true
    }
    var branchPreview: String? { preview.first?["branch"] as? String }
    var cwdPreview: String? { preview.first?["cwd"] as? String }
    var concurrent: DispatchWarning? { warnings.first { $0.code == "concurrent_edit" } }
    var chosenAgent: AgentChoice? { agents.first { $0.id == agent } }
    /// Another agent that can take over from a logged-out one.
    var alternative: AgentChoice? { agents.first { $0.id != agent && !$0.loggedOut } }
    /// Why Start can't go, said once under the items with its way out as the footer's default (one pattern for every
    /// reason): the items already with a running session, the agent not signed in, no agent at all, a dry run that
    /// failed. A real start that failed is not a block: Start stays, to try again.
    enum Block: Equatable { case busy(String), loggedOut, outdated, noAgent, failed(String) }
    var block: Block? {
        if case .failed(let why) = phase {
            if let j = busyJob { return .busy(j) }
            if outdated != nil { return .outdated }
            if checkFailed { return .failed(why) }
        }
        if agentsLoaded && agents.isEmpty { return .noAgent }
        if !desktop, loginChecked, chosenAgent?.loggedOut == true { return .loggedOut }
        return nil
    }
    /// How many of the selected items are still unreviewed: Start moves them to To Do (sessions.py draft_confirmed).
    var toTodo: Int {
        guard let w = warnings.first(where: { $0.code == "draft_confirmed" }) else { return 0 }
        return max(w.items.filter { selected.contains($0) }.count, count == 1 ? 1 : 0)
    }
    /// One session per item: Start says how many.
    var sessionsToStart: Int { mode == .parallel && count > 1 ? count : 1 }

    var canStart: Bool {
        // the desktop app signs in on its own: the CLI's login only matters in the terminal. A dry run that failed
        // would fail the same way: Start stays off until a choice changes and the check passes.
        count > 0 && !agent.isEmpty && phase != .starting && !checkFailed && chosenAgent?.session != false
            && (desktop || (loginChecked && chosenAgent?.loggedOut != true))
    }

    func load() async {
        async let detect = try? Agents.shared.detect(login: false)
        async let doctor = try? AgentSessions.shared.doctor()
        let (d, doc) = await (detect, doctor)
        // the last sign-in check: who was signed out, so the first frame already shows the agent that will stay
        let cache = Agents.shared.loginCache
        var list: [AgentChoice] = []
        for a in d?.agents ?? [] {
            let session = doc?.agents[a.id] ?? (a.interactive == "terminal")
            if a.installed && session {
                list.append(AgentChoice(id: a.id, name: a.name, installed: a.installed, session: session,
                                        loggedOut: cache?.loggedOut(a.id) ?? false, fix: cache?.fix[a.id] ?? ""))
            }
        }
        agents = list
        cachedKnown = Set(list.map(\.id).filter { cache?.knows($0) == true })
        agentsLoaded = true
        // K5: the project's default agent → the global one → the first that is set up; the last one used wins over all
        // — among the agents the last check didn't find signed out, when there is one
        let saved = Config.shared["sessions.agent"] as? String
        let projectDefault = projectID.flatMap { ProjectStore.shared.project(id: $0)?.defaultAgent }
        let globalDefault = Config.shared["record.default_agent"] as? String
        let order = [saved, projectDefault, globalDefault, d?.pick, list.first?.id].compactMap { $0 }
        agent = order.first { id in list.contains { $0.id == id && !$0.loggedOut } }
            ?? order.first { id in list.contains { $0.id == id } } ?? ""
        target = DesktopApp.target(agent)
        // the chosen agent alone first (a second or two: Start waits for it), every agent behind it (the Agent
        // pop-up's "not signed in" marks). Neither moves the choice: a signed-out agent is the notice's, with Use Codex
        let first = agent
        if !first.isEmpty {
            Task { @MainActor [weak self] in
                guard let one = try? await Agents.shared.detect(login: true, ids: [first]) else { return }
                self?.applyLogin(one)
            }
        }
        Task { @MainActor [weak self] in
            guard let full = try? await Agents.shared.detect(login: true) else { return }
            self?.applyLogin(full)
        }
        if pickItems { await loadCandidates() } else { await loadLabels() }
        await loadModels()
        await check()
    }

    /// A sign-in probe answered for these agents: their marks follow it, and they count as checked.
    func applyLogin(_ d: AgentDetect) {
        let rows = Dictionary(d.agents.map { ($0.id, $0) }) { a, _ in a }
        agents = agents.map { a in
            guard let r = rows[a.id] else { return a }
            var a = a
            a.loggedOut = r.state == "logged_out"
            a.fix = a.loggedOut ? r.fix : ""
            return a
        }
        probed.formUnion(rows.keys)
    }

    /// Sign In… → Check Again: the full sign-in check once more (the Agent row and the block follow it).
    func recheckLogin() async {
        guard let full = try? await Agents.shared.detect(login: true) else { return }
        applyLogin(full)
    }

    private var modelKey: String { projectID ?? "_" }

    func loadModels() async {
        let a = agent
        guard !a.isEmpty, let m = try? await Agents.shared.models(a) else { models = []; cliDefault = nil; model = ""; return }
        guard a == agent else { return }
        models = m.models
        cliDefault = m.cliDefault
        let saved = ((Config.shared["sessions.models"] as? [String: Any])?[modelKey] as? [String: Any])?[a] as? String ?? ""
        model = models.contains { $0.id == saved } ? saved : ""
    }

    private func rememberModel() {
        var all = Config.shared["sessions.models"] as? [String: Any] ?? [:]
        var p = all[modelKey] as? [String: Any] ?? [:]
        p[agent] = model.isEmpty ? nil : model
        all[modelKey] = p
        Config.shared.set("sessions.models", all)
    }

    func loadCandidates() async {
        guard let p = projectID else { candidates = []; return }
        loadingCandidates = true
        defer { loadingCandidates = false }
        do {
            let o = try await ScriptRunner.shared.json("items.py", ["list", "--project", p, "--work", "todo"], timeout: 60)
            candidates = (o["items"] as? [[String: Any]] ?? []).compactMap {
                guard let uid = $0["uid"] as? String, ($0["state"] as? String) != "discarded" else { return nil }
                return DispatchItem(uid: uid, ref: $0["id"] as? String ?? "", title: $0["title"] as? String ?? "",
                                    kind: $0["kind"] as? String ?? "issue")
            }
            candidatesError = nil
        } catch {
            candidates = []
            candidatesError = TL("dispatch.pick.failed")
        }
        chosen = chosen.intersection(candidates.map(\.uid))
    }

    /// dry-run with the current choices → warnings + what would happen
    func check() async {
        guard count > 0 else { warnings = []; preview = []; return }
        checkGen += 1
        let gen = checkGen
        if phase != .starting { phase = .checking }
        busyJob = nil
        outdated = nil
        checkFailed = false
        do {
            let r = try await AgentSessions.shared.dispatch(items: selected, agent: agent.isEmpty ? nil : agent, mode: mode,
                                                            worktree: mode == .parallel ? .on : worktree, dryRun: true,
                                                            model: desktop ? nil : model, desktop: desktop)
            guard gen == checkGen else { return }
            warnings = r.warnings
            preview = r.rows
            desktopMCP = desktop ? r.mcp : nil
            if phase == .checking { phase = .idle }
        } catch {
            guard gen == checkGen else { return }
            warnings = []
            preview = []
            busyJob = (error as? SessionsError).flatMap { $0.code == "already_dispatched" ? $0.job : nil }
            outdated = (error as? SessionsError).flatMap { $0.code == "outdated" ? $0 : nil }
            checkFailed = true
            phase = .failed(sessionsErrorText(error))
        }
    }

    func start() async -> DispatchResult? {
        phase = .starting
        Config.shared.set("sessions.agent", agent)
        rememberModel()
        if desktopAvailable { DesktopApp.remember(agent, target) }
        let toDesktop = desktop
        do {
            let r = try await AgentSessions.shared.dispatch(items: selected, agent: agent, mode: mode,
                                                            worktree: mode == .parallel ? .on : (worktree == .auto ? (worktreeOn ? .on : .off) : worktree),
                                                            dryRun: false, model: toDesktop ? nil : model, loginChecked: loginVerified,
                                                            desktop: toDesktop)
            for l in r.launch { AppRunner.shared.launch(l) }
            for l in r.links { DesktopApp.open(l.url, job: l.job) }
            emit(["event": "dispatch", "jobs": r.jobs, "warnings": r.warnings.map(\.code), "app_runner": r.launch.count,
                  "agent": agent, "model": model.isEmpty || toDesktop ? NSNull() : model, "target": toDesktop ? "desktop" : "terminal"])
            phase = .idle
            return r
        } catch {
            busyJob = (error as? SessionsError).flatMap { $0.code == "already_dispatched" ? $0.job : nil }
            outdated = (error as? SessionsError).flatMap { $0.code == "outdated" ? $0 : nil }
            checkFailed = outdated != nil       // too old: Start would fail the same way until it is updated
            phase = .failed(sessionsErrorText(error))
            return nil
        }
    }
}

/// The panel (HandoffKit's family): the 15 pt title with the project at its right, one line of what goes — the item
/// as the list draws it, or "6 items" with each kind's count and a disclosure that lists them (no box around one item:
/// it isn't a field) — then, when Start can't go or something must be read first, one notice; one box of settings rows
/// (Agent, Sessions when there are several items, Separate branch), the rare ones (where it runs, the model) behind
/// "› Options", and a footer: one quiet line on the left (what Start will do to all the items, or the spinner and what
/// it is doing), Cancel and the one default on the right — Start, named after what it starts, or, while Start can't
/// go, the way out (Open Its Session, Use Codex, Sign In…). Every row's description is one line.
struct DispatchView: View {
    @ObservedObject var m: DispatchModel
    @ObservedObject var agentsModel = AgentsModel.shared
    /// This sheet asked for the installer (the blurt MCP for the desktop app): its sheet shows here, not in Settings.
    @State var installAsked = false
    /// Sign In…'s popover (the command, then Check Again): from the Agent row or from the footer's default.
    @State private var signInFrom: String?
    @State private var hovered: String?
    @AppStorage("handoff.optionsOpen") private var optionsOpen = false
    var close: () -> Void
    var started: (DispatchResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            what.padding(.top, 6)
            if m.pickItems { picker.padding(.top, PanelMetrics.gap) }
            else if m.itemsOpen && m.items.count > 1 { itemsBox.padding(.top, 10).transition(.opacity.combined(with: .move(edge: .top))) }
            notices
            settingsBox.padding(.top, PanelMetrics.gap)
            if hasOptions { options.padding(.top, 14) }
            footer.padding(.top, 20)
        }
        .padding(.horizontal, PanelMetrics.side)
        .padding(.top, PanelMetrics.top)
        .padding(.bottom, PanelMetrics.bottom)
        .frame(width: PanelMetrics.width)
        .animation(PanelMetrics.change, value: changeKey)
        .task { await m.load() }
        .sheet(isPresented: Binding(get: { installAsked && agentsModel.plan != nil },
                                    set: { if !$0 { agentsModel.plan = nil; installAsked = false; Task { await m.check() } } })) {
            if let p = agentsModel.plan { InstallSheet(m: agentsModel, agent: p.agent, plan: p.plan, applied: p.applied) }
        }
        .onChange(of: m.agent) { _ in m.target = DesktopApp.target(m.agent); Task { await m.loadModels(); await m.check() } }
        .onChange(of: m.target) { _ in Task { await m.check() } }
        .onChange(of: m.model) { _ in Task { await m.check() } }
        .onChange(of: m.mode) { _ in Task { await m.check() } }
        .onChange(of: m.worktree) { _ in Task { await m.check() } }
        .onChange(of: m.chosen) { _ in Task { await m.check() } }
        .onChange(of: m.projectID) { _ in Task { await m.loadCandidates(); await m.check() } }
        // Settings → Agents changed the remembered choice while this sheet is open: follow it
        .onReceive(NotificationCenter.default.publisher(for: DesktopApp.targetChanged)) { n in
            if n.object as? String == m.agent { m.target = DesktopApp.target(m.agent) }
        }
    }

    /// What the panel animates with: a notice coming or going, a row appearing (Sessions with a second item).
    private var changeKey: [String] {
        [m.count > 1 ? "many" : "one", "\(m.phase)", m.concurrent != nil && !m.worktreeOn ? "concurrent" : "",
         m.desktop ? "desktop" : "", m.desktopMCP == false ? "nomcp" : "", m.itemsOpen ? "all" : "", m.busyJob ?? "",
         m.block.map { "\($0)" } ?? ""]
    }

    // MARK: header and items

    /// The title and, at its right, whose items these are: the project's name, or New Session's project pop-up.
    var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(TL(m.pickItems ? "handoff.title.new" : "dispatch.title"))
                .font(.system(size: PanelMetrics.titleSize, weight: .semibold)).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            if m.pickItems { projectMenu } else if !m.projectName.isEmpty {
                Text(m.projectName).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(m.projectName)
            }
        }
        .frame(minHeight: 22)
    }

    /// The line under the title: what goes. One item as the list draws it; several as "6 items" (each kind's icon and
    /// count) whose disclosure lists them; New Session: what is chosen.
    @ViewBuilder var what: some View {
        if m.pickItems {
            Text(m.count == 0 ? TL("dispatch.subtitle.none") : TL("handoff.pick.count", m.count))
                .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
        } else if m.items.count == 1, let i = m.items.first {
            HandoffItemLine(item: i)
        } else {
            PanelDisclosure(title: TL("handoff.items.count", m.items.count), open: $m.itemsOpen, inset: 0, size: 13) {
                KindSummary(items: m.items)
            }
        }
    }

    var itemsBox: some View {
        let w = HandoffItemLine.refWidth(m.items)
        let rows = VStack(spacing: 0) {
            ForEach(m.items) { i in
                SettingsLine(padding: PanelMetrics.rowPadding) { HandoffItemLine(item: i, refWidth: w) }
            }
        }
        return PanelBox {
            // past seven rows the list scrolls inside the box
            if m.items.count > 7 { ScrollView { rows }.frame(height: 7 * Self.rowHeight) } else { rows }
        }
    }

    /// A row of the items box: 13 pt text with 6 pt above and below, and the hairline.
    static let rowHeight: CGFloat = 29

    /// New Session: the project's To Do under a heading with Select All at its right. A row is the target: its kind
    /// icon at rest, the checkbox in the same slot while the pointer is over it or once it is chosen (Linear's list) —
    /// one leading glyph, never a column of grey squares.
    var picker: some View {
        let w = HandoffItemLine.refWidth(m.candidates)
        let all = !m.candidates.isEmpty && m.chosen.count == m.candidates.count
        return PanelBox(heading: AnyView(Text(TL("handoff.pick.heading")))) {
            ScrollView {
                VStack(spacing: 0) {
                    if m.loadingCandidates && m.candidates.isEmpty {
                        SettingsLine(padding: 8) {
                            HStack(spacing: 6) { BrandSpinnerView(size: 10); Text(TL("handoff.pick.loading")) }
                                .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                        }
                    } else if let e = m.candidatesError {
                        SettingsLine(padding: 8) { Text(e).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary) }
                    } else if m.candidates.isEmpty {
                        SettingsLine(padding: 8) {
                            Text(TL("dispatch.pick.empty")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(m.candidates) { c in
                        let on = m.chosen.contains(c.uid)
                        SettingsLine(padding: PanelMetrics.rowPadding) {
                            HStack(spacing: 8) {
                                ZStack {
                                    if on || hovered == c.uid {
                                        Toggle("", isOn: Binding(get: { on }, set: { pick(c.uid, $0) })).toggleStyle(.checkbox).labelsHidden()
                                            .tint(Color.settingsDefault)
                                    } else {
                                        Image(nsImage: Look.kindImage(c.kind, size: KindStyle.smallSize))
                                    }
                                }
                                .frame(width: KindStyle.smallSize, height: KindStyle.smallSize)
                                Text(c.ref).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: w, alignment: .leading)
                                Text(c.title.isEmpty ? TL("dispatch.untitled") : c.title).font(.system(size: 13)).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading).help(c.title)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { pick(c.uid, !on) }
                            .onHover { hovered = $0 ? c.uid : (hovered == c.uid ? nil : hovered) }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(Look.kindName(c.kind)) \(c.ref) \(c.title)")
                            .accessibilityValue(on ? "1" : "0")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { pick(c.uid, !on) }
                        }
                    }
                }
            }
            .frame(height: CGFloat(min(max(m.candidates.count, 3), 7)) * Self.rowHeight)
        } accessory: {
            if !m.candidates.isEmpty {
                TextLinkButton(TL(all ? "handoff.pick.none" : "handoff.pick.all")) {
                    m.chosen = all ? [] : Set(m.candidates.map(\.uid))
                }
                .font(.system(size: SettingsMetrics.detailSize))
            }
        }
    }

    func pick(_ uid: String, _ on: Bool) {
        if on { m.chosen.insert(uid) } else { m.chosen.remove(uid) }
    }

    /// New Session's project: the kit's pop-up (ChoicePopup) at the title's right, like every other choice.
    var projectMenu: some View {
        ChoicePopup(label: TL("dispatch.project"),
                    choices: ProjectStore.shared.projects.map { ($0.id, $0.name) },
                    selection: Binding(get: { m.projectID ?? "" }, set: { m.projectID = $0 }))
            .help(m.projectID.flatMap { ProjectStore.shared.project(id: $0)?.name } ?? "")
    }

    // MARK: settings

    var settingsBox: some View {
        PanelBox {
            agentRow
            if m.count > 1 {
                SettingRow("handoff.mode", title: TL("handoff.mode"),
                           detail: m.mode == .together ? TL("handoff.mode.together.detail") : TL("handoff.mode.parallel.detail")) {
                    ChoicePopup(label: TL("handoff.mode"),
                                choices: [(DispatchMode.together, TL("handoff.mode.together")), (.parallel, TL("handoff.mode.parallel"))],
                                selection: $m.mode)
                }
                .transition(.opacity)
            }
            branchRow
        }
    }

    /// Sign In… sits before the pop-up (Settings' fix pattern) while the footer's default is another way out (Use
    /// Codex); when it is the only way out it is the default itself, not said twice.
    var signInInRow: Bool { m.block == .loggedOut && m.alternative != nil }

    var agentRow: some View {
        SettingRow("handoff.agent", title: TL("dispatch.agent"), detailContent: AnyView(agentDetail)) {
            HStack(spacing: 8) {
                if signInInRow {
                    Button(TL("agents.sign_in")) { signInFrom = "row" }.controlSize(.small).fixedSize()
                        .popover(isPresented: Binding(get: { signInFrom == "row" }, set: { if !$0 { signInFrom = nil } }),
                                 arrowEdge: .bottom) { signInPopover }
                }
                if !m.agents.isEmpty {
                    ChoicePopup(label: TL("dispatch.agent"),
                                choices: m.agents.map { a in (a.id, a.loggedOut && a.id != m.agent ? Loc.t("dispatch.agent.logged_out", table: "Terminal", a.name) : a.name) },
                                selection: Binding(get: { m.agent }, set: { m.agent = $0; m.agentTouched = true }))
                }
            }
        }
    }

    /// One signal, on one line: checking (the spinner and the words), not signed in (the "!" disc and the words in
    /// attention ink), else what the session will run: the model and that the agent is signed in, or the desktop app.
    @ViewBuilder var agentDetail: some View {
        Group {
            if !m.agentsLoaded || (!m.agents.isEmpty && !m.loginChecked && !m.desktop) {
                HStack(spacing: 5) { BrandSpinnerView(size: 10); Text(TL("dispatch.checking_login")) }
                    .foregroundStyle(.secondary)
            } else if m.agents.isEmpty {
                attention(TL("handoff.agent.none"))
            } else if let a = m.chosenAgent, a.loggedOut, !m.desktop {
                attention(TL("handoff.agent.signed_out"))
            } else if m.desktop {
                Text(TL("handoff.agent.desktop", DesktopApp.name(m.agent))).foregroundStyle(.secondary)
            } else {
                Text(agentSummary).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: SettingsMetrics.detailSize))
        .lineLimit(1)
    }

    func attention(_ text: String) -> some View {
        HStack(spacing: 5) {
            StatusDot(tone: .warn)
            Text(text).foregroundStyle(Color.brandAttnInk)
        }
    }

    /// The model in use, by name (the one picked, else the CLI's own setting), and "signed in" once the check said so.
    var modelName: String? {
        if !m.model.isEmpty { return m.models.first { $0.id == m.model }?.name ?? m.model }
        return m.cliDefault.map { d in m.models.first { $0.id == d }?.name ?? d }
    }

    var agentSummary: String {
        switch (modelName, m.loginVerified) {
        case (let n?, true): return TL("handoff.agent.model_signed_in", n)
        case (let n?, false): return n
        case (nil, true): return TL("handoff.agent.signed_in")
        case (nil, false): return TL("handoff.agent.ready")
        }
    }

    /// How to sign in: the agent's own words and its command (copyable), then Check Again — Settings' Sign In….
    var signInPopover: some View {
        let a = m.chosenAgent
        return VStack(alignment: .leading, spacing: 10) {
            Text(TL("agents.fix.sign_in_title", a?.name ?? "")).font(.headline)
            if let a = a {
                let text = a.fix.isEmpty ? AgentHub.shared.def(a.id)?.fixText ?? "" : a.fix
                if !text.isEmpty {
                    Text(AgentFix.sentence(text)).font(.system(size: SettingsMetrics.titleSize)).fixedSize(horizontal: false, vertical: true)
                }
                if let c = AgentFix.signInCommand(a.id, fallback: a.fix) { CommandText(text: c) }
            }
            Text(TL("agents.fix.then")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(TL("agents.check_again")) { signInFrom = nil; Task { await m.recheckLogin() } }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    var noGit: Bool { m.warnings.contains { $0.code == "no_git" } }
    var branchLocked: Bool { m.mode == .parallel && m.count > 1 }

    /// One sentence per state, the same on every screen; the branch's name only in the tooltip (a slug cut mid-phrase
    /// says less than none). Locked on (one session per item), it says why.
    var branchRow: some View {
        let detail: String = {
            if noGit { return TL("handoff.branch.no_git") }
            if branchLocked { return TL("handoff.branch.locked") }
            return TL(m.worktreeOn ? "handoff.branch.on" : "handoff.branch.off")
        }()
        let help = m.worktreeOn && !noGit && !branchLocked
            ? (m.branchPreview.map { $0 + "\n" } ?? "") + TL("handoff.branch.help") : TL("handoff.branch.help")
        return SettingRow("handoff.branch", title: TL("handoff.branch"), detail: detail, help: help) {
            Toggle(TL("handoff.branch"), isOn: Binding(get: { m.worktreeOn && !noGit }, set: { m.worktree = $0 ? .on : .off }))
                .labelsHidden().panelSwitch()
                .disabled(branchLocked || noGit)
        }
        .help(help)
    }

    // MARK: options (rare: where it runs, the model)

    var hasOptions: Bool { m.desktopAvailable || (!m.models.isEmpty && !m.desktop) }

    var options: some View {
        VStack(alignment: .leading, spacing: 5) {
            PanelDisclosure(title: TL("handoff.options"), open: $optionsOpen)
            if optionsOpen {
                PanelBox {
                    if m.desktopAvailable {
                        let app = DesktopApp.name(m.agent)
                        SettingRow("handoff.run_in", title: TL("handoff.run_in"),
                                   detail: m.desktop ? TL("handoff.run_in.desktop.detail") : TL("handoff.run_in.terminal.detail")) {
                            ChoicePopup(label: TL("handoff.run_in"),
                                        choices: [(HandoffTarget.terminal, TL("handoff.run_in.terminal")),
                                                  (.desktop, TL("handoff.run_in.desktop", app))],
                                        selection: $m.target)
                        }
                    }
                    if !m.models.isEmpty && !m.desktop {
                        SettingRow("handoff.model", title: TL("dispatch.model")) {
                            ChoicePopup(label: TL("dispatch.model"),
                                        choices: [("", m.cliDefault.map { d in TL("handoff.model.default_named", m.models.first { $0.id == d }?.name ?? d) } ?? TL("handoff.model.default"))]
                                            + m.models.map { ($0.id, $0.name) },
                                        selection: $m.model, dividers: [1])
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: notices: under the items, above the settings

    /// Only what has to be read before Start, in one place: why it can't start (its way out is the footer's
    /// default), a start that failed, the concurrent-edit choice, the desktop app without the blurt MCP, items taken
    /// back from an ended session, no tmux.
    @ViewBuilder var notices: some View {
        if m.block == .outdated, let o = m.outdated {
            // what is installed, what it needs, and the command, copyable: Check Again is the footer's default
            VStack(alignment: .leading, spacing: 8) {
                PanelNotice(text: blockText(.outdated))
                if let fix = o.fix { CommandText(text: fix).padding(.leading, SettingsMetrics.boxInset) }
            }
            .padding(.top, 14).transition(.opacity)
        } else if let b = m.block, !(b == .loggedOut && signInInRow) {
            // signed out with Sign In… in the Agent row: the row's "Not signed in" and its button say it once
            PanelNotice(text: blockText(b)).padding(.top, 14).transition(.opacity)
        } else if m.block == nil, case .failed(let why) = m.phase {
            PanelNotice(text: why).padding(.top, 14).transition(.opacity)
        }
        if m.concurrent != nil && !m.worktreeOn {
            PanelNotice(text: TL("warning.concurrent_edit", m.projectName)).padding(.top, 14).transition(.opacity)
        }
        if m.desktop && m.desktopMCP == false {
            PanelNotice(text: TL("dispatch.desktop.no_mcp", DesktopApp.name(m.agent)), tone: .off) {
                if agentsModel.installing == m.agent { BrandSpinnerView(size: 10) }
                else {
                    Button(TL("dispatch.desktop.install")) {
                        installAsked = true
                        let a = CoreAgent(id: m.agent, name: m.chosenAgent?.name ?? AgentNames.name(m.agent), installed: true, state: "ready")
                        Task { await agentsModel.preview(a) }
                    }
                    .controlSize(.small)
                }
            }
            .padding(.top, 14).transition(.opacity)
        }
        // codes this version has no sentence for are left out rather than shown raw; no_git is the branch row's,
        // draft_confirmed the footer's
        ForEach(m.warnings.filter { !["concurrent_edit", "no_git", "draft_confirmed"].contains($0.code) && TL($0.noteKey) != $0.noteKey },
                id: \.code) { w in
            PanelNotice(text: TL(w.noteKey), tone: .off).padding(.top, 14)
        }
    }

    func blockText(_ b: DispatchModel.Block) -> String {
        switch b {
        case .busy, .failed:
            if case .failed(let why) = m.phase { return why }
            return TL("error.already_dispatched")
        case .loggedOut: return TL("handoff.block.logged_out", m.chosenAgent?.name ?? "")
        case .outdated:
            let name = m.chosenAgent?.name ?? AgentNames.name(m.agent)
            guard let o = m.outdated, let v = o.version, let need = o.need else { return TL("error.outdated") }
            return TL("handoff.block.outdated", name, v, Self.shortVersion(need))
        case .noAgent: return TL("handoff.block.no_agent")
        }
    }

    // MARK: footer

    /// What Start will do to all the items: one item by its id, several by count ("6 items · 1 moves to To Do").
    var footnote: String? {
        if m.block != nil { return nil }           // never a promise next to a Start that isn't there
        if m.pickItems && m.count == 0 { return TL("handoff.pick.hint") }
        if m.desktop { return TL("dispatch.desktop.send", DesktopApp.name(m.agent)) }
        let todo = m.toTodo
        if m.count == 1 {
            let ref = (m.pickItems ? m.candidates.first { m.chosen.contains($0.uid) } : m.items.first)?.ref ?? ""
            return todo > 0 && !ref.isEmpty ? TL("handoff.note.todo.one", ref) : nil
        }
        guard m.count > 1 else { return nil }
        return todo > 0 ? TL("handoff.note.todo.count", m.count, todo) : TL("handoff.items.count", m.count)
    }

    var footer: some View {
        let concurrentAsk = m.concurrent != nil && !m.worktreeOn
        return HStack(spacing: 8) {
            PanelFootnote(text: footnote, busy: m.phase == .starting ? TL("handoff.starting") : nil)
            Button(TL("common.cancel"), action: close).keyboardShortcut(.cancelAction)
            if let b = m.block {
                wayOut(b)
            } else if concurrentAsk {
                // the reminder's two answers are the footer's buttons while it is up
                Button(TL("warning.concurrent_edit.continue")) { Task { if let r = await m.start() { started(r) } } }
                    .disabled(!m.canStart)
                Button(TL("warning.concurrent_edit.use_worktree")) { m.worktree = .on }
                    .panelDefault().keyboardShortcut(.defaultAction)
            } else {
                Button(m.desktop ? TL("dispatch.start.desktop", DesktopApp.name(m.agent)) : m.sessionsToStart > 1 ? TL("handoff.start.many", m.sessionsToStart) : TL("dispatch.start")) { Task { if let r = await m.start() { started(r) } } }
                    .panelDefault().keyboardShortcut(.defaultAction)
                    .disabled(!m.canStart)
            }
        }
    }

    /// "0.164.0" → "0.164": how people write a minimum version.
    static func shortVersion(_ v: String) -> String { v.hasSuffix(".0") ? String(v.dropLast(2)) : v }

    /// While Start can't go, the default is the way out (Claude desktop's permission prompts): the session the items
    /// are with, the other agent, how to sign in, Settings → Agents, or the check once more.
    @ViewBuilder func wayOut(_ b: DispatchModel.Block) -> some View {
        switch b {
        case .busy(let j):
            Button(TL("dispatch.open_session")) { close(); TerminalModule.reveal(job: j) }
                .panelDefault().keyboardShortcut(.defaultAction)
        case .loggedOut:
            if let other = m.alternative {
                Button(TL("dispatch.use_agent", other.name)) { m.agent = other.id; m.agentTouched = true }
                    .panelDefault().keyboardShortcut(.defaultAction)
            } else {
                Button(TL("agents.sign_in")) { signInFrom = "footer" }
                    .panelDefault().keyboardShortcut(.defaultAction)
                    .popover(isPresented: Binding(get: { signInFrom == "footer" }, set: { if !$0 { signInFrom = nil } }),
                             arrowEdge: .bottom) { signInPopover }
            }
        case .outdated:
            Button(TL("agents.check_again")) { Task { await m.check() } }
                .panelDefault().keyboardShortcut(.defaultAction)
        case .noAgent:
            Button(TL("handoff.open_agents")) { close(); AppEnvironment.settings?.show(pane: "agents") }
                .panelDefault().keyboardShortcut(.defaultAction)
        case .failed:
            Button(TL("overlay.retry")) { Task { await m.check() } }
                .panelDefault().keyboardShortcut(.defaultAction)
        }
    }
}

@MainActor
enum DispatchPanel {
    private static var panels: [NSPanel] = []
    static var windowNumber: Int? { panels.last?.windowNumber }
    /// The newest panel's model and the action its Start button runs (self-tests).
    private(set) static var current: (model: DispatchModel, start: () -> Void)?

    static func show(items: [String], project: String? = nil) {
        let m = DispatchModel(items: items, project: project)
        let w = HandoffWindow()
        w.isFloatingPanel = true
        w.title = TL(items.isEmpty ? "handoff.title.new" : "dispatch.title")
        let started: (DispatchResult) -> Void = { [weak w] r in
            w?.close()
            if let j = r.jobs.first { TerminalModule.reveal(job: j) }
        }
        current = (m, { Task { @MainActor in if let r = await m.start() { started(r) } } })
        let host = NSHostingController(rootView: DispatchView(m: m, close: { [weak w] in w?.close() }, started: started))
        host.sizingOptions = [.preferredContentSize]
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }     // the content runs under the hidden title bar
        w.contentViewController = host
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { n in
            MainActor.assumeIsolated { panels.removeAll { $0 === n.object as AnyObject } }
        }
        panels.append(w)
        activateApp()
        w.makeKeyAndOrderFront(nil)
    }
}
