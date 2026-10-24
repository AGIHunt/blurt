// The Structured style's list (docs/design/dictation-styles.md §3.3): spoken ordinal enumerations become a numbered
// list, deterministically, on the stitched and guarded text — no model call, a few ms. Python port with the same
// rules: scripts/dictation_styles.py (the Dictation Lab); the shared fixture tests/fixtures/dictation_lists.jsonl
// checks both.
//
//  • Markers, at a clause start (the text's start, or after 。，、；：！？ , . ; : ! ? or a line break), in sequence:
//      第一/第二/…(个/点/条/步/项/件)(是) · 一是/二是 · 一来/二来 · 其一/其二 · 一、二、(或"一，") · 1. 2. / 1、2、 ·
//      首先 … 其次 / 再次 … 最后 · first(ly) / second(ly) / third(ly) … finally / lastly · number one / two · one, two,
//    The run must start at 1 and go up by one; 最后 / finally may close any run. ≥ 2 markers when the user asked
//    (Structured), ≥ 3 for Auto.
//  • Never markers on their own: 以及, 其他, 另外, 还有, 然后, 接着, also, then. 然后 / 接着 / 另外 / 还有 / then / next
//    count only inside 首先 … 最后 (first … finally) with nothing numbered in between. 第一次 / 第一天 / 第一时间 /
//    first time … are no markers at all.
//  • Every item needs ≥ 2 units (一是一，二是二 is an idiom, not a list); otherwise nothing is rendered.
//  • Output: the text before the first marker stays as a line ending in ：/ :, each item becomes "1. …" with its marker
//    word taken out, the text after the last item's sentence stays as a closing paragraph. Only marker words go; only
//    digits, ". " and line breaks are added (DictationListTests checks that every other unit survives).
//  • No confident sequence → nil: the caller types the text unchanged.
import Foundation

public enum DictationList {
    public static let askedMarkers = 2
    public static let autoMarkers = 3

    struct Marker {
        var family: String
        /// 1, 2, 3 … ; 0 = closes the run (最后, finally); -1 = a connective (然后, then)
        var ordinal: Int
        /// the marker with its trailing punctuation (what goes)
        var range: NSRange
        var zh: Bool
    }

    public struct Detection: Equatable {
        public var markers: Int
        public var intro: String
        public var items: [String]
        public var outro: String
        /// the marker phrases taken out ("第一，", "First, ")
        public var removed: [String]
        /// where they were (UTF-16 ranges of the input)
        public var removedRanges: [NSRange] = []
    }

    // MARK: patterns

