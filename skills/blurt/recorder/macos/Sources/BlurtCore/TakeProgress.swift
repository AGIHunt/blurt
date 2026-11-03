// What a take says about itself while it runs and after it ends (BA-64, BA-61; 2026-10-31).
//
//  • TakeLine: the open recording island's quiet line. The founder couldn't tell what "已识别 4 条" was or where the
//    shots went: now it names both in plain words ("截图 6 张 · 已识别 4 个事项" / "6 snaps · 4 items spotted"), each
//    snap is a card of its own (⌥A runs the normal snap flow while recording), and a second line says where the items
//    will be: "点完成后整理进 Atlas Web" / "Organized into Atlas Web when you finish".
//  • OrganizeEstimate: how long organizing a recording usually takes *on this Mac*, from the recordings it has already
//    organized (the process jobs in $BLURT_HOME/jobs: their start and end, the video's length in meta.json) — nothing
//    is assumed. Fewer than 3 such runs: no estimate, the island just says it is organizing and where.
import Foundation

public enum TakeLine {
    public enum Part: Equatable {
        case snaps(Int), items(Int)
    }

    /// The counts worth saying, in this order: the snaps taken (⌥A, the island's button), the items live.py spotted
    /// so far. Zero ones are left out.
    public static func parts(snaps: Int, items: Int) -> [Part] {
        [snaps > 0 ? .snaps(snaps) : nil, items > 0 ? .items(items) : nil].compactMap { $0 }
    }

    /// The counts as a line ("6 snaps · 4 items spotted").
    public static func text(snaps: Int, items: Int) -> String {
        parts(snaps: snaps, items: items).map { p -> String in
            switch p {
            case .snaps(let n): return Loc.plural("capture.rec.snaps", table: "Capture", count: n)
            case .items(let n): return Loc.plural("capture.rec.spotted", table: "Capture", count: n)
            }
        }.joined(separator: " · ")
    }

    /// Where it all goes: "Organized into Atlas Web when you finish" — said once there is something to organize; when
    /// the take will only be saved (record.process off): nothing.
    public static func whereTo(project: String, organizes: Bool, anything: Bool) -> String? {
        guard organizes, anything else { return nil }
        return Loc.t("capture.rec.goes_after", table: "Capture", project)
    }
}

public enum OrganizeEstimate {
    public struct Run: Equatable {
        public let video: Double     // seconds of video
        public let took: Double      // seconds from the run's start to its end
        public init(video: Double, took: Double) { self.video = video; self.took = took }
    }

    /// Past runs below this many say nothing: one or two runs are anecdotes.
    public static let minRuns = 3

    /// The usual run for a video this long, in seconds — a robust line through the past runs (Theil–Sen: the median
    /// of the pairwise slopes, never below 0; the median intercept), never shorter than the quickest run seen. nil:
    /// fewer than `minRuns` usable runs (a video of at least 5 s, a run of at least 5 s).
    public static func seconds(video: Double, past: [Run]) -> Double? {
        let runs = past.filter { $0.video >= 5 && $0.took >= 5 && $0.video.isFinite && $0.took.isFinite }
        guard runs.count >= minRuns, video > 0 else { return nil }
        var slopes: [Double] = []
        for i in 0..<runs.count {
            for j in (i + 1)..<runs.count where abs(runs[j].video - runs[i].video) >= 1 {
                slopes.append((runs[j].took - runs[i].took) / (runs[j].video - runs[i].video))
            }
        }
        let slope = max(0, slopes.isEmpty ? 0 : median(slopes))
        let intercept = median(runs.map { $0.took - slope * $0.video })
        return max(runs.map(\.took).min() ?? 0, intercept + slope * video)
    }

    /// Whole minutes to say ("about 4 min"): rounded, at least 1.
    public static func minutes(_ seconds: Double) -> Int { max(1, Int((seconds / 60).rounded())) }

    /// What is left of a run that started `elapsed` seconds ago, in whole minutes — nil once it is past the usual
    /// length (the island then just says it is organizing; it never counts down below zero or makes up a new figure).
    public static func minutesLeft(usual: Double, elapsed: Double) -> Int? {
        let left = usual - elapsed
        guard left > 20 else { return nil }
        return max(1, Int((left / 60).rounded()))
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
