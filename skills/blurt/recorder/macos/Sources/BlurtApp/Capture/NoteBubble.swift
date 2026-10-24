// The note bubble under a fresh shot: "Listening… just pause when you're done · or type", and where it will go.
//
//  • listens right away (the user usually starts talking as they let go of the mouse); ~1.8 s of silence after
//    speech ends the note, 8 s without speech = no note, 60 s max. Audio → shots/NNN.wav (16 kHz mono). "Silence" is
//    relative to the room (BlurtCore NoteEndpointer: an adaptive noise floor — v0.7's floor froze at the mic's quiet
//    first moments, so a normal room never counted as silence and the note never ended). Since v0.8.6 the voice note
//    (⌥⇧V) ends when you say so; this one keeps ending on the pause — it is a sentence about one picture.
//  • typing before speaking switches to a text note (the mic stops). Typing after speaking keeps listening until the
//    pause; if less than 1 s of it was talking, the recording was abandoned for typing and is dropped (no mic mark,
//    nothing to transcribe). A kept recording is always transcribed (Snapper.settled), also next to typed text.
//  • ⏎ (or ✓) keeps the shot — with the note, or
//    without one (then it hangs as a card); Esc (or the bin) discards the shot: Trash, "Discarded · Undo" for 3 s.
//  • the shot is shown enlarged; drag (⌃-drag, as with the recorder's pen — or just drag) to circle things → the
//    ink is burnt into shots/NNN.marked.png, the original stays as it was.
//  • ⌥⇧A while it is open saves the note and takes the next shot.
// The same panel, text-only, is the note popover for snaps taken while recording (the island's snap button,
// the recording pauses while it is open).
//
// Tests: BLURT_NOTE_WAV=<file.wav> feeds that file through the same path instead of the microphone.

import AppKit
import BlurtCore
import AudioToolbox
import AVFoundation
import Carbon.HIToolbox
import CoreAudio

// MARK: - Voice note: microphone (or an injected wav) → VAD → wav file

final class NoteVoice {
    enum End { case silence, noSpeech, maxed }
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

