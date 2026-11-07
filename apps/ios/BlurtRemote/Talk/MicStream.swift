// The phone's microphone, to the Mac: 16 kHz mono PCM16 in 100 ms pieces, the format Blurt's dictation takes. It starts on
// the talk bar's key-down, so nothing said in the first moments is lost; the Mac keeps what arrives before its take has
// started. It ends when the Mac says the take isn't listening any more, or when the press came to nothing.
import AVFoundation
import BlurtRemoteKit
import Foundation

final class MicStream {
    static let shared = MicStream()

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var running = false
    private var pieces = Data()
    private var sawListening = false
    private var giveUp: DispatchWorkItem?

    var access: AVAudioApplication.recordPermission { AVAudioApplication.shared.recordPermission }
    func ask() { AVAudioApplication.requestRecordPermission { _ in } }

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
    @discardableResult func start() -> Bool {
        giveUp?.cancel()
        guard !running else { return true }
        #if DEBUG
        if let w = testWav { startTestWav(w); return true }
        #endif
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
            try s.setPreferredIOBufferDuration(0.02)
            try s.setActive(true, options: [])
            let input = engine.inputNode
            let f = input.outputFormat(forBus: 0)
            guard f.sampleRate > 0, let c = AVAudioConverter(from: f, to: target) else { return false }
            converter = c
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 2048, format: f) { [weak self] b, _ in self?.convert(b) }
            engine.prepare()
            try engine.start()
            running = true
            sawListening = false
            return true
        } catch {
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
            self.stop()
        }
        giveUp = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    func macPhase(_ p: RemoteDictationPhase) {
        if p == .listening { sawListening = true } else if running, sawListening { stop() }
    }

    func stop() {
        giveUp?.cancel()
        guard running else { return }
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
