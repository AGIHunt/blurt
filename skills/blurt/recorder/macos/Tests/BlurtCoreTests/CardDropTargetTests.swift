// BlurtCore/CardDropTarget.swift: which kind of app a card is dropped into, what each kind gets, and what the island
// says afterwards. The report: a card dropped into WeChat arrived as a picture plus a Markdown file attachment.
import XCTest
@testable import BlurtCore

final class CardDropTargetTests: XCTestCase {
    let img = URL(fileURLWithPath: "/s/out/003/截图-144012.png")
    let md = URL(fileURLWithPath: "/s/out/003/截图-144012-备注.md")
    let note = "see the header\nthe logo overlaps"

    // MARK: which kind of app

    func testClassifiesTheAppsByBundleID() {
        let cases: [(String, DropClass)] = [
            ("com.anthropic.claudefordesktop", .web), ("com.google.Chrome", .web), ("com.brave.Browser", .web),
            ("com.microsoft.edgemac", .web), ("company.thebrowser.Browser", .web), ("com.apple.Safari", .web),
            ("com.tinyspeck.slackmacgap", .web), ("com.microsoft.VSCode", .web), ("com.todesktop.230313mzl4w4u92", .web),
            ("notion.id", .web), ("com.hnc.Discord", .web), ("com.electron.lark", .web),
            ("com.tencent.xinWeChat", .text), ("com.tencent.qq", .text), ("com.apple.MobileSMS", .text),
            ("com.apple.Notes", .text), ("com.apple.TextEdit", .text), ("com.apple.mail", .text),
            ("ru.keepcoder.Telegram", .text), ("net.whatsapp.WhatsApp", .text), ("com.apple.iWork.Pages", .text),
            ("com.apple.iWork.Keynote", .text),
            ("com.apple.Terminal", .terminal), ("com.googlecode.iterm2", .terminal), ("com.mitchellh.ghostty", .terminal),
            ("dev.warp.Warp-Stable", .terminal), ("net.kovidgoyal.kitty", .terminal), ("com.github.wez.wezterm", .terminal),
            ("org.alacritty", .terminal),
            ("com.apple.finder", .finder),
            ("com.example.SomethingElse", .unknown),
        ]
        for (id, want) in cases {
            XCTAssertEqual(DropTargets.classify(bundleID: id, appURL: nil), want, id)
        }
        XCTAssertEqual(DropTargets.classify(bundleID: nil, appURL: nil), .unknown, "a window whose owner has no bundle")
    }

    /// An app no table names is an Electron app if its bundle carries Electron's framework — then it is a web app.
    func testFindsElectronAppsByTheirFramework() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-droptarget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let electron = root.appendingPathComponent("Some Chat.app"), native = root.appendingPathComponent("Native.app")
        try FileManager.default.createDirectory(at: electron.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: native.appendingPathComponent("Contents/Frameworks/Sparkle.framework"),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(DropTargets.isElectron(electron))
        XCTAssertFalse(DropTargets.isElectron(native))
        XCTAssertEqual(DropTargets.classify(bundleID: "com.example.chat", appURL: electron), .web)
        XCTAssertEqual(DropTargets.classify(bundleID: "com.example.native", appURL: native), .unknown)
        // the tables come first: a terminal or a text app stays what the table says even if it ships Electron
        XCTAssertEqual(DropTargets.classify(bundleID: "co.zeit.hyper", appURL: electron), .terminal)
        XCTAssertEqual(DropTargets.classify(bundleID: "com.tencent.qq", appURL: electron), .text)
    }

    func testTheTablesDontOverlap() {
        let sets = [DropTargets.finder, DropTargets.terminals, DropTargets.textApps, DropTargets.webApps]
        for (i, a) in sets.enumerated() {
            for b in sets[(i + 1)...] { XCTAssertTrue(a.isDisjoint(with: b), "\(a.intersection(b))") }
        }
    }

    // MARK: what each kind gets — the rich item, then a .md file or nothing

    var card: CardPasteboard.Card { CardPasteboard.Card(image: img, note: note, noteFile: md) }
    var rich: CardPasteboard.Item { CardPasteboard.Item(file: img, image: img, rich: true, text: "see the header · the logo overlaps", tag: true) }

    /// WeChat, Notes, TextEdit…: the rich item (a text view takes picture and note from its RTFD) and an inert second
    /// item — no .md, and no second copy of the text (a text view would insert the note twice).
    func testATextAppGetsTheRichItemOnly() {
        let items = CardPasteboard.drag(for: .text, card: card)
        XCTAssertEqual(items, [rich, CardPasteboard.Item(tag: true)])
        XCTAssertFalse(items.contains { $0.file == md }, "no Markdown attachment")
        XCTAssertEqual(items.filter { $0.text != nil }.count, 1, "the note once")
    }

