// BlurtCore/TopRows: the banners and jobs above the list are reachable from the keyboard (micro 15).
import XCTest
@testable import BlurtCore

final class TopRowsTests: XCTestCase {
    let rows = ["banner:captures", "banner:taken", "job-1"]

    func testUpFromTheFirstItemEntersTheLastRowAbove() {
        XCTAssertEqual(TopRows.step(rows, current: nil, by: -1, fromRow: 0, hasItems: true), .row("job-1"))
        XCTAssertEqual(TopRows.step(rows, current: nil, by: -1, fromRow: 3, hasItems: true), .pass)     // inside the list
        XCTAssertEqual(TopRows.step(rows, current: nil, by: 1, fromRow: 0, hasItems: true), .pass)
        XCTAssertEqual(TopRows.step([], current: nil, by: -1, fromRow: 0, hasItems: true), .pass)
    }

    func testTheBannersAreWalkedLikeTheJobs() {
        XCTAssertEqual(TopRows.step(rows, current: "job-1", by: -1, fromRow: -1, hasItems: true), .row("banner:taken"))
        XCTAssertEqual(TopRows.step(rows, current: "banner:taken", by: -1, fromRow: -1, hasItems: true), .row("banner:captures"))
        XCTAssertEqual(TopRows.step(rows, current: "banner:captures", by: -1, fromRow: -1, hasItems: true), .beep)
        XCTAssertEqual(TopRows.step(rows, current: "banner:captures", by: 1, fromRow: -1, hasItems: true), .row("banner:taken"))
    }

    func testDownFromTheLastRowIsTheFirstItem() {
        XCTAssertEqual(TopRows.step(rows, current: "job-1", by: 1, fromRow: -1, hasItems: true), .firstItem)
        XCTAssertEqual(TopRows.step(["banner:taken"], current: "banner:taken", by: 1, fromRow: -1, hasItems: false), .beep)
    }

    func testARowThatWentAwayHandsTheKeyBack() {
        // the banner hid (its cards were filed) while the cursor was on it
        XCTAssertEqual(TopRows.step(["job-1"], current: "banner:captures", by: -1, fromRow: 0, hasItems: true), .row("job-1"))
    }
}
