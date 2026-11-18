import XCTest
@testable import BlurtCore

/// Retry outside the notch: the menu bar's last-dictation row and Home's timeline (2026-11-16).
final class DictationRetryTests: XCTestCase {
    func ok(_ id: String, _ text: String) -> DictationEntry {
        DictationEntry(id: id, time: Date(), app: "Notes", bundle: nil, duration: 2, raw: text, polished: nil, text: text,
                       model: nil, fellBack: false, reason: nil, insert: "pasted")
    }
    func failed(_ id: String, _ reason: String) -> DictationEntry {
        DictationEntry(id: id, time: Date(), app: "Notes", bundle: nil, duration: 12, raw: "", polished: nil, text: "",
                       model: nil, fellBack: false, reason: reason, insert: "none", audio: "audio/\(id).wav")
    }
    let kept: (DictationEntry) -> Bool = { _ in true }
    let gone: (DictationEntry) -> Bool = { _ in false }

    func testTheMenuRetriesTheLastTakeWhenItFailed() {
        let es = [failed("f", "asr_failed:timeout"), ok("a", "hello")]
        XCTAssertEqual(DictationRetry.menuRow(es, audioKept: kept), .retry("f"))
        XCTAssertEqual(DictationRetry.menuRow([failed("i", DictationHistory.interruptedReason)], audioKept: kept), .retry("i"))
    }

    func testACancelledOrAudiolessTakeLeavesCopyOfTheLastText() {
        XCTAssertEqual(DictationRetry.menuRow([failed("c", DictationHistory.cancelledReason), ok("a", "hello")], audioKept: kept), .copy("a"))
        XCTAssertEqual(DictationRetry.menuRow([failed("f", "asr_failed:timeout"), ok("a", "hello")], audioKept: gone), .copy("a"))
        XCTAssertNil(DictationRetry.menuRow([failed("c", DictationHistory.cancelledReason)], audioKept: kept))
        XCTAssertNil(DictationRetry.menuRow([], audioKept: kept))
    }

    func testHomeListsFailedTakesButNotCancelledOnes() {
        XCTAssertTrue(DictationRetry.onHome(ok("a", "hello"), audioKept: gone))
        XCTAssertTrue(DictationRetry.onHome(failed("f", "asr_failed:timeout"), audioKept: kept))
        XCTAssertFalse(DictationRetry.onHome(failed("f", "asr_failed:timeout"), audioKept: gone))
        XCTAssertFalse(DictationRetry.onHome(failed("c", DictationHistory.cancelledReason), audioKept: kept))
        XCTAssertFalse(DictationRetry.onHome(ok("e", "  "), audioKept: kept))
    }
}
