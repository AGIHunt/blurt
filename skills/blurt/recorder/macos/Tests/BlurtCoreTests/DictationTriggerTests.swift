// BlurtCore/DictationTrigger.swift: the dictation key's tap / hold logic, event script in, start / stop / cancel out.
import XCTest
@testable import BlurtCore

final class DictationTriggerTests: XCTestCase {
    private func run(_ script: String, key: DictationTrigger.Key = .rightOption, mode: DictationTrigger.Mode = .tap)
        -> [DictationTrigger.Output] {
        var t = DictationTrigger(key: key, mode: mode)
        return t.run(script)
    }

    // MARK: tap mode

    func testTapStartsAndTapStops() {
        XCTAssertEqual(run("ropt-down@0 ropt-up@120"), [.arm, .start])
        XCTAssertEqual(run("ropt-down@0 ropt-up@120 ropt-down@3000 ropt-up@3100"), [.arm, .start, .stop])
    }

    func testSlowPressIsNotATap() {
        XCTAssertEqual(run("ropt-down@0 ropt-up@450"), [.arm])
        XCTAssertEqual(run("ropt-down@0 ropt-up@400"), [.arm, .start])
    }

    func testOptionAsAModifierNeverTriggers() {
        XCTAssertEqual(run("ropt-down@0 key:0@60 ropt-up@120"), [.arm])                         // ⌥A
        XCTAssertEqual(run("ropt-down@0 shift-down@30 key:9@60 shift-up@80 ropt-up@100"), [.arm]) // ⌥⇧V
        XCTAssertEqual(run("shift-down@0 ropt-down@20 ropt-up@90 shift-up@120"), [])            // ⇧ held first
        XCTAssertEqual(run("cmd-down@0 ropt-down@20 ropt-up@90 cmd-up@120"), [])
        XCTAssertEqual(run("ropt-down@0 click@50 ropt-up@100"), [.arm])                         // ⌥-click
    }

    func testLeftOptionDoesNothing() {
        XCTAssertEqual(run("lopt-down@0 lopt-up@100"), [])
        XCTAssertEqual(run("lopt-down@0 ropt-down@10 ropt-up@80 lopt-up@90"), [])              // both ⌥ held
    }

    func testEscapeCancels() {
        XCTAssertEqual(run("ropt-down@0 ropt-up@100 esc@900"), [.arm, .start, .cancel])
        XCTAssertEqual(run("esc@100"), [])                                                      // not dictating
        // after a cancel the next tap starts again
        XCTAssertEqual(run("ropt-down@0 ropt-up@100 esc@900 ropt-down@2000 ropt-up@2100"), [.arm, .start, .cancel, .arm, .start])
    }

    func testTypingWhileDictatingDoesNotStop() {
        XCTAssertEqual(run("ropt-down@0 ropt-up@100 key:4@500 click@700 ropt-down@900 ropt-up@1000"), [.arm, .start, .stop])
    }

    func testResetFromOutside() {
        var t = DictationTrigger(key: .rightOption, mode: .tap)
        XCTAssertEqual(t.run("ropt-down@0 ropt-up@100"), [.arm, .start])
        t.reset(active: false)                       // the app ended it (time limit, the island's button)
        XCTAssertEqual(t.run("ropt-down@2000 ropt-up@2100"), [.arm, .start])
    }

    func testFnKey() {
        XCTAssertEqual(run("fn-down@0 fn-up@100", key: .fn), [.arm, .start])
        XCTAssertEqual(run("ropt-down@0 ropt-up@100", key: .fn), [])
        XCTAssertEqual(run("fn-down@0 key:123@50 fn-up@100", key: .fn), [.arm])                 // Fn-← (Home)
        XCTAssertEqual(run("ropt-down@0 fn-down@10 fn-up@80 ropt-up@90", key: .fn), [])        // ⌥ held: not alone
    }

    // MARK: the default: Fn, auto

