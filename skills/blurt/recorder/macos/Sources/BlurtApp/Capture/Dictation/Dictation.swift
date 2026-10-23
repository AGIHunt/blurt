// Dictation (听写, docs/design/dictation.md): talk, and the words are typed into whichever app has the focus —
// separate from the voice note (⌥⇧V files into Blurt; the two never share a key).
//
//  • trigger: right ⌥ (or Fn, or either ⌥) alone, read by a listen-only event tap (DictationKeys) and decided by
//    BlurtCore's DictationTrigger — tap to start / tap to stop (default), or hold to talk. Esc cancels.
//  • the tap needs Input Monitoring. Until it is installed (BlurtCore's DictationAccess decides): macOS is asked once
//    per version at launch, the menu-bar menu's top row says "Turn On Dictation…", the island reminds about once a
//    day (launch, the voice-note key, Settings), and a poll picks the grant up without a restart. Test builds never
//    install a tap or ask macOS: BLURT_TEST_DICTATION_TAP=ok|failed (or `dictation tap …`) simulates the answer.
//  • capture: NoteVoice (the voice note's mic → wav path; BLURT_TEST_MIC_WAV / BLURT_NOTE_WAV in tests), no silence
//    stop — you end it. The models are warmed on key-down: `transcribe.py serve --preload` (SenseVoice, or what
//    Settings → Speech picked for voice notes) and, with polish on, `polish.py serve --preload`.
//  • text: the warm ASR server (WarmServer, no `uv run` per request), else `transcribe.py note`; then polish (Light)
//    through the warm polish server with record.dictation.polish_timeout_ms (3 s) — any fall-back = the raw text.
//  • insert: DictationInsert (pasteboard → ⌘V → pasteboard back). History: DictationHistory (history.jsonl).
//  • off while a screen recording runs (it owns the mic) and while a voice note listens.
// Config record.dictation: enabled (true), key right_option|fn|either_option, mode tap|hold, polish off|light, polish_model,
// polish_timeout_ms, retention_days (30), keep_audio (false). Test hooks: SnapApp.swift `dictation …`.
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
    private var permissionTimer: Timer?
    private var escRegistered = false
    private var polishServer: Process?
    /// `polish.py models` said a model is installed and selected (refreshed at launch and by Settings)
    private(set) var polishModel: String?
    private var generation = 0

    var elapsed: Double { phase == .listening ? voice?.elapsed ?? Date().timeIntervalSince(startedAt) : 0 }

    // MARK: settings (record.dictation.*)

    static var settings: [String: Any] { recordConfig()["dictation"] as? [String: Any] ?? [:] }
    static func set(_ key: String, _ value: Any?) { Config.shared.set("record.dictation.\(key)", value) }
    static var enabled: Bool { settings["enabled"] as? Bool ?? true }
    static var key: DictationTrigger.Key { DictationTrigger.Key(rawValue: settings["key"] as? String ?? "") ?? .rightOption }
    static var mode: DictationTrigger.Mode { DictationTrigger.Mode(rawValue: settings["mode"] as? String ?? "") ?? .tap }
    static var polishOn: Bool { (settings["polish"] as? String ?? "light") != "off" }
    static var polishTimeout: Double { max(0.5, (settings["polish_timeout_ms"] as? Double ?? 3000) / 1000) }
    static var retentionDays: Int { settings["retention_days"] as? Int ?? 30 }
    static var keepAudio: Bool { settings["keep_audio"] as? Bool ?? false }

    // MARK: launch / settings changed

    /// At launch (the menu-bar app): history retention, the key tap; if the key can't be heard, ask macOS (once per
    /// version) and say so on the island (about once a day). The menu-bar menu's top row stays until it works.
    func install() {
        keys.onEvent = { [weak self] e in self?.handle(e) }
        DispatchQueue.global(qos: .utility).async { DictationHistory.shared.prune(days: Dictation.retentionDays) }
        // ≤ 0.7: a once-ever flag that silenced the reminder for good after one unseen toast
        if Config.shared["app.dictation_prompted"] != nil { Config.shared.set("app.dictation_prompted", nil) }
        apply()
        refreshPolishModel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.launchCheck() }
    }

    /// The setup assistant (first launch) has its own Input Monitoring row: no prompt or toast on top of it.
    private var assistantShows: Bool { Onboarding.needed && ProcessInfo.processInfo.environment["BLURT_NO_ONBOARDING"] == nil }

    private func launchCheck() {
        let asked = Config.shared["app.dictation_asked_version"] as? String
        if access.askAtLaunch(assistantShowing: assistantShows, askedVersion: asked, version: Dictation.appVersion) {
            Dictation.requestListenAccess(via: "launch")
        }
        if !assistantShows { nudge("launch") }
    }

    /// Re-reads the settings: the tap on or off, the key and the mode.
    func apply() {
        trigger.key = Dictation.key
        trigger.mode = Dictation.mode
        if Dictation.enabled {
            // test builds wait only when a test simulates the tap (they never install a real one)
            if !keys.start() && (!DictationInsert.testMode || DictationKeys.testTap != nil) { waitForPermission() }
        } else {
            keys.stop()
            permissionTimer?.invalidate()
            if busy { cancel() }
        }
        emit(["event": "dictation_keys", "enabled": Dictation.enabled, "tap": keys.installed, "key": trigger.key.rawValue,
              "mode": trigger.mode.rawValue, "input_monitoring": DictationKeys.inputMonitoring, "accessibility": AXIsProcessTrusted(),
              "test_mode": DictationInsert.testMode])
    }

    var tapInstalled: Bool { keys.installed }

    /// What the cues go by: on, and is the key heard (the tap, not a permission check).
    var access: DictationAccess { DictationAccess(enabled: Dictation.enabled, tapInstalled: keys.installed) }
    /// On but deaf: the menu row, Settings → Dictation's warning, the island's reminder.
    var needsSetup: Bool { access.needsSetup }

    /// No tap yet: try again every few seconds — granting Input Monitoring in System Settings needs no restart — and
    /// say so on the island when it comes up.
    private func waitForPermission() {
        permissionTimer?.invalidate()
        let every = DictationInsert.testMode ? 0.5 : 3
        permissionTimer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [weak self] t in
            guard let self = self else { return t.invalidate() }
            guard Dictation.enabled else { return t.invalidate() }
            let before = self.access
            if self.keys.start() {
                t.invalidate()
                emit(["event": "dictation_keys", "tap": true, "via": "poll"])
                if DictationAccess.confirm(before: before, after: self.access) { self.confirmOn() }
            }
        }
    }

    /// "Dictation is on: tap right Option to talk" — once, when the key starts being heard.
    private func confirmOn() {
        Config.shared.set("app.dictation_nudged_at", nil)
        var t = Island.Toast(text: Loc.t(Dictation.mode == .hold ? "dictation.toast.on.hold" : "dictation.toast.on.tap", table: "Dictation",
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

    /// "Turn On Dictation…" (the menu row, the toast's button, Settings → Dictation): Settings → Dictation, then the
    /// Input Monitoring pane on top of it with Blurt in its list.
    func openSetup() {
        AppEnvironment.settings?.show(pane: "dictation")
        Dictation.requestListenAccess(via: "setup")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Dictation.openSystemPane() }
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
                             actionTitle: Loc.t("dictation.toast.set_up", table: "Dictation"), action: { Dictation.shared.openSetup() })
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
        VoiceInput.warmSpeechModel()
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
        v.noSpeechTimeout = trigger.mode == .hold ? .infinity : 30
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
        if !keys.installed {        // without the tap, Esc comes as a Carbon hotkey (as for the voice note)
            registerHotkey(.dictationEsc, key: kVK_Escape, mods: 0)
            escRegistered = true
        }
        emit(["event": "dictation_start", "id": entryID, "app": front?.localizedName ?? "", "bundle": front?.bundleIdentifier ?? "",
              "key": trigger.key.rawValue, "mode": trigger.mode.rawValue])
        v.start { [weak self] ok in
            guard let self = self, self.voice === v else { return }
            if !ok {
                self.trigger.reset(active: false)
                self.discard(quietly: true)
                NoteVoice.toastUnavailable()
            }
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
        emit(["event": "dictation_stop", "id": id, "duration": (duration * 100).rounded() / 100])
        Task.detached(priority: .userInitiated) {
            let t0 = Date()
            let asr = await Dictation.transcribe(url)
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
            let pol = polish ? Dictation.polish(raw, timeout: timeout) : nil
            let polMS = polish ? Int(Date().timeIntervalSince(t1) * 1000) : 0
            await MainActor.run {
                guard gen == self.generation else { return }
                self.deliver(id: id, raw: raw, asr: asr ?? [:], polish: pol, polishTried: polish, app: app, started: started,
                             duration: duration, wav: url, timing: ["asr_ms": asrMS, "polish_ms": polMS])
            }
        }
    }

    /// The warm server (no process start), else `transcribe.py note` (it starts the model itself).
    private static func transcribe(_ wav: URL) async -> [String: Any]? {
        let lang = Config.shared["asr.language"] as? String ?? "auto"
        if let r = WarmServer.call("asr-serve", ["cmd": "note", "wav": wav.path, "language": lang], timeout: 60), r["ok"] as? Bool == true {
            return r
        }
        return try? await ScriptRunner.shared.json("transcribe.py", ["note", wav.path, "--language", lang], timeout: 120)
    }

    /// The warm polish server, waiting up to `timeout` for it to come up; its own deadline is `timeout` once the
    /// model is loaded (a cold load gets 4 s more). nil = no polish (raw text, not a fall-back).
    private static func polish(_ raw: String, timeout: Double) -> [String: Any]? {
        let until = Date().addingTimeInterval(timeout)
        while !WarmServer.running("polish-serve") && Date() < until { usleep(100_000) }
        guard WarmServer.running("polish-serve") else { return ["ok": true, "text": raw, "fell_back": true, "reason": "unavailable"] }
        guard let r = WarmServer.call("polish-serve", ["cmd": "polish", "text": raw, "timeout": timeout], timeout: timeout + 4) else {
            return ["ok": true, "text": raw, "fell_back": true, "reason": "timeout"]
        }
        return r["ok"] as? Bool == true ? r : nil
    }

    private func deliver(id: String, raw: String, asr: [String: Any], polish: [String: Any]?, polishTried: Bool,
                         app: NSRunningApplication?, started: Date, duration: Double, wav: URL, timing: [String: Int]) {
        let text = (polish?["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? raw
        let fellBack = polish?["fell_back"] as? Bool ?? false
        phase = .idle
        DictationInsert.insert(text) { [weak self] result in
            guard let self = self else { return }
            let keep = Dictation.keepAudio
            if !keep { try? FileManager.default.removeItem(at: wav) }
            let e = DictationEntry(id: id, time: started, app: app?.localizedName, bundle: app?.bundleIdentifier, duration: duration,
                                   raw: raw, polished: polish?["polished"] as? String, text: text,
                                   model: polish?["model"] as? String, fellBack: fellBack, reason: polish?["reason"] as? String,
                                   insert: result.rawValue, audio: keep ? "audio/\(wav.lastPathComponent)" : nil,
                                   asrModel: asr["model"] as? String, language: asr["language"] as? String)
            DictationHistory.shared.append(e)
            DictationHistoryWindow.shared.reloadIfOpen()
            if result == .copied {
                island.toast(Loc.t("dictation.toast.copied", table: "Dictation"), actionTitle: nil, action: nil)
            }
            var out: [String: Any] = ["event": "dictation_text", "id": id, "ok": true, "raw": raw, "text": text,
                                      "fell_back": fellBack, "reason": polish?["reason"] as? String ?? NSNull(),
                                      "polished": polish?["polished"] as? String ?? NSNull(), "model": polish?["model"] as? String ?? NSNull(),
                                      "insert": result.rawValue, "polish_tried": polishTried]
            for (k, v) in timing { out[k] = v }
            self.lastResult = out
            emit(out)
        }
    }
}
