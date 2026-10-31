import XCTest
@testable import BlurtCore

/// The Cards panel's rules (CardsPanelKeys.swift): ⌥H's segment, and every key in the panel and its preview.
final class CardsPanelKeysTests: XCTestCase {
    func testOptionHOpensOnHangingElseUsedNeverEmpty() {
        XCTAssertEqual(CardsPanelRules.openSegment(hanging: 3, used: 5), .hanging)
        XCTAssertEqual(CardsPanelRules.openSegment(hanging: 3, used: 0), .hanging)
        XCTAssertEqual(CardsPanelRules.openSegment(hanging: 0, used: 2), .used)
        XCTAssertNil(CardsPanelRules.openSegment(hanging: 0, used: 0))
    }

    func testOptionHAgainCloses() {
        XCTAssertEqual(CardsPanelRules.toggle(isOpen: false, hanging: 1, used: 0), .open(.hanging))
        XCTAssertEqual(CardsPanelRules.toggle(isOpen: false, hanging: 0, used: 4), .open(.used))
        XCTAssertEqual(CardsPanelRules.toggle(isOpen: false, hanging: 0, used: 0), .nothing)
        XCTAssertEqual(CardsPanelRules.toggle(isOpen: true, hanging: 3, used: 3), .close)
        XCTAssertEqual(CardsPanelRules.toggle(isOpen: true, hanging: 0, used: 0), .close)
    }

    func testTabAndUnfocusedArrowsSwitchSegments() {
        XCTAssertEqual(CardsPanelRules.action(.tab, segment: .hanging, focus: nil, count: 3, columns: 3), .segment(.used))
        XCTAssertEqual(CardsPanelRules.action(.tab, segment: .used, focus: 1, count: 3, columns: 3), .segment(.hanging))
        XCTAssertEqual(CardsPanelRules.action(.right, segment: .hanging, focus: nil, count: 3, columns: 3), .segment(.used))
        XCTAssertEqual(CardsPanelRules.action(.left, segment: .used, focus: nil, count: 3, columns: 3), .segment(.hanging))
        // already there: nothing (never a wrap round)
        XCTAssertEqual(CardsPanelRules.action(.left, segment: .hanging, focus: nil, count: 3, columns: 3), .none)
        XCTAssertEqual(CardsPanelRules.action(.right, segment: .used, focus: nil, count: 0, columns: 1), .none)
    }

    func testArrowsMoveBetweenCardsOnceOneIsFocused() {
        // 7 cards in 4 columns: 0 1 2 3 / 4 5 6
        XCTAssertEqual(CardsPanelRules.action(.down, segment: .hanging, focus: nil, count: 7, columns: 4), .focus(0))
        XCTAssertEqual(CardsPanelRules.action(.right, segment: .hanging, focus: 0, count: 7, columns: 4), .focus(1))
        XCTAssertEqual(CardsPanelRules.action(.left, segment: .hanging, focus: 1, count: 7, columns: 4), .focus(0))
        XCTAssertEqual(CardsPanelRules.action(.left, segment: .used, focus: 0, count: 7, columns: 4), .none)
        XCTAssertEqual(CardsPanelRules.action(.right, segment: .hanging, focus: 6, count: 7, columns: 4), .none)
        XCTAssertEqual(CardsPanelRules.action(.down, segment: .hanging, focus: 1, count: 7, columns: 4), .focus(5))
        XCTAssertEqual(CardsPanelRules.action(.down, segment: .hanging, focus: 3, count: 7, columns: 4), .focus(6))   // under it: none, the last
        XCTAssertEqual(CardsPanelRules.action(.down, segment: .hanging, focus: 5, count: 7, columns: 4), .none)      // the last row stays
        XCTAssertEqual(CardsPanelRules.action(.up, segment: .hanging, focus: 5, count: 7, columns: 4), .focus(1))
        // from the top row back to the segments, where ← → switch again
        XCTAssertEqual(CardsPanelRules.action(.up, segment: .hanging, focus: 2, count: 7, columns: 4), .focus(nil))
        XCTAssertEqual(CardsPanelRules.action(.up, segment: .hanging, focus: nil, count: 7, columns: 4), .none)
        XCTAssertEqual(CardsPanelRules.action(.down, segment: .used, focus: nil, count: 0, columns: 1), .none)
    }

    func testSpacePreviewsTheFocusedCardElseThePointedOne() {
        XCTAssertEqual(CardsPanelRules.action(.space, segment: .used, focus: 2, count: 3, columns: 3), .preview(2))
        XCTAssertEqual(CardsPanelRules.action(.space, segment: .used, focus: nil, count: 3, columns: 3, pointed: 1), .preview(1))
        XCTAssertEqual(CardsPanelRules.action(.space, segment: .used, focus: 0, count: 3, columns: 3, pointed: 1), .preview(0))
        XCTAssertEqual(CardsPanelRules.action(.space, segment: .hanging, focus: nil, count: 3, columns: 3), .none)
        XCTAssertEqual(CardsPanelRules.action(.space, segment: .hanging, focus: nil, count: 3, columns: 3, pointed: 9), .none)
    }

    func testEnterCopiesDeleteDeletesEscCloses() {
        XCTAssertEqual(CardsPanelRules.action(.enter, segment: .hanging, focus: 1, count: 3, columns: 3), .copyAndClose(1))
        XCTAssertEqual(CardsPanelRules.action(.copy, segment: .used, focus: 0, count: 3, columns: 3), .copyAndClose(0))
        XCTAssertEqual(CardsPanelRules.action(.enter, segment: .hanging, focus: nil, count: 3, columns: 3), .none)
        XCTAssertEqual(CardsPanelRules.action(.delete, segment: .used, focus: 2, count: 3, columns: 3), .delete(2))
        XCTAssertEqual(CardsPanelRules.action(.delete, segment: .used, focus: nil, count: 3, columns: 3), .none)
        XCTAssertEqual(CardsPanelRules.action(.escape, segment: .used, focus: 2, count: 3, columns: 3), .close)
        XCTAssertEqual(CardsPanelRules.action(.close, segment: .hanging, focus: nil, count: 0, columns: 1), .close)
        // a focus left over from a longer list is no card
        XCTAssertEqual(CardsPanelRules.action(.enter, segment: .hanging, focus: 5, count: 3, columns: 3), .none)
    }

    func testPreviewKeys() {
        XCTAssertEqual(CardsPanelRules.previewAction(.left), .step(-1))
        XCTAssertEqual(CardsPanelRules.previewAction(.right), .step(1))
        XCTAssertEqual(CardsPanelRules.previewAction(.space), .close)
        XCTAssertEqual(CardsPanelRules.previewAction(.escape), .close)
        XCTAssertEqual(CardsPanelRules.previewAction(.tab), .none)
    }
}
