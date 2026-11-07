import BlurtRemoteKit
import XCTest
@testable import BlurtRemote

final class PadEngineTests: XCTestCase {
    private func t(_ id: Int, _ x: CGFloat, _ y: CGFloat) -> PadTouch { PadTouch(id: id, x: x, y: y) }

    func testTapClicks() {
        let e = PadEngine()
        XCTAssertEqual(e.began([t(1, 100, 100)], at: 0), [])
        XCTAssertEqual(e.ended([1], at: 0.1), [.click(.left), .haptic(.tap)])
    }

    func testRestingThumbNeverClicks() {
        let e = PadEngine()
        _ = e.began([t(1, 100, 100)], at: 0)
        XCTAssertEqual(e.ended([1], at: 0.3), [])
    }

    func testMoveHasNoClick() {
        let e = PadEngine()
        _ = e.began([t(1, 100, 100)], at: 0)
        _ = e.moved([t(1, 110, 100)], at: 0.05)
        let o = e.moved([t(1, 120, 100)], at: 0.06)
        guard case .move? = o.first else { return XCTFail("\(o)") }
        XCTAssertEqual(e.ended([1], at: 0.1), [])
    }

    func testDoubleTapIsTwoClicks() {
        let e = PadEngine()
        _ = e.began([t(1, 100, 100)], at: 0)
        _ = e.ended([1], at: 0.08)
        _ = e.began([t(1, 102, 100)], at: 0.2)
        XCTAssertEqual(e.ended([1], at: 0.26), [.click(.left), .haptic(.tap)])
    }

    func testTapThenMoveDragsAndSurvivesALift() {
        let e = PadEngine()
        _ = e.began([t(1, 100, 100)], at: 0)
        _ = e.ended([1], at: 0.08)
        _ = e.began([t(1, 100, 100)], at: 0.2)
        XCTAssertEqual(e.moved([t(1, 120, 100)], at: 0.25), [.button(.left, down: true), .haptic(.grab)])
        XCTAssertEqual(e.ended([1], at: 0.4), [])
        _ = e.began([t(1, 50, 50)], at: 0.6)    // a new stroke, still dragging
        guard case .move? = e.moved([t(1, 60, 50)], at: 0.62).first else { return XCTFail() }
        XCTAssertEqual(e.ended([1], at: 0.7), [])
        XCTAssertEqual(e.tick(at: 1.2), [.button(.left, down: false), .haptic(.release)])
    }

    func testHoldThenLiftIsRightClick() {
        let e = PadEngine()
        _ = e.began([t(1, 100, 100)], at: 0)
        XCTAssertEqual(e.tick(at: 0.45), [.haptic(.grab)])
        XCTAssertEqual(e.ended([1], at: 0.6), [.click(.right), .haptic(.tap)])
    }

    func testAPalmStartsNothing() {
        let e = PadEngine()
        XCTAssertEqual(e.began([], at: 0), [])
        _ = e.began([t(1, 100, 100)], at: 0.1)
        XCTAssertEqual(e.moved([t(1, 200, 100)], at: 0.2), [], "no three-finger swipe from nowhere")
    }

    func testLiftingOneOfThreeFingersSwipesNothing() {
        let e = PadEngine()
        _ = e.began([t(1, 0, 300), t(2, 100, 300), t(3, 300, 300)], at: 0)
        _ = e.ended([3], at: 0.1)
        XCTAssertEqual(e.moved([t(1, 0, 300), t(2, 100, 300)], at: 0.2), [])
    }

    func testRestingThumbNeverRightClicks() {
        let e = PadEngine()
        _ = e.began([t(1, 100, 100)], at: 0)
        _ = e.tick(at: 0.45)
        XCTAssertEqual(e.ended([1], at: 2), [])
    }

    func testATouchLongAfterAFlingClicks() {
        let e = PadEngine()
        _ = e.began([t(1, 100, 300), t(2, 160, 300)], at: 0)
        var y: CGFloat = 300
        for i in 0...6 {
            y -= 20
            _ = e.moved([t(1, 100, y), t(2, 160, y)], at: 0.02 + Double(i) * 0.016)
        }
        _ = e.ended([1, 2], at: 0.13)
        XCTAssertEqual(e.began([t(1, 100, 100)], at: 5), [])
        XCTAssertEqual(e.ended([1], at: 5.05), [.click(.left), .haptic(.tap)])
    }

