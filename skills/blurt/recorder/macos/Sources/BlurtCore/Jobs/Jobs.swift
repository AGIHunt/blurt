// K4 jobs: everything that is happening (a recording, a snap batch, voice, processing, routing) is a job in
// $BLURT_HOME/jobs/:
//   <id>.json           the job, written only by its owner (atomic replace; under <id>.lock when several processes own it)
//   <id>.events.jsonl   progress anyone else reports: one appended line each (hooks, items.py, agents)
// Every reader computes the same *effective state*: the json, then the events from `events_offset` on, in order —
// steps merge by id, `state` and `progress` overwrite, `items` are unioned. Python (jobs.py) and Rust (Tauri) implement
// the same fold, so the state is current even while the owner isn't running. Agent-session jobs ("type": "agent")
// left by older versions are not read: JobFold.job skips any type it doesn't know.
//
//   JobStore.shared.start()            FSEvents on jobs/ (100 ms debounce) → jobs (newest first), onChange(changed)
//   JobWriter(type: .record, …)        a job the app owns (record / snap / voice / process)
import Foundation
import CoreServices

public enum JobType: String { case record, snap, voice, process, route }
public enum JobState: String { case queued, running, done, failed, cancelled }
public enum StepState: String { case pending, running, done, failed, skipped }

public struct JobStep {
    public let id: String
    public let state: StepState
    public let progress: Double?
    public init(id: String, state: StepState, progress: Double? = nil) { self.id = id; self.state = state; self.progress = progress }
}

public struct JobError {
    public let code: String
    /// For the log: whatever the run said (a traceback, an exit status). Never shown as is.
    public let message: String
    public let hintKey: String?
    /// For people: a sentence already in their language, composed when it failed (which agent, why, what to do) —
    /// "Claude Code 没登录 — 在终端运行 claude，然后输入 /login". Shown before the code's generic sentence.
    public let reason: String?
    public init(code: String, message: String, hintKey: String? = nil, reason: String? = nil) {
        self.code = code; self.message = message; self.hintKey = hintKey; self.reason = reason
    }
}

/// The fixed step ids per job type (K4; the UI shows `job.step.<id>`).
public let jobSteps: [JobType: [String]] = [
    .record: ["capture", "finalize"], .snap: ["capture"], .voice: ["listen", "transcribe", "file"],
    // no routing step any more: an organizing run only suggests projects (route jobs are v0.8 files, still read)
    .process: ["prepare", "transcribe", "write", "frames"], .route: ["route"],
]

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
    public let updated: Date?

    public var isActive: Bool { state == .queued || state == .running }
    /// The user put this failure away: it no longer waits in the jobs section.
    public var dismissed: Bool { raw["dismissed"] as? Bool ?? false }
    /// The step in progress, else the next one to run.
    public var currentStep: JobStep? { steps.first { $0.state == .running } ?? steps.first { $0.state == .pending } }

    /// The effective state as a dictionary, as jobs.py get prints it.
    public let raw: [String: Any]

    /// Which agent organised it when the first in the user's order couldn't (AgentHub: `organizer`): its id, and the
    /// ones it stood in for with why, in words ("Claude Code 没登录"). nil = the first one did.
    public var organizer: (agent: String, insteadOf: [String])? {
        guard let o = raw["organizer"] as? [String: Any], let a = o["agent"] as? String else { return nil }
        let instead = o["instead_of"] as? [String] ?? []
        return instead.isEmpty ? nil : (a, instead)
    }

    /// What an organising run cost (JobWriter.setUsage): tokens nil = the CLI didn't say; agent nil = no agent ran.
    public var usage: (tokens: Int?, agent: String?, model: String?, effort: String?)? {
        guard let u = raw["usage"] as? [String: Any] else { return nil }
        return ((u["tokens"] as? NSNumber)?.intValue, u["agent"] as? String, u["model"] as? String, u["effort"] as? String)
    }
}

/// The jobs section's failures (K4): organising or routing that failed in the last week stays listed — a recording
/// whose organising failed has no items to reach it from — until it is dismissed, retried (a newer job for the same
/// recording) or old.
public enum JobFailures {
    public static let keep: TimeInterval = 7 * 24 * 3600

