import XCTest
@testable import BlurtCore

/// BA-22 (a main window row dragged into WeChat brought only its picture) and BA-54 (a card dragged into Claude without
/// Accessibility brought only its picture, and nothing said why).
final class DragOutTests: XCTestCase {
    let img = URL(fileURLWithPath: "/w/inbox/frames/f-0001.png")
    let md = URL(fileURLWithPath: "/w/inbox/items/BUG-0007.md")
    let text = "The header overlaps\n\nSteps\nopen the page"

    func landings() -> [DragLanding] {
        DropClass.allCases.flatMap { c in ComposerKind.allCases.map { DragLanding(cls: c, kind: $0) } } + [DragLanding(cls: .chat)]
    }

    // MARK: a list row's drag (CardPasteboard.itemDrag)

    /// With a picture, a row travels like a card: the picture alone into a chat app (the text is pasted after it),
    /// the rich item into a rich app and WeChat / QQ, both paths into a terminal — and the Finder gets its two files
    /// (no text on the clipboard behind a drop into a folder).
    func testARowWithAPictureTravelsLikeACard() {
        let card = CardPasteboard.Card(image: img, note: text, noteFile: md)
        for l in landings() {
            for attach in [false, true] {
                XCTAssertEqual(CardPasteboard.itemDrag(into: l, card: card, attachNote: attach),
                               CardPasteboard.drag(into: l, card: card, attachNote: attach || l.cls == .finder), "\(l)")
            }
        }
        XCTAssertEqual(CardPasteboard.itemDrag(into: DragLanding(cls: .finder), card: card).map(\.file), [img, md])
        XCTAssertEqual(DragReceipt.outcome(delivered: .finder, notePasted: false, noteFile: true), .files)
        XCTAssertEqual(CardPasteboard.itemDrag(into: DragLanding(cls: .chat, kind: .qt), card: card)[0].rich, true,
                       "WeChat puts the picture in its composer from the rich item")
        XCTAssertEqual(CardPasteboard.itemDrag(into: DragLanding(cls: .terminal), card: card).map(\.file), [img, md])
    }

    /// Without a picture (a voice or typed item): chat and rich apps get its text — rich text with its line breaks, the
    /// plain text as one line — never a lone .md attachment; a terminal and the Finder its .md.
    func testARowWithoutAPictureGivesChatAppsItsText() {
        let card = CardPasteboard.Card(image: nil, note: text, noteFile: md)
        for c in [DropClass.chat, .rich] {
            for k in ComposerKind.allCases {
                let items = CardPasteboard.itemDrag(into: DragLanding(cls: c, kind: k), card: card)
                XCTAssertEqual(items, [CardPasteboard.Item(rich: true, text: "The header overlaps · Steps · open the page")],
                               "\(c) \(k)")
                XCTAssertTrue(items.allSatisfy { $0.file == nil }, "a web composer ignores text when a file is there")
            }
        }
        for c in [DropClass.terminal, .finder] {
            XCTAssertEqual(CardPasteboard.itemDrag(into: DragLanding(cls: c), card: card), [CardPasteboard.Item(file: md)], "\(c)")
            XCTAssertEqual(CardPasteboard.itemDrag(into: DragLanding(cls: c), card: CardPasteboard.Card(image: nil, note: "hi")),
                           [CardPasteboard.Item(text: "hi")], "no .md: the one line")
        }
        // no text (an empty item): its .md everywhere, else nothing
        XCTAssertEqual(CardPasteboard.itemDrag(into: DragLanding(cls: .chat), card: CardPasteboard.Card(image: nil, note: nil, noteFile: md)),
                       [CardPasteboard.Item(file: md)])
        XCTAssertEqual(CardPasteboard.itemDrag(into: DragLanding(cls: .chat), card: CardPasteboard.Card(image: nil, note: nil)), [])
    }

    /// A terminal never gets text it could run: a row's one line has no control characters.
    func testARowsTextIsSafeForATerminal() {
        let card = CardPasteboard.Card(image: nil, note: "ls\n\u{1B}[201~rm -rf ~\r")
        let t = CardPasteboard.itemDrag(into: DragLanding(cls: .terminal), card: card)
        XCTAssertEqual(t.count, 1)
        XCTAssertFalse(t[0].text?.contains { $0.isNewline || $0 == "\u{1B}" } ?? true)
    }

    // MARK: Accessibility missing (BA-54)

