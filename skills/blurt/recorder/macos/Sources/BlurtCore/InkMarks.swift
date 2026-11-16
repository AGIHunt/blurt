// The markup tools on a snap (v1.0.23): the tool chosen and its keys, colours, the arrow's head, the mosaic's blocks,
// the text box, how every mark is kept (shots.jsonl "marks" next to the old "strokes"), undo / redo, and where the tool
// strip goes. The model and the key decision are in Ink.swift's header; InkMarksTests covers each rule.
import CoreGraphics
import Foundation

// MARK: - The tool chosen

/// What a plain drag on a snap does (the tool strip, ⌘-letter). The pen is the default: zero clicks to draw.
public enum InkPick: String, CaseIterable, Equatable {
    case pen, box, ellipse, arrow, text, mosaic

    /// The letter that chooses it with ⌘ while the bubble has the keyboard. Bare letters always type the note; ⌘A is
    /// the note's Select All, so the arrow is ⌘L (a line with a head).
    public var key: String {
        switch self {
        case .pen: return "p"
        case .box: return "r"
        case .ellipse: return "o"
        case .arrow: return "l"
        case .text: return "t"
        case .mosaic: return "m"
        }
    }

    /// "⌘P" — for tooltips.
    public var keyLabel: String { "⌘" + key.uppercased() }

    /// ⌘ and a letter (nothing else held): the tool it chooses, or nil (not a tool key: the field's or the menu's).
    public static func forCommandKey(_ charactersIgnoringModifiers: String?, command: Bool, shift: Bool, option: Bool,
                                     control: Bool) -> InkPick? {
        guard command, !shift, !option, !control, let c = charactersIgnoringModifiers?.lowercased(), c.count == 1 else { return nil }
        return allCases.first { $0.key == c }
    }
}

/// What one drag on a snap makes, from the tool chosen and the modifiers down at that moment.
public enum InkSnapDrag: Equatable {
    /// a line: freehand, box, ellipse or arrow; `constrained` square / round / on 45° (⇧ with a chosen shape)
    case stroke(InkTool, constrained: Bool)
    /// a click places a text box (modifiers mean nothing)
    case text
    /// pixelation: a rectangle, or a freehand brush (⇧)
    case mosaic(brush: Bool)

    public static func decide(_ pick: InkPick, shift: Bool, option: Bool) -> InkSnapDrag {
        switch pick {
        case .pen: return .stroke(InkModifiers.snapTool(shift: shift, option: option), constrained: false)
        case .box: return .stroke(.box, constrained: shift)
        case .ellipse: return .stroke(.ellipse, constrained: shift)
        case .arrow: return .stroke(.arrow, constrained: shift)
        case .text: return .text
        case .mosaic: return .mosaic(brush: shift)
        }
    }
}

// MARK: - Colours

/// The markup colours, the brand's first (BrandColor.markup). One value light and dark: they are content.
public enum InkColor: String, CaseIterable, Equatable {
    case markup, yellow, blue, black, white

    /// sRGB
    public var rgb: UInt32 {
        switch self {
        case .markup: return 0xFF5C3D
        case .yellow: return 0xFFC830
        case .blue: return 0x2F7BF5
        case .black: return 0x1C1C1E
        case .white: return 0xFFFFFF
        }
    }

    /// Text keeps an outline in the opposite tone so it reads on any picture: light outline round black, else dark.
    public var outlineIsLight: Bool { self == .black }

    /// an unknown name (a newer build's) reads as the brand colour
    public static func parse(_ s: Any?) -> InkColor { (s as? String).flatMap(InkColor.init(rawValue:)) ?? .markup }
}

// MARK: - Arrow

public enum InkArrow {
    /// The head's length for a line `width` wide on a shaft `shaft` long: 4.5 lines (at least 12), at most 45 % of the
    /// shaft (a short arrow is still an arrow, not a triangle).
    public static func headLength(width: CGFloat, shaft: CGFloat) -> CGFloat {
        min(max(12, width * 4.5), shaft * 0.45)
    }

    /// half the head's width over its length (~29° each side)
    public static let spread: CGFloat = 0.55

