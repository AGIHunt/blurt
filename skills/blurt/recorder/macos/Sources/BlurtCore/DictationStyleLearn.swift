// Learning the user's style preference from their switches (docs/design/dictation-styles.md §3.5, build step 6):
// suggest, never switch silently. ≥ 3 consistent signals in an app (≥ 70 % one way) → the island asks once
// ("Format spoken lists in Notes from now on?"); the answer is remembered either way. Pure: DictationStyleLearnTests.
import Foundation

public enum DictationStyleLearn {
    /// An app's name set into a Chinese question whose format has no spaces around it ("以后在%@里…"): a space only on
    /// a side where the name begins or ends in Latin letters or digits — "以后在 Notes 里", "以后在Safari浏览器里".
    /// `cjk` false (English formats carry their own spaces): the name as it is.
    public static func inline(_ name: String, cjk: Bool) -> String {
        guard cjk, let first = name.first, let last = name.last else { return name }
        let latin = { (c: Character) in c.isASCII && (c.isLetter || c.isNumber) }
        return (latin(first) ? " " : "") + name + (latin(last) ? " " : "")
    }

    public static let minSignals = 3
    public static let share = 0.7
    /// the last this-many signals of an app count
    public static let window = 10

    /// What one take says the user wants in its app (nil: nothing). Lists (structured / auto) count as one wish.
    ///  • a reformat that was kept → its style; undone → the style it had;
    ///  • ⇧ / the island / Fn+⇧ → that style;
    ///  • a list the user took apart in the field → light;
    ///  • a take that sounded like a list, left as prose (the ≡ suggestion ignored) → light.
    public static func signal(_ r: DictationStyleRecord) -> DictationStyle? {
        func norm(_ s: String) -> DictationStyle? { DictationStyle(rawValue: s).map { $0 == .auto ? .structured : $0 } }
        let acts = r.reformats.filter { $0.action != "suggest" }          // an offer is no choice of the user's
        if let last = acts.last(where: { $0.action != "revert" }) {
            if acts.contains(where: { $0.action == "revert" && $0.time > last.time }) { return .light }
            return norm(last.to)            // an undo goes back `to` the style the take had
        }
        if acts.contains(where: { $0.action == "revert" }) { return .light }
        if ["shift", "island", "chord"].contains(r.source) { return norm(r.style) }
        if r.listLikely, r.style == DictationStyle.light.rawValue { return .light }
        return nil
    }

    public struct Suggestion: Equatable {
        public var bundle: String
        public var app: String?
        /// what to make the app's style: auto (lists when confident), light or verbatim
        public var style: DictationStyle
        public var signals: Int
        /// "bundle|style": asked once, whatever the answer
        public var key: String { "\(bundle)|\(style.rawValue)" }
    }

    /// The suggestion for `bundle` now, if its signals agree and it hasn't been asked: entries newest first (as
    /// DictationHistory.load returns them), `current` = the app's style today.
    public static func suggest(entries: [DictationEntry], bundle: String, current: DictationStyle, asked: Set<String>) -> Suggestion? {
        let mine = entries.filter { $0.bundle == bundle }
        let signals = mine.compactMap { $0.style.flatMap(signal) }.prefix(window)
        guard signals.count >= minSignals else { return nil }
        var count: [DictationStyle: Int] = [:]
        for s in signals { count[s, default: 0] += 1 }
        guard let (top, n) = count.max(by: { $0.value < $1.value }), n >= minSignals,
              Double(n) / Double(signals.count) >= share else { return nil }
        let now: DictationStyle = current == .auto ? .structured : current
        guard top != now else { return nil }
        let target: DictationStyle = top == .structured ? .auto : top
        let s = Suggestion(bundle: bundle, app: mine.first?.app, style: target, signals: n)
        return asked.contains(s.key) ? nil : s
    }
}
