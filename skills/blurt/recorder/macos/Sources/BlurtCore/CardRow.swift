// The hanging cards' rules that don't need AppKit (BlurtApp Capture/Island/HangingCards.swift draws them,
// CardsOverview.swift lists them all): which cards hang and where, where their threads come out of the island, when they
// come down and go back up, the keyboard's stops, what the hover note adds, the deferred click, the first-card hint and
// the Undo window of a delete.
//
//  • the row (CardRow.layout): newest first, left to right — at most `maxShown` cards, and no wider than `maxWidth` (a
//    voice card is wider, so fewer of those hang); the rest wait behind a quiet "+N" tile at the row's end, which opens
//    the overview of every card. A "+1" tile never stands in for a card that would fit: when only one would wait
//    behind it, there is room for one more under `maxShown`, and every card fits in the room the tile row may take
//    (`maxWidth` plus the tile), all of them hang — five snaps of
//    150 pt are 798 pt, and the dogfood saw four and a "+1" the size of the card it hid. Centred under the island,
//    never off the screen's edge. Nothing rotates the cards any
//    more: the order is always the time they were taken, newest first (Copy All and a ⌘-click selection too).
//  • the threads (CardRow.threadX): straight above their card while the row fits under the island; a wider row is
//    mapped onto the island's bottom edge in proportion, so the threads keep their order, never cross and hang close to
//    vertical — not a fan from the island's two corners.
//  • the band (CardRow.panelTop): the strip under the island the cards hang in. Recently Dragged Out and the cards'
//    overview open below it, so a card hung back (Put Back, Undo) or brought down by the pointer never covers them;
//    with no card hanging, right under the island (and down below the band once Put Back hangs one).
//  • coming down (CardReveal): only after the pointer has rested on the island `dwell` (brushing past the notch on the
//    way to a menu drops nothing); up again `away` after it has left the cards' region. Brought down on purpose (the
//    ear, ⌥H, the menu, the main window) they stay until the pointer has been on them and left — or, if it never
//    comes, `unvisited` after. Esc is taken from the system only while such cards have the pointer on them, or for
//    `escGrace` after they came down with the pointer elsewhere; with the keyboard on the cards their own panel gets it.
//  • the hover note (CardTip): only what the card can't show itself — the rest of a note cut short on the card, and the
//    play button of a spoken one. Otherwise no note at all.
//  • a click (DeferredClick): a plain click copies once the double-click interval has passed; a second click (double-click
//    = edit the note) cancels it, so editing never overwrites the clipboard first.
//  • a delete (CardDelete, CardUndo): no question, an Undo — and deletes in a row gather under that one Undo, so
//    Undo brings back every card deleted while it was offered.

