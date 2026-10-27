// The agent session behind an item (K3 `work.job` → a K4 agent job): what the line above the item, the Item menu and
// the job view say about it. An exit never moves an item (sessions.py: only the agent's own report does), so a
// session that ended while its items are still with it is a state the user resolves — and a session id that points
// at nothing (a v0.6 run, a job that is gone) is said to be gone, never offered as a button that does nothing.
import Foundation

public enum WorkSession: Equatable {
    /// running, waiting for you or between turns: Open Session
    case live(AgentSessionStatus)
    /// exited, crashed or stopped (.exited / .error) without the agent saying the items are done
    case ended(AgentSessionStatus)
    /// no record of it any more
    case gone

    /// For an item in `state` handed to a session (`to` "session", or a `job` set). nil: the item isn't with a
    /// session (not handed off, in progress or to verify; or handed off to the user's own agent).
    public static func of(state: String, to: String?, job: String?, lookup: (String) -> Job?) -> WorkSession? {
        guard Lifecycle.active.contains(state), to == "session" || (job ?? "").isEmpty == false else { return nil }
        guard let id = job, !id.isEmpty, let j = lookup(id), j.type == .agent, let a = j.agent else { return .gone }
        if j.isActive, a.status != .exited, a.status != .error { return .live(a.status) }
        return .ended(a.status == .error || j.state == .failed ? .error : .exited)
    }

    /// There is a session to open (its terminal, its log).
    public var canOpen: Bool { self != .gone }
}

/// What the review page sends over the host bridge (web/packages/review/src/hosts/macos.ts).
public enum ReviewHostParams {
    /// openSession's job id: the page sends {job}; {jobId} is what older builds of this side read.
    public static func job(_ p: [String: Any]) -> String? {
        ((p["job"] ?? p["jobId"]) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// review.py's page, shown in the main window instead of the browser (SKILL.md §3–5): the app tells review.py it
/// has the batch (`api/attached`, so no browser opens) and that the user confirmed it (`api/done`, so review.py
/// prints its summary and the agent goes on). Only review.py's own address is ever called: a local http URL with
/// its per-run token path — a distributed notification can come from any process.
public enum ReviewLink {
    public static func endpoint(_ base: String, _ path: String) -> URL? {
        guard let u = URL(string: base), let c = URLComponents(url: u, resolvingAgainstBaseURL: false), c.scheme == "http",
              ["127.0.0.1", "localhost"].contains(c.host ?? ""), c.port != nil, c.path.hasPrefix("/r/"), c.path.hasSuffix("/"),
              c.path.count > 4, c.query == nil else { return nil }
        return URL(string: path, relativeTo: u)?.absoluteURL
    }
}

/// A Range request on a file of `size` bytes, answered with at most `cap` bytes (a player asks for the next part):
/// nil when it can't be satisfied (416).
public enum ByteRange {
    public static let cap = 8 << 20

    public static func plan(_ header: String, size: Int, cap: Int = ByteRange.cap) -> ClosedRange<Int>? {
        guard header.hasPrefix("bytes="), size > 0 else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        var start: Int, end: Int
        if parts[0].isEmpty {           // bytes=-N: the last N
            guard let n = Int(parts[1]), n > 0 else { return nil }
            start = max(0, size - n)
            end = size - 1
        } else {
            guard let s = Int(parts[0]) else { return nil }
            start = s
            end = parts[1].isEmpty ? size - 1 : Int(parts[1]) ?? size - 1
        }
        end = min(end, size - 1, start + cap - 1)
        guard start >= 0, start < size, end >= start else { return nil }
        return start...end
    }
}
