// Settings → Dictation (docs/design/dictation.md), modelled on System Settings → Keyboard → Dictation: a short page of
// rows (SettingsKit; titles and descriptions from SettingsCatalog), one control each, the popups in one 180 pt column.
//   (notice)    only while dictation can't work: a permission missing (Allow…, the guide), the key not heard (Turn
//               On…), macOS's own "Press Globe key to" also reacting to Fn (Fix…), another Blurt holding the key
//   Dictation   on / off (the master: everything under it dims when off; the listener and when the key was last heard
//               in another app are its tooltip) · Shortcut: the key, with Fn's "Use Fn only for dictation" in its
//               menu · Start and stop: tap or hold / tap / hold (Esc and the voice note in its tooltip) · Double-tap to
//               send · Structured / Translate trigger: double-tap (default) or single tap, both keys from one choice,
//               a footnote saying what the gesture is · Microphone: Automatic / this Mac's / the default input · the
//               start sound
//   Style and words  Style: Verbatim (no polish) / Light / Structured / Auto (DictationStyleChoice: the polish key
//               and the styles' default) · By kind of app: per category, apps set on their own, list suggestions,
//               learning and the polish time limit folded under it (unfolded when a search lands in it) · Names and
//               terms: Manage… (the Dictation page's Words tab), with reading the context and learning in its menu ·
//               Translate: Chinese ↔ English / into English / into Chinese (⌘ while talking turns it on), whether the
//               cloud model translates, the apps where every take is translated (DictationTranslating.swift)
//   History and models  History: Open History…, with how long it is kept, the audio and Clear History… in its menu ·
//               Models: the names in use, or what isn't on this Mac yet, in plain words — and always the one way on,
//               a link to Settings → Speech, which chooses them and owns the one Download (DictationModels.swift)
//   Advanced    folded at the foot (open while it is on): Show the Dictation Lab (record.dictation.lab), for developers
// Everything is record.dictation.* in config.json; Dictation.shared.apply() picks changes up at once.
// Strings: Resources/*.lproj/Dictation.strings (T("dictation.…")).
import AppKit
import SwiftUI
import BlurtCore

@MainActor
final class DictationSettings: ObservableObject {
    @Published var enabled = Dictation.enabled
    @Published var key = Dictation.key
    @Published var mode = Dictation.mode
    @Published var doubleTap = Dictation.doubleTapSend
    @Published var modifierTap = Dictation.modifierTap
    @Published var timeout = Dictation.polishTimeout
    @Published var retention = Dictation.retentionDays
    @Published var keepAudio = Dictation.keepAudio
    @Published var inputMonitoring = DictationKeys.inputMonitoring
    @Published var accessibility = DictationKeys.accessibility
    @Published var tap = Dictation.shared.tapInstalled
    @Published var listener = Dictation.shared.listenerKind
    @Published var lastOther = Dictation.shared.lastKeyFromOtherApp
    @Published var mic = SystemAccess.state(.microphone)
    @Published var fnCapture = Dictation.fnCapture
    @Published var fnFiltering = Dictation.shared.fnFiltering
    @Published var fnUsage: FnUsage? = SystemAccess.fnUsage
    @Published var fnApps: [String] = SystemAccess.fnClashApps
    @Published var historyCount = 0
    @Published var contextOn = Dictation.contextOn
    @Published var learnOn = Dictation.learnOn
    /// the Words summary: the user's own words, suggestions waiting
    @Published var wordCounts = (mine: 0, suggested: 0)
    private var timer: Timer?

