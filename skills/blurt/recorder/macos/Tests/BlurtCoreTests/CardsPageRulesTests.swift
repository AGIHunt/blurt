import XCTest
@testable import BlurtCore

/// The Cards page's rules (CardsPageRules.swift): the grid's columns, every key on the grid, and the search.
final class CardsPageRulesTests: XCTestCase {
    func testColumnsFitTheWidthAndNeverNone() {
        XCTAssertEqual(CardsPageRules.columns(width: 760), 4)       // 4 × 148 + 3 × 12 = 628; a fifth needs 788
        XCTAssertEqual(CardsPageRules.columns(width: 788), 5)
        XCTAssertEqual(CardsPageRules.columns(width: 787), 4)
        XCTAssertEqual(CardsPageRules.columns(width: 308), 2)
        XCTAssertEqual(CardsPageRules.columns(width: 307), 1)
        XCTAssertEqual(CardsPageRules.columns(width: 90), 1)
        XCTAssertEqual(CardsPageRules.columns(width: 0), 1)
    }

    func testTilesWidenToFillTheRow() {
        // the page's full column: four across, 181 × 122 (4 × 181 + 3 × 12 = 760)
        var t = CardsPageRules.tile(width: 760)
        XCTAssertEqual(t.columns, 4); XCTAssertEqual(t.width, 181); XCTAssertEqual(t.height, 122)
        // exactly the panel's size when that fills it
        t = CardsPageRules.tile(width: 628)
        XCTAssertEqual(t.columns, 4); XCTAssertEqual(t.width, 148); XCTAssertEqual(t.height, 100)
        // just under a fourth column: three wide ones
        t = CardsPageRules.tile(width: 627)
        XCTAssertEqual(t.columns, 3); XCTAssertEqual(t.width, 201); XCTAssertEqual(t.height, 136)
        // never smaller than the panel's, however narrow
        t = CardsPageRules.tile(width: 100)
        XCTAssertEqual(t.columns, 1); XCTAssertEqual(t.width, 148); XCTAssertEqual(t.height, 100)
        // a row never overflows its width
        for w in stride(from: 148.0, through: 1200, by: 7) {
            let m = CardsPageRules.tile(width: w)
            XCTAssertLessThanOrEqual(Double(m.columns) * m.width + Double(m.columns - 1) * CardsPageRules.gap, w, "\(w)")
        }
    }

    // 6 current in 4 columns (4 + 2), 5 in history (4 + 1):
    //    0  1  2  3
    //    4  5
    //    6  7  8  9
    //   10
    private let two = [6, 5]

    func testNoCardFocused() {
        XCTAssertEqual(CardsPageRules.action(.down, focus: nil, sections: two, columns: 4), .focus(0))
        XCTAssertEqual(CardsPageRules.action(.right, focus: nil, sections: two, columns: 4), .focus(0))
        XCTAssertEqual(CardsPageRules.action(.left, focus: nil, sections: two, columns: 4), .none)
        XCTAssertEqual(CardsPageRules.action(.up, focus: nil, sections: two, columns: 4), .search)
        XCTAssertEqual(CardsPageRules.action(.down, focus: nil, sections: [0, 0], columns: 4), .none)
        for k in [CardsPanelKey.enter, .copy, .delete, .space] {
            XCTAssertEqual(CardsPageRules.action(k, focus: nil, sections: two, columns: 4), .none)
        }
        // a focus that no longer exists counts as none
        XCTAssertEqual(CardsPageRules.action(.down, focus: 40, sections: two, columns: 4), .focus(0))
    }

    func testLeftAndRightRunThroughBothSections() {
        XCTAssertEqual(CardsPageRules.action(.right, focus: 5, sections: two, columns: 4), .focus(6))
        XCTAssertEqual(CardsPageRules.action(.left, focus: 6, sections: two, columns: 4), .focus(5))
        XCTAssertEqual(CardsPageRules.action(.left, focus: 0, sections: two, columns: 4), .none)
        XCTAssertEqual(CardsPageRules.action(.right, focus: 10, sections: two, columns: 4), .none)
    }

