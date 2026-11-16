// How fast dictation is on this Mac, from the history's own timings (DictationEntry.timing, written since v0.9:
// asr_ms / polish_ms / structure_ms / translate_ms / load_ms are what the user waited for after key-up, total_ms is
// key-up → text at the cursor; docs/design/dictation.md §Latency). Shown on the Dictation page (the first day
// heading: "Usually 0.4 s after you stop"; each entry's details: its own wait and what it was spent on) and in
// Settings → Models / → Dictation next to the model in use. Pure: DictationSpeedTests.
//
// Only dictations that typed (or copied) text count: a cancelled, failed or empty take has no "wait for the text".
// Nothing is said from fewer than `minimum` takes — one slow first take (a model loading) is not "usually".
import Foundation

public struct DictationSpeed: Equatable, Sendable {
    /// the most recent takes it looks at
    public static let window = 50
    /// fewer takes than this: say nothing
    public static let minimum = 5
    /// a take this long (seconds spoken) or longer is a "long" one, said apart when there are enough of them
    public static let longTake: Double = 30
    /// long takes needed before their own figure is said
    public static let longMinimum = 3

    /// how many takes the figures are over
    public let count: Int
    /// median key-up → text (ms)
    public let medianMS: Int
    /// median recognition after key-up (ms), over the takes that recorded it
    public let asrMedianMS: Int?
    /// median key-up → text of the long takes among them (nil: fewer than `longMinimum`)
    public let longMedianMS: Int?
    public let longCount: Int

    /// The last `window` takes that typed something and recorded their wait (newest first by time), optionally only
    /// those heard by one speech model; nil below `minimum`.
    public init?(_ entries: [DictationEntry], model: String? = nil) {
        let used = entries.filter { DictationSpeed.counts($0) && (model == nil || $0.asrModel == model) }
            .sorted { $0.time > $1.time }
            .prefix(DictationSpeed.window)
        guard used.count >= DictationSpeed.minimum else { return nil }
        let totals = used.compactMap { $0.timing?["total_ms"] }
        count = used.count
        medianMS = DictationSpeed.median(totals)
        let asr = used.compactMap { $0.timing?["asr_ms"] }
        asrMedianMS = asr.count >= DictationSpeed.minimum ? DictationSpeed.median(asr) : nil
        let long = used.filter { $0.duration >= DictationSpeed.longTake }.compactMap { $0.timing?["total_ms"] }
        longCount = long.count
        longMedianMS = long.count >= DictationSpeed.longMinimum ? DictationSpeed.median(long) : nil
    }

    /// A take whose wait means something: it typed or copied text, and recorded key-up → text.
    public static func counts(_ e: DictationEntry) -> Bool {
        guard let t = e.timing?["total_ms"], t >= 0 else { return false }
        if e.text.isEmpty || e.insert == "none" { return false }
        if let r = e.reason, r.hasPrefix("asr_failed") || r == "nothing_heard" { return false }
        return true
    }

    /// The middle value (the mean of the two middle ones for an even count); 0 for none.
    public static func median(_ xs: [Int]) -> Int {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : Int((Double(s[n / 2 - 1] + s[n / 2]) / 2).rounded())
    }

    // MARK: one take

    /// The parts of a take's wait, in the order they happen.
    public enum Stage: String, CaseIterable, Sendable {
        case load, asr, polish, structure, translate
        public var key: String { rawValue + "_ms" }
    }

    /// What one take's wait after key-up went on — only what ran (a stage that took no time after key-up, or isn't
    /// recorded, is left out). Empty for a take without timings.
    public static func stages(_ e: DictationEntry) -> [(stage: Stage, ms: Int)] {
        guard let t = e.timing, t["total_ms"] != nil else { return [] }
        return Stage.allCases.compactMap { s in t[s.key].flatMap { $0 > 0 ? (s, $0) : nil } }
    }

    /// key-up → text for a take that counts (nil: no timings, or nothing was typed).
    public static func total(_ e: DictationEntry) -> Int? { counts(e) ? e.timing?["total_ms"] : nil }

    // MARK: saying it

    /// Seconds as they are said: tenths ("0.4", "1.2"), whole seconds from 10 s; nil under 0.1 s ("under 0.1 s").
    public static func seconds(_ ms: Int) -> Double? {
        guard ms >= 100 else { return nil }
        let s = Double(ms) / 1000
        return s >= 10 ? s.rounded() : (s * 10).rounded() / 10
    }

    /// "0.4", "1.2", "1", "12" in the locale's own digits and decimal mark; nil under 0.1 s.
    public static func secondsText(_ ms: Int, locale: Locale) -> String? {
        guard let s = seconds(ms) else { return nil }
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = s >= 10 ? 0 : 1
        return f.string(from: s as NSNumber) ?? String(s)
    }
}