    func start() {
        Dictation.shared.seedVocabulary()
        refresh()
        emit(["event": "dictation_pane", "tap": tap])
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        Task { await DictationModels.shared.load() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        let tr = Dictation.translateConfig      // an app accepted on the island shows up here
        if tr != translate { translate = tr }
        let im = DictationKeys.inputMonitoring, ax = DictationKeys.accessibility, t = Dictation.shared.tapInstalled
        if im != inputMonitoring { inputMonitoring = im }
        if ax != accessibility { accessibility = ax }
        let l = Dictation.shared.listenerKind, o = Dictation.shared.lastKeyFromOtherApp
        if l != listener { listener = l; emit(["event": "dictation_pane", "listener": l.rawValue]) }
        if o != lastOther { lastOther = o }
        let mc = SystemAccess.state(.microphone), ff = Dictation.shared.fnFiltering, fu = SystemAccess.fnUsage, fa = SystemAccess.fnClashApps
        if mc != mic { mic = mc }
        if ff != fnFiltering { fnFiltering = ff }
        if fu != fnUsage { fnUsage = fu; emit(["event": "dictation_pane", "fn_usage": fu?.rawValue ?? NSNull()]) }
        if fa != fnApps { fnApps = fa }
        if t != tap {
            tap = t
            emit(["event": "dictation_pane", "tap": t])
        }
        let n = DictationHistory.shared.load().count
        if n != historyCount { historyCount = n }
        let st = Dictation.styleConfig          // a learned suggestion accepted on the island shows up here
        if st != styles { styles = st }
        let s = DictationStyleChoice.current(polishOff: !Dictation.polishOn, config: st)
        if s != style { style = s }
        let all = DictationVocabulary.shared.load()
        // the Words tab's own count (its "Yours" group), so the two places never say different numbers
        let wc = (mine: DictationVocabulary.groups(all).own.count,
                  suggested: all.filter { $0.state == .suggested }.count)
        if wc != wordCounts { wordCounts = wc }
    }

    // MARK: words, microphone

    func setContext(_ v: Bool) { contextOn = v; save("context", v ? nil : false) }
    func setLearn(_ v: Bool) { learnOn = v; save("learn", v ? nil : false) }
    /// nil = Automatic (the Mac's own mic when the default input is Bluetooth), true = always the Mac's, false = always
    /// the default input (DictationMicChoice)
    @Published var micChoice = Dictation.builtInMicSetting
    @Published var startSound = DictationSound.startOn
    @Published var stopSound = DictationSound.stopOn
    func setMic(_ v: Bool?) {
        micChoice = v
        save("builtin_mic", v)
        MicEngine.shared.prepare(builtIn: Dictation.useBuiltInMic)
    }
    func setStartSound(_ v: Bool) { startSound = v; save("sounds", v ? nil : false) }
    func setStopSound(_ v: Bool) { stopSound = v; save("stop_sound", v ? true : nil) }
    @Published var onlyMyVoice = Dictation.onlyMyVoice
    func setOnlyMyVoice(_ v: Bool) { onlyMyVoice = v; save("only_my_voice", v ? true : nil) }
    @Published var cancelKey = Dictation.cancelKey
    func setCancelKey(_ k: Dictation.CancelKey) { cancelKey = k; save("cancel_key", k == .esc ? nil : k.rawValue) }

    private func save(_ key: String, _ value: Any?) {
        Dictation.set(key, value)
        Dictation.shared.apply()
        emit(["event": "dictation_setting", "key": key, "value": value.map { "\($0)" } ?? "default"])
    }

    func setEnabled(_ v: Bool) { enabled = v; save("enabled", v ? nil : false) }
    // stored even when it is the default: a later default (≤ 0.8: right ⌥, tap) never moves a choice the user made
    func setKey(_ v: DictationTrigger.Key) { key = v; save("key", v.rawValue); refresh() }
    func setMode(_ v: DictationTrigger.Mode) { mode = v; save("mode", v.rawValue) }
    func setDoubleTap(_ v: Bool) { doubleTap = v; save("double_tap_send", v ? nil : false) }
    /// ⇧ / ⌘ alone: double tap (the default) or single tap, both keys from one choice
    func setModifierTap(_ v: DictationTrigger.ModifierTap) { modifierTap = v; save("modifier_tap", v == DictationTrigger.shippedModifierTap ? nil : v.rawValue) }
    func setFnCapture(_ v: Bool) { fnCapture = v; save("fn_capture", v ? nil : false); refresh() }
    func setTimeout(_ s: Double) { timeout = s; save("polish_timeout_ms", Int(s * 1000) == 3000 ? nil : Int(s * 1000)) }
    func setRetention(_ d: Int) {
        retention = d
        save("retention_days", d == 30 ? nil : d)
        DispatchQueue.global(qos: .utility).async { DictationHistory.shared.prune(days: d) }
    }
    func setKeepAudio(_ v: Bool) { keepAudio = v; save("keep_audio", v ? nil : false) }

    // MARK: translate (dictation-translate.md)

    @Published var translate = Dictation.translateConfig
    func setTranslate(_ change: (inout DictationTranslateConfig) -> Void) {
        var c = Dictation.translateConfig
        change(&c)
        Dictation.setTranslateConfig(c)
        translate = c
        emit(["event": "dictation_setting", "key": "translate", "target": c.target.rawValue, "cloud": c.cloud, "apps": c.apps.count])
    }

    // MARK: style (dictation-styles.md)

    @Published var styles = Dictation.styleConfig
    @Published var style = DictationStyleChoice.current(polishOff: !Dictation.polishOn, config: Dictation.styleConfig)
    @Published var suggestLists = Dictation.suggestLists
    @Published var learnStyles = Dictation.learnStyles

    /// The one Style choice: Verbatim turns polish off; the others turn it on with that style as the default.
    func setStyle(_ s: DictationStyle) {
        let r = DictationStyleChoice.apply(s, to: Dictation.styleConfig)
        Dictation.setStyleConfig(r.config)
        styles = r.config
        style = s
        save("polish", r.polish)
        emit(["event": "dictation_setting", "key": "style", "value": s.rawValue])
    }
    /// a category's style; nil = the default above
    func setStyle(_ s: DictationStyle?, for c: DictationAppCategory) {
        var cfg = Dictation.styleConfig
        cfg.categories[c] = s
        Dictation.setStyleConfig(cfg)
        styles = cfg
        emit(["event": "dictation_setting", "key": "styles.\(c.rawValue)", "value": s?.rawValue ?? "default"])
    }
    /// an app set on its own (by a learned suggestion) back to its category's style
    func resetApp(_ bundle: String) {
        var cfg = Dictation.styleConfig
        cfg.apps[bundle] = nil
        cfg.learned.remove(bundle)
        Dictation.setStyleConfig(cfg)
        styles = cfg
        emit(["event": "dictation_setting", "key": "styles.apps", "value": "reset \(bundle)"])
    }
    func setSuggestLists(_ v: Bool) { suggestLists = v; save("suggest_lists", v ? nil : false) }
    func setLearnStyles(_ v: Bool) { learnStyles = v; save("learn_styles", v ? nil : false) }
    /// an app's name from its bundle id (AppNames: the running or installed app's; else "Unknown app", never the id)
    func appName(_ bundle: String) -> String { AppNames.displayOrUnknown(name: nil, bundle: bundle) }

    func clearHistory() {
        DictationHistory.shared.clear()
        DictationHistoryWindow.shared.reloadIfOpen()
        refresh()
    }

    /// Saved dictations whose recording is still on disk (Keep the audio, a failed take kept for Retry, the Lab's
    /// "keep the next N"): the clear question names recordings only when there are some.
    func savedRecordings() -> Int {
        let h = DictationHistory.shared, fm = FileManager.default
        return h.load().filter { e in e.audio.map { fm.fileExists(atPath: h.resolve($0).path) } ?? false }.count
    }

    /// The clear question while it shows: one at a time.
    private(set) var asking: NSAlert?

    /// Clear History…: an alert sheet on the Settings window, like System Settings' own — the app icon, the question,
    /// what goes (the count; the recordings only when some are kept) and that it can't be undone, on its own line.
    /// Cancel is the default (↩ and Esc both keep the history); Clear History is the red one and has to be clicked.
    func askClear() {
        refresh()
        let n = historyCount
        guard n > 0, asking == nil else { return }
        let audio = savedRecordings()
        let a = NSAlert()
        a.alertStyle = .warning
        a.icon = NSApp.applicationIconImage
        a.messageText = T("dictation.history.clear.title")
        a.informativeText = TP(audio > 0 ? "dictation.history.clear.message_audio" : "dictation.history.clear.message", n)
            + "\n" + T("dictation.history.clear.undo")
        let cancel = a.addButton(withTitle: T("dictation.cancel"))       // first: the default (↩, drawn filled)
        cancel.keyEquivalent = "\r"
        let clear = a.addButton(withTitle: T("dictation.history.clear.confirm"))
        clear.keyEquivalent = ""
        // the system's quiet red (its own capsule; macOS 26 ignores a title colour or tint on alert buttons): next to
        // the filled Cancel it never stands out (system.md: a destructive button is never the one that does)
        clear.hasDestructiveAction = true
        asking = a
        emit(["event": "dictation_clear_ask", "count": n, "recordings": audio])
        // Esc answers Cancel as well: NSAlert gives Esc only to a Cancel that isn't also the ↩ default
        let esc = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak a] e in
            guard e.keyCode == 53, let a = a, e.window === a.window else { return e }
            a.buttons.first?.performClick(nil)
            return nil
        }
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            if let m = esc { NSEvent.removeMonitor(m) }
            guard let self = self else { return }
            self.asking = nil
            let yes = r == .alertSecondButtonReturn
            emit(["event": "dictation_clear", "cleared": yes])
            if yes { self.clearHistory() }
        }
        // test screenshots taken in the background: the sheet drawn as the user sees it, Cancel filled as the default
        if SettingsTestKeyLook.on { SettingsTestKeyLook.apply(to: a.window) }
        if let w = NSApp.windows.first(where: { $0 is SettingsWindow && $0.isVisible }) {
            a.beginSheetModal(for: w, completionHandler: done)
        } else { done(a.runModal()) }
    }
}

