// The Cards page's rules (BlurtApp MainWindow/CardsPage.swift; docs/design/capabilities.md): the main window's page
// of every card — Current (under the notch) then History (used in other apps) — as one grid in two sections.
// Kept here, without AppKit, so they are tested: how many columns fit, what each key does with the keyboard on the
// grid, and which cards a search shows.
//
// With ⇧ the arrows extend the selection (CardSelection); ↩, ⌘C and ⌫ act on every selected card; ⌘A selects the
// focused card's section (`section`). ⌥H in the window's terms: `hotkey`.
//
//   ← / →         the card before / after, across the two sections (no card focused: → goes to the first).
//   ↓             the card under it; from a section's last row, the next section's first row in the same column
//                 (no card focused: the first card).
//   ↑             the card above; from a section's first row, the section before's last row in the same column; from
//                 the very first row, back to the search field.
//   Space         the big preview of the focused card (or the one under the pointer).
//   ↩ / ⌘C        copies the focused card (the page stays: it is a place to browse, not a panel over another app).
//   ⌫ / ⌦         deletes the focused card (Undo in the island); the keyboard stays where it was.
//   Esc           clears the search, when there is one; else lets go of the focused card.
// Tab and ⌘W are the window's.

import Foundation

public enum CardsPageAction: Equatable {
    /// the keyboard on card N (counted through the sections in order)
    case focus(Int)
    /// back to the search field
    case search
    case preview(Int)
    case copy(Int)
    case delete(Int)
    case clearSearch
    /// no card focused any more
    case deselect
    /// the key does nothing here (it is not swallowed)
    case none
}

public enum CardsPageRules {
    /// A tile's picture at its smallest (the Cards panel's 148 × 100) and the gap between two.
    public static let tileWidth: Double = 148
    public static let tileHeight: Double = 100
    public static let gap: Double = 12

    /// How many tiles fit a row `width` wide — never none.
    public static func columns(width: Double, tile: Double = tileWidth, gap: Double = gap) -> Int {
        max(1, Int(((width + gap) / (tile + gap)).rounded(.down)))
    }

    /// A row `width` wide: as many tiles as fit at the panel's size, each then widened (whole points; its picture keeps
    /// 148 : 100) so the row fills the width — the grid ends where the page's column does, at any window size.
    public static func tile(width: Double) -> (columns: Int, width: Double, height: Double) {
        let cols = columns(width: width)
        let w = max(tileWidth, ((width - Double(cols - 1) * gap) / Double(cols)).rounded(.down))
        return (cols, w, (w * tileHeight / tileWidth).rounded())
    }

    /// Where card `i` is: its section, the first card of that section, its row and column there.
    static func place(_ i: Int, sections: [Int], columns: Int) -> (section: Int, start: Int, row: Int, col: Int)? {
        var start = 0
        for (s, n) in sections.enumerated() {
            if i < start + n { return (s, start, (i - start) / columns, (i - start) % columns) }
            start += n
        }
        return nil
    }

    /// What `key` does with the keyboard on the grid: `focus` the card it is on (nil: none), `sections` how many cards
    /// each section shows (in order), `columns` in a row, `pointed` the card under the pointer, `searching` a search
    /// is typed.
    public static func action(_ key: CardsPanelKey, focus: Int?, sections: [Int], columns: Int, pointed: Int? = nil,
                              searching: Bool = false) -> CardsPageAction {
        let count = sections.reduce(0, +)
        let f = focus.flatMap { (0..<count).contains($0) ? $0 : nil }
        let cols = max(1, columns)
        switch key {
        case .left:
            guard let i = f else { return .none }
            return i > 0 ? .focus(i - 1) : .none
        case .right:
            guard let i = f else { return count > 0 ? .focus(0) : .none }
            return i < count - 1 ? .focus(i + 1) : .none
        case .down:
            guard let i = f, let p = place(i, sections: sections, columns: cols) else { return count > 0 ? .focus(0) : .none }
            let n = sections[p.section]
            if p.row < (n - 1) / cols { return .focus(p.start + min((p.row + 1) * cols + p.col, n - 1)) }
            // the next section that shows a card: its first row, the same column
            var start = p.start + n
            for m in sections[(p.section + 1)...] {
                if m > 0 { return .focus(start + min(p.col, m - 1)) }
                start += m
            }
            return .none
        case .up:
            guard let i = f, let p = place(i, sections: sections, columns: cols) else { return .search }
            if p.row > 0 { return .focus(p.start + (p.row - 1) * cols + p.col) }
            // the section before that shows a card: its last row, the same column
            var end = p.start
            for m in sections[..<p.section].reversed() {
                if m > 0 { return .focus(end - m + min(((m - 1) / cols) * cols + p.col, m - 1)) }
                end -= m
            }
            return .search
        case .space:
            if let i = f ?? pointed.flatMap({ (0..<count).contains($0) ? $0 : nil }) { return .preview(i) }
            return .none
        case .enter, .copy: return f.map { .copy($0) } ?? .none
        case .delete: return f.map { .delete($0) } ?? .none
        case .escape: return searching ? .clearSearch : f != nil ? .deselect : .none
        case .tab, .close: return .none
        }
    }

    /// Where the keyboard is after card `i` of `count` was deleted: the card that took its place, the last one when
    /// it was the last, none when it was the only one.
    public static func focusAfterDelete(_ i: Int, count: Int) -> Int? {
        count <= 1 ? nil : min(i, count - 2)
    }

    /// Where the keyboard is after the cards at `deleted` (of `count`) went: the card that took the first one's place,
    /// the last one left when they were the last, none when nothing is left.
    public static func focusAfterDelete(_ deleted: [Int], count: Int) -> Int? {
        let gone = Set(deleted.filter { (0..<count).contains($0) })
        guard let first = gone.min() else { return nil }
        let left = count - gone.count
        return left <= 0 ? nil : min(first, left - 1)
    }

    /// The cards of the section card `i` is in (indices counted through the sections in order); no card: the first
    /// section that shows one. ⌘A selects these.
    public static func section(of i: Int?, sections: [Int]) -> Range<Int>? {
        var start = 0
        var firstShown: Range<Int>?
        for n in sections {
            let r = start..<(start + n)
            if let i, r.contains(i) { return r }
            if firstShown == nil, n > 0 { firstShown = r }
            start += n
        }
        return i == nil ? firstShown : nil
    }

    /// ⌥H, in the main window's terms: the window is key and on the Cards page — hide it again (the keyboard back to
    /// the app the user was in); anywhere else — bring it forward on the Cards page.
    public enum Hotkey: Equatable {
        case open
        case hide
    }

    public static func hotkey(windowKey: Bool, onCards: Bool) -> Hotkey {
        windowKey && onCards ? .hide : .open
    }

    /// The search as typed, in words: letter case, accents and full-width forms don't count.
    public static func terms(_ query: String) -> [String] {
        fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// A card shows for `query` when every word of it is somewhere in the card's `fields` (its note, its name, the
    /// file it refers to). An empty search shows every card.
    public static func matches(_ query: String, fields: [String?]) -> Bool {
        let words = terms(query)
        guard !words.isEmpty else { return true }
        let hay = fields.compactMap { $0 }.map(fold)
        return words.allSatisfy { w in hay.contains { $0.contains(w) } }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
