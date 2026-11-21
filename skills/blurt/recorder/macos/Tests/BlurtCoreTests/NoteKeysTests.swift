// BlurtCore/NoteKeys.swift: the note bubble's keys in each of its states — ↩ commits (the grey words as they are),
// ⇧↩ breaks the line, Tab takes the grey words (or opens the place list), typing replaces the words, Esc in two steps,
// and an input method's composition or the open place list keeps its own keys; ⌘1–⌘4 / ⌘0 the snap's type and the
// type list's keys (NoteKind).
import XCTest
@testable import BlurtCore

final class NoteKeysTests: XCTestCase {
    typealias S = NoteKeys.State

    // MARK: ⌘Z — the panel's, before the Edit menu's Undo

    func testCommandZIsTheBubblesBeforeTheMenusUndo() {
        XCTAssertTrue(NoteKeys.takesCommandZBeforeTheMenu(shift: false, charactersIgnoringModifiers: "z"))
        // Redo stays the menu's. So does every other ⌘ letter.
        XCTAssertFalse(NoteKeys.takesCommandZBeforeTheMenu(shift: true, charactersIgnoringModifiers: "z"))
        XCTAssertFalse(NoteKeys.takesCommandZBeforeTheMenu(shift: false, charactersIgnoringModifiers: "x"))
        XCTAssertFalse(NoteKeys.takesCommandZBeforeTheMenu(shift: false, charactersIgnoringModifiers: nil))
    }

    // MARK: ↩ — the user commits; nothing else does

    func testReturnCommitsInEveryState() {
        let states: [S] = [
            S(mode: .fresh, voice: .listening),                       // nothing said yet: the snap without a note
            S(mode: .fresh, voice: .words),                           // the grey words, as they are
            S(mode: .fresh, voice: .words, typed: "the total is wrong"),  // typed over them: the text alone
            S(mode: .fresh, voice: .none, typed: "taken with Tab, then more"),
            S(mode: .fresh),                                          // the mic ended with nothing said
            S(mode: .edit, typed: "fixed words"),
            S(mode: .edit, voice: .words),                            // a re-record: kept on Save
            S(mode: .recording, typed: "a line"),
        ]
        for s in states { XCTAssertEqual(NoteKeys.action(.returnKey, s), .commit, "\(s)") }
    }

    // MARK: Tab — take the grey words, or the place list

    func testTabTakesTheGreyWords() {
        XCTAssertEqual(NoteKeys.action(.tab, S(mode: .fresh, voice: .words)), .takeWords(newLine: false))
        // only spaces typed: the words still show, Tab still takes them
        XCTAssertEqual(NoteKeys.action(.tab, S(mode: .fresh, voice: .words, typed: "  ")), .takeWords(newLine: false))
    }

    func testTabWithoutWordsToTakeOpensThePlaces() {
        XCTAssertEqual(NoteKeys.action(.tab, S(mode: .fresh, voice: .listening)), .openPlaces, "nothing said yet")
        XCTAssertEqual(NoteKeys.action(.tab, S(mode: .fresh)), .openPlaces, "taken already, or a typed note")
        XCTAssertEqual(NoteKeys.action(.tab, S(mode: .fresh, typed: "typed")), .openPlaces)
        // typed over the words: they are hidden, so Tab doesn't bring them over the text
        XCTAssertEqual(NoteKeys.action(.tab, S(mode: .fresh, voice: .words, typed: "my own words")), .openPlaces)
        XCTAssertEqual(NoteKeys.action(.tab, S(mode: .edit, typed: "a note")), .openPlaces)
        XCTAssertEqual(NoteKeys.action(.tab, S(mode: .edit, voice: .listening)), .openPlaces)
    }

    func testTabEndsEditNotesReRecordKept() {
        XCTAssertEqual(NoteKeys.action(.tab, S(mode: .edit, voice: .words, typed: "the typed part")), .takeWords(newLine: false))
    }

    func testTabInARecordingsNoteIsTheFields() {
        XCTAssertEqual(NoteKeys.action(.tab, S(mode: .recording, typed: "x")), .pass)
    }

    // MARK: ⇧↩ — a new line

    func testShiftReturnBreaksTheLine() {
        XCTAssertEqual(NoteKeys.action(.shiftReturn, S(mode: .fresh, typed: "first line")), .newLine)
        XCTAssertEqual(NoteKeys.action(.shiftReturn, S(mode: .fresh, voice: .words, typed: "typed over")), .newLine)
        XCTAssertEqual(NoteKeys.action(.shiftReturn, S(mode: .edit)), .newLine)
        XCTAssertEqual(NoteKeys.action(.shiftReturn, S(mode: .recording, typed: "a")), .newLine)
    }

