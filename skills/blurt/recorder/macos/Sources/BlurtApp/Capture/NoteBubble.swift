// The note bubble under a fresh shot: "Say it or type…", the words as they are heard, and where it will go.
//
//  • listens right away (the user usually starts talking as they let go of the mouse); ~1.8 s of silence after
//    speech ends the note, 8 s without speech = no note, 60 s max. Audio → shots/NNN.wav (16 kHz mono). "Silence" is
//    relative to the room (BlurtCore NoteEndpointer: an adaptive noise floor — v0.7's floor froze at the mic's quiet
//    first moments, so a normal room never counted as silence and the note never ended). Since v0.8.6 the voice note
//    (⌥⇧V) ends when you say so; this one keeps ending on the pause — it is a sentence about one picture.
//  • the words while they are said (v0.9): the voice note's live text (VoiceNoteStream, interim decodes about once a
//    second) in the field's place, secondary, the part still being said quieter. When the pause ends it, the final
//    words go into the field in label colour with "✓ Saved · Goes to …" for `savedSeconds` (at most `wordsWait` for
//    them), then it tucks away — not while the pointer is over it (NoteHold.hovering); a click into the words or a key
//    that moves the caret pins it open until ⏎ / Esc (the user is fixing a word), and a change to them is an edit
//    (NoteEdit: it replaces them). The stream goes to Snapper, so the card has its words as it lands, not
//    "Transcribing…". ⏎ shows the same "Saved" (the check in BrandColor.ok, the line secondary), only shorter.
//  • it closes by itself only when BlurtCore NoteHold says so: never under the pen (a stroke being drawn holds the
//    pause end too: NoteEndpointer.activity), not within `inkGrace` (1.5 s) of the last stroke, never while typed text
//    waits for ⏎, never with ink or a frozen picture and nothing said (then: ⏎, Done, or a click outside it),
//    `emptiedGrace` after the text was cleared. A stroke still being drawn when it closes (⏎, ⌥⇧A) is kept.
//  • typing before speaking switches to a text note (the mic stops). Typing after speaking keeps listening until the
//    pause; if less than 1 s of it was talking, the recording was abandoned for typing and is dropped (no mic mark,
//    nothing to transcribe). A kept recording is always transcribed (Snapper.settled), also next to typed text. Only
//    committed text counts as typing (NoteTyping: not an IME composition; an emptied field is voice mode again).
//  • ⏎ (or ✓) keeps the shot — with the note, or without one (with a project it is filed all the same, "Goes to …";
//    in Auto it hangs as a card). Esc (BlurtCore NoteEsc): typed text first; then the shot is discarded — Trash,
//    "Discarded · Undo" for 5 s. Gone to another app: saved `resignSeconds` later, or as soon as it is done listening
//    and has its words after that (it never floats over every app waiting for ⏎).
//  • a ⌥⇧V voice note listening already: this bubble is typed only (no second listener), and the voice note's Esc
//    hotkey is the bubble's while it is open (VoiceInput.yieldEsc).
//  • the microphone gone mid-note (NoteVoice's watchdog, the engine's configuration change): it ends with what it has;
//    gone before anything was said, the bubble stays, typed only: "Mic disconnected · type a note". A mic that
//    doesn't start logs note_voice_start_failed with the reason (NoteVoice.failReason).
//  • in place (v0.9-next): a fresh snap's picture stays frozen where it was taken and the pen is on it (InkStage); the
//    bubble docks beside it (BlurtCore BubbleDock: never over it, flipped near the screen's edges, the selection's
//    display), its caret pointing at it. A plain drag draws, ⇧ a box, ⌥ an ellipse, holding still snaps a rough shape
//    clean, ⌘Z (or the undo button by the bin, shown while there are strokes) takes the last stroke back
//    (InkView.swift); the status line says "⏎ done", the button's word. Done (⏎, the Done button, a click outside): the
//    marked picture flies from the selection to the notch and becomes the card. The ink is burnt into
//    shots/NNN.marked.png (what a copy or a drag hands out); shots/NNN.png stays unmarked, the strokes stay editable.
//  • the "Goes to X" chip (ProjectChip.swift): a click, or Tab from the field, lists the recent projects in the bubble;
//    typing filters, ↩ picks — this capture goes there instead (Snapper.retarget), the island's project stays. While
//    the list is open the bubble never closes (NoteHold.picking, apart from `pinned`: closing it keeps the words pinned).
//  • ⌥⇧A while it is open saves the note and takes the next shot. Listening starts the warm speech server
//    (VoiceInput.warmSpeechModel), so the note's words come back in well under a second, not a cold model load.
//  • every open has a generation: a close still fading out never orders out (or takes the focus from) a bubble opened
//    after it — Edit Note on another card, a snap right after a saved note (v0.9: it vanished while still open).
// "Edit Note…" on a card (mode .edit) opens the same panel with the whole note as editable text — typed, then said —
// and the unmarked picture enlarged with its strokes, editable with the same pen (and ⌘Z) —
// so words heard wrong can be fixed (BlurtCore NoteEdit: an edited spoken note replaces its words). A voice card
// has no picture: the bubble is text only. The mic re-records: the new take goes to shots/NNN.retake.wav
// (VoiceRetake) and replaces the original only when it is kept; Esc, or no speech, leaves the original untouched.
// While it records, the field holds only what was typed (the take brings new words); a take not kept puts the words
// said back, and they stay. A kept take's words are fresh: words still coming for the old take are dropped
// (Snapper.voiceReplaced). Retakes left behind by a quit are swept when the cards come back (Snapper.restore).
// The same panel, text-only, is the note popover for snaps taken while recording (the island's snap button,
// the recording pauses while it is open).
//
// Tests: BLURT_NOTE_WAV=<file.wav> feeds that file through the same path instead of the microphone; test commands
// notetype / noteclear / notekey / noteink / notestall / notestate drive and read it (SnapApp).

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
        island.toast(Loc.t("capture.voice.mic_denied", table: "Capture"), actionTitle: Loc.t("capture.voice.mic_settings", table: "Capture")) {
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
        if let wav = inject ?? ProcessInfo.processInfo.environment["BLURT_NOTE_WAV"] {
            running = true                  // the feed checks it as it begins
            running = startInjected(URL(fileURLWithPath: wav))
            if !running { failReason = "inject_unreadable" }
            ready(running)
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
                // the input device changed under a running note (AirPods out of the ear, a headset unplugged): macOS
                // stops the engine — the note ends with what it has rather than listening to nothing
                self.configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e,
                                                                             queue: .main) { [weak self] _ in
                    self?.engineLost = true
                    self?.lost("config_change")
                }
                ready(true)
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

final class LevelBars: NSView {
    var level: Float = 0 { didSet { needsDisplay = true } }
    var active = true { didSet { needsDisplay = true } }
    private var phase: CGFloat = 0
    override func draw(_ dirty: NSRect) {
        phase += 0.6
        let n = 5, w: CGFloat = 3, gap: CGFloat = 2.5
        let x0 = (bounds.width - CGFloat(n) * w - CGFloat(n - 1) * gap) / 2
        for i in 0..<n {
            let wob = (sin(phase + CGFloat(i) * 1.3) + 1) / 2
            let h = active ? 4 + (bounds.height - 6) * CGFloat(level) * (0.55 + 0.45 * wob) : 4
            let r = NSRect(x: x0 + CGFloat(i) * (w + gap), y: (bounds.height - h) / 2, width: w, height: h)
            (active ? BrandColor.ink : NSColor.tertiaryLabelColor).setFill()      // listening (the bubble is light or dark)
            NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

final class SymbolButton: NSButton {
    var onClick: (() -> Void)?
    convenience init(_ symbol: String, tip: String, size: CGFloat = 26, _ click: @escaping () -> Void) {
        self.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
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
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Key-able, but doesn't activate the app: typing works, the app the user was in stays in front.
final class NotePanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    /// every click in the bubble, before it reaches the view under it (the field's editor swallows its own)
    var onMouseDown: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { true }
    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown, onKey?(e) == true { return }
        if e.type == .leftMouseDown { onMouseDown?(e) }
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

    func shape() -> NSBezierPath {
        let c = BubbleBackground.caret, i = insets
        let body = NSRect(x: 0.5 + i.left, y: 0.5 + i.top, width: bounds.width - 1 - i.left - i.right,
                          height: bounds.height - 1 - i.top - i.bottom)
        let p = NSBezierPath(roundedRect: body, xRadius: 14, yRadius: 14)
        let t = NSBezierPath()
        let x = min(max(caretAt, 26), bounds.width - 26), y = min(max(caretAt, 24), bounds.height - 24)
        switch caret {
        case .up:
            t.move(to: NSPoint(x: x - c - 2, y: c + 0.5)); t.line(to: NSPoint(x: x, y: 0.5)); t.line(to: NSPoint(x: x + c + 2, y: c + 0.5))
        case .down:
            t.move(to: NSPoint(x: x - c - 2, y: bounds.height - c - 0.5)); t.line(to: NSPoint(x: x, y: bounds.height - 0.5))
            t.line(to: NSPoint(x: x + c + 2, y: bounds.height - c - 0.5))
        case .left:
            t.move(to: NSPoint(x: c + 0.5, y: y - c - 2)); t.line(to: NSPoint(x: 0.5, y: y)); t.line(to: NSPoint(x: c + 0.5, y: y + c + 2))
        case .right:
            t.move(to: NSPoint(x: bounds.width - c - 0.5, y: y - c - 2)); t.line(to: NSPoint(x: bounds.width - 0.5, y: y))
            t.line(to: NSPoint(x: bounds.width - c - 0.5, y: y + c + 2))
        case .none:
            return p
        }
        t.close()
        p.append(t)
        return p
    }

    /// The card and its caret only: the window's own shadow (NotePanel.hasShadow) follows that shape. (v0.9: a shadow
    /// drawn here was cut off at the window's edge — a grey rectangle behind the rounded card.)
    override func draw(_ dirty: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let p = shape()
        (dark ? NSColor(calibratedWhite: 0.17, alpha: 0.98) : NSColor(calibratedWhite: 0.995, alpha: 0.98)).setFill()
        p.fill()
        (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.10)).setStroke()
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
    private var bars = LevelBars(frame: NSRect(x: 0, y: 0, width: 26, height: 22))
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
    /// the words while they are said (VoiceNoteStream, the ⌥⇧V voice note's live text): shown in the field's place
    private var stream: VoiceNoteStream?
    private var heard = (committed: "", pending: "")
    /// committed text in the field (BlurtCore NoteTyping: not an IME composition, not just spaces)
    private var typed = false
    private var speechStarted = false
    private var voiceKept = false
    /// how much of the kept recording was talking
    private var voiceSpeech: Double = 0
    /// Typed, and said less than this: the voice was abandoned for typing (a word, a cough, the keyboard) — dropped.
    static let abandonedSpeech = 1.0
    /// When the bubble may close by itself (BlurtCore NoteHold): never under the pen, never with typed text.
    private var hold = NoteHold()
    private var holdWork: DispatchWorkItem?
    /// the words said are in the field (the "Saved" moment): an edit of them replaces them, like Edit Note (NoteEdit)
    private var wordsInField: String?
    /// "Saved" shows the words this long before the bubble tucks away
    static let savedSeconds = 1.2
    /// …and waits for them at most this long (else it closes, and the card gets them when they come)
    static let wordsWait = 2.5
    /// a ⌥⇧V voice note has the microphone: this bubble takes typing only (no second listener)
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
        holdWork?.cancel()
        resignWork?.cancel()
        shot = s
        mode = m
        anchor = a ?? { hanging.screenRect(of: s) ?? island.frameOnScreen }
        typed = false
        speechStarted = false
        voiceKept = false
        voiceSpeech = 0
        takeRel = nil
        retakeKept = false
        retakeSeconds = 0
        fieldHoldsSaid = true
        wordsInField = nil
        heard = ("", "")
        hold = NoteHold()
        voiceBusy = false
        micGone = false
        // the pen hint, the first few times only (InkHint; the stage counts them)
        penHintGone = !InkHint.shows(alreadyShown: recordConfig()["ink_hint_shown"] as? Int ?? 0)
        penHint.alphaValue = 1
        inkUndoFirst = false
        picking = false
        dock = m == .listen && InkStage.shared.shot === s ? inPlace : nil
        dockSide = nil
        original = (s.text, s.voice, s.said, s.strokes)
        build()
        if staged {
            let st = InkStage.shared
            st.canvas.onChange = { [weak self] in self?.inkChanged() }
            st.canvas.onStrokeBegan = { [weak self] in self?.strokeBegan() }
            st.canvas.onStrokeMoved = { [weak self] in self?.voice?.activity(grace: NoteHold.inkGrace) }
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
        p.onMouseDown = { [weak self] e in self?.pointerDown(e) }
        let root = bg
        p.contentView = root
        canvas.onChange = { [weak self] in self?.inkChanged() }
        canvas.onStrokeBegan = { [weak self] in self?.strokeBegan() }
        canvas.onStrokeMoved = { [weak self] in self?.voice?.activity(grace: NoteHold.inkGrace) }
        canvas.onStrokeEnded = { [weak self] in self?.strokeEnded() }
        root.addSubview(canvas)
        penHint.font = .systemFont(ofSize: 11, weight: .semibold)
        penHint.textColor = .white
        penHint.wantsLayer = true
        penHint.drawsBackground = true
        penHint.backgroundColor = NSColor(white: 0.08, alpha: 0.78)     // readable on a light screenshot too
        penHint.layer?.cornerRadius = 9
        penHint.alignment = .center
        root.addSubview(penHint)
        undoBtn = SymbolButton("arrow.uturn.backward", tip: Loc.t("capture.note.undo", table: "Capture")) { [weak self] in self?.undoInk() }
        root.addSubview(undoBtn)
        chip = ProjectChip { [weak self] in self?.togglePick() }
        root.addSubview(chip)
        pick.isHidden = true
        pick.onPick = { [weak self] p in self?.picked(p) }
        pick.onCancel = { [weak self] in self?.closePick() }
        pick.onFilterChange = { [weak self] in self?.layout() }
        root.addSubview(pick)
        doneBtn = BrandButton(title: Loc.t("capture.note.done", table: "Capture"), target: self, action: #selector(doneClicked))
        doneBtn.fontSize = 12
        doneBtn.hPad = 11
        doneBtn.toolTip = Loc.t("capture.note.done_tip", table: "Capture")
        root.addSubview(doneBtn)
        icon.imageScaling = .scaleProportionallyDown
        root.addSubview(icon)
        root.addSubview(bars)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.delegate = self
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        root.addSubview(field)
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        root.addSubview(status)
        micBtn = SymbolButton("mic.fill", tip: Loc.t("capture.note.rerecord", table: "Capture")) { [weak self] in self?.rerecord() }
        playBtn = SymbolButton("play.fill", tip: Loc.t("capture.note.play", table: "Capture")) { [weak self] in self?.play() }
        prevBtn = SymbolButton("chevron.left", tip: Loc.t("capture.note.prev", table: "Capture")) { [weak self] in self?.step(-1) }
        nextBtn = SymbolButton("chevron.right", tip: Loc.t("capture.note.next", table: "Capture")) { [weak self] in self?.step(1) }
        keepBtn = SymbolButton("checkmark.circle.fill", tip: Loc.t("capture.note.keep_tip", table: "Capture")) { [weak self] in self?.commit() }
        keepBtn.contentTintColor = BrandColor.ink           // the bubble's primary: brand ink (light / dark / contrast)
        discardBtn = SymbolButton("trash", tip: Loc.t("capture.note.discard_tip", table: "Capture")) { [weak self] in self?.cancel() }
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

    private func layout() {
        let pic = showsPicture
        let pv = pic ? previewSize() : .zero
        let pad: CGFloat = 12
        let c = BubbleBackground.caret
        let ins = bg.insets
        let inner = max(mode == .recording ? 340 : staged ? 372 : 400, pv.width + pad * 2)
        let width = inner + ins.left + ins.right
        let x0 = ins.left, top = ins.top
        let fieldH = fieldHeight(inner - pad * 2 - 40, max: pic ? 90 : 220)
        let fresh = mode == .listen
        let pickH = picking ? pick.height + 4 : 0
        // (a caret up or down takes its height; one at the side, its width — the card keeps the same inner size)
        let height = (ins.top + ins.bottom > 0 ? c : 0) + pad + (pic ? pv.height + 10 : 0) + fieldH + 4 + (fresh ? 20 : 16) + pickH + pad
        panel?.setContentSize(NSSize(width: width, height: height))
        bg.frame = NSRect(x: 0, y: 0, width: width, height: height)
        canvas.isHidden = !pic
        canvas.frame = NSRect(x: x0 + (inner - pv.width) / 2, y: top + pad, width: pv.width, height: pv.height)
        penHint.stringValue = mode == .recording ? "" : "  " + Loc.t("capture.note.pen_hint", table: "Capture") + "  "
        penHint.sizeToFit()
        penHint.frame = NSRect(x: canvas.frame.minX + 8, y: canvas.frame.maxY - 26, width: penHint.frame.width, height: 18)
        penHint.isHidden = !pic || mode == .recording || !canvas.strokes.isEmpty || penHintGone
        undoBtn.frame.origin = NSPoint(x: canvas.frame.maxX - 32, y: canvas.frame.maxY - 32)
        undoBtn.isHidden = !pic || canvas.strokes.isEmpty
        undoBtn.wantsLayer = true
        undoBtn.layer?.backgroundColor = NSColor(white: 1, alpha: 0.85).cgColor
        undoBtn.layer?.cornerRadius = 13
        let rowY = pic ? canvas.frame.maxY + 10 : top + pad
        icon.frame = NSRect(x: x0 + pad + 2, y: rowY + 1, width: 22, height: 20)
        bars.frame = NSRect(x: x0 + pad, y: rowY, width: 26, height: 22)
        var bx = x0 + inner - pad - 26
        for b in [nextBtn, prevBtn, micBtn, playBtn, keepBtn, discardBtn] { b?.isHidden = true }
        doneBtn.isHidden = true
        var fieldRight = x0 + inner - pad - 6
        if fresh {
            // in place: Done (the one primary) and the bin on the field's row; else the check and the bin
            if staged {
                doneBtn.isHidden = false
                let sz = doneBtn.intrinsicContentSize
                doneBtn.frame = NSRect(x: x0 + inner - pad - sz.width, y: rowY - 1, width: sz.width, height: 22)
                bx = doneBtn.frame.minX - 26 - 2
                fieldRight = bx - 2
            } else {
                keepBtn.isHidden = false; keepBtn.frame.origin = NSPoint(x: bx, y: rowY + fieldH - 2); bx -= 26
            }
            discardBtn.isHidden = false
            discardBtn.frame.origin = staged ? NSPoint(x: bx, y: rowY - 3) : NSPoint(x: bx, y: rowY + fieldH - 2)
            bx -= 26
            // in place the picture is outside the bubble: its undo sits by the bin while there are strokes (⌘Z too)
            if staged, !ink.strokes.isEmpty {
                undoBtn.isHidden = false
                undoBtn.layer?.backgroundColor = nil
                undoBtn.frame.origin = NSPoint(x: bx, y: rowY - 3)
                bx -= 26
                fieldRight = bx - 2
            }
        }
        field.frame = NSRect(x: x0 + pad + 34, y: rowY + 1, width: fieldRight - (x0 + pad + 34), height: fieldH)
        let buttons: CGFloat = mode == .recording && recordingShots.count > 1 ? 56 : mode == .edit || (fresh && !staged) ? 56 : 0
        // a fresh shot: the chip leads the status row ("Goes to X ⌄"), the hint after it
        chip.isHidden = !fresh
        var statusX = x0 + pad + 34
        let statusY = rowY + fieldH + (fresh ? 6 : 4)
        if fresh {
            chip.set(destination, maxWidth: min(200, inner * 0.5))
            chip.frame.origin = NSPoint(x: x0 + pad + 32, y: statusY - 2)
            statusX = chip.frame.maxX + 8
        }
        status.frame = NSRect(x: statusX, y: statusY, width: x0 + inner - pad - buttons - statusX, height: 15)
        pick.isHidden = !picking
        if picking {
            pick.frame = NSRect(x: x0 + pad + 30, y: statusY + 20, width: inner - pad * 2 - 30, height: pick.height)
            pick.layoutRows()
        }
        if mode == .recording, recordingShots.count > 1 {
            nextBtn.isHidden = false; nextBtn.frame.origin = NSPoint(x: bx, y: rowY + fieldH); bx -= 26
            prevBtn.isHidden = false; prevBtn.frame.origin = NSPoint(x: bx, y: rowY + fieldH); bx -= 26
        }
        if mode == .edit {
            bx = x0 + inner - pad - 26
            micBtn.isHidden = false; micBtn.frame.origin = NSPoint(x: bx, y: rowY + fieldH - 2); bx -= 26
            if playURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
                playBtn.isHidden = false; playBtn.frame.origin = NSPoint(x: bx, y: rowY + fieldH - 2); bx -= 26
            }
        }
        position()
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
        p.makeKey()
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
        // a ⌥⇧V voice note is listening: it already hears what is said — this note is typed (one listener at a time)
        if VoiceInput.shared.active, mode == .listen {
            voiceBusy = true
            emit(["event": "note_voice_busy", "n": s.n])
            return refreshStatus()
        }
        // a re-record never writes over the note it replaces: it goes next to it until it is kept (VoiceRetake)
        let rel = mode == .edit ? VoiceRetake.path(for: canonicalVoice(s)) : canonicalVoice(s)
        takeRel = rel
        let v = NoteVoice(url: dir.appendingPathComponent(rel))
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
                emit(["event": "note_mic_gone", "n": self.shot?.n ?? 0])
                self.refreshStatus()
                return
            }
            if e == .noSpeech {
                self.retakeFell()
                self.dropStream()
            } else {
                self.voiceKept = true
                self.voiceSpeech = v.speechSeconds
                if self.mode == .edit {
                    self.retakeKept = true                   // it replaces the original when the edit is saved
                    self.retakeSeconds = v.elapsed
                } else {
                    self.shot?.voice = rel
                    self.shot?.said = nil                    // its words to come
                    self.wordsComing()
                }
                if e == .micLost { VoiceInput.say(.micLost) }
            }
            self.hold.voiceDone = true
            self.refreshStatus()
            self.maybeClose()
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

    /// The pause after speech ended a fresh shot's note: its words now (the stream's last piece, else the whole
    /// wav), shown in the field before the bubble tucks away — at most `wordsWait`, then the card gets them.
    private func wordsComing() {
        guard let s = shot, mode == .listen else { return }
        if let st = stream { snapper.attach(st, to: s) }
        stream = nil
        hold.waitingWords = true
        let g = generation
        snapper.fetchWords(s) { [weak self] said in
            guard let self = self, self.generation == g, self.shot === s else { return }
            self.wordsIn(said)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + NoteBubble.wordsWait) { [weak self] in
            guard let self = self, self.generation == g, self.hold.waitingWords else { return }
            emit(["event": "note_words_wait", "n": s.n, "timeout": true])
            self.hold.waitingWords = false
            self.maybeClose()
        }
    }

    /// The words of what was just said are in: they go into the field (label colour), with "Saved" — a click or a key
    /// in them is an edit (it replaces the words); left alone, the bubble tucks away after `savedSeconds`.
    private func wordsIn(_ said: String?) {
        hold.waitingWords = false
        if let w = CardNote.clean(said), !typed {
            wordsInField = w
            field.stringValue = w
            field.currentEditor()?.selectedRange = NSRange(location: (w as NSString).length, length: 0)
            hold.savedUntil = CACurrentMediaTime() + NoteBubble.savedSeconds
            emit(["event": "note_words_shown", "n": shot?.n ?? 0, "chars": w.count])
            // in place: the screen is given back now — only the picture and the bubble wait out the saved window
            if staged { InkStage.shared.lift() }
            layout()
        }
        refreshStatus()
        maybeClose()
    }

    private func dropStream() {
        stream?.cancel()
        stream = nil
        heard = ("", "")
    }

    /// Close by itself when NoteHold says so (now, or ask again later).
    private func maybeClose() {
        holdWork?.cancel()
        guard isOpen, mode != .recording else { return }
        hold.typed = typed
        hold.drawing = ink.isDrawing
        hold.inked = !ink.strokes.isEmpty
        hold.spoke = voiceKept
        hold.inPlace = staged
        hold.hovering = panel.map { $0.isVisible && $0.frame.contains(NSEvent.mouseLocation) } ?? false
        guard let wait = hold.closeIn(now: CACurrentMediaTime()) else { return }
        if wait > 0 {
            let w = DispatchWorkItem { [weak self] in self?.maybeClose() }
            holdWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: w)
            return
        }
        // the words were already shown with "Saved": no second flash
        close(save: true, flash: voiceKept && wordsInField == nil)
    }

    /// A click into the words shown with "Saved" (to fix one): the bubble stays until ⏎ or Esc (BlurtCore NoteHold).
    private func pointerDown(_ e: NSEvent) {
        guard e.window === panel, field.frame.insetBy(dx: -4, dy: -4).contains(bg.convert(e.locationInWindow, from: nil)) else { return }
        engageWords(via: "click")
    }

    /// The user is working on the words shown with "Saved" (a click into them, the caret moved): pinned open.
    private func engageWords(via: String) {
        guard wordsInField != nil, hold.savedUntil != nil, !hold.pinned else { return }
        hold.pinned = true
        hold.savedUntil = nil
        holdWork?.cancel()
        emit(["event": "note_words_engaged", "n": shot?.n ?? 0, "via": via])
    }

    private func strokeBegan() {
        voice?.activity(grace: NoteHold.inkGrace)
        hold.drawing = true
        holdWork?.cancel()
        fadePenHint(for: shot, after: 0)
        if staged { InkStage.shared.hideHint() }
    }

    private func strokeEnded() {
        inkUndoFirst = true
        hold.drawing = false
        hold.lastInk = CACurrentMediaTime()
        voice?.activity(grace: NoteHold.inkGrace)
        maybeClose()
    }

    private func resignedKey() {
        guard isOpen, mode != .recording else { return }
        emit(["event": "note_resign", "n": shot?.n ?? 0, "app_active": NSApp.isActive])
        // tests on a shared machine: another app coming forward isn't the tester leaving the bubble
        guard !NoteBubble.testIgnoresResign else { return }
        scheduleResignSave(after: NoteBubble.resignSeconds)
    }

    /// Saves the bubble once it isn't key and isn't listening or waiting for its words. Still listening (the user
    /// spoke, typed, then switched apps), it checks again until the voice is done — it never floats over every app.
    private func scheduleResignSave(after delay: Double) {
        resignWork?.cancel()
        let g = generation
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == g, self.isOpen, self.panel?.isKeyWindow != true else { return }
            if self.voice?.running == true || self.hold.waitingWords {
                return self.scheduleResignSave(after: 0.5)
            }
            emit(["event": "note_resign_commit", "n": self.shot?.n ?? 0])
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
        hold.voiceDone = false
        let keepTyped = typed
        startListening()
        typed = keepTyped
        refreshStatus()
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

    private func refreshStatus() {
        let listening = voice?.running == true
        bars.isHidden = !listening
        icon.isHidden = listening
        let saved = wordsInField != nil && !typed
        let quietDone = staged && hold.voiceDone && !micGone       // in place, nothing said: typing is what is left
        let sym = mode == .recording ? "note.text" : saved ? "checkmark" : (typed || mode == .edit || voiceBusy || quietDone ? "keyboard" : "mic.slash")
        icon.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        icon.contentTintColor = saved ? BrandColor.ok : .secondaryLabelColor
        status.textColor = .secondaryLabelColor
        switch mode {
        case .listen:
            // in place the one button says Done, so the line says "⏎ done" too (one name for one action); under the
            // notch it stays "⏎ save"
            // where it goes, in every state, is the chip before this line ("Goes to X ⌄"): with a project, straight
            // into it (with a note or without); Auto: a card
            let dest = ""
            // (in place the line is shorter: the chip and Done sit beside it)
            let next = staged ? "" : hkHint(.snap, "capture.note.next_hint").map { " · " + $0 } ?? ""
            chip?.set(destination, maxWidth: min(200, (panel?.frame.width ?? 400) * 0.5))
            if listening || (hold.voiceDone && voiceKept && wordsInField == nil) {
                livePlaceholder(Loc.t("capture.note.listening", table: "Capture"))
            } else {
                plainPlaceholder(Loc.t("capture.note.placeholder_optional", table: "Capture"))
            }
            if saved {
                // (the check is the row's icon: one mark, not two)
                status.stringValue = Loc.t("capture.note.saved", table: "Capture")
            } else if typed {
                let said = voiceKept ? Loc.t("capture.note.said", table: "Capture", fmt(voiceSpeech)) + " · " : ""
                status.stringValue = dest + said + Loc.t(staged ? "capture.note.done_clear" : "capture.note.save_clear", table: "Capture")
            } else if voiceBusy {
                status.stringValue = Loc.t(staged ? "capture.note.voice_busy_done" : "capture.note.voice_busy", table: "Capture")
            } else if listening && speechStarted {
                status.stringValue = fmt(voice?.elapsed ?? 0) + " · " + dest + Loc.t(staged ? "capture.note.listening_done" : "capture.note.listening_save", table: "Capture")
            } else if listening {
                status.stringValue = dest + Loc.t(staged ? "capture.note.done_discard" : "capture.note.keep_discard", table: "Capture") + next
            } else if hold.voiceDone && voiceKept {
                status.stringValue = dest + Loc.t(staged ? "capture.note.done_discard" : "capture.note.save_discard", table: "Capture")
            } else if staged && hold.voiceDone && !micGone {
                // in place, nothing said (the mic has stopped listening): it waits for ⏎, Done or a click outside
                status.stringValue = Loc.t("capture.note.done_discard", table: "Capture")
            } else {
                // every key written out whole (tests/test_l10n.py checks each one exists in both languages)
                let key = micGone ? (staged ? "capture.note.mic_gone_done" : "capture.note.mic_gone")
                                  : (staged ? "capture.note.no_mic_done" : "capture.note.no_mic")
                status.stringValue = dest + Loc.t(key, table: "Capture")
            }
        case .edit:
            plainPlaceholder(Loc.t("capture.note.placeholder", table: "Capture"))
            if listening { status.stringValue = fmt(voice?.elapsed ?? 0) + " · " + Loc.t("capture.note.recording_new", table: "Capture") }
            else { status.stringValue = Loc.t("capture.note.save_cancel", table: "Capture") }
        case .recording:
            let i = recordingShots.firstIndex(where: { $0 === shot }).map { $0 + 1 } ?? 1
            plainPlaceholder(Loc.t("capture.note.placeholder_shot", table: "Capture"))
            // the shot counter first: on a narrow bubble the hint's tail is what gets cut, not "2/2"
            status.stringValue = (recordingShots.count > 1 ? "\(i)/\(recordingShots.count)  ·  " : "")
                + Loc.t("capture.note.paused", table: "Capture")
        }
    }

    private func fmt(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    /// "Goes to ordo-platform" for a fresh snap taken with a current project; "Stays as a card" without one — what
    /// happens to it (it hangs under the notch until a project is picked), as the voice note's island line says it
    /// (v0.9-fix2: a bare "Unassigned ⌄" didn't read as where the snap goes). The list's row is still "Unassigned".
    private var destination: String {
        guard let pid = shot?.project, let p = ProjectStore.shared.project(id: pid) else {
            // the current project's folder is gone (MissingFolder): say why it stays a card
            if let m = ProjectStore.shared.missingCurrent { return Loc.t("capture.note.goes_missing", table: "Capture", m.name) }
            return Loc.t("capture.note.stays_card", table: "Capture")
        }
        return Loc.t("capture.note.goes_to", table: "Capture", p.name)
    }

    private func tick() {
        bars.needsDisplay = true
        if voice?.running == true && speechStarted { refreshStatus() }
        // the pen held still on the picture is still drawing: the pause doesn't end the note under it
        if ink.isDrawing { voice?.activity(grace: NoteHold.inkGrace) }
        // follow the card if the cards re-lay out (another capture arrived, a neighbour was removed); docked, it stays
        if let p = panel, p.isVisible, mode != .recording, !staged { position() }
    }

    // MARK: input

    func controlTextDidChange(_ n: Notification) {
        let marked = (field.currentEditor() as? NSTextView).flatMap { $0.hasMarkedText() ? $0.markedRange() : nil }
        var now = NoteTyping.typed(field.stringValue, marked: marked)
        // the words said, shown in the field: only a change to them is typing (an edit of the words)
        if let w = wordsInField, CardNote.clean(NoteTyping.committed(field.stringValue, marked: marked)) == w { now = false }
        if now && !typed, mode == .listen, let v = voice, !speechStarted {
            // typing before speaking: a text note — the mic stops (nothing was said)
            v.stop(keep: false)
            voice = nil
            dropStream()
            hold.voiceDone = true
        }
        if typed && !now { hold.emptiedAt = CACurrentMediaTime() }
        if now { hold.pinned = false; hold.savedUntil = nil }
        if field.stringValue != (wordsInField ?? "") { inkUndoFirst = false }
        typed = now
        refreshStatus()
        layout()
        maybeClose()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        // Tab: to the chip's list (where it goes), the keyboard's way to it
        if sel == #selector(NSResponder.insertTab(_:)), mode == .listen { openPick(); return true }
        if sel == #selector(NSResponder.insertNewline(_:)) { commit(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { escape(); return true }
        if sel == #selector(NSResponder.insertLineBreak(_:)) { textView.insertText("\n", replacementRange: textView.selectedRange()); return true }
        return false
    }

    private func key(_ e: NSEvent) -> Bool {
        // the chip's list is open: Esc goes back to the note (its field takes ↑ ↓ ↩)
        if picking, e.keyCode == UInt16(kVK_Escape) { closePick(); return true }
        if picking { return false }
        // (an IME composition takes its own Esc: it cancels the composition, not the note)
        if e.keyCode == UInt16(kVK_Escape), (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { escape(); return true }
        // a key in the words shown with "Saved" other than ⏎ (moving the caret to a word): they are being fixed
        if e.keyCode != UInt16(kVK_Return), e.keyCode != UInt16(kVK_ANSI_KeypadEnter) { engageWords(via: "key") }
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

    /// Esc (BlurtCore NoteEsc): on a fresh shot with typed text, the text goes first (the words said come back if
    /// they were being edited) and the bubble stays; the next Esc discards the shot, with Undo.
    private func escape() {
        guard isOpen else { return }
        let typedPart = wordsInField != nil && !typed ? "" : field.stringValue
        switch NoteEsc.action(fresh: mode == .listen, field: typedPart) {
        case .clearText:
            field.stringValue = wordsInField ?? ""
            typed = false
            hold.typed = false
            hold.pinned = true              // the next step is the user's: ⏎ keeps, Esc discards
            holdWork?.cancel()
            emit(["event": "note_esc", "n": shot?.n ?? 0, "action": "clear_text"])
            refreshStatus()
            layout()
        case .close:
            cancel()
        }
    }

    private func inkChanged() {
        layout()
    }

    private func undoInk() {
        guard ink.undo() else { return }
        if ink.strokes.isEmpty { inkUndoFirst = false }
        layout()
        maybeClose()
    }

    // MARK: the chip: where it goes

    @objc private func doneClicked() { commit() }

    private func togglePick() { picking ? closePick() : openPick() }

    private func openPick() {
        guard mode == .listen, let s = shot, !picking else { return }
        picking = true
        pick.current = s.project
        pick.filter.stringValue = ""
        pick.reload()
        pick.select(max(0, pick.rows.firstIndex { $0?.id == s.project && s.project != nil } ?? 0))
        hold.picking = true                      // choosing: it doesn't close by itself under the list
        holdWork?.cancel()
        layout()
        panel?.makeFirstResponder(pick.filter)
        emit(["event": "note_chip", "open": true, "n": s.n, "rows": pick.rows.map { $0?.id ?? "inbox" }])
    }

    private func closePick() {
        guard picking else { return }
        picking = false
        hold.picking = false                     // `pinned` (words being fixed, text just cleared) stays as it was
        layout()
        panel?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        emit(["event": "note_chip", "open": false, "n": shot?.n ?? 0])
        maybeClose()
    }

    private func picked(_ p: Project?) {
        guard let s = shot else { return }
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

    // MARK: tests (BLURT_TEST_COMMANDS: SnapApp's "notetype" / "notekey" / "noteink" / "notestall" / "notestate")

    /// BLURT_TEST_NOTE_KEEP_KEY=1 (test commands only): losing the key doesn't save the bubble.
    static let testIgnoresResign: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["BLURT_TEST_COMMANDS"] == "1" && env["BLURT_TEST_NOTE_KEEP_KEY"] == "1"
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

    /// A real key event through the bubble's panel (Esc = 53, Return = 36): the same path a key press takes.
    func testKey(_ code: UInt16) {
        guard let p = panel, isOpen else { return }
        let chars = code == 53 ? "\u{1B}" : "\r"
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: p.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                       isARepeat: false, keyCode: code) else { return }
        p.sendEvent(e)
    }

    /// A click into the note's field through the panel (down, with its up queued first so the field editor's tracking
    /// loop ends at once): the same path a click takes.
    func testClickField() {
        guard let p = panel, isOpen else { return }
        let at = bg.convert(NSPoint(x: field.frame.midX, y: field.frame.midY), to: nil)
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
            pick.filter.stringValue = a.count > 1 ? a[1] : ""
            pick.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: pick.filter))
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
         "hold": ["voice_done": hold.voiceDone, "waiting_words": hold.waitingWords, "pinned": hold.pinned, "picking": hold.picking,
                  "saved": hold.savedUntil != nil, "hovering": hold.hovering, "spoke": hold.spoke, "inked": hold.inked], "mic_gone": micGone,
         "recording_paused": island.rec.map { $0.isPaused as Any } ?? NSNull(), "resume_on_close": recordingResume as Any? ?? NSNull()]
    }

    // MARK: close

    /// Save what's there (⏎, ⌥⇧A again, the pause after speech).
    func commit() { if isOpen { close(save: true, flash: voice?.running == true || (voiceKept && wordsInField == nil)) } }

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
        holdWork?.cancel()
        resignWork?.cancel()
        ticker?.invalidate()
        player?.stop()
        ink.flush()                             // a stroke still being drawn is part of the note
        if picking { picking = false; pick.isHidden = true }
        let savedLine = Loc.t("capture.note.saved", table: "Capture") + (mode == .listen ? " · " + destination : "")
        // Esc on a fresh shot discards it; what was said, typed and drawn goes with it, and comes back with Undo
        let discard = !save && mode == .listen
        let rel = takeRel ?? canonicalVoice(s)
        // (a fresh shot only: in an edit the text was there before the re-record; the words said shown in the field
        // are not typing)
        let hadTyping = mode == .listen && wordsInField == nil && typed
            && !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let v = voice {
            // kept: something was said — unless the user went on to type and what was "said" was barely anything (a
            // word, a cough, the keyboard): then the voice was abandoned for typing, and it goes
            let keep = (save || discard) && speechStarted && !(hadTyping && v.speechSeconds < NoteBubble.abandonedSpeech)
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
        } else if voiceKept, hadTyping, voiceSpeech < NoteBubble.abandonedSpeech, save || discard {
            // it had ended by itself (a pause), then the user typed the note instead
            if let u = s.voiceURL { try? FileManager.default.removeItem(at: u) }
            snapper.forgetWords(s)
            s.voice = nil
            s.said = nil
            emit(["event": "note_voice_close", "n": s.n, "kept": false, "speech": (voiceSpeech * 100).rounded() / 100, "typed": true])
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
            // the words said were in the field: an edit of them replaces them (an emptied field keeps them)
            let note = NoteEdit.apply(openedTyped: nil, openedSaid: w, currentSaid: s.said, field: field.stringValue,
                                      fieldHoldsSaid: true, retaken: false)
            s.text = note.typed
            s.said = note.said
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
            icon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            // the same "Saved" as when the words are shown (wordsIn): the check in the brand's ok colour, the line
            // secondary — only shorter, as the user pressed ⏎ and is going on
            icon.contentTintColor = BrandColor.ok
            status.stringValue = savedLine
            status.textColor = .secondaryLabelColor
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
