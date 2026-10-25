// The setup assistant (docs/design/desktop-app.md §2.2), dictation first — four steps, every one skippable:
//   1. welcome — one line for the three uses (dictate anywhere, snap and voice notes as cards, record and let an Agent
//      fix it) and their keys;
//   2. permissions — what dictation needs: the microphone and Accessibility, live, and "Set Up Permissions" (the brand
//      button while anything is missing): the permission guide's dictation walk (PermissionGuide.swift) with the
//      helper panel next to System Settings; Input Monitoring shows only when it is needed (still missing with
//      Accessibility on or after a walk, or a key other than Fn); with Fn the 🌐 key's row shows (the walk asks for it). The step moves on by itself when the
//      walk ends with everything on. The dictation key (Fn first) is picked here too. Screen Recording is not asked
//      here: the first snap or recording asks for it (the toast's Allow… / the alert start the guide for it);
//   3. models — one "Download recommended models" for this Mac (ModelSetup.swift: dictation, polish, voice notes) with
//      the total size and one progress bar (and Stop); it carries on in the background. uv is found, or — one sentence
//      and a button — installed into ~/.blurt/bin with the user's consent (the official installer); the scripts'
//      dependencies are warmed up in the background as soon as uv is there (only a failure shows: one sentence and
//      Try Again);
//   4. try it — a text box ("tap Fn and say something") that shows a check once the first dictation lands, and "Open
//      Blurt at login" (on the first time: dictation needs Blurt running; reopened later, as it is now); Done applies
//      it and closes.
// Connecting agents (the blurt skill + MCP) is not in the assistant: Settings → Agents.
// Shown once on first launch (config app.onboarded), again from Settings → General or blurt://onboarding.
//
// Look (docs/design/system.md §3.4): a fixed-width hero panel on the left — the field (light) / deep (dark) with grain,
// a soft still spectrum glow behind the mascot (none with Reduce Transparency; the one place the spectrum appears) —
// then the steps: the welcome title in gradient text, step bars in brand ink, one brand primary per step (the step's
// own action while it is still to do, with "Skip for Now" in the footer; else Next / Done). Done closes (the chick is
// already happy on the last step; no bloom).
// Test builds never register a login item (an event says what would have happened) and never ask macOS for anything
// (SystemAccess.swift); BLURT_TEST_WARM_FAIL names a script that stands in for the warm-up's first one (a failure).
import AppKit
import ServiceManagement
import SwiftUI
import BlurtCore

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var step = 0
    @Published var uv: String? = ScriptRunner.shared.uvPath
    @Published var installingUV = false
    @Published var uvFailed = false
    @Published var warm: String?            // nil | "running" | "done" | "failed" (the script's output: the event only)
    @Published var dictationKey = Dictation.key
    /// a dictation walk started here (Input Monitoring's row shows once Accessibility stays off after it)
    @Published var walked = false
    /// "Open Blurt at login" on the last step: on the first time (dictation needs Blurt running); opened again later,
    /// as it is now — Done never turns back on what the user turned off in Settings → General
    @Published var openAtLogin = Onboarding.needed ? true : LoginItem.enabled
    @Published var tryText = ""
    /// the first dictation landed while the last step showed
    @Published var tried = false
    private var tryTimer: Timer?
    private var tryBaseline: String?

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

    /// Done on the last step: "Open Blurt at login" as set, then close.
    func done() {
        if openAtLogin != LoginItem.enabled { LoginItem.set(openAtLogin, via: "onboarding") }
        emit(["event": "onboarding", "done": true, "login": openAtLogin, "tried": tried])
        finish()
    }

    /// The assistant opened (or uv just arrived): the dependencies warm up and the models are read, in the background —
    /// each time, so models installed from Settings meanwhile show as installed (load() skips while a download runs).
    func appear() {
        uv = ScriptRunner.shared.uvPath
        guard uv != nil else { return }
        warmUp()
        Task { await ModelSetup.shared.load() }
    }

    static let heroWidth: CGFloat = 200
    static let contentWidth: CGFloat = 640
    static let height: CGFloat = 600

    static let uvInstallCommand = "curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=\"$HOME/.blurt/bin\" UV_NO_MODIFY_PATH=1 sh"

    /// Only after the user pressed Install uv (its tooltip shows this exact command).
    func installUV() {
        installingUV = true
        uvFailed = false
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        var env = ShellEnv.agentEnvironment()
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        // ~/.blurt/bin follows BLURT_HOME, like everything else
        p.arguments = ["-c", OnboardingModel.uvInstallCommand.replacingOccurrences(of: "$HOME/.blurt", with: BlurtPaths.home.path)]
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        streamLines(p) { line, _ in emit(["event": "onboarding_uv", "line": line]) }
        p.terminationHandler = { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self else { return }
                self.installingUV = false
                self.uv = ScriptRunner.shared.uvPath
                self.uvFailed = self.uv == nil
                self.appear()
            }
        }
        do { try p.run() } catch { installingUV = false; uvFailed = true }
    }

    /// Pre-installs the scripts' dependencies (numpy, sherpa-onnx…) and builds the search index — quietly: only a
    /// failure shows (on the models step: one sentence and Try Again; the script's output goes to the event).
    func warmUp() {
        guard warm != "running", warm != "done" else { return }
        warm = "running"
        Task {
            var error: String?
            do {
                let test = ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1"
                let fail = test ? ProcessInfo.processInfo.environment["BLURT_TEST_WARM_FAIL"] : nil
                let a = try await SkillCLI.shared.run(fail ?? "transcribe.py", ["backends"], timeout: 600)
                let b = try await SkillCLI.shared.run("index.py", ["scan"], timeout: 300)
                if !(a.ok && b.ok) { error = a.ok ? b.errorText : a.errorText }
            } catch let e { error = "\(e)" }
            warm = error == nil ? "done" : "failed"
            emit(["event": "onboarding_warm", "result": warm ?? NSNull(), "error": error ?? NSNull()])
        }
    }

    // MARK: try it

    /// The last step shows: watch for the next dictation to land.
    func startTry() {
        tryBaseline = Dictation.shared.lastResult?["id"] as? String
        tryTimer?.invalidate()
        tryTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTry() }
        }
    }
    func stopTry() { tryTimer?.invalidate(); tryTimer = nil }

    private func checkTry() {
        guard !tried, let r = Dictation.shared.lastResult, r["ok"] as? Bool == true,
              let id = r["id"] as? String, id != tryBaseline else { return }
        tried = true
        stopTry()
        emit(["event": "onboarding_try", "id": id])
    }
}

