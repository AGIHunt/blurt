// The island's geometry rules that don't need AppKit (BlurtApp Capture/Island/Island.swift, IslandContent.swift,
// Ears.swift, HangingCards.swift and Capture/LiveTranscript.swift draw them).
//
//  • the ears (IslandLayout.earOrigin): each ear's content sits against the island's *outer* edge, `earInset` in, in
//    both shapes — the notch's ears and the capsule — so a glyph keeps one leading x and a number one trailing x
//    through listening, transcribing, polishing and idle (the dogfood found them centred in their 56 pt ear, so the
//    mint glyph jumped 12 pt at the stop tap). Content wider than the ear gives up the inset before it slides under
//    the notch.
//  • a toast (IslandLayout.toast): its content box is never narrower than the shape it shows in (the notch plus both
//    ears, or 260 pt on a capsule), so the text starts 18 pt in — the island rows' side inset — and an action button
//    ends `earInset` from the right edge, under the right ear's number; a line with nothing beside it is centred.
//  • time left (IslandLayout.timeLeft): rounded up, so the clock and the time left always add up to the limit.
//  • the live-text panel (IslandLayout.livePanelWidth): the island's lower half, not a second pop-up — as wide as
//    the island when it is open (a voice note), else a little wider than its ears, in one width family; the width
//    is the island's without a toast (one during a take never re-wraps the words). On a capsule (no notch) the
//    island itself widens to `liveCapsuleWidth` while live text shows, so the pair is the notch's proportions there
//    too, and the panel's corners are the capsule's (15; under the notch 14, under the open island 22).
//  • a snap's card (CardShape): 84 pt high, as wide as its picture wants within 84…150 pt; a picture too wide or
//    too tall for that is shown whole (letterboxed on the card's surface), never as a blown-up slice of its middle.
import CoreGraphics

public enum IslandLayout {
    public static let earWidth: CGFloat = 56
    /// The ears' content and a toast's button keep this far from the island's outer edges.
    public static let earInset: CGFloat = 14
    /// A toast's text starts here (the island rows' 18 pt side inset).
    public static let toastInset: CGFloat = 18
    /// A toast on a capsule (no notch) is at least this wide.
    public static let capsuleToastWidth: CGFloat = 260

    public enum Side { case left, right }

    /// Where an ear's content (`width` wide) starts, in the island's coordinates: `outer` is the island's outer edge
    /// on that side (its minX for the left ear, its maxX for the right), `inner` the notch's edge on that side (nil on
    /// a capsule: nothing to slide under).
    public static func earOrigin(_ side: Side, width: CGFloat, outer: CGFloat, inner: CGFloat?) -> CGFloat {
        var inset = earInset
        if let n = inner {
            let room = abs(n - outer) - 2            // keep 2 pt clear of the notch
            inset = max(2, min(earInset, room - width))
        }
        return side == .left ? outer + inset : outer - inset - width
    }

    /// The narrowest a toast's shape is: the notch with both ears, or the capsule's minimum.
    public static func toastFloor(notchWidth: CGFloat?) -> CGFloat {
        notchWidth.map { $0 + 2 * earWidth } ?? capsuleToastWidth
    }

    public struct Toast: Equatable {
        /// The content box's width (= the shape's, between the floor and `maxWidth`).
        public var width: CGFloat
        /// Where the leading group (icon / badge, then the text) starts.
        public var leadX: CGFloat
        /// The text's width as drawn (cut short with "…" when the box is full).
        public var textWidth: CGFloat
        /// The action button's x (nil: no button).
        public var buttonX: CGFloat?
    }

    /// `lead`: the width of what goes before the text (the chick's art, an icon, a key badge, with their gaps);
    /// `art`: the lead is the mascot (drawn from the left edge, so the line is never centred).
    public static func toast(text: CGFloat, lead: CGFloat, art: Bool = false, button: CGFloat?, floor: CGFloat,
                             maxWidth: CGFloat, buttonGap: CGFloat = 10) -> Toast {
        let right = button.map { earInset + $0 + buttonGap } ?? toastInset
        let start = art ? 0 : toastInset
        let want = start + lead + text + right
        let width = min(maxWidth, max(floor, want))
        var leadX = start
        if button == nil, !art { leadX = max(toastInset, ((width - lead - text) / 2).rounded()) }    // nothing beside it: centred
        let tw = max(0, min(text, width - leadX - lead - right))
        return Toast(width: width, leadX: leadX, textWidth: tw, buttonX: button.map { width - earInset - $0 })
    }

    /// The time left of a limit, in whole seconds rounded up (40 s cap, 37.6 s in: "0:03" beside the clock's "0:37").
    public static func timeLeft(limit: Double, elapsed: Double) -> Int {
        Int(max(0, limit - elapsed).rounded(.up))
    }

    /// The live-text panel's width under an island `islandWidth` wide (its resting width, so the words don't
    /// re-wrap while it springs): the same width when it is open (`open`), else the ears plus 24 pt a side —
    /// never narrower than `minWidth` (a line has to hold a phrase), never wider than the open island.
    public static func livePanelWidth(islandWidth: CGFloat, open: Bool, minWidth: CGFloat = livePanelMinWidth,
                                      openWidth: CGFloat = 480, screenWidth: CGFloat) -> CGFloat {
        let w = open ? islandWidth : min(openWidth, max(minWidth, islandWidth + 48))
        return min(w, screenWidth - 32)
    }

    /// The narrowest the live panel is (a line has to hold a phrase).
    public static let livePanelMinWidth: CGFloat = 340

    /// The capsule's width while live text hangs under it: the panel's minimum less its 24 pt a side — about the
    /// notch with its ears (297 pt), so the island and its lower half keep one proportion on every screen.
    public static func liveCapsuleWidth(panelMin: CGFloat = livePanelMinWidth) -> CGFloat { panelMin - 48 }

    /// The live panel's corner radius: the open island's 22, else the notch's panel 14, the capsule's 15.
    public static func livePanelRadius(open: Bool, notch: Bool) -> CGFloat { open ? 22 : notch ? 14 : 15 }
}

public enum CardShape {
    public static let height: CGFloat = 84
    public static let minWidth: CGFloat = 84
    public static let maxWidth: CGFloat = 150
    /// Aspect fill crops at most this much of the picture; beyond it the picture is shown whole.
    public static let maxCrop: CGFloat = 0.4

    public struct Fit: Equatable {
        public var size: CGSize
        /// true: the picture fills the card (a little of its edges cut); false: it is shown whole, centred on the
        /// card's surface.
        public var fills: Bool
    }

    /// A snap's card for a picture `pixels` big (nil: no picture yet — the classic 4:3 card).
    public static func shot(_ pixels: CGSize?) -> Fit {
        guard let p = pixels, p.width > 0, p.height > 0 else { return Fit(size: CGSize(width: 112, height: height), fills: true) }
        let aspect = p.width / p.height
        let w = min(maxWidth, max(minWidth, (height * aspect).rounded()))
        return Fit(size: CGSize(width: w, height: height), fills: fills(picture: p, box: CGSize(width: w, height: height)))
    }

    /// Whether `picture` may fill `box` (aspect fill), or must be shown whole (aspect fit): fill only while it cuts
    /// at most `maxCrop` of the picture.
    public static func fills(picture p: CGSize, box b: CGSize) -> Bool {
        guard p.width > 0, p.height > 0, b.width > 0, b.height > 0 else { return true }
        let a = p.width / p.height, c = b.width / b.height
        let kept = min(a / c, c / a)                 // the share of the picture that stays visible under aspect fill
        return 1 - kept <= maxCrop
    }
}
