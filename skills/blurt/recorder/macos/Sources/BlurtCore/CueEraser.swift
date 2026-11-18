// Takes Blurt's own start cue (Peep's peep, DictationSound) back out of the microphone's audio.
//
// The peep plays when the mic's first audio arrives ("talk now"), so on the Mac's speakers the mic records it: it was in
// 203 of the founder's last 300 kept takes, 0.20 s in, around −30 dBFS (2026-11-12, docs/design/dictation.md §Start
// cue). It doesn't change what the recognizer writes, but it is in every kept recording, in the audio a personal model is
// trained on, and in what the voiceprint and the endpointer hear.
//
// The app knows what it played and roughly when. From `armed(at:)` the samples are held for `searchSeconds` + the cue's
// length (about 0.85 s, once a take): the cue is found by normalized cross-correlation, a short FIR from the clip to
// the recording (the speaker, the room, the mic) is fitted by least squares over the cue's window and subtracted, and
// what is left there is turned down unless it is loud enough to be the speaker already talking. With headphones (no
// match) the samples go on unchanged. Signal processing only: nothing here interprets speech.
import Accelerate

public struct CueEraser {
    public struct Result: Equatable {
        /// where the cue started, samples after the arming point
        public let offset: Int
        public let match: Float
        /// the cue window's level before and after (dBFS)
        public let beforeDB: Float
        public let afterDB: Float
        /// true: the window was turned down after the subtraction; false: speech was there too, only subtracted
        public let muted: Bool
    }

    public let sampleRate: Double
    /// how long after the cue was started it may appear in the recording (output + input latency, buffering)
    public var searchSeconds: Double = 0.6
    /// a correlation below this is no cue (headphones, or the volume down)
    public var minMatch: Float = 0.5
    /// …or this, when the peak stands this many times above the correlation's median (the speaker already talking)
    public var minMatchUnderSpeech: Float = 0.12
    public var minProminence: Float = 12
    /// after the subtraction, a window quieter than this (or followed by 0.2 s quieter than this) holds only the cue's
    /// remains and is turned down; louder, with talk after it, is speech that began during the peep
    public var speechDB: Float = -38
    /// the turned-down window's gain (≈ −30 dB: room tone stays, no hole of digital silence)
    public var floorGain: Float = 0.03
    static let taps = 48

    private let cue: [Float]
    private var held: [Float] = []
    private var holding = false
    public private(set) var result: Result?

    /// cue: the clip as played, mono, at `sampleRate` (DictationSound's start.wav, resampled)
    public init(cue: [Float], sampleRate: Double) {
        self.cue = cue
        self.sampleRate = sampleRate
    }

    /// The cue just started playing: samples from now on are held until it has been found (or not).
    public mutating func armed() {
        guard !cue.isEmpty, result == nil, !holding else { return }
        holding = true
        held.removeAll(keepingCapacity: true)
    }

    public var isHolding: Bool { holding }

    /// Samples in, samples out: the same ones while nothing is armed; while armed, nothing until the search window is
    /// in, then all of it with the cue taken out.
    public mutating func process(_ x: [Float]) -> [Float] {
        guard holding else { return x }
        held += x
        guard held.count >= Int(searchSeconds * sampleRate) + cue.count + tail else { return [] }
        return release()
    }

    /// The take ends while samples are held: they go out now, cue taken out if it is in them.
    public mutating func flush() -> [Float] {
        guard holding else { return [] }
        return release()
    }

    private var pre: Int { Int(0.01 * sampleRate) }
    private var tail: Int { Int(0.04 * sampleRate) }    // the room's ring after the clip ends

    private mutating func release() -> [Float] {
        holding = false
        var y = held
        held = []
        if let r = erase(&y) { result = r }
        return y
    }