    func testDefaultIsFnAuto() {
        XCTAssertEqual(DictationTrigger().key, .fn)
        XCTAssertEqual(DictationTrigger().mode, .auto)
        XCTAssertEqual(DictationTrigger.Key.allCases.first, .fn)              // Fn first in every picker
        XCTAssertEqual(DictationTrigger.Mode.allCases.first, .auto)
        XCTAssertEqual(DictationTrigger.Key(rawValue: "either_option"), .eitherOption)
        XCTAssertEqual(DictationTrigger.Key(rawValue: "right_option"), .rightOption)   // an explicit choice stays
    }

    // MARK: auto mode (tap = hands-free, hold = push-to-talk)

    private func auto(_ script: String, key: DictationTrigger.Key = .fn) -> [DictationTrigger.Output] {
        run(script, key: key, mode: .auto)
    }

    func testAutoTapIsHandsFree() {
        var t = DictationTrigger()
        XCTAssertEqual(t.run("fn-down@0"), [.arm])
        XCTAssertEqual(t.deadline, 0.3)                                     // asks for a tick at the hold threshold
        XCTAssertEqual(t.run("fn-up@120"), [.start])
        XCTAssertTrue(t.active)
        XCTAssertFalse(t.pushToTalk)
        XCTAssertNil(t.deadline)                                            // no hold while hands-free
        XCTAssertEqual(t.run("key:4@500 click@700"), [])                    // typing / clicking doesn't stop it
        XCTAssertEqual(t.run("fn-down@3000 fn-up@3100"), [.stop])
        XCTAssertFalse(t.active)
    }

    func testAutoHoldIsPushToTalk() {
        var t = DictationTrigger()
        XCTAssertEqual(t.run("fn-down@0 tick@300"), [.arm, .start])
        XCTAssertTrue(t.pushToTalk)
        XCTAssertEqual(t.run("fn-up@2500"), [.stop])
        XCTAssertFalse(t.pushToTalk)
        // the next short tap is hands-free again
        XCTAssertEqual(t.run("fn-down@4000 fn-up@4100"), [.arm, .start])
        XCTAssertFalse(t.pushToTalk)
    }

    func testAutoBoundary() {
        XCTAssertEqual(auto("fn-down@0 tick@299 fn-up@299"), [.arm, .start])          // under 300 ms: a tap
        XCTAssertEqual(auto("fn-down@0 tick@300 fn-up@310"), [.arm, .start, .stop])   // at 300 ms: push-to-talk
        XCTAssertEqual(auto("fn-down@0 fn-up@450"), [.arm])                           // long, no tick delivered: nothing
    }

    /// `armedDown`: the app opens the mic on `.arm` and closes it once the press can no longer start a dictation.
    func testArmedDownSaysWhenThePressCanStillStart() {
        func states(_ script: String, mode: DictationTrigger.Mode = .auto) -> [Bool] {
            var t = DictationTrigger(key: .fn, mode: mode)
            return DictationTrigger.parse(script).map { e in _ = t.handle(e); return t.armedDown }
        }
        XCTAssertEqual(states("fn-down@0 fn-up@100"), [true, false])                 // a tap: started at the key-up
        XCTAssertEqual(states("fn-down@0 tick@300 fn-up@900"), [true, false, false])  // held: started at the tick
        XCTAssertEqual(states("fn-down@0 key:123@50 fn-up@100"), [true, false, false]) // Fn-←: the mic closes at once
        XCTAssertEqual(states("fn-down@0 click@40 fn-up@90"), [true, false, false])
        XCTAssertEqual(states("fn-down@0 fn-up@450"), [true, false])                  // too long, no tick: closes
        XCTAssertEqual(states("cmd-down@0 fn-down@10 fn-up@60 cmd-up@90"), [false, false, false, false])  // never armed
        XCTAssertEqual(states("fn-down@0 fn-up@100 fn-down@1000 fn-up@1100"), [true, false, false, false]) // the stop press isn't an arm
        XCTAssertEqual(states("fn-down@0 tick@250 fn-up@400", mode: .hold), [true, false, false])
        XCTAssertEqual(states("fn-down@0 fn-up@100", mode: .hold), [true, false])     // let go before 250 ms
    }

    func testAutoStopsHandsFreeWithALongPressToo() {
        XCTAssertEqual(auto("fn-down@0 fn-up@100 fn-down@2000 fn-up@2900"), [.arm, .start, .stop])
    }

