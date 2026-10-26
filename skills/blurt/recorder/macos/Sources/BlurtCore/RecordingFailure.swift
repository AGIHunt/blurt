// Why a recording failed, in words a person can act on (BlurtApp Recorder / AppDelegate.takeEnded). dogfood v0.9-2:
// a take whose writer failed said only "The recording couldn't be saved · its snap and notes ar…" (cut off, no cause),
// and the alert without stills showed the raw error ("…SCStreamErrorDomain error -3801", or "?"). Now the error's
// domain and code (its underlying errors too) pick a reason; the raw text stays in the log and meta.json.
//  • disk_full — no space left (Cocoa 640, POSIX ENOSPC 28, AVFoundation -11807)
//  • permission — macOS refused the screen (ScreenCaptureKit -3801 "user declined", -3803 entitlements; the up-front
//    probe failing)
//  • display_gone — the screen being recorded went away (ScreenCaptureKit -3815 "no capture source", -3814: a display
//    unplugged, or gone and not back after a restart)
//  • interrupted — macOS paused the capture or the encoder (sleep, lock, the screen saver, media services reset:
//    ScreenCaptureKit -3821 / -3805 / -3804, AVFoundation -11847 / -11819)
//  • writer — the video file couldn't be written on (AVFoundation's other errors; v0.9-userfix: the 2026-10-26 take
//    ended at 50 s on AVFoundationErrorDomain -11800 over OSStatus -16341 from the mp4 fragment writer, and was
//    reported as "unknown" with only "这项操作无法完成" kept — the domain and the codes were thrown away)
//  • stopped — the screen capture stopped partway for another reason
//  • no_frames — no picture came in at all
//  • unknown — anything else
// `detail`: the error's whole chain (domain, code, each underlying error) for meta.json and the log, so a failure is
// never just "unknown" again. `restartable`: a stream stop worth one more try (the Recorder restarts the capture and
// keeps writing); `endedByUser`: the user stopped sharing from macOS's menu (-3817) — a finished take, not a failure.
// `lowSpace`: below this much free space a take starts with a warning (an hour of a Retina screen is ~5 GB).
// Pure: RecordingFailureTests.
import Foundation

public enum RecordingFailure: String, Equatable, CaseIterable {
    case diskFull = "disk_full", permission, displayGone = "display_gone", interrupted, writer, stopped
    case noFrames = "no_frames", unknown

    static let scDomains: Set<String> = ["com.apple.ScreenCaptureKit.SCStreamErrorDomain", "SCStreamErrorDomain"]
    static let avDomain = "AVFoundationErrorDomain"

    /// The reason for a take that ended with `code` (Recorder's "error" event code) and `error` (nil: none). A cause
    /// anywhere in the chain (an underlying "disk full" under AVFoundation's generic -11800) wins over the generic
    /// error around it.
    public static func reason(code: String?, error: Error?) -> RecordingFailure {
        let errors = chain(error)
        for e in errors { if let r = specific(domain: e.domain, code: e.code) { return r } }
        for e in errors { if let r = generic(domain: e.domain) { return r } }
        switch code {
        case "screen_permission": return .permission
        case "stream_stopped": return .stopped
        case "no_frames": return .noFrames
        case "writer": return .writer
        default: return .unknown
        }
    }

