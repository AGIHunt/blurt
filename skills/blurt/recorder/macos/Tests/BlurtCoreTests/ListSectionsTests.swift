// The Inbox grouped by project (IndexReader byProject + ListSections): Unassigned first, then the projects by name,
// newest first inside each; the runs the list draws a header above.
import Foundation
import SQLite3
import XCTest
@testable import BlurtCore

final class ListSectionsTests: XCTestCase {
    func testRunsCutTheOrderWhereTheProjectChanges() {
        XCTAssertEqual(ListSections.runs([]), [])
        XCTAssertEqual(ListSections.runs(["inbox", "inbox", "pa", "pz", "pz"]),
                       [ListSection(start: 0, count: 2, project: "inbox"), ListSection(start: 2, count: 1, project: "pa"),
                        ListSection(start: 3, count: 2, project: "pz")])
        // an id typed into the search comes first, wherever its project sorts: a run of its own
        XCTAssertEqual(ListSections.runs(["pz", "inbox", "pz"]).map(\.project), ["pz", "inbox", "pz"])
        XCTAssertEqual(ListSections.starts(ListSections.runs(["a", "a", "b"])).keys.sorted(), [0, 2])
    }

    func testGroupedBucketsByRankKeepingEachBucketsOrder() {
        let rows = [(uid: "1", key: "new"), (uid: "2", key: "to_verify"), (uid: "3", key: "new"), (uid: "4", key: "done"),
                    (uid: "5", key: "to_verify")]
        let g = ListSections.grouped(rows, rank: ListSections.stateRank)
        XCTAssertEqual(g.uids, ["2", "5", "1", "3", "4"])         // to verify first, then new, then done
        XCTAssertEqual(g.keys, ["to_verify", "to_verify", "new", "new", "done"])
        // projects in the one order (pinned, then recent), Unassigned last, one unknown after the known ones
        let p = ListSections.grouped([(uid: "a", key: "inbox"), (uid: "b", key: "pz"), (uid: "c", key: "pa"), (uid: "d", key: "px")],
                                     rank: ListSections.projectRank(["pa", "pz"]))
        XCTAssertEqual(p.keys, ["pa", "pz", "px", "inbox"])
    }

    func testInboxByProjectPutsUnassignedFirstThenNamesThenNewest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-sections-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        IndexReaderTests.exec(db, IndexReaderTests.ddl)
        IndexReaderTests.exec(db, "INSERT INTO meta(key, value) VALUES ('schema_version', '3') ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        for (id, name, key) in [("inbox", "Unassigned", "IN"), ("pz", "Zeta", "ZE"), ("pa", "alpha", "AL")] {
            IndexReaderTests.exec(db, "INSERT INTO projects VALUES ('\(id)', '/w/\(id)', '/w/\(id)/.blurt', '\(name)', '\(key)', '\(id)', '\(id == "inbox" ? "inbox" : "repo")', 1, 0)")
        }
        // (uid, store, state, updated)
        let items: [(String, String, String, Int)] = [
            ("a", "pz", "new", 90), ("b", "inbox", "new", 10), ("c", "pa", "to_verify", 20), ("d", "inbox", "new", 40),
            ("e", "pa", "new", 60), ("f", "pa", "done", 99)]
        for (k, it) in items.enumerated() {
            IndexReaderTests.exec(db, """
                INSERT INTO items(uid, project_id, path, item_id, kind, title, state, created, updated)
                VALUES ('\(it.0)', '\(it.1)', '/w/\(it.0).md', 'X-\(k)', 'issue', 't\(it.0)', '\(it.2)', \(it.3), \(it.3))
                """)
        }
        sqlite3_close(db)
        let r = try IndexReader(url: url)
        var q = ItemQuery(inbox: true, limit: 0)
        XCTAssertEqual(try r.uids(q), ["a", "e", "d", "c", "b"])          // newest first, projects mixed
        q.byProject = true
        XCTAssertEqual(try r.uids(q), ["d", "b", "e", "c", "a"])          // Unassigned, alpha, Zeta; newest first in each
        let rows = try r.uidProjects(q)
        XCTAssertEqual(rows.map(\.uid), try r.uids(q))
        XCTAssertEqual(ListSections.runs(rows.map(\.project)).map { "\($0.project)×\($0.count)" }, ["inbox×2", "pa×2", "pz×1"])
    }
}

/// The list's date column: one short token (Mail's), never a relative phrase repeated on every row.
final class ListDateTests: XCTestCase {
    override func tearDown() { Loc.setting = nil }

    func testTodayIsTheTimeThenYesterdayWeekdayMonthDayAndAShortDate() {
        Loc.setting = "en"
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
        let now = at("2026-10-26T15:00:00Z")      // a Monday
        let today = Loc.listDate(at("2026-10-26T09:05:00Z"), now: now, calendar: cal)
        XCTAssertTrue(today.contains("9") && today.contains("05"), today)
        XCTAssertEqual(Loc.listDate(at("2026-10-25T23:00:00Z"), now: now, calendar: cal), "Yesterday")
        XCTAssertEqual(Loc.listDate(at("2026-10-22T10:00:00Z"), now: now, calendar: cal), "Thu")
        XCTAssertEqual(Loc.listDate(at("2026-09-03T10:00:00Z"), now: now, calendar: cal), "Sep 3")
        XCTAssertFalse(Loc.listDate(at("2025-09-03T10:00:00Z"), now: now, calendar: cal).contains("Sep"))
        Loc.setting = "zh-Hans"
        XCTAssertEqual(Loc.listDate(at("2026-10-25T23:00:00Z"), now: now, calendar: cal), "昨天")
        XCTAssertEqual(Loc.listDate(at("2026-09-03T10:00:00Z"), now: now, calendar: cal), "9月3日")
    }
}
