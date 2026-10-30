// The note bubble under a fresh shot: "Say it or type…", the words as they are heard, and where it will go.
//
//  • listens right away (the user usually starts talking as they let go of the mouse) and never ends the note by
//    itself (the founder, 2026-10-31 — it replaces BA-53's 3 s / 5 s pause end and its countdown ring on Done): the
//    user commits it. The mic stops after 20 s with nothing said (the bubble stays, typed only) and at 120 s. Audio →
//    shots/NNN.wav (16 kHz mono). The keys are BlurtCore NoteKeys (state × key → action):
//      ↩ / Done — commit: typed text, or the grey words as they are (their recording kept, the card gets its words from
//        the stream), or nothing — with a project it is filed all the same ("Goes to …"); in Auto it hangs as a card.
//      ⇧↩ — a new line (⌃↩ / ⌥↩ too); over the grey words it takes them first.
//      Tab — takes the grey words: they go into the field in label colour, listening stops, the caret at their end,
//        the keyboard has the note. Voice does not go on after Tab (Tab → keyboard mode): the live text is one
//        revised string (VoiceNoteStream's committed + pending pieces, re-heard in windows), not pieces that could be
//        appended after typed text cleanly. The stream's final words replace the taken ones while they are untouched,
//        so the card says what the bubble shows; committed before they land, or after an edit, the field is the note.
//        With no words to take, Tab opens the place list (the chip) as before.
//      typing — over the grey words it replaces them: the mic stops, the take is set aside (an emptied field shows the
//        words again, and ↩ then keeps them; ↩ with text drops the recording). Before anything was said it makes a
//        typed note. Only committed text counts as typing (NoteTyping: not an IME composition).
//      Esc (NoteEsc) — typed text first; then the shot is discarded: Trash, "Discarded · Undo" for 5 s.
//    "Silence" is relative to the room (BlurtCore NoteEndpointer: an adaptive noise floor); drawing on the picture
//    pushes the no-speech stop out (NoteEndpointer.activity).
//  • the words while they are said (v0.9): the voice note's live text (VoiceNoteStream, interim decodes about once a
//    second) in the field's place, secondary, the part still being said quieter. The footer's status slot says the
//    keys for them ("Tab accept · type to replace"); before anything is said it shows the running time. The stream
//    goes to Snapper, so the card has its words as it lands, not "Transcribing…". ↩ shows "Saved" for a moment (the
//    check in BrandColor.ok, the line secondary).
//  • it closes only on ↩, Done, Esc, ⌥A (the next snap), a click outside the frozen picture, or `resignSeconds` after
//    the user went to another app (the mic stops and what was said is kept: it never floats, or listens, over every
//    app). A stroke still being drawn when it closes is kept.
//  • a ⌥V voice note listening already: this bubble is typed only (no second listener), and the voice note's Esc
//    hotkey is the bubble's while it is open (VoiceInput.yieldEsc).
//  • the microphone gone mid-note (NoteVoice's watchdog, the engine's configuration change): it ends with what it has;
//    gone before anything was said, the bubble stays, typed only: "Mic disconnected · type a note". A mic that
//    doesn't start logs note_voice_start_failed with the reason (NoteVoice.failReason).
//  • in place (v0.9-next): a fresh snap's picture stays frozen where it was taken and the pen is on it (InkStage); the
//    bubble docks beside it (BlurtCore BubbleDock: never over it, flipped near the screen's edges, the selection's
//    display), its caret pointing at it. A plain drag draws, ⇧ a box, ⌥ an ellipse, holding still snaps a rough shape
//    clean, ⌘Z (or the undo arrow by the chip, shown while the pointer is over the bubble) takes the last stroke
//    back (InkView.swift). Done (⏎, the "Done ↩" button, a click outside): the
//    marked picture flies from the selection to the notch and becomes the card. The ink is burnt into
//    shots/NNN.marked.png (what a copy or a drag hands out); shots/NNN.png stays unmarked, the strokes stay editable.
//  • r2 of the overlays redesign: one composer for a fresh snap and Edit Note (`layout`): the words on top (15 pt), the
//    glyph column before them (the live level, the check, the keyboard, mic.slash; Edit Note's play / mic button); one
//    footer in fixed slots — the place chip, the hover tools (stroke undo, the bin / Record Again), the status slot
//    pinned against the primary (state: the running time, "Saved"; the keys only for the grey words: "Tab accept ·
//    type to replace"), "Done ↩" / "Save ↩". Other keys are on buttons and in tooltips; the first snaps learn Esc
//    from the stage's pill (InkStage).
//  • the place chip (ProjectChip.swift): a click, or Tab from the field (when there are no grey words to take), lists
//    the recent projects in the bubble; typing filters, ↩ picks — this capture goes there instead (Snapper.retarget),
//    the island's project stays.
//  • ⌥A while it is open saves the note and takes the next shot. Listening starts the warm speech server
//    (VoiceInput.warmSpeechModel), so the note's words come back in well under a second, not a cold model load.
//  • every open has a generation: a close still fading out never orders out (or takes the focus from) a bubble opened
//    after it — Edit Note on another card, a snap right after a saved note (v0.9: it vanished while still open).
// "Edit Note…" on a card (mode .edit) opens the same panel with the whole note as editable text — typed, then said —
// and the unmarked picture enlarged with its strokes, editable with the same pen (and ⌘Z) —
// so words heard wrong can be fixed (BlurtCore NoteEdit: an edited spoken note replaces its words). A voice card
// has no picture: the bubble is text only. The mic re-records: the new take goes to shots/NNN.retake.wav
// (VoiceRetake) and replaces the original only when it is kept (Save ↩, or Tab, which ends the re-record); Esc, or no
// speech, leaves the original untouched. It records until then: no pause ends it either.
// While it records, the field holds only what was typed (the take brings new words); a take not kept puts the words
// said back, and they stay. A kept take's words are fresh: words still coming for the old take are dropped
// (Snapper.voiceReplaced). Retakes left behind by a quit are swept when the cards come back (Snapper.restore).
// The same panel, text-only, is the note popover for snaps taken while recording (the island's snap button,
// the recording pauses while it is open).
//
// Tests: BLURT_NOTE_WAV=<file.wav> feeds that file through the same path instead of the microphone; test commands
// notetype / noteclear / notekey / noteheard / notewords / noteink / notestall / notestate drive and read it (SnapApp).

import AppKit
import BlurtCore
import BlurtObjC
import AudioToolbox
import AVFoundation
import Carbon.HIToolbox
import CoreAudio

// MARK: - Voice note: microphone (or an injected wav) → VAD → wav file

