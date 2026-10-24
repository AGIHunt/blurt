// The hanging cards' rules that don't need AppKit (BlurtApp Capture/Island/HangingCards.swift draws them,
// CardsOverview.swift lists them all): which cards hang and where, where their threads come out of the island, when they
// come down and go back up, the keyboard's stops, what the hover note adds, the deferred click, the first-card hint and
// the Undo window of a delete.
//
//  • the row (CardRow.layout): newest first, left to right — at most `maxShown` cards, and no wider than `maxWidth` (a
//    voice card is wider, so fewer of those hang); the rest wait behind a quiet "+N" tile at the row's end, which opens
//    the overview of every card. Centred under the island, never off the screen's edge. Nothing rotates the cards any
//    more: the order is always the time they were taken, newest first (Copy All and a ⌘-click selection too).
//  • the threads (CardRow.threadX): straight above their card while the row fits under the island; a wider row is
//    mapped onto the island's bottom edge in proportion, so the threads keep their order, never cross and hang close to
//    vertical — not a fan from the island's two corners.
//  • coming down (CardReveal): only after the pointer has rested on the island `dwell` (brushing past the notch on the
//    way to a menu drops nothing); up again `away` after it has left the cards' region. Esc is taken from the system
//    only while cards brought down on purpose have the pointer on them; with the keyboard on the cards their own panel
//    gets it.
//  • the hover note (CardTip): only what the card can't show itself — the rest of a note cut short on the card, and the
//    play button of a spoken one. Otherwise no note at all.
//  • a click (DeferredClick): a plain click copies once the double-click interval has passed; a second click (double-click
//    = edit the note) cancels it, so editing never overwrites the clipboard first.

import CoreGraphics

public enum CardRow {
    /// At most this many cards hang side by side; the others wait behind the "+N" tile.
    public static let maxShown = 5
    /// …and the row (with the tile) is never wider than this.
    public static let maxWidth: CGFloat = 780

    public struct Layout: Equatable {
        /// Indices into the cards (kept oldest first) in the order they hang, left to right: newest first.
        public var shown: [Int]
        /// Each shown card's centre x, in the same order.
        public var centres: [CGFloat]
        /// The cards that don't hang: the "+N" tile's count (0: no tile).
        public var more: Int
        /// The tile's centre x (at the row's end, after the oldest card that hangs); nil without one.
        public var tileX: CGFloat?

        /// From the left edge of the first item to the right edge of the last (the tile included).
        public var span: ClosedRange<CGFloat>

        public static let empty = Layout(shown: [], centres: [], more: 0, tileX: nil, span: 0...0)
    }

    /// `widths`: every card's width, oldest first. `tile`: the "+N" tile's width. `bounds`: where the row may go (the
    /// screen less its margins).
    public static func layout(widths: [CGFloat], tile: CGFloat, gap: CGFloat, centre: CGFloat, bounds: ClosedRange<CGFloat>,
                              maxShown: Int = maxShown, maxWidth: CGFloat = maxWidth) -> Layout {
        guard !widths.isEmpty else { return .empty }
        let room = min(maxWidth, bounds.upperBound - bounds.lowerBound)
        func width(_ n: Int) -> CGFloat {
            let cards = widths.suffix(n).reduce(0, +) + gap * CGFloat(max(0, n - 1))
            return cards + (widths.count > n ? gap + tile : 0)
        }
        var n = min(widths.count, max(1, maxShown))
        while n > 1, width(n) > room { n -= 1 }
        let shown = Array((widths.count - n ..< widths.count).reversed())          // newest first
        let total = width(n)
        // centred on the island, but never off the screen's edge
        var x = min(max(centre - total / 2, bounds.lowerBound), max(bounds.lowerBound, bounds.upperBound - total))
        let left = x
        var centres: [CGFloat] = []
        for i in shown {
            centres.append(x + widths[i] / 2)
            x += widths[i] + gap
        }
        let more = widths.count - n
        return Layout(shown: shown, centres: centres, more: more, tileX: more > 0 ? x + tile / 2 : nil, span: left...(left + total))
    }

