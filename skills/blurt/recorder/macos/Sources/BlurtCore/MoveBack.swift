// ⌘Z after "Move to Project": every item goes back to the project it came from — one `items.py move` per original
// project (a selection from All Items can come from several), in the order the items were selected. items.py gives
// an item moving back its old id there again (_former_id), so a move and its undo leave the ids as they were.
import Foundation

public enum MoveBack {
    public struct Step: Equatable {
        public let project: String
        public let uids: [String]
    }

    /// `before`: each moved item's uid and the project it was in ("inbox" = Unassigned); `dest`: where they went.
    /// Items that were already there (not moved) stay.
    public static func plan(_ before: [(uid: String, project: String)], movedTo dest: String) -> [Step] {
        var order: [String] = []
        var by: [String: [String]] = [:]
        for (uid, p) in before where p != dest {
            if by[p] == nil { order.append(p) }
            by[p, default: []].append(uid)
        }
        return order.map { Step(project: $0, uids: by[$0]!) }
    }
}
