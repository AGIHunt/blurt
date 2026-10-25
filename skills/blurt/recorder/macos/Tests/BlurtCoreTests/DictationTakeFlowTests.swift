import XCTest
@testable import BlurtCore

/// A take between its stop and its text (docs/design/dictation.md §Takes in flight): pastes in order, the forgotten
/// hands-free take, the first-takes tips, recognition failures.
final class DictationTakeFlowTests: XCTestCase {
    func testPastesGoInTheOrderTheyWereSaid() {
        var q = DictationPasteQueue<String>()
        q.add("a")
        q.add("b")                       // a tap while "a" was still being structured started "b"
        q.markReady("b")                 // the short second take is done first
        XCTAssertNil(q.next())           // …but waits for the first
        q.markReady("a")
        XCTAssertEqual(q.next(), "a")
        XCTAssertNil(q.next())           // one paste at a time
        q.delivered("a")
        XCTAssertEqual(q.next(), "b")
        q.delivered("b")
        XCTAssertTrue(q.isEmpty)
    }

    func testADroppedTakeLetsTheNextOneGo() {
        var q = DictationPasteQueue<Int>()
        q.add(1); q.add(2)
        q.markReady(2)
        q.drop(1)                        // nothing heard / cancelled / failed
        XCTAssertEqual(q.next(), 2)
        XCTAssertEqual(q.last, 2)
        q.add(2)                         // never twice
        XCTAssertEqual(q.count, 1)
    }

    func testForgottenTakeIsRemindedAndCountedDown() {
        var r = DictationRunaway()
        var notices: [DictationRunaway.Notice] = []
        var t = 0.0
        // 6 s of speech, then silence until the limit (the dogfood repro)
        while t < 300 {
            if let n = r.feed(elapsed: t, speaking: t < 6, handsFree: true) { notices.append(n) }
            t += 0.5
        }
        XCTAssertEqual(notices, [.stillListening, .endsSoon])          // once each: no nagging every 20 s
        // speech again resets the quiet stretch: another reminder only after 20 more quiet seconds
        var s = DictationRunaway()
        XCTAssertNil(s.feed(elapsed: 19, speaking: false, handsFree: true))
        XCTAssertEqual(s.feed(elapsed: 20, speaking: false, handsFree: true), .stillListening)
        XCTAssertNil(s.feed(elapsed: 30, speaking: true, handsFree: true))
        XCTAssertNil(s.feed(elapsed: 49, speaking: false, handsFree: true))
        XCTAssertEqual(s.feed(elapsed: 50, speaking: false, handsFree: true), .stillListening)
        // push-to-talk: no reminder (the key is held), the countdown still comes
        var p = DictationRunaway()
        XCTAssertNil(p.feed(elapsed: 60, speaking: false, handsFree: false))
        XCTAssertEqual(p.feed(elapsed: 271, speaking: true, handsFree: false), .endsSoon)
    }

    func testEarClockCountsDownFromFourThirty() {
        XCTAssertEqual(DictationRunaway.clock(elapsed: 0).text, "0:00")
        XCTAssertEqual(DictationRunaway.clock(elapsed: 269.9).text, "4:29")
        XCTAssertFalse(DictationRunaway.clock(elapsed: 269.9).countdown)
        XCTAssertEqual(DictationRunaway.clock(elapsed: 270).text, "\u{2212}0:30")
        XCTAssertTrue(DictationRunaway.clock(elapsed: 270).countdown)
        XCTAssertEqual(DictationRunaway.clock(elapsed: 299.2).text, "\u{2212}0:01")
        XCTAssertEqual(DictationRunaway.clock(elapsed: 300).text, "\u{2212}0:00")
    }

    func testTipsAfterTheFirstTakes() {
        typealias T = DictationTip
        // chat apps: double-tap to send, five times, never right after the user sent
        XCTAssertEqual(T.next(chat: true, sendOn: true, sent: false, shown: [:]), .send)
        XCTAssertEqual(T.next(chat: true, sendOn: true, sent: false, shown: ["send": 4]), .send)
        XCTAssertNil(T.next(chat: true, sendOn: true, sent: false, shown: ["send": 5]))
        XCTAssertNil(T.next(chat: true, sendOn: true, sent: true, shown: [:]))
        XCTAssertNil(T.next(chat: true, sendOn: false, sent: false, shown: [:]))
        // elsewhere: nothing on the very first take, then ⇧ for a list once, ⌥⇧L once, then quiet
        XCTAssertNil(T.next(chat: false, sendOn: true, sent: false, shown: [:]))
        XCTAssertEqual(T.next(chat: false, sendOn: true, sent: false, shown: ["takes": 1]), .list)
        XCTAssertEqual(T.next(chat: false, sendOn: true, sent: false, shown: ["takes": 2, "list": 1]), .reformat)
        XCTAssertNil(T.next(chat: false, sendOn: true, sent: false, shown: ["takes": 3, "list": 1, "reformat": 1]))
    }

    func testRecognitionFailures() {
        XCTAssertEqual(DictationASRFailure(code: "model_missing"), .noModel)
        XCTAssertEqual(DictationASRFailure(code: "timeout"), .timedOut)
        XCTAssertEqual(DictationASRFailure(code: nil), .failed("error"))
        XCTAssertEqual(DictationASRFailure(code: "network").code, "network")
        // the server's time scales with the audio: a hung server is given up on in proportion, not after a flat minute
        XCTAssertEqual(DictationASRFailure.serverTimeout(audioSeconds: 0), 15)
        XCTAssertEqual(DictationASRFailure.serverTimeout(audioSeconds: 20), 45)
    }
}