    func testAutoIgnoresShortcutsAndCancels() {
        XCTAssertEqual(auto("fn-down@0 key:123@50 fn-up@100"), [.arm])                           // Fn-← (Home)
        XCTAssertEqual(auto("fn-down@0 tick@300 key:123@500 fn-up@600"), [.arm, .start, .cancel])  // joined while held
        XCTAssertEqual(auto("cmd-down@0 fn-down@10 fn-up@60 cmd-up@90"), [])                       // ⌘ held first
        XCTAssertEqual(auto("fn-down@0 fn-up@100 esc@900"), [.arm, .start, .cancel])
        XCTAssertEqual(auto("fn-down@0 tick@300 esc@600 fn-up@900"), [.arm, .start, .cancel])      // release waited out
        // a stop press that turned into a shortcut doesn't stop
        XCTAssertEqual(auto("fn-down@0 fn-up@100 fn-down@1000 key:123@1050 fn-up@1100"), [.arm, .start])
    }

    func testAutoWithRightOption() {
        XCTAssertEqual(auto("ropt-down@0 ropt-up@100", key: .rightOption), [.arm, .start])
        XCTAssertEqual(auto("ropt-down@0 key:0@60 ropt-up@120", key: .rightOption), [.arm])          // ⌥A
    }

    func testResetEndsPushToTalk() {
        var t = DictationTrigger()
        XCTAssertEqual(t.run("fn-down@0 tick@300"), [.arm, .start])
        t.reset(active: false)                       // the app ended it (time limit)
        XCTAssertFalse(t.pushToTalk)
        XCTAssertEqual(t.run("fn-up@900"), [])        // its release is waited out
    }

    // MARK: either ⌥

    func testEitherOptionTapsWithLeftOrRight() {
        XCTAssertEqual(run("lopt-down@0 lopt-up@100", key: .eitherOption), [.arm, .start])
        XCTAssertEqual(run("ropt-down@0 ropt-up@100", key: .eitherOption), [.arm, .start])
        // start with the left one, stop with the right one
        XCTAssertEqual(run("lopt-down@0 lopt-up@100 ropt-down@2000 ropt-up@2100", key: .eitherOption), [.arm, .start, .stop])
    }

    func testEitherOptionStillIgnoresShortcuts() {
        XCTAssertEqual(run("lopt-down@0 key:0@60 lopt-up@120", key: .eitherOption), [.arm])                         // ⌥A
        XCTAssertEqual(run("lopt-down@0 shift-down@30 key:9@60 shift-up@80 lopt-up@100", key: .eitherOption), [.arm]) // ⌥⇧V
        XCTAssertEqual(run("cmd-down@0 lopt-down@20 lopt-up@90 cmd-up@120", key: .eitherOption), [])
        XCTAssertEqual(run("lopt-down@0 click@50 lopt-up@100", key: .eitherOption), [.arm])                          // ⌥-click
        XCTAssertEqual(run("lopt-down@0 fn-down@20 fn-up@40 lopt-up@90", key: .eitherOption), [.arm])
    }

    func testEitherOptionBothSidesAtOnceIsNotATap() {
        XCTAssertEqual(run("lopt-down@0 ropt-down@10 ropt-up@80 lopt-up@90", key: .eitherOption), [.arm])
        XCTAssertEqual(run("ropt-down@0 lopt-down@10 ropt-up@80 lopt-up@90", key: .eitherOption), [.arm])
        // and the next clean tap works again
        XCTAssertEqual(run("lopt-down@0 ropt-down@10 ropt-up@80 lopt-up@90 lopt-down@500 lopt-up@600", key: .eitherOption),
                       [.arm, .arm, .start])
    }

    func testEitherOptionHold() {
        XCTAssertEqual(run("lopt-down@0 tick@260 lopt-up@1000", key: .eitherOption, mode: .hold), [.arm, .start, .stop])
        XCTAssertEqual(run("lopt-down@0 tick@260 ropt-down@500 ropt-up@550 lopt-up@1000", key: .eitherOption, mode: .hold),
                       [.arm, .start, .cancel])
    }

