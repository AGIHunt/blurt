// BlurtCore/CardDropTarget.swift: which kind of app a card is dropped into, what each kind gets, and what the island
// says afterwards. The reports: a card dropped into WeChat arrived as a picture plus a Markdown file attachment
// (v0.8.2); one dropped into DeepSeek's chat in a browser as the picture and a .md (v0.8.5) — now the picture alone,
// then the note pasted after it.
import XCTest
@testable import BlurtCore

final class CardDropTargetTests: XCTestCase {
    let img = URL(fileURLWithPath: "/s/out/003/截图-144012.png")
    let md = URL(fileURLWithPath: "/s/out/003/截图-144012-备注.md")
    let note = "see the header\nthe logo overlaps"

    // MARK: which kind of app

    func testClassifiesTheAppsByBundleID() {
        let cases: [(String, DropClass)] = [
            ("com.apple.MobileSMS", .rich), ("com.apple.Notes", .rich), ("com.apple.TextEdit", .rich), ("com.apple.mail", .rich),
            ("ru.keepcoder.Telegram", .rich), ("net.whatsapp.WhatsApp", .rich), ("com.apple.iWork.Pages", .rich),
            ("com.apple.iWork.Keynote", .rich), ("com.apple.Stickies", .rich),
            // browsers, Electron apps, WeChat / QQ and every app no table names: chat
            ("com.anthropic.claudefordesktop", .chat), ("com.google.Chrome", .chat), ("com.brave.Browser", .chat),
            ("com.microsoft.edgemac", .chat), ("company.thebrowser.Browser", .chat), ("com.apple.Safari", .chat),
            ("com.tinyspeck.slackmacgap", .chat), ("com.microsoft.VSCode", .chat), ("notion.id", .chat), ("com.electron.lark", .chat),
            ("com.tencent.xinWeChat", .chat), ("com.tencent.qq", .chat), ("org.telegram.desktop", .chat),
            ("com.example.SomethingElse", .chat),
            ("com.apple.Terminal", .terminal), ("com.googlecode.iterm2", .terminal), ("com.mitchellh.ghostty", .terminal),
            ("dev.warp.Warp-Stable", .terminal), ("net.kovidgoyal.kitty", .terminal), ("com.github.wez.wezterm", .terminal),
            ("org.alacritty", .terminal), ("co.zeit.hyper", .terminal),
            ("com.apple.finder", .finder),
        ]
        for (id, want) in cases { XCTAssertEqual(DropTargets.classify(bundleID: id), want, id) }
        XCTAssertEqual(DropTargets.classify(bundleID: nil), .chat, "a window whose owner has no bundle")
    }

    /// The engine only says how the note's paste finds its place after the picture.
    func testTheComposerKind() {
        for id in ["com.google.Chrome", "com.apple.Safari", "com.anthropic.claudefordesktop", "com.electron.lark", "com.tinyspeck.slackmacgap"] {
            XCTAssertEqual(DropTargets.composer(bundleID: id, appURL: nil), .web, id)
        }
        XCTAssertEqual(DropTargets.composer(bundleID: "com.tencent.xinWeChat", appURL: nil), .qt)
        XCTAssertEqual(DropTargets.composer(bundleID: "com.tencent.qq", appURL: nil), .qt)
        XCTAssertEqual(DropTargets.composer(bundleID: "com.example.native", appURL: nil), .native)
        XCTAssertEqual(DropTargets.composer(bundleID: nil, appURL: nil), .native)
    }

