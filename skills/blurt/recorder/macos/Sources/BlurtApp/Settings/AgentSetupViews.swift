// "Set Up with Agent…" (docs/design/agent-setup.md §4): beside Add Service… in Settings → Models → Cloud services and
// beside Add… on onboarding's cloud row, only when an agent that runs as a session is installed (agents.py detect +
// sessions.py doctor, as the hand-off panel reads them). The sheet picks the agent; Start runs `sessions.py
// setup-session` — the agent in Blurt's terminal (tmux, or the app's own pty) on the setup prompt, with a token for
// the control socket in its environment — and shows that terminal. While it works, the page lists what it did as it
// happens (AgentSetupProgress, fed by App/AgentSetupServer.swift): a service connected, a job's model, a download, the
// test dictation; Stop ends the session and closes the grant. An agent the user started on their own gets the same
// list once the user clicks Allow.
import AppKit
import Combine
import SwiftUI
import BlurtCore

/// The live list, and the session or Allow window it belongs to.
@MainActor
final class AgentSetupProgress: ObservableObject {
    static let shared = AgentSetupProgress()

    @Published private(set) var steps = AgentSetupSteps()
    /// the agent's name ("Claude Code"); nil: not known (Allow from a process that isn't a known agent)
    @Published private(set) var agentName: String?
    /// the session "Set Up with Agent…" started (nil: the user's own agent, through Allow)
    @Published private(set) var job: String?
    /// changes may happen now (a session runs, or the Allow window is open)
    @Published private(set) var active = false
    /// Stop couldn't end the session: why
    @Published private(set) var stopError: String?
    private var token: String?
    private var jobObserver: UUID?
    private var allowTimer: Timer?
    private var downloads: AnyCancellable?

    var visible: Bool { active || !steps.steps.isEmpty }

    /// A session the app started.
    func started(agentName name: String, job: String, token: String) {
        if let t = self.token { AgentSetupServer.revoke(t) }
        steps.clear()
        agentName = name; self.job = job; self.token = token; active = true
        watchJob()
        watchDownloads()
    }

    /// The user clicked Allow for an agent of their own.
    func allowed(agent name: String?) {
        if !active || job == nil {
            // a new Allow window after an ended session: that session's rows and job go (Show Terminal pointed at it)
            if !active { steps.clear(); job = nil; stopError = nil }
            agentName = name
            active = true
        }
        allowTimer?.invalidate()
        allowTimer = Timer.scheduledTimer(withTimeInterval: AgentSetupGrant.approvalTTL, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if self?.job == nil { self?.ended() } }
        }
        watchDownloads()
    }

    func record(_ s: AgentSetupStep) { steps.record(s) }

    /// Stop: the session ends (as the Sessions pane's Stop), and nothing may change things until asked again.
    func stop() {
        stopError = nil
        if let j = job {
            Task { @MainActor [weak self] in
                // a session that wouldn't stop says why under the heading (its terminal is still there to close)
                do { try await AgentSessions.shared.stop(job: j, kill: false) } catch { self?.stopError = sessionsErrorText(error) }
            }
        }
        AgentSetupServer.revokeAll()
        emit(["event": "agent_setup_stop", "job": job ?? NSNull()])
        ended()
    }

    /// The list goes once the user has read it.
    func dismiss() {
        stopError = nil
        steps.clear()
        agentName = nil
        job = nil
    }

    private func ended() {
        active = false
        if let t = token { AgentSetupServer.revoke(t) }
        token = nil
        allowTimer?.invalidate()
        allowTimer = nil
        if let o = jobObserver { JobStore.shared.removeObserver(o); jobObserver = nil }
    }

    private func watchJob() {
        if let o = jobObserver { JobStore.shared.removeObserver(o) }
        jobObserver = JobStore.shared.addObserver { [weak self] changed in
            MainActor.assumeIsolated {
                guard let self, let j = self.job, let job = changed.first(where: { $0.id == j }), !job.isActive else { return }
                self.ended()
            }
        }
    }

    /// A download the agent started: done once the download manager has it in, failed when it says so.
    private func watchDownloads() {
        guard downloads == nil else { return }
        downloads = ModelDownloads.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.settleDownloads() } }
        }
    }

    private func settleDownloads() {
        let dl = ModelDownloads.shared
        for s in steps.steps where s.state == .running && (s.kind == .download || (s.kind == .use && s.subject == "dictation")) {
            let id = s.kind == .download ? s.subject : (DictationModels.shared.asr?.selected ?? "")
            if dl.failed[s.subject] != nil { var x = s; x.state = .failed; steps.record(x); continue }
            if s.kind == .download ? !dl.queue.contains(id) : !dl.active { var x = s; x.state = .done; steps.record(x) }
        }
    }

    // MARK: the words

    var title: String {
        guard active else { return M("models.agent.ended") }
        return agentName.map { M("models.agent.active", $0) } ?? M("models.agent.active.unknown")
    }

    static func text(_ s: AgentSetupStep) -> String {
        switch (s.kind, s.state) {
        case (.connect, .running): return M("models.agent.step.connecting", s.name)
        case (.connect, .done): return M("models.agent.step.connected", s.name)
        case (.connect, .failed): return M("models.agent.step.connect_failed", s.name)
        case (.use, .failed): return M("models.agent.step.use_failed", jobName(s.subject))
        case (.use, _): return M("models.agent.step.use", jobName(s.subject), s.name)
        case (.download, .running): return M("models.agent.step.downloading", s.name)
        case (.download, .done): return M("models.agent.step.downloaded", s.name)
        case (.download, .failed): return M("models.agent.step.download_failed", s.name)
        case (.verify, .running): return M("models.agent.step.verifying")
        case (.verify, .done): return M("models.agent.step.verified")
        case (.verify, .failed): return M("models.agent.step.verify_failed")
        }
    }

    static func jobName(_ job: String) -> String {
        let row = CloudJob(rawValue: job)?.rowID ?? "speech.dictation"
        return SettingsCatalog.entry(row).map(SettingsCatalog.title) ?? job
    }
}