    public static func waiting(_ jobs: [Job], now: Date = Date()) -> [Job] {
        jobs.filter { j in
            guard j.state == .failed, j.type == .process || j.type == .route, !j.dismissed,
                  now.timeIntervalSince(j.ended ?? j.created) < keep else { return false }
            // a later run for the same recording (or the same items) replaced it
            return !jobs.contains { o in
                o.id != j.id && o.type == j.type && o.created > j.created
                    && (j.session.map { o.session?.path == $0.path } ?? (!j.items.isEmpty && Set(o.items) == Set(j.items)))
            }
        }
    }
}

// MARK: - The fold (K4)

public enum JobFold {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()
    static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func now() -> String { iso.string(from: Date()) }
    public static func date(_ v: Any?) -> Date? {
        if let s = v as? String { return iso.date(from: s) ?? isoFrac.date(from: s) }
        if let d = v as? Double { return Date(timeIntervalSince1970: d) }
        return nil
    }

    /// The steps of a job that ended without finishing: running → failed, pending → skipped.
    public static func closeSteps(_ steps: [[String: Any]], at: String) -> [[String: Any]] {
        steps.map { st in
            var st = st
            switch st["state"] as? String {
            case "running": st["state"] = "failed"; st["ended"] = at
            case "pending": st["state"] = "skipped"
            default: break
            }
            return st
        }
    }

    /// The owner ends its job (JobWriter.finish), with whatever others reported already folded in. A job the user
    /// stopped (an event set it cancelled: the detail's Stop) stays stopped — the run's own end (its killed agent's
    /// exit, items it wrote anyway) never turns it into a failure or a success; its steps are closed all the same.
    public static func finishing(_ d: inout [String: Any], state: JobState, error: JobError?, at: String) {
        let stopped = d["state"] as? String == JobState.cancelled.rawValue && state != .cancelled
        d["ended"] = at
        if !stopped {
            d["state"] = state.rawValue
            if let e = error {
                d["error"] = ["code": e.code, "message": e.message, "hint_key": e.hintKey ?? NSNull(), "reason": e.reason ?? NSNull()] as [String: Any]
            }
        }
        if state != .done || stopped { d["steps"] = closeSteps(d["steps"] as? [[String: Any]] ?? [], at: at) }
    }

    /// Apply one events.jsonl line to a job dictionary.
    public static func apply(_ ev: [String: Any], to job: inout [String: Any]) {
        if let st = ev["step"] as? [String: Any], let sid = st["id"] as? String {
            var steps = job["steps"] as? [[String: Any]] ?? []
            if let i = steps.firstIndex(where: { $0["id"] as? String == sid }) {
                steps[i].merge(st) { _, new in new }
            } else {
                steps.append(st)
            }
            job["steps"] = steps
        }
        if let s = ev["state"] { job["state"] = s }
        // a failure someone else reported (`jobs.py finish --error-code`): its reason, unless the owner wrote one
        if let e = (ev["detail"] as? [String: Any])?["error"] as? [String: Any], e["code"] is String,
           !(job["error"] is [String: Any]) {
            job["error"] = e
        }
        if let p = ev["progress"] { job["progress"] = p }
        if let add = ev["items"] as? [String] {
            var items = job["items"] as? [String] ?? []
            for u in add where !items.contains(u) { items.append(u) }
            job["items"] = items
        }
        if let t = ev["t"] { job["updated"] = t }
    }

