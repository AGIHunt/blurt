// BlurtCore/VoiceCardDrop.swift: a voice card let go of anywhere in a chat app's window gets its words pasted into
// that window's composer. The report: into Claude desktop it only worked on the input box itself (Electron takes a
// text drop only there and shows its drop overlay only for files).
import XCTest
@testable import BlurtCore

final class VoiceCardDropTests: XCTestCase {
    let words = "把登录页的按钮再调大一点\n然后发给设计看看"

    func plan(_ cls: DropClass?, _ kind: ComposerKind?, accepted: Bool = false, words: String? = nil, enabled: Bool = true,
              ax: Bool = true, secure: Bool = false, withheld: Bool? = nil) -> VoiceCardDrop.Plan {
        // what the drag did over that window when it was let go of: words left off where Blurt can paste them
        let w = withheld ?? (cls.map { c in kind.map { VoiceCardDrop.withholdsWords(cls: c, kind: $0, canPaste: enabled && ax) } ?? false } ?? false)
        return VoiceCardDrop.plan(cls: cls, kind: kind, accepted: accepted, words: words ?? self.words, enabled: enabled,
                                  accessibility: ax, secureInput: secure, wordsWithheld: w)
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

    func testADropWeChatTookIsLeftAlone() {
        // WeChat / QQ put a text drop in their composer: pasting as well would put the words in twice
        XCTAssertEqual(plan(.chat, .qt, accepted: true), .none("app_took_it"))
        XCTAssertEqual(plan(.chat, .qt, accepted: true, ax: false), .none("app_took_it"))
    }

    /// v0.9, the report: a voice card dragged into Feishu did nothing. Feishu takes a text drop on its chat area and
    /// puts nothing in; Blurt took "taken" to mean done. Over a web composer the drag now carries no words where Blurt
    /// can paste them, and Blurt pastes them taken or not.
    func testAWebAppsYesToADropProvesNothing() {
        XCTAssertTrue(VoiceCardDrop.withholdsWords(cls: .chat, kind: .web, canPaste: true))
        XCTAssertFalse(VoiceCardDrop.withholdsWords(cls: .chat, kind: .web, canPaste: false), "then a drop on the box is the only way in")
        XCTAssertFalse(VoiceCardDrop.withholdsWords(cls: .chat, kind: .qt, canPaste: true), "WeChat's own text drop works")
        for k in [ComposerKind.native, .editor] { XCTAssertFalse(VoiceCardDrop.withholdsWords(cls: .chat, kind: k, canPaste: true), "\(k)") }
        for c in [DropClass.rich, .terminal, .finder] { XCTAssertFalse(VoiceCardDrop.withholdsWords(cls: c, kind: .web, canPaste: true), "\(c)") }

        XCTAssertEqual(plan(.chat, .web, accepted: true), .paste(words), "the drag had no words for it to take")
        XCTAssertEqual(plan(.chat, .web, accepted: false), .paste(words))
        // can't paste: the words were on the drag; whether a web app that took them put them in, nobody knows
        XCTAssertEqual(plan(.chat, .web, accepted: true, ax: false), .copy(words))
        XCTAssertEqual(plan(.chat, .web, accepted: true, enabled: false), .copy(words))
        XCTAssertEqual(plan(.chat, .web, accepted: true, secure: true, withheld: true), .copy(words))
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
}
