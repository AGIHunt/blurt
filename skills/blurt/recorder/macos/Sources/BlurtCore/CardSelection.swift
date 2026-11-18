// The Cards page's selection (BlurtApp MainWindow/CardsPage.swift): the Finder's and a table's rules, over the cards
// counted through the page's sections in order. Kept here, without AppKit, so it is tested.
//
//   click          that card alone; it becomes the anchor and the keyboard's card.
//   ⌘-click        that card in or out of the selection; it becomes the anchor.
//   ⇧-click        every card from the anchor to that one, added to what was selected before the anchor was set
//                  (a second ⇧-click replaces the first one's range, as in a table); the anchor stays.
//   ⇧-arrow        the same as a ⇧-click on the card the arrow goes to.
//   ⌘A             every card of a section (CardsPageRules.section).
// The keyboard's card (`focus`) is where the arrows start from and what Space previews; with several selected,
// Copy, Delete and a drag take all of them, in the order they show.

import Foundation

public struct CardSelection: Equatable {
    /// the selected cards, in the order they show
    public private(set) var picked: [Int] = []
    /// where a ⇧-click range starts
    public private(set) var anchor: Int?
    /// the keyboard's card: the last one clicked, ⌘-clicked, ⇧-clicked or moved to
    public private(set) var focus: Int?
    /// what was selected when the anchor was set (a ⇧-click range is added to it)
    private var base: [Int] = []

    public init() {}

    public var isEmpty: Bool { picked.isEmpty }
    public var count: Int { picked.count }
    public func contains(_ i: Int) -> Bool { picked.contains(i) }

    /// A click (or a plain arrow onto `i`): that card alone.
    public mutating func click(_ i: Int) {
        picked = [i]
        anchor = i
        focus = i
        base = []
    }

    /// ⌘-click: `i` in or out of the selection. Taken out, the keyboard's card is the nearest one still selected.
    public mutating func toggle(_ i: Int) {
        if let k = picked.firstIndex(of: i) {
            picked.remove(at: k)
            focus = picked.isEmpty ? nil : picked[min(k, picked.count - 1)]
            anchor = focus
        } else {
            picked = (picked + [i]).sorted()
            anchor = i
            focus = i
        }
        base = picked
    }

    /// ⇧-click (or ⇧-arrow onto `i`): every card from the anchor to `i`, added to what was selected before the anchor.
    /// No anchor yet: from `i` alone.
    public mutating func extend(to i: Int) {
        guard let a = anchor else { return click(i) }
        let range = Array(min(a, i)...max(a, i))
        picked = Array(Set(base + range)).sorted()
        focus = i
    }

    /// ⌘A: every card in `range`.
    public mutating func selectAll(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        picked = Array(range)
        anchor = range.lowerBound
        if focus.map({ !range.contains($0) }) ?? true { focus = range.lowerBound }
        base = []
    }

    /// The keyboard's card moves to `i`, one of the selection, which stays as it is (the preview stepping through it).
    public mutating func moveFocus(to i: Int) {
        guard picked.contains(i) else { return }
        focus = i
    }

    /// Esc, or the cards it held are gone.
    public mutating func clear() {
        self = CardSelection()
    }

    /// The same cards after the page was read again: `map` says where each one is now (nil: gone, or not showing).
    public func remapped(_ map: (Int) -> Int?) -> CardSelection {
        var s = CardSelection()
        s.picked = Array(Set(picked.compactMap(map))).sorted()
        s.base = Array(Set(base.compactMap(map))).sorted()
        s.anchor = anchor.flatMap(map)
        s.focus = focus.flatMap(map)
        if s.focus == nil, let first = s.picked.first { s.focus = first }
        if s.anchor == nil { s.anchor = s.focus }
        return s
    }

    /// What Copy, Delete and a drag take when `i` is acted on: the whole selection when `i` is part of it, else `i`
    /// alone (a card outside the selection goes by itself, as in the Finder).
    public func acted(on i: Int) -> [Int] {
        picked.contains(i) && picked.count > 1 ? picked : [i]
    }
}
