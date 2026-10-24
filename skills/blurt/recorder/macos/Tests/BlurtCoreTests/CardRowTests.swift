// BlurtCore/CardRow.swift: the hanging cards' row (newest first, at most 5, a "+N" tile), their threads, when they come
// down and go up, Esc, the keyboard's stops, the hover note, the deferred click and the Undo window of a delete.
import XCTest
@testable import BlurtCore

final class CardRowTests: XCTestCase {
    let shot: CGFloat = 112, voice: CGFloat = 168, gap: CGFloat = 12

    func layout(_ widths: [CGFloat], centre: CGFloat = 720, screen: CGFloat = 1440) -> CardRow.Layout {
        CardRow.layout(widths: widths, tile: shot, gap: gap, centre: centre, bounds: 12...(screen - 12))
    }

    func testNewestFirstLeftToRight() {
        let l = layout([shot, shot, shot])
        XCTAssertEqual(l.shown, [2, 1, 0], "the newest card hangs on the left")
        XCTAssertEqual(l.more, 0)
        XCTAssertNil(l.tileX)
        XCTAssertEqual(l.centres, l.centres.sorted())
        XCTAssertEqual((l.span.lowerBound + l.span.upperBound) / 2, 720, accuracy: 0.01, "centred under the island")
    }

    /// The audit's 16 cards: the 5 newest hang, the other 11 wait behind "+11" — no rotating pages, nothing mixed.
    func testManyCardsShowTheNewestFiveAndACount() {
        let l = layout(Array(repeating: shot, count: 16))
        XCTAssertEqual(l.shown, [15, 14, 13, 12, 11])
        XCTAssertEqual(l.more, 11)
        XCTAssertNotNil(l.tileX)
        XCTAssertGreaterThan(l.tileX!, l.centres.last!, "the tile closes the row, after the oldest card that hangs")
        XCTAssertLessThanOrEqual(l.span.upperBound - l.span.lowerBound, CardRow.maxWidth, "no curtain across the screen")
    }

    func testVoiceCardsAreWiderSoFewerHang() {
        let l = layout(Array(repeating: voice, count: 8))
        XCTAssertLessThan(l.shown.count, CardRow.maxShown)
        XCTAssertLessThanOrEqual(l.span.upperBound - l.span.lowerBound, CardRow.maxWidth)
        XCTAssertEqual(l.shown.count + l.more, 8)
    }

    func testNeverOffTheScreen() {
        let l = layout(Array(repeating: shot, count: 9), centre: 40, screen: 1280)
        XCTAssertGreaterThanOrEqual(l.span.lowerBound, 12)
        let narrow = layout(Array(repeating: voice, count: 6), centre: 300, screen: 600)
        XCTAssertLessThanOrEqual(narrow.span.upperBound, 588)
        XCTAssertGreaterThanOrEqual(narrow.shown.count, 1)
    }

    func testEmpty() {
        XCTAssertEqual(layout([]), .empty)
    }

    func testThreadsHangStraightWhenTheRowFitsUnderTheIsland() {
        XCTAssertEqual(CardRow.threadX(700, row: 650...790, edge: 620...820), 700)
        XCTAssertEqual(CardRow.threadX(600, row: 560...700, edge: 620...820), 620, "clamped to the island's edge")
    }

    func testWideRowMapsOntoTheEdgeInOrder() {
        let row: ClosedRange<CGFloat> = 350...1090, edge: ClosedRange<CGFloat> = 620...820
        let xs: [CGFloat] = [406, 530, 654, 778, 902, 1034]
        let ts = xs.map { CardRow.threadX($0, row: row, edge: edge) }
        XCTAssertEqual(ts, ts.sorted(), "threads keep their order and never cross")
        XCTAssertTrue(ts.allSatisfy { edge.contains($0) })
        let steps = zip(ts.dropFirst(), ts).map { $0 - $1 }
        XCTAssertTrue(steps.allSatisfy { $0 > 20 }, "spread along the edge, not bunched at its two corners")
    }

