// Learning from the user's own fixes (docs/design/dictation.md §Auto-learn): after a dictation is typed, the app
// watches the same text field for about a minute; when the user edits what was typed, the edit is compared with the
// typed text here, word by word (and character by character for Chinese), and a short span replaced by something
// that sounds or looks like it becomes a vocabulary suggestion (DictationVocabulary.learn). Pure, unit-tested
// (Tests/BlurtCoreTests/DictationLearnTests). Nothing here keeps the surrounding text.
import Foundation

public enum DictationLearn {
    /// A word, a number, or one CJK character, with where it sits in its string (UTF-16 offsets).
    public struct Token: Equatable {
        public let text: String
        public let range: NSRange
        public var cjk: Bool
    }

    public struct Fix: Equatable {
        public let heard: String
        public let fixed: String
        public let kind: Kind
        public enum Kind: String { case spelling, sound, caseOrSpacing = "case" }
        public init(heard: String, fixed: String, kind: Kind) { self.heard = heard; self.fixed = fixed; self.kind = kind }
    }

    static func isCJK(_ c: unichar) -> Bool {
        (0x3400...0x4DBF).contains(c) || (0x4E00...0x9FFF).contains(c) || (0xF900...0xFAFF).contains(c)
    }

    public static func tokens(_ s: String) -> [Token] {
        let ns = s as NSString
        var out: [Token] = []
        var i = 0
        let n = ns.length
        func isWord(_ c: unichar) -> Bool {
            guard let u = Unicode.Scalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(u) && !isCJK(c)
        }
        while i < n {
            let c = ns.character(at: i)
            if isCJK(c) {
                out.append(Token(text: ns.substring(with: NSRange(location: i, length: 1)), range: NSRange(location: i, length: 1), cjk: true))
                i += 1
            } else if isWord(c) {
                var j = i + 1
                // a word goes on through letters and digits, and through an apostrophe or a hyphen between them
                while j < n {
                    let d = ns.character(at: j)
                    if isWord(d) { j += 1; continue }
                    if (d == 0x27 || d == 0x2019 || d == 0x2D), j + 1 < n, isWord(ns.character(at: j + 1)) { j += 2; continue }
                    break
                }
                out.append(Token(text: ns.substring(with: NSRange(location: i, length: j - i)), range: NSRange(location: i, length: j - i), cjk: false))
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    /// Longest common subsequence of two token lists (by text): the index pairs that match, in order.
    static func lcs(_ a: [Token], _ b: [Token]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i].text == b[j].text ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i].text == b[j].text { out.append((i, j)); i += 1; j += 1 } else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        return out
    }

    /// The replaced spans between what was typed and what the field holds now: (typed tokens, edited tokens) runs
    /// that sit between the same unchanged neighbours. Pure insertions and deletions are left out.
    static func replacements(_ a: [Token], _ b: [Token]) -> [(ArraySlice<Token>, ArraySlice<Token>, Int, Int)] {
        var out: [(ArraySlice<Token>, ArraySlice<Token>, Int, Int)] = []
        var pi = 0, pj = 0
        for (i, j) in lcs(a, b) + [(a.count, b.count)] {
            if i > pi && j > pj { out.append((a[pi..<i], b[pj..<j], pi, pj)) }
            pi = i + 1
            pj = j + 1
        }
        return out
    }

    static func text(_ ts: ArraySlice<Token>, in s: String) -> String {
        guard let f = ts.first, let l = ts.last else { return "" }
        return (s as NSString).substring(with: NSRange(location: f.range.location, length: NSMaxRange(l.range) - f.range.location))
    }

    // MARK: similarity

    static func key(_ s: String) -> String { DictationVocabulary.key(s) }

    static func lev(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var cur = [i + 1]
            for (j, y) in b.enumerated() { cur.append(min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (x == y ? 0 : 1))) }
            prev = cur
        }
        return prev[b.count]
    }

    static func ratio(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        let n = max(x.count, y.count)
        return n == 0 ? 1 : 1 - Double(lev(x, y)) / Double(n)
    }

    /// Mandarin → toneless pinyin, no spaces ("口喷鸡" → "koupenji"); Latin stays (lower case).
    public static func pinyin(_ s: String) -> String {
        let m = NSMutableString(string: s) as CFMutableString
        CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
        return key(m as String).filter { $0.isLetter || $0.isNumber }
    }

    static func skeleton(_ s: String) -> String { String(s.filter { !"aeiouyhw".contains($0) }) }

    /// How `heard` and `fixed` are alike, or nil when the fix isn't a recognition fix (a different word, a rewrite).
    public static func similarity(_ heard: String, _ fixed: String) -> Fix.Kind? {
        let h = key(heard), f = key(fixed)
        guard !h.isEmpty, !f.isEmpty, heard != fixed else { return nil }
        if h == f { return .caseOrSpacing }
        let hasCJK = { (s: String) in s.utf16.contains(where: isCJK) }
        if !hasCJK(heard) && !hasCJK(fixed) {
            if ratio(h, f) >= 0.5 { return .spelling }
            if h.count >= 2 && f.hasPrefix(h) { return .spelling }                  // cut short: op → option, bl → blurt
            let a = skeleton(h), b = skeleton(f)
            if a.count >= 2 && a == b { return .sound }                            // cloud → Claude
            return nil
        }
        // pinyin against pinyin, or against the Latin spelling; c and k sound alike across the two (克劳德 → Claude)
        let p = pinyin(heard).replacingOccurrences(of: "c", with: "k"), q = pinyin(fixed).replacingOccurrences(of: "c", with: "k")
        guard !p.isEmpty, !q.isEmpty else { return nil }
        if p == q || ratio(p, q) >= 0.6 { return .sound }                            // 口喷机 → 口喷鸡, 克劳德 → Claude
        if skeleton(p).count >= 2 && skeleton(p) == skeleton(q) { return .sound }
        return nil
    }

    // MARK: the fixes in an edit

    /// Limits: longer replacements are rewrites, not recognition fixes.
    static let maxWords = 3, maxCJK = 4, maxFixedWords = 4, maxFixedCJK = 6, maxFixes = 3

    /// What the user fixed in the typed text. Empty when the edit isn't a handful of small recognition fixes (a
    /// rewrite, a new sentence, too many changes). `isCommonWord`: an ordinary dictionary word in lower case is not
    /// learned as a term (their → there is grammar, not vocabulary), unless the typed word was cut short of it.
    public static func fixes(typed: String, edited: String, isCommonWord: (String) -> Bool = { _ in false }) -> [Fix] {
        let a = tokens(typed), b = tokens(edited)
        guard !a.isEmpty, !b.isEmpty, a.map(\.text) != b.map(\.text) else { return [] }
        let same = lcs(a, b).count
        // mostly the same text: at least half of the typed tokens survive
        guard Double(same) / Double(a.count) >= 0.5 else { return [] }
        let reps = replacements(a, b)
        guard !reps.isEmpty, reps.count <= maxFixes else { return [] }
        var out: [Fix] = []
        for (x, y, xi, yi) in reps {
            var xs = x, ys = y
            let cjk = xs.allSatisfy(\.cjk) && ys.allSatisfy(\.cjk)
            let words = xs.filter { !$0.cjk }.count, chars = xs.filter(\.cjk).count
            let fwords = ys.filter { !$0.cjk }.count, fchars = ys.filter(\.cjk).count
            if words > maxWords || chars > maxCJK || fwords > maxFixedWords || fchars > maxFixedCJK { continue }
            // one Chinese character alone means nothing as a term: take the unchanged characters before it (口喷 + 机→鸡)
            if cjk && ys.count < 2 {
                var lo = xi, lj = yi
                while lo > 0, lj > 0, xs.count < 3, a[lo - 1].cjk, b[lj - 1].cjk, a[lo - 1].text == b[lj - 1].text,
                      NSMaxRange(a[lo - 1].range) == xs.first!.range.location {
                    lo -= 1; lj -= 1
                    xs = a[lo..<(xi + x.count)]
                    ys = b[lj..<(yi + y.count)]
                }
                if ys.count < 2 { continue }
            }
            let heard = text(xs, in: typed), fixed = text(ys, in: edited)
            guard let kind = similarity(heard, fixed) else { continue }
            let plainWord = fixed == fixed.lowercased() && !fixed.contains(" ") && !fixed.utf16.contains(where: isCJK)
                && !fixed.contains(where: \.isNumber)
            if plainWord && isCommonWord(fixed) && !key(fixed).hasPrefix(key(heard)) { continue }
            out.append(Fix(heard: heard, fixed: fixed, kind: kind))
        }
        return out
    }

    // MARK: finding the typed text again

    /// The text between `prefix` and `suffix` in `text`, taking the `prefix` that ends nearest `near` (UTF-16). The
    /// prefix / suffix are a few dozen characters around the dictation, held only while it is watched. nil = they
    /// aren't there any more (the user moved on, or rewrote around it).
    public static func locate(in text: String, prefix: String, suffix: String, near: Int, maxLength: Int) -> String? {
        let ns = text as NSString
        var starts: [Int] = []
        if prefix.isEmpty { starts = [0] } else {
            var r = NSRange(location: 0, length: ns.length)
            while true {
                let f = ns.range(of: prefix, options: [], range: r)
                if f.location == NSNotFound { break }
                starts.append(NSMaxRange(f))
                let next = f.location + 1
                if next >= ns.length { break }
                r = NSRange(location: next, length: ns.length - next)
            }
        }
        guard let start = starts.min(by: { abs($0 - near) < abs($1 - near) }) else { return nil }
        let end: Int
        if suffix.isEmpty { end = ns.length } else {
            let f = ns.range(of: suffix, options: [], range: NSRange(location: start, length: ns.length - start))
            guard f.location != NSNotFound else { return nil }
            end = f.location
        }
        guard end - start <= maxLength else { return nil }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    // MARK: ordinary words

    private static var words: Set<String>?
    private static let wordsLock = NSLock()

    /// An ordinary English word (macOS's /usr/share/dict/words, lower-case entries; the same list dictation_vocab.py
    /// uses), loaded on first use.
    public static func isCommonWord(_ w: String) -> Bool {
        wordsLock.lock(); defer { wordsLock.unlock() }
        if words == nil {
            var set = Set<String>()
            if let s = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) {
                for line in s.split(separator: "\n") where line.first?.isLowercase == true { set.insert(String(line)) }
            }
            words = set
        }
        return words!.contains(w.lowercased())
    }
}
