// Putting a streamed dictation back together (docs/design/dictation.md §Streaming): the pieces DictationSegmenter cut
// were transcribed (and polished) one by one; this joins their texts without doubling or losing words at the seams.
//
//  • join: Chinese / Japanese runs are joined as they are; a space only between two Latin words or numbers (and after
//    Latin punctuation before a letter), the way the speech model writes one whole utterance.
//  • a hard cut (no pause; the pieces overlap by ~0.8 s of audio): the words both pieces heard are dropped from the
//    second — the longest run of ≥ 2 units at the end of the first that the second starts with (allowing 1
//    half-heard unit in front of it, a word cut in half, when ≥ 3 units match). Units as polish.py's guard counts them: each CJK character,
//    each Latin word, each digit; case, spaces and punctuation ignored.
//  • a piece that starts with a self-correction ("不对…", "no wait…") is polished together with the one before, so the
//    corrected-away words can still go.
//  • a seam is a pause, not a sentence end: each piece was transcribed (and polished) as if it were a whole utterance,
//    so it ended in 。 and the next began with a capital — a full stop at every breath. `boundary` takes the piece's
//    trailing punctuation off (。.!?！？ and ，,) unless the pause was long (`longPause`, 1.2 s) and the text before it
//    is plausibly a whole sentence (`plausiblyFinal`); in English the next piece's first word loses the capital the
//    cut gave it (`decapitalize`). Polish then decides over a window that spans the seam: `commitSplit` keeps the
//    last, unfinished clause of a window to be polished again with the next piece.
// Pure: DictationStitchTests.
import Foundation

public enum DictationStitch {
    /// One unit: what it is (lower case) and where it is in the text.
    public struct Unit: Equatable {
        public let value: String
        public let range: Range<String.Index>
    }

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x3040...0x30FF, 0xAC00...0xD7AF: return true
        default: return false
        }
    }

    static func isWordChar(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        return !isCJK(s) && (c.isLetter || c.isNumber) && !c.isWhitespace
    }

    /// Each CJK character, each Latin word, each digit — with its range.
    public static func units(_ text: String) -> [Unit] {
        var out: [Unit] = []
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if let s = c.unicodeScalars.first, isCJK(s) {
                let j = text.index(after: i)
                out.append(Unit(value: String(c), range: i..<j))
                i = j
            } else if c.isNumber {
                let j = text.index(after: i)
                out.append(Unit(value: String(c).lowercased(), range: i..<j))
                i = j
            } else if c.isLetter {
                var j = text.index(after: i)
                while j < text.endIndex, text[j].isLetter, let s = text[j].unicodeScalars.first, !isCJK(s) { j = text.index(after: j) }
                // an apostrophe inside a word (don't, it's)
                if j < text.endIndex, "'’".contains(text[j]) {
                    let k = text.index(after: j)
                    if k < text.endIndex, text[k].isLetter, let s = text[k].unicodeScalars.first, !isCJK(s) {
                        j = k
                        while j < text.endIndex, text[j].isLetter, let s = text[j].unicodeScalars.first, !isCJK(s) { j = text.index(after: j) }
                    }
                }
                out.append(Unit(value: String(text[i..<j]).lowercased(), range: i..<j))
                i = j
            } else {
                i = text.index(after: i)
            }
        }
        return out
    }

    /// Two pieces' texts as one: a space only where two Latin words (or numbers) meet.
    public static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespacesAndNewlines), b = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        let last = a.last!, first = b.first!
        let latinEnd = isWordChar(last) || ".,;:!?)”\"".contains(last)
        let space = latinEnd && isWordChar(first)
        return a + (space ? " " : "") + b
    }

    /// Joins every piece in order (empty ones skipped).
    public static func join(_ parts: [String]) -> String { parts.reduce("") { join($0, $1) } }

    /// The second piece of a hard cut without the words the first already has.
    public static func dropOverlap(previous: String, next: String, maxUnits: Int = 12, slack: Int = 1) -> String {
        let p = units(previous), n = units(next)
        guard p.count >= 2, n.count >= 2 else { return next }
        let longest = min(maxUnits, p.count, n.count)
        guard longest >= 2 else { return next }
        for k in stride(from: longest, through: 2, by: -1) {
            let tail = p[(p.count - k)...].map(\.value)
            for off in 0...min(slack, n.count - k) where off == 0 || k >= 3 {
                if Array(n[off..<(off + k)].map(\.value)) == Array(tail) {
                    let cut = n[off + k - 1].range.upperBound
                    var rest = String(next[cut...])
                    // the punctuation that followed the dropped words goes with them
                    while let c = rest.first, !c.isLetter, !c.isNumber, !(c.unicodeScalars.first.map(isCJK) ?? false) { rest.removeFirst() }
                    return rest
                }
            }
        }
        return next
    }

    /// The piece opens with a self-correction: polish it together with the piece before it.
    public static func startsWithCorrection(_ text: String) -> Bool {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // fillers and punctuation in front don't count
        while let c = t.first, !c.isLetter, !c.isNumber { t.removeFirst() }
        for f in ["嗯", "呃", "啊", "额", "哦", "噢", "um", "uh", "er"] where t.hasPrefix(f) {
            t = String(t.dropFirst(f.count))
            while let c = t.first, !c.isLetter, !c.isNumber { t.removeFirst() }
        }
        let zh = ["不对", "不是不是", "哦不是", "我是说", "我的意思是", "更正", "算了", "说错了", "应该是"]
        let en = ["no wait", "wait no", "i mean", "sorry", "actually", "scratch that", "make that", "rather"]
        // 不对称 / 不对劲 / 不对外 are words, not "no wait"
        let words = ["不对称", "不对劲", "不对外", "不对应", "不对头", "不对付", "不是很", "不是所有", "不是每"]
        if words.contains(where: { t.hasPrefix($0) }) { return false }
        if zh.contains(where: { t.hasPrefix($0) }) { return true }
        return en.contains { e in t.hasPrefix(e) && (t.count == e.count || !(t[t.index(t.startIndex, offsetBy: e.count)].isLetter)) }
    }
}

