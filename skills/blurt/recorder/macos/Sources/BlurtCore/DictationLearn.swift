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

    /// English function words: a fix on one of them is grammar, and none of them anchors a learned phrase.
    static let functionWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "by", "from", "as", "is", "are",
        "was", "were", "be", "been", "am", "it", "its", "it's", "this", "that", "these", "those", "there", "their", "they're",
        "they", "them", "he", "she", "we", "you", "your", "you're", "i", "my", "our", "his", "her", "not", "no", "do", "does",
        "did", "have", "has", "had", "can", "could", "will", "would", "should", "may", "might", "so", "if", "then", "than",
        "too", "two", "who", "whose", "what", "which", "where", "when", "how", "here", "hear", "we're", "lets", "let's"]

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
            // one run can hold two fixes the user made side by side ("绘画 BA 三" → "会话，BA-3"): it is cut where the
            // edited text has punctuation or changes script, and each part is a fix of its own — never one term with
            // a comma in it
            for (xs, ys, i, j) in split(x, y, xi, yi, typed: typed, edited: edited) {
                if let f = fix(xs, ys, xi: i, yi: j, a: a, b: b, typed: typed, edited: edited, isCommonWord: isCommonWord) {
                    out.append(f)
                }
            }
        }
        return Array(out.prefix(maxFixes))
    }

    /// The text between two neighbouring tokens has punctuation (anything but spaces), or they are in different scripts
    /// (Chinese next to Latin): a point where one fix ends and the next can begin.
    static func boundary(_ l: Token, _ r: Token, in s: String) -> Bool {
        if l.cjk != r.cjk { return true }
        let ns = s as NSString
        let from = NSMaxRange(l.range), to = r.range.location
        guard to > from else { return false }
        return !ns.substring(with: NSRange(location: from, length: to - from)).allSatisfy { $0 == " " }
    }

    /// A replaced run cut at the edited side's boundaries, the typed tokens shared out to the parts so each part pairs
    /// with what sounds most like it (every contiguous split is tried: the runs are a few tokens). One part: the run.
    static func split(_ x: ArraySlice<Token>, _ y: ArraySlice<Token>, _ xi: Int, _ yi: Int, typed: String, edited: String)
        -> [(ArraySlice<Token>, ArraySlice<Token>, Int, Int)] {
        var cuts: [Int] = []          // indices into y where a new part starts
        for k in y.indices.dropFirst() where boundary(y[k - 1], y[k], in: edited) { cuts.append(k) }
        guard !cuts.isEmpty else { return [(x, y, xi, yi)] }
        let bounds = [y.startIndex] + cuts + [y.endIndex]
        let parts = (0..<(bounds.count - 1)).map { y[bounds[$0]..<bounds[$0 + 1]] }
        let n = x.count, m = parts.count
        guard n >= m else { return [] }          // fewer typed tokens than parts: not a recognition fix
        func score(_ xs: ArraySlice<Token>, _ ys: ArraySlice<Token>) -> Double {
            let h = text(xs, in: typed), f = text(ys, in: edited)
            guard similarity(h, f) != nil else { return 0 }
            let ph = pinyin(h), pf = pinyin(f)
            return 1 + ratio(ph.isEmpty ? key(h) : ph, pf.isEmpty ? key(f) : pf)
        }
        // best[k][j]: the best score sharing the first j typed tokens out to the first k parts (and how)
        var best = Array(repeating: Array(repeating: -1.0, count: n + 1), count: m + 1)
        var from = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        best[0][0] = 0
        for k in 1...m {
            for j in k...n where n - j >= m - k {
                for i in (k - 1)..<j where best[k - 1][i] >= 0 {
                    let xs = x[(x.startIndex + i)..<(x.startIndex + j)]
                    let v = best[k - 1][i] + score(xs, parts[k - 1])
                    if v > best[k][j] { best[k][j] = v; from[k][j] = i }
                }
            }
        }
        var out: [(ArraySlice<Token>, ArraySlice<Token>, Int, Int)] = []
        var j = n
        for k in stride(from: m, through: 1, by: -1) {
            let i = from[k][j]
            let xs = x[(x.startIndex + i)..<(x.startIndex + j)]
            out.append((xs, parts[k - 1], xi + i, yi + (parts[k - 1].startIndex - y.startIndex)))
            j = i
        }
        return out.reversed()
    }

    /// One replaced span → the fix it is, or nil (a rewrite, a different word, grammar).
    static func fix(_ x: ArraySlice<Token>, _ y: ArraySlice<Token>, xi: Int, yi: Int, a: [Token], b: [Token], typed: String,
                    edited: String, isCommonWord: (String) -> Bool) -> Fix? {
        var xs = x, ys = y
        let cjk = xs.allSatisfy(\.cjk) && ys.allSatisfy(\.cjk)
        let words = xs.filter { !$0.cjk }.count, chars = xs.filter(\.cjk).count
        let fwords = ys.filter { !$0.cjk }.count, fchars = ys.filter(\.cjk).count
        if words > maxWords || chars > maxCJK || fwords > maxFixedWords || fchars > maxFixedCJK { return nil }
        // one Chinese character alone means nothing as a term: take the unchanged characters before it (口喷 + 机→鸡)
        if cjk && ys.count < 2 {
            var lo = xi, lj = yi
            while lo > 0, lj > 0, xs.count < 3, a[lo - 1].cjk, b[lj - 1].cjk, a[lo - 1].text == b[lj - 1].text,
                  NSMaxRange(a[lo - 1].range) == xs.first!.range.location {
                lo -= 1; lj -= 1
                xs = a[lo..<(xi + x.count)]
                ys = b[lj..<(yi + y.count)]
            }
            if ys.count < 2 { return nil }
        }
        var heard = text(xs, in: typed), fixed = text(ys, in: edited)
        guard let kind = similarity(heard, fixed) else { return nil }
        let plainWord = fixed == fixed.lowercased() && !fixed.contains(" ") && !fixed.utf16.contains(where: isCJK)
            && !fixed.contains(where: \.isNumber)
        if plainWord && isCommonWord(fixed) && !key(fixed).hasPrefix(key(heard)) {
            // an ordinary word: grammar (there → their) is not vocabulary; a misheard word in a phrase is
            // (pool request → pull request): learn the phrase with its unchanged neighbour, which only ever
            // replaces that exact phrase
            if functionWords.contains(fixed) || functionWords.contains(heard.lowercased()) || xs.count != 1 || ys.count != 1 { return nil }
            let ai = xi + x.count, bi = yi + y.count
            func plainNeighbour(_ t: Token) -> Bool { !t.cjk && !functionWords.contains(t.text.lowercased()) }
            if ai < a.count, bi < b.count, a[ai].text == b[bi].text, plainNeighbour(a[ai]),
               NSMaxRange(xs.last!.range) + 1 == a[ai].range.location, NSMaxRange(ys.last!.range) + 1 == b[bi].range.location {
                xs = a[xi...ai]; ys = b[yi...bi]
            } else if xi > 0, yi > 0, a[xi - 1].text == b[yi - 1].text, plainNeighbour(a[xi - 1]),
                      NSMaxRange(a[xi - 1].range) + 1 == xs.first!.range.location, NSMaxRange(b[yi - 1].range) + 1 == ys.first!.range.location {
                xs = a[(xi - 1)...xi]; ys = b[(yi - 1)...yi]
            } else { return nil }
            heard = text(xs, in: typed)
            fixed = text(ys, in: edited)
        }
        // a term never carries sentence punctuation (the split above keeps it out; this is the last word)
        guard !DictationVocabulary.hasSentencePunctuation(fixed) else { return nil }
        return Fix(heard: heard, fixed: fixed, kind: kind)
    }

    // MARK: the after-typing watch

    /// What the watch of a typed take learns from: the text as typed, the field's latest state of it; one diff, at the
    /// end. A pause in the middle of an edit is never taken as the user's final word.
    public struct EditWatch: Equatable {
        public let typed: String
        public private(set) var latest: String
        public init(typed: String) { self.typed = typed; latest = typed }
        /// A tick saw the typed text's span as `now`.
        public mutating func saw(_ now: String) { latest = now }
        /// The watch ends: the edit to learn from (typed → latest), or nil when nothing changed.
        public func end() -> (typed: String, edited: String)? {
            latest != typed && !latest.isEmpty ? (typed, latest) : nil
        }
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
        wordsLock.lock()
        if words == nil {
            var set = Set<String>()
            if let s = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) {
                for line in s.split(separator: "\n") where line.first?.isLowercase == true { set.insert(String(line)) }
            }
            words = set
        }
        let known = words!.contains(w.lowercased())
        wordsLock.unlock()
        // the word list has no contractions or inflections ("you're", "doesn't"): the system's spelling dictionary
        // knows them (v0.9 dogfood: a fix to "you're" was offered as a word to learn)
        return known || (spelledRight?(w.lowercased()) ?? false)
    }

    /// The system's spelling dictionary (the app sets it: NSSpellChecker): a lower-case word it knows is ordinary
    /// language, not a term the speech model needs to be told.
    public static var spelledRight: ((String) -> Bool)?
}