    /// The events after `offset` (complete lines only — a writer may be mid-append), and the offset after them.
    public static func events(_ url: URL, from offset: Int) -> (events: [[String: Any]], end: Int) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()).map(Int.init) ?? 0
        guard size > offset else { return ([], min(offset, size)) }
        try? fh.seek(toOffset: UInt64(offset))
        let data = (try? fh.readToEnd()) ?? Data()
        guard let lastNL = data.lastIndex(of: 0x0A) else { return ([], offset) }
        var out: [[String: Any]] = []
        for line in data[data.startIndex...lastNL].split(separator: 0x0A) where !line.isEmpty {
            if let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { out.append(o) }
        }
        return (out, offset + (lastNL - data.startIndex) + 1)
    }

    /// json + events → the effective job dictionary.
    public static func effective(json: [String: Any], events url: URL) -> [String: Any] {
        var j = json
        let (evs, _) = events(url, from: j["events_offset"] as? Int ?? 0)
        for e in evs { apply(e, to: &j) }
        return j
    }

    public static func job(_ o: [String: Any]) -> Job? {
        guard let id = o["id"] as? String, let type = JobType(rawValue: o["type"] as? String ?? "") else { return nil }
        let steps = (o["steps"] as? [[String: Any]] ?? []).compactMap { s -> JobStep? in
            guard let sid = s["id"] as? String else { return nil }
            return JobStep(id: sid, state: StepState(rawValue: s["state"] as? String ?? "") ?? .pending, progress: s["progress"] as? Double)
        }
        let err = (o["error"] as? [String: Any]).map {
            JobError(code: $0["code"] as? String ?? "unknown", message: $0["message"] as? String ?? "", hintKey: $0["hint_key"] as? String,
                     // reason_i18n: the sentence in both languages, so it follows the app's, not the language the
                     // script guessed when it failed
                     reason: (($0["reason_i18n"] as? [String: String]).flatMap(Loc.pick) ?? $0["reason"] as? String)
                        .flatMap { $0.isEmpty ? nil : $0 })
        }
        return Job(id: id, type: type, state: JobState(rawValue: o["state"] as? String ?? "") ?? .queued,
                   project: o["project"] as? String, session: (o["session"] as? String).map { URL(fileURLWithPath: $0) },
                   parent: o["parent"] as? String, title: o["title"] as? String,
                   items: o["items"] as? [String] ?? [], captures: (o["captures"] as? [NSNumber] ?? []).map(\.intValue),
                   steps: steps, progress: o["progress"] as? Double,
                   created: date(o["created"]) ?? .distantPast, started: date(o["started"]), ended: date(o["ended"]),
                   error: err, updated: date(o["updated"]), raw: o)
    }
}

public enum JobFiles {
    public static var dir: URL { BlurtPaths.home.appendingPathComponent("jobs") }
    public static func json(_ id: String) -> URL { dir.appendingPathComponent("\(id).json") }
    public static func events(_ id: String) -> URL { dir.appendingPathComponent("\(id).events.jsonl") }
    public static func lock(_ id: String) -> URL { dir.appendingPathComponent("\(id).lock") }
    public static func log(_ id: String) -> URL { dir.appendingPathComponent("\(id).log") }

    /// j-YYYYMMDD-HHMMSS-xxxx (4 lowercase base32 characters)
    public static func newID(_ now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        return "j-\(f.string(from: now))-" + String((0..<4).map { _ in alphabet.randomElement()! })
    }

    /// Rewrite an app-owned job's json under its lock (a job whose writer is gone: the last run's, a failure the user
    /// dismissed). Events not folded yet stay after events_offset, so nothing reported is lost.
    public static func rewrite(_ id: String, _ change: (inout [String: Any]) -> Void) {
        let lfd = open(lock(id).path, O_RDWR | O_CREAT, 0o644)
        if lfd >= 0 { flock(lfd, LOCK_EX) }
        defer { if lfd >= 0 { flock(lfd, LOCK_UN); close(lfd) } }
        guard let d = try? Data(contentsOf: json(id)), var doc = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        change(&doc)
        doc["updated"] = JobFold.now()
        guard let out = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) else { return }
        let tmp = dir.appendingPathComponent(".\(id).\(getpid()).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: out) else { return }
        _ = rename(tmp.path, json(id).path)
    }

    /// Append one event line (O_APPEND, so concurrent writers never interleave a line).
    public static func appendEvent(_ id: String, _ event: [String: Any]) {
        var e = event
        if e["t"] == nil { e["t"] = JobFold.now() }
        guard var d = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys]) else { return }
        d.append(0x0A)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(events(id).path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        d.withUnsafeBytes { _ = write(fd, $0.baseAddress, d.count) }
        close(fd)
    }
}

// MARK: - JobStore

public final class JobStore {
    public static let shared = JobStore()