final class NoteVoice {
    /// micLost: the microphone stopped delivering mid-note (a headset gone, the input switched: macOS stops the engine)
    enum End { case silence, noSpeech, maxed, micLost }
    static let rate: Double = 16000
    let url: URL
    var onLevel: ((Float) -> Void)?
    var onSpeech: (() -> Void)?
    var onEnd: ((End) -> Void)?
    /// every buffer of 16 kHz mono samples, as it is written (dictation streams them to the speech model)
    var onSamples: (([Float]) -> Void)?
    /// the first audio arrived: the microphone really listens now (dictation shows "listening" only from here)
    var onFirstAudio: (() -> Void)?
    var speaking: Bool { vad.speaking }
    /// how long nobody has talked (dictation's "still listening" reminder)
    var quietSeconds: Double { vad.quietSeconds }
    private(set) var running = false
    /// seconds from start() to the first buffer (nil until then)
    private(set) var firstAudioAfter: Double?
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var injectTimer: Timer?
    private var started = Date()
    private var startedAt: CFTimeInterval = 0
    /// speech start / the pause that ends it (BlurtCore: an adaptive noise floor, so a room louder than the mic's
    /// first moments still counts as quiet)
    private var vad = NoteEndpointer(sampleRate: NoteVoice.rate)
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: NoteVoice.rate, channels: 1, interleaved: false)!
    var noSpeechTimeout: Double {
        get { vad.noSpeechTimeout }
        set { vad.noSpeechTimeout = newValue }
    }
    var silenceToEnd: Double {
        get { vad.silenceToEnd }
        set { vad.silenceToEnd = newValue }
    }
    var maxLength: Double {
        get { vad.maxLength }
        set { vad.maxLength = newValue }
    }
    /// how much of it was talking (seconds)
    var speechSeconds: Double { vad.speechSeconds }
    /// the loudest frame so far (dBFS): a take that is digital silence stays near −120 (BlurtCore VoiceKeep)
    var peakDB: Float { vad.peakDB }
    /// how long a sound was held above the room: a fan or a hum alone holds none (BlurtCore VoiceKeep)
    var soundSeconds: Double { vad.soundSeconds }
    /// the user is still at it without talking (drawing on the picture): the pause / no-speech end waits `grace` more
    func activity(grace: Double) { vad.activity(grace: grace) }
    /// when the last buffer arrived (CACurrentMediaTime), for the watchdog
    private var lastBufferAt: CFTimeInterval?
    private var firstAudioAt: CFTimeInterval?
    private var watchdog: Timer?
    private var configObserver: NSObjectProtocol?
    /// the engine stopped under us (config change): it is never given back as the spare
    private var engineLost = false
    /// A wav to play through instead of the microphone (tests); nil = $BLURT_NOTE_WAV, else the mic.
    var inject: String?
    /// Tests: the injected wav stands for the world's sound since this moment (the key-down): audio that played
    /// before the feed started is skipped, as a real mic would have missed it. nil = the wav from its start.
    var injectClock: CFTimeInterval?
    /// Tests: how long the simulated microphone takes to deliver its first buffer (BLURT_TEST_MIC_START_MS; a
    /// Bluetooth headset switching to its call profile takes ~1 s).
    static var testStartDelay: Double { Double(ProcessInfo.processInfo.environment["BLURT_TEST_MIC_START_MS"] ?? "").map { $0 / 1000 } ?? 0 }
    /// dictation: prefer the Mac's own microphone (DictationMicChoice decides; MicEngine sets the device)
    var builtInMic = false
    /// a specific input device (the Dictation Lab's microphone picker); nil = the default (or the built-in one)
    var device: AudioDeviceID?

    init(url: URL) { self.url = url }

    /// Tests (test commands only): BLURT_TEST_MIC_DENIED=1 acts as if microphone access had been turned off.
    static let testDenied: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["BLURT_TEST_COMMANDS"] == "1" && env["BLURT_TEST_MIC_DENIED"] == "1"
    }()

    /// Microphone access was turned off for Blurt (System Settings → Privacy & Security → Microphone).
    static var denied: Bool {
        testDenied || [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// "The microphone isn't available" in the island — with a way to System Settings when access was turned off.
    static func toastUnavailable() {
        guard denied else {
            return island.toast(Loc.t("capture.voice.no_mic", table: "Capture"), actionTitle: nil, action: nil)
        }
        island.toast(Loc.t("capture.voice.mic_denied", table: "Capture"), key: nil, icon: .warning,
                     actionTitle: Loc.t("capture.voice.mic_settings", table: "Capture")) {
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(u) }
        }
    }

    var elapsed: Double { vad.heard }
    /// why `start` answered false (logged as note_voice_start_failed / voice_start_failed)
    private(set) var failReason: String?

    func start(_ ready: @escaping (Bool) -> Void) {
        StoreFolders.make(url.deletingLastPathComponent())       // never below a project folder that is gone
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: NoteVoice.rate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        started = Date()
        startedAt = CACurrentMediaTime()
        if NoteVoice.testDenied { failReason = "test_denied"; ready(false); return }
        // tests: BLURT_TEST_MIC_WAV (the documented hook, as voice notes and dictation read it) or BLURT_NOTE_WAV; a test
        // run with neither never opens the real microphone (a dogfood run recorded the room into a card) — it says the
        // no-mic state instead
        let env = ProcessInfo.processInfo.environment
        if let wav = inject ?? env["BLURT_TEST_MIC_WAV"] ?? env["BLURT_NOTE_WAV"] {
            running = true                  // the feed checks it as it begins
            running = startInjected(URL(fileURLWithPath: wav))
            if !running { failReason = "inject_unreadable" }
            ready(running)
            return
        }
        if env["BLURT_TEST_COMMANDS"] == "1" {
            emit(["event": "note_mic_blocked_in_test"])
            failReason = "test_no_wav"
            ready(false)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: startMic(ready)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { if ok { self.startMic(ready) } else { self.failReason = "denied"; ready(false) } }
            }
        default: failReason = "not_allowed"; ready(false)
        }
    }

    /// The prepared engine (MicEngine: made at launch, input node ready, not started — no mic in use until here),
    /// started off the main thread: a Bluetooth headset can take a second to switch profiles, and the key presses
    /// and the island must not wait for it.
    private func startMic(_ ready: @escaping (Bool) -> Void) {
        running = true          // buffers may arrive before ready() runs
        let builtIn = builtInMic
        let device = self.device
        MicEngine.shared.queue.async { [weak self] in
            guard let self = self else { return }
            var e = device.map { MicEngine.shared.make(device: $0) } ?? MicEngine.shared.take(builtIn: builtIn)
            var why = self.tap(e)
            if why != nil {
                // a stale engine (the input changed since it was prepared): once more with a new one
                MicEngine.shared.discard(e)
                e = device.map { MicEngine.shared.make(device: $0) } ?? MicEngine.shared.fresh(builtIn: builtIn)
                why = self.tap(e)
            }
            if let why = why {
                MicEngine.shared.discard(e)
                return DispatchQueue.main.async { self.running = false; self.failReason = why; ready(false) }
            }
            let input = e.inputNode
            do { try e.start() } catch {
                input.removeTap(onBus: 0)
                MicEngine.shared.giveBack(e, builtIn: builtIn)
                let why = "engine_start: \((error as NSError).domain) \((error as NSError).code)"
                return DispatchQueue.main.async { self.running = false; self.failReason = why; ready(false) }
            }
            DispatchQueue.main.async {
                guard self.running else {          // stopped while it was starting
                    MicEngine.shared.queue.async { input.removeTap(onBus: 0); e.stop(); MicEngine.shared.giveBack(e, builtIn: builtIn) }
                    return
                }
                self.engine = e
                self.observeConfig(e)
                ready(true)
            }
        }
    }

    /// How many times this take restarted its engine after a configuration change.
    private var restarts = 0

    /// The engine's configuration changed under a running take, and macOS stopped it. Most often this is the engine
    /// settling on the device it was switched to (the built-in mic picked while AirPods are the default: the node
    /// cached the old device's rate, and the first start reconciles it). In that case the same engine is tapped again
    /// in the format it reports now and restarted, and the take goes on. After two restarts, or when the tap or the
    /// start fails (the device really went away: AirPods out of the ear, a headset unplugged), the take ends with
    /// what it has rather than listening to nothing.
    private func observeConfig(_ e: AVAudioEngine) {
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e,
                                                                queue: .main) { [weak self] _ in
            guard let self = self, self.running, self.engine === e else { return }
            guard self.restarts < 2 else { self.engineLost = true; return self.lost("config_change") }
            self.restarts += 1
            let n = self.restarts
            MicEngine.shared.queue.async { [weak self] in
                guard let self = self else { return }
                e.inputNode.removeTap(onBus: 0)
                e.stop()
                var why = self.tap(e)
                if why == nil {
                    do { try e.start() } catch { e.inputNode.removeTap(onBus: 0); why = "engine_start: \((error as NSError).code)" }
                }
                let hw = e.inputNode.inputFormat(forBus: 0).sampleRate
                DispatchQueue.main.async {
                    emit(["event": "mic_restart", "n": n, "ok": why == nil, "why": why ?? NSNull(), "hw_rate": hw])
                    guard self.running, self.engine === e else { return }
                    if why != nil { self.engineLost = true; self.lost("config_change") }
                }
            }
        }
    }

    /// On MicEngine's queue: the tap on the engine's input, converting to `fmt`. nil when it is in; otherwise why not.
    /// The tap takes the input hardware's own rate: after the device under a prepared engine changed (the built-in
    /// mic picked while AirPods are the default, a headset switching profiles) the node can still report the old
    /// device's rate, and a tap in that rate makes AVFoundation raise — caught here (BlurtTry), never a crash.
    private func tap(_ e: AVAudioEngine) -> String? {
        let input = e.inputNode
        let out = input.outputFormat(forBus: 0)
        let hw = input.inputFormat(forBus: 0)
        var inFmt = out
        if hw.sampleRate > 0, hw.sampleRate != out.sampleRate {
            emit(["event": "mic_format_mismatch", "node_rate": out.sampleRate, "hw_rate": hw.sampleRate,
                  "channels": Int(out.channelCount)])
            guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hw.sampleRate,
                                        channels: max(1, out.channelCount), interleaved: false) else { return "no_input_format" }
            inFmt = f
        }
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0, let conv = AVAudioConverter(from: inFmt, to: fmt) else {
            return "no_input_format"
        }
        let rate = inFmt.sampleRate
        var err: NSError?
        let ok = BlurtTry({
            input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(rate / 20), format: inFmt) { [weak self] buf, _ in
                guard let self = self else { return }
                let cap = AVAudioFrameCount(Double(buf.frameLength) * NoteVoice.rate / rate) + 32
                guard let out = AVAudioPCMBuffer(pcmFormat: self.fmt, frameCapacity: cap) else { return }
                var fed = false
                conv.convert(to: out, error: nil) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return buf
                }
                DispatchQueue.main.async { self.feed(out) }
            }
        }, &err)
        guard ok else {
            let reason = err?.userInfo["reason"] as? String ?? "exception"
            emit(["event": "mic_tap_refused", "reason": reason, "node_rate": out.sampleRate, "hw_rate": hw.sampleRate])
            return "tap_refused"
        }
        return nil
    }

    private func startInjected(_ src: URL) -> Bool {
        guard let f = try? AVAudioFile(forReading: src), let conv = AVAudioConverter(from: f.processingFormat, to: fmt),
              let all = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return false }
        try? f.read(into: all)
        let cap = AVAudioFrameCount(Double(all.frameLength) * NoteVoice.rate / f.processingFormat.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return false }
        var fed = false
        conv.convert(to: out, error: nil) { _, st in
            if fed { st.pointee = .endOfStream; return nil }
            fed = true; st.pointee = .haveData; return all
        }
        var pos: AVAudioFrameCount = 0
        let chunk = AVAudioFrameCount(NoteVoice.rate / 10)
        let begin = { [weak self] in
            guard let self = self, self.running else { return }
            // the world kept talking since the key went down: what played before the "mic" came up is not heard
            if let clock = self.injectClock {
                pos = AVAudioFrameCount(max(0, (CACurrentMediaTime() - clock) * NoteVoice.rate))
            }
            self.injectTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self, let b = AVAudioPCMBuffer(pcmFormat: self.fmt, frameCapacity: chunk) else { return }
                b.frameLength = chunk
                let dst = b.floatChannelData![0]
                let src = out.floatChannelData![0]
                for i in 0..<Int(chunk) { dst[i] = pos + AVAudioFrameCount(i) < out.frameLength ? src[Int(pos) + i] : 0 }
                pos += chunk
                self.feed(b)
            }
            self.injectTimer?.fire()
        }
        let delay = NoteVoice.testStartDelay
        if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: begin) } else { begin() }
        return true
    }

    private func feed(_ b: AVAudioPCMBuffer) {
        guard running || injectTimer != nil, b.frameLength > 0 else { return }
        let now = CACurrentMediaTime()
        lastBufferAt = now
        if firstAudioAfter == nil {
            firstAudioAfter = now - startedAt
            firstAudioAt = now
            onFirstAudio?()
            startWatchdog()
        }
        try? file?.write(from: b)
        let samples = Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
        onSamples?(samples)
        let db = NoteEndpointer.level(samples)
        onLevel?(max(0, min(1, (db + 55) / 45)))
        for e in vad.feed(samples) {
            switch e {
            case .speechStarted: onSpeech?()
            case .ended(let end):
                emit(["event": "note_voice_end", "end": "\(end)", "heard": (vad.heard * 100).rounded() / 100,
                      "speech": (vad.speechSeconds * 100).rounded() / 100, "floor_db": Double((vad.floorDB * 10).rounded() / 10)])
                finish(end == .silence ? .silence : end == .noSpeech ? .noSpeech : .maxed)
            }
        }
    }

    private func finish(_ e: End) {
        guard running else { return }
        stop(keep: e != .noSpeech)
        onEnd?(e)
    }

    /// No buffer for `MicWatchdog.timeout` once audio had started (BlurtCore MicWatchdog): the microphone is gone.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.running else { return }
            if MicWatchdog.stalled(now: CACurrentMediaTime(), firstAudio: self.firstAudioAt, lastBuffer: self.lastBufferAt) {
                self.lost("stalled")
            }
        }
    }

    private func lost(_ why: String) {
        guard running else { return }
        emit(["event": "note_voice_end", "end": "micLost", "why": why, "heard": (vad.heard * 100).rounded() / 100,
              "speech": (vad.speechSeconds * 100).rounded() / 100])
        finish(.micLost)
    }

    /// Tests (test commands only): the simulated microphone stops delivering, as a headset that went away does.
    func testStall() { injectTimer?.invalidate(); injectTimer = nil; running = true }

    /// keep: false deletes the wav (no speech / skipped).
    func stop(keep: Bool) {
        running = false
        injectTimer?.invalidate()
        injectTimer = nil
        watchdog?.invalidate()
        watchdog = nil
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        if let e = engine {
            engine = nil
            let builtIn = builtInMic
            let reuse = !engineLost
            MicEngine.shared.queue.async {
                e.inputNode.removeTap(onBus: 0)
                e.stop()
                if reuse { MicEngine.shared.giveBack(e, builtIn: builtIn) } else { MicEngine.shared.discard(e) }   // never the spare
            }
        }
        file = nil
        if !keep { try? FileManager.default.removeItem(at: url) }
    }
}

/// The microphone's AVAudioEngine, made once (at launch, when microphone access is already granted) and reused: the
/// engine and its input node (the HAL unit, the device's format) are set up and `prepare()`d, but never started until
/// someone listens — macOS shows the mic as in use only while it runs. That takes the engine set-up (tens of ms, more
/// on the first use) off the moment the dictation key goes down. Dictation can ask for the Mac's built-in mic
/// (DictationMicChoice): the input unit's device is switched before it starts. Test builds never touch it.
final class MicEngine {
    static let shared = MicEngine()
    /// starts and stops happen here, never on the main thread
    let queue = DispatchQueue(label: "blurt.mic", qos: .userInteractive)
    private var spare: AVAudioEngine?
    private var spareBuiltIn = false
    private var observer: NSObjectProtocol?

    /// At launch and after each use: a spare engine, ready but not running.
    func prepare(builtIn: Bool) {
        guard !DictationInsert.testMode, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        queue.async {
            guard self.spare == nil || self.spareBuiltIn != builtIn else { return }
            self.spare = self.make(builtIn: builtIn)
            self.spareBuiltIn = builtIn
        }
    }

    /// On `queue`: the spare engine when it fits, else a new one.
    func take(builtIn: Bool) -> AVAudioEngine {
        if let e = spare, spareBuiltIn == builtIn { spare = nil; return e }
        spare = nil
        return make(builtIn: builtIn)
    }

    /// On `queue`: a new engine, never the spare (the spare turned out stale).
    func fresh(builtIn: Bool) -> AVAudioEngine {
        if spareBuiltIn == builtIn { spare = nil }
        return make(builtIn: builtIn)
    }

    /// On `queue`: a stopped engine goes back to being the spare (the next dictation reuses it).
    func giveBack(_ e: AVAudioEngine, builtIn: Bool) {
        // an engine made for a picked device (the Dictation Lab) is never the spare
        if custom.remove(ObjectIdentifier(e)) != nil { return }
        guard spare == nil, !DictationInsert.testMode else { return }
        e.prepare()
        spare = e
        spareBuiltIn = builtIn
    }

    private var custom = Set<ObjectIdentifier>()

    /// On `queue`: an engine macOS stopped under a note (the input device changed): dropped, never reused.
    func discard(_ e: AVAudioEngine) {
        custom.remove(ObjectIdentifier(e))
        if spare === e { spare = nil }
    }

    /// On `queue`: an engine on this input device (the Dictation Lab's microphone picker), made for one take.
    func make(device: AudioDeviceID) -> AVAudioEngine {
        let e = AVAudioEngine()
        if let unit = e.inputNode.audioUnit {
            var id = device
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        _ = e.inputNode.outputFormat(forBus: 0)
        e.prepare()
        custom.insert(ObjectIdentifier(e))
        return e
    }

    private func make(builtIn: Bool) -> AVAudioEngine {
        let e = AVAudioEngine()
        if builtIn, let dev = AudioDevices.builtInInput(), let unit = e.inputNode.audioUnit {
            var id = dev
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        _ = e.inputNode.outputFormat(forBus: 0)
        e.prepare()
        if observer == nil {
            // the default input changed (headphones plugged in, AirPods connected): the spare is stale
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] n in
                guard let self = self else { return }
                self.queue.async { if let s = self.spare, (n.object as? AVAudioEngine) === s { self.spare = nil } }
            }
        }
        return e
    }
}

/// The audio devices dictation cares about (CoreAudio, read-only: nothing here opens a device).
enum AudioDevices {
    private static func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ empty: T) -> T? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var v = empty
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    static var defaultInput: AudioDeviceID? {
        prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, AudioDeviceID(0)).flatMap { $0 == 0 ? nil : $0 }
    }

    static func transport(_ d: AudioDeviceID) -> UInt32? { prop(d, kAudioDevicePropertyTransportType, UInt32(0)) }

    static func isBluetooth(_ d: AudioDeviceID) -> Bool {
        guard let t = transport(d) else { return false }
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The default input is a Bluetooth headset (AirPods & co.).
    static var defaultInputIsBluetooth: Bool { defaultInput.map(isBluetooth) ?? false }

    /// Every input device and its name (the Dictation Lab's microphone picker). Read-only: nothing is opened.
    static func inputs() -> [(id: AudioDeviceID, name: String)] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                               mElement: kAudioObjectPropertyElementMain)
            var s: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &s) == noErr, s > 0 else { return nil }
            var na = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var ns = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &na, 0, nil, &ns, &name) == noErr, let n = name?.takeRetainedValue() else { return nil }
            return (id, n as String)
        }
    }

    /// The Mac's own microphone, if it has one (a Mac mini or Studio doesn't).
    static func builtInInput() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { id in
            guard transport(id) == kAudioDeviceTransportTypeBuiltIn else { return false }
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                               mElement: kAudioObjectPropertyElementMain)
            var s: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &s) == noErr && s > 0
        }
    }
}

