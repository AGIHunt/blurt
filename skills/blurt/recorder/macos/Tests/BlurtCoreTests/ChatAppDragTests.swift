// Cards dragged into WeChat and Feishu (Lark), end to end through the decisions (v0.9 report):
//  1. a picture + note card arrived as the picture alone in both. It worked in v0.8.4: WeChat got the rich item (its
//     composer put the picture in), then Blurt pasted the note. v0.8.5 (cb35b4d6) gave every chat app the picture
//     alone — for WeChat (Qt, no public.png) a bare file URL: a file to send, not a picture in the message — and the
//     note had nowhere to go. Feishu: the note's blind paste after the drop didn't land (cause not observed; Feishu
//     shows Accessibility nothing of its web content without a screen reader) — now the note is pasted only into text
//     Accessibility confirms there, else it goes on the clipboard ("⌘V to paste"), and the drag's events are kept in
//     <BLURT_HOME>/logs/card-drag.log to find out.
//  2. a voice card did nothing in Feishu (WeChat was fine): Feishu takes a text drop on its chat area and puts
//     nothing in, and Blurt took "taken" to mean done. Only Feishu changes; every other app keeps its own text drop.
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
    let feishu = ["com.electron.lark", "com.bytedance.lark", "com.electron.feishu", "com.bytedance.feishu", "com.bytedance.macos.feishu",
                  "com.bytedance.macos.lark"]
    let otherWeb = ["com.google.Chrome", "com.anthropic.claudefordesktop", "com.apple.Safari", "com.tinyspeck.slackmacgap", "notion.id"]

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
    /// is pasted after it — but only into text Accessibility confirms: the blind paste is what didn't land.
    func testFeishuGetsThePictureThenTheNoteOnlyIntoText() {
        typealias F = FollowUpFocus.Facts
        for id in feishu {
            let l = landing(id)
            XCTAssertEqual(CardPasteboard.drag(into: l, card: shot), CardPasteboard.drag(for: .chat, card: shot), id)
            XCTAssertEqual(DragFollowUp.plan(delivered: l.cls, card: shot, enabled: true, accessibility: true, secureInput: false, kind: l.kind),
                           .pasteNote(note), id)
            XCTAssertTrue(FollowUpFocus.needsText(bundleID: id), id)
            let k = l.kind ?? .web
            // Accessibility can't say (no tree for its web content), or the focus is a dialog's button / the window
            XCTAssertEqual(FollowUpFocus.decide(F(kind: k, needsText: true)), .skip("not_text"), id)
            XCTAssertEqual(FollowUpFocus.decide(F(kind: k, editable: false, needsText: true)), .skip("not_text"), id)
            // its message box (or a text field the drop opened, over the drop point): the paste
            XCTAssertEqual(FollowUpFocus.decide(F(kind: k, sameWindow: true, editable: true, selection: 0, needsText: true)), .paste(caret: []), id)
            XCTAssertEqual(FollowUpFocus.decide(F(kind: k, editable: true, needsText: true)), .paste(caret: [.end]), id)
            // not pasted → the safety net: the note on the clipboard, "picture · note copied, ⌘V to paste"
            let o = DragReceipt.outcome(delivered: l.cls, notePasted: false, noteFile: false)
            XCTAssertEqual(o, .pictureOnly)
            XCTAssertTrue(DragReceipt.copiesNote(o))
            XCTAssertEqual(DragReceipt.toastKey(o, hasNote: true, noteCopied: true), "capture.taken_out_picture_note")
        }
        let drop = CGPoint(x: 700, y: 640)
        let covers = FollowUpFocus.sameWindow(identical: false, focusedFrame: CGRect(x: 400, y: 200, width: 800, height: 700), drop: drop)
        XCTAssertEqual(covers, true)
        XCTAssertEqual(FollowUpFocus.decide(F(kind: .web, sameWindow: covers, editable: true, selection: 0, needsText: true)), .paste(caret: []))
    }

    /// Every other web app is as it was: the paste when Accessibility can't say (Claude, ChatGPT in Chrome… worked).
    func testOtherWebAppsKeepTheirFollowUp() {
        typealias F = FollowUpFocus.Facts
        for id in otherWeb {
            XCTAssertFalse(FollowUpFocus.needsText(bundleID: id), id)
            XCTAssertEqual(FollowUpFocus.decide(F(kind: DropTargets.composer(bundleID: id, appURL: nil),
                                                  needsText: FollowUpFocus.needsText(bundleID: id))), .paste(caret: [.end]), id)
        }
        XCTAssertFalse(FollowUpFocus.needsText(bundleID: wechat))
        XCTAssertFalse(FollowUpFocus.needsText(bundleID: nil))
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

    func voicePlan(_ id: String, accepted: Bool, canPaste: Bool = true, withheld: Bool? = nil) -> VoiceCardDrop.Plan {
        let l = landing(id, voice: true, canPaste: canPaste)
        return VoiceCardDrop.plan(cls: l.cls, kind: l.kind, accepted: accepted, words: voice.note, enabled: true,
                                  accessibility: canPaste, secureInput: false, swallows: VoiceCardDrop.swallowsTextDrop(bundleID: id),
                                  wordsWithheld: withheld ?? l.wordsWithheld)
    }

    /// Feishu: no words on the drag where Blurt can paste them — it can't take a text drop and lose it — and Blurt
    /// pastes them into its composer, whatever Feishu answered.
    func testFeishuGetsAVoiceCardsWordsPasted() {
        for id in feishu {
            let l = landing(id, voice: true)
            XCTAssertTrue(l.wordsWithheld, id)
            XCTAssertEqual(CardPasteboard.drag(into: l, card: voice), [CardPasteboard.Item(tag: true)], "only the capture's tag")
            for accepted in [true, false] {
                XCTAssertEqual(voicePlan(id, accepted: accepted), .paste("纯文字的录音"), "\(id) accepted=\(accepted)")
            }
            // the drop beat the rewrite (the words were still on the drag) and Feishu said yes: pasted all the same
            XCTAssertEqual(voicePlan(id, accepted: true, withheld: false), .paste("纯文字的录音"), id)
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
            XCTAssertEqual(voicePlan("com.electron.lark", accepted: accepted, canPaste: false), .copy("纯文字的录音"))
        }
    }

    /// WeChat: its own text drop (it works there) — the words stay on the drag, and a drop it took is left alone.
    func testWeChatKeepsItsOwnTextDrop() {
        let l = landing(wechat, voice: true)
        XCTAssertFalse(l.wordsWithheld)
        XCTAssertEqual(CardPasteboard.drag(into: l, card: voice), [CardPasteboard.Item(text: "纯文字的录音", tag: true)])
        XCTAssertEqual(voicePlan(wechat, accepted: true), .none("app_took_it"))
        XCTAssertEqual(voicePlan(wechat, accepted: false), .paste("纯文字的录音"))
    }

    /// Chrome, Claude, Safari, Slack, Notion: as before v0.9 — the words on the drag, a drop the app took is its own
    /// (no paste on top, nothing on the clipboard, with or without Accessibility), a refused one gets the paste.
    func testOtherWebAppsKeepTheirOwnTextDrop() {
        for id in otherWeb {
            for canPaste in [true, false] {
                let l = landing(id, voice: true, canPaste: canPaste)
                XCTAssertFalse(l.wordsWithheld, id)
                XCTAssertEqual(CardPasteboard.drag(into: l, card: voice), [CardPasteboard.Item(text: "纯文字的录音", tag: true)], id)
                XCTAssertEqual(voicePlan(id, accepted: true, canPaste: canPaste), .none("app_took_it"), "\(id) ax=\(canPaste)")
            }
            XCTAssertEqual(voicePlan(id, accepted: false), .paste("纯文字的录音"), id)
            XCTAssertEqual(voicePlan(id, accepted: false, canPaste: false), .copy("纯文字的录音"), id)
        }
    }

    /// Only the voice card's own drag changes: a shot card over Feishu still carries its picture.
    func testWithholdingIsForVoiceCardsOnly() {
        XCTAssertFalse(landing("com.electron.lark", voice: false).wordsWithheld)
        XCTAssertEqual(CardPasteboard.drag(into: DragLanding(cls: .chat, kind: .web, wordsWithheld: true), card: shot),
                       CardPasteboard.drag(for: .chat, card: shot))
        XCTAssertEqual(CardPasteboard.drag(into: DragLanding(cls: .chat, kind: .web, wordsWithheld: true),
                                           card: CardPasteboard.Card(image: nil, note: " ")), [], "no words: nothing to drag")
    }

    // MARK: the log

    /// The drag's events go to card-drag.log — never the words.
    func testTheDragLogKeepsWhatHappenedNotTheWords() throws {
        XCTAssertNil(DragLog.line(["event": "cards_frame", "vis": 1], at: 0), "not a drag event")
        let plan = try XCTUnwrap(DragLog.line(["event": "voice_drop_plan", "bundle": "com.electron.lark", "accepted": true,
                                               "plan": "\(VoiceCardDrop.Plan.paste("纯文字的录音"))"], at: 1_792_980_884.1666))
        XCTAssertFalse(plan.contains("纯文字"), plan)
        XCTAssertTrue(plan.contains("\"plan\":\"paste\"") && plan.contains("com.electron.lark") && plan.contains("\"at\":\"\(DragLog.stamp(1_792_980_884.1666))\"") && DragLog.stamp(1_792_980_884.1666).hasPrefix("2026-10-2"), plan)
        let note = try XCTUnwrap(DragLog.line(["event": "drag_note_plan", "plan": "\(DragFollowUp.Plan.pasteNote("图片加文字"))"], at: 0))
        XCTAssertFalse(note.contains("图片加文字"), note)
        XCTAssertTrue(note.contains("\"plan\":\"pasteNote\""), note)
        let none = try XCTUnwrap(DragLog.line(["event": "voice_drop_plan", "plan": "\(VoiceCardDrop.Plan.none("app_took_it"))"], at: 0))
        XCTAssertTrue(none.contains("app_took_it"), "a reason stays")
        let focus = try XCTUnwrap(DragLog.line(["event": "drag_note_focus", "decision": "\(FollowUpFocus.Decision.skip("not_text"))",
                                                "role": "AXWindow", "text": "秘密"], at: 0))
        XCTAssertTrue(focus.contains("not_text") && focus.contains("AXWindow") && !focus.contains("秘密"), focus)
        XCTAssertNotNil(DragLog.line(["event": "card_drag_end", "bundle": NSNull(), "delivered": NSNull()], at: 0))
    }
}