    /// The head's two back corners for an arrow from `tail` to `tip`.
    public static func head(tail: CGPoint, tip: CGPoint, width: CGFloat) -> (left: CGPoint, right: CGPoint) {
        let dx = tip.x - tail.x, dy = tip.y - tail.y
        let len = max(0.0001, hypot(dx, dy))
        let ux = dx / len, uy = dy / len
        let h = headLength(width: width, shaft: len), half = h * spread
        let bx = tip.x - ux * h, by = tip.y - uy * h
        return (CGPoint(x: bx - uy * half, y: by + ux * half), CGPoint(x: bx + uy * half, y: by - ux * half))
    }

    /// The one point list an arrow is kept and drawn as: the shaft, then the head round from the tip — every corner
    /// doubled so the midpoint smoothing keeps it sharp. Stroked it is an outlined arrow (old readers); filled as well
    /// (the app), the head is solid: the fill closes back along the shaft, which has no area.
    public static func points(tail: CGPoint, tip: CGPoint, width: CGFloat) -> [CGPoint] {
        let (l, r) = head(tail: tail, tip: tip, width: width)
        return [tail, tip, tip, l, l, r, r, tip, tip]
    }
}

// MARK: - Mosaic

public enum InkMosaic {
    /// The block's edge in the picture's pixels: 12 pt at its scale (pixels per point), never finer than 1/64 of its
    /// short side (a big picture shown small still hides its text), at least 6 px. Text a size the eye reads is about
    /// one block high: it can't be read back.
    public static func block(pixelsPerPoint: CGFloat, shortSidePx: Int) -> Int {
        max(6, Int((12 * max(1, pixelsPerPoint)).rounded()), shortSidePx / 64)
    }

    /// The brush's width (⇧-mosaic), in the canvas's points: six lines, at least 24.
    public static func brush(lineWidth: CGFloat) -> CGFloat { max(24, lineWidth * 6) }

    /// The rectangle a drag from `a` to `b` covers (nil while it is still a dot).
    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect? {
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        return max(r.width, r.height) >= 4 && min(r.width, r.height) >= 2 ? r : nil
    }
}

// MARK: - Text

public enum InkText {
    /// The text's size on a picture whose short side is `s` points: a twenty-second of it, 16–28 pt — bigger than the
    /// UI's text (it is read in the picture, often scaled down), never a headline.
    public static func fontSize(pictureShortSide s: CGFloat) -> CGFloat { min(28, max(16, (s / 22).rounded())) }

