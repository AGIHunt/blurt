// BlurtCore/MoveBack.swift: ⌘Z after a move sends each item back to its own project.
import XCTest
@testable import BlurtCore

final class MoveBackTests: XCTestCase {
    func testEachItemBackToItsOwnProject() {
        let plan = MoveBack.plan([("u1", "atlas"), ("u2", "inbox"), ("u3", "atlas"), ("u4", "api")], movedTo: "api")
        XCTAssertEqual(plan, [MoveBack.Step(project: "atlas", uids: ["u1", "u3"]), MoveBack.Step(project: "inbox", uids: ["u2"])])
    }

    func testNothingMovedNothingToUndo() {
        XCTAssertEqual(MoveBack.plan([("u1", "api")], movedTo: "api"), [])
        XCTAssertEqual(MoveBack.plan([], movedTo: "api"), [])
    }
}