    func testHoldThenMoveDrags() {
        let e = PadEngine()
        _ = e.began([t(1, 100, 100)], at: 0)
        XCTAssertEqual(e.tick(at: 0.45), [.haptic(.grab)])
        XCTAssertEqual(e.moved([t(1, 100, 120)], at: 0.5), [.button(.left, down: true)])
        guard case .move? = e.moved([t(1, 100, 130)], at: 0.52).first else { return XCTFail() }
        XCTAssertEqual(e.ended([1], at: 0.6), [])
        XCTAssertEqual(e.tick(at: 1.1), [.button(.left, down: false), .haptic(.release)], "a long drag can take a new stroke first")
    }

    func testOneFingerAlongTheEdgeScrolls() {
        let e = PadEngine()
        e.scrollEdge = 374...400
        _ = e.began([t(1, 390, 100)], at: 0)
        XCTAssertEqual(e.moved([t(1, 390, 120)], at: 0.05), [.scroll(0, 0, .began)])
        guard case .scroll(_, _, .changed)? = e.moved([t(1, 390, 130)], at: 0.07).first else { return XCTFail() }
    }

    func testAcrossTheEdgeIsThePointer() {
        let e = PadEngine()
        e.scrollEdge = 374...400
        _ = e.began([t(1, 390, 100)], at: 0)
        _ = e.moved([t(1, 370, 102)], at: 0.05)
        guard case .move? = e.moved([t(1, 360, 104)], at: 0.07).first else { return XCTFail() }
    }

    func testATapOnTheEdgeStillClicks() {
        let e = PadEngine()
        e.scrollEdge = 374...400
        _ = e.began([t(1, 390, 100)], at: 0)
        XCTAssertEqual(e.ended([1], at: 0.08), [.click(.left), .haptic(.tap)])
    }

    func testTwoFingerTapRightClicks() {
        let e = PadEngine()
        _ = e.began([t(1, 100, 100), t(2, 160, 100)], at: 0)
        _ = e.ended([1], at: 0.08)
        XCTAssertEqual(e.ended([2], at: 0.1), [.click(.right), .haptic(.tap)])
    }

    func testTwoFingerScrollFlingsAndATouchStopsIt() {
        let e = PadEngine()
        _ = e.began([t(1, 100, 300), t(2, 160, 300)], at: 0)
        XCTAssertEqual(e.moved([t(1, 100, 290), t(2, 160, 290)], at: 0.02), [.scroll(0, 0, .began)])
        var y: CGFloat = 290
        for i in 1...6 {
            y -= 20
            _ = e.moved([t(1, 100, y), t(2, 160, y)], at: 0.02 + Double(i) * 0.016)
        }
        let o = e.ended([1, 2], at: 0.13)
        XCTAssertEqual(o.first, .scroll(0, 0, .ended))
        guard case .fling? = o.last else { return XCTFail("\(o)") }
        XCTAssertEqual(e.began([t(1, 100, 100)], at: 0.3), [.scrollStop])
        XCTAssertEqual(e.ended([1], at: 0.35), [], "the touch that stopped it isn't a click")
    }

    func testThreeFingerSwipes() {
        let e = PadEngine()
        _ = e.began([t(1, 100, 300), t(2, 150, 300), t(3, 200, 300)], at: 0)
        let o = e.moved([t(1, 100, 200), t(2, 150, 200), t(3, 200, 200)], at: 0.1)
        XCTAssertEqual(o, [.system(.missionControl), .haptic(.grab)])
        XCTAssertEqual(e.moved([t(1, 100, 100), t(2, 150, 100), t(3, 200, 100)], at: 0.2), [], "once per swipe")
    }

