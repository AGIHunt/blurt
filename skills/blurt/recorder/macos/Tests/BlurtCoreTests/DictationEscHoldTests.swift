// Esc while a take listens never reaches the app in front (BlurtCore/DictationEscHold.swift, docs/design/dictation.md
// §Trigger): the filter keeps a whole press, and the hotkeys stay until the press is over.
import XCTest
@testable import BlurtCore

final class DictationEscHoldTests: XCTestCase {
    private let fn: UInt64 = 0x80_0000

    // MARK: the filter

    func testAnEscWithNothingHeldIsKeptWhileATakeListens() {
        var f = DictationEscFilter()
        XCTAssertFalse(f.drop(keyDown: true, flags: 0), "no take: the app's")
        XCTAssertFalse(f.drop(keyDown: false, flags: 0))
        f.armed = true
        XCTAssertTrue(f.drop(keyDown: true, flags: 0))
        XCTAssertTrue(f.drop(keyDown: true, flags: 0), "a repeat of it")
        XCTAssertTrue(f.drop(keyDown: false, flags: 0))
        XCTAssertFalse(f.kept)
    }

    /// Fn is the dictation key, held in push-to-talk: a hotkey can't match that, the filter can. Caps lock is no key here.
    func testFnHeldWithItChangesNothing() {
        for flags: UInt64 in [fn, fn | 0x1_0000, 0x1_0000] {
            var f = DictationEscFilter()
            f.armed = true
            XCTAssertTrue(f.drop(keyDown: true, flags: flags), "flags \(flags)")
            XCTAssertTrue(f.drop(keyDown: false, flags: flags), "flags \(flags)")
        }
    }

    /// ⌘ ⇧ ⌃ ⌥ with Esc is a shortcut of the app's own: where no filter runs it goes there, so it does here too.
    func testAnotherKeysModifierLeavesItToTheApp() {
        for m: UInt64 in [0x10_0000, 0x4_0000, 0x2_0000, 0x8_0000] {
            var f = DictationEscFilter()
            f.armed = true
            XCTAssertFalse(f.drop(keyDown: true, flags: m), "flags \(m)")
            XCTAssertFalse(f.drop(keyDown: true, flags: m | fn), "flags \(m)")
            XCTAssertFalse(f.kept, "flags \(m)")
        }
    }

    /// ⌃Esc is the cancel key: plain Esc is the app's, as Settings says.
    func testTheCancelKeysOwnModifierDecides() {
        var f = DictationEscFilter()
        f.armed = true
        f.needs = 0x4_0000
        XCTAssertFalse(f.drop(keyDown: true, flags: 0))
        XCTAssertFalse(f.drop(keyDown: true, flags: 0x4_0000 | 0x2_0000), "⌃⇧Esc isn't the cancel key either")
        XCTAssertTrue(f.drop(keyDown: true, flags: 0x4_0000))
        XCTAssertTrue(f.drop(keyDown: false, flags: 0x4_0000))
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
        XCTAssertTrue(f.drop(keyDown: true, flags: 0))
    }

    /// The tap went away between the press and its release.
    func testForgettingAPressFreesTheNextOne() {
        var f = DictationEscFilter()
        f.armed = true
        XCTAssertTrue(f.drop(keyDown: true, flags: 0))
        f.armed = false
        f.forgetPress()
        XCTAssertFalse(f.drop(keyDown: true, flags: 0))
    }

    // MARK: the hotkeys

    func testNoPressGoesOnceSettled() {
        var h = DictationEscHold(since: 10)
        XCTAssertFalse(h.canRelease(now: 10, keyDown: false))
        XCTAssertFalse(h.canRelease(now: 10 + DictationEscHold.settle / 2, keyDown: false))
        XCTAssertTrue(h.canRelease(now: 10 + DictationEscHold.settle, keyDown: false))
    }

    /// Held for a second: the hotkeys stay, and go only after the key has been up for `settle`.
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
