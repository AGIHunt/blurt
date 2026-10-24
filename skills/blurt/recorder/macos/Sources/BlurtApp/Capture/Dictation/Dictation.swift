// Dictation (听写, docs/design/dictation.md): talk, and the words are typed into whichever app has the focus —
// separate from the voice note (⌥⇧V files into Blurt; the two never share a key).
//
//  • trigger: Fn (default; or right ⌥, or either ⌥) alone, read by an event tap (DictationKeys) and decided by
//    BlurtCore's DictationTrigger — auto (default: a tap is hands-free, holding is push-to-talk), tap / tap, or hold
//    to talk. Esc cancels. With Fn and Accessibility, the tap is an active filter that keeps the Fn press from macOS.
//    A double tap presses Return (record.dictation.double_tap_send, on): idle, it cancels the dictation its first tap
//    started and sends; right after a dictation stopped, Return goes in once the paste has landed.
//  • the key needs Accessibility (the Fn filter, or the monitor) or Input Monitoring (the listen-only tap). Until it
//    is heard (BlurtCore's DictationAccess decides): the menu-bar menu's top row says "Turn On Dictation…", the
//    island reminds about once a day (launch, the voice-note key, Settings), and both start the permission guide
//    (Onboarding/PermissionGuide.swift); a poll picks the grant up without a restart. macOS is never asked at launch.
//    Test builds never install a tap or ask macOS: BLURT_TEST_DICTATION_TAP=ok|failed (or `dictation tap …`)
//    simulates the answer.
//  • capture: NoteVoice (the voice note's mic → wav path; BLURT_TEST_MIC_WAV / BLURT_NOTE_WAV in tests), no silence
//    stop — you end it. The mic opens on the clean key-down (`arm`; MicEngine prepared it at launch), before the
//    trigger decides, and closes again if the press becomes a shortcut; the island says "listening" once audio
//    arrives. The models are warmed on key-down (offline-first spawns, WarmSpawn): `transcribe.py serve --preload
//    --purpose dictation` and, with polish on, `polish.py serve --preload`.
//  • text: DictationStream cuts the audio at pauses while the user talks and transcribes + polishes each piece as it
//    completes (the warm servers; a model still loading gets record.dictation.load_budget_ms, never counted against
//    polish_timeout_ms); at key-up only the last piece is left. Any fall-back = that piece's raw text.
//    The pieces' transcripts so far show under the island while the user talks (LiveTranscript, record.live_text,
//    on; DictationStream.onHeard) — out of the way of the caret (read once at the start), gone once the text is in.
//  • insert: DictationInsert (pasteboard → ⌘V into the app in front, DictationPastePolicy → pasteboard back).
//    History: DictationHistory (history.jsonl, with asr / polish / load / total ms).
//  • custom words (DictationVocabulary, vocabulary.json): sent with every request — the speech model is biased toward
//    them where it can be and exact sounds-likes are fixed (transcribe.py), polish gets them as spelling hints with
//    the text around the cursor (DictationContext, read at the start, never stored). After the text goes in, the
//    field is watched for a minute (DictationWatch) and the user's own fixes become words (DictationLearn).
//  • off while a screen recording runs (it owns the mic) and while a voice note listens.
// Config record.dictation: enabled (true), key fn|right_option|either_option (unset = fn), mode auto|tap|hold (unset =
// auto), fn_capture (true: keep Fn from macOS's own 🌐 action), polish off|light, polish_model,
// polish_timeout_ms, load_budget_ms (12000), streaming (true), precapture (true), builtin_mic (automatic), start_sound
// (false), retention_days (30), keep_audio (false), asr_model (automatic), context (true), learn (true),
// double_tap_send (true). Test hooks:
// DictationTestHooks.swift (`dictation …` on the test channel).
import AppKit
import BlurtCore
import Carbon.HIToolbox

final class Dictation {
    static let shared = Dictation()

    enum Phase: String { case idle, listening, transcribing, polishing }
    private(set) var phase: Phase = .idle {
        didSet {
            if phase != oldValue { island.dictationChanged() }
            // the words shown while talking go a moment after the text is in (or at once when nothing was kept)
            if phase == .idle, oldValue != .idle { LiveTranscript.shared.end(session: liveSession, after: 0.6) }
            updateShiftFilter()
        }
    }
    private(set) var levels: [Float] = []
    private(set) var lastResult: [String: Any]?
    var busy: Bool { phase != .idle }

    private var trigger = DictationTrigger()
    private let keys = DictationKeys()
    private var voice: NoteVoice?
    private var wav: URL?
    private(set) var entryID = ""
    private var startedAt = Date()
    private var heardSpeech = false
    /// pieces transcribed and polished while the user talks (DictationStream)
    private var stream: DictationStream?
    /// the mic was opened on the key-down (`arm`), before the trigger decided: kept by `start`, closed when the press
    /// turns out to be something else
    private var precaptured = false
    /// when the key went down (the mic's start latency is measured from here)
    private var armedAt: CFTimeInterval = 0
    /// audio is arriving: the island says "listening" only from here
    private(set) var micLive = false
    /// tests: the "microphone" (a wav) — `dictation wav PATH`, else BLURT_TEST_MIC_WAV / BLURT_NOTE_WAV
    var testWav: String?
    /// tests: stop the next dictation at this point of the wav, as a key-up would (`dictation stop-after S`): a release
    /// timed to the audio, which a command sent from outside can't be
    var testStopAfter: Double?
    private var front: NSRunningApplication?
    private var holdTimer: Timer?
    private var escRegistered = false
    private var polishServer: Process?
    /// `polish.py models` said a model is installed and selected (refreshed at launch and by Settings)
    private(set) var polishModel: String?
    private var generation = 0
    /// this take's live transcript (LiveTranscript's session)
    private var liveSession = 0
    /// the text around the cursor when this dictation started (polish's hints; never stored unless debugging)
    private var context: DictationContext?
    /// a double tap came while the text was still on its way: Return once it has been pasted
    private var sendAfterPaste = false
    /// the paste is under way (⌘V posted, the clipboard not back yet)
    private var inserting = false