    /// An app no table names is web content if its bundle carries Electron's framework.
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
        XCTAssertEqual(DropTargets.composer(bundleID: "com.example.chat", appURL: electron), .web)
        XCTAssertEqual(DropTargets.composer(bundleID: "com.example.native", appURL: native), .native)
        // QQ ships Electron in recent builds, but it is a single-flavour composer first (⌘↓ before the note)
        XCTAssertEqual(DropTargets.composer(bundleID: "com.tencent.qq", appURL: electron), .qt)
        // the class never depends on the engine
        XCTAssertEqual(DropTargets.classify(bundleID: "co.zeit.hyper"), .terminal)
    }

    func testTheTablesDontOverlap() {
        let sets = [DropTargets.finder, DropTargets.terminals, DropTargets.richApps, DropTargets.webApps, SingleFlavourApps.bundles]
        for (i, a) in sets.enumerated() {
            for b in sets[(i + 1)...] { XCTAssertTrue(a.isDisjoint(with: b), "\(a.intersection(b))") }
        }
    }

    func testOldTestNamesStillParse() {
        XCTAssertEqual(DropClass(legacy: "web"), .chat)
        XCTAssertEqual(DropClass(legacy: "unknown"), .chat)
        XCTAssertEqual(DropClass(legacy: "text"), .rich)
        XCTAssertEqual(DropClass(legacy: "terminal"), .terminal)
        XCTAssertNil(DropClass(legacy: "com.apple.Notes"))
    }

    // MARK: what each kind gets

    var card: CardPasteboard.Card { CardPasteboard.Card(image: img, note: note, noteFile: md) }
    var rich: CardPasteboard.Item { CardPasteboard.Item(file: img, image: img, rich: true, text: "see the header · the logo overlaps", tag: true) }
    var picture: CardPasteboard.Item { CardPasteboard.Item(file: img, image: img, tag: true) }
    let inert = CardPasteboard.Item(tag: true)

    /// Notes, TextEdit, Mail…: the rich item (a text view takes picture and note from its RTFD) and an inert second
    /// item — no .md, and no second copy of the text (a text view would insert the note twice).
    func testARichAppGetsTheRichItemOnly() {
        XCTAssertEqual(CardPasteboard.drag(for: .rich, card: card), [rich, inert])
        XCTAssertEqual(CardPasteboard.drag(for: .rich, card: card, attachNote: true), [rich, inert], "a text view doesn't add a later file")
    }

    /// DeepSeek / ChatGPT in a browser, Claude, Feishu, WeChat…: the picture alone — no .md, no text, no HTML (a
    /// composer that took them would get the note twice once it is pasted after the picture).
    func testAChatAppGetsThePictureAlone() {
        let items = CardPasteboard.drag(for: .chat, card: card)
        XCTAssertEqual(items, [picture, inert])
        XCTAssertFalse(items.contains { $0.file == md }, "no Markdown attachment by default")
        XCTAssertTrue(items.allSatisfy { $0.text == nil && !$0.rich })
        XCTAssertEqual(items.compactMap(\.file), [img], "the picture is the only file")
    }

    func testTheNoteFileIsAnOption() {
        XCTAssertEqual(CardPasteboard.drag(for: .chat, card: card, attachNote: true), [picture, CardPasteboard.Item(file: md)])
        XCTAssertEqual(CardPasteboard.drag(for: .finder, card: card, attachNote: true), [picture, CardPasteboard.Item(file: md)])
        // asked for, but it couldn't be written: inert
        XCTAssertEqual(CardPasteboard.drag(for: .chat, card: CardPasteboard.Card(image: img, note: note), attachNote: true), [picture, inert])
    }

    /// A terminal types the paths it gets: both files (Claude Code / Codex read the .md), and no text or rich text
    /// anywhere — the note never reaches a shell. The option doesn't matter there.
    func testATerminalGetsOnlyPaths() {
        for attach in [false, true] {
            let items = CardPasteboard.drag(for: .terminal, card: card, attachNote: attach)
            XCTAssertEqual(items, [CardPasteboard.Item(file: img, tag: true), CardPasteboard.Item(file: md)])
            XCTAssertTrue(items.allSatisfy { $0.text == nil && $0.image == nil && !$0.rich })
        }
    }

    func testTheFinderGetsThePictureFile() {
        XCTAssertEqual(CardPasteboard.drag(for: .finder, card: card), [picture, inert])
        XCTAssertEqual(CardPasteboard.drag(for: .finder, card: card), CardPasteboard.drag(for: .chat, card: card),
                       "moving between a chat app and the Finder rewrites nothing")
    }

    /// The number of items is fixed when the drag starts: every kind of app gets the same count for the same card.
    func testItemCountIsTheSameForEveryKindOfApp() {
        for c in [card, CardPasteboard.Card(image: img, note: nil, noteFile: md), CardPasteboard.Card(image: img, note: note, noteFile: nil)] {
            for attach in [false, true] {
                let counts = Set(DropClass.allCases.map { CardPasteboard.drag(for: $0, card: c, attachNote: attach).count })
                XCTAssertEqual(counts.count, 1, "\(counts)")
            }
        }
        XCTAssertTrue(DropClass.allCases.allSatisfy { CardPasteboard.drag(for: $0, card: card)[0].tag })
    }

    // MARK: what happens after the drop

    func testTheOutcome() {
        XCTAssertEqual(DragReceipt.outcome(delivered: .rich, notePasted: false, noteFile: false), .both)
        XCTAssertEqual(DragReceipt.outcome(delivered: .chat, notePasted: true, noteFile: false), .both)
        XCTAssertEqual(DragReceipt.outcome(delivered: .chat, notePasted: false, noteFile: false), .pictureOnly)
        XCTAssertEqual(DragReceipt.outcome(delivered: .chat, notePasted: false, noteFile: true), .pictureOnly,
                       "the .md went too, but the note isn't in the message")
        XCTAssertEqual(DragReceipt.outcome(delivered: .terminal, notePasted: false, noteFile: true), .paths)
        XCTAssertEqual(DragReceipt.outcome(delivered: .finder, notePasted: false, noteFile: false), .pictureOnly)
        XCTAssertEqual(DragReceipt.outcome(delivered: .finder, notePasted: false, noteFile: true), .files)
        XCTAssertEqual(DragReceipt.outcome(delivered: nil, notePasted: false, noteFile: false), .unsure)
    }

    /// The note goes on the clipboard only where it didn't go in.
    func testTheSafetyNetOnlyWhereItHelps() {
        XCTAssertFalse(DragReceipt.copiesNote(.both), "picture and note went in")
        XCTAssertFalse(DragReceipt.copiesNote(.paths), "both paths went in; ⌘V would paste at a prompt")
        XCTAssertFalse(DragReceipt.copiesNote(.files), "the Finder got the note's file")
        XCTAssertTrue(DragReceipt.copiesNote(.pictureOnly))
        XCTAssertTrue(DragReceipt.copiesNote(.unsure), "not sure what it got")
    }

    func testToastSaysWhatWentIn() {
        XCTAssertEqual(DragReceipt.toastKey(.both, hasNote: true, noteCopied: false), "capture.taken_out_text")
        XCTAssertEqual(DragReceipt.toastKey(.paths, hasNote: true, noteCopied: false, noteFile: true), "capture.taken_out_paths")
        XCTAssertEqual(DragReceipt.toastKey(.files, hasNote: true, noteCopied: false, noteFile: true), "capture.taken_out_files")
        XCTAssertEqual(DragReceipt.toastKey(.pictureOnly, hasNote: true, noteCopied: true), "capture.taken_out_picture_note")
        XCTAssertEqual(DragReceipt.toastKey(.pictureOnly, hasNote: true, noteCopied: false), "capture.taken_out_picture")
        XCTAssertEqual(DragReceipt.toastKey(.pictureOnly, hasNote: true, noteCopied: true, noteFile: true), "capture.taken_out_files_note")
        XCTAssertEqual(DragReceipt.toastKey(.pictureOnly, hasNote: true, noteCopied: false, noteFile: true), "capture.taken_out_files")
        XCTAssertEqual(DragReceipt.toastKey(.unsure, hasNote: true, noteCopied: true), "capture.taken_out_note")
        XCTAssertEqual(DragReceipt.toastKey(.unsure, hasNote: true, noteCopied: false), "capture.taken_out")
        // no note (or a voice card): just "Dragged out"
        for o in [DragReceipt.Outcome.both, .pictureOnly, .paths, .files, .unsure] {
            XCTAssertEqual(DragReceipt.toastKey(o, hasNote: false, noteCopied: false), "capture.taken_out")
        }
    }

    // MARK: the composer that received the drop

    func testPicksTheComposerUnderOrNearestTheDrop() {
        let search = CGRect(x: 100, y: 40, width: 300, height: 30), composer = CGRect(x: 100, y: 700, width: 800, height: 80)
        XCTAssertEqual(ComposerPick.nearest([search, composer], to: CGPoint(x: 500, y: 730)), 1, "under the drop point")
        XCTAssertEqual(ComposerPick.nearest([search, composer], to: CGPoint(x: 500, y: 500)), 1, "the chat's drop zone: the nearest")
        XCTAssertEqual(ComposerPick.nearest([search, composer], to: CGPoint(x: 200, y: 90)), 0)
        XCTAssertEqual(ComposerPick.nearest([.zero, composer], to: CGPoint(x: 0, y: 0)), 1, "an empty frame is no composer")
        XCTAssertNil(ComposerPick.nearest([], to: .zero))
    }
}
