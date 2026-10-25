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
        // ⇧ with a key is a shortcut: cancelled; ⇧ alone is the style toggle (testShiftAloneTogglesTheStyle)
        XCTAssertEqual(run("ropt-down@0 tick@260 shift-down@900 key:0@920 shift-up@950 ropt-up@1000", mode: .hold), [.arm, .start, .cancel])
        XCTAssertEqual(run("ropt-down@0 tick@260 shift-down@900 shift-up@950 ropt-up@1000", mode: .hold), [.arm, .start, .style, .stop])
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
        // too slow for a double tap (the default window is 0.5 s): an ordinary stop
        XCTAssertEqual(auto("fn-down@0 fn-up@90 fn-down@620 fn-up@700"), [.arm, .start, .stop])
        // the window is from the first release to the second press
        XCTAssertEqual(auto("fn-down@0 fn-up@90 fn-down@580 fn-up@660"), [.arm, .start, .cancel, .send])
        // the audit's slow double tap (320 ms between the release and the next press) is one now
        XCTAssertEqual(auto("fn-down@0 fn-up@120 fn-down@440 fn-up@560"), [.arm, .start, .cancel, .send])
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

    func testPushToTalkThenDoubleTapSends() {
        // hold to talk, let go (stop), double-tap at once: the first tap does nothing by itself, the second sends
        XCTAssertEqual(auto("fn-down@0 tick@300 fn-up@2500 fn-down@2700 fn-up@2780"), [.arm, .start, .stop])
        XCTAssertEqual(auto("fn-down@0 tick@300 fn-up@2500 fn-down@2700 fn-up@2780 fn-down@2900 fn-up@2980"),
                       [.arm, .start, .stop, .send])
        // the same in hold mode
        XCTAssertEqual(run("ropt-down@0 tick@250 ropt-up@2000 ropt-down@2150 ropt-up@2220 ropt-down@2350 ropt-up@2420", mode: .hold),
                       [.arm, .start, .stop, .send])
        // a tap long after the release is an ordinary start
        XCTAssertEqual(auto("fn-down@0 tick@300 fn-up@2500 fn-down@4000 fn-up@4080"), [.arm, .start, .stop, .arm, .start])
    }

    func testHoldModeDoubleTapSends() {
        // taps start nothing in hold mode; two of them press Return
        XCTAssertEqual(run("ropt-down@0 ropt-up@100 ropt-down@250 ropt-up@330", mode: .hold), [.arm, .send])
        XCTAssertEqual(run("ropt-down@0 ropt-up@100 ropt-down@700 ropt-up@780", mode: .hold), [.arm, .arm])
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
        t.reset(active: false)               // the app ended it itself
        XCTAssertEqual(t.run("fn-down@200 fn-up@280"), [.arm, .start])
    }

    func testRefusedStartKeepsTheDoubleTap() {
        // the app couldn't start (a recording has the mic, the mic failed): the second tap still sends — Return needs
        // no mic (dict031)
        var t = DictationTrigger()
        XCTAssertEqual(t.run("fn-down@0 fn-up@90"), [.arm, .start])
        t.reset(active: false, keepTap: true)
        XCTAssertFalse(t.active)
        XCTAssertEqual(t.run("fn-down@200 fn-up@280"), [.send])
    }

    func testDoubleTapWindowFollowsDoubleClickInterval() {
        XCTAssertEqual(DictationTrigger.window(doubleClickInterval: 0.5), 0.5)
        XCTAssertEqual(DictationTrigger.window(doubleClickInterval: 0.4), 0.4)
        XCTAssertEqual(DictationTrigger.window(doubleClickInterval: 0.15), 0.3)     // never under 0.3 s
        XCTAssertEqual(DictationTrigger.window(doubleClickInterval: 5), 0.5)        // never over 0.5 s
        var t = DictationTrigger()
        t.doubleTapWindow = 0.3
        XCTAssertEqual(t.run("fn-down@0 fn-up@90 fn-down@420 fn-up@500"), [.arm, .start, .stop])
    }

    // MARK: pending (the last take is still being transcribed, polished or pasted)

    func testTapWhilePendingStartsTheNextTake() {
        // dogfood: stop, then a tap 650 ms later (past the double-tap window) to say the next thought - it starts a
        // new take at once (the app pastes in order), instead of being swallowed while the last one is still typed
        var t = DictationTrigger()
        XCTAssertEqual(t.run("fn-down@0 fn-up@80"), [.arm, .start])
        XCTAssertEqual(t.run("fn-down@10000 fn-up@10070"), [.stop])
        t.pending = true                                                    // the app: transcribing
        XCTAssertEqual(t.run("fn-down@10720"), [.arm])                      // the mic opens on the key-down as usual
        XCTAssertTrue(t.armedDown)
        XCTAssertEqual(t.run("fn-up@10800"), [.start])
        XCTAssertTrue(t.active)
        // held instead: push-to-talk, also while pending
        var h = DictationTrigger()
        h.pending = true
        XCTAssertEqual(h.run("fn-down@0 tick@310 fn-up@2000"), [.arm, .start, .stop])
        // tap mode too
        var m = DictationTrigger(key: .rightOption, mode: .tap)
        m.pending = true
        XCTAssertEqual(m.run("ropt-down@0 ropt-up@90"), [.arm, .start])
    }

    func testDoubleTapAfterStopStillSendsWhilePending() {
        // the stop tap, then a tap within the window: the double tap's second one - Return once the paste is in
        var t = DictationTrigger()
        XCTAssertEqual(t.run("fn-down@0 fn-up@90 fn-down@42500 fn-up@42580"), [.arm, .start, .stop])
        t.pending = true
        XCTAssertEqual(t.run("fn-down@42900 fn-up@42980"), [.send])
        XCTAssertFalse(t.active)
        // two quick taps while pending, outside the stop's window: a take starts and the second tap cancels it and
        // sends (the app queues Return after the paste)
        var s = DictationTrigger()
        XCTAssertEqual(s.run("fn-down@0 fn-up@90 fn-down@42500 fn-up@42580"), [.arm, .start, .stop])
        s.pending = true
        XCTAssertEqual(s.run("fn-down@43200 fn-up@43280 fn-down@43400 fn-up@43480"), [.arm, .start, .cancel, .send])
        XCTAssertFalse(s.active)
    }

    func testThirdTapOfADoubleTapIsABounce() {
        // dict019: the double tap's second press, then a third 120 ms later - the third never starts a take
        var t = DictationTrigger()
        XCTAssertEqual(t.run("fn-down@0 fn-up@90 fn-down@42500 fn-up@42580"), [.arm, .start, .stop])
        XCTAssertEqual(t.run("fn-down@42900 fn-up@42980"), [.send])
        XCTAssertEqual(t.run("fn-down@43100 fn-up@43180"), [])
        XCTAssertFalse(t.active)
        // idle: tap, tap (send), tap -> nothing; a tap once the window has passed starts as usual
        var i = DictationTrigger()
        XCTAssertEqual(i.run("fn-down@0 fn-up@80 fn-down@200 fn-up@280 fn-down@400 fn-up@480"), [.arm, .start, .cancel, .send])
        XCTAssertEqual(i.run("fn-down@2000 fn-up@2080"), [.arm, .start])
    }

    func testEscCancelsTheTakeOnItsWay() {
        var t = DictationTrigger()
        XCTAssertEqual(t.run("fn-down@0 fn-up@90 fn-down@5000 fn-up@5080"), [.arm, .start, .stop])
        XCTAssertEqual(t.run("esc@5200"), [])                               // nothing on its way: Esc is the app's
        t.pending = true
        XCTAssertEqual(t.run("esc@5300"), [.cancel])
        XCTAssertFalse(t.active)
        // a dictation listening: Esc cancels that one, as before
        var l = DictationTrigger()
        l.pending = true
        XCTAssertEqual(l.run("fn-down@0 fn-up@90 esc@900"), [.arm, .start, .cancel])
    }

    func testTapRightAfterAnAutomaticEndDoesNothing() {
        // the 5-minute limit ended the take; the user's "stop" tap a moment later must not start a new one
        var t = DictationTrigger()
        XCTAssertEqual(t.run("fn-down@0 fn-up@90"), [.arm, .start])
        t.endedByItself(at: 300)
        XCTAssertFalse(t.active)
        XCTAssertEqual(t.run("fn-down@301000 fn-up@301080"), [])
        XCTAssertFalse(t.active)
        // the next tap is a new take
        XCTAssertEqual(t.run("fn-down@302000 fn-up@302080"), [.arm, .start])
        // the late stop 3.5 s after the end, while the island still says the take ended, is a stop too (v0.9
        // dogfood: with a 2 s grace it started a new take under that line)
        var e = DictationTrigger()
        _ = e.run("fn-down@0 fn-up@90")
        e.endedByItself(at: 300)
        XCTAssertEqual(DictationTrigger.limitGrace, 4)
        XCTAssertEqual(e.run("fn-down@303500 fn-up@303580"), [])
        // after the grace a tap starts again
        var g = DictationTrigger()
        _ = g.run("fn-down@0 fn-up@90")
        g.endedByItself(at: 300)
        XCTAssertEqual(g.run("fn-down@304500 fn-up@304580"), [.arm, .start])
        // a quick double tap right after the end still sends
        var d = DictationTrigger()
        _ = d.run("fn-down@0 fn-up@90")
        d.endedByItself(at: 300)
        XCTAssertEqual(d.run("fn-down@300500 fn-up@300580 fn-down@300700 fn-up@300780"), [.send])
    }

    /// Fn+← (Home) within the first second is a shortcut: no "Cancelled" line; Esc, or later, still says it.
    func testAKeyJoiningRightAwayIsAShortcut() {
        XCTAssertTrue(DictationTrigger.joinedEarly(esc: false, listening: true, elapsed: 0.4, finalPieces: 0))
        XCTAssertFalse(DictationTrigger.joinedEarly(esc: true, listening: true, elapsed: 0.4, finalPieces: 0))
        XCTAssertFalse(DictationTrigger.joinedEarly(esc: false, listening: true, elapsed: 1.5, finalPieces: 0))
        XCTAssertFalse(DictationTrigger.joinedEarly(esc: false, listening: true, elapsed: 0.8, finalPieces: 1))
        XCTAssertFalse(DictationTrigger.joinedEarly(esc: false, listening: false, elapsed: 0.2, finalPieces: 0))
    }

    func testMissesSayWhatTheModeWants() {
        var h = DictationTrigger(key: .fn, mode: .hold)
        XCTAssertEqual(h.run("fn-down@0 fn-up@90"), [.arm])
        XCTAssertEqual(h.miss, .tappedInHoldMode)
        XCTAssertEqual(h.run("fn-down@2000 tick@2250 fn-up@4000"), [.arm, .start, .stop])
        XCTAssertNil(h.miss)
        var t = DictationTrigger(key: .rightOption, mode: .tap)
        XCTAssertEqual(t.run("ropt-down@0 ropt-up@900"), [.arm])
        XCTAssertEqual(t.miss, .heldInTapMode)
        XCTAssertEqual(t.run("ropt-down@2000 ropt-up@2080"), [.arm, .start])
        XCTAssertNil(t.miss)
        // auto mode uses both: never a miss
        var a = DictationTrigger()
        _ = a.run("fn-down@0 fn-up@90 fn-down@900 fn-up@990")
        XCTAssertNil(a.miss)
    }

    /// review: the miss stayed set until the next dictation-key press, so every other key and click re-reported it
    func testAMissIsReportedOnce() {
        var h = DictationTrigger(key: .fn, mode: .hold)
        _ = h.run("fn-down@0 fn-up@90")
        XCTAssertEqual(h.takeMiss(), .tappedInHoldMode)
        XCTAssertNil(h.takeMiss())
        // the keys and the click that follow don't bring it back
        _ = h.run("key:0@500 click@700")
        XCTAssertNil(h.takeMiss())
        XCTAssertNil(h.miss)
    }

    func testNearMissDoubleTapIsAQuickStop() {
        // the second press 520 ms after the first release: outside the window, so the first tap's dictation stops —
        // but it was a near miss, and the app sends instead of "nothing heard" when nothing was
        var t = DictationTrigger()
        XCTAssertEqual(t.run("fn-down@0 fn-up@120 fn-down@640 fn-up@760"), [.arm, .start, .stop])
        XCTAssertTrue(t.quickStop)
        // a real stop seconds later is not
        var s = DictationTrigger()
        XCTAssertEqual(s.run("fn-down@0 fn-up@120 fn-down@3000 fn-up@3080"), [.arm, .start, .stop])
        XCTAssertFalse(s.quickStop)
        // nor one with a key between, nor a long stop press, nor with double tap off
        var k = DictationTrigger()
        XCTAssertEqual(k.run("fn-down@0 fn-up@120 key:4@300 fn-down@640 fn-up@760"), [.arm, .start, .stop])
        XCTAssertFalse(k.quickStop)
        var l = DictationTrigger()
        XCTAssertEqual(l.run("fn-down@0 fn-up@120 fn-down@640 fn-up@1400"), [.arm, .start, .stop])
        XCTAssertFalse(l.quickStop)
        var o = DictationTrigger()
        o.doubleTap = false
        XCTAssertEqual(o.run("fn-down@0 fn-up@120 fn-down@640 fn-up@760"), [.arm, .start, .stop])
        XCTAssertFalse(o.quickStop)
        // tap mode the same
        var m = DictationTrigger(key: .rightOption, mode: .tap)
        XCTAssertEqual(m.run("ropt-down@0 ropt-up@100 ropt-down@650 ropt-up@740"), [.arm, .start, .stop])
        XCTAssertTrue(m.quickStop)
    }

    // MARK: the physical event stream

    func testRepeatedKeyDownIsOnePress() {
        // the same Fn change reported twice (two listeners overlapping, a repeat): one press, its hold time unchanged
        XCTAssertEqual(auto("fn-down@0 fn-down@40 fn-up@90"), [.arm, .start])
        XCTAssertEqual(auto("fn-down@0 fn-down@200 tick@300 fn-up@2000"), [.arm, .start, .stop])
        // a repeat on the double tap's second press keeps it the second tap
        XCTAssertEqual(auto("fn-down@0 fn-up@90 fn-down@200 fn-down@230 fn-up@280"), [.arm, .start, .cancel, .send])
        // a release reported twice: the second one does nothing
        XCTAssertEqual(auto("fn-down@0 fn-up@90 fn-up@100"), [.arm, .start])
    }

    func testEventTimeUsesTheEventsOwnClock() {
        let now = 3_516_593.68
        // Apple Silicon: mach ticks (125/3 ns each); an event 120 ms ago
        let ticks = UInt64((now - 0.12) * 1e9 * 3 / 125)
        XCTAssertEqual(DictationTrigger.eventTime(raw: ticks, now: now, ticksToNs: 125.0 / 3), now - 0.12, accuracy: 0.001)
        // nanoseconds (Intel, or a fixed CoreGraphics)
        let ns = UInt64((now - 0.3) * 1e9)
        XCTAssertEqual(DictationTrigger.eventTime(raw: ns, now: now, ticksToNs: 125.0 / 3), now - 0.3, accuracy: 0.001)
        XCTAssertEqual(DictationTrigger.eventTime(raw: ns, now: now, ticksToNs: 1), now - 0.3, accuracy: 0.001)
        // a synthetic event (0), or one that makes no sense: the time it reached us
        XCTAssertEqual(DictationTrigger.eventTime(raw: 0, now: now, ticksToNs: 125.0 / 3), now)
        XCTAssertEqual(DictationTrigger.eventTime(raw: UInt64((now + 5) * 1e9), now: now, ticksToNs: 1), now)
        XCTAssertEqual(DictationTrigger.eventTime(seconds: now - 0.2, now: now), now - 0.2)
        XCTAssertEqual(DictationTrigger.eventTime(seconds: 12, now: now), now)
        // a double tap whose second press was handled 400 ms late still reads as one with the events' own times
        var t = DictationTrigger()
        _ = t.handle(.flags(keyCode: 63, flags: 0x80_0000, time: 0))
        _ = t.handle(.flags(keyCode: 63, flags: 0, time: 0.09))
        _ = t.handle(.flags(keyCode: 63, flags: 0x80_0000, time: 0.25))     // stamped 0.25 (the event), not 0.65 (handled)
        XCTAssertEqual(t.handle(.flags(keyCode: 63, flags: 0, time: 0.33)), [.cancel, .send])
    }

    func testGlobeKeyDownIsPartOfTheFnPress() {
        // some keyboards send a keyDown (179) with the Globe key: not a shortcut, not "another key between the taps"
        XCTAssertEqual(auto("fn-down@0 key:179@10 fn-up@90"), [.arm, .start])
        XCTAssertEqual(auto("fn-down@0 fn-up@90 key:179@100 fn-down@200 key:179@210 fn-up@280"), [.arm, .start, .cancel, .send])
        // with an ⌥ key it is just another key
        XCTAssertEqual(run("ropt-down@0 key:179@10 ropt-up@90"), [.arm])
    }

    // MARK: the style toggle (dictation-styles.md §3.2): ⇧ during a take, the island, Fn+⇧

    func testShiftAloneTogglesTheStyle() {
        // hands-free (auto tap): ⇧ tapped twice while talking → two toggles; the dictation goes on and stops normally
        XCTAssertEqual(auto("fn-down@0 fn-up@90 shift-down@1000 shift-up@1080 shift-down@2000 shift-up@2060 fn-down@3000 fn-up@3080"),
                       [.arm, .start, .style, .style, .stop])
        // the right ⇧ too
        XCTAssertEqual(auto("fn-down@0 fn-up@90 rshift-down@1000 rshift-up@1080"), [.arm, .start, .style])
        // tap mode, right ⌥
        XCTAssertEqual(run("ropt-down@0 ropt-up@100 shift-down@500 shift-up@560 ropt-down@900 ropt-up@1000"), [.arm, .start, .style, .stop])
    }

    func testShiftInPushToTalkTogglesWithoutCancelling() {
        // auto held past 300 ms: push-to-talk; a lone ⇧ while held is the toggle, and letting go still stops
        var t = DictationTrigger()
        XCTAssertEqual(t.run("fn-down@0 tick@300"), [.arm, .start])
        XCTAssertTrue(t.pushToTalk)
        XCTAssertEqual(t.run("shift-down@800 shift-up@870"), [.style])
        XCTAssertTrue(t.active)
        XCTAssertEqual(t.run("fn-up@2000"), [.stop])
        // hold mode the same
        XCTAssertEqual(run("ropt-down@0 tick@260 shift-down@600 shift-up@650 ropt-up@1500", mode: .hold), [.arm, .start, .style, .stop])
    }

    func testShiftWithAnotherKeyIsNoToggle() {
        // ⇧A (a capital) while hands-free: no toggle, nothing cancelled
        XCTAssertEqual(auto("fn-down@0 fn-up@90 shift-down@1000 key:0@1050 shift-up@1100"), [.arm, .start])
        // ⇧ with a click
        XCTAssertEqual(auto("fn-down@0 fn-up@90 shift-down@1000 click@1050 shift-up@1100"), [.arm, .start])
        // push-to-talk: ⇧ + a key is a shortcut → cancelled, as before
        XCTAssertEqual(auto("fn-down@0 tick@300 shift-down@800 key:0@820 shift-up@870 fn-up@2000"), [.arm, .start, .cancel])
        // ⇧ held for a long time (a resting finger) is no toggle
        XCTAssertEqual(auto("fn-down@0 fn-up@90 shift-down@1000 shift-up@2500"), [.arm, .start])
        // not dictating: ⇧ is just a key
        XCTAssertEqual(auto("shift-down@0 shift-up@60"), [])
    }

    func testFnShiftStartsInStructured() {
        // ⇧ held when Fn goes down (a tap): starts, and says it was Fn+⇧
        var t = DictationTrigger()
        XCTAssertEqual(t.run("shift-down@0 fn-down@20 fn-up@110 shift-up@150"), [.arm, .start])
        XCTAssertTrue(t.startShift)
        XCTAssertEqual(t.run("fn-down@2000 fn-up@2080"), [.stop])
        XCTAssertFalse(t.startShift == true && t.active)
        // ⇧ pressed while Fn is down, then push-to-talk
        var h = DictationTrigger()
        XCTAssertEqual(h.run("fn-down@0 shift-down@50 shift-up@120 tick@300"), [.arm, .start])
        XCTAssertTrue(h.startShift)
        XCTAssertTrue(h.pushToTalk)
        // a plain start isn't
        var p = DictationTrigger()
        XCTAssertEqual(p.run("fn-down@0 fn-up@90"), [.arm, .start])
        XCTAssertFalse(p.startShift)
        // Fn+⇧+← (select to the line start) is a shortcut, not a start
        XCTAssertEqual(auto("fn-down@0 shift-down@30 key:123@60 shift-up@90 fn-up@120"), [.arm])
        XCTAssertEqual(auto("shift-down@0 fn-down@20 key:123@60 fn-up@120 shift-up@150"), [.arm])
        // with an ⌥ key ⇧ stays a modifier: ⌥⇧V and Blurt's ⌥⇧ shortcuts never start anything
        XCTAssertEqual(run("shift-down@0 ropt-down@20 ropt-up@90 shift-up@120"), [])
        XCTAssertEqual(auto("shift-down@0 lopt-down@20 lopt-up@90 shift-up@120", key: .eitherOption), [])
        // while dictating, ⇧ + Fn is neither a stop nor a toggle (a press that turned into a shortcut)
        XCTAssertEqual(auto("fn-down@0 fn-up@90 shift-down@1000 fn-down@1050 fn-up@1120 shift-up@1200"), [.arm, .start])
    }

    func testIslandClickTogglesAndNeverCancels() {
        // push-to-talk: a click elsewhere cancels it, a click on the island is the style chip
        XCTAssertEqual(auto("fn-down@0 tick@300 island@800 fn-up@2000"), [.arm, .start, .style, .stop])
        XCTAssertEqual(auto("fn-down@0 tick@300 click@800 fn-up@2000"), [.arm, .start, .cancel])
        XCTAssertEqual(auto("fn-down@0 fn-up@90 island@500 island@900"), [.arm, .start, .style, .style])
        // not dictating: nothing
        XCTAssertEqual(auto("island@100"), [])
    }

    func testParseFlags() {
        let e = DictationTrigger.parse("ropt-down@0 shift-down@10 ropt-up@20")
        XCTAssertEqual(e, [.flags(keyCode: 61, flags: 0x80040, time: 0), .flags(keyCode: 56, flags: 0xA0040, time: 0.01),
                           .flags(keyCode: 61, flags: 0x20000, time: 0.02)])
    }
}