    func testShiftReturnOverTheGreyWordsTakesThemThenBreaksTheLine() {
        XCTAssertEqual(NoteKeys.action(.shiftReturn, S(mode: .fresh, voice: .words)), .takeWords(newLine: true))
    }

    func testShiftReturnOnAnEmptyFreshNoteDoesNothing() {
        // a bare line break would hide "Say it or type…" and the words to come behind an invisible character
        XCTAssertEqual(NoteKeys.action(.shiftReturn, S(mode: .fresh, voice: .listening)), .ignore)
        XCTAssertEqual(NoteKeys.action(.shiftReturn, S(mode: .fresh)), .ignore)
        // the words taken with Tab are in the field (not typed): ⇧↩ starts the next line after them (the dogfood's
        // "…shows up.Seen on Safari 18.")
        XCTAssertEqual(NoteKeys.action(.shiftReturn, S(mode: .fresh, hasText: true)), .newLine)
    }

    // MARK: typing — replaces the grey words

    func testTypingReplacesTheGreyWords() {
        XCTAssertEqual(NoteKeys.action(.typing, S(mode: .fresh, voice: .words)), .typeOver)
    }

    func testTypingBeforeSpeakingIsATypedNote() {
        XCTAssertEqual(NoteKeys.action(.typing, S(mode: .fresh, voice: .listening)), .typedNote)
    }

    func testTypingElsewhereIsJustTyping() {
        XCTAssertEqual(NoteKeys.action(.typing, S(mode: .fresh)), .pass, "after Tab: typing goes on after the words")
        XCTAssertEqual(NoteKeys.action(.typing, S(mode: .edit, voice: .words)), .pass, "a re-record keeps recording")
        XCTAssertEqual(NoteKeys.action(.typing, S(mode: .recording)), .pass)
    }

    // MARK: Esc — as before: typed text first, then the snap

    func testEscKeepsItsMeaning() {
        XCTAssertEqual(NoteKeys.action(.escape, S(mode: .fresh, voice: .words, typed: "typed over")), .clearText,
                       "the typed text goes; the grey words show again")
        XCTAssertEqual(NoteKeys.action(.escape, S(mode: .fresh, voice: .words)), .close, "the snap is discarded (Undo)")
        XCTAssertEqual(NoteKeys.action(.escape, S(mode: .fresh, voice: .listening)), .close)
        XCTAssertEqual(NoteKeys.action(.escape, S(mode: .fresh, typed: "   ")), .close)
        XCTAssertEqual(NoteKeys.action(.escape, S(mode: .edit, typed: "edited")), .close, "an edit is put back")
        XCTAssertEqual(NoteKeys.action(.escape, S(mode: .recording, typed: "a line")), .close, "the recording resumes")
    }

    // MARK: an input method, the place list

    func testAnInputMethodsCompositionKeepsItsKeys() {
        let s = S(mode: .fresh, voice: .words, composing: true)
        for k: NoteKeys.Key in [.returnKey, .shiftReturn, .tab, .escape, .typing] {
            XCTAssertEqual(NoteKeys.action(k, s), .pass, "\(k)")
        }
    }

    func testThePlaceListKeepsItsKeysButEsc() {
        let s = S(mode: .fresh, voice: .words, picking: true)
        XCTAssertEqual(NoteKeys.action(.escape, s), .closePlaces)
        for k: NoteKeys.Key in [.returnKey, .shiftReturn, .tab, .typing] {
            XCTAssertEqual(NoteKeys.action(k, s), .pass, "\(k)")
        }
    }

    // MARK: the type — ⌘1–⌘4 set it, ⌘0 clears it (NoteKind)

    func testCommandDigitsSetTheTypeInEveryMode() {
        for m: NoteKeys.Mode in [.fresh, .edit, .recording] {
            XCTAssertEqual(NoteKeys.action(.command(1), S(mode: m)), .setKind(.issue), "\(m)")
            XCTAssertEqual(NoteKeys.action(.command(2), S(mode: m, typed: "x")), .setKind(.idea), "\(m)")
            XCTAssertEqual(NoteKeys.action(.command(3), S(mode: m)), .setKind(.note), "\(m)")
            XCTAssertEqual(NoteKeys.action(.command(4), S(mode: m)), .setKind(.task), "\(m)")
            XCTAssertEqual(NoteKeys.action(.command(0), S(mode: m)), .setKind(nil), "\(m): ⌘0 clears it")
        }
        // while it listens, over the grey words: the words stay as they are
        XCTAssertEqual(NoteKeys.action(.command(1), S(mode: .fresh, voice: .listening)), .setKind(.issue))
        XCTAssertEqual(NoteKeys.action(.command(4), S(mode: .fresh, voice: .words)), .setKind(.task))
    }

