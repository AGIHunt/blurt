// The setup assistant (§2.2), at most four steps, every one skippable:
//   1. permissions — Screen Recording, Microphone, Accessibility, Input Monitoring, live, and "Set Up Permissions":
//      the permission guide (PermissionGuide.swift) walks the missing ones with the helper panel next to System
//      Settings; the dictation key (Fn first) is picked here too, since Fn adds a step (macOS's own 🌐 action);
//   2. uv + Python — found, or installed into ~/.blurt/bin with the user's consent (the official installer), then the
//      scripts' dependencies warmed up so the first real run doesn't wait;
//   3. a speech model — the recommended one for the user's language, downloaded with progress;
//   4. agents — which are installed / logged in, and the blurt skill + MCP installed into one (preview first).
// Shown once on first launch (config app.onboarded), again from Settings → General or blurt://onboarding.
import AppKit
import SwiftUI
import BlurtCore

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var step = 0
    @Published var uv: String? = ScriptRunner.shared.uvPath
    @Published var installingUV = false
    @Published var uvLog: [String] = []
    @Published var warm: String?            // nil | "running" | "done" | error text
    @Published var dictationKey = Dictation.key

    func setKey(_ k: DictationTrigger.Key) {
        dictationKey = k
        Dictation.set("key", k.rawValue)
        Dictation.shared.apply()
        emit(["event": "dictation_setting", "key": "key", "value": k.rawValue, "via": "onboarding"])
    }
    let steps = 4
    var close: () -> Void = {}

    func finish() {
        Config.shared.set("app.onboarded", true)
        close()
    }

    static let uvInstallCommand = "curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=\"$HOME/.blurt/bin\" UV_NO_MODIFY_PATH=1 sh"

    /// Only after the user pressed the button that shows this exact command.
    func installUV() {
        installingUV = true
        uvLog = []
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        var env = ShellEnv.agentEnvironment()
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        // ~/.blurt/bin follows BLURT_HOME, like everything else
        p.arguments = ["-c", OnboardingModel.uvInstallCommand.replacingOccurrences(of: "$HOME/.blurt", with: BlurtPaths.home.path)]
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        streamLines(p) { [weak self] line, _ in self?.uvLog.append(line) }
        p.terminationHandler = { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self else { return }
                self.installingUV = false
                self.uv = ScriptRunner.shared.uvPath
                if self.uv != nil { self.warmUp() }
            }
        }
        do { try p.run() } catch { installingUV = false; uvLog.append("\(error)") }
    }

    /// Pre-installs the scripts' dependencies (numpy, sherpa-onnx…) and builds the search index.
    func warmUp() {
        guard warm != "running" else { return }
        warm = "running"
        Task {
            do {
                let a = try await SkillCLI.shared.run("transcribe.py", ["backends"], timeout: 600)
                let b = try await SkillCLI.shared.run("index.py", ["scan"], timeout: 300)
                warm = a.ok && b.ok ? "done" : (a.ok ? b.errorText : a.errorText)
            } catch { warm = "\(error)" }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var m: OnboardingModel
    @StateObject var perms = Permissions()
    @ObservedObject var speech = SpeechModel.shared
    @ObservedObject var agents = AgentsModel.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                // the chick hatches to say hello, and hops when everything is set up (the mascot, Icons/Mascot.swift)
                MascotImage(clip: m.step == m.steps - 1 ? .happy : .hatching, then: .idle, size: 64)
                    .frame(width: 64, height: 64).padding(-6)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(T("onboarding.welcome_blurt")).font(.title2.weight(.semibold))
                    Text(T("onboarding.four_quick_steps_talk"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 16)

            HStack(spacing: 6) {
                ForEach(0..<m.steps, id: \.self) { i in
                    Capsule().fill(i <= m.step ? Color.accentColor : Color(nsColor: .quaternaryLabelColor)).frame(height: 4)
                }
            }.padding(.horizontal, 28)

            Group {
                switch m.step {
                case 0: permissions
                case 1: python
                case 2: model
                default: agentsStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 28).padding(.vertical, 18)

            Divider()
            HStack {
                Button(T("onboarding.skip_setup")) { m.finish() }.buttonStyle(.link)
                Spacer()
                if m.step > 0 { Button(T("onboarding.back")) { m.step -= 1 } }
                Button(m.step == m.steps - 1 ? T("onboarding.done") : T("onboarding.next")) {
                    if m.step == m.steps - 1 { m.finish() } else { m.step += 1 }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28).padding(.vertical, 14)
        }
        .frame(width: 640, height: 600)
        .onAppear { perms.start() }
        .onDisappear { perms.stop() }
    }

    func title(_ n: Int, _ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(T("onboarding.step", "\(n)") + t).font(.headline)
            Text(sub).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 10)
    }

    var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            title(1, T("onboarding.permissions"), T("onboarding.permissions_detail"))
            PermissionSetupButton(flow: .all, source: .onboarding, p: perms)
            GroupBox { VStack(spacing: 10) { PermissionRows(p: perms, source: .onboarding) }.padding(4) }
            HStack(spacing: 10) {
                Text(T("onboarding.dictation_key"))
                Picker("", selection: Binding(get: { m.dictationKey }, set: { m.setKey($0) })) {
                    ForEach(DictationTrigger.Key.allCases, id: \.self) { k in Text(Dictation.keyName(k)).tag(k) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
                Spacer()
            }
            Text(m.dictationKey == .fn ? T("onboarding.dictation_key.fn") : T("onboarding.dictation_key.other", Dictation.keyInline(m.dictationKey)))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if m.dictationKey == .fn, !SystemAccess.fnClashApps.isEmpty {
                Text(T("dictation.settings.fn_clash", SystemAccess.fnClashApps.joined(separator: T("settings.perm.list_sep"))))
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var python: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(2, T("onboarding.python_uv"), T("onboarding.processing_search_speech_recognition"))
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        StatusDot(tone: m.uv != nil ? .good : .warn)
                        Text(m.uv.map { T("onboarding.uv_found") + ($0 as NSString).abbreviatingWithTildeInPath } ?? T("onboarding.uv_not_found"))
                        Spacer()
                    }
                    if m.uv == nil {
                        Text(T("onboarding.your_ok_blurt_runs"))
                            .font(.callout).foregroundStyle(.secondary)
                        CommandText(text: OnboardingModel.uvInstallCommand)
                        HStack {
                            Button(T("onboarding.install_uv")) { m.installUV() }.disabled(m.installingUV)
                            if m.installingUV { ProgressView().controlSize(.small) }
                        }
                        if !m.uvLog.isEmpty { Text(m.uvLog.suffix(3).joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    } else {
                        HStack {
                            switch m.warm {
                            case nil: Button(T("onboarding.warm_up_dependencies")) { m.warmUp() }
                                      Text(T("onboarding.fetches_scripts_packages_now")).font(.caption).foregroundStyle(.secondary)
                            case "running"?: ProgressView().controlSize(.small); Text(T("onboarding.preparing_about_minute_first")).foregroundStyle(.secondary)
                            case "done"?: Label(T("onboarding.dependencies_ready_index_built"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            case let e?: Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3)
                            }
                        }
                    }
                }.padding(6)
            }
        }
    }

    var recommended: ASRModel? { speech.models.first { $0.isDefault == true } ?? speech.models.first(where: \.local) }

    var model: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(3, T("onboarding.speech_model"), T("onboarding.turns_your_narration_into"))
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if m.uv == nil {
                        Text(T("onboarding.needs_uv_first_previous")).foregroundStyle(.secondary)
                    } else if let r = recommended {
                        HStack {
                            StatusDot(tone: r.installed ? .good : .warn)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("SenseVoice Small").fontWeight(.medium)
                                Text("\(Int(r.sizeMB)) MB · " + r.languages.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if r.installed { Label(T("onboarding.downloaded"), systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                            else if speech.download[r.id] == nil { Button(T("onboarding.download")) { speech.startDownload(r) } }
                        }
                        if let d = speech.download[r.id] {
                            ProgressView(value: min(d.done, max(d.total, 1)), total: max(d.total, 1)) { Text(d.text).font(.caption) }
                        }
                        Toggle(T("onboarding.download_via_hf_mirror"),
                               isOn: Binding(get: { speech.mirror }, set: { speech.setMirror($0) }))
                    } else {
                        HStack { ProgressView().controlSize(.small); Text(T("onboarding.reading_models")).foregroundStyle(.secondary) }
                    }
                    if let e = speech.error { Text(e).font(.caption).foregroundStyle(.orange) }
                }.padding(6)
            }
            Hint(T("onboarding.you_can_switch_models"))
        }
        .task { if m.uv != nil { await speech.load() } }
    }

    var agentsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(4, T("onboarding.coding_agent"), T("onboarding.blurt_hands_recordings_agent"))
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if agents.loading && agents.rows.isEmpty { HStack { ProgressView().controlSize(.small); Text(T("onboarding.looking_agents")).foregroundStyle(.secondary) } }
                    ForEach(agents.rows.filter { $0.installed }) { a in
                        HStack {
                            StatusDot(tone: a.state == "ready" ? .good : a.state == "logged_out" ? .bad : .warn)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.name)
                                Text(a.why.isEmpty ? a.state : a.why).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if agents.installing == a.id { ProgressView().controlSize(.small) }
                            else { Button(T("onboarding.install_skill_mcp")) { Task { await agents.preview(a) } } }
                        }
                    }
                    if !agents.loading && agents.rows.filter(\.installed).isEmpty {
                        Text(T("onboarding.no_claude_code_codex")).foregroundStyle(.secondary)
                    }
                }.padding(6)
            }
        }
        .task { if agents.rows.isEmpty { await agents.load() } }
        .sheet(isPresented: Binding(get: { agents.plan != nil }, set: { if !$0 { agents.plan = nil } })) {
            if let p = agents.plan { InstallSheet(m: agents, agent: p.agent, plan: p.plan, applied: p.applied) }
        }
    }
}