    public private(set) var jobs: [Job] = []
    public var active: [Job] { jobs.filter(\.isActive) }
    public func job(_ id: String) -> Job? { byID[id] }
    /// Main queue; the jobs whose effective state changed (or appeared). A removed job is not reported.
    public var onChange: ((_ changed: [Job]) -> Void)?

    private var byID: [String: Job] = [:]
    private var stamps: [String: String] = [:]          // id → "<json mtime>|<json size>|<events size>"
    private var stream: FSEventStreamRef?
    private var pending = Set<String>()
    private var flushScheduled = false
    private var watchedDir: String?
    private var observers: [UUID: ([Job]) -> Void] = [:]

    public init() {}

    /// Several parts of the app follow jobs; each gets the changes after onChange. Returns a token for removeObserver.
    @discardableResult
    public func addObserver(_ f: @escaping ([Job]) -> Void) -> UUID {
        let k = UUID()
        observers[k] = f
        return k
    }
    public func removeObserver(_ k: UUID) { observers[k] = nil }

    public func start() {
        guard stream == nil else { return }
        let dir = JobFiles.dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        watchedDir = dir.resolvingSymlinksInPath().path
        rescan()
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, n, paths, _, _ in
            guard let info = info else { return }
            let me = Unmanaged<JobStore>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.touched(Array(arr.prefix(n)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, [dir.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
        stream = nil
    }

    /// Re-read every job (cheap for unchanged ones). Also the fallback when FSEvents reports a dropped / rescanned dir.
    public func rescan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: JobFiles.dir.path)) ?? []
        let ids = Set(names.compactMap { n -> String? in n.hasSuffix(".json") && n.hasPrefix("j-") ? String(n.dropLast(5)) : nil })
        for gone in Set(byID.keys).subtracting(ids) { byID[gone] = nil; stamps[gone] = nil }
        let changed = ids.compactMap { refresh($0) }
        publish(changed)
    }

    private func touched(_ paths: [String]) {
        for p in paths {
            let name = (p as NSString).lastPathComponent
            guard name.hasPrefix("j-"), let dot = name.firstIndex(of: ".") else {
                if p.hasSuffix("/jobs") || p == watchedDir { pending.insert("*") }
                continue
            }
            pending.insert(String(name[..<dot]))
        }
        guard !flushScheduled, !pending.isEmpty else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        let ids = pending
        pending.removeAll()
        if ids.contains("*") { rescan(); return }
        var changed: [Job] = []
        for id in ids {
            if FileManager.default.fileExists(atPath: JobFiles.json(id).path) {
                if let j = refresh(id) { changed.append(j) }
            } else if byID[id] != nil {
                byID[id] = nil; stamps[id] = nil
                rebuildList()
            }
        }
        publish(changed)
    }

    /// Re-fold one job when its files changed. Returns it when its effective state is new.
    private func refresh(_ id: String) -> Job? {
        let fm = FileManager.default
        let ja = try? fm.attributesOfItem(atPath: JobFiles.json(id).path)
        let ea = try? fm.attributesOfItem(atPath: JobFiles.events(id).path)
        let stamp = "\((ja?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(ja?[.size] ?? 0)|\(ea?[.size] ?? 0)"
        if stamps[id] == stamp { return nil }
        guard let d = try? Data(contentsOf: JobFiles.json(id)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }   // mid-write: next event
        stamps[id] = stamp
        guard let j = JobFold.job(JobFold.effective(json: o, events: JobFiles.events(id))) else { return nil }
        byID[id] = j
        return j
    }

    private func rebuildList() {
        jobs = byID.values.sorted { $0.created != $1.created ? $0.created > $1.created : $0.id > $1.id }
    }

    private func publish(_ changed: [Job]) {
        guard !changed.isEmpty else { return }
        rebuildList()
        onChange?(changed)
        for f in observers.values { f(changed) }
    }
}

// MARK: - JobWriter

/// A job the app owns (record / snap / voice / process). Every change rewrites <id>.json under its lock, after folding
/// in whatever others appended to <id>.events.jsonl (so the owner's json never goes back on a reported step).
public final class JobWriter {
    public let id: String
    private var doc: [String: Any]
    private let q = DispatchQueue(label: "blurt.jobwriter")

