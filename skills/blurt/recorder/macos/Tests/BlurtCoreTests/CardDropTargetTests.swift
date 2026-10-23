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

    // MARK: what each kind gets — two items, item 2 a .md file or just text

    /// WeChat, Notes, TextEdit…: the picture and the words — no .md. The picture also comes as RTFD: a rich text view
    /// reads RTFD before file names (and file names before plain text), so without it the words would be dropped.
    func testATextAppGetsThePictureAndTheText() {
        let items = CardPasteboard.drag(for: .text, image: img, noteFile: md, note: note)
        XCTAssertEqual(items, [
            CardPasteboard.Item(file: img, imageData: true, rtfd: true, tag: true),
            CardPasteboard.Item(text: "see the header · the logo overlaps"),
        ])
        XCTAssertFalse(items.contains { $0.file == md }, "no Markdown attachment")
    }

    /// Claude desktop, Chrome, Slack…: a web app attaches files and drops loose text — the note goes as a .md file.
    func testAWebAppGetsTheNoteAsAFile() {
        XCTAssertEqual(CardPasteboard.drag(for: .web, image: img, noteFile: md, note: note), [
            CardPasteboard.Item(file: img, imageData: true, tag: true),
            CardPasteboard.Item(file: md, text: "see the header · the logo overlaps"),
        ])
    }

    /// A terminal types the paths it gets: both files, and no text anywhere — the note never reaches a shell.
    func testATerminalGetsOnlyPaths() {
        let items = CardPasteboard.drag(for: .terminal, image: img, noteFile: md, note: note)
        XCTAssertEqual(items, [CardPasteboard.Item(file: img, tag: true), CardPasteboard.Item(file: md)])
        XCTAssertTrue(items.allSatisfy { $0.text == nil && !$0.imageData && !$0.rtfd })
    }

    func testTheFinderGetsTwoFiles() {
        XCTAssertEqual(CardPasteboard.drag(for: .finder, image: img, noteFile: md, note: note),
                       [CardPasteboard.Item(file: img, imageData: true, tag: true), CardPasteboard.Item(file: md)])
    }

    /// An app we don't know gets what a web app gets: in every kind of target we measured it reaches the note (a file
    /// where files win, the text where text wins); the text layout would lose it in a web app.
    func testAnUnknownAppGetsTheFilesAndTheText() {
        XCTAssertEqual(CardPasteboard.drag(for: .unknown, image: img, noteFile: md, note: note),
                       CardPasteboard.drag(for: .web, image: img, noteFile: md, note: note))
    }

    /// The number of items is fixed when the drag starts: every kind of app gets the same count for the same card.
    func testItemCountIsTheSameForEveryKindOfApp() {
        for (i, n) in [(img, note), (img, nil)] as [(URL, String?)] {
            let counts = Set(DropClass.allCases.map { CardPasteboard.drag(for: $0, image: i, noteFile: md, note: n).count })
            XCTAssertEqual(counts.count, 1, "\(counts)")
        }
        XCTAssertTrue(DropClass.allCases.allSatisfy { CardPasteboard.drag(for: $0, image: img, noteFile: md, note: note)[0].tag })
    }

    // MARK: what the island says

    func testToastSaysWhatWentIn() {
        XCTAssertEqual(DragReceipt.toastKey(delivered: .text, hasNote: true, noteCopied: true), "capture.taken_out_text")
        XCTAssertEqual(DragReceipt.toastKey(delivered: .text, hasNote: true, noteCopied: false), "capture.taken_out_text")
        XCTAssertEqual(DragReceipt.toastKey(delivered: .terminal, hasNote: true, noteCopied: true), "capture.taken_out_paths")
        for c in [DropClass.web, .finder, .unknown] {
            XCTAssertEqual(DragReceipt.toastKey(delivered: c, hasNote: true, noteCopied: true), "capture.taken_out_files_note")
            XCTAssertEqual(DragReceipt.toastKey(delivered: c, hasNote: true, noteCopied: false), "capture.taken_out_files")
        }
        // not sure what it got (it landed in another kind of app than the pasteboard was last written for)
        XCTAssertEqual(DragReceipt.toastKey(delivered: nil, hasNote: true, noteCopied: true), "capture.taken_out_note")
        XCTAssertEqual(DragReceipt.toastKey(delivered: nil, hasNote: true, noteCopied: false), "capture.taken_out")
        // no note (or a voice card): just "Dragged out"
        for c in DropClass.allCases {
            XCTAssertEqual(DragReceipt.toastKey(delivered: c, hasNote: false, noteCopied: false), "capture.taken_out")
        }
    }
}
