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

    /// v0.9-fix2: a voice note's card said "Transcribing…" while the live panel beside it showed the whole sentence.
    func testAVoiceNoteStillTranscribingShowsTheWordsAlreadyHeard() {
        let n = CardNote.make(typed: nil, said: nil, hasVoice: true, transcription: .pending, heard: "the export button is broken")
        XCTAssertEqual(n.text, "the export button is broken")
        XCTAssertEqual(n.status, .none)
        XCTAssertTrue(n.showsMic)
        // nothing heard: as before
        XCTAssertEqual(CardNote.make(typed: nil, said: nil, hasVoice: true, transcription: .pending, heard: " ").status, .transcribing)
        // the final words replace them; a failure or no words is still said so
        XCTAssertEqual(CardNote.make(typed: nil, said: "final", hasVoice: true, transcription: .idle, heard: "heard").text, "final")
        XCTAssertEqual(CardNote.make(typed: nil, said: nil, hasVoice: true, transcription: .failed, heard: "heard").status, .failed)
        XCTAssertEqual(CardNote.make(typed: nil, said: "", hasVoice: true, transcription: .idle, heard: "heard").status, .noWords)
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

    /// A voice note the model found no words in (v0.9) is drawn like a failed one: the mic mark kept, in amber, Retry.
    func testANoWordsCardKeepsTheMicAndNeedsYouLikeAFailedOne() {
        let n = make(nil, "", voice: true)
        XCTAssertEqual(n.status, .noWords)
        XCTAssertTrue(n.status.needsRetry)
        XCTAssertTrue(n.marksMic)
        XCTAssertTrue(n.needsYou)
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

    // MARK: a terminal: the picture's path, then its note (Claude Code / Codex read the picture from its path)

    func testAPlainPathStaysAsItIs() {
        XCTAssertEqual(CardTransfer.shellQuoted("/Users/ana/.blurt/sessions/2026-11-12-101010/out/003/Screenshot-144012.png"),
                       "/Users/ana/.blurt/sessions/2026-11-12-101010/out/003/Screenshot-144012.png")
        XCTAssertEqual(CardTransfer.shellQuoted("/Users/ana/.blurt/out/003/截图-144012.png"), "/Users/ana/.blurt/out/003/截图-144012.png",
                       "another script's letters need no quotes")
        XCTAssertEqual(CardTransfer.shellQuoted("/a/b_c+d,e:f@g%h.png"), "/a/b_c+d,e:f@g%h.png")
    }

    func testAPathThatNeedsItIsSingleQuoted() {
        XCTAssertEqual(CardTransfer.shellQuoted("/Users/Ana Li/Library/Application Support/x.png"),
                       "'/Users/Ana Li/Library/Application Support/x.png'")
        XCTAssertEqual(CardTransfer.shellQuoted("/Users/o'brien/x.png"), "'/Users/o'\\''brien/x.png'", "a quote inside: '\\''")
        XCTAssertEqual(CardTransfer.shellQuoted("/tmp/\"q\" $HOME `id` *.png"), "'/tmp/\"q\" $HOME `id` *.png'",
                       "inside single quotes nothing expands")
        XCTAssertEqual(CardTransfer.shellQuoted("/tmp/a;b&c|d(e)!.png"), "'/tmp/a;b&c|d(e)!.png'")
        XCTAssertEqual(CardTransfer.shellQuoted("/Users/李 雷/截图 144012.png"), "'/Users/李 雷/截图 144012.png'")
        XCTAssertEqual(CardTransfer.shellQuoted("/Users/李\u{3000}雷/x.png"), "'/Users/李\u{3000}雷/x.png'", "an ideographic space")
        XCTAssertEqual(CardTransfer.shellQuoted("/x/\u{202E}gnp.exe"), "'/x/\u{202E}gnp.exe'", "a bidi override is quoted, never bare")
        XCTAssertEqual(CardTransfer.shellQuoted("~/x.png"), "'~/x.png'", "no tilde expansion")
    }

    func testAPathNeverCarriesAControlCharacter() {
        XCTAssertEqual(CardTransfer.shellQuoted("/tmp/a\nb\u{1B}c.png"), "/tmp/abc.png")
        XCTAssertEqual(CardTransfer.shellQuoted("\n"), "''")
    }

    func testATerminalLineIsThePathThenTheNoteOnOneLine() {
        let img = URL(fileURLWithPath: "/Users/Ana Li/.blurt/out/003/截图-144012.png")
        XCTAssertEqual(CardTransfer.terminalLine(image: img, note: "结账按钮被挡住了\nthe banner covers it\r\n\n  see the logo "),
                       "'/Users/Ana Li/.blurt/out/003/截图-144012.png' 结账按钮被挡住了 the banner covers it see the logo",
                       "line breaks flattened to spaces, blank lines and ends dropped")
        let line = CardTransfer.terminalLine(image: img, note: "ls\n\u{1B}[201~rm -rf ~\r\u{07}\u{2028}x")!
        XCTAssertFalse(line.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || $0.value == 0x2028 },
                       "nothing a terminal would run or read as an escape (the end of a bracketed paste)")
        XCTAssertEqual(line, "'/Users/Ana Li/.blurt/out/003/截图-144012.png' ls [201~rm -rf ~ x")
        XCTAssertEqual(CardTransfer.terminalLine(image: img, note: nil), "'/Users/Ana Li/.blurt/out/003/截图-144012.png'")
        XCTAssertEqual(CardTransfer.terminalLine(image: img, note: " \n "), "'/Users/Ana Li/.blurt/out/003/截图-144012.png'")
        XCTAssertEqual(CardTransfer.terminalLine(image: nil, note: "call Ana\nabout pricing"), "call Ana about pricing", "a voice card: its words")
        XCTAssertNil(CardTransfer.terminalLine(image: nil, note: nil))
        XCTAssertEqual(CardTransfer.terminalLine(image: URL(fileURLWithPath: "/s/a.png"), note: "tab\there"), "/s/a.png tab here")
    }

    /// Several cards: one line each, in the copy's order — each picture keeps its own words.
    func testTerminalLinesKeepEveryPictureWithItsNote() {
        let a = URL(fileURLWithPath: "/s/out/001/截图-101010.png"), b = URL(fileURLWithPath: "/s/o ut/002/截图-101020.png")
        let text = CardTransfer.terminalLines([
            CardPasteboard.Card(image: a, note: "first\nline two"),
            CardPasteboard.Card(image: nil, note: "a voice card"),
            CardPasteboard.Card(image: b, note: nil),
            CardPasteboard.Card(image: nil, note: "  "),
            CardPasteboard.Card(image: a, note: "again"),
        ])
        XCTAssertEqual(text, [
            "/s/out/001/截图-101010.png first line two",
            "a voice card",
            "'/s/o ut/002/截图-101020.png'",
            "/s/out/001/截图-101010.png again",
        ].joined(separator: "\n"))
        XCTAssertNil(CardTransfer.terminalLines([CardPasteboard.Card(image: nil, note: "only words")]),
                     "no picture: the copy's own text is what a terminal gets")
        XCTAssertNil(CardTransfer.terminalLines([]))
    }
}
