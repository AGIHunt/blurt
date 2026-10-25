// Putting a streamed dictation back together (docs/design/dictation.md §Streaming): the pieces DictationSegmenter cut
// were transcribed (and polished) one by one; this joins their texts without doubling or losing words at the seams.
//
//  • join: Chinese / Japanese runs are joined as they are; a space only between two Latin words or numbers (and after
//    Latin punctuation before a letter), the way the speech model writes one whole utterance.
//  • a hard cut (no pause; the pieces overlap by ~0.8 s of audio): the words both pieces heard are dropped from the
//    second — the longest run of ≥ 2 units at the end of the first that the second starts with (allowing 1
//    half-heard unit in front of it, a word cut in half, when ≥ 3 units match). Units as polish.py's guard counts them: each CJK character,
//    each Latin word, each digit; case, spaces and punctuation ignored.
//  • a seam is a pause, not a sentence end: each piece was transcribed (and polished) as if it were a whole utterance,
//    so it ended in 。 and the next began with a capital — a full stop at every breath. `seam` takes the piece's
//    trailing punctuation off after a breath and keeps the speech model's own mark after a long pause (`longPause`,
//    1.2 s). Mechanical only (docs/design/dictation.md §Rules vs model): no stop words, no list of ordinary words, no
//    correction markers — whether a sentence is complete, a capital belongs to a name, or a piece corrects the one
//    before is the polish model's call, made over a window that spans the seam (`commitSplit` keeps the last,
//    unfinished clause of a window to be polished again with the next piece).
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
    /// Too short for polish to tidy ("OK", 「好的」): polish.py answers "short" without its model (`len(units) <= 2`),
    /// so the app doesn't ask — a one-word reply after the polish server's idle exit waited ~2 s for a model load it
    /// didn't use (v0.9 dogfood).
    public static let polishMinUnits = 3
    public static func nothingToPolish(_ text: String) -> Bool { units(text).count < polishMinUnits }

    /// Long enough to hold a list worth suggesting (the ≡ chip's structuring pass after the paste): 24 Chinese
    /// characters, or 12 Latin words — a word carries about what two characters do. Counting both alike, a 22-word
    /// English list of three points never got the chip Chinese got for the same three points (v0.9 dogfood).
    public static let listMinContent = 24
    public static func mayHoldList(_ text: String) -> Bool {
        let us = units(text)
        let cjk = us.filter { $0.value.unicodeScalars.first.map(isCJK) ?? false }.count
        return cjk + 2 * (us.count - cjk) >= listMinContent
    }

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
}

// MARK: seams are pauses, not sentence ends

extension DictationStitch {
    /// A pause at least this long may have ended a sentence; anything shorter is a breath.
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

    /// The one mark a pause leaves: the sentence end in `end` (in the text's script), else its semicolon or comma.
    public static func mark(_ end: String, after text: String) -> String {
        if end.contains(where: { terminators.contains($0) }) { return terminator(end, after: text) }
        if end.isEmpty { return "" }
        if end.contains(where: { $0 == "；" || $0 == ";" }) { return endsCJK(text) ? "；" : ";" }
        return endsCJK(text) ? "，" : ","
    }

    /// What a pause between two pieces leaves. Mechanical — the pause's length and the speech model's own mark, no
    /// word lists: after a long pause (≥ `longPause`) the mark the speech model ended the piece with stays; after a
    /// breath (or a pause not known) it goes. Words and case are left as they are; with polish on, the model decides
    /// over a window that spans the seam.
    public static func seam(_ previous: String, _ next: String, pause: Double?) -> (String, String) {
        let (core, end) = splitTrailing(previous)
        guard !core.isEmpty else { return (previous, next) }
        if let p = pause, p >= longPause, !end.isEmpty { return (core + mark(end, after: core), next) }
        return (core, next)
    }

    /// The pieces' texts joined with the seam rule. `pauses[i]`: the pause after piece i (nil: not known — a short
    /// one). The last piece keeps its ending: that is where the dictation ended.
    public static func joinPieces(_ texts: [String], pauses: [Double?]) -> String {
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
                let (a, b) = seam(acc, t, pause: after)
                acc = join(a, b)
            }
            after = pause
        }
        return acc
    }

    /// Where a polish window fell back to the transcript, its seam (the pause before the piece) still gets
    /// punctuation: after a long pause the seam rule's; after a short one a comma where the speech model heard a
    /// boundary (`heardEnd`: the mark it ended the piece with). Without it a fall-back read 「…跑完第二，把文档…」.
    public static func fallbackSeam(_ previous: String, _ next: String, pause: Double?, heardEnd: String) -> String {
        let (core, end) = splitTrailing(previous)
        guard !core.isEmpty else { return join(previous, next) }
        let m = end.isEmpty ? heardEnd : end
        if let p = pause, p >= longPause {
            let (a, b) = seam(core + m, next, pause: p)
            return join(a, b)
        }
        let rest = next.trimmingCharacters(in: .whitespacesAndNewlines)
        if !m.isEmpty { return core + (endsCJK(core) ? "，" : ", ") + rest }
        return join(core, rest)
    }

    /// The pieces' texts joined as a fall-back types them: `joinPieces`, with `fallbackSeam` at every seam.
    public static func joinPiecesForFallback(_ texts: [String], pauses: [Double?]) -> String {
        var acc = ""
        var after: Double?
        var afterEnd = ""
        for (i, t) in texts.enumerated() {
            let pause = i < pauses.count ? pauses[i] : nil
            let t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty {
                if let a = after, let p = pause { after = a + p }
                continue
            }
            acc = acc.isEmpty ? t : fallbackSeam(acc, t, pause: after, heardEnd: afterEnd)
            after = pause
            afterEnd = splitTrailing(t).end
        }
        return acc
    }

    /// The window's output with the case its first word had in the input: polish capitalises a window as a sentence of
    /// its own (「…, update the docs」 → "Update the docs") when it continues one.
    public static func keepCase(input: String, output: String) -> String {
        let i = input.trimmingCharacters(in: .whitespaces), o = output.trimmingCharacters(in: .whitespaces)
        guard let a = i.first, let b = o.first, a.isLowercase, b.isUppercase, isWordChar(b) else { return output }
        let wi = i.prefix { $0.isLetter || "'’".contains($0) }, wo = o.prefix { $0.isLetter || "'’".contains($0) }
        guard !wi.isEmpty, wi.count == wo.count, wi.lowercased() == wo.lowercased(), wo.dropFirst() == wi.dropFirst() else { return output }
        return String(wi) + o.dropFirst(wo.count)
    }

    /// The text stops inside a sentence (no sentence end, no line break at its end).
    public static func midSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return !terminators.contains(last) && last != "\n"
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

    /// Numbered or bulleted lines ("1. …", "2、…", "- …" at a line start): Light must never write one; a structured
    /// text with ≥ 2 of them is a list.
    public static func listLines(_ text: String) -> Int {
        text.components(separatedBy: "\n").filter {
            $0.range(of: #"^[ \t]*(?:[0-9]{1,2}(?:[.)）](?![0-9])|、)|[-•*](?=[ \t]))[ \t]*\S"#, options: .regularExpression) != nil
        }.count
    }
}
