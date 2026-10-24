// The dispatch panel (AppEnvironment.dispatch, TerminalHosting.newSession): hand items to Claude Code / Codex in a new
// session — which agent, together (one conversation) or in parallel (a window each), in a worktree or in the project
// folder. Every change re-runs `sessions.py dispatch --dry-run`, which says what would happen (branch, folder) and
// warns — never blocks — when another session is already editing the same folder without a worktree (K5 wording).
import AppKit
import SwiftUI
import BlurtCore

struct DispatchItem: Identifiable, Hashable {
    let uid: String
    let ref: String         // BA-12, or a uid prefix while unknown
    let title: String
    var id: String { uid }
}

@MainActor
final class DispatchModel: ObservableObject {
    struct AgentChoice: Identifiable, Hashable { let id: String; let name: String; let installed: Bool; let session: Bool
        var loggedOut = false }
    enum Phase: Equatable { case idle, checking, starting, failed(String) }

    @Published var items: [DispatchItem]
    let pickItems: Bool                         // New Session: the user picks the items
    @Published var projectID: String?
    @Published var candidates: [DispatchItem] = []
    @Published var chosen = Set<String>()
    @Published var loadingCandidates = false
    @Published var candidatesError: String?

    @Published var agents: [AgentChoice] = []
    @Published var agent = ""
    var agentTouched = false                    // the user picked one: login results no longer move it
    /// The chosen agent's models (agents.py models) and the pick: "" = whatever the CLI is set to. Remembered per
    /// project and agent (config sessions.models.<project>.<agent>).
    @Published var models: [AgentModels.Model] = []
    @Published var cliDefault: String?
    @Published var model = ""
    @Published var mode: DispatchMode = .together
    @Published var worktree: WorktreeChoice = .auto
    @Published var warnings: [DispatchWarning] = []
    @Published var preview: [[String: Any]] = []
    @Published var phase: Phase = .idle
    private var checkGen = 0

    init(items: [String], project: String?) {
        self.items = items.map(DispatchModel.label)
        pickItems = items.isEmpty
        projectID = project ?? ProjectStore.shared.currentID ?? ProjectStore.shared.projects.first?.id
    }

