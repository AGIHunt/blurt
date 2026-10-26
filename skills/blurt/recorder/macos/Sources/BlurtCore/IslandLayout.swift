// The island's geometry rules that don't need AppKit (BlurtApp Capture/Island/Island.swift, IslandContent.swift,
// Ears.swift, HangingCards.swift and Capture/LiveTranscript.swift draw them).
//
//  • the ears (IslandLayout.earOrigin): each ear's content sits against the island's *outer* edge, `earInset` in, in
//    both shapes — the notch's ears and the capsule — so a glyph keeps one leading x and a number one trailing x
//    through listening, transcribing, polishing and idle (the dogfood found them centred in their 56 pt ear, so the
//    mint glyph jumped 12 pt at the stop tap). Content wider than the ear widens that ear (IslandLayout.earSpan:
//    both ears, so the shape stays centred on the notch) instead of giving up its inset — "✓ Sent" sat 4 pt from the
//    island's rounded corner while the clock beside it kept 14. The other ear's content stays where it was
//    (IslandLayout.earReach: measured from the notch by its own need), the extra black outside it — a glyph never
//    jumps because the ear across the notch grew.
//  • one grid for the open island (v0.9-island r2): every leading glyph — a row's icon, the project chip's, a toast's
//    status mark — is centred on `iconColumn` (26 pt in), and every line of text starts on `textColumn` (42 pt in),
//    so a row, the chip and a toast line up whatever they say.
//  • a toast (IslandLayout.toast): its content box is never narrower than the shape it shows in (the notch plus both
//    ears, or 260 pt on a capsule); the mark in the leading slot, the text on the text column, and an action button
//    ending `earInset` from the right edge, under the right ear's number. Nothing is centred: like a list row, a
//    toast's line starts at the same x every time.
//    A line too long for the open width wraps — up to three lines (`wraps`, `toastLines`, `toastHeight`) — instead of
//    ending in "…" mid-word: the lines that explain a failure are the long ones.
//  • the ears (IslandLayout.earNeed): each side as wide as its own content needs — a "✓ Sent" in the right ear never
//    widens the left one, whose keyboard keeps its place and its 56 pt.
//  • time left (IslandLayout.timeLeft): rounded up, so the clock and the time left always add up to the limit.
//  • the live-text panel (IslandLayout.livePanelWidth): the island's lower half, not a second pop-up — as wide as
//    the island when it is open (a voice note), else a little wider than its ears, in one width family; the width
//    is the island's without a toast (one during a take never re-wraps the words). On a capsule (no notch) the
//    island itself widens to `liveCapsuleWidth` while live text shows, so the pair is the notch's proportions there
//    too, and the panel's corners are the capsule's (15; under the notch 14, under the open island 22).
//  • the live-text panel's lines (IslandLayout.liveLines): the last three while the take listens, newest at the
//    bottom; once its text has gone in (typed), from the top, up to eight — a Structured list keeps its heading and
//    its first item in view before a double tap sends it — and a fade on the last line when there is more.
//  • the live-text panel at the end of a take: it keeps the width its words were laid out at and stays on the
//    island's bottom edge (never re-placed below the cards that came down meanwhile); the lower half of an open
//    island (a voice note) goes when the island closes (IslandLayout.livePanelGoes), instead of narrowing and
//    dropping loose below the new card for a second.
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
    /// The open island's one icon column (the centre of every leading glyph) and text column.
    public static let iconColumn: CGFloat = 26
    public static let textColumn: CGFloat = 42
    /// The open voice / recording body's side edges: the ears' content lines up with them while it is open.
    public static let bodyInset: CGFloat = 18

    public enum Side { case left, right }

    /// Where an ear's content (`width` wide) starts, in the island's coordinates: `outer` is the island's outer edge
    /// on that side (its minX for the left ear, its maxX for the right), `inner` the notch's edge on that side (nil on
    /// a capsule: nothing to slide under).
    public static func earOrigin(_ side: Side, width: CGFloat, outer: CGFloat, inner: CGFloat?) -> CGFloat {
        // (only a shape narrower than its content — while the ear still grows to `earSpan` — gives up the inset)
        var inset = earInset
        if let n = inner {
            let room = abs(n - outer) - 2            // keep 2 pt clear of the notch
            inset = max(2, min(earInset, room - width))
        }
        return side == .left ? outer + inset : outer - inset - width
    }

    /// How wide an ear has to be for content `width` wide to keep `earInset` from the outer edge and 2 pt from the
    /// notch: the usual 56 pt, more for a wider one ("✓ 已发送", a Structured clock counting down).
    public static func earWidth(content width: CGFloat) -> CGFloat { max(earWidth, ceil(width) + earInset + 2) }

    /// Both ears' width beside a notch: the wider of the two needs, so the shape stays centred on the notch.
    public static func earSpan(left: CGFloat, right: CGFloat) -> CGFloat {
        max(earWidth(content: left), earWidth(content: right))
    }

    /// One ear's width beside the notch: 0 when it says nothing, else what its own content needs (the other side's
    /// content never widens it).
    public static func earNeed(content width: CGFloat, shown: Bool) -> CGFloat { shown ? earWidth(content: width) : 0 }

    /// The shape's centre offset from the notch's with ears `left` and `right` wide (each side its own).
    public static func earShift(left: CGFloat, right: CGFloat) -> CGFloat { (right - left) / 2 }

    /// How far from the notch an ear's content measures its outer edge, while the shape's ear is `shape` wide (as it
    /// springs): its own need (`earWidth(content:)`), never more — so when the *other* ear widens ("✓ Sent", a clock
    /// past 9:59) this one's glyph stays where it was and the extra black is outside it; and never beyond the shape,
    /// so a growing ear's content rides the edge rather than standing outside the black.
    public static func earReach(content width: CGFloat, shape: CGFloat) -> CGFloat {
        max(earWidth, min(earWidth(content: width), shape))
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
        /// The text doesn't fit on one line at the widest the shape goes: it wraps (`textWidth` is the wrap width;
        /// at most `toastMaxLines`, the row `toastHeight` high).
        public var wraps = false
    }

    /// A toast's row: 46 pt for one line, a line's height more for each further one.
    public static let toastLineHeight: CGFloat = 17
    /// Three: two cut the launch line's list of shortcuts mid-word ("…and ⌃⌥⇧⌘L w…"), the part that says what is wrong.
    public static let toastMaxLines = 3
    public static func toastHeight(lines: Int) -> CGFloat { 46 + CGFloat(min(max(1, lines), toastMaxLines) - 1) * toastLineHeight }
    /// How many lines a wrapped toast's text takes: `wrapped` its height laid out at the wrap width, `line` one line's.
    public static func toastLines(wrapped: CGFloat, line: CGFloat) -> Int {
        guard line > 0 else { return 1 }
        return min(toastMaxLines, max(1, Int(((wrapped - line) / toastLineHeight).rounded()) + 1))
    }

    /// `lead`: the leading slot's width (from `leadX` to the text); `art`: the slot holds the mascot (drawn from the
    /// left edge). Every toast has its slot filled — a status mark, the spinner, the chick — and nothing is centred:
    /// the text starts at `leadX + lead` whatever its length.
    public static func toast(text: CGFloat, lead: CGFloat = textColumn - toastInset, art: Bool = false, button: CGFloat?,
                             floor: CGFloat, maxWidth: CGFloat, buttonGap: CGFloat = 10) -> Toast {
        let right = button.map { earInset + $0 + buttonGap } ?? toastInset
        let leadX = art ? 0 : toastInset
        let want = leadX + lead + text + right
        let width = min(maxWidth, max(floor, want))
        let room = max(0, width - leadX - lead - right)
        return Toast(width: width, leadX: leadX, textWidth: min(text, room), buttonX: button.map { width - earInset - $0 },
                     wraps: text > room + 0.5)
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

    /// The live panel's lines while listening: the last three, newest at the bottom.
    public static let liveListeningLines = 3
    /// …and once its text has gone in: from the top, up to this many.
    public static let liveTypedLines = 8

    /// Which of `total` laid-out lines show: while listening the last `liveListeningLines`; once typed the first
    /// `liveTypedLines`. `more`: lines are left out below the last one shown (it fades out).
    public static func liveLines(total: Int, typed: Bool) -> (range: Range<Int>, more: Bool) {
        guard total > 0 else { return (0..<0, false) }
        if typed { let n = min(total, liveTypedLines); return (0..<n, total > n) }
        return (max(0, total - liveListeningLines)..<total, false)
    }

    /// The live panel goes now, as the island moves: it hung under the open island (`laidOutOpen`: a voice note) and
    /// the island has closed (`open`) — the note is over and its card has the words.
    public static func livePanelGoes(laidOutOpen: Bool, open: Bool) -> Bool { laidOutOpen && !open }

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
