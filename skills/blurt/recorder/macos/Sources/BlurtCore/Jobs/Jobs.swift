// K4: everything that is happening — a recording, a snap batch, voice input, processing, routing, an agent session —
// is a job in $BLURT_HOME/jobs/. <id>.json is written only by the job's owner (atomic replace); anyone else appends
// one line to <id>.events.jsonl, and every reader folds those events over the json from `events_offset` on (steps by
// id, status → agent.status, state / progress replace, items union). So a job's state is current even while its owner
// isn't running.
//
// G0 (docs/design/next-round.md "所有权、闸门和合并"): the shared interface, written by P4 so the packages compile
// against it; P3 owns this file from here on.
import CoreServices
import Foundation

public enum JobType: String { case record, snap, voice, process, route, agent }
public enum JobState: String { case queued, running, done, failed, cancelled }
public enum StepState: String { case pending, running, done, failed, skipped }
public enum AgentSessionStatus: String { case running, waitingInput = "waiting_input", turnDone = "turn_done", exited, error }

public struct JobStep {
    public let id: String
    public let state: StepState
    public let progress: Double?
    public init(id: String, state: StepState, progress: Double? = nil) { self.id = id; self.state = state; self.progress = progress }
}

public struct JobError {
    public let code: String
    public let message: String
    public let hintKey: String?
    public init(code: String, message: String, hintKey: String? = nil) { self.code = code; self.message = message; self.hintKey = hintKey }
}

public struct AgentInfo {
    public let agent, mode, runner: String
    public let tmuxSession, tmuxWindow, windowName, branch, handoff: String?
    public let cwd: URL
    public let worktree: URL?
    public let status: AgentSessionStatus
    public let statusAt: Date?
    public let exit: Int32?
}

public struct Job: Identifiable {
    public let id: String
    public let type: JobType
    public let state: JobState
    public let project: String?
    public let session: URL?
    public let parent, title: String?
    public let items: [String]
    public let captures: [Int]
    public let steps: [JobStep]
    public let progress: Double?
    public let created: Date
    public let started, ended: Date?
    public let error: JobError?
    public let agent: AgentInfo?
    public var isActive: Bool { state == .queued || state == .running }
    /// The step running now, else the first one not done yet.
    public var currentStep: JobStep? { steps.first { $0.state == .running } ?? steps.first { $0.state == .pending } }
}

/// The fixed step ids per job type (UI: `job.step.<id>`).
public let jobSteps: [JobType: [String]] = [
    .record: ["capture", "finalize"], .snap: ["capture"], .voice: ["listen", "transcribe", "file"],
    .process: ["prepare", "transcribe", "write", "frames", "route"], .route: ["route"], .agent: ["launch", "work", "finish"],
]

public enum JobFiles {
    public static var dir: URL { BlurtPaths.home.appendingPathComponent("jobs") }
    public static func json(_ id: String) -> URL { dir.appendingPathComponent("\(id).json") }
    public static func events(_ id: String) -> URL { dir.appendingPathComponent("\(id).events.jsonl") }
    public static func log(_ id: String) -> URL { dir.appendingPathComponent("\(id).log") }

