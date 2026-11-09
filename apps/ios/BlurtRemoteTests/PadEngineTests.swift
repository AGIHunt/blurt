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

    func testWithThePictureTwoFingersScrollTheMacUnderThem() {
        let e = PadEngine()
        e.pinchZoomsView = true
        e.touchMode = true
        _ = e.began([t(1, 100, 300), t(2, 200, 300)], at: 0)
        XCTAssertEqual(e.moved([t(1, 100, 320), t(2, 200, 320)], at: 0.05), [.pointAt(CGPoint(x: 150, y: 300)), .scroll(0, 0, .began)])
        guard case let .scroll(_, dy, .changed)? = e.moved([t(1, 100, 340), t(2, 200, 340)], at: 0.08).first else { return XCTFail() }
        XCTAssertGreaterThan(dy, 0)
    }

    func testSideways() {
        let e = PadEngine()
        _ = e.began([t(1, 100, 300), t(2, 200, 300)], at: 0)
        _ = e.moved([t(1, 120, 300), t(2, 220, 300)], at: 0.05)
        guard case let .scroll(dx, dy, .changed)? = e.moved([t(1, 140, 300), t(2, 240, 300)], at: 0.08).first else { return XCTFail() }
        XCTAssertGreaterThan(dx, 0); XCTAssertEqual(dy, 0)
    }

    func testAScrollThatClearlyPinchesZoomsThePicture() {
        let e = PadEngine()
        e.pinchZoomsView = true
        _ = e.began([t(1, 100, 300), t(2, 200, 300)], at: 0)
        _ = e.moved([t(1, 100, 320), t(2, 200, 320)], at: 0.05)
        XCTAssertEqual(e.moved([t(1, 70, 330), t(2, 230, 330)], at: 0.1), [.scroll(0, 0, .ended)])
        guard case let .view(f, _, _, _)? = e.moved([t(1, 60, 330), t(2, 240, 330)], at: 0.12).first else { return XCTFail() }
        XCTAssertEqual(f, 180 / 160, accuracy: 0.001)
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

    func testUnevenFingersScrollingDontZoom() {
        let e = PadEngine()
        e.pinchZoomsView = true
        _ = e.began([t(1, 100, 300), t(2, 200, 300)], at: 0)
        _ = e.moved([t(1, 110, 310), t(2, 212, 306)], at: 0.05)
        for i in 1...6 {
            let y = 310 + CGFloat(i) * 12
            guard case .scroll? = e.moved([t(1, 110, y), t(2, 212 + CGFloat(i % 2) * 6, y + 3)], at: 0.05 + Double(i) * 0.02).first else { return XCTFail() }
        }
    }

    func testFingersClearlyPinchingWhileZoomedDoZoom() {
        let e = PadEngine()
        e.pinchZoomsView = true
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
        for s in d.sections {
            let cells = s.slots.reduce(0) { $0 + ($1.span ?? 1) }
            XCTAssertLessThanOrEqual(cells, s.columns * PadLayout.visibleRows, "\(s.name) fits a page, nothing to scroll for")
        }
        let held = Set(d.dock.compactMap { s -> RemoteModifiers? in if case let .sticky(m) = s.action { m } else { nil } })
        XCTAssertEqual(held, [.command, .option, .control, .shift], "all four, side by side")
        XCTAssertTrue(d.dock.contains { if case let .chord(c, _) = $0.action { c.key == "Escape" } else { false } }, "Esc wherever the list is")
    }

    func testEveryFaceIsAnIconThatExistsOrFits() {
        let all = Deck.standard.dock + Deck.standard.sections.flatMap(\.slots) + Deck.catalogue.flatMap(\.slots)
        for s in all {
            if s.face.hasPrefix("sf:") { XCTAssertNotNil(UIImage(systemName: String(s.face.dropFirst(3))), s.face) }
            if s.face.hasPrefix("mark:") { XCTAssertNotNil(KeyMarks.image(String(s.face.dropFirst(5))), s.face) }
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
        let names = (Deck.standard.dock + Deck.standard.sections.flatMap(\.slots)).compactMap { s -> String? in
            if case let .chord(c, _) = s.action, c.mods.isEmpty { c.key } else { nil }
        }
        for k in ["A", "Z", "0", "9", "F12", "Space", "/"] { XCTAssertTrue(names.contains(k), k) }
        let letters = Deck.standard.sections.first { $0.columns == 10 }!
        XCTAssertEqual(letters.slots.reduce(0) { $0 + ($1.span ?? 1) }, 40, "whole rows, as on a keyboard")
    }

    func testNoKeyTwice() {
        var seen: [KeyAction: String] = [:]
        for s in Deck.standard.dock + Deck.standard.sections.flatMap(\.slots) {
            XCTAssertNil(seen[s.action], "\(s.title) is there twice")
            seen[s.action] = s.title
        }
    }

    func testPagesAsTheyShippedComeUpToDate() throws {
        defer { ["deck.v8", "deck.v9"].forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        var old = Deck.standard
        old.sections[1].slots = "QWERTYUIOPASDFGHJKL;ZXCVBNM,./".map { KeySlot(.chord(RemoteChord([], String($0)), cycle: false)) }
            + [KeySlot(.chord(RemoteChord([], "Space"), cycle: false), glyph: "Space"), KeySlot(.chord(RemoteChord([], "-"), cycle: false)),
               KeySlot(.chord(RemoteChord([], "="), cycle: false)), KeySlot(.chord(RemoteChord([], "'"), cycle: false))]
        old.sections[0].slots.swapAt(0, 1)
        UserDefaults.standard.removeObject(forKey: "deck.v9")
        UserDefaults.standard.set(try JSONEncoder().encode(old), forKey: "deck.v8")
        let d = Deck.load()
        XCTAssertEqual(d.sections[1].slots.map(\.action), Deck.standard.sections[1].slots.map(\.action), "no space bar on 字母 any more")
        XCTAssertEqual(d.sections[0].slots.map(\.id), old.sections[0].slots.map(\.id), "and the owner's own page kept")
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

final class DeckMigrationTests: XCTestCase {
    override func tearDown() {
        ["deck.v7", "deck.v8", "deck.v9"].forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    func testKeysSetUpBeforeTheSpaceBarAreKept() throws {
        var old = Deck.standard
        old.dock.removeLast()                       // as it was: eight
        old.sections[0].slots.swapAt(0, 1)           // and changed by its owner
        ["deck.v8", "deck.v9"].forEach { UserDefaults.standard.removeObject(forKey: $0) }
        UserDefaults.standard.set(try JSONEncoder().encode(old), forKey: "deck.v7")
        let d = Deck.load()
        XCTAssertEqual(d.dock.count, Deck.dockCount)
        XCTAssertEqual(d.dock.last?.action, Deck.spaceBar.action)
        XCTAssertEqual(d.sections[0].slots.map(\.id), old.sections[0].slots.map(\.id), "the owner's keys, where they were")
    }

    func testACustomDockStillGetsTheSpaceBar() throws {
        var old = Deck.standard
        old.dock.removeLast()
        old.dock[1] = old.sections[0].slots[0]       // ⌥ swapped for ⌘C
        ["deck.v8", "deck.v9"].forEach { UserDefaults.standard.removeObject(forKey: $0) }
        UserDefaults.standard.set(try JSONEncoder().encode(old), forKey: "deck.v7")
        XCTAssertEqual(Deck.load().dock.last?.action, Deck.spaceBar.action)
    }

    func testASpaceAlreadyInTheDockIsntDoubled() throws {
        var old = Deck.standard
        old.dock.removeLast()
        old.dock[4] = Deck.spaceBar                  // in place of ⇥
        ["deck.v8", "deck.v9"].forEach { UserDefaults.standard.removeObject(forKey: $0) }
        UserDefaults.standard.set(try JSONEncoder().encode(old), forKey: "deck.v7")
        let d = Deck.load()
        XCTAssertEqual(d.dock.filter { $0.action == Deck.spaceBar.action }.count, 1)
        XCTAssertEqual(d.dock.count, Deck.dockCount)
    }
}

final class LayoutTests: XCTestCase {
    private let portrait = CGSize(width: 402, height: 874), wide = CGSize(width: 874, height: 402)
    private let max = CGSize(width: 956, height: 440)
    private let tall = UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0), side = UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62)

    private func noOverlaps(_ r: [CGRect], line: UInt = #line) {
        for (i, a) in r.enumerated() { for b in r[(i + 1)...] { XCTAssertFalse(a.intersects(b), "\(a) \(b)", line: line) } }
    }

    func testPortrait() {
        let l = PadLayout(size: portrait, safe: tall, lefty: false)
        XCTAssertFalse(l.landscape)
        XCTAssertEqual(l.dock.count, Deck.dockCount)
        XCTAssertEqual(l.list.height, l.keySize.height * 4 + PadLayout.gap * 3, accuracy: 1, "four whole rows")
        XCTAssertLessThanOrEqual(l.drawer.height, 315, "a keyboard, not a wall of keys")
        XCTAssertGreaterThanOrEqual(l.arrowKey.height, 44, "room for up and down")
        XCTAssertLessThan(l.talk.minX - l.dock[PadLayout.thumbSlots.esc].maxX, 140, "esc by the thumb")
        XCTAssertGreaterThan(l.keySize.width, 56, "easy to hit without looking")
        XCTAssertLessThan(l.pad.maxY, l.drawer.minY + 1)
        XCTAssertEqual(l.talk.maxX, l.drawer.maxX, accuracy: 1, "the talk key by the thumb")
        XCTAssertEqual(l.talk.width, l.dock[0].width, accuracy: 0.5, "no bigger than the keys beside it")
        XCTAssertEqual(l.dock[PadLayout.thumbSlots.space].maxX + PadLayout.gap, l.talk.minX, accuracy: 0.5, "space right by it")
        XCTAssertEqual(l.settingsButton.minX, l.drawer.minX, accuracy: 1, "settings first")
        noOverlaps(l.dock + [l.talk, l.arrowKey, l.keyboardButton, l.screenButton, l.findButton, l.settingsButton, l.strip, l.list])
        XCTAssertGreaterThanOrEqual(l.strip.width / 4, 38, "room for four tabs")

        let m = PadLayout(size: portrait, safe: tall, lefty: true)
        XCTAssertEqual(m.talk.minX, m.drawer.minX, accuracy: 1)
        XCTAssertEqual(m.settingsButton.minX, m.drawer.minX, accuracy: 1, "settings first either way")
        XCTAssertGreaterThan(m.arrowKey.minX, m.drawer.minX + 36, "room for a slide to the left")
        noOverlaps(m.dock + [m.talk, m.arrowKey, m.keyboardButton, m.screenButton, m.findButton, m.settingsButton, m.strip, m.list])
    }

    func testLandscapeTheIslandsEndHoldsTheControlsAndTheOtherTheThumbsKeys() {
        for size in [max, wide] {
            for islandLeft in [true, false] {
                let l = PadLayout(size: size, safe: side, lefty: false, islandLeft: islandLeft)
                XCTAssertTrue(l.landscape)
                let island = CGRect(x: islandLeft ? 8 : size.width - 54, y: size.height / 2 - 66, width: 46, height: 132)
                for b in [l.settingsButton, l.findButton, l.screenButton, l.keyboardButton] {
                    XCTAssertFalse(b.intersects(island), "clear of the island")
                    XCTAssertEqual(b.midX, islandLeft ? 31 : size.width - 31, accuracy: 1, "in the black edge")
                }
                let t = PadLayout.thumbSlots
                let stay = [l.drawerButton, l.appsKey, l.dock[t.esc], l.arrowKey, l.dock[t.enter], l.dock[t.space], l.talk]
                noOverlaps(stay)
                for r in stay {
                    XCTAssertEqual(r.midX, islandLeft ? size.width - 40 : 40, accuracy: 1, "one column, at the far end")
                    XCTAssertGreaterThanOrEqual(r.minY, 18)
                    XCTAssertLessThanOrEqual(r.maxY, size.height - 18, "clear of the round corners")
                    XCTAssertGreaterThanOrEqual(islandLeft ? size.width - r.maxX : r.minX, 12)
                }
                XCTAssertGreaterThanOrEqual(l.dock[t.space].height, 44, "keys a thumb can hit")
                XCTAssertGreaterThan(l.talk.height, l.dock[t.space].height, "the talk key a little taller")
                XCTAssertLessThanOrEqual(l.talk.height, l.dock[t.space].height + 12, "but not a tower")
                XCTAssertGreaterThan(l.drawer.height, size.height - 90, "the keys use the height")
                XCTAssertLessThanOrEqual(l.keySize.height, l.keySize.width * 1.25 + 1, "but stay key-shaped")
            }
        }
    }

    func testLandscapeTheRestOfTheKeysComeAndGo() {
        for size in [max, wide] {
            for islandLeft in [true, false] {
                let open = PadLayout(size: size, safe: side, lefty: false, islandLeft: islandLeft, drawerOpen: true)
                XCTAssertFalse(open.pad.intersects(open.drawer), "beside the keys")
                XCTAssertGreaterThan(open.pad.width / open.pad.height, 0.95, "and still a picture")
                let rest = (0..<Deck.dockCount).filter { !PadLayout.staysOut($0) }
                noOverlaps(rest.map { open.dock[$0] } + [open.strip, open.list])
                for i in rest { XCTAssertTrue(open.drawer.insetBy(dx: -1, dy: -1).contains(open.dock[i]), "in the keys") }
                let shut = PadLayout(size: size, safe: side, lefty: false, islandLeft: islandLeft, drawerOpen: false)
                XCTAssertGreaterThan(shut.pad.width, open.pad.width + 300)
                XCTAssertGreaterThanOrEqual(shut.pad.width / shut.pad.height, 16.0 / 10, "a whole 16:10 screen at full height")
                XCTAssertFalse(shut.pad.intersects(shut.talk))
                XCTAssertFalse(shut.pad.intersects(shut.settingsButton))
                XCTAssertEqual(open.talk, shut.talk, "what stays doesn't move")
                XCTAssertEqual(open.arrowKey, shut.arrowKey)
            }
        }
    }

    func testAPhoneWithNoIslandStillFits() {
        let s = CGSize(width: 667, height: 375)
        let l = PadLayout(size: s, safe: .zero, lefty: false, drawerOpen: true)
        XCTAssertGreaterThanOrEqual(l.dock[PadLayout.thumbSlots.space].height, 43, "the thumb's column too")
        XCTAssertGreaterThan(l.pad.width, 150)
        XCTAssertGreaterThanOrEqual(l.keySize.width, 30)
        XCTAssertGreaterThanOrEqual(l.keySize.height, 44)
        XCTAssertLessThanOrEqual(l.drawer.maxY, s.height)
    }

    func testSmallestPhone() {
        let l = PadLayout(size: CGSize(width: 375, height: 667), safe: UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0), lefty: false)
        XCTAssertGreaterThan(l.pad.height, 300)
        XCTAssertGreaterThan(l.strip.width / 4, 35)
    }
}

final class ScreenPlanTests: XCTestCase {
    private let native = CGSize(width: 1320, height: 2868)
    private func plan(_ q: ScreenQuality, _ r: Link.Route, cellular: Bool = false, lowData: Bool = false) -> ScreenPlan {
        ScreenPlan(q, route: r, cellular: cellular, lowData: lowData, native: native)
    }

    func testAutoSpendsWhereItsFree() {
        XCTAssertEqual(plan(.auto, .local).bitrate, 12_000_000)
        XCTAssertEqual(plan(.auto, .local).width, 2868)
        XCTAssertEqual(plan(.auto, .local).fps, 60)
        XCTAssertLessThan(plan(.auto, .local, cellular: true).bitrate, 12_000_000, "a public address on mobile data isn't home")
        XCTAssertLessThan(plan(.auto, .relay, cellular: true).bitrate, plan(.auto, .relay).bitrate, "mobile data costs money")
        XCTAssertLessThan(plan(.auto, .relay, cellular: true, lowData: true).bitrate, plan(.auto, .relay, cellular: true).bitrate, "and the user said so")
    }

    func testAtHomeFramesComeAtThePanelsRate() {
        let pro = ScreenPlan(.auto, route: .local, cellular: false, lowData: false, native: native, panel: 120)
        XCTAssertEqual(pro.fps, 120, "ProMotion")
        XCTAssertEqual(pro.bitrate, 12_000_000, "no more data for it")
        XCTAssertEqual(ScreenPlan(.auto, route: .relay, cellular: false, lowData: false, native: native, panel: 120).fps, 30, "away, motion is what gives")
        XCTAssertEqual(ScreenPlan(.auto, route: .local, cellular: false, lowData: false, native: native, panel: 240).fps, 120)
    }

    func testAChoiceIsKept() {
        XCTAssertEqual(plan(.saver, .local).bitrate, 1_000_000, "even at home")
        XCTAssertEqual(plan(.sharp, .relay, cellular: true).width, 2868)
        XCTAssertGreaterThan(plan(.sharp, .relay, cellular: true).bitrate, plan(.balanced, .relay).bitrate)
        for q in ScreenQuality.allCases {
            for r in [Link.Route.local, .relay, .direct] {
                let p = plan(q, r)
                XCTAssertEqual(p.width % 2 + p.height % 2, 0)
                XCTAssertLessThanOrEqual(p.width, 2868)
            }
        }
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
