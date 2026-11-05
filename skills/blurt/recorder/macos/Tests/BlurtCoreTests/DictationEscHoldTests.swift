// Esc while a take is under way never reaches the app in front (BlurtCore/DictationEscHold.swift, docs/design/
// dictation.md §Trigger): the filter keeps a whole press, and the hotkey stays until the press is over.
import XCTest
@testable import BlurtCore

final class DictationEscHoldTests: XCTestCase {
    // MARK: when

    func testEscIsBlurtsOnlyWhileATakeIsUnderWay() {
        XCTAssertFalse(DictationEscHold.isBlurts(listening: false, onItsWay: false, otherHolder: false), "idle: the app's")
        XCTAssertTrue(DictationEscHold.isBlurts(listening: true, onItsWay: false, otherHolder: false))
        XCTAssertTrue(DictationEscHold.isBlurts(listening: false, onItsWay: true, otherHolder: false))
    }

    /// The picker or a card opened after the take stopped: Esc is meant for it, and it would be refused otherwise.
    func testATakeOnItsWayGivesEscUpToAnotherHolder() {
        XCTAssertFalse(DictationEscHold.isBlurts(listening: false, onItsWay: true, otherHolder: true))
        XCTAssertFalse(DictationEscHold.isBlurts(listening: false, onItsWay: false, otherHolder: true))
    }

    /// While it listens the take keeps it, as it always has.
    func testATakeThatListensKeepsEsc() {
        XCTAssertTrue(DictationEscHold.isBlurts(listening: true, onItsWay: true, otherHolder: true))
    }

    // MARK: the filter

    func testIdleEscGoesToTheApp() {
        var f = DictationEscFilter()
        XCTAssertFalse(f.drop(keyDown: true, flags: 0))
        XCTAssertFalse(f.drop(keyDown: false, flags: 0))
    }

    func testAWholePressIsKept() {
        var f = DictationEscFilter()
        f.armed = true
        XCTAssertTrue(f.drop(keyDown: true, flags: 0))
        XCTAssertTrue(f.drop(keyDown: true, flags: 0), "a repeat of it")
        XCTAssertTrue(f.drop(keyDown: false, flags: 0))
        XCTAssertFalse(f.kept)
    }

    /// The take ends on the press: its repeats and release still go with it, the app never sees half of an Esc.
    func testTheTakeEndingMidPressKeepsTheRest() {
        var f = DictationEscFilter()
        f.armed = true
        XCTAssertTrue(f.drop(keyDown: true, flags: 0))
        f.armed = false
        XCTAssertTrue(f.drop(keyDown: true, flags: 0))
        XCTAssertTrue(f.drop(keyDown: false, flags: 0))
        XCTAssertFalse(f.drop(keyDown: true, flags: 0), "the next press is the app's again")
        XCTAssertFalse(f.drop(keyDown: false, flags: 0))
    }

    /// A press from before the take started is the app's: so is its release.
    func testAPressFromBeforeTheTakeStaysTheApps() {
        var f = DictationEscFilter()
        XCTAssertFalse(f.drop(keyDown: true, flags: 0))
        f.armed = true
        XCTAssertFalse(f.drop(keyDown: false, flags: 0))
    }

    /// Whatever is held with it: Fn and ⌥ are the dictation key in push-to-talk, and a hotkey can't match those.
    func testHeldModifiersDontLetItThrough() {
        for held: UInt64 in [0x80_0000, 0x8_0040, 0x2_0002, 0x10_0008] {
            var f = DictationEscFilter()
            f.armed = true
            XCTAssertTrue(f.drop(keyDown: true, flags: held), "flags \(held)")
        }
    }

    /// ⌃Esc is the cancel key: plain Esc is the app's, as Settings says.
    func testACancelKeyWithAModifierLeavesPlainEscToTheApp() {
        var f = DictationEscFilter()
        f.armed = true
        f.needs = 0x4_0000
        XCTAssertFalse(f.drop(keyDown: true, flags: 0))
        XCTAssertFalse(f.drop(keyDown: false, flags: 0))
        XCTAssertTrue(f.drop(keyDown: true, flags: 0x4_0000))
        XCTAssertTrue(f.drop(keyDown: false, flags: 0x4_0000))
    }

    func testForgettingAPressFreesTheNextOne() {
        var f = DictationEscFilter()
        f.armed = true
        XCTAssertTrue(f.drop(keyDown: true, flags: 0))
        f.armed = false
        f.forgetPress()
        XCTAssertFalse(f.drop(keyDown: true, flags: 0))
    }

    // MARK: the hotkey

    func testNoPressGoesOnceSettled() {
        var h = DictationEscHold(since: 10)
        XCTAssertFalse(h.canRelease(now: 10, keyDown: false))
        XCTAssertFalse(h.canRelease(now: 10 + DictationEscHold.settle / 2, keyDown: false))
        XCTAssertTrue(h.canRelease(now: 10 + DictationEscHold.settle, keyDown: false))
    }

    /// Held for a second: the hotkey stays, and goes only after the key has been up for `settle`.
    func testStaysWhileTheKeyIsDownThenSettles() {
        var h = DictationEscHold(since: 10)
        XCTAssertFalse(h.canRelease(now: 10.2, keyDown: true))
        XCTAssertFalse(h.canRelease(now: 11, keyDown: true))
        XCTAssertFalse(h.canRelease(now: 11.01, keyDown: false))
        XCTAssertFalse(h.canRelease(now: 11.05, keyDown: false))
        XCTAssertTrue(h.canRelease(now: 11.01 + DictationEscHold.settle, keyDown: false))
    }

    /// Pressed again before it settled: the wait starts over.
    func testPressedAgainStartsTheWaitOver() {
        var h = DictationEscHold(since: 10)
        XCTAssertFalse(h.canRelease(now: 10, keyDown: false))
        XCTAssertFalse(h.canRelease(now: 10.05, keyDown: true))
        XCTAssertFalse(h.canRelease(now: 10.1, keyDown: false))
        XCTAssertFalse(h.canRelease(now: 10.1 + DictationEscHold.settle / 2, keyDown: false))
        XCTAssertTrue(h.canRelease(now: 10.1 + DictationEscHold.settle, keyDown: false))
    }

    /// A key that reads as down for good never keeps Esc from every app.
    func testNeverLongerThanTheLimit() {
        var h = DictationEscHold(since: 10)
        XCTAssertFalse(h.canRelease(now: 10 + DictationEscHold.limit - 0.01, keyDown: true))
        XCTAssertTrue(h.canRelease(now: 10 + DictationEscHold.limit, keyDown: true))
    }
}
