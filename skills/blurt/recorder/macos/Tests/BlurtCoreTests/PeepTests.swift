import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import BlurtCore

/// Peep's playback (BlurtCore Peep.swift) and the frames the app ships (Sources/BlurtApp/Resources/Peep, written by
/// assets/brand/import_peep.py from the Peep release package). The menu-bar glyph's old in-frame rule (the hop and the
/// crouch kept their ink half a point inside the box) holds for every frame of every clip now.
final class PeepTests: XCTestCase {
    let talk = PeepClip(frames: 6, fps: 30, open: [1.2, 2.4, 1.6, 2.6, 1.3, 1.2])

    func testLoopsWrapAndOneShotsRestOnTheirLastFrame() {
        let c = PeepClip(frames: 42, fps: 30)
        XCTAssertEqual(PeepPlayback.frame(at: 0, clip: c, loops: true), 0)
        XCTAssertEqual(PeepPlayback.frame(at: 1.0, clip: c, loops: true), 30)
        XCTAssertEqual(PeepPlayback.frame(at: 1.5, clip: c, loops: true), 3)             // 45 % 42
        XCTAssertEqual(PeepPlayback.frame(at: 1.5, clip: c, loops: false), 41)
        XCTAssertEqual(PeepPlayback.frame(at: -1, clip: c, loops: false), 0)
        XCTAssertEqual(c.duration, 1.4, accuracy: 1e-9)
    }

    func testTheBeakFollowsTheLevel() {
        XCTAssertEqual(PeepPlayback.talkingFrame(level: 0, clip: talk), 0, "silence: the most shut frame")
        XCTAssertEqual(PeepPlayback.talkingFrame(level: 1, clip: talk), 3, "loud: the widest")
        let mid = PeepPlayback.talkingFrame(level: 0.4, clip: talk)
        XCTAssertTrue((1.2...2.6).contains(talk.open[mid]) && mid != 0 && mid != 3)
        // louder never shows a more shut beak
        var last = 0.0
        for i in 0...20 {
            let o = talk.open[PeepPlayback.talkingFrame(level: Double(i) / 20, clip: talk)]
            XCTAssertGreaterThanOrEqual(o, last - 1e-9)
            last = o
        }
        XCTAssertEqual(PeepPlayback.talkingFrame(level: 0.7, clip: PeepClip(frames: 4, fps: 30)), 0, "no openings: frame 0")
    }

    func testTheLevelOpensFastAndClosesSlower() {
        let up = PeepPlayback.smooth(0, toward: 1, dt: 1.0 / 30)
        let down = 1 - PeepPlayback.smooth(1, toward: 0, dt: 1.0 / 30)
        XCTAssertGreaterThan(up, down)
        XCTAssertEqual(PeepPlayback.smooth(0.3, toward: 0.9, dt: 10), 0.9, accuracy: 1e-9)
    }

    func testEveryStateHasAStillThatSaysIt() {
        let c = PeepClip(frames: 45, fps: 30)
        for s in PeepState.allCases { XCTAssertTrue((0..<45).contains(PeepPlayback.stillFrame(s, clip: c)), s.rawValue) }
        XCTAssertEqual(PeepPlayback.stillFrame(.idle, clip: c), 0)
        XCTAssertEqual(PeepPlayback.stillFrame(.done, clip: PeepClip(frames: 42, fps: 30)), 26, "the happy closed eye")
        XCTAssertTrue(PeepState.idle.loops && PeepState.talking.loops && !PeepState.done.loops && !PeepState.error.loops)
        XCTAssertEqual(PeepPlayback.idleHold(random: 0.5), 1)
        XCTAssertEqual(PeepPlayback.idleHold(random: 7), 2)
    }

    func testTheMenuBarGlyphSaysWhatBlurtDoes() {
        func m(_ d: Bool = false, _ v: Bool = false, _ c: Bool = false, _ t: Bool = false, _ o: Bool = false) -> PeepGlyphMode {
            PeepGlyphMode.from(dictating: d, voiceNote: v, countdown: c, transcribing: t, organizing: o)
        }
        XCTAssertEqual(m(), .idle)
        XCTAssertEqual(m(true), .talking)
        XCTAssertEqual(m(false, true), .listening)
        XCTAssertEqual(m(false, false, true), .listening)
        XCTAssertEqual(m(false, false, false, true), .thinking)
        XCTAssertEqual(m(false, false, false, false, true), .thinking)
        XCTAssertEqual(m(true, false, false, true, true), .talking, "your voice comes first")
        XCTAssertEqual(m(false, true, false, false, true), .listening)
        XCTAssertEqual(PeepGlyphMode.thinking.state, .thinking)
    }

