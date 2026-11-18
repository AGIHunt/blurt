import AVFoundation
@testable import BlurtCore
import XCTest

final class CueEraserTests: XCTestCase {
    let rate = 16000.0

    /// a chirp-like clip standing in for the peep (0.22 s)
    func clip() -> [Float] {
        (0..<3520).map { (i: Int) -> Float in
            let t = Float(i) / 16000
            let phase: Float = 2 * Float.pi * (1800 + 2400 * t) * t
            let env: Float = min(1, min(Float(i) / 160, Float(3520 - i) / 400))
            return 0.5 * sin(phase) * env
        }
    }

    func noise(_ n: Int, _ level: Float, seed: UInt64 = 7) -> [Float] {
        var s = seed
        return (0..<n).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return level * (Float(s >> 40) / Float(1 << 24) - 0.5)
        }
    }

    /// the clip as a speaker and a room would put it into the mic: delayed, quieter, smeared
    func recorded(_ c: [Float], at: Int, into y: inout [Float], gain: Float = 0.06) {
        let h: [Float] = [0.6, 0.25, -0.1, 0.05, 0.02]
        for (i, v) in c.enumerated() {
            for (t, w) in h.enumerated() where at + i + t < y.count { y[at + i + t] += gain * w * v }
        }
    }

    func run(_ e: inout CueEraser, _ y: [Float], chunk: Int = 800) -> [Float] {
        var out: [Float] = []
        var i = 0
        while i < y.count { out += e.process(Array(y[i..<min(y.count, i + chunk)])); i += chunk }
        return out + e.flush()
    }

    func testPassesThroughWhenNotArmed() {
        var e = CueEraser(cue: clip(), sampleRate: rate)
        let y = noise(16000, 0.01)
        XCTAssertEqual(run(&e, y), y)
        XCTAssertNil(e.result)
    }

    func testFindsAndRemovesTheCue() {
        var e = CueEraser(cue: clip(), sampleRate: rate)
        var y = noise(32000, 0.002)
        recorded(clip(), at: 3200, into: &y)
        e.armed()
        let out = run(&e, y)
        XCTAssertEqual(out.count, y.count)
        let r = try! XCTUnwrap(e.result)
        XCTAssertEqual(r.offset, 3200, accuracy: 2)
        XCTAssertTrue(r.muted)
        XCTAssertLessThan(r.afterDB, r.beforeDB - 25)
        // nothing outside the window changed
        XCTAssertEqual(Array(out[0..<3000]), Array(y[0..<3000]))
        XCTAssertEqual(Array(out[8000...]), Array(y[8000...]))
    }

    func testKeepsSpeechThatOverlapsTheCue() {
        var e = CueEraser(cue: clip(), sampleRate: rate)
        // "speech": a loud low tone starting in the middle of the cue
        var y = noise(32000, 0.002)
        for i in 4500..<20000 { y[i] += 0.1 * sin(2 * .pi * 180 * Float(i) / 16000) }
        let speech = y
        recorded(clip(), at: 3200, into: &y)
        e.armed()
        let out = run(&e, y)
        let r = try! XCTUnwrap(e.result)
        XCTAssertFalse(r.muted)
        // the speech is still there, the cue mostly gone: the output is close to the signal without the cue
        var err: Float = 0, sig: Float = 0
        for i in 3200..<6800 { err += (out[i] - speech[i]) * (out[i] - speech[i]); sig += speech[i] * speech[i] }
        XCTAssertLessThan(err / sig, 0.05)
    }

    func testNoCueLeavesTheAudioAlone() {
        var e = CueEraser(cue: clip(), sampleRate: rate)
        let y = noise(32000, 0.01)
        e.armed()
        XCTAssertEqual(run(&e, y), y)
        XCTAssertNil(e.result)
    }

    func testShortTakeFlushes() {
        var e = CueEraser(cue: clip(), sampleRate: rate)
        var y = noise(8000, 0.002)
        recorded(clip(), at: 1600, into: &y)
        e.armed()
        let out = run(&e, y)
        XCTAssertEqual(out.count, y.count)
        XCTAssertNotNil(e.result)
    }

    /// The founder's own takes (local only): BLURT_CUE_TAKES=<dir of 16 kHz wavs> BLURT_CUE_CLIP=<start.wav>.
    func testRealTakes() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["BLURT_CUE_TAKES"], let clipPath = env["BLURT_CUE_CLIP"] else { throw XCTSkip("no takes") }
        let cue = try read(URL(fileURLWithPath: clipPath))
        var found = 0, muted = 0, total = 0
        var drops: [Float] = []
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".wav") }.sorted()
        for f in files {
            let y = try read(URL(fileURLWithPath: dir).appendingPathComponent(f))
            var e = CueEraser(cue: cue, sampleRate: rate)
            e.armed()
            _ = run(&e, y)
            total += 1
            if let r = e.result {
                found += 1; muted += r.muted ? 1 : 0; drops.append(r.beforeDB - r.afterDB)
            }
        }
        drops.sort()
        print("CUE takes \(total) found \(found) muted \(muted) drop dB median \(drops.isEmpty ? 0 : drops[drops.count / 2]) p10 \(drops.isEmpty ? 0 : drops[drops.count / 10])")
    }

    func read(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let inBuf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: inBuf)
        if f.processingFormat.sampleRate == rate && f.processingFormat.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: inBuf.floatChannelData![0], count: Int(inBuf.frameLength)))
        }
        let conv = AVAudioConverter(from: f.processingFormat, to: out)!
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * rate / f.processingFormat.sampleRate) + 1024
        let o = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: cap)!
        var done = false
        _ = conv.convert(to: o, error: nil) { _, status in
            if done { status.pointee = .endOfStream; return nil }
            done = true; status.pointee = .haveData; return inBuf
        }
        return Array(UnsafeBufferPointer(start: o.floatChannelData![0], count: Int(o.frameLength)))
    }
}
