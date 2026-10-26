// The dispatch panel (AppEnvironment.dispatch, TerminalHosting.newSession): hand items to Claude Code / Codex in a new
// session — which agent, together (one conversation) or in parallel (a window each), in a worktree or in the project
// folder. Every change re-runs `sessions.py dispatch --dry-run`, which says what would happen (branch, folder) and
// warns — never blocks — when another session is already editing the same folder without a worktree (K5 wording).
// What does block, said next to the choice instead of after it: an agent that isn't logged in (its fix, and the
// other agent to use; Start waits up to 3 s for the sign-in check after a launch), and items already with a session
// that is still going (Open Its Session).
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
    /// The sign-in check has answered (or 3 s passed): until then Start waits, so it never starts a logged-out agent.
    @Published var loginChecked = false
    /// The full login check came back (not just the 3 s wait): sessions.py needn't check again (--force).
    private(set) var loginVerified = false
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
        var list: [AgentChoice] = []
        for a in d?.agents ?? [] {
            let session = doc?.agents[a.id] ?? (a.interactive == "terminal")
            if a.installed && session { list.append(AgentChoice(id: a.id, name: a.name, installed: a.installed, session: session)) }
        }
        agents = list
        agentsLoaded = true
        // K5: the project's default agent → the global one → the first that is set up; the last one used wins over all
        let saved = Config.shared["sessions.agent"] as? String
        let projectDefault = projectID.flatMap { ProjectStore.shared.project(id: $0)?.defaultAgent }
        let globalDefault = Config.shared["record.default_agent"] as? String
        let order = [saved, projectDefault, globalDefault, d?.pick, list.first?.id].compactMap { $0 }
        agent = order.first { id in list.contains { $0.id == id } } ?? ""
        target = DesktopApp.target(agent)
        if pickItems { await loadCandidates() } else { await loadLabels() }
        await loadModels()
        await check()
        // the quick detect can't tell who is logged in; the full one (a few seconds) can: never default to an agent
        // that would stop at its login screen, and say so next to its name. Start waits for it, 3 s at most.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.loginChecked = true
        }
        defer { loginChecked = true }
        if let full = try? await Agents.shared.detect(login: true) {
            loginVerified = true
            let out = Dictionary(full.agents.filter { $0.state == "logged_out" }.map { ($0.id, $0.fix) }) { a, _ in a }
            agents = agents.map { var a = $0; a.loggedOut = out[a.id] != nil; a.fix = out[a.id] ?? ""; return a }
            if !agentTouched, out[agent] != nil,
               let better = ([projectDefault, globalDefault, full.pick] + agents.map(\.id)).compactMap({ $0 })
                .first(where: { id in agents.contains { $0.id == id && !$0.loggedOut } }) {
                agent = better
            }
        }
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
            phase = .failed(sessionsErrorText(error))
            return nil
        }
    }
}

/// The panel (HandoffKit's family): a 15 pt title over one secondary line, the items as the list draws them, one box of
/// settings rows (Agent, Sessions when there are several items, Separate branch), the rare ones (where it runs, the
/// model) behind "› Options", a notice only when something needs reading first, and a footer: one quiet line on the
/// left (what Start will do, or the spinner and what it is doing), Cancel and the one default on the right. The
/// sign-in check lives in the Agent row only; the model in use is that row's description.
struct DispatchView: View {
    @ObservedObject var m: DispatchModel
    @ObservedObject var agentsModel = AgentsModel.shared
    /// This sheet asked for the installer (the blurt MCP for the desktop app): its sheet shows here, not in Settings.
    @State var installAsked = false
    /// Several items: the first three, then "N more" opens the rest.
    @State private var allItems = false
    @AppStorage("handoff.optionsOpen") private var optionsOpen = false
    var close: () -> Void
    var started: (DispatchResult) -> Void