/// The agents that can run a setup session: installed, with an interactive session (read once, then on each sheet).
@MainActor
final class AgentSetupAgents: ObservableObject {
    static let shared = AgentSetupAgents()
    struct Agent: Identifiable, Hashable { let id: String; let name: String }
    @Published private(set) var list: [Agent] = []
    private var loading = false
    private var loadedAt: Date?

    /// Read again when a page with the button appears, at most once a minute (an agent installed meanwhile shows up).
    func loadIfNeeded() {
        guard !loading, loadedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }
        Task { await load() }
    }

    func load() async {
        loading = true
        async let detect = try? Agents.shared.detect(login: false)
        async let doctor = try? AgentSessions.shared.doctor()
        let (d, doc) = await (detect, doctor)
        list = (d?.agents ?? []).filter { a in a.installed && (doc?.agents[a.id] ?? (a.interactive == "terminal")) }
            .map { Agent(id: $0.id, name: $0.name) }
        loading = false
        loadedAt = Date()
    }
}

/// "Set Up with Agent…" and its sheet. Hidden while no agent can run a session.
struct AgentSetupButton: View {
    enum Look { case settings, onboarding }
    var look: Look = .settings
    @ObservedObject private var agents = AgentSetupAgents.shared
    @ObservedObject private var progress = AgentSetupProgress.shared
    @State private var sheet = false

    var body: some View {
        Group {
            if agents.list.isEmpty {
                // nothing to show, but something to appear: the list is read from here
                Color.clear.frame(width: 0, height: 0)
            } else {
                // one session at a time: a second Start while one runs would leave the first agent working unseen
                // (an Allow window doesn't count: the user may still start a session)
                let running = progress.active && progress.job != nil
                switch look {
                case .settings:
                    Button(M("models.agent.button")) { sheet = true }.buttonStyle(SettingsOutlinedButtonStyle())
                        .disabled(running)
                case .onboarding:
                    Button(M("models.agent.button")) { sheet = true }.controlSize(.small).disabled(running)
                }
            }
        }
        .onAppear { agents.loadIfNeeded() }
        .sheet(isPresented: $sheet) { AgentSetupSheet { sheet = false }.buttonStyle(.automatic) }
    }
}

