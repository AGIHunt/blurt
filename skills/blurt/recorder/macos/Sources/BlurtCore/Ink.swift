// The pen's rules (v0.9-next, in-place markup): what a drag draws, the clean shape a rough one snaps to, how wide the
// line is, the first-times hint, where the note bubble docks beside a frozen selection, and the project chip's list.
// BlurtApp draws (InkCanvas on a snap, InkView while recording, renderMarked into NNN.marked.png); what it decides is
// here, so it can be tested (InkTests).
//
//  • InkTool / InkModifiers — the same modifiers for a snap and for the recording pen: a plain drag = freehand,
//    ⇧ = box, ⌥ = ellipse. A snap needs no key (the frozen picture takes the drag); while recording the pen key (⌃ by
//    default, record.draw_key) is held as well: ⌃-drag freehand, ⌃⇧ box, ⌃⌥ ellipse. With ⌥ as the pen key the
//    ellipse is ⌃⌥ (the pen key and ⌃). ⌘ never draws (it is a shortcut).
//  • InkFit — holding still ~0.5 s (InkHold) at the end of a freehand stroke snaps it to a clean straight line,
//    rectangle or ellipse when it is close to one (plain geometry: the chord for a line, the mean distance to the
//    bounding box's edges or its inscribed ellipse for a closed loop); anything else stays freehand.
//  • InkFit.points — every stroke is still a point list in shots.jsonl / events.jsonl (0–1 of the picture): a box's
//    corners are doubled so the smoothing every renderer applies (quadratic curves through the midpoints) keeps them
//    sharp; an ellipse is 72 points; a line two. Old readers (frames.py --crop stroke, the review page) need nothing new.
//  • InkStyle — one markup colour (BrandColor.markup) with a soft dark shadow; the line is wider on a bigger display.
//  • InkHint — "Drag to draw · ⇧ box · ⌥ ellipse" the first `times` times only.
//  • BubbleDock — the note bubble sits beside the frozen selection, never over it: right, else left (it flips near the
//    screen's edges), else below, else above; only a selection that fills the screen gets it inside, in a corner.
//  • ProjectPick — the bubble's "Goes to X" chip: recent projects first, typing filters them (name or key).
import CoreGraphics
import Foundation

// MARK: - Tools and modifiers

public enum InkTool: String, Equatable {
    case free, box, ellipse
}

public enum InkModifiers {
    /// The recording pen's key (record.draw_key).
    public enum PenKey: String { case control, option, fn }

    /// A snap's markup: ⇧ box, ⌥ ellipse (⇧ wins when both are down), else freehand.
    public static func snapTool(shift: Bool, option: Bool) -> InkTool {
        shift ? .box : option ? .ellipse : .free
    }

    /// The modifier that makes an ellipse while recording: ⌥, or ⌃ when ⌥ is the pen key itself.
    public static func ellipseKey(pen: PenKey) -> PenKey { pen == .option ? .control : .option }

    /// The recording pen: on while its key is held (with ⇧ for a box, the ellipse key for an ellipse) — nil: off. Any
    /// other modifier (⌘, or a second one that means nothing here) keeps it off: that is a shortcut being typed.
    public static func recordingTool(pen: PenKey, control: Bool, option: Bool, shift: Bool, command: Bool, fn: Bool) -> InkTool? {
        let down: [PenKey: Bool] = [.control: control, .option: option, .fn: fn]
        guard !command, down[pen] == true else { return nil }
        let ell = ellipseKey(pen: pen)
        for k in [PenKey.control, .option, .fn] where k != pen && k != ell && down[k] == true { return nil }
        if shift { return .box }
        if down[ell] == true { return .ellipse }
        return .free
    }
}

// MARK: - Shapes

public enum InkShape: Equatable {
    case line(CGPoint, CGPoint)
    case rect(CGRect)
    case ellipse(CGRect)
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

    /// A ⇧ / ⌥ drag from `a` to `b`: the box or the ellipse it spans (nil while it is still a dot).
    public static func shape(_ tool: InkTool, from a: CGPoint, to b: CGPoint) -> InkShape? {
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        guard max(r.width, r.height) >= 4 else { return nil }
        switch tool {
        case .box: return .rect(r)
        case .ellipse: return .ellipse(r)
        case .free: return nil
        }
    }

    /// The point list a shape is stored as (and drawn from): a box's corners doubled (the midpoint smoothing keeps them
    /// sharp), an ellipse as 72 points round, a line as its two ends.
    public static func points(_ s: InkShape) -> [CGPoint] {
        switch s {
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

// MARK: - The project chip

public enum ProjectPick {
    /// The projects the chip offers: with no query, the most recently used first; typing keeps those whose name or key
    /// contains it (case- and width-insensitive), the ones that start with it first. At most `limit`.
    public static func rows(_ projects: [Project], query: String, limit: Int = 6) -> [Project] {
        let recent = projects.filter { !$0.isInbox }.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Array(recent.prefix(limit)) }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        let hits = recent.filter { $0.name.range(of: q, options: opts) != nil || $0.key.range(of: q, options: opts) != nil }
        let starts = hits.filter { $0.name.range(of: q, options: opts.union(.anchored)) != nil || $0.key.range(of: q, options: opts.union(.anchored)) != nil }
        let rest = hits.filter { h in !starts.contains { $0.id == h.id } }
        return Array((starts + rest).prefix(limit))
    }
}
