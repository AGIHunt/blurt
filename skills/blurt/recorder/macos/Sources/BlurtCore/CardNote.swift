// What a hanging card (a capture without a project) says, and what it carries when copied or dragged out (v0.8).
//
// Card content (CardNote.make):
//  • the note is the typed text first, then the words said (if both, each once: "typed\nsaid") — the card shows it,
//    the hover note shows it, a copy / drag / captures.py item carries it.
//  • the mic mark means "these words were spoken": only when there is a voice note *and* its words — or when its
//    transcription failed or found no words (`marksMic`): the audio is there to retry, and the card says so.
//  • a voice note whose last words are still being transcribed shows the words already heard while it was said
//    (`heard`: the live text — v0.9-fix2, the card said "Transcribing…" next to a panel showing the whole sentence);
//    the card only, never a copy or an item (they wait for `said`). With nothing heard: a quiet "Transcribing…"
//    (never an empty card); failed: "Couldn't
//    transcribe" in the attention colour (`needsYou`: it isn't a caption), Retry in the card's right-click menu. A
//    shot's spoken note that turned out to hold no speech is dropped (no mark, nothing left to transcribe) — the app
//    does that. A voice note with no words (`said` == "", v0.9: one the user ended in a noisy room is kept) says "No
//    words recognized" and offers Retry, like a failed one: the same amber, the mic mark kept (`Status.needsRetry`).
//
// Copy / drag-out (v0.8.3: CardFiles.swift / CardPasteboard / CardDropTarget.swift): one rich item — picture and note
// together as HTML, RTFD and RTF, the picture's PNG, the note as text (a WeChat-style copy) — and, for a drag, what the
// app under the pointer needs besides: the note's .md for web apps and the Finder (they take files and drop the text),
// nothing for WeChat / Notes, and for a terminal one line of text: the picture's path, then the note.
// A drag's text is CardTransfer.dragText: one line (the note's lines joined with " · "), control characters out. The
// app that reads the text first is the one under the pointer when it asks, which is not always where the drag ends —
// and a terminal types what it gets at its prompt (a dropped newline would run the line, an escape sequence could end
// a bracketed paste). So every drop gets the safe form. A terminal's line is CardTransfer.terminalLine: the picture's
// absolute path, shell-quoted where it needs it, a space, the note's lines joined with spaces — so Claude Code or Codex
// (they read a local picture from its path) get each picture with its own words, and nothing runs at a shell prompt.
// A copy (click) keeps the note's line breaks: pasting is the user's own act; ⌘V of a copy in a terminal pastes one
// such line per card (CardTransfer.terminalLines, smart paste).

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

    /// The card carries the mic mark: the words said are here, or the audio is, waiting for a retry.
    public var marksMic: Bool { showsMic || status.needsRetry }
    /// The card needs the user (its status is drawn in the attention colour, not like a caption): Retry.
    public var needsYou: Bool { status.needsRetry }

    /// `heard`: what the live text showed while the note was said — shown while its words are still pending.
    public static func make(typed: String?, said: String?, hasVoice: Bool, transcription: Transcription,
                            heard: String? = nil) -> CardNote {
        let s = clean(said)
        let status: Status = !hasVoice || s != nil ? .none : transcription == .failed ? .failed
            : transcription == .pending || said == nil ? .transcribing : .noWords
        if status == .transcribing, hasVoice, let h = clean(heard) {
            return CardNote(text: merged(typed: typed, said: h), showsMic: true, status: .none)
        }
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
    public static func dragText(_ note: String?) -> String? { oneLine(note, joiner: " · ") }

    /// The note's lines joined with `joiner`, tabs as spaces, every other control character out (C0, DEL, C1: nothing
    /// a terminal would run or take as an escape sequence). nil when nothing is left.
    public static func oneLine(_ note: String?, joiner: String) -> String? {
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
        return kept.isEmpty ? nil : kept.joined(separator: joiner)
    }

    // MARK: a terminal: the picture's path, then its note

    /// One card for a terminal (a drop, or a line of a copy's ⌘V there): `'<absolute picture path>' <note>` — the path
    /// shell-quoted where it needs it (shellQuoted), the note on the same line (its lines joined with spaces, control
    /// characters out: oneLine). Never a newline, so a paste or drop at a shell prompt runs nothing; Claude Code and
    /// Codex read the picture from its path and keep it next to its own words. No picture (a voice card): the note
    /// alone; no note: the path alone. nil: nothing.
    public static func terminalLine(image: URL?, note: String?) -> String? {
        let words = oneLine(note, joiner: " ")
        guard let img = image else { return words }
        let path = shellQuoted(img.path)
        return words.map { path + " " + $0 } ?? path
    }

    /// A copy of several cards, for a terminal: one terminalLine per card, in the copy's order, joined with newlines
    /// (zsh, bash, fish, Terminal and iTerm2 take a paste bracketed: its newlines don't run anything; Claude Code shows
    /// a long one as "[Pasted text]" and keeps it whole). nil when no card has a picture: the copy's plain text (the
    /// notes) is already what a terminal should get.
    public static func terminalLines(_ cards: [CardPasteboard.Card]) -> String? {
        guard cards.contains(where: { $0.image != nil }) else { return nil }
        let lines = cards.compactMap { terminalLine(image: $0.image, note: $0.note) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// `path` as one shell word: as it is when every character is plain (ASCII letters, digits, `/ . _ - + , : @ %`,
    /// and letters of other scripts — 截图-153012.png stays readable), else in single quotes, a quote inside written
    /// `'\''`. A control character can't be quoted for a terminal: it is left out.
    public static func shellQuoted(_ path: String) -> String {
        let clean = String(String.UnicodeScalarView(path.unicodeScalars.filter { !isControl($0) }))
        guard !clean.isEmpty else { return "''" }
        if clean.unicodeScalars.allSatisfy(isPlain) { return clean }
        return "'" + clean.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isControl(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        return v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) || v == 0x2028 || v == 0x2029
    }

    static func isPlain(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        if v < 0x80 {
            return (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
                || "/._-+,:@%".unicodeScalars.contains(u)
        }
        // another script's letters and marks, its digits and punctuation (。、「」), but no space of any kind and no
        // invisible format character (a bidi override would make the path read differently than it is)
        switch u.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator, .control, .format, .privateUse, .surrogate, .unassigned:
            return false
        default:
            return !u.properties.isWhitespace
        }
    }
}
