import XCTest
@testable import BlurtCore

/// Why a recording failed (dogfood v0.9-2: no cause, and a raw "SCStreamErrorDomain error -3801" in the alert).
final class RecordingFailureTests: XCTestCase {
    func testTheErrorPicksTheReason() {
        let full = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        XCTAssertEqual(RecordingFailure.reason(code: "writer", error: full), .diskFull)
        XCTAssertEqual(RecordingFailure.reason(code: "writer", error: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))), .diskFull)
        // AVAssetWriter wraps the cause: its underlying error counts
        let av = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                         userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        XCTAssertEqual(RecordingFailure.reason(code: "writer", error: av), .diskFull)
        XCTAssertEqual(RecordingFailure.reason(code: "writer", error: NSError(domain: "AVFoundationErrorDomain", code: -11807)), .diskFull)
        let declined = NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3801)
        XCTAssertEqual(RecordingFailure.reason(code: "capture", error: declined), .permission)
    }

    func testTheCodeWhenTheErrorSaysNothing() {
        XCTAssertEqual(RecordingFailure.reason(code: "screen_permission", error: nil), .permission)
        XCTAssertEqual(RecordingFailure.reason(code: "stream_stopped", error: NSError(domain: "x", code: 1)), .stopped)
        XCTAssertEqual(RecordingFailure.reason(code: "no_frames", error: nil), .noFrames)
        XCTAssertEqual(RecordingFailure.reason(code: "writer", error: NSError(domain: "AVFoundationErrorDomain", code: -11800)), .unknown)
        XCTAssertEqual(RecordingFailure.reason(code: nil, error: nil), .unknown)
    }

    func testLowSpace() {
        XCTAssertTrue(RecordingFailure.lowSpace(freeBytes: 500_000_000))
        XCTAssertFalse(RecordingFailure.lowSpace(freeBytes: 50_000_000_000))
        XCTAssertFalse(RecordingFailure.lowSpace(freeBytes: nil))
    }
}
