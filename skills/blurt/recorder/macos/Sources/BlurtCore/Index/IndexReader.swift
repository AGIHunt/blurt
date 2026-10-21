// Read-only view of $BLURT_HOME/index.db (contract C3, docs/contracts/index-schema.sql), through the SQLite3 C API.
// index.py is the only writer; we open the file with ?mode=ro (WAL), so a scan running next to us never blocks a read.
// The query rules are the ones in index.py's docstring (§5 C3 细则): the query is split on whitespace, every term must
// match; a term of ≥ 3 characters goes to FTS5 (trigram) as a quoted phrase, a 1–2 character term becomes a LIKE on
// title / quote / body; no status filter = everything but deleted; fix state "none" = NULL; every sort ends on item_id.
//
// For big lists (the main window, 20k+ rows) use uids(_:) — the ordered uids of every match, one cheap column — and
// fetch the rows a screenful at a time with items(uids:).
import Foundation
import SQLite3

public struct WorkspaceRow: Hashable {
    public var id: String, path: String, name: String, kind: String    // kind: default | repo
    public var sessions: Int, openItems: Int
    public init(id: String, path: String, name: String, kind: String, sessions: Int = 0, openItems: Int = 0) {
        self.id = id; self.path = path; self.name = name; self.kind = kind; self.sessions = sessions; self.openItems = openItems
    }
}

public struct SessionRow: Hashable {
    public var id: String, workspaceID: String, dir: String, mode: String    // mode: video | shots
    public var title: String?, created: Double?, itemCount: Int, processed: Bool, processing: Bool, reviewed: Bool
    public var duration: Double? = nil, shotCount = 0, author: String? = nil, workspaceName: String? = nil
    public init(id: String, workspaceID: String, dir: String, mode: String, title: String? = nil, created: Double? = nil,
                itemCount: Int = 0, processed: Bool = false, processing: Bool = false, reviewed: Bool = false) {
        self.id = id; self.workspaceID = workspaceID; self.dir = dir; self.mode = mode; self.title = title; self.created = created
        self.itemCount = itemCount; self.processed = processed; self.processing = processing; self.reviewed = reviewed
    }
    /// unprocessed | processing | unreviewed | reviewed — the egg the UI shows (🥚, wobbling, 🐣, done)
    public var state: String { processing ? "processing" : !processed ? "unprocessed" : reviewed ? "reviewed" : "unreviewed" }
    public var url: URL { URL(fileURLWithPath: dir) }
}

/// C3 ItemRow, plus a few columns the native list shows (session title, workspace, created, frame count).
public struct ItemRow: Hashable {
    public var uid: String, sessionID: String, sessionDir: String, itemID: String, kind: String, title: String
    public var status: String, fixState: String?, severity: String?, primaryFrame: String?, updated: Double, snippet: String?
    public var quote = "", sessionTitle: String? = nil, workspaceName: String? = nil, created: Double? = nil
    public var frameCount = 0, hasCodeRefs = false, tStart: Double? = nil
    public init(uid: String, sessionID: String, sessionDir: String, itemID: String, kind: String, title: String, status: String,
                fixState: String? = nil, severity: String? = nil, primaryFrame: String? = nil, updated: Double = 0, snippet: String? = nil) {
        self.uid = uid; self.sessionID = sessionID; self.sessionDir = sessionDir; self.itemID = itemID; self.kind = kind
        self.title = title; self.status = status; self.fixState = fixState; self.severity = severity
        self.primaryFrame = primaryFrame; self.updated = updated; self.snippet = snippet
    }
    public var sessionURL: URL { URL(fileURLWithPath: sessionDir) }
}

public struct SessionQuery {
    /// unprocessed | processing | unreviewed | reviewed | inbox (= not processed yet, or processed and not reviewed)
    public var workspace: String?, state: String?
    public var limit = 200, offset = 0
    public init(workspace: String? = nil, state: String? = nil, limit: Int = 200, offset: Int = 0) {
        self.workspace = workspace; self.state = state; self.limit = limit; self.offset = offset
    }
}

