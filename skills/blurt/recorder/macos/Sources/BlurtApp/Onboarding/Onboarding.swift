// The setup assistant (docs/design/desktop-app.md §2.2), dictation first — four steps, every one skippable:
//   1. welcome — the four uses (dictation, snap, voice note, record), each a row with what it makes and its key as
//      keycaps; a link to Settings → Shortcuts;
//   2. dictation — the key first (a pop-up; it decides which lines the list below has, so changing it never moves the
//      control under the pointer), with Fn macOS's own Fn-key setting as a line of the key (not a permission), then
//      the permissions it needs: the microphone and Accessibility, live; Input Monitoring only when it is needed
//      (still missing with Accessibility on or after a walk, or a key other than Fn). "Set Up Permissions…" is the
//      footer's primary while anything is missing: the permission guide's dictation walk (PermissionGuide.swift) with
//      the helper panel next to System Settings; a row's own Allow… shows under the pointer. The step moves on by
//      itself when the walk ends with everything on. Screen Recording is not asked here: the first snap or recording
//      asks for it (the toast's Allow… / the alert start the guide for it);
//   3. models — the three models for this Mac (ModelSetup.swift: dictation, polish, voice notes) as plain rows (what
//      each does; the model's name is the tooltip), the total to download, then one progress bar (and Stop); it
//      carries on in the background. "Download Models" is the footer's primary; offline it waits, and a line says the
//      Mac is offline before anything was tried (NetworkWatch). uv is found, or — one sentence, Install uv as the
//      primary — installed into ~/.blurt/bin with the user's consent (the official installer); the scripts'
//      dependencies are warmed up in the background as soon as uv is there. Speech tools that didn't install and a
//      model list that couldn't be read are one state (BlurtCore SpeechSetup .blocked — offline, a proxy): one
//      notice and Try Again as the primary (the warm-up, the list, then the download), tried again by itself when the
//      Mac comes back online. Its sentence blames the network only when macOS says the Mac is offline
//      (SpeechSetup.Cause; online it points at a proxy or VPN), Try Again shows Checking… for at least a second with
//      the footer kept, and a retry still blocked says when it tried;
//   4. try it — a practice card: the key as a keycap and what to do with it, the box the words land in, a check once
//      the first dictation lands, then (double-tap send on) a second exercise: double-tap to send, checked once the
//      double tap came (Dictation.sendAttempts; no Return goes into Blurt's own window). While dictation can't be
//      tried, the card is a notice that says why (permissions, the recogniser still coming down with its bar, no
//      model, the tools) and the footer's primary is the fix — never a button that does nothing; with the recogniser
//      in and polish still downloading it says dictation works already. "Open Blurt at login" is the step's last row
//      (on the first time: dictation needs Blurt running; reopened later, as it is now); Done applies it and closes.
// The headline is the welcome on the first step, then the step's own name and one line. Wherever the dictation key is
// explained, so is the double tap (it presses Return). The models' downloads are the app's one download manager's
// (App/ModelDownloads.swift): closing the assistant mid-download says they carry on, and where to see them. Sizes:
// modelSize, as everywhere.
// Connecting agents (the blurt skill + MCP) is not in the assistant: Settings → Agents.
// Shown once on first launch (config app.onboarded), again from Settings → General or blurt://onboarding.
//
// Look (docs/design/system.md §3.4): a fixed-width hero panel on the left — the field (light) / deep (dark) with grain,
// a soft still spectrum glow behind the mascot (none with Reduce Transparency; the one place the spectrum appears) —
// then the steps: the title in gradient text and one line, the step's rows (OnboardingKit.swift: one row language,
// rows over hairlines as in Settings, a neutral glyph column, one trailing element on one right edge), and the footer:
// the step dots, Skip Setup (neutral; the one skip — none per step), Back, and one brand primary: the step's own
// action while it is still to do (Next / Done beside it, plain, goes on without it), else Next / Done. Done closes
// (Peep already peeps and hops on the last step; no bloom). The window is sized before it is centred (it opened
// against the menu bar, its left edge on the screen's middle, when centred at zero size).
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
    /// Try Again runs: the warm-up, the list, then the download (the step shows "Checking…" meanwhile)
    @Published var retrying = false
    /// The last Try Again ended still blocked, at this time ("Tried again at 14:32: still offline")
    @Published var retriedAt: Date?
    @Published var dictationKey = Dictation.key
    /// how the key starts a take (the Try-it line says the gesture of this mode: a Hold-only user is never told to tap)
    @Published var dictationMode = Dictation.mode
    /// a dictation walk started here (Input Monitoring's row shows once Accessibility stays off after it)
    @Published var walked = false
    /// "Open Blurt at login" on the last step: on the first time (dictation needs Blurt running); opened again later,
    /// as it is now — Done never turns back on what the user turned off in Settings → General
    @Published var openAtLogin = Onboarding.needed ? true : LoginItem.enabled
    @Published var tryText = ""
    /// the first dictation landed while the last step showed
    @Published var tried = false
    /// the second exercise once a dictation landed: the double tap that sends (only while double-tap send is on)
    @Published var sendTried = false
    private var sendBaseline = 0
    private var tryTimer: Timer?
    private var tryBaseline: String?
    /// what macOS says of the network (NetworkWatch, read every second while the window shows): offline, the models'
    /// download can't start — the step says so before the button is pressed, not after it failed
    @Published var online: Bool? = NetworkWatch.shared.isOnline
    private var netTimer: Timer?

    func watchNetwork() {
        online = NetworkWatch.shared.isOnline
        netTimer?.invalidate()
        netTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                let now = NetworkWatch.shared.isOnline
                if now != self.online { self.online = now }
            }
        }
    }
    func stopNetwork() { netTimer?.invalidate(); netTimer = nil }

    func setKey(_ k: DictationTrigger.Key) {
        dictationKey = k
        Dictation.set("key", k.rawValue)
        Dictation.shared.apply()
        emit(["event": "dictation_setting", "key": "key", "value": k.rawValue, "via": "onboarding"])
    }

    private var settingsWatch: Any?
    /// The key and the mode follow Settings while this window is open (Dictation.settingsChanged).
    func watchSettings() {
        guard settingsWatch == nil else { return }
        settingsWatch = NotificationCenter.default.addObserver(forName: Dictation.settingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                if self.dictationKey != Dictation.key { self.dictationKey = Dictation.key }
                if self.dictationMode != Dictation.mode { self.dictationMode = Dictation.mode }
            }
        }
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
    static let height: CGFloat = 560

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

    /// Pre-installs the scripts' dependencies (numpy, sherpa-onnx…) and builds the search index — quietly: only the
    /// speech tools' failure shows (on the models step, as SpeechSetup .blocked; the script's output goes to the
    /// event). The index is built on the way and logged; it has nothing to do with speech and never blocks the step.
    func warmUp() {
        Task { await warmUpNow() }
    }

    func warmUpNow() async {
        guard warm != "running", warm != "done" else { return }
        warm = "running"
        var error: String?
        do {
            let test = ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1"
            let fail = test ? ProcessInfo.processInfo.environment["BLURT_TEST_WARM_FAIL"] : nil
            let a = try await SkillCLI.shared.run(fail ?? "transcribe.py", ["backends"], timeout: 600)
            if !a.ok { error = a.errorText }
        } catch let e { error = "\(e)" }
        warm = error == nil ? "done" : "failed"
        emit(["event": "onboarding_warm", "result": warm ?? NSNull(), "error": error ?? NSNull()])
        if warm == "done" {
            let b = try? await SkillCLI.shared.run("index.py", ["scan"], timeout: 300)
            if b?.ok != true { emit(["event": "onboarding_index", "result": "failed", "error": b?.errorText ?? NSNull()]) }
        }
    }

    /// Where the models step stands (BlurtCore SpeechSetup): one state for "the tools or the list can't be set up".
    var speechStep: SpeechSetup.Step {
        let ms = ModelSetup.shared
        if retrying { return .checking }
        return SpeechSetup.step(uv: uv != nil, warm: warm, loaded: ms.loaded, listRead: ms.listRead,
                                downloading: ms.downloading, failed: ms.failed, ready: ms.ready)
    }

    /// The one Try Again (the models step, the Try-it step, back online): the speech tools again if they didn't
    /// install, the model list, then the download — what was asked for is carried through, not half of it.
    /// "Checking…" lasts at least SpeechSetup.minimumCheck (offline it fails in a blink), and a retry that is still
    /// blocked says when it tried.
    func retrySetup(via: String) {
        guard !retrying, uv != nil else { return }
        retrying = true
        retriedAt = nil
        if warm == "failed" { warm = nil }
        emit(["event": "onboarding_retry", "via": via])
        let started = Date()
        Task {
            await warmUpNow()
            await ModelSetup.shared.load()
            let left = SpeechSetup.minimumCheck - Date().timeIntervalSince(started)
            if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1e9)) }
            retrying = false
            if speechStep == .blocked { retriedAt = Date() }
            emit(["event": "onboarding_retry_done", "via": via, "step": "\(speechStep)", "cause": "\(blockedCause)"])
            let ms = ModelSetup.shared
            if warm == "done", ms.listRead, !ms.pending.isEmpty, !ms.downloading { ms.start() }
        }
    }

    /// What a blocked setup is put down to: the network only when macOS says the Mac is offline.
    var blockedCause: SpeechSetup.Cause { SpeechSetup.cause(online: NetworkWatch.shared.isOnline) }

    /// The Mac is online again (NetworkWatch): a blocked or failed setup is tried again by itself.
    func backOnline() {
        switch speechStep {
        case .blocked, .failed: retrySetup(via: "online")
        default: break
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
        if tried {
            // the second exercise: a double tap asked for Return (in Blurt's own window it isn't pressed — the line says
            // what it does elsewhere)
            guard Dictation.shared.sendAttempts > sendBaseline else { return }
            sendTried = true
            stopTry()
            emit(["event": "onboarding_try_send"])
            return
        }
        guard let r = Dictation.shared.lastResult, r["ok"] as? Bool == true,
              let id = r["id"] as? String, id != tryBaseline else { return }
        tried = true
        emit(["event": "onboarding_try", "id": id])
        // a first dictation came in: now the double tap that sends, when it is on
        if Dictation.doubleTapSend { sendBaseline = Dictation.shared.sendAttempts } else { stopTry() }
    }
}

