// BlurtCore/NothingHeard.swift: "nothing heard" names the mic, and tells a silent mic from a quiet take.
import XCTest
@testable import BlurtCore

final class NothingHeardTests: XCTestCase {
    func testAMicThatNeverLeftTheFloorIsSilent() {
        XCTAssertEqual(NothingHeard.why(levels: [Float](repeating: 0, count: 40)), .silentMic)
        XCTAssertEqual(NothingHeard.why(levels: [0, 0.004, 0, 0.002, 0, 0]), .silentMic)
    }

    func testRoomNoiseOrABlinkIsNoSpeech() {
        XCTAssertEqual(NothingHeard.why(levels: [0, 0.05, 0.02, 0, 0, 0.1]), .noSpeech)     // it heard the room
        XCTAssertEqual(NothingHeard.why(levels: [0, 0]), .noSpeech)                         // too short to tell
        XCTAssertEqual(NothingHeard.why(levels: []), .noSpeech)
    }

    func testTheLineNamesTheMicWhenItKnowsIt() {
        XCTAssertEqual(NothingHeard.key(.silentMic, hasName: true), "dictation.toast.nothing.silent")
        XCTAssertEqual(NothingHeard.key(.noSpeech, hasName: true), "dictation.toast.nothing.named")
        XCTAssertEqual(NothingHeard.key(.silentMic, hasName: false), "dictation.toast.nothing")
    }
}
