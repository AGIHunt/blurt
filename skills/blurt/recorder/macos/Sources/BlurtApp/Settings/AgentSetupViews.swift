// "Set Up with Agent…" (docs/design/agent-setup.md §4): beside Add Service… in Settings → Models → Cloud services and
// beside Add… on onboarding's cloud row, on every Mac. The sheet's main way is an instruction to copy into any agent
// the user has (Claude Code, Codex, Cursor, WorkBuddy… — no agent to detect or launch); its first change makes Blurt
// ask Allow. Once the user clicks Allow, the page lists what the agent did as it happens (AgentSetupProgress, fed by
// App/AgentSetupServer.swift): a service connected, a job's model, a download, the test dictation; Stop closes the
// grant.
import AppKit
import Combine
import SwiftUI
import BlurtCore

/// The live list, and the Allow window it belongs to.
@MainActor
final class AgentSetupProgress: ObservableObject {
    static let shared = AgentSetupProgress()

    @Published private(set) var steps = AgentSetupSteps()
    /// the agent's name ("Claude Code"); nil: not known (Allow from a process that isn't a known agent)
    @Published private(set) var agentName: String?
    /// changes may happen now (the Allow window is open)
    @Published private(set) var active = false
    private var allowTimer: Timer?
    private var downloads: AnyCancellable?

    var visible: Bool { active || !steps.steps.isEmpty }

    /// The user clicked Allow for an agent of their own.
    func allowed(agent name: String?) {
        if !active {
            // a new Allow window after an ended one: its rows go
            steps.clear()
            agentName = name
            active = true
        }
        allowTimer?.invalidate()
        allowTimer = Timer.scheduledTimer(withTimeInterval: AgentSetupGrant.approvalTTL, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.ended() }
        }
        watchDownloads()
    }

    func record(_ s: AgentSetupStep) { steps.record(s) }

    /// Stop: nothing may change things until asked again.
    func stop() {
        AgentSetupServer.revokeAll()
        emit(["event": "agent_setup_stop"])
        ended()
    }

    /// The list goes once the user has read it.
    func dismiss() {
        steps.clear()
        agentName = nil
    }

    private func ended() {
        active = false
        allowTimer?.invalidate()
        allowTimer = nil
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

/// "Set Up with Agent…" and its sheet, on every Mac: the instruction goes to any agent the user has.
struct AgentSetupButton: View {
    enum Look { case settings, onboarding }
    var look: Look = .settings
    @State private var sheet = false

    var body: some View {
        Group {
            switch look {
            case .settings:
                Button(M("models.agent.button")) { sheet = true }.buttonStyle(SettingsOutlinedButtonStyle())
            case .onboarding:
                Button(M("models.agent.button")) { sheet = true }.controlSize(.small)
            }
        }
        .sheet(isPresented: $sheet) { AgentSetupSheet { sheet = false }.buttonStyle(.automatic) }
    }
}

/// The instruction to paste into the user's own agent (Claude Code, Codex, Cursor, WorkBuddy…): the setup guide and
/// setup.py by absolute path. Its first change makes Blurt ask Allow (AgentSetupServer), and the page lists what it
/// does.
enum AgentSetupInstruction {
    static var text: String {
        let skill = BlurtPaths.skillDir
        return M("models.agent.prompt", skill.appendingPathComponent("reference/setup-models.md").path,
                 skill.appendingPathComponent("scripts/setup.py").path)
    }
}

struct AgentSetupSheet: View {
    var close: () -> Void
    @State private var copied = false
    private let instruction = AgentSetupInstruction.text

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(M("models.agent.sheet.title")).font(.system(size: 15, weight: .semibold))
            Text(M("models.agent.sheet.detail")).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(instruction).font(.system(size: 12)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .frame(height: 118)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
            Text(M("models.agent.note")).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button(M(copied ? "models.sheet.done" : "models.cancel")) { close() }.keyboardShortcut(.cancelAction)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(instruction, forType: .string)
                    copied = true
                    emit(["event": "agent_setup_copied"])
                } label: {
                    Label(M(copied ? "models.agent.sheet.copied" : "models.agent.sheet.copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// The live list: a heading line (who, Stop, Done once it is over), then one line per thing done.
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
                    Text(p.title).font(.system(size: SettingsMetrics.titleSize))
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
