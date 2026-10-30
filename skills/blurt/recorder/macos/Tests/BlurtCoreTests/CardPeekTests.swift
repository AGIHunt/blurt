// BlurtCore/CardPeek.swift: the bigger picture under a hovered hanging card — when it shows (a rest, then warm
// switching, gone off the row), how big it is, where it goes, and its entrance with and without Reduce Motion.
import XCTest
@testable import BlurtCore

final class CardPeekTests: XCTestCase {
    typealias Peek = CardPeek<Int>

    func testShowsOnlyAfterARest() {
        var p = Peek()
        p.pointer(on: 1, onRow: true, now: 10)
        XCTAssertNil(p.shown(now: 10.1))
        XCTAssertTrue(p.waiting(now: 10.1))
        XCTAssertNil(p.shown(now: 10.29))
        XCTAssertEqual(p.shown(now: 10.3), 1)
        XCTAssertFalse(p.waiting(now: 10.3))
    }

    /// Sweeping across the row: each card restarts the wait, so nothing flashes on the way.
    func testSweepingFlashesNothing() {
        var p = Peek()
        for (i, t) in [(1, 0.0), (2, 0.1), (3, 0.2), (4, 0.28)] {
            p.pointer(on: i, onRow: true, now: t)
            XCTAssertNil(p.shown(now: t), "card \(i) while sweeping")
        }
        XCTAssertNil(p.shown(now: 0.5))
        XCTAssertEqual(p.shown(now: 0.6), 4, "the card the pointer stopped on, a rest after it got there")
    }

    /// Once it shows, another card on the row shows at once (tooltip behaviour), however quickly it is reached.
    func testWarmSwitchIsInstant() {
        var p = Peek()
        p.pointer(on: 1, onRow: true, now: 0)
        p.pointer(on: 1, onRow: true, now: 0.4)
        XCTAssertEqual(p.shown(now: 0.4), 1)
        p.pointer(on: 2, onRow: true, now: 0.45)
        XCTAssertEqual(p.shown(now: 0.45), 2)
        XCTAssertTrue(p.warm)
        p.pointer(on: 3, onRow: true, now: 0.46)
        XCTAssertEqual(p.shown(now: 0.46), 3)
    }

    /// Warm even when the first pointer event after the rest is the move to the next card (no event in between).
    func testWarmWithoutAnEventAtTheRest() {
        var p = Peek()
        p.pointer(on: 1, onRow: true, now: 0)
        XCTAssertEqual(p.shown(now: 0.35), 1)
        p.pointer(on: 2, onRow: true, now: 0.5)
        XCTAssertEqual(p.shown(now: 0.5), 2)
    }

    /// The gap between two cards: the last preview stays (no blink) once warm; before that, the wait starts over.
    func testGapKeepsTheLastOnceWarm() {
        var p = Peek()
        p.pointer(on: 1, onRow: true, now: 0)
        p.pointer(on: nil, onRow: true, now: 0.5)
        XCTAssertEqual(p.shown(now: 0.5), 1)
        p.pointer(on: 2, onRow: true, now: 0.55)
        XCTAssertEqual(p.shown(now: 0.55), 2)

        var cold = Peek()
        cold.pointer(on: 1, onRow: true, now: 0)
        cold.pointer(on: nil, onRow: true, now: 0.2)
        XCTAssertNil(cold.shown(now: 0.4), "a card left before its rest doesn't show from the gap")
        cold.pointer(on: 1, onRow: true, now: 0.4)
        XCTAssertNil(cold.shown(now: 0.6))
        XCTAssertEqual(cold.shown(now: 0.75), 1)
    }