    func testRightOptionStillIgnoresLeft() {
        XCTAssertEqual(run("lopt-down@0 lopt-up@100", key: .rightOption), [])
        XCTAssertEqual(run("lopt-down@0 lopt-up@100", key: .fn), [])
    }

    // MARK: hold mode

    func testHoldStartsAfterThresholdAndReleaseStops() {
        var t = DictationTrigger(key: .rightOption, mode: .hold)
        XCTAssertEqual(t.run("ropt-down@0"), [.arm])
        XCTAssertEqual(t.deadline, 0.25)
        XCTAssertEqual(t.run("tick@250"), [.start])
        XCTAssertNil(t.deadline)
        XCTAssertEqual(t.run("ropt-up@3000"), [.stop])
    }

    func testHoldTooShortDoesNothing() {
        XCTAssertEqual(run("ropt-down@0 tick@100 ropt-up@200", mode: .hold), [.arm])
    }

    func testHoldCancelsWhenAnotherKeyJoins() {
        XCTAssertEqual(run("ropt-down@0 tick@260 key:0@900 ropt-up@1000", mode: .hold), [.arm, .start, .cancel])
        XCTAssertEqual(run("ropt-down@0 tick@260 shift-down@900 shift-up@950 ropt-up@1000", mode: .hold), [.arm, .start, .cancel])
        // a key before the threshold: a shortcut, never a start
        XCTAssertEqual(run("ropt-down@0 key:0@100 tick@260 ropt-up@400", mode: .hold), [.arm])
    }

    func testHoldStartsOnLateInputWithoutTick() {
        // no tick delivered, but the key was alone for 300 ms when the click came: started, then cancelled by it
        XCTAssertEqual(run("ropt-down@0 click@300 ropt-up@500", mode: .hold), [.arm, .start, .cancel])
    }

    func testHoldEscape() {
        XCTAssertEqual(run("ropt-down@0 tick@260 esc@600 ropt-up@900", mode: .hold), [.arm, .start, .cancel])
    }

    // MARK: double tap = Return (send)

    func testSingleTapStillStartsAtOnce() {
        // nothing waits for a second tap: the first one starts as it always did
        XCTAssertEqual(auto("fn-down@0 fn-up@100"), [.arm, .start])
        XCTAssertEqual(auto("fn-down@0 fn-up@100 fn-down@3000 fn-up@3100"), [.arm, .start, .stop])
    }

    func testDoubleTapWhenIdleCancelsAndSends() {
        // the first tap started a dictation; the second, 120 ms after its release, cancels it and sends
        XCTAssertEqual(auto("fn-down@0 fn-up@90 fn-down@210 fn-up@290"), [.arm, .start, .cancel, .send])
        XCTAssertEqual(run("ropt-down@0 ropt-up@90 ropt-down@200 ropt-up@280"), [.arm, .start, .cancel, .send])  // tap mode
        // too slow for a double tap: an ordinary stop
        XCTAssertEqual(auto("fn-down@0 fn-up@90 fn-down@420 fn-up@500"), [.arm, .start, .stop])
        // the window is from the first release to the second press
        XCTAssertEqual(auto("fn-down@0 fn-up@90 fn-down@380 fn-up@460"), [.arm, .start, .cancel, .send])
        // a triple tap: the third starts afresh
        XCTAssertEqual(auto("fn-down@0 fn-up@90 fn-down@200 fn-up@280 fn-down@1500 fn-up@1600"),
                       [.arm, .start, .cancel, .send, .arm, .start])
    }

    func testDoubleTapWhileDictatingStopsThenSends() {
        var t = DictationTrigger()
        XCTAssertEqual(t.run("fn-down@0 fn-up@100"), [.arm, .start])
        // dictating… the first tap stops (the paste starts at once), the second sends — no mic for it
        XCTAssertEqual(t.run("fn-down@5000 fn-up@5080"), [.stop])
        XCTAssertEqual(t.run("fn-down@5200"), [])
        XCTAssertEqual(t.run("fn-up@5270"), [.send])
        XCTAssertFalse(t.active)
        // a stop press can be long (auto mode): the next quick tap still sends
        XCTAssertEqual(auto("fn-down@0 fn-up@100 fn-down@3000 fn-up@3500 fn-down@3600 fn-up@3680"), [.arm, .start, .stop, .send])
    }

