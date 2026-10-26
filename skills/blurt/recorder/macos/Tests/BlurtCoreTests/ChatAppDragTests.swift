// Cards dragged into WeChat and Feishu (Lark), end to end through the decisions (v0.9 report):
//  1. a picture + note card arrived as the picture alone in both. It worked in v0.8.4: WeChat got the rich item (its
//     composer put the picture in), then Blurt pasted the note. v0.8.5 (cb35b4d6) gave every chat app the picture
//     alone — for WeChat (Qt, no public.png) a bare file URL: a file to send, not a picture in the message — and the
//     note had nowhere to go.
//  2. a voice card did nothing in Feishu (WeChat was fine): Feishu takes a text drop on its chat area and puts
//     nothing in, and Blurt took "taken" to mean done.
// The bundle ids are the ones the apps ship with: WeChat com.tencent.xinWeChat (Qt), Feishu / Lark com.electron.lark
// (the installed Lark.app; Chromium based, no Electron framework in its bundle — the table names it) and the other
// ids its builds have used.
import XCTest
@testable import BlurtCore

final class ChatAppDragTests: XCTestCase {
    let img = URL(fileURLWithPath: "/s/out/010/截图-102023.png")
    let note = "图片加文字"
    let wechat = "com.tencent.xinWeChat"
    let qq = "com.tencent.qq"
    let feishu = ["com.electron.lark", "com.bytedance.lark", "com.electron.feishu", "com.bytedance.feishu"]

    var shot: CardPasteboard.Card { CardPasteboard.Card(image: img, note: note) }
    var voice: CardPasteboard.Card { CardPasteboard.Card(image: nil, note: "纯文字的录音") }

    func landing(_ id: String, voice: Bool = false, canPaste: Bool = true) -> DragLanding {
        DragLanding.of(bundleID: id, kind: DropTargets.composer(bundleID: id, appURL: nil), voice: voice, canPaste: canPaste)
    }

    func testTheirClassAndComposer() {
        for id in [wechat, qq] {
            XCTAssertEqual(DropTargets.classify(bundleID: id), .chat, id)
            XCTAssertEqual(DropTargets.composer(bundleID: id, appURL: nil), .qt, id)
        }
        for id in feishu {
            XCTAssertEqual(DropTargets.classify(bundleID: id), .chat, id)
            XCTAssertEqual(DropTargets.composer(bundleID: id, appURL: nil), .web, id)
        }
    }

    // MARK: 1. picture + note

    /// WeChat / QQ: the rich item again (as in v0.8.4), not a bare file: their composer takes the picture from it.
    func testWeChatGetsTheRichItemItPutsInItsComposer() {
        for id in [wechat, qq] {
            let items = CardPasteboard.drag(into: landing(id), card: shot)
            XCTAssertEqual(items, CardPasteboard.drag(for: .rich, card: shot), id)
            XCTAssertTrue(items[0].rich && items[0].image == img && items[0].file == img, id)
            XCTAssertEqual(items.count, 2, "the badge's count")
            XCTAssertEqual(CardPasteboard.drag(into: landing(id), card: shot, attachNote: true), items, "never a .md in a chat")
        }
    }

    /// …and the note is still pasted after it: the class stays chat, the caret goes to the end first (⌘↓).
    func testWeChatThenGetsTheNotePasted() {
        for id in [wechat, qq] {
            let l = landing(id)
            XCTAssertEqual(l.cls, .chat)
            XCTAssertEqual(DragFollowUp.plan(delivered: l.cls, card: shot, enabled: true, accessibility: true, secureInput: false, kind: l.kind),
                           .pasteNote(note), id)
            XCTAssertEqual(FollowUpFocus.decide(.init(kind: .qt)), .paste(caret: [.end]), id)
            XCTAssertEqual(DragReceipt.outcome(delivered: l.cls, notePasted: true, noteFile: false), .both)
        }
    }

    /// Feishu keeps the picture alone (a web composer that took the HTML too would get the note twice), and the note
    /// is pasted after it.
    func testFeishuGetsThePictureThenTheNote() {
        for id in feishu {
            let l = landing(id)
            XCTAssertEqual(CardPasteboard.drag(into: l, card: shot), CardPasteboard.drag(for: .chat, card: shot), id)
            XCTAssertEqual(DragFollowUp.plan(delivered: l.cls, card: shot, enabled: true, accessibility: true, secureInput: false, kind: l.kind),
                           .pasteNote(note), id)
        }
        // what the focus may look like there: a composer, no Accessibility tree yet, or what the drop opened in a
        // window of its own over the drop point (sameWindow: it covers the drop point) — always the paste
        typealias F = FollowUpFocus.Facts
        XCTAssertEqual(FollowUpFocus.decide(F(kind: .web)), .paste(caret: [.end]))
        XCTAssertEqual(FollowUpFocus.decide(F(kind: .web, sameWindow: true, editable: true, selection: 0)), .paste(caret: []))
        let drop = CGPoint(x: 700, y: 640)
        let covers = FollowUpFocus.sameWindow(identical: false, focusedFrame: CGRect(x: 400, y: 200, width: 800, height: 700), drop: drop)
        XCTAssertEqual(covers, true)
        XCTAssertEqual(FollowUpFocus.decide(F(kind: .web, sameWindow: covers, editable: true, selection: 0)), .paste(caret: []))
    }

