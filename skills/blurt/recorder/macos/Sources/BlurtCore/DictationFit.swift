// Fitting a dictation into the text around the cursor (docs/design/dictation.md §Insert: fitting at the cursor), like
// Typeless. The field holds 「我知道你就是▮的。」 and the user says 「就是从老家回来的。」: pasted as it is, that gives
// 「我知道你就是就是从老家回来的。。」; fitted, only 「从老家回来」 goes in → 「我知道你就是从老家回来的。」.
//
//  • overlap before: the dictation's start repeats the end of the text before the cursor → that start goes. At least
//    2 CJK characters (or 2 digits), or 1 Latin word, so a coincidental single character isn't eaten.
//  • overlap after: the dictation's end repeats the start of the text after the cursor → that end goes, with its
//    punctuation. At least 2 units, or 1 when both end the same way (「的。」 before 「的。」).
//  • punctuation: the text after the cursor starts with punctuation → the insertion ends without any; it continues the
//    sentence (a CJK character, a lower-case word, a digit) while the text before ends mid-sentence → no closing
//    。.!?！？. The text before ends mid-sentence → no leading 「，」 and (English) no capital the speech model gave.
//  • spacing: a space between two Latin words at either seam; between CJK and Latin the way the field already does it
//    (else the way the dictation does, else spaced, as polish writes).
// Conservative by construction: only the inserted text is trimmed — nothing in the field is ever touched — and a fit
// that would leave nothing to insert isn't made. Pure: DictationFitTests. The app calls it right before the paste,
// only when the field's text could be read (Accessibility; WeChat & co. expose none: then nothing changes).
import Foundation

public enum DictationFit {
    public struct Result: Equatable {
        public var text: String
        /// what changed: "head" (overlap before), "tail" (overlap after), "punct", "capital", "space"
        public var changes: [String]
        public var trimmed: Bool { !changes.isEmpty }
    }

    static let terminators: Set<Character> = ["。", ".", "!", "?", "！", "？"]
    static let punct: Set<Character> = Set("。.!?！？，,、；;：:…）)」』”’\"'")
    static let leadingCommas: Set<Character> = ["，", ",", "、", "；", ";"]

    static func isCJK(_ c: Character) -> Bool { c.unicodeScalars.first.map(DictationStitch.isCJK) ?? false }
    static func isLatinWordChar(_ c: Character) -> Bool { DictationStitch.isWordChar(c) }

    /// `text` fitted between `before` and `after` (the field's text on each side of the cursor or selection).
    public static func fit(_ text: String, before: String, after: String, names: Set<String> = []) -> Result {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var changes: [String] = []
        guard !t.isEmpty else { return Result(text: text, changes: []) }

        // 1. overlap with the text before the cursor
        if let cut = headOverlap(t, before: before) {
            var rest = Substring(t[cut...])
            while let c = rest.first, c.isWhitespace || punct.contains(c) { rest.removeFirst() }
            if !DictationStitch.units(String(rest)).isEmpty { t = String(rest); changes.append("head") }
        }
        // 2. overlap with the text after the cursor
        if let cut = tailOverlap(t, after: after) {
            let rest = String(t[..<cut]).trimmingCharacters(in: .whitespaces)
            if !DictationStitch.units(rest).isEmpty { t = rest; changes.append("tail") }
        }

        let b = before.last(where: { !$0.isWhitespace || $0.isNewline })
        let a = after.first(where: { !$0.isWhitespace || $0.isNewline })
        let beforeEndsSentence = b == nil || b!.isNewline || terminators.contains(b!) || "）)」』”\"".contains(b!) && endsWithTerminator(before)
        let midSentence = !beforeEndsSentence

        // 3. punctuation at the end: what follows the cursor decides
        if let a = a, !a.isNewline {
            if punct.contains(a) {
                let stripped = stripTrailingPunct(t)
                if stripped != t, !stripped.isEmpty { t = stripped; changes.append("punct") }
            } else if (isCJK(a) || a.isNumber || (a.isLetter && a.isLowercase)) && midSentence {
                var s = t
                while let c = s.last, terminators.contains(c) { s.removeLast() }
                if s != t, !s.isEmpty { t = s; changes.append("punct") }
            }
        }
        // …and at the start: what precedes it
        // the text before already ends in punctuation (「安排：▮」): no second mark at the start (「：下午…」)
        if let b = b, punct.contains(b), let f = t.first, punct.contains(f), !"）)」』”’\"'".contains(f) {
            var s = Substring(t)
            while let c = s.first, punct.contains(c) || c.isWhitespace { s.removeFirst() }
            if !s.isEmpty { t = String(s); changes.append("punct") }
        }
        if midSentence {
            var s = Substring(t)
            while let c = s.first, leadingCommas.contains(c) || c.isWhitespace { s.removeFirst() }
            if s.count != t.count, !s.isEmpty { t = String(s); if !changes.contains("punct") { changes.append("punct") } }
            let d = DictationStitch.decapitalize(t, names: names)
            if d != t { t = d; changes.append("capital") }
        }

        // 4. spacing at the seams
        var lead = "", trail = ""
        if let bc = before.last, !bc.isWhitespace, let tc = t.first {
            if needsSpace(bc, tc, spaced: cjkLatinSpaced(before, t)) { lead = " " }
        }
        if let ac = after.first, !ac.isWhitespace, let tc = t.last {
            if needsSpace(tc, ac, spaced: cjkLatinSpaced(before + after, t)) { trail = " " }
        }
        if !lead.isEmpty || !trail.isEmpty { changes.append("space") }
        let out = lead + t + trail
        if changes.isEmpty, out == text { return Result(text: text, changes: []) }
        return Result(text: out, changes: changes)
    }

