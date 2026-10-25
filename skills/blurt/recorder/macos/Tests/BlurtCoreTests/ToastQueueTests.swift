// BlurtCore/ToastQueue.swift: the island's toasts — newest first, replaced by key, stale ones dropped, at least 5 s and
// paused while pointed at, a pushed-out Undo or question comes back.
import XCTest
@testable import BlurtCore

final class ToastQueueTests: XCTestCase {
    typealias Q = ToastQueue<String>

    func entry(_ text: String, key: String? = nil, kind: Q.Kind = .reply, seconds: Double = 2.4,
               actionable: Bool = false, question: Bool = false) -> Q.Entry {
        Q.Entry(text, text: text, key: key, kind: kind, seconds: seconds, actionable: actionable, question: question)
    }

    /// Runs the clock from `from` to `to` in 1/60 s ticks.
    func run(_ q: Q, from: Double, to: Double, paused: Bool = false, canShow: (Q.Entry) -> Bool = { _ in true }) {
        var t = from
        while t <= to { q.tick(now: t, paused: paused, canShow: canShow); t += 1.0 / 60 }
    }

    func testFirstToastShowsAtOnce() {
        let q = Q()
        XCTAssertEqual(q.post(entry("Copied"), now: 0), .shown)
        XCTAssertEqual(q.current?.text, "Copied")
    }

    /// The dogfood's ⌥⇧L twice: the second "Reformatted as …" (same key) replaces the first at once, with its own Undo.
    func testSameKeyReplacesTheOneShowingAtOnce() {
        let q = Q()
        q.post(entry("Reformatted as Structured", key: "dictation", actionable: true), now: 0)
        run(q, from: 0, to: 0.3)
        XCTAssertEqual(q.post(entry("Reformatted as Verbatim", key: "dictation", actionable: true), now: 0.3), .replaced)
        XCTAssertEqual(q.current?.text, "Reformatted as Verbatim")
        XCTAssertTrue(q.waiting.isEmpty, "nothing about the old state waits behind it")
    }

    /// A newer reply doesn't wait out the whole of an older one: it goes up once that one has been readable for 1 s.
    func testNewestReplyTakesTheSlotAfterMinShown() {
        let q = Q()
        q.post(entry("Moved to Alpha"), now: 0)
        run(q, from: 0, to: 0.2)
        XCTAssertEqual(q.post(entry("Copied"), now: 0.2), .queued)
        run(q, from: 0.2, to: 0.9)
        XCTAssertEqual(q.current?.text, "Moved to Alpha", "the first stays readable for a moment")
        run(q, from: 0.9, to: 1.2)
        XCTAssertEqual(q.current?.text, "Copied")
        XCTAssertTrue(q.waiting.isEmpty, "a plain line that was superseded is not shown again")
    }

    func testWaitingRepliesAreTakenNewestFirst() {
        let q = Q()
        q.post(entry("A", seconds: 6), now: 0)
        run(q, from: 0, to: 0.1)
        q.post(entry("B"), now: 0.1)
        q.post(entry("C"), now: 0.2)
        run(q, from: 0.2, to: 1.3)
        XCTAssertEqual(q.current?.text, "C")
    }

    /// "Nothing to reformat yet" no longer waits behind the launch welcome; the welcome comes back after it.
    func testRepliesGoAheadOfPassiveLinesWhichComeBack() {
        let q = Q()
        q.post(entry("Welcome to Blurt", kind: .passive, seconds: 6), now: 0)
        run(q, from: 0, to: 1.5)
        q.post(entry("Nothing to reformat yet"), now: 1.5)
        run(q, from: 1.5, to: 1.6)
        XCTAssertEqual(q.current?.text, "Nothing to reformat yet")
        XCTAssertEqual(q.waiting.map(\.text), ["Welcome to Blurt"], "the welcome is still to come")
        run(q, from: 1.6, to: 6.8)
        XCTAssertEqual(q.current?.text, "Welcome to Blurt")
    }

    func testPassiveLinesWaitInOrderBehindReplies() {
        let q = Q()
        q.post(entry("Copied"), now: 0)
        q.post(entry("Job one done", kind: .passive), now: 0.1)
        q.post(entry("Job two done", kind: .passive), now: 0.2)
        run(q, from: 0, to: 0.5)
        XCTAssertEqual(q.current?.text, "Copied", "a passive line never pushes a reply out")
        run(q, from: 0.5, to: 5.2)
        XCTAssertEqual(q.current?.text, "Job one done")
    }