    /// Where the box goes (y down): its left edge at the click, its first line centred on it; moved in, whole, so it
    /// stays inside `bounds` (a box bigger than the picture keeps its top-left corner in).
    public static func box(at p: CGPoint, size: CGSize, lineHeight: CGFloat, in bounds: CGRect) -> CGRect {
        var x = p.x, y = p.y - lineHeight / 2
        x = min(x, bounds.maxX - size.width)
        y = min(y, bounds.maxY - size.height)
        x = max(x, bounds.minX)
        y = max(y, bounds.minY)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// What the box holds when it ends: trimmed; nil when nothing was typed (no mark is made).
    public static func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - The marks, as kept

/// One mark on a picture. `points` are 0–1 of the picture (x right, y down). Kept in shots.jsonl "marks".
///  • pen — any line: freehand, a box, an ellipse, a snapped line (their point lists, InkFit.points)
///  • arrow — InkArrow.points
///  • text — one point, the text's top-left; `size` its font size; `text`
///  • mosaic — a rectangle's two corners, or (`brush`) the brush's path with `size` its width
/// `size` is a fraction of the picture's shorter side, so a mark looks the same at any scale.
public struct InkMark: Equatable {
    public enum Kind: String { case pen, arrow, text, mosaic }
    public var kind: Kind
    public var color: InkColor
    public var points: [[Double]]
    public var text: String?
    public var size: Double?
    public var brush: Bool

    public init(kind: Kind, color: InkColor = .markup, points: [[Double]], text: String? = nil, size: Double? = nil, brush: Bool = false) {
        self.kind = kind
        self.color = color
        self.points = points
        self.text = text
        self.size = size
        self.brush = brush
    }

    /// The old "strokes" entry (a point list) for a line: pen and arrow; nil for text and mosaic (they are only in the
    /// marked picture and "marks").
    public var stroke: [[Double]]? { kind == .pen || kind == .arrow ? points : nil }

    public var json: [String: Any] {
        var o: [String: Any] = ["kind": kind.rawValue, "color": color.rawValue, "points": points]
        if let t = text { o["text"] = t }
        if let s = size { o["size"] = (s * 10000).rounded() / 10000 }
        if brush { o["brush"] = true }
        return o
    }

    public init?(json o: [String: Any]) {
        guard let k = (o["kind"] as? String).flatMap(Kind.init(rawValue:)) else { return nil }
        let pts = (o["points"] as? [[Any]] ?? []).compactMap { p -> [Double]? in
            let v = p.compactMap { ($0 as? NSNumber)?.doubleValue }
            return v.count == 2 ? v : nil
        }
        guard !pts.isEmpty else { return nil }
        self.init(kind: k, color: InkColor.parse(o["color"]), points: pts, text: o["text"] as? String,
                  size: (o["size"] as? NSNumber)?.doubleValue, brush: o["brush"] as? Bool ?? false)
        if k == .text, InkText.clean(text ?? "") == nil { return nil }
    }

    /// shots.jsonl "marks" → the marks (nil: the key isn't there — an older line: build them from "strokes").
    public static func parse(_ v: Any?) -> [InkMark]? {
        guard let a = v as? [[String: Any]] else { return nil }
        return a.compactMap(InkMark.init(json:))
    }

    /// An older capture's strokes as marks: every one a pen line in the brand colour (how they were drawn).
    public static func fromStrokes(_ strokes: [[[Double]]]) -> [InkMark] {
        strokes.filter { !$0.isEmpty }.map { InkMark(kind: .pen, points: $0) }
    }

    /// The "strokes" every older reader takes: the marks that are lines, in order.
    public static func strokes(_ marks: [InkMark]) -> [[[Double]]] { marks.compactMap(\.stroke) }

    /// The order they are drawn in: mosaics first (over the original pixels), then the rest as they were made — ink
    /// is never pixelated, and a mosaic always hides the picture under it.
    public static func drawOrder(_ marks: [InkMark]) -> [InkMark] {
        marks.filter { $0.kind == .mosaic } + marks.filter { $0.kind != .mosaic }
    }
}

/// Undo / redo over the marks: a new mark clears what was undone.
public struct InkHistory: Equatable {
    public private(set) var marks: [InkMark]
    public private(set) var undone: [InkMark] = []

    public init(_ marks: [InkMark] = []) { self.marks = marks }

    public var canUndo: Bool { !marks.isEmpty }
    public var canRedo: Bool { !undone.isEmpty }

    public mutating func add(_ m: InkMark) {
        marks.append(m)
        undone.removeAll()
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let m = marks.popLast() else { return false }
        undone.append(m)
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let m = undone.popLast() else { return false }
        marks.append(m)
        return true
    }

    /// The marks set from outside (a capture loaded for Edit Note): nothing to redo.
    public mutating func reset(_ m: [InkMark]) {
        marks = m
        undone.removeAll()
    }
}

// MARK: - Where the tool strip goes

public enum StripDock {
    /// Where a `strip`-sized row goes for `selection` inside `screen` (unflipped, y up), never over `avoid` (the note
    /// bubble): under the selection with their right edges lined up (WeChat's place), else its left edges, else above
    /// it (right, then left), else inside the selection along its bottom. Clamped to the screen.
    public static func place(strip: CGSize, selection sel: CGRect, screen: CGRect, avoid: CGRect? = nil,
                             gap: CGFloat = 8, margin: CGFloat = 8) -> CGPoint {
        let w = strip.width, h = strip.height
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, screen.minX + margin), screen.maxX - margin - w) }
        let below = sel.minY - gap - h, above = sel.maxY + gap
        let candidates: [CGPoint] = [
            CGPoint(x: clampX(sel.maxX - w), y: below), CGPoint(x: clampX(sel.minX), y: below),
            CGPoint(x: clampX(sel.maxX - w), y: above), CGPoint(x: clampX(sel.minX), y: above),
        ]
        for o in candidates {
            let r = CGRect(origin: o, size: strip)
            guard r.minY >= screen.minY + margin, r.maxY <= screen.maxY - margin else { continue }
            if let a = avoid, a.insetBy(dx: -2, dy: -2).intersects(r) { continue }
            return o
        }
        return CGPoint(x: clampX(sel.maxX - w - gap), y: max(screen.minY + margin, sel.minY + gap))
    }
}