    func testThirdFingerLandingLateStillSwipes() {
        for wobble: CGFloat in [10, 40] {   // two fingers that scrolled, or spread, a little first
            let e = PadEngine()
            _ = e.began([t(1, 100, 300), t(2, 160, 300)], at: 0)
            _ = e.moved([t(1, 100 - wobble, 300), t(2, 160 + wobble, 300 + wobble)], at: 0.02)
            _ = e.began([t(3, 220, 300)], at: 0.04)
            let o = e.moved([t(1, 40, 300), t(2, 100, 300), t(3, 160, 300)], at: 0.1)
            XCTAssertEqual(o.first, .system(.spaceRight), "\(o)")
        }
    }

    func testPinchZooms() {
        let e = PadEngine()
        _ = e.began([t(1, 100, 300), t(2, 200, 300)], at: 0)
        _ = e.moved([t(1, 70, 300), t(2, 230, 300)], at: 0.05)
        XCTAssertEqual(e.moved([t(1, 40, 300), t(2, 260, 300)], at: 0.1), [.system(.zoomIn), .haptic(.step)])
    }

    func testWithTheScreenShowingAPinchZoomsTheView() {
        let e = PadEngine()
        e.pinchZoomsView = true
        _ = e.began([t(1, 100, 300), t(2, 200, 300)], at: 0)
        _ = e.moved([t(1, 80, 300), t(2, 220, 300)], at: 0.05)     // 100 → 140 apart: past the threshold
        guard case let .view(f, dx, dy, at)? = e.moved([t(1, 60, 300), t(2, 240, 300)], at: 0.1).first else { return XCTFail() }
        XCTAssertEqual(f, 180 / 140, accuracy: 0.001)
        XCTAssertEqual(dx, 0); XCTAssertEqual(dy, 0)
        XCTAssertEqual(at, CGPoint(x: 150, y: 300))
        XCTAssertEqual(e.ended([1, 2], at: 0.2), [.viewEnd])
    }

    func testZoomedInTwoFingersMoveTheView() {
        let e = PadEngine()
        e.pinchZoomsView = true
        e.viewZoomed = true
        _ = e.began([t(1, 100, 300), t(2, 200, 300)], at: 0)
        _ = e.moved([t(1, 110, 300), t(2, 210, 300)], at: 0.05)
        guard case let .view(f, dx, _, _)? = e.moved([t(1, 130, 300), t(2, 230, 300)], at: 0.1).first else { return XCTFail() }
        XCTAssertEqual(f, 1); XCTAssertEqual(dx, 20)
    }

    func testNotZoomedTwoFingersStillScroll() {
        let e = PadEngine()
        e.pinchZoomsView = true
        _ = e.began([t(1, 100, 300), t(2, 200, 300)], at: 0)
        XCTAssertEqual(e.moved([t(1, 100, 320), t(2, 200, 320)], at: 0.05), [.scroll(0, 0, .began)])
    }

    func testAFingerLiftedMidPinchDoesntJump() {
        let e = PadEngine()
        e.pinchZoomsView = true
        _ = e.began([t(1, 100, 300), t(2, 200, 300)], at: 0)
        _ = e.moved([t(1, 60, 300), t(2, 240, 300)], at: 0.05)
        XCTAssertEqual(e.ended([2], at: 0.1), [])
        XCTAssertEqual(e.moved([t(1, 50, 300)], at: 0.12), [])
        _ = e.began([t(3, 300, 300)], at: 0.2)
        guard case let .view(f, _, _, _)? = e.moved([t(3, 310, 300)], at: 0.22).first else { return XCTFail() }
        XCTAssertEqual(f, 260 / 250, accuracy: 0.001)
    }

    func testZoomedATwoFingerTapStillRightClicks() {
        let e = PadEngine()
        e.pinchZoomsView = true
        e.viewZoomed = true
        _ = e.began([t(1, 100, 300), t(2, 200, 300)], at: 0)
        XCTAssertEqual(e.ended([1, 2], at: 0.1), [.click(.right), .haptic(.tap)])
    }

    func testASecondFingerDoesntJumpADrag() {
        let e = PadEngine()
        _ = e.began([t(1, 100, 100)], at: 0)
        _ = e.tick(at: 0.45)
        _ = e.moved([t(1, 100, 120)], at: 0.5)
        _ = e.began([t(2, 300, 120)], at: 0.55)
        guard case let .move(x, _)? = e.moved([t(1, 101, 120), t(2, 301, 120)], at: 0.6).first else { return XCTFail() }
        XCTAssertLessThan(abs(x), 6)
        XCTAssertEqual(e.ended([2], at: 0.65), [])
        XCTAssertEqual(e.moved([t(1, 101, 120)], at: 0.7), [], "no jump back when it lifts")
    }