// MARK: - Small views

/// The bubble's listening mark (r2): three short bars in brand ink in the glyph column — a live level, as the Dynamic
/// Island keeps a waveform while its mic is open. Quiet, they breathe low (so "listening" never looks like "ready", a
/// still mic glyph); with the voice they rise, the middle one most, falling slower than they rise. Reduce Motion: they
/// stand still at rest and step with the voice. (v0.9 drew five ink dots — read as a password mask; r1 filled a mic glyph
/// from its foot — at silence it looked like the mic that is merely ready.)
final class MicLevel: NSView {
    /// 0…1, as the microphone hears it; shown a little smoothed (it falls slower than it rises)
    var level: Float = 0 { didSet { shown = max(CGFloat(level), shown * 0.82); needsDisplay = true } }
    private var shown: CGFloat = 0
    /// each tick (20 Hz): the level falls back, and the bars breathe while it is quiet
    func decay() {
        if shown > 0.01 { shown *= 0.86 }
        if !isHidden { needsDisplay = true }
    }
    override func draw(_ dirty: NSRect) {
        // (tall enough at rest to read as bars, never as "…")
        let w: CGFloat = 2.5, gap: CGFloat = 2.5, maxH: CGFloat = 15
        let x0 = (bounds.width - (3 * w + 2 * gap)) / 2
        let t = CACurrentMediaTime()
        BrandColor.ink.setFill()
        for i in 0..<3 {
            let weight: CGFloat = i == 1 ? 1 : 0.7
            // at rest: a slow breath, each bar a little after the one before (none with Reduce Motion)
            let breath = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(t * 3.2 - Double(i) * 0.9)
            let rest = (i == 1 ? 8 : 5) + CGFloat(breath) * (i == 1 ? 2.5 : 1.5)
            let voice = (reduceMotion ? (shown > 0.15 ? 1 : 0) : min(1, shown * 1.25)) * weight
            let h = max(rest, 5 + (maxH - 5) * voice)
            let r = NSRect(x: x0 + CGFloat(i) * (w + gap), y: (bounds.height - h) / 2, width: w, height: h)
            NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
        }
    }
}

final class SymbolButton: NSButton {
    var onClick: (() -> Void)?
    convenience init(_ symbol: String, tip: String, size: CGFloat = 26, _ click: @escaping () -> Void) {
        self.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        contentTintColor = .secondaryLabelColor
        toolTip = tip
        onClick = click
        target = self
        action = #selector(fire)
    }
    @objc func fire() { onClick?() }
    /// the glyph's colour while the pointer is on it (the bin: red), a faint wash behind it either way
    var hoverTint: NSColor?
    private var restTint: NSColor?
    private var over = false { didSet { needsDisplay = true } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        over = true
        if let h = hoverTint { restTint = contentTintColor; contentTintColor = h }
    }
    override func mouseExited(with event: NSEvent) {
        over = false
        if hoverTint != nil, let r = restTint { contentTintColor = r }
    }
    override func draw(_ dirty: NSRect) {
        if over || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.12 : 0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirty)
    }
}

/// Key-able, but doesn't activate the app: typing works, the app the user was in stays in front.
final class NotePanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown, onKey?(e) == true { return }
        super.sendEvent(e)
    }
}

/// The bubble's background: a rounded card with a caret pointing at the shot it belongs to — up or down at a card,
/// left or right at a frozen selection it docks beside (none when it sits inside one that fills the screen).
final class BubbleBackground: NSView {
    enum Caret { case up, down, left, right, none }
    var caret: Caret = .up { didSet { needsDisplay = true } }
    /// where along its side the caret points (x for up / down, y from the top for left / right)
    var caretAt: CGFloat = 40 { didSet { needsDisplay = true } }
    var caretUp: Bool { caret == .up }
    static let caret: CGFloat = 9
    override var isFlipped: Bool { true }

    /// The card's insets for its caret (top, left, bottom, right).
    var insets: NSEdgeInsets {
        let c = BubbleBackground.caret
        switch caret {
        case .up: return NSEdgeInsets(top: c, left: 0, bottom: 0, right: 0)
        case .down: return NSEdgeInsets(top: 0, left: 0, bottom: c, right: 0)
        case .left: return NSEdgeInsets(top: 0, left: c, bottom: 0, right: 0)
        case .right: return NSEdgeInsets(top: 0, left: 0, bottom: 0, right: c)
        case .none: return NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }
    }

    /// One outline: the card and its caret traced as one path (r1: the caret was a triangle appended to the card, so
    /// the card's own edge ran across the caret's base — a drawn-on notch in light mode).
    func shape() -> NSBezierPath {
        let c = BubbleBackground.caret, i = insets, r: CGFloat = 14, half = c + 2
        let b = NSRect(x: 0.5 + i.left, y: 0.5 + i.top, width: bounds.width - 1 - i.left - i.right,
                       height: bounds.height - 1 - i.top - i.bottom)
        let x = min(max(caretAt, b.minX + r + half), b.maxX - r - half)
        let y = min(max(caretAt, b.minY + r + half), b.maxY - r - half)
        let p = NSBezierPath()
        // (flipped: y grows down) the top edge left to right, the right edge down, the bottom right to left, the left up
        p.move(to: NSPoint(x: b.minX + r, y: b.minY))
        if caret == .up {
            p.line(to: NSPoint(x: x - half, y: b.minY)); p.line(to: NSPoint(x: x, y: b.minY - c)); p.line(to: NSPoint(x: x + half, y: b.minY))
        }
        p.appendArc(from: NSPoint(x: b.maxX, y: b.minY), to: NSPoint(x: b.maxX, y: b.maxY), radius: r)
        if caret == .right {
            p.line(to: NSPoint(x: b.maxX, y: y - half)); p.line(to: NSPoint(x: b.maxX + c, y: y)); p.line(to: NSPoint(x: b.maxX, y: y + half))
        }
        p.appendArc(from: NSPoint(x: b.maxX, y: b.maxY), to: NSPoint(x: b.minX, y: b.maxY), radius: r)
        if caret == .down {
            p.line(to: NSPoint(x: x + half, y: b.maxY)); p.line(to: NSPoint(x: x, y: b.maxY + c)); p.line(to: NSPoint(x: x - half, y: b.maxY))
        }
        p.appendArc(from: NSPoint(x: b.minX, y: b.maxY), to: NSPoint(x: b.minX, y: b.minY), radius: r)
        if caret == .left {
            p.line(to: NSPoint(x: b.minX, y: y + half)); p.line(to: NSPoint(x: b.minX - c, y: y)); p.line(to: NSPoint(x: b.minX, y: y - half))
        }
        p.appendArc(from: NSPoint(x: b.minX, y: b.minY), to: NSPoint(x: b.maxX, y: b.minY), radius: r)
        p.close()
        p.lineJoinStyle = .round
        return p
    }

    /// The pointer is over the card: its quiet actions show (the bin, the stroke undo).
    var onHover: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    /// The card and its caret only: the window's own shadow (NotePanel.hasShadow) follows that shape. (v0.9: a shadow
    /// drawn here was cut off at the window's edge — a grey rectangle behind the rounded card.) Dark: the raised
    /// surface, #2C2C2C as rendered (sRGB, opaque — r1's calibrated 0.19 came out #3F3F3F, a grey HUD on a dimmed
    /// screen), with a white 14 % hairline; light: near-white, a black 12 % hairline and the window's shadow.
    static let darkSurface = NSColor(srgbRed: 44 / 255, green: 44 / 255, blue: 44 / 255, alpha: 1)
    static let lightSurface = NSColor(srgbRed: 0.995, green: 0.995, blue: 0.995, alpha: 1)
    /// The capture panels' one surface (the note bubble, the Cards panel and its preview): opaque, so a titled
    /// panel's background never picks up the wallpaper's tint beside the bubble's neutral grey in dark mode.
    static let surface = NSColor(name: "captureSurface") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkSurface : lightSurface
    }
    override func draw(_ dirty: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let p = shape()
        (dark ? BubbleBackground.darkSurface : BubbleBackground.lightSurface).setFill()
        p.fill()
        (dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.12)).setStroke()
        p.lineWidth = 1
        p.stroke()
        // the shape changed (size, caret): the window's shadow is worked out again from what was drawn
        DispatchQueue.main.async { [weak self] in self?.window?.invalidateShadow() }
    }
}

// MARK: - The bubble

final class NoteBubble: NSObject, NSTextFieldDelegate {
    static let shared = NoteBubble()
    enum Mode { case listen, edit, recording }

