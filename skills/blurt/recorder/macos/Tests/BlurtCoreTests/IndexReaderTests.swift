// IndexReader against an index.db with schema v3 (docs/design/next-round.md K1 "index.db", K3's `state`) and 20k synthetic
// items. P4 acceptance: filter + reload ≤ 100 ms, search ≤ 150 ms on 20k rows. "reload" = what the main window does
// on a filter change: the ordered uids of every match + the first screenful of rows + the sidebar counts.
// The DDL is docs/contracts/index-schema.sql when that file is v3 (P1 writes it), else the contract's own copy below.
// Run: swift test (needs Xcode's XCTest; the Command Line Tools alone can build the app but not run this).
import Foundation
import SQLite3
import XCTest
@testable import BlurtCore

final class IndexReaderTests: XCTestCase {
    static var dbURL: URL!
    static let n = 20_000

    override class func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-index-tests-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("index.db")
        try? FileManager.default.removeItem(at: dbURL)
        let t0 = Date()
        build(dbURL, items: n)
        print("built \(n) items in \(Int(Date().timeIntervalSince(t0) * 1000)) ms → \(dbURL.path)")
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
        super.tearDown()
    }

    /// K1's DDL (the parts the reader uses), for when the contract file isn't v3 yet.
    static let contractDDL = """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE projects (id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, store TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
          key TEXT NOT NULL, slug TEXT NOT NULL, kind TEXT NOT NULL CHECK (kind IN ('inbox', 'folder', 'repo')),
          registered INTEGER NOT NULL DEFAULT 1, last_seen REAL);
        CREATE TABLE sessions (id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
          dir TEXT NOT NULL UNIQUE, mode TEXT NOT NULL CHECK (mode IN ('video', 'shots', 'voice')), title TEXT, author TEXT,
          created REAL, duration REAL, shot_count INTEGER NOT NULL DEFAULT 0, card_count INTEGER NOT NULL DEFAULT 0,
          item_count INTEGER NOT NULL DEFAULT 0, processed INTEGER NOT NULL DEFAULT 0, processing INTEGER NOT NULL DEFAULT 0,
          reviewed INTEGER NOT NULL DEFAULT 0, legacy INTEGER NOT NULL DEFAULT 0, items_mtime REAL, shots_mtime REAL,
          indexed_at REAL NOT NULL);
        CREATE TABLE items (uid TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
          session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL, path TEXT NOT NULL UNIQUE, item_id TEXT NOT NULL,
          kind TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', quote TEXT NOT NULL DEFAULT '', body TEXT NOT NULL DEFAULT '',
          tags TEXT NOT NULL DEFAULT '', state TEXT NOT NULL, work_to TEXT,
          work_agent TEXT, work_job TEXT, work_claim TEXT, severity TEXT, owner TEXT, module TEXT, assignee TEXT, confidence TEXT,
          source_type TEXT, source_by TEXT, source_app TEXT, source_url TEXT, project_by TEXT, project_confidence REAL,
          suggested_project TEXT, suggested_confidence REAL, t_start REAL, primary_frame TEXT,
          frame_count INTEGER NOT NULL DEFAULT 0, has_code_refs INTEGER NOT NULL DEFAULT 0, exported TEXT NOT NULL DEFAULT '{}',
          user_edited INTEGER NOT NULL DEFAULT 0, parse_error TEXT, created REAL NOT NULL, updated REAL NOT NULL, mtime REAL,
          UNIQUE (project_id, item_id));
        CREATE INDEX items_updated ON items(updated DESC);
        CREATE INDEX items_proj ON items(project_id, state);
        CREATE VIRTUAL TABLE items_fts USING fts5(title, quote, body, tags, content='items', content_rowid='rowid', tokenize='trigram');
        CREATE TRIGGER items_ai AFTER INSERT ON items BEGIN
          INSERT INTO items_fts(rowid, title, quote, body, tags) VALUES (new.rowid, new.title, new.quote, new.body, new.tags); END;
        """

    static var ddl: String {
        // Tests/BlurtCoreTests/<this file> → repo root is 7 levels up
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { u.deleteLastPathComponent() }
        let file = (try? String(contentsOf: u.appendingPathComponent("docs/contracts/index-schema.sql"), encoding: .utf8)) ?? ""
        return !file.contains("work_state") && file.contains("CREATE TABLE projects") ? file : contractDDL
    }

    static func exec(_ db: OpaquePointer?, _ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            XCTFail("sql: \(err.map { String(cString: $0) } ?? "?")")
        }
    }

    static let titles = ["登录按钮点击无响应", "价格页在移动端溢出", "头像上传返回 500", "保存后 toast 叠加三个", "暗色模式下表格边框看不见",
                         "Checkout button stays disabled", "Search results flicker", "侧栏折叠后图标错位", "Onboarding skips a step",
                         "通知设置不生效", "Dropdown clipped by the modal", "导出 CSV 中文乱码", "空状态学 Linear 的做法",
                         "Command palette for every action", "给图表加对比上周"]

    static func build(_ url: URL, items: Int) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        exec(db, ddl)
        exec(db, "INSERT INTO meta(key, value) VALUES ('schema_version', '3') ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        exec(db, "BEGIN")
        let projects = [("inbox", "IN", "inbox"), ("p1", "MS", "repo"), ("p2", "LP", "repo"), ("p3", "IOS", "folder")]
        for (k, p) in projects.enumerated() {
            exec(db, "INSERT INTO projects VALUES ('\(p.0)', '/tmp/ws/\(p.0)', '/tmp/ws/\(p.0)/.blurt', '\(p.0)', '\(p.1)', '\(p.0)', '\(p.2)', 1, \(k))")
        }
        let perSession = 50, sessions = items / perSession
        for s in 0..<sessions {
            let p = projects[s % 4].0
            exec(db, """
                INSERT INTO sessions(id, project_id, dir, mode, title, created, item_count, processed, processing, reviewed, indexed_at)
                VALUES ('\(p):s\(s)', '\(p)', '/tmp/ws/\(p)/.blurt/sessions/s\(s)', '\(s % 7 == 3 ? "shots" : "video")', 'session \(s)',
                        \(1_790_000_000 + s * 3600), \(perSession), 1, 0, \(s % 3 == 0 ? 1 : 0), 0)
                """)
        }
        var ins: OpaquePointer?
        sqlite3_prepare_v2(db, """
            INSERT INTO items(uid, project_id, session_id, path, item_id, kind, title, quote, body, tags, state, severity,
                              t_start, primary_frame, frame_count, created, updated) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,1,?,?)
            """, -1, &ins, nil)
        let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var rng = UInt64(7)
        func next(_ m: Int) -> Int { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Int((rng >> 33) % UInt64(m)) }
        let kinds = ["issue", "issue", "issue", "idea", "note", "task"]
        let states = ["new", "new", "new", "todo", "todo", "todo", "handed_off", "in_progress", "to_verify", "done", "done", "wontfix",
                      "discarded"]
        for i in 0..<items {
            let s = i / perSession
            let p = projects[s % 4]
            let title = titles[next(titles.count)] + " \(i)"
            let vals: [String] = [String(format: "U%025d", i), p.0, "\(p.0):s\(s)", "/tmp/ws/\(p.0)/.blurt/items/\(p.1)-\(i).md",
                                  "\(p.1)-\(i + 1)", kinds[next(kinds.count)], title, "这里\(title)，你看一下。", "实际：\(title)\n期望：正常",
                                  "ui", states[next(states.count)], ["high", "medium", "low"][next(3)]]
            for (k, v) in vals.enumerated() { sqlite3_bind_text(ins, Int32(k + 1), v, -1, T) }
            sqlite3_bind_double(ins, 13, Double(i % perSession) * 3)
            sqlite3_bind_text(ins, 14, "/tmp/ws/\(p.0)/.blurt/assets/U\(i)/1.png", -1, T)
            sqlite3_bind_double(ins, 15, 1_790_000_000 + Double(i) * 30)
            sqlite3_bind_double(ins, 16, 1_790_000_000 + Double(i) * 37)
            XCTAssertEqual(sqlite3_step(ins), SQLITE_DONE)
            sqlite3_reset(ins)
        }
        sqlite3_finalize(ins)
        exec(db, "INSERT INTO meta(key, value) VALUES ('last_full_scan', '1790000000') ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        exec(db, "COMMIT")
    }

    /// median of `runs` timings, ms
    func time(_ runs: Int = 9, _ f: () throws -> Void) rethrows -> Double {
        var ts: [Double] = []
        for _ in 0..<runs {
            let t0 = DispatchTime.now().uptimeNanoseconds
            try f()
            ts.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        return ts.sorted()[runs / 2]
    }

    /// What the main window does on every filter / search change.
    func reload(_ r: IndexReader, _ q: ItemQuery) throws -> Int {
        var q = q
        q.limit = 0
        let uids = try r.uids(q)
        _ = try r.items(uids: Array(uids.prefix(80)), terms: q.terms)
        _ = try r.counts()
        _ = try r.projects()
        return uids.count
    }

    func testRefusesAnOlderSchema() throws {
        let u = Self.dbURL.deletingLastPathComponent().appendingPathComponent("v1.db")
        var db: OpaquePointer?
        sqlite3_open(u.path, &db)
        Self.exec(db, "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT); INSERT INTO meta VALUES ('schema_version', '1'); CREATE TABLE items (uid TEXT)")
        sqlite3_close(db)
        XCTAssertThrowsError(try IndexReader(url: u)) { e in
            guard case IndexError.schema("1") = e else { return XCTFail("\(e)") }
        }
    }

    func testCountsAndRows() throws {
        let r = try IndexReader(url: Self.dbURL)
        let all = try r.count(ItemQuery())
        XCTAssertGreaterThan(all, 15_000)
        XCTAssertEqual(try r.uids(ItemQuery(limit: 0)).count, all)
        let c = try r.counts()
        XCTAssertEqual(c.all, all)
        XCTAssertEqual(c.inbox, try r.count(ItemQuery(inbox: true)))
        XCTAssertEqual(c.inbox, c.new + c.toVerify)
        XCTAssertEqual(c.unassigned, try r.count(ItemQuery(project: "inbox")))
        XCTAssertEqual(c.active, try r.count(ItemQuery(states: ["handed_off", "in_progress", "to_verify"])))
        XCTAssertEqual(c.open, try r.count(ItemQuery(states: ["new", "todo", "handed_off", "in_progress"])))
        XCTAssertEqual(c.discarded, try r.count(ItemQuery(states: ["discarded"])))
        XCTAssertGreaterThan(c.discarded, 0)
        let first = try r.items(ItemQuery(limit: 5))
        XCTAssertEqual(first.count, 5)
        XCTAssertGreaterThanOrEqual(first[0].updated, first[4].updated)
        XCTAssertFalse(first[0].projectName.isEmpty)
        XCTAssertFalse(first[0].projectKey.isEmpty)
        XCTAssertNotNil(first[0].sessionDir)
        let byUID = try r.items(uids: first.map(\.uid).reversed())
        XCTAssertEqual(byUID.map(\.uid), first.map(\.uid).reversed())
        let projects = try r.projects()
        XCTAssertEqual(projects.count, 4)
        XCTAssertEqual(projects.first?.id, "inbox")
        XCTAssertGreaterThan(projects.map(\.openItems).reduce(0, +), 0)
        XCTAssertFalse(try r.sessions(SessionQuery(project: "p1", limit: 0)).isEmpty)
        let s = try r.sessions(SessionQuery(limit: 1))[0]
        XCTAssertEqual(try r.session(dir: s.dir)?.id, s.id)
    }

    func testPlacesAndFilters() throws {
        let r = try IndexReader(url: Self.dbURL)
        XCTAssertTrue(try r.items(ItemQuery(inbox: true, limit: 300)).allSatisfy { $0.needsYou && !$0.discarded })
        XCTAssertTrue(try r.items(ItemQuery(states: ["to_verify"], limit: 100)).allSatisfy { $0.state == "to_verify" })
        XCTAssertTrue(try r.items(ItemQuery(project: "p2", limit: 100)).allSatisfy { $0.projectID == "p2" && $0.projectKey == "LP" })
        XCTAssertTrue(try r.items(ItemQuery(kinds: ["idea"], limit: 50)).allSatisfy { $0.kind == "idea" })
        XCTAssertTrue(try r.items(ItemQuery(limit: 500)).allSatisfy { !$0.discarded })
        XCTAssertTrue(try r.items(ItemQuery(states: ["discarded"], limit: 50)).allSatisfy { $0.discarded })
        // the old vocabulary still works (the island's draft count): status draft = new, work todo = new + todo
        XCTAssertEqual(try r.count(ItemQuery(statuses: ["draft"])), try r.count(ItemQuery(states: ["new"])))
        XCTAssertEqual(try r.count(ItemQuery(statuses: ["deleted"])), try r.count(ItemQuery(states: ["discarded"])))
        XCTAssertEqual(try r.count(ItemQuery(workStates: ["todo"])), try r.count(ItemQuery(states: ["new", "todo"])))
        XCTAssertEqual(try r.count(ItemQuery(states: ["done"], inbox: true)), 0)
        // the state sort follows the lifecycle: new first, wontfix last (discarded aren't listed)
        var asc = ItemQuery(sort: "state", limit: 3)
        asc.ascending = true
        XCTAssertTrue(try r.items(asc).allSatisfy { $0.state == "new" })
        XCTAssertTrue(try r.items(ItemQuery(sort: "state", limit: 3)).allSatisfy { $0.state == "wontfix" })
    }

    func testSearchSemantics() throws {
        let r = try IndexReader(url: Self.dbURL)
        // ≥ 3 characters: FTS5 trigram, Chinese without segmentation
        let fts = try r.items(ItemQuery(text: "登录按", limit: 3))
        XCTAssertFalse(fts.isEmpty)
        XCTAssertTrue(fts.allSatisfy { $0.title.contains("登录按") })
        XCTAssertTrue(fts[0].snippet?.contains("[") == true)
        // 1–2 characters: LIKE fallback, host-side snippet
        let short = try r.items(ItemQuery(text: "登录", limit: 3))
        XCTAssertFalse(short.isEmpty)
        XCTAssertTrue(short[0].snippet?.contains("[登录]") == true)
        // terms are ANDed; FTS syntax in the query is plain text
        XCTAssertEqual(try r.count(ItemQuery(text: "登录 侧栏")), 0)
        XCTAssertEqual(try r.count(ItemQuery(text: "\"OR\" NEAR(")), 0)
        XCTAssertEqual(try r.count(ItemQuery(text: "100%")), 0)
    }

    /// The id printed on every row ("AW-11") finds that item, in any case, first (index.py does the same).
    func testSearchByItemID() throws {
        let r = try IndexReader(url: Self.dbURL)
        let some = try XCTUnwrap(r.items(ItemQuery(limit: 20)).last)
        for typed in [some.itemID, some.itemID.lowercased()] {
            let hits = try r.items(ItemQuery(text: typed, limit: 5))
            XCTAssertEqual(hits.first?.uid, some.uid, typed)
            XCTAssertEqual(try r.uids(ItemQuery(text: typed, limit: 0)).first, some.uid, typed)
        }
        XCTAssertEqual(try r.count(ItemQuery(text: "ZZ-424242")), 0)
        XCTAssertTrue(ItemQuery.isItemID("AW-11") && ItemQuery.isItemID("ios-3"))
        XCTAssertFalse(ItemQuery.isItemID("3D-1") || ItemQuery.isItemID("AW-") || ItemQuery.isItemID("UTF-8x") || ItemQuery.isItemID("登录-1"))
    }

    func testPerformanceFilterReload() throws {
        let r = try IndexReader(url: Self.dbURL)
        let qs = [ItemQuery(), ItemQuery(inbox: true), ItemQuery(states: ["handed_off", "in_progress", "to_verify"]),
                  ItemQuery(project: "inbox"), ItemQuery(project: "p2"), ItemQuery(kinds: ["issue"], states: ["new"]),
                  ItemQuery(sort: "title"), ItemQuery(sort: "state")]
        for q in qs {
            var count = 0
            let ms = try time { count = try reload(r, q) }
            print(String(format: "PERF filter+reload %-60@ %6d rows %6.1f ms",
                         "\(q.kinds)\(q.states)\(q.inbox ? "inbox" : "")\(q.project ?? "")\(q.sort)", count, ms))
            XCTAssertLessThanOrEqual(ms, 100, "filter + reload over \(Self.n) rows")
        }
    }

    func testPerformanceSearch() throws {
        let r = try IndexReader(url: Self.dbURL)
        for text in ["登录按", "登录", "button", "a", "toast 叠加", "Checkout button stays", "不存在的词组"] {
            var count = 0
            let ms = try time { count = try reload(r, ItemQuery(text: text)) }
            print(String(format: "PERF search %-24@ %6d rows %6.1f ms", "“\(text)”", count, ms))
            XCTAssertLessThanOrEqual(ms, 150, "search over \(Self.n) rows")
        }
    }
}
