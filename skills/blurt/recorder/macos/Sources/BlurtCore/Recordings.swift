// A recording is always findable, with its state (docs/design/capabilities.md §4; the
// Windows/Linux app's web/apps/desktop/src/recordings.ts says the same): Home's Recent lists every recording, and the
// items' places list the ones with no items to be found by — at the top of the list, where the organising job's row
// was. One recording is one row: its process job (running, failed) is drawn as that row, never as a job row beside it.
//
//   Facts     what the index and the folder say: the session row, whether recording.mp4 is still there
//             (housekeeping deletes organised recordings' videos after a while), the first thing said in it
//             (live/transcript.jsonl, else transcript.json), Save Video Only (meta.json "video_only")
//   state     from its newest process job (record.py take_state's rules): organising while a job runs, failed when the
//             last one failed (until it is dismissed or retried), items once organised, video only, else unorganised
//   actions   what the row offers in that state, the first being its click
//   place     which recordings an items' place lists
import Foundation

public enum Recordings {
    public struct Facts: Equatable, Sendable {
        public var dir: String, projectID: String, projectName: String?
        public var created: Double?, duration: Double?
        public var itemCount = 0, processed = false, processing = false
        /// recording.mp4, while it is there
        public var video: URL?
        public var firstLine: String?
        public var videoOnly = false

        public init(dir: String, projectID: String, projectName: String? = nil, created: Double? = nil, duration: Double? = nil,
                    itemCount: Int = 0, processed: Bool = false, processing: Bool = false, video: URL? = nil,
                    firstLine: String? = nil, videoOnly: Bool = false) {
            self.dir = dir; self.projectID = projectID; self.projectName = projectName; self.created = created
            self.duration = duration; self.itemCount = itemCount; self.processed = processed; self.processing = processing
            self.video = video; self.firstLine = firstLine; self.videoOnly = videoOnly
        }
        public var url: URL { URL(fileURLWithPath: dir) }
    }

    public enum State: Equatable, Sendable {
        /// a job organises it now (nil: the index says so, no job file seen)
        case organising(job: String?, step: String?)
        /// its newest run failed: the error's code
        case failed(job: String, code: String)
        case items(Int)
        case videoOnly
        case unorganised

        /// "organising" | "failed" | "items" | "video_only" | "unorganised" (tests, the shell channel)
        public var name: String {
            switch self {
            case .organising: return "organising"
            case .failed: return "failed"
            case .items: return "items"
            case .videoOnly: return "video_only"
            case .unorganised: return "unorganised"
            }
        }
        public var job: String? {
            switch self {
            case .organising(let j, _): return j
            case .failed(let j, _): return j
            default: return nil
            }
        }
    }

    public struct Row: Equatable, Sendable {
        public var facts: Facts
        public var state: State
        public var hasItems: Bool { if case .items(let n) = state { return n > 0 } else { return false } }
    }

    // MARK: facts

    /// The longest first line kept (rows cut it further).
    static let lineMax = 160

    /// The first thing said in a take: the first line with text of live/transcript.jsonl, else the first segment of
    /// transcript.json; whitespace folded.
    public static func firstLine(_ session: URL) -> String? {
        func fold(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        var found: String?
        if let raw = try? String(contentsOf: session.appendingPathComponent("live/transcript.jsonl"), encoding: .utf8) {
            for l in raw.split(separator: "\n") {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any],
                      let t = (o["text"] as? String).map(fold), !t.isEmpty else { continue }
                found = t
                break
            }
        }
        if found == nil, let d = try? Data(contentsOf: session.appendingPathComponent("transcript.json")),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let segs = o["segments"] as? [[String: Any]] {
            found = segs.lazy.compactMap { ($0["text"] as? String).map(fold) }.first { !$0.isEmpty }
        }
        guard let f = found else { return nil }
        return f.count > lineMax ? String(f.prefix(lineMax)) + "…" : f
    }

    /// An index session row with its folder's facts; nil: not a recording (shots, voice, a legacy session) or the take
    /// being recorded now (`live`).
    public static func facts(_ s: SessionRow, live: URL? = nil) -> Facts? {
        guard s.mode == "video", !s.legacy else { return nil }
        let dir = s.url
        if let l = live, l.standardizedFileURL.path == dir.standardizedFileURL.path { return nil }
        let meta = (try? Data(contentsOf: dir.appendingPathComponent("meta.json")))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        let video = dir.appendingPathComponent("recording.mp4")
        return Facts(dir: s.dir, projectID: s.projectID, projectName: s.projectName, created: s.created,
                     duration: s.duration ?? (meta["duration"] as? Double), itemCount: s.itemCount, processed: s.processed,
                     processing: s.processing, video: FileManager.default.fileExists(atPath: video.path) ? video : nil,
                     firstLine: firstLine(dir), videoOnly: meta["video_only"] as? Bool ?? false)
    }

