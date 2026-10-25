// Why a selection can't be handed to an agent session in Blurt, decided before the dispatch panel opens (⌘↩, the
// Item menu's tooltip, the review page's 交给 Agent) — the same rules sessions.py's plan() enforces, so the panel never
// opens on something it would refuse with a raw code. One reason, the first that applies, in this order:
//   unreadable      a file that doesn't parse (fix it in an editor first)
//   discarded       everything selected was discarded (restore first)
//   finished        to_verify / done / wontfix (reopen first)
//   withSession     handed_off / in_progress with a session that is still going (open that session)
//   mixedProjects   items of more than one project
//   needsProject    unassigned items (move them into a project first)
// handed_off / in_progress whose session is over (it failed to start, or ended without reporting) are NOT blocked:
// sessions.py takes them back and hands them to the new session.
import Foundation

public enum HandOffBlock: Equatable {
    case unreadable
    case discarded
    case finished(state: String)
    case withSession(itemID: String, job: String)
    case mixedProjects
    case needsProject
}

public enum HandOffCheck {
    public struct Item: Equatable {
        public var itemID: String, state: String, projectID: String, job: String?, unreadable: Bool
        public init(itemID: String, state: String, projectID: String, job: String? = nil, unreadable: Bool = false) {
            self.itemID = itemID; self.state = state; self.projectID = projectID; self.job = job; self.unreadable = unreadable
        }
    }

    /// nil = they can go. `isLive(job)`: that agent session is still going.
    public static func block(_ items: [Item], isLive: (String) -> Bool) -> HandOffBlock? {
        guard !items.isEmpty else { return nil }
        if items.contains(where: \.unreadable) { return .unreadable }
        let live = items.filter { $0.state != "discarded" }
        if live.isEmpty { return .discarded }
        if let f = live.first(where: { Lifecycle.closed.contains($0.state) || $0.state == "to_verify" }) {
            return .finished(state: f.state)
        }
        if let b = live.first(where: { ["handed_off", "in_progress"].contains($0.state) && $0.job.map(isLive) == true }),
           let j = b.job {
            return .withSession(itemID: b.itemID, job: j)
        }
        if Set(live.map(\.projectID)).count > 1 { return .mixedProjects }
        if live.first?.projectID == "inbox" { return .needsProject }
        return nil
    }
}
