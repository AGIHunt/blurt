// The arrow key: what a touch sends (ArrowStroke), and how big it is where (PadLayout). docs/design/remote.md "The arrow key".
import XCTest
@testable import BlurtRemote

final class ArrowKeyTests: XCTestCase {
    /// A drag from `from` through `points`, fed 2 pt at a time the way touches come: every key it sends, in order (a repeat counts once
    /// each time it starts or changes key).
    private func drag(from start: CGPoint, _ points: [CGPoint]) -> [String] {
        var s = ArrowStroke(at: start)
        var out: [String] = [], repeating: String?
        var at = start
        for target in points {
            let n = max(1, Int((hypot(target.x - at.x, target.y - at.y) / 2).rounded(.up)))
            let from = at
            for i in 1...n {
                let t = CGFloat(i) / CGFloat(n)
                switch s.move(to: CGPoint(x: from.x + (target.x - from.x) * t, y: from.y + (target.y - from.y) * t)) {
                case let .step(k): out.append(k); repeating = nil
                case let .repeating(k, _): if repeating != k { out.append("repeat " + k); repeating = k }
                case .none: repeating = nil
                }
            }
            at = target
        }
        return out
    }

    func testASlideRightWithDriftDownSendsOnlyRights() {
        // 200 pt right, sinking 30 pt as it goes
        let path = stride(from: 10, through: 200, by: 10).map { x in CGPoint(x: x, y: 30 * x / 200) }
        let keys = drag(from: .zero, path)
        XCTAssertFalse(keys.isEmpty)
        XCTAssertTrue(keys.allSatisfy { $0.hasSuffix("Right") }, "\(keys)")
        XCTAssertEqual(keys.first, "Right")
        XCTAssertEqual(keys.last, "repeat Right", "far out, it repeats")
    }

    /// A thumb's arc: most of the sideways drift in the first 60 pt, which used to come out as a Down.
    func testAThumbsArcStaysRight() {
        let keys = drag(from: .zero, [CGPoint(x: 20, y: 10), CGPoint(x: 40, y: 20), CGPoint(x: 60, y: 28), CGPoint(x: 70, y: 30)])
        XCTAssertEqual(keys, ["Right", "Right"])
    }

