import XCTest
@testable import BlurtCore

final class MiddleTruncateTests: XCTestCase {
    func testAShortNameStaysWhole() {
        XCTAssertEqual(MiddleTruncate.fit("billing-api", in: { "Filed to \($0) · BA-4" }, fits: { $0.count <= 40 }), "billing-api")
    }

    func testALongNameLosesItsMiddleUntilTheLineFits() {
        let name = "口喷鸡 iOS 客户端（非常长的项目名称用来测试截断）"
        let out = MiddleTruncate.fit(name, in: { "Filed to \($0) · IOS-4" }, fits: { $0.count <= 30 })
        XCTAssertTrue(out.contains("…"))
        XCTAssertTrue(out.hasPrefix("口喷鸡"))
        XCTAssertTrue(out.hasSuffix("截断）"))
        XCTAssertLessThanOrEqual("Filed to \(out) · IOS-4".count, 30)
        XCTAssertGreaterThan("Filed to \(out)x · IOS-4".count, 30 - 1)
    }
}
