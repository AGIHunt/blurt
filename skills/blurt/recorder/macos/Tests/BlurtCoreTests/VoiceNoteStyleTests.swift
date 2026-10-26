import XCTest
@testable import BlurtCore

/// ⇧ alone toggles a voice note's Structured, as it does a dictation's (v0.9-userfix).
final class VoiceNoteStyleTests: XCTestCase {
    func toggles(_ script: String, holding: Set<String> = []) -> Int {
        var s = LoneShift()
        return DictationTrigger.parse(script, holding: holding).filter { s.handle($0) }.count
    }

    func testALoneShiftTapToggles() {
        XCTAssertEqual(toggles("shift-down@0 shift-up@120"), 1)
        XCTAssertEqual(toggles("rshift-down@0 rshift-up@90"), 1)
        XCTAssertEqual(toggles("shift-down@0 shift-up@100 shift-down@400 shift-up@480"), 2)
    }

    func testNotALoneShift() {
        // ⌥⇧V itself: ⇧ goes down with ⌥ held, in either order of letting go
        XCTAssertEqual(toggles("lopt-down@0 shift-down@30 key:9@60 shift-up@120 lopt-up@150"), 0)
        XCTAssertEqual(toggles("lopt-down@0 shift-down@30 key:9@60 lopt-up@100 shift-up@150"), 0)
        // a capital letter, a ⇧-click, a finger resting on it
        XCTAssertEqual(toggles("shift-down@0 key:0@50 shift-up@100"), 0)
        XCTAssertEqual(toggles("shift-down@0 click@50 shift-up@100"), 0)
        XCTAssertEqual(toggles("shift-down@0 shift-up@1500"), 0)
        // ⌘⇧ (a shortcut)
        XCTAssertEqual(toggles("cmd-down@0 shift-down@20 shift-up@80 cmd-up@100"), 0)
    }

    func testTheSameChangeTwiceCountsOnce() {
        var s = LoneShift()
        let down = DictationTrigger.Event.flags(keyCode: 56, flags: 0x2_0000, time: 1.0)
        let up = DictationTrigger.Event.flags(keyCode: 56, flags: 0, time: 1.1)
        let upAgain = DictationTrigger.Event.flags(keyCode: 56, flags: 0, time: 1.11)
        XCTAssertFalse(s.handle(down))
        XCTAssertFalse(s.handle(down))
        XCTAssertTrue(s.handle(up))
        XCTAssertFalse(s.handle(upAgain))
        // the second listener's copies arriving after the first's whole tap: still one toggle
        var t = LoneShift()
        XCTAssertEqual([down, up, down, upAgain].filter { t.handle($0) }.count, 1)
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
