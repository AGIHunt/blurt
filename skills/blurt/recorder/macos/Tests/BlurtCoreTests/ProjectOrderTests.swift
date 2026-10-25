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

    /// A pinned project can't be dropped among the unpinned ones (it would snap back), nor the other way round.
    func testDropStaysInsideTheDraggedProjectsSection() {
        let ids = ["p1", "p2", "a", "b", "c"]
        let pinned: Set<String> = ["p1", "p2"]
        XCTAssertEqual(ProjectStore.dropRange(ids, pinned: pinned, moving: "c"), 2...5)
        XCTAssertEqual(ProjectStore.dropRange(ids, pinned: pinned, moving: "p2"), 0...2)
        XCTAssertEqual(ProjectStore.dropRange(["a", "b"], pinned: [], moving: "a"), 0...2)
        // a drop clamped into the range lands at the section's edge
        let at = min(max(0, 2), 5)
        XCTAssertEqual(ProjectStore.userOrder(ProjectStore.reordered(ids, moving: "c", to: at).map { p($0, pinned: pinned.contains($0)) }).map(\.id),
                       ["p1", "p2", "c", "a", "b"])
    }

    /// An order applied later (⌘Z after a project was removed meanwhile) never names a project that isn't there.
    func testAnOrderAppliedLaterSkipsProjectsThatAreGone() {
        XCTAssertEqual(ProjectStore.reconciled(["b", "gone", "a"], with: ["a", "b", "c"]), ["b", "a", "c"])
        XCTAssertEqual(ProjectStore.reconciled([], with: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(ProjectStore.reconciled(["a", "b"], with: ["a", "b"]), ["a", "b"])
    }
}