/// "Open Blurt at login" — the one switch behind Settings → General's row and the assistant's. Test builds never
/// register (a scratch bundle would land in the user's Login Items): the event says what would have happened, and the
/// switch remembers it in memory so the row still flips.
enum LoginItem {
    private static var testState: Bool?
    static var enabled: Bool { SystemAccess.testMode ? testState ?? false : SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ on: Bool, via: String) -> String? {
        emit(["event": "login_item", "on": on, "via": via, "test_mode": SystemAccess.testMode])
        if SystemAccess.testMode { testState = on; return nil }
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
        .onAppear { perms.start(); models.shown = true; m.appear(); m.watchNetwork() }
        .onDisappear { perms.stop(); models.shown = false; m.stopTry(); m.stopNetwork() }
        .onChange(of: guide.finished) { f in
            // the walk ended with everything dictation needs: on to the models
            guard f != nil, m.step == 1, guide.missing(.dictation).isEmpty else { return }
            emit(["event": "onboarding", "step": 2, "via": "permissions_done"])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if m.step == 1 { m.step = 2 } }
        }
        .onChange(of: m.step) { s in emit(["event": "onboarding", "step": s]) }
        // a model came down: the network works — speech tools that failed earlier are set up again quietly
        .onChange(of: models.finished.count) { _ in if m.warm == "failed" { m.warm = nil; m.warmUp() } }
    }

    /// The step's own action is still to do: it is the footer's one primary (Return), and Next / Done sits beside it,
    /// plain — going on without it. The footer never has a second skip.
    var pending: Bool { action != nil }

    /// The step's own action, while it is still to do (nil: the step is done, Next / Done is the primary).
    struct StepAction {
        var title: String
        var enabled = true
        var help: String?
        var run: () -> Void
    }

    var action: StepAction? {
        switch m.step {
        case 1:
            guard !guide.missing(.dictation).isEmpty else { return nil }
            return StepAction(title: guide.running ? T("settings.perm.setup_running") : T("settings.perm.setup")) { startWalk() }
        case 2:
            guard SpeechSetup.pending(m.speechStep, settled: models.settled, retrying: m.retrying) else { return nil }
            switch m.speechStep {
            case .needsUV:
                return StepAction(title: T("onboarding.install_uv"), enabled: !m.installingUV, help: OnboardingModel.uvInstallCommand) { m.installUV() }
            case .offer:
                // offline, the download can't start: the line above says so and the button waits for the network
                return StepAction(title: T("onboarding.models.download"), enabled: m.online != false) { models.start() }
            default:
                return StepAction(title: T("onboarding.models.retry"), enabled: !m.retrying) { m.retrySetup(via: "models") }
            }
        case 3:
            switch tryBlock {
            case .permissions?: return StepAction(title: T("settings.perm.setup")) { startWalk() }
            case .noModel?: return StepAction(title: T("onboarding.try.download"), enabled: m.online != false) { models.start() }
            case .tools?: return StepAction(title: T("onboarding.models.retry")) { m.step = 2; m.retrySetup(via: "try") }
            default: return nil
            }
        default:
            return nil
        }
    }

    func startWalk() {
        m.walked = true
        guide.start(.dictation, source: .onboarding)
    }

    var last: Bool { m.step == m.steps - 1 }

    func advance() { if last { m.done() } else { m.step += 1 } }

    var content: some View {
        VStack(spacing: 0) {
            // a large headline in gradient text (flat brand ink with Increase Contrast) and one line under it
            let h = heading
            VStack(alignment: .leading, spacing: 6) {
                Text(h.title).font(.system(size: 24, weight: .bold)).brandGradientText()
                    .accessibilityAddTraits(.isHeader)
                Text(h.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, OnbMetrics.inset).padding(.top, 22)

            Group {
                switch m.step {
                case 0: welcome
                case 1: permissions
                case 2: modelsStep
                default: tryIt
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, OnbMetrics.inset).padding(.top, 20).padding(.bottom, 16)

            Divider()
            footer
        }
    }

    /// Where you are (the dots), the one way out of the whole assistant, Back, and the one primary.
    var footer: some View {
        HStack(spacing: 8) {
            StepDots(step: m.step, count: m.steps)
            Spacer(minLength: 12)
            // on the last step Done says the same: one way out
            if !last {
                Button(T("onboarding.skip_setup")) { m.finish() }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .padding(.trailing, 8)
            }
            if m.step > 0 { Button(T("onboarding.back")) { m.step -= 1 } }
            let nextTitle = last ? T("onboarding.done") : T("onboarding.next")
            if let a = action {
                Button(nextTitle) { advance() }
                Button(a.title) { a.run() }
                    .buttonStyle(.brand).keyboardShortcut(.defaultAction)
                    .disabled(!a.enabled).help(a.help ?? "")
            } else {
                Button(nextTitle) { advance() }
                    .buttonStyle(.brand).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, OnbMetrics.inset).padding(.top, 14).padding(.bottom, 18)
    }

    /// The headline and its line for the step showing.
    var heading: (title: String, detail: String) {
        switch m.step {
        case 0: return (T("onboarding.welcome_blurt"), T("onboarding.subtitle"))
        case 1:
            return (T("onboarding.dictation.title"),
                    T(guide.missing(.dictation).isEmpty ? "onboarding.dictation.detail_done" : "onboarding.dictation.detail"))
        case 2: return (T("onboarding.models"), T("onboarding.models.detail"))
        default: return (T("onboarding.try"), T("onboarding.try.subtitle"))
        }
    }

    func check(_ text: String) -> some View {
        HStack(spacing: 8) {
            StatusDot(tone: .good)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 1 welcome

    /// The dictation key as keycaps.
    static func dictationCaps(_ k: DictationTrigger.Key) -> [String] {
        switch k {
        case .fn: return ["fn"]
        case .rightOption: return [T("onboarding.cap.right_option")]
        case .eitherOption: return ["⌥"]
        }
    }

    var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            feature(.keyboard, T("onboarding.use.dictation"),
                    T(Dictation.doubleTapSend ? "onboarding.use.dictation.detail" : "onboarding.use.dictation.detail_plain"),
                    OnboardingView.dictationCaps(m.dictationKey), first: true)
            feature(.snap, T("onboarding.use.snap"), T("onboarding.use.snap.detail"), KeyCaps.split(hk(.snap)))
            feature(.mic, T("onboarding.use.voice"), T("onboarding.use.voice.detail"), KeyCaps.split(hk(.voice)))
            feature(.record, T("onboarding.use.record"), T("onboarding.use.record.detail"), KeyCaps.split(hk(.toggleRecord)))
            Spacer(minLength: 12)
            Button(T("onboarding.use.change")) { AppEnvironment.settings?.show(pane: SettingsPane.shortcuts.rawValue) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.brandInk)
                .onHover { NSCursor.pointingHand.set(); if !$0 { NSCursor.arrow.set() } }
        }
    }

    func feature(_ icon: BlurtIcon, _ title: String, _ detail: String, _ caps: [String], first: Bool = false) -> some View {
        OnbRow(image: GlyphTile.brand(icon), title: title, detail: detail, first: first) {
            if caps.isEmpty {
                Text(T("settings.kit.not_set")).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                KeyCaps(caps)
            }
        }
        .frame(minHeight: 62)
        .accessibilityElement(children: .combine)
    }

    // MARK: 2 dictation: the key, then the permissions

    /// The microphone and Accessibility; Input Monitoring only when dictation needs it: a key other than Fn, or it still
    /// isn't satisfied once Accessibility is on or a walk got past it (with Fn, Accessibility alone hears the key —
    /// Input Monitoring is what's left when Accessibility was turned down or its tap was refused). The 🌐 key (with
    /// Fn) is the key's own line above, not a permission. So whatever the walk still asks for has its row here.
    var permissionKinds: [PermissionKind] {
        let pastAccessibility = (m.walked || perms.accessibility == .granted) && !(guide.running && guide.current == .accessibility)
        let im = !guide.satisfied(.inputMonitoring) && (m.dictationKey != .fn || pastAccessibility)
        return [.microphone, .accessibility] + (im ? [.inputMonitoring] : [])
    }

    /// The picker's names, all of one form ("Fn", "Right Option", "Either Option").
    static func keyLabel(_ k: DictationTrigger.Key) -> String {
        switch k {
        case .fn: return T("onboarding.key.fn")
        case .rightOption: return T("onboarding.key.right_option")
        case .eitherOption: return T("onboarding.key.either_option")
        }
    }

    var keyGesture: String {
        let send = Dictation.doubleTapSend ? T("onboarding.key.gesture_send") : ""
        return (m.dictationMode == .hold ? T("onboarding.key.gesture_hold") : T("onboarding.key.gesture")) + send
    }

    var permissions: some View {
        VStack(alignment: .leading, spacing: 0) {
            // the key first: it decides which lines the permissions below have, so changing it never moves this row
            OnbRow(image: GlyphTile.brand(.keyboard), title: T("onboarding.dictation_key"), detail: keyGesture, first: true) {
                Picker(T("onboarding.dictation_key"), selection: Binding(get: { m.dictationKey }, set: { m.setKey($0) })) {
                    ForEach(DictationTrigger.Key.allCases, id: \.self) { k in Text(OnboardingView.keyLabel(k)).tag(k) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            if m.dictationKey == .fn {
                // macOS's own 🌐 key setting: not a permission, a line of the key (the walk sets it with the rest)
                OnbRow(image: GlyphTile.symbol("globe"), title: T("onboarding.fn.title"), detail: T("onboarding.fn.detail")) {
                    if guide.running && guide.current == .fnKey {
                        waiting
                    } else if guide.satisfied(.fnKey) {
                        StateLabel(tone: .good, text: T("onboarding.fn.set"))
                    } else {
                        StateLabel(tone: .warn, text: T("settings.kit.not_set"), color: .brandAttnInk)
                    }
                }
                if !SystemAccess.fnClashApps.isEmpty {
                    Text(T("dictation.settings.fn_clash", SystemAccess.fnClashApps.joined(separator: T("settings.perm.list_sep"))))
                        .font(.system(size: 12)).foregroundStyle(Color.brandAttnInk).fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, OnbMetrics.glyph + OnbMetrics.rowGap).padding(.bottom, 6)
                }
            }

            OnbHeading(text: T("onboarding.permissions")).padding(.top, OnbMetrics.sectionGap)
            ForEach(Array(permissionKinds.enumerated()), id: \.element) { i, k in
                OnbPermissionRow(kind: k, state: perms.state(k), first: i == 0)
            }
            Text(T("onboarding.permissions.screen_later")).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }

    var waiting: some View {
        HStack(spacing: 6) {
            BrandSpinnerView(size: 10)
            Text(T("onboarding.perm.waiting")).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    // MARK: 3 models

    /// The same size format as Settings (modelSize).
    func size(_ mb: Double) -> String { modelSize(mb) }

    var modelsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch m.speechStep {
            case .needsUV:
                OnbNotice(kind: .attention, title: T("onboarding.uv.title"), detail: T("onboarding.uv.needed")) {
                    if m.installingUV {
                        HStack(spacing: 6) { BrandSpinnerView(size: 10); Text(T("onboarding.uv.installing")).font(.system(size: 12)).foregroundStyle(.secondary) }
                            .padding(.top, 2)
                    }
                    if m.uvFailed { Text(T("onboarding.uv.failed")).font(.system(size: 12)).foregroundStyle(Color.brandErr) }
                }
            case .checking:
                OnbNotice(kind: .working, title: T("onboarding.models.checking"), detail: nil)
            case .blocked:
                // the tools or the list: one cause, one sentence; the footer's Try Again (the rows wait for it)
                let offline = m.blockedCause == .offline
                OnbNotice(kind: offline ? .offline : .error,
                          title: T(offline ? "onboarding.setup.blocked.title_offline" : "onboarding.setup.blocked.title"),
                          detail: T(offline ? "onboarding.setup.blocked" : "onboarding.setup.blocked_error")) {
                    if let at = m.retriedAt {
                        Text(T(offline ? "onboarding.setup.retried_offline" : "onboarding.setup.retried_error",
                               at.formatted(date: .omitted, time: .shortened)))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            default:
                modelRows
                modelStatus.padding(.top, 14)
            }
            Spacer(minLength: 12)
            Text(T("onboarding.models.later")).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func kindIcon(_ k: ModelBundle.Kind) -> NSImage {
        switch k {
        case .dictation: return GlyphTile.brand(.keyboard)
        case .polish: return GlyphTile.brand(.wand)
        case .note: return GlyphTile.brand(.mic)
        }
    }

    /// A model's role in plain words and what it does (its own name is the row's tooltip).
    func kindWords(_ k: ModelBundle.Kind) -> (title: String, what: String) {
        switch k {
        case .dictation: return (T("onboarding.models.kind.dictation"), T("onboarding.models.what.dictation"))
        case .polish: return (T("onboarding.models.kind.polish"), T("onboarding.models.what.polish"))
        case .note: return (T("onboarding.models.kind.note"), T("onboarding.models.what.note"))
        }
    }

    @ViewBuilder var modelRows: some View {
        ForEach(Array(models.parts.enumerated()), id: \.element.id) { i, p in
            let have = p.installed || models.finished.contains(p.id)
            // the model's own name is detail: the tooltip, not the row
            let words = kindWords(p.kind)
            OnbRow(image: kindIcon(p.kind), title: words.title, detail: words.what, first: i == 0, help: p.name) {
                modelState(p, have: have)
            }
            .accessibilityElement(children: .combine)
        }
        // what is still to come down, in the sizes' column
        if !models.ready, !models.downloading, models.totalMB > 0 {
            HStack(spacing: 8) {
                Spacer()
                Text(T("onboarding.models.total_label")).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(size(models.totalMB)).font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            .padding(.top, 8)
            .overlay(alignment: .top) { Divider() }
        }
    }

    /// One trailing element per model: its size while it is to come, a spinner while it comes down, a check once in.
    @ViewBuilder func modelState(_ p: ModelBundle.Part, have: Bool) -> some View {
        if have {
            StateLabel(tone: .good, text: T("onboarding.models.installed"))
        } else if models.current == p.id {
            HStack(spacing: 6) {
                BrandSpinnerView(size: 10)
                Text(size(p.sizeMB)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            }
            .fixedSize()
        } else {
            Text(size(p.sizeMB)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    /// Under the rows: the one bar while the set downloads, the done line, a stop that failed, the Mac offline.
    @ViewBuilder var modelStatus: some View {
        if models.downloading {
            let pr = models.progress
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    ProgressView(value: min(pr.done, pr.total), total: max(pr.total, 1)).tint(Color.brandInk)
                    Text(T("onboarding.models.progress", size(pr.done), size(pr.total)))
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                    Button(T("onboarding.models.stop")) { models.cancel() }.controlSize(.small)
                }
                Text(T("onboarding.models.background")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else if models.ready {
            check(T("onboarding.models.ready"))
        } else if models.failed {
            VStack(alignment: .leading, spacing: 8) {
                Text(T("onboarding.models.failed")).font(.system(size: 12)).foregroundStyle(Color.brandErr)
                    .fixedSize(horizontal: false, vertical: true)
                if let f = models.fallback {
                    Button(T("onboarding.models.small", size(f.sizeMB))) { models.start(only: [f]) }
                        .controlSize(.small).help(T("onboarding.models.small.help"))
                }
            }
        } else if m.online == false {
            OnbNotice(kind: .offline, title: T("onboarding.models.offline.title"), detail: T("onboarding.models.offline"))
        } else if models.settled {
            // the small model is in: the full set stays on offer, no longer the step's primary
            Button(T("onboarding.models.download")) { models.start() }
        }
    }

    // MARK: 4 try it

    /// Why dictation can't be tried yet (nil: it can).
    enum TryBlock { case permissions, downloading(done: Double, total: Double), noModel, tools }

    var tryBlock: TryBlock? {
        if m.tried { return nil }
        if !guide.missing(.dictation).isEmpty { return .permissions }
        // only the recogniser itself blocks trying it: its own bar
        if let p = models.dictationProgress { return .downloading(done: p.done, total: p.total) }
        if models.dictationReady { return nil }
        guard models.loaded || m.speechStep == .blocked else { return nil }        // the list is still being read
        switch SpeechSetup.tryState(dictationReady: false, dictationDownloading: false, step: m.speechStep,
                                    pendingDownloads: !models.pending.isEmpty) {
        case .download: return .noModel
        default: return .tools
        }
    }

    var tryIt: some View {
        VStack(alignment: .leading, spacing: 0) {
            // one place for the practice: the card, or (while it can't be tried) why, in the card's own size
            if let b = tryBlock {
                tryNotice(b).frame(height: OnboardingView.tryHeight)
            } else {
                practice
            }
            if tryBlock == nil, !m.tried, models.downloading, models.dictationReady {
                // dictation works already; polish (and the voice-note model) are still coming
                Text(T("onboarding.try.polish_coming", size(models.restMB))).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            Spacer(minLength: 16)
            OnbRow(image: GlyphTile.symbol("power"), title: T("settings.general.login"), detail: T("onboarding.login.detail")) {
                Toggle(T("settings.general.login"), isOn: $m.openAtLogin).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
        .onAppear {
            m.startTry()
            if tryBlock == nil { DispatchQueue.main.async { tryFocused = true } }
        }
        .onDisappear { m.stopTry() }
    }

    static let tryHeight: CGFloat = 224

    @ViewBuilder func tryNotice(_ b: TryBlock) -> some View {
        switch b {
        case .permissions:
            let names = ListFormatter.localizedString(byJoining: guide.missing(.dictation).map(PermissionGuide.name))
            OnbNotice(kind: .attention, title: T("onboarding.try.needs_permissions"), detail: T("onboarding.try.needs_permissions.detail", names),
                      centered: true)
        case .downloading(let done, let total):
            OnbNotice(kind: .working, title: T("onboarding.try.asr_downloading"), detail: T("onboarding.try.asr_downloading.detail"),
                      centered: true) {
                HStack(spacing: 12) {
                    ProgressView(value: min(done, total), total: max(total, 1)).tint(Color.brandInk)
                    Text(T("onboarding.models.progress", size(done), size(total))).font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary).fixedSize()
                }
                .padding(.top, 4)
            }
        case .noModel:
            OnbNotice(kind: .attention, title: T("onboarding.try.no_model"), detail: T("onboarding.try.no_model.detail"), centered: true)
        case .tools:
            OnbNotice(kind: .error, title: T("onboarding.try.blocked"), detail: T("onboarding.try.blocked.detail"), centered: true)
        }
    }

    /// The practice card: the key as a keycap and what to do with it, the box the words land in, then the checks.
    var practice: some View {
        let key = Dictation.keyShort(m.dictationKey).trimmingCharacters(in: .whitespaces)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                KeyCaps(OnboardingView.dictationCaps(m.dictationKey), size: 13)
                Text(T(m.dictationMode == .hold ? "onboarding.try.how.hold" : "onboarding.try.how"))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            TextField(T("onboarding.try.placeholder"), text: $m.tryText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(3...5)
                .focused($tryFocused)
            if m.tried {
                VStack(alignment: .leading, spacing: 6) {
                    check(T("onboarding.try.works"))
                    // the second exercise: the double tap that sends (taught here, before it surprises in a chat)
                    if Dictation.doubleTapSend {
                        if m.sendTried { check(T("onboarding.try.sent")) }
                        else {
                            Text(T("onboarding.try.send_next", key)).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, StatusDot.size + 8)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: OnboardingView.tryHeight, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)         // its own height, never stretched to the login row
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(tryFocused ? Color.brandAccent : Color.primary.opacity(0.12), lineWidth: tryFocused ? 1.5 : 0.5))
        .contentShape(Rectangle())
        .onTapGesture { tryFocused = true }
    }
}

/// One permission of the dictation step: its glyph, name and why, then one trailing element — Allowed (with the ok
/// dot), Not allowed (the attention dot; Allow… under the pointer: the footer's Set Up Permissions… is the way for
/// all of them), Turned off with System Settings… (macOS won't ask again), Not needed, or the guide waiting on it.
struct OnbPermissionRow: View {
    var kind: PermissionKind
    var state: Permissions.State
    var first: Bool
    @ObservedObject var guide = PermissionGuide.shared
    @State private var hover = false

    var symbol: String {
        switch kind {
        case .microphone: return "mic"
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "keyboard"
        case .screen: return "rectangle.dashed"
        case .fnKey: return "globe"
        }
    }

    var why: String {
        switch kind {
        case .microphone: return T("onboarding.perm.why.microphone")
        case .accessibility: return T("onboarding.perm.why.accessibility")
        case .inputMonitoring: return T("onboarding.perm.why.input_monitoring", Dictation.keyInline)
        case .screen: return T("onboarding.perm.why.screen")
        case .fnKey: return T("onboarding.fn.detail")
        }
    }

    var missing: Bool { state != .granted && !guide.satisfied(kind) }

    func allow() { PermissionGuide.shared.start(.all, only: [kind], source: .onboarding) }

    var body: some View {
        OnbRow(image: GlyphTile.symbol(symbol), title: PermissionGuide.name(kind), detail: why, first: first) {
            trailing.frame(minWidth: 96, alignment: .trailing)
        }
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: T("settings.kit.allow")) { if missing { allow() } }
    }

    @ViewBuilder var trailing: some View {
        if guide.running && guide.current == kind {
            HStack(spacing: 6) {
                BrandSpinnerView(size: 10)
                Text(T("onboarding.perm.waiting")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .fixedSize()
        } else if state == .granted {
            StateLabel(tone: .good, text: T("settings.kit.allowed"))
        } else if guide.satisfied(kind) {
            StateLabel(tone: .off, text: T("settings.perm.not_needed"))
        } else if state == .denied {
            // macOS won't ask again: the way back is System Settings, said on the button itself
            HStack(spacing: 8) {
                Text(T("settings.kit.not_allowed")).font(.system(size: 12)).foregroundStyle(Color.brandAttnInk)
                Button(T("settings.kit.system_settings")) { allow() }.controlSize(.small)
            }
            .fixedSize()
        } else if hover {
            Button(T("settings.kit.allow")) { allow() }.controlSize(.small)
        } else {
            StateLabel(tone: .warn, text: T("onboarding.perm.missing"), color: .brandAttnInk)
        }
    }
}

/// The hero side panel (§3.4): the field with grain, a soft still spectrum glow, the mascot on it — the only place
/// the spectrum appears. Flat field (no grain, no glow) with Reduce Transparency. Peep (the paper clay renders) turns
/// to say hello on the first steps, then idles (a breath and a blink), and peeps and hops on the last step. It sits a
/// little above the middle, where the eye puts the centre.
struct OnboardingHero: View {
    @ObservedObject var m: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { g in
            ZStack {
                BrandField()
                ZStack {
                    // light: a bloom that lightens the field (screen), never a darker smudge on it
                    SpectrumGlow(size: 176, opacity: scheme == .dark ? 0.5 : 0.7)
                        .blendMode(scheme == .dark ? .normal : .screen)
                    MascotImage(clip: m.step == m.steps - 1 ? .done : .hello, then: .idle, size: 108, backdrop: .light)   // the field is light in both appearances: the paper set
                        .frame(width: 108, height: 108)
                }
                .frame(width: 140, height: 140)
                .position(x: g.size.width / 2, y: g.size.height * 0.45)
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

    /// A config.json that can't be read says nothing about a first run: the assistant isn't shown again for it.
    static var needed: Bool { Config.shared.readable && Config.shared["app.onboarded"] as? Bool != true }

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
        m.watchSettings()
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
        let host = NSHostingController(rootView: OnboardingView(m: m))
        host.sizingOptions = []         // the window keeps its size: centred at that size, not at zero
        w.contentViewController = host
        // the content view sits under the transparent title bar, but the SwiftUI layout keeps out of it (safe area):
        // the window is that much taller, so the whole layout — the footer's buttons included — fits inside it
        let probe = NSRect(x: 0, y: 0, width: 100, height: 100)
        let titleBar = NSWindow.frameRect(forContentRect: probe, styleMask: [.titled, .closable]).height - probe.height
        w.setContentSize(NSSize(width: OnboardingModel.heroWidth + OnboardingModel.contentWidth,
                                height: OnboardingModel.height + titleBar))
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
            ModelSetup.shared.closedWhileDownloading()       // "the models carry on in the background · Show"
            // closed while speech couldn't be set up: the one line that says dictation won't work yet, and the way back
            if model?.speechStep == .blocked { Dictation.shared.notSetUp(from: "onboarding_closed") }
            model?.stopTry()
        }
        window = nil
        model = nil
    }

    var windowNumber: Int? { window?.windowNumber }

    /// The Mac is online again (NetworkWatch): an open assistant whose speech setup was blocked tries again.
    func backOnline() { MainActor.assumeIsolated { model?.backOnline() } }

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
        case "retry": m.retrySetup(via: "test")
        case "small": if let f = ModelSetup.shared.fallback { ModelSetup.shared.start(only: [f]) }
        case "reload": Task { await ModelSetup.shared.load() }
        case "login": m.openAtLogin = a.count > 1 && a[1] == "on"
        // tried [TEXT…]: as if the first dictation had landed in the Try-it box (TEXT: what it typed there)
        case "tried": m.tried = true; m.tryText = a.dropFirst().joined(separator: " ")
        case "done": m.done()
        default: break
        }
        let ms = ModelSetup.shared, pr = ms.progress
        emit(["event": "onboarding_state", "shown": true, "step": m.step, "uv": m.uv ?? NSNull(), "warm": m.warm ?? NSNull(),
              "missing": PermissionGuide.shared.missing(.dictation).map(\.rawValue), "walked": m.walked, "tried": m.tried, "send_tried": m.sendTried,
              "login": m.openAtLogin, "models": ms.parts.map { "\($0.kind.rawValue):\($0.id):\($0.installed ? "installed" : "missing")" },
              "total_mb": ms.totalMB, "downloading": ms.current ?? NSNull(), "progress": [pr.done, pr.total].map { Double(Int($0)) },
              "failed": ms.failed, "ready": ms.ready, "dictation_ready": ms.dictationReady, "step_state": "\(m.speechStep)",
              "skip_for_now": m.step == 2 && SpeechSetup.pending(m.speechStep, settled: ms.settled, retrying: m.retrying), "list_read": ms.listRead,
              "dictation_progress": ms.dictationProgress.map { [Int($0.done), Int($0.total)] } ?? NSNull(),
              "retrying": m.retrying, "cause": "\(m.blockedCause)", "retried_at": m.retriedAt.map { $0.timeIntervalSince1970 } ?? NSNull()])
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