/// Only my voice (issue #26, docs/design/voiceprint.md): the voice profile behind the switch. It is set up by reading a
/// passage aloud (VoiceprintSheet), with the microphone dictation uses; the speech tools learn it (transcribe.py
/// `voiceprint enroll`, the CLI — it may download the ~28 MB model, which the warm server never waits for) and it keeps
/// learning from dictation. The switch only turns on with a profile in place. The profile stays on this Mac
/// ($BLURT_HOME/voiceprint.json); the passage's recording is deleted once it is learned.
@MainActor
final class VoiceprintModel: ObservableObject {
    enum Phase: Equatable { case idle, starting, recording, saving }
    @Published var phase: Phase = .idle
    @Published var enrolled = false
    /// a profile an older voice model made: it can't be used until the passage is read again
    @Published var stale = false
    @Published var modelReady = false
    /// the model is being downloaded (the sheet opened without it)
    @Published var downloading = false
    /// how much of the passage has been heard (0…1), for the sheet
    @Published var progress: Double = 0
    /// a failure to say in the sheet (already localized)
    @Published var failed: String?
    private var voice: NoteVoice?
    private var ticker: Timer?
    private var prepared: Task<Void, Never>?
    /// the passage's recording (deleted once the speech tools have it)
    static let wavURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("blurt-voiceprint.wav")
    /// seconds of speech that make a good profile (the whole passage, read at an ordinary pace: ~15 s of audio); 6 is
    /// about the least the speech tools accept; a minute ends the take whatever was said. Learning from dictation does
    /// the rest, so a longer take isn't needed (nor harmful: its 5 s windows are averaged)
    static let enough = 12.0, least = 6.0

    var canFinish: Bool { phase == .recording && progress * Self.enough >= Self.least }

    func refresh() {
        request(["cmd": "vp_status"], cli: ["voiceprint", "status"], timeout: 30) { [weak self] r in
            guard let self, let r, r["ok"] as? Bool == true else { return }
            apply(r)
        }
    }

    private func apply(_ r: [String: Any]) {
        enrolled = r["enrolled"] as? Bool ?? false
        stale = r["stale"] as? Bool ?? false
        modelReady = r["model_ready"] as? Bool ?? false
        // a profile deleted elsewhere (or never made): the switch can't stay on
        if !enrolled, Dictation.onlyMyVoice { Config.shared.set("record.dictation.only_my_voice", nil) }
    }

    /// The sheet opened: the model comes down while the passage is read.
    func prepare() {
        failed = nil
        guard !modelReady, prepared == nil else { return }
        downloading = true
        prepared = Task { [weak self] in
            let r = try? await ScriptRunner.shared.json("transcribe.py", ["voiceprint", "prepare"], timeout: 600)
            guard let self else { return }
            downloading = false
            prepared = nil
            if let r, r["ok"] as? Bool == true { apply(r) } else if phase != .saving { failed = T("dictation.voiceprint.network") }
        }
    }