// MARK: seams are pauses, not sentence ends

extension DictationStitch {
    /// A pause at least this long after a whole sentence ends it; anything shorter is a breath.
    public static let longPause = 1.2
    /// What a pause leaves at the end of a piece: the sentence ends and commas the speech model or polish put there.
    static let trailing: Set<Character> = ["。", ".", "!", "?", "！", "？", "，", ",", "、", "；", ";", "…"]
    static let terminators: Set<Character> = ["。", ".", "!", "?", "！", "？"]
    static let closers: Set<Character> = ["”", "’", "\"", "'", "」", "』", "）", ")"]

    /// The text without the punctuation at its end, and that punctuation.
    public static func splitTrailing(_ text: String) -> (core: String, end: String) {
        var core = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var end = ""
        while let c = core.last, trailing.contains(c) || c.isWhitespace {
            if !c.isWhitespace { end = String(c) + end }
            core.removeLast()
        }
        return (String(core), end)
    }

    static func endsCJK(_ text: String) -> Bool {
        for c in text.reversed() where c.isLetter || c.isNumber {
            return c.unicodeScalars.first.map(isCJK) ?? false
        }
        return false
    }

    /// The sentence end to write after `text`: the one in `end` (a full stop when it had none), in the text's script.
    public static func terminator(_ end: String, after text: String) -> String {
        let c = end.first(where: { terminators.contains($0) }) ?? "."
        let cjk = endsCJK(text)
        switch c {
        case "!", "！": return cjk ? "！" : "!"
        case "?", "？": return cjk ? "？" : "?"
        default: return cjk ? "。" : "."
        }
    }

    /// The last sentence: what follows the last sentence end inside the text.
    static func lastSentence(_ core: String) -> String {
        if let i = core.lastIndex(where: { terminators.contains($0) }) { return String(core[core.index(after: i)...]) }
        return core
    }

