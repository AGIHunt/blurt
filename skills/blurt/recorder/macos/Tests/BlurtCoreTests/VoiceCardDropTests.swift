// BlurtCore/VoiceCardDrop.swift: a voice card let go of anywhere in a chat app's window gets its words pasted into
// that window's composer. The report: into Claude desktop it only worked on the input box itself (Electron takes a
// text drop only there and shows its drop overlay only for files).
import XCTest
@testable import BlurtCore

final class VoiceCardDropTests: XCTestCase {
    let words = "把登录页的按钮再调大一点\n然后发给设计看看"

    /// `bundle`: the app (nil: one no table names specially); what the drag did over that window when it was let go
    /// of: words left off only over Feishu / Lark, where Blurt can paste them.
    func plan(_ cls: DropClass?, _ kind: ComposerKind?, accepted: Bool = false, words: String? = nil, enabled: Bool = true,
              ax: Bool = true, secure: Bool = false, bundle: String? = nil, withheld: Bool? = nil) -> VoiceCardDrop.Plan {
        let w = withheld ?? (cls.map { c in kind.map { VoiceCardDrop.withholdsWords(bundleID: bundle, cls: c, kind: $0,
                                                                                    canPaste: enabled && ax) } ?? false } ?? false)
        return VoiceCardDrop.plan(cls: cls, kind: kind, accepted: accepted, words: words ?? self.words, enabled: enabled,
                                  accessibility: ax, secureInput: secure,
                                  swallows: VoiceCardDrop.swallowsTextDrop(bundleID: bundle), wordsWithheld: w)
    }

    func testChatAppsWithAWebOrQtComposerAreTargets() {
        XCTAssertTrue(VoiceCardDrop.pastes(cls: .chat, kind: .web))       // browsers, Claude, Feishu, Slack
        XCTAssertTrue(VoiceCardDrop.pastes(cls: .chat, kind: .qt))        // WeChat, QQ
        XCTAssertFalse(VoiceCardDrop.pastes(cls: .chat, kind: .native))   // an app no table names: its own text drop
        XCTAssertFalse(VoiceCardDrop.pastes(cls: .chat, kind: .editor))   // a code editor: never a paste into source code
        XCTAssertEqual(plan(.chat, .editor), .none("not_a_chat_app"))
        XCTAssertNil(VoiceCardDrop.hint(cls: .chat, kind: .editor, app: "Cursor", enabled: true, accessibility: true))
        for c in [DropClass.rich, .terminal, .finder] {
            for k in ComposerKind.allCases { XCTAssertFalse(VoiceCardDrop.pastes(cls: c, kind: k), "\(c) \(k)") }
        }
    }

    func testARefusedDropInAChatAppPastesTheWords() {
        XCTAssertEqual(plan(.chat, .web), .paste(words))
        XCTAssertEqual(plan(.chat, .qt), .paste(words))
    }

    func testADropTheAppTookIsLeftAlone() {
        // the composer itself took the text: pasting as well would put the words in twice (WeChat, QQ, the browsers,
        // Claude, Slack… — as before v0.9), with or without Accessibility, and nothing goes on the clipboard
        for (k, id) in [(ComposerKind.qt, "com.tencent.xinWeChat"), (.web, "com.google.Chrome"), (.web, "com.anthropic.claudefordesktop"), (.web, nil)] {
            XCTAssertEqual(plan(.chat, k, accepted: true, bundle: id), .none("app_took_it"), id ?? "?")
            XCTAssertEqual(plan(.chat, k, accepted: true, ax: false, bundle: id), .none("app_took_it"), id ?? "?")
            XCTAssertEqual(plan(.chat, k, accepted: true, enabled: false, bundle: id), .none("app_took_it"), id ?? "?")
        }
    }

    /// v0.9, the report: a voice card dragged into Feishu did nothing. Feishu takes a text drop on its chat area and
    /// puts nothing in; Blurt took "taken" to mean done. Over Feishu / Lark only, the drag now carries no words where
    /// Blurt can paste them, and Blurt pastes them taken or not.
    func testFeishusYesToADropProvesNothing() {
        let lark = "com.electron.lark"
        XCTAssertTrue(VoiceCardDrop.withholdsWords(bundleID: lark, cls: .chat, kind: .web, canPaste: true))
        XCTAssertFalse(VoiceCardDrop.withholdsWords(bundleID: lark, cls: .chat, kind: .web, canPaste: false), "then a drop on the box is the only way in")
        for id in ["com.tencent.xinWeChat", "com.google.Chrome", "com.anthropic.claudefordesktop", "com.tinyspeck.slackmacgap", "notion.id"] {
            let k = DropTargets.composer(bundleID: id, appURL: nil)
            XCTAssertFalse(VoiceCardDrop.withholdsWords(bundleID: id, cls: .chat, kind: k, canPaste: true), "\(id): its own text drop")
        }
        for c in [DropClass.rich, .terminal, .finder] { XCTAssertFalse(VoiceCardDrop.withholdsWords(bundleID: lark, cls: c, kind: .web, canPaste: true), "\(c)") }

        XCTAssertEqual(plan(.chat, .web, accepted: true, bundle: lark), .paste(words), "the drag had no words for it to take")
        XCTAssertEqual(plan(.chat, .web, accepted: false, bundle: lark), .paste(words))
        // the drop beat the rewrite: the words were on the drag, Feishu said yes and put nothing in — paste anyway
        XCTAssertEqual(plan(.chat, .web, accepted: true, bundle: lark, withheld: false), .paste(words))
        // can't paste: the words were on the drag, and Feishu's yes says nothing — on the clipboard
        XCTAssertEqual(plan(.chat, .web, accepted: true, ax: false, bundle: lark), .copy(words))
        XCTAssertEqual(plan(.chat, .web, accepted: true, enabled: false, bundle: lark), .copy(words))
        XCTAssertEqual(plan(.chat, .web, accepted: true, secure: true, bundle: lark, withheld: true), .copy(words))
    }

