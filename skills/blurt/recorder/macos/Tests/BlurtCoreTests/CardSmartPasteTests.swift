// BlurtCore/CardSmartPaste.swift: picture, then note, into every chat app — they take one thing per paste or drop.
// The reports: a card dragged into WeChat, or copied and pasted there, arrived as the picture alone (v0.8.4); one
// dragged into DeepSeek in a browser as the picture and a .md file (v0.8.5).
import XCTest
@testable import BlurtCore

final class CardSmartPasteTests: XCTestCase {
    let a = URL(fileURLWithPath: "/s/out/001/截图-101010.png")
    let b = URL(fileURLWithPath: "/s/out/002/截图-101020.png")

    // MARK: the table

    func testTheSingleFlavourTable() {
        XCTAssertTrue(SingleFlavourApps.contains("com.tencent.xinWeChat"))
        XCTAssertTrue(SingleFlavourApps.contains("com.tencent.qq"))
        for id in ["com.apple.Notes", "com.electron.lark", "com.anthropic.claudefordesktop", "com.apple.TextEdit", "com.apple.Terminal"] {
            XCTAssertFalse(SingleFlavourApps.contains(id), id)
        }
        XCTAssertFalse(SingleFlavourApps.contains(nil))
        // chat apps like any other: the picture lands, the note comes in a second step (after ⌘↓)
        for id in SingleFlavourApps.bundles {
            XCTAssertEqual(DropTargets.classify(bundleID: id), .chat, id)
            XCTAssertEqual(DropTargets.composer(bundleID: id, appURL: nil), .qt, id)
        }
    }

    // MARK: the sequence

    func testOneCardIsItsPictureThenItsNote() {
        let steps = CardPasteSequence.steps([CardPasteboard.Card(image: a, note: "  the logo\noverlaps  ")])
        XCTAssertEqual(steps, [.image(a), .text("the logo\noverlaps")], "line breaks kept, ends trimmed")
        XCTAssertTrue(CardPasteSequence.needsSequence(steps))
    }

    func testSeveralCardsAlternateInTheOrderTheyHang() {
        let steps = CardPasteSequence.steps([
            CardPasteboard.Card(image: a, note: "first"),
            CardPasteboard.Card(image: b, note: "second"),
        ])
        XCTAssertEqual(steps, [.image(a), .text("first\n"), .image(b), .text("second")],
                       "a note with more after it ends its line (attachments in a web composer; a new line in WeChat)")
    }

    func testTextNextToTextIsOnePasteAndAPictureWithoutANoteStandsAlone() {
        let steps = CardPasteSequence.steps([
            CardPasteboard.Card(image: a, note: "first"),
            CardPasteboard.Card(image: nil, note: "a voice card's words"),
            CardPasteboard.Card(image: b, note: nil),
            CardPasteboard.Card(image: nil, note: "   "),
        ])
        XCTAssertEqual(steps, [.image(a), .text("first\n\na voice card's words\n"), .image(b)])
    }

    func testOneThingNeedsNoSequence() {
        XCTAssertFalse(CardPasteSequence.needsSequence(CardPasteSequence.steps([CardPasteboard.Card(image: a, note: nil)])))
        XCTAssertFalse(CardPasteSequence.needsSequence(CardPasteSequence.steps([CardPasteboard.Card(image: nil, note: "words")])))
        XCTAssertFalse(CardPasteSequence.needsSequence([]))
    }

    // MARK: arming and expiry

    func testArmedForTwoMinutesWhileTheCopyIsOnTheClipboard() {
        let arm = SmartPasteArm(changeCount: 41, steps: [.image(a), .text("n")], now: 1000)
        XCTAssertEqual(SmartPasteArm.window, 120)
        XCTAssertTrue(arm.isLive(now: 1000, changeCount: 41))
        XCTAssertTrue(arm.isLive(now: 1119.9, changeCount: 41))
        XCTAssertFalse(arm.isLive(now: 1120, changeCount: 41), "two minutes passed")
        XCTAssertFalse(arm.isLive(now: 1001, changeCount: 42), "something else was copied")
        // a sequence wrote the copy back: the new count, and the window starts again
        let again = arm.rearmed(changeCount: 47, now: 1100)
        XCTAssertEqual(again.steps, arm.steps)
        XCTAssertTrue(again.isLive(now: 1210, changeCount: 47))
        XCTAssertFalse(again.isLive(now: 1210, changeCount: 41))
    }

