// Dictation (听写, docs/design/dictation.md): talk, and the words are typed into whichever app has the focus —
// separate from the voice note (⌥⇧V files into Blurt; the two never share a key).
//
//  • trigger: Fn (default; or right ⌥, or either ⌥) alone, read by an event tap (DictationKeys) and decided by
//    BlurtCore's DictationTrigger — auto (default: a tap is hands-free, holding is push-to-talk), tap / tap, or hold
//    to talk. Esc cancels. With Fn and Accessibility, the tap is an active filter that keeps the Fn press from macOS.
//  • the key needs Accessibility (the Fn filter, or the monitor) or Input Monitoring (the listen-only tap). Until it
//    is heard (BlurtCore's DictationAccess decides): the menu-bar menu's top row says "Turn On Dictation…", the
//    island reminds about once a day (launch, the voice-note key, Settings), and both start the permission guide
//    (Onboarding/PermissionGuide.swift); a poll picks the grant up without a restart. macOS is never asked at launch.
//    Test builds never install a tap or ask macOS: BLURT_TEST_DICTATION_TAP=ok|failed (or `dictation tap …`)
//    simulates the answer.
//  • capture: NoteVoice (the voice note's mic → wav path; BLURT_TEST_MIC_WAV / BLURT_NOTE_WAV in tests), no silence
//    stop — you end it. The models are warmed on key-down: `transcribe.py serve --preload` (SenseVoice, or what
//    Settings → Speech picked for voice notes) and, with polish on, `polish.py serve --preload`.
//  • text: the warm ASR server (WarmServer, no `uv run` per request), else `transcribe.py note`; then polish (Light)
//    through the warm polish server with record.dictation.polish_timeout_ms (3 s) — any fall-back = the raw text.
//  • insert: DictationInsert (pasteboard → ⌘V → pasteboard back). History: DictationHistory (history.jsonl).
//  • custom words (DictationVocabulary, vocabulary.json): sent with every request — the speech model is biased toward
//    them where it can be and exact sounds-likes are fixed (transcribe.py), polish gets them as spelling hints with
//    the text around the cursor (DictationContext, read at the start, never stored). After the text goes in, the
//    field is watched for a minute (DictationWatch) and the user's own fixes become words (DictationLearn).
//  • off while a screen recording runs (it owns the mic) and while a voice note listens.
// Config record.dictation: enabled (true), key fn|right_option|either_option (unset = fn), mode auto|tap|hold (unset =
// auto), fn_capture (true: keep Fn from macOS's own 🌐 action), polish off|light, polish_model,
// polish_timeout_ms, retention_days (30), keep_audio (false), asr_model (automatic), context (true), learn (true). Test hooks: SnapApp.swift `dictation …`.
import AppKit
import BlurtCore
import Carbon.HIToolbox

final class Dictation {
    static let shared = Dictation()

    enum Phase: String { case idle, listening, transcribing, polishing }
    private(set) var phase: Phase = .idle { didSet { if phase != oldValue { island.dictationChanged() } } }
    private(set) var levels: [Float] = []
    private(set) var lastResult: [String: Any]?
    var busy: Bool { phase != .idle }

