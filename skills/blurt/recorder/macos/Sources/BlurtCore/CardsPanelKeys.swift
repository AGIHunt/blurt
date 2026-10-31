// The Cards panel's rules, CardsPanelRules (BlurtApp CardsOverview.swift; docs/design/system.md §3.2): which segment ⌥H opens on, and
// what every key does in the panel and in its preview. Kept here, without AppKit, so they are tested.
//
//   ⌥H            opens the panel on Hanging — on Used when nothing hangs (it never opens empty while there is
//                 something to show); open already: it closes. Nothing at all: nothing opens (the island says so).
//   Tab           the other segment.
//   ← / →         no card focused: Hanging / Used (the segments' own order) — a card focused: the card before / after.
//   ↓             no card focused: the first card; else the card under it (the last row stays).
//   ↑             the card above; from the top row back to no card focused (the segments again).
//   Space         the big preview of the focused card (or the one under the pointer).
//   ↩ / ⌘C        copies the focused card and closes the panel (the keyboard back where the user was: ⌘V pastes).
//   ⌫ / ⌦         deletes the focused card (Undo in the island).
//   Esc / ⌘W      closes.
// In the preview: ← / → the card before / after it, Space or Esc back to the grid.

import Foundation

/// Which cards the Cards panel shows.
public enum CardsSegment: String, CaseIterable {
    /// the cards under the notch
    case hanging
    /// dragged out or pasted into another app in the last 7 days
    case used

    public var other: CardsSegment { self == .hanging ? .used : .hanging }
}

public enum CardsPanelKey: Equatable {
    case left, right, up, down, space, tab, enter, copy, delete, escape, close
}

public enum CardsPanelAction: Equatable {
    case segment(CardsSegment)
    /// the keyboard on card N; nil: on no card (the segments)
    case focus(Int?)
    case preview(Int)
    case copyAndClose(Int)
    case delete(Int)
    case close
    /// the key does nothing here (it is not swallowed)
    case none
}

public enum CardsPreviewAction: Equatable {
    /// the card N places before (−) or after (+) this one
    case step(Int)
    case close
    case none
}

public enum CardsPanelRules {
    /// ⌥H with the panel closed: the segment it opens on — Hanging while a card hangs, else Used — or nil when there is
    /// nothing in either.
    public static func openSegment(hanging: Int, used: Int) -> CardsSegment? {
        if hanging > 0 { return .hanging }
        return used > 0 ? .used : nil
    }

    public enum Toggle: Equatable {
        case open(CardsSegment)
        case close
        /// nothing to show: say so
        case nothing
    }

    /// ⌥H: opens the panel (on `openSegment`), or closes it when it is open.
    public static func toggle(isOpen: Bool, hanging: Int, used: Int) -> Toggle {
        if isOpen { return .close }
        return openSegment(hanging: hanging, used: used).map { .open($0) } ?? .nothing
    }

    /// What `key` does with the keyboard on the panel: `focus` the card it is on (nil: none), `count` cards showing in
    /// `columns`, `pointed` the card under the pointer (Space previews it when no card is focused).
    public static func action(_ key: CardsPanelKey, segment: CardsSegment, focus: Int?, count: Int, columns: Int,
                              pointed: Int? = nil) -> CardsPanelAction {
        let f = focus.flatMap { (0..<count).contains($0) ? $0 : nil }
        let cols = max(1, columns)
        switch key {
        case .tab: return .segment(segment.other)
        case .left:
            guard let i = f else { return segment == .hanging ? .none : .segment(.hanging) }
            return i > 0 ? .focus(i - 1) : .none
        case .right:
            guard let i = f else { return segment == .used ? .none : .segment(.used) }
            return i < count - 1 ? .focus(i + 1) : .none
        case .down:
            guard let i = f else { return count > 0 ? .focus(0) : .none }
            let lastRow = (count - 1) / cols
            return i / cols < lastRow ? .focus(min(i + cols, count - 1)) : .none
        case .up:
            guard let i = f else { return .none }
            return i - cols >= 0 ? .focus(i - cols) : .focus(nil)
        case .space:
            if let i = f ?? pointed.flatMap({ (0..<count).contains($0) ? $0 : nil }) { return .preview(i) }
            return .none
        case .enter, .copy: return f.map { .copyAndClose($0) } ?? .none
        case .delete: return f.map { .delete($0) } ?? .none
        case .escape, .close: return .close
        }
    }

    /// What `key` does with the keyboard on the preview.
    public static func previewAction(_ key: CardsPanelKey) -> CardsPreviewAction {
        switch key {
        case .left, .up: return .step(-1)
        case .right, .down: return .step(1)
        case .space, .escape, .close: return .close
        default: return .none
        }
    }
}
