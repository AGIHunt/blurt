// Dictation (听写, docs/design/dictation.md): talk, and the words are typed into whichever app has the focus —
// separate from the voice note (⌥⇧V files into Blurt; the two never share a key).
//
//  • trigger: Fn (default; or right ⌥, or either ⌥) alone, read by an event tap (DictationKeys) and decided by
//    BlurtCore's DictationTrigger — auto (default: a tap is hands-free, holding is push-to-talk), tap / tap, or hold
//    to talk. Esc cancels — while listening, and while the text is still on its way (it is then never pasted). With Fn
//    and Accessibility, the tap is an active filter that keeps the Fn press from macOS.
//    A double tap presses Return (record.dictation.double_tap_send, on; the window is macOS's double-click interval,
//    0.3–0.5 s): idle, it cancels the dictation its first tap started and sends; right after a dictation stopped
//    (a tap, or letting go of push-to-talk and then a double tap), Return goes in once the paste has landed. So there
//    are two ways to send: tap to stop → check the words → double-tap; or double-tap instead of the stop tap. A tap
//    while the last take is still being transcribed, polished or pasted starts the next take once the double-tap
//    window has passed (the trigger is told `pending`); the takes are pasted in the order they were said
//    (DictationTakes.swift). A slightly slow double tap (the stop tap within 0.8 s of the start, nothing heard) sends
//    instead of saying "nothing heard". A start the app refuses (a recording has the mic, the mic failed, no speech
//    model) resets the trigger but keeps the tap, so a second one sends.
//  • no speech model (`transcribe.py dictation-models`, read through DictationModels at launch, after every download
//    and whenever Settings reloads it): the key doesn't listen; the island says so (with the size), and its button
//    starts the download in the app's one download manager (`Dictation.getSpeechModel` → ModelDownloads; "Show" opens
//    its progress). A dictation never downloads a model itself (`--no-download`, `no_download`).
//  • a hands-free take nobody stops: "still listening" after 20 s without speech, the ear counts down from 4:30, and
//    the 5-minute limit says so when it ends the take (BlurtCore's DictationRunaway); the tap right after is its stop.
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
//    --purpose dictation` and, with polish on, `polish.py serve --preload`; the speech model also a few seconds after
//    launch (`prewarm`: dictation on, key heard, ≥ 16 GB, model installed) and as soon as the download manager brings
//    dictation's model in. The servers end with Blurt (`--parent`) and after 10 idle minutes, which is what gives their
//    memory back. A key press never downloads anything: the servers and the CLI run with BLURT_NO_DOWNLOAD /
//    --no-download, and without a recogniser to run on (`speechModels.ready`: the selected model and the VAD) the key
//    starts nothing — the island says the model is still downloading (Show) or offers to download it through the
//    app's one download manager (App/ModelDownloads.swift; `noSpeechModel`, DictationTakes.swift).
//  • nothing heard: the island names the mic it listened with and offers Change Mic… ("No sound from AirPods" when
//    its level never left the floor: BlurtCore NothingHeard).
//  • two running Blurts: the first that hears the key keeps it (HotkeyCenter.dictationOwner — an instance publishes
//    the key only while its listener is in, so a deaf one never holds it); the other one listens once
//    it quits.
//  • text: DictationStream cuts the audio at pauses while the user talks and transcribes + polishes each piece as it
//    completes (the warm servers; a model still loading gets record.dictation.load_budget_ms, never counted against
//    polish_timeout_ms); at key-up only the last piece is left. Any fall-back = that piece's raw text.
//    The words show under the island while the user talks (LiveTranscript, record.live_text, on;
//    DictationStream.onLive): the finished pieces' transcripts, then — quieter, provisional — the piece still being
//    said, decoded about once a second by the warm speech server as an interim request that never delays a final
//    piece (BlurtCore's DictationLiveDecode; record.dictation.live_partial, unset = on from 16 GB). Out of the way of
//    the caret (read once at the start). After the stop it shows the text actually typed (polished, structured) for
//    about 1.5 s — what a double tap would now send — then goes.
//  • insert: DictationInsert (pasteboard → ⌘V into the app in front, DictationPastePolicy → pasteboard back) — only
//    into the app the take started in; when the user moved on, the text is copied ("Copied — paste with ⌘V").
//    History: DictationHistory (history.jsonl, with asr / polish / load / total ms). A take whose speech recognition
//    failed keeps its audio and a history row, and the island says what failed, with Retry.
//  • words (DictationVocabulary, vocabulary.json): sent with every request as hints, never rewrites — the speech
//    model is biased toward them where it can be (transcribe.py), polish gets them as spelling hints with
//    the text around the cursor (DictationContext, read at the start, never stored). After the text goes in, the
//    field is watched for a minute (DictationWatch) and the user's own fixes become words (DictationLearn).
//  • off while a screen recording runs (it owns the mic) and while a voice note listens.
// Config record.dictation: enabled (true), key fn|right_option|either_option (unset = fn), mode auto|tap|hold (unset =
// auto), fn_capture (true: keep Fn from macOS's own 🌐 action), polish off|light, polish_model,
// polish_timeout_ms, load_budget_ms (12000), streaming (true), precapture (true), builtin_mic (automatic), start_sound
// (false), retention_days (30), keep_audio (false), asr_model (automatic), context (true), learn (true),
// double_tap_send (true), live_partial (automatic: on from 16 GB). Test hooks:
// DictationTestHooks.swift (`dictation …` on the test channel).
import AppKit
import BlurtCore
import Carbon.HIToolbox