    private(set) var shot: Shot?
    private(set) var mode: Mode = .listen
    private var panel: NotePanel?
    private var bg = BubbleBackground()
    private var canvas = InkCanvas(frame: .zero)
    private var field = NSTextField()
    private var status = NSTextField(labelWithString: "")
    private var bars = MicLevel(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    /// the pointer is over the bubble: the quiet actions (the bin, the stroke undo) show
    private var hovering = false
    /// the first few bubbles also name their keys in the footer (Esc), as the pen hint does (InkHint)
    private var firstTimes = false
    private var icon = NSImageView()
    private var undoBtn: SymbolButton!
    private var micBtn: SymbolButton!
    private var playBtn: SymbolButton!
    private var prevBtn: SymbolButton!
    private var nextBtn: SymbolButton!
    private var keepBtn: SymbolButton!
    private var discardBtn: SymbolButton!
    private var penHint = NSTextField(labelWithString: "")
    /// in place: the frozen selection it docks beside (global AppKit points); the pen is on InkStage's canvas then
    private var dock: NSRect?
    private var dockSide: BubbleDock.Side?
    private var staged: Bool { dock != nil }
    /// the pen this note draws with: the frozen picture's (in place), else the enlarged one in the bubble (Edit Note)
    private var ink: InkCanvas { staged ? InkStage.shared.canvas : canvas }
    /// ⌘Z takes back a stroke (the last thing done was drawing), not typing
    private var inkUndoFirst = false
    /// the bubble holds the cards down (not in place: the card isn't there yet)
    private var heldCards = false
    /// "Goes to X" (a fresh shot): where it goes, switched in place
    private var chip: ProjectChip!
    private let pick = ProjectPickView(frame: .zero)
    private var picking = false
    /// in place: the one primary, "Done"
    private var doneBtn: BrandButton!
    private var voice: NoteVoice?
    /// the words while they are said (VoiceNoteStream, the ⌥V voice note's live text): shown in the field's place
    private var stream: VoiceNoteStream?
    private var heard = (committed: "", pending: "")
    /// committed text in the field (BlurtCore NoteTyping: not an IME composition, not just spaces)
    private var typed = false
    private var speechStarted = false
    /// the recording stopped and is kept (the mic ended by itself after speech, typing set it aside, Tab took it)
    private var voiceKept = false
    /// the voice part is over: the mic stopped (or never started, or typing before speech made it a typed note)
    private var voiceDone = false
    /// the final words of the kept recording are still coming (Snapper.fetchWords)
    private var waitingWords = false
    /// Tab took the words heard: the field holds them (black) and the keyboard has the note — no grey words any more
    private var accepted = false
    /// the words taken with Tab, as they are in the field: an edit of them replaces them (NoteEdit); nil = none (yet)
    private var wordsInField: String?
    /// …exactly as they were put in the field (the final words take their place while the field still starts with them)
    private var takenRaw: String?
    /// the mic stops after this long with nothing said (the bubble stays, typed only)…
    static let noSpeechStop = 20.0
    /// …and after this long in all (nothing ends the note on a pause: the user commits it — NoteKeys)
    static let maxListen = 120.0
    /// drawing on the picture keeps the mic open this long past the stroke (the no-speech stop waits for the pen)
    static let inkGrace = 1.5
    /// a ⌥V voice note has the microphone: this bubble takes typing only (no second listener)
    private var voiceBusy = false
    /// the microphone went before anything was said: typed only now ("Mic disconnected · type a note")
    private var micGone = false
    /// every open has its own number: a close still fading out never hides the bubble opened after it
    private var generation = 0
    private var closeWork: DispatchWorkItem?
    private var resignWork: DispatchWorkItem?
    private var keyObservers: [NSObjectProtocol] = []
    /// the user went to another app with the bubble open and not listening: it saves this long after
    static let resignSeconds: Double = 3
    private var ticker: Timer?
    private var showWork: DispatchWorkItem?
    private var original: (text: String?, voice: String?, said: String?, strokes: [[[Double]]])?
    /// where this bubble's recording goes: shots/NNN.wav (a fresh shot), shots/NNN.retake.wav (a re-record in an edit)
    private var takeRel: String?
    /// edit: a re-record was kept (it replaces the original on save, and is deleted on Esc)
    private var retakeKept = false
    private var retakeSeconds: Double = 0
    /// edit: the field still shows the words said (false once a re-record left only the typed part in it)
    private var fieldHoldsSaid = true
    /// the "Drag to circle" hint has faded for this bubble
    private var penHintGone = false
    private var player: AVAudioPlayer?
    /// recording mode: which shots can be switched between, and what to do on close (resume).
    var recordingShots: [Shot] = []
    var onClose: (() -> Void)?
    /// a recording's note session is open: whether closing it resumes the take (IslandRecording, RecordingNotes)
    var recordingResume: Bool?
    var anchor: (() -> NSRect?)?

    var isOpen: Bool { shot != nil }
    /// Its microphone is on (dictation waits for it).
    var isListening: Bool { voice?.running == true }

    var canvasScreenRect: NSRect? {
        if staged, InkStage.shared.isOpen { return InkStage.shared.selection }
        guard let p = panel, p.isVisible else { return nil }
        return p.convertToScreen(canvas.convert(canvas.bounds, to: nil))
    }

    // MARK: open

    /// `inPlace`: the frozen selection of a fresh snap (InkStage is open on it): the bubble docks beside it.
    func begin(_ s: Shot, mode m: Mode, anchor a: (() -> NSRect?)? = nil, inPlace: NSRect? = nil) {
        if isOpen { commit() }
        generation += 1
        // a close of the bubble before this one may still be fading out: it never hides this one
        closeWork?.cancel()
        closeWork = nil
        resignWork?.cancel()
        shot = s
        mode = m
        anchor = a ?? { hanging.screenRect(of: s) ?? island.frameOnScreen }
        typed = false
        speechStarted = false
        voiceKept = false
        takeRel = nil
        retakeKept = false
        retakeSeconds = 0
        fieldHoldsSaid = true
        wordsInField = nil
        takenRaw = nil
        accepted = false
        voiceDone = false
        waitingWords = false
        heard = ("", "")
        voiceBusy = false
        micGone = false
        // the pen hint, the first few times only (InkHint; the stage counts them)
        let hintsShown = recordConfig()["ink_hint_shown"] as? Int ?? 0
        penHintGone = !InkHint.shows(alreadyShown: hintsShown)
        // (in place the stage has counted this snap already: its hint showing is the answer)
        firstTimes = inPlace != nil && InkStage.shared.shot === s ? InkStage.shared.hintShown : InkHint.shows(alreadyShown: hintsShown)
        hovering = false
        penHint.alphaValue = 1
        inkUndoFirst = false
        picking = false
        editPicked = false
        editProject = nil
        lastSecond = -1
        dock = m == .listen && InkStage.shared.shot === s ? inPlace : nil
        dockSide = nil
        original = (s.text, s.voice, s.said, s.strokes)
        build()
        if staged {
            let st = InkStage.shared
            st.canvas.onChange = { [weak self] in self?.inkChanged() }
            st.canvas.onStrokeBegan = { [weak self] in self?.strokeBegan() }
            st.canvas.onStrokeMoved = { [weak self] in self?.voice?.activity(grace: NoteBubble.inkGrace) }
            st.canvas.onStrokeEnded = { [weak self] in self?.strokeEnded() }
            st.onClickOutside = { [weak self] in self?.commit() }        // a click outside the picture: done
        }
        load(s)
        VoiceInput.shared.yieldEsc(true)        // Esc is this bubble's while it is open
        if m == .listen { startListening() }
        heldCards = m != .recording && !staged
        if heldCards { hanging.hold(true) }
        // let the card land on its thread first, then unfold the bubble under it (in place: beside the picture now)
        let delay = m == .listen && !staged && !reduceMotion ? 0.55 : 0.0
        let work = DispatchWorkItem { [weak self] in self?.present() }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func build() {
        guard panel == nil else { return }
        let p = NotePanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.nonactivatingPanel, .borderless],
                          backing: .buffered, defer: false)
        p.isFloatingPanel = true          // (before the level: it resets the level to .floating)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true                // the system's shadow, following the card and its caret (BubbleBackground)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.sharingType = chromeSharing
        p.isMovableByWindowBackground = false
        p.onKey = { [weak self] e in self?.key(e) ?? false }
        let root = bg
        p.contentView = root
        canvas.onChange = { [weak self] in self?.inkChanged() }
        canvas.onStrokeBegan = { [weak self] in self?.strokeBegan() }
        canvas.onStrokeMoved = { [weak self] in self?.voice?.activity(grace: NoteBubble.inkGrace) }
        canvas.onStrokeEnded = { [weak self] in self?.strokeEnded() }
        root.addSubview(canvas)
        // the pen hint on the enlarged picture (Edit Note): the stage's one hint component (§3.1: 12 pt regular,
        // white 65 % on black 42 %, r 11), never a second style
        penHint.font = .systemFont(ofSize: 12, weight: .regular)
        penHint.textColor = NSColor(white: 1, alpha: 0.65)
        penHint.wantsLayer = true
        penHint.drawsBackground = true
        penHint.backgroundColor = NSColor(white: 0.06, alpha: 0.42)
        penHint.layer?.cornerRadius = 11
        penHint.alignment = .center
        root.addSubview(penHint)
        undoBtn = SymbolButton("arrow.uturn.backward", tip: Loc.t("capture.note.undo", table: "Capture"), size: 24) { [weak self] in self?.undoInk() }
        root.addSubview(undoBtn)
        chip = ProjectChip { [weak self] in self?.togglePick() }
        root.addSubview(chip)
        pick.isHidden = true
        pick.onPick = { [weak self] p in self?.picked(p) }
        pick.onCancel = { [weak self] in self?.closePick() }
        pick.onFilterChange = { [weak self] in self?.layout() }
        root.addSubview(pick)
        // the one primary, with its key on it ("Done ↩", Edit Note's "Save ↩"): no line saying the same
        doneBtn = BrandButton(title: Loc.t("capture.note.done", table: "Capture"), target: self, action: #selector(doneClicked))
        doneBtn.fontSize = 12
        doneBtn.hPad = 10
        doneBtn.keyHint = "↩"
        root.addSubview(doneBtn)
        root.onHover = { [weak self] on in self?.hover(on) }
        icon.imageScaling = .scaleProportionallyDown
        root.addSubview(icon)
        root.addSubview(bars)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NoteBubble.fontSize)      // the words are the strongest thing in it
        field.delegate = self
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        root.addSubview(field)
        // the footer's quiet line: what the bubble is doing now, never a sentence about the buttons
        status.font = .systemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        root.addSubview(status)
        micBtn = SymbolButton("mic", tip: Loc.t("capture.note.rerecord", table: "Capture"), size: 24) { [weak self] in self?.rerecord() }
        playBtn = SymbolButton("play", tip: Loc.t("capture.note.play", table: "Capture"), size: 24) { [weak self] in self?.play() }
        prevBtn = SymbolButton("chevron.left", tip: Loc.t("capture.note.prev", table: "Capture"), size: 24) { [weak self] in self?.step(-1) }
        nextBtn = SymbolButton("chevron.right", tip: Loc.t("capture.note.next", table: "Capture"), size: 24) { [weak self] in self?.step(1) }
        keepBtn = SymbolButton("checkmark.circle.fill", tip: Loc.t("capture.note.keep_tip", table: "Capture")) { [weak self] in self?.commit() }
        keepBtn.contentTintColor = BrandColor.ink           // the bubble's primary: brand ink (light / dark / contrast)
        // the bin: a hover tool by the chip (its tooltip names Esc, which does it too, with Undo)
        discardBtn = SymbolButton("trash", tip: Loc.t("capture.note.discard_tip", table: "Capture"), size: 24) { [weak self] in self?.cancel() }
        discardBtn.hoverTint = .systemRed
        [micBtn, playBtn, prevBtn, nextBtn, keepBtn, discardBtn].forEach { root.addSubview($0!) }
        // the user went to another app: a bubble that isn't listening any more saves a moment later (a popover's
        // click-outside), so it never floats over every app waiting for ⏎
        keyObservers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
                self?.resignedKey()
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: p, queue: .main) { [weak self] _ in
                self?.resignWork?.cancel()
            },
        ]
        panel = p
    }

    private func load(_ s: Shot) {
        // in place the picture and its pen are on the stage; the bubble is the words
        canvas.image = s.kind == .voice || staged ? nil : s.image()
        canvas.strokes = staged ? [] : s.strokes
        canvas.editable = mode != .recording && s.kind != .voice && !staged
        // the enlarged picture draws the line as wide as the snap's own (scaled to the preview)
        if !staged, s.kind == .shot {
            let regionW = s.region.count == 4 && s.region[2] > 0 ? CGFloat(s.region[2]) : CGFloat(s.pixelSize.width) / max(1, s.scale)
            let pv = previewSize()
            canvas.lineWidth = max(2, inkWidth(for: s.regionRect.flatMap { InkStage.screen(for: toNS($0)) }) * pv.width / max(1, regionW))
        }
        // an edit shows the whole note — what was said too — so the words can be fixed (NoteEdit)
        field.stringValue = mode == .listen ? "" : mode == .edit ? NoteEdit.field(typed: s.text, said: s.said) : (s.text ?? "")
        layout()
        refreshStatus()
    }

    /// A voice card has no picture: the bubble is its words alone (in place, the picture is the frozen one beside it).
    private var showsPicture: Bool { shot?.kind != .voice && !staged }

    private func previewSize() -> NSSize {
        let px = shot?.pixelSize ?? CGSize(width: 1600, height: 1000)
        let maxW: CGFloat = mode == .recording ? 340 : 540, maxH: CGFloat = mode == .recording ? 210 : 320
        let aspect = max(0.2, min(5, px.width / max(1, px.height)))
        var w = maxW, h = w / aspect
        if h > maxH { h = maxH; w = h * aspect }
        return NSSize(width: max(140, w.rounded()), height: max(90, h.rounded()))
    }

    /// The bubble's grid (the main window's Move popover's): 12 pt to a 16 pt glyph column — how the note is taken
    /// (the live level, the saved check, mic.slash, the keyboard; in Edit Note the play or the mic button), the chip's
    /// place, the list's folders — then 8 pt to the text column — the note, the chip's name, the list's names.
    /// r2: one composer for a fresh snap and Edit Note, with one footer grammar in fixed slots, left to right:
    ///   the place chip · the hover tools (the stroke undo, the bin / Record Again — only under the pointer) · the status
    ///   slot (right-aligned against the primary: state — "0:04", "Saved" — and the keys only for the grey words) · the one
    ///   primary with its key on it ("Done ↩", "Save ↩"). The bin sits by the chip, never by the primary.
    static let inset: CGFloat = 12
    static let footH: CGFloat = 24
    /// a long project name widens the bubble while its list is open, up to this (then its middle is cut, the tooltip
    /// has it whole)
    static let maxInner: CGFloat = 440
    static let fontSize: CGFloat = 15

    /// The footer's hover tools now, in order: the stroke undo (with ink), then the bin (a fresh snap) or Record Again
    /// (Edit Note, when the note has a voice — without one the mic is the glyph column's button).
    private var hoverTools: [SymbolButton] {
        var t: [SymbolButton] = []
        if !ink.strokes.isEmpty, mode != .recording { t.append(undoBtn) }
        if mode == .listen { t.append(discardBtn) }
        if mode == .edit, hasVoice, voice?.running != true { t.append(micBtn) }
        return t
    }

    /// Edit Note: the note has a voice to play (a kept re-record, else the original)
    private var hasVoice: Bool { playURL.map { FileManager.default.fileExists(atPath: $0.path) } == true }

    private func layout() {
        let pic = showsPicture
        let pv = pic ? previewSize() : .zero
        let m = NoteBubble.inset
        let c = BubbleBackground.caret
        let ins = bg.insets
        let composer = mode != .recording
        var inner = max(mode == .recording ? 340 : staged ? 384 : 400, pv.width + m * 2)
        // a fresh snap's footer holds the chip, the bin, the keys for the grey words and Done ↩ on one line — sized for
        // them from the start, so the bubble never widens as the words come
        if mode == .listen { inner = max(inner, min(NoteBubble.maxInner, footerWidth())) }
        if picking { inner = max(inner, min(NoteBubble.maxInner, pick.wantWidth)) }
        let width = inner + ins.left + ins.right
        let x0 = ins.left, top = ins.top
        let glyphX = x0 + m, textX = x0 + m + 24, right = x0 + inner - m
        // (the field's cell draws its text 2 pt in: the text starts on the text column)
        let fieldW = right - textX + 2
        let fieldH = fieldHeight(fieldW - 4, max: pic ? 90 : 220)
        let footH = NoteBubble.footH
        let pickH = picking ? pick.height : 0
        // (a caret up or down takes its height; one at the side, its width — the card keeps the same inner size)
        let height = (ins.top + ins.bottom > 0 ? c : 0) + m + (pic ? pv.height + 10 : 0) + fieldH + 6 + footH
            + (picking ? 4 + pickH : 0) + m - 2
        panel?.setContentSize(NSSize(width: width, height: height))
        bg.frame = NSRect(x: 0, y: 0, width: width, height: height)
        canvas.isHidden = !pic
        canvas.frame = NSRect(x: x0 + (inner - pv.width) / 2, y: top + m, width: pv.width, height: pv.height)
        penHint.stringValue = mode == .recording ? "" : "   " + Loc.t("capture.note.pen_hint", table: "Capture") + "   "
        penHint.sizeToFit()
        penHint.frame = NSRect(x: canvas.frame.minX + 8, y: canvas.frame.maxY - 30, width: penHint.frame.width, height: 22)
        penHint.isHidden = !pic || mode == .recording || !canvas.strokes.isEmpty || penHintGone
        // row 1: the glyph column (how the note is being taken) and the words
        let rowY = pic ? canvas.frame.maxY + 10 : top + m
        let lineMid = rowY + ceil((field.font ?? .systemFont(ofSize: NoteBubble.fontSize)).boundingRectForFont.height) / 2 + 1
        icon.frame = NSRect(x: glyphX, y: lineMid - 8, width: 16, height: 16)
        bars.frame = icon.frame
        field.frame = NSRect(x: textX - 2, y: rowY, width: fieldW, height: fieldH)
        for b in [nextBtn, prevBtn, micBtn, playBtn, keepBtn, discardBtn, undoBtn] { b?.isHidden = true }
        // Edit Note: the glyph column is a button — play the voice it has, else record one (brand ink, the bubble's mic)
        if mode == .edit, voice?.running != true {
            let b: SymbolButton = hasVoice ? playBtn : micBtn
            b.isHidden = false
            b.contentTintColor = BrandColor.ink
            b.toolTip = Loc.t(hasVoice ? "capture.note.play" : "capture.note.record", table: "Capture")
            b.frame.origin = NSPoint(x: glyphX + 8 - 12, y: lineMid - 12)
        }
        // the footer
        let footY = rowY + fieldH + 6
        let midY = footY + footH / 2
        doneBtn.isHidden = !composer
        chip.isHidden = !composer
        var leftEnd = textX, rightEnd = right
        if composer {
            doneBtn.title = Loc.t(mode == .edit ? "capture.note.save" : "capture.note.done", table: "Capture")
            doneBtn.toolTip = Loc.t(mode == .edit ? "capture.note.save_tip" : "capture.note.done_tip", table: "Capture")
            // while the list is open its ↩ is the action: the primary steps back (system.md: neutral fill, no gradient)
            doneBtn.isEnabled = !picking
            doneBtn.alphaValue = 1
            let sz = doneBtn.intrinsicContentSize
            doneBtn.frame = NSRect(x: right - sz.width, y: midY - 11, width: sz.width, height: 22)
            rightEnd = doneBtn.frame.minX - 10
            // the place leads the footer — its glyph on the glyph column, its name on the text column
            chip.set(place, maxWidth: min(200, inner * 0.56))
            chip.open = picking
            chip.frame.origin = NSPoint(x: glyphX - ProjectChip.lead, y: footY)
            leftEnd = chip.frame.maxX + 4
            // the hover tools, after the chip (never over an open list)
            if hovering && !picking {
                for t in hoverTools {
                    t.isHidden = false
                    t.contentTintColor = .secondaryLabelColor
                    if t === micBtn { t.toolTip = Loc.t("capture.note.rerecord", table: "Capture") }
                    t.frame.origin = NSPoint(x: leftEnd, y: midY - 12)
                    leftEnd += 24 + 2
                }
            }
            leftEnd += 6
        } else {
            // the note popover while recording: its own line (the shot counter, the keys), the arrows at the right
            var bx = right
            if recordingShots.count > 1 {
                nextBtn.isHidden = false; nextBtn.frame.origin = NSPoint(x: bx - 24, y: midY - 12); bx -= 26
                prevBtn.isHidden = false; prevBtn.frame.origin = NSPoint(x: bx - 24, y: midY - 12); bx -= 26
            }
            rightEnd = bx - 6
        }
        // the status slot: pinned against the primary (right-aligned), so it never moves with the chip's name
        status.alignment = composer ? .right : .left
        let sh = ceil(status.attributedStringValue.size().height)
        status.frame = NSRect(x: leftEnd, y: midY - max(15, sh) / 2, width: max(0, rightEnd - leftEnd), height: max(15, sh))
        // a line that doesn't fit beside the hover tools steps aside while they show (never cut mid-word)
        status.isHidden = ceil(status.attributedStringValue.size().width) + 4 > status.frame.width
        pick.isHidden = !picking
        if picking {
            pick.frame = NSRect(x: x0, y: footY + footH + 4, width: inner, height: pick.height)
            pick.layoutRows()
            pick.needsDisplay = true
        }
        position()
    }

    /// The inner width a fresh snap's footer needs: the chip (at most 200 pt), the bin, the keys line, Done ↩.
    private func footerWidth() -> CGFloat {
        let m = NoteBubble.inset
        chip.set(place, maxWidth: 200)
        let keys = ceil(NoteBubble.keyLine(Loc.t("capture.note.st_voice", table: "Capture")).size().width) + 4
        return m + (chip.frame.width - ProjectChip.lead) + 4 + 26 + 6 + keys + 10 + doneBtn.intrinsicContentSize.width + m
    }

    private func fieldHeight(_ w: CGFloat, max cap: CGFloat) -> CGFloat {
        // the live words take the placeholder's place, so they size the field as typed text does
        let s = field.stringValue.isEmpty ? (field.placeholderAttributedString?.string ?? field.placeholderString ?? "x") : field.stringValue
        let r = (s as NSString).boundingRect(with: NSSize(width: w, height: 400), options: [.usesLineFragmentOrigin],
                                             attributes: [.font: field.font!])
        return min(cap, max(20, ceil(r.height) + 2))
    }

    private func position() {
        guard let p = panel else { return }
        if let sel = dock { return positionDocked(p, beside: sel) }
        let size = p.frame.size
        let a = anchor?() ?? NSRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y, width: 1, height: 1)
        let screen = (NSScreen.screens.first(where: { $0.frame.intersects(a) }) ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        var up = true
        var o = NSPoint(x: a.midX - size.width / 2, y: a.minY - 6 - size.height)
        if o.y < screen.minY + 8 { up = false; o.y = a.maxY + 6 }
        o.x = max(screen.minX + 8, min(o.x, screen.maxX - size.width - 8))
        o.y = max(screen.minY + 8, min(o.y, screen.maxY - size.height))
        let want: BubbleBackground.Caret = up ? .up : .down
        if bg.caret != want { bg.caret = want; DispatchQueue.main.async { self.layout() } }
        bg.caretAt = a.midX - o.x
        p.setFrameOrigin(o)
    }

    /// In place: beside the frozen selection, on its screen, never over it (BlurtCore BubbleDock); the caret points at
    /// it from the side it is on.
    private func positionDocked(_ p: NSPanel, beside sel: NSRect) {
        let screen = InkStage.shared.visibleFrame
        // the card's size without its caret; placed as if the caret took room both ways, then trimmed to its side
        let ins = bg.insets
        let card = NSSize(width: p.frame.width - ins.left - ins.right, height: p.frame.height - ins.top - ins.bottom)
        let c = BubbleBackground.caret
        let d = BubbleDock.place(bubble: NSSize(width: card.width + c, height: card.height + c), selection: sel, screen: screen)
        let want: BubbleBackground.Caret
        switch d.side {
        case .right: want = .left
        case .left: want = .right
        case .below: want = .up
        case .above: want = .down
        case .inside: want = .none
        }
        if dockSide != d.side { dockSide = d.side; emit(["event": "note_dock", "side": d.side.rawValue, "n": shot?.n ?? 0]) }
        if bg.caret != want { bg.caret = want; layout(); return }       // (layout positions it again, with this caret)
        var o = d.origin
        switch d.side {
        case .right, .left:
            o.y += c                                     // its top at the selection's top
            let top = o.y + p.frame.height, bottom = o.y
            let overlapTop = min(sel.maxY, top), overlapBottom = max(sel.minY, bottom)
            let aim = overlapTop - min(26, max(0, overlapTop - overlapBottom) / 2)
            bg.caretAt = top - aim                       // (from the card's top: the view is flipped)
        case .below, .above, .inside:
            o.x += c                                     // its right edge at the selection's
            bg.caretAt = sel.midX - o.x
        }
        p.setFrameOrigin(o)
    }

    private func present() {
        guard let p = panel, isOpen else { return }
        position()
        let reduce = reduceMotion
        if !p.isVisible {
            p.alphaValue = 0
            p.orderFrontRegardless()
            if !reduce, let l = bg.layer ?? { bg.wantsLayer = true; return bg.layer }() {
                l.anchorPoint = .zero
                let s = CASpringAnimation(keyPath: "transform.scale")
                s.fromValue = 0.92; s.toValue = 1
                s.mass = 0.8; s.stiffness = 320; s.damping = 22
                s.duration = s.settlingDuration
                l.add(s, forKey: "unfold")
            }
        }
        // always back to full: a bubble reopened while the last one was still fading out (v0.9: Edit Note on another
        // card, or a snap right after a saved note, came up at the fade's alpha and was then ordered out by it)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = reduce ? 0.15 : 0.18
            p.animator().alphaValue = 1
        }
        // the panel is non-activating: it takes the typing without activating Blurt, so Blurt's main window never
        // jumps above the app the user just snapped; close() still hands focus back
        if mode == .recording { snapper.rememberFrontApp() }
        if !NoteBubble.testNoKey { p.makeKey() }
        p.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.count, length: 0)
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.tick() }
        fadePenHint(for: shot, after: NoteBubble.penHintSeconds)
    }

    /// The pen hint says it once, then gets off the picture (it sits over what is being circled): after a moment, or
    /// as soon as the user talks or draws.
    static let penHintSeconds: Double = 2.5
    private func fadePenHint(for s: Shot?, after delay: Double) {
        guard let s = s, !penHint.isHidden, !penHintGone else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.shot === s, !self.penHintGone else { return }
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = reduceMotion ? 0 : 0.3
                self.penHint.animator().alphaValue = 0
            }, completionHandler: {
                guard self.shot === s else { return }
                self.penHintGone = true
                self.penHint.isHidden = true
            })
        }
    }

    // MARK: listening

    private func startListening() {
        guard let s = shot, let dir = s.batch?.dir else { return }
        guard Dictation.shared.phase != .listening else { return refreshStatus() }    // dictation has the mic: type instead
        // a ⌥V voice note is listening: it already hears what is said — this note is typed (one listener at a time)
        if VoiceInput.shared.active, mode == .listen {
            voiceBusy = true
            emit(["event": "note_voice_busy", "n": s.n])
            return refreshStatus()
        }
        // a re-record never writes over the note it replaces: it goes next to it until it is kept (VoiceRetake)
        let rel = mode == .edit ? VoiceRetake.path(for: canonicalVoice(s)) : canonicalVoice(s)
        takeRel = rel
        let v = NoteVoice(url: dir.appendingPathComponent(rel))
        // no pause ends it: the user commits the note (↩, Tab, Done — NoteKeys). The mic stops after 20 s with nothing
        // said (drawing pushes that out) and at 120 s; the bubble stays either way.
        v.silenceToEnd = .infinity
        v.noSpeechTimeout = NoteBubble.noSpeechStop
        v.maxLength = NoteBubble.maxListen
        // a fresh shot's words while they are said (the voice note's live text), in the field's place
        let st = mode == .listen && VoiceInput.shared.streams ? VoiceNoteStream(id: "note-\(ShotBatch.name(s.n))-\(Int(Date().timeIntervalSince1970))",
                                                   interim: VoiceInput.liveWords) : nil
        st?.onLive = { [weak self] committed, pending in
            guard let self = self, self.stream === st else { return }
            self.heard = (committed, pending)
            self.refreshStatus()
            self.layout()
        }
        if let st = st { v.onSamples = { [weak st] x in st?.append(x) } }
        stream = st
        v.onLevel = { [weak self] l in self?.bars.level = l }
        v.onSpeech = { [weak self] in
            self?.speechStarted = true
            self?.fadePenHint(for: self?.shot, after: 0)
            self?.refreshStatus()
        }
        v.onEnd = { [weak self] e in
            guard let self = self, self.voice === v else { return }
            self.voice = nil
            if e == .micLost && !self.speechStarted {
                // nothing was said: the bubble stays and says so — the note can still be typed
                self.retakeFell()
                self.dropStream()
                self.micGone = true
                self.voiceDone = true
                emit(["event": "note_mic_gone", "n": self.shot?.n ?? 0])
                self.refreshStatus()
                return
            }
            if e == .noSpeech {
                self.retakeFell()
                self.dropStream()
            } else {
                // the mic ended by itself after speech (120 s, the mic gone): what was said is kept and is still the
                // user's to commit — the grey words stay (a fresh snap), the re-record is kept (Edit Note)
                self.keepTake(v)
                if e == .micLost { VoiceInput.say(.micLost) }
            }
            self.voiceDone = true
            self.refreshStatus()
            self.layout()                                // (Edit Note: the play / mic button back in the glyph column)
        }
        voice = v
        VoiceInput.warmSpeechModel()            // its words come from the warm server, not a cold model load
        v.start { [weak self] ok in
            guard let self = self, self.voice === v else { return }
            guard !ok else { return }
            emit(["event": "note_voice_start_failed", "n": s.n, "why": v.failReason ?? "unknown", "mode": "\(self.mode)"])
            self.voice = nil; self.dropStream(); self.retakeFell(); self.refreshStatus()
        }
        refreshStatus()
    }

    /// The recording stopped and is kept (the mic ended by itself after speech, Tab, typing over the words): a fresh
    /// shot's take becomes its voice, its final words coming (Snapper); Edit Note's re-record will replace the original
    /// when the edit is saved.
    private func keepTake(_ v: NoteVoice) {
        voiceKept = true
        if mode == .edit {
            retakeKept = true
            retakeSeconds = v.elapsed
        } else if let rel = takeRel {
            shot?.voice = rel
            shot?.said = nil                    // its words to come
            wordsComing()
        }
    }

    /// Stops listening now (Tab, typing over the words): what was said is kept; with nothing said, nothing is.
    private func stopListening(via: String) {
        guard let v = voice else { return }
        voice = nil
        // (the live words can come before the endpointer calls it speech: words seen are words said)
        let keep = speechStarted || !(heard.committed + heard.pending).isEmpty
        emit(["event": "note_voice_stop", "n": shot?.n ?? 0, "via": via, "kept": keep,
              "speech": (v.speechSeconds * 100).rounded() / 100])
        v.stop(keep: keep)
        voiceDone = true
        if keep { keepTake(v) } else { retakeFell(); dropStream() }
    }

    /// A fresh shot's recording stopped and is kept: its final words (the stream's last piece, else the whole wav).
    private func wordsComing() {
        guard let s = shot, mode == .listen else { return }
        if let st = stream { snapper.attach(st, to: s) }
        stream = nil
        waitingWords = true
        let g = generation
        snapper.fetchWords(s) { [weak self] said in
            guard let self = self, self.generation == g, self.shot === s else { return }
            self.wordsIn(said)
        }
    }

    /// The final words of what was said are in. Not taken: they are the grey words now. Taken with Tab: while the field
    /// still starts with the live words as they were put in, the final words take their place (what was typed after
    /// them stays, the caret with it), so the card says what the bubble shows; once the words themselves were edited,
    /// the field is the note (NoteEdit). Taken before any words were heard: they go in before what was typed since.
    private func wordsIn(_ said: String?) {
        waitingWords = false
        guard let w = CardNote.clean(said) else {
            // no words in it after all (or they couldn't be had): nothing grey to keep unless the live words were seen
            if (heard.committed + heard.pending).isEmpty && !accepted { voiceKept = false }
            refreshStatus()
            return
        }
        emit(["event": "note_words_in", "n": shot?.n ?? 0, "chars": w.count, "taken": accepted])
        heard = (w, "")
        if accepted, let raw = takenRaw {
            if field.stringValue.hasPrefix(raw) { settleTaken(raw, into: w) }
        } else if accepted {
            setField(NoteBubble.joined(w, then: field.stringValue))
        }
        refreshStatus()
        layout()
    }

    /// The words taken, then what was typed after Tab before they came ("" — just the words).
    static func joined(_ words: String, then typed: String) -> String {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return words }
        let ascii: (Character?) -> Bool = { c in c.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0.isPunctuation) } ?? false }
        return words + (ascii(words.last) && ascii(t.first) ? " " : "") + t
    }

    /// The words taken into the field (black), the caret at their end.
    private func setField(_ w: String) {
        field.stringValue = w
        takenRaw = w
        wordsInField = CardNote.clean(w) ?? w
        field.currentEditor()?.selectedRange = NSRange(location: (w as NSString).length, length: 0)
    }

    /// The final words in place of the live ones the field starts with; what follows them, and the caret, stay.
    private func settleTaken(_ raw: String, into w: String) {
        let old = field.stringValue as NSString, rawLen = (raw as NSString).length, wLen = (w as NSString).length
        let tail = old.substring(from: rawLen)
        let caret = field.currentEditor()?.selectedRange.location ?? old.length
        field.stringValue = w + tail
        takenRaw = w
        wordsInField = CardNote.clean(w) ?? w
        let at = caret >= rawLen ? caret - rawLen + wLen : min(caret, wLen)
        field.currentEditor()?.selectedRange = NSRange(location: at, length: 0)
        typed = NoteTyping.typed(field.stringValue, marked: nil) && CardNote.clean(field.stringValue) != wordsInField
    }

    private func dropStream() {
        stream?.cancel()
        stream = nil
        heard = ("", "")
    }

    private func strokeBegan() {
        voice?.activity(grace: NoteBubble.inkGrace)
        fadePenHint(for: shot, after: 0)
        if staged { InkStage.shared.hideHint() }
    }

    private func strokeEnded() {
        inkUndoFirst = true
        voice?.activity(grace: NoteBubble.inkGrace)
    }

    private func resignedKey() {
        guard isOpen, mode != .recording else { return }
        emit(["event": "note_resign", "n": shot?.n ?? 0, "app_active": NSApp.isActive])
        // tests on a shared machine: another app coming forward isn't the tester leaving the bubble
        guard !NoteBubble.testIgnoresResign else { return }
        scheduleResignSave(after: NoteBubble.resignSeconds)
    }

    /// The user went to another app: the bubble saves a moment later — listening or not (the mic stops, what was said
    /// is kept), so it never floats, or listens, over every app.
    private func scheduleResignSave(after delay: Double) {
        resignWork?.cancel()
        let g = generation
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == g, self.isOpen, self.panel?.isKeyWindow != true else { return }
            emit(["event": "note_resign_commit", "n": self.shot?.n ?? 0, "listening": self.voice?.running == true])
            self.commit()
        }
        resignWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func rerecord() {
        guard mode == .edit else { return }
        guard Dictation.shared.phase != .listening else { return refreshStatus() }    // dictation has the mic
        voice?.stop(keep: false)                // a retake in progress: only it goes
        voice = nil
        if retakeKept, let u = retakeURL { VoiceRetake.discard(u) }
        retakeKept = false
        // the words said will be the new take's: the field keeps what was typed (unless it was changed)
        if let o = original, CardNote.clean(field.stringValue) == CardNote.clean(NoteEdit.field(typed: o.text, said: o.said)) {
            field.stringValue = o.text ?? ""
            fieldHoldsSaid = false
            layout()
        }
        typed = !field.stringValue.isEmpty
        speechStarted = false
        voiceDone = false
        let keepTyped = typed
        startListening()
        typed = keepTyped
        refreshStatus()
        layout()                                // the glyph column's button gives way to the level
    }

    /// A re-record ended without a take (no speech, the mic didn't start): the words said stay, so the field shows
    /// them again — unless the user changed what was typed meanwhile.
    private func retakeFell() {
        guard mode == .edit, !fieldHoldsSaid, !retakeKept, let o = original,
              CardNote.clean(field.stringValue) == CardNote.clean(o.text) else { return }
        field.stringValue = NoteEdit.field(typed: o.text, said: o.said)
        fieldHoldsSaid = true
        layout()
    }

    private func plainPlaceholder(_ s: String) {
        field.placeholderAttributedString = nil
        field.placeholderString = s
    }

    /// The live words in the field's place (secondary, the part still being said quieter), or the prompt.
    private func livePlaceholder(_ prompt: String) {
        let f = field.font ?? .systemFont(ofSize: 14)
        guard !(heard.committed + heard.pending).isEmpty else {
            field.placeholderAttributedString = NSAttributedString(string: prompt, attributes: [.font: f, .foregroundColor: NSColor.placeholderTextColor])
            return
        }
        let a = NSMutableAttributedString(string: heard.committed, attributes: [.font: f, .foregroundColor: NSColor.secondaryLabelColor])
        a.append(NSAttributedString(string: heard.pending, attributes: [.font: f, .foregroundColor: NSColor.tertiaryLabelColor]))
        field.placeholderAttributedString = a
    }

    /// What the bubble says now (r2). The glyph column says how the note is taken: the live level while it listens, a
    /// waveform once the mic stopped with words said (they wait for ↩ or Tab), the keyboard once the keyboard has the
    /// note (typed, or the words taken with Tab), mic.slash when it can't or doesn't listen (Edit Note: its play or mic
    /// button, the level while it records again). The placeholder says what to do — or, in grey, the words heard.
    /// The status slot holds state — the running time while it listens, "Saved" — and the keys only for the grey words
    /// ("Tab accept · type to replace": they are the one thing the keyboard does differently there). Other keys live on
    /// buttons and in tooltips (Done ↩, the bin's Esc, the undo's ⌘Z); the first few snaps teach Esc on the stage's pill
    /// (InkStage), and the list's keys under the list.
    private var lastSecond = -1
    private func refreshStatus() {
        let listening = voice?.running == true
        bars.isHidden = !listening
        var sym: String?
        var tint: NSColor = .tertiaryLabelColor
        switch mode {
        case .listen:
            if listening { sym = nil }
            else if accepted || typed { sym = "keyboard" }  // the keyboard has the note: the column never goes empty
            else if voiceKept { sym = "waveform" }           // said, the mic stopped: the words wait for ↩ or Tab
            else { sym = "mic.slash" }                       // it can't, or doesn't any more, listen
        case .edit:
            sym = nil                                        // (its play / mic button)
        case .recording:
            sym = "note.text"; tint = .secondaryLabelColor
        }
        icon.isHidden = listening || sym == nil
        icon.image = sym.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) }
        icon.contentTintColor = tint
        var line = ""
        let t = voice?.elapsed ?? 0
        lastSecond = listening ? Int(t) : -1
        switch mode {
        case .listen:
            chip?.set(place, maxWidth: min(200, (panel?.frame.width ?? 352) * 0.56))
            if accepted {
                // (the words taken with Tab, still to come: nothing to prompt for meanwhile)
                plainPlaceholder(wordsInField == nil && waitingWords ? "" : Loc.t("capture.note.placeholder_optional", table: "Capture"))
            } else if listening || voiceKept {
                livePlaceholder(Loc.t("capture.note.listening", table: "Capture"))
            } else if voiceBusy {
                plainPlaceholder(Loc.t("capture.note.ph_voice_busy", table: "Capture"))
            } else if micGone {
                plainPlaceholder(Loc.t("capture.note.ph_mic_gone", table: "Capture"))
            } else if !voiceDone {
                plainPlaceholder(Loc.t("capture.note.ph_no_mic", table: "Capture"))      // it never listened
            } else {
                plainPlaceholder(Loc.t("capture.note.placeholder_optional", table: "Capture"))
            }
            if picking {
                line = ""
            } else if keyState.wordsShowing {
                line = Loc.t("capture.note.st_voice", table: "Capture")
            } else if listening {
                line = fmt(t)
            }
        case .edit:
            chip?.set(place, maxWidth: min(200, (panel?.frame.width ?? 400) * 0.56))
            plainPlaceholder(Loc.t("capture.note.placeholder", table: "Capture"))
            // a re-record: the running time; once something was said, Tab ends it (kept) — Save ↩ keeps it too
            line = picking || !listening ? "" : Loc.t(speechStarted ? "capture.note.st_rerecord_tab" : "capture.note.st_rerecord",
                                                      table: "Capture", fmt(t))
        case .recording:
            let i = recordingShots.firstIndex(where: { $0 === shot }).map { $0 + 1 } ?? 1
            plainPlaceholder(Loc.t("capture.note.placeholder_shot", table: "Capture"))
            // the shot counter first: on a narrow bubble the hint's tail is what gets cut, not "2/2"
            line = (recordingShots.count > 1 ? "\(i)/\(recordingShots.count)  ·  " : "") + Loc.t("capture.note.paused", table: "Capture")
        }
        // (the slot is pinned against the primary: right-aligned, set on the string itself — an attributed value
        // carries its own paragraph style, the field's `alignment` alone doesn't hold)
        status.attributedStringValue = NoteBubble.keyLine(line, alignment: mode == .recording ? .left : .right)
        if status.frame.width > 0 { status.isHidden = ceil(status.attributedStringValue.size().width) + 4 > status.frame.width }
    }

    /// The footer line, the way macOS menus set their keys: the keys (⏎ ↩ ⌘Z ↑↓ Esc …) in medium, the words regular,
    /// both secondary (a key hint is text that must be read: never tertiary), times in tabular figures.
    static func keyLine(_ s: String, alignment: NSTextAlignment = .natural) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let ps = NSMutableParagraphStyle()
        ps.alignment = alignment
        ps.lineBreakMode = .byTruncatingTail
        let a = NSMutableAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: ps])
        let keys = ["⌘Z", "↑↓", "⏎", "↩", "Esc", "Tab", "⇧", "⌥", "⌘←", "⌘→"]
        let ns = s as NSString
        for k in keys {
            var r = ns.range(of: k)
            while r.location != NSNotFound {
                a.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), range: r)
                let from = r.location + r.length
                r = ns.range(of: k, range: NSRange(location: from, length: ns.length - from))
            }
        }
        return a
    }

    private func fmt(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    /// Where this snap goes, by the name its list uses (one name for one choice): the project, or Unassigned — the
    /// list's row and the chip's tooltip say what that means (it stays as a card until a project is picked). The
    /// current project's folder is gone (MissingFolder): its name and "folder not found" (it stays a card meanwhile).
    private var place: ProjectChip.Place {
        guard let pid = placeID, let p = ProjectStore.shared.project(id: pid) else {
            if let m = ProjectStore.shared.missingCurrent { return .missing(m.name) }
            return .unassigned
        }
        return .project(p)
    }

    /// Where it goes: the capture's project — in Edit Note, the place picked in its list (it moves on Save).
    private var placeID: String? { mode == .edit && editPicked ? editProject : shot?.project }
    /// Edit Note: a place was picked in the chip's list (nil = Unassigned); applied when the edit is saved
    private var editPicked = false
    private var editProject: String?

    /// The pointer came onto the bubble or left it: the hover tools fade in or out (0.12 s).
    private func hover(_ on: Bool) {
        guard hovering != on, isOpen else { return }
        hovering = on
        let quiet = hoverTools
        if on { quiet.forEach { $0.alphaValue = 0 } }
        layout()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = reduceMotion ? 0 : 0.12
            quiet.forEach { $0.animator().alphaValue = 1 }
        }
    }

    private func tick() {
        bars.decay()
        if let v = voice, v.running, Int(v.elapsed) != lastSecond { refreshStatus() }      // the running time
        // the pen held still on the picture is still drawing: the no-speech stop waits for it
        if ink.isDrawing { voice?.activity(grace: NoteBubble.inkGrace) }
        // follow the card if the cards re-lay out (another capture arrived, a neighbour was removed); docked, it stays
        if let p = panel, p.isVisible, mode != .recording, !staged { position() }
    }

    // MARK: input — the keys are BlurtCore NoteKeys (state × key → action)

    /// The bubble's state as NoteKeys reads it.
    private var keyState: NoteKeys.State {
        let listening = voice?.running == true
        let heardAny = !(heard.committed + heard.pending).isEmpty
        var v: NoteKeys.Voice = .none
        switch mode {
        case .listen where !accepted:
            if listening { v = speechStarted || heardAny ? .words : .listening } else if voiceKept { v = .words }
        case .edit where listening:
            v = speechStarted ? .words : .listening
        default:
            break
        }
        // the words taken with Tab, untouched, are not typing
        let typedPart = (accepted || wordsInField != nil) && !typed ? "" : field.stringValue
        return NoteKeys.State(mode: mode == .listen ? .fresh : mode == .edit ? .edit : .recording, voice: v, typed: typedPart,
                              composing: (field.currentEditor() as? NSTextView)?.hasMarkedText() == true, picking: picking)
    }

    /// Does what NoteKeys decided; false when the key isn't the bubble's (it goes on to the field, the IME, the list).
    @discardableResult
    private func perform(_ a: NoteKeys.Action, key k: NoteKeys.Key) -> Bool {
        guard isOpen, a != .pass else { return false }
        emit(["event": "note_key", "n": shot?.n ?? 0, "key": "\(k)", "action": "\(a)"])
        switch a {
        case .pass, .ignore: break
        case .commit: commit()
        case .newLine: lineBreak()
        case .takeWords(let newLine):
            takeWords()
            if newLine { lineBreak() }
        case .openPlaces: openPick()
        case .closePlaces: closePick()
        case .clearText: clearText()
        case .close: cancel()
        case .typeOver, .typedNote: stopListening(via: "typing")
        }
        return true
    }

    func controlTextDidChange(_ n: Notification) {
        let marked = (field.currentEditor() as? NSTextView).flatMap { $0.hasMarkedText() ? $0.markedRange() : nil }
        let committed = NoteTyping.committed(field.stringValue, marked: marked)
        var now = NoteTyping.typed(field.stringValue, marked: marked)
        // the words taken with Tab, in the field: only a change to them is typing (an edit of the words)
        if let w = wordsInField, CardNote.clean(committed) == w { now = false }
        // typing over the grey words replaces them (the mic stops, the take is set aside); before anything was said it
        // makes a typed note
        if now && !typed { perform(NoteKeys.action(.typing, keyState), key: .typing) }
        // the words taken with Tab, all deleted: they are the grey words again (↩ keeps them, Tab takes them again)
        if accepted, wordsInField != nil, marked == nil, committed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            accepted = false
            wordsInField = nil
            takenRaw = nil
            emit(["event": "note_words_untaken", "n": shot?.n ?? 0])
        }
        if field.stringValue != (wordsInField ?? "") { inkUndoFirst = false }
        typed = now
        refreshStatus()
        layout()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        // (the keys the panel didn't take first — an IME passing one on, ⌃↩ / ⌥↩ — and the scripted checks' keys)
        let k: NoteKeys.Key
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): k = .returnKey
        case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): k = .shiftReturn
        case #selector(NSResponder.insertTab(_:)): k = .tab
        case #selector(NSResponder.cancelOperation(_:)): k = .escape
        default: return false
        }
        return perform(NoteKeys.action(k, keyState), key: k)
    }

    private func key(_ e: NSEvent) -> Bool {
        // ↩ ⇧↩ Tab Esc: NoteKeys (an IME composition and the open place list keep their own)
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        var k: NoteKeys.Key?
        switch Int(e.keyCode) {
        case kVK_Escape: k = .escape
        case kVK_Return, kVK_ANSI_KeypadEnter: k = mods.isEmpty ? .returnKey : mods == .shift ? .shiftReturn : nil
        case kVK_Tab: k = mods.isEmpty ? .tab : nil
        default: break
        }
        if let k = k { return perform(NoteKeys.action(k, keyState), key: k) }
        if picking { return false }
        // ⌘Z: the last stroke goes when drawing was the last thing done (or there is no text to undo)
        if e.modifierFlags.contains(.command), !e.modifierFlags.contains(.shift), e.charactersIgnoringModifiers == "z",
           !ink.strokes.isEmpty, inkUndoFirst || field.stringValue.isEmpty {
            undoInk(); return true
        }
        if mode == .recording, e.modifierFlags.contains(.command) {
            if e.keyCode == UInt16(kVK_LeftArrow) { step(-1); return true }
            if e.keyCode == UInt16(kVK_RightArrow) { step(1); return true }
        }
        return false
    }

    /// Tab over the grey words: they go into the field (label colour, the caret at their end), listening stops and the
    /// keyboard has the note — the stream's final words replace them while they are untouched (wordsIn). Edit Note: the
    /// re-record ends, kept (its words replace the note's on Save).
    private func takeWords() {
        let live = CardNote.clean(heard.committed + heard.pending)
        if mode == .listen { accepted = true }
        stopListening(via: "tab")
        if mode == .listen, let w = live { setField(w) }
        emit(["event": "note_take_words", "n": shot?.n ?? 0, "chars": live?.count ?? 0, "waiting": waitingWords])
        refreshStatus()
        layout()
    }

    /// A line break at the caret (the field is multi-line).
    private func lineBreak() {
        guard let tv = field.currentEditor() as? NSTextView else { return }
        tv.insertText("\n", replacementRange: tv.selectedRange())
    }

    /// Esc's first step (BlurtCore NoteEsc): the typed text goes — the words taken with Tab stay, and over grey words
    /// they show again — and the bubble stays; the next Esc discards the shot, with Undo.
    private func clearText() {
        field.stringValue = takenRaw ?? ""
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        typed = false
        emit(["event": "note_esc", "n": shot?.n ?? 0, "action": "clear_text"])
        refreshStatus()
        layout()
    }

    private func inkChanged() {
        refreshStatus()                         // (⌘Z is named once there is ink)
        layout()
    }

    private func undoInk() {
        guard ink.undo() else { return }
        if ink.strokes.isEmpty { inkUndoFirst = false }
        layout()
    }

    // MARK: the chip: where it goes

    @objc private func doneClicked() { commit() }

    private func togglePick() { picking ? closePick() : openPick() }

    private func openPick() {
        guard mode != .recording, let s = shot, !picking else { return }
        picking = true
        pick.current = placeID
        pick.showsKeys = firstTimes             // its keys, the first few times (as the pen hint)
        pick.filter.stringValue = ""
        pick.reload()
        pick.select(pick.currentIndex)          // the cursor opens on where it goes now: the wash and the check agree
        refreshStatus()
        layout()
        // the list unfolds from the chip (0.15 s): it comes from what was clicked
        if !reduceMotion {
            pick.alphaValue = 0
            NSAnimationContext.runAnimationGroup { c in c.duration = 0.15; pick.animator().alphaValue = 1 }
        }
        panel?.makeFirstResponder(pick.filter)
        emit(["event": "note_chip", "open": true, "n": s.n, "rows": pick.rows.map { $0?.id ?? "inbox" }])
    }

    private func closePick() {
        guard picking else { return }
        picking = false
        refreshStatus()
        layout()
        panel?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        emit(["event": "note_chip", "open": false, "n": shot?.n ?? 0])
    }

    private func picked(_ p: Project?) {
        guard let s = shot else { return }
        // Edit Note: the card moves when the edit is saved (Esc leaves it where it was)
        if mode == .edit {
            editPicked = true
            editProject = p?.id
            emit(["event": "note_pick_edit", "n": s.n, "project": p?.id ?? NSNull()])
            closePick()
            return refreshStatus()
        }
        // a project whose folder can't be found takes nothing: the capture stays a card (what the island's line says,
        // with Locate…) — in place, said once the note settles (the island can't show it under the note)
        if let p = p, !p.exists {
            if s.project != nil { snapper.retarget(s, to: nil) }
            closePick()
            if staged { snapper.warnWhenSettled(s, missing: p) } else { MissingFolder.warn(p) }
            emit(["event": "note_pick_missing", "n": s.n, "project": p.id, "deferred": staged])
            return refreshStatus()
        }
        if s.project != p?.id { snapper.retarget(s, to: p?.id) }
        closePick()
        refreshStatus()
    }

    private func step(_ d: Int) {
        guard mode == .recording, let s = shot, let i = recordingShots.firstIndex(where: { $0 === s }) else { return }
        saveText(s)
        let j = (i + d + recordingShots.count) % recordingShots.count
        shot = recordingShots[j]
        load(recordingShots[j])
    }

    /// shots/NNN.wav — where a capture's voice note lives (a kept re-record ends up there too).
    private func canonicalVoice(_ s: Shot) -> String { s.voice ?? "shots/\(ShotBatch.name(s.n)).wav" }
    /// this edit's re-record (shots/NNN.retake.wav)
    private var retakeURL: URL? {
        guard mode == .edit, let s = shot, let rel = takeRel else { return nil }
        return s.batch?.dir.appendingPathComponent(rel)
    }
    /// What the play button plays: a kept re-record (what saving keeps), else the note as it is.
    private var playURL: URL? { retakeKept ? retakeURL : shot?.voiceURL }

    private func play() {
        guard let u = playURL else { return }
        player = try? AVAudioPlayer(contentsOf: u)
        player?.play()
    }

    // MARK: tests (BLURT_TEST_COMMANDS: SnapApp's "notetype" / "notekey" / "noteheard" / "noteink" / "notestall" / "notestate")

    /// BLURT_TEST_NOTE_KEEP_KEY=1 (test commands only): losing the key doesn't save the bubble.
    static let testIgnoresResign: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["BLURT_TEST_COMMANDS"] == "1" && env["BLURT_TEST_NOTE_KEEP_KEY"] == "1"
    }()

    /// BLURT_TEST_NOTE_NO_KEY=1 (test commands only): the bubble never takes the keyboard — scripted checks on a Mac
    /// someone is using never catch their typing (the test commands type and press keys through the panel itself).
    static let testNoKey: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["BLURT_TEST_COMMANDS"] == "1" && env["BLURT_TEST_NOTE_NO_KEY"] == "1"
    }()

    /// Typing into the field, as the field editor would.
    func testType(_ text: String) {
        guard isOpen else { return }
        if let ed = field.currentEditor() { ed.insertText(text) } else { field.stringValue += text }
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    /// Emptying the field (⌘A ⌫), as the field editor would.
    func testClear() {
        guard isOpen else { return }
        if let ed = field.currentEditor() as? NSTextView { ed.selectAll(nil); ed.deleteBackward(nil) } else { field.stringValue = "" }
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    /// A real key event through the bubble's panel — `esc` | `return` | `shift-return` | `tab`: the same path a key
    /// press takes.
    func testKey(_ name: String) {
        guard let p = panel, isOpen else { return }
        let (code, chars, mods): (Int, String, NSEvent.ModifierFlags) = {
            switch name {
            case "esc": return (kVK_Escape, "\u{1B}", [])
            case "tab": return (kVK_Tab, "\t", [])
            case "shift-return": return (kVK_Return, "\r", [.shift])
            default: return (kVK_Return, "\r", [])
            }
        }()
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: p.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                       isARepeat: false, keyCode: UInt16(code)) else { return }
        p.sendEvent(e)
    }

    /// The words heard so far while it listens (test commands only): as the live stream shows them, grey in the
    /// field's place — `noteheard TEXT` (a "|" splits the final part from the part still being said).
    func testHeard(_ text: String) {
        guard isOpen, mode == .listen, voice?.running == true else { return }
        let parts = text.components(separatedBy: "|")
        heard = (parts[0], parts.count > 1 ? parts[1] : "")
        speechStarted = true
        refreshStatus()
        layout()
    }

    /// A click into the note's field through the panel (down, with its up queued first so the field editor's tracking
    /// loop ends at once): the same path a click takes — after the last word, where a fix usually starts.
    func testClickField() {
        guard let p = panel, isOpen else { return }
        let at = bg.convert(NSPoint(x: field.frame.maxX - 3, y: field.frame.maxY - 9), to: nil)
        func ev(_ t: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: p.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: t == .leftMouseDown ? 1 : 0)
        }
        guard let down = ev(.leftMouseDown), let up = ev(.leftMouseUp) else { return }
        p.postEvent(up, atStart: false)
        p.sendEvent(down)
    }

    /// A stroke on the picture through the pen's own mouse handlers — the frozen picture's in place, else the bubble's:
    /// `down` | `move` | `up` (normalised x,y), with `mods` held ("shift", "option").
    func testInk(_ phase: String, x: Double, y: Double, mods: NSEvent.ModifierFlags = []) {
        let c = ink
        guard isOpen, let w = c.window, c.editable else { return }
        let local = NSPoint(x: c.bounds.width * x, y: c.bounds.height * y)
        let inWin = c.convert(local, to: nil)
        let type: NSEvent.EventType = phase == "down" ? .leftMouseDown : phase == "up" ? .leftMouseUp : .leftMouseDragged
        guard let e = NSEvent.mouseEvent(with: type, location: inWin, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        switch phase {
        case "down": c.mouseDown(with: e)
        case "up": c.mouseUp(with: e)
        default: c.mouseDragged(with: e)
        }
    }

    /// A click on the undo button by the bin (in place), when it shows.
    func testUndoButton() {
        guard isOpen, let b = undoBtn, !b.isHidden else { emit(["event": "note_undo_button", "shown": false]); return }
        b.performClick(nil)
        emit(["event": "note_undo_button", "shown": true, "strokes": ink.strokes.count])
    }

    /// ⌘Z through the panel, as the key press arrives.
    func testUndo() {
        guard let p = panel, isOpen,
              let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: p.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z",
                                       isARepeat: false, keyCode: UInt16(kVK_ANSI_Z)) else { return }
        p.sendEvent(e)
    }

    /// The chip: `open` | `close` | `type TEXT` (into its filter) | `down` | `up` | `return` | `pick ID|inbox`.
    func testChip(_ arg: String) {
        let a = arg.split(separator: " ", maxSplits: 1).map(String.init)
        switch a.first ?? "" {
        case "open": openPick()
        case "close": closePick()
        case "type":
            // through the field editor, as keys arrive: a caret after the letters, never a selection over them
            let q = a.count > 1 ? a[1] : ""
            if let ed = pick.filter.currentEditor() as? NSTextView {
                ed.selectAll(nil); ed.insertText(q, replacementRange: ed.selectedRange())
            } else { pick.filter.stringValue = q }
            pick.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: pick.filter))
        case "hover": chip.testHover(true)
        case "unhover": chip.testHover(false)
        case "down": _ = pick.control(pick.filter, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))
        case "up": _ = pick.control(pick.filter, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveUp(_:)))
        case "return": pick.pick()
        case "pick":
            let id = a.count > 1 ? a[1] : "inbox"         // inbox (or the older "card"): Unassigned
            picked(id == "inbox" || id == "card" ? nil : ProjectStore.shared.project(id: id))
        default: break
        }
        emit(["event": "note_chip_state", "open": picking, "rows": pick.rows.map { $0?.id ?? "inbox" }, "selected": pick.selected,
              "chip": chip?.title ?? "", "project": shot?.project ?? NSNull()])
    }

    /// The pointer on the bubble or off it, as its tracking area tells (the hover tools show).
    func testHover(_ on: Bool) {
        hover(on)
        emit(["event": "note_hover", "on": hovering, "discard": !(discardBtn?.isHidden ?? true), "undo": !(undoBtn?.isHidden ?? true),
              "tools": hoverTools.filter { !$0.isHidden }.map { $0.toolTip ?? "" }])
    }

    /// The bubble's microphone states, for the shots of each (test commands only): `busy` (a ⌥V voice note has the
    /// mic), `gone` (it went before anything was said), `off` (it never started) — as their own paths leave them.
    func testMic(_ what: String) {
        guard isOpen, mode == .listen else { return }
        voice?.stop(keep: false)
        voice = nil
        dropStream()
        switch what {
        case "busy": voiceBusy = true
        case "gone": micGone = true; voiceDone = true
        default: voiceDone = false
        }
        refreshStatus()
        layout()
        emit(["event": "note_mic", "state": what, "placeholder": field.placeholderAttributedString?.string ?? field.placeholderString ?? ""])
    }

    /// The mic stopped after speech and the final words came in (test commands only): grey, waiting for ↩ or Tab — or,
    /// taken with Tab already, in the field — as wordsIn shows them.
    func testWords(_ said: String) {
        guard isOpen, mode == .listen else { return }
        voice?.stop(keep: true)
        voice = nil
        voiceKept = true
        speechStarted = true
        voiceDone = true
        dropStream()
        shot?.said = CardNote.clean(said)          // (as Snapper.fetchWords leaves it)
        wordsIn(said)
    }

    /// The microphone stops delivering mid-note (a headset gone): the watchdog ends the note.
    func testStall() { voice?.testStall() }

    /// What the bubble shows now (scripted checks).
    var testState: [String: Any] {
        ["open": isOpen, "visible": panel?.isVisible == true, "alpha": Double(panel?.alphaValue ?? 0), "mode": "\(mode)",
         "field": field.stringValue, "placeholder": field.placeholderAttributedString?.string ?? field.placeholderString ?? "",
         "status": status.stringValue, "listening": isListening, "typed": typed, "words_in_field": wordsInField ?? NSNull(),
         "voice_busy": voiceBusy, "strokes": ink.strokes.count, "drawing": ink.isDrawing, "generation": generation,
         "in_place": staged, "dock": dockSide?.rawValue ?? NSNull(), "chip": chip?.title ?? "", "picking": picking, "undo_button": undoBtn.map { !$0.isHidden } ?? false,
         "project": shot?.project ?? NSNull(), "frame": panel.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? [],
         "voice_done": voiceDone, "waiting_words": waitingWords, "voice_kept": voiceKept, "taken": accepted,
         "heard": heard.committed + heard.pending, "keys": "\(keyState.voice)", "mic_gone": micGone,
         "recording_paused": island.rec.map { $0.isPaused as Any } ?? NSNull(), "resume_on_close": recordingResume as Any? ?? NSNull()]
    }

    // MARK: close

    /// Save what's there (↩, Done, ⌥A again, a click outside the picture, another app taking over) — the grey words as
    /// they are. A spoken note shows "Saved" for a moment; a typed one (or the words taken with Tab) just goes.
    func commit() { if isOpen { close(save: true, flash: voice?.running == true || (voiceKept && !accepted && !typed)) } }

    /// Blurt is quitting: saved now, no "Saved" moment.
    func commitNow() { if isOpen { close(save: true, flash: false) } }

    /// Esc on a shot with nothing typed, the bin: a fresh shot is discarded (with Undo); an edit puts things back.
    func cancel() { if isOpen { close(save: false, flash: false) } }

    private func saveText(_ s: Shot) {
        let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        s.text = t.isEmpty ? nil : t
        s.batch?.save(s)
    }

    private func close(save: Bool, flash: Bool) {
        guard let s = shot else { return }
        showWork?.cancel()
        resignWork?.cancel()
        ticker?.invalidate()
        player?.stop()
        ink.flush()                             // a stroke still being drawn is part of the note
        if picking { picking = false; pick.isHidden = true }
        // (the chip beside it already says where it goes)
        let savedLine = Loc.t("capture.note.saved", table: "Capture")
        // Esc on a fresh shot discards it; what was said, typed and drawn goes with it, and comes back with Undo
        let discard = !save && mode == .listen
        let rel = takeRel ?? canonicalVoice(s)
        // typed over the words heard (a fresh shot only: in an edit the text was there before the re-record; the words
        // taken with Tab are not typing)
        let hadTyping = mode == .listen && !accepted && wordsInField == nil && typed
            && !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let v = voice {
            // kept: something was said (words seen count) — unless the note was typed over it: typing replaces the words
            let said = speechStarted || !(heard.committed + heard.pending).isEmpty
            let keep = (save || discard) && said && !hadTyping
            emit(["event": "note_voice_close", "n": s.n, "kept": keep, "speech": (v.speechSeconds * 100).rounded() / 100, "typed": hadTyping])
            v.stop(keep: keep)                  // (an edit's retake: not kept = only the retake goes)
            if mode == .edit {
                if keep { retakeKept = true; retakeSeconds = v.elapsed }
            } else if keep {
                s.voice = rel
                s.said = nil
                if let st = stream { snapper.attach(st, to: s) }    // its words are mostly in already
                stream = nil
            } else if s.voice == rel { s.voice = nil; s.said = nil }
            voice = nil
        } else if voiceKept, hadTyping, save || discard {
            // the mic had stopped (typing over the words stopped it, or it ended by itself), and the note was typed:
            // the text replaces the words, the recording goes
            if let u = s.voiceURL { try? FileManager.default.removeItem(at: u) }
            snapper.forgetWords(s)
            s.voice = nil
            s.said = nil
            emit(["event": "note_voice_close", "n": s.n, "kept": false, "typed": true])
        }
        dropStream()
        if save, mode == .edit, let o = original {
            var retaken = false
            if retakeKept, let u = retakeURL, let dir = s.batch?.dir {
                // the re-record takes the original's place; its words are to come
                let target = canonicalVoice(s)
                let ok = VoiceRetake.commit(u, over: dir.appendingPathComponent(target))
                emit(["event": "note_retake", "n": s.n, "kept": ok])
                if ok {
                    retaken = true
                    s.voice = target
                    s.transcription = .idle
                    if s.kind == .voice { s.duration = retakeSeconds }
                }
            }
            // the field held the whole note: an edit of spoken words replaces them (NoteEdit)
            let note = NoteEdit.apply(openedTyped: o.text, openedSaid: o.said, currentSaid: s.said, field: field.stringValue,
                                      fieldHoldsSaid: fieldHoldsSaid, retaken: retaken)
            s.text = note.typed
            s.said = note.said
            if retaken { snapper.voiceReplaced(s) }     // words still coming for the old take are not the new take's
            applyInk(s)
            s.batch?.save(s)
        } else if save || discard, let w = wordsInField {
            // the words taken with Tab were in the field: an edit of them replaces them (an emptied field keeps them).
            // Committed before their final words came, the field is the note as it stands: those words are dropped.
            if s.said == nil, s.voice != nil { snapper.forgetWords(s) }
            let note = NoteEdit.apply(openedTyped: nil, openedSaid: w, currentSaid: s.said ?? w, field: field.stringValue,
                                      fieldHoldsSaid: true, retaken: false)
            if s.voice == nil {
                // (no recording behind them any more: the words are typed text)
                s.text = CardNote.clean(field.stringValue) ?? w
                s.said = nil
            } else {
                s.text = note.typed
                s.said = note.said
            }
            if mode != .recording { applyInk(s) }
            s.batch?.save(s)
        } else if save || discard {
            let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            s.text = t.isEmpty ? nil : t
            if mode != .recording { applyInk(s) }
            s.batch?.save(s)
        } else if mode == .edit, let o = original {
            // Esc: as it was — a re-record goes, the note it would have replaced was never touched
            if let u = retakeURL { VoiceRetake.discard(u) }
            emit(["event": "note_edit_cancel", "n": s.n, "retake": retakeKept])
            s.text = o.text; s.voice = o.voice; s.said = o.said; s.strokes = o.strokes
        } else if mode == .recording {
            // Esc = resume without saving the edit in the field
        }
        shot = nil
        VoiceInput.shared.yieldEsc(false)
        if let sel = dock {
            // in place: the marked picture flies from the selection up to the notch and becomes the card (discarded:
            // the stage just fades)
            dock = nil
            InkStage.shared.close(flying: !discard)
            if !discard {
                // the marked picture as it is on the screen (full size: it starts at the selection's size)
                let img = s.markedURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? loadCGImage($0) : nil } ?? s.image()
                hanging.catchCapture(s, from: sel, image: img)
            }
        }
        if mode != .recording {
            hanging.update(s)
            if heldCards { hanging.hold(false); heldCards = false }
            if discard { snapper.discard(s) } else { snapper.settled(s) }
            // Edit Note: a place picked in its chip's list — the card goes there now (Move To's own path)
            if save, mode == .edit, editPicked, let id = editProject, id != s.project, s.isCard { snapper.assign([s], to: id) }
        }
        let p = panel
        let g = generation
        let cb = onClose
        onClose = nil
        // only the newest open may hide the panel and hand the focus back (a bubble opened meanwhile owns them)
        let done = { [weak self] in
            if self?.generation == g, self?.isOpen == false {
                p?.orderOut(nil)
                snapper.restoreFocus()
            }
            cb?()
        }
        if flash, let p = p {
            // the moment it is saved: no "Listening…" next to it, no bars still standing
            bars.isHidden = true
            icon.isHidden = false
            plainPlaceholder("")
            if !(heard.committed + heard.pending).isEmpty || wordsInField != nil { livePlaceholder("") }
            icon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
            // "Saved": the check in the brand's ok colour, the line secondary — short, as the user pressed ⏎ and is going on
            icon.contentTintColor = BrandColor.ok
            status.attributedStringValue = NoteBubble.keyLine(savedLine, alignment: .right)
            let w = DispatchWorkItem { [weak self] in
                guard let self = self, self.generation == g else { return }
                self.fadeOut(p, generation: g, then: done)
            }
            closeWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
        } else if let p = p {
            fadeOut(p, generation: g, then: done)
        } else { done() }
    }

    private func fadeOut(_ p: NSPanel, generation g: Int, then: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.16
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // a bubble opened meanwhile brought the alpha back up: leave it as it is
            if self?.generation != g { p.alphaValue = 1 }
            then()
        })
    }

    /// Strokes changed → (re)write NNN.marked.png, or drop it when the ink was undone.
    private func applyInk(_ s: Shot) {
        let strokes = ink.strokes
        guard strokes != s.strokes || (s.marked == nil && !strokes.isEmpty) else { return }
        s.strokes = strokes
        guard let dir = s.batch?.dir else { return }
        let rel = "shots/\(ShotBatch.name(s.n)).marked.png"
        let url = dir.appendingPathComponent(rel)
        if strokes.isEmpty {
            try? FileManager.default.removeItem(at: url)
            s.marked = nil
            s.markedThumb = nil
            return
        }
        guard let img = s.image() else { return }
        // the line as wide in the picture as it was drawn (in place: the display's width at the picture's scale)
        let lw = ink.lineWidth * CGFloat(img.width) / max(1, ink.bounds.width)
        guard let m = renderMarked(img, strokes: strokes, lineWidthPx: lw), let d = pngData(m, scale: s.scale) else { return }
        try? d.write(to: url)
        s.marked = rel
        s.markedThumb = thumbnail(m, maxPixels: 520)
    }
}