    func testUnevenFingersMovingTheViewDontZoomIt() {
        let e = PadEngine()
        e.pinchZoomsView = true
        e.viewZoomed = true
        _ = e.began([t(1, 100, 300), t(2, 200, 300)], at: 0)
        _ = e.moved([t(1, 110, 310), t(2, 212, 306)], at: 0.05)
        for i in 1...6 {
            let y = 310 + CGFloat(i) * 12
            guard case let .view(f, _, _, _)? = e.moved([t(1, 110, y), t(2, 212 + CGFloat(i % 2) * 6, y + 3)], at: 0.05 + Double(i) * 0.02).first else { return XCTFail() }
            XCTAssertEqual(f, 1, "a little apart or together is still a move")
        }
    }

    func testFingersClearlyPinchingWhileZoomedDoZoom() {
        let e = PadEngine()
        e.pinchZoomsView = true
        e.viewZoomed = true
        _ = e.began([t(1, 100, 300), t(2, 200, 300)], at: 0)
        _ = e.moved([t(1, 95, 300), t(2, 205, 300)], at: 0.05)
        _ = e.moved([t(1, 85, 300), t(2, 215, 300)], at: 0.1)      // past the line: nothing jumps
        guard case let .view(f, _, _, _)? = e.moved([t(1, 75, 300), t(2, 225, 300)], at: 0.15).first else { return XCTFail() }
        XCTAssertEqual(f, 150 / 130, accuracy: 0.001)
    }

    func testWithTouchModeATapLandsUnderTheFinger() {
        let e = PadEngine()
        e.touchMode = true
        _ = e.began([t(1, 100, 200)], at: 0)
        XCTAssertEqual(e.ended([1], at: 0.08), [.pointAt(CGPoint(x: 100, y: 200)), .click(.left), .haptic(.tap)])
        _ = e.began([t(1, 102, 203)], at: 0.2)
        XCTAssertEqual(e.ended([1], at: 0.26), [.click(.left), .haptic(.tap)], "the second of a double click stays put")
    }

    func testWithTouchModeMovingAFingerIsStillThePointer() {
        let e = PadEngine()
        e.touchMode = true
        _ = e.began([t(1, 100, 200)], at: 0)
        _ = e.moved([t(1, 110, 200)], at: 0.05)
        guard case .move? = e.moved([t(1, 120, 200)], at: 0.07).first else { return XCTFail() }
        XCTAssertEqual(e.ended([1], at: 0.2), [])
    }

    func testWithTouchModeADragFollowsTheFinger() {
        let e = PadEngine()
        e.touchMode = true
        _ = e.began([t(1, 100, 200)], at: 0)
        XCTAssertEqual(e.tick(at: 0.45), [.pointAt(CGPoint(x: 100, y: 200)), .haptic(.grab)])
        XCTAssertEqual(e.moved([t(1, 100, 220)], at: 0.5), [.button(.left, down: true)])
        XCTAssertEqual(e.moved([t(1, 130, 260)], at: 0.55), [.dragTo(CGPoint(x: 130, y: 260))])
        _ = e.began([t(2, 300, 300)], at: 0.6)
        XCTAssertEqual(e.moved([t(1, 135, 262), t(2, 310, 300)], at: 0.65), [.dragTo(CGPoint(x: 135, y: 262))], "the finger that started it")
        _ = e.ended([2], at: 0.7)
        XCTAssertEqual(e.ended([1], at: 0.75), [.button(.left, down: false), .haptic(.release)], "up at once: nothing to wait for")
    }

    func testWithTouchModeHoldAndLiftRightClicksThere() {
        let e = PadEngine()
        e.touchMode = true
        _ = e.began([t(1, 100, 200)], at: 0)
        _ = e.tick(at: 0.45)
        XCTAssertEqual(e.ended([1], at: 0.6), [.click(.right), .haptic(.tap)])
    }

