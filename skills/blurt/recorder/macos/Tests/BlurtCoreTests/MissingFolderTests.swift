// BlurtCore/Projects/MissingFolder.swift: nothing is filed into a project whose folder is gone; Locate… only takes the
// same project back.
import XCTest
@testable import BlurtCore

final class MissingFolderTests: XCTestCase {
    /// The dogfood: a card moved into a renamed project's old path made that folder again, with clashing ids.
    func testAProjectWhoseFolderIsGoneKeepsItsCapturesAsCards() {
        XCTAssertEqual(MissingFolder.filing(project: "p-1", exists: false), .keepAsCards)
        XCTAssertEqual(MissingFolder.filing(project: "p-1", exists: true), .file)
        XCTAssertEqual(MissingFolder.filing(project: "inbox", exists: false), .file, "Unassigned is Blurt's own folder")
        XCTAssertEqual(MissingFolder.filing(project: "p-unknown", exists: nil), .file, "not known here: the scripts decide")
    }

    /// Locate… on the wrong folder opened another project: it doesn't take the missing one's place.
    func testLocateTakesOnlyTheSameProjectBack() {
        XCTAssertEqual(MissingFolder.located(wanted: "p-1", found: "p-1"), .same)
        XCTAssertEqual(MissingFolder.located(wanted: "p-1", found: "p-2"), .other)
    }
}