    static func specific(domain: String, code: Int) -> RecordingFailure? {
        switch (domain, code) {
        case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError), (NSPOSIXErrorDomain, Int(ENOSPC)), (avDomain, -11807):
            return .diskFull
        case (avDomain, -11847), (avDomain, -11819):
            return .interrupted
        default:
            break
        }
        guard scDomains.contains(domain) else { return nil }
        switch code {
        case -3801, -3803: return .permission
        case -3815, -3814: return .displayGone
        case -3821, -3805, -3804: return .interrupted
        default: return nil
        }
    }

    static func generic(domain: String) -> RecordingFailure? {
        if domain == avDomain { return .writer }
        if scDomains.contains(domain) { return .stopped }
        return nil
    }

    /// The error and each error under it (NSUnderlyingErrorKey, then NSMultipleUnderlyingErrorsKey's first), outermost
    /// first; at most 6 deep.
    public static func chain(_ error: Error?) -> [(domain: String, code: Int)] {
        var out: [(String, Int)] = []
        var e = error.map { $0 as NSError }
        while let n = e, out.count < 6 {
            out.append((n.domain, n.code))
            e = n.userInfo[NSUnderlyingErrorKey] as? NSError
                ?? (n.userInfo["NSMultipleUnderlyingErrorsKey"] as? [NSError])?.first
        }
        return out
    }

    /// What meta.json and the log keep of an error: its domain and code, the errors under it ("NSOSStatusErrorDomain
    /// -16341"), and its message. Empty for nil.
    public static func detail(_ error: Error?) -> [String: Any] {
        let c = chain(error)
        guard let first = c.first, let e = error.map({ $0 as NSError }) else { return [:] }
        var d: [String: Any] = ["error_domain": first.domain, "error_code": first.code,
                                "error_message": e.localizedDescription]
        let under = c.dropFirst().map { "\($0.domain) \($0.code)" }
        if !under.isEmpty { d["error_underlying"] = under.joined(separator: " · ") }
        if let f = e.localizedFailureReason, !f.isEmpty { d["error_failure_reason"] = f }
        return d
    }

    /// A stream stop the Recorder tries once more (up to `maxRestarts` times in a take): the connection to the capture
    /// service dropped, the system stopped the stream (sleep, the screen locked, a display reconfigured) or lost its
    /// source for a moment. A refusal or the user's own stop never is.
    public static func restartable(_ error: Error?) -> Bool {
        guard let e = chain(error).first, scDomains.contains(e.domain) else { return false }
        return [-3805, -3804, -3811, -3815, -3821].contains(e.code)
    }
    public static let maxRestarts = 3

    /// The user stopped the screen sharing from macOS itself (the menu bar's capture indicator): the take ends as if
    /// Finish was pressed.
    public static func endedByUser(_ error: Error?) -> Bool {
        guard let e = chain(error).first else { return false }
        return scDomains.contains(e.domain) && e.code == -3817
    }

    /// A writer that failed mid-take is replaced by a new one (a new segment of the take) this many times at most; a
    /// full disk never is (a new file would fail the same way).
    public static let maxSegments = 4
    public static func rollsOver(_ error: Error?, segments: Int) -> Bool {
        segments < maxSegments && reason(code: "writer", error: error) != .diskFull
    }

    /// Less free space than this (bytes) when a take starts: say so first.
    public static let lowSpaceBytes: Int64 = 2_000_000_000
    public static func lowSpace(freeBytes: Int64?) -> Bool { freeBytes.map { $0 < lowSpaceBytes } ?? false }
}

/// A take recorded in more than one piece (a writer replaced mid-take, RecordingFailure.rollsOver): where each piece
/// goes on the take's timeline. `starts`: each piece's first moment, seconds from the take's start; `durations`: how
/// much of each piece plays. A piece never overlaps the one before it (a later start wins over a longer piece: the
/// earlier piece is cut), and a piece with nothing to play is left out. Pure: RecordingFailureTests.
public enum TakeSegments {
    public struct Place: Equatable {
        public let index: Int
        public let at: Double
        public let length: Double
        public init(index: Int, at: Double, length: Double) { self.index = index; self.at = at; self.length = length }
    }

    public static func layout(starts: [Double], durations: [Double]) -> [Place] {
        var out: [Place] = []
        let n = min(starts.count, durations.count)
        for i in 0..<n {
            let at = max(0, starts[i])
            var len = max(0, durations[i])
            if i + 1 < n { len = min(len, max(0, starts[i + 1] - at)) }
            if let last = out.last, at < last.at + last.length { continue }
            if len >= 0.05 { out.append(Place(index: i, at: at, length: len)) }
        }
        return out
    }

    /// The seconds lost between pieces (what was being recorded while a writer failed and the next one started).
    public static func lost(_ places: [Place]) -> Double {
        zip(places, places.dropFirst()).reduce(0) { $0 + max(0, $1.1.at - ($1.0.at + $1.0.length)) }
    }
}