    static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; f.timeZone = .current; return f }()
    static let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    public static func now() -> String { iso.string(from: Date()) }
    public static func date(_ v: Any?) -> Date? { (v as? String).flatMap { iso.date(from: $0) ?? isoFrac.date(from: $0) } }

    /// j-YYYYMMDD-HHMMSS-xxxx (4 lowercase base32)
    public static func newID() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        return "j-" + f.string(from: Date()) + "-" + String((0..<4).map { _ in alphabet.randomElement()! })
    }

    /// The effective state of one job: <id>.json with <id>.events.jsonl folded over it (K4).
    public static func effective(_ id: String) -> [String: Any]? {
        guard let d = try? Data(contentsOf: json(id)), var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let offset = (o["events_offset"] as? NSNumber)?.intValue ?? 0
        guard let ev = try? Data(contentsOf: events(id)), ev.count > offset else { return o }
        for line in ev.dropFirst(offset).split(separator: 0x0A) {
            guard let e = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            fold(&o, e)
        }
        return o
    }

    public static func fold(_ o: inout [String: Any], _ e: [String: Any]) {
        if let s = e["step"] as? [String: Any], let sid = s["id"] as? String {
            var steps = o["steps"] as? [[String: Any]] ?? []
            if let i = steps.firstIndex(where: { $0["id"] as? String == sid }) { steps[i].merge(s) { _, n in n } } else { steps.append(s) }
            o["steps"] = steps
        }
        if let st = e["status"] as? String {
            var a = o["agent"] as? [String: Any] ?? [:]
            a["status"] = st
            a["status_at"] = e["t"]
            a["status_source"] = e["source"]
            o["agent"] = a
        }
        if let st = e["state"] { o["state"] = st }
        if let p = e["progress"] { o["progress"] = p }
        if let items = e["items"] as? [String] {
            var cur = o["items"] as? [String] ?? []
            for u in items where !cur.contains(u) { cur.append(u) }
            o["items"] = cur
        }
        if let t = e["t"] { o["updated"] = t }
    }

    public static func parse(_ o: [String: Any]) -> Job? {
        guard let id = o["id"] as? String, let type = JobType(rawValue: o["type"] as? String ?? "") else { return nil }
        let steps = (o["steps"] as? [[String: Any]] ?? []).compactMap { s -> JobStep? in
            guard let sid = s["id"] as? String else { return nil }
            return JobStep(id: sid, state: StepState(rawValue: s["state"] as? String ?? "") ?? .pending, progress: (s["progress"] as? NSNumber)?.doubleValue)
        }
        let err = (o["error"] as? [String: Any]).map {
            JobError(code: $0["code"] as? String ?? "unknown", message: $0["message"] as? String ?? "", hintKey: $0["hint_key"] as? String)
        }
        var agent: AgentInfo?
        if let a = o["agent"] as? [String: Any], type == .agent {
            let tmux = a["tmux"] as? [String: Any]
            let wt = a["worktree"] as? [String: Any]
            agent = AgentInfo(agent: a["id"] as? String ?? "", mode: a["mode"] as? String ?? "together", runner: a["runner"] as? String ?? "tmux",
                              tmuxSession: tmux?["session"] as? String, tmuxWindow: tmux?["window"] as? String, windowName: tmux?["name"] as? String,
                              branch: wt?["branch"] as? String, handoff: a["handoff"] as? String,
                              cwd: URL(fileURLWithPath: a["cwd"] as? String ?? NSHomeDirectory()),
                              worktree: (wt?["path"] as? String).map { URL(fileURLWithPath: $0) },
                              status: AgentSessionStatus(rawValue: a["status"] as? String ?? "") ?? .running,
                              statusAt: date(a["status_at"]), exit: (a["exit"] as? NSNumber)?.int32Value)
        }
        return Job(id: id, type: type, state: JobState(rawValue: o["state"] as? String ?? "") ?? .queued, project: o["project"] as? String,
                   session: (o["session"] as? String).map { URL(fileURLWithPath: $0) }, parent: o["parent"] as? String, title: o["title"] as? String,
                   items: o["items"] as? [String] ?? [], captures: (o["captures"] as? [NSNumber] ?? []).map(\.intValue), steps: steps,
                   progress: (o["progress"] as? NSNumber)?.doubleValue, created: date(o["created"]) ?? Date.distantPast,
                   started: date(o["started"]), ended: date(o["ended"]), error: err, agent: agent)
    }
}

public final class JobStore {
    public static let shared = JobStore()

    /// Effective states, newest first (the most recent `limit`).
    public private(set) var jobs: [Job] = []
    public var active: [Job] { jobs.filter(\.isActive) }
    public func job(_ id: String) -> Job? { jobs.first { $0.id == id } }
    /// Main thread; the jobs whose effective state changed (new ones included).
    public var onChange: ((_ changed: [Job]) -> Void)?
    public var limit = 300

    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var stamps: [String: String] = [:]          // id → json mtime + events size, to tell what changed

    public init() {}

    public func start() {
        guard stream == nil else { return }
        try? FileManager.default.createDirectory(at: JobFiles.dir, withIntermediateDirectories: true)
        reload()
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            Unmanaged<JobStore>.fromOpaque(info).takeUnretainedValue().scheduleReload()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, [JobFiles.dir.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    private func scheduleReload() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reload() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: w)
    }

