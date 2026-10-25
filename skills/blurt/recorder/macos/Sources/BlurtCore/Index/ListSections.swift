// The main window's lists come grouped (Linear's grouped list, Mail's sections): the Inbox by project — in the one
// project order every picker and the sidebar use (pinned, then most recently used), Unassigned last — and In Progress,
// All Items and a project by state, what needs you first (To verify, In progress, Handed off, New, To do, Done,
// Won't do, Discarded). The rows keep the place's sort inside each group. A run's header is drawn above its first row
// (the row is taller, the header in its top band), so row numbers stay the model's: nothing else in the window maps
// between "table rows" and "items". One group alone gets no header (a State filter, a project with only new items).
import Foundation

public struct ListSection: Equatable {
    /// `project`: the run's key — a project id ("inbox" for Unassigned), or a state when the list groups by state.
    public let start: Int, count: Int, project: String
    public init(start: Int, count: Int, project: String) { self.start = start; self.count = count; self.project = project }
    public var key: String { project }
}

public enum ListSections {
    /// The order the state groups come in: what needs you first, then what is moving, then what is new or waiting,
    /// then what is closed.
    public static let stateOrder = ["to_verify", "in_progress", "handed_off", "new", "todo", "done", "wontfix", "discarded"]

    /// Runs of the same key, in order. A key that shows up again later (an id typed into the search comes first,
    /// wherever its project sorts) starts a run of its own.
    public static func runs(_ projects: [String]) -> [ListSection] {
        var out: [ListSection] = []
        var start = 0
        for k in projects.indices where k == projects.count - 1 || projects[k + 1] != projects[k] {
            out.append(ListSection(start: start, count: k - start + 1, project: projects[k]))
            start = k + 1
        }
        return out
    }

    /// The run that starts at each row (only rows that start one are keys).
    public static func starts(_ runs: [ListSection]) -> [Int: ListSection] {
        Dictionary(runs.map { ($0.start, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// The rows bucketed by key, the buckets in `rank` order (lower first; ties keep the order a key first shows up),
    /// each bucket keeping the rows' own order. Returns the uids and their keys, in the new order.
    public static func grouped(_ rows: [(uid: String, key: String)], rank: (String) -> Int) -> (uids: [String], keys: [String]) {
        var order: [String] = []
        var buckets: [String: [String]] = [:]
        for r in rows {
            if buckets[r.key] == nil { order.append(r.key); buckets[r.key] = [] }
            buckets[r.key]!.append(r.uid)
        }
        let first = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let keys = order.sorted { (rank($0), first[$0]!) < (rank($1), first[$1]!) }
        var uids: [String] = [], out: [String] = []
        for k in keys {
            let b = buckets[k]!
            uids += b
            out += Array(repeating: k, count: b.count)
        }
        return (uids, out)
    }

    /// A state group's rank (stateOrder; an unknown state after them).
    public static func stateRank(_ s: String) -> Int { stateOrder.firstIndex(of: s) ?? stateOrder.count }

    /// A project group's rank: its place in `projects` (the one order: pinned, then recent), a project not in it
    /// (an unopened folder) after them, Unassigned last.
    public static func projectRank(_ projects: [String]) -> (String) -> Int {
        let at = Dictionary(projects.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return { id in id == "inbox" ? Int.max : at[id] ?? projects.count }
    }
}