    /// The newest `limit` recordings the index knows.
    public static func load(_ reader: IndexReader, live: URL? = nil, limit: Int = 40) -> [Facts] {
        let rows = (try? reader.sessions(SessionQuery(limit: max(50, limit * 4)))) ?? []
        return Array(rows.lazy.compactMap { facts($0, live: live) }.prefix(limit))
    }

    // MARK: state

    static func samePath(_ a: URL?, _ b: String) -> Bool {
        guard let a else { return false }
        return a.standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
    }

    /// The newest process job that organises this folder.
    public static func job(of dir: String, in jobs: [Job]) -> Job? {
        jobs.filter { $0.type == .process && samePath($0.session, dir) }.max { $0.created < $1.created }
    }

    public static func state(_ f: Facts, jobs: [Job]) -> State {
        let j = job(of: f.dir, in: jobs)
        if let j, j.isActive { return .organising(job: j.id, step: j.steps.first { $0.state == .running }?.id) }
        if j == nil, f.processing { return .organising(job: nil, step: nil) }
        if let j, j.state == .failed, !j.dismissed { return .failed(job: j.id, code: j.error?.code ?? "unknown") }
        if j?.state == .done || f.processed || f.itemCount > 0 { return .items(max(f.itemCount, j?.state == .done ? j!.items.count : 0)) }
        return f.videoOnly ? .videoOnly : .unorganised
    }

    public static func rows(_ facts: [Facts], jobs: [Job]) -> [Row] { facts.map { Row(facts: $0, state: state($0, jobs: jobs)) } }

    // MARK: actions

    public enum Action: String, CaseIterable, Sendable {
        case review, progress, play, reveal, organise, retry, setUpAgent = "set_up_agent", copyRequest = "copy_request", dismiss
    }

    /// What a row offers, the first being its click. `agent`: an agent can organise in the background (nil: not known
    /// yet — as if it could).
    public static func actions(_ r: Row, agent: Bool?) -> [Action] {
        let can = agent != false
        let play: [Action] = r.facts.video != nil ? [.play] : []
        // nothing to organise once the video is gone
        let organise: [Action] = r.facts.video == nil ? [] : can ? [.organise] : [.setUpAgent, .copyRequest]
        switch r.state {
        case .organising(let j, _): return (j != nil ? [.progress] : []) + play + [.reveal]
        case .failed: return (can ? [.retry] : [.setUpAgent, .copyRequest]) + play + [.reveal, .progress, .dismiss]
        case .items(let n): return n > 0 ? [.review] + play + [.reveal] : play + organise + [.reveal]
        case .videoOnly, .unorganised: return play + organise + [.reveal]
        }
    }

    /// The one action drawn on the row itself: a failure's way forward, or Organise for one never organised (only with
    /// an agent to do it — without one, Home's Recording row already says how).
    public static func inline(_ r: Row, agent: Bool?) -> Action? {
        let can = agent != false
        if case .failed = r.state { return can ? .retry : .setUpAgent }
        if case .unorganised = r.state, can, r.facts.video != nil { return .organise }
        return nil
    }

    // MARK: places

    public enum Place: Equatable, Sendable {
        case needsYou, inProgress, unassigned, project(String), other
    }

    /// The recordings a place lists, newest first: Needs You and In Progress those under way or failed (In Progress:
    /// under way); Unassigned and a project their own that have no items (with items, the items are where it is).
    public static func listed(_ rows: [Row], in place: Place) -> [Row] {
        rows.filter { r in
            switch (place, r.state) {
            case (.needsYou, .failed), (.needsYou, .organising), (.inProgress, .organising): return true
            case (.unassigned, _): return r.facts.projectID == "inbox" && !r.hasItems
            case (.project(let p), _): return r.facts.projectID == p && !r.hasItems
            default: return false
            }
        }.sorted { ($0.facts.created ?? 0) > ($1.facts.created ?? 0) }
    }

    /// The jobs section beside the recordings: a process job of a listed recording is that recording's row.
    public static func jobsBeside(_ jobs: [Job], _ rows: [Row]) -> [Job] {
        jobs.filter { j in !(j.type == .process && rows.contains { samePath(j.session, $0.facts.dir) }) }
    }

    /// The job error codes whose words are short enough for a row; the rest say only "Didn't finish" there.
    public static let shortWhy: Set<String> = ["no_agent", "auth", "network", "quota", "model", "agent_exit"]
}