    // the style of this take (DictationStyles.swift; docs/design/dictation-styles.md)
    /// the router's decision so far: the app's style at the key-down, then ⇧ / the island / Fn+⇧
    var styleDecision: DictationStyleRouter.Decision?
    /// ⇧ / the island / Fn+⇧ this take (the last choice wins), and how often it was switched
    var explicitStyle: (style: DictationStyle, source: DictationStyleSource)?
    var styleToggles = 0
    /// the bundle id the take goes into (the app in front at the key-down)
    var styleBundle: String?
    /// tests (`dictation style app BUNDLE`): the app a take counts as going into (the pad is always the field)
    var testStyleBundle: String?
    /// what reformat-last works on: the last paste, its versions and where it went
    var lastPaste: DictationLastPaste?
    /// the style the island's ear shows while listening (nil: light, the quiet default)
    var listeningStyle: DictationStyle? { phase == .listening ? styleDecision?.style : nil }

    var elapsed: Double { phase == .listening ? voice?.elapsed ?? Date().timeIntervalSince(startedAt) : 0 }

    // MARK: settings (record.dictation.*)

    static var settings: [String: Any] { recordConfig()["dictation"] as? [String: Any] ?? [:] }
    static func set(_ key: String, _ value: Any?) { Config.shared.set("record.dictation.\(key)", value) }
    static var enabled: Bool { settings["enabled"] as? Bool ?? true }
    /// Fn unless the user picked another key (≤ 0.8 stored nothing for right ⌥, the old default: they get Fn now)
    static var key: DictationTrigger.Key { DictationTrigger.Key(rawValue: settings["key"] as? String ?? "") ?? .fn }
    static var mode: DictationTrigger.Mode { DictationTrigger.Mode(rawValue: settings["mode"] as? String ?? "") ?? .auto }
    /// With Fn: an active tap keeps the Fn press from macOS's own 🌐 action (needs Accessibility)
    static var fnCapture: Bool { settings["fn_capture"] as? Bool ?? true }
    static var polishOn: Bool { (settings["polish"] as? String ?? "light") != "off" }
    static var polishTimeout: Double { max(0.5, (settings["polish_timeout_ms"] as? Double ?? 3000) / 1000) }
    /// how long a cold model (server start + load) may take: never counted against polish_timeout_ms
    /// Structured's one pass over the whole take (record.dictation.structure_timeout_ms; the generation alone)
    static var structureTimeout: Double { max(1, (settings["structure_timeout_ms"] as? Double ?? 10000) / 1000) }
    static var loadBudget: Double { max(1, (settings["load_budget_ms"] as? Double ?? 12000) / 1000) }
    /// transcribe and polish while talking (DictationStream); off = everything after key-up, the old way
    static var streaming: Bool { settings["streaming"] as? Bool ?? true }
    /// open the mic on the key-down, before the trigger has decided (the first words aren't lost)
    static var precapture: Bool { settings["precapture"] as? Bool ?? true }
    /// the Mac's own mic for dictation: unset = automatic (when the default input is Bluetooth), true / false
    static var builtInMicSetting: Bool? { settings["builtin_mic"] as? Bool }
    /// a soft tick when the mic is really listening (off by default)
    static var startSound: Bool { settings["start_sound"] as? Bool ?? false }
    static var retentionDays: Int { settings["retention_days"] as? Int ?? 30 }
    static var keepAudio: Bool { settings["keep_audio"] as? Bool ?? false }
    /// the Dictation Lab: keep the audio of this many more dictations (collecting cases from real use)
    static var labKeepNext: Int { (settings["lab_keep_next"] as? NSNumber)?.intValue ?? 0 }
    /// read the text around the cursor for polish (Accessibility, read-only)
    static var contextOn: Bool { settings["context"] as? Bool ?? true }
    /// watch the field after typing and learn the user's fixes
    static var learnOn: Bool { settings["learn"] as? Bool ?? true }
    /// a double tap of the key presses Return ("send"; after a dictation, once it is pasted)
    static var doubleTapSend: Bool { settings["double_tap_send"] as? Bool ?? true }
    /// per-category / per-app styles (unset = light everywhere, with the category's variant)
    static var styleConfig: DictationStyleConfig { DictationStyleConfig(json: settings["styles"] as? [String: Any]) }
    static func setStyleConfig(_ c: DictationStyleConfig) { set("styles", c.json) }
    /// after a take that sounds like a list but was typed as prose, the island offers to make it one
    static var suggestLists: Bool { settings["suggest_lists"] as? Bool ?? true }
    /// suggest an app's style from how the user switches there (never switches by itself)
    static var learnStyles: Bool { settings["learn_styles"] as? Bool ?? true }

    // MARK: launch / settings changed

    /// At launch (the menu-bar app): history retention, the key tap; if the key can't be heard, ask macOS (once per
    /// version) and say so on the island (about once a day). The menu-bar menu's top row stays until it works.
    func install() {
        keys.onEvent = { [weak self] e in self?.handle(e) }
        keys.onChange = { [weak self] in self?.listenerChanged() }
        DispatchQueue.global(qos: .utility).async { DictationHistory.shared.prune(days: Dictation.retentionDays) }
        // ≤ 0.7: a once-ever flag that silenced the reminder for good after one unseen toast
        if Config.shared["app.dictation_prompted"] != nil { Config.shared.set("app.dictation_prompted", nil) }
        apply()
        refreshPolishModel()
        seedVocabulary()
        DictationWatch.shared.onLearned = { term in Dictation.toastLearned(term) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.launchCheck() }
        // the mic's engine, set up but not started: the key-down only has to start it
        if Dictation.enabled { MicEngine.shared.prepare(builtIn: Dictation.useBuiltInMic) }
    }

    /// Dictation listens with the Mac's own mic (DictationMicChoice: automatic = when the default input is Bluetooth).
    static var useBuiltInMic: Bool {
        if DictationInsert.testMode { return false }
        return DictationMicChoice.useBuiltIn(setting: builtInMicSetting, defaultIsBluetooth: AudioDevices.defaultInputIsBluetooth,
                                             builtInAvailable: AudioDevices.builtInInput() != nil)
    }

