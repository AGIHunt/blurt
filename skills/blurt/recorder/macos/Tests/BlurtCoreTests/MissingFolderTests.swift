// BlurtCore/Projects/Projects.swift (ProjectStore.filing, locatePick): nothing is filed into a project whose folder is
// gone; Locate… only takes the same project back.
import XCTest
@testable import BlurtCore

final class MissingFolderTests: XCTestCase {
    /// The dogfood: a card moved into a renamed project's old path made that folder again, with clashing ids.
    func testAProjectWhoseFolderIsGoneKeepsItsCapturesAsCards() {
        XCTAssertEqual(ProjectStore.filing(project: "p-1", exists: false), .keepAsCards)
        XCTAssertEqual(ProjectStore.filing(project: "p-1", exists: true), .file)
        XCTAssertEqual(ProjectStore.filing(project: "inbox", exists: false), .file, "Unassigned is Blurt's own folder")
        XCTAssertEqual(ProjectStore.filing(project: "p-unknown", exists: nil), .file, "not known here: the scripts decide")
    }

    /// Locate… on the wrong folder (another project's) doesn't take the missing one's place.
    func testLocateTakesOnlyTheSameProjectBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".blurt"), withIntermediateDirectories: true)
        try Data(#"{"project": "p-1", "key": "P", "next": 1}"#.utf8).write(to: dir.appendingPathComponent(".blurt/store.json"))
        XCTAssertEqual(ProjectStore.locatePick(dir, projectID: "p-1"), .same)
        XCTAssertEqual(ProjectStore.locatePick(dir, projectID: "p-2"), .other)
    }
}
