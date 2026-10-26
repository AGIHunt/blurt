import XCTest
@testable import BlurtCore

/// The countdown's window over a small region shows the whole panel (review v0.9-userfix: the ring and "Start now"
/// were cut off on a 260 × 200 region).
final class OverlayFitTests: XCTestCase {
    let panel = CGSize(width: 350, height: 234)
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testABigRegionIsTheWindow() {
        let r = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(OverlayFit.frame(region: r, panel: panel, margin: 40, screen: screen), r)
    }

    func testASmallRegionGrowsAroundItsCentre() {
        let r = CGRect(x: 300, y: 200, width: 260, height: 200)
        let f = OverlayFit.frame(region: r, panel: panel, margin: 40, screen: screen)
        XCTAssertEqual(f.size, CGSize(width: 430, height: 314))
        XCTAssertEqual(f.midX, r.midX, accuracy: 0.5)
        XCTAssertEqual(f.midY, r.midY, accuracy: 0.5)
        // one side grows, the other is the region's
        let wide = OverlayFit.frame(region: CGRect(x: 300, y: 200, width: 900, height: 120), panel: panel, margin: 40, screen: screen)
        XCTAssertEqual(wide.size, CGSize(width: 900, height: 314))
    }

    func testItStaysOnTheScreen() {
        let corner = CGRect(x: 0, y: 0, width: 120, height: 90)
        let f = OverlayFit.frame(region: corner, panel: panel, margin: 40, screen: screen)
        XCTAssertEqual(f.origin, .zero)
        let top = CGRect(x: 1400, y: 900, width: 112, height: 82)
        let g = OverlayFit.frame(region: top, panel: panel, margin: 40, screen: screen)
        XCTAssertEqual(g.maxX, screen.maxX)
        XCTAssertEqual(g.maxY, screen.maxY)
    }
}
