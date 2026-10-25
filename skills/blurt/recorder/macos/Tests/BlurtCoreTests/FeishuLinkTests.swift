// BlurtCore/FeishuLink.swift: a pasted table link is checked before it is saved.
import XCTest
@testable import BlurtCore

final class FeishuLinkTests: XCTestCase {
    func testTableLinks() {
        XCTAssertTrue(FeishuLink.plausible(""))
        XCTAssertTrue(FeishuLink.plausible("https://acme.feishu.cn/base/bascnXYZ?table=tbl1"))
        XCTAssertTrue(FeishuLink.plausible(" https://acme.larksuite.com/base/abc?table=t "))
        XCTAssertTrue(FeishuLink.plausible("https://x.larkoffice.com/wiki/abc"))
        XCTAssertFalse(FeishuLink.plausible("acme.feishu.cn/base/x"))          // no scheme
        XCTAssertFalse(FeishuLink.plausible("https://notfeishu.cn/base/x"))
        XCTAssertFalse(FeishuLink.plausible("https://docs.google.com/spreadsheets/d/x"))
        XCTAssertFalse(FeishuLink.plausible("ftp://acme.feishu.cn/base/x"))
    }
}