final class Onboarding: NSObject, NSWindowDelegate {
    static let shared = Onboarding()
    private var window: NSWindow?
    private var model: OnboardingModel?

    static var needed: Bool { Config.shared["app.onboarded"] as? Bool != true }

    func show(step: Int = 0) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.present(step) } }
    }

    @MainActor
    private func present(_ step: Int) {
        if let w = window {
            model?.step = step
            activateApp(); w.makeKeyAndOrderFront(nil); return
        }
        let m = OnboardingModel()
        m.step = step
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = T("onboarding.set_up_blurt")
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.sharingType = ProcessInfo.processInfo.environment["BLURT_DEBUG_CHROME"] == nil ? .none : .readOnly
        m.close = { [weak w] in w?.close() }
        w.contentViewController = NSHostingController(rootView: OnboardingView(m: m))
        w.center()
        window = w
        model = m
        activateApp()
        w.makeKeyAndOrderFront(nil)
        emit(["event": "onboarding", "step": step])
    }

    func windowWillClose(_ notification: Notification) {
        Config.shared.set("app.onboarded", true)     // closing it counts as "skip"
        window = nil
        model = nil
    }

    var windowNumber: Int? { window?.windowNumber }

    /// Back to the front as it was (the permission guide finished), without changing the step.
    @MainActor
    func bringToFront() {
        guard let w = window else { return }
        activateApp()
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()        // even when macOS keeps the focus on System Settings
    }
}