    func start() {
        failed = nil
        progress = 0
        let url = Self.wavURL
        try? FileManager.default.removeItem(at: url)
        let v = NoteVoice(url: url)
        v.builtInMic = Dictation.useBuiltInMic          // the microphone dictation uses
        v.silenceToEnd = .infinity                      // Done ends the take, not a pause between sentences
        v.noSpeechTimeout = 8                           // …but a take nobody reads into ends itself
        v.maxLength = 60
        v.onEnd = { [weak self] e in Task { @MainActor in
            guard let self, self.phase == .recording || self.phase == .starting else { return }
            if e == .maxed { self.finish() } else { self.stopRecording(); self.failed = T("dictation.voiceprint.too_short") }
        } }
        phase = .starting
        v.start { [weak self] ok in Task { @MainActor in
            guard let self, self.phase == .starting else { return }
            if ok { self.phase = .recording } else { self.stopRecording(); self.failed = T("dictation.voiceprint.mic_failed") }
        } }
        voice = v
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in
            guard let self, let v = self.voice, self.phase == .recording else { return }
            self.progress = min(1, v.speechSeconds / Self.enough)
            // the passage is read (or the reader stopped after enough of it): no need to tap Done
            if self.progress >= 1 || (self.canFinish && v.quietSeconds >= 2.5) { self.finish() }
        } }
    }

    func cancel() {
        stopRecording()
        try? FileManager.default.removeItem(at: Self.wavURL)
    }

    private func stopRecording() {
        ticker?.invalidate(); ticker = nil
        voice?.stop(keep: false); voice = nil
        phase = .idle
    }

    /// The passage is read: stop the microphone, learn the voice. `done` runs once it is learned.
    var learned: (() -> Void)?
    func finish() {
        guard phase == .recording else { return }
        ticker?.invalidate(); ticker = nil
        let v = voice
        voice = nil
        v?.stop(keep: true)
        phase = .saving
        Task { [weak self] in
            await self?.prepared?.value                 // one download at a time
            let r = try? await ScriptRunner.shared.json("transcribe.py", ["voiceprint", "enroll", Self.wavURL.path], timeout: 600)
            try? FileManager.default.removeItem(at: Self.wavURL)
            guard let self else { return }
            phase = .idle
            guard let r, r["ok"] as? Bool == true else {
                let code = (r?["code"] as? String) ?? "error"
                failed = code == "too_short" ? T("dictation.voiceprint.too_short")
                    : code == "network" || code == "model_missing" ? T("dictation.voiceprint.network")
                    : T("dictation.voiceprint.failed", code)
                return
            }
            apply(r)
            emit(["event": "voiceprint_enrolled", "takes": r["takes"] ?? 0, "audio_s": r["audio_seconds"] ?? 0])
            learned?()
        }
    }

    func forget() {
        request(["cmd": "vp_clear"], cli: ["voiceprint", "clear"], timeout: 15) { [weak self] r in
            guard let self, let r, r["ok"] as? Bool == true else { return }
            apply(r)
        }
    }

    /// The warm speech server when one runs (no process start), else the CLI. The answer lands on the main actor;
    /// nil = the tools couldn't run at all.
    private func request(_ req: [String: Any], cli: [String], timeout: Double, done: @escaping @MainActor ([String: Any]?) -> Void) {
        Task.detached {
            var answer = WarmServer.running("asr-serve") ? WarmServer.call("asr-serve", req, timeout: timeout) : nil
            if answer == nil { answer = try? await ScriptRunner.shared.json("transcribe.py", cli, timeout: timeout) }
            await done(answer)
        }
    }
}

/// Reading the passage: the text, the microphone's level, how much has been heard; the model downloads meanwhile.
struct VoiceprintSheet: View {
    @ObservedObject var vp: VoiceprintModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(T("dictation.voiceprint.title")).font(.system(size: 15, weight: .semibold))
            Text(T("dictation.voiceprint.read")).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(T("dictation.voiceprint.passage"))
                .font(.system(size: 14)).lineSpacing(4)
                .foregroundStyle(vp.phase == .recording ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Image(systemName: vp.phase == .recording ? "mic.fill" : "mic")
                    .foregroundStyle(vp.phase == .recording ? Color.brandAccent : Color.secondary)
                    .frame(width: 14)
                PassageBar(value: vp.progress).frame(height: 6)
            }
            Text(status).font(.system(size: 12))
                .foregroundStyle(vp.failed != nil ? Color.brandAttnInk : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(T("dictation.voiceprint.private")).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button(T("dictation.voiceprint.cancel")) { vp.cancel(); close() }.keyboardShortcut(.cancelAction)
                    .disabled(vp.phase == .saving)
                switch vp.phase {
                case .idle:
                    Button(T("dictation.voiceprint.start")) { vp.start() }.keyboardShortcut(.defaultAction)
                case .starting, .recording:
                    Button(T("dictation.voiceprint.done")) { vp.finish() }.keyboardShortcut(.defaultAction)
                        .disabled(!vp.canFinish)
                case .saving:
                    ProgressView().controlSize(.small).frame(width: 60)
                }
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { vp.prepare() }
        .onDisappear { if vp.phase != .saving { vp.cancel() } }
    }

    private var status: String {
        if let f = vp.failed { return f }
        switch vp.phase {
        case .starting: return T("dictation.voiceprint.starting")
        case .recording: return T("dictation.voiceprint.recording")
        case .saving: return T(vp.downloading ? "dictation.voiceprint.downloading" : "dictation.voiceprint.saving", VoiceprintModel.modelMB)
        case .idle: return vp.downloading ? T("dictation.voiceprint.downloading", VoiceprintModel.modelMB) : " "
        }
    }
}

extension VoiceprintModel {
    /// the voice model's download size (transcribe.py VP_MB)
    static let modelMB = 30
}

/// How much of the passage has been heard, in the brand accent (a native progress bar turns grey while the window
/// isn't key — Settings shows without taking focus).
private struct PassageBar: View {
    var value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .quaternaryLabelColor))
                Capsule().fill(Color.brandAccent).frame(width: g.size.width * CGFloat(min(1, max(0, value))))
            }
        }
        .animation(.easeOut(duration: 0.2), value: value)
    }
}

struct DictationPane: View {
    /// tests: `dictation settings-scroll style|models|words|history|mic|only_my_voice|voiceprint` (a screenshot of a row
    /// further down; voiceprint: Only my voice's sheet)
    static let scrollRequest = Notification.Name("BlurtDictationPaneScroll")
    @StateObject var m = DictationSettings()
    @StateObject var vp = VoiceprintModel()
    @State var voiceSheet = false
    @StateObject var perms = Permissions()
    @ObservedObject var models = DictationModels.shared
    @ObservedObject var guide = PermissionGuide.shared
    @State var showByApp = false
    @State var lab = DictationLabModel.enabled