    /// Finds the cue in `y` and takes it out in place.
    func erase(_ y: inout [Float]) -> Result? {
        let n = cue.count
        let lags = min(Int(searchSeconds * sampleRate), y.count - n)
        guard lags > 0 else { return nil }
        // normalized cross-correlation: <y[k..k+n], cue> / (|y[k..k+n]| |cue|)
        var corr = [Float](repeating: 0, count: lags + 1)
        y.withUnsafeBufferPointer { yp in
            cue.withUnsafeBufferPointer { cp in
                vDSP_conv(yp.baseAddress!, 1, cp.baseAddress!, 1, &corr, 1, vDSP_Length(lags + 1), vDSP_Length(n))
            }
        }
        var cueNorm: Float = 0
        vDSP_svesq(cue, 1, &cueNorm, vDSP_Length(n))
        cueNorm = cueNorm.squareRoot()
        var energy: Float = 0
        for i in 0..<n { energy += y[i] * y[i] }
        var best = 0, bestMatch: Float = -1
        for k in 0...lags {
            if k > 0 { energy += y[k + n - 1] * y[k + n - 1] - y[k - 1] * y[k - 1] }
            let m = corr[k] / (max(energy, 1e-12).squareRoot() * cueNorm)
            if m > bestMatch { bestMatch = m; best = k }
        }
        // speech over the cue lowers the normalized match (its energy is in the window too); the clip still stands out
        // as a sharp peak of the raw correlation, far above the correlation with everything else in the search window
        var mags = corr.map { abs($0) }
        mags.sort()
        let prominence = abs(corr[best]) / max(mags[mags.count / 2], 1e-9)
        guard bestMatch >= minMatch || (bestMatch >= minMatchUnderSpeech && prominence >= minProminence) else { return nil }

        let a = max(0, best - pre), b = min(y.count, best + n + tail)
        let before = CueEraser.db(y[best..<min(y.count, best + n)])
        // least-squares FIR h (taps): y[a..<b] ≈ Σ_t h[t] · cue[i − best − t]
        let T = CueEraser.taps, len = b - a
        func x(_ i: Int, _ t: Int) -> Float {        // the clip, delayed by t, at window row i
            let j = a + i - best - t
            return j >= 0 && j < n ? cue[j] : 0
        }
        var ata = [Double](repeating: 0, count: T * T), atb = [Double](repeating: 0, count: T)
        for i in 0..<len {
            let yi = Double(y[a + i])
            for t in 0..<T {
                let xt = Double(x(i, t))
                if xt == 0 { continue }
                atb[t] += xt * yi
                for u in t..<T { ata[t * T + u] += xt * Double(x(i, u)) }
            }
        }
        for t in 0..<T { for u in 0..<t { ata[t * T + u] = ata[u * T + t] }; ata[t * T + t] += 1e-6 }
        guard let h = CueEraser.solve(ata, atb, T) else { return nil }
        for i in 0..<len {
            var fit = 0.0
            for t in 0..<T { fit += h[t] * Double(x(i, t)) }
            y[a + i] -= Float(fit)
        }
        let left = CueEraser.db(y[best..<min(y.count, best + n)])
        // what is left is only the cue's remains (the subtraction can't follow the speaker's distortion fully) when it
        // is quiet, or when nobody talks in the 0.2 s after it either: speech that started during the peep goes on
        let after = CueEraser.db(y[min(y.count, b)..<min(y.count, b + Int(0.2 * sampleRate))])
        let mute = left < speechDB || (b < y.count && after < speechDB)
        if mute {
            let fade = max(1, Int(0.008 * sampleRate))
            for i in a..<b {
                let edge = min(i - a, b - 1 - i)
                let g = edge >= fade ? floorGain : 1 - (1 - floorGain) * Float(edge) / Float(fade)
                y[i] *= g
            }
        }
        return Result(offset: best, match: bestMatch, beforeDB: before, afterDB: mute ? CueEraser.db(y[best..<min(y.count, best + n)]) : left,
                      muted: mute)
    }

    static func db(_ s: ArraySlice<Float>) -> Float {
        guard !s.isEmpty else { return -120 }
        var sum: Float = 0
        for v in s { sum += v * v }
        return 10 * log10(max(sum / Float(s.count), 1e-12))
    }

    /// Gaussian elimination with partial pivoting (T×T, T = 48).
    static func solve(_ m: [Double], _ v: [Double], _ n: Int) -> [Double]? {
        var a = m, b = v
        for c in 0..<n {
            var p = c
            for r in c + 1..<n where abs(a[r * n + c]) > abs(a[p * n + c]) { p = r }
            guard abs(a[p * n + c]) > 1e-12 else { return nil }
            if p != c {
                for k in 0..<n { a.swapAt(c * n + k, p * n + k) }
                b.swapAt(c, p)
            }
            for r in c + 1..<n {
                let f = a[r * n + c] / a[c * n + c]
                if f == 0 { continue }
                for k in c..<n { a[r * n + k] -= f * a[c * n + k] }
                b[r] -= f * b[c]
            }
        }
        var out = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for k in r + 1..<n { s -= a[r * n + k] * out[k] }
            out[r] = s / a[r * n + r]
        }
        return out
    }
}
