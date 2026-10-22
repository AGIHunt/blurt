// The few index.db lookups the system integrations need (uid → item, Spotlight rows), on a short-lived IndexReader
// (read-only; only index.py writes the index). The main window keeps its own long-lived reader.
import Foundation
import BlurtCore

struct IndexedItem {
    var uid: String, itemID: String, kind: String, title: String, quote: String
    var status: String, workState: String, primaryFrame: String?, updated: Double
    /// the item's .md file
    var path: String
    /// "" for an item with no source session
    var sessionDir: String, sessionTitle: String?
    /// the project folder (the inbox store for unassigned items), its id and name
    var workspacePath: String, projectID: String, projectName: String

    /// The v2 fix state, for callers that still speak it (K3's mapping, reversed).
    var fixState: String? {
        switch workState {
        case "handed_off", "in_progress": return "fixing"
        case "to_verify", "done": return "fixed"
        case "wontfix": return "wontfix"
        default: return nil
        }
    }
}

enum IndexLookup {
    static var available: Bool { FileManager.default.fileExists(atPath: BlurtPaths.indexDB.path) }

    private static func reader() -> IndexReader? { try? IndexReader(url: BlurtPaths.indexDB) }

    private static func make(_ r: ItemRow, _ paths: [String: String]) -> IndexedItem {
        IndexedItem(uid: r.uid, itemID: r.itemID, kind: r.kind, title: r.title, quote: r.quote, status: r.status, workState: r.workState,
                    primaryFrame: r.primaryFrame, updated: r.updated, path: r.fileURL.path, sessionDir: r.sessionDir ?? "",
                    sessionTitle: r.sessionTitle, workspacePath: paths[r.projectID] ?? "", projectID: r.projectID, projectName: r.projectName)
    }

    private static func paths(_ r: IndexReader) -> [String: String] {
        Dictionary(((try? r.projects()) ?? []).map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
    }

    static func item(uid: String) -> IndexedItem? {
        guard let r = reader(), let row = (try? r.item(uid: uid)) ?? nil else { return nil }
        return make(row, paths(r))
    }

    /// Live items (not dropped), newest first.
    static func items(limit: Int = 5000) -> [IndexedItem] {
        guard let r = reader() else { return [] }
        let p = paths(r)
        return ((try? r.items(ItemQuery(limit: limit))) ?? []).map { make($0, p) }
    }
}

/// A v2 session's items.json, read directly — only FixWatcher (P3) still needs it, until it follows work states.
func readItems(_ session: URL) -> [[String: Any]] {
    guard let d = try? Data(contentsOf: session.appendingPathComponent("items.json")),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
    return o["items"] as? [[String: Any]] ?? []
}
