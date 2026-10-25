// Project assignment (BlurtCore Projects/Assignment.swift, Agents/Processing.swift, IndexReader.suggestions): the
// user's pick made cheap — type-to-filter over projects, Unassigned grouped by the organizer's suggestion, the
// candidates only an Unassigned capture's run is told, and the model each kind of organizing run uses.
import Foundation
import SQLite3
import XCTest
@testable import BlurtCore

final class AssignmentTests: XCTestCase {
    struct P { let name, key: String }
    let ps = [P(name: "billing-api", key: "BA"), P(name: "Atlas Web", key: "AW"), P(name: "口喷鸡 iOS 客户端", key: "IOS"),
              P(name: "Café Notes", key: "CN"), P(name: "web-tools", key: "WT")]
    func names(_ q: String) -> [String] { ProjectPick.filter(ps, q, name: \.name, key: \.key).map(\.name) }

    // MARK: type to filter

    func testFilterRanksTheKeyThenPrefixesThenWordsThenAnywhere() {
        XCTAssertEqual(names(""), ps.map(\.name))                                    // nothing typed: all, as given
        XCTAssertEqual(names("aw"), ["Atlas Web"])                                   // the key, exactly
        XCTAssertEqual(names("web"), ["web-tools", "Atlas Web"])                     // name prefix before a later word
        XCTAssertEqual(names("ios"), ["口喷鸡 iOS 客户端"])                               // key and a word, CJK names too
        XCTAssertEqual(names("口喷"), ["口喷鸡 iOS 客户端"])
        XCTAssertEqual(names("cafe"), ["Café Notes"])                                // accents ignored
        XCTAssertEqual(names("i"), ["口喷鸡 iOS 客户端", "billing-api"])                  // a word starting with it, then anywhere
        XCTAssertEqual(names("  BILL "), ["billing-api"])                            // case and spaces around ignored
        XCTAssertEqual(names("zzz"), [])
    }

    // MARK: Unassigned, grouped by suggestion

    func testGroupsFollowTheSidebarAndDropProjectsThatAreGone() {
        let rows = [("u1", "p2"), ("u2", "p1"), ("u3", "p2"), ("u4", "gone"), ("u5", "p2")].map { (uid: $0.0, project: $0.1) }
        let g = Suggestions.groups(rows, known: ["p1", "p2", "p3"])
        XCTAssertEqual(g, [SuggestionGroup(project: "p1", uids: ["u2"]), SuggestionGroup(project: "p2", uids: ["u1", "u3", "u5"])])
        XCTAssertEqual(Suggestions.groups([], known: ["p1"]), [])
    }

