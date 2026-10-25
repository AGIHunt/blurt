import XCTest
@testable import BlurtCore

final class SearchHitTests: XCTestCase {
    func testPlainDropsMarkersAndEllipses() {
        XCTAssertEqual(SearchHit.plain("…the [login] button…"), "the login button")
        XCTAssertEqual(SearchHit.plain("[登录]按钮"), "登录按钮")
    }

    func testTheTitleAgainAddsNothing() {
        // the palette used to read "Login button does nothing · BA-12 · app · Login button does nothing"
        XCTAssertFalse(SearchHit.adds("[Login] button does nothing", to: "Login button does nothing"))
        XCTAssertFalse(SearchHit.adds("[登录]按钮点击无响应", to: "登录按钮点击无响应"))
        XCTAssertFalse(SearchHit.adds("…button [does]…", to: "Login button does nothing"))   // a piece of it
        XCTAssertFalse(SearchHit.adds("[login] BUTTON", to: "Login button does nothing"))     // case aside
        XCTAssertFalse(SearchHit.adds(nil, to: "x"))
        XCTAssertFalse(SearchHit.adds("…", to: "x"))
    }

    func testAHitOverSeveralLinesIsOneLine() {
        // the palette showed "Open /login" and a clipped "Cl" under every row (an item's steps, one per line)
        XCTAssertEqual(SearchHit.oneLine("Open /[login]\nClick Sign in"), "Open /[login] · Click Sign in")
        XCTAssertEqual(SearchHit.oneLine("  a \r\n\n b  "), "a · b")
        XCTAssertEqual(SearchHit.oneLine("登录按钮"), "登录按钮")
    }

    func testAHitInAnotherFieldIsShown() {
        XCTAssertTrue(SearchHit.adds("…returns a [500] from /api/avatar…", to: "Avatar upload fails"))
    }
}