final class Dictation {
    static let shared = Dictation()

    enum Phase: String { case idle, listening, transcribing, polishing }
    /// What the island shows: listening while a take listens, else the stage of the oldest take still on its way.
    private(set) var phase: Phase = .idle {
        didSet {
            if phase != oldValue { island.dictationChanged() }
            updateShiftFilter()
        }
    }
    private(set) var levels: [Float] = []
    var lastResult: [String: Any]?
    var busy: Bool { phase != .idle }

    var trigger = DictationTrigger()
    private let keys = DictationKeys()
    private var voice: NoteVoice?
    private var wav: URL?
    /// a take is listening (the mic is this take's)
    private(set) var listening = false
    private(set) var entryID = ""
    private var startedAt = Date()
    private var heardSpeech = false
    /// the hands-free take nobody stops (BlurtCore's DictationRunaway)
    private var runaway = DictationRunaway()

    // the takes that stopped and are on their way to the cursor (DictationTakes.swift)
    var takes: [String: DictationTake] = [:]
    var queue = DictationPasteQueue<String>()
    /// ⌥⇧L came while a take was on its way: run once that take is in (BlurtCore's DictationReformatAfterPaste)
    var reformatAfterPaste = DictationReformatAfterPaste<String>()
    /// takes whose speech recognition failed, kept (with their audio) for Retry — the last few
    var failedTakes: [String: DictationTake] = [:]
    /// takes stopped on their way by Esc, kept (with their audio) while "Cancelled" offers Undo
    var cancelledTakes: [String: DictationTake] = [:]
    /// when Return was last pressed (a hint about a missed press doesn't come after a send)
    var lastSendAt: CFTimeInterval = 0
    /// Settings' model list (DictationModels) → `speechModels`; the history being cleared or edited
    var observers: [Any] = []
    /// `transcribe.py dictation-models`: can a take run with nothing downloaded (the selected model and the VAD), what
    /// is missing, the recommended and configured models (nil: not known yet — the key then listens as before)
    var speechModels: DictationSpeechModels?
    /// tests (`dictation front NAME`): the app in front as far as the paste check knows (the pad is always the field)
    var testFront = "test-pad"

    /// The stage changed, a take started or stopped, or one is in or gone: the island's phase and the trigger's
    /// `pending` follow.
    func updatePhase() {
        let first = queue.ids.first { $0 != queue.delivering }.flatMap { takes[$0]?.stage }
        phase = listening ? .listening : first ?? .idle
        trigger.pending = !queue.isEmpty || inserting
        updateShiftFilter()
    }
    /// pieces transcribed and polished while the user talks (DictationStream)
    private var stream: DictationStream?
    /// the mic was opened on the key-down (`arm`), before the trigger decided: kept by `start`, closed when the press
    /// turns out to be something else
    private var precaptured = false
    /// the mic is open for a press that hasn't started yet (its audio file must not be deleted under it)
    var precapturing: Bool { precaptured }
    /// when the key went down (the mic's start latency is measured from here)
    private var armedAt: CFTimeInterval = 0
    /// audio is arriving: the island says "listening" only from here
    private(set) var micLive = false
    /// the listening aura shows from here (DictationGlow: after the double-tap window for a tap-started take)
    private(set) var glowFrom: CFTimeInterval = 0
    var glowOn: Bool { phase == .listening && micLive && CACurrentMediaTime() >= glowFrom }
    /// tests: the "microphone" (a wav) — `dictation wav PATH`, else BLURT_TEST_MIC_WAV / BLURT_NOTE_WAV
    var testWav: String?
    /// tests: stop the next dictation at this point of the wav, as a key-up would (`dictation stop-after S`): a release
    /// timed to the audio, which a command sent from outside can't be — counted in audio fed, not by a timer (a
    /// background test app's timers are coalesced: a wall-clock stop came 0.2–1.8 s late, later when the app was idle)
    var testStopAfter: Double?
    private var front: NSRunningApplication?
    /// what "the same app" is compared by at paste time: the front app's pid at the key-down (tests: `testFront`)
    private var frontKey = ""
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
    /// a double tap came for a take still on its way (DictationTake.sendAfterPaste): Return once it has been pasted
    /// (the island's ears say "sending" meanwhile)
    var sendQueued: Bool { takes.values.contains { $0.sendAfterPaste } }
    /// the paste is under way (⌘V posted, the clipboard not back yet)
    var inserting = false { didSet { updatePhase() } }

