import XCTest
@testable import BlurtCore

/// ⇧ for a voice note's Structured asks the same way a dictation's does (v0.9-userfix): a double tap by default, a
/// single tap when the dictation's setting says so.
final class VoiceNoteStyleTests: XCTestCase {
    func toggles(_ script: String, mode: DictationTrigger.ModifierTap = DictationTrigger.shippedModifierTap,
                 holding: Set<String> = []) -> Int {
        var s = LoneShift()
        s.mode = mode
        return DictationTrigger.parse(script, holding: holding).filter { s.handle($0) }.count
    }

    func testDoubleShiftToggles() {
        // one ⇧ is nothing; two quick ones toggle
        XCTAssertEqual(toggles("shift-down@0 shift-up@120"), 0)
        XCTAssertEqual(toggles("shift-down@0 shift-up@120 shift-down@300 shift-up@420"), 1)
        XCTAssertEqual(toggles("rshift-down@0 rshift-up@100 rshift-down@280 rshift-up@400"), 1)
        // too slow: two singles, no toggle
        XCTAssertEqual(toggles("shift-down@0 shift-up@120 shift-down@600 shift-up@720"), 0)
        // after a fire, a third tap inside the cooldown does nothing
        XCTAssertEqual(toggles("shift-down@0 shift-up@100 shift-down@250 shift-up@350 shift-down@500 shift-up@600"), 1)
    }

    func testSingleModeFiresOnOneShift() {
        XCTAssertEqual(toggles("shift-down@0 shift-up@120", mode: .single), 1)
        XCTAssertEqual(toggles("rshift-down@0 rshift-up@90", mode: .single), 1)
        // a finger resting on it
        XCTAssertEqual(toggles("shift-down@0 shift-up@1500", mode: .single), 0)
    }

    func testNotALoneShift() {
        // ⌥⇧V itself: ⇧ goes down with ⌥ held, in either order of letting go
        XCTAssertEqual(toggles("lopt-down@0 shift-down@30 key:9@60 shift-up@120 lopt-up@150"), 0)
        XCTAssertEqual(toggles("lopt-down@0 shift-down@30 key:9@60 lopt-up@100 shift-up@150"), 0)
        // a capital letter, a ⇧-click, a finger resting on it
        XCTAssertEqual(toggles("shift-down@0 key:0@50 shift-up@100"), 0)
        XCTAssertEqual(toggles("shift-down@0 click@50 shift-up@100"), 0)
        XCTAssertEqual(toggles("shift-down@0 shift-up@1500"), 0)
        // ⌘⇧ (a shortcut), one tap or two
        XCTAssertEqual(toggles("cmd-down@0 shift-down@20 shift-up@80 cmd-up@100"), 0)
        XCTAssertEqual(toggles("cmd-down@0 shift-down@20 shift-up@80 shift-down@200 shift-up@260 cmd-up@300"), 0)
    }

    func testTheSameChangeTwiceCountsOnce() {
        var s = LoneShift()
        let down = DictationTrigger.Event.flags(keyCode: 56, flags: 0x2_0000, time: 1.0)
        let up = DictationTrigger.Event.flags(keyCode: 56, flags: 0, time: 1.1)
        XCTAssertFalse(s.handle(down))
        XCTAssertFalse(s.handle(down))      // a second listener's copy: not a first tap twice
        XCTAssertFalse(s.handle(up))
        // the second listener's copies arriving after the first's whole double tap: still one toggle
        var t = LoneShift()
        let d1 = DictationTrigger.Event.flags(keyCode: 56, flags: 0x2_0000, time: 1.0)
        let u1 = DictationTrigger.Event.flags(keyCode: 56, flags: 0, time: 1.1)
        let d2 = DictationTrigger.Event.flags(keyCode: 56, flags: 0x2_0000, time: 1.25)
        let u2 = DictationTrigger.Event.flags(keyCode: 56, flags: 0, time: 1.35)
        XCTAssertEqual([d1, u1, d2, u2].filter { t.handle($0) }.count, 1)
    }

    func testWhatTheCardKeeps() {
        let k = VoiceNoteStructure.keep(raw: " 买牛奶 鸡蛋 不对是鸭蛋 ", structured: "- 买牛奶\n- 鸭蛋")
        XCTAssertEqual(k.said, "- 买牛奶\n- 鸭蛋")
        XCTAssertEqual(k.raw, "买牛奶 鸡蛋 不对是鸭蛋")
        // refused, no model, or the same text: the transcript is the note, nothing extra kept
        XCTAssertEqual(VoiceNoteStructure.keep(raw: "hello", structured: nil).said, "hello")
        XCTAssertNil(VoiceNoteStructure.keep(raw: "hello", structured: nil).raw)
        XCTAssertNil(VoiceNoteStructure.keep(raw: "hello", structured: "hello").raw)
        XCTAssertNil(VoiceNoteStructure.keep(raw: "hello", structured: "  ").raw)
    }
}