    // MARK: the shipped frames

    var peepDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BlurtApp/Resources/Peep")
    }

    func manifest() throws -> [String: Any] {
        let d = try Data(contentsOf: peepDir.appendingPathComponent("peep.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
    }

    func image(_ name: String) throws -> CGImage {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(peepDir.appendingPathComponent(name) as CFURL, nil), name)
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil), name)
    }

    /// The alpha of every pixel (row-major, top row first).
    func alpha(_ img: CGImage) -> [UInt8] {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return stride(from: 3, to: px.count, by: 4).map { px[$0] }
    }

    func testEverySheetHasItsClipsAtTheirSize() throws {
        let j = try manifest()
        let sets = try XCTUnwrap(j["sets"] as? [String: [String: Any]])
        let dark = try XCTUnwrap(sets["dark"]), paper = try XCTUnwrap(sets["paper"])
        let darkClips = try XCTUnwrap(dark["clips"] as? [String: [String: Any]])
        XCTAssertEqual(Set(darkClips.keys), Set(PeepState.allCases.map(\.rawValue)), "the notch plays every state")
        let paperClips = try XCTUnwrap(paper["clips"] as? [String: [String: Any]])
        XCTAssertTrue(Set(["idle", "hello", "done"]).isSubset(of: Set(paperClips.keys)), "onboarding, empty states, About")
        for (name, set) in sets {
            let cell = try XCTUnwrap(set["cell"] as? Int), square = try XCTUnwrap(set["square"] as? Int)
            let cols = try XCTUnwrap(set["cols"] as? Int)
            XCTAssertGreaterThan(cell, square)
            for (clip, info) in try XCTUnwrap(set["clips"] as? [String: [String: Any]]) {
                let n = try XCTUnwrap(info["frames"] as? Int)
                let sheet = try image("\(name)-\(clip).webp")
                XCTAssertEqual(sheet.width, cols * cell, "\(name)/\(clip)")
                XCTAssertEqual(sheet.height, Int((Double(n) / Double(cols)).rounded(.up)) * cell, "\(name)/\(clip)")
                if clip == "talking" { XCTAssertEqual((info["open"] as? [Double])?.count, n, "a beak opening per frame") }
            }
        }
    }

    func testEveryGlyphFrameIsATemplateInsideItsBox() throws {
        let j = try manifest()
        let g = try XCTUnwrap(j["glyph"] as? [String: Any])
        XCTAssertEqual(g["box"] as? Int, 18)
        let clips = try XCTUnwrap(g["clips"] as? [String: [String: Any]])
        XCTAssertEqual(Set(clips.keys), Set(PeepState.allCases.map(\.rawValue)))
        for (clip, info) in clips {
            let n = try XCTUnwrap(info["frames"] as? Int)
            for (sfx, cell) in [("", 36), ("@1x", 18)] {
                let strip = try image("glyph-\(clip)\(sfx).png")
                XCTAssertEqual(strip.width, n * cell, clip + sfx)
                XCTAssertEqual(strip.height, cell, clip + sfx)
                guard sfx.isEmpty else { continue }
                let a = alpha(strip)
                let margin = 1                       // half a point at @2x: the hop and the shake never touch the edge
                for f in 0..<n {
                    var minX = cell, maxX = -1, minY = cell, maxY = -1, ink = 0
                    for y in 0..<cell {
                        for x in 0..<cell where a[y * strip.width + f * cell + x] > 24 {
                            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y); ink += 1
                        }
                    }
                    XCTAssertGreaterThan(ink, cell * cell / 5, "\(clip)#\(f): a silhouette, not a speck")
                    XCTAssertGreaterThanOrEqual(minX, margin, "\(clip)#\(f) left")
                    XCTAssertGreaterThanOrEqual(minY, margin, "\(clip)#\(f) top")
                    XCTAssertLessThanOrEqual(maxX, cell - 1 - margin, "\(clip)#\(f) right")
                    XCTAssertLessThanOrEqual(maxY, cell - 1 - margin, "\(clip)#\(f) bottom")
                }
            }
        }
        if let b = (clips["idle"]?["blink"] as? [Int]) { XCTAssertTrue(b.count == 2 && b[0] < b[1]) }
    }
}