    // MARK: which key press

    func testOnlyAPlainCommandVCounts() {
        let cmd = PasteChord.command
        XCTAssertTrue(PasteChord.isPaste(keyCode: 9, characters: "v", flags: cmd, autorepeat: false))
        XCTAssertTrue(PasteChord.isPaste(keyCode: 9, characters: nil, flags: cmd | 0x100, autorepeat: false), "device bits are fine")
        XCTAssertTrue(PasteChord.isPaste(keyCode: 47, characters: "v", flags: cmd, autorepeat: false), "another layout's V key")
        XCTAssertFalse(PasteChord.isPaste(keyCode: 9, characters: ".", flags: cmd, autorepeat: false), "that key types something else here")
        XCTAssertFalse(PasteChord.isPaste(keyCode: 9, characters: "v", flags: 0, autorepeat: false), "no ⌘: typing a v")
        XCTAssertFalse(PasteChord.isPaste(keyCode: 9, characters: "v", flags: cmd | PasteChord.shift, autorepeat: false), "⇧⌘V")
        XCTAssertFalse(PasteChord.isPaste(keyCode: 9, characters: "v", flags: cmd | PasteChord.option, autorepeat: false), "⌥⌘V")
        XCTAssertFalse(PasteChord.isPaste(keyCode: 9, characters: "v", flags: cmd | PasteChord.control, autorepeat: false), "⌃⌘V")
        XCTAssertFalse(PasteChord.isPaste(keyCode: 9, characters: "v", flags: cmd, autorepeat: true), "a held key repeating")
    }

    // MARK: what a ⌘V does while armed

    func input(_ change: (inout SmartPastePolicy.Input) -> Void = { _ in }) -> SmartPastePolicy.Input {
        var i = SmartPastePolicy.Input(enabled: true, arm: SmartPasteArm(changeCount: 5, steps: [.image(a), .text("n")], now: 0),
                                       now: 10, changeCount: 5, frontBundle: "com.tencent.xinWeChat", accessibility: true,
                                       secureInput: false, running: false)
        change(&i)
        return i
    }

    /// Every chat app: browsers (DeepSeek, ChatGPT, Claude on the web), Electron apps, WeChat, QQ, apps we don't know.
    func testCommandVInAChatAppRunsTheSequence() {
        for id in ["com.tencent.xinWeChat", "com.tencent.qq", "com.google.Chrome", "com.apple.Safari", "com.anthropic.claudefordesktop",
                   "com.electron.lark", "com.tinyspeck.slackmacgap", "com.example.SomethingElse"] {
            XCTAssertEqual(SmartPastePolicy.decide(input { $0.frontBundle = id }), .sequence, id)
            XCTAssertTrue(SmartPastePolicy.sequences(frontBundle: id), id)
        }
    }