/// Settings → General's "Open Blurt at login", from the assistant. Test builds never register (a scratch bundle would
/// land in the user's Login Items): the event says what would have happened.
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ on: Bool, via: String) -> String? {
        emit(["event": "login_item", "on": on, "via": via, "test_mode": SystemAccess.testMode])
        if SystemAccess.testMode { return nil }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch { return error.localizedDescription }
    }
}

struct OnboardingView: View {
    @ObservedObject var m: OnboardingModel
    @StateObject var perms = Permissions()
    @ObservedObject var guide = PermissionGuide.shared
    @ObservedObject var models = ModelSetup.shared
    @FocusState private var tryFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            OnboardingHero(m: m)
                .frame(width: OnboardingModel.heroWidth)
                .ignoresSafeArea()          // up under the transparent title bar
            content
                .frame(width: OnboardingModel.contentWidth)
        }
        .frame(width: OnboardingModel.heroWidth + OnboardingModel.contentWidth, height: OnboardingModel.height)
        .onAppear { perms.start(); models.shown = true; m.appear() }
        .onDisappear { perms.stop(); models.shown = false; m.stopTry() }
        .onChange(of: guide.finished) { f in
            // the walk ended with everything dictation needs: on to the models
            guard f != nil, m.step == 1, guide.missing(.dictation).isEmpty else { return }
            emit(["event": "onboarding", "step": 2, "via": "permissions_done"])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if m.step == 1 { m.step = 2 } }
        }
        .onChange(of: m.step) { s in emit(["event": "onboarding", "step": s]) }
    }

    /// The step's own action is still to do: it is the primary, and the footer offers "Skip for Now" instead of Next.
    var pending: Bool {
        switch m.step {
        case 1: return !guide.missing(.dictation).isEmpty
        case 2: return m.uv == nil || (models.loaded && !models.parts.isEmpty && !models.pending.isEmpty && !models.downloading
                                       && !models.settled)
        default: return false
        }
    }

    var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    // a large headline: gradient text (flat brand ink with Increase Contrast)
                    Text(T("onboarding.welcome_blurt")).font(.system(size: 24, weight: .bold)).brandGradientText()
                    Text(T("onboarding.subtitle", Dictation.keyShort(m.dictationKey)))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 16)

            HStack(spacing: 6) {
                ForEach(0..<m.steps, id: \.self) { i in
                    Capsule().fill(i <= m.step ? Color.brandInk : Color(nsColor: .quaternaryLabelColor)).frame(height: 4)
                }
            }.padding(.horizontal, 28)

            Group {
                switch m.step {
                case 0: welcome
                case 1: permissions
                case 2: modelsStep
                default: tryIt
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 28).padding(.vertical, 18)

            Divider()
            HStack {
                Button(T("onboarding.skip_setup")) { m.finish() }.buttonStyle(.link).foregroundStyle(Color.brandInk)
                Spacer()
                if m.step > 0 { Button(T("onboarding.back")) { m.step -= 1 } }
                if pending {
                    Button(T("onboarding.skip_for_now")) { m.step += 1 }
                } else {
                    // the one primary: the brand button
                    Button(m.step == m.steps - 1 ? T("onboarding.done") : T("onboarding.next")) {
                        if m.step == m.steps - 1 { m.done() } else { m.step += 1 }
                    }
                    .buttonStyle(.brand)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 14)
        }
    }

    func title(_ n: Int, _ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(T("onboarding.step", "\(n)") + t).font(.headline)
            Text(sub).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 10)
    }

    func check(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: BlurtIcon.check.symbolImage(pointSize: 13, weight: .semibold)).foregroundStyle(Color.brandOk)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 1 welcome

    var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                VStack(spacing: 12) {
                    use(T("onboarding.use.dictation"), Dictation.keyShort(m.dictationKey))
                    Divider()
                    use(T("onboarding.use.snap"), hk(.snap))
                    Divider()
                    use(T("onboarding.use.voice"), hk(.voice))
                    Divider()
                    use(T("onboarding.use.record"), hk(.toggleRecord))
                }.padding(8)
            }
            Hint(T("onboarding.use.hint"))
        }
    }

    func use(_ what: String, _ key: String) -> some View {
        HStack {
            Text(what)
            Spacer()
            Text(key.trimmingCharacters(in: .whitespaces)).foregroundStyle(.secondary)     // zh short names lead with a space
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 2 permissions

    /// The microphone and Accessibility; Input Monitoring only when dictation needs it: a key other than Fn, or it still
    /// isn't satisfied once Accessibility is on or a walk got past it (with Fn, Accessibility alone hears the key —
    /// Input Monitoring is what's left when Accessibility was turned down or its tap was refused). With Fn, the 🌐 key's
    /// row too. So whatever the walk still asks for has its row here.
    var permissionKinds: [PermissionKind] {
        let pastAccessibility = (m.walked || perms.accessibility == .granted) && !(guide.running && guide.current == .accessibility)
        let im = !guide.satisfied(.inputMonitoring) && (m.dictationKey != .fn || pastAccessibility)
        return [.microphone, .accessibility] + (im ? [.inputMonitoring] : []) + (m.dictationKey == .fn ? [.fnKey] : [])
    }

    var setupButton: some View {
        Button(guide.running ? T("settings.perm.setup_running") : T("settings.perm.setup")) {
            m.walked = true
            guide.start(.dictation, source: .onboarding)
        }
    }

    var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            title(2, T("onboarding.permissions"), T("onboarding.permissions_detail"))
            PermissionDoneBanner()
            if !guide.missing(.dictation).isEmpty {
                setupButton.buttonStyle(.brand).keyboardShortcut(.defaultAction)
            }
            GroupBox { VStack(spacing: 10) { PermissionRows(p: perms, source: .onboarding, kinds: permissionKinds, paneLink: false) }.padding(4) }
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
                    .font(.caption).foregroundStyle(Color.brandAttnInk).fixedSize(horizontal: false, vertical: true)
            }
            Hint(T("onboarding.permissions.screen_later"))
        }
    }

    // MARK: 3 models

    func size(_ mb: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(mb * 1_000_000), countStyle: .file) }

    var modelsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(3, T("onboarding.models"), T("onboarding.models.detail"))
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if m.uv == nil {
                        Text(T("onboarding.uv.needed")).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(T("onboarding.install_uv")) { m.installUV() }
                                .buttonStyle(.brand).keyboardShortcut(.defaultAction)
                                .disabled(m.installingUV).help(OnboardingModel.uvInstallCommand)
                            if m.installingUV { ProgressView().controlSize(.small) }
                        }
                        if m.uvFailed { Text(T("onboarding.uv.failed")).font(.caption).foregroundStyle(Color.brandErr) }
                    } else if !models.loaded {
                        HStack { ProgressView().controlSize(.small); Text(T("onboarding.models.checking")).foregroundStyle(.secondary) }
                    } else if models.parts.isEmpty {
                        Text(T("onboarding.models.unavailable")).foregroundStyle(.secondary)
                        Button(T("onboarding.models.retry")) { Task { await models.load() } }
                    } else {
                        modelRows
                    }
                    if m.warm == "failed" {
                        HStack(spacing: 10) {
                            Text(T("onboarding.warm.failed")).font(.callout).foregroundStyle(Color.brandErr)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(T("onboarding.models.retry")) { m.warmUp() }
                        }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Hint(T("onboarding.models.later"))
        }
    }

    @ViewBuilder var modelRows: some View {
        ForEach(models.parts, id: \.id) { p in
            let have = p.installed || models.finished.contains(p.id)
            HStack(spacing: 10) {
                StatusDot(tone: have ? .good : .warn)
                Text(T("onboarding.models.kind.\(p.kind.rawValue)"))
                Text(p.name).foregroundStyle(.secondary)
                Spacer()
                // only what is still to come down has a size (the total counts just these)
                if !have { Text(size(p.sizeMB)).foregroundStyle(.secondary).monospacedDigit() }
            }
            .accessibilityElement(children: .combine)
        }
        if models.downloading {
            let pr = models.progress
            HStack(alignment: .bottom, spacing: 10) {
                ProgressView(value: pr.done, total: max(pr.total, 1)) {
                    Text(T("onboarding.models.progress", size(pr.done), size(pr.total))).font(.caption).monospacedDigit()
                }
                Button(T("onboarding.models.stop")) { models.cancel() }.controlSize(.small)
            }
            Text(T("onboarding.models.background")).font(.caption).foregroundStyle(.secondary)
        } else if models.ready {
            check(T("onboarding.models.ready"))
        } else if models.failed {
            Text(T("onboarding.models.failed")).font(.callout).foregroundStyle(Color.brandErr).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(T("onboarding.models.retry")) { models.start() }.primary(pending)
                if let f = models.fallback { Button(T("onboarding.models.small", size(f.sizeMB))) { models.start(only: [f]) } }
            }
        } else {
            HStack(spacing: 10) {
                // after the small model alone: still on offer, no longer the step's primary
                Button(T("onboarding.models.download")) { models.start() }.primary(pending)
                Text(T("onboarding.models.total", size(models.totalMB))).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 4 try it

    var tryIt: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(4, T("onboarding.try"), T("onboarding.try.detail", Dictation.keyShort(m.dictationKey)))
            TextField(T("onboarding.try.placeholder"), text: $m.tryText, axis: .vertical)
                .lineLimit(3...5)
                .textFieldStyle(.roundedBorder)
                .focused($tryFocused)
            if m.tried {
                check(T("onboarding.try.works"))
            } else if !guide.missing(.dictation).isEmpty {
                HStack(spacing: 10) {
                    Text(T("onboarding.try.needs_permissions")).foregroundStyle(.secondary)
                    setupButton
                }
            } else if models.downloading {
                Text(T("onboarding.try.downloading")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer().frame(height: 6)
            Toggle(isOn: $m.openAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(T("settings.general.login"))
                    Text(T("onboarding.login.detail")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            m.startTry()
            DispatchQueue.main.async { tryFocused = true }
        }
        .onDisappear { m.stopTry() }
    }
}

private extension View {
    /// The step's own action as the one brand primary (Return presses it), or a plain button.
    @ViewBuilder func primary(_ on: Bool) -> some View {
        if on { buttonStyle(.brand).keyboardShortcut(.defaultAction) } else { self }
    }
}

/// The hero side panel (§3.4): the field with grain, a soft still spectrum glow, the mascot on it — the only place
/// the spectrum appears. Flat field (no grain, no glow) with Reduce Transparency. The chick hatches to say hello and
/// hops on the last step.
struct OnboardingHero: View {
    @ObservedObject var m: OnboardingModel

    var body: some View {
        ZStack {
            BrandField()
            VStack(spacing: 0) {
                Spacer()
                ZStack {
                    SpectrumGlow(size: 150, opacity: 0.5)
                    MascotImage(clip: m.step == m.steps - 1 ? .happy : .hatching, then: .idle, size: 96, backdrop: .light)
                        .frame(width: 96, height: 96)
                }
                .frame(width: 128, height: 128)
                Spacer()
                Spacer()
            }
        }
        .clipped()
        .accessibilityHidden(true)
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
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: OnboardingModel.heroWidth + OnboardingModel.contentWidth,
                                             height: OnboardingModel.height), styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = T("onboarding.set_up_blurt")
        w.isReleasedWhenClosed = false
        w.delegate = self
        // an ordinary window: screenshots (yours or ours) can show it; our own recordings leave it out by their filter
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
        // the view's onDisappear doesn't come when the window closes: from now on the island says how the models went
        MainActor.assumeIsolated {
            ModelSetup.shared.shown = false
            model?.stopTry()
        }
        window = nil
        model = nil
    }

    var windowNumber: Int? { window?.windowNumber }

    /// Tests (wp6 `onboardingdone`): Done on the last step — the window closes.
    @MainActor
    func testDone() {
        guard let m = model else { return }
        m.step = m.steps - 1
        m.done()
    }

    /// Tests (`onboarding …` of the test channel): the assistant's buttons, then an "onboarding_state" event.
    @MainActor
    func testCommand(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        guard let m = model else { return emit(["event": "onboarding_state", "shown": false]) }
        switch a.first ?? "state" {
        case "step": m.step = Int(a.count > 1 ? a[1] : "") ?? m.step
        case "setup": m.walked = true; PermissionGuide.shared.start(.dictation, source: .onboarding)
        case "download": ModelSetup.shared.start()
        case "stop": ModelSetup.shared.cancel()
        case "warm": m.warmUp()
        case "small": if let f = ModelSetup.shared.fallback { ModelSetup.shared.start(only: [f]) }
        case "reload": Task { await ModelSetup.shared.load() }
        case "login": m.openAtLogin = a.count > 1 && a[1] == "on"
        case "done": m.done()
        default: break
        }
        let ms = ModelSetup.shared, pr = ms.progress
        emit(["event": "onboarding_state", "shown": true, "step": m.step, "uv": m.uv ?? NSNull(), "warm": m.warm ?? NSNull(),
              "missing": PermissionGuide.shared.missing(.dictation).map(\.rawValue), "walked": m.walked, "tried": m.tried,
              "login": m.openAtLogin, "models": ms.parts.map { "\($0.kind.rawValue):\($0.id):\($0.installed ? "installed" : "missing")" },
              "total_mb": ms.totalMB, "downloading": ms.current ?? NSNull(), "progress": [pr.done, pr.total].map { Double(Int($0)) },
              "failed": ms.failed, "ready": ms.ready])
    }

    /// Back to the front as it was (the permission guide finished), without changing the step.
    @MainActor
    func bringToFront() {
        guard let w = window else { return }
        activateApp()
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()        // even when macOS keeps the focus on System Settings
    }
}