    /// Where the thread of a card at `x` comes out of the island's bottom edge (`edge`: the part of it a thread may
    /// leave from), given the whole row's `span`.
    public static func threadX(_ x: CGFloat, row: ClosedRange<CGFloat>, edge: ClosedRange<CGFloat>) -> CGFloat {
        let rw = row.upperBound - row.lowerBound, ew = edge.upperBound - edge.lowerBound
        guard rw > ew, rw > 0 else { return min(max(x, edge.lowerBound), edge.upperBound) }
        let k = (x - row.lowerBound) / rw
        return min(max(edge.lowerBound + k * ew, edge.lowerBound), edge.upperBound)
    }
}

public enum CardReveal {
    /// The pointer rests on the island this long before the cards come down (the island opens after the same time).
    public static let dwell: Double = 0.18
    /// They go back up this long after the pointer has left their region.
    public static let away: Double = 0.25

    /// Whether the pointer, on the island since `since` (nil: not on it), has rested there long enough.
    public static func dwelled(since: Double?, now: Double) -> Bool { since.map { now - $0 >= dwell } ?? false }

    /// Esc is ours (a system-wide hotkey) only while cards brought down on purpose have the pointer on them; with the
    /// keyboard on the cards their panel has it already, and otherwise Esc belongs to whatever app is in front.
    public static func holdsEsc(sticky: Bool, pointerIn: Bool, keyboard: Bool) -> Bool { sticky && pointerIn && !keyboard }

    /// The first card ever says what to do with it, once.
    public static func firstHint(alreadyShown: Bool, isCard: Bool, recording: Bool) -> Bool { !alreadyShown && isCard && !recording }
}

/// The keyboard's stops along the row: the cards (0 = the newest) and then the "+N" tile.
public enum CardFocus {
    /// ←/→ (Tab, ⇧Tab): the next stop, staying at the ends. nil (nothing focused yet) starts at the newest card.
    public static func move(_ i: Int?, by d: Int, cards: Int, tile: Bool) -> Int? {
        let stops = cards + (tile ? 1 : 0)
        guard stops > 0 else { return nil }
        guard let i = i else { return 0 }
        return min(max(i + d, 0), stops - 1)
    }

    /// After the focused card left the row (deleted, taken): the same place, or the last stop.
    public static func clamp(_ i: Int?, cards: Int, tile: Bool) -> Int? {
        let stops = cards + (tile ? 1 : 0)
        guard let i = i, stops > 0 else { return nil }
        return min(i, stops - 1)
    }
}

public enum CardTip {
    public struct Content: Equatable {
        public var text: Bool
        public var play: Bool
        public init(text: Bool, play: Bool) { self.text = text; self.play = play }
    }

    /// What the note under a hovered card shows: the whole note when the card cuts it short, and the play button when
    /// there is a recording to hear. nil: nothing the card doesn't already say — no note.
    public static func content(truncated: Bool, playable: Bool) -> Content? {
        truncated || playable ? Content(text: truncated, play: playable) : nil
    }
}

/// A plain click copies, but only once the double-click interval has passed; a second click cancels it (a double-click
/// edits the note), so the clipboard is never overwritten on the way to editing.
public struct DeferredClick<ID: Equatable> {
    public enum Outcome: Equatable {
        case copy(at: Double)       // copy then, unless a second click comes first
        case edit
    }

    public private(set) var pending: ID?
    public private(set) var due: Double = 0

    public init() {}

    public mutating func click(_ id: ID, count: Int, at t: Double, interval: Double) -> Outcome {
        if count >= 2 { pending = nil; return .edit }
        pending = id
        due = t + interval
        return .copy(at: due)
    }

    /// The click whose copy is due at `t` (once), if any.
    public mutating func fire(at t: Double) -> ID? {
        guard let id = pending, t >= due else { return nil }
        pending = nil
        return id
    }

    public mutating func cancel() { pending = nil }
}

/// Delete (a card's ×, its menu, ⌫) and Delete All: no question first, an Undo instead. The files stay where they are a
/// moment longer than the Undo is offered, so Undo never has to fetch them back from the Trash.
public enum CardDelete {
    public static let undoSeconds: Double = 5
    public static let recycleAfter: Double = undoSeconds + 2
}