    func testCancelLetsGoOfADrag() {
        let e = PadEngine()
        _ = e.began([t(1, 100, 100)], at: 0)
        _ = e.ended([1], at: 0.08)
        _ = e.began([t(1, 100, 100)], at: 0.2)
        _ = e.moved([t(1, 120, 100)], at: 0.25)
        XCTAssertEqual(e.cancel(), [.button(.left, down: false)])
    }
}

final class DeckTests: XCTestCase {
    func testStandardDeckFits() {
        let d = Deck.standard
        XCTAssertEqual(d.dock.count, Deck.dockCount)
        XCTAssertLessThanOrEqual(d.sections.count, Deck.maxSections)
        XCTAssertLessThanOrEqual(d.sections[0].slots.count, Deck.columns * PadLayout.visibleRows, "everything for every day, on one screen")
        XCTAssertTrue(d.dock.contains { if case let .chord(c, _) = $0.action { c.key == "Escape" } else { false } }, "Esc wherever the list is")
    }

    func testEveryFaceIsAnIconThatExistsOrFits() {
        let all = Deck.standard.dock + Deck.standard.sections.flatMap(\.slots) + Deck.catalogue.flatMap(\.slots)
        for s in all {
            if s.face.hasPrefix("sf:") { XCTAssertNotNil(UIImage(systemName: String(s.face.dropFirst(3))), s.face) }
            XCTAssertFalse(s.face.isEmpty, s.title)
        }
        for n in Deck.icons { XCTAssertNotNil(UIImage(systemName: n), n) }
    }

    func testAKeyShowsWhatsPressedNotWhatItsFor() {
        let copy = Deck.standard.sections[0].slots[0]
        XCTAssertEqual(copy.face, "sf:doc.on.doc")
        XCTAssertEqual(copy.detail, "⌘C")
        XCTAssertEqual(copy.title, String(localized: "Copy"), "lists still say")
    }

    func testControlTabBothWays() {
        let chords = Deck.standard.sections[0].slots.compactMap { s -> RemoteChord? in if case let .chord(c, true) = s.action { c } else { nil } }
        XCTAssertTrue(chords.contains(RemoteChord(.control, "Tab")))
        XCTAssertTrue(chords.contains(RemoteChord([.control, .shift], "Tab")))
    }

    func testTheWholeKeyboardIsThere() {
        let names = Deck.standard.sections.flatMap(\.slots).compactMap { s -> String? in
            if case let .chord(c, _) = s.action, c.mods.isEmpty { c.key } else { nil }
        }
        for k in ["A", "Z", "0", "9", "F12", "Space", "/"] { XCTAssertTrue(names.contains(k), k) }
        let letters = Deck.standard.sections.first { $0.columns == 10 }!
        XCTAssertEqual(letters.slots.count, 40, "whole rows, as on a keyboard")
    }

    func testMovingKeys() {
        var d = Deck.standard
        let a = d.sections[0].slots[0], b = d.sections[0].slots[3]
        d.move(a.id, onto: b.id)
        XCTAssertEqual(d.sections[0].slots[3].id, a.id)
        let esc = d.dock[0], one = d.sections[0].slots[1]
        d.move(one.id, onto: esc.id)
        XCTAssertEqual(d.dock[0].id, one.id)
        XCTAssertEqual(d.dock.count, Deck.dockCount)
        XCTAssertEqual(d.sections[0].slots[1].id, esc.id, "the dock swaps")
        let far = d.sections[1].slots[0]
        let count = d.sections[0].slots.count
        d.move(far.id, onto: d.sections[0].slots[2].id)
        XCTAssertEqual(d.sections[0].slots.count, count + 1, "across sections")
    }

    func testRoundTrips() throws {
        let d = Deck.standard
        XCTAssertEqual(try JSONDecoder().decode(Deck.self, from: JSONEncoder().encode(d)), d)
    }

    func testEveryChordIsAKeyTheMacKnows() {
        for (_, slots) in Deck.catalogue {
            for s in slots {
                if case let .chord(c, _) = s.action { XCTAssertNotNil(RemoteKey.named(c.key), c.key) }
            }
        }
    }
}