    /// The words every user obviously says: the agents, Blurt itself, each project's name and key (source "project",
    /// once; a removed one stays removed). At launch and when Settings → Dictation opens.
    func seedVocabulary() {
        let ps = ProjectStore.shared.projects.map { (name: $0.name, key: $0.key) }
        DispatchQueue.global(qos: .utility).async {
            let added = DictationVocabulary.shared.seed(projects: ps)
            if !added.isEmpty { emit(["event": "dictation_vocab_seed", "added": added]) }
        }
    }

    /// "Learned “Claude” · Undo" — the first time a fix became a word.
    static func toastLearned(_ term: String) {
        var t = Island.Toast(text: Loc.t("dictation.toast.learned", table: "Dictation", term),
                             actionTitle: Loc.t("dictation.toast.undo", table: "Dictation"), action: {
            DictationVocabulary.shared.forget(term)
            emit(["event": "dictation_vocab_undo", "term": term])
        })
        t.seconds = 5
        island.toast(t)
        emit(["event": "dictation_learned_toast", "term": term])
    }

    /// The setup assistant (first launch) walks the permissions itself: no toast on top of it.
    private var assistantShows: Bool { Onboarding.needed && ProcessInfo.processInfo.environment["BLURT_NO_ONBOARDING"] == nil }

    /// At launch macOS is never asked (DictationAccess.asksAtLaunch): only the island's reminder, whose button starts
    /// the permission guide; a guide cut short by a relaunch (Screen Recording) carries on.
    private func launchCheck() {
        MainActor.assumeIsolated { PermissionGuide.shared.resumeIfNeeded() }
        if !assistantShows { nudge("launch") }
    }

    /// Re-reads the settings: the tap on or off, the key and the mode.
    func apply() {
        trigger.key = Dictation.key
        trigger.mode = Dictation.mode
        trigger.doubleTap = Dictation.doubleTapSend
        keys.watchedKeyCodes = trigger.key.keyCodes
        keys.wantsFilter = Dictation.enabled && trigger.key == .fn && Dictation.fnCapture
        if Dictation.enabled {
            // DictationKeys polls (and listens for Blurt being activated) until the key is heard everywhere; test
            // builds only simulate macOS, and only when a test says something about it
            keys.start()
        } else {
            keys.stop()
            if busy { cancel() }
        }
        lastAccess = access
        emit(["event": "dictation_keys", "enabled": Dictation.enabled, "tap": keys.installed, "listener": keys.kind.rawValue,
              "key": trigger.key.rawValue, "filter": keys.filtering,
              "mode": trigger.mode.rawValue, "double_tap": trigger.doubleTap, "input_monitoring": DictationKeys.inputMonitoring, "accessibility": DictationKeys.accessibility,
              "test_mode": DictationInsert.testMode])
    }

    /// The key is heard in other apps (a tap made with Input Monitoring, or the Accessibility monitor).
    var tapInstalled: Bool { keys.installed }
    var listenerKind: DictationListenerKind { keys.kind }
    var tapGeneration: Int { keys.tapGeneration }
    /// The Fn filter runs (macOS's own Fn action is kept out), and how many Fn changes it kept.
    var fnFiltering: Bool { keys.filtering }
    var fnSwallowed: Int { keys.swallowed }
    /// When the key was last heard while another app was in front (Settings → Dictation; only the user can do this).
    var lastKeyFromOtherApp: Date? { keys.lastOtherApp }
    private var lastAccess: DictationAccess?

    // tests (DictationTestHooks): the listener's paths without macOS
    func testRefreshListener(_ via: String) { keys.refresh(via: via) }
    func testFilterDecision(_ code: Int) -> Bool { keys.testFilterDecision(keyCode: code) }
    /// The permission guide saw Accessibility or Input Monitoring change: the listener now, not at its next poll.
    func refreshListener(via: String) {
        guard Dictation.enabled else { return }
        keys.refresh(via: via)
    }
    func testTapDisabled() { keys.tapDisabled("timeout") }
    func testHeard(keyCode: Int, otherApp: Bool) {
        let down: UInt64 = keyCode == 61 ? 0x80040 : keyCode == 58 ? 0x80020 : keyCode == 63 ? 0x800000 : 0
        keys.flags(keyCode, down, otherApp: otherApp)
        keys.flags(keyCode, 0x100, otherApp: otherApp)
    }

    /// The listener changed (a poll, Blurt activated, a tap made again): say once that dictation works now.
    private func listenerChanged() {
        let now = access
        if let before = lastAccess, DictationAccess.confirm(before: before, after: now) { confirmOn() }
        lastAccess = now
    }

    /// What the cues go by: on, and is the key heard (the tap, not a permission check).
    var access: DictationAccess { DictationAccess(enabled: Dictation.enabled, tapInstalled: keys.installed) }
    /// On but deaf: the menu row, Settings → Dictation's warning, the island's reminder.
    var needsSetup: Bool { access.needsSetup }

    /// "Dictation is on: tap right Option to talk" — once, when the key starts being heard.
    private func confirmOn() {
        Config.shared.set("app.dictation_nudged_at", nil)
        var t = Island.Toast(text: Loc.t("dictation.toast.on.\(Dictation.mode.rawValue)", table: "Dictation",
                                         Dictation.keyShort), actionTitle: nil, action: nil)
        t.seconds = 5
        island.toast(t)
        emit(["event": "dictation_on"])
    }

    // MARK: the key can't be heard (DictationAccess decides; these act)