    func testOtherCommandDigitsArentTheBubbles() {
        for d in 5...9 { XCTAssertEqual(NoteKeys.action(.command(d), S(mode: .fresh)), .pass, "⌘\(d)") }
    }

    func testCommandDigitsWorkWithEitherListOpen() {
        XCTAssertEqual(NoteKeys.action(.command(2), S(mode: .fresh, picking: true)), .setKind(.idea))
        XCTAssertEqual(NoteKeys.action(.command(0), S(mode: .fresh, pickingKind: true)), .setKind(nil))
    }

    func testAnInputMethodsCompositionKeepsCommandDigits() {
        XCTAssertEqual(NoteKeys.action(.command(1), S(mode: .fresh, composing: true)), .pass)
    }

    func testTheTypeListTakesArrowsReturnEscAndTab() {
        let s = S(mode: .fresh, voice: .words, pickingKind: true)
        XCTAssertEqual(NoteKeys.action(.up, s), .moveKind(-1))
        XCTAssertEqual(NoteKeys.action(.down, s), .moveKind(1))
        XCTAssertEqual(NoteKeys.action(.returnKey, s), .pickKind, "↩ picks the row, it doesn't commit the note")
        XCTAssertEqual(NoteKeys.action(.escape, s), .closeKinds, "Esc goes back to the note, never discards")
        XCTAssertEqual(NoteKeys.action(.tab, s), .closeKinds, "Tab doesn't take the words under an open list")
        XCTAssertEqual(NoteKeys.action(.shiftReturn, s), .ignore)
        XCTAssertEqual(NoteKeys.action(.escape, S(mode: .edit, typed: "edited", pickingKind: true)), .closeKinds)
        XCTAssertEqual(NoteKeys.action(.returnKey, S(mode: .recording, pickingKind: true)), .pickKind)
    }

    func testTypingUnderTheTypeListGoesIntoTheNote() {
        XCTAssertEqual(NoteKeys.action(.typing, S(mode: .fresh, voice: .words, pickingKind: true)), .typeOver)
        XCTAssertEqual(NoteKeys.action(.typing, S(mode: .fresh, voice: .listening, pickingKind: true)), .typedNote)
    }

    func testArrowsAreTheFieldsWithoutTheTypeList() {
        for s in [S(mode: .fresh, typed: "two\nlines"), S(mode: .edit), S(mode: .recording), S(mode: .fresh, picking: true)] {
            XCTAssertEqual(NoteKeys.action(.up, s), .pass, "\(s)")
            XCTAssertEqual(NoteKeys.action(.down, s), .pass, "\(s)")
        }
    }

    func testTheKindsDigitsAndShotsJsonlValues() {
        XCTAssertEqual(NoteKind.allCases.map(\.digit), [1, 2, 3, 4])
        XCTAssertEqual(NoteKind.allCases.map(\.rawValue), ["issue", "idea", "note", "task"])
        XCTAssertEqual(NoteKind.forDigit(3), .some(.note))
        XCTAssertEqual(NoteKind.forDigit(0), .some(nil))
        XCTAssertNil(NoteKind.forDigit(7))
        XCTAssertEqual(NoteKind.parse("task"), .task)
        for raw: Any? in [nil, NSNull(), "", "bug", 3] { XCTAssertNil(NoteKind.parse(raw), "\(String(describing: raw))") }
    }

    func testWordsShowOnlyWhileNothingIsTyped() {
        XCTAssertTrue(S(mode: .fresh, voice: .words).wordsShowing)
        XCTAssertTrue(S(mode: .fresh, voice: .words, typed: " \n").wordsShowing)
        XCTAssertFalse(S(mode: .fresh, voice: .words, typed: "x").wordsShowing)
        XCTAssertFalse(S(mode: .fresh, voice: .listening).wordsShowing)
    }

    // MARK: Recording & Items off — no place chip, no type chip (State.filing false)

    func testWithoutFilingTabNeverOpensThePlaces() {
        for s in [S(mode: .fresh, voice: .listening, filing: false), S(mode: .fresh, filing: false),
                  S(mode: .fresh, typed: "typed", filing: false), S(mode: .fresh, voice: .words, typed: "my own words", filing: false),
                  S(mode: .edit, typed: "a note", filing: false), S(mode: .edit, voice: .listening, filing: false)] {
            XCTAssertEqual(NoteKeys.action(.tab, s), .ignore, "\(s)")
        }
    }

