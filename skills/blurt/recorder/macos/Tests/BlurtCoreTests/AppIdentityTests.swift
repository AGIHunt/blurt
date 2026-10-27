import XCTest
@testable import BlurtCore

final class AppIdentityTests: XCTestCase {
    func testBundleIDsAreNotNames() {
        XCTAssertTrue(AppIdentity.looksLikeBundleID("com.apple.TextEdit"))
        XCTAssertTrue(AppIdentity.looksLikeBundleID("com.anthropic.claudefordesktop"))
        XCTAssertFalse(AppIdentity.looksLikeBundleID("TextEdit"))
        XCTAssertFalse(AppIdentity.looksLikeBundleID("Visual Studio Code"))
        XCTAssertFalse(AppIdentity.looksLikeBundleID("Node.js"))
        XCTAssertFalse(AppIdentity.looksLikeBundleID("口喷鸡"))
    }
}
