// BlurtCore/CardSmartPaste.swift: picture and note into WeChat / QQ, which take one thing per paste or drop. The
// report: a card dragged into WeChat, or copied and pasted there, arrived as the picture alone.
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
        // still text-class for a drag: the rich item (the picture lands); the note comes in a second step
        for id in SingleFlavourApps.bundles { XCTAssertEqual(DropTargets.classify(bundleID: id, appURL: nil), .text, id) }
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
        XCTAssertEqual(steps, [.image(a), .text("first"), .image(b), .text("second")])
    }

    func testTextNextToTextIsOnePasteAndAPictureWithoutANoteStandsAlone() {
        let steps = CardPasteSequence.steps([
            CardPasteboard.Card(image: a, note: "first"),
            CardPasteboard.Card(image: nil, note: "a voice card's words"),
            CardPasteboard.Card(image: b, note: nil),
            CardPasteboard.Card(image: nil, note: "   "),
        ])
        XCTAssertEqual(steps, [.image(a), .text("first\n\na voice card's words"), .image(b)])
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

    func testCommandVInWeChatRunsTheSequence() {
        XCTAssertEqual(SmartPastePolicy.decide(input()), .sequence)
        XCTAssertEqual(SmartPastePolicy.decide(input { $0.frontBundle = "com.tencent.qq" }), .sequence)
    }

    func testEverythingElsePassesUntouched() {
        XCTAssertEqual(SmartPastePolicy.decide(input { $0.enabled = false }), .pass("off"))
        XCTAssertEqual(SmartPastePolicy.decide(input { $0.arm = nil }), .pass("not_armed"))
        XCTAssertEqual(SmartPastePolicy.decide(input { $0.now = 121 }), .pass("expired"))
        XCTAssertEqual(SmartPastePolicy.decide(input { $0.changeCount = 6 }), .pass("clipboard_changed"))
        for id in ["com.electron.lark", "com.apple.Notes", "com.anthropic.claudefordesktop", "com.apple.Terminal"] {
            XCTAssertEqual(SmartPastePolicy.decide(input { $0.frontBundle = id }), .pass("other_app"), id)
        }
        XCTAssertEqual(SmartPastePolicy.decide(input { $0.frontBundle = nil }), .pass("other_app"))
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

    func testADropIntoWeChatGetsItsNoteTypedInAfterThePicture() {
        let card = CardPasteboard.Card(image: a, note: "the logo\noverlaps")
        func plan(_ id: String?, enabled: Bool = true, ax: Bool = true, secure: Bool = false, card c: CardPasteboard.Card? = nil) -> DragFollowUp.Plan {
            DragFollowUp.plan(bundleID: id, card: c ?? card, enabled: enabled, accessibility: ax, secureInput: secure)
        }
        XCTAssertEqual(plan("com.tencent.xinWeChat"), .typeNote("the logo\noverlaps"))
        XCTAssertEqual(plan("com.tencent.qq"), .typeNote("the logo\noverlaps"))
        XCTAssertEqual(plan("com.apple.Notes"), .none("other_app"), "Notes took both from the RTFD")
        XCTAssertEqual(plan("com.electron.lark"), .none("other_app"))
        XCTAssertEqual(plan(nil), .none("other_app"))
        XCTAssertEqual(plan("com.tencent.xinWeChat", card: CardPasteboard.Card(image: a, note: nil)), .none("nothing_more"))
        XCTAssertEqual(plan("com.tencent.xinWeChat", card: CardPasteboard.Card(image: nil, note: "words")), .none("nothing_more"),
                       "a voice card dropped its words already")
        XCTAssertEqual(plan("com.tencent.xinWeChat", enabled: false), .none("off"))
        XCTAssertEqual(plan("com.tencent.xinWeChat", ax: false), .none("no_accessibility"))
        XCTAssertEqual(plan("com.tencent.xinWeChat", secure: true), .none("secure_input"))
    }

    /// Picture only (the note couldn't be typed in): the safety net copies the note and the toast says so.
    func testAPictureOnlyDropCopiesTheNote() {
        XCTAssertTrue(DragReceipt.copiesNote(delivered: .text, pictureOnly: true))
        XCTAssertFalse(DragReceipt.copiesNote(delivered: .text, pictureOnly: false), "Notes & co. took both")
        XCTAssertEqual(DragReceipt.toastKey(delivered: .text, hasNote: true, noteCopied: true, pictureOnly: true), "capture.taken_out_picture_note")
        XCTAssertEqual(DragReceipt.toastKey(delivered: .text, hasNote: true, noteCopied: false, pictureOnly: true), "capture.taken_out_picture")
        XCTAssertEqual(DragReceipt.toastKey(delivered: .text, hasNote: false, noteCopied: false, pictureOnly: true), "capture.taken_out")
    }
}