final class LayoutTests: XCTestCase {
    private let portrait = CGSize(width: 402, height: 874), wide = CGSize(width: 874, height: 402)
    private let max = CGSize(width: 956, height: 440)
    private let tall = UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0), side = UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62)

    func testPortrait() {
        let l = PadLayout(size: portrait, safe: tall, lefty: false)
        XCTAssertFalse(l.landscape)
        XCTAssertEqual(l.dock.count, Deck.dockCount)
        XCTAssertGreaterThanOrEqual(l.pad.height, 380, "the pad gets what the keys leave")
        XCTAssertGreaterThan(l.keySize.width, 40, "eight across")
        XCTAssertEqual(l.list.height, l.keySize.height * 6 + PadLayout.gap * 5, accuracy: 1, "six whole rows")
        XCTAssertGreaterThan(l.talk.minX, l.dock.last!.maxX, "the talk key by the right thumb")
        XCTAssertLessThanOrEqual(l.talk.maxY, 874 - 20)
        XCTAssertLessThan(l.arrowKey.maxY, l.list.minY + 1, "above the keys, room to slide down")
        XCTAssertLessThanOrEqual(l.strip.maxX, l.screenButton.minX)
        XCTAssertLessThanOrEqual(l.keyboardButton.maxX, l.arrowKey.minX)
        let m = PadLayout(size: portrait, safe: tall, lefty: true)
        XCTAssertEqual(m.talk.minX, 8, "left-handed, it's by the left thumb")
        XCTAssertEqual(m.arrowKey.minX, 8)
        XCTAssertEqual(m.scrollEdge.lowerBound, 0, "the scroll edge with it")
    }

    func testLandscapeTheSideStripUsesTheIslandsMargin() {
        for islandLeft in [true, false] {
            for showing in [true, false] {
                let l = PadLayout(size: max, safe: side, lefty: false, islandLeft: islandLeft, screenAspect: showing ? 1.6 : nil)
                let rail = l.rail!
                XCTAssertEqual(islandLeft ? rail.minX : rail.maxX, islandLeft ? 0 : 956, "at the island's end")
                XCTAssertFalse(l.pad.intersects(rail))
                XCTAssertTrue(rail.contains(l.screenButton))
                XCTAssertTrue(rail.contains(l.talk))
                for c in l.dock + [l.arrowKey, l.talk] { XCTAssertTrue(rail.contains(c)); XCTAssertGreaterThanOrEqual(c.height, 36) }
                // the Dynamic Island takes the middle of the margin
                for b in [l.settingsButton, l.screenButton, l.keyboardButton, l.drawerButton] { XCTAssertFalse(b.intersects(CGRect(x: 0, y: 150, width: 956, height: 140))) }
                XCTAssertGreaterThan(l.arrowKey.minY, 120, "the middle: room to slide up")
                XCTAssertLessThan(l.arrowKey.maxY, 320, "and down")
            }
        }
    }

    func testLandscapeTheKeysAndThePictureShareTheRest() {
        for size in [wide, max] {
            for islandLeft in [true, false] {
                let open = PadLayout(size: size, safe: side, lefty: false, islandLeft: islandLeft, screenAspect: 1.6, drawerOpen: true)
                XCTAssertFalse(open.pad.intersects(open.drawer), "beside the keys, not under them")
                XCTAssertGreaterThan(open.pad.width, 380)
                let shut = PadLayout(size: size, safe: side, lefty: false, islandLeft: islandLeft, screenAspect: 1.6)
                XCTAssertGreaterThan(shut.pad.width, open.pad.width + 300)
                XCTAssertGreaterThan(shut.pad.height, size.height - 13)
            }
        }
    }

    func testAPhoneWithNoIslandStillFits() {
        let l = PadLayout(size: CGSize(width: 667, height: 375), safe: .zero, lefty: false, screenAspect: 1.6)
        XCTAssertGreaterThan(l.pad.width, 400)
        XCTAssertFalse(l.dock[0].intersects(l.settingsButton))
    }

    func testSmallestPhone() {
        let l = PadLayout(size: CGSize(width: 375, height: 667), safe: UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0), lefty: false)
        XCTAssertGreaterThan(l.pad.height, 200)
    }
}