    func testEverythingElsePassesUntouched() {
        XCTAssertEqual(SmartPastePolicy.decide(input { $0.enabled = false }), .pass("off"))
        XCTAssertEqual(SmartPastePolicy.decide(input { $0.arm = nil }), .pass("not_armed"))
        XCTAssertEqual(SmartPastePolicy.decide(input { $0.now = 121 }), .pass("expired"))
        XCTAssertEqual(SmartPastePolicy.decide(input { $0.changeCount = 6 }), .pass("clipboard_changed"), "something else copied since")
        // one rich paste brings both there; a terminal and the Finder keep their own paste
        for id in ["com.apple.Notes", "com.apple.TextEdit", "com.apple.mail", "com.apple.iWork.Pages"] {
            XCTAssertEqual(SmartPastePolicy.decide(input { $0.frontBundle = id }), .pass("rich_app"), id)
        }
        XCTAssertEqual(SmartPastePolicy.decide(input { $0.frontBundle = "com.apple.Terminal" }), .pass("terminal"))
        XCTAssertEqual(SmartPastePolicy.decide(input { $0.frontBundle = "com.apple.finder" }), .pass("finder"))
        XCTAssertEqual(SmartPastePolicy.decide(input { $0.frontBundle = nil }), .pass("no_app"))
        XCTAssertEqual(SmartPastePolicy.decide(input { $0.frontIsBlurt = true }), .pass("blurt"))
        for id in ["com.apple.Notes", "com.apple.Terminal", "com.apple.finder"] { XCTAssertFalse(SmartPastePolicy.sequences(frontBundle: id), id) }
        XCTAssertFalse(SmartPastePolicy.sequences(frontBundle: nil))
        XCTAssertEqual(SmartPastePolicy.decide(input { $0.arm?.steps = [.image(self.a)] }), .pass("one_thing"))
        XCTAssertEqual(SmartPastePolicy.decide(input { $0.accessibility = false }), .pass("no_accessibility"))
        XCTAssertEqual(SmartPastePolicy.decide(input { $0.secureInput = true }), .pass("secure_input"))
        XCTAssertEqual(SmartPastePolicy.decide(input { $0.running = true }), .pass("running"))
    }

    // MARK: the sequence, step by step

    func testRunsEachStepThenGivesTheClipboardBack() {
        var run = PasteRun(steps: [.image(a), .text("first"), .image(b), .text("second")])
        XCTAssertEqual(run.start(), [.put(.image(a)), .paste])
        XCTAssertEqual(run.state, .pasting(0))
        XCTAssertEqual(run.handle(.restoreDue), [], "nothing to restore while pasting")
        XCTAssertEqual(run.handle(.read), [.put(.text("first")), .paste])
        XCTAssertEqual(run.handle(.timeout), [.put(.image(b)), .paste], "a slow app: the next step after the timeout")
        XCTAssertEqual(run.handle(.read), [.put(.text("second")), .paste])
        XCTAssertEqual(run.handle(.read), [], "the last step read: wait before giving the clipboard back")
        XCTAssertEqual(run.state, .restoring)
        XCTAssertFalse(run.finished)
        XCTAssertEqual(run.handle(.restoreDue), [.restore])
        XCTAssertEqual(run.state, .done)
        XCTAssertTrue(run.finished)
        XCTAssertEqual(run.read, 3)
        XCTAssertEqual(run.unconfirmed, 1)
        XCTAssertEqual(run.handle(.read), [], "finished: later events change nothing")
    }

    func testSomethingCopiedMeanwhileStopsItAndNothingIsPutBackOverIt() {
        var run = PasteRun(steps: [.image(a), .text("n")])
        _ = run.start()
        XCTAssertEqual(run.handle(.clobbered), [])
        XCTAssertEqual(run.state, .aborted)
        XCTAssertTrue(run.finished)
        XCTAssertEqual(run.handle(.restoreDue), [])

        var late = PasteRun(steps: [.image(a), .text("n")])
        _ = late.start(); _ = late.handle(.read); _ = late.handle(.read)
        XCTAssertEqual(late.state, .restoring)
        XCTAssertEqual(late.handle(.clobbered), [], "copied while waiting to restore: the user's copy stays")
        XCTAssertEqual(late.state, .aborted)
    }

    func testAnEmptyRunIsDoneAtOnce() {
        var run = PasteRun(steps: [])
        XCTAssertEqual(run.start(), [])
        XCTAssertTrue(run.finished)
    }

    // MARK: after a drop

