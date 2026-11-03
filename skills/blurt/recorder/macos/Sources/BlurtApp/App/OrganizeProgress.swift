// How long organizing a recording usually takes on this Mac (BA-61), measured, never assumed: the process jobs that
// organized a whole recording before (their start and end, in $BLURT_HOME/jobs) against their video's length (the
// session's meta.json "duration"); BlurtCore OrganizeEstimate draws the line. Until three such runs exist, nothing is
// said about time — only that it is organizing and where.
import AppKit
import BlurtCore

enum OrganizeProgress {
    /// session path → its video's length (meta.json), read once
    private static var lengths: [String: Double] = [:]

    static func videoLength(_ session: URL) -> Double? {
        if let d = lengths[session.path] { return d }
        guard let data = try? Data(contentsOf: session.appendingPathComponent("meta.json")),
              let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = (m["duration"] as? NSNumber)?.doubleValue, d > 0 else { return nil }
        lengths[session.path] = d
        return d
    }

    /// The runs this Mac has made: whole recordings (no capture list), done, with a start and an end.
    static func pastRuns() -> [OrganizeEstimate.Run] {
        JobStore.shared.jobs.compactMap { j -> OrganizeEstimate.Run? in
            guard j.type == .process, j.state == .done, j.captures.isEmpty, let s = j.session, let a = j.started, let b = j.ended,
                  FileManager.default.fileExists(atPath: s.appendingPathComponent("recording.mp4").path) || VideoRetention.isRecording(s),
                  let v = videoLength(s) else { return nil }
            return OrganizeEstimate.Run(video: v, took: b.timeIntervalSince(a))
        }
    }

    /// The usual run for a video of `video` seconds (nil: not enough runs measured yet).
    static func usual(video: Double) -> Double? {
        let r = OrganizeEstimate.seconds(video: video, past: pastRuns())
        emit(["event": "organize_estimate", "video": video, "runs": pastRuns().count, "usual": r ?? NSNull()])
        return r
    }

    /// For a recording being organized: "about 3 min left" (nil when there is no measure, or it is past the usual).
    static func leftText(_ j: Job) -> String? {
        guard j.type == .process, j.isActive, j.captures.isEmpty, let s = j.session, let v = videoLength(s),
              let usual = OrganizeEstimate.seconds(video: v, past: pastRuns()) else { return nil }
        let since = Date().timeIntervalSince(j.started ?? j.created)
        return OrganizeEstimate.minutesLeft(usual: usual, elapsed: since)
            .map { Loc.t("capture.recording.organizing_left", table: "Capture", Loc.number($0)) }
    }
}
