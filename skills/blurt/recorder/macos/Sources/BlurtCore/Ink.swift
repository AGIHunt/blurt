// The pen's rules (v0.9-next, in-place markup): what a drag draws, the clean shape a rough one snaps to, how wide the
// line is, the first-times hint and where the note bubble docks beside a frozen selection.
// BlurtApp draws (InkCanvas on a snap, InkView while recording, renderMarks into NNN.marked.png); what it decides is
// here and in InkMarks.swift, so it can be tested (InkTests, InkMarksTests).
//
//  • InkTool / InkModifiers — the same modifiers for a snap and for the recording pen: a plain drag = freehand,
//    ⇧ = box, ⌥ = ellipse, ⇧⌥ = arrow (v1.0.23: before, ⇧ won and ⇧⌥ was a box). A snap needs no key (the frozen
//    picture takes the drag); while recording the pen key (⌃ by default, record.draw_key) is held as well: ⌃-drag
//    freehand, ⌃⇧ box, ⌃⌥ ellipse, ⌃⇧⌥ arrow. With ⌥ as the pen key the ellipse is ⌃⌥ (the pen key and ⌃) and the
//    arrow ⌥⇧⌃. ⌘ never draws (it is a shortcut). Only the keys held count, never the order they went down in (BA-59):
//    ⌃ then ⇧, ⇧ then ⌃ and both at once are all a box (`recordingTool(pen:held:)`; while dragging `dragTool`).
//    PenArm: the pen turns on once such a set has been held a moment (a quick ⌃-shortcut never shows it).
//    Text and mosaic are a snap's only (they need a picture to bake into; the recording pen's ink is the video's).
//  • The markup tools on a snap (v1.0.23, the founder: "WeChat's screenshot tools, all of them") — InkPick, chosen on
//    the tool strip under the frozen selection (InkStage): pen, box, ellipse, arrow, text, mosaic, and a colour
//    (InkColor, the brand markup colour first). The zero-click default stays: the strip opens on the pen, so a plain
//    drag draws freehand and ⇧ / ⌥ / ⇧⌥ make a box / ellipse / arrow without touching the strip. With box, ellipse or
//    arrow chosen a plain drag draws that and ⇧ keeps it square / round / on 45°; mosaic paints a rectangle (⇧: a
//    freehand brush); text places a text box where it is clicked (InkSnapDrag).
//    THE KEYS (decided): the note's field has the keyboard the whole time the snap is frozen (the bubble listens and
//    takes typing at once), so a bare letter always types into the note — never a tool. A tool is chosen by a click
//    on the strip or with ⌘ and its letter: ⌘P pen, ⌘R box (rectangle), ⌘O ellipse (oval), ⌘L arrow (a line with a
//    head; ⌘A stays Select All in the note), ⌘T text, ⌘M mosaic (InkPick.forCommandKey). None of them is a text
//    field's own ⌘-key (⌘A ⌘C ⌘V ⌘X ⌘Z stay the note's); ⌘0–⌘4 stay the type (NoteKeys); the bubble takes the tool
//    keys before the main menu. Each tool's tooltip names its key. ⌘Z / ⇧⌘Z undo / redo the marks (InkHistory) when
//    drawing was the last thing done, else the note's typing.
//  • Text (InkText): a click places an editable box on the picture — the UI's font, semibold, sized to the picture
//    (InkText.fontSize), in the chosen colour with a contrast outline; ↩ ends it, ⇧↩ breaks the line, Esc drops it, a
//    click elsewhere ends it. While it is being edited it has the keyboard (the note's keys don't fire), then the note
//    has it again. The box stays inside the picture (InkText.box).
//  • Mosaic (InkMosaic): the original pixels averaged into blocks (12 pt at the picture's scale, never finer than
//    1/64 of its short side) — baked into NNN.marked.png, which is what a copy or a drag hands out: the covered pixels
//    never leave the Mac in it. The unmarked NNN.png stays as it was (on this Mac). Mosaics are drawn under the ink.
//  • InkMark (InkMarks.swift) — every mark, kept in shots.jsonl "marks" (kind, colour, 0–1 points, text, size). The
//    old "strokes" (point lists) are still written for what is a line: pen, box, ellipse and the arrow (its shaft and
//    head as one point list: old readers — frames.py --crop stroke, the review page — draw it as an outlined arrow).
//    Text and mosaic exist only in "marks" and in the marked PNG.
//  • InkStroke — the stroke being drawn (both views): the freehand path keeps following the pointer while a modifier
//    shows a box / ellipse, so letting go of it mid-drag carries on from where the pointer is.
//  • InkFit — holding still ~0.5 s (InkHold) at the end of a freehand stroke snaps it to a clean straight line,
//    rectangle or ellipse when it is close to one (plain geometry: the chord for a line, the mean distance to the
//    bounding box's edges or its inscribed ellipse for a closed loop); anything else stays freehand.
//  • InkFit.points — every stroke is still a point list in shots.jsonl / events.jsonl (0–1 of the picture): a box's
//    corners are doubled so the smoothing every renderer applies (quadratic curves through the midpoints) keeps them
//    sharp; an ellipse is 72 points; a line two; an arrow its tail, then tip, head corners and tip again, doubled
//    (InkArrow: filled in the app, outlined by old readers).
//  • InkStyle — the markup colour (BrandColor.markup, or the one chosen) with a soft dark shadow; the line is wider on
//    a bigger display.
//  • InkHint — "Drag to draw · ⇧ box · ⌥ ellipse" the first `times` times only.
//  • BubbleDock — the note bubble sits beside the frozen selection, never over it: right, else left (it flips near the
//    screen's edges), else below, else above; only a selection that fills the screen gets it inside, in a corner.
//    StripDock — the tool strip under the selection, right-aligned (WeChat's place), else above it, never over the
//    bubble.
//  (The bubble's "Goes to X" chip lists projects through Projects/Assignment.swift ProjectPick.choices, like every
//  other project picker.)
import CoreGraphics
import Foundation