struct AgentSetupSheet: View {
    var close: () -> Void
    @ObservedObject private var agents = AgentSetupAgents.shared
    @State private var agent = ""
    @State private var starting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(M("models.agent.sheet.title")).font(.system(size: 15, weight: .semibold))
            Text(M("models.agent.sheet.detail")).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text(M("models.agent.sheet.agent")).foregroundStyle(.secondary)
                Picker("", selection: $agent) {
                    ForEach(agents.list) { a in Text(a.name).tag(a.id) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            .padding(.top, 4)
            Text(M("models.agent.note")).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let e = error {
                Text(e).font(.system(size: 12)).foregroundStyle(Color.brandErr).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(M("models.cancel")) { close() }.keyboardShortcut(.cancelAction)
                Button(M("models.agent.sheet.start")) { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(agent.isEmpty || starting)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            let saved = Config.shared["sessions.agent"] as? String
            agent = agents.list.first { $0.id == saved }?.id ?? agents.list.first?.id ?? ""
            Task { await agents.load() }
        }
    }

    private func start() {
        starting = true
        error = nil
        let id = agent
        let token = AgentSetupServer.issueToken()
        Task { @MainActor in
            do {
                let r = try await AgentSessions.shared.setupSession(agent: id, token: token)
                for l in r.launch { AppRunner.shared.launch(l) }
                AgentSetupProgress.shared.started(agentName: AgentNames.name(id), job: r.job, token: token)
                emit(["event": "agent_setup_session", "agent": id, "job": r.job, "app_runner": r.launch.count])
                close()
                TerminalModule.reveal(job: r.job)
            } catch {
                AgentSetupServer.revoke(token)
                self.error = sessionsErrorText(error)
                starting = false
            }
        }
    }
}

/// The live list: a heading line (who, Stop / Show Terminal, Done once it is over), then one line per thing done.
struct AgentSetupProgressView: View {
    enum Look { case settings, onboarding }
    var look: Look = .settings
    @ObservedObject private var p = AgentSetupProgress.shared

    var body: some View {
        if p.visible {
            switch look {
            case .settings: settings
            case .onboarding: onboarding
            }
        }
    }

    @ViewBuilder var settings: some View {
        SettingsLine(flashID: "speech_agent_setup") {
            HStack(alignment: .center, spacing: 14) {
                HStack(alignment: .center, spacing: SettingsMetrics.iconGap) {
                    SettingsIcon("terminal")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).font(.system(size: SettingsMetrics.titleSize))
                        if let e = p.stopError {
                            Text(e).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandErr)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                buttons.buttonStyle(SettingsOutlinedButtonStyle())
            }
        }
        ForEach(p.steps.steps) { s in
            SettingsLine {
                HStack(alignment: .center, spacing: SettingsMetrics.iconGap) {
                    mark(s.state).frame(width: SettingsMetrics.iconSlot)
                    Text(AgentSetupProgress.text(s)).font(.system(size: SettingsMetrics.detailSize))
                        .foregroundStyle(s.state == .failed ? AnyShapeStyle(Color.brandErr) : AnyShapeStyle(.primary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder var onboarding: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(p.title).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                buttons.controlSize(.small)
            }
            if let e = p.stopError { Text(e).font(.system(size: 12)).foregroundStyle(Color.brandErr) }
            // the page doesn't scroll: a long list pushed Back / Next out of the window (dogfood 2026-10-31); Settings
            // keeps every row
            ForEach(p.steps.latest(3)) { s in
                HStack(spacing: 6) {
                    mark(s.state).frame(width: 14)
                    Text(AgentSetupProgress.text(s)).font(.system(size: 12))
                        .foregroundStyle(s.state == .failed ? AnyShapeStyle(Color.brandErr) : AnyShapeStyle(.secondary))
                }
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder var buttons: some View {
        HStack(spacing: 8) {
            if let j = p.job, p.active {
                Button(M("models.agent.show")) { TerminalModule.reveal(job: j) }
            }
            if p.active {
                Button(M("models.agent.stop")) { p.stop() }
            } else {
                Button(M("models.sheet.done")) { p.dismiss() }
            }
        }
    }

    @ViewBuilder func mark(_ s: AgentSetupStep.State) -> some View {
        switch s {
        case .running: BrandSpinnerView(size: 10)
        case .done: Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.brandOk)
        case .failed: Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.brandErr)
        }
    }
}
