import AVFoundation
import XCTest
@testable import BlurtCore

/// Why a recording failed (dogfood v0.9-2: no cause, and a raw "SCStreamErrorDomain error -3801" in the alert;
/// v0.9-userfix: the 2026-10-26 take ended on AVFoundation -11800 / OSStatus -16341 and was filed as "unknown").
final class RecordingFailureTests: XCTestCase {
    let sc = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
    let av = "AVFoundationErrorDomain"

    func testTheErrorPicksTheReason() {
        let full = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        XCTAssertEqual(RecordingFailure.reason(code: "writer", error: full), .diskFull)
        XCTAssertEqual(RecordingFailure.reason(code: "writer", error: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))), .diskFull)
        // AVAssetWriter wraps the cause: its underlying error counts
        let wrapped = NSError(domain: av, code: -11800,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        XCTAssertEqual(RecordingFailure.reason(code: "writer", error: wrapped), .diskFull)
        XCTAssertEqual(RecordingFailure.reason(code: "writer", error: NSError(domain: av, code: -11807)), .diskFull)
        XCTAssertEqual(RecordingFailure.reason(code: "capture", error: NSError(domain: sc, code: -3801)), .permission)
        XCTAssertEqual(RecordingFailure.reason(code: "capture", error: NSError(domain: "SCStreamErrorDomain", code: -3803)), .permission)
    }

    /// The errors macOS stops a take with, each to a reason that says what happened (and so what to do).
    func testKnownErrorsMapToPlainReasons() {
        let cases: [(String, Int, RecordingFailure)] = [
            (sc, -3815, .displayGone), (sc, -3814, .displayGone),
            (sc, -3821, .interrupted), (sc, -3805, .interrupted), (sc, -3804, .interrupted),
            (av, -11847, .interrupted), (av, -11819, .interrupted),
            (sc, -3811, .stopped),           // ScreenCaptureKit's own internal error: it stopped, no more known
            (av, -11800, .writer), (av, -11823, .writer),
        ]
        for (d, c, want) in cases {
            XCTAssertEqual(RecordingFailure.reason(code: "stream_stopped", error: NSError(domain: d, code: c)), want, "\(d) \(c)")
        }
        // the 2026-10-26 take: never "unknown" again
        let take = NSError(domain: av, code: -11800, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -16341)])
        XCTAssertEqual(RecordingFailure.reason(code: "writer", error: take), .writer)
        // a specific cause under a generic one wins
        let sleep = NSError(domain: av, code: -11800, userInfo: [NSUnderlyingErrorKey: NSError(domain: av, code: -11847)])
        XCTAssertEqual(RecordingFailure.reason(code: "writer", error: sleep), .interrupted)
    }

    func testTheCodeWhenTheErrorSaysNothing() {
        XCTAssertEqual(RecordingFailure.reason(code: "screen_permission", error: nil), .permission)
        XCTAssertEqual(RecordingFailure.reason(code: "stream_stopped", error: NSError(domain: "x", code: 1)), .stopped)
        XCTAssertEqual(RecordingFailure.reason(code: "no_frames", error: nil), .noFrames)
        XCTAssertEqual(RecordingFailure.reason(code: "writer", error: nil), .writer)
        XCTAssertEqual(RecordingFailure.reason(code: nil, error: nil), .unknown)
        XCTAssertEqual(RecordingFailure.reason(code: "setup", error: NSError(domain: "x", code: 1)), .unknown)
    }

    /// meta.json and the log keep the error's domain, code and the errors under it.
    func testDetailKeepsTheWholeChain() {
        let e = NSError(domain: av, code: -11800, userInfo: [
            NSLocalizedDescriptionKey: "这项操作无法完成",
            NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -16341)])
        let d = RecordingFailure.detail(e)
        XCTAssertEqual(d["error_domain"] as? String, av)
        XCTAssertEqual(d["error_code"] as? Int, -11800)
        XCTAssertEqual(d["error_underlying"] as? String, "\(NSOSStatusErrorDomain) -16341")
        XCTAssertEqual(d["error_message"] as? String, "这项操作无法完成")
        XCTAssertTrue(RecordingFailure.detail(nil).isEmpty)
        XCTAssertNil(RecordingFailure.detail(NSError(domain: "x", code: 2))["error_underlying"])
        // deep chains stop at six
        var deep: NSError = NSError(domain: "d", code: 0)
        for i in 1...10 { deep = NSError(domain: "d", code: i, userInfo: [NSUnderlyingErrorKey: deep]) }
        XCTAssertEqual(RecordingFailure.chain(deep).count, 6)
    }

    func testWhatIsRestartedAndWhatEndsTheTake() {
        for c in [-3805, -3804, -3811, -3815, -3821] {
            XCTAssertTrue(RecordingFailure.restartable(NSError(domain: sc, code: c)), "\(c)")
        }
        for c in [-3801, -3803, -3817, -3812] {
            XCTAssertFalse(RecordingFailure.restartable(NSError(domain: sc, code: c)), "\(c)")
        }
        XCTAssertFalse(RecordingFailure.restartable(NSError(domain: av, code: -11800)))
        XCTAssertTrue(RecordingFailure.endedByUser(NSError(domain: sc, code: -3817)))
        XCTAssertFalse(RecordingFailure.endedByUser(NSError(domain: sc, code: -3821)))
        // a writer is replaced, but never for a full disk, and never past the last piece
        let take = NSError(domain: av, code: -11800)
        XCTAssertTrue(RecordingFailure.rollsOver(take, segments: 1))
        XCTAssertFalse(RecordingFailure.rollsOver(take, segments: RecordingFailure.maxSegments))
        XCTAssertFalse(RecordingFailure.rollsOver(NSError(domain: av, code: -11807), segments: 1))
    }

    func testEveryReasonHasWords() throws {
        let res = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/BlurtApp/Resources")
        for lang in ["en", "zh-Hans"] {
            let s = try String(contentsOf: res.appendingPathComponent("\(lang).lproj/Main.strings"), encoding: .utf8)
            for r in RecordingFailure.allCases {
                XCTAssertTrue(s.contains("\"app.record.reason.\(r.rawValue)\""), "\(lang) reason \(r)")
                XCTAssertTrue(s.contains("\"app.record.failed.\(r.rawValue)\""), "\(lang) failed \(r)")
            }
        }
    }

    func testLowSpace() {
        XCTAssertTrue(RecordingFailure.lowSpace(freeBytes: 500_000_000))
        XCTAssertFalse(RecordingFailure.lowSpace(freeBytes: 50_000_000_000))
        XCTAssertFalse(RecordingFailure.lowSpace(freeBytes: nil))
    }

    // MARK: a take in pieces

    func testPiecesKeepTheirPlaceOnTheTimeline() {
        // piece 1 failed at 50 s and plays to 40 (its last fragment); piece 2 started at 50.3 and ran 30 s
        let p = TakeSegments.layout(starts: [0, 50.3], durations: [40, 30])
        XCTAssertEqual(p, [.init(index: 0, at: 0, length: 40), .init(index: 1, at: 50.3, length: 30)])
        XCTAssertEqual(TakeSegments.lost(p), 10.3, accuracy: 0.001)
        // a piece that plays past the next one's start is cut there
        let q = TakeSegments.layout(starts: [0, 10], durations: [12, 5])
        XCTAssertEqual(q.map(\.length), [10, 5])
        XCTAssertEqual(TakeSegments.lost(q), 0)
        // nothing to play: left out
        XCTAssertEqual(TakeSegments.layout(starts: [0, 4, 8], durations: [4, 0, 3]).map(\.index), [0, 2])
    }

    /// Two real mp4 pieces become one file, the second where it started, with nothing re-encoded.
    func testStitchingTwoPieces() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stitch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("recording.mp4"), b = dir.appendingPathComponent("recording.part2.mp4")
        try await Self.writeClip(a, seconds: 1.0)
        try await Self.writeClip(b, seconds: 1.0)
        let r = try await TakeStitch.stitch([a, b], starts: [0, 1.5], into: a)
        XCTAssertEqual(r.pieces, 2)
        XCTAssertEqual(r.lost, 0.5, accuracy: 0.1)
        XCTAssertEqual(r.duration, 2.5, accuracy: 0.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path), "the pieces go once they are in")
        let out = AVURLAsset(url: a)
        let d = try await out.load(.duration).seconds
        XCTAssertEqual(d, 2.5, accuracy: 0.15)
        let tracks = try await out.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
    }

    /// A short H.264 clip (64 × 64, 30 fps), as the Recorder writes it (no frame reordering).
    static func writeClip(_ url: URL, seconds: Double) async throws {
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false]])
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64])
        w.add(v)
        XCTAssertTrue(w.startWriting())
        w.startSession(atSourceTime: .zero)
        let n = Int(seconds * 30)
        for i in 0..<n {
            while !v.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            memset(CVPixelBufferGetBaseAddress(pb!), Int32(i * 8 % 255), CVPixelBufferGetDataSize(pb!))
            CVPixelBufferUnlockBaseAddress(pb!, [])
            ad.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        v.markAsFinished()
        w.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        await w.finishWriting()
        XCTAssertEqual(w.status, .completed)
    }
}
