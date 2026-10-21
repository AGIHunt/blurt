// K4 jobs (G0 stub, owner P3): $BLURT_HOME/jobs/<id>.json written by the owner, <id>.events.jsonl appended by
// everyone else; readers fold the events on top (steps by id, status, state, progress, items ∪). The stub polls the
// folder once a second; P3 replaces it with FSEvents.
import Foundation

public enum JobType: String { case record, snap, voice, process, route, agent }
public enum JobState: String { case queued, running, done, failed, cancelled }
public enum StepState: String { case pending, running, done, failed, skipped }
public enum AgentSessionStatus: String { case running, waitingInput = "waiting_input", turnDone = "turn_done", exited, error }

public struct JobStep { public let id: String; public let state: StepState; public let progress: Double? }
public struct JobError { public let code: String; public let message: String; public let hintKey: String? }
public struct AgentInfo {
    public let agent, mode, runner: String
    public let tmuxSession, tmuxWindow, windowName, branch, handoff: String?
    public let cwd: URL; public let worktree: URL?; public let status: AgentSessionStatus; public let statusAt: Date?; public let exit: Int32?
}

public struct Job: Identifiable {
    public let id: String; public let type: JobType; public let state: JobState; public let project: String?
    public let session: URL?; public let parent, title: String?; public let items: [String]; public let captures: [Int]; public let steps: [JobStep]
    public let progress: Double?; public let created: Date; public let started, ended: Date?; public let error: JobError?; public let agent: AgentInfo?
    public var isActive: Bool { state == .queued || state == .running }
}

enum JobFiles {
    static var dir: URL { BlurtPaths.home.appendingPathComponent("jobs") }
    static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.timeZone = .current; return f }()
    static func now() -> String { iso.string(from: Date()) }
}

public final class JobStore {
    public static let shared = JobStore()
    public private(set) var jobs: [Job] = []
    public var active: [Job] { jobs.filter(\.isActive) }
    public func job(_ id: String) -> Job? { jobs.first { $0.id == id } }
    public var onChange: ((_ changed: [Job]) -> Void)?

    private var timer: Timer?
    private var stamps: [String: Date] = [:]

    public init() {}

    public func start() {
        guard timer == nil else { return }
        scan()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.scan() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() { timer?.invalidate(); timer = nil }

    /// Re-read every job whose json or events changed.
    public func scan() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: JobFiles.dir.path)) ?? []
        var byID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        var changed: [Job] = []
        var seen = Set<String>()
        for n in names where n.hasSuffix(".json") && !n.contains(".claude-settings") {
            let id = String(n.dropLast(5))
            seen.insert(id)
            let j = JobFiles.dir.appendingPathComponent(n), ev = JobFiles.dir.appendingPathComponent("\(id).events.jsonl")
            let m = [j, ev].compactMap { (try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }.max()
            guard m != stamps[id] else { continue }
            stamps[id] = m
            if let job = Self.read(id) { byID[id] = job; changed.append(job) }
        }
        for id in byID.keys where !seen.contains(id) { byID.removeValue(forKey: id) }
        jobs = byID.values.sorted { $0.created > $1.created }
        if !changed.isEmpty { onChange?(changed) }
    }

    /// The effective state: the json plus every event after events_offset.
    static func read(_ id: String) -> Job? {
        guard let d = try? Data(contentsOf: JobFiles.dir.appendingPathComponent("\(id).json")),
              var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        if let ev = try? Data(contentsOf: JobFiles.dir.appendingPathComponent("\(id).events.jsonl")) {
            let off = min(ev.count, o["events_offset"] as? Int ?? 0)
            var steps = o["steps"] as? [[String: Any]] ?? []
            var items = o["items"] as? [String] ?? []
            for line in ev[off...].split(separator: 0x0A) {
                guard let e = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if let s = e["state"] as? String { o["state"] = s }
                if let p = e["progress"] { o["progress"] = p }
                if let st = e["step"] as? [String: Any], let sid = st["id"] as? String {
                    if let i = steps.firstIndex(where: { $0["id"] as? String == sid }) { steps[i].merge(st) { $1 } } else { steps.append(st) }
                }
                if let its = e["items"] as? [String] { items += its.filter { !items.contains($0) } }
                if let status = e["status"] as? String {
                    var a = o["agent"] as? [String: Any] ?? [:]
                    a["status"] = status; a["status_at"] = e["t"]; a["status_source"] = e["source"]
                    o["agent"] = a
                }
            }
            o["steps"] = steps
            o["items"] = items
        }
        return decode(o)
    }

    static func decode(_ o: [String: Any]) -> Job? {
        guard let id = o["id"] as? String, let type = JobType(rawValue: o["type"] as? String ?? "") else { return nil }
        let iso = JobFiles.iso
        func date(_ k: String) -> Date? { (o[k] as? String).flatMap(iso.date(from:)) }
        let steps = (o["steps"] as? [[String: Any]] ?? []).compactMap { s -> JobStep? in
            guard let sid = s["id"] as? String else { return nil }
            return JobStep(id: sid, state: StepState(rawValue: s["state"] as? String ?? "") ?? .pending, progress: s["progress"] as? Double)
        }
        let err = (o["error"] as? [String: Any]).map {
            JobError(code: $0["code"] as? String ?? "unknown", message: $0["message"] as? String ?? "", hintKey: $0["hint_key"] as? String)
        }
        var agent: AgentInfo?
        if let a = o["agent"] as? [String: Any], let cwd = a["cwd"] as? String {
            let t = a["tmux"] as? [String: Any], w = a["worktree"] as? [String: Any]
            agent = AgentInfo(agent: a["id"] as? String ?? "", mode: a["mode"] as? String ?? "together", runner: a["runner"] as? String ?? "tmux",
                              tmuxSession: t?["session"] as? String, tmuxWindow: t?["window"] as? String, windowName: t?["name"] as? String,
                              branch: w?["branch"] as? String, handoff: a["handoff"] as? String, cwd: URL(fileURLWithPath: cwd),
                              worktree: (w?["path"] as? String).map { URL(fileURLWithPath: $0) },
                              status: AgentSessionStatus(rawValue: a["status"] as? String ?? "") ?? .running,
                              statusAt: (a["status_at"] as? String).flatMap(iso.date(from:)), exit: (a["exit"] as? Int).map(Int32.init))
        }
        return Job(id: id, type: type, state: JobState(rawValue: o["state"] as? String ?? "") ?? .queued, project: o["project"] as? String,
                   session: (o["session"] as? String).map { URL(fileURLWithPath: $0) }, parent: o["parent"] as? String,
                   title: o["title"] as? String, items: o["items"] as? [String] ?? [], captures: o["captures"] as? [Int] ?? [],
                   steps: steps, progress: o["progress"] as? Double, created: date("created") ?? Date(), started: date("started"),
                   ended: date("ended"), error: err, agent: agent)
    }
}