    func testTextNativeAppsKeepTheNormalTextDrop() {
        XCTAssertEqual(plan(.rich, .native), .none("not_a_chat_app"))
        XCTAssertEqual(plan(.terminal, .native), .none("not_a_chat_app"))       // a terminal types only what a text drop would
        XCTAssertEqual(plan(.finder, .native), .none("not_a_chat_app"))
        XCTAssertEqual(plan(.chat, .native), .none("not_a_chat_app"))
        XCTAssertEqual(plan(nil, nil), .none("not_a_chat_app"))                 // Blurt's own window, or nothing
    }

    func testWhenThePasteCantRunTheWordsGoOnTheClipboard() {
        XCTAssertEqual(plan(.chat, .web, enabled: false), .copy(words))
        XCTAssertEqual(plan(.chat, .web, ax: false), .copy(words))
        XCTAssertEqual(plan(.chat, .web, secure: true), .copy(words))
    }

    func testNoWordsNothingToPaste() {
        XCTAssertEqual(plan(.chat, .web, words: "  \n "), .none("no_words"))
    }

    func testTheHintNamesTheAppOnlyOverATarget() {
        XCTAssertEqual(VoiceCardDrop.hint(cls: .chat, kind: .web, app: "Claude", enabled: true, accessibility: true), .paste(app: "Claude"))
        XCTAssertEqual(VoiceCardDrop.hint(cls: .chat, kind: .qt, app: "微信", enabled: true, accessibility: false), .copy(app: "微信"))
        XCTAssertEqual(VoiceCardDrop.hint(cls: .chat, kind: .web, app: "Slack", enabled: false, accessibility: true), .copy(app: "Slack"))
        XCTAssertEqual(VoiceCardDrop.hint(cls: .chat, kind: .web, app: " ", enabled: true, accessibility: true), .paste(app: "App"))
        XCTAssertNil(VoiceCardDrop.hint(cls: .rich, kind: .native, app: "Notes", enabled: true, accessibility: true))
        XCTAssertNil(VoiceCardDrop.hint(cls: .terminal, kind: .native, app: "Terminal", enabled: true, accessibility: true))
        XCTAssertNil(VoiceCardDrop.hint(cls: nil, kind: nil, app: nil, enabled: true, accessibility: true))
    }

    /// The dogfood: Blurt sent End + ⌘V to Claude, couldn't read it back, and said "Copied — ⌘V to paste": the user
    /// pasted a second copy. Keys sent but unconfirmed is pasted (the words stay on the clipboard, unsaid).
    func testAnUnconfirmedPasteIsReportedAsPasted() {
        XCTAssertEqual(VoiceCardDrop.outcome(.confirmed).toast, "capture.voice_drop.pasted")
        XCTAssertFalse(VoiceCardDrop.outcome(.confirmed).copyWords)
        XCTAssertEqual(VoiceCardDrop.outcome(.unconfirmed).toast, "capture.voice_drop.pasted")
        XCTAssertTrue(VoiceCardDrop.outcome(.unconfirmed).copyWords, "the safety net, quietly")
        XCTAssertEqual(VoiceCardDrop.outcome(.notSent).toast, "capture.voice_drop.copied")
        XCTAssertTrue(VoiceCardDrop.outcome(.notSent).copyWords)
    }

    /// A shot card's note by the same rule: keys sent, read unconfirmed = pasted ("picture and note"), the note on the
    /// clipboard quietly; never "⌘V to paste" after Blurt already pasted it.
    func testAShotCardsUnconfirmedNoteIsPastedToo() {
        XCTAssertTrue(DragReceipt.followUp(.unconfirmed).notePasted)
        XCTAssertTrue(DragReceipt.followUp(.unconfirmed).quietCopy)
        XCTAssertEqual(DragReceipt.outcome(delivered: .chat, notePasted: DragReceipt.followUp(.unconfirmed).notePasted, noteFile: false), .both)
        XCTAssertEqual(DragReceipt.toastKey(.both, hasNote: true, noteCopied: false), "capture.taken_out_text")
        XCTAssertFalse(DragReceipt.followUp(.notSent).notePasted)
        XCTAssertFalse(DragReceipt.followUp(.confirmed).quietCopy)
    }
}
