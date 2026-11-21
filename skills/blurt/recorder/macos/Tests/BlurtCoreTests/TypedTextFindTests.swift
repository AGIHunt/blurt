import XCTest
@testable import BlurtCore

final class TypedTextFindTests: XCTestCase {
    func testWhereTheCursorWasThenNearbyThenGone() {
        XCTAssertEqual(TypedTextFind.find("你好", in: "说你好呀", near: 1), 1)
        XCTAssertEqual(TypedTextFind.find("hello", in: "  hello", near: 0), 2, "a field that reflowed it")
        XCTAssertNil(TypedTextFind.find("hello", in: "bye", near: 0))
    }

    func testAFieldReadBackShorterThanItsCursorDoesNotCrash() {
        // the 1.0.26 crash: the cursor was 500 in, the field read back 20 characters long → a search from past its end
        XCTAssertNil(TypedTextFind.find("hi", in: "rewritten by the page", near: 500))
        XCTAssertEqual(TypedTextFind.find("page", in: "rewritten by the page", near: 500), nil, "searched only from 200 before the cursor")
        XCTAssertEqual(TypedTextFind.find("page", in: "rewritten by the page", near: 210), 17)
        XCTAssertNil(TypedTextFind.find("x", in: "", near: 3))
        XCTAssertEqual(TypedTextFind.find("hi", in: "hi there", near: -5), 0, "a negative cursor finds it from the start")
        XCTAssertNil(TypedTextFind.find("a long typed text", in: "short", near: 0))
        XCTAssertNil(TypedTextFind.find("hi", in: "hi", near: Int.max))
    }
}