    static func label(_ uid: String) -> DispatchItem {
        if let it = IndexLookup.item(uid: uid) { return DispatchItem(uid: uid, ref: it.itemID, title: it.title) }
        return DispatchItem(uid: uid, ref: String(uid.prefix(8)), title: "")
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
                    return DispatchItem(uid: u, ref: it["id"] as? String ?? String(u.prefix(8)), title: it["title"] as? String ?? "")
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
    var canStart: Bool { count > 0 && !agent.isEmpty && phase != .starting && !(agents.first { $0.id == agent }?.session == false) }

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
        // K5: the project's default agent → the global one → the first that is set up; the last one used wins over all
        let saved = Config.shared["sessions.agent"] as? String
        let projectDefault = projectID.flatMap { ProjectStore.shared.project(id: $0)?.defaultAgent }
        let globalDefault = Config.shared["record.default_agent"] as? String
        let order = [saved, projectDefault, globalDefault, d?.pick, list.first?.id].compactMap { $0 }
        agent = order.first { id in list.contains { $0.id == id } } ?? ""
        if pickItems { await loadCandidates() } else { await loadLabels() }
        await loadModels()
        await check()
        // the quick detect can't tell who is logged in; the full one (a few seconds) can: never default to an agent
        // that would stop at its login screen, and say so next to its name
        if let full = try? await Agents.shared.detect(login: true) {
            let out = Set(full.agents.filter { $0.state == "logged_out" }.map(\.id))
            agents = agents.map { var a = $0; a.loggedOut = out.contains(a.id); return a }
            if !agentTouched, out.contains(agent),
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
                return DispatchItem(uid: uid, ref: $0["id"] as? String ?? String(uid.prefix(8)), title: $0["title"] as? String ?? "")
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
        do {
            let r = try await AgentSessions.shared.dispatch(items: selected, agent: agent.isEmpty ? nil : agent, mode: mode,
                                                            worktree: mode == .parallel ? .on : worktree, dryRun: true, model: model)
            guard gen == checkGen else { return }
            warnings = r.warnings
            preview = r.rows
            if phase == .checking { phase = .idle }
        } catch {
            guard gen == checkGen else { return }
            warnings = []
            preview = []
            phase = .failed(sessionsErrorText(error))
        }
    }

    func start() async -> DispatchResult? {
        phase = .starting
        Config.shared.set("sessions.agent", agent)
        rememberModel()
        do {
            let r = try await AgentSessions.shared.dispatch(items: selected, agent: agent, mode: mode,
                                                            worktree: mode == .parallel ? .on : (worktree == .auto ? (worktreeOn ? .on : .off) : worktree),
                                                            dryRun: false, model: model)
            for l in r.launch { AppRunner.shared.launch(l) }
            emit(["event": "dispatch", "jobs": r.jobs, "warnings": r.warnings.map(\.code), "app_runner": r.launch.count,
                  "agent": agent, "model": model.isEmpty ? NSNull() : model])
            phase = .idle
            return r
        } catch {
            phase = .failed(sessionsErrorText(error))
            return nil
        }
    }
}

struct DispatchView: View {
    @ObservedObject var m: DispatchModel
    var close: () -> Void
    var started: (DispatchResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "paperplane").font(.system(size: 20, weight: .regular)).foregroundStyle(Color.brandInk)
                    .frame(width: 34, height: 34).background(Circle().fill(Color.brandTint))
                VStack(alignment: .leading, spacing: 2) {
                    Text(TL("dispatch.title")).font(.title3.weight(.semibold))
                    Text(m.count == 0 ? TL("dispatch.subtitle.none")
                         : m.projectName.isEmpty ? Loc.plural("dispatch.count", table: "Terminal", count: m.count)
                         : Loc.plural("dispatch.subtitle", table: "Terminal", count: m.count, m.projectName))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if m.pickItems { picker } else { itemList(m.items) }

            VStack(alignment: .leading, spacing: 12) {
                field(TL("dispatch.agent")) {
                    if m.agents.isEmpty {
                        Text(TL("dispatch.agent.none")).foregroundStyle(.secondary).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Picker("", selection: Binding(get: { m.agent }, set: { m.agent = $0; m.agentTouched = true })) {
                            ForEach(m.agents) { a in
                                Text(a.loggedOut ? Loc.t("dispatch.agent.logged_out", table: "Terminal", a.name) : a.name).tag(a.id)
                            }
                        }
                            .labelsHidden().fixedSize()
                    }
                }
                if !m.models.isEmpty {
                    field(TL("dispatch.model")) {
                        Picker("", selection: $m.model) {
                            Text(m.cliDefault.map { TL("dispatch.model.default_named", $0) } ?? TL("dispatch.model.default")).tag("")
                            Divider()
                            ForEach(m.models) { x in Text(x.name).tag(x.id) }
                        }
                        .labelsHidden().fixedSize()
                        .accessibilityLabel(TL("dispatch.model"))
                    }
                }
                if m.count > 1 {
                    field(TL("dispatch.mode")) {
                        Picker("", selection: $m.mode) {
                            Text(TL("dispatch.mode.together")).tag(DispatchMode.together)
                            Text(TL("dispatch.mode.parallel")).tag(DispatchMode.parallel)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        Text(m.mode == .together ? TL("dispatch.mode.together.help") : Loc.plural("dispatch.mode.parallel.help", table: "Terminal", count: m.count))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                field(TL("dispatch.worktree")) {
                    Toggle(TL("dispatch.worktree.toggle"), isOn: Binding(get: { m.worktreeOn }, set: { m.worktree = $0 ? .on : .off }))
                        .disabled(m.mode == .parallel)
                    Group {
                        if m.worktreeOn {
                            if m.mode == .parallel && m.count > 1 {
                                Text(TL("dispatch.worktree.on.parallel"))      // a branch each: naming the first one misleads
                            } else if let b = m.branchPreview { Text(TL("dispatch.worktree.on.branch", b)) } else { Text(TL("dispatch.worktree.on")) }
                        } else {
                            Text(TL("dispatch.worktree.off", m.projectName))
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            // codes this version has no sentence for are left out rather than shown raw
            ForEach(m.warnings.filter { $0.code != "concurrent_edit" && TL("warning.\($0.code)") != "warning.\($0.code)" }, id: \.code) { w in
                Label(TL("warning.\(w.code)"), systemImage: w.code == "no_tmux" ? "info.circle" : "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if m.concurrent != nil && !m.worktreeOn { concurrentCallout }

            if case .failed(let why) = m.phase {
                Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(Color.brandAttnInk).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if m.phase == .checking || m.phase == .starting { ProgressView().controlSize(.small) }
                Spacer()
                Button(TL("common.cancel"), action: close).keyboardShortcut(.cancelAction)
                // while the concurrent-edit reminder is up, its two buttons are the choice
                if !(m.concurrent != nil && !m.worktreeOn) {
                    Button(TL("dispatch.start")) { Task { if let r = await m.start() { started(r) } } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!m.canStart)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 20)
        .frame(width: 500)
        .task { await m.load() }
        .onChange(of: m.agent) { _ in Task { await m.loadModels(); await m.check() } }
        .onChange(of: m.model) { _ in Task { await m.check() } }
        .onChange(of: m.mode) { _ in Task { await m.check() } }
        .onChange(of: m.worktree) { _ in Task { await m.check() } }
        .onChange(of: m.chosen) { _ in Task { await m.check() } }
        .onChange(of: m.projectID) { _ in Task { await m.loadCandidates(); await m.check() } }
    }

    /// A label column of fixed width and a content column that fills the rest (wrapping text needs a known width).
    func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).foregroundStyle(.secondary).frame(width: 76, alignment: .trailing)
            VStack(alignment: .leading, spacing: 5) { content() }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var concurrentCallout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(AgentSessionStatus.waitingInput.color)
                Text(TL("warning.concurrent_edit", m.projectName)).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(TL("warning.concurrent_edit.continue")) { Task { if let r = await m.start() { started(r) } } }
                    .disabled(!m.canStart)
                Button(TL("warning.concurrent_edit.use_worktree")) { m.worktree = .on }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(AgentSessionStatus.waitingInput.color.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AgentSessionStatus.waitingInput.color.opacity(0.35)))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    func itemList(_ items: [DispatchItem]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items.prefix(4)) { i in
                HStack(spacing: 8) {
                    Text(i.ref).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                    Text(i.title.isEmpty ? i.uid : i.title).lineLimit(1)
                }.font(.callout)
            }
            if items.count > 4 {
                Text(Loc.plural("dispatch.items.more", table: "Terminal", count: items.count - 4)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35)))
    }

    var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(TL("dispatch.project"), selection: $m.projectID) {
                ForEach(ProjectStore.shared.projects) { Text($0.name).tag(Optional($0.id)) }
            }
            .fixedSize()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if m.loadingCandidates { ProgressView().controlSize(.small) }
                    if let e = m.candidatesError { Text(e).font(.caption).foregroundStyle(.secondary) }
                    if !m.loadingCandidates && m.candidates.isEmpty && m.candidatesError == nil {
                        Text(TL("dispatch.pick.empty")).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(m.candidates) { c in
                        Toggle(isOn: Binding(get: { m.chosen.contains(c.uid) }, set: { on in if on { m.chosen.insert(c.uid) } else { m.chosen.remove(c.uid) } })) {
                            HStack(spacing: 8) {
                                Text(c.ref).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                                Text(c.title).lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35)))
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
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled, .closable],
                        backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.isFloatingPanel = true
        w.title = TL("dispatch.title")
        let started: (DispatchResult) -> Void = { [weak w] r in
            w?.close()
            if let j = r.jobs.first { TerminalModule.reveal(job: j) }
        }
        current = (m, { Task { @MainActor in if let r = await m.start() { started(r) } } })
        let host = NSHostingController(rootView: DispatchView(m: m, close: { [weak w] in w?.close() }, started: started))
        host.sizingOptions = [.preferredContentSize]
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