    func testADropIntoAChatAppGetsItsNotePastedAfterThePicture() {
        let card = CardPasteboard.Card(image: a, note: "the logo\noverlaps")
        func plan(_ d: DropClass?, enabled: Bool = true, ax: Bool = true, secure: Bool = false, card c: CardPasteboard.Card? = nil) -> DragFollowUp.Plan {
            DragFollowUp.plan(delivered: d, card: c ?? card, enabled: enabled, accessibility: ax, secureInput: secure)
        }
        XCTAssertEqual(plan(.chat), .pasteNote("the logo\noverlaps"), "line breaks kept: it is one paste")
        XCTAssertEqual(plan(.rich), .none("rich_app"), "Notes took both from the RTFD")
        XCTAssertEqual(plan(.terminal), .none("other_app"), "never text at a prompt")
        XCTAssertEqual(plan(.finder), .none("other_app"))
        XCTAssertEqual(plan(nil), .none("not_sure"), "it may have read the rich layout: no second note")
        XCTAssertEqual(plan(.chat, card: CardPasteboard.Card(image: a, note: nil)), .none("nothing_more"))
        XCTAssertEqual(plan(.chat, card: CardPasteboard.Card(image: nil, note: "words")), .none("nothing_more"),
                       "a voice card dropped its words already")
        XCTAssertEqual(plan(.chat, enabled: false), .none("off"))
        XCTAssertEqual(plan(.chat, ax: false), .none("no_accessibility"))
        XCTAssertEqual(plan(.chat, secure: true), .none("secure_input"))
    }

    /// Where the note's paste goes, and how the caret gets after the picture.
    func testThePasteGoesIntoTheComposerThatReceivedTheDrop() {
        typealias F = FollowUpFocus.Facts
        // WeChat / QQ: ⌘↓ first (the dropped picture is selected; Qt's Accessibility can't say)
        XCTAssertEqual(FollowUpFocus.decide(F(kind: .qt)), .paste(caret: [.end]))
        XCTAssertEqual(FollowUpFocus.decide(F(kind: .qt, editable: false, selection: 0)), .paste(caret: [.end]))
        // a web composer: the picture became an upload, the caret is where it was — nothing to press
        XCTAssertEqual(FollowUpFocus.decide(F(kind: .web, sameWindow: true, editable: true, selection: 0)), .paste(caret: []))
        // an editor that put the picture inline and selected it: → collapses the selection after it
        XCTAssertEqual(FollowUpFocus.decide(F(kind: .web, sameWindow: true, editable: true, selection: 1)), .paste(caret: [.right]))
        // can't tell (no Accessibility tree yet, or a composer we just focused): still paste, like dictation, at the end
        XCTAssertEqual(FollowUpFocus.decide(F(kind: .web)), .paste(caret: [.end]))
        XCTAssertEqual(FollowUpFocus.decide(F(kind: .web, editable: false)), .paste(caret: [.end]),
                       "a page often routes a paste to its composer; it counts only if the app reads it")
        // a native app we don't know: only into editable text (an image editor would make it a text layer)
        XCTAssertEqual(FollowUpFocus.decide(F(kind: .native, editable: true, selection: 1)), .paste(caret: [.right]))
        XCTAssertEqual(FollowUpFocus.decide(F(kind: .native, editable: false)), .skip("not_text"))
        XCTAssertEqual(FollowUpFocus.decide(F(kind: .native)), .skip("not_text"))
        // never elsewhere
        for k in ComposerKind.allCases {
            XCTAssertEqual(FollowUpFocus.decide(F(kind: k, frontIsTarget: false)), .skip("not_front"), "\(k)")
            XCTAssertEqual(FollowUpFocus.decide(F(kind: k, frontIsBlurt: true)), .skip("blurt_in_front"), "\(k)")
            XCTAssertEqual(FollowUpFocus.decide(F(kind: k, secureInput: true)), .skip("secure_input"), "\(k)")
            XCTAssertEqual(FollowUpFocus.decide(F(kind: k, focusSecure: true, editable: true)), .skip("secure_input"), "\(k)")
            XCTAssertEqual(FollowUpFocus.decide(F(kind: k, sameWindow: false, editable: true, selection: 0)), .skip("other_window"), "\(k)")
        }
    }
}