// MARK: - Tools and modifiers

public enum InkTool: String, Equatable {
    case free, box, ellipse, arrow
}

public enum InkModifiers {
    /// The recording pen's key (record.draw_key).
    public enum PenKey: String { case control, option, fn }

    /// A snap's markup: ⇧ box, ⌥ ellipse, both an arrow, else freehand.
    public static func snapTool(shift: Bool, option: Bool) -> InkTool {
        shift && option ? .arrow : shift ? .box : option ? .ellipse : .free
    }

    /// The modifier that makes an ellipse while recording: ⌥, or ⌃ when ⌥ is the pen key itself.
    public static func ellipseKey(pen: PenKey) -> PenKey { pen == .option ? .control : .option }

    /// The modifier keys held at one moment — a set: what matters is which are down, never the order they went down in.
    public struct Held: OptionSet, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Held(rawValue: 1 << 0)
        public static let option = Held(rawValue: 1 << 1)
        public static let shift = Held(rawValue: 1 << 2)
        public static let command = Held(rawValue: 1 << 3)
        public static let fn = Held(rawValue: 1 << 4)

        static func key(_ k: PenKey) -> Held { k == .control ? .control : k == .option ? .option : .fn }
    }

    /// The recording pen: on while its key is held (with ⇧ for a box, the ellipse key for an ellipse) — nil: off. Any
    /// other modifier (⌘, or a second one that means nothing here) keeps it off: that is a shortcut being typed.
    /// A pure function of the keys held (BA-59): ⌃⇧ is a box however it was pressed — ⌃ first, ⇧ first or together.
    public static func recordingTool(pen: PenKey, held: Held) -> InkTool? {
        guard !held.contains(.command), held.contains(Held.key(pen)) else { return nil }
        let ell = Held.key(ellipseKey(pen: pen))
        for k in [PenKey.control, .option, .fn] where held.contains(Held.key(k)) && Held.key(k) != Held.key(pen) && Held.key(k) != ell {
            return nil
        }
        if held.contains(.shift) { return held.contains(ell) ? .arrow : .box }
        if held.contains(ell) { return .ellipse }
        return .free
    }

    public static func recordingTool(pen: PenKey, control: Bool, option: Bool, shift: Bool, command: Bool, fn: Bool) -> InkTool? {
        var h: Held = []
        if control { h.insert(.control) }
        if option { h.insert(.option) }
        if shift { h.insert(.shift) }
        if command { h.insert(.command) }
        if fn { h.insert(.fn) }
        return recordingTool(pen: pen, held: h)
    }

    /// What a recording drag draws at its start and on every move after (InkView): the pen's tool for the keys held
    /// now; once the pen is on (or latched with ⌥D) and its key is let go mid-drag, ⇧ / ⌥ alone still say box / ellipse.
    public static func dragTool(pen: PenKey?, held: Held) -> InkTool {
        if let pen, let t = recordingTool(pen: pen, held: held) { return t }
        return snapTool(shift: held.contains(.shift), option: held.contains(.option))
    }
}

