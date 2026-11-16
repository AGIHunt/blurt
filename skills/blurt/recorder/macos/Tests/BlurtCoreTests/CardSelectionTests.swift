import XCTest
@testable import BlurtCore

/// The Cards page's selection (CardSelection.swift): click, ⌘-click, ⇧-click, ⌘A, as in the Finder and a table.
final class CardSelectionTests: XCTestCase {
    func testClickSelectsOneCard() {
        var s = CardSelection()
        XCTAssertTrue(s.isEmpty)
        s.click(3)
        XCTAssertEqual(s.picked, [3])
        XCTAssertEqual(s.focus, 3)
        XCTAssertEqual(s.anchor, 3)
        s.click(1)
        XCTAssertEqual(s.picked, [1])
    }

    func testCommandClickTogglesAndKeepsShowingOrder() {
        var s = CardSelection()
        s.click(4)
        s.toggle(1)
        s.toggle(6)
        XCTAssertEqual(s.picked, [1, 4, 6])
        XCTAssertEqual(s.focus, 6)
        s.toggle(4)
        XCTAssertEqual(s.picked, [1, 6])
        XCTAssertEqual(s.focus, 6)                  // the nearest one still selected
        s.toggle(1); s.toggle(6)
        XCTAssertTrue(s.isEmpty)
        XCTAssertNil(s.focus)
    }

    func testShiftClickSelectsARangeFromTheAnchor() {
        var s = CardSelection()
        s.click(2)
        s.extend(to: 5)
        XCTAssertEqual(s.picked, [2, 3, 4, 5])
        XCTAssertEqual(s.anchor, 2)
        XCTAssertEqual(s.focus, 5)
        // a second ⇧-click replaces the first one's range
        s.extend(to: 0)
        XCTAssertEqual(s.picked, [0, 1, 2])
    }

    func testShiftClickAddsToACommandClickSelection() {
        var s = CardSelection()
        s.click(0)
        s.toggle(5)             // anchor 5, with 0 kept
        s.extend(to: 7)
        XCTAssertEqual(s.picked, [0, 5, 6, 7])
    }

    func testShiftWithNothingSelectedIsAClick() {
        var s = CardSelection()
        s.extend(to: 3)
        XCTAssertEqual(s.picked, [3])
        XCTAssertEqual(s.anchor, 3)
    }

    func testShiftArrowsExtendOneCardAtATime() {
        var s = CardSelection()
        s.click(2)
        s.extend(to: 3)
        s.extend(to: 4)
        XCTAssertEqual(s.picked, [2, 3, 4])
        s.extend(to: 3)         // back again: the range shrinks
        XCTAssertEqual(s.picked, [2, 3])
    }

    func testSelectAllTakesTheSection() {
        var s = CardSelection()
        s.click(5)
        s.selectAll(3..<7)
        XCTAssertEqual(s.picked, [3, 4, 5, 6])
        XCTAssertEqual(s.focus, 5)              // the keyboard stays where it was, inside the section
        s.selectAll(0..<3)
        XCTAssertEqual(s.focus, 0)
        s.selectAll(0..<0)
        XCTAssertEqual(s.picked, [0, 1, 2])     // an empty section changes nothing
    }

    func testRemapFollowsTheCardsAndDropsTheGone() {
        var s = CardSelection()
        s.click(1)
        s.toggle(3)
        s.toggle(5)
        // card 3 was deleted: 4 → 3, 5 → 4
        let r = s.remapped { $0 == 3 ? nil : $0 > 3 ? $0 - 1 : $0 }
        XCTAssertEqual(r.picked, [1, 4])
        XCTAssertEqual(r.focus, 4)
        // the focused card gone: the first still selected
        let r2 = s.remapped { $0 == 5 ? nil : $0 }
        XCTAssertEqual(r2.picked, [1, 3])
        XCTAssertEqual(r2.focus, 1)
        XCTAssertTrue(s.remapped { _ in nil }.isEmpty)
    }

    func testFocusMovesInsideTheSelectionOnly() {
        var s = CardSelection()
        s.click(1)
        s.toggle(4)
        s.moveFocus(to: 1)
        XCTAssertEqual(s.focus, 1)
        XCTAssertEqual(s.picked, [1, 4])
        s.moveFocus(to: 3)                      // not selected: nothing moves
        XCTAssertEqual(s.focus, 1)
    }

    func testActingOnACardOutsideTheSelectionTakesItAlone() {
        var s = CardSelection()
        s.click(1)
        s.toggle(2)
        XCTAssertEqual(s.acted(on: 2), [1, 2])
        XCTAssertEqual(s.acted(on: 4), [4])
        s.click(4)
        XCTAssertEqual(s.acted(on: 4), [4])
    }
}