public struct ItemQuery: Equatable {
    public var text: String?                          // ≥ 3 chars: FTS5 trigram; 1–2: LIKE; nil/empty: filters only
    public var kinds: [String] = [], statuses: [String] = [], fixStates: [String] = []   // fixStates may hold "none"
    public var workspace: String?, session: String?
    public var sort = "updated"                       // updated | created | t_start | title | kind | status | fix
    public var ascending = false                      // only for title / kind / status / fix and a flipped updated
    public var limit = 50, offset = 0                 // limit 0 = no limit (uids)
    public init(text: String? = nil, kinds: [String] = [], statuses: [String] = [], fixStates: [String] = [],
                workspace: String? = nil, session: String? = nil, sort: String = "updated", limit: Int = 50, offset: Int = 0) {
        self.text = text; self.kinds = kinds; self.statuses = statuses; self.fixStates = fixStates
        self.workspace = workspace; self.session = session; self.sort = sort; self.limit = limit; self.offset = offset
    }
    public var terms: [String] { (text ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init) }
}

/// Sidebar badges, one query.
public struct IndexCounts: Equatable {
    public var all = 0, inbox = 0, openIssues = 0, ideas = 0, fixing = 0, fixed = 0, sessions = 0
    public init() {}
}

public enum IndexError: Error, CustomStringConvertible {
    case notImplemented, open(String), query(String), missing(URL)
    public var description: String {
        switch self {
        case .notImplemented: return "not implemented"
        case .open(let s): return "index.db: \(s)"
        case .query(let s): return "index.db query: \(s)"
        case .missing(let u): return "no index at \(u.path)"
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class IndexReader {
    public let url: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()     // one connection, used from the main thread and a loader queue

    public init(url: URL = BlurtPaths.indexDB) throws {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { throw IndexError.missing(url) }
        var c = URLComponents()
        c.scheme = "file"
        c.path = url.path
        c.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        let uri = c.string ?? "file:\(url.path)?mode=ro"
        // ?mode=ro first. When index.py was the last connection, SQLite removed index.db-wal / -shm on close, and a
        // read-only connection can't recreate the -shm of a WAL database (SQLITE_CANTOPEN on the first statement).
        // Then: read-write without CREATE plus query_only — that only recreates the -shm, it never writes data.
        do {
            try connect(uri, SQLITE_OPEN_READONLY)
        } catch {
            sqlite3_close(db)
            db = nil
            try connect(url.path, SQLITE_OPEN_READWRITE)
            try each("PRAGMA query_only = 1", []) { _ in }
            _ = try scalarInt("SELECT COUNT(*) FROM items LIMIT 1")
        }
    }

    private func connect(_ path: String, _ mode: Int32) throws {
        let rc = sqlite3_open_v2(path, &db, mode | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, db != nil else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "rc \(rc)"
            throw IndexError.open(msg)
        }
        sqlite3_busy_timeout(db, 2000)
        // a file that isn't an index (or an older schema), or the -shm problem above, fails here, not on first use
        _ = try scalarInt("SELECT COUNT(*) FROM items LIMIT 1")
    }

    deinit { sqlite3_close(db) }

    // MARK: public queries

    /// Changes whenever another connection (index.py) commits: poll it to know when to reload.
    public var dataVersion: Int { (try? scalarInt("PRAGMA data_version")) ?? 0 }

    public func workspaces() throws -> [WorkspaceRow] {
        try rows("""
            SELECT w.id, w.path, w.name, w.kind,
                   (SELECT COUNT(*) FROM sessions s WHERE s.workspace_id = w.id),
                   (SELECT COUNT(*) FROM items i JOIN sessions s ON s.id = i.session_id WHERE s.workspace_id = w.id
                      AND i.status != 'deleted' AND (i.fix_state IS NULL OR i.fix_state IN ('fixing', 'reopened')))
            FROM workspaces w ORDER BY w.kind = 'default' DESC, w.last_seen DESC, w.name
            """, []) { s in
            WorkspaceRow(id: s.text(0), path: s.text(1), name: s.text(2), kind: s.text(3), sessions: s.int(4), openItems: s.int(5))
        }
    }

    public func sessions(_ q: SessionQuery) throws -> [SessionRow] {
        var wh: [String] = [], args: [Any] = []
        if let w = q.workspace { wh.append("s.workspace_id = ?"); args.append(w) }
        switch q.state {
        case "unprocessed": wh.append("s.processed = 0 AND s.processing = 0")
        case "processing": wh.append("s.processing = 1")
        case "unreviewed": wh.append("s.processed = 1 AND s.processing = 0 AND s.reviewed = 0")
        case "reviewed": wh.append("s.reviewed = 1")
        case "inbox": wh.append("(s.processed = 0 OR s.processing = 1 OR s.reviewed = 0)")
        default: break
        }
        let whereSQL = wh.isEmpty ? "" : "WHERE " + wh.joined(separator: " AND ")
        args += [q.limit > 0 ? q.limit : -1, q.offset]
        return try rows("""
            SELECT s.id, s.workspace_id, s.dir, s.mode, s.title, s.created, s.item_count, s.processed, s.processing,
                   s.reviewed, s.duration, s.shot_count, s.author, w.name
            FROM sessions s JOIN workspaces w ON w.id = s.workspace_id \(whereSQL)
            ORDER BY s.created DESC, s.id LIMIT ? OFFSET ?
            """, args) { s in
            var r = SessionRow(id: s.text(0), workspaceID: s.text(1), dir: s.text(2), mode: s.text(3), title: s.optText(4),
                               created: s.optDouble(5), itemCount: s.int(6), processed: s.int(7) != 0,
                               processing: s.int(8) != 0, reviewed: s.int(9) != 0)
            r.duration = s.optDouble(10); r.shotCount = s.int(11); r.author = s.optText(12); r.workspaceName = s.optText(13)
            return r
        }
    }

    public func session(id: String) throws -> SessionRow? {
        try sessions(SessionQuery(limit: 0)).first { $0.id == id }
    }

    public func items(_ q: ItemQuery) throws -> [ItemRow] {
        let (base, args, fts) = whereClause(q)
        let snip = fts ? "snippet(items_fts, -1, '[', ']', '…', 12)" : "NULL"
        let lim = q.limit > 0 ? q.limit : -1
        var out = try rows("SELECT \(Self.cols), \(snip) \(base) ORDER BY \(order(q)) LIMIT ? OFFSET ?",
                           args + [lim, q.offset], Self.itemRow)
        let terms = q.terms
        if !fts, !terms.isEmpty { for k in out.indices { out[k].snippet = Self.snippet(out[k], terms) } }
        return out
    }

    public func count(_ q: ItemQuery) throws -> Int {
        let (base, args, _) = whereClause(q)
        return try scalarInt("SELECT COUNT(*) \(base)", args)
    }

    /// The uids of every match, in display order (limit 0 = all of them).
    public func uids(_ q: ItemQuery) throws -> [String] {
        let (base, args, _) = whereClause(q)
        let lim = q.limit > 0 ? q.limit : -1
        return try rows("SELECT i.uid \(base) ORDER BY \(order(q)) LIMIT ? OFFSET ?", args + [lim, q.offset]) { $0.text(0) }
    }

    /// Full rows for these uids, in the same order (missing uids are skipped). `terms` fills `snippet`.
    public func items(uids: [String], terms: [String] = []) throws -> [ItemRow] {
        guard !uids.isEmpty else { return [] }
        var byUID: [String: ItemRow] = [:]
        for chunk in stride(from: 0, to: uids.count, by: 500).map({ Array(uids[$0..<min($0 + 500, uids.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for r in try rows("SELECT \(Self.cols), NULL FROM items i JOIN sessions s ON s.id = i.session_id " +
                              "JOIN workspaces w ON w.id = s.workspace_id WHERE i.uid IN (\(marks))", chunk, Self.itemRow) {
                byUID[r.uid] = r
            }
        }
        return uids.compactMap { u in
            guard var r = byUID[u] else { return nil }
            if !terms.isEmpty { r.snippet = Self.snippet(r, terms) }
            return r
        }
    }

    public func item(uid: String) throws -> ItemRow? { try items(uids: [uid]).first }

    public func counts() throws -> IndexCounts {
        var c = IndexCounts()
        try each("""
            SELECT COUNT(*),
                   SUM(kind = 'issue' AND (fix_state IS NULL OR fix_state IN ('fixing', 'reopened'))),
                   SUM(kind = 'idea'), SUM(fix_state = 'fixing'), SUM(fix_state = 'fixed')
            FROM items WHERE status != 'deleted'
            """, []) { s in
            c.all = s.int(0); c.openIssues = s.int(1); c.ideas = s.int(2); c.fixing = s.int(3); c.fixed = s.int(4)
        }
        c.inbox = try scalarInt("SELECT COUNT(*) FROM sessions WHERE processed = 0 OR processing = 1 OR reviewed = 0")
        c.sessions = try scalarInt("SELECT COUNT(*) FROM sessions")
        return c
    }

    /// meta.last_full_scan (epoch seconds), nil before the first scan.
    public func lastFullScan() -> Double? {
        var v: Double?
        try? each("SELECT value FROM meta WHERE key = 'last_full_scan'", []) { v = Double($0.text(0)) }
        return v
    }

    // MARK: SQL building (index.py search, §5 C3)

    static let cols = """
        i.uid, i.session_id, s.dir, i.item_id, i.kind, i.title, i.status, i.fix_state, i.severity, i.primary_frame, \
        i.updated, i.quote, s.title, w.name, s.created, i.frame_count, i.has_code_refs, i.t_start
        """

    static func itemRow(_ s: Stmt) -> ItemRow {
        var r = ItemRow(uid: s.text(0), sessionID: s.text(1), sessionDir: s.text(2), itemID: s.text(3), kind: s.text(4),
                        title: s.text(5), status: s.text(6), fixState: s.optText(7), severity: s.optText(8),
                        primaryFrame: s.optText(9), updated: s.double(10), snippet: s.optText(18))
        r.quote = s.text(11); r.sessionTitle = s.optText(12); r.workspaceName = s.optText(13); r.created = s.optDouble(14)
        r.frameCount = s.int(15); r.hasCodeRefs = s.int(16) != 0; r.tStart = s.optDouble(17)
        return r
    }

    static func like(_ t: String) -> String {
        "%" + t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
    }

    /// "FROM … WHERE …", its arguments, and whether it joins items_fts.
    func whereClause(_ q: ItemQuery) -> (String, [Any], Bool) {
        let terms = q.terms
        let fts = terms.filter { $0.count >= 3 }, short = terms.filter { $0.count < 3 }
        var wh: [String] = [], args: [Any] = []
        if !fts.isEmpty {
            wh.append("items_fts MATCH ?")
            args.append(fts.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND "))
        }
        for t in short {
            wh.append("(i.title LIKE ? ESCAPE '\\' OR i.quote LIKE ? ESCAPE '\\' OR i.body LIKE ? ESCAPE '\\')")
            let l = Self.like(t)
            args += [l, l, l]
        }
        func list(_ col: String, _ v: [String]) {
            wh.append("\(col) IN (\(Array(repeating: "?", count: v.count).joined(separator: ",")))")
            args += v as [Any]
        }
        if q.statuses.isEmpty { wh.append("i.status != 'deleted'") } else { list("i.status", q.statuses) }
        if !q.kinds.isEmpty { list("i.kind", q.kinds) }
        if !q.fixStates.isEmpty {
            let fs = q.fixStates.filter { $0 != "none" }
            var parts: [String] = []
            if !fs.isEmpty { parts.append("i.fix_state IN (\(Array(repeating: "?", count: fs.count).joined(separator: ",")))"); args += fs as [Any] }
            if q.fixStates.contains("none") { parts.append("i.fix_state IS NULL") }
            wh.append("(" + parts.joined(separator: " OR ") + ")")
        }
        if let w = q.workspace { wh.append("s.workspace_id = ?"); args.append(w) }
        if let s = q.session { wh.append("i.session_id = ?"); args.append(s) }
        let join = fts.isEmpty ? "" : "JOIN items_fts f ON f.rowid = i.rowid "
        return ("FROM items i \(join)JOIN sessions s ON s.id = i.session_id JOIN workspaces w ON w.id = s.workspace_id " +
                "WHERE \(wh.joined(separator: " AND "))", args, !fts.isEmpty)
    }

    func order(_ q: ItemQuery) -> String {
        let dir = q.ascending ? "ASC" : "DESC"
        switch q.sort {
        case "created": return "s.created DESC, i.t_start, i.item_id"
        case "t_start": return "i.t_start, s.created DESC, i.item_id"
        case "title": return "i.title COLLATE NOCASE \(q.ascending ? "ASC" : "DESC"), i.updated DESC, i.item_id"
        case "kind": return "i.kind \(dir), i.updated DESC, i.item_id"
        case "status": return "i.status \(dir), i.updated DESC, i.item_id"
        case "fix": return "i.fix_state IS NULL, i.fix_state \(dir), i.updated DESC, i.item_id"
        default: return "i.updated \(dir), i.item_id"
        }
    }

    /// The host's own snippet for LIKE-only matches (index.py _snippet: ~20 characters either side of the hit).
    static func snippet(_ r: ItemRow, _ terms: [String], width: Int = 40) -> String? {
        for text in [r.title, r.quote] {
            let lower = text.lowercased()
            for t in terms {
                guard let k = lower.range(of: t.lowercased()) else { continue }
                let a = lower.index(k.lowerBound, offsetBy: -width / 2, limitedBy: lower.startIndex) ?? lower.startIndex
                let b = lower.index(k.upperBound, offsetBy: width / 2, limitedBy: lower.endIndex) ?? lower.endIndex
                // same offsets in the original text (lowercasing can change lengths only for exotic scripts)
                guard lower.count == text.count else { return text }
                let ia = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: a))
                let ik = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: k.lowerBound))
                let ie = text.index(ik, offsetBy: lower.distance(from: k.lowerBound, to: k.upperBound))
                let ib = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: b))
                return (a > lower.startIndex ? "…" : "") + text[ia..<ik] + "[" + text[ik..<ie] + "]" + text[ie..<ib] +
                    (b < lower.endIndex ? "…" : "")
            }
        }
        return nil
    }

    // MARK: statements

    final class Stmt {
        let p: OpaquePointer
        init(_ p: OpaquePointer) { self.p = p }
        func text(_ i: Int32) -> String { sqlite3_column_text(p, i).map { String(cString: $0) } ?? "" }
        func optText(_ i: Int32) -> String? { sqlite3_column_type(p, i) == SQLITE_NULL ? nil : text(i) }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(p, i)) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(p, i) }
        func optDouble(_ i: Int32) -> Double? { sqlite3_column_type(p, i) == SQLITE_NULL ? nil : double(i) }
    }

    private func each(_ sql: String, _ args: [Any], _ row: (Stmt) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let p = st else {
            throw IndexError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(p) }
        for (k, a) in args.enumerated() {
            let i = Int32(k + 1)
            switch a {
            case let s as String: sqlite3_bind_text(p, i, s, -1, SQLITE_TRANSIENT)
            case let n as Int: sqlite3_bind_int64(p, i, Int64(n))
            case let d as Double: sqlite3_bind_double(p, i, d)
            default: sqlite3_bind_null(p, i)
            }
        }
        let s = Stmt(p)
        while true {
            let rc = sqlite3_step(p)
            if rc == SQLITE_ROW { try row(s); continue }
            if rc == SQLITE_DONE { break }
            throw IndexError.query(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func rows<T>(_ sql: String, _ args: [Any], _ map: (Stmt) -> T) throws -> [T] {
        var out: [T] = []
        try each(sql, args) { out.append(map($0)) }
        return out
    }

    private func scalarInt(_ sql: String, _ args: [Any] = []) throws -> Int {
        var v = 0
        try each(sql, args) { v = $0.int(0) }
        return v
    }
}