    func testAClearTurnGoesTheNewWay() {
        let keys = drag(from: .zero, [CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 60)])
        XCTAssertEqual(keys, ["Right", "Right", "Down", "Down"])
        // and back up, the same axis: no turn needed
        XCTAssertEqual(drag(from: .zero, [CGPoint(x: 0, y: 50), CGPoint(x: 0, y: 0)]), ["Down", "Down", "Up", "Up"])
    }

    func testDriftDoesntFlipTheFarRepeat() {
        // far out to the right, then a slow sink while still going right
        let keys = drag(from: .zero, [CGPoint(x: 100, y: 0), CGPoint(x: 160, y: 40)])
        XCTAssertTrue(keys.allSatisfy { $0.hasSuffix("Right") }, "\(keys)")
    }

    func testAFarTurnStartsAgainFromTheTurn() {
        let keys = drag(from: .zero, [CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 60)])
        XCTAssertEqual(keys.prefix(4), ["Right", "Right", "Right", "repeat Right"])
        XCTAssertEqual(Array(keys.dropFirst(4)), ["Down", "Down"], "steps, not straight into a fast repeat")
    }

    func testTheScreenEdgeRepeats() {
        var s = ArrowStroke(at: .zero)
        XCTAssertEqual(s.move(to: CGPoint(x: 24, y: 0)), .step("Right"))
        guard case .repeating("Right", _) = s.move(to: CGPoint(x: 30, y: 0), screenEdge: 1) else { return XCTFail() }
        // the other edge, sliding right: no
        XCTAssertEqual(s.move(to: CGPoint(x: 32, y: 0), screenEdge: -1), .none)
    }

    func testTheMiddleIsNobodys() {
        let size = CGSize(width: 88, height: 88)
        XCTAssertNil(ArrowStroke.tapKey(CGPoint(x: 44, y: 44), in: size))
        XCTAssertNil(ArrowStroke.tapKey(CGPoint(x: 52, y: 37), in: size))
        // on the phone's wide key too
        XCTAssertNil(ArrowStroke.tapKey(CGPoint(x: 45, y: 27), in: CGSize(width: 82, height: 50)))
        // but a drag from there goes
        XCTAssertEqual(drag(from: CGPoint(x: 44, y: 44), [CGPoint(x: 44, y: 94)]), ["Down", "Down"])
    }

    func testEdgesTapTheirArrow() {
        for size in [CGSize(width: 82, height: 50), CGSize(width: 88, height: 88), CGSize(width: 56, height: 74)] {
            let w = size.width, h = size.height
            XCTAssertEqual(ArrowStroke.tapKey(CGPoint(x: w / 2, y: 4), in: size), "Up", "\(size)")
            XCTAssertEqual(ArrowStroke.tapKey(CGPoint(x: w / 2, y: h - 4), in: size), "Down", "\(size)")
            XCTAssertEqual(ArrowStroke.tapKey(CGPoint(x: 4, y: h / 2), in: size), "Left", "\(size)")
            XCTAssertEqual(ArrowStroke.tapKey(CGPoint(x: w - 4, y: h / 2), in: size), "Right", "\(size)")
            // just outside the middle
            XCTAssertEqual(ArrowStroke.tapKey(CGPoint(x: w / 2, y: h * 0.37), in: size), "Up", "\(size)")
        }
    }

    func testTapThenDragAddsShift() {
        XCTAssertTrue(ArrowStroke.shifted(now: 10.2, lastTap: 10))
        XCTAssertFalse(ArrowStroke.shifted(now: 10.5, lastTap: 10))
        XCTAssertFalse(ArrowStroke.shifted(now: 10.1, lastTap: 0), "no tap before")
    }

    // MARK: size

    func testBigScreensGiveEveryEdge44Points() {
        for room in Rooms.all {
            for lefty in [false, true] {
                for open in [true, false] {
                    let l = PadLayout(size: room.size, safe: room.safe, lefty: lefty, islandLeft: room.islandLeft, drawerOpen: open, surround: room.surround)
                    guard l.mode == .big, l.halves.count == 2, !room.surround.foldActive else { continue }
                    let name = "\(room.name) \(lefty) \(open)", a = l.arrowKey
                    XCTAssertGreaterThanOrEqual(a.width / 2, 44, name)
                    XCTAssertGreaterThanOrEqual(a.height / 2, 44, name)
                    // ⌘Tab across from it, the same size, on the same row; the controls two by two, aligned with both
                    XCTAssertEqual(l.appsKey.size, a.size, name)
                    XCTAssertEqual(l.appsKey.minY, a.minY, name)
                    XCTAssertEqual(l.settingsButton.minY, a.minY, accuracy: 0.5, name)
                    XCTAssertEqual(l.screenButton.maxY, a.maxY, accuracy: 0.5, name)
                    XCTAssertEqual(l.findButton.minY, l.settingsButton.minY, name)
                    XCTAssertEqual(l.keyboardButton.minX, l.findButton.minX, name)
                    XCTAssertEqual(l.strip.height, a.height, name)
                    XCTAssertGreaterThanOrEqual(l.strip.width, 140, "\(name): the tabs keep their room")
                    let half = l.halves.first { $0.contains(a.center) }!
                    XCTAssertEqual(min(abs(a.minX - half.minX), abs(a.maxX - half.maxX)), 0, accuracy: 0.5, "\(name): at the half's inner side")
                    XCTAssertGreaterThan(l.list.minY, a.maxY, name)
                }
            }
        }
    }

    func testThePhoneKeepsItsKey() {
        let l = PadLayout(size: CGSize(width: 402, height: 874), safe: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0), lefty: false)
        XCTAssertEqual(l.arrowKey.size, CGSize(width: 82, height: 50))
        let w = PadLayout(size: CGSize(width: 874, height: 402), safe: UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62), lefty: false)
        XCTAssertEqual(w.arrowKey.size, CGSize(width: 56, height: 74))
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