    static func endsWithTerminator(_ s: String) -> Bool {
        var t = Substring(s.trimmingCharacters(in: .whitespaces))
        while let c = t.last, "）)」』”\"’'".contains(c) { t.removeLast() }
        return t.last.map { terminators.contains($0) } ?? true
    }

    static func stripTrailingPunct(_ s: String) -> String {
        var t = Substring(s)
        while let c = t.last, punct.contains(c) || c.isWhitespace, !"）)」』”".contains(c) { t.removeLast() }
        return String(t)
    }

    /// Where the dictation continues after the words that repeat the end of `before` (nil: no such overlap).
    static func headOverlap(_ t: String, before: String) -> String.Index? {
        let tu = DictationStitch.units(t)
        let bs = String(before.suffix(200))      // the units' ranges index into this string, not into `before`
        let bu = DictationStitch.units(bs)
        guard !tu.isEmpty, !bu.isEmpty else { return nil }
        // only directly at the end of the text before: no sentence end between its last unit and the cursor
        if let last = bu.last, bs[last.range.upperBound...].contains(where: { terminators.contains($0) }) { return nil }
        for k in stride(from: min(12, tu.count - 1, bu.count), through: 1, by: -1) {
            guard Array(bu.suffix(k).map(\.value)) == Array(tu.prefix(k).map(\.value)), enough(Array(tu.prefix(k))) else { continue }
            return tu[k - 1].range.upperBound
        }
        return nil
    }

    /// Where the dictation's own end starts if it repeats the start of `after` (nil: no such overlap).
    static func tailOverlap(_ t: String, after: String) -> String.Index? {
        let tu = DictationStitch.units(t)
        let a = String(after.prefix(200))
        let au = DictationStitch.units(a)
        guard tu.count > 1, !au.isEmpty else { return nil }
        // only directly at the start of the text after
        if let first = au.first, a[..<first.range.lowerBound].contains(where: { !$0.isWhitespace && !punct.contains($0) }) { return nil }
        if let first = au.first, a[..<first.range.lowerBound].contains(where: { punct.contains($0) }) { return nil }
        for k in stride(from: min(12, tu.count - 1, au.count), through: 1, by: -1) {
            let tail = Array(tu.suffix(k)), head = Array(au.prefix(k))
            guard tail.map(\.value) == head.map(\.value) else { continue }
            if enough(tail) { return tail[0].range.lowerBound }
            // one unit: only when both end the same way right after it (「的。」 before 「的。」)
            let tEnd = String(t[tail[k - 1].range.upperBound...]).trimmingCharacters(in: .whitespaces)
            let aEnd = a[head[k - 1].range.upperBound...].first(where: { !$0.isWhitespace })
            if let p = tEnd.first, terminators.contains(p), let q = aEnd, terminators.contains(q) { return tail[0].range.lowerBound }
        }
        return nil
    }

    /// An overlap long enough to be more than a coincidence: a Latin word, or two CJK characters / digits.
    static func enough(_ u: [DictationStitch.Unit]) -> Bool {
        u.contains { $0.value.count > 1 || ($0.value.first.map { $0.isLetter && !isCJK($0) } ?? false) } || u.count >= 2
    }

    static func needsSpace(_ l: Character, _ r: Character, spaced: Bool) -> Bool {
        let lw = isLatinWordChar(l), rw = isLatinWordChar(r)
        if lw && rw { return true }
        if (isCJK(l) && rw) || (lw && isCJK(r)) { return spaced }
        // Latin punctuation before a word ("Done.▮Next")
        if ".,;:!?".contains(l) && rw { return true }
        return false
    }

    /// Does the field (else the dictation) put a space between CJK and Latin? Default: yes, as polish writes.
    static func cjkLatinSpaced(_ field: String, _ text: String) -> Bool {
        func count(_ s: String) -> (spaced: Int, tight: Int) {
            var sp = 0, ti = 0
            let cs = Array(s)
            for i in 0..<max(0, cs.count - 1) {
                let x = cs[i], y = cs[i + 1]
                if (isCJK(x) && isLatinWordChar(y)) || (isLatinWordChar(x) && isCJK(y)) { ti += 1 }
                if i + 2 < cs.count, y == " ", (isCJK(x) && isLatinWordChar(cs[i + 2])) || (isLatinWordChar(x) && isCJK(cs[i + 2])) { sp += 1 }
            }
            return (sp, ti)
        }
        let f = count(field)
        if f.spaced + f.tight > 0 { return f.spaced >= f.tight }
        let t = count(text)
        if t.spaced + t.tight > 0 { return t.spaced >= t.tight }
        return true
    }
}
