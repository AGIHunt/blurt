// Read-only view of $BLURT_HOME/index.db, schema v3 (docs/design/next-round.md K1 "index.db", K3's one `state`,
// docs/contracts/index-schema.sql), through the SQLite3 C API. index.py is the only writer; we open the file with
// ?mode=ro (WAL), so a scan running next to us never blocks a read. Query rules as index.py search (C3): the query is
// split on whitespace, every term must match; a term of ≥ 3 characters goes to FTS5 (trigram) as a quoted phrase, a
// 1–2 character term becomes a LIKE on title / quote / body; no state filter = everything but discarded; every sort
// ends on item_id.
//
// For big lists (the main window, 20k+ rows) use uids(_:) — the ordered uids of every match, one cheap column — and
// fetch the rows a screenful at a time with items(uids:).
import Foundation
import SQLite3

/// A project as the index knows it (K2): registered folders, the inbox store ("inbox"), and v0.6 workspaces found on
/// disk that aren't registered yet (registered = false).
public struct ProjectRow: Hashable {
    public var id: String, path: String, store: String, name: String, key: String, slug: String
    public var kind: String                      // inbox | folder | repo
    public var registered: Bool
    /// state ∈ Lifecycle.open (MCP list_projects' "open")
    public var openItems = 0
    /// new or to_verify (Lifecycle.inbox): what the user still has to look at
    public var inbox = 0
    public init(id: String, path: String, store: String, name: String, key: String, slug: String, kind: String, registered: Bool = true) {
        self.id = id; self.path = path; self.store = store; self.name = name; self.key = key; self.slug = slug; self.kind = kind
        self.registered = registered
    }
    public var isInbox: Bool { id == "inbox" }
}

public struct SessionRow: Hashable {
    public var id: String, projectID: String, dir: String, mode: String    // mode: video | shots | voice
    public var title: String?, created: Double?, itemCount: Int, processed: Bool, processing: Bool, reviewed: Bool
    public var duration: Double? = nil, shotCount = 0, cardCount = 0, author: String? = nil, projectName: String? = nil
    public var legacy = false
    public init(id: String, projectID: String, dir: String, mode: String, title: String? = nil, created: Double? = nil,
                itemCount: Int = 0, processed: Bool = false, processing: Bool = false, reviewed: Bool = false) {
        self.id = id; self.projectID = projectID; self.dir = dir; self.mode = mode; self.title = title; self.created = created
        self.itemCount = itemCount; self.processed = processed; self.processing = processing; self.reviewed = reviewed
    }
    /// unprocessed | processing | unreviewed | reviewed
    public var state: String { processing ? "processing" : !processed ? "unprocessed" : reviewed ? "reviewed" : "unreviewed" }
    public var url: URL { URL(fileURLWithPath: dir) }
}

/// ItemRow v3 (K1, K3), plus the few columns the native list shows.
public struct ItemRow: Hashable {
    public var uid: String, projectID: String, projectName: String, projectKey: String
    public var sessionID: String?, sessionDir: String?, path: String, itemID: String, kind: String, title: String
    /// K3's one state (Lifecycle.states)
    public var state: String, workTo: String? = nil, workAgent: String? = nil, workJob: String? = nil
    public var severity: String? = nil, primaryFrame: String? = nil, created: Double, updated: Double, snippet: String? = nil
    public var suggestedProject: String? = nil, suggestedConfidence: Double? = nil
    public var quote = "", frameCount = 0, hasCodeRefs = false, tStart: Double? = nil, sourceType: String? = nil
    public var sessionTitle: String? = nil, parseError: String? = nil