    // words a sentence doesn't end on: a connective, a preposition, an article, a pronoun waiting for its verb
    static let openEndsZH = ["的时候", "时候", "以后", "之后", "之前", "的话", "因为", "所以", "但是", "可是", "然后", "而且",
                             "如果", "还是", "或者", "就是", "还有", "以及", "比如", "不过", "那么", "这个", "那个", "一个",
                             "我们", "你们", "他们", "也", "都", "就", "还", "又", "再", "才", "把", "被", "给", "从",
                             "向", "往", "在", "是", "和", "跟", "与", "或", "而", "但", "且", "让", "将", "比", "为", "若",
                             "嗯", "呃", "额"]
    static let openStartsZH = ["但是", "可是", "所以", "因为", "然后", "而且", "如果", "不过", "那么", "就是"]
    static let openEndsEN = Set<String>(["and", "or", "but", "so", "because", "the", "a", "an", "to", "of", "in", "on",
                                          "at", "for", "with", "from", "that", "which", "who", "whose", "if", "when",
                                          "while", "where", "is", "are", "was", "were", "be", "been", "am", "i", "we",
                                          "you", "they", "he", "she", "my", "your", "our", "their", "his", "her", "its",
                                          "this", "these", "those", "than", "as", "by", "about", "into", "then", "also",
                                          "just", "like", "um", "uh", "er", "very", "really", "not", "until", "since",
                                          "although", "though", "whether", "both", "either", "neither", "some", "any"])
    static let openStartsEN: Set<String> = ["but", "so", "and", "because", "then", "or", "if", "when"]

    /// Could the text before a pause be a whole sentence? It had a sentence end (。!? from the speech model), its last
    /// sentence isn't a stub (「但是呢」, "and so"), and it doesn't stop on a word that needs more (的时候, 是, also, the …).
    /// "…to the shared folder, myself." is whole: the length is the sentence's, not its last clause's.
    public static func plausiblyFinal(_ core: String, end: String) -> Bool {
        guard end.contains(where: { terminators.contains($0) }) else { return false }
        let sentence = lastSentence(core).trimmingCharacters(in: .whitespaces)
        let u = units(sentence).map(\.value)
        guard let last = u.last else { return false }
        if endsCJK(sentence) {
            if u.count < 4 { return false }
            if openEndsZH.contains(where: { sentence.hasSuffix($0) }) { return false }
            if u.count <= 5, openStartsZH.contains(where: { sentence.hasPrefix($0) }) { return false }
        } else {
            if u.count < 3 { return false }
            if openEndsEN.contains(last) { return false }
            if u.count <= 4, let f = u.first, openStartsEN.contains(f) { return false }
        }
        return true
    }

    // ordinary words a speech model capitalises only because the piece started there
    static let ordinary = Set<String>([
        "the", "a", "an", "and", "or", "but", "so", "because", "then", "also", "just", "that", "this", "these", "those",
        "there", "here", "it", "its", "it's", "we", "we're", "we'll", "you", "you're", "they", "they're", "he", "she",
        "me", "us", "them", "my", "your", "our", "their", "his", "her", "what", "which", "who", "when", "where", "why",
        "how", "if", "is", "are", "was", "were", "be", "been", "am", "do", "does", "did", "don't", "doesn't", "didn't",
        "have", "has", "had", "will", "would", "can", "could", "should", "may", "might", "must", "won't", "can't",
        "not", "no", "yes", "to", "of", "in", "on", "at", "for", "with", "from", "by", "about", "as", "than", "like",
        "into", "after", "before", "while", "until", "since", "all", "some", "any", "each", "every", "more", "most",
        "much", "many", "very", "really", "maybe", "still", "even", "only", "well", "now", "later", "today",
        "tomorrow", "make", "made", "take", "get", "got", "go", "going", "see", "look", "let", "send", "add", "use",
        "try", "want", "need", "know", "think", "say", "said", "tell", "ask", "give", "keep", "put", "set", "run",
        "move", "check", "fix", "write", "read", "start", "finish", "open", "close", "show", "find", "work", "please",
        "thanks", "thank", "okay", "ok", "one", "two", "three", "first", "next", "last", "other", "another", "same",
        "both", "either", "neither", "whether", "though", "although", "once", "again", "too", "already", "always",
        "never", "sometimes", "something", "anything", "everything", "nothing", "someone", "everyone", "anyone",
        "otherwise", "instead", "actually", "probably", "definitely", "especially", "myself", "yourself", "itself",
        "ourselves", "themselves", "don’t", "it’s", "we’re", "you’re", "they’re", "being"])

