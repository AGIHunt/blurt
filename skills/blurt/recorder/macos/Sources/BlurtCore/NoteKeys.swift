// The note bubble's keys: a fresh snap's note (⌥A), Edit Note, and a recording's snap note. BlurtApp's NoteBubble
// reads the key, asks `NoteKeys.action` what it does in the bubble's state, and does it (NoteKeysTests).
//
// The founder, 2026-10-31: nothing ends a note by itself any more (no pause end, no countdown on Done); the user
// commits it. Voice first, as before: the bubble listens as it opens and shows the words heard in grey.
//  • ↩ commits whatever the note holds: typed text, the words heard (still grey: taken as they are), or nothing (the
//    snap is kept without a note). Edit Note: Save. A recording's note: save and resume.
//  • ⇧↩ breaks the line (the field is multi-line). Over the grey words it takes them first, then breaks the line; on a
//    fresh snap's empty field (nothing to break) it does nothing.
//  • Tab over the grey words takes them: they turn black in the field, listening stops, the caret goes to their end and
//    the keyboard has the note. Voice doesn't go on after Tab (the typed and the heard text would share one field, and
//    the heard text is revised as it is decoded). Edit Note's re-record: Tab ends it, kept. With no words to take, Tab
//    opens the place list (the chip), as before; a recording's note leaves Tab to the field.
//  • typing (the first committed character) while words are heard replaces them: the mic stops and the words step
//    aside — an emptied field shows them again (↩ then keeps them); ↩ with text keeps the text alone. Typing before
//    anything was said makes it a typed note (the mic stops, nothing is kept).
//  • Esc (NoteEsc): typed text first, then the snap (with Undo); Edit Note puts the note back; a recording's note resumes.
//  • an input method's composition keeps its own keys (↩ / Esc / Tab end or cancel the composition); with the place
//    list open, Esc closes it and the other keys are the list's.

import Foundation

public enum NoteKeys {
    public enum Key: Equatable {
        case returnKey, shiftReturn, tab, escape
        /// the first committed character typed into the field (not an IME composition: NoteTyping)
        case typing
    }

    public enum Mode: Equatable {
        /// a snap just taken (⌥A): it listens as it opens
        case fresh
        /// Edit Note on a card: the whole note as text; the mic records it again on request
        case edit
        /// a snap taken while recording: typed only (the recording has the mic)
        case recording
    }

    public enum Voice: Equatable {
        /// no mic, or its words are already in the field (taken with Tab) or gone
        case none
        /// the mic is on and nothing has been said yet
        case listening
        /// words said and not taken: grey in the field's place (while it still listens, or after the mic ended), or
        /// set aside under typed text. Edit Note: a re-record with speech in it.
        case words
    }

    public struct State: Equatable {
        public var mode: Mode
        public var voice: Voice
        /// what the user typed: Esc's first step clears it, and the grey words show only while it is blank (the words
        /// taken with Tab, untouched, are not typing)
        public var typed: String
        /// an input method is composing (marked text in the field)
        public var composing: Bool
        /// the place list (the chip's) is open
        public var picking: Bool

        public init(mode: Mode, voice: Voice = .none, typed: String = "", composing: Bool = false, picking: Bool = false) {
            self.mode = mode
            self.voice = voice
            self.typed = typed
            self.composing = composing
            self.picking = picking
        }

        /// the grey words are showing in the field's place
        public var wordsShowing: Bool {
            voice == .words && typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public enum Action: Equatable {
        /// save the note (↩ / Done): with the grey words as they are, typed text, or nothing
        case commit
        /// a line break at the caret
        case newLine
        /// take the grey words into the field (black, the caret at their end), stop listening — and break the line
        /// after them (⇧↩). Edit Note: end the re-record, kept.
        case takeWords(newLine: Bool)
        /// the chip's place list
        case openPlaces
        case closePlaces
        /// Esc, first step: the typed text goes, the bubble stays
        case clearText
        /// Esc: a fresh snap is discarded (Undo); an edit is put back; a recording's note resumes
        case close
        /// typing over the grey words: the mic stops and the words step aside (an emptied field shows them again)
        case typeOver
        /// typing before anything was said: a typed note, the mic stops
        case typedNote
        /// nothing happens (and the key goes nowhere)
        case ignore
        /// not the bubble's: the field, the input method or the place list takes it
        case pass
    }

    public static func action(_ key: Key, _ s: State) -> Action {
        if s.composing { return .pass }
        if s.picking { return key == .escape ? .closePlaces : .pass }
        switch key {
        case .returnKey:
            return .commit
        case .escape:
            return NoteEsc.action(fresh: s.mode == .fresh, field: s.typed) == .clearText ? .clearText : .close
        case .shiftReturn:
            guard s.mode == .fresh else { return .newLine }
            if s.wordsShowing { return .takeWords(newLine: true) }
            return s.typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .ignore : .newLine
        case .tab:
            switch s.mode {
            case .recording: return .pass
            case .edit: return s.voice == .words ? .takeWords(newLine: false) : .openPlaces
            case .fresh: return s.wordsShowing ? .takeWords(newLine: false) : .openPlaces
            }
        case .typing:
            guard s.mode == .fresh else { return .pass }
            switch s.voice {
            case .words: return .typeOver
            case .listening: return .typedNote
            case .none: return .pass
            }
        }
    }
}