    func start(_ ready: @escaping (Bool) -> Void) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: NoteVoice.rate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        started = Date()
        startedAt = CACurrentMediaTime()
        if NoteVoice.testDenied { ready(false); return }
        if let wav = inject ?? ProcessInfo.processInfo.environment["BLURT_NOTE_WAV"] {
            running = true                  // the feed checks it as it begins
            running = startInjected(URL(fileURLWithPath: wav))
            ready(running)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: startMic(ready)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { if ok { self.startMic(ready) } else { ready(false) } }
            }
        default: ready(false)
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
            let e = device.map { MicEngine.shared.make(device: $0) } ?? MicEngine.shared.take(builtIn: builtIn)
            let input = e.inputNode
            let inFmt = input.outputFormat(forBus: 0)
            guard inFmt.sampleRate > 0, let conv = AVAudioConverter(from: inFmt, to: self.fmt) else {
                MicEngine.shared.giveBack(e, builtIn: builtIn)
                return DispatchQueue.main.async { self.running = false; ready(false) }
            }
            input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(inFmt.sampleRate / 20), format: inFmt) { [weak self] buf, _ in
                guard let self = self else { return }
                let cap = AVAudioFrameCount(Double(buf.frameLength) * NoteVoice.rate / inFmt.sampleRate) + 32
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
            do { try e.start() } catch {
                input.removeTap(onBus: 0)
                MicEngine.shared.giveBack(e, builtIn: builtIn)
                return DispatchQueue.main.async { self.running = false; ready(false) }
            }
            DispatchQueue.main.async {
                guard self.running else {          // stopped while it was starting
                    MicEngine.shared.queue.async { input.removeTap(onBus: 0); e.stop(); MicEngine.shared.giveBack(e, builtIn: builtIn) }
                    return
                }
                self.engine = e
                ready(true)
            }
        }
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
        if firstAudioAfter == nil {
            firstAudioAfter = CACurrentMediaTime() - startedAt
            onFirstAudio?()
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

    /// keep: false deletes the wav (no speech / skipped).
    func stop(keep: Bool) {
        running = false
        injectTimer?.invalidate()
        injectTimer = nil
        if let e = engine {
            engine = nil
            let builtIn = builtInMic
            MicEngine.shared.queue.async { e.inputNode.removeTap(onBus: 0); e.stop(); MicEngine.shared.giveBack(e, builtIn: builtIn) }
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

// MARK: - Ink on the enlarged preview

final class InkCanvas: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var strokes: [[[Double]]] = [] { didSet { redrawInk() } }
    var editable = true
    var onChange: (() -> Void)?
    private var pts: [CGPoint] = []
    private let inkLayer = CALayer()
    private let live = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.addSublayer(inkLayer)
        style(live)
        inkLayer.addSublayer(live)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { if editable { addCursorRect(bounds, cursor: .crosshair) } }

    func style(_ l: CAShapeLayer) {
        l.fillColor = nil
        l.strokeColor = BrandColor.Island.markup.cgColor      // the pen (BrandColor.markup, one value light and dark)
        l.lineWidth = 3.5
        l.lineCap = .round
        l.lineJoin = .round
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = 0.45
        l.shadowRadius = 1.5
        l.shadowOffset = .zero
    }

    override func layout() {
        super.layout()
        inkLayer.frame = bounds
        redrawInk()
    }

    override func draw(_ dirty: NSRect) {
        guard let img = image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: bounds)
        ctx.restoreGState()
    }

    func path(_ p: [CGPoint]) -> CGPath {
        let m = CGMutablePath()
        guard let f = p.first else { return m }
        if p.count == 1 { m.addEllipse(in: CGRect(x: f.x - 16, y: f.y - 16, width: 32, height: 32)); return m }
        m.move(to: f)
        for i in 1..<max(1, p.count - 1) where i + 1 < p.count {
            m.addQuadCurve(to: CGPoint(x: (p[i].x + p[i + 1].x) / 2, y: (p[i].y + p[i + 1].y) / 2), control: p[i])
        }
        m.addLine(to: p[p.count - 1])
        return m
    }

    func redrawInk() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkLayer.sublayers?.filter { $0 !== live }.forEach { $0.removeFromSuperlayer() }
        for s in strokes {
            let l = CAShapeLayer()
            style(l)
            l.path = path(s.map { CGPoint(x: CGFloat($0[0]) * bounds.width, y: CGFloat($0[1]) * bounds.height) })
            inkLayer.insertSublayer(l, below: live)
        }
        CATransaction.commit()
    }

    func local(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    override func mouseDown(with e: NSEvent) {
        guard editable else { return }
        pts = [local(e)]
        live.path = nil
    }

    override func mouseDragged(with e: NSEvent) {
        guard editable, let last = pts.last else { return }
        let p = local(e)
        guard hypot(p.x - last.x, p.y - last.y) >= 1.5 else { return }
        pts.append(p)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        live.path = path(pts)
        CATransaction.commit()
    }

    override func mouseUp(with e: NSEvent) {
        guard editable, !pts.isEmpty else { return }
        let length = zip(pts, pts.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        var keep: [CGPoint] = length < 6 ? [pts[0]] : []
        if length >= 6 { for p in pts where keep.last.map({ hypot(p.x - $0.x, p.y - $0.y) >= 2 }) ?? true { keep.append(p) } }
        if length >= 6, let end = pts.last, keep.last != end { keep.append(end) }
        let r3 = { (v: CGFloat) in Double((v * 1000).rounded() / 1000) }
        strokes.append(keep.map { [r3($0.x / bounds.width), r3($0.y / bounds.height)] })
        pts = []
        live.path = nil
        onChange?()
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
    override var canBecomeKey: Bool { true }
    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown, onKey?(e) == true { return }
        super.sendEvent(e)
    }
}

/// The bubble's background: a rounded card with a caret pointing at the shot it belongs to.
final class BubbleBackground: NSView {
    var caretX: CGFloat = 40 { didSet { needsDisplay = true } }
    var caretUp = true { didSet { needsDisplay = true } }
    static let caret: CGFloat = 9
    override var isFlipped: Bool { true }

    func shape() -> NSBezierPath {
        let c = BubbleBackground.caret
        let body = caretUp ? NSRect(x: 0.5, y: c, width: bounds.width - 1, height: bounds.height - c - 0.5)
                           : NSRect(x: 0.5, y: 0.5, width: bounds.width - 1, height: bounds.height - c - 0.5)
        let p = NSBezierPath(roundedRect: body, xRadius: 14, yRadius: 14)
        let x = min(max(caretX, 26), bounds.width - 26)
        let t = NSBezierPath()
        if caretUp {
            t.move(to: NSPoint(x: x - c - 2, y: c + 0.5)); t.line(to: NSPoint(x: x, y: 0.5)); t.line(to: NSPoint(x: x + c + 2, y: c + 0.5))
        } else {
            t.move(to: NSPoint(x: x - c - 2, y: bounds.height - c - 0.5)); t.line(to: NSPoint(x: x, y: bounds.height - 0.5))
            t.line(to: NSPoint(x: x + c + 2, y: bounds.height - c - 0.5))
        }
        t.close()
        p.append(t)
        return p
    }

    override func draw(_ dirty: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let p = shape()
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowBlurRadius = 18
        sh.shadowOffset = NSSize(width: 0, height: -6)
        sh.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.22)
        sh.set()
        (dark ? NSColor(calibratedWhite: 0.17, alpha: 0.98) : NSColor(calibratedWhite: 0.995, alpha: 0.98)).setFill()
        p.fill()
        NSGraphicsContext.restoreGraphicsState()
        (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.10)).setStroke()
        p.lineWidth = 1
        p.stroke()
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
    /// "● 0:04 在听…": a red recording dot (BlurtIcon.recordFill) + the status text.
    private func recLabel(_ text: String) -> NSAttributedString {
        BlurtIcon.recordFill.label(text, font: status.font ?? .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor,
                                   iconColor: BrandColor.rec)
    }
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
    private var voice: NoteVoice?
    private var typed = false
    private var speechStarted = false
    private var voiceKept = false
    /// how much of the kept recording was talking
    private var voiceSpeech: Double = 0
    /// Typed, and said less than this: the voice was abandoned for typing (a word, a cough, the keyboard) — dropped.
    static let abandonedSpeech = 1.0
    private var ticker: Timer?
    private var showWork: DispatchWorkItem?
    private var original: (text: String?, voice: String?, said: String?, strokes: [[[Double]]])?
    private var player: AVAudioPlayer?
    /// recording mode: which shots can be switched between, and what to do on close (resume).
    var recordingShots: [Shot] = []
    var onClose: (() -> Void)?
    var anchor: (() -> NSRect?)?

    var isOpen: Bool { shot != nil }
    /// Its microphone is on (dictation waits for it).
    var isListening: Bool { voice?.running == true }

    var canvasScreenRect: NSRect? {
        guard let p = panel, p.isVisible else { return nil }
        return p.convertToScreen(canvas.convert(canvas.bounds, to: nil))
    }

    // MARK: open

    func begin(_ s: Shot, mode m: Mode, anchor a: (() -> NSRect?)? = nil) {
        if isOpen { commit() }
        shot = s
        mode = m
        anchor = a ?? { hanging.screenRect(of: s) ?? island.frameOnScreen }
        typed = false
        speechStarted = false
        voiceKept = false
        voiceSpeech = 0
        original = (s.text, s.voice, s.said, s.strokes)
        build()
        load(s)
        if m == .listen { startListening() }
        if m != .recording { hanging.hold(true) }
        // let the card land on its thread first, then unfold the bubble under it
        let delay = m == .listen && !reduceMotion ? 0.55 : 0.0
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
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.sharingType = chromeSharing
        p.isMovableByWindowBackground = false
        p.onKey = { [weak self] e in self?.key(e) ?? false }
        let root = bg
        p.contentView = root
        canvas.onChange = { [weak self] in self?.inkChanged() }
        root.addSubview(canvas)
        penHint.font = .systemFont(ofSize: 11, weight: .semibold)
        penHint.textColor = .white
        penHint.wantsLayer = true
        penHint.drawsBackground = true
        penHint.backgroundColor = NSColor(white: 0, alpha: 0.5)
        penHint.layer?.cornerRadius = 9
        penHint.alignment = .center
        root.addSubview(penHint)
        undoBtn = SymbolButton("arrow.uturn.backward", tip: Loc.t("capture.note.undo", table: "Capture")) { [weak self] in self?.undoInk() }
        root.addSubview(undoBtn)
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
        panel = p
    }

    private func load(_ s: Shot) {
        let img = s.image()
        canvas.image = img
        canvas.strokes = s.strokes
        canvas.editable = mode != .recording
        field.stringValue = mode == .listen ? "" : (s.text ?? "")
        layout()
        refreshStatus()
    }

    private func previewSize() -> NSSize {
        let px = shot?.pixelSize ?? CGSize(width: 1600, height: 1000)
        let maxW: CGFloat = mode == .recording ? 340 : 540, maxH: CGFloat = mode == .recording ? 210 : 320
        let aspect = max(0.2, min(5, px.width / max(1, px.height)))
        var w = maxW, h = w / aspect
        if h > maxH { h = maxH; w = h * aspect }
        return NSSize(width: max(140, w.rounded()), height: max(90, h.rounded()))
    }

    private func layout() {
        let pv = previewSize()
        let pad: CGFloat = 12
        let width = max(mode == .recording ? 340 : 400, pv.width + pad * 2)
        let fieldH = fieldHeight(width - pad * 2 - 40)
        let c = BubbleBackground.caret
        let top = bg.caretUp ? c : 0
        let height = c + pad + pv.height + 10 + fieldH + 4 + 16 + pad
        panel?.setContentSize(NSSize(width: width, height: height))
        bg.frame = NSRect(x: 0, y: 0, width: width, height: height)
        canvas.frame = NSRect(x: (width - pv.width) / 2, y: top + pad, width: pv.width, height: pv.height)
        penHint.stringValue = mode == .recording ? "" : "  " + Loc.t("capture.note.pen_hint", table: "Capture") + "  "
        penHint.sizeToFit()
        penHint.frame = NSRect(x: canvas.frame.minX + 8, y: canvas.frame.maxY - 26, width: penHint.frame.width, height: 18)
        penHint.isHidden = mode == .recording || !canvas.strokes.isEmpty
        undoBtn.frame.origin = NSPoint(x: canvas.frame.maxX - 32, y: canvas.frame.maxY - 32)
        undoBtn.isHidden = canvas.strokes.isEmpty
        undoBtn.wantsLayer = true
        undoBtn.layer?.backgroundColor = NSColor(white: 1, alpha: 0.85).cgColor
        undoBtn.layer?.cornerRadius = 13
        let rowY = canvas.frame.maxY + 10
        icon.frame = NSRect(x: pad + 2, y: rowY + 1, width: 22, height: 20)
        bars.frame = NSRect(x: pad, y: rowY, width: 26, height: 22)
        field.frame = NSRect(x: pad + 34, y: rowY + 1, width: width - pad * 2 - 34 - 6, height: fieldH)
        let buttons: CGFloat = mode == .recording && recordingShots.count > 1 ? 56 : mode == .edit || mode == .listen ? 56 : 0
        status.frame = NSRect(x: pad + 34, y: rowY + fieldH + 4, width: width - pad * 2 - 34 - buttons, height: 15)
        var bx = width - pad - 26
        for b in [nextBtn, prevBtn, micBtn, playBtn, keepBtn, discardBtn] { b?.isHidden = true }
        if mode == .listen {
            keepBtn.isHidden = false; keepBtn.frame.origin = NSPoint(x: bx, y: rowY + fieldH - 2); bx -= 26
            discardBtn.isHidden = false; discardBtn.frame.origin = NSPoint(x: bx, y: rowY + fieldH - 2); bx -= 26
        }
        if mode == .recording, recordingShots.count > 1 {
            nextBtn.isHidden = false; nextBtn.frame.origin = NSPoint(x: bx, y: rowY + fieldH); bx -= 26
            prevBtn.isHidden = false; prevBtn.frame.origin = NSPoint(x: bx, y: rowY + fieldH); bx -= 26
        }
        if mode == .edit {
            micBtn.isHidden = false; micBtn.frame.origin = NSPoint(x: bx, y: rowY + fieldH - 2); bx -= 26
            if shot?.voiceURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
                playBtn.isHidden = false; playBtn.frame.origin = NSPoint(x: bx, y: rowY + fieldH - 2); bx -= 26
            }
        }
        position()
    }

    private func fieldHeight(_ w: CGFloat) -> CGFloat {
        let s = field.stringValue.isEmpty ? (field.placeholderString ?? "x") : field.stringValue
        let r = (s as NSString).boundingRect(with: NSSize(width: w, height: 400), options: [.usesLineFragmentOrigin],
                                             attributes: [.font: field.font!])
        return min(90, max(20, ceil(r.height) + 2))
    }

    private func position() {
        guard let p = panel else { return }
        let size = p.frame.size
        let a = anchor?() ?? NSRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y, width: 1, height: 1)
        let screen = (NSScreen.screens.first(where: { $0.frame.intersects(a) }) ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        var up = true
        var o = NSPoint(x: a.midX - size.width / 2, y: a.minY - 6 - size.height)
        if o.y < screen.minY + 8 { up = false; o.y = a.maxY + 6 }
        o.x = max(screen.minX + 8, min(o.x, screen.maxX - size.width - 8))
        o.y = max(screen.minY + 8, min(o.y, screen.maxY - size.height))
        if bg.caretUp != up { bg.caretUp = up; DispatchQueue.main.async { self.layout() } }
        bg.caretX = a.midX - o.x
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
            NSAnimationContext.runAnimationGroup { c in
                c.duration = reduce ? 0.15 : 0.18
                p.animator().alphaValue = 1
            }
        }
        // the panel is non-activating: it takes the typing without activating Blurt, so Blurt's main window never
        // jumps above the app the user just snapped; close() still hands focus back
        if mode == .recording { snapper.rememberFrontApp() }
        p.makeKey()
        p.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.count, length: 0)
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: listening

    private func startListening() {
        guard let s = shot, let dir = s.batch?.dir else { return }
        guard Dictation.shared.phase != .listening else { return refreshStatus() }    // dictation has the mic: type instead
        let rel = "shots/\(ShotBatch.name(s.n)).wav"
        let v = NoteVoice(url: dir.appendingPathComponent(rel))
        v.onLevel = { [weak self] l in self?.bars.level = l }
        v.onSpeech = { [weak self] in self?.speechStarted = true; self?.refreshStatus() }
        v.onEnd = { [weak self] e in
            guard let self = self, self.voice === v else { return }
            if e == .noSpeech {
                self.voice = nil
                if !self.typed { self.close(save: true, flash: false) }
            } else {
                self.voice = nil
                self.voiceKept = true
                self.voiceSpeech = v.speechSeconds
                self.shot?.voice = rel
                self.shot?.said = nil                    // a new recording (a re-record in edit): its words to come
                if !self.typed { self.close(save: true, flash: true) }
            }
        }
        voice = v
        v.start { [weak self] ok in
            guard let self = self, self.voice === v else { return }
            if !ok { self.voice = nil; self.refreshStatus() }
        }
        refreshStatus()
    }

    private func rerecord() {
        guard mode == .edit else { return }
        voice?.stop(keep: false)
        typed = !field.stringValue.isEmpty
        speechStarted = false
        let keepTyped = typed
        startListening()
        typed = keepTyped
        refreshStatus()
    }

    private func refreshStatus() {
        let listening = voice?.running == true
        bars.isHidden = !listening
        icon.isHidden = listening
        let sym = mode == .recording ? "note.text" : (typed || mode == .edit ? "keyboard" : "mic.slash")
        icon.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        icon.contentTintColor = .secondaryLabelColor
        switch mode {
        case .listen:
            field.placeholderString = listening ? Loc.t("capture.note.listening", table: "Capture")
                                                : Loc.t("capture.note.placeholder_optional", table: "Capture")
            // where it goes first (with a note, straight into the current project; without, it waits as a card)
            let dest = destination.map { $0 + " · " } ?? ""
            let next = hkHint(.snap, "capture.note.next_hint").map { " · " + $0 } ?? ""
            if typed { status.stringValue = dest + Loc.t("capture.note.save_discard", table: "Capture") + next }
            else if listening && speechStarted {
                status.attributedStringValue = recLabel(fmt(voice?.elapsed ?? 0) + "  " + Loc.t("capture.note.listening_save", table: "Capture"))
            }
            else if listening { status.stringValue = dest + Loc.t("capture.note.keep_discard", table: "Capture") + next }
            else { status.stringValue = dest + Loc.t("capture.note.no_mic", table: "Capture") }
        case .edit:
            field.placeholderString = Loc.t("capture.note.placeholder", table: "Capture")
            if listening { status.attributedStringValue = recLabel(fmt(voice?.elapsed ?? 0) + "  " + Loc.t("capture.note.recording_new", table: "Capture")) }
            else { status.stringValue = Loc.t("capture.note.save_cancel", table: "Capture") }
        case .recording:
            let i = recordingShots.firstIndex(where: { $0 === shot }).map { $0 + 1 } ?? 1
            field.placeholderString = Loc.t("capture.note.placeholder_shot", table: "Capture")
            // the shot counter first: on a narrow bubble the hint's tail is what gets cut, not "2/2"
            status.stringValue = (recordingShots.count > 1 ? "\(i)/\(recordingShots.count)  ·  " : "")
                + Loc.t("capture.note.paused", table: "Capture")
        }
    }

    private func fmt(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    /// "→ ordo-platform" for a fresh shot taken with a current project.
    private var destination: String? {
        guard mode == .listen, let pid = shot?.project, let p = ProjectStore.shared.project(id: pid) else { return nil }
        return Loc.t("capture.note.goes_to", table: "Capture", p.name)
    }

    private func tick() {
        bars.needsDisplay = true
        if voice?.running == true && speechStarted { refreshStatus() }
        // follow the card if the cards re-lay out (another capture arrived, a neighbour was removed)
        if let p = panel, p.isVisible, mode != .recording { position() }
    }

    // MARK: input

    func controlTextDidChange(_ n: Notification) {
        if !typed && !field.stringValue.isEmpty {
            typed = true
            if mode == .listen, let v = voice, !speechStarted { v.stop(keep: false); voice = nil }
        }
        refreshStatus()
        layout()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { commit(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        if sel == #selector(NSResponder.insertLineBreak(_:)) { textView.insertText("\n", replacementRange: textView.selectedRange()); return true }
        return false
    }

    private func key(_ e: NSEvent) -> Bool {
        if e.keyCode == UInt16(kVK_Escape) { cancel(); return true }
        if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "z", !canvas.strokes.isEmpty, field.stringValue.isEmpty {
            undoInk(); return true
        }
        if mode == .recording, e.modifierFlags.contains(.command) {
            if e.keyCode == UInt16(kVK_LeftArrow) { step(-1); return true }
            if e.keyCode == UInt16(kVK_RightArrow) { step(1); return true }
        }
        return false
    }

    private func inkChanged() {
        if mode == .listen, voice?.running == true, !speechStarted {
            // drawing counts as "still working on it": don't let the no-speech timeout close the bubble under the pen
            voice?.noSpeechTimeout = max(voice?.noSpeechTimeout ?? 8, (voice?.elapsed ?? 0) + 8)
        }
        layout()
    }

    private func undoInk() {
        guard !canvas.strokes.isEmpty else { return }
        canvas.strokes.removeLast()
        layout()
    }

    private func step(_ d: Int) {
        guard mode == .recording, let s = shot, let i = recordingShots.firstIndex(where: { $0 === s }) else { return }
        saveText(s)
        let j = (i + d + recordingShots.count) % recordingShots.count
        shot = recordingShots[j]
        load(recordingShots[j])
    }

    private func play() {
        guard let u = shot?.voiceURL else { return }
        player = try? AVAudioPlayer(contentsOf: u)
        player?.play()
    }

    // MARK: tests (BLURT_TEST_COMMANDS: SnapApp's "notetype" / "notekey")

    /// Typing into the field, as the field editor would.
    func testType(_ text: String) {
        guard isOpen else { return }
        if let ed = field.currentEditor() { ed.insertText(text) } else { field.stringValue += text }
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

    // MARK: close

    /// Save what's there (⏎, ⌥⇧A again, silence after speech).
    func commit() { if isOpen { close(save: true, flash: voice?.running == true || voiceKept) } }

    /// Esc = cancel: a fresh shot is discarded (with Undo); an edit puts things back as they were.
    func cancel() { if isOpen { close(save: false, flash: false) } }

    private func saveText(_ s: Shot) {
        let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        s.text = t.isEmpty ? nil : t
        s.batch?.save(s)
    }

    private func close(save: Bool, flash: Bool) {
        guard let s = shot else { return }
        showWork?.cancel()
        ticker?.invalidate()
        player?.stop()
        // Esc on a fresh shot discards it; what was said, typed and drawn goes with it, and comes back with Undo
        let discard = !save && mode == .listen
        let rel = "shots/\(ShotBatch.name(s.n)).wav"
        // (a fresh shot only: in an edit the text was there before the re-record)
        let hadTyping = mode == .listen && typed && !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let v = voice {
            // kept: something was said — unless the user went on to type and what was "said" was barely anything (a
            // word, a cough, the keyboard): then the voice was abandoned for typing, and it goes
            let keep = (save || discard) && speechStarted && !(hadTyping && v.speechSeconds < NoteBubble.abandonedSpeech)
            emit(["event": "note_voice_close", "n": s.n, "kept": keep, "speech": (v.speechSeconds * 100).rounded() / 100, "typed": hadTyping])
            v.stop(keep: keep)
            if keep { s.voice = rel; s.said = nil } else if s.voice == rel { s.voice = nil; s.said = nil }
            voice = nil
        } else if voiceKept, hadTyping, voiceSpeech < NoteBubble.abandonedSpeech, save || discard {
            // it had ended by itself (a pause), then the user typed the note instead
            if let u = s.voiceURL { try? FileManager.default.removeItem(at: u) }
            s.voice = nil
            s.said = nil
            emit(["event": "note_voice_close", "n": s.n, "kept": false, "speech": (voiceSpeech * 100).rounded() / 100, "typed": true])
        }
        if save || discard {
            let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            s.text = t.isEmpty ? nil : t
            if mode != .recording { applyInk(s) }
            s.batch?.save(s)
        } else if mode == .edit, let o = original {
            s.text = o.text; s.voice = o.voice; s.said = o.said; s.strokes = o.strokes
        } else if mode == .recording {
            // Esc = resume without saving the edit in the field
        }
        shot = nil
        if mode != .recording {
            hanging.update(s)
            hanging.hold(false)
            if discard { snapper.discard(s) } else { snapper.settled(s) }
        }
        let p = panel
        let done = { [weak self] in
            p?.orderOut(nil)
            snapper.restoreFocus()
            let cb = self?.onClose
            self?.onClose = nil
            cb?()
        }
        if flash, let p = p {
            status.attributedStringValue = BlurtIcon.check.label(Loc.t("capture.note.saved", table: "Capture"), font: status.font ?? .systemFont(ofSize: 11, weight: .medium),
                                                                 color: BrandColor.ok, preferSymbol: true)
            status.textColor = BrandColor.ok
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                self.status.textColor = .secondaryLabelColor
                self.fadeOut(p, then: done)
            }
        } else if let p = p {
            fadeOut(p, then: done)
        } else { done() }
    }

    private func fadeOut(_ p: NSPanel, then: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.16
            p.animator().alphaValue = 0
        }, completionHandler: then)
    }

    /// Strokes changed → (re)write NNN.marked.png, or drop it when the ink was undone.
    private func applyInk(_ s: Shot) {
        let strokes = canvas.strokes
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
        let lw = 3.5 * CGFloat(img.width) / max(1, canvas.bounds.width)
        guard let m = renderMarked(img, strokes: strokes, lineWidthPx: lw), let d = pngData(m, scale: s.scale) else { return }
        try? d.write(to: url)
        s.marked = rel
        s.markedThumb = thumbnail(m, maxPixels: 520)
    }
}