    /// Off the row: gone at once, and the next card waits again.
    func testLeavingTheRowEndsItAndCoolsDown() {
        var p = Peek()
        p.pointer(on: 1, onRow: true, now: 0)
        XCTAssertEqual(p.shown(now: 0.4), 1)
        p.pointer(on: nil, onRow: false, now: 0.5)
        XCTAssertNil(p.shown(now: 0.5))
        XCTAssertFalse(p.warm)
        p.pointer(on: 2, onRow: true, now: 0.6)
        XCTAssertNil(p.shown(now: 0.6), "cold again: the rest applies")
        XCTAssertEqual(p.shown(now: 0.9), 2)
    }

    // MARK: size

    func testSizeIsCappedAtTheMaxWidthAspectKept() {
        let s = CardPeekLayout.size(picture: CGSize(width: 1440, height: 900), below: 2000)!
        XCTAssertEqual(s.width, 360)
        XCTAssertEqual(s.height, 225)
    }

    func testTallPictureIsCappedByTheScreenUnderTheRow() {
        // 40 % of 500 pt under the row: 200 pt tall at most
        let s = CardPeekLayout.size(picture: CGSize(width: 400, height: 1000), below: 500)!
        XCTAssertEqual(s.height, 200)
        XCTAssertEqual(s.width, 80)
        XCTAssertEqual(s.width / s.height, 0.4, accuracy: 0.01)
    }

    func testRoomInTheWindowCapsItToo() {
        let s = CardPeekLayout.size(picture: CGSize(width: 800, height: 800), below: 2000, room: 150)!
        XCTAssertEqual(s, CGSize(width: 150, height: 150))
    }

    func testSmallPictureIsNeverEnlarged() {
        XCTAssertEqual(CardPeekLayout.size(picture: CGSize(width: 120, height: 80), below: 900), CGSize(width: 120, height: 80))
    }

    func testNoPictureOrNoRoom() {
        XCTAssertNil(CardPeekLayout.size(picture: .zero, below: 900), "a voice card has no picture")
        XCTAssertNil(CardPeekLayout.size(picture: CGSize(width: 800, height: 600), below: 100), "40 pt is too little")
        XCTAssertNil(CardPeekLayout.size(picture: CGSize(width: 800, height: 600), below: 900, room: 20))
    }

    // MARK: place

    func testCentredOnTheCardWhereItFits() {
        XCTAssertEqual(CardPeekLayout.centreX(card: 700, width: 384, screen: 0...1440), 700)
    }

    func testClampedToTheScreen() {
        XCTAssertEqual(CardPeekLayout.centreX(card: 40, width: 384, screen: 0...1440), 12 + 192)
        XCTAssertEqual(CardPeekLayout.centreX(card: 1430, width: 384, screen: 0...1440), 1440 - 12 - 192)
        XCTAssertEqual(CardPeekLayout.centreX(card: 100, width: 2000, screen: 0...1440), 720, "wider than the screen: its middle")
    }

    // MARK: entrance

    func testEntranceFadesAndGrowsSlightly() {
        let start = CardPeekLayout.entrance(elapsed: 0, reduceMotion: false)
        XCTAssertEqual(start.opacity, 0)
        XCTAssertEqual(start.scale, CardPeekLayout.entranceScale)
        let end = CardPeekLayout.entrance(elapsed: 1, reduceMotion: false)
        XCTAssertEqual(end.opacity, 1)
        XCTAssertEqual(end.scale, 1)
        let mid = CardPeekLayout.entrance(elapsed: 0.07, reduceMotion: false)
        XCTAssertGreaterThan(mid.opacity, 0)
        XCTAssertLessThan(mid.opacity, 1)
    }

    func testReduceMotionIsAFadeOnly() {
        for t in stride(from: 0.0, through: 0.2, by: 0.02) {
            XCTAssertEqual(CardPeekLayout.entrance(elapsed: t, reduceMotion: true).scale, 1, "no scale at \(t)")
        }
        XCTAssertEqual(CardPeekLayout.entrance(elapsed: 0, reduceMotion: true).opacity, 0)
        XCTAssertEqual(CardPeekLayout.entrance(elapsed: 0.2, reduceMotion: true).opacity, 1)
    }
}
