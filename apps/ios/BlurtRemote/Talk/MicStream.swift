// The phone's microphone, to the Mac: 16 kHz mono PCM16 in 100 ms pieces, the format Blurt's dictation takes. It starts on
// the talk bar's key-down, so nothing said in the first moments is lost; the Mac keeps what arrives before its take has
// started. It ends when the Mac says the take isn't listening any more, or when the press came to nothing.
import AVFoundation
import BlurtRemoteKit
import Foundation

final class MicStream {
    static let shared = MicStream()

    /// a new engine for every start: an engine's input node keeps the format it first read, and once the route has changed
    /// since (AirPods' 16/24 kHz against the built-in 48 kHz, a call, another app) installTap throws an Objective-C
    /// exception Swift can't catch — two crashes on an iPhone 16 Pro Max on 2026-11-12, both on the talk bar's key-down
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var running = false
    /// who has the microphone: the talk key, and a voice note the Mac started from here. It stops when neither does
    enum Holder { case talk, note }
    private var holders: Set<Holder> = []
    private var pieces = Data()
    private var sawListening = false
    private var giveUp: DispatchWorkItem?

    var access: AVAudioApplication.recordPermission { AVAudioApplication.shared.recordPermission }
    func ask() {
        AVAudioApplication.requestRecordPermission { _ in
            DispatchQueue.main.async { Link.shared.send(.setMicOnPhone(MicStream.shared.usable)) }     // the Mac now knows which to use
        }
    }

    /// The phone's microphone is the one to use: chosen in Settings, and allowed. Otherwise the Mac listens with its own.
    var usable: Bool {
        guard Prefs.shared.micOnPhone else { return false }
        #if DEBUG
        if testWav != nil { return true }
        #endif
        return access == .granted
    }

    #if DEBUG
    /// Tests: this wav (16 kHz mono PCM16) instead of the microphone, in real time. SIMCTL_CHILD_BLURT_REMOTE_TEST_WAV.
    private let testWav = ProcessInfo.processInfo.environment["BLURT_REMOTE_TEST_WAV"]
    private var testTimer: Timer?
    private func startTestWav(_ path: String) {
        guard let d = FileManager.default.contents(atPath: path) else { return }
        var at = 44
        running = true
        sawListening = false
        testTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self, self.running, at < d.count else { t.invalidate(); return }
            Link.shared.audio(d.subdata(in: at..<min(at + 3200, d.count)))
            at += 3200
        }
    }
    #endif

    /// false: the microphone can't be had right now (a phone call has it)
    @discardableResult func start(for h: Holder = .talk) -> Bool {
        if h == .talk { giveUp?.cancel() }
        holders.insert(h)
        guard !running else { return true }
        #if DEBUG
        if let w = testWav { startTestWav(w); return true }
        #endif
        do {
            let s = AVAudioSession.sharedInstance()
            // .default, not .measurement: measurement turns the input gain down to the device's raw level, which on an
            // iPad Pro (11-inch, 3rd generation) is about 30 dB lower than on an iPhone — speech stayed under the Mac's
            // silence floor and every take was "nothing heard"
            try s.setCategory(.record, mode: .default, options: [.allowBluetooth])
            try s.setPreferredIOBufferDuration(0.02)
            try s.setActive(true, options: [])
            engine = AVAudioEngine()
            let input = engine.inputNode
            let f = input.outputFormat(forBus: 0)
            // the tap's format has to be the hardware's, or installTap raises; a mismatch here means the route is still
            // settling: no take this time rather than a crash
            guard f.sampleRate > 0, f.channelCount > 0, f.sampleRate == input.inputFormat(forBus: 0).sampleRate,
                  let c = AVAudioConverter(from: f, to: target) else { throw CocoaError(.featureUnsupported) }
            converter = c
            input.installTap(onBus: 0, bufferSize: 2048, format: f) { [weak self] b, _ in self?.convert(b) }
            engine.prepare()
            try engine.start()
            running = true
            sawListening = false
            return true
        } catch {
            holders.remove(h)
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            return false
        }
    }

    private func convert(_ b: AVAudioPCMBuffer) {
        guard let c = converter, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(b.frameLength) * 16000 / b.format.sampleRate) + 32) else { return }
        var fed = false
        var err: NSError?
        c.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true
            st.pointee = .haveData
            return b
        }
        guard err == nil, out.frameLength > 0, let p = out.int16ChannelData?[0] else { return }
        pieces.append(Data(bytes: p, count: Int(out.frameLength) * 2))
        if pieces.count >= 3200 {
            Link.shared.audio(pieces)
            pieces = Data()
        }
    }

    /// The bar was let go of. A hands-free take goes on: the Mac's next phase decides.
    func released() {
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.sawListening else { return }
            self.stop(for: .talk)
        }
        giveUp = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    func macPhase(_ p: RemoteDictationPhase) {
        if p == .listening { sawListening = true } else if running, sawListening { sawListening = false; stop(for: .talk) }
    }

    /// `h` is done with it; nil: everyone is (the session ended)
    func stop(for h: Holder? = nil) {
        if let h { holders.remove(h) } else { holders = [] }
        if h == nil || h == .talk { giveUp?.cancel() }
        guard running, holders.isEmpty else { return }
        running = false
        #if DEBUG
        if testWav != nil { testTimer?.invalidate(); return }
        #endif
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if !pieces.isEmpty { Link.shared.audio(pieces); pieces = Data() }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
