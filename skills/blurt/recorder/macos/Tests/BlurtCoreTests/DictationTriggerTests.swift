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
        var t = DictationTrigger()
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

    // MARK: hold mode

    func testHoldStartsAfterThresholdAndReleaseStops() {
        var t = DictationTrigger(mode: .hold)
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

    func testParseFlags() {
        let e = DictationTrigger.parse("ropt-down@0 shift-down@10 ropt-up@20")
        XCTAssertEqual(e, [.flags(keyCode: 61, flags: 0x80040, time: 0), .flags(keyCode: 56, flags: 0xA0040, time: 0.01),
                           .flags(keyCode: 61, flags: 0x20000, time: 0.02)])
    }
}
