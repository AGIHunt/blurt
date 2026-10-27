import CoreGraphics
import XCTest
@testable import BlurtCore

/// The layout lint's rules (LayoutLint.swift); the app's `layoutcheck` hook only collects the elements.
final class LayoutLintTests: XCTestCase {
    let size = CGSize(width: 840, height: 600)

    func testTheSetupAssistantsCutOffNextButtonIsFlagged() {
        // 65475278: the window sized without the title bar the SwiftUI layout keeps out of — Next 2 pt under the edge
        let nodes = [LayoutNode(role: "AXLink", label: "Skip Setup", frame: CGRect(x: 228, y: 582, width: 65.5, height: 16)),
                     LayoutNode(role: "AXButton", label: "Next", frame: CGRect(x: 754.5, y: 578, width: 57.5, height: 24))]
        let p = LayoutLint.check(nodes, window: size)
        XCTAssertEqual(p.map(\.label), ["Next"])
        XCTAssertEqual(p.first?.kind, "outside_window")
        XCTAssertEqual(p.first?.bounds, CGRect(origin: .zero, size: size))
        // the fixed window (32 pt taller): clean
        XCTAssertEqual(LayoutLint.check(nodes, window: CGSize(width: 840, height: 632)), [])
    }

    func testTextGetsFourPointsOfTolerance() {
        let inside = LayoutNode(role: "AXStaticText", label: "Hello", frame: CGRect(x: -3, y: 590, width: 100, height: 13))
        let outside = LayoutNode(role: "AXStaticText", label: "Bye", frame: CGRect(x: 10, y: 590, width: 100, height: 20))
        XCTAssertEqual(LayoutLint.check([inside, outside], window: size).map(\.label), ["Bye"])
    }

    func testOnlyControlsTextsAndLabelledImagesCount() {
        let nodes = [LayoutNode(role: "AXGroup", frame: CGRect(x: 0, y: 0, width: 900, height: 900)),
                     LayoutNode(role: "AXImage", label: "", frame: CGRect(x: 800, y: 580, width: 80, height: 80)),
                     LayoutNode(role: "AXImage", label: "Chick", frame: CGRect(x: 800, y: 580, width: 80, height: 80)),
                     LayoutNode(role: "AXButton", subrole: "AXCloseButton", frame: CGRect(x: -20, y: -20, width: 16, height: 16))]
        XCTAssertEqual(LayoutLint.check(nodes, window: size).map(\.label), ["Chick"])
    }

    func testScrolledOutOfSightIsNotAProblemButAScrollAreaPastTheEdgeIs() {
        let clip = CGRect(x: 0, y: 100, width: 840, height: 400)
        let below = LayoutNode(role: "AXButton", label: "Far down", frame: CGRect(x: 10, y: 900, width: 80, height: 24), clip: clip)
        let half = LayoutNode(role: "AXButton", label: "Half", frame: CGRect(x: 10, y: 490, width: 80, height: 24), clip: clip)
        XCTAssertEqual(LayoutLint.check([below, half], window: size), [])
        // the scroll area itself runs 100 pt past the window's bottom: its visible rows there are cut
        let tall = CGRect(x: 0, y: 100, width: 840, height: 600)
        let row = LayoutNode(role: "AXButton", label: "Row", frame: CGRect(x: 10, y: 640, width: 80, height: 24), clip: tall)
        XCTAssertEqual(LayoutLint.check([row], window: size).map(\.kind), ["outside_window"])
    }

    func testTrafficLights() {
        let lights = [CGRect(x: 8, y: 8, width: 62, height: 16)]
        let under = LayoutNode(role: "AXButton", label: "Back", frame: CGRect(x: 20, y: 6, width: 60, height: 20))
        let beside = LayoutNode(role: "AXButton", label: "Search", frame: CGRect(x: 90, y: 6, width: 60, height: 20))
        let p = LayoutLint.check([under, beside], window: size, trafficLights: lights)
        XCTAssertEqual(p.map(\.kind), ["under_traffic_lights"])
        XCTAssertEqual(p.first?.label, "Back")
    }

    func testOverlappingControlsButNotNestedOnes() {
        let a = LayoutNode(role: "AXButton", label: "Save", frame: CGRect(x: 100, y: 100, width: 80, height: 24))
        let b = LayoutNode(role: "AXButton", label: "Cancel", frame: CGRect(x: 160, y: 100, width: 80, height: 24))
        let p = LayoutLint.check([a, b], window: size)
        XCTAssertEqual(p.map(\.kind), ["overlap"])
        XCTAssertEqual(p.first?.other, "AXButton Cancel")
        XCTAssertEqual(p.first?.bounds, b.frame)
        // a button inside a row-like control, or touching by a hairline: not an overlap
        let row = LayoutNode(role: "AXButton", label: "Row", frame: CGRect(x: 0, y: 200, width: 400, height: 40))
        let inner = LayoutNode(role: "AXButton", label: "More", frame: CGRect(x: 360, y: 208, width: 24, height: 24), parent: 0)
        let next = LayoutNode(role: "AXButton", label: "Next", frame: CGRect(x: 400 - 1, y: 200, width: 80, height: 40))
        XCTAssertEqual(LayoutLint.check([row, inner, next], window: size), [])
        // texts may sit over each other's controls (a label next to its toggle reports its own frame)
        let text = LayoutNode(role: "AXStaticText", label: "Label", frame: a.frame)
        XCTAssertEqual(LayoutLint.check([a, text], window: size), [])
    }

    func testTruncatedAndDuplicatesReportedOnce() {
        let t = LayoutNode(role: "AXStaticText", label: "A long sentence", frame: CGRect(x: 10, y: 10, width: 40, height: 16), truncated: true)
        let p = LayoutLint.check([t, t], window: size)
        XCTAssertEqual(p.map(\.kind), ["truncated"])
        XCTAssertEqual(p.first?.json["frame"] as? [Double], [10, 10, 40, 16])
    }
}