    public init(type: JobType, project: String?, session: URL?, parent: String? = nil, title: String? = nil) {
        id = JobFiles.newID()
        let now = JobFold.now()
        let steps = jobSteps[type] ?? []
        doc = ["schema": 1, "id": id, "type": type.rawValue, "state": "running", "owner": "app",
               "project": project ?? NSNull(), "session": session?.path ?? NSNull(), "parent": parent ?? NSNull(),
               "title": title ?? NSNull(), "items": [String](), "captures": [Int](),
               "steps": steps.map { ["id": $0, "state": "pending", "started": NSNull(), "ended": NSNull()] as [String: Any] },
               "progress": NSNull(), "created": now, "started": now, "ended": NSNull(), "updated": now,
               "events_offset": 0, "error": NSNull(), "app_pid": Int(getpid())]   // who to ask whether it is still alive
        save()
    }

    public func step(_ sid: String, _ state: StepState, progress: Double? = nil) {
        mutate { d in
            var steps = d["steps"] as? [[String: Any]] ?? []
            let i = steps.firstIndex { $0["id"] as? String == sid } ?? { steps.append(["id": sid]); return steps.count - 1 }()
            let prev = steps[i]["state"] as? String
            steps[i]["state"] = state.rawValue
            if let p = progress { steps[i]["progress"] = p }
            if state == .running, prev != "running" { steps[i]["started"] = JobFold.now() }
            if [.done, .failed, .skipped].contains(state) { steps[i]["ended"] = JobFold.now() }
            d["steps"] = steps
        }
    }

    public func setItems(_ uids: [String]) { mutate { $0["items"] = uids } }
    public func setCaptures(_ n: [Int]) { mutate { $0["captures"] = n } }
    public func setProgress(_ p: Double?) { mutate { $0["progress"] = p ?? NSNull() } }
    /// What the run cost (v0.7): {"tokens": n | null, "agent", "model", "effort"} — tokens 0 and agent null for a
    /// capture filed without an agent.
    public func setUsage(tokens: Int?, agent: String?, model: String?, effort: String?) {
        mutate { $0["usage"] = ["tokens": tokens ?? NSNull(), "agent": agent ?? NSNull(), "model": model ?? NSNull(),
                                "effort": effort ?? NSNull()] as [String: Any] }
    }

    /// A job that ends without finishing closes its steps: the running one failed, the pending ones skipped — never
    /// a step that keeps saying it runs on a finished job.
    public func finish(_ state: JobState, error: JobError? = nil) {
        mutate { d in JobFold.finishing(&d, state: state, error: error, at: JobFold.now()) }
    }

    /// Any other field of the job (the organiser's process group: "agent_pgid").
    public func set(_ key: String, _ value: Any?) { mutate { $0[key] = value ?? NSNull() } }

    private func mutate(_ f: (inout [String: Any]) -> Void) { q.sync { write(f) } }

    private func save() { q.sync { write { _ in } } }

    /// Under the job's lock: fold in what others reported since our last write, then our change, then replace the file.
    private func write(_ f: (inout [String: Any]) -> Void) {
        let fm = FileManager.default
        try? fm.createDirectory(at: JobFiles.dir, withIntermediateDirectories: true)
        let lfd = open(JobFiles.lock(id).path, O_RDWR | O_CREAT, 0o644)
        if lfd >= 0 { flock(lfd, LOCK_EX) }
        defer { if lfd >= 0 { flock(lfd, LOCK_UN); close(lfd) } }
        let (evs, end) = JobFold.events(JobFiles.events(id), from: doc["events_offset"] as? Int ?? 0)
        for e in evs { JobFold.apply(e, to: &doc) }
        doc["events_offset"] = end
        f(&doc)
        doc["updated"] = JobFold.now()
        guard let d = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) else { return }
        let tmp = JobFiles.dir.appendingPathComponent(".\(id).\(getpid()).tmp")
        guard fm.createFile(atPath: tmp.path, contents: d) else { return }
        _ = rename(tmp.path, JobFiles.json(id).path)
    }
}
