import XCTest
@testable import BlurtCore

/// The recording's discard question (dogfood v0.9-2: drawn under its buttons, markers counted as snaps, Discard where
/// Finish had been).
final class RecordingDiscardTests: XCTestCase {
    func testMarkersAreNotSnaps() {
        XCTAssertEqual(RecordingDiscard.lost(stills: 0, markers: 0), .nothing)
        XCTAssertEqual(RecordingDiscard.lost(stills: 3, markers: 0), .snaps(3))
        XCTAssertEqual(RecordingDiscard.lost(stills: 0, markers: 2), .markers(2))
        // the dogfood take: 3 shots in the batch, 2 of them markers → "1 snap and 2 markers", not "3 snaps"
        XCTAssertEqual(RecordingDiscard.lost(stills: 1, markers: 2), .both(snaps: 1, markers: 2))
    }

    func testTheSafeAnswerIsWhereFinishWas() {
        XCTAssertEqual(RecordingDiscard.order.last, .keep)
        XCTAssertEqual(RecordingDiscard.order.first, .discard)
        XCTAssertEqual(Set(RecordingDiscard.order), Set(RecordingDiscard.Answer.allCases))
    }

    func testTheQuestionGetsItsOwnLineWhenItWouldRunUnderTheAnswers() {
        // en: "Discard this recording, with 1 snap and 2 markers?" (~330 pt) beside three buttons (~260 pt) in 480 pt
        XCTAssertTrue(RecordingDiscard.ownLine(question: 330, answers: 260, width: 480))
        // zh: "丢弃这段录屏？" (~100 pt) fits beside them
        XCTAssertFalse(RecordingDiscard.ownLine(question: 100, answers: 260, width: 480))
        XCTAssertTrue(RecordingDiscard.ownLine(question: 180, answers: 260, width: 480))   // 18+180+12+260+12 = 482
    }
}
