// BlurtCore/NoteKeys.swift: the note bubble's keys in each of its states — ↩ commits (the grey words as they are),
// ⇧↩ breaks the line, Tab takes the grey words (or opens the place list), typing replaces the words, Esc in two steps,
// and an input method's composition or the open place list keeps its own keys.
import XCTest
@testable import BlurtCore

final class NoteKeysTests: XCTestCase {
    typealias S = NoteKeys.State

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

    func testWordsShowOnlyWhileNothingIsTyped() {
        XCTAssertTrue(S(mode: .fresh, voice: .words).wordsShowing)
        XCTAssertTrue(S(mode: .fresh, voice: .words, typed: " \n").wordsShowing)
        XCTAssertFalse(S(mode: .fresh, voice: .words, typed: "x").wordsShowing)
        XCTAssertFalse(S(mode: .fresh, voice: .listening).wordsShowing)
    }
}
