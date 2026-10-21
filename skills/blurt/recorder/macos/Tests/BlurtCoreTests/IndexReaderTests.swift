// IndexReader against an index.db built from the C3 DDL (docs/contracts/index-schema.sql) with 20k synthetic items.
// WP5 acceptance: filter + reload ≤ 100 ms, search ≤ 150 ms on 20k rows. "reload" = what the main window does on a
// filter change: the ordered uids of every match + the first screenful of rows + the sidebar counts.
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

    static var schemaURL: URL {
        // Tests/BlurtCoreTests/<this file> → repo root is 6 levels up (skills/blurt/recorder/macos/Tests/BlurtCoreTests)
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("docs/contracts/index-schema.sql")
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
        let ddl = (try? String(contentsOf: schemaURL, encoding: .utf8)) ?? ""
        XCTAssertFalse(ddl.isEmpty, "schema at \(schemaURL.path)")
        exec(db, ddl)
        exec(db, "BEGIN")
        let wss = ["default", "my-saas", "landing", "ios"]
        for (k, w) in wss.enumerated() {
            exec(db, "INSERT INTO workspaces VALUES ('w\(k)', '/tmp/ws/\(w)', '\(w)', '\(k == 0 ? "default" : "repo")', \(k))")
        }
        let perSession = 50, sessions = items / perSession
        for s in 0..<sessions {
            let st = s % 9 == 0 ? (0, 0, 0) : s % 5 == 0 ? (1, 0, 0) : (1, 0, 1)
            exec(db, """
                INSERT INTO sessions(id, workspace_id, dir, mode, title, created, item_count, processed, processing, reviewed, indexed_at)
                VALUES ('w\(s % 4):s\(s)', 'w\(s % 4)', '/tmp/ws/s\(s)', '\(s % 7 == 3 ? "shots" : "video")', 'session \(s)',
                        \(1_790_000_000 + s * 3600), \(perSession), \(st.0), \(st.1), \(st.2), 0)
                """)
        }
        var ins: OpaquePointer?
        sqlite3_prepare_v2(db, """
            INSERT INTO items(uid, session_id, item_id, kind, title, quote, body, tags, status, fix_state, severity, t_start,
                              primary_frame, frame_count, updated) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,1,?)
            """, -1, &ins, nil)
        let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var rng = UInt64(7)
        func next(_ m: Int) -> Int { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Int((rng >> 33) % UInt64(m)) }
        let kinds = ["issue", "issue", "issue", "idea", "note", "task"]
        let fixes: [String?] = [nil, nil, nil, nil, nil, "fixing", "fixed", "fixed", "wontfix", "reopened"]
        for i in 0..<items {
            let s = i / perSession
            let title = titles[next(titles.count)] + " \(i)"
            let vals: [String?] = [String(format: "U%025d", i), "w\(s % 4):s\(s)", String(format: "I-%03d", i % perSession + 1),
                                   kinds[next(kinds.count)], title, "这里\(title)，你看一下。", "实际：\(title)\n期望：正常",
                                   "ui", ["draft", "confirmed", "confirmed", "deleted"][next(4) == 3 && next(5) == 0 ? 3 : next(3)],
                                   fixes[next(fixes.count)], ["high", "medium", "low"][next(3)]]
            for (k, v) in vals.enumerated() {
                if let v = v { sqlite3_bind_text(ins, Int32(k + 1), v, -1, T) } else { sqlite3_bind_null(ins, Int32(k + 1)) }
            }
            sqlite3_bind_double(ins, 12, Double(i % perSession) * 3)
            sqlite3_bind_text(ins, 13, "/tmp/ws/s\(s)/frames/I-001-1.jpg", -1, T)
            sqlite3_bind_double(ins, 14, 1_790_000_000 + Double(i) * 37)
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
        return uids.count
    }

    func testCountsAndRows() throws {
        let r = try IndexReader(url: Self.dbURL)
        let all = try r.count(ItemQuery())
        XCTAssertGreaterThan(all, 15_000)
        XCTAssertEqual(try r.uids(ItemQuery(limit: 0)).count, all)
        XCTAssertEqual(try r.counts().all, all)
        let first = try r.items(ItemQuery(limit: 5))
        XCTAssertEqual(first.count, 5)
        XCTAssertGreaterThanOrEqual(first[0].updated, first[4].updated)
        XCTAssertEqual(first[0].workspaceName != nil, true)
        let byUID = try r.items(uids: first.map(\.uid).reversed())
        XCTAssertEqual(byUID.map(\.uid), first.map(\.uid).reversed())
        XCTAssertEqual(try r.workspaces().count, 4)
        XCTAssertFalse(try r.sessions(SessionQuery(state: "inbox", limit: 0)).isEmpty)
        XCTAssertTrue(try r.sessions(SessionQuery(state: "inbox", limit: 0)).allSatisfy { $0.state != "reviewed" })
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
        // filters
        XCTAssertTrue(try r.items(ItemQuery(kinds: ["idea"], limit: 50)).allSatisfy { $0.kind == "idea" })
        XCTAssertTrue(try r.items(ItemQuery(fixStates: ["none"], limit: 50)).allSatisfy { $0.fixState == nil })
        XCTAssertTrue(try r.items(ItemQuery(limit: 500)).allSatisfy { $0.status != "deleted" })
        XCTAssertTrue(try r.items(ItemQuery(statuses: ["deleted"], limit: 50)).allSatisfy { $0.status == "deleted" })
    }

    func testPerformanceFilterReload() throws {
        let r = try IndexReader(url: Self.dbURL)
        let qs = [ItemQuery(), ItemQuery(kinds: ["issue"]), ItemQuery(kinds: ["issue"], fixStates: ["none", "fixing", "reopened"]),
                  ItemQuery(statuses: ["draft"]), ItemQuery(workspace: "w2"), ItemQuery(sort: "title")]
        for q in qs {
            var count = 0
            let ms = try time { count = try reload(r, q) }
            print(String(format: "PERF filter+reload %-60@ %6d rows %6.1f ms", "\(q.kinds)\(q.fixStates)\(q.statuses)\(q.workspace ?? "")\(q.sort)", count, ms))
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