    public init(uid: String, projectID: String = "inbox", projectName: String = "", projectKey: String = "", sessionID: String? = nil,
                sessionDir: String? = nil, path: String = "", itemID: String, kind: String, title: String, state: String = "new",
                created: Double = 0, updated: Double = 0) {
        self.uid = uid; self.projectID = projectID; self.projectName = projectName; self.projectKey = projectKey
        self.sessionID = sessionID; self.sessionDir = sessionDir; self.path = path; self.itemID = itemID; self.kind = kind
        self.title = title; self.state = state; self.created = created; self.updated = updated
    }
    public var sessionURL: URL? { sessionDir.map { URL(fileURLWithPath: $0) } }
    /// The item's .md (a legacy row's items.json)
    public var fileURL: URL { URL(fileURLWithPath: path.components(separatedBy: "#").first ?? path) }
    /// A v1/v2 session that hasn't been migrated yet ("<items.json>#<id>"): shown, not editable.
    public var legacy: Bool { path.contains("#") }
    /// Needs you (K3): new, or an agent says it's finished.
    public var needsYou: Bool { Lifecycle.inbox.contains(state) }
    public var discarded: Bool { state == "discarded" }
}

public struct SessionQuery {
    /// unprocessed | processing | unreviewed | reviewed | inbox (= not processed yet, or processed and not reviewed)
    public var project: String?, state: String?
    public var limit = 200, offset = 0
    public init(project: String? = nil, state: String? = nil, limit: Int = 200, offset: Int = 0) {
        self.project = project; self.state = state; self.limit = limit; self.offset = offset
    }
}

public struct ItemQuery: Equatable {
    public var text: String?                          // ≥ 3 chars: FTS5 trigram; 1–2: LIKE; nil/empty: filters only
    /// K3 states; empty = every state but discarded
    public var kinds: [String] = [], states: [String] = []
    /// The old vocabulary, kept for callers that still speak it (Lifecycle.states(fromStatus:) / (fromWork:)); each
    /// narrows `states` further.
    public var statuses: [String] = [], workStates: [String] = []
    /// new or to_verify — the inbox ("Needs you"); combines with the other filters
    public var inbox = false
    public var project: String?, session: String?
    public var sort = "updated"                       // updated | created | t_start | title | kind | state | project | id
    public var ascending = false
    /// Unassigned: items with the same suggested project next to each other (by that project's name), the ones with no
    /// suggestion last — then `sort` within each run.
    public var bySuggestion = false
    public var limit = 50, offset = 0                 // limit 0 = no limit (uids)
    public init(text: String? = nil, kinds: [String] = [], states: [String] = [], statuses: [String] = [], workStates: [String] = [],
                inbox: Bool = false, project: String? = nil, session: String? = nil, sort: String = "updated", limit: Int = 50,
                offset: Int = 0) {
        self.text = text; self.kinds = kinds; self.states = states; self.statuses = statuses; self.workStates = workStates
        self.inbox = inbox; self.project = project; self.session = session; self.sort = sort; self.limit = limit; self.offset = offset
    }
    /// The states this query allows, in lifecycle order; nil = every state but discarded.
    public var allowedStates: [String]? {
        var allowed: Set<String>?
        func narrow(_ s: [String]) { allowed = allowed.map { $0.intersection(s) } ?? Set(s) }
        if !states.isEmpty { narrow(states) }
        if !statuses.isEmpty { narrow(statuses.flatMap(Lifecycle.states(fromStatus:))) }
        if !workStates.isEmpty { narrow(workStates.flatMap(Lifecycle.states(fromWork:))) }
        if inbox { narrow(Array(Lifecycle.inbox)) }
        return allowed.map { a in Lifecycle.states.filter(a.contains) }
    }
    public var terms: [String] { (text ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init) }
    /// Terms shaped like an item's id ("AW-11", "ba-3": a project key, a dash, a number): they find that item first,
    /// as well as the text that mentions them (index.py's search does the same).
    public var idTerms: [String] { terms.filter(Self.isItemID).map { $0.uppercased() } }
    public static func isItemID(_ t: String) -> Bool {
        let parts = t.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let k = parts[0].first, k.isASCII, k.isLetter, !parts[1].isEmpty else { return false }
        return parts[0].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } && parts[1].allSatisfy { $0.isASCII && $0.isNumber }
    }
}

