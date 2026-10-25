// Why a recording failed, in words a person can act on (BlurtApp Recorder / AppDelegate.takeEnded). dogfood v0.9-2:
// a take whose writer failed said only "The recording couldn't be saved · its snap and notes ar…" (cut off, no cause),
// and the alert without stills showed the raw error ("…SCStreamErrorDomain error -3801", or "?"). Now the error's
// domain and code (its underlying errors too) pick a reason; the raw text stays in the log and meta.json.
//  • disk_full — no space left (Cocoa 640, POSIX ENOSPC 28, AVFoundation -11807)
//  • permission — macOS refused the screen (ScreenCaptureKit -3801 "user declined"; the up-front probe failing)
//  • stopped — the screen capture stopped partway (a display unplugged, the session locked)
//  • no_frames — no picture came in at all
//  • unknown — anything else
// `lowSpace`: below this much free space a take starts with a warning (an hour of a Retina screen is ~5 GB).
// Pure: RecordingFailureTests.
import Foundation

public enum RecordingFailure: String, Equatable {
    case diskFull = "disk_full", permission, stopped, noFrames = "no_frames", unknown

    /// The reason for a take that ended with `code` (Recorder's "error" event code) and `error` (nil: none).
    public static func reason(code: String?, error: Error?) -> RecordingFailure {
        var e = error.map { $0 as NSError }
        while let n = e {
            if let r = reason(domain: n.domain, code: n.code) { return r }
            e = n.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        switch code {
        case "screen_permission": return .permission
        case "stream_stopped": return .stopped
        case "no_frames": return .noFrames
        default: return .unknown
        }
    }

    static func reason(domain: String, code: Int) -> RecordingFailure? {
        switch (domain, code) {
        case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError), (NSPOSIXErrorDomain, Int(ENOSPC)), ("AVFoundationErrorDomain", -11807):
            return .diskFull
        case ("com.apple.ScreenCaptureKit.SCStreamErrorDomain", -3801), ("SCStreamErrorDomain", -3801):
            return .permission
        default:
            return nil
        }
    }

    /// Less free space than this (bytes) when a take starts: say so first.
    public static let lowSpaceBytes: Int64 = 2_000_000_000
    public static func lowSpace(freeBytes: Int64?) -> Bool { freeBytes.map { $0 < lowSpaceBytes } ?? false }
}
