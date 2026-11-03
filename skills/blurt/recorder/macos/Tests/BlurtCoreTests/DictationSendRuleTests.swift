// A double tap presses Return only as the send of a dictation (BlurtCore/DictationSendRule.swift).
import XCTest
@testable import BlurtCore

final class DictationSendRuleTests: XCTestCase {
    func testReturnOnlyAfterADictationInTheSameApp() {
        let wechat = "com.tencent.xinWeChat"
        // nothing dictated yet: no Return (the founder's report)
        XCTAssertEqual(DictationSendRule.decide(pending: false, lastPaste: nil, front: wechat, now: 100), .noTake)
        // a take still on its way: Return once it has been pasted
        XCTAssertEqual(DictationSendRule.decide(pending: true, lastPaste: nil, front: wechat, now: 100), .queue)
        // just typed into the app in front: send
        XCTAssertEqual(DictationSendRule.decide(pending: false, lastPaste: (95, wechat), front: wechat, now: 100), .send)
        // typed elsewhere, or long ago: no
        XCTAssertEqual(DictationSendRule.decide(pending: false, lastPaste: (95, "com.apple.Notes"), front: wechat, now: 100), .noTake)
        XCTAssertEqual(DictationSendRule.decide(pending: false, lastPaste: (0, wechat), front: wechat, now: 100), .noTake)
    }
}