    private let nav = SettingsNavigator.shared       // not observed: the pane needn't redraw as the search is typed

    var body: some View {
        SettingsPage(.dictation) {
            if guide.finished != nil { PermissionDoneBanner().padding(.top, 12) }   // the permission guide just finished
            notice
            SettingsGroup("dictation.main") { mainRows }
            SettingsGroup("dictation.text") { textRows }
            SettingsGroup("dictation.translation") { translateRows }
            SettingsGroup("dictation.data") {
                historyRow
                SettingToggle("dictation.keep_audio", isOn: Binding(get: { m.keepAudio }, set: { m.setKeepAudio($0) }),
                              detail: T("dictation.history.keep_audio.detail.days", T("dictation.history.days", m.retention)))
                modelsRow
            }

            // the page's foot, shown open like every section (folded until v1.0.2)
            SettingsGroup("dictation.advanced") {
                SettingToggle("dictation.lab", isOn: Binding(get: { lab }, set: { v in
                    lab = v
                    Config.shared.set("record.dictation.lab", v ? true : nil)
                }))
            }
        }
        // tests: `dictation settings-scroll style|models|words|history|mic`
        .onReceive(NotificationCenter.default.publisher(for: DictationPane.scrollRequest)) { n in
            guard let id = n.object as? String else { return }
            if id == "style" { showByApp = true }
            if id == "voiceprint-start" { vp.start(); return }     // tests: the sheet's Start Recording / Done
            if id == "voiceprint-done" { vp.finish(); return }
            if id == "voiceprint" {     // tests: `dictation settings-scroll voiceprint` — Only my voice's sheet
                nav.reveal("dictation.only_my_voice")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { voiceSheet = true }
                return
            }
            if id == "clear" {      // tests: `dictation clear ask` — the History section in view, then the question
                nav.reveal("dictation.history_saved")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { m.askClear() }
                return
            }
            let rows = ["style": "dictation.text", "words": "dictation.word_list", "history": "dictation.history_saved"]
            nav.reveal(rows[id] ?? "dictation.\(id)")
        }
        // a search or a link landing on a row that is folded away: unfold it first
        .onReceive(SettingsFlash.shared.$request) { r in
            guard let id = r?.id else { return }
            if id == "dictation.by_app" || SettingsCatalog.entry(id)?.fold == "dictation.by_app" { showByApp = true }
        }
        .onAppear { m.start(); perms.start(); vp.refresh() }
        .onDisappear { m.stop(); perms.stop() }
    }

    // MARK: how dictating works

    @ViewBuilder var mainRows: some View {
        SettingToggle("dictation.enable", isOn: Binding(get: { m.enabled }, set: { m.setEnabled($0) }), help: m.enabled ? listenerLine : nil)
        Group {
            SettingRow("dictation.key", detail: keyDetail?.text, help: keyDetail?.help, detailColor: keyDetail?.warn == true ? .brandAttnInk : nil,
                       hosts: ["dictation.fn_capture"]) {
                ChoicePopup(label: T("dictation.settings.key"),
                            choices: DictationTrigger.Key.allCases.map { ($0, Dictation.keyName($0)) },     // Fn first
                            selection: Binding(get: { m.key }, set: { m.setKey($0) }),
                            checks: m.key == .fn ? [SettingMenuToggle("dictation.fn_capture", isOn: Binding(get: { m.fnCapture }, set: { m.setFnCapture($0) }))] : [])
            }
            SettingRow("dictation.mode", detail: T("dictation.mode.\(m.mode.rawValue).detail", Dictation.keyInline(m.key)),
                       help: T("dictation.mode.help", m.cancelKey.label, hk(.voice).isEmpty ? T("dictation.settings.voice_note_off") : hk(.voice))) {
                ChoicePopup(label: T("dictation.settings.mode"), choices: DictationTrigger.Mode.allCases.map { ($0, T("dictation.mode.\($0.rawValue)")) },
                            selection: Binding(get: { m.mode }, set: { m.setMode($0) }))
            }
            SettingRow("dictation.cancel_key", detail: T("dictation.settings.cancel_key.detail")) {
                ChoicePopup(label: T("dictation.settings.cancel_key"),
                            choices: Dictation.CancelKey.allCases.map { ($0, $0 == .esc ? T("dictation.settings.cancel_key.default", $0.label) : $0.label) },
                            selection: Binding(get: { m.cancelKey }, set: { m.setCancelKey($0) }))
            }
            SettingToggle("dictation.double_tap", isOn: Binding(get: { m.doubleTap }, set: { m.setDoubleTap($0) }),
                          detail: T("dictation.settings.double_tap.key", Dictation.keyShort(m.key)), help: T("dictation.settings.double_tap.help"))
            SettingRow("dictation.modifier_tap", detail: T("dictation.settings.modifier_tap.detail")) {
                ChoicePopup(label: T("dictation.settings.modifier_tap"),
                            choices: DictationTrigger.ModifierTap.allCases.map { ($0, T("dictation.mode.modifier.\($0.rawValue)")) },
                            selection: Binding(get: { m.modifierTap }, set: { m.setModifierTap($0) }))
            }
            SettingRow("dictation.mic") {
                ChoicePopup(label: T("dictation.mic.section"),
                            choices: [(nil, T("dictation.mic.auto")), (true, T("dictation.mic.mac")), (false, T("dictation.mic.default"))],
                            selection: Binding(get: { m.micChoice }, set: { m.setMic($0) }))
            }
            onlyMyVoiceRow
            SettingToggle("dictation.sounds", isOn: Binding(get: { m.startSound }, set: { m.setStartSound($0) }))
            SettingToggle("dictation.stop_sound", isOn: Binding(get: { m.stopSound }, set: { m.setStopSound($0) }))
        }
        .disabled(!m.enabled)
    }

