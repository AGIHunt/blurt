// Several displays (docs/design/remote.md §Several displays): the switcher on the real main screen, the map where the keys are and never
// over the picture, and the pointer's prediction across displays. With BLURT_RENDER_DIR set the screens are kept as PNGs.
import BlurtRemoteKit
import XCTest
@testable import BlurtRemote

final class DisplaySwitchTests: XCTestCase {
    let laptop = RemoteDisplay(id: "1", name: "Built-in Retina Display", x: 0, y: 0, width: 1728, height: 1117, main: true)
    let dell = RemoteDisplay(id: "4", name: "DELL P2725QE", x: 1728, y: 0, width: 1920, height: 1080, main: false)

    private var dir: URL? { ProcessInfo.processInfo.environment["BLURT_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }

    func testAStrokeCrossesOntoTheNeighbourAndStopsAtTheOuterEdge() {
        let all = [laptop, dell]
        let size = CGSize(width: 1728, height: 1117)
        // from the laptop's right edge, 100 pt further: onto the Dell, off this picture
        let p = ScreenStream.moved(CGPoint(x: 0.99, y: 0.5), by: CGPoint(x: 100, y: 0), on: size, display: "1", displays: all)
        XCTAssertGreaterThan(p.x, 1)
        // from its left edge, nothing is there: it stops
        let q = ScreenStream.moved(CGPoint(x: 0.01, y: 0.5), by: CGPoint(x: -100, y: 0), on: size, display: "1", displays: all)
        XCTAssertEqual(q.x, 0, accuracy: 0.001)
        // one display: the edge of the picture is the edge
        let r = ScreenStream.moved(CGPoint(x: 0.99, y: 0.5), by: CGPoint(x: 100, y: 0), on: size, display: "1", displays: [laptop])
        XCTAssertEqual(r.x, 1)
    }

    func testTheGlyphIsDrawn() {
        let i = ScreenButton.arrangement([laptop, dell], shown: "4", ink: .white)
        XCTAssertEqual(i.size, CGSize(width: 30, height: 21))
    }

    @MainActor
    private func screen(_ size: CGSize, safe: UIEdgeInsets, name: String, steps: Int?, pinned: String? = nil) throws -> PadViewController {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { throw XCTSkip("no scene") }
        Pretend.connected = true
        Pretend.screen = true
        Link.shared.pretend(displays: [laptop, dell], shown: "4", pinned: pinned)
        defer { Pretend.screen = false }
        let w = UIWindow(windowScene: scene)
        w.frame = CGRect(origin: .zero, size: size)
        let c = PadViewController()
        w.rootViewController = c
        w.isHidden = false
        w.layoutIfNeeded()
        let have = c.view.safeAreaInsets
        c.additionalSafeAreaInsets = UIEdgeInsets(top: max(0, safe.top - have.top), left: max(0, safe.left - have.left),
                                                  bottom: max(0, safe.bottom - have.bottom), right: max(0, safe.right - have.right))
        c.view.setNeedsLayout()
        w.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        c.testMap(steps: steps)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        if let d = dir {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            let f = UIGraphicsImageRendererFormat()
            f.scale = 3
            let i = UIGraphicsImageRenderer(size: size, format: f).image { w.layer.render(in: $0.cgContext) }
            try i.pngData()?.write(to: d.appendingPathComponent("displays-\(name).png"))
        }
        return c
    }

    @MainActor
    func testTheMapTakesTheKeysPlaceNotThePictures() throws {
        for (name, size, safe) in [("portrait", CGSize(width: 402, height: 874), UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)),
                                   ("landscape", CGSize(width: 874, height: 402), UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62)),
                                   ("ipad", CGSize(width: 1376, height: 1032), UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0))] {
            for (kind, steps) in [("held", nil), ("slid", 1)] as [(String, Int?)] {
                let c = try screen(size, safe: safe, name: "\(name)-\(kind)", steps: steps)
                let map = try XCTUnwrap(c.view.subviews.first { $0 is DisplayMap }, "\(name): the map is up")
                XCTAssertFalse(map.frame.isEmpty)
                XCTAssertTrue(c.view.bounds.contains(map.frame), "\(name): on screen")
                c.testCloseMap()
            }
        }
        _ = try screen(CGSize(width: 402, height: 874), safe: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0), name: "portrait-pinned", steps: nil, pinned: "4")
    }
}