// MARK: - The stroke being drawn

/// One stroke from mouse-down to mouse-up: freehand points, or the box / ellipse a modifier asks for, or the clean shape
/// a rough freehand stroke snapped to when the pen rested at its end.
public final class InkStroke {
    public let start: CGPoint
    public private(set) var pts: [CGPoint]
    public private(set) var tool: InkTool
    /// the box / ellipse being dragged, or the shape the stroke snapped to (what is shown and kept)
    public private(set) var shape: [CGPoint]?
    /// how it snapped (held still): "line" | "rect" | "ellipse"
    public private(set) var snappedAs: String?
    /// the line's width where it is drawn (an arrow's head is sized from it)
    public let lineWidth: CGFloat
    private var restAt: CGPoint
    private var restSince: Double

    public init(at p: CGPoint, tool: InkTool, lineWidth: CGFloat = 4, now: Double = ProcessInfo.processInfo.systemUptime) {
        start = p
        pts = [p]
        self.tool = tool
        self.lineWidth = lineWidth
        restAt = p
        restSince = now
    }

    /// What to draw now.
    public var display: [CGPoint] { shape ?? pts }
    public var isShape: Bool { shape != nil }
    public var length: CGFloat { zip(pts, pts.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } }
    /// for the event log
    public var kind: String { snappedAs ?? tool.rawValue }

    /// The pen moved (with these modifiers down): true when what is shown changed. `constrained`: a chosen box /
    /// ellipse / arrow with ⇧ — square, round, on 45°.
    @discardableResult
    public func move(to p: CGPoint, tool t: InkTool, constrained: Bool = false,
                     now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        if hypot(p.x - restAt.x, p.y - restAt.y) > InkHold.radius * (snappedAs != nil ? 2 : 1) {
            restAt = p
            restSince = now
            if snappedAs != nil { snappedAs = nil; shape = nil }     // moved on after a snap: freehand again
        }
        tool = t
        // the freehand path follows the pointer even while ⇧ / ⌥ shows a box or ellipse, so letting go of the modifier
        // mid-drag goes back to the line as drawn (never a straight jump from where the shape began)
        var added = false
        if let last = pts.last, hypot(p.x - last.x, p.y - last.y) >= 1.5 { pts.append(p); added = true }
        if t != .free {
            snappedAs = nil
            shape = InkFit.shape(t, from: start, to: constrained ? InkFit.constrain(t, from: start, to: p) : p,
                                 width: lineWidth).map(InkFit.points)
            return true
        }
        if snappedAs == nil {
            let wasShape = shape != nil
            shape = nil
            return added || wasShape
        }
        return false
    }

    /// Called while the button is down (a timer): a freehand stroke the pen rested on snaps to its clean shape.
    /// True when it just snapped.
    public func checkRest(now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard tool == .free, snappedAs == nil, InkHold.rested(lastMove: restSince, now: now), let s = InkFit.fit(pts) else { return false }
        shape = InkFit.points(s)
        switch s {
        case .line: snappedAs = "line"
        case .rect: snappedAs = "rect"
        case .ellipse: snappedAs = "ellipse"
        case .arrow: snappedAs = "arrow"
        }
        return true
    }

    /// The kept points: a shape as it is (its doubled corners matter), freehand thinned to ≥ `minGap` apart; a tap is
    /// its one point (drawn as a ring).
    public func kept(minGap: CGFloat) -> [CGPoint] {
        if let s = shape { return s }
        guard length >= 6 else { return [pts[0]] }
        var keep: [CGPoint] = []
        for p in pts where keep.last.map({ hypot(p.x - $0.x, p.y - $0.y) >= minGap }) ?? true { keep.append(p) }
        if let end = pts.last, keep.last != end { keep.append(end) }
        return keep
    }
}

