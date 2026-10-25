// BlurtCore/Projects: the main window's projects keep the user's order (micro 11) — the registry's, pinned first,
// never re-sorted by use — and a drag in the sidebar moves one project to where it was dropped.
import Foundation
import XCTest
@testable import BlurtCore

final class ProjectOrderTests: XCTestCase {
    func p(_ id: String, pinned: Bool = false, used: TimeInterval = 0) -> Project {
        Project(id: id, name: id, key: id.uppercased(), slug: id, description: "", path: URL(fileURLWithPath: "/tmp/\(id)"),
                store: URL(fileURLWithPath: "/tmp/\(id)/.blurt"), isInbox: false, isGitRepo: false, worktree: false, defaultAgent: nil,
                modules: [], lastUsed: Date(timeIntervalSince1970: used), pinned: pinned)
    }

    func testTheUsersOrderIgnoresRecentUse() {
        // c was used last: the recency list puts it first, the user's order doesn't move it
        let reg = [p("a", used: 1), p("b", used: 2), p("c", used: 3), p("d", pinned: true)]
        XCTAssertEqual(ProjectStore.userOrder(reg).map(\.id), ["d", "a", "b", "c"])
    }

    func testDropMovesOneProject() {
        let ids = ["a", "b", "c", "d"]
        XCTAssertEqual(ProjectStore.reordered(ids, moving: "c", to: 0), ["c", "a", "b", "d"])   // to the top
        XCTAssertEqual(ProjectStore.reordered(ids, moving: "a", to: 4), ["b", "c", "d", "a"])   // to the end
        XCTAssertEqual(ProjectStore.reordered(ids, moving: "a", to: 2), ["b", "a", "c", "d"])   // down one
        XCTAssertEqual(ProjectStore.reordered(ids, moving: "b", to: 1), ids)                    // where it was
        XCTAssertEqual(ProjectStore.reordered(ids, moving: "x", to: 0), ids)
    }
}