    func testDwellBeforeTheCardsComeDown() {
        XCTAssertFalse(CardReveal.dwelled(since: nil, now: 10))
        XCTAssertFalse(CardReveal.dwelled(since: 10, now: 10.05), "brushing past the notch drops nothing")
        XCTAssertTrue(CardReveal.dwelled(since: 10, now: 10 + CardReveal.dwell + 0.001))
        XCTAssertGreaterThanOrEqual(CardReveal.dwell, 0.15)
        XCTAssertLessThanOrEqual(CardReveal.dwell, 0.2)
        XCTAssertLessThan(CardReveal.away, 0.4, "they go up again quickly")
    }

    func testEscIsOnlyTakenWhileThePointerIsOnCardsBroughtDownOnPurpose() {
        XCTAssertFalse(CardReveal.holdsEsc(sticky: true, pointerIn: false, keyboard: false), "⌥⇧H, then Esc in another app: theirs")
        XCTAssertTrue(CardReveal.holdsEsc(sticky: true, pointerIn: true, keyboard: false))
        XCTAssertFalse(CardReveal.holdsEsc(sticky: true, pointerIn: true, keyboard: true), "the panel has the keyboard: no hotkey")
        XCTAssertFalse(CardReveal.holdsEsc(sticky: false, pointerIn: true, keyboard: false))
    }

    func testFirstHintOnce() {
        XCTAssertTrue(CardReveal.firstHint(alreadyShown: false, isCard: true, recording: false))
        XCTAssertFalse(CardReveal.firstHint(alreadyShown: true, isCard: true, recording: false))
        XCTAssertFalse(CardReveal.firstHint(alreadyShown: false, isCard: false, recording: false), "filed straight away: no card")
        XCTAssertFalse(CardReveal.firstHint(alreadyShown: false, isCard: true, recording: true))
    }

    func testKeyboardStops() {
        XCTAssertEqual(CardFocus.move(nil, by: 1, cards: 3, tile: true), 0, "starts on the newest card")
        XCTAssertEqual(CardFocus.move(0, by: 1, cards: 3, tile: true), 1)
        XCTAssertEqual(CardFocus.move(2, by: 1, cards: 3, tile: true), 3, "then the +N tile")
        XCTAssertEqual(CardFocus.move(3, by: 1, cards: 3, tile: true), 3, "stays at the end")
        XCTAssertEqual(CardFocus.move(0, by: -1, cards: 3, tile: false), 0)
        XCTAssertNil(CardFocus.move(nil, by: 1, cards: 0, tile: false))
        XCTAssertEqual(CardFocus.clamp(3, cards: 2, tile: false), 1, "the last card was deleted: the one before it")
        XCTAssertNil(CardFocus.clamp(0, cards: 0, tile: false))
    }

    func testHoverNoteOnlyAddsWhatTheCardCannotShow() {
        XCTAssertNil(CardTip.content(truncated: false, playable: false), "the caption says it all: no note")
        XCTAssertEqual(CardTip.content(truncated: true, playable: false), .init(text: true, play: false))
        XCTAssertEqual(CardTip.content(truncated: false, playable: true), .init(text: false, play: true), "just the play button")
        XCTAssertEqual(CardTip.content(truncated: true, playable: true), .init(text: true, play: true))
    }

    func testDoubleClickNeverCopiesFirst() {
        var c = DeferredClick<Int>()
        XCTAssertEqual(c.click(7, count: 1, at: 1.0, interval: 0.4), .copy(at: 1.4))
        XCTAssertNil(c.fire(at: 1.2), "not yet: a second click may still come")
        XCTAssertEqual(c.click(7, count: 2, at: 1.25, interval: 0.4), .edit)
        XCTAssertNil(c.fire(at: 2.0), "the double-click cancelled the copy")
    }

    func testSingleClickCopiesOnceTheIntervalHasPassed() {
        var c = DeferredClick<Int>()
        _ = c.click(3, count: 1, at: 5, interval: 0.3)
        XCTAssertEqual(c.fire(at: 5.3), 3)
        XCTAssertNil(c.fire(at: 5.4), "once")
        _ = c.click(4, count: 1, at: 6, interval: 0.3)
        c.cancel()
        XCTAssertNil(c.fire(at: 7))
    }

    func testDeletedFilesOutlastTheUndo() {
        XCTAssertGreaterThan(CardDelete.recycleAfter, CardDelete.undoSeconds)
        XCTAssertGreaterThanOrEqual(CardDelete.undoSeconds, 3)
    }
}