    /// The app in front now, as the paste check compares it with the take's start.
    var currentFrontKey: String {
        DictationInsert.testMode ? testFront : NSWorkspace.shared.frontmostApplication.map { "\($0.processIdentifier)" } ?? ""
    }

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
    /// The right ear's clock while listening: the time so far, from 4:30 the time left ("−0:29") before the limit.
    var earClock: String { DictationRunaway.clock(elapsed: elapsed).text }

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
    /// the live text also shows the piece still being said (interim decodes about once a second): unset = by the
    /// machine (not on the light / minimal tiers, < 16 GB), true / false
    static var livePartial: Bool {
        settings["live_partial"] as? Bool
            ?? DictationLiveDecode.tierAllows(ramGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824)
    }
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
    /// log every event the trigger gets (`dictation_keytrace`; debugging a real keyboard)
    static var keyTrace: Bool { settings["key_trace"] as? Bool ?? false }
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
        refreshSpeechModels()
        watchModelChanges()
        seedVocabulary()
        watchHistoryClear()
        DictationWatch.shared.onLearned = { term in Dictation.toastLearned(term) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.launchCheck() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.prewarm("launch") }
        // the mic's engine, set up but not started: the key-down only has to start it
        if Dictation.enabled { MicEngine.shared.prepare(builtIn: Dictation.useBuiltInMic) }
    }

    /// The speech model loaded a few seconds after launch (and when the key starts being heard), so the first
    /// dictation doesn't wait ~6 s for it (newc008). Only when dictation is on and its key is heard, the Mac has 16 GB
    /// or more, and the dictation model is installed (`transcribe.py dictation-models`: nothing is ever downloaded
    /// for this). At utility priority; the server ends again after 10 idle minutes, and with Blurt.
    func prewarm(_ why: String) {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let skip: String? = !Dictation.enabled ? "off" : !keys.installed ? "key_not_heard" : gb < 15 ? "memory" :
            WarmSpawn.testNoServers ? "test" : phase != .idle ? "busy" : nil
        if let s = skip { return emit(["event": "dictation_prewarm", "why": why, "skipped": s]) }
        refreshSpeechModels { [weak self] in
            guard let self = self, let m = self.speechModels, m.ready, Dictation.enabled else {
                return emit(["event": "dictation_prewarm", "why": why, "skipped": "not_installed",
                             "model": self?.speechModels?.selected ?? NSNull()])
            }
            VoiceInput.warmSpeechModel(dictation: true)
            emit(["event": "dictation_prewarm", "why": why, "model": m.selected])
        }
    }

    /// `transcribe.py dictation-models` → `speechModels`: read once, through DictationModels (Settings' rows, the
    /// download manager's sizes and the key all go by the same answer; `then` on the main thread).
    func refreshSpeechModels(then: (() -> Void)? = nil) {
        MainActor.assumeIsolated {
            Task { @MainActor in
                await DictationModels.shared.load()
                if let a = DictationModels.shared.asr { self.setSpeechModels(a.dictionary) }
                then?()
            }
        }
    }

    /// The dictation-models answer (the CLI's, or Settings' when it reloads it). A take that failed for lack of a
    /// model, when a model is there now: the island offers Retry for it.
    func setSpeechModels(_ r: [String: Any]) {
        guard let m = DictationSpeechModels(r) else { return }
        let was = speechModels
        speechModels = m
        if was?.ready != m.ready || was?.missing != m.missing {
            emit(["event": "dictation_models", "selected": m.selected, "ready": m.ready, "installed": m.selectedInstalled,
                  "missing": m.missing, "recommended": m.recommended])
        }
        if was?.ready == false, m.ready { modelArrived() }
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
        island.toast(Loc.t("dictation.toast.learned", table: "Dictation", term), key: "dictation.learned", icon: .check,
                     actionTitle: Loc.t("dictation.toast.undo", table: "Dictation"), action: {
            DictationVocabulary.shared.forget(term)
            emit(["event": "dictation_vocab_undo", "term": term])
        })
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
        trigger.doubleTapWindow = DictationTrigger.window(doubleClickInterval: NSEvent.doubleClickInterval)
        keys.watchedKeyCodes = trigger.key.keyCodes
        keys.wantsFilter = Dictation.enabled && trigger.key == .fn && Dictation.fnCapture
        // another running Blurt (a release next to a dev build) already listens to this key: it keeps it — two
        // listeners would both type — and this one takes over when that one quits (App.otherInstancesChanged)
        let hk = Hotkeys.shared
        hk.testBuild = DictationInsert.testMode
        deferredTo = Dictation.enabled && hk.resident ? hk.dictationOwner(trigger.key.rawValue) : nil
        if Dictation.enabled && deferredTo == nil {
            // DictationKeys polls (and listens for Blurt being activated) until the key is heard everywhere; test
            // builds only simulate macOS, and only when a test says something about it
            keys.start()
            hk.dictationKey = keys.installed ? trigger.key.rawValue : nil     // published only while it is heard
        } else {
            keys.stop()
            hk.dictationKey = nil
            if busy { cancel() }
        }
        lastAccess = access
        emit(["event": "dictation_keys", "enabled": Dictation.enabled, "tap": keys.installed, "listener": keys.kind.rawValue,
              "key": trigger.key.rawValue, "filter": keys.filtering,
              "mode": trigger.mode.rawValue, "double_tap": trigger.doubleTap, "double_tap_window": trigger.doubleTapWindow, "input_monitoring": DictationKeys.inputMonitoring, "accessibility": DictationKeys.accessibility,
              "test_mode": DictationInsert.testMode, "deferred_to": deferredTo.map { Int($0) } ?? NSNull()])
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
        // the key is heard now: unless another Blurt already hears it (then that one keeps it, this one stops
        // listening), publish it; not heard any more: unpublish, so another instance that can hear it takes over
        let hk = Hotkeys.shared
        if Dictation.enabled, hk.resident, deferredTo == nil {
            let heard = keys.installed ? trigger.key.rawValue : nil
            if heard != nil, hk.dictationKey == nil, hk.dictationOwner(trigger.key.rawValue) != nil { return checkOwner(via: "heard") }
            hk.dictationKey = heard
        }
        let now = access
        if let before = lastAccess, DictationAccess.confirm(before: before, after: now) { confirmOn() }
        lastAccess = now
    }

    /// What the cues go by: on, and is the key heard (the tap, not a permission check).
    var access: DictationAccess { DictationAccess(enabled: Dictation.enabled, tapInstalled: keys.installed) }
    /// On but deaf: the menu row, Settings → Dictation's warning, the island's reminder. Not while another Blurt has
    /// the key (nothing to set up here).
    var needsSetup: Bool { deferredTo == nil && access.needsSetup }
    /// The pid of the other running Blurt that listens to the dictation key instead of this one.
    private(set) var deferredTo: pid_t?

    /// Another Blurt started or quit: listen again if the key is free now (or leave it, if one has it).
    func checkOwner(via why: String) {
        guard Dictation.enabled else { return }
        let before = deferredTo
        let owner = Hotkeys.shared.dictationOwner(trigger.key.rawValue)
        guard owner != before else { return }
        apply()
        emit(["event": "dictation_owner", "via": why, "deferred_to": deferredTo.map { Int($0) } ?? NSNull(),
              "before": before.map { Int($0) } ?? NSNull()])
    }

    /// "Dictation is on: tap right Option to talk" — once, when the key starts being heard.
    private func confirmOn() {
        Config.shared.set("app.dictation_nudged_at", nil)
        var t = Island.Toast(text: Loc.t("dictation.toast.on.\(Dictation.mode.rawValue)", table: "Dictation",
                                         Dictation.keyShort), actionTitle: nil, action: nil)
        t.seconds = 5
        island.toast(t)
        emit(["event": "dictation_on"])
        prewarm("key_on")
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
        let outs = trigger.handle(e)
        if Dictation.keyTrace { trace(e, outs) }
        for out in outs {
            switch out {
            case .arm: arm()
            case .start: start()
            case .stop: stop()
            case .cancel: cancel(quietly: outs.contains(.send))
            case .send: send()
            case .style: toggleStyle(via: wasIsland ? .island : .shift)
            }
        }
        // the press became a shortcut (Fn-←, ⌥A), a click joined in, or it was let go too early / too late: the mic
        // opened on the key-down closes again, and nothing is kept
        if precaptured, !listening, !trigger.armedDown { dropPrecapture() }
        // a press this mode doesn't use (a tap in hold mode, a long press in tap mode): say how it starts
        if let m = trigger.takeMiss() { missedPress(m) }
        updateShiftFilter()
        scheduleHoldTick()
    }

    private var lastTraced: Double?
    /// record.dictation.key_trace (off; a debugging switch): each event the trigger got, as the keyboard sent it, and
    /// what it said — to check a real double tap on the user's own keyboard. Only the dictation key's own changes carry
    /// their flags; any other key is "key" (no key code: this is not a key log).
    private func trace(_ e: DictationTrigger.Event, _ outs: [DictationTrigger.Output]) {
        var o: [String: Any] = ["event": "dictation_keytrace", "out": outs.map { "\($0)" }, "pending": trigger.pending,
                                "active": trigger.active, "phase": phase.rawValue]
        let t: Double
        switch e {
        case let .flags(c, f, at):
            t = at
            if trigger.key.keyCodes.contains(c) { o["type"] = "dictation_key"; o["flags"] = String(f, radix: 16) } else { o["type"] = "modifier" }
        case let .keyDown(c, at): t = at; o["type"] = c == DictationTrigger.escape ? "esc" : c == 179 ? "globe" : "key"
        case let .mouseDown(at): t = at; o["type"] = "click"
        case let .islandClick(at): t = at; o["type"] = "island"
        case let .tick(at): t = at; o["type"] = "tick"
        }
        if let l = lastTraced { o["dt_ms"] = Int((t - l) * 1000) }
        lastTraced = t
        emit(o)
    }

    /// While a take listens (or its key is down), a lone ⇧ is the style toggle: the Fn filter keeps it from the app
    /// in front too (an input method would switch between Chinese and English on it).
    func updateShiftFilter() {
        keys.swallowShift = trigger.active || trigger.armedDown || listening
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
        // no speech model: nothing to listen for (the start says so) — and nothing to warm, nothing downloaded
        guard !speechModelMissing else { return }
        warm()
        guard Dictation.precapture, !listening, voice == nil, canListen(toast: false) else { return }
        precaptured = true
        beginCapture()
    }

    /// The speech model dictation would use isn't on this Mac (known only once `dictation-models` has answered).
    var speechModelMissing: Bool { speechModels.map { !$0.ready } ?? false }

    /// Key went down alone: get the models loaded while the user starts talking. A server that isn't running is
    /// started offline first (no package index lookup: `uv run` checking PyPI after its cache expired took 13 s here,
    /// which is how a cold polish server missed a 19 s dictation); online only if that fails.
    func warm() {
        guard !speechModelMissing else { return }
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
        if listening { trigger.reset(active: false); stop() } else {
            armedAt = CACurrentMediaTime()
            warm(); trigger.reset(active: true); start()
        }
    }

    /// Not while recording (it owns the mic) or while a voice note listens. (Without a speech model the key-down and the
    /// start already refused: `speechModelMissing`.)
    private func canListen(toast: Bool) -> Bool {
        if (NSApp.delegate as? App)?.rec != nil {
            if toast { island.toast(Loc.t("dictation.toast.recording_busy", table: "Dictation"), key: Dictation.toastKey) }
            return false
        }
        if VoiceInput.shared.active || NoteBubble.shared.isListening {     // a voice note, or a snap's spoken note
            if toast { island.toast(Loc.t("dictation.toast.voice_busy", table: "Dictation"), key: Dictation.toastKey) }
            return false
        }
        return true
    }

    /// The mic (or the test wav) → the wav file and the stream. On the key-down (pre-capture) or at the start.
    private func beginCapture() {
        front = NSWorkspace.shared.frontmostApplication
        frontKey = currentFrontKey
        runaway = DictationRunaway()
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
            if !self.listening { self.trigger.reset(active: false); return self.dropPrecapture() }
            if e == .maxed {
                // the 5-minute limit: said, and the user's next tap (meant as the stop) doesn't start a new take
                self.trigger.endedByItself(at: CACurrentMediaTime())
                self.toast("dictation.toast.limit", key: "dictation.listening", seconds: 4)      // in place of "still listening"
                emit(["event": "dictation_limit", "id": self.entryID, "seconds": DictationRunaway.limit])
            } else {
                self.trigger.reset(active: false)
            }
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
        opt.interim = Dictation.livePartial && LiveTranscript.enabled
        let s = DictationStream(id: entryID, dir: DictationHistory.shared.audioDir, wholeWav: url, options: opt)
        let stopAt = DictationInsert.testMode ? testStopAfter : nil
        testStopAfter = nil
        v.onSamples = { [weak s, weak v, weak self] x in
            s?.append(x)
            if let self = self, let v = v, self.voice === v, self.listening { self.watchRunaway(v) }
            // tests: the release at that point of the audio, after this buffer (as a key-up would)
            if let t = stopAt, let v = v, v.elapsed >= t {
                DispatchQueue.main.async {
                    guard let self = self, self.voice === v, self.listening else { return }
                    self.trigger.reset(active: false)
                    self.stop()
                }
            }
        }
        // the words while talking: the pieces' transcripts as they come in, the piece still being said after them
        let live = LiveTranscript.shared.begin(.dictation)
        liveSession = live
        s.onLive = { committed, pending in LiveTranscript.shared.update(committed, pending: pending, session: live) }
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
                self.trigger.reset(active: false, keepTap: true)     // a second tap still sends: Return needs no mic
                self.discard(quietly: true)
                NoteVoice.toastUnavailable()
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
        if listening {
            island.dictationChanged()
            if Dictation.startSound, (NSApp.delegate as? App)?.rec == nil { NSSound(named: "Tink")?.play() }
        }
    }

    /// A pre-capture the trigger didn't turn into a dictation: closed, nothing kept.
    private func dropPrecapture() {
        guard precaptured, !listening else { return }
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
        // one take listens at a time (takes still on their way don't stop the next one from starting)
        guard !listening else {
            trigger.reset(active: false, keepTap: true)
            emit(["event": "dictation_start_refused", "phase": phase.rawValue])
            return
        }
        // no speech model: say so (with the way to get one) instead of listening to words that can't be recognised
        guard !speechModelMissing else {
            trigger.reset(active: false, keepTap: true)
            dropPrecapture()
            emit(["event": "dictation_start_refused", "why": "no_model", "model": speechModels?.selected ?? NSNull()])
            return noSpeechModel()
        }
        guard canListen(toast: true) else {
            trigger.reset(active: false, keepTap: true)      // a second tap still sends: Return needs no mic
            dropPrecapture()
            return
        }
        let adopted = precaptured && voice != nil
        precaptured = false
        if !adopted { beginCapture() }
        voice?.noSpeechTimeout = trigger.pushToTalk ? .infinity : 30     // push-to-talk ends when the key comes up
        if trigger.startShift { explicitStyle = (.structured, .chord); routeStyle() }      // Fn+⇧: start in Structured
        listening = true
        // a tap-started take may be a double tap's first tap (a send): the listening aura waits out the window, so a
        // send never flashes it
        glowFrom = CACurrentMediaTime() + DictationGlow.delay(pushToTalk: trigger.pushToTalk,
                                                             doubleTapSend: Dictation.doubleTapSend && trigger.doubleTap,
                                                             window: trigger.doubleTapWindow)
        updatePhase()
        captureContext()
        readCaret()
        if !keys.installed {        // without the tap, Esc comes as a Carbon hotkey (as for the voice note)
            registerHotkey(.dictationEsc, key: kVK_Escape, mods: 0)
            escRegistered = true
        }
        // what the island said about the last take (its Undo, the list chip, "nothing heard") is over — not a failed
        // take's Retry or "Cancelled · Undo" (their own keys, DictationTakes.swift)
        island.dropToasts(key: Dictation.toastKey)
        emit(["event": "dictation_start", "id": entryID, "app": front?.localizedName ?? "", "bundle": front?.bundleIdentifier ?? "",
              "key": trigger.key.rawValue, "mode": trigger.mode.rawValue, "push_to_talk": trigger.pushToTalk,
              "precaptured": adopted, "mic_live": micLive, "pending": queue.count, "style": styleDecision?.style.rawValue ?? "light",
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
        guard listening else {
            trigger.reset(active: false, keepTap: true)     // in step with the app: nothing is listening
            return
        }
        // a double tap a little too slow for the window: the first tap started, the second stopped within 0.8 s and
        // nothing was said — the user meant Return, not "nothing heard" (timing only; no words are read)
        if trigger.quickStop, !heardSpeech, Dictation.doubleTapSend {
            emit(["event": "dictation_cancel", "id": entryID, "phase": phase.rawValue, "why": "near_miss_double_tap"])
            discard(quietly: true)
            send(after: "near_miss")
            return
        }
        finish(ended: false)
    }

    /// Esc, a double tap's second tap, the menu: ends a take that is listening (nothing kept) — or, when none
    /// listens, throws away the takes still on their way (never pasted, a queued Return dropped). A paste already
    /// under way (the 0.6 s of ⌘V) can't be taken back.
    /// `quietly`: the double tap's own cancel (it sends right after); otherwise the island says "Cancelled".
    func cancel(quietly: Bool = false) {
        guard listening else {
            dropPrecapture()
            let stopped = cancelPending()
            if !stopped.isEmpty, !quietly { toastCancelled(stopped) }
            return
        }
        trigger.reset(active: false)
        emit(["event": "dictation_cancel", "id": entryID, "phase": phase.rawValue])
        discard(quietly: true)
        if !quietly { toast("dictation.toast.cancelled", key: Dictation.cancelToastKey, seconds: 1.2) }
    }

    /// A double tap: Return in the app in front ("send"). After the takes still on their way, once the last one has
    /// been pasted (the clipboard is back by then, so the paste has landed); otherwise now. The dictation the double
    /// tap's first tap started was cancelled just before (nothing pasted, nothing in the history).
    private func send(after: String = "tap") {
        if let id = queue.last, let t = takes[id] {
            t.sendAfterPaste = true
            emit(["event": "dictation_send", "result": "queued", "phase": phase.rawValue, "id": id])
            return
        }
        pressReturn(after: after)
    }

    /// How many times a double tap asked for Return (pressed or not — Blurt's own window never gets one): the setup
    /// assistant's Try-it step watches it to see the send gesture was tried.
    private(set) var sendAttempts = 0

    func pressReturn(after: String) {
        sendAttempts += 1
        let r = DictationInsert.pressReturn()
        emit(["event": "dictation_send", "result": r.result, "why": r.why ?? NSNull(), "after": after])
        if r.pressed {
            noteUsed(.send)
            island.dictationSent()          // "Sent" with the ok check, in the ear (the island doesn't grow for one word)
        } else {
            sendSkipped(r.why)
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
        listening = false
        LiveTranscript.shared.end(session: liveSession)
        updatePhase()
        if !quietly { toastNothing() }
    }

    /// The silence watch while a take listens: a reminder after 20 s without speech, the countdown from 4:30.
    private func watchRunaway(_ v: NoteVoice) {
        // talking now: the last stretch of speech is under half a second ago (`speaking` alone stays on through pauses)
        guard let n = runaway.feed(elapsed: v.elapsed, speaking: v.quietSeconds < 0.5, handsFree: !trigger.pushToTalk) else { return }
        switch n {
        case .stillListening:
            emit(["event": "dictation_runaway", "notice": "still_listening", "id": entryID, "elapsed": Int(v.elapsed)])
            toast("dictation.toast.still_listening", Dictation.keyShort, key: "dictation.listening", seconds: 4, passive: true)
        case .endsSoon:
            emit(["event": "dictation_runaway", "notice": "ends_soon", "id": entryID, "elapsed": Int(v.elapsed)])
            island.dictationChanged()
        }
    }

    /// One quiet line on the island from this table (`name`), about `key` (Island.toast: a newer one with the same key
    /// replaces it at once). `passive`: not a reply to what the user just did (a reminder, a tip) — it waits behind
    /// replies. Every toast stays at least ToastQueue.minSeconds, whatever `seconds` asks.
    func toast(_ name: String, _ args: CVarArg..., key: String?, seconds: Double = 2.4, icon: BlurtIcon? = nil,
               passive: Bool = false) {
        let fmt = Loc.string(name, table: "Dictation")
        var t = Island.Toast(text: args.isEmpty ? fmt : String(format: fmt, locale: Loc.locale, arguments: args),
                             actionTitle: nil, action: nil)
        t.seconds = seconds
        t.icon = icon
        t.key = key
        t.passive = passive
        island.toast(t)
    }

    /// "Didn't catch anything (AirPods) · Change Mic…" / "No sound from AirPods" (BlurtCore NothingHeard): the mic it
    /// listened with, and the way to another — Settings → Dictation's microphone.
    func toastNothing(levels: [Float]? = nil) {
        let levels = levels ?? self.levels
        let why = NothingHeard.why(levels: levels)
        let name = micName
        emit(["event": "dictation_nothing", "why": why.rawValue, "mic": name ?? NSNull(),
              "peak": Double(levels.max() ?? 0)])
        // about the last take (Dictation.toastKey): the next take's start drops it
        island.toast(Loc.t(NothingHeard.key(why, hasName: name != nil), table: "Dictation", name ?? ""), key: Dictation.toastKey,
                     actionTitle: Loc.t("dictation.toast.nothing.change", table: "Dictation")) {
            AppEnvironment.settings?.show(pane: "dictation/mic")
        }
    }

    /// The microphone dictation listens with: the Mac's own (when it uses it) or the default input; a test build's
    /// stand-in wav by its file name. nil = not known.
    var micName: String? {
        if DictationInsert.testMode {
            let env = ProcessInfo.processInfo.environment
            return (testWav ?? env["BLURT_TEST_MIC_WAV"] ?? env["BLURT_NOTE_WAV"]).map { URL(fileURLWithPath: $0).lastPathComponent }
        }
        let useBuiltInMic = Dictation.useBuiltInMic
        let id = useBuiltInMic ? AudioDevices.builtInInput() : AudioDevices.defaultInput
        return id.flatMap { d in AudioDevices.inputs().first { $0.id == d }?.name }
    }

    // MARK: the words

    /// The take stops listening: it joins the takes on their way (DictationTakes.swift), and the key is free for the
    /// next one at once.
    private func finish(ended: Bool) {
        guard let v = voice, let url = wav, let s = stream else { return }
        let keyUp = CACurrentMediaTime()
        let duration = v.elapsed
        if !ended { v.stop(keep: heardSpeech) }
        voice = nil
        stream = nil
        micLive = false
        listening = false
        releaseEsc()
        guard heardSpeech else {
            s.cancel()
            try? FileManager.default.removeItem(at: url)
            LiveTranscript.shared.end(session: liveSession)
            updatePhase()
            return toastNothing()
        }
        let polish = Dictation.polishOn && polishModel != nil
        // Structured / Auto (the style as the take ends: ⇧ and the island may have changed it): one structuring pass
        let structure = (styleDecision?.style == .structured || styleDecision?.style == .auto) && polish
        let take = DictationTake(id: entryID, front: front, frontKey: frontKey, started: startedAt, duration: duration,
                                 wav: url, context: polish ? context : nil, polishTried: polish, keyUp: keyUp,
                                 style: styleDecision, explicit: explicitStyle, toggles: styleToggles,
                                 bundle: styleBundle, liveSession: liveSession, stream: s, structure: structure)
        take.levels = levels
        emit(["event": "dictation_stop", "id": take.id, "duration": (duration * 100).rounded() / 100, "segments": s.segments,
              "pending": queue.count])
        enqueue(take)
    }

    /// The warm server (no process start; waiting up to `budget` for one starting), else `transcribe.py note
    /// --no-server` (it loads the model itself). Dictation's model (record.dictation.asr_model, else the recommended
    /// one when installed), biased toward the words, with `prior` (the text so far) as context; the answer's `text` is
    /// what the model wrote (`asr_text`, when present, the same). Blocking: off the main thread.
    /// `hint`: the target window's title and the text around the cursor (DictationContext.hint) — words seen there go
    /// to the model first (docs/design/dictation.md §Code-switching).
    /// Always an answer: `ok` true with the text, or false with `code` (model_missing, timeout, …) and `error` — a
    /// failure is never mistaken for silence. Nothing is ever downloaded for a dictation (`no_download`,
    /// `--no-download`). The server gets `DictationASRFailure.serverTimeout` for this much audio, not a flat minute;
    /// a server that doesn't answer in that time is given up on (ended when it is ours) and the CLI is used — which
    /// no longer asks that same server first (`--no-server`).
    static func transcribe(_ wav: URL, vocab: [[String: Any]], language: String, prior: String, budget: Double,
                           hint: String = "", audioSeconds: Double) -> [String: Any] {
        var req: [String: Any] = ["cmd": "note", "wav": wav.path, "language": language, "purpose": "dictation", "vocab": vocab,
                                  "no_download": true]
        if !prior.isEmpty { req["prior"] = prior }
        if !hint.isEmpty { req["hint"] = hint }
        let until = Date().addingTimeInterval(budget)
        while !WarmServer.running("asr-serve") && Date() < until && VoiceInput.serverStarting { usleep(50_000) }
        if WarmServer.running("asr-serve"), !serverGivenUp {
            let t0 = Date()
            if let r = WarmServer.call("asr-serve", req, timeout: DictationASRFailure.serverTimeout(audioSeconds: audioSeconds)) {
                if r["ok"] as? Bool == true { return r }
                // no model: the CLI would only say the same
                if r["code"] as? String == "model_missing" { return r }
            } else if Date().timeIntervalSince(t0) >= DictationASRFailure.serverTimeout(audioSeconds: audioSeconds) - 0.5 {
                giveUpOnServer()
            }
        }
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any] = ["ok": false, "code": "error"]
        Task.detached {
            do {
                out = try await ScriptRunner.shared.json("transcribe.py", ["note", wav.path, "--language", language, "--dictation",
                                                                           "--vocab", "--no-server", "--no-download"], timeout: 120)
            } catch ScriptError.failed(_, let stdout, _) {
                let line = String(decoding: stdout, as: UTF8.self).split(separator: "\n").last { $0.hasPrefix("{") }
                let o = line.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                out = ["ok": false, "code": o?["code"] as? String ?? "error", "error": o?["error"] as? String ?? ""]
            } catch ScriptError.timeout {
                out = ["ok": false, "code": "timeout"]
            } catch {
                out = ["ok": false, "code": "error", "error": "\(error)"]
            }
            sem.signal()
        }
        sem.wait()
        return out
    }

    /// A speech server that stopped answering (hung, stopped): its requests go to the CLI for a minute — that server,
    /// by its pid: a fresh one (the next key-down starts it) is used as soon as it is up. The one Blurt started is
    /// ended, except while a voice note is waiting on it (it may only be busy with that note: the note's own timeout
    /// and CLI fallback cover a real hang).
    private static let serverLock = NSLock()
    private static var serverGivenUpAt: Date?
    private static var serverGivenUpPid: Int32?
    static var serverGivenUp: Bool {
        serverLock.lock(); defer { serverLock.unlock() }
        guard let at = serverGivenUpAt, Date().timeIntervalSince(at) < 60 else { return false }
        return DictationServerGiveUp.stillGivenUp(givenUp: serverGivenUpPid, now: WarmServer.pid("asr-serve"))
    }
    private static func giveUpOnServer() {
        serverLock.lock()
        serverGivenUpAt = Date()
        serverGivenUpPid = WarmServer.pid("asr-serve")
        serverLock.unlock()
        let busy = VoiceInput.notesWaiting > 0
        emit(["event": "dictation_asr_server", "state": "given_up", "pid": serverGivenUpPid ?? NSNull(), "ended": !busy])
        if !busy { DispatchQueue.main.async { VoiceInput.endUnresponsiveServer() } }
    }

    /// An interim request for the live text: the warm server only (no process start, no CLI — a missing server is
    /// "no_server", tried again later), `interim` so the server stops it as soon as a final piece (or anything) waits.
    /// Blocking: off the main thread.
    static func transcribeInterim(_ wav: URL, vocab: [[String: Any]], language: String, prior: String,
                                  hint: String) -> [String: Any]? {
        guard WarmServer.running("asr-serve") else { return ["ok": false, "code": "no_server"] }
        var req: [String: Any] = ["cmd": "note", "wav": wav.path, "language": language, "purpose": "dictation",
                                  "vocab": vocab, "interim": true, "no_download": true]
        if !prior.isEmpty { req["prior"] = prior }
        if !hint.isEmpty { req["hint"] = hint }
        return WarmServer.call("asr-serve", req, timeout: 15)
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
}

/// Starting a warm model server (transcribe.py / polish.py serve): offline first — `uv run` resolves the script's
/// packages, and once its index cache has expired it asks PyPI again (13 s here on the first try, 2.5 s cached), which
/// made a cold server miss a whole dictation. With UV_OFFLINE=1 the cached packages are used as they are; only when
/// that fails (nothing cached yet: the first use ever) does it start again online.
/// Every server started here gets `--parent <this app>`: it ends when Blurt quits (or crashes), after answering a
/// request in flight, and it ends by itself after 10 idle minutes — so the models' memory (~5 GB for both) goes back.
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
        let args = args.first == "serve" && !args.contains("--parent") ? args + ["--parent", "\(getpid())"] : args
        // BLURT_NO_DOWNLOAD: a server started by a key press never downloads a model (the download manager does that,
        // when the user asks); a request for a missing model is answered "model_missing"
        let p = try? ScriptRunner.shared.spawn(script, args, env: ["UV_OFFLINE": "1", "BLURT_NO_DOWNLOAD": "1"]) { _ in }
        p?.terminationHandler = { proc in
            guard proc.terminationStatus != 0, !WarmServer.running(server) else { return }
            emit(["event": "warm_spawn_online", "script": script, "status": Int(proc.terminationStatus)])
            DispatchQueue.main.async { _ = try? ScriptRunner.shared.spawn(script, args, env: ["BLURT_NO_DOWNLOAD": "1"]) { _ in } }
        }
        return p
    }
}
