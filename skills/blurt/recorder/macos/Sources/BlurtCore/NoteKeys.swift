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
//  • the type (NoteKind, 2026-10-31): ⌘1–⌘4 set 问题 / 想法 / 笔记 / 待办 and ⌘0 clears it, in every mode and with either
//    list open (the bubble has no other ⌘-digit; the main menu's ⌘1–⌘4 "Go" items are the main window's, and the
//    bubble takes those keys first while it has the keyboard). ⌘5–⌘9 aren't the bubble's. The type list (the type
//    chip's, opened with a click) takes ↑↓ ↩ while it is open; Esc or Tab close it, back to the note; typing goes on
//    into the note (the bubble closes the list). ↑↓ are otherwise the field's.
//  • Recording & Items off (Capabilities.swift; `State.filing` false): the bubble has no place chip and no type chip —
//    a snap is a card, nothing is filed and nothing has a type. Tab still takes the grey words (and ends Edit Note's
//    re-record); with none to take it does nothing. ⌘0–⌘4 do nothing either: they stay the bubble's while it has the
//    keyboard, so the main window behind a frozen snap never changes page under it.
//  • ⌘↩ (v1.0.23, the founder: "after a snap I don't want it hung as a card, straight onto the clipboard"): a fresh
//    snap's note is saved as ↩ saves it, then the picture (marked) and the note go to the clipboard — the same items a
//    card's click-copy puts there — and it is done: no card under the notch; it is in the Cards panel's History (used)
//    so it can be found again. Only a fresh snap of its own (State.canCopy): a snap into a recording, Edit Note and a
//    recording's note ignore it; with a list open it is ignored (the list has ↩), an IME keeps it. ⇧↩ stays the line
//    break.

import Foundation

public enum NoteKeys {
    public enum Key: Equatable {
        case returnKey, shiftReturn, tab, escape
        /// ⌘↩
        case commandReturn
        /// the first committed character typed into the field (not an IME composition: NoteTyping)
        case typing
        /// ↑ / ↓ (no modifiers)
        case up, down
        /// ⌘ and a digit (the top row or the keypad): ⌘1–⌘4 the type, ⌘0 none
        case command(Int)
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
        /// the type list (the type chip's) is open
        public var pickingKind: Bool
        /// the bubble has its place chip and its type chip (Capability.projectsShown): false with Recording & Items
        /// off — no place list, no types
        public var filing: Bool
        /// ⌘↩ may copy it and finish: a fresh snap in place, not one going into a recording
        public var canCopy: Bool
        /// the field holds text — typed, or the words taken with Tab (which are not `typed`)
        public var hasText: Bool

        public init(mode: Mode, voice: Voice = .none, typed: String = "", composing: Bool = false, picking: Bool = false,
                    pickingKind: Bool = false, filing: Bool = true, canCopy: Bool = false, hasText: Bool? = nil) {
            self.hasText = hasText ?? !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            self.mode = mode
            self.voice = voice
            self.typed = typed
            self.composing = composing
            self.picking = picking
            self.pickingKind = pickingKind
            self.filing = filing
            self.canCopy = canCopy
        }

        /// the grey words are showing in the field's place
        public var wordsShowing: Bool {
            voice == .words && typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public enum Action: Equatable {
        /// save the note (↩ / Done): with the grey words as they are, typed text, or nothing
        case commit
        /// ⌘↩: save it as ↩ does, copy the picture and the note, and finish without a card (History has it)
        case copyAndFinish
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
        /// the snap's type: ⌘1–⌘4, ⌘0 none (nil) — the type list closes if it is open
        case setKind(NoteKind?)
        /// the type list: ↑↓ move its cursor, ↩ picks the row under it, Esc / Tab close it
        case moveKind(Int)
        case pickKind
        case closeKinds
        /// nothing happens (and the key goes nowhere)
        case ignore
        /// not the bubble's: the field, the input method or the place list takes it
        case pass
    }

    /// ⌘Z is the bubble's, before the Edit menu's Undo. ⇧⌘Z stays the menu's Redo.
    ///
    /// The menu's Undo runs the field editor's typing undo on the main thread. A snap frozen in
    /// place eats every click until that thread gets back, so a ⌘Z the menu takes — and a typing
    /// undo that never returns — leaves the whole screen stuck. The panel claims ⌘Z in
    /// `performKeyEquivalent` (key equivalents run before `sendEvent`) and only then decides
    /// stroke versus text.
    public static func takesCommandZBeforeTheMenu(shift: Bool, charactersIgnoringModifiers: String?) -> Bool {
        !shift && charactersIgnoringModifiers == "z"
    }

    public static func action(_ key: Key, _ s: State) -> Action {
        if s.composing { return .pass }
        if case .command(let d) = key {
            guard let k = NoteKind.forDigit(d) else { return .pass }
            return s.filing ? .setKind(k) : .ignore
        }
        if key == .commandReturn {
            if (s.picking || s.pickingKind) && s.filing { return .ignore }
            return s.mode == .fresh && s.canCopy ? .copyAndFinish : .ignore
        }
        if s.pickingKind, s.filing {
            switch key {
            case .escape, .tab: return .closeKinds
            case .returnKey: return .pickKind
            case .up: return .moveKind(-1)
            case .down: return .moveKind(1)
            case .shiftReturn: return .ignore
            default: break                  // typing: as below (the bubble closes the list)
            }
        }
        if s.picking, s.filing { return key == .escape ? .closePlaces : .pass }
        switch key {
        case .up, .down, .command, .commandReturn:
            return .pass
        case .returnKey:
            return .commit
        case .escape:
            return NoteEsc.action(fresh: s.mode == .fresh, field: s.typed) == .clearText ? .clearText : .close
        case .shiftReturn:
            guard s.mode == .fresh else { return .newLine }
            if s.wordsShowing { return .takeWords(newLine: true) }
            // the words taken with Tab are text in the field too: ⇧↩ after Tab ran the next line into them
            return s.hasText ? .newLine : .ignore
        case .tab:
            switch s.mode {
            case .recording: return .pass
            case .edit: return s.voice == .words ? .takeWords(newLine: false) : s.filing ? .openPlaces : .ignore
            case .fresh: return s.wordsShowing ? .takeWords(newLine: false) : s.filing ? .openPlaces : .ignore
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