    /// Re-reads the jobs directory and folds the events (also what the FSEvents callback does, debounced 100 ms).
    public func reload() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: JobFiles.dir.path)) ?? []
        let ids = names.filter { $0.hasSuffix(".json") && $0.hasPrefix("j-") }.map { String($0.dropLast(5)) }.sorted(by: >).prefix(limit)
        var out: [Job] = [], changed: [Job] = []
        var newStamps: [String: String] = [:]
        for id in ids {
            let a = (try? fm.attributesOfItem(atPath: JobFiles.json(id).path)) ?? [:]
            let b = (try? fm.attributesOfItem(atPath: JobFiles.events(id).path)) ?? [:]
            let stamp = "\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)/\((b[.size] as? Int) ?? 0)"
            newStamps[id] = stamp
            if stamp == stamps[id], let old = jobs.first(where: { $0.id == id }) { out.append(old); continue }
            guard let o = JobFiles.effective(id), let j = JobFiles.parse(o) else { continue }
            out.append(j)
            changed.append(j)
        }
        out.sort { $0.created > $1.created }
        let removed = Set(stamps.keys).subtracting(newStamps.keys)
        stamps = newStamps
        jobs = out
        if !changed.isEmpty || !removed.isEmpty { onChange?(changed) }
    }
}

/// A job the app itself owns (record / snap / voice / process): it writes <id>.json, nobody else does.
public final class JobWriter {
    public let id: String
    private var o: [String: Any]
    private let lock = NSLock()

    public init(type: JobType, project: String?, session: URL?, parent: String? = nil, title: String? = nil) {
        id = JobFiles.newID()
        let now = JobFiles.now()
        o = ["schema": 1, "id": id, "type": type.rawValue, "state": JobState.running.rawValue, "owner": "app",
             "project": project as Any? ?? NSNull(), "session": session?.path as Any? ?? NSNull(), "parent": parent as Any? ?? NSNull(),
             "title": title as Any? ?? NSNull(), "items": [String](), "captures": [Int](),
             "steps": (jobSteps[type] ?? []).map { ["id": $0, "state": StepState.pending.rawValue, "started": NSNull(), "ended": NSNull()] },
             "progress": NSNull(), "created": now, "started": now, "ended": NSNull(), "updated": now, "events_offset": 0, "error": NSNull()]
        write()
    }

    /// Others' events land in events.jsonl; fold them in before every write so nothing they said is lost.
    private func absorb() {
        guard let d = try? Data(contentsOf: JobFiles.events(id)) else { return }
        let offset = (o["events_offset"] as? Int) ?? 0
        guard d.count > offset else { return }
        let new = d.dropFirst(offset)
        guard let last = new.lastIndex(of: 0x0A) else { return }       // only whole lines
        for line in d[new.startIndex...last].split(separator: 0x0A) {
            if let e = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { JobFiles.fold(&o, e) }
        }
        o["events_offset"] = last + 1
    }

    private func write() {
        o["updated"] = JobFiles.now()
        try? FileManager.default.createDirectory(at: JobFiles.dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: JobFiles.json(id), options: .atomic)
        }
    }

    private func change(_ f: (inout [String: Any]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        absorb()
        f(&o)
        write()
    }

    public func step(_ sid: String, _ state: StepState, progress: Double? = nil) {
        change { o in
            var steps = o["steps"] as? [[String: Any]] ?? []
            var s = steps.first { $0["id"] as? String == sid } ?? ["id": sid]
            s["state"] = state.rawValue
            s["progress"] = progress as Any? ?? NSNull()
            if state == .running, s["started"] == nil || s["started"] is NSNull { s["started"] = JobFiles.now() }
            if [.done, .failed, .skipped].contains(state) { s["ended"] = JobFiles.now() }
            if let i = steps.firstIndex(where: { $0["id"] as? String == sid }) { steps[i] = s } else { steps.append(s) }
            o["steps"] = steps
        }
    }
    public func setItems(_ uids: [String]) { change { $0["items"] = uids } }
    public func setCaptures(_ n: [Int]) { change { $0["captures"] = n } }
    public func setProgress(_ p: Double?) { change { $0["progress"] = p as Any? ?? NSNull() } }
    public func setTitle(_ t: String?) { change { $0["title"] = t as Any? ?? NSNull() } }

    public func finish(_ state: JobState, error: JobError? = nil) {
        change { o in
            o["state"] = state.rawValue
            o["ended"] = JobFiles.now()
            if let e = error { o["error"] = ["code": e.code, "message": e.message, "hint_key": e.hintKey as Any? ?? NSNull()] }
            // whatever was still pending won't happen now
            o["steps"] = (o["steps"] as? [[String: Any]] ?? []).map { s in
                var s = s
                let st = s["state"] as? String
                if st == "running" { s["state"] = state == .done ? "done" : "failed"; s["ended"] = JobFiles.now() }
                else if st == "pending" { s["state"] = "skipped" }
                return s
            }
        }
    }
}