import CoreGraphics
import Foundation

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
        // no "+1" for a card that fits: the one card it would hide hangs instead, in the room the tile row may take
        let screen = bounds.upperBound - bounds.lowerBound
        if widths.count == n + 1, n + 1 <= max(1, maxShown), width(n + 1) <= min(screen, room + gap + tile) { n += 1 }
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

    /// How far under the island's bottom edge the cards reach: the shortest thread (`below`), the longest slack, a
    /// card at its tallest (`cardHeight`), and the "Copied" pill or first-card hint under it (`under`).
    public static func bandDepth(below: CGFloat, slacks: [CGFloat], cardHeight: CGFloat, under: CGFloat = 30) -> CGFloat {
        below + (slacks.max() ?? 0) + cardHeight + under
    }

    /// The top edge (screen points, y up) of a panel that opens under the cards — Recently Dragged Out, the overview:
    /// below the band whether the cards are down or not, so ones hung back later never cover its title or rows. With
    /// no card hanging at all (`cardsHang` false) right under the island instead — 150 pt down it read as a window
    /// of its own; Put Back then moves it below the band as the card hangs again (TakenPanel).
    public static func panelTop(islandBottom: CGFloat, band: CGFloat, cardsHang: Bool = true, gap: CGFloat = 12) -> CGFloat {
        islandBottom - (cardsHang ? band : 0) - gap
    }

    /// Whether the row hangs from a rod (v0.9.1): some card's (or the tile's) clasp, at `centres`, is not under the
    /// island's `edge` — a thread to it would run nearly flat from the island (the fan the judges read as tent ropes).
    /// Then a short rod under the island spans the row, held by two stems, and every card hangs straight down from it.
    public static func rodded(centres: [CGFloat], edge: ClosedRange<CGFloat>, tolerance: CGFloat = 1) -> Bool {
        centres.contains { $0 < edge.lowerBound - tolerance || $0 > edge.upperBound + tolerance }
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

/// v0.9.2: the row hangs from the island itself, never from a drawn diagram (the stems-and-rod read as an org chart).
public extension CardRow {
    /// The lip (a row wider than the island): a 3 pt band of the island's own black, flush under its bottom edge,
    /// centred on the island, as wide as the outermost clasps plus `overhang` each side (never narrower than the
    /// island). nil while every clasp is under the island's `edge`: then each thread leaves the island itself.
    static func lip(clasps: [CGFloat], edge: ClosedRange<CGFloat>, island: ClosedRange<CGFloat>, overhang: CGFloat = 8) -> ClosedRange<CGFloat>? {
        guard rodded(centres: clasps, edge: edge), !clasps.isEmpty else { return nil }
        let centre = (island.lowerBound + island.upperBound) / 2
        let half = max((island.upperBound - island.lowerBound) / 2, clasps.map { abs($0 - centre) }.max()! + overhang)
        return (centre - half)...(centre + half)
    }

    /// Making room for a lifted card (hovered, or holding the keyboard): every item left of it moves `by` to the left,
    /// every item right of it — the "+N" tile included (it is the last item) — `by` to the right, so the lifted card's
    /// growth comes out of a reserved budget and no gap anywhere drops below the row's own.
    static func stepAside(items: Int, lifted: Int?, by: CGFloat) -> [CGFloat] {
        (0..<max(0, items)).map { i in
            guard let h = lifted, h < items, i != h else { return 0 }
            return i < h ? -by : by
        }
    }
}

/// The overview's grid (v0.9.2): one row up to 4 cards, then half of them a row (rounded up), at most 4 — 5 = 3 + 2,
/// 6 = 3 + 3, 7 = 4 + 3, never a lone orphan under two full rows.
public enum CardGrid {
    public static func columns(_ n: Int) -> Int { n <= 4 ? max(1, n) : min(4, (n + 1) / 2) }
}

/// A one-line band (a card's note): the longest run of whole words that fits — never cut mid-word and never an "…";
/// the band fades out its end when there is more (the hover note has all of it).
public enum CardBand {
    /// `fits`: whether a string fits the band. Returns the text to draw and whether some of it was left out.
    public static func clamp(_ text: String, fits: (String) -> Bool) -> (text: String, clipped: Bool) {
        let t = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if fits(t) { return (t, false) }
        var ends: [String.Index] = []
        t.enumerateSubstrings(in: t.startIndex..<t.endIndex, options: [.byWords, .substringNotRequired]) { _, r, _, _ in ends.append(r.upperBound) }
        var best: String?
        for e in ends {
            let s = String(t[..<e]).trimmingCharacters(in: .whitespaces)
            if fits(s) { best = s } else { break }
        }
        if let b = best, !b.isEmpty { return (b, true) }
        // one word longer than the band (a URL): as many characters as fit
        var out = ""
        for ch in t { if fits(out + String(ch)) { out.append(ch) } else { break } }
        return (out, true)
    }
}

/// How long ago, for the cards' panels (v0.9.2: one formatter for the overview and Recently Dragged Out): "Just now"
/// under a minute, then minutes, hours, "Yesterday", days — never a live count of seconds.
public enum CardAgo: Equatable {
    case justNow, minutes(Int), hours(Int), yesterday, days(Int)

    public static func of(_ seconds: Double) -> CardAgo {
        let s = max(0, seconds)
        if s < 60 { return .justNow }
        if s < 3600 { return .minutes(Int(s / 60)) }
        if s < 86_400 { return .hours(Int(s / 3600)) }
        let d = Int(s / 86_400)
        return d == 1 ? .yesterday : .days(d)
    }
}

public enum CardReveal {
    /// The pointer rests on the island this long before the cards come down (the island opens after the same time).
    public static let dwell: Double = 0.18
    /// They go back up this long after the pointer has left their region.
    public static let away: Double = 0.25

    /// Whether the pointer, on the island since `since` (nil: not on it), has rested there long enough.
    public static func dwelled(since: Double?, now: Double) -> Bool { since.map { now - $0 >= dwell } ?? false }

    /// Brought down on purpose with the pointer elsewhere (the menu, the main window): Esc sends them up this long,
    /// before the pointer has come to them.
    public static let escGrace: Double = 4
    /// …and if the pointer never comes to them, they stop staying down this long after (then they go up like any time
    /// the pointer isn't on them): never a curtain over the top of the screen.
    public static let unvisited: Double = 10

    /// Whether cards brought down on purpose stay down: until the pointer has been on them (`visited`) and left them
    /// and the island (`pointerIn`) — or, if it never came, `unvisited` after the reveal.
    public static func staysDown(visited: Bool, pointerIn: Bool, sinceReveal: Double) -> Bool {
        visited ? pointerIn : sinceReveal < unvisited
    }

    /// Esc is ours (a system-wide hotkey) only while cards brought down on purpose have the pointer on them (or the
    /// island), or just came down with it elsewhere (`escGrace`). With the keyboard on the cards (or the overview) their
    /// panel has it already, and otherwise Esc belongs to whatever app is in front.
    public static func holdsEsc(sticky: Bool, pointerIn: Bool, keyboard: Bool, visited: Bool, sinceReveal: Double) -> Bool {
        sticky && !keyboard && (pointerIn || (!visited && sinceReveal < escGrace))
    }

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

/// Deletes in a row gather under one Undo: while the Undo of the last delete is still offered, the next one joins it
/// ("Deleted 2 cards · Undo") and Undo brings back every one of them — never only the first.
public struct CardUndo<Item: AnyObject> {
    public private(set) var items: [Item] = []

    public init() {}

    /// `live`: the Undo of the earlier ones is still offered (else they are gone for good and this starts afresh).
    /// Returns everything the Undo now covers, in the order they were deleted.
    public mutating func add(_ new: [Item], live: Bool) -> [Item] {
        if !live { items = [] }
        for i in new where !items.contains(where: { $0 === i }) { items.append(i) }
        return items
    }

    /// Undo: everything it covers, once.
    public mutating func take() -> [Item] {
        defer { items = [] }
        return items
    }
}
