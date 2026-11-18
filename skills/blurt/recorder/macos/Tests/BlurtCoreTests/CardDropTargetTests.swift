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
    func testACodingAgentsWindowIsATerminal() {
        let code = AgentWindow.Facts(urls: ["file:///Applications/Claude.app/Contents/Resources/app.asar/.vite/renderer/main_window/index.html",
                                            "https://claude.ai/epitaxy/local_2f383153"])
        let chat = AgentWindow.Facts(urls: ["https://claude.ai/chat/0b1c", "https://claude.ai/new"])
        XCTAssertTrue(AgentWindow.isAgent(bundleID: AgentWindow.claude, code))
        XCTAssertFalse(AgentWindow.isAgent(bundleID: AgentWindow.claude, chat))
        XCTAssertFalse(AgentWindow.isAgent(bundleID: AgentWindow.claude, .init(urls: ["https://evil.example/epitaxy/x"])))
        let codex = AgentWindow.Facts(popUps: ["Usage", "Switch mode, current mode: Codex", "GPT-6.1 Sol High"])
        let chatgpt = AgentWindow.Facts(popUps: ["Switch mode, current mode: ChatGPT", "gpt-5-codex"])
        XCTAssertTrue(AgentWindow.isAgent(bundleID: AgentWindow.codex, codex))
        XCTAssertTrue(AgentWindow.isAgent(bundleID: AgentWindow.codex, .init(popUps: ["切换模式，当前模式：Codex"])))
        XCTAssertFalse(AgentWindow.isAgent(bundleID: AgentWindow.codex, chatgpt), "a model named codex is not the mode")
        XCTAssertFalse(AgentWindow.isAgent(bundleID: AgentWindow.codex, .init()))
        XCTAssertFalse(AgentWindow.isAgent(bundleID: "com.google.Chrome", codex))
        XCTAssertEqual(DropTargets.classify(bundleID: AgentWindow.codex, agent: true), .terminal)
        XCTAssertEqual(DropTargets.classify(bundleID: AgentWindow.codex), .chat)
        XCTAssertEqual(DropTargets.classify(bundleID: AgentWindow.claude), .chat)
        for id in ["com.tencent.workbuddy.mac", "com.qoder.work", "com.kimi.code.desktop", "com.work.pc.doubao", "com.qoder.ide",
                   "com.todesktop.230313mzl4w4u92", "com.trae.app"] {
            XCTAssertEqual(DropTargets.classify(bundleID: id, agent: true), .terminal, id)
        }
        // cloud chats and plain editors are not agents here
        for id in ["com.moonshot.kimichat", "com.microsoft.VSCode", "com.apple.dt.Xcode"] {
            XCTAssertFalse(AgentWindow.builtIn.contains(id), id)
        }
        // the user's changes: add any app, switch a built-in one off; a built-in app's own state is no change
        let mine = AgentWindow.changing(AgentWindow.changing([:], "com.example.agent", on: true), "com.trae.app", on: false)
        XCTAssertEqual(mine, ["com.example.agent": true, "com.trae.app": false])
        XCTAssertTrue(AgentWindow.list(mine).contains("com.example.agent"))
        XCTAssertFalse(AgentWindow.list(mine).contains("com.trae.app"))
        XCTAssertTrue(AgentWindow.list(mine).contains(AgentWindow.codex))
        XCTAssertEqual(AgentWindow.changing(mine, "com.trae.app", on: true), ["com.example.agent": true])
        XCTAssertEqual(AgentWindow.changing(mine, "com.example.agent", on: false), ["com.trae.app": false])
        XCTAssertTrue(AgentWindow.checksWindow(AgentWindow.claude))
        XCTAssertFalse(AgentWindow.checksWindow("com.tencent.workbuddy.mac"))
        XCTAssertTrue(AgentWindow.getsPaths(setting: nil))
        XCTAssertTrue(AgentWindow.getsPaths(setting: "paths"))
        XCTAssertFalse(AgentWindow.getsPaths(setting: "same"))
    }

    func testTheComposerKind() {
        for id in ["com.google.Chrome", "com.apple.Safari", "com.anthropic.claudefordesktop", "com.electron.lark", "com.tinyspeck.slackmacgap"] {
            XCTAssertEqual(DropTargets.composer(bundleID: id, appURL: nil), .web, id)
        }
        XCTAssertEqual(DropTargets.composer(bundleID: "com.tencent.xinWeChat", appURL: nil), .qt)
        XCTAssertEqual(DropTargets.composer(bundleID: "com.tencent.qq", appURL: nil), .qt)
        XCTAssertEqual(DropTargets.composer(bundleID: "com.example.native", appURL: nil), .native)
        XCTAssertEqual(DropTargets.composer(bundleID: nil, appURL: nil), .native)
    }

    /// Code editors are chat apps for the drop (the picture alone) but their own composer kind: the focus after a drop
    /// may be source code, so Blurt never pastes there by itself (v0.8.7, the capture audit).
    func testCodeEditorsAreTheirOwnKind() {
        for id in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed",
                   "com.apple.dt.Xcode", "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.sublimetext.4", "com.panic.Nova"] {
            XCTAssertTrue(DropTargets.isCodeEditor(id), id)
            XCTAssertEqual(DropTargets.classify(bundleID: id), .chat, id)
            XCTAssertEqual(DropTargets.composer(bundleID: id, appURL: nil), .editor, id)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-editor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Cursor.app")
        try? FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
                                                 withIntermediateDirectories: true)
        XCTAssertEqual(DropTargets.composer(bundleID: "com.todesktop.230313mzl4w4u92", appURL: app), .editor,
                       "an Electron editor is an editor first")
        for id in ["com.google.Chrome", "com.anthropic.claudefordesktop", "com.tinyspeck.slackmacgap", "com.example.native"] {
            XCTAssertFalse(DropTargets.isCodeEditor(id), id)
        }
        XCTAssertFalse(DropTargets.isCodeEditor(nil))
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

    /// A terminal (Claude Code / Codex in it) gets one line of text: the picture's path, then its note — paired, so
    /// several cards never get their notes mixed up. No file URL (the terminal would type its own copy of the path), no
    /// .md, no picture bytes, no rich text; never a newline. The option doesn't matter there.
    func testATerminalGetsThePathThenTheNoteAsOneLine() {
        for attach in [false, true] {
            let items = CardPasteboard.drag(for: .terminal, card: card, attachNote: attach)
            XCTAssertEqual(items, [CardPasteboard.Item(text: "/s/out/003/截图-144012.png see the header the logo overlaps", tag: true), inert])
            XCTAssertTrue(items.allSatisfy { $0.file == nil && $0.image == nil && !$0.rich })
            XCTAssertFalse(items[0].text!.contains { $0.isNewline })
        }
        // a path that needs quoting
        let spaced = URL(fileURLWithPath: "/Users/Ana Li/.blurt/sessions/s 1/out/003/Screenshot-144012.png")
        XCTAssertEqual(CardPasteboard.drag(for: .terminal, card: CardPasteboard.Card(image: spaced, note: "the logo"))[0].text,
                       "'/Users/Ana Li/.blurt/sessions/s 1/out/003/Screenshot-144012.png' the logo")
        // no note: the path alone, one item
        XCTAssertEqual(CardPasteboard.drag(for: .terminal, card: CardPasteboard.Card(image: img, note: nil, noteFile: md)),
                       [CardPasteboard.Item(text: "/s/out/003/截图-144012.png", tag: true)])
        // a voice card: its words, as a text drop everywhere (the " · " one line)
        XCTAssertEqual(CardPasteboard.drag(for: .terminal, card: CardPasteboard.Card(image: nil, note: note)),
                       [CardPasteboard.Item(text: "see the header · the logo overlaps", tag: true)])
        // over a terminal the landing is the terminal's layout, whatever its composer kind
        for k in ComposerKind.allCases {
            XCTAssertEqual(CardPasteboard.drag(into: DragLanding(cls: .terminal, kind: k), card: card), CardPasteboard.drag(for: .terminal, card: card))
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
        XCTAssertFalse(DragReceipt.copiesNote(.paths), "path and note went in; ⌘V would paste at a prompt")
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

/// DropWindows: the window under a drag. The 1.0.22 report — every card dropped into Claude Code / Codex arrived as the
/// picture alone: macOS 26.5's Notification Center window (full screen, transparent, layer 21) was taken for the app.
final class DropWindowsTests: XCTestCase {
    let full = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let me = 87047

    func testNotificationCenterAndTheMenuBarAreNeverTheTarget() {
        let ws: [DropWindows.Window] = [
            .init(pid: 83774, ownerName: "Bartender 6", layer: 26, alpha: 0, bounds: CGRect(x: 0, y: -1, width: 1728, height: 34)),
            .init(pid: 581, bundleID: "com.apple.controlcenter", layer: 25, bounds: CGRect(x: 1395, y: 0, width: 56, height: 33)),
            .init(pid: 166, ownerName: "Window Server", layer: 24, bounds: CGRect(x: 0, y: 0, width: 1728, height: 33)),
            .init(pid: 547, bundleID: "com.apple.notificationcenterui", layer: 21, bounds: full),
            .init(pid: 23477, bundleID: "com.anthropic.claudefordesktop", bounds: CGRect(x: 0, y: 33, width: 1728, height: 1084)),
        ]
        XCTAssertEqual(DropWindows.pick(ws, at: CGPoint(x: 800, y: 600), me: me), .app(23477))
        // over the menu bar: nothing that takes a drop
        XCTAssertEqual(DropWindows.pick(ws, at: CGPoint(x: 1400, y: 10), me: me), .nothing)
    }

    func testAnOverlayProcessIsSkippedAtAnyLevel() {
        let ws: [DropWindows.Window] = [
            .init(pid: 547, bundleID: "com.apple.notificationcenterui", layer: 0, bounds: full),
            .init(pid: 9, bundleID: "com.openai.codex", bounds: full),
        ]
        XCTAssertEqual(DropWindows.pick(ws, at: CGPoint(x: 5, y: 500), me: me), .app(9))
    }

    func testOurWindowsAreAnInAppDropUnlessMouseTransparent() {
        let island = DropWindows.Window(pid: me, layer: 27, bounds: CGRect(x: 544, y: 0, width: 640, height: 470))
        let cards = DropWindows.Window(pid: me, layer: 25, bounds: CGRect(x: 300, y: 0, width: 1100, height: 300), oursTakesMouse: false)
        let main = DropWindows.Window(pid: me, bounds: CGRect(x: 205, y: 127, width: 1277, height: 889))
        let app = DropWindows.Window(pid: 9, bundleID: "com.openai.codex", bounds: full)
        XCTAssertEqual(DropWindows.pick([island, app], at: CGPoint(x: 600, y: 100), me: me), .ours)
        XCTAssertEqual(DropWindows.pick([cards, app], at: CGPoint(x: 400, y: 100), me: me), .app(9), "the cards take no drops")
        XCTAssertEqual(DropWindows.pick([cards, main, app], at: CGPoint(x: 400, y: 200), me: me), .ours, "the main window under the cards")
        let dragImage = DropWindows.Window(pid: me, layer: 500, bounds: full)
        XCTAssertEqual(DropWindows.pick([dragImage, app], at: CGPoint(x: 400, y: 600), me: me), .app(9))
    }
}

/// Several cards dragged as one (v1.0.23), and file cards (a referenced PDF / video).
final class MultiCardDragTests: XCTestCase {
    let a = CardPasteboard.Card(image: URL(fileURLWithPath: "/s/shots/001.png"), note: "header overlaps")
    let b = CardPasteboard.Card(image: URL(fileURLWithPath: "/s/shots/003.png"), note: "button\ntoo small")
    let pdf = CardPasteboard.Card(image: URL(fileURLWithPath: "/s/shots/004.png"), note: "the spec",
                                  ref: URL(fileURLWithPath: "/Users/me/Documents/spec v2.pdf"))
    let words = CardPasteboard.Card(image: nil, note: "also check dark mode")

    func testAnAgentGetsALinePerCardATerminalOneLine() {
        let agent = CardPasteboard.drag(into: DragLanding(cls: .terminal, lines: true), cards: [a, b, pdf, words])
        XCTAssertEqual(agent.first, .init(text: "/s/shots/001.png header overlaps\n/s/shots/003.png button too small\n'/Users/me/Documents/spec v2.pdf' the spec\nalso check dark mode", tag: true))
        XCTAssertEqual(agent.count, 4, "one item per card: the count badge says 4")
        XCTAssertTrue(agent.allSatisfy(\.tag), "every item names the cards (an in-app drop reads any of them)")
        let term = CardPasteboard.drag(into: DragLanding(cls: .terminal), cards: [a, b])
        XCTAssertEqual(term.first?.text, "/s/shots/001.png header overlaps  /s/shots/003.png button too small")
        XCTAssertFalse(term.first?.text?.contains("\n") ?? true, "never a newline at a shell prompt")
    }

    func testAChatAppGetsEveryFileInOrderAndTheNotesAfter() {
        let items = CardPasteboard.drag(into: DragLanding(cls: .chat, kind: .web), cards: [a, words, pdf])
        XCTAssertEqual(items.map(\.file?.path), ["/s/shots/001.png", nil, "/Users/me/Documents/spec v2.pdf"])
        XCTAssertEqual(items.map(\.image?.path), ["/s/shots/001.png", nil, nil], "a file card's thumbnail never goes out")
        XCTAssertTrue(items.allSatisfy(\.tag))
        XCTAssertEqual(CardTransfer.followUpNotes([a, words, pdf]), "1. header overlaps\n2. the spec\nalso check dark mode")
        XCTAssertEqual(CardTransfer.followUpNotes([a, words]), "header overlaps\nalso check dark mode", "one picture: no numbers")
    }

    func testARichAppGetsOneRichItemAndTheFinderTheFiles() {
        let rich = CardPasteboard.drag(into: DragLanding(cls: .rich), cards: [a, b])
        XCTAssertEqual(rich.count, 2)
        XCTAssertTrue(rich[0].rich)
        XCTAssertEqual(rich[1], .init(tag: true))
        let finder = CardPasteboard.drag(into: DragLanding(cls: .finder), cards: [a, pdf])
        XCTAssertEqual(finder.map(\.file?.lastPathComponent), ["001.png", "spec v2.pdf"])
    }

    func testOneFileCardGoesOutAsItsFile() {
        XCTAssertEqual(CardPasteboard.drag(into: DragLanding(cls: .terminal), card: pdf),
                       [.init(text: "'/Users/me/Documents/spec v2.pdf' the spec", tag: true), .init(tag: true)])
        XCTAssertEqual(CardPasteboard.drag(into: DragLanding(cls: .chat, kind: .web), card: pdf).first,
                       .init(file: URL(fileURLWithPath: "/Users/me/Documents/spec v2.pdf"), tag: true))
    }

    func testTheItemCountIsTheCardCountForEveryApp() {
        let landings: [DragLanding] = [.init(cls: .chat, kind: .web), .init(cls: .chat, kind: .qt), .init(cls: .rich), .init(cls: .finder),
                                       .init(cls: .terminal), .init(cls: .terminal, lines: true)]
        for l in landings { XCTAssertEqual(CardPasteboard.drag(into: l, cards: [a, words, pdf]).count, 3, "\(l)") }
    }

    // MARK: v1.0.26 — one list with the agents (agents.json `drop`), the same vectors as tests/test_agent_detect.py

    /// the repo's agents.json (skills/blurt/scripts), as agents.py reads it
    func registry() throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../scripts/agents.json").standardizedFileURL
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return try XCTUnwrap(o?["agents"] as? [[String: Any]])
    }

    func testDropTargetsFromAgentsJSON() throws {
        let reg = try registry()
        let t = Dictionary(uniqueKeysWithValues: AgentDropList.targets(registry: reg, record: [:]).map { ($0.agent, $0) })
        XCTAssertEqual(t["claude"]?.ids, [AgentWindow.claude])
        XCTAssertEqual(t["claude"]?.drop, "composer")
        XCTAssertEqual(t["codex"]?.ids, [AgentWindow.codex])
        XCTAssertEqual(t["workbuddy"]?.drop, "composer")
        XCTAssertEqual(t["cursor"]?.drop, "terminal")
        XCTAssertNil(t["gemini"], "no app, no drop")
        XCTAssertTrue(t.values.allSatisfy(\.on))
        // every built-in of v1.0.21 is still in the list
        let all = AgentWindow.list(record: [:], registry: reg)
        XCTAssertTrue(AgentWindow.builtIn.isSubset(of: all), "\(AgentWindow.builtIn.subtracting(all))")
        let composers = AgentWindow.composers(record: [:], registry: reg)
        XCTAssertTrue(composers.contains("com.tencent.workbuddy.mac") && composers.contains(AgentWindow.codex))
        XCTAssertFalse(composers.contains("com.todesktop.230313mzl4w4u92"), "an AI IDE: its drop may land in its terminal")
        // switched off (record.agent_drop), a user's own (record.agent_defs)
        let mine: [String: Any] = ["agent_drop": ["cursor": false],
                                   "agent_defs": ["zed": AgentDropList.customDef(name: "Zed", bundleID: "dev.zed.Zed")]]
        let l = AgentWindow.list(record: mine, registry: reg)
        XCTAssertFalse(l.contains("com.todesktop.230313mzl4w4u92"))
        XCTAssertTrue(l.contains("dev.zed.Zed"))
        XCTAssertEqual(AgentDropList.targets(registry: reg, record: mine).first { $0.agent == "zed" }?.custom, true)
        // no agents.json at hand: the built-in list with v1.0.21's changes
        XCTAssertEqual(AgentWindow.list(record: ["agent_apps": ["com.trae.app": false]], registry: nil),
                       AgentWindow.builtIn.subtracting(["com.trae.app"]))
    }

    func testLegacyAgentAppsStillCountThenMove() throws {
        let reg = try registry()
        let legacy: [String: Any] = ["agent_apps": ["com.todesktop.230313mzl4w4u92": false, "dev.zed.Zed": true]]
        let t = Dictionary(uniqueKeysWithValues: AgentDropList.targets(registry: reg, record: legacy).map { ($0.agent, $0) })
        XCTAssertEqual(t["cursor"]?.on, false)
        XCTAssertEqual(t["dev.zed.Zed"]?.on, true)
        XCTAssertEqual(t["dev.zed.Zed"]?.custom, true)
        let patch = try XCTUnwrap(AgentDropList.migrate(registry: reg, record: legacy))
        XCTAssertTrue(patch["agent_apps"] is NSNull)
        XCTAssertEqual(patch["agent_drop"] as? [String: Bool], ["cursor": false])
        let defs = try XCTUnwrap(patch["agent_defs"] as? [String: Any])
        XCTAssertEqual(defs.count, 1)
        let (zid, zdef) = (defs.first!.key, defs.first!.value as? [String: Any])
        XCTAssertEqual(zid, "zed")
        XCTAssertEqual((zdef?["app"] as? [String: Any])?["macos"] as? [String], ["dev.zed.Zed"])
        XCTAssertEqual(zdef?["drop"] as? String, "terminal")
        XCTAssertEqual(zdef?["connect"] as? Bool, false)
        var after: [String: Any] = [:]
        for (k, v) in patch where !(v is NSNull) { after[k] = v }
        let t2 = Dictionary(uniqueKeysWithValues: AgentDropList.targets(registry: reg, record: after).map { ($0.agent, $0) })
        XCTAssertEqual(t2["cursor"]?.on, false)
        XCTAssertEqual(t2[zid]?.ids, ["dev.zed.Zed"])
        XCTAssertEqual(t2[zid]?.on, true)
        XCTAssertNil(AgentDropList.migrate(registry: reg, record: after), "nothing left to move")
    }

    func testCustomIDs() {
        XCTAssertEqual(AgentDropList.customID("My Agent", taken: []), "my-agent")
        XCTAssertEqual(AgentDropList.customID("My Agent", taken: ["my-agent"]), "my-agent-2")
        XCTAssertEqual(AgentDropList.customID("豆包 工作", taken: []), "豆包-工作")
        XCTAssertEqual(AgentDropList.customID("  ", taken: []), "agent")
    }
}