    private var trigger = DictationTrigger()
    private let keys = DictationKeys()
    private var voice: NoteVoice?
    private var wav: URL?
    private var entryID = ""
    private var startedAt = Date()
    private var heardSpeech = false
    private var front: NSRunningApplication?
    private var holdTimer: Timer?
    private var escRegistered = false
    private var polishServer: Process?
    /// `polish.py models` said a model is installed and selected (refreshed at launch and by Settings)
    private(set) var polishModel: String?
    private var generation = 0
    /// the text around the cursor when this dictation started (polish's hints; never stored unless debugging)
    private var context: DictationContext?

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
    static var retentionDays: Int { settings["retention_days"] as? Int ?? 30 }
    static var keepAudio: Bool { settings["keep_audio"] as? Bool ?? false }
    /// read the text around the cursor for polish (Accessibility, read-only)
    static var contextOn: Bool { settings["context"] as? Bool ?? true }
    /// watch the field after typing and learn the user's fixes
    static var learnOn: Bool { settings["learn"] as? Bool ?? true }

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
              "mode": trigger.mode.rawValue, "input_monitoring": DictationKeys.inputMonitoring, "accessibility": DictationKeys.accessibility,
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
        island.toast(t)
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
    static var keyShort: String {
        switch key {
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

    func handle(_ e: DictationTrigger.Event) {
        guard Dictation.enabled else { return }
        for out in trigger.handle(e) {
            switch out {
            case .arm: warm()
            case .start: start()
            case .stop: stop()
            case .cancel: cancel()
            }
        }
        scheduleHoldTick()
    }

    private func scheduleHoldTick() {
        holdTimer?.invalidate()
        guard let d = trigger.deadline else { return }
        let wait = max(0, d - CACurrentMediaTime())
        holdTimer = Timer.scheduledTimer(withTimeInterval: wait + 0.005, repeats: false) { [weak self] _ in
            self?.handle(.tick(time: CACurrentMediaTime()))
        }
    }

    /// Key went down alone: get the models loaded while the user starts talking.
    private func warm() {
        VoiceInput.warmSpeechModel(dictation: true)
        guard Dictation.polishOn, polishModel != nil else { return }
        if WarmServer.running("polish-serve") {
            DispatchQueue.global(qos: .userInitiated).async { _ = WarmServer.call("polish-serve", ["cmd": "load"], timeout: 30) }
        } else if polishServer?.isRunning != true {
            polishServer = try? ScriptRunner.shared.spawn("polish.py", ["serve", "--preload"]) { _ in }
        }
    }

    // MARK: start / stop / cancel

    /// Also the menu's "Start Dictation" (and the test hook): the same as a tap.
    func toggle() {
        if phase == .listening { trigger.reset(active: false); stop() } else if phase == .idle { warm(); trigger.reset(active: true); start() }
    }

    private func start() {
        guard phase == .idle else { return }
        if (NSApp.delegate as? App)?.rec != nil {
            trigger.reset(active: false)
            return island.toast(Loc.t("dictation.toast.recording_busy", table: "Dictation"), actionTitle: nil, action: nil)
        }
        if VoiceInput.shared.active || NoteBubble.shared.isListening {     // a voice note, or a snap's spoken note
            trigger.reset(active: false)
            return island.toast(Loc.t("dictation.toast.voice_busy", table: "Dictation"), actionTitle: nil, action: nil)
        }
        front = NSWorkspace.shared.frontmostApplication
        startedAt = Date()
        entryID = DictationHistory.newID(startedAt)
        let url = DictationHistory.shared.audioDir.appendingPathComponent("\(entryID).wav")
        let v = NoteVoice(url: url)
        v.inject = ProcessInfo.processInfo.environment["BLURT_TEST_MIC_WAV"] ?? ProcessInfo.processInfo.environment["BLURT_NOTE_WAV"]
        v.silenceToEnd = .infinity                   // you end it, not a pause
        v.noSpeechTimeout = trigger.pushToTalk ? .infinity : 30     // push-to-talk ends when the key comes up
        v.maxLength = 300
        v.onLevel = { [weak self] l in
            guard let self = self else { return }
            self.levels.append(l)
            if self.levels.count > 120 { self.levels.removeFirst(self.levels.count - 120) }
        }
        v.onSpeech = { [weak self] in self?.heardSpeech = true }
        v.onEnd = { [weak self] e in
            guard let self = self, self.voice === v else { return }
            self.trigger.reset(active: false)
            if e == .noSpeech { self.discard(quietly: false) } else { self.finish(ended: true) }
        }
        voice = v
        wav = url
        levels = []
        heardSpeech = false
        generation += 1
        phase = .listening
        captureContext()
        if !keys.installed {        // without the tap, Esc comes as a Carbon hotkey (as for the voice note)
            registerHotkey(.dictationEsc, key: kVK_Escape, mods: 0)
            escRegistered = true
        }
        emit(["event": "dictation_start", "id": entryID, "app": front?.localizedName ?? "", "bundle": front?.bundleIdentifier ?? "",
              "key": trigger.key.rawValue, "mode": trigger.mode.rawValue, "push_to_talk": trigger.pushToTalk])
        v.start { [weak self] ok in
            guard let self = self, self.voice === v else { return }
            if !ok {
                self.trigger.reset(active: false)
                self.discard(quietly: true)
                NoteVoice.toastUnavailable()
            }
        }
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
        guard phase == .listening else {
            if busy { generation += 1; phase = .idle }     // a cancel while working: drop the result
            return
        }
        trigger.reset(active: false)
        emit(["event": "dictation_cancel", "id": entryID])
        discard(quietly: true)
    }

    private func releaseEsc() {
        if escRegistered { unregisterHotkey(.dictationEsc); escRegistered = false }
    }

    private func discard(quietly: Bool) {
        voice?.stop(keep: false)
        voice = nil
        releaseEsc()
        phase = .idle
        if !quietly { island.toast(Loc.t("dictation.toast.nothing", table: "Dictation"), actionTitle: nil, action: nil) }
    }

    // MARK: the words

    private func finish(ended: Bool) {
        guard let v = voice, let url = wav else { return }
        let duration = v.elapsed
        if !ended { v.stop(keep: heardSpeech) }
        voice = nil
        releaseEsc()
        guard heardSpeech else { return discard(quietly: false) }
        phase = .transcribing
        let gen = generation
        let id = entryID, app = front, started = startedAt
        let polish = Dictation.polishOn && polishModel != nil
        let timeout = Dictation.polishTimeout
        let vocab = DictationVocabulary.shared.payload()
        let ctx = polish ? context : nil
        emit(["event": "dictation_stop", "id": id, "duration": (duration * 100).rounded() / 100])
        Task.detached(priority: .userInitiated) {
            let t0 = Date()
            let asr = await Dictation.transcribe(url, vocab: vocab)
            let asrMS = Int(Date().timeIntervalSince(t0) * 1000)
            let raw = (asr?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                await MainActor.run {
                    guard gen == self.generation else { return }
                    try? FileManager.default.removeItem(at: url)
                    self.phase = .idle
                    island.toast(Loc.t("dictation.toast.nothing", table: "Dictation"), actionTitle: nil, action: nil)
                    emit(["event": "dictation_text", "id": id, "ok": false, "asr_ms": asrMS])
                }
                return
            }
            if polish { await MainActor.run { if gen == self.generation { self.phase = .polishing } } }
            let t1 = Date()
            let pol = polish ? Dictation.polish(raw, timeout: timeout, vocab: vocab, context: ctx) : nil
            let polMS = polish ? Int(Date().timeIntervalSince(t1) * 1000) : 0
            await MainActor.run {
                guard gen == self.generation else { return }
                self.deliver(id: id, raw: raw, asr: asr ?? [:], polish: pol, polishTried: polish, app: app, started: started,
                             duration: duration, wav: url, timing: ["asr_ms": asrMS, "polish_ms": polMS], context: ctx,
                             vocabTerms: vocab.compactMap { $0["term"] as? String })
            }
        }
    }

    /// The warm server (no process start), else `transcribe.py note` (it starts the model itself). Dictation's model
    /// (record.dictation.asr_model, else the recommended one when installed), biased toward the custom words; the
    /// answer's `text` has the exact sounds-likes fixed, `asr_text` is what the model wrote.
    private static func transcribe(_ wav: URL, vocab: [[String: Any]]) async -> [String: Any]? {
        let lang = Config.shared["asr.language"] as? String ?? "auto"
        let req: [String: Any] = ["cmd": "note", "wav": wav.path, "language": lang, "purpose": "dictation", "vocab": vocab]
        if let r = WarmServer.call("asr-serve", req, timeout: 60), r["ok"] as? Bool == true {
            return r
        }
        return try? await ScriptRunner.shared.json("transcribe.py", ["note", wav.path, "--language", lang, "--dictation", "--vocab"], timeout: 120)
    }

    /// The warm polish server, waiting up to `timeout` for it to come up; its own deadline is `timeout` once the
    /// model is loaded (a cold load gets 4 s more). nil = no polish (raw text, not a fall-back).
    private static func polish(_ raw: String, timeout: Double, vocab: [[String: Any]], context: DictationContext?) -> [String: Any]? {
        let until = Date().addingTimeInterval(timeout)
        while !WarmServer.running("polish-serve") && Date() < until { usleep(100_000) }
        guard WarmServer.running("polish-serve") else { return ["ok": true, "text": raw, "fell_back": true, "reason": "unavailable"] }
        let req: [String: Any] = ["cmd": "polish", "text": raw, "timeout": timeout, "vocab": vocab, "context": context?.payload ?? NSNull()]
        guard let r = WarmServer.call("polish-serve", req, timeout: timeout + 4) else {
            return ["ok": true, "text": raw, "fell_back": true, "reason": "timeout"]
        }
        return r["ok"] as? Bool == true ? r : nil
    }

    private func deliver(id: String, raw: String, asr: [String: Any], polish: [String: Any]?, polishTried: Bool,
                         app: NSRunningApplication?, started: Date, duration: Double, wav: URL, timing: [String: Int],
                         context: DictationContext?, vocabTerms: [String]) {
        let text = (polish?["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? raw
        let fellBack = polish?["fell_back"] as? Bool ?? false
        let asrText = asr["asr_text"] as? String ?? raw         // what the speech model wrote, before the sounds-like pass
        // the custom words this dictation wrote: fixed by the sounds-like pass or polish, or (when the speech model was
        // told the words) written by the model itself
        var terms: [String] = []
        let told = asr["biased"] as? Bool == true ? vocabTerms.filter { text.contains($0) } : []
        for t in (asr["terms"] as? [String] ?? []) + (polish?["terms"] as? [String] ?? []) + told where !terms.contains(t) { terms.append(t) }
        let contextUsed = polish?["context"] as? Bool ?? false
        phase = .idle
        // where the text goes in, read just before pasting: the field the watch then follows for the user's fixes
        let field = Dictation.learnOn ? DictationField.focused() : nil
        let at = field?.read()?.selection.location
        DictationInsert.insert(text) { [weak self] result in
            guard let self = self else { return }
            let keep = Dictation.keepAudio
            if !keep { try? FileManager.default.removeItem(at: wav) }
            let e = DictationEntry(id: id, time: started, app: app?.localizedName, bundle: app?.bundleIdentifier, duration: duration,
                                   raw: asrText, polished: polish?["polished"] as? String, text: text,
                                   model: polish?["model"] as? String, fellBack: fellBack, reason: polish?["reason"] as? String,
                                   insert: result.rawValue, audio: keep ? "audio/\(wav.lastPathComponent)" : nil,
                                   asrModel: asr["model"] as? String, language: asr["language"] as? String,
                                   termsApplied: terms, contextUsed: contextUsed,
                                   context: keep && contextUsed ? context?.debugText : nil)
            DictationHistory.shared.append(e)
            if !terms.isEmpty { DispatchQueue.global(qos: .utility).async { DictationVocabulary.shared.recordHits(terms) } }
            if result == .pasted, let f = field, let loc = at { DictationWatch.shared.start(field: f, inserted: text, location: loc) }
            DictationHistoryWindow.shared.reloadIfOpen()
            if result == .copied {
                island.toast(Loc.t("dictation.toast.copied", table: "Dictation"), actionTitle: nil, action: nil)
            }
            var out: [String: Any] = ["event": "dictation_text", "id": id, "ok": true, "raw": raw, "text": text,
                                      "fell_back": fellBack, "reason": polish?["reason"] as? String ?? NSNull(),
                                      "polished": polish?["polished"] as? String ?? NSNull(), "model": polish?["model"] as? String ?? NSNull(),
                                      "insert": result.rawValue, "polish_tried": polishTried, "asr_text": asrText,
                                      "terms": terms, "context_used": contextUsed, "asr_model": asr["model"] as? String ?? NSNull(),
                                      "biased": asr["biased"] as? Bool ?? false]
            for (k, v) in timing { out[k] = v }
            self.lastResult = out
            emit(out)
        }
    }
}
