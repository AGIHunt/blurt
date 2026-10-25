// The main window's Inbox and In Progress lists come grouped by project (Linear's grouped list, Mail's sections):
// IndexReader's `byProject` order puts each project's rows together, Unassigned first; this cuts that order into runs.
// A run's header is drawn above its first row (the row is taller, the header in its top band), so row numbers stay
// the model's: nothing else in the window maps between "table rows" and "items".
import Foundation

public struct ListSection: Equatable {
    public let start: Int, count: Int, project: String
    public init(start: Int, count: Int, project: String) { self.start = start; self.count = count; self.project = project }
}

public enum ListSections {
    /// Runs of the same project, in order. A project that shows up again later (an id typed into the search comes
    /// first, wherever its project sorts) starts a run of its own.
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
}
