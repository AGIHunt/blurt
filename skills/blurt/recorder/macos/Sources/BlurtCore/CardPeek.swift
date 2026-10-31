// BlurtCore/CardPeek.swift: the bigger picture under a hovered hanging card. The cards are small, so pictures
// that look alike are hard to tell apart; the row stays still (growing the hovered card made its neighbours shift) and
// the hover note under the row shows the card's picture, larger, under its words: one surface, text then picture.
//
//  • CardPeek — when: after the pointer has rested on a card for `rest` (0.3 s), so sweeping across the row flashes
//    nothing; once it shows, another card on the row switches it at once (warm, as tooltips do), and a gap between
//    two cards keeps the last one rather than blinking. Off the row it is gone at once and the next one waits again.
//  • CardPeekLayout — where and how big: the picture at its own size in points, at most half the visible screen's width
//    and half its height (a quarter of it: a full-screen snap shows its details, so several that look alike can be
//    told apart), nor taller than the room under the row; never enlarged (a small snap stays sharp), aspect kept.
//    Sizes differ from card to card — each picture is as large as it usefully gets (1.0.7: 360 pt / 40 % was too small
//    for a full-screen snap). The surface is centred on the hovered card's x where it fits, else kept `edge` from the
//    screen's sides.
//  • CardPeekLayout.entrance — how it arrives: a 0.15 s fade with a slight grow (0.97 → 1); with Reduce Motion the fade
//    alone. A warm switch has no entrance: the content changes in place.
import CoreGraphics

public struct CardPeek<ID: Equatable>: Equatable {
    /// How long the pointer rests on a card before its preview shows (a cold start).
    public static var rest: Double { 0.3 }

    /// The card under the pointer, or the last one while the pointer crosses a gap on the row after a preview showed.
    public private(set) var card: ID?
    /// When the pointer came onto `card`.
    public private(set) var since: Double = 0
    /// A preview has shown since the pointer came onto the row: the next card shows at once.
    public private(set) var warm = false

    public init() {}

    /// The pointer moved: `on` is the card under it (nil: between cards, on the tile, off the row), `onRow` whether it
    /// is still on the row (the cards' band, its gaps included; the keyboard on a card counts as on it).
    public mutating func pointer(on new: ID?, onRow: Bool, now: Double) {
        guard onRow else { self = CardPeek(); return }          // left the row: gone at once, and cold again
        if card != nil, now - since >= Self.rest { warm = true }
        guard let new else {
            if !warm { card = nil }                             // a gap before anything showed: the wait starts over
            return
        }
        guard new != card else { return }
        card = new
        since = now
    }

    /// The card whose preview shows now, if any.
    public func shown(now: Double) -> ID? {
        guard let card else { return nil }
        return warm || now - since >= Self.rest ? card : nil
    }

    /// A card is waiting out its rest (the caller keeps its clock running until it shows).
    public func waiting(now: Double) -> Bool { card != nil && !warm && now - since < Self.rest }
}

public enum CardPeekLayout {
    /// The largest the picture gets: this share of the visible screen's width, and of its height.
    public static let screenShare: CGFloat = 0.5
    /// Under this height there is no room worth a picture: none (the words still show).
    public static let minHeight: CGFloat = 48
    /// The surface keeps this far from the screen's sides.
    public static let edge: CGFloat = 12
    /// The entrance's length (seconds) and how small it starts without Reduce Motion.
    public static let entranceSeconds: Double = 0.15
    public static let entranceScale: CGFloat = 0.97

    /// The picture's size in points: `picture` (its own size in points: pixels ÷ the display's scale) fitted inside
    /// `screenShare` of `screen` (the visible screen's size) and `room` (the height left under the row and the words),
    /// aspect kept, never enlarged. nil: no picture, or too little room for one.
    public static func size(picture: CGSize, screen: CGSize, room: CGFloat = .greatestFiniteMagnitude) -> CGSize? {
        guard picture.width > 0, picture.height > 0 else { return nil }
        let maxW = screen.width * screenShare, maxH = min(screen.height * screenShare, room)
        guard maxH >= minHeight, maxW >= minHeight else { return nil }
        let k = min(1, maxW / picture.width, maxH / picture.height)
        let s = CGSize(width: (picture.width * k).rounded(.down), height: (picture.height * k).rounded(.down))
        return s.width >= 1 && s.height >= 1 ? s : nil
    }

    /// The surface's centre x: under the hovered card (`card`) where it fits, else as near as `edge` from the sides of
    /// `screen` allows (the screen's middle if it is wider than the screen).
    public static func centreX(card: CGFloat, width: CGFloat, screen: ClosedRange<CGFloat>) -> CGFloat {
        let lo = screen.lowerBound + edge + width / 2, hi = screen.upperBound - edge - width / 2
        guard lo <= hi else { return (screen.lowerBound + screen.upperBound) / 2 }
        return min(max(card, lo), hi)
    }

    /// The entrance at `elapsed` seconds after it began: (opacity, scale). Reduce Motion: a fade, never a scale.
    public static func entrance(elapsed: Double, reduceMotion: Bool) -> (opacity: CGFloat, scale: CGFloat) {
        let k = CGFloat(max(0, min(1, elapsed / entranceSeconds)))
        let eased = 1 - (1 - k) * (1 - k) * (1 - k)
        return (eased, reduceMotion ? 1 : entranceScale + (1 - entranceScale) * eased)
    }
}