    /// The first word without the capital the cut gave it ("Than the one…" after "a lot faster" → "than the one…"):
    /// only an ordinary word written as a capital and lower-case letters; never "I", a custom word (`names`), an
    /// acronym or a name in the middle of the sentence (Thursday, GitHub).
    public static func decapitalize(_ text: String, names: Set<String> = []) -> String {
        guard let first = text.first, first.isUppercase, isWordChar(first) else { return text }
        var end = text.startIndex
        while end < text.endIndex, text[end].isLetter || "'’".contains(text[end]) { end = text.index(after: end) }
        let word = String(text[..<end])
        guard word != "I", !word.hasPrefix("I'"), !word.hasPrefix("I’"), !names.contains(word),
              word.dropFirst().allSatisfy({ !$0.isUppercase }), ordinary.contains(word.lowercased()) else { return text }
        return word.lowercased() + text[end...]
    }

    /// What a pause between two pieces leaves: the first piece's ending and the second one's start.
    ///  • `pause` ≥ `longPause` and the first is plausibly a whole sentence → its sentence end stays;
    ///  • `pause` ≥ `longPause`, not a whole sentence, but it ended in punctuation → a comma;
    ///  • otherwise (a breath, or not known) → no punctuation: polish, or the reader, decides.
    /// The second piece loses the capital the cut gave it unless the sentence really ended.
    public static func seam(_ previous: String, _ next: String, pause: Double?, names: Set<String> = []) -> (String, String) {
        let (core, end) = splitTrailing(previous)
        guard !core.isEmpty else { return (previous, next) }
        if let p = pause, p >= longPause {
            if plausiblyFinal(core, end: end) { return (core + terminator(end, after: core), next) }
            if !end.isEmpty { return (core + (endsCJK(core) ? "，" : ","), decapitalize(next, names: names)) }
        }
        return (core, decapitalize(next, names: names))
    }

    /// The pieces' texts joined with the seam rule. `pauses[i]`: the pause after piece i (nil: not known — a short
    /// one). The last piece keeps its ending: that is where the dictation ended.
    public static func joinPieces(_ texts: [String], pauses: [Double?], names: Set<String> = []) -> String {
        var acc = ""
        var after: Double?
        for (i, t) in texts.enumerated() {
            let pause = i < pauses.count ? pauses[i] : nil
            let t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty {          // a piece with no words: its pause adds to the one before it
                if let a = after, let p = pause { after = a + p }
                continue
            }
            if acc.isEmpty { acc = t } else {
                let (a, b) = seam(acc, t, pause: after, names: names)
                acc = join(a, b)
            }
            after = pause
        }
        return acc
    }

    /// A polish window's output split for committing: everything up to its last sentence end — or, with `atClauses`
    /// (the default), its last comma — is final; the last, unfinished clause (`carry`) is polished again together with
    /// the next piece, so polish decides the punctuation across the pause. Only the window's very end was written
    /// without knowing what came next; every comma inside it was decided with the words on both sides in view. Carrying
    /// a clause rather than a whole sentence keeps each window — and the one left at key-up — small: a long sentence
    /// carried whole made the last polish ~2× slower. `end` is the punctuation the window ended in (taken off the carry:
    /// a pause is not a sentence end).
    public static func commitSplit(_ text: String, atClauses: Bool = true) -> (commit: String, carry: String, end: String) {
        let (core, end) = splitTrailing(text)
        let clause: Set<Character> = atClauses ? ["，", "；", "、", "：", ",", ";", ":"] : []
        var cut: String.Index?
        var i = core.startIndex
        while i < core.endIndex {
            let c = core[i]
            var j = core.index(after: i)
            if terminators.contains(c) || clause.contains(c) {
                while j < core.endIndex, closers.contains(core[j]) { j = core.index(after: j) }
                // Latin punctuation counts only before a space or a CJK character (not 3.5, v0.8, 1,000, 10:30)
                let latin = c.isASCII
                if !latin || j == core.endIndex || core[j].isWhitespace || (core[j].unicodeScalars.first.map(isCJK) ?? false) {
                    cut = j
                }
            }
            i = j
        }
        let commitEnd = cut ?? core.startIndex
        let commit = String(core[..<commitEnd]).trimmingCharacters(in: .whitespaces)
        let carry = String(core[commitEnd...]).trimmingCharacters(in: .whitespaces)
        return (commit, carry, end)
    }
}