    func testWithoutFilingTabStillTakesTheWords() {
        XCTAssertEqual(NoteKeys.action(.tab, S(mode: .fresh, voice: .words, filing: false)), .takeWords(newLine: false))
        XCTAssertEqual(NoteKeys.action(.tab, S(mode: .edit, voice: .words, filing: false)), .takeWords(newLine: false),
                       "Edit Note's re-record still ends, kept")
        XCTAssertEqual(NoteKeys.action(.shiftReturn, S(mode: .fresh, voice: .words, filing: false)), .takeWords(newLine: true))
    }

    func testWithoutFilingCommandDigitsSetNoType() {
        for m: NoteKeys.Mode in [.fresh, .edit, .recording] {
            // swallowed, not passed on: the main menu's ⌘0–⌘4 would change the main window's page behind the note
            for d in 0...4 { XCTAssertEqual(NoteKeys.action(.command(d), S(mode: m, filing: false)), .ignore, "\(m) ⌘\(d)") }
            for d in 5...9 { XCTAssertEqual(NoteKeys.action(.command(d), S(mode: m, filing: false)), .pass, "\(m) ⌘\(d)") }
        }
        XCTAssertEqual(NoteKeys.action(.command(1), S(mode: .fresh, composing: true, filing: false)), .pass)
    }

    func testWithoutFilingTheOtherKeysAreAsEver() {
        let on = S(mode: .fresh, voice: .words), off = S(mode: .fresh, voice: .words, filing: false)
        for k: NoteKeys.Key in [.returnKey, .shiftReturn, .escape, .typing, .up, .down] {
            XCTAssertEqual(NoteKeys.action(k, off), NoteKeys.action(k, on), "\(k)")
        }
        XCTAssertEqual(NoteKeys.action(.escape, S(mode: .fresh, typed: "x", filing: false)), .clearText)
        XCTAssertEqual(NoteKeys.action(.escape, S(mode: .fresh, filing: false)), .close)
        XCTAssertEqual(NoteKeys.action(.returnKey, S(mode: .edit, typed: "x", filing: false)), .commit)
    }

    func testWithoutFilingAListLeftOpenTakesNoKeys() {
        // (a switch flipped while a list was open: the lists are gone, their keys are the note's again)
        XCTAssertEqual(NoteKeys.action(.returnKey, S(mode: .fresh, pickingKind: true, filing: false)), .commit)
        XCTAssertEqual(NoteKeys.action(.returnKey, S(mode: .fresh, picking: true, filing: false)), .commit)
        XCTAssertEqual(NoteKeys.action(.escape, S(mode: .fresh, picking: true, filing: false)), .close)
    }

    // MARK: ⌘↩ copy and done (v1.0.23)

    func testCommandReturnCopiesAFreshSnapAndFinishes() {
        for v: NoteKeys.Voice in [.none, .listening, .words] {
            XCTAssertEqual(NoteKeys.action(.commandReturn, S(mode: .fresh, voice: v, canCopy: true)), .copyAndFinish, "\(v)")
            XCTAssertEqual(NoteKeys.action(.commandReturn, S(mode: .fresh, voice: v, typed: "x", canCopy: true)), .copyAndFinish)
        }
        // ↩ is still the card, ⇧↩ still the line break
        XCTAssertEqual(NoteKeys.action(.returnKey, S(mode: .fresh, canCopy: true)), .commit)
        XCTAssertEqual(NoteKeys.action(.shiftReturn, S(mode: .fresh, typed: "x", canCopy: true)), .newLine)
    }

    func testCommandReturnIsOnlyAFreshSnapsOwn() {
        // a snap into a recording (it goes with the take), Edit Note, a recording's note: nothing
        XCTAssertEqual(NoteKeys.action(.commandReturn, S(mode: .fresh, canCopy: false)), .ignore)
        XCTAssertEqual(NoteKeys.action(.commandReturn, S(mode: .edit, canCopy: true)), .ignore)
        XCTAssertEqual(NoteKeys.action(.commandReturn, S(mode: .recording, canCopy: true)), .ignore)
    }

    func testCommandReturnWaitsForAListAndAnInputMethod() {
        XCTAssertEqual(NoteKeys.action(.commandReturn, S(mode: .fresh, picking: true, canCopy: true)), .ignore)
        XCTAssertEqual(NoteKeys.action(.commandReturn, S(mode: .fresh, pickingKind: true, canCopy: true)), .ignore)
        XCTAssertEqual(NoteKeys.action(.commandReturn, S(mode: .fresh, composing: true, canCopy: true)), .pass)
        // without filing there are no lists: a list flag left over doesn't hold it
        XCTAssertEqual(NoteKeys.action(.commandReturn, S(mode: .fresh, picking: true, filing: false, canCopy: true)), .copyAndFinish)
    }
}
