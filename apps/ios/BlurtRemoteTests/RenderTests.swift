// The real main screen, laid out at each room's size in a window of that size, drawn to a PNG: how it looks on devices this Mac
// can't run (the Duo's folds) and every iPad multitasking size, to judge by eye. Set TEST_RUNNER_BLURT_RENDER_DIR to keep the images;
// a magenta band marks where the fold is.
import XCTest
@testable import BlurtRemote

final class RenderTests: XCTestCase {
    private var dir: URL? {
        ProcessInfo.processInfo.environment["BLURT_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @MainActor
    private func render(_ room: Rooms.Room, screen: Bool, lefty: Bool = false) throws -> UIImage {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { throw XCTSkip("no scene") }
        Pretend.connected = true
        Pretend.screen = screen
        Pretend.surround = room.surround
        let wasLefty = Prefs.shared.lefty
        Prefs.shared.lefty = lefty
        defer { Prefs.shared.lefty = wasLefty; Pretend.surround = nil; Pretend.screen = false }
        let w = UIWindow(windowScene: scene)
        w.frame = CGRect(origin: .zero, size: room.size)
        let c = PadViewController()
        w.rootViewController = c
        w.isHidden = false
        w.layoutIfNeeded()
        let have = c.view.safeAreaInsets
        c.additionalSafeAreaInsets = UIEdgeInsets(top: max(0, room.safe.top - have.top), left: max(0, room.safe.left - have.left),
                                                  bottom: max(0, room.safe.bottom - have.bottom), right: max(0, room.safe.right - have.right))
        c.view.setNeedsLayout()
        w.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        w.layoutIfNeeded()
        let f = UIGraphicsImageRendererFormat()
        f.scale = 2
        let image = UIGraphicsImageRenderer(size: room.size, format: f).image { ctx in
            w.layer.render(in: ctx.cgContext)
            if let fold = room.surround.fold {
                UIColor(red: 1, green: 0.2, blue: 0.8, alpha: room.surround.foldActive ? 0.35 : 0.5).setFill()
                ctx.fill(fold.width < 3 || fold.height < 3 ? fold.insetBy(dx: fold.width < 3 ? -0.5 : 0, dy: fold.height < 3 ? -0.5 : 0) : fold)
            }
            for o in room.surround.occlusions {
                UIColor(white: 0.25, alpha: 1).setFill()
                UIBezierPath(roundedRect: o.insetBy(dx: 14, dy: 14), cornerRadius: 16).fill()
            }
        }
        w.isHidden = true
        return image
    }

    @MainActor
    func testRenderEveryRoom() throws {
        for room in Rooms.all {
            for screen in [false, true] {
                let i = try render(room, screen: screen)
                XCTAssertEqual(i.size, room.size)
                if let d = dir {
                    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                    try i.pngData()?.write(to: d.appendingPathComponent("\(room.name)\(screen ? "-screen" : "").png"))
                }
            }
        }
        // left-handed, where it differs most
        for room in Rooms.all where ["duo-inner-open", "ipad11-landscape", "duo-inner-book"].contains(room.name) {
            let i = try render(room, screen: true, lefty: true)
            if let d = dir { try i.pngData()?.write(to: d.appendingPathComponent("\(room.name)-screen-lefty.png")) }
        }
    }
}