    static let shownItems = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group { if m.pickItems { picker } else { itemsBox } }.padding(.top, PanelMetrics.gap)
            settingsBox.padding(.top, PanelMetrics.gap)
            if hasOptions { options.padding(.top, 14) }
            notices
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
         m.desktop ? "desktop" : "", m.desktopMCP == false ? "nomcp" : "", allItems ? "all" : "", m.busyJob ?? ""]
    }

    // MARK: header and items

    var header: some View {
        PanelHeader(title: TL(m.pickItems ? "handoff.title.new" : "dispatch.title"), subtitle: subtitle)
    }

    var subtitle: String {
        if m.pickItems { return m.count == 0 ? TL("dispatch.subtitle.none") : TL("handoff.pick.count", m.count) }
        return m.projectName
    }

    var itemsBox: some View {
        let shown = allItems || m.items.count <= Self.shownItems + 1 ? m.items : Array(m.items.prefix(Self.shownItems))
        let w = HandoffItemLine.refWidth(m.items)
        let rows = VStack(spacing: 0) {
            ForEach(shown) { i in
                SettingsLine(padding: PanelMetrics.rowPadding) { HandoffItemLine(item: i, refWidth: w) }
            }
        }
        return PanelBox {
            // past seven rows the list scrolls inside the box
            if shown.count > 7 { ScrollView { rows }.frame(height: 7 * Self.rowHeight) } else { rows }
            if m.items.count > shown.count || allItems && m.items.count > Self.shownItems + 1 {
                SettingsLine(padding: PanelMetrics.rowPadding) {
                    Button {
                        withAnimation(PanelMetrics.change) { allItems.toggle() }
                    } label: {
                        Text(allItems ? TL("handoff.items.fewer") : TL("handoff.items.more", m.items.count - Self.shownItems))
                            .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandInk)
                            .padding(.leading, KindStyle.smallSize + 8)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// A row of the items box: 13 pt text with 6 pt above and below, and the hairline.
    static let rowHeight: CGFloat = 29

    /// New Session: the project as a pull-down on the title's line, the list with a check per row (the whole row is
    /// the target) and Select All over its right end.
    var picker: some View {
        let w = HandoffItemLine.refWidth(m.candidates)
        let all = !m.candidates.isEmpty && m.chosen.count == m.candidates.count
        return PanelBox(heading: AnyView(projectMenu)) {
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
                        SettingsLine(padding: 4) {
                            HStack(spacing: 8) {
                                Toggle("", isOn: Binding(get: { on }, set: { pick(c.uid, $0) })).toggleStyle(.checkbox).labelsHidden()
                                    .accessibilityLabel("\(c.ref) \(c.title)")
                                HandoffItemLine(item: c, refWidth: w)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { pick(c.uid, !on) }
                        }
                    }
                }
            }
            .frame(height: CGFloat(min(max(m.candidates.count, 3), 7)) * Self.pickRow)
        } accessory: {
            if !m.candidates.isEmpty {
                Button(TL(all ? "handoff.pick.none" : "handoff.pick.all")) {
                    m.chosen = all ? [] : Set(m.candidates.map(\.uid))
                }
                .buttonStyle(.plain).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandInk)
            }
        }
    }

    /// A picker row (a checkbox's height and 4 pt above and below); the list shows three to seven, then scrolls.
    static let pickRow: CGFloat = 24

    func pick(_ uid: String, _ on: Bool) {
        if on { m.chosen.insert(uid) } else { m.chosen.remove(uid) }
    }

    var projectMenu: some View {
        let name = m.projectID.flatMap { ProjectStore.shared.project(id: $0)?.name } ?? TL("dispatch.project")
        return Menu {
            ForEach(ProjectStore.shared.projects) { p in
                Button { m.projectID = p.id } label: {
                    if p.id == m.projectID { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
        } label: {
            // the list's heading: whose items these are, and where to pick another project
            HStack(spacing: 5) {
                Image(systemName: "folder")
                Text(name).lineLimit(1).truncationMode(.middle)
            }
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 300, alignment: .leading)
        .help(name)
        .accessibilityLabel(TL("dispatch.project"))
        .accessibilityValue(name)
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

    var agentRow: some View {
        SettingRow("handoff.agent", title: TL("dispatch.agent"), detailContent: AnyView(agentDetail)) {
            Group {
                if !m.agents.isEmpty {
                    ChoicePopup(label: TL("dispatch.agent"),
                                choices: m.agents.map { a in (a.id, a.loggedOut && a.id != m.agent ? Loc.t("dispatch.agent.logged_out", table: "Terminal", a.name) : a.name) },
                                selection: Binding(get: { m.agent }, set: { m.agent = $0; m.agentTouched = true }))
                }
            }
        }
    }

    /// One signal, in its row: checking (the spinner and the words), not signed in (what to run, in attention ink),
    /// else what the session will run: the model, or the desktop app it opens in.
    @ViewBuilder var agentDetail: some View {
        Group {
            if !m.agentsLoaded || (!m.agents.isEmpty && !m.loginChecked && !m.desktop) {
                HStack(spacing: 5) { BrandSpinnerView(size: 10); Text(TL("dispatch.checking_login")) }
                    .foregroundStyle(.secondary)
            } else if m.agents.isEmpty {
                Text(TL("dispatch.agent.none")).foregroundStyle(Color.brandAttnInk)
            } else if let a = m.chosenAgent, a.loggedOut, !m.desktop {
                VStack(alignment: .leading, spacing: 3) {
                    Text(a.fix.isEmpty ? TL("dispatch.logged_out", a.name) : TL("dispatch.logged_out.fix", a.name, a.fix))
                        .foregroundStyle(Color.brandAttnInk).textSelection(.enabled)
                    // the way on from here: the other agent, as a text button in brand ink (Settings' link look)
                    if let other = m.alternative {
                        Button(TL("dispatch.use_agent", other.name)) { m.agent = other.id; m.agentTouched = true }
                            .buttonStyle(.plain).foregroundStyle(Color.brandInk)
                    }
                }
            } else if m.desktop {
                Text(TL("handoff.agent.desktop", DesktopApp.name(m.agent))).foregroundStyle(.secondary)
            } else {
                Text(modelSummary).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: SettingsMetrics.detailSize))
        .fixedSize(horizontal: false, vertical: true)
    }

    var modelSummary: String {
        if !m.model.isEmpty { return m.models.first { $0.id == m.model }?.name ?? m.model }
        return m.cliDefault.map { TL("handoff.agent.model_default_named", $0) } ?? TL("handoff.agent.model_default")
    }

    var noGit: Bool { m.warnings.contains { $0.code == "no_git" } }

    var branchRow: some View {
        let detail: String = {
            if noGit { return TL("handoff.branch.no_git") }
            if m.mode == .parallel && m.count > 1 { return TL("handoff.branch.parallel") }
            if m.worktreeOn { return m.branchPreview.map { TL("handoff.branch.on.named", $0) } ?? TL("handoff.branch.on") }
            return TL("handoff.branch.off")
        }()
        return SettingRow("handoff.branch", title: TL("handoff.branch"), detail: detail) {
            Toggle(TL("handoff.branch"), isOn: Binding(get: { m.worktreeOn && !noGit }, set: { m.worktree = $0 ? .on : .off }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .disabled(m.mode == .parallel && m.count > 1 || noGit)
        }
        .help(TL("handoff.branch.help"))
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
                                   detail: m.desktop ? TL("dispatch.desktop.send", app) : TL("handoff.run_in.terminal.detail")) {
                            ChoicePopup(label: TL("handoff.run_in"),
                                        choices: [(HandoffTarget.terminal, TL("handoff.run_in.terminal")),
                                                  (.desktop, TL("handoff.run_in.desktop", app))],
                                        selection: $m.target)
                        }
                    }
                    if !m.models.isEmpty && !m.desktop {
                        SettingRow("handoff.model", title: TL("dispatch.model")) {
                            ChoicePopup(label: TL("dispatch.model"),
                                        choices: [("", m.cliDefault.map { TL("handoff.model.default_named", $0) } ?? TL("handoff.model.default"))]
                                            + m.models.map { ($0.id, $0.name) },
                                        selection: $m.model, dividers: [1])
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: notices

    /// Only what has to be read before Start: why it can't start (and the way out), the concurrent-edit choice, the
    /// desktop app without the blurt MCP, items taken back from an ended session, no tmux. One notice look (Settings').
    @ViewBuilder var notices: some View {
        if case .failed(let why) = m.phase {
            SettingsNotice(title: why, tone: .warn) {
                if let j = m.busyJob {
                    Button(TL("dispatch.open_session")) { close(); TerminalModule.reveal(job: j) }.controlSize(.small)
                }
            }
            .padding(.top, 14).transition(.opacity)
        }
        if m.concurrent != nil && !m.worktreeOn {
            SettingsNotice(title: TL("warning.concurrent_edit", m.projectName), tone: .warn) { EmptyView() }
                .padding(.top, 14).transition(.opacity)
        }
        if m.desktop && m.desktopMCP == false {
            SettingsNotice(title: TL("dispatch.desktop.no_mcp", DesktopApp.name(m.agent)), tone: .off) {
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
            SettingsNotice(title: TL(w.noteKey), tone: .off) { EmptyView() }.padding(.top, 14)
        }
    }

    // MARK: footer

    var footnote: String? {
        if m.pickItems && m.count == 0 { return TL("handoff.pick.hint") }
        if m.desktop { return TL("dispatch.desktop.send", DesktopApp.name(m.agent)) }
        if let w = m.warnings.first(where: { $0.code == "draft_confirmed" }) {
            let refs = w.items.compactMap { uid in (m.pickItems ? m.candidates : m.items).first { $0.uid == uid }?.ref }
            if m.count == 1 || refs.count == 1, let r = refs.first ?? (m.count == 1 ? m.items.first?.ref : nil) {
                return TL("handoff.note.todo.one", r)
            }
            return TL("handoff.note.todo.many")
        }
        return nil
    }

    var footer: some View {
        let concurrentAsk = m.concurrent != nil && !m.worktreeOn
        return HStack(spacing: 8) {
            PanelFootnote(text: footnote, busy: m.phase == .starting ? TL("handoff.starting") : nil)
            Button(TL("common.cancel"), action: close).keyboardShortcut(.cancelAction)
            if concurrentAsk {
                // the reminder's two answers are the footer's buttons while it is up
                Button(TL("warning.concurrent_edit.continue")) { Task { if let r = await m.start() { started(r) } } }
                    .disabled(!m.canStart)
                Button(TL("warning.concurrent_edit.use_worktree")) { m.worktree = .on }
                    .panelDefault().keyboardShortcut(.defaultAction)
            } else {
                Button(m.desktop ? TL("dispatch.start.desktop", DesktopApp.name(m.agent)) : TL("dispatch.start")) { Task { if let r = await m.start() { started(r) } } }
                    .panelDefault().keyboardShortcut(.defaultAction)
                    .disabled(!m.canStart)
            }
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
