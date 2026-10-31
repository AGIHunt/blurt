// BlurtCore/ToastQueue.swift: the island's toasts — newest first (older plain replies superseded), replaced by key,
// stale ones dropped, at least 5 s and paused while pointed at, a pushed-out Undo or question comes back for the time
// it had left, every exit but acting on it reported to onGone, a body click acts only on a line without a button.
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
        XCTAssertTrue(q.waiting.isEmpty, "B, older than C, is superseded with it")
        var seen: [String] = []
        var t = 1.3
        while t <= 12 { q.tick(now: t, paused: false, canShow: { _ in true }); if let c = q.current?.text, seen.last != c { seen.append(c) }; t += 1.0 / 60 }
        XCTAssertEqual(seen, ["C"], "B never goes up after C (the past out of order)")
    }

    /// An older reply that was held back by `canShow` (the open island) isn't superseded: it still waits its turn.
    func testAHeldBackReplyIsNotSuperseded() {
        let q = Q()
        q.post(entry("Filed to Alpha"), now: 0, canShowNow: false)
        q.post(entry("Copied"), now: 0.1)
        XCTAssertEqual(q.current?.text, "Copied")
        XCTAssertTrue(q.waiting.isEmpty, "both could show: the older plain one is superseded")
        let q2 = Q()
        q2.post(entry("Filed to Alpha", key: "file"), now: 0, canShowNow: false)
        q2.post(entry("Deleted · Undo", key: "delete", actionable: true), now: 0.1, canShowNow: false)
        run(q2, from: 0.1, to: 0.3, canShow: { $0.key == "delete" })
        XCTAssertEqual(q2.current?.text, "Deleted · Undo")
        XCTAssertEqual(q2.waiting.map(\.text), ["Filed to Alpha"])
    }

    /// An older Undo is not a plain line: it still comes after the newer reply.
    func testAnOlderUndoIsNotSuperseded() {
        let q = Q()
        q.post(entry("A", seconds: 6), now: 0)
        q.post(entry("Deleted · Undo", key: "delete", actionable: true), now: 0.1)
        q.post(entry("C"), now: 0.2)
        run(q, from: 0.2, to: 1.3)
        XCTAssertEqual(q.current?.text, "C")
        XCTAssertEqual(q.waiting.map(\.text), ["Deleted · Undo"])
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
        // for the time it had left (3.5 s), not a fresh 5 s
        run(q, from: 6.7, to: 9.9)
        XCTAssertEqual(q.current?.text, "Deleted · Undo")
        run(q, from: 9.9, to: 10.5)
        XCTAssertNil(q.current)
    }

    /// Every toast that goes without being acted on is reported once; one acted on (dismissCurrent) is not.
    func testOnGoneReportsEveryExitButActingOnIt() {
        let q = Q()
        var gone: [String] = []
        q.onGone = { gone.append($0.text) }
        q.post(entry("Page · Undo", key: "page", actionable: true), now: 0)
        q.post(entry("Page again · Undo", key: "page", actionable: true), now: 0.5)        // replaced
        XCTAssertEqual(gone, ["Page · Undo"])
        run(q, from: 0.5, to: 6)                                                           // expired
        XCTAssertEqual(gone, ["Page · Undo", "Page again · Undo"])
        q.post(entry("Stale"), now: 6, canShowNow: false)
        run(q, from: 6, to: 6 + Q.staleReply + 1, canShow: { _ in false })                 // stale
        XCTAssertEqual(gone.last, "Stale")
        q.post(entry("Dictation", key: "d"), now: 20)
        q.drop(key: "d")                                                                   // dropped
        XCTAssertEqual(gone.last, "Dictation")
        q.post(entry("Acted · Undo", actionable: true), now: 30)
        q.dismissCurrent()                                                                 // acted on
        XCTAssertEqual(gone.last, "Dictation")
        q.post(entry("Superseded"), now: 40)
        run(q, from: 40, to: 40.5)
        q.post(entry("Newer"), now: 40.5)
        run(q, from: 40.5, to: 41.2)                                                       // pushed out, not coming back
        XCTAssertEqual(gone.last, "Superseded")
        XCTAssertEqual(gone.filter { $0 == "Superseded" }.count, 1)
    }

    /// A click on a toast's body: only a line without a button acts; with a button, it just opens the island.
    func testBodyClickActsOnlyWithoutAButton() {
        XCTAssertEqual(Q.bodyClick(hasButton: true, hasAction: true), .open, "an Undo runs only from its button")
        XCTAssertEqual(Q.bodyClick(hasButton: false, hasAction: true), .act)
        XCTAssertEqual(Q.bodyClick(hasButton: false, hasAction: false), .open)
    }

    func testAQuestionComesBackUntilAnswered() {
        let q = Q()
        q.post(entry("Record the last area?", seconds: .infinity, question: true), now: 0)
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

    /// The dogfood's cloud-polish reminder (two answers, 10 s) sat on the notch for minutes: two answers are not
    /// "waits forever". It goes by itself after its seconds, as its "no" (onGone), and a newer reply doesn't bring it
    /// back after that.
    func testATimedQuestionGoesByItself() {
        let q = Q()
        var gone: [String] = []
        q.onGone = { gone.append($0.text) }
        q.post(entry("Turn on cloud polish?", seconds: 10, actionable: true, question: true), now: 0)
        XCTAssertFalse(q.current!.sticky)
        run(q, from: 0, to: 9.9)
        XCTAssertEqual(q.current?.text, "Turn on cloud polish?")
        run(q, from: 9.9, to: 10.2)
        XCTAssertNil(q.current, "gone after its 10 s")
        XCTAssertEqual(gone, ["Turn on cloud polish?"], "going unanswered is reported once (its no)")
        q.post(entry("Copied"), now: 11)
        run(q, from: 11, to: 30)
        XCTAssertNil(q.current)
        XCTAssertTrue(q.waiting.isEmpty, "it never comes back")
    }

    /// Pushed out by a newer reply, a timed question comes back only for the time it had left, and a timed question
    /// waiting behind something goes stale like an Undo.
    func testATimedQuestionPushedOutComesBackForItsTimeLeft() {
        let q = Q()
        q.post(entry("Always make lists in Safari?", seconds: 12, actionable: true, question: true), now: 0)
        run(q, from: 0, to: 2)
        q.post(entry("Reformatted as Verbatim"), now: 2)
        run(q, from: 2, to: 3.2)
        XCTAssertEqual(q.current?.text, "Reformatted as Verbatim")
        XCTAssertEqual(q.waiting.map(\.text), ["Always make lists in Safari?"])
        run(q, from: 3.2, to: 8.3)
        XCTAssertEqual(q.current?.text, "Always make lists in Safari?")
        run(q, from: 8.3, to: 30)
        XCTAssertNil(q.current, "it had about 10 s left, not forever")

        let q2 = Q()
        q2.post(entry("Always make lists in Safari?", seconds: 12, actionable: true, question: true), now: 0, canShowNow: false)
        run(q2, from: 0, to: Q.staleReply + 0.5, canShow: { _ in false })
        XCTAssertTrue(q2.waiting.isEmpty, "a timed question that never got the island goes stale")
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
        XCTAssertEqual(q.waiting.map(\.text), ["Filed to Alpha"], "held back, not superseded")
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