    static var appVersion: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "")+\(i?["CFBundleVersion"] as? String ?? "")"
    }

    /// CGRequestListenEventAccess(): macOS's own prompt the first time, and Blurt listed under Input Monitoring. Remembers
    /// the version that asked (launch asks once per version). Test builds never call it: an event says they would have.
    @discardableResult
    static func requestListenAccess(via: String) -> Bool {
        Config.shared.set("app.dictation_asked_version", appVersion)
        emit(["event": "dictation_access_request", "via": via, "test_mode": DictationInsert.testMode])
        if DictationInsert.testMode { return false }
        return CGRequestListenEventAccess()
    }

    /// System Settings → Privacy & Security → Input Monitoring (a test build only says it would open it).
    static func openSystemPane() {
        emit(["event": "dictation_open_pane", "pane": "Privacy_ListenEvent"])
        if !DictationInsert.testMode {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
    }

    /// "Turn On Dictation…" (the menu row, the island's button, Settings → Dictation, the Dictation page): Settings →
    /// Dictation, then the permission guide's dictation walk — Blurt registered in each list, the exact pane, the
    /// helper panel next to System Settings, and back here with a check mark when it works.
    func openSetup(from source: String = "dictation") {
        AppEnvironment.settings?.show(pane: "dictation")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                PermissionGuide.shared.start(.dictation, source: PermissionGuide.Source(rawValue: source) ?? .dictation)
            }
        }
    }

    /// The island's reminder while the key can't be heard — at launch, when the voice-note key is pressed, when
    /// Settings opens — about once a day (BLURT_TEST_DICTATION_NUDGE_SECONDS in test builds).
    func nudge(_ reason: String) {
        let last = (Config.shared["app.dictation_nudged_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let test = DictationInsert.testMode ? Double(ProcessInfo.processInfo.environment["BLURT_TEST_DICTATION_NUDGE_SECONDS"] ?? "") : nil
        guard access.nudge(lastNudge: last, now: Date(), every: test ?? DictationAccess.nudgeInterval) else { return }
        Config.shared.set("app.dictation_nudged_at", Date().timeIntervalSince1970)
        emit(["event": "dictation_nudge", "reason": reason])
        var t = Island.Toast(text: Loc.t("dictation.toast.needs_permission", table: "Dictation", Dictation.keyShort),
                             actionTitle: Loc.t("dictation.toast.set_up", table: "Dictation"), action: { Dictation.shared.openSetup(from: "island") })
        t.seconds = 8               // the island's line is quiet and brief by default; this one must be read
        if reason == "launch" { LaunchMessages.shared.post(.permission, t) } else { island.toast(t) }    // one message at launch
    }

    /// The key's name for a picker or a field ("Right Option", "Fn", "Either Option Key").
    static var keyName: String { keyName(key) }
    static func keyName(_ k: DictationTrigger.Key) -> String {
        switch k {
        case .rightOption: return Loc.t("dictation.key.right_option", table: "Dictation")
        case .fn: return Loc.t("dictation.key.fn", table: "Dictation")
        case .eitherOption: return Loc.t("dictation.key.either_option", table: "Dictation")
        }
    }
    /// The key's short name, for the island's one line ("tap right Option to talk", "单按右 Option 开始说话").
    static var keyShort: String { keyShort(key) }
    static func keyShort(_ k: DictationTrigger.Key) -> String {
        switch k {
        case .rightOption: return Loc.t("dictation.key.right_option.short", table: "Dictation")
        case .fn: return Loc.t("dictation.key.fn.short", table: "Dictation")
        case .eitherOption: return Loc.t("dictation.key.either_option.short", table: "Dictation")
        }
    }
    /// The key's name inside a sentence ("Press the right Option key alone", "单独按一下右 Option 键").
    static var keyInline: String { keyInline(key) }
    static func keyInline(_ k: DictationTrigger.Key) -> String {
        switch k {
        case .rightOption: return Loc.t("dictation.key.right_option.inline", table: "Dictation")
        case .fn: return Loc.t("dictation.key.fn.inline", table: "Dictation")
        case .eitherOption: return Loc.t("dictation.key.either_option.inline", table: "Dictation")
        }
    }

    /// Which polish model would run (installed + selected) — `polish.py models`, off the main thread.
    func refreshPolishModel(then: (() -> Void)? = nil) {
        Task.detached(priority: .utility) {
            let r = try? await ScriptRunner.shared.json("polish.py", ["models"], timeout: 60)
            let m = r?["selected"] as? String
            await MainActor.run {
                self.polishModel = m
                then?()
            }
        }
    }

    // MARK: events (the tap, or the test hook)

    /// The Dictation Lab while it is in front: the key records a lab take there instead of typing into an app.
    weak var lab: DictationLabSink?

    /// The lab stopped its take itself (its Stop button): the key's next press starts again.
    func labReset() { trigger.reset(active: false) }

    func handle(_ event: DictationTrigger.Event) {
        guard Dictation.enabled else { return }
        var e = event
        // a click on Blurt's own island while dictating is the style chip, not "a click joined in" (it never cancels
        // push-to-talk; the island itself ignores it then)
        if case let .mouseDown(t) = e, trigger.active, phase == .listening, island.frameOnScreen.contains(NSEvent.mouseLocation) {
            e = .islandClick(time: t)
        }
        if let l = lab, phase == .idle, voice == nil, MainActor.assumeIsolated({ l.wantsKey }) {
            for out in trigger.handle(e) {
                switch out {
                case .start: MainActor.assumeIsolated { l.keyStart() }
                case .stop: MainActor.assumeIsolated { l.keyStop() }
                case .cancel: MainActor.assumeIsolated { l.keyCancel() }
                case .arm: warm()
                case .send, .style: break
                }
            }
            scheduleHoldTick()
            return
        }
        let wasIsland: Bool = { if case .islandClick = e { return true }; return false }()
        for out in trigger.handle(e) {
            switch out {
            case .arm: arm()
            case .start: start()
            case .stop: stop()
            case .cancel: cancel()
            case .send: send()
            case .style: toggleStyle(via: wasIsland ? .island : .shift)
            }
        }
        // the press became a shortcut (Fn-←, ⌥A), a click joined in, or it was let go too early / too late: the mic
        // opened on the key-down closes again, and nothing is kept
        if precaptured, phase == .idle, !trigger.armedDown { dropPrecapture() }
        updateShiftFilter()
        scheduleHoldTick()
    }

    /// While a take listens (or its key is down), a lone ⇧ is the style toggle: the Fn filter keeps it from the app
    /// in front too (an input method would switch between Chinese and English on it).
    func updateShiftFilter() {
        keys.swallowShift = trigger.active || trigger.armedDown || phase == .listening
    }

    private func scheduleHoldTick() {
        holdTimer?.invalidate()
        guard let d = trigger.deadline else { return }
        let wait = max(0, d - CACurrentMediaTime())
        holdTimer = Timer.scheduledTimer(withTimeInterval: wait + 0.005, repeats: false) { [weak self] _ in
            self?.handle(.tick(time: CACurrentMediaTime()))
        }
    }

    /// Key went down alone: open the mic now (what is said while the trigger waits for the key to come up is kept),
    /// and get the models loaded while the user starts talking.
    private func arm() {
        armedAt = CACurrentMediaTime()
        warm()
        guard Dictation.precapture, phase == .idle, voice == nil, canListen(toast: false) else { return }
        precaptured = true
        beginCapture()
    }

    /// Key went down alone: get the models loaded while the user starts talking. A server that isn't running is
    /// started offline first (no package index lookup: `uv run` checking PyPI after its cache expired took 13 s here,
    /// which is how a cold polish server missed a 19 s dictation); online only if that fails.
    func warm() {
        VoiceInput.warmSpeechModel(dictation: true)
        guard Dictation.polishOn, polishModel != nil else { return }
        if WarmServer.running("polish-serve") {
            DispatchQueue.global(qos: .userInitiated).async { _ = WarmServer.call("polish-serve", ["cmd": "load"], timeout: 30) }
        } else if polishServer?.isRunning != true {
            polishServer = WarmSpawn.start("polish.py", ["serve", "--preload"], server: "polish-serve")
        }
    }

    // MARK: start / stop / cancel

    /// Also the menu's "Start Dictation" (and the test hook): the same as a tap.
    func toggle() {
        if phase == .listening { trigger.reset(active: false); stop() } else if phase == .idle {
            armedAt = CACurrentMediaTime()
            warm(); trigger.reset(active: true); start()
        }
    }

    /// Not while recording (it owns the mic) or while a voice note listens.
    private func canListen(toast: Bool) -> Bool {
        if (NSApp.delegate as? App)?.rec != nil {
            if toast { island.toast(Loc.t("dictation.toast.recording_busy", table: "Dictation"), actionTitle: nil, action: nil) }
            return false
        }
        if VoiceInput.shared.active || NoteBubble.shared.isListening {     // a voice note, or a snap's spoken note
            if toast { island.toast(Loc.t("dictation.toast.voice_busy", table: "Dictation"), actionTitle: nil, action: nil) }
            return false
        }
        return true
    }

    /// The mic (or the test wav) → the wav file and the stream. On the key-down (pre-capture) or at the start.
    private func beginCapture() {
        front = NSWorkspace.shared.frontmostApplication
        startedAt = Date()
        entryID = DictationHistory.newID(startedAt)
        let url = DictationHistory.shared.audioDir.appendingPathComponent("\(entryID).wav")
        let v = NoteVoice(url: url)
        let env = ProcessInfo.processInfo.environment
        v.inject = testWav ?? env["BLURT_TEST_MIC_WAV"] ?? env["BLURT_NOTE_WAV"]
        // tests: the wav is the world's sound since the key went down — what the "mic" missed while starting is lost
        if DictationInsert.testMode, env["BLURT_TEST_MIC_CLOCK"] == "keydown" { v.injectClock = armedAt }
        v.builtInMic = Dictation.useBuiltInMic
        v.silenceToEnd = .infinity                   // you end it, not a pause
        v.noSpeechTimeout = .infinity                // set at the start (push-to-talk has none)
        v.maxLength = 300
        v.onLevel = { [weak self] l in
            guard let self = self else { return }
            self.levels.append(l)
            if self.levels.count > 120 { self.levels.removeFirst(self.levels.count - 120) }
        }
        v.onSpeech = { [weak self] in self?.heardSpeech = true }
        v.onFirstAudio = { [weak self] in self?.micStarted(v) }
        v.onEnd = { [weak self] e in
            guard let self = self, self.voice === v else { return }
            self.trigger.reset(active: false)
            if self.phase != .listening { return self.dropPrecapture() }
            if e == .noSpeech { self.discard(quietly: false) } else { self.finish(ended: true) }
        }
        // the style: the app in front decides the base now (verbatim skips polish for the whole take); ⇧ or the
        // island can still make it Structured — the structuring pass runs once at key-up, on the stitched text
        beginStyle(bundle: DictationInsert.testMode ? testStyleBundle ?? front?.bundleIdentifier : front?.bundleIdentifier)
        let base = styleDecision?.base ?? .light
        var opt = DictationStream.Options()
        opt.language = Config.shared["asr.language"] as? String ?? "auto"
        opt.streaming = Dictation.streaming
        opt.polishTimeout = Dictation.polishTimeout
        opt.structureTimeout = Dictation.structureTimeout
        opt.loadBudget = Dictation.loadBudget
        opt.vocab = DictationVocabulary.shared.payload()
        opt.polish = Dictation.polishOn && polishModel != nil && base.polishes
        opt.variant = styleDecision?.category == .chat ? "chat" : nil
        let s = DictationStream(id: entryID, dir: DictationHistory.shared.audioDir, wholeWav: url, options: opt)
        v.onSamples = { [weak s] x in s?.append(x) }
        // the words while talking: the pieces' transcripts as they come in (shown from the first one on)
        let live = LiveTranscript.shared.begin(.dictation)
        liveSession = live
        s.onHeard = { t in LiveTranscript.shared.update(t, session: live) }
        voice = v
        stream = s
        wav = url
        levels = []
        micLive = false
        heardSpeech = false
        generation += 1
        let g = generation
        v.start { [weak self] ok in
            guard let self = self, self.voice === v, g == self.generation else { return }
            if !ok {
                self.trigger.reset(active: false)
                self.discard(quietly: true)
                NoteVoice.toastUnavailable()
            }
        }
        if DictationInsert.testMode, let t = testStopAfter {
            testStopAfter = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self = self, self.voice === v, self.phase == .listening else { return }
                self.trigger.reset(active: false)
                self.stop()
            }
        }
    }

    /// The first audio arrived: the island switches to "listening" (the user can talk now), a soft tick if wanted.
    private func micStarted(_ v: NoteVoice) {
        guard voice === v else { return }
        micLive = true
        let ms = Int((CACurrentMediaTime() - armedAt) * 1000)
        emit(["event": "dictation_mic_live", "id": entryID, "from_key_ms": ms, "from_open_ms": Int((v.firstAudioAfter ?? 0) * 1000),
              "precaptured": precaptured, "builtin_mic": v.builtInMic])
        if phase == .listening {
            island.dictationChanged()
            if Dictation.startSound, (NSApp.delegate as? App)?.rec == nil { NSSound(named: "Tink")?.play() }
        }
    }

    /// A pre-capture the trigger didn't turn into a dictation: closed, nothing kept.
    private func dropPrecapture() {
        guard precaptured, phase == .idle else { return }
        precaptured = false
        voice?.stop(keep: false)
        voice = nil
        stream?.cancel()
        stream = nil
        micLive = false
        LiveTranscript.shared.end(session: liveSession)
        emit(["event": "dictation_precapture_dropped"])
    }

    /// Where the text goes in, so the live transcript can stay off it (read once, off the main thread; the test pad
    /// on it).
    private func readCaret() {
        guard LiveTranscript.enabled else { return }
        let live = liveSession
        if DictationInsert.testMode { return LiveTranscript.shared.setAvoid(DictationField.focused()?.caretRect(), session: live) }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = DictationField.focused()?.caretRect()
            DispatchQueue.main.async { LiveTranscript.shared.setAvoid(r, session: live) }
        }
    }

    private func start() {
        guard phase == .idle else { return }
        guard canListen(toast: true) else {
            trigger.reset(active: false)
            dropPrecapture()
            return
        }
        let adopted = precaptured && voice != nil
        precaptured = false
        if !adopted { beginCapture() }
        voice?.noSpeechTimeout = trigger.pushToTalk ? .infinity : 30     // push-to-talk ends when the key comes up
        if trigger.startShift { explicitStyle = (.structured, .chord); routeStyle() }      // Fn+⇧: start in Structured
        phase = .listening
        captureContext()
        readCaret()
        if !keys.installed {        // without the tap, Esc comes as a Carbon hotkey (as for the voice note)
            registerHotkey(.dictationEsc, key: kVK_Escape, mods: 0)
            escRegistered = true
        }
        emit(["event": "dictation_start", "id": entryID, "app": front?.localizedName ?? "", "bundle": front?.bundleIdentifier ?? "",
              "key": trigger.key.rawValue, "mode": trigger.mode.rawValue, "push_to_talk": trigger.pushToTalk,
              "precaptured": adopted, "mic_live": micLive, "style": styleDecision?.style.rawValue ?? "light",
              "style_source": styleDecision?.source.rawValue ?? "default", "category": styleDecision?.category.rawValue ?? "other"])
        if micLive, Dictation.startSound { NSSound(named: "Tink")?.play() }
    }

    /// The text around the cursor, read while the user talks (Accessibility calls can take a moment). Test builds read
    /// the test pad on the main thread; nothing else of this app is read.
    private func captureContext() {
        context = nil
        guard Dictation.contextOn, Dictation.polishOn else { return }
        let g = generation
        let done = { (c: DictationContext?) in
            guard g == self.generation else { return }
            self.context = c
            self.stream?.setContext(c)          // the pieces polished from now on see it
            emit(["event": "dictation_context", "id": self.entryID, "found": c != nil, "before": c?.before.count ?? 0,
                  "after": c?.after.count ?? 0, "title": !(c?.title.isEmpty ?? true)])
        }
        if DictationInsert.testMode { return done(DictationContext.capture()) }
        DispatchQueue.global(qos: .userInitiated).async {
            let c = DictationContext.capture()
            DispatchQueue.main.async { done(c) }
        }
    }

    private func stop() {
        guard phase == .listening else { return }
        finish(ended: false)
    }

    func cancel() {
        sendAfterPaste = false
        guard phase == .listening else {
            if busy { generation += 1; phase = .idle }     // a cancel while working: drop the result
            dropPrecapture()
            return
        }
        trigger.reset(active: false)
        emit(["event": "dictation_cancel", "id": entryID])
        discard(quietly: true)
    }

    /// A double tap: Return in the app in front ("send"). Right after a dictation stopped, once its text has been
    /// pasted (the clipboard is back by then, so the paste has landed); otherwise now. The dictation the double tap's
    /// first tap started was cancelled just before (nothing pasted, nothing in the history).
    private func send() {
        if phase == .transcribing || phase == .polishing || inserting {
            sendAfterPaste = true
            emit(["event": "dictation_send", "result": "queued", "phase": phase.rawValue])
            return
        }
        pressReturn(after: "tap")
    }

    private func pressReturn(after: String) {
        let r = DictationInsert.pressReturn()
        emit(["event": "dictation_send", "result": r.result, "why": r.why ?? NSNull(), "after": after])
        if r.pressed {
            var t = Island.Toast(text: Loc.t("dictation.toast.sent", table: "Dictation"), actionTitle: nil, action: nil)
            t.seconds = 1.2
            island.toast(t)
        }
    }

    private func releaseEsc() {
        if escRegistered { unregisterHotkey(.dictationEsc); escRegistered = false }
    }

    private func discard(quietly: Bool) {
        voice?.stop(keep: false)
        voice = nil
        stream?.cancel()
        stream = nil
        micLive = false
        precaptured = false
        releaseEsc()
        phase = .idle
        if !quietly { island.toast(Loc.t("dictation.toast.nothing", table: "Dictation"), actionTitle: nil, action: nil) }
    }

    // MARK: the words

    private func finish(ended: Bool) {
        guard let v = voice, let url = wav, let s = stream else { return }
        let keyUp = CACurrentMediaTime()
        let duration = v.elapsed
        if !ended { v.stop(keep: heardSpeech) }
        voice = nil
        stream = nil
        micLive = false
        releaseEsc()
        guard heardSpeech else { s.cancel(); return discard(quietly: false) }
        phase = .transcribing
        let gen = generation
        let id = entryID, app = front, started = startedAt
        let polish = Dictation.polishOn && polishModel != nil
        let ctx = polish ? context : nil
        emit(["event": "dictation_stop", "id": id, "duration": (duration * 100).rounded() / 100, "segments": s.segments])
        s.setContext(ctx)
        s.onStage = { [weak self] stage in
            guard let self = self, gen == self.generation, self.phase != .idle else { return }
            self.phase = stage == "polish" ? .polishing : .transcribing
        }
        // Structured / Auto (the style as the take ends: ⇧ and the island may have changed it): one structuring pass
        let structure = (styleDecision?.style == .structured || styleDecision?.style == .auto) && Dictation.polishOn && polishModel != nil
        s.finish(keyUp: keyUp, structure: structure) { [weak self] r in
            guard let self = self, gen == self.generation else { return }
            guard !r.empty else {
                try? FileManager.default.removeItem(at: url)
                if self.sendAfterPaste {         // nothing to send: Return would send something else
                    self.sendAfterPaste = false
                    emit(["event": "dictation_send", "result": "skipped", "why": "nothing_dictated", "after": "paste"])
                }
                self.phase = .idle
                island.toast(Loc.t("dictation.toast.nothing", table: "Dictation"), actionTitle: nil, action: nil)
                emit(["event": "dictation_text", "id": id, "ok": false, "asr_ms": r.timing["asr_ms"] ?? 0])
                return
            }
            self.deliver(id: id, r: r, polishTried: polish, app: app, started: started, duration: duration, wav: url,
                         context: ctx, keyUp: keyUp)
        }
    }

    /// The warm server (no process start; waiting up to `budget` for one starting), else `transcribe.py note` (it
    /// starts the model itself). Dictation's model (record.dictation.asr_model, else the recommended one when
    /// installed), biased toward the custom words, with `prior` (the text so far) as context; the answer's `text` has
    /// the exact sounds-likes fixed, `asr_text` is what the model wrote. Blocking: off the main thread.
    /// `hint`: the target window's title and the text around the cursor (DictationContext.hint) — words seen there go
    /// to the model first, and let the near-miss pass correct a weaker miss (docs/design/dictation.md §Code-switching).
    static func transcribe(_ wav: URL, vocab: [[String: Any]], language: String, prior: String, budget: Double,
                           hint: String = "") -> [String: Any]? {
        var req: [String: Any] = ["cmd": "note", "wav": wav.path, "language": language, "purpose": "dictation", "vocab": vocab]
        if !prior.isEmpty { req["prior"] = prior }
        if !hint.isEmpty { req["hint"] = hint }
        let until = Date().addingTimeInterval(budget)
        while !WarmServer.running("asr-serve") && Date() < until && VoiceInput.serverStarting { usleep(50_000) }
        if let r = WarmServer.call("asr-serve", req, timeout: 60), r["ok"] as? Bool == true { return r }
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any]?
        Task.detached {
            out = try? await ScriptRunner.shared.json("transcribe.py", ["note", wav.path, "--language", language, "--dictation", "--vocab"], timeout: 120)
            sem.signal()
        }
        sem.wait()
        return out
    }

    /// The warm polish server. A model still coming up (the server starting, the weights loading) gets `loadBudget`
    /// — that time never counts against `timeout`, which the server applies to the generation alone once the model is
    /// loaded. nil = no polish (raw text, not a fall-back). Blocking: off the main thread.
    static func polish(_ raw: String, timeout: Double, loadBudget: Double, vocab: [[String: Any]], context: [String: Any]?,
                       variant: String? = nil) -> [String: Any]? {
        let t0 = Date()
        let until = t0.addingTimeInterval(loadBudget)
        while !WarmServer.running("polish-serve") && Date() < until { usleep(50_000) }
        guard WarmServer.running("polish-serve") else {
            return ["ok": true, "text": raw, "fell_back": true, "reason": "unavailable", "load_ms": Int(Date().timeIntervalSince(t0) * 1000)]
        }
        let waited = Int(Date().timeIntervalSince(t0) * 1000)
        var req: [String: Any] = ["cmd": "polish", "text": raw, "timeout": timeout, "vocab": vocab, "context": context ?? NSNull()]
        if let v = variant { req["variant"] = v }       // "chat": sentence-final particles stay (dictation-styles.md §3.1)
        guard var r = WarmServer.call("polish-serve", req, timeout: timeout + loadBudget + 1) else {
            return ["ok": true, "text": raw, "fell_back": true, "reason": "timeout", "load_ms": waited]
        }
        guard r["ok"] as? Bool == true else { return nil }
        r["load_ms"] = (r["load_ms"] as? Int ?? 0) + waited
        return r
    }

    /// The warm polish server's structuring pass (Structured): the whole take, its self-corrections resolved and what
    /// was enumerated laid out — or nil (no server: Light's text is typed). Blocking: off the main thread.
    static func structure(_ text: String, timeout: Double, loadBudget: Double, vocab: [[String: Any]]) -> [String: Any]? {
        let until = Date().addingTimeInterval(loadBudget)
        while !WarmServer.running("polish-serve") && Date() < until { usleep(50_000) }
        guard WarmServer.running("polish-serve") else { return nil }
        let req: [String: Any] = ["cmd": "structure", "text": text, "timeout": timeout, "vocab": vocab]
        guard let r = WarmServer.call("polish-serve", req, timeout: timeout + loadBudget + 1), r["ok"] as? Bool == true else { return nil }
        return r
    }

    private func deliver(id: String, r: DictationStream.Result, polishTried: Bool, app: NSRunningApplication?, started: Date,
                         duration: Double, wav: URL, context: DictationContext?, keyUp: CFTimeInterval) {
        // the custom words this dictation wrote: fixed by the sounds-like pass or polish, or (when the speech model was
        // told the words) written by the model itself
        var terms = r.terms
        if r.biased { for t in DictationVocabulary.shared.active().map(\.term) where r.text.contains(t) && !terms.contains(t) { terms.append(t) } }
        // the take's style: the structured text when Structured asked for it (the model's pass at key-up), the category's
        // variant of light (DictationStyles.swift)
        let styled = styleText(r)
        var text = styled.text
        let styleRecord = styled.record
        phase = .idle
        // where the text goes in, read just before pasting: the field the watch then follows for the user's fixes, and
        // the text on either side of the cursor the dictation is fitted into (DictationFit: the words that repeat the
        // field go, punctuation and spacing follow the sentence). A field whose text can't be read (WeChat) gets the
        // text as it is; nothing in the field is ever changed, only what is inserted.
        let field = Dictation.learnOn || Dictation.contextOn ? DictationField.focused() : nil
        let now = field?.read()
        let at = now?.selection.location
        var fitted: [String] = []
        if Dictation.contextOn, let f = now {
            let ns = f.text as NSString
            let loc = min(max(0, f.selection.location), ns.length)
            let len = min(max(0, f.selection.length), ns.length - loc)
            let before = String(ns.substring(to: loc).suffix(500))
            let after = String(ns.substring(from: loc + len).prefix(500))
            let fit = Dictation.fit(text, before: before, after: after, list: styleRecord.rendered)
            if fit.changes.count > 0 {
                emit(["event": "dictation_fit", "id": id, "changes": fit.changes, "from": text.count, "to": fit.text.count])
                text = fit.text
                fitted = fit.changes
            }
        }
        let pasteAt = CACurrentMediaTime()
        let bundle = styleBundle ?? app?.bundleIdentifier      // the app the take went into (tests: `dictation style app`)
        var timing = r.timing
        timing["total_ms"] = Int((pasteAt - keyUp) * 1000)
        inserting = true
        DictationInsert.insert(text) { [weak self] result in
            guard let self = self else { return }
            self.inserting = false
            if self.sendAfterPaste {
                self.sendAfterPaste = false
                if result == .pasted { self.pressReturn(after: "paste") } else {
                    // left on the clipboard (a password field, Blurt in front …): Return would send without it
                    emit(["event": "dictation_send", "result": "skipped", "why": "not_pasted", "after": "paste"])
                }
            }
            // the Dictation Lab's "keep the audio of the next N dictations" (record.dictation.lab_keep_next): only the
            // audio, never the text around the cursor
            let labKeep = Dictation.labKeepNext > 0
            if labKeep { Dictation.set("lab_keep_next", Dictation.labKeepNext - 1) }
            let keep = Dictation.keepAudio || labKeep
            if !keep { try? FileManager.default.removeItem(at: wav) }
            let e = DictationEntry(id: id, time: started, app: bundle == app?.bundleIdentifier ? app?.localizedName : bundle, bundle: bundle, duration: duration,
                                   raw: r.asrText, polished: r.polished, text: text,
                                   model: r.model, fellBack: r.fellBack, reason: r.reason,
                                   insert: result.rawValue, audio: keep ? "audio/\(wav.lastPathComponent)" : nil,
                                   asrModel: r.asrModel, language: r.language,
                                   termsApplied: terms, contextUsed: r.contextUsed,
                                   context: Dictation.keepAudio && r.contextUsed ? context?.debugText : nil,
                                   timing: timing.filter { DictationEntry.timingKeys.contains($0.key) },
                                   repaired: r.repaired.isEmpty ? nil : r.repaired, fitted: fitted.isEmpty ? nil : fitted)
            var entry = e
            entry.style = styleRecord
            DictationHistory.shared.append(entry)
            if !terms.isEmpty { DispatchQueue.global(qos: .utility).async { DictationVocabulary.shared.recordHits(terms) } }
            if result == .pasted, let f = field, let loc = at { DictationWatch.shared.start(field: f, inserted: text, location: loc) }
            // reformat-last's material: the versions, and where the text went (only while it stays untouched)
            self.rememberPaste(id: id, app: app, bundle: bundle, r: r, record: styleRecord, typed: text, result: result,
                               field: result == .pasted ? field : nil, location: at)
            DictationHistoryWindow.shared.reloadIfOpen()
            if result == .copied {
                island.toast(Loc.t("dictation.toast.copied", table: "Dictation"), actionTitle: nil, action: nil)
            } else if result == .pasted, !DictationInsert.lastPasteConfirmed {
                // pasted into a focus Accessibility couldn't confirm as text (WeChat & co.): in case it didn't land
                var t = Island.Toast(text: Loc.t("dictation.toast.pasted_unsure", table: "Dictation"),
                                     actionTitle: Loc.t("dictation.toast.copy_again", table: "Dictation"), action: {
                    DictationInsert.copy(text)
                    emit(["event": "dictation_copy_again", "id": id])
                })
                t.seconds = 4
                island.toast(t)
            }
            var out: [String: Any] = ["event": "dictation_text", "id": id, "ok": true, "raw": r.raw, "text": text,
                                      "fell_back": r.fellBack, "reason": r.reason ?? NSNull(),
                                      "polished": r.polished ?? NSNull(), "model": r.model ?? NSNull(),
                                      "insert": result.rawValue, "polish_tried": polishTried, "asr_text": r.asrText,
                                      "terms": terms, "context_used": r.contextUsed, "asr_model": r.asrModel ?? NSNull(),
                                      "biased": r.biased, "repaired": r.repaired, "fitted": fitted,
                                      "style": styleRecord.style, "style_source": styleRecord.source,
                                      "category": styleRecord.category, "structure_reason": r.structureReason ?? NSNull(),
                                      "rendered": styleRecord.rendered, "variant": styleRecord.variant,
                                      "style_ms": styled.ms]
            for (k, v) in timing { out[k] = v }
            self.lastResult = out
            emit(out)
        }
    }
}