/// The recording pen turns on once a pen chord — its key alone, or with ⇧ (box) or the ellipse key, pressed in any order
/// or together (BA-59) — has been held for `settle`; then the keys may change freely and the tool follows them. A quick
/// ⌃-shortcut (⌃A in a terminal) is let go before that, so the pen never flashes on; ⌘ or a key that means nothing here
/// (InkModifiers.recordingTool → nil) turns it off. Fed by the 30 Hz modifier poll. (Until v1.0.7 the pen key had to go
/// down first, for window managers' ⌃⌥-drag; the founder chose the shape over that, BA-59.)
public struct PenArm: Equatable {
    public static let settle = 0.15
    public private(set) var armed = false
    private var heldSince: Double?

    public init() {}

    /// `tool`: InkModifiers.recordingTool for the keys down now (nil: the pen key is up, or a shortcut). Returns the
    /// tool while the pen is on, else nil.
    public mutating func update(_ tool: InkTool?, now: Double) -> InkTool? {
        guard let tool else { armed = false; heldSince = nil; return nil }
        if armed { return tool }
        if heldSince == nil { heldSince = now }
        if now - heldSince! >= PenArm.settle { armed = true; return tool }
        return nil
    }
}

// MARK: - Shapes

public enum InkShape: Equatable {
    case line(CGPoint, CGPoint)
    case rect(CGRect)
    case ellipse(CGRect)
    /// from its tail to its tip, the head sized for a line `width` wide (InkArrow)
    case arrow(CGPoint, CGPoint, width: CGFloat)
}

/// Holding still at the end of a freehand stroke: how long, and how far the pointer may wander meanwhile.
public enum InkHold {
    public static let seconds = 0.5
    public static let radius: CGFloat = 3

    /// The pen has rested since `lastMove` (any clock): the stroke snaps to its shape.
    public static func rested(lastMove: Double, now: Double) -> Bool { now - lastMove >= seconds }
}

public enum InkFit {
    /// The clean shape a rough freehand stroke is close to, or nil (it stays as drawn).
    public static func fit(_ pts: [CGPoint]) -> InkShape? {
        guard pts.count >= 3, let first = pts.first, let last = pts.last else { return nil }
        let length = zip(pts, pts.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        guard length >= 16 else { return nil }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let chord = hypot(last.x - first.x, last.y - first.y)

        // a line: the stroke runs along its chord
        if chord >= 20, chord >= 0.8 * length {
            let dev = pts.map { distance($0, toLineThrough: first, last) }.max() ?? 0
            if dev <= max(5, 0.07 * chord) { return .line(first, straightened(first, last)) }
        }

        // a closed loop: back near where it started, about a perimeter long
        let big = max(box.width, box.height)
        guard min(box.width, box.height) >= 10, chord <= max(14, 0.3 * big), length >= 1.4 * (box.width + box.height) else { return nil }
        var rectErr: CGFloat = 0, ellErr: CGFloat = 0
        for p in pts {
            let u = (p.x - box.minX) / box.width, v = (p.y - box.minY) / box.height
            rectErr += min(u, 1 - u, v, 1 - v)
            ellErr += abs(hypot(u - 0.5, v - 0.5) / 0.5 - 1) * 0.5
        }
        rectErr /= CGFloat(pts.count)
        ellErr /= CGFloat(pts.count)
        let best = min(rectErr, ellErr)
        guard best <= 0.08 else { return nil }
        return rectErr <= ellErr ? .rect(box) : .ellipse(box)
    }

    /// A ⇧ / ⌥ / ⇧⌥ drag from `a` to `b`: the box, the ellipse or the arrow it spans (nil while it is still a dot).
    public static func shape(_ tool: InkTool, from a: CGPoint, to b: CGPoint, width: CGFloat = 4) -> InkShape? {
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        guard max(r.width, r.height) >= 4 else { return nil }
        switch tool {
        case .box: return .rect(r)
        case .ellipse: return .ellipse(r)
        case .arrow: return .arrow(a, b, width: width)
        case .free: return nil
        }
    }

    /// ⇧ with a chosen shape: a box or an ellipse as wide as it is high (the longer side wins), an arrow on the nearest
    /// 45°.
    public static func constrain(_ tool: InkTool, from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        switch tool {
        case .box, .ellipse:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: a.x + (dx < 0 ? -side : side), y: a.y + (dy < 0 ? -side : side))
        case .arrow:
            let len = hypot(dx, dy)
            let ang = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            return CGPoint(x: a.x + len * cos(ang), y: a.y + len * sin(ang))
        case .free:
            return b
        }
    }

