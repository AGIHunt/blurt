// BlurtCore/CardNote.swift: what a hanging card says (typed + said, the mic mark, transcribing / failed) and what a
// drag into a terminal types.
import XCTest
@testable import BlurtCore

final class CardNoteTests: XCTestCase {
    func make(_ typed: String?, _ said: String?, voice: Bool, _ t: Transcription = .idle) -> CardNote {
        CardNote.make(typed: typed, said: said, hasVoice: voice, transcription: t)
    }

    func testTypedOnly() {
        let n = make("fdsfdsa", nil, voice: false)
        XCTAssertEqual(n.text, "fdsfdsa")
        XCTAssertFalse(n.showsMic)
        XCTAssertEqual(n.status, .none)
    }

    func testSaidOnlyShowsTheMic() {
        let n = make(nil, " 按钮被挡住了 ", voice: true)
        XCTAssertEqual(n.text, "按钮被挡住了")
        XCTAssertTrue(n.showsMic)
        XCTAssertEqual(n.status, .none)
    }

    func testTypedFirstThenSaid() {
        let n = make("see the header", "the logo overlaps the menu", voice: true)
        XCTAssertEqual(n.text, "see the header\nthe logo overlaps the menu")
        XCTAssertTrue(n.showsMic)
        XCTAssertEqual(make("same", "same", voice: true).text, "same")
        XCTAssertEqual(make("the logo overlaps the menu, fix", "the logo overlaps the menu", voice: true).text,
                       "the logo overlaps the menu, fix")
    }

    /// shot 002 of the user's batch: a voice wav and typed text, no `said` yet → the typed text, no mic, transcribing
    func testVoiceWithoutWordsYetIsTranscribingNotEmpty() {
        let n = make("fdsfdsa", nil, voice: true, .pending)
        XCTAssertEqual(n.text, "fdsfdsa")
        XCTAssertFalse(n.showsMic, "no mic mark without words")
        XCTAssertEqual(n.status, .transcribing)
        XCTAssertEqual(make(nil, nil, voice: true).status, .transcribing)
        XCTAssertNil(make(nil, nil, voice: true).text)
        XCTAssertEqual(make(nil, "", voice: true, .pending).status, .transcribing)
    }

    func testFailedTranscription() {
        let n = make(nil, nil, voice: true, .failed)
        XCTAssertEqual(n.status, .failed)
        XCTAssertFalse(n.showsMic)
        XCTAssertEqual(make(nil, "words", voice: true, .failed).status, .none, "words are there: nothing failed")
    }

    /// A failed card doesn't read like a caption: it keeps the mic mark (the audio is there to retry) and needs you.
    func testAFailedCardKeepsTheMicAndNeedsYou() {
        let f = make(nil, nil, voice: true, .failed)
        XCTAssertTrue(f.marksMic)
        XCTAssertTrue(f.needsYou)
        let pending = make(nil, nil, voice: true, .pending)
        XCTAssertFalse(pending.marksMic, "still transcribing: no mark yet")
        XCTAssertFalse(pending.needsYou)
        XCTAssertTrue(make(nil, "words", voice: true).marksMic)
        XCTAssertFalse(make("typed", nil, voice: false).marksMic)
    }

    func testNoVoiceNoStatus() {
        XCTAssertEqual(make(nil, nil, voice: false, .pending), CardNote(text: nil, showsMic: false, status: .none))
        XCTAssertFalse(make(nil, "stale words", voice: false).showsMic, "a dropped voice note leaves no mark")
    }

    func testMerged() {
        XCTAssertNil(CardNote.merged(typed: "  ", said: "\n"))
        XCTAssertEqual(CardNote.merged(typed: nil, said: "a"), "a")
        XCTAssertEqual(CardNote.merged(typed: "b", said: nil), "b")
    }


    // MARK: a drag's text (it may land in a terminal)

    func testDragTextIsOneLine() {
        let t = CardTransfer.dragText("See the header\nThe checkout button hides under the banner")
        XCTAssertEqual(t, "See the header · The checkout button hides under the banner")
        XCTAssertEqual(CardTransfer.dragText("first line\r\n\n  rm -rf ~\r\n\tthird "), "first line · rm -rf ~ · third")
        XCTAssertFalse(CardTransfer.dragText("a\nb\rc\u{2028}d\u{85}e")!.contains { $0.isNewline })
    }

    func testDragTextDropsControlCharacters() {
        // an escape sequence (the end of a bracketed paste), a bell, DEL, a C1 CSI must not reach a terminal
        XCTAssertEqual(CardTransfer.dragText("a\u{1B}[201~b\u{07}c\u{7F}d\u{9B}e"), "a[201~bcde")
        XCTAssertEqual(CardTransfer.dragText("结账按钮\t被挡住了"), "结账按钮 被挡住了")
    }

    func testDragTextOfNothing() {
        XCTAssertNil(CardTransfer.dragText(nil))
        XCTAssertNil(CardTransfer.dragText(" \n\u{1B}\n "))
    }
}
