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
//      dependencies are warmed up in the background as soon as uv is there. Speech tools that didn't install and a
//      model list that couldn't be read are one state (BlurtCore SpeechSetup .blocked — offline, a proxy): one
//      sentence and one Try Again (the warm-up, the list, then the download), Next becomes Skip for Now, and it is
//      tried again by itself when the Mac comes back online (NetworkWatch);
//   4. try it — a text box ("tap Fn and say something … or double-tap to send it") that shows a check once the first
//      dictation lands, then (double-tap send on) a second exercise: double-tap to send, checked once the double tap
//      came (Dictation.sendAttempts; no Return goes into Blurt's own window); it waits only while dictation's own
//      recogniser is still coming down (its bar) — with it in and
//      polish still downloading it says dictation works already — and offers the download when there is a model to
//      download, else (blocked) the models step's Try Again — never a button that does nothing;
//      and "Open Blurt at login" (on the first time: dictation needs Blurt running; reopened later, as it is now);
//      Done applies it and closes.
// The big gradient headline is the welcome on the first step, then the step's own name and line (the four bars say
// which step it is). Wherever the dictation key is explained, so is the double tap (it presses Return). The models'
// downloads are the app's one download manager's (App/ModelDownloads.swift): closing the assistant mid-download says
// they carry on, and where to see them. Sizes: modelSize, as everywhere.
// Connecting agents (the blurt skill + MCP) is not in the assistant: Settings → Agents.
// Shown once on first launch (config app.onboarded), again from Settings → General or blurt://onboarding.
//
// Look (docs/design/system.md §3.4): a fixed-width hero panel on the left — the field (light) / deep (dark) with grain,
// a soft still spectrum glow behind the mascot (none with Reduce Transparency; the one place the spectrum appears) —
// then the steps: the welcome title in gradient text, step bars in brand ink, one brand primary per step (the step's
// own action while it is still to do, with "Skip for Now" in the footer; else Next / Done). Done closes (the chick is
// already happy on the last step; no bloom). The window is sized before it is centred (it opened against the menu
// bar, its left edge on the screen's middle, when centred at zero size).
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
    @Published var dictationKey = Dictation.key
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
    func retrySetup(via: String) {
        guard !retrying, uv != nil else { return }
        retrying = true
        if warm == "failed" { warm = nil }
        emit(["event": "onboarding_retry", "via": via])
        Task {
            await warmUpNow()
            await ModelSetup.shared.load()
            retrying = false
            let ms = ModelSetup.shared
            if warm == "done", ms.listRead, !ms.pending.isEmpty, !ms.downloading { ms.start() }
        }
    }

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
        .onAppear { perms.start(); models.shown = true; m.appear() }
        .onDisappear { perms.stop(); models.shown = false; m.stopTry() }
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

    /// The step's own action is still to do: it is the primary, and the footer offers "Skip for Now" instead of Next.
    var pending: Bool {
        switch m.step {
        case 1: return !guide.missing(.dictation).isEmpty
        case 2: return SpeechSetup.pending(m.speechStep, settled: models.settled)
        default: return false
        }
    }

    var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    // a large headline: gradient text (flat brand ink with Increase Contrast) — the welcome on the first
                    // step, then the step's own name (the bars below already say which step it is)
                    let h = heading
                    Text(h.title).font(.system(size: 24, weight: .bold)).brandGradientText()
                    Text(h.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                // on the last step Done says the same: one way out
                if m.step < m.steps - 1 {
                    Button(T("onboarding.skip_setup")) { m.finish() }.buttonStyle(.link).foregroundStyle(Color.brandInk)
                }
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

    /// The headline and its line for the step showing.
    var heading: (title: String, detail: String) {
        let key = Dictation.keyShort(m.dictationKey)
        switch m.step {
        case 0: return (T("onboarding.welcome_blurt"), T("onboarding.subtitle", key))
        case 1: return (T("onboarding.permissions"), T("onboarding.permissions_detail"))
        case 2: return (T("onboarding.models"), T("onboarding.models.detail"))
        default: return (T("onboarding.try"), T("onboarding.try.detail", key) + (Dictation.doubleTapSend ? T("onboarding.try.send", key) : ""))
        }
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
                    use(T("onboarding.use.dictation"), Dictation.keyShort(m.dictationKey),
                        detail: T(Dictation.doubleTapSend ? "onboarding.use.dictation.detail" : "onboarding.use.dictation.detail_plain"))
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

    func use(_ what: String, _ key: String, detail: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(what)
                if let d = detail { Text(d).font(.caption).foregroundStyle(.secondary) }
            }
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
            // the step's footnotes in one style (Hint); attention ink only for the Fn clash
            Hint((m.dictationKey == .fn ? T("onboarding.dictation_key.fn") : T("onboarding.dictation_key.other", Dictation.keyInline(m.dictationKey)))
                 + (Dictation.doubleTapSend ? T("onboarding.dictation_key.send", Dictation.keyInline(m.dictationKey)) : ""))
            if m.dictationKey == .fn, !SystemAccess.fnClashApps.isEmpty {
                Text(T("dictation.settings.fn_clash", SystemAccess.fnClashApps.joined(separator: T("settings.perm.list_sep"))))
                    .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandAttnInk).fixedSize(horizontal: false, vertical: true)
            }
            Hint(T("onboarding.permissions.screen_later"))
        }
    }

    // MARK: 3 models

    /// The same size format as Settings (modelSize).
    func size(_ mb: Double) -> String { modelSize(mb) }

    var modelsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    switch m.speechStep {
                    case .needsUV:
                        Text(T("onboarding.uv.needed")).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(T("onboarding.install_uv")) { m.installUV() }
                                .buttonStyle(.brand).keyboardShortcut(.defaultAction)
                                .disabled(m.installingUV).help(OnboardingModel.uvInstallCommand)
                            if m.installingUV { BrandSpinnerView() }
                        }
                        if m.uvFailed { Text(T("onboarding.uv.failed")).font(.caption).foregroundStyle(Color.brandErr) }
                    case .checking:
                        HStack { BrandSpinnerView(); Text(T("onboarding.models.checking")).foregroundStyle(.secondary) }
                    case .blocked:
                        // the tools or the list: one cause, one sentence, one Try Again (the rows wait for it)
                        Text(T("onboarding.setup.blocked")).foregroundStyle(Color.brandErr).fixedSize(horizontal: false, vertical: true)
                        Button(T("onboarding.models.retry")) { m.retrySetup(via: "models") }.primary(true)
                    default:
                        modelRows
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
                // in: ok; coming down now: a small spinner; waiting its turn: quiet; missing while idle: attention
                if models.current == p.id {
                    BrandSpinnerView(size: 10).frame(width: StatusDot.size, height: StatusDot.size)     // the dot's column
                } else {
                    StatusDot(tone: have ? .good : models.downloading ? .off : .warn)
                }
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
            // the rows' checks already say it: a quiet caption, not a fourth check
            Text(T("onboarding.models.ready")).font(.caption).foregroundStyle(.secondary)
        } else if models.failed {
            Text(T("onboarding.models.failed")).font(.callout).foregroundStyle(Color.brandErr).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(T("onboarding.models.retry")) { m.retrySetup(via: "models") }.primary(pending)
                if let f = models.fallback {
                    Button(T("onboarding.models.small", size(f.sizeMB))) { models.start(only: [f]) }
                        .help(T("onboarding.models.small.help"))
                }
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
            TextField(T("onboarding.try.placeholder"), text: $m.tryText, axis: .vertical)
                .lineLimit(3...5)
                .textFieldStyle(.roundedBorder)
                .focused($tryFocused)
            if m.tried {
                check(T("onboarding.try.works"))
                // the second exercise: the double tap that sends (taught here, before it surprises in a chat)
                if Dictation.doubleTapSend {
                    if m.sendTried { check(T("onboarding.try.sent")) }
                    else { Text(T("onboarding.try.send_next", Dictation.keyShort(m.dictationKey))).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true) }
                }
            } else if !guide.missing(.dictation).isEmpty {
                HStack(spacing: 10) {
                    Text(T("onboarding.try.needs_permissions")).foregroundStyle(.secondary)
                    setupButton
                }
            } else if let p = models.dictationProgress {
                // only the recogniser itself blocks trying it: its own bar
                VStack(alignment: .leading, spacing: 6) {
                    Text(T("onboarding.try.asr_downloading")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ProgressView(value: min(p.done, p.total), total: max(p.total, 1)) {
                        Text(T("onboarding.models.progress", size(p.done), size(p.total))).font(.caption).monospacedDigit()
                    }
                }
            } else if models.downloading && models.dictationReady {
                // dictation works already; polish (and the voice-note model) are still coming
                Text(T("onboarding.try.polish_coming", size(models.restMB))).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if (models.loaded || m.speechStep == .blocked) && !models.dictationReady {
                switch SpeechSetup.tryState(dictationReady: false, dictationDownloading: false, step: m.speechStep,
                                            pendingDownloads: !models.pending.isEmpty) {
                case .download:
                    HStack(spacing: 10) {
                        Text(T("onboarding.try.no_model")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button(T("onboarding.models.download")) { models.start() }
                    }
                default:
                    // nothing to download until the tools are in: the models step's Try Again, where its progress shows
                    HStack(spacing: 10) {
                        Text(T("onboarding.try.blocked")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button(T("onboarding.models.retry")) { m.step = 2; m.retrySetup(via: "try") }
                    }
                }
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
        w.setContentSize(NSSize(width: OnboardingModel.heroWidth + OnboardingModel.contentWidth, height: OnboardingModel.height))
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
        case "done": m.done()
        default: break
        }
        let ms = ModelSetup.shared, pr = ms.progress
        emit(["event": "onboarding_state", "shown": true, "step": m.step, "uv": m.uv ?? NSNull(), "warm": m.warm ?? NSNull(),
              "missing": PermissionGuide.shared.missing(.dictation).map(\.rawValue), "walked": m.walked, "tried": m.tried, "send_tried": m.sendTried,
              "login": m.openAtLogin, "models": ms.parts.map { "\($0.kind.rawValue):\($0.id):\($0.installed ? "installed" : "missing")" },
              "total_mb": ms.totalMB, "downloading": ms.current ?? NSNull(), "progress": [pr.done, pr.total].map { Double(Int($0)) },
              "failed": ms.failed, "ready": ms.ready, "dictation_ready": ms.dictationReady, "step_state": "\(m.speechStep)",
              "skip_for_now": m.step == 2 && SpeechSetup.pending(m.speechStep, settled: ms.settled), "list_read": ms.listRead,
              "dictation_progress": ms.dictationProgress.map { [Int($0.done), Int($0.total)] } ?? NSNull()])
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
