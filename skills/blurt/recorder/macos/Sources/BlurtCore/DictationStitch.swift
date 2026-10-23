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