    func testTheWindowTheFocusIsIn() {
        let drop = CGPoint(x: 100, y: 100)
        XCTAssertEqual(FollowUpFocus.sameWindow(identical: true, focusedFrame: nil, drop: drop), true)
        XCTAssertEqual(FollowUpFocus.sameWindow(identical: false, focusedFrame: CGRect(x: 0, y: 0, width: 200, height: 200), drop: drop), true)
        XCTAssertEqual(FollowUpFocus.sameWindow(identical: false, focusedFrame: CGRect(x: 300, y: 0, width: 200, height: 200), drop: drop), false,
                       "another window elsewhere: no paste")
        XCTAssertEqual(FollowUpFocus.sameWindow(identical: false, focusedFrame: .zero, drop: drop), false)
        XCTAssertNil(FollowUpFocus.sameWindow(identical: nil, focusedFrame: nil, drop: drop))
        XCTAssertEqual(FollowUpFocus.sameWindow(identical: nil, focusedFrame: CGRect(x: 0, y: 0, width: 200, height: 200), drop: drop), true)
    }

    /// Other chat apps are as they were: the picture alone.
    func testOtherChatAppsKeepThePictureAlone() {
        for id in ["com.anthropic.claudefordesktop", "com.google.Chrome", "com.tinyspeck.slackmacgap", "com.example.Other"] {
            XCTAssertEqual(CardPasteboard.drag(into: landing(id), card: shot), CardPasteboard.drag(for: .chat, card: shot), id)
        }
        for c in DropClass.allCases {
            XCTAssertEqual(CardPasteboard.drag(into: DragLanding(cls: c), card: shot), CardPasteboard.drag(for: c, card: shot), "\(c)")
        }
    }

    // MARK: 2. a voice card (text only)

    /// Feishu: no words on the drag where Blurt can paste them — it can't take a text drop and lose it — and Blurt
    /// pastes them into its composer, whatever Feishu answered.
    func testFeishuGetsAVoiceCardsWordsPasted() {
        for id in feishu {
            let l = landing(id, voice: true)
            XCTAssertTrue(l.wordsWithheld, id)
            XCTAssertEqual(CardPasteboard.drag(into: l, card: voice), [CardPasteboard.Item(tag: true)], "only the capture's tag")
            for accepted in [true, false] {
                XCTAssertEqual(VoiceCardDrop.plan(cls: l.cls, kind: l.kind, accepted: accepted, words: voice.note, enabled: true,
                                                  accessibility: true, secureInput: false, wordsWithheld: l.wordsWithheld),
                               .paste("纯文字的录音"), "\(id) accepted=\(accepted)")
            }
            XCTAssertEqual(VoiceCardDrop.hint(cls: l.cls, kind: l.kind, app: "飞书", enabled: true, accessibility: true), .paste(app: "飞书"))
        }
    }

    /// Without Accessibility (or smart paste off) the words stay on the drag (a drop on the box itself still works)
    /// and go on the clipboard too: "已复制，在 飞书 里按 ⌘V 粘贴" — never nothing at all.
    func testFeishuWithoutAccessibilityCopiesTheWords() {
        let l = landing("com.electron.lark", voice: true, canPaste: false)
        XCTAssertFalse(l.wordsWithheld)
        XCTAssertEqual(CardPasteboard.drag(into: l, card: voice), [CardPasteboard.Item(text: "纯文字的录音", tag: true)])
        for accepted in [true, false] {
            XCTAssertEqual(VoiceCardDrop.plan(cls: l.cls, kind: l.kind, accepted: accepted, words: voice.note, enabled: true,
                                              accessibility: false, secureInput: false, wordsWithheld: false), .copy("纯文字的录音"))
        }
    }

    /// WeChat: its own text drop (it works there) — the words stay on the drag, and a drop it took is left alone.
    func testWeChatKeepsItsOwnTextDrop() {
        let l = landing(wechat, voice: true)
        XCTAssertFalse(l.wordsWithheld)
        XCTAssertEqual(CardPasteboard.drag(into: l, card: voice), [CardPasteboard.Item(text: "纯文字的录音", tag: true)])
        XCTAssertEqual(VoiceCardDrop.plan(cls: l.cls, kind: l.kind, accepted: true, words: voice.note, enabled: true,
                                          accessibility: true, secureInput: false), .none("app_took_it"))
        XCTAssertEqual(VoiceCardDrop.plan(cls: l.cls, kind: l.kind, accepted: false, words: voice.note, enabled: true,
                                          accessibility: true, secureInput: false), .paste("纯文字的录音"))
    }

    /// Only the voice card's own drag changes: a shot card over Feishu still carries its picture.
    func testWithholdingIsForVoiceCardsOnly() {
        XCTAssertFalse(landing("com.electron.lark", voice: false).wordsWithheld)
        XCTAssertEqual(CardPasteboard.drag(into: DragLanding(cls: .chat, kind: .web, wordsWithheld: true), card: shot),
                       CardPasteboard.drag(for: .chat, card: shot))
        XCTAssertEqual(CardPasteboard.drag(into: DragLanding(cls: .chat, kind: .web, wordsWithheld: true),
                                           card: CardPasteboard.Card(image: nil, note: " ")), [], "no words: nothing to drag")
    }
}
