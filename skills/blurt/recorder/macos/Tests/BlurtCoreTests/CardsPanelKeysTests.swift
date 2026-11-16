import XCTest
@testable import BlurtCore

/// The big preview's keys (CardsPanelKeys.swift).
final class CardsPanelKeysTests: XCTestCase {
    func testPreviewKeys() {
        XCTAssertEqual(CardsPanelRules.previewAction(.left), .step(-1))
        XCTAssertEqual(CardsPanelRules.previewAction(.up), .step(-1))
        XCTAssertEqual(CardsPanelRules.previewAction(.right), .step(1))
        XCTAssertEqual(CardsPanelRules.previewAction(.down), .step(1))
        XCTAssertEqual(CardsPanelRules.previewAction(.space), .close)
        XCTAssertEqual(CardsPanelRules.previewAction(.escape), .close)
        XCTAssertEqual(CardsPanelRules.previewAction(.tab), .none)
    }
}