    /// An Undo pushed out early comes back after the newer toast, with the time it had left.
    func testAPushedOutUndoComesBack() {
        let q = Q()
        q.post(entry("Deleted · Undo", key: "delete", seconds: 5, actionable: true), now: 0)
        run(q, from: 0, to: 1.5)
        q.post(entry("Copied"), now: 1.5)
        run(q, from: 1.5, to: 1.6)
        XCTAssertEqual(q.current?.text, "Copied")
        XCTAssertEqual(q.waiting.first?.text, "Deleted · Undo")
        XCTAssertEqual(q.waiting.first?.seconds ?? 0, 3.5, accuracy: 0.1)
        run(q, from: 1.6, to: 6.7)
        XCTAssertEqual(q.current?.text, "Deleted · Undo")
    }

    func testAQuestionComesBackUntilAnswered() {
        let q = Q()
        q.post(entry("Record the last area?", question: true), now: 0)
        run(q, from: 0, to: 30)
        XCTAssertEqual(q.current?.text, "Record the last area?", "a question stays until it is answered")
        q.post(entry("Copied"), now: 30)
        run(q, from: 30, to: 31.2)
        XCTAssertEqual(q.current?.text, "Copied")
        run(q, from: 31.2, to: 50)
        XCTAssertEqual(q.current?.text, "Record the last area?", "a question never goes stale")
        q.dismissCurrent()
        XCTAssertNil(q.current)
    }

    /// A reply that couldn't go up for a while (the island was open) describes the past by then: dropped.
    func testStaleRepliesAreDropped() {
        let q = Q()
        q.post(entry("Sent"), now: 0, canShowNow: false)
        run(q, from: 0, to: Q.staleReply + 0.5, canShow: { _ in false })
        XCTAssertTrue(q.waiting.isEmpty)
        run(q, from: Q.staleReply + 0.5, to: Q.staleReply + 1)
        XCTAssertNil(q.current)
    }

    func testPassiveLinesWaitLonger() {
        let q = Q()
        q.post(entry("Organizing done", kind: .passive), now: 0, canShowNow: false)
        run(q, from: 0, to: 20, canShow: { _ in false })
        XCTAssertEqual(q.waiting.count, 1)
        run(q, from: 20, to: 20.1)
        XCTAssertEqual(q.current?.text, "Organizing done")
    }

    /// Every toast stays at least 5 s (an Undo window is never shorter), whatever it asked for.
    func testAtLeastFiveSeconds() {
        let q = Q()
        q.post(entry("Discarded · Undo", seconds: 3, actionable: true), now: 0)
        run(q, from: 0, to: 4.9)
        XCTAssertNotNil(q.current)
        run(q, from: 4.9, to: 5.1)
        XCTAssertNil(q.current)
    }

    /// The pointer on it stops the clock — and it doesn't give way to a newer one meanwhile.
    func testPausedWhilePointedAt() {
        let q = Q()
        q.post(entry("Deleted · Undo", actionable: true), now: 0)
        run(q, from: 0, to: 4)
        run(q, from: 4, to: 20, paused: true)
        XCTAssertEqual(q.current?.text, "Deleted · Undo")
        q.post(entry("Copied"), now: 20)
        run(q, from: 20, to: 22, paused: true)
        XCTAssertEqual(q.current?.text, "Deleted · Undo", "nothing swaps under the pointer")
        run(q, from: 22, to: 23.5)
        XCTAssertEqual(q.current?.text, "Copied")
    }

    func testDropForgetsAKind() {
        let q = Q()
        q.post(entry("Reformatted", key: "dictation"), now: 0)
        q.post(entry("Make a list?", key: "dictation"), now: 0.1)
        q.post(entry("Copied"), now: 0.2)
        q.drop(key: "dictation")
        XCTAssertNil(q.current)
        XCTAssertEqual(q.waiting.map(\.text), ["Copied"])
    }

    func testTheSameTextRestartsTheClockInsteadOfQueueing() {
        let q = Q()
        q.post(entry("Copied"), now: 0)
        run(q, from: 0, to: 4)
        XCTAssertEqual(q.post(entry("Copied"), now: 4), .refreshed)
        run(q, from: 4, to: 8)
        XCTAssertEqual(q.current?.text, "Copied")
        XCTAssertTrue(q.waiting.isEmpty)
    }

    /// The open island takes only the toasts meant to go over it; the others wait (and aren't skipped over).
    func testCanShowGatesWhatGoesUp() {
        let q = Q()
        q.post(entry("Filed to Alpha"), now: 0, canShowNow: false)
        q.post(entry("Deleted · Undo", key: "delete", actionable: true), now: 0.1, canShowNow: false)
        run(q, from: 0.1, to: 0.3, canShow: { $0.key == "delete" })
        XCTAssertEqual(q.current?.text, "Deleted · Undo")
    }

    /// The display link idles while nothing shows: a long gap before the next tick is not time on screen.
    func testAGapInTheTicksIsNotTimeOnScreen() {
        let q = Q()
        q.tick(now: 0, paused: false, canShow: { _ in true })
        q.post(entry("Copied"), now: 100)
        q.tick(now: 100, paused: false, canShow: { _ in true })
        XCTAssertEqual(q.current?.text, "Copied")
    }
}
