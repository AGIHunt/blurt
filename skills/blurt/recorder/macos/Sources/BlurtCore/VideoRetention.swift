// Recording videos are most of Blurt's disk use (≈ 9 MB a minute) and, once a recording is organized, only its
// items, frames and transcript are needed day to day. Settings → Storage deletes the videos of organized recordings
// older than a chosen age, by hand or automatically (record.delete_videos_after_days; off by default — Blurt never
// deletes what the user made unless they ask). Only the video goes (recording.mp4 and the scan made from it); the
// items, frames, clips and transcript stay, and the item page simply has no "Recording" tab. To the Trash, so a
// mistake can be undone.
// A recording without its video must still read as a recording: snaps taken while recording leave shots.jsonl in the
// session, and without recording.mp4 the scripts (index.py, items.py) and the app (isShotsSession) would otherwise take
// it for a snap batch. So the session's meta.json says {"mode": "video"} before the video goes and
// {"video_removed": <iso>} once it has (stamp).
import Foundation

public enum VideoRetention {
    /// The files that are only the video: the mp4 and the motion scan made from it.
    public static let videoFiles = ["recording.mp4", "recording.scan.npz"]
    /// The choices Settings → Storage offers (days).
    public static let choices = [30, 90, 180]

    public struct Candidate: Equatable {
        public let session: URL
        public let files: [URL]
        public let bytes: Int64
        public let date: Date
    }

    /// Delete videos this many days after they were recorded, automatically; nil = never (the default).
    public static var autoDays: Int? {
        get { (Config.shared["record.delete_videos_after_days"] as? Int).flatMap { $0 > 0 ? $0 : nil } }
        set { Config.shared.set("record.delete_videos_after_days", newValue) }
    }

    /// Sessions under `roots` (each a folder of session folders) whose video can go: organized (transcript.json and a
    /// batch.json that isn't processing), recorded at least `days` days ago (nil = any age), not in `excluding`.
    public static func candidates(roots: [URL], olderThan days: Int?, now: Date = Date(), excluding: Set<String> = []) -> [Candidate] {
        let fm = FileManager.default
        var out: [Candidate] = []
        for root in roots {
            for s in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                guard !excluding.contains(s.standardizedFileURL.path) else { continue }
                let video = s.appendingPathComponent("recording.mp4")
                guard let attrs = try? fm.attributesOfItem(atPath: video.path), let date = attrs[.modificationDate] as? Date,
                      organized(s) else { continue }
                if let d = days, now.timeIntervalSince(date) < Double(d) * 86400 { continue }
                let files = videoFiles.map { s.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
                let bytes = files.reduce(Int64(0)) { $0 + Int64((try? fm.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0) }
                out.append(Candidate(session: s, files: files, bytes: bytes, date: date))
            }
        }
        return out.sorted { $0.date < $1.date }
    }

    /// Merges {"mode": "video"} (and, once the video is gone, {"video_removed": <iso>}) into the session's meta.json,
    /// atomically; the other keys stay.
    @discardableResult
    public static func stamp(_ session: URL, removed: Date? = nil) -> Bool {
        let f = session.appendingPathComponent("meta.json")
        var m = (try? JSONSerialization.jsonObject(with: Data(contentsOf: f))) as? [String: Any] ?? [:]
        m["mode"] = "video"
        if let r = removed { m["video_removed"] = ISO8601DateFormatter().string(from: r) }
        guard let d = try? JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? d.write(to: f, options: .atomic)) != nil
    }

    /// The video came back from the Trash (Undo in Settings → Storage): the session no longer says it was removed.
    @discardableResult
    public static func unstampRemoved(_ session: URL) -> Bool {
        let f = session.appendingPathComponent("meta.json")
        guard var m = (try? JSONSerialization.jsonObject(with: Data(contentsOf: f))) as? [String: Any] else { return false }
        m.removeValue(forKey: "video_removed")
        guard let d = try? JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? d.write(to: f, options: .atomic)) != nil
    }

    /// Whether a session is a screen recording by its meta.json, whether or not its video is still there.
    public static func isRecording(_ session: URL) -> Bool {
        guard let d = try? Data(contentsOf: session.appendingPathComponent("meta.json")),
              let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return m["mode"] as? String == "video" || m["video_removed"] != nil
    }

    /// The recording became items: its transcript is there and its batch isn't being made.
    public static func organized(_ session: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: session.appendingPathComponent("transcript.json").path),
              let d = try? Data(contentsOf: session.appendingPathComponent("batch.json")),
              let b = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return b["processing"] as? Bool != true
    }
}