/// Starting a warm model server (transcribe.py / polish.py serve): offline first — `uv run` resolves the script's
/// packages, and once its index cache has expired it asks PyPI again (13 s here on the first try, 2.5 s cached), which
/// made a cold server miss a whole dictation. With UV_OFFLINE=1 the cached packages are used as they are; only when
/// that fails (nothing cached yet: the first use ever) does it start again online.
enum WarmSpawn {
    /// Tests (test commands only): BLURT_TEST_NO_SERVERS=1 starts no warm server — nothing listens on a local port;
    /// the requests go through the CLI (which loads its model itself).
    static let testNoServers: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["BLURT_TEST_COMMANDS"] == "1" && env["BLURT_TEST_NO_SERVERS"] == "1"
    }()

    static func start(_ script: String, _ args: [String], server: String) -> Process? {
        if testNoServers {
            emit(["event": "warm_spawn_skipped", "script": script, "server": server])
            return nil
        }
        let p = try? ScriptRunner.shared.spawn(script, args, env: ["UV_OFFLINE": "1"]) { _ in }
        p?.terminationHandler = { proc in
            guard proc.terminationStatus != 0, !WarmServer.running(server) else { return }
            emit(["event": "warm_spawn_online", "script": script, "status": Int(proc.terminationStatus)])
            DispatchQueue.main.async { _ = try? ScriptRunner.shared.spawn(script, args) { _ in } }
        }
        return p
    }
}
