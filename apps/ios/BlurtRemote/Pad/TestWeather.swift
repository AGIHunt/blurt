// A made-up bad network for the measured runs (docs/design/remote-realtime.md), debug builds only. The simulator's loopback loses nothing
// and never stalls; a phone on Wi-Fi does both. Applied to the picture's pieces as they arrive, before anything else sees them:
//
//  • BLURT_TEST_LOSS=rate[:burst] drops pieces at that rate, in runs of `burst` on average (Gilbert–Elliott: Wi-Fi loses in bursts)
//  • BLURT_TEST_STALL=ms:seconds holds every piece for `ms` once every `seconds`, then lets them all through at once: a radio dozing,
//    a busy channel, a scan for other networks
#if DEBUG
import Foundation

struct TestWeather {
    private let rate: Double, burst: Double
    private let stall: Double, every: Double
    private var bad = false
    private var stallStart = 0.0, nextStall = 0.0
    private(set) var dropped = 0
    private var rng = SystemRandomNumberGenerator()

    init(_ env: [String: String]) {
        let l = (env["BLURT_TEST_LOSS"] ?? "").split(separator: ":").compactMap { Double($0) }
        rate = l.first ?? 0
        burst = max(1, l.count > 1 ? l[1] : 1)
        let s = (env["BLURT_TEST_STALL"] ?? "").split(separator: ":").compactMap { Double($0) }
        stall = (s.first ?? 0) / 1000
        every = s.count > 1 ? s[1] : 1
    }

    /// False: dropped, or held (`later` gets it when the stall ends).
    mutating func passes(_ d: Data, now: Double, later: @escaping (Data) -> Void) -> Bool {
        if stall > 0 {
            if nextStall == 0 { nextStall = now + every }
            if now >= nextStall {
                stallStart = nextStall
                nextStall += every
            }
            if now < stallStart + stall {
                let release = stallStart + stall - now
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + release) { later(d) }
                return false
            }
        }
        guard rate > 0 else { return true }
        // two states: in a bad run every piece is lost; a run ends with 1/burst, and starts so that the average loss is `rate`
        let end = 1 / burst, start = rate * end / max(1e-9, 1 - rate)
        bad = bad ? Double.random(in: 0..<1, using: &rng) >= end : Double.random(in: 0..<1, using: &rng) < start
        if bad { dropped += 1 }
        return !bad
    }
}
#endif