    func testDownStaysInTheColumnAndCrossesIntoTheNextSection() {
        XCTAssertEqual(CardsPageRules.action(.down, focus: 0, sections: two, columns: 4), .focus(4))
        XCTAssertEqual(CardsPageRules.action(.down, focus: 3, sections: two, columns: 4), .focus(5))    // a short row: its last card
        XCTAssertEqual(CardsPageRules.action(.down, focus: 4, sections: two, columns: 4), .focus(6))    // into History, column 0
        XCTAssertEqual(CardsPageRules.action(.down, focus: 5, sections: two, columns: 4), .focus(7))
        XCTAssertEqual(CardsPageRules.action(.down, focus: 9, sections: two, columns: 4), .focus(10))
        XCTAssertEqual(CardsPageRules.action(.down, focus: 10, sections: two, columns: 4), .none)
        // an empty section between is stepped over; an empty one after: nothing
        XCTAssertEqual(CardsPageRules.action(.down, focus: 1, sections: [2, 0, 3], columns: 4), .focus(3))
        XCTAssertEqual(CardsPageRules.action(.down, focus: 1, sections: [2, 0], columns: 4), .none)
        // the next section is narrower than the column
        XCTAssertEqual(CardsPageRules.action(.down, focus: 3, sections: [4, 1], columns: 4), .focus(4))
    }

    func testUpStaysInTheColumnCrossesBackAndLeavesFromTheTopRow() {
        XCTAssertEqual(CardsPageRules.action(.up, focus: 4, sections: two, columns: 4), .focus(0))
        XCTAssertEqual(CardsPageRules.action(.up, focus: 10, sections: two, columns: 4), .focus(6))
        XCTAssertEqual(CardsPageRules.action(.up, focus: 6, sections: two, columns: 4), .focus(4))     // Current's last row, column 0
        XCTAssertEqual(CardsPageRules.action(.up, focus: 7, sections: two, columns: 4), .focus(5))
        XCTAssertEqual(CardsPageRules.action(.up, focus: 9, sections: two, columns: 4), .focus(5))     // that row ends at column 1
        XCTAssertEqual(CardsPageRules.action(.up, focus: 2, sections: two, columns: 4), .search)
        XCTAssertEqual(CardsPageRules.action(.up, focus: 0, sections: [0, 3], columns: 4), .search)    // nothing above History
        XCTAssertEqual(CardsPageRules.action(.up, focus: 2, sections: [2, 0, 3], columns: 4), .focus(0))
    }

    func testOneColumn() {
        XCTAssertEqual(CardsPageRules.action(.down, focus: 1, sections: [2, 2], columns: 1), .focus(2))
        XCTAssertEqual(CardsPageRules.action(.up, focus: 2, sections: [2, 2], columns: 1), .focus(1))
        XCTAssertEqual(CardsPageRules.action(.down, focus: 0, sections: [2, 2], columns: 0), .focus(1))   // never fewer than one
    }

    func testTheFocusedCardsKeys() {
        XCTAssertEqual(CardsPageRules.action(.enter, focus: 3, sections: two, columns: 4), .copy(3))
        XCTAssertEqual(CardsPageRules.action(.copy, focus: 7, sections: two, columns: 4), .copy(7))
        XCTAssertEqual(CardsPageRules.action(.delete, focus: 7, sections: two, columns: 4), .delete(7))
        XCTAssertEqual(CardsPageRules.action(.space, focus: 2, sections: two, columns: 4), .preview(2))
        // Space without a focused card previews the one under the pointer
        XCTAssertEqual(CardsPageRules.action(.space, focus: nil, sections: two, columns: 4, pointed: 9), .preview(9))
        XCTAssertEqual(CardsPageRules.action(.space, focus: nil, sections: two, columns: 4, pointed: 30), .none)
    }

    func testEscClearsASearchThenLetsGoOfTheCard() {
        XCTAssertEqual(CardsPageRules.action(.escape, focus: 1, sections: two, columns: 4, searching: true), .clearSearch)
        XCTAssertEqual(CardsPageRules.action(.escape, focus: nil, sections: two, columns: 4, searching: true), .clearSearch)
        XCTAssertEqual(CardsPageRules.action(.escape, focus: 1, sections: two, columns: 4), .deselect)
        XCTAssertEqual(CardsPageRules.action(.escape, focus: nil, sections: two, columns: 4), .none)      // the window's
        XCTAssertEqual(CardsPageRules.action(.tab, focus: 1, sections: two, columns: 4), .none)
        XCTAssertEqual(CardsPageRules.action(.close, focus: 1, sections: two, columns: 4), .none)
    }