    func testOnlyAMissingPermissionAsksForIt() {
        XCTAssertTrue(DragFollowUp.needsAccessibility(.none("no_accessibility")))
        for p in [DragFollowUp.Plan.none("off"), .none("code_editor"), .none("secure_input"), .none("not_sure"), .pasteNote("x")] {
            XCTAssertFalse(DragFollowUp.needsAccessibility(p), "\(p)")
        }
        let card = CardPasteboard.Card(image: img, note: "note")
        XCTAssertTrue(DragFollowUp.needsAccessibility(DragFollowUp.plan(delivered: .chat, card: card, enabled: true, accessibility: false,
                                                                        secureInput: false, kind: .web)))
        XCTAssertFalse(DragFollowUp.needsAccessibility(DragFollowUp.plan(delivered: .chat, card: card, enabled: true, accessibility: false,
                                                                         secureInput: false, kind: .editor)),
                       "a code editor never gets the paste: nothing to allow")
    }

    func testTheCardToastSaysAccessibilityIsMissing() {
        XCTAssertEqual(DragReceipt.toastKey(.pictureOnly, hasNote: true, noteCopied: true, noAccessibility: true), "capture.taken_out_no_ax")
        XCTAssertEqual(DragReceipt.toastKey(.pictureOnly, hasNote: true, noteCopied: false, noAccessibility: true),
                       "capture.taken_out_picture_no_ax")
        // as before otherwise
        XCTAssertEqual(DragReceipt.toastKey(.pictureOnly, hasNote: true, noteCopied: true), "capture.taken_out_picture_note")
        XCTAssertEqual(DragReceipt.toastKey(.both, hasNote: true, noteCopied: false, noAccessibility: true), "capture.taken_out_text")
        XCTAssertEqual(DragReceipt.toastKey(.pictureOnly, hasNote: false, noteCopied: false, noAccessibility: true), "capture.taken_out")
        XCTAssertEqual(DragReceipt.toastKey(.pictureOnly, hasNote: true, noteCopied: true, noteFile: true, noAccessibility: true),
                       "capture.taken_out_files_note", "the note file went too: that toast")
    }

    /// The main window's toast: only when there is something to do.
    func testTheRowToastOnlyWhenThereIsSomethingToDo() {
        XCTAssertNil(DragReceipt.itemToastKey(.both, noteCopied: false), "picture and text went in")
        XCTAssertNil(DragReceipt.itemToastKey(.paths, noteCopied: false))
        XCTAssertNil(DragReceipt.itemToastKey(.files, noteCopied: false))
        XCTAssertNil(DragReceipt.itemToastKey(.pictureOnly, noteCopied: false), "a text item's drop, or the safety net off")
        XCTAssertEqual(DragReceipt.itemToastKey(.pictureOnly, noteCopied: true), "capture.item_out_note")
        XCTAssertEqual(DragReceipt.itemToastKey(.unsure, noteCopied: true), "capture.item_out_note")
        XCTAssertEqual(DragReceipt.itemToastKey(.pictureOnly, noteCopied: true, noAccessibility: true), "capture.item_out_no_ax")
        XCTAssertEqual(DragReceipt.itemToastKey(.pictureOnly, noteCopied: false, noAccessibility: true), "capture.item_out_picture_no_ax")
    }

    /// The drag image's pill for a shot card: only over a chat app, only while Accessibility is missing.
    func testTheShotCardHintWithoutAccessibility() {
        let card = CardPasteboard.Card(image: img, note: "the logo overlaps")
        func hint(_ c: DropClass?, _ k: ComposerKind? = .web, card c2: CardPasteboard.Card? = nil, enabled: Bool = true, ax: Bool = false,
                  copies: Bool = true, app: String? = "Claude") -> VoiceCardDrop.Hint? {
            DragFollowUp.noteHint(cls: c, kind: k, app: app, card: c2 ?? card, enabled: enabled, accessibility: ax, copiesNote: copies)
        }
        XCTAssertEqual(hint(.chat), .copy(app: "Claude"))
        XCTAssertEqual(hint(.chat, .qt, app: "微信"), .copy(app: "微信"))
        XCTAssertEqual(hint(.chat, .native, app: " "), .copy(app: "App"))
        XCTAssertNil(hint(.chat, ax: true), "the note follows: nothing to say")
        XCTAssertNil(hint(.chat, enabled: false), "smart paste off: the user chose the picture alone")
        XCTAssertNil(hint(.chat, copies: false), "the note won't be on the clipboard")
        XCTAssertNil(hint(.chat, .editor), "a code editor keeps its by-design clipboard")
        XCTAssertNil(hint(nil, nil), "Blurt's own windows, or nothing")
        for c in [DropClass.rich, .terminal, .finder] { XCTAssertNil(hint(c), "\(c)") }
        XCTAssertNil(hint(.chat, card: CardPasteboard.Card(image: img, note: nil)), "no note")
        XCTAssertNil(hint(.chat, card: CardPasteboard.Card(image: img, note: " \n")), "a blank note")
        XCTAssertNil(hint(.chat, card: CardPasteboard.Card(image: nil, note: "words")), "a voice card has its own hint")
    }
}