    /// Only my voice: the switch, and beside it (once a voice is set up) Record Again / Delete. Turning it on without a
    /// voice profile opens the passage to read; it turns on once the voice is learned.
    @ViewBuilder var onlyMyVoiceRow: some View {
        let label = T("dictation.only_my_voice")
        SettingRow("dictation.only_my_voice",
                   detail: T(vp.stale ? "dictation.only_my_voice.stale" : "dictation.only_my_voice.detail"),
                   detailColor: vp.stale ? .brandAttnInk : nil) {
            HStack(spacing: 6) {
                RowMenu(label: T("dictation.voiceprint.more"), visible: vp.enrolled || vp.stale) {
                    Button(T("dictation.voiceprint.again")) { voiceSheet = true }
                    Button(T("dictation.voiceprint.delete"), role: .destructive) {
                        m.setOnlyMyVoice(false)
                        vp.forget()
                    }
                }
                Toggle(label, isOn: Binding(get: { m.onlyMyVoice && vp.enrolled }, set: { on in
                    if on && !vp.enrolled { voiceSheet = true } else { m.setOnlyMyVoice(on) }
                }))
                .labelsHidden().toggleStyle(BrandSwitchStyle(label: label))
            }
        }
        .sheet(isPresented: $voiceSheet) {
            VoiceprintSheet(vp: vp) { voiceSheet = false }
                .onAppear { vp.learned = { m.setOnlyMyVoice(true); voiceSheet = false } }
        }
    }

    /// The key's one line, only when there is something to say: another Fn dictation app running (attention), or
    /// how "either ⌥" counts a tap.
    var keyDetail: (text: String, help: String?, warn: Bool)? {
        if m.key == .fn, !m.fnApps.isEmpty {
            return (T("dictation.settings.fn_clash", m.fnApps.joined(separator: T("settings.perm.list_sep"))), T("dictation.settings.fn_clash.help"), true)
        }
        if m.key == .eitherOption { return (T("dictation.settings.either_hint"), nil, false) }
        return nil
    }

    /// Which listener runs, and the one thing only the user can prove: the key heard while another app is in front.
    var listenerLine: String {
        let l = T("dictation.listener.\(m.fnFiltering && m.listener == .tap ? "filter" : m.listener.rawValue)")
        let h = m.lastOther.map { T("dictation.heard.other", heardTime($0)) } ?? T("dictation.heard.never", Dictation.keyInline(m.key))
        let restart = m.inputMonitoring && m.listener != .tap ? [T("dictation.perm.restart_hint")] : []
        return ([l, h] + restart).joined(separator: Loc.isChinese ? "" : " ")
    }

    // MARK: the notice: only while dictation can't work

    /// One line at the top for the one thing in the way, most basic first; nothing while dictation is off or works.
    @ViewBuilder var notice: some View {
        if m.enabled {
            let missing = guide.missing(.dictation).filter { $0 != .fnKey }
            let _ = perms.accessibility                 // re-evaluated as the states change (once a second)
            Group {
                if !m.tap, Dictation.shared.deferredTo != nil, HotkeySettings.solo {
                    EmptyView()                     // screenshots beside the user's own Blurt: as if this one were alone
                } else if !m.tap, Dictation.shared.deferredTo != nil {
                    // another Blurt has the key (this one takes over when that one quits): the same notice and the same
                    // way out as the Shortcuts page's — the key named, one copy one "Quit Other Copy"
                    let keys = HotkeySettings.shared
                    SettingsNotice(title: T("dictation.status.other_instance_key", Dictation.keyInline(m.key)),
                                   detail: T("dictation.status.other_instance.detail")) {
                        if !keys.otherApps.isEmpty {
                            Button(keys.quitting ? Loc.t("capture.keys.quitting", table: "Capture")
                                   : Loc.t(keys.others.count > 1 ? "capture.keys.quit_others" : "capture.keys.quit_other", table: "Capture")) {
                                keys.quitOthers()
                            }
                            .disabled(keys.quitting)
                        }
                    }
                } else if !missing.isEmpty {
                    SettingsNotice(title: T("dictation.notice.needs", missing.map(PermissionGuide.name).joined(separator: T("settings.perm.list_sep"))),
                                   detail: missing.count == 1 ? PermissionGuide.why(missing[0]) : nil) {
                        Button(guide.running ? T("settings.perm.setup_running") : T("settings.kit.allow")) {
                            guide.start(.dictation, source: .dictation)
                        }
                        .buttonStyle(SettingsOutlinedButtonStyle())
                    }
                } else if !m.tap {
                    SettingsNotice(title: T("dictation.status.off", Dictation.keyInline(m.key)), detail: T("dictation.status.off.detail")) {
                        Button(T("dictation.status.fix")) { Dictation.shared.openSetup(from: "dictation") }
                    }
                } else if m.key == .fn, FnUsage.clashes(m.fnUsage) {
                    // macOS's own "Press Globe key to" (read live; Fix… walks the user there with the helper panel,
                    // Blurt never changes it)
                    SettingsNotice(title: T("dictation.fn.usage", T("dictation.fn_usage.\(m.fnUsage.map { "\($0.rawValue)" } ?? "default")")),
                                   detail: T("dictation.fn.usage.clash")) {
                        Button(T("dictation.fn.usage.fix")) { PermissionGuide.shared.start(.dictation, only: [.fnKey], source: .dictation) }
                    }
                }
            }
            .padding(.top, SettingsMetrics.groupGap)
        }
    }

    // MARK: what comes out: style, words, history, models