/// Sidebar and menu-bar badges, one query, by K3's groups.
public struct IndexCounts: Equatable {
    /// all = live (not discarded) items; inbox = new + to_verify ("Needs you"); active = handed_off + in_progress +
    /// to_verify (the In Progress place); open = new … in_progress; unassigned = live items in the inbox store
    public var all = 0, inbox = 0, new = 0, toVerify = 0, active = 0, open = 0, unassigned = 0, done = 0, wontfix = 0, discarded = 0
    public init() {}
}

public enum IndexError: Error, CustomStringConvertible {
    case open(String), query(String), missing(URL), schema(String)
    public var description: String {
        switch self {
        case .open(let s): return "index.db: \(s)"
        case .query(let s): return "index.db query: \(s)"
        case .missing(let u): return "no index at \(u.path)"
        case .schema(let v): return "index.db schema \(v), expected \(IndexReader.schemaVersion)"
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class IndexReader {
    public static let schemaVersion = "3"
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
        } catch IndexError.schema(let v) {
            throw IndexError.schema(v)
        } catch {
            sqlite3_close(db)
            db = nil
            try connect(url.path, SQLITE_OPEN_READWRITE)
            try each("PRAGMA query_only = 1", []) { _ in }
        }
    }

    private func connect(_ path: String, _ mode: Int32) throws {
        let rc = sqlite3_open_v2(path, &db, mode | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, db != nil else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "rc \(rc)"
            throw IndexError.open(msg)
        }
        sqlite3_busy_timeout(db, 2000)
        // an older schema (index.py rebuilds it on its next run), or the -shm problem above, fails here
        var v = ""
        try each("SELECT value FROM meta WHERE key = 'schema_version'", []) { v = $0.text(0) }
        guard v == Self.schemaVersion else { throw IndexError.schema(v.isEmpty ? "?" : v) }
    }

    deinit { sqlite3_close(db) }

    // MARK: public queries

    /// Changes whenever another connection (index.py) commits: poll it to know when to reload.
    public var dataVersion: Int { (try? scalarInt("PRAGMA data_version")) ?? 0 }

    /// Every project the index knows (registered ones, unregistered old workspaces, the inbox) with its counts.
    public func projects() throws -> [ProjectRow] {
        try rows("""
            SELECT p.id, p.path, p.store, p.name, p.key, p.slug, p.kind, p.registered,
                   (SELECT COUNT(*) FROM items i WHERE i.project_id = p.id AND i.state IN \(Self.sqlList(Lifecycle.open))),
                   (SELECT COUNT(*) FROM items i WHERE i.project_id = p.id AND i.state IN \(Self.sqlList(Lifecycle.inbox)))
            FROM projects p ORDER BY p.kind = 'inbox' DESC, p.last_seen DESC, p.name
            """, []) { s in
            var r = ProjectRow(id: s.text(0), path: s.text(1), store: s.text(2), name: s.text(3), key: s.text(4), slug: s.text(5),
                               kind: s.text(6), registered: s.int(7) != 0)
            r.openItems = s.int(8); r.inbox = s.int(9)
            return r
        }
    }

    static let sessionCols = """
        s.id, s.project_id, s.dir, s.mode, s.title, s.created, s.item_count, s.processed, s.processing, s.reviewed, \
        s.duration, s.shot_count, s.card_count, s.author, p.name, s.legacy
        """

    public func sessions(_ q: SessionQuery) throws -> [SessionRow] {
        var wh: [String] = [], args: [Any] = []
        if let p = q.project { wh.append("s.project_id = ?"); args.append(p) }
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
        return try rows("SELECT \(Self.sessionCols) FROM sessions s JOIN projects p ON p.id = s.project_id \(whereSQL) " +
                        "ORDER BY s.created DESC, s.id LIMIT ? OFFSET ?", args, Self.sessionRow)
    }

    static func sessionRow(_ s: Stmt) -> SessionRow {
        var r = SessionRow(id: s.text(0), projectID: s.text(1), dir: s.text(2), mode: s.text(3), title: s.optText(4),
                           created: s.optDouble(5), itemCount: s.int(6), processed: s.int(7) != 0,
                           processing: s.int(8) != 0, reviewed: s.int(9) != 0)
        r.duration = s.optDouble(10); r.shotCount = s.int(11); r.cardCount = s.int(12); r.author = s.optText(13)
        r.projectName = s.optText(14); r.legacy = s.int(15) != 0
        return r
    }

    public func session(id: String) throws -> SessionRow? {
        try rows("SELECT \(Self.sessionCols) FROM sessions s JOIN projects p ON p.id = s.project_id WHERE s.id = ?", [id], Self.sessionRow).first
    }

    /// The session row of a directory (index.py stores resolved absolute paths).
    public func session(dir: String) throws -> SessionRow? {
        try rows("SELECT \(Self.sessionCols) FROM sessions s JOIN projects p ON p.id = s.project_id WHERE s.dir = ?", [dir], Self.sessionRow).first
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
            for r in try rows("SELECT \(Self.cols), NULL \(Self.from) WHERE i.uid IN (\(marks))", chunk, Self.itemRow) {
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
            SELECT SUM(state != 'discarded'), SUM(state IN \(Self.sqlList(Lifecycle.inbox))), SUM(state = 'new'),
                   SUM(state = 'to_verify'), SUM(state IN \(Self.sqlList(Lifecycle.active))), SUM(state IN \(Self.sqlList(Lifecycle.open))),
                   SUM(project_id = 'inbox' AND state != 'discarded'), SUM(state = 'done'), SUM(state = 'wontfix'),
                   SUM(state = 'discarded')
            FROM items
            """, []) { s in
            c.all = s.int(0); c.inbox = s.int(1); c.new = s.int(2); c.toVerify = s.int(3); c.active = s.int(4); c.open = s.int(5)
            c.unassigned = s.int(6); c.done = s.int(7); c.wontfix = s.int(8); c.discarded = s.int(9)
        }
        return c
    }

    /// meta.last_full_scan (epoch seconds), nil before the first scan.
    public func lastFullScan() -> Double? {
        var v: Double?
        try? each("SELECT value FROM meta WHERE key = 'last_full_scan'", []) { v = Double($0.text(0)) }
        return v
    }

    // MARK: SQL building (index.py search)

    static let from = "FROM items i JOIN projects p ON p.id = i.project_id LEFT JOIN sessions s ON s.id = i.session_id"

    static let cols = """
        i.uid, i.project_id, p.name, p.key, i.session_id, s.dir, i.path, i.item_id, i.kind, i.title, i.state, \
        i.work_to, i.work_agent, i.work_job, i.severity, i.primary_frame, i.created, i.updated, \
        i.suggested_project, i.suggested_confidence, i.quote, i.frame_count, i.has_code_refs, i.t_start, i.source_type, \
        s.title, i.parse_error
        """

    static func itemRow(_ s: Stmt) -> ItemRow {
        let st = s.text(10)
        var r = ItemRow(uid: s.text(0), projectID: s.text(1), projectName: s.text(2), projectKey: s.text(3), sessionID: s.optText(4),
                        sessionDir: s.optText(5), path: s.text(6), itemID: s.text(7), kind: s.text(8), title: s.text(9),
                        state: Lifecycle.isState(st) ? st : "new", created: s.double(16), updated: s.double(17))
        r.workTo = s.optText(11); r.workAgent = s.optText(12); r.workJob = s.optText(13); r.severity = s.optText(14)
        r.primaryFrame = s.optText(15); r.suggestedProject = s.optText(18); r.suggestedConfidence = s.optDouble(19)
        r.quote = s.text(20); r.frameCount = s.int(21); r.hasCodeRefs = s.int(22) != 0; r.tStart = s.optDouble(23)
        r.sourceType = s.optText(24); r.sessionTitle = s.optText(25); r.parseError = s.optText(26)
        r.snippet = s.optText(27)
        return r
    }

    static func like(_ t: String) -> String {
        "%" + t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
    }

    /// "FROM … WHERE …", its arguments, and whether it joins items_fts.
    func whereClause(_ q: ItemQuery) -> (String, [Any], Bool) {
        let terms = q.terms.filter { !ItemQuery.isItemID($0) }
        let fts = terms.filter { $0.count >= 3 }, short = terms.filter { $0.count < 3 }
        var wh: [String] = [], args: [Any] = []
        func phrase(_ t: String) -> String { "\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        if !fts.isEmpty {
            wh.append("items_fts MATCH ?")
            args.append(fts.map(phrase).joined(separator: " AND "))
        }
        // an id: that item (its id now, or an old one in its text), or the text that mentions it
        for t in q.idTerms {
            wh.append("(upper(i.item_id) = ? OR i.rowid IN (SELECT rowid FROM items_fts WHERE items_fts MATCH ?))")
            args += [t, phrase(t)]
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
        if let st = q.allowedStates {
            if st.isEmpty { wh.append("0") } else { list("i.state", st) }
        } else {
            wh.append("i.state != 'discarded'")
        }
        if !q.kinds.isEmpty { list("i.kind", q.kinds) }
        if let p = q.project { wh.append("i.project_id = ?"); args.append(p) }
        if let s = q.session { wh.append("i.session_id = ?"); args.append(s) }
        let join = fts.isEmpty ? "" : "JOIN items_fts f ON f.rowid = i.rowid "
        return ("FROM items i \(join)JOIN projects p ON p.id = i.project_id LEFT JOIN sessions s ON s.id = i.session_id " +
                "WHERE \(wh.joined(separator: " AND "))", args, !fts.isEmpty)
    }

    /// States in lifecycle order (new … discarded).
    static let stateOrder = "CASE i.state " + Lifecycle.states.enumerated().map { "WHEN '\($0.element)' THEN \($0.offset) " }.joined() +
        "ELSE \(Lifecycle.states.count) END"

    /// "('a', 'b')" for a fixed set of known words (never user input).
    static func sqlList<S: Sequence>(_ v: S) -> String where S.Element == String {
        "(" + v.sorted().map { "'\($0)'" }.joined(separator: ", ") + ")"
    }

    func order(_ q: ItemQuery) -> String {
        // the item whose id was typed comes first (ids are [A-Z0-9-] only: safe as literals)
        let first = q.idTerms.map { "CASE WHEN upper(i.item_id) = '\($0)' THEN 0 ELSE 1 END, " }.joined()
        let groups = q.bySuggestion
            ? "(i.suggested_project IS NULL), (SELECT sp.name FROM projects sp WHERE sp.id = i.suggested_project) COLLATE NOCASE, i.suggested_project, "
            : ""
        return first + groups + sortOrder(q)
    }

    /// Live items of a store (`project`, "inbox" for Unassigned) that carry a suggested project: (uid, project id),
    /// newest first — what the list's "Looks like X · Move All" groups are made of.
    public func suggestions(in project: String = "inbox") throws -> [(uid: String, project: String)] {
        try rows("""
            SELECT i.uid, i.suggested_project FROM items i
            WHERE i.project_id = ? AND i.state != 'discarded' AND i.suggested_project IS NOT NULL AND i.suggested_project != ''
            ORDER BY i.updated DESC, i.item_id
            """, [project]) { (uid: $0.text(0), project: $0.text(1)) }
    }

    private func sortOrder(_ q: ItemQuery) -> String {
        let dir = q.ascending ? "ASC" : "DESC"
        switch q.sort {
        case "created": return "i.created \(dir), i.t_start, i.item_id"
        case "t_start": return "i.t_start, i.created DESC, i.item_id"
        case "title": return "i.title COLLATE NOCASE \(dir), i.updated DESC, i.item_id"
        case "kind": return "i.kind \(dir), i.updated DESC, i.item_id"
        case "state", "status", "work": return "\(Self.stateOrder) \(dir), i.updated DESC, i.item_id"
        case "project": return "p.name COLLATE NOCASE \(dir), i.updated DESC, i.item_id"
        case "id": return "p.key \(dir), CAST(substr(i.item_id, instr(i.item_id, '-') + 1) AS INTEGER) \(dir), i.item_id"
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