/// A job the app owns (record / snap / voice / process): it alone rewrites <id>.json (atomically).
public final class JobWriter {
    public let id: String
    private var o: [String: Any]

    public init(type: JobType, project: String?, session: URL?, parent: String? = nil, title: String? = nil) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        id = "j-\(f.string(from: Date()))-" + String((0..<4).map { _ in alphabet.randomElement()! })
        let now = JobFiles.now()
        o = ["schema": 1, "id": id, "type": type.rawValue, "state": "running", "owner": "app", "project": project ?? NSNull(),
             "session": session?.path ?? NSNull(), "parent": parent ?? NSNull(), "title": title ?? NSNull(), "items": [String](),
             "captures": [Int](), "steps": [[String: Any]](), "progress": NSNull(), "created": now, "started": now,
             "ended": NSNull(), "updated": now, "events_offset": 0, "error": NSNull()]
        write()
    }

    public func step(_ sid: String, _ state: StepState, progress: Double? = nil) {
        var steps = o["steps"] as? [[String: Any]] ?? []
        let now = JobFiles.now()
        if let i = steps.firstIndex(where: { $0["id"] as? String == sid }) {
            steps[i]["state"] = state.rawValue
            steps[i]["progress"] = progress ?? NSNull()
            if state != .running && state != .pending { steps[i]["ended"] = now }
        } else {
            steps.append(["id": sid, "state": state.rawValue, "progress": progress ?? NSNull(), "started": now,
                          "ended": state == .running || state == .pending ? NSNull() : now])
        }
        o["steps"] = steps
        write()
    }
    public func setItems(_ uids: [String]) { o["items"] = uids; write() }
    public func setCaptures(_ n: [Int]) { o["captures"] = n; write() }
    public func setProgress(_ p: Double?) { o["progress"] = p ?? NSNull(); write() }
    public func finish(_ state: JobState, error: JobError? = nil) {
        o["state"] = state.rawValue
        o["ended"] = JobFiles.now()
        if let e = error { o["error"] = ["code": e.code, "message": e.message, "hint_key": e.hintKey as Any? ?? NSNull()] as [String: Any] }
        write()
    }

    private func write() {
        o["updated"] = JobFiles.now()
        let fm = FileManager.default
        try? fm.createDirectory(at: JobFiles.dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: JobFiles.dir.appendingPathComponent("\(id).json"), options: .atomic)
        }
    }
}