    @ViewBuilder var textRows: some View {
        SettingRow("dictation.default_style", detail: T("dictation.style.\(m.style.rawValue).detail")) {
            ChoicePopup(label: T("dictation.style.default"), choices: [DictationStyle.verbatim, .light, .structured, .auto].map { ($0, Dictation.styleName($0)) },
                        selection: Binding(get: { m.style }, set: { m.setStyle($0) }))
        }
        .disabled(!m.enabled)
        if m.style != .verbatim {
            SettingRow("dictation.by_app", detail: byAppSummary) {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(showByApp ? 90 : 0))
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showByApp.toggle() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(showByApp ? "1" : "0")
            .accessibilityAction { showByApp.toggle() }
            .disabled(!m.enabled)
            if showByApp {
                // the folded rows in the same box, on the same text column (the chevron above says they belong to it)
                VStack(alignment: .leading, spacing: 0) { byApp }
                    .disabled(!m.enabled)
            }
        }
        wordsRow
    }

    /// Translate (⌘), its own box (2026-10-30): into what — dictation's own target, not ⌥T's (writing your words in
    /// another language usually goes the other way from reading) —, the model that translates (Settings → Models'
    /// Translate row, said here with Change…), and the apps where it starts on (read and remove; ⌘ in an app adds
    /// it, ⌘ again removes it).
    @ViewBuilder var translateRows: some View {
        SettingRow("dictation.translate", detail: TranslateTargets.autoNote(m.translate.target) ?? T("dictation.translate.settings.detail")) {
            // Auto first, named by its pair (TranslateTargets: global-first), then every language by its own name
            ChoicePopup(label: T("dictation.translate.settings.title"), choices: TranslateTargets.choices(),
                        selection: Binding(get: { m.translate.target }, set: { v in m.setTranslate { $0.target = v } }),
                        width: TranslateTargets.popupWidth, dividers: [1])
        }
        .disabled(!m.enabled)
        // which model translates is Settings → Models' Translate row: here, what it is now and the way there
        CloudObserving {
            SettingRow("dictation.translate_model", detail: CloudText.uses(.translate)) { JobChangeButton(job: .translate) }
        }
        if !m.translate.apps.isEmpty {
            SettingsLine(padding: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Hint(T("dictation.translate.apps"))
                    Text(T("dictation.translate.apps.note")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(m.translate.apps.sorted(), id: \.self) { b in
                SettingsLine(padding: 8) {
                    HStack(spacing: 8) {
                        Text(m.appName(b)).font(.system(size: SettingsMetrics.titleSize))
                        Spacer()
                        Button(T("dictation.translate.apps.remove")) { m.setTranslate { $0.apps.remove(b) } }
                            .buttonStyle(SettingsOutlinedButtonStyle(compact: true))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// What is set per kind of app ("Code and terminals: Verbatim · 2 apps on their own"); else what the row is for.
    var byAppSummary: String? {
        var parts = DictationAppCategory.allCases.compactMap { c in
            m.styles.categories[c].map { T("dictation.style.by_app.pair", T("dictation.style.cat.\(c.rawValue)"), Dictation.styleName($0)) }
        }
        if !m.styles.apps.isEmpty { parts.append(T("dictation.style.by_app.apps", m.styles.apps.count)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder var byApp: some View {
        ForEach(DictationAppCategory.allCases, id: \.self) { c in
            SettingRow("dictation.cat.\(c.rawValue)") {
                ChoicePopup(label: T("dictation.style.cat.\(c.rawValue)"),
                            choices: [(DictationStyle?.none, T("dictation.style.follow", Dictation.styleName(m.style)))]
                                + DictationStyle.allCases.map { (Optional($0), Dictation.styleName($0)) },
                            selection: Binding(get: { m.styles.categories[c] }, set: { m.setStyle($0, for: c) }))
            }
        }
        if !m.styles.apps.isEmpty {
            SettingsLine(padding: 8) { Hint(T("dictation.style.apps")) }
            ForEach(m.styles.apps.keys.sorted(), id: \.self) { b in
                SettingsLine(padding: 8) {
                    HStack(spacing: 8) {
                        Text(m.appName(b)).font(.system(size: SettingsMetrics.titleSize))
                        if m.styles.learned.contains(b) { Badge(T("dictation.style.learned")) }
                        Spacer()
                        Text(Dictation.styleName(m.styles.apps[b] ?? .light)).foregroundStyle(.secondary)
                        Button(T("dictation.style.reset")) { m.resetApp(b) }.buttonStyle(SettingsOutlinedButtonStyle(compact: true)).help(T("dictation.style.reset.help"))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        SettingToggle("dictation.suggest_lists", isOn: Binding(get: { m.suggestLists }, set: { m.setSuggestLists($0) }))
        SettingToggle("dictation.learn_styles", isOn: Binding(get: { m.learnStyles }, set: { m.setLearnStyles($0) }))
        SettingRow("dictation.polish_timeout",
                   detail: hk(.reformat).isEmpty ? T("dictation.style.keys.no_hotkey") : T("dictation.style.keys", hk(.reformat))) {
            HStack(spacing: 6) {
                Text(T("dictation.polish.seconds", seconds(m.timeout))).foregroundStyle(.secondary).monospacedDigit()
                Stepper(T("dictation.polish.timeout"), value: Binding(get: { m.timeout }, set: { m.setTimeout($0) }), in: 1...10, step: 0.5)
                    .labelsHidden()
            }
        }
    }

    /// "13 of your own · 1 to review" (the count that needs you in attention ink), Manage… with the two learning
    /// switches in its menu: set once, rarely touched.
    var wordsRow: some View {
        var summary = Text(T("dictation.vocab.summary.mine", m.wordCounts.mine))
        if m.wordCounts.suggested > 0 {
            summary = summary + Text(" · ") + Text(T("dictation.vocab.summary.suggested", m.wordCounts.suggested)).foregroundColor(.brandAttnInk)
        }
        return SettingRow("dictation.word_list", richDetail: summary, hosts: ["dictation.context", "dictation.learn"]) {
            Menu {
                SettingMenuToggle("dictation.context", isOn: Binding(get: { m.contextOn }, set: { m.setContext($0) }))
                SettingMenuToggle("dictation.learn", isOn: Binding(get: { m.learnOn }, set: { m.setLearn($0) }))
            } label: {
                Text(T("dictation.vocab.manage"))
            } primaryAction: { DictationHistoryWindow.shared.showWords() }
            .fixedSize()
        }
    }

    /// "9 saved · deleted after 30 days", Open History… — how long and the destructive Clear History… are in its
    /// menu, never a button at rest; keeping the audio is the row under it.
    var historyRow: some View {
        SettingRow("dictation.history_saved", detail: T("dictation.history.summary", m.historyCount, T("dictation.history.days", m.retention)),
                   hosts: ["dictation.history_keep"]) {
            Menu {
                SettingMenuPicker("dictation.history_keep", selection: Binding(get: { m.retention }, set: { m.setRetention($0) })) {
                    ForEach([7, 30, 90, 365], id: \.self) { d in Text(T("dictation.history.days", d)).tag(d) }
                }
                Divider()
                Button(T("dictation.history.clear"), role: .destructive) { m.askClear() }
                    .disabled(m.historyCount == 0)
            } label: {
                Text(T("dictation.history.open"))
            } primaryAction: { DictationHistoryWindow.shared.show() }
            .fixedSize()
        }
    }

    // MARK: models (chosen in Settings → Speech)

    /// One row for both models, said as Settings → Speech's rows say it: the names in use, what isn't on this Mac yet
    /// ("polish model not downloaded"), or the download's progress — and always one way on, a link to Speech, the one
    /// page that chooses them and offers the download. Never a second Download button, never a size that disagrees
    /// with Speech's.
    var modelsRow: some View {
        let s = modelsState
        let detail: String? = {
            switch s {
            case .loading: return nil
            case .coming(let j): return downloadLine(j)
            case .missing(let jobs):
                var parts: [String] = []
                // the recogniser in use (Speech's Dictation row names the same one), then what is still to come: only
                // the small voice detector, or the speech model itself
                let asrHere = models.asr?.selectedInstalled ?? models.selectedASR?.installed ?? false
                if asrHere, let a = models.selectedASR { parts.append(a.name ?? models.asrName(a.id)) }
                if jobs.count > 1 { parts.append(T("dictation.models.n_missing", jobs.count)) }
                else if let j = jobs.first(where: { $0.kind == .dictation }) {
                    parts.append(T(asrHere || j.sizeMB <= 1 ? "dictation.models.small_missing" : "dictation.models.asr_missing"))
                } else if jobs.contains(where: { $0.kind == .polish }) { parts.append(T("dictation.models.polish_missing")) }
                let line = parts.joined(separator: " · ")
                return line.prefix(1).uppercased(with: Loc.locale) + line.dropFirst()
            case .ready: return modelNames
            }
        }()
        return SettingRow("dictation.models", detail: detail) {
            switch s {
            case .loading: BrandSpinnerView()
            case .missing: TextLinkButton(T("dictation.models.get_in_speech")) { SpeechPane.showDictationModels() }
            case .coming, .ready: TextLinkButton(T("dictation.models.change")) { SpeechPane.showDictationModels() }
            }
        }
    }

    enum ModelsState { case loading, coming(ModelDownloadQueue.Job), missing([ModelDownloadQueue.Job]), ready }


    var modelsState: ModelsState {
        let dl = ModelDownloads.shared
        let polish = m.style != .verbatim
        if models.asr == nil && models.polish == nil { return .loading }
        let asrJob = models.dictationJob.flatMap { j in dl.queue.contains(j.id) ? j : nil }
            ?? dl.queue.pending.first { j in j.kind == .dictation && models.asr?.models.contains { $0.id == j.id } == true }
        if let j = asrJob ?? (polish ? dl.queue.pending.first { j in j.kind == .polish } : nil) { return .coming(j) }
        let missing = models.missingJobs(polish: polish)
        return missing.isEmpty ? .ready : .missing(missing)
    }

    /// "Qwen3-ASR 1.7B · Gemma 4 E2B": the recogniser in use, and the polish model while a style polishes.
    var modelNames: String? {
        var names: [String] = []
        if let a = models.selectedASR { names.append(a.name ?? models.asrName(a.id)) }
        if m.style != .verbatim, let c = CloudStore.cloudModel(.polish) {
            names.append(T("dictation.models.cloud", c.model))
        } else if m.style != .verbatim, let p = models.selectedPolish, p.installed { names.append(p.name) }
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }

    /// "Downloading · 1.2 GB of 2.5 GB" while it runs, "Waiting to download · 3.4 GB" while it waits its turn.
    func downloadLine(_ j: ModelDownloadQueue.Job) -> String {
        guard let p = models.progress(j.id) else { return T("dictation.models.queued", modelSize(j.sizeMB)) }
        return T("dictation.models.downloading", modelSize(p.done), modelSize(max(p.total, j.sizeMB)))
    }

    // MARK: formatting

    private func heardTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Loc.locale
        f.dateStyle = Calendar.current.isDateInToday(d) ? .none : .short
        f.timeStyle = .medium
        return f.string(from: d)
    }

    private func seconds(_ s: Double) -> String {
        let f = NumberFormatter()
        f.locale = Loc.locale
        f.maximumFractionDigits = 1
        return f.string(from: s as NSNumber) ?? "\(s)"
    }
}

/// A small capsule label next to a name ("Recommended", "Learned"): brand ink on the brand tint (§3.4); with a `tint`,
/// that colour as text on 15 % of itself.
struct Badge: View {
    let text: String
    var tint: Color?
    init(_ text: String, tint: Color? = nil) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(tint.map { $0.opacity(0.15) } ?? Color.brandTint))
            .foregroundStyle(tint ?? Color.brandInk)
    }
}