    func testFocusAfterDelete() {
        XCTAssertEqual(CardsPageRules.focusAfterDelete(2, count: 5), 2)     // the next card took its place
        XCTAssertEqual(CardsPageRules.focusAfterDelete(4, count: 5), 3)     // it was the last
        XCTAssertNil(CardsPageRules.focusAfterDelete(0, count: 1))
    }

    func testFocusAfterDeletingSeveral() {
        XCTAssertEqual(CardsPageRules.focusAfterDelete([1, 3], count: 6), 1)       // the card after the first one gone
        XCTAssertEqual(CardsPageRules.focusAfterDelete([4, 5], count: 6), 3)       // they were the last: the last left
        XCTAssertEqual(CardsPageRules.focusAfterDelete([3, 0], count: 4), 0)       // any order
        XCTAssertNil(CardsPageRules.focusAfterDelete([0, 1, 2], count: 3))         // nothing left
        XCTAssertNil(CardsPageRules.focusAfterDelete([], count: 3))
        XCTAssertNil(CardsPageRules.focusAfterDelete([7], count: 3))               // not a card showing
    }

    func testSelectAllTakesTheFocusedCardsSection() {
        XCTAssertEqual(CardsPageRules.section(of: 2, sections: [3, 4]), 0..<3)
        XCTAssertEqual(CardsPageRules.section(of: 5, sections: [3, 4]), 3..<7)
        XCTAssertEqual(CardsPageRules.section(of: nil, sections: [3, 4]), 0..<3)    // no card: the first section
        XCTAssertEqual(CardsPageRules.section(of: nil, sections: [0, 4]), 0..<4)    // that shows a card
        XCTAssertNil(CardsPageRules.section(of: nil, sections: [0, 0]))
        XCTAssertNil(CardsPageRules.section(of: 9, sections: [3, 4]))
    }

    func testOptionHOpensThePageAndHidesItWhenItIsInFront() {
        XCTAssertEqual(CardsPageRules.hotkey(windowKey: false, onCards: false), .open)
        XCTAssertEqual(CardsPageRules.hotkey(windowKey: false, onCards: true), .open)      // behind another app: forward
        XCTAssertEqual(CardsPageRules.hotkey(windowKey: true, onCards: false), .open)       // on another page: to Cards
        XCTAssertEqual(CardsPageRules.hotkey(windowKey: true, onCards: true), .hide)
    }

    func testSearchFindsEveryWordAnywhereInTheCard() {
        let card: [String?] = ["结账按钮一直是灰的 Checkout button stays grey", "Snap · 19:05", nil]
        XCTAssertTrue(CardsPageRules.matches("", fields: card))
        XCTAssertTrue(CardsPageRules.matches("   ", fields: card))
        XCTAssertTrue(CardsPageRules.matches("按钮", fields: card))
        XCTAssertTrue(CardsPageRules.matches("CHECKOUT", fields: card))
        XCTAssertTrue(CardsPageRules.matches("grey checkout", fields: card))     // every word, in any order
        XCTAssertTrue(CardsPageRules.matches("snap 灰", fields: card))            // across fields
        XCTAssertFalse(CardsPageRules.matches("grey invoice", fields: card))
        XCTAssertFalse(CardsPageRules.matches("发票", fields: card))
        XCTAssertFalse(CardsPageRules.matches("x", fields: [nil, nil]))
    }

    func testSearchIgnoresCaseAccentsAndWidth() {
        XCTAssertTrue(CardsPageRules.matches("cafe", fields: ["Café menu"]))
        XCTAssertTrue(CardsPageRules.matches("ＡＢＣ", fields: ["abc.pdf"]))
        XCTAssertEqual(CardsPageRules.terms("  Grey  CHECKOUT "), ["grey", "checkout"])
    }
}