final class ViewPortTests: XCTestCase {
    private func close(_ a: CGRect, _ b: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        for (x, y) in [(a.minX, b.minX), (a.minY, b.minY), (a.width, b.width), (a.height, b.height)] { XCTAssertEqual(x, y, accuracy: 0.0001, file: file, line: line) }
    }

    func testThePointBetweenTheFingersStaysPut() {
        var p = ViewPort()
        p.change(scale: 2, move: .zero, anchor: CGPoint(x: 0.25, y: 0.5))
        close(p.rect, CGRect(x: 0.125, y: 0.25, width: 0.5, height: 0.5))
        p.change(scale: 2, move: .zero, anchor: CGPoint(x: 0.5, y: 0.5))
        close(p.rect, CGRect(x: 0.25, y: 0.375, width: 0.25, height: 0.25))
    }

    func testAMoveStopsAtTheEdge() {
        var p = ViewPort()
        p.change(scale: 2, move: .zero, anchor: CGPoint(x: 0.5, y: 0.5))
        p.change(scale: 1, move: CGPoint(x: 0.25, y: 0), anchor: .zero)     // the picture goes right: the view goes left
        close(p.rect, CGRect(x: 0.125, y: 0.25, width: 0.5, height: 0.5))
        p.change(scale: 1, move: CGPoint(x: 5, y: -5), anchor: .zero)
        close(p.rect, CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
    }

    func testAPinchOutStretchesThenSpringsBack() {
        var p = ViewPort()
        p.change(scale: 0.5, move: .zero, anchor: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(p.zoom, ViewPort.stretch)
        close(p.rect, CGRect(x: -0.125, y: -0.125, width: 1.25, height: 1.25))
        p.settle()
        XCTAssertEqual(p.zoom, 1)
        close(p.rect, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testOnATallerStageThePictureSitsAtTheBottomAndFillsItAsItZooms() {
        var p = ViewPort()
        p.reshape(0.5, alignY: 1)       // twice the picture's height
        close(p.rect, CGRect(x: 0, y: -1, width: 1, height: 2))
        XCTAssertEqual(p.crop, .whole)
        p.change(scale: 2, move: .zero, anchor: CGPoint(x: 0.5, y: 0.75))
        close(p.rect, CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(p.crop, .whole, "all of the height is in view: the picture must be whole top to bottom")
        p.change(scale: 2, move: .zero, anchor: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(Double(p.crop.w), 0.5, accuracy: 0.0001, "the screen's shape, around a taller view")
        XCTAssertEqual(Double(p.crop.h), 0.5, accuracy: 0.0001)
    }

    func testATallStageMovesAroundBothWays() {
        var p = ViewPort()
        p.reshape(0.5, alignY: 1)
        p.change(scale: 4, move: .zero, anchor: CGPoint(x: 0.5, y: 0.75))
        let was = p.rect
        p.change(scale: 1, move: CGPoint(x: 0.1, y: 0.1), anchor: .zero)
        XCTAssertLessThan(p.rect.minX, was.minX)
        XCTAssertLessThan(p.rect.minY, was.minY)
    }

    func testNotQuiteZoomedIsTheWholeScreen() {
        var p = ViewPort()
        p.change(scale: 1.05, move: .zero, anchor: .zero)
        p.settle()
        XCTAssertTrue(p.isWhole)
        XCTAssertEqual(p.crop, .whole)
    }

    func testThePointerPushesTheView() {
        var p = ViewPort()
        p.change(scale: 2, move: .zero, anchor: CGPoint(x: 0.5, y: 0.5))
        XCTAssertFalse(p.follow(CGPoint(x: 0.5, y: 0.5)))
        XCTAssertTrue(p.follow(CGPoint(x: 0.76, y: 0.5)))
        XCTAssertEqual(p.rect.maxX, 0.82, accuracy: 0.001)
    }

    func testNoFurtherThanEight() {
        var p = ViewPort()
        p.change(scale: 100, move: .zero, anchor: .zero)
        XCTAssertEqual(p.zoom, ViewPort.closest)
    }
}