    /// Claude desktop, Chrome, Slack…: a web app attaches files and drops the text and HTML — the note goes as a .md file.
    func testAWebAppGetsTheNoteAsAFile() {
        XCTAssertEqual(CardPasteboard.drag(for: .web, card: card), [rich, CardPasteboard.Item(file: md)])
    }

    /// A terminal types the paths it gets: both files, and no text or rich text anywhere — the note never reaches a shell.
    func testATerminalGetsOnlyPaths() {
        let items = CardPasteboard.drag(for: .terminal, card: card)
        XCTAssertEqual(items, [CardPasteboard.Item(file: img, tag: true), CardPasteboard.Item(file: md)])
        XCTAssertTrue(items.allSatisfy { $0.text == nil && $0.image == nil && !$0.rich })
    }

    func testTheFinderGetsTheRichItemAndTheMarkdown() {
        XCTAssertEqual(CardPasteboard.drag(for: .finder, card: card), [rich, CardPasteboard.Item(file: md)])
    }

    /// An app we don't know gets what a web app gets: the rich item reaches the note where a text view reads, the .md
    /// where files win.
    func testAnUnknownAppGetsWhatAWebAppGets() {
        XCTAssertEqual(CardPasteboard.drag(for: .unknown, card: card), CardPasteboard.drag(for: .web, card: card))
    }

    /// The first item is the same for every kind of app but a terminal: moving between them rewrites only the second.
    func testTheRichItemIsTheSameButForATerminal() {
        let firsts = Set(DropClass.allCases.filter { $0 != .terminal }.map { "\(CardPasteboard.drag(for: $0, card: card)[0])" })
        XCTAssertEqual(firsts.count, 1)
    }

    /// The number of items is fixed when the drag starts: every kind of app gets the same count for the same card.
    func testItemCountIsTheSameForEveryKindOfApp() {
        for c in [card, CardPasteboard.Card(image: img, note: nil, noteFile: md), CardPasteboard.Card(image: img, note: note, noteFile: nil)] {
            let counts = Set(DropClass.allCases.map { CardPasteboard.drag(for: $0, card: c).count })
            XCTAssertEqual(counts.count, 1, "\(counts)")
        }
        XCTAssertTrue(DropClass.allCases.allSatisfy { CardPasteboard.drag(for: $0, card: card)[0].tag })
    }

    // MARK: what happens after the drop

    /// The note goes on the clipboard only where the app may have kept just the picture.
    func testTheSafetyNetOnlyWhereItHelps() {
        XCTAssertFalse(DragReceipt.copiesNote(delivered: .text), "picture and note went in")
        XCTAssertFalse(DragReceipt.copiesNote(delivered: .terminal), "both paths went in; ⌘V would paste at a prompt")
        for c in [DropClass.web, .finder, .unknown] { XCTAssertTrue(DragReceipt.copiesNote(delivered: c), "\(c)") }
        XCTAssertTrue(DragReceipt.copiesNote(delivered: nil), "not sure what it got")
    }

    func testToastSaysWhatWentIn() {
        XCTAssertEqual(DragReceipt.toastKey(delivered: .text, hasNote: true, noteCopied: true), "capture.taken_out_text")
        XCTAssertEqual(DragReceipt.toastKey(delivered: .text, hasNote: true, noteCopied: false), "capture.taken_out_text")
        XCTAssertEqual(DragReceipt.toastKey(delivered: .terminal, hasNote: true, noteCopied: true), "capture.taken_out_paths")
        for c in [DropClass.web, .finder] {
            XCTAssertEqual(DragReceipt.toastKey(delivered: c, hasNote: true, noteCopied: true), "capture.taken_out_files_note")
            XCTAssertEqual(DragReceipt.toastKey(delivered: c, hasNote: true, noteCopied: false), "capture.taken_out_files")
        }
        // not sure what it got: an app we don't know (a text view reads the rich item, a web view the files), or it
        // landed in another kind of app than the pasteboard was last written for — the toast claims only the clipboard
        for c in [DropClass.unknown, nil] {
            XCTAssertEqual(DragReceipt.toastKey(delivered: c, hasNote: true, noteCopied: true), "capture.taken_out_note")
            XCTAssertEqual(DragReceipt.toastKey(delivered: c, hasNote: true, noteCopied: false), "capture.taken_out")
        }
        // no note (or a voice card): just "Dragged out"
        for c in DropClass.allCases {
            XCTAssertEqual(DragReceipt.toastKey(delivered: c, hasNote: false, noteCopied: false), "capture.taken_out")
        }
    }
}
