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

    // MARK: control titles (widths are SF 13 pt measurements)

    func testTheReviewChangesFailureAlertsCutButtonIsFlaggedByGeometry() {
        // w42-after-merge-codex: the 360-pt alert, "End Session and Mer…" in a 147 x 24 bordered button
        XCTAssertTrue(LayoutLint.controlTitleClipped(titleWidth: 142.0, fontSize: 13, frame: CGSize(width: 147, height: 24)))
        // Close and Try Again beside it fit (their measured bezels: 24 pt)
        XCTAssertFalse(LayoutLint.controlTitleClipped(titleWidth: 34.1, fontSize: 13, frame: CGSize(width: 58.5, height: 24)))
        XCTAssertFalse(LayoutLint.controlTitleClipped(titleWidth: 56.6, fontSize: 13, frame: CGSize(width: 81, height: 24)))
        // the same button at its natural width (text + 24) and the 480-pt panel's: clean
        XCTAssertFalse(LayoutLint.controlTitleClipped(titleWidth: 142.0, fontSize: 13, frame: CGSize(width: 166, height: 24)))
    }

    func testPlainButtonsHaveNoBezelAndSmallOnesAreMeasuredAtTheirFont() {
        // a borderless text button is as tall as its line and exactly as wide as its text
        XCTAssertFalse(LayoutLint.controlTitleClipped(titleWidth: 115.3, fontSize: 13, frame: CGSize(width: 115.5, height: 16)))
        XCTAssertTrue(LayoutLint.controlTitleClipped(titleWidth: 115.3, fontSize: 13, frame: CGSize(width: 90, height: 16)))
        // small (11 pt, 20 high): "Commit and Merge" is 99.6 wide, natural 120
        XCTAssertFalse(LayoutLint.controlTitleClipped(titleWidth: 99.6, fontSize: 11, frame: CGSize(width: 120, height: 20)))
        XCTAssertTrue(LayoutLint.controlTitleClipped(titleWidth: 99.6, fontSize: 11, frame: CGSize(width: 100, height: 20)))
    }

    func testIconOnlyButtonsAreNotTitles() {
        XCTAssertTrue(LayoutLint.iconOnly(frame: CGSize(width: 14, height: 14)))                      // square.and.pencil
        XCTAssertTrue(LayoutLint.iconOnly(frame: CGSize(width: 42, height: 25)))                      // a template image
        XCTAssertTrue(LayoutLint.iconOnly(frame: CGSize(width: 38, height: 12.5), symbolIdentifier: true)) // the ⋯ capsule
        XCTAssertFalse(LayoutLint.iconOnly(frame: CGSize(width: 65, height: 24)))                     // "Co…" is text
    }

    func testAPopUpWhoseTitleDoesntFit() {
        // "A very long popup choice title" (156 pt) in a 90-pt pop-up: its cell draws the title in 55.5 pt
        XCTAssertTrue(LayoutLint.popupTitleClipped(titleWidth: 156.1, titleRectWidth: 55.5))
        // "GPT-6-Astra (default)" in the hand-off panel's model pop-up at its width
        XCTAssertFalse(LayoutLint.popupTitleClipped(titleWidth: 132.4, titleRectWidth: 140))
        XCTAssertFalse(LayoutLint.popupTitleClipped(titleWidth: 0, titleRectWidth: 0))                // an icon menu
    }

    func testTheReviewChangesSplitButtonIsFoundInTheRendering() {
        // w42-review-changes-codex: the 480 x 215 panel; "Commit and Merge" + divider + chevron in a 148-pt button.
        // Geometry alone can't see it (115.3 + its bezel fits 148; the chevron's 26 pt are invisible to it) …
        let merge = LayoutNode(role: "AXButton", label: "Commit and Merge", frame: CGRect(x: 308, y: 167, width: 148, height: 24))
        let cancel = LayoutNode(role: "AXButton", label: "Cancel", frame: CGRect(x: 234, y: 167, width: 66, height: 24))
        let more = LayoutNode(role: "AXMenuButton", label: "More", frame: CGRect(x: 24, y: 171, width: 38, height: 17))
        XCTAssertFalse(LayoutLint.controlTitleClipped(titleWidth: 115.3, fontSize: 13, frame: merge.frame.size))
        // … the rendering read back shows it: "Commit and Mer…" inside the button
        let texts: [(String, CGRect)] = [("Cancel", CGRect(x: 248, y: 172, width: 40, height: 14)),
                                         ("Commit and Mer... | v", CGRect(x: 314, y: 172, width: 115, height: 14)),
                                         ("1 file changed", CGRect(x: 36, y: 78, width: 100, height: 16))]
        let nodes = [more, cancel, merge]
        XCTAssertEqual(LayoutLint.cutTitles(nodes, texts: texts), [2])
        var flagged = nodes
        for i in LayoutLint.cutTitles(nodes, texts: texts) { flagged[i].truncated = true }
        let p = LayoutLint.check(flagged, window: CGSize(width: 480, height: 215))
        XCTAssertEqual(p.map(\.kind), ["truncated"])
        XCTAssertEqual(p.first?.label, "Commit and Merge")
        // the fixed panel shows the whole title: nothing
        XCTAssertEqual(LayoutLint.cutTitles(nodes, texts: [("Commit and Merge", CGRect(x: 314, y: 172, width: 115, height: 14))]), [])
    }

    func testShowsCut() {
        XCTAssertTrue(LayoutLint.showsCut(label: "End Session and Merge", shown: "End Session and Mer…"))
        XCTAssertTrue(LayoutLint.showsCut(label: "结束会话并合并", shown: "结束会话并…"))
        XCTAssertTrue(LayoutLint.showsCut(label: "Commit and Merge", shown: "commit and mer..."))   // case, the dots
        XCTAssertFalse(LayoutLint.showsCut(label: "Sign In…", shown: "Sign In…"))                 // the title's own …
        XCTAssertFalse(LayoutLint.showsCut(label: "Open Diff", shown: "Open Diff"))
        XCTAssertFalse(LayoutLint.showsCut(label: "Commit and Merge", shown: "Discard…"))          // another text
        XCTAssertTrue(LayoutLint.showsCut(label: "A very long popup choice title", shown: "A very l... ="))  // the arrows
        XCTAssertFalse(LayoutLint.showsCut(label: "Commit and Merge", shown: "Commit and Mer… then more words"))
        XCTAssertFalse(LayoutLint.showsCut(label: "Commit", shown: "C…"))                         // one letter says nothing
    }
}
