// What a hanging card (a capture without a project) says, and what it carries when copied or dragged out (v0.8).
//
// Card content (CardNote.make):
//  • the note is the typed text first, then the words said (if both, each once: "typed\nsaid") — the card shows it,
//    the hover note shows it, a copy / drag / captures.py item carries it.
//  • the mic mark means "these words were spoken": only when there is a voice note *and* its words.
//  • a voice note still being transcribed: a quiet "Transcribing…" (never an empty card); failed: "Couldn't
//    transcribe" (Retry in the card's right-click menu). A shot's spoken note that turned out to hold no speech is
//    dropped (no mark, nothing left to transcribe) — the app does that. A voice note with no words (`said` == "", v0.9:
//    one the user ended in a noisy room is kept) says "No words recognized" and offers Retry, like a failed one.
//
// Copy / drag-out (v0.8.3: CardFiles.swift / CardPasteboard / CardDropTarget.swift): one rich item — picture and note
// together as HTML, RTFD and RTF, the picture's PNG, the note as text (a WeChat-style copy) — and, for a drag, what the
// app under the pointer needs besides: the note's .md for web apps and the Finder (they take files and drop the text),
// nothing for WeChat / Notes, only the two paths for a terminal.
// A drag's text is CardTransfer.dragText: one line (the note's lines joined with " · "), control characters out. The
// app that reads the text first is the one under the pointer when it asks, which is not always where the drag ends —
// and a terminal types what it gets at its prompt (a dropped newline would run the line, an escape sequence could end
// a bracketed paste). So every drop gets the safe form, and a terminal is only ever offered file paths. A copy (click)
// keeps the note's line breaks: pasting is the user's own act.

import Foundation

public enum Transcription: String, Equatable {
    case idle        // nothing asked yet (or done)
    case pending     // transcribe.py note is running
    case failed      // it failed: "Couldn't transcribe", Retry in the menu
}

public struct CardNote: Equatable {
    public enum Status: Equatable {
        case none, transcribing, failed
        /// transcribed, and the speech model found no words in it (the audio stays: Retry)
        case noWords

        /// It needs the user: "Couldn't transcribe" / "No words recognized", Retry (the card shows it in amber).
        public var needsRetry: Bool { self == .failed || self == .noWords }
    }

    /// The note: typed text first, then the words said (each once); nil when there is neither.
    public let text: String?
    /// The mic mark: the note was (also) spoken, and its words are here.
    public let showsMic: Bool
    /// A voice note whose words aren't here (yet).
    public let status: Status

    public static func make(typed: String?, said: String?, hasVoice: Bool, transcription: Transcription) -> CardNote {
        let s = clean(said)
        let status: Status = !hasVoice || s != nil ? .none : transcription == .failed ? .failed
            : transcription == .pending || said == nil ? .transcribing : .noWords
        return CardNote(text: merged(typed: typed, said: said), showsMic: hasVoice && s != nil, status: status)
    }

    /// Typed first, then said; one of them if the other is empty or the same (or already contains it).
    public static func merged(typed: String?, said: String?) -> String? {
        switch (clean(typed), clean(said)) {
        case let (t?, s?): return t == s || t.contains(s) ? t : s.contains(t) ? s : t + "\n" + s
        case let (t?, nil): return t
        case let (nil, s?): return s
        default: return nil
        }
    }

    public static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

public enum CardTransfer {
    /// A dragged card's text: the note's lines joined with " · " on one line, every control character out (nothing a
    /// terminal would run or take as an escape sequence). nil when nothing is left.
    public static func dragText(_ note: String?) -> String? {
        guard let note = note else { return nil }
        var lines: [String] = []
        var cur = ""
        for u in note.unicodeScalars {
            let v = u.value
            if v == 0x0A || v == 0x0D || v == 0x2028 || v == 0x2029 || v == 0x85 {
                lines.append(cur); cur = ""; continue
            }
            if v == 0x09 { cur.append(" "); continue }
            if v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) { continue }
            cur.unicodeScalars.append(u)
        }
        lines.append(cur)
        let kept = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: " · ")
    }
}
