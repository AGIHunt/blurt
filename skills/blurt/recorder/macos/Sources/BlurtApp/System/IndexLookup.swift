// The few read-only index.db queries the system integrations need (uid → session, Spotlight rows). Opened read-only
// (C3: only index.py writes it). The main window's IndexReader (WP5) is the general reader; this stays small on purpose.
import Foundation
import SQLite3
import BlurtCore

struct IndexedItem {
    var uid: String, itemID: String, kind: String, title: String, quote: String
    var status: String, fixState: String?, primaryFrame: String?, updated: Double
    var sessionDir: String, sessionTitle: String?, workspacePath: String, workspaceKind: String
}

enum IndexLookup {
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func query(_ sql: String, _ args: [String], _ row: (OpaquePointer) -> Void) -> Bool {
        let path = BlurtPaths.indexDB.path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        // A WAL database can't be opened read-only while its -shm file is missing (index.py closed it last, and
        // SQLite removed -wal/-shm): SQLITE_CANTOPEN. Then open it read-write without CREATE, with query_only on —
        // that only recreates the -shm; no data is ever written from here.
        var db: OpaquePointer?
        var st: OpaquePointer?
        for flags in [SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI] {
            guard sqlite3_open_v2(flags & SQLITE_OPEN_READONLY != 0 ? "file:\(path)?mode=ro" : "file:\(path)", &db, flags, nil) == SQLITE_OK else {
                sqlite3_close(db); db = nil; continue
            }
            sqlite3_busy_timeout(db, 2000)
            if flags & SQLITE_OPEN_READWRITE != 0 { sqlite3_exec(db, "PRAGMA query_only = 1", nil, nil, nil) }
            if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK { break }
            sqlite3_close(db); db = nil; st = nil
        }
        guard let db = db, let st = st else { return false }
        defer { sqlite3_close(db) }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() { sqlite3_bind_text(st, Int32(i + 1), a, -1, SQLITE_TRANSIENT) }
        while sqlite3_step(st) == SQLITE_ROW { row(st) }
        return true
    }

    private static func text(_ st: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(st, i) else { return nil }
        return String(cString: c)
    }

    private static let select = """
        SELECT i.uid, i.item_id, i.kind, i.title, i.quote, i.status, i.fix_state, i.primary_frame, i.updated,
               s.dir, s.title, w.path, w.kind
        FROM items i JOIN sessions s ON s.id = i.session_id JOIN workspaces w ON w.id = s.workspace_id
        """

    private static func row(_ st: OpaquePointer) -> IndexedItem {
        IndexedItem(uid: text(st, 0) ?? "", itemID: text(st, 1) ?? "", kind: text(st, 2) ?? "note", title: text(st, 3) ?? "",
                    quote: text(st, 4) ?? "", status: text(st, 5) ?? "draft", fixState: text(st, 6), primaryFrame: text(st, 7),
                    updated: sqlite3_column_double(st, 8), sessionDir: text(st, 9) ?? "", sessionTitle: text(st, 10),
                    workspacePath: text(st, 11) ?? "", workspaceKind: text(st, 12) ?? "default")
    }

    static func item(uid: String) -> IndexedItem? {
        var out: IndexedItem?
        _ = query(select + " WHERE i.uid = ?1", [uid]) { out = row($0) }
        return out
    }

    /// Live items (not deleted), newest first.
    static func items(limit: Int = 5000) -> [IndexedItem] {
        var out: [IndexedItem] = []
        _ = query(select + " WHERE i.status != 'deleted' ORDER BY i.updated DESC LIMIT \(limit)", []) { out.append(row($0)) }
        return out
    }

    static var available: Bool { FileManager.default.fileExists(atPath: BlurtPaths.indexDB.path) }
}

/// items.json of a session, read directly (fix state / title of one item) — for when the index has not caught up.
func readItems(_ session: URL) -> [[String: Any]] {
    guard let d = try? Data(contentsOf: session.appendingPathComponent("items.json")),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
    return o["items"] as? [[String: Any]] ?? []
}