    func testIndexListsSuggestionsAndKeepsEachGroupTogether() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-assign-\(getpid())")
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
        // (uid, store, state, suggestion, updated)
        let items: [(String, String, String, String?, Int)] = [
            ("a", "inbox", "new", "pz", 10), ("b", "inbox", "new", nil, 50), ("c", "inbox", "todo", "pa", 20),
            ("d", "inbox", "new", "pz", 40), ("e", "inbox", "discarded", "pa", 60), ("f", "pa", "new", "pz", 70),
            ("g", "inbox", "new", "pa", 30)]
        for (k, it) in items.enumerated() {
            let sug = it.3.map { "'\($0)'" } ?? "NULL"
            IndexReaderTests.exec(db, """
                INSERT INTO items(uid, project_id, path, item_id, kind, title, state, suggested_project, created, updated)
                VALUES ('\(it.0)', '\(it.1)', '/w/\(it.0).md', 'IN-\(k)', 'issue', 't\(it.0)', '\(it.2)', \(sug), \(it.4), \(it.4))
                """)
        }
        sqlite3_close(db)
        let r = try IndexReader(url: url)
        // live Unassigned items with a suggestion, newest first (not the discarded one, not another store's)
        XCTAssertEqual(try r.suggestions().map(\.uid), ["d", "g", "c", "a"])
        XCTAssertEqual(Suggestions.groups(try r.suggestions(), known: ["pa", "pz"]).map(\.uids), [["g", "c"], ["d", "a"]])
        // the list: each suggested project's run together (by its name, alpha before Zeta), newest first inside, the
        // ones with no suggestion last
        var q = ItemQuery(project: "inbox", limit: 0)
        q.bySuggestion = true
        XCTAssertEqual(try r.uids(q), ["g", "c", "d", "a", "b"])
        q.bySuggestion = false
        XCTAssertEqual(try r.uids(q), ["b", "d", "g", "c", "a"])
    }

    // MARK: what the organizer is told

    func testOnlyAnUnassignedCaptureGetsTheCandidates() {
        XCTAssertTrue(OrganizerPrompt.wantsCandidates(runProject: nil, sessionProject: "inbox"))
        XCTAssertTrue(OrganizerPrompt.wantsCandidates(runProject: nil, sessionProject: nil))
        XCTAssertFalse(OrganizerPrompt.wantsCandidates(runProject: "p1", sessionProject: "inbox"))   // "Organize into X"
        XCTAssertFalse(OrganizerPrompt.wantsCandidates(runProject: nil, sessionProject: "p1"))       // recorded into X
        XCTAssertEqual(OrganizerPrompt.with("Do it.", candidates: nil), "Do it.")
        XCTAssertEqual(OrganizerPrompt.with("Do it.", candidates: "  \n"), "Do it.")
        XCTAssertEqual(OrganizerPrompt.with("Do it.", candidates: "Projects:\n- a\n"), "Do it.\n\nProjects:\n- a")
    }

    // MARK: the model per kind of run

    func testRecordingsUseTheCLIModelAndCardsTheCheapest() {
        let shipped: [String: Any] = ["recording": ["model": "default", "effort": "low"], "cards": ["model": "cheapest", "effort": "low"]]
        XCTAssertTrue(ProcessingSpec.wanted(base: shipped, over: nil, kind: .recording) == ("default", "low"))
        XCTAssertTrue(ProcessingSpec.wanted(base: shipped, over: nil, kind: .cards) == ("cheapest", "low"))
        XCTAssertTrue(ProcessingSpec.wanted(base: nil, over: nil, kind: .recording) == ("default", "low"))     // a custom agent
        // v0.8's one {model, effort} stands for both kinds — agents.json's or the user's
        let old: [String: Any] = ["model": "sonnet", "effort": "high"]
        for k in ProcessingKind.allCases { XCTAssertTrue(ProcessingSpec.wanted(base: shipped, over: old, kind: k) == ("sonnet", "high")) }
        let mine: [String: Any] = ["cards": ["model": "haiku"]]
        XCTAssertTrue(ProcessingSpec.wanted(base: shipped, over: mine, kind: .cards) == ("haiku", "low"))
        XCTAssertTrue(ProcessingSpec.wanted(base: shipped, over: mine, kind: .recording) == ("default", "low"))
    }

    func testChangingOneKindKeepsTheOther() {
        // from v0.8's shape: changing cards leaves recordings as the user had them
        let s = ProcessingSpec.setting(["model": "sonnet", "effort": "high"], kind: .cards, model: "haiku", effort: nil)
        XCTAssertEqual(ProcessingSpec.of(s, .recording), ["model": "sonnet", "effort": "high"])
        XCTAssertEqual(ProcessingSpec.of(s, .cards), ["model": "haiku"])
        // back to the defaults: nothing of the user's left
        XCTAssertNil(ProcessingSpec.setting(["cards": ["model": "haiku"]], kind: .cards, model: nil, effort: nil))
        let r = ProcessingSpec.setting(nil, kind: .recording, model: "opus", effort: "medium")
        XCTAssertEqual(r?["recording"] as? [String: String], ["model": "opus", "effort": "medium"])
        XCTAssertNil(r?["cards"])
    }

    func testWhichKindOrganizesASession() {
        let base = URL(fileURLWithPath: "/w/.blurt/sessions")
        XCTAssertEqual(ProcessingSpec.kind(forSession: base.appendingPathComponent("20261025-100000"), isShots: false), .recording)
        XCTAssertEqual(ProcessingSpec.kind(forSession: base.appendingPathComponent("20261025-100000-shots"), isShots: true), .cards)
        XCTAssertEqual(ProcessingSpec.kind(forSession: base.appendingPathComponent("20261025-100000-voice"), isShots: false), .cards)
    }

    // "Filed to X · Change" while the recording is still being organized: the run's end moves items only from the
    // places the recording was filed to before, never from where the user wants it now.
    func testRefileTrailRemembersEarlierPlaces() {
        var t = RefileTrail(to: "atlas")
        t.refiled(to: "inbox", from: "atlas")
        XCTAssertEqual(t.to, "inbox")
        XCTAssertEqual(t.movesFrom, ["atlas"])
        t.refiled(to: "ios", from: "inbox")
        XCTAssertEqual(t.to, "ios")
        XCTAssertEqual(t.movesFrom, ["atlas", "inbox"])
    }

    func testRefileTrailUndoneLeavesNothingToMove() {
        var t = RefileTrail(to: "atlas")
        t.refiled(to: "ios", from: "atlas")
        t.refiled(to: "atlas", from: "ios")   // Undo
        XCTAssertEqual(t.to, "atlas")
        XCTAssertEqual(t.movesFrom, ["ios"])  // the run may have written them to iOS in between
        var u = RefileTrail(to: "atlas")
        u.refiled(to: "atlas", from: "atlas")
        XCTAssertEqual(u.movesFrom, [])
    }

    // MARK: a current project whose folder moved

    /// dogfood v0.9-2: a snap with a current project whose folder had been moved made the folder again at the old
    /// path (and its items started at BA-1 there). Captures go to Unassigned until the folder is located.
    func testACurrentProjectWhoseFolderIsGoneTakesNoCaptures() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func project(_ id: String, at u: URL, inbox: Bool = false) -> Project {
            Project(id: id, name: id, key: id.uppercased(), slug: id, description: "", path: u, store: u.appendingPathComponent(".blurt"),
                    isInbox: inbox, isGitRepo: false, worktree: false, defaultAgent: nil, modules: [], lastUsed: nil, pinned: false)
        }
        let inbox = project("inbox", at: dir.appendingPathComponent("inbox"), inbox: true)
        let here = project("ba", at: dir)
        let gone = project("ba", at: dir.appendingPathComponent("billing-api"))
        XCTAssertEqual(ProjectStore.captureTarget(current: here, inbox: inbox).id, "ba")
        XCTAssertEqual(ProjectStore.captureTarget(current: gone, inbox: inbox).id, "inbox")
        XCTAssertEqual(ProjectStore.captureTarget(current: nil, inbox: inbox).id, "inbox")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path.path))
        // Organize (the island's button and its menu alike): into the project only while its folder is there
        XCTAssertEqual(ProjectStore.organizeTarget(current: here, inbox: inbox), "ba")
        XCTAssertNil(ProjectStore.organizeTarget(current: gone, inbox: inbox))
        XCTAssertNil(ProjectStore.organizeTarget(current: nil, inbox: inbox))
        // Locate…: the moved folder holds this project's store; another project's is refused
        let moved = dir.appendingPathComponent("billing-api-moved")
        XCTAssertEqual(ProjectStore.locatePick(moved, projectID: "ba"), .empty)
        try FileManager.default.createDirectory(at: moved.appendingPathComponent(".blurt"), withIntermediateDirectories: true)
        try Data(#"{"project": "ba", "key": "BA", "next": 13}"#.utf8).write(to: moved.appendingPathComponent(".blurt/store.json"))
        XCTAssertEqual(ProjectStore.locatePick(moved, projectID: "ba"), .same)
        XCTAssertEqual(ProjectStore.locatePick(moved, projectID: "aw"), .other)
    }
}