    private static let cn = "一二三四五六七八九十"
    private static func cnNumber(_ s: String) -> Int? {
        let d: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if s == "十" { return 10 }
        if s.count == 2, s.first == "十", let n = d[s.last!] { return 10 + n }
        if s.count == 1, let n = d[s.first!] { return n }
        return nil
    }
    private static let enOrd: [String: Int] = ["first": 1, "firstly": 1, "second": 2, "secondly": 2, "third": 3, "thirdly": 3,
                                               "fourth": 4, "fourthly": 4, "fifth": 5, "fifthly": 5, "finally": 0, "lastly": 0, "last": 0]
    private static let enNum: [String: Int] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                                               "eight": 8, "nine": 9, "ten": 10]
    private static let tail = "[，,、：:\\s]*"

    private static let patterns: [(NSRegularExpression, (NSTextCheckingResult, NSString) -> Marker?)] = {
        func re(_ p: String, _ ci: Bool = false) -> NSRegularExpression {
            try! NSRegularExpression(pattern: p, options: ci ? [.caseInsensitive] : [])   // swiftlint:disable:this force_try
        }
        func g(_ m: NSTextCheckingResult, _ s: NSString, _ i: Int) -> String {
            m.range(at: i).location == NSNotFound ? "" : s.substring(with: m.range(at: i))
        }
        return [
            // 第一 / 第二个 / 第三点是 — never 第一次 / 第一天 / 第一时间 / 第一眼 …
            (re("第(十[一二三四五六七八九]|[\(cn)])(?:个|点|条|步|项|件|部分)?(?:是|就是|呢)?(?![次天名年批轮届期章页句位周月季代层排场手眼印时把])\(tail)"),
             { m, s in cnNumber(g(m, s, 1)).map { Marker(family: "di", ordinal: $0, range: m.range, zh: true) } }),
            // 一是 / 二是, 一来 / 二来
            (re("([\(cn)])(是|来)\(tail)"),
             { m, s in cnNumber(g(m, s, 1)).map { Marker(family: g(m, s, 2) == "是" ? "shi" : "lai", ordinal: $0, range: m.range, zh: true) } }),
            // 其一 / 其二
            (re("其([\(cn)])\(tail)"), { m, s in cnNumber(g(m, s, 1)).map { Marker(family: "qi", ordinal: $0, range: m.range, zh: true) } }),
            // 一、/ 一，(spoken numbers at a clause start)
            (re("([\(cn)])[、．.:：，,]\\s*"), { m, s in cnNumber(g(m, s, 1)).map { Marker(family: "num", ordinal: $0, range: m.range, zh: true) } }),
            // 1. / 2、/ 3)
            (re("([0-9]{1,2})[、．.:：)）](?![0-9])\\s*"),
             { m, s in Int(g(m, s, 1)).map { Marker(family: "digit", ordinal: $0, range: m.range, zh: false) } }),
            // 首先 … 其次 / 再次 … 最后; 然后 / 接着 / 另外 / 还有 / 此外 only inside 首先 … 最后
            (re("(首先|其次|再次|最后(?:一点|一个|一条|就是)?|然后|接着|另外|还有|此外)\(tail)"), { m, s in
                let w = g(m, s, 1)
                let o = w == "首先" ? 1 : w == "其次" ? 2 : w == "再次" ? 3 : w.hasPrefix("最后") ? 0 : -1
                return Marker(family: "seq", ordinal: o, range: m.range, zh: true)
            }),
            // first(ly) … finally — never "first time", "first of the …"
            (re("(?:and\\s+)?(first(?:ly)?|second(?:ly)?|third(?:ly)?|fourth(?:ly)?|fifth(?:ly)?|finally|lastly)(?:\\s+of\\s+all)?(?![a-z’'])"
                + "(?!\\s+(?:time|times|place|day|days|name|class|prize|floor|half|quarter|impression|hand|person|of|and|or|thing)\\b)[,:]?\\s*", true),
             { m, s in enOrd[g(m, s, 1).lowercased()].map { Marker(family: "en_ord", ordinal: $0, range: m.range, zh: false) } }),
            // "last," closes a run only with its comma (never "last week")
            (re("(last)[,:]\\s*", true), { m, _ in Marker(family: "en_ord", ordinal: 0, range: m.range, zh: false) }),
            (re("(then|next|also|and then)\\b,?\\s*", true), { m, _ in Marker(family: "en_ord", ordinal: -1, range: m.range, zh: false) }),
            (re("number\\s+(one|two|three|four|five|six|seven|eight|nine|ten)\\b[,:]?\\s*", true),
             { m, s in enNum[g(m, s, 1).lowercased()].map { Marker(family: "en_num", ordinal: $0, range: m.range, zh: false) } }),
            (re("(one|two|three|four|five|six|seven|eight|nine|ten)[,:]\\s+", true),
             { m, s in enNum[g(m, s, 1).lowercased()].map { Marker(family: "en_word", ordinal: $0, range: m.range, zh: false) } }),
        ]
    }()

    private static let clauseEnds: Set<Character> = ["。", "，", ",", "、", "；", ";", "：", ":", "！", "!", "？", "?", "\n", "."]

    /// Is `loc` (UTF-16) at a clause start: the beginning, or after a clause mark (spaces between allowed)?
    private static func clauseStart(_ s: NSString, _ loc: Int) -> Bool {
        var i = loc - 1
        while i >= 0, let u = UnicodeScalar(s.character(at: i)), u == " " || u == "\t" { i -= 1 }
        if i < 0 { return true }
        guard let u = UnicodeScalar(s.character(at: i)) else { return false }
        let c = Character(u)
        if c == "." {               // a full stop, not a decimal point ("3.5") or an abbreviation inside a word
            return i == 0 || !(Character(UnicodeScalar(s.character(at: i - 1)) ?? " ").isNumber)
        }
        return clauseEnds.contains(c)
    }

    /// A later marker of a run where a seam lost its punctuation (a piece polish fell back on is joined without the
    /// mark at a short pause: 「…跑完第二，把文档…」, "…the tests Second, update…"): 第二 … / 其次 / 再次 / 最后 and
    /// Second … / Finally — a capital in English — followed at once by a comma or colon. Never the run's first marker
    /// (that one always needs its clause start).
    static func strongInside(_ m: Marker, _ phrase: String) -> Bool {
        guard m.ordinal >= 2 || m.ordinal == 0, ["di", "seq", "en_ord"].contains(m.family) else { return false }
        guard let last = phrase.trimmingCharacters(in: .whitespaces).last, "，,：:".contains(last) else { return false }
        if m.zh { return true }
        return phrase.first?.isUppercase == true
    }

    static func candidates(_ text: String) -> [Marker] {
        let s = text as NSString
        var out: [Marker] = []
        for (re, make) in patterns {
            for m in re.matches(in: text, range: NSRange(location: 0, length: s.length)) {
                guard var mk = make(m, s) else { continue }
                if !clauseStart(s, m.range.location) && !strongInside(mk, s.substring(with: m.range)) { continue }
                // a Latin marker must not be the end of a longer word ("Firstly" is matched whole; "xfirst" never)
                if !mk.zh, m.range.location > 0, let u = UnicodeScalar(s.character(at: m.range.location - 1)),
                   CharacterSet.letters.contains(u) { continue }
                mk.range = m.range
                out.append(mk)
            }
        }
        // overlapping matches (一、 inside 第一、): the longest at a position wins, then the earliest
        out.sort { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length }
        var kept: [Marker] = []
        for m in out where kept.last.map({ NSMaxRange($0.range) <= m.range.location }) ?? true { kept.append(m) }
        return kept
    }

    /// The best ordered run: the most markers, then the earliest.
    static func bestRun(_ ms: [Marker]) -> [Marker] {
        var best: [Marker] = []
        for (i, first) in ms.enumerated() where first.ordinal == 1 {
            var run = [first]
            var closed = false
            for m in ms[(i + 1)...] {
                if m.family == first.family, m.ordinal == run.last!.ordinal + 1, run.last!.ordinal > 0 { run.append(m); continue }
                if m.ordinal == 0, m.zh == first.zh, run.last!.ordinal > 0 { run.append(m); closed = true; break }
                if m.family == first.family, m.ordinal == 1 { break }          // a second list starts
            }
            // 首先 … 然后 … 最后 (first … then … finally): the connectives count only between an ordinal start and
            // an end with nothing numbered in between
            if closed, run.count == 2, first.family == "seq" || first.family == "en_ord" {
                let lo = NSMaxRange(run[0].range), hi = run[1].range.location
                let inner = ms.filter { $0.ordinal == -1 && $0.family == first.family && $0.range.location >= lo && $0.range.location < hi }
                if !inner.isEmpty { run = [run[0]] + inner + [run[1]] }
            }
            if run.count > best.count { best = run }
        }
        return best
    }

    static func unitCount(_ s: String) -> Int { DictationStitch.units(s).count }

    private static let leadPunct = CharacterSet(charactersIn: "，,、：:；;。.！!？? \t\n")
    private static let trailPunct = CharacterSet(charactersIn: "，,、；;。. \t\n")

    static func cleanItem(_ s: String) -> String {
        var t = s.trimmingCharacters(in: leadPunct.subtracting(CharacterSet(charactersIn: "！!？?")))
        while let l = t.unicodeScalars.last, trailPunct.contains(l) { t.unicodeScalars.removeLast() }
        t = t.replacingOccurrences(of: "\n", with: " ")
        // an English item starts with a capital, as a line does
        if let f = t.first, f.isASCII, f.isLowercase { t = f.uppercased() + t.dropFirst() }
        return t
    }

    /// Where the last item ends: its sentence's end (。！？ ! ? a line break, or ". "), else the text's end.
    static func lastItemEnd(_ s: NSString, from: Int) -> Int {
        var i = from
        while i < s.length {
            if let u = UnicodeScalar(s.character(at: i)) {
                let c = Character(u)
                if "。！？!?\n".contains(c) { return i + 1 }
                if c == ".", i + 1 >= s.length || s.character(at: i + 1) == 0x20 || s.character(at: i + 1) == 0x0A {
                    if i == 0 || !Character(UnicodeScalar(s.character(at: i - 1)) ?? " ").isNumber || i + 1 >= s.length { return i + 1 }
                }
            }
            i += 1
        }
        return s.length
    }

    /// The spoken list in `text`, if there is one (≥ 2 ordered markers, every item ≥ 2 units).
    public static func detect(_ text: String) -> Detection? {
        let s = text as NSString
        let run = bestRun(candidates(text))
        guard run.count >= askedMarkers else { return nil }
        var items: [String] = []
        for (k, m) in run.enumerated() {
            let start = NSMaxRange(m.range)
            let end = k + 1 < run.count ? run[k + 1].range.location : lastItemEnd(s, from: start)
            guard end >= start else { return nil }
            let item = cleanItem(s.substring(with: NSRange(location: start, length: end - start)))
            guard unitCount(item) >= 2 else { return nil }
            items.append(item)
        }
        let lastEnd = lastItemEnd(s, from: NSMaxRange(run.last!.range))
        var intro = s.substring(to: run[0].range.location).trimmingCharacters(in: .whitespacesAndNewlines)
        while let l = intro.unicodeScalars.last, CharacterSet(charactersIn: "，,；;：:。.、").contains(l) { intro.unicodeScalars.removeLast() }
        if !intro.isEmpty {
            let zh = intro.unicodeScalars.contains { DictationStitch.isCJK($0) }
            if let l = intro.last, !"？?！!".contains(l) { intro += zh ? "：" : ":" }
        }
        let outro = s.substring(from: lastEnd).trimmingCharacters(in: .whitespacesAndNewlines)
        return Detection(markers: run.count, intro: intro, items: items, outro: outro,
                         removed: run.map { s.substring(with: $0.range).trimmingCharacters(in: .whitespaces) },
                         removedRanges: run.map(\.range))
    }

    /// How many ordered markers the take has (0: none): the history's `markers`, the island's ≡ suggestion.
    public static func markers(_ text: String) -> Int { detect(text)?.markers ?? 0 }

    /// The text with its spoken list as a numbered list; nil when there is no list with at least `minMarkers` markers
    /// (the caller types the text unchanged).
    public static func render(_ text: String, minMarkers: Int = askedMarkers) -> String? {
        guard let d = detect(text), d.markers >= minMarkers else { return nil }
        var lines: [String] = []
        if !d.intro.isEmpty { lines.append(d.intro) }
        for (i, it) in d.items.enumerated() { lines.append("\(i + 1). \(it)") }
        if !d.outro.isEmpty { lines.append(d.outro) }
        return lines.joined(separator: "\n")
    }
}
