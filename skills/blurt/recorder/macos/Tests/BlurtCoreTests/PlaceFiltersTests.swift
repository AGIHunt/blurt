// BlurtCore/PlaceFilters.swift: each place of the main window keeps its own filters, and a place never shows a State
// filter it has no control for (the dogfood's Inbox emptied by All Items' "Discarded", even after a relaunch).
import Foundation
import XCTest
@testable import BlurtCore

final class PlaceFiltersTests: XCTestCase {
    func testAStateSetInAllItemsStaysThere() {
        var f = PlaceFilters()
        f.set(PlaceFilter(kinds: ["issue"], state: "discarded"), for: "all")
        XCTAssertEqual(f.filter(for: "all"), PlaceFilter(kinds: ["issue"], state: "discarded"))
        XCTAssertEqual(f.filter(for: "inbox"), PlaceFilter())
        XCTAssertEqual(f.filter(for: "project:p1"), PlaceFilter())
    }

    func testTheInboxNeverKeepsAState() {
        var f = PlaceFilters()
        f.set(PlaceFilter(kinds: ["idea"], state: "discarded"), for: "inbox")
        XCTAssertEqual(f.filter(for: "inbox"), PlaceFilter(kinds: ["idea"]))   // its kinds, yes
        // a file written before the filter was per place: the state can't come back into the Inbox either
        let old = try! JSONDecoder().decode(PlaceFilters.self, from: Data(#"{"byPlace":{"inbox":{"kinds":[],"state":"discarded"}}}"#.utf8))
        XCTAssertEqual(old.filter(for: "inbox"), PlaceFilter())
        XCTAssertFalse(PlaceFilters.showsState("inbox"))
        XCTAssertTrue(PlaceFilters.showsState("progress"))
    }

    func testSavedAndRestored() throws {
        var f = PlaceFilters()
        f.set(PlaceFilter(kinds: ["task", "issue"], state: nil), for: "project:p1")
        f.set(PlaceFilter(state: "todo"), for: "all")
        f.set(PlaceFilter(state: "bogus"), for: "unassigned")      // not a state the control offers: dropped
        f.set(PlaceFilter(state: "done"), for: "session:abc")       // a batch is visited, not kept
        f.set(PlaceFilter(), for: "progress")                       // nothing to keep
        let back = try JSONDecoder().decode(PlaceFilters.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(back, f)
        XCTAssertEqual(Set(back.byPlace.keys), ["project:p1", "all"])
        XCTAssertEqual(back.filter(for: "project:p1").kinds, ["issue", "task"])
        XCTAssertEqual(back.filter(for: "session:abc"), PlaceFilter())
        var g = back
        g.forget("project:p1")
        XCTAssertEqual(g.filter(for: "project:p1"), PlaceFilter())
    }
}
