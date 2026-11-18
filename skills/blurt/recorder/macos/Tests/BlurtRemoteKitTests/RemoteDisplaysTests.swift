// Several displays (docs/design/remote.md §Several displays): order, following with hysteresis, the map.
@testable import BlurtRemoteKit
import XCTest

final class RemoteDisplaysTests: XCTestCase {
    // a laptop with a 4K monitor to its right, a little higher, and a portrait one to the laptop's left
    let laptop = RemoteDisplay(id: "1", name: "Built-in Retina Display", x: 0, y: 0, width: 1728, height: 1117, main: true)
    let dell = RemoteDisplay(id: "2", name: "DELL P2725QE", x: 1728, y: -400, width: 2560, height: 1440, main: false)
    let side = RemoteDisplay(id: "3", name: "LG", x: -1080, y: -600, width: 1080, height: 1920, main: false)
    var all: [RemoteDisplay] { [dell, laptop, side] }

    func testOrderIsLeftToRight() {
        XCTAssertEqual(all.arranged.map(\.id), ["3", "1", "2"])
    }

    func testOneAboveAnotherGoesTopFirst() {
        let top = RemoteDisplay(id: "9", name: "Top", x: 0, y: -1440, width: 1728, height: 1440, main: false)
        XCTAssertEqual([laptop, top].arranged.map(\.id), ["9", "1"])
    }

    func testStepWrapsBothWays() {
        XCTAssertEqual(all.step(from: "1", by: 1)?.id, "2")
        XCTAssertEqual(all.step(from: "2", by: 1)?.id, "3")
        XCTAssertEqual(all.step(from: "3", by: -1)?.id, "2")
        XCTAssertEqual(all.step(from: "gone", by: 1)?.id, "3", "a display no longer there: start from the first")
    }

    func testFollowWaitsForThePointerToReallyCross() {
        var f = RemoteDisplayFollow()
        // just over the edge onto the Dell: not yet
        XCTAssertNil(f.update(shown: "1", pointer: CGPoint(x: 1730, y: 500), displays: all, now: 0))
        XCTAssertNil(f.update(shown: "1", pointer: CGPoint(x: 1731, y: 500), displays: all, now: 0.1))
        // stayed there long enough
        XCTAssertEqual(f.update(shown: "1", pointer: CGPoint(x: 1731, y: 500), displays: all, now: 0.16), "2")
    }

    func testFollowGoesAtOnceWhenThePointerIsWellIn() {
        var f = RemoteDisplayFollow()
        XCTAssertEqual(f.update(shown: "1", pointer: CGPoint(x: 1760, y: 500), displays: all, now: 0), "2")
    }

    func testAPointerDancingOnTheEdgeDoesntFlipFlop() {
        var f = RemoteDisplayFollow()
        var t = 0.0
        for i in 0..<40 {
            let x: CGFloat = i % 2 == 0 ? 1725 : 1732
            XCTAssertNil(f.update(shown: "1", pointer: CGPoint(x: x, y: 500), displays: all, now: t))
            t += 0.03
        }
    }

    func testBetweenDisplaysNothingChanges() {
        var f = RemoteDisplayFollow()
        XCTAssertNil(f.update(shown: "1", pointer: CGPoint(x: -50, y: 1400), displays: all, now: 0))
    }

    func testTheShownDisplayGoneMeansNoWait() {
        var f = RemoteDisplayFollow()
        XCTAssertEqual(f.update(shown: "7", pointer: CGPoint(x: 1, y: 1), displays: all, now: 0), "1")
    }

    func testTheMapIsToScaleAndInTheBox() {
        let box = CGSize(width: 220, height: 96)
        let m = RemoteDisplayMap.layout(all, in: box)
        XCTAssertEqual(m.count, 3)
        for r in m.values { XCTAssertTrue(CGRect(origin: .zero, size: box).insetBy(dx: -1, dy: -1).contains(r)) }
        // the Dell is wider than the laptop, as it is on the desk
        XCTAssertGreaterThan(m["2"]!.width, m["1"]!.width)
        XCTAssertLessThan(m["3"]!.maxX, m["1"]!.minX + 1)
        XCTAssertEqual(RemoteDisplayMap.hit(CGPoint(x: m["2"]!.midX, y: m["2"]!.midY), in: m), "2")
        XCTAssertNil(RemoteDisplayMap.hit(CGPoint(x: -100, y: -100), in: m))
    }

    func testATinyDisplayIsStillATarget() {
        let tiny = RemoteDisplay(id: "8", name: "Sidecar", x: 6000, y: 0, width: 300, height: 200, main: false)
        let m = RemoteDisplayMap.layout([laptop, dell, tiny], in: CGSize(width: 200, height: 80))
        XCTAssertGreaterThanOrEqual(min(m["8"]!.width, m["8"]!.height), 21.9)
    }
}