    /// The point list a shape is stored as (and drawn from): a box's corners doubled (the midpoint smoothing keeps them
    /// sharp), an ellipse as 72 points round, a line as its two ends, an arrow as InkArrow.points.
    public static func points(_ s: InkShape) -> [CGPoint] {
        switch s {
        case .arrow(let a, let b, let w):
            return InkArrow.points(tail: a, tip: b, width: w)
        case .line(let a, let b):
            return [a, b]
        case .rect(let r):
            let c = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
                     CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)]
            return c.flatMap { [$0, $0] }
        case .ellipse(let r):
            let n = 72
            return (0...n).map { i in
                let a = Double(i) / Double(n) * 2 * .pi - .pi / 2
                return CGPoint(x: r.midX + r.width / 2 * CGFloat(cos(a)), y: r.midY + r.height / 2 * CGFloat(sin(a)))
            }
        }
    }

    /// Nearly level or upright (within 6°): exactly so.
    static func straightened(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let ang = abs(atan2(b.y - a.y, b.x - a.x) * 180 / .pi)
        if ang <= 6 || ang >= 174 { return CGPoint(x: b.x, y: a.y) }
        if abs(ang - 90) <= 6 { return CGPoint(x: a.x, y: b.y) }
        return b
    }

    static func distance(_ p: CGPoint, toLineThrough a: CGPoint, _ b: CGPoint) -> CGFloat {
        let d = hypot(b.x - a.x, b.y - a.y)
        guard d > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        return abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / d
    }
}

// MARK: - Style and the hint

public enum InkStyle {
    /// The line in points: wider on a bigger display (its short side), 3–6 pt in half points.
    public static func width(screenShortSide s: CGFloat) -> CGFloat {
        (min(6, max(3, s / 260)) * 2).rounded() / 2
    }
}

public enum InkHint {
    /// how many pens it is shown on
    public static let times = 3
    public static func shows(alreadyShown n: Int) -> Bool { n < times }
}

// MARK: - Where the note bubble docks

public enum BubbleDock {
    public enum Side: String { case right, left, below, above, inside }

    /// Where a `bubble`-sized panel goes beside `selection`, inside `screen` (all in the same unflipped coordinates):
    /// to the right with its top at the selection's top, else to the left, else below, else above; a selection that
    /// leaves no room outside gets it inside, in its bottom-right corner.
    public static func place(bubble: CGSize, selection sel: CGRect, screen: CGRect, gap: CGFloat = 12,
                             margin: CGFloat = 8) -> (origin: CGPoint, side: Side) {
        let w = bubble.width, h = bubble.height
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, screen.minY + margin), screen.maxY - margin - h) }
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, screen.minX + margin), screen.maxX - margin - w) }
        let topY = clampY(sel.maxY - h)
        if sel.maxX + gap + w <= screen.maxX - margin { return (CGPoint(x: sel.maxX + gap, y: topY), .right) }
        if sel.minX - gap - w >= screen.minX + margin { return (CGPoint(x: sel.minX - gap - w, y: topY), .left) }
        if sel.minY - gap - h >= screen.minY + margin { return (CGPoint(x: clampX(sel.maxX - w), y: sel.minY - gap - h), .below) }
        if sel.maxY + gap + h <= screen.maxY - margin { return (CGPoint(x: clampX(sel.maxX - w), y: sel.maxY + gap), .above) }
        return (CGPoint(x: clampX(sel.maxX - w - gap), y: clampY(sel.minY + gap)), .inside)
    }
}