    func testPushToTalkThenTapSends() {
        // hold to talk, let go (stop), tap at once: send
        XCTAssertEqual(auto("fn-down@0 tick@300 fn-up@2500 fn-down@2700 fn-up@2780"), [.arm, .start, .stop, .send])
        // the same in hold mode
        XCTAssertEqual(run("ropt-down@0 tick@250 ropt-up@2000 ropt-down@2150 ropt-up@2220", mode: .hold), [.arm, .start, .stop, .send])
    }

    func testHoldModeDoubleTapSends() {
        // taps start nothing in hold mode; two of them press Return
        XCTAssertEqual(run("ropt-down@0 ropt-up@100 ropt-down@250 ropt-up@330", mode: .hold), [.arm, .send])
        XCTAssertEqual(run("ropt-down@0 ropt-up@100 ropt-down@600 ropt-up@680", mode: .hold), [.arm, .arm])
        // holding the second press is push-to-talk as usual
        XCTAssertEqual(run("ropt-down@0 ropt-up@100 ropt-down@250 tick@500 ropt-up@2000", mode: .hold), [.arm, .start, .stop])
    }

    func testSecondPressHeldIsPushToTalk() {
        // after a stop, a press held past the threshold isn't a tap: it starts push-to-talk
        XCTAssertEqual(auto("fn-down@0 fn-up@100 fn-down@3000 fn-up@3080 fn-down@3200 tick@3510 fn-up@5000"),
                       [.arm, .start, .stop, .start, .stop])
        // and while dictating, a long second press stops (no send)
        XCTAssertEqual(auto("fn-down@0 fn-up@90 fn-down@200 fn-up@800"), [.arm, .start, .stop])
    }

    func testFnWithAnotherKeyIsNeverADoubleTap() {
        // Fn-← between two taps: the second tap is an ordinary one
        XCTAssertEqual(auto("fn-down@0 fn-up@90 key:123@150 fn-down@200 fn-up@280"), [.arm, .start, .stop])
        // the second press joined by a key (Fn-←): no send, the dictation goes on
        XCTAssertEqual(auto("fn-down@0 fn-up@90 fn-down@200 key:123@230 fn-up@280"), [.arm, .start])
        // ⌘ held for the second press: not alone
        XCTAssertEqual(auto("fn-down@0 fn-up@90 cmd-down@150 fn-down@200 fn-up@280 cmd-up@300"), [.arm, .start])
        // a click in between
        XCTAssertEqual(auto("fn-down@0 fn-up@90 click@150 fn-down@200 fn-up@280"), [.arm, .start, .stop])
    }

    func testEscapeBetweenTapsIsNotADoubleTap() {
        XCTAssertEqual(auto("fn-down@0 fn-up@90 esc@150 fn-down@200 fn-up@280"), [.arm, .start, .cancel, .arm, .start])
    }

    func testDoubleTapOff() {
        var t = DictationTrigger()
        t.doubleTap = false
        XCTAssertEqual(t.run("fn-down@0 fn-up@90 fn-down@210 fn-up@290"), [.arm, .start, .stop])
        var h = DictationTrigger(key: .rightOption, mode: .hold)
        h.doubleTap = false
        XCTAssertEqual(h.run("ropt-down@0 ropt-up@100 ropt-down@250 ropt-up@330"), [.arm, .arm])
    }

    func testResetForgetsTheFirstTap() {
        var t = DictationTrigger()
        XCTAssertEqual(t.run("fn-down@0 fn-up@90"), [.arm, .start])
        t.reset(active: false)               // the app couldn't start (a recording has the mic)
        XCTAssertEqual(t.run("fn-down@200 fn-up@280"), [.arm, .start])
    }

    func testParseFlags() {
        let e = DictationTrigger.parse("ropt-down@0 shift-down@10 ropt-up@20")
        XCTAssertEqual(e, [.flags(keyCode: 61, flags: 0x80040, time: 0), .flags(keyCode: 56, flags: 0xA0040, time: 0.01),
                           .flags(keyCode: 61, flags: 0x20000, time: 0.02)])
    }
}
