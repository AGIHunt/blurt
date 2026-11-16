// The pen (v0.9-next): one set of rules for a snap and for a recording (BlurtCore Ink.swift).
//
//  • a plain drag draws freehand, ⇧-drag a box, ⌥-drag an ellipse, ⇧⌥-drag an arrow (v1.0.23; its head solid in the
//    app, outlined by old readers) (the modifiers are read on every move, so ⇧ pressed
//    mid-drag turns the stroke into a box); holding still ~0.5 s at the end of a freehand stroke snaps a rough line,
//    box or ellipse to a clean one (InkFit — plain geometry). While recording the same modifiers go with the pen key:
//    ⌃-drag, ⌃⇧, ⌃⌥, ⌃⇧⌥ (record.draw_key; with ⌥ as the pen key the ellipse is ⌃⌥), in any order or together (BA-59:
//    BlurtCore InkModifiers.dragTool reads the keys held, PenArm only waits a moment so a ⌃-shortcut never shows the
//    pen). Letting go of ⇧ / ⌥ mid-drag carries on freehand from the pointer.
//  • one colour, BrandColor.markup, with a soft dark shadow so it reads on any background; the line is wider on a
//    bigger display (InkStyle.width).
//  • InkStroke (BlurtCore) builds the stroke being drawn (shared by both views); inkPath draws a point list the way every renderer
//    does (quadratic curves through the midpoints; renderMarked, the review page and frames.py read the same points).
//  • InkCanvas: the markup on a picture — the snap's frozen selection (InkStage) and Edit Note's picture (NoteBubble):
//    the tools (pen, box, ellipse, arrow, text, mosaic) and colours of InkTools.swift / BlurtCore InkMarks.swift. Marks
//    are 0–1 of the picture (shots.jsonl "marks", the lines also as "strokes"); ⌘Z / ⇧⌘Z undo / redo (InkHistory).
//  • InkView: the pen while recording. It covers the recorded area, click-through until the pen is on (its key held, or
//    latched with ⌥D); then it takes the drag itself, over any app and over Blurt's own windows alike, so nothing
//    underneath moves or selects (BA-65: its window sat at .floating — NSPanel.isFloatingPanel resets the level set
//    before it — so Blurt's own floating panels, Recently Taken first, and other apps' floating windows covered it and
//    took the drag; the window is lifted to .statusBar here and to the front of it when the pen turns on); ink fades a few seconds after the last stroke, so a circle and the arrow drawn right after it
//    share a frame. Unlike the rest of the chrome this window *is* captured, and each stroke is logged to events.jsonl
//    in the same 0–1 coordinates as clicks ("shape": free | box | ellipse | arrow | line | rect, the fitted ones).
//    Text and mosaic are a snap's only: the recording's ink is the video's, there is no picture to bake them into.
import AppKit
import AVFoundation
import BlurtCore
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import ServiceManagement

/// A stroke's path, as every renderer draws it: through the midpoints (smooth without lagging behind the hand; a doubled
/// point is a sharp corner), a single point as a ring of radius `ring`.
func inkPath(_ p: [CGPoint], ring: CGFloat) -> CGPath {
    let m = CGMutablePath()
    guard let f = p.first else { return m }
    if p.count == 1 { m.addEllipse(in: CGRect(x: f.x - ring, y: f.y - ring, width: ring * 2, height: ring * 2)); return m }
    m.move(to: f)
    if p.count > 2 {
        for i in 1..<(p.count - 1) {
            m.addQuadCurve(to: CGPoint(x: (p[i].x + p[i + 1].x) / 2, y: (p[i].y + p[i + 1].y) / 2), control: p[i])
        }
    }
    m.addLine(to: p[p.count - 1])
    return m
}

/// The pen's look on a layer: the markup colour (or the one chosen), round ends, a soft dark shadow (reads on light and
/// dark pages).
func styleInk(_ l: CAShapeLayer, width: CGFloat, color: InkColor = .markup) {
    l.fillColor = nil
    l.strokeColor = color == .markup ? BrandColor.Island.markup.cgColor : color.ns.cgColor     // BrandColor.markup: one value light and dark
    l.lineWidth = width
    l.lineCap = .round
    l.lineJoin = .round
    l.shadowColor = NSColor.black.cgColor
    l.shadowOpacity = 0.45
    l.shadowRadius = max(1.2, width * 0.4)
    l.shadowOffset = .zero
}

/// The line width for a display (InkStyle: wider on a bigger one).
func inkWidth(for screen: NSScreen?) -> CGFloat {
    let s = (screen ?? NSScreen.main)?.frame.size ?? CGSize(width: 1512, height: 982)
    return InkStyle.width(screenShortSide: min(s.width, s.height))
}

// MARK: - The pen on a picture (snap, Edit Note)

/// The markup on a picture — the frozen selection (InkStage) and Edit Note's enlarged picture (NoteBubble). Every mark is
/// a BlurtCore InkMark (0–1 points); `strokes` is the old point-list view of the lines among them. The tool chosen
/// (`pick`, the strip or ⌘-letter) and the modifiers held say what a drag makes (InkSnapDrag); ⌘Z / ⇧⌘Z (undo / redo)
/// go through InkHistory. Drawing is one live layer (a shape, or the mosaic's mask) moved on each drag event — nothing
/// else is redrawn until the mark is made, so a drag keeps up at 120 Hz.
final class InkCanvas: NSView, NSTextViewDelegate {
    var image: CGImage? { didSet { pixels = nil; needsDisplay = true; redrawInk() } }
    private var history = InkHistory()
    var marks: [InkMark] {
        get { history.marks }
        set { endText(commit: false); history.reset(newValue); redrawInk(); onToolChange?() }
    }
    /// the lines among the marks, as older code and readers keep them
    var strokes: [[[Double]]] {
        get { InkMark.strokes(marks) }
        set { marks = InkMark.fromStrokes(newValue) }
    }
    var canRedo: Bool { history.canRedo }
    var editable = true { didSet { window?.invalidateCursorRects(for: self) } }
    /// the line in points (InkStyle.width for the display, or scaled for an enlarged preview)
    var lineWidth: CGFloat = 3.5 { didSet { styleInk(live, width: lineWidth, color: color); redrawInk() } }
    /// the picture's pixels per point (Shot.scale): the mosaic's block (BlurtCore InkMosaic.block)
    var pictureScale: CGFloat = 2 { didSet { if pictureScale != oldValue { pixels = nil; redrawInk() } } }
    /// what a plain drag makes (the strip, ⌘-letter); the pen by default
    var pick: InkPick = .pen {
        didSet {
            if pick != .text { endText(commit: true) }
            window?.invalidateCursorRects(for: self)
            if pick != oldValue { emit(["event": "ink_tool", "tool": pick.rawValue]) }
            onToolChange?()
        }
    }
    var color: InkColor = .markup {
        didSet {
            styleInk(live, width: lineWidth, color: color)
            if let tb = textBox {
                tb.textColor = color.ns
                tb.insertionPointColor = color.ns
                textOutline?.layer?.borderColor = color.ns.withAlphaComponent(0.85).cgColor
            }
            if color != oldValue { emit(["event": "ink_color", "color": color.rawValue]) }
            onToolChange?()
        }
    }
    var onChange: (() -> Void)?
    /// a stroke went down / the pen moved / it was lifted (the bubble holds its close while the pen is on the picture)
    var onStrokeBegan: (() -> Void)?
    var onStrokeMoved: (() -> Void)?
    var onStrokeEnded: (() -> Void)?
    /// the tool, the colour or the marks changed (the strip shows them)
    var onToolChange: (() -> Void)?
    /// a text box ended: the note's field takes the keys again
    var onTextEnded: (() -> Void)?
    /// a text box began: its window takes the keys (the stage's panel, which otherwise never does)
    var onTextBegan: (() -> Void)?

    private var stroke: InkStroke?
    private var constrained = false
    private var mosaicDrag: (start: CGPoint, brush: Bool, pts: [CGPoint])?
    private var restTimer: Timer?
    /// a stroke or a mosaic is being drawn
    var isDrawing: Bool { stroke != nil || mosaicDrag != nil }
    private let inkLayer = CALayer()
    private let live = CAShapeLayer()
    private let liveMosaic = CALayer()
    private let liveMask = CAShapeLayer()
    /// the picture pixelated (made the first time a mosaic needs it)
    private var pixels: CGImage?
    private var textBox: InkTextBox?
    private var textAt: CGPoint = .zero
    private var textSize: CGFloat = 18
    var isEditingText: Bool { textBox != nil }

    init(frame: NSRect, corner: CGFloat = 8) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = corner
        layer?.masksToBounds = true
        layer?.addSublayer(inkLayer)
        styleInk(live, width: lineWidth, color: color)
        liveMosaic.magnificationFilter = .nearest
        liveMosaic.mask = liveMask
        liveMosaic.isHidden = true
        inkLayer.addSublayer(liveMosaic)
        inkLayer.addSublayer(live)
    }
    override convenience init(frame: NSRect) { self.init(frame: frame, corner: 8) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var cursor: NSCursor { !editable ? .arrow : pick == .text ? .iBeam : .crosshair }
    override func resetCursorRects() { if editable { addCursorRect(bounds, cursor: cursor) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // the app is not active while the pen is on a snap: cursor rects alone don't apply then
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    override func layout() {
        super.layout()
        inkLayer.frame = bounds
        redrawInk()
    }

    override func draw(_ dirty: NSRect) {
        guard let img = image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: bounds)
        ctx.restoreGState()
    }

    private var ring: CGFloat { lineWidth * 4.5 }
    private var short: CGFloat { max(1, min(bounds.width, bounds.height)) }
    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    private func at(_ p: [Double]) -> CGPoint { CGPoint(x: CGFloat(p[0]) * bounds.width, y: CGFloat(p[1]) * bounds.height) }
    private func norm(_ p: CGPoint) -> [Double] {
        let r3 = { (v: CGFloat) in Double((v * 1000).rounded() / 1000) }
        return [r3(min(max(p.x, 0), bounds.width) / max(1, bounds.width)), r3(min(max(p.y, 0), bounds.height) / max(1, bounds.height))]
    }

    private func pixelated() -> CGImage? {
        if pixels == nil, let img = image {
            pixels = pixelate(img, block: InkMosaic.block(pixelsPerPoint: pictureScale, shortSidePx: min(img.width, img.height)))
        }
        return pixels
    }

    /// The marks as layers: mosaics first (under the ink), then lines, arrows and text in the order they were made.
    func redrawInk() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkLayer.sublayers?.filter { $0 !== live && $0 !== liveMosaic }.forEach { $0.removeFromSuperlayer() }
        for m in InkMark.drawOrder(marks) where !m.points.isEmpty {
            guard let l = layer(for: m) else { continue }
            inkLayer.insertSublayer(l, below: liveMosaic)
        }
        CATransaction.commit()
    }

    private func layer(for m: InkMark) -> CALayer? {
        switch m.kind {
        case .pen, .arrow:
            let l = CAShapeLayer()
            styleInk(l, width: lineWidth, color: m.color)
            if m.kind == .arrow { l.fillColor = m.color.ns.cgColor }
            l.path = inkPath(m.points.map(at), ring: ring)
            return l
        case .mosaic:
            guard let px = pixelated() else { return nil }
            let l = CALayer()
            l.frame = bounds
            l.contents = px
            l.magnificationFilter = .nearest
            let mask = CAShapeLayer()
            mask.frame = bounds
            if m.brush {
                mask.path = inkPath(m.points.map(at), ring: 0.5)
                mask.fillColor = nil
                mask.strokeColor = NSColor.black.cgColor
                mask.lineWidth = CGFloat(m.size ?? 0.05) * short
                mask.lineCap = .round
                mask.lineJoin = .round
            } else if m.points.count >= 2 {
                let a = at(m.points[0]), b = at(m.points[1])
                mask.path = CGPath(rect: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)), transform: nil)
            }
            l.mask = mask
            return l
        case .text:
            guard let t = m.text else { return nil }
            let fs = CGFloat(m.size ?? 0.05) * short, s = scale
            guard let img = inkTextImage(t, fontSize: fs, color: m.color, scale: s) else { return nil }
            let pad = inkTextPad(fs), tl = at(m.points[0])
            let l = CALayer()
            l.contents = img
            l.contentsScale = s
            l.frame = CGRect(x: tl.x - pad, y: tl.y - pad, width: CGFloat(img.width) / s, height: CGFloat(img.height) / s)
            return l
        }
    }

    func local(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    private func drag(_ flags: NSEvent.ModifierFlags) -> InkSnapDrag {
        InkSnapDrag.decide(pick, shift: flags.contains(.shift), option: flags.contains(.option))
    }

    private func showLive() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        live.path = stroke.map { inkPath($0.display, ring: ring) }
        live.fillColor = stroke?.tool == .arrow && stroke?.isShape == true ? color.ns.cgColor : nil
        CATransaction.commit()
    }

    override func mouseDown(with e: NSEvent) {
        guard editable else { return }
        // a click while a text box is open ends it (kept) and does nothing more
        if textBox != nil { endText(commit: true); return }
        let p = local(e)
        switch drag(e.modifierFlags) {
        case .stroke(let t, let c): constrained = c; begin(at: p, tool: t)
        case .text: beginText(at: p)
        case .mosaic(let brush): beginMosaic(at: p, brush: brush)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard editable else { return }
        if mosaicDrag != nil { moveMosaic(to: local(e)); return }
        guard stroke != nil else { return }
        if case .stroke(let t, let c) = drag(e.modifierFlags) { constrained = c; move(to: local(e), tool: t) }
    }

    override func mouseUp(with e: NSEvent) {
        guard editable, isDrawing else { return }
        flush()
        onStrokeEnded?()
    }

    func begin(at p: CGPoint, tool: InkTool) {
        stroke = InkStroke(at: p, tool: tool, lineWidth: lineWidth)
        live.path = nil
        restTimer?.invalidate()
        // the pen resting at the end of a freehand stroke: it snaps to its shape (checked while the button is down)
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let s = self.stroke else { return }
            if s.checkRest() {
                self.showLive()
                emit(["event": "ink_snap", "shape": s.kind])
            }
        }
        RunLoop.main.add(t, forMode: .common)
        restTimer = t
        onStrokeBegan?()
    }

    func move(to p: CGPoint, tool: InkTool) {
        guard let s = stroke else { return }
        if s.move(to: p, tool: tool, constrained: constrained) { showLive() }
        onStrokeMoved?()
    }

    // MARK: mosaic

    private func beginMosaic(at p: CGPoint, brush: Bool) {
        guard let px = pixelated() else { return }
        mosaicDrag = (p, brush, [p])
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveMosaic.frame = bounds
        liveMask.frame = bounds
        liveMosaic.contents = px
        liveMask.path = nil
        liveMask.fillColor = brush ? nil : NSColor.black.cgColor
        liveMask.strokeColor = brush ? NSColor.black.cgColor : nil
        liveMask.lineWidth = InkMosaic.brush(lineWidth: lineWidth)
        liveMask.lineCap = .round
        liveMask.lineJoin = .round
        liveMosaic.isHidden = false
        if brush { liveMask.path = inkPath([p], ring: 0.5) }
        CATransaction.commit()
        onStrokeBegan?()
    }

    private func moveMosaic(to p: CGPoint) {
        guard var d = mosaicDrag else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if d.brush {
            if let last = d.pts.last, hypot(p.x - last.x, p.y - last.y) >= 2 { d.pts.append(p) }
            liveMask.path = inkPath(d.pts, ring: 0.5)
        } else {
            d.pts = [d.start, p]
            liveMask.path = InkMosaic.rect(from: d.start, to: p).map { CGPath(rect: $0, transform: nil) }
        }
        CATransaction.commit()
        mosaicDrag = d
        onStrokeMoved?()
    }

    private func endMosaic() -> InkMark? {
        guard let d = mosaicDrag else { return nil }
        mosaicDrag = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveMosaic.isHidden = true
        liveMask.path = nil
        CATransaction.commit()
        if d.brush {
            var keep: [CGPoint] = []
            for p in d.pts where keep.last.map({ hypot(p.x - $0.x, p.y - $0.y) >= 3 }) ?? true { keep.append(p) }
            if let end = d.pts.last, keep.last != end { keep.append(end) }
            return InkMark(kind: .mosaic, color: color, points: keep.map(norm),
                           size: Double(InkMosaic.brush(lineWidth: lineWidth) / short), brush: true)
        }
        guard let last = d.pts.last, let r = InkMosaic.rect(from: d.start, to: last) else { return nil }
        return InkMark(kind: .mosaic, color: color, points: [norm(CGPoint(x: r.minX, y: r.minY)), norm(CGPoint(x: r.maxX, y: r.maxY))])
    }

    // MARK: text

    /// The size text is set in here: the picture's own (InkText.fontSize for its short side in its points), shown at
    /// this canvas's scale — a text made in Edit Note is as big in the picture as one made in place.
    private var textFontSize: CGFloat {
        guard let img = image else { return InkText.fontSize(pictureShortSide: short) }
        let picShort = CGFloat(min(img.width, img.height)) / max(0.5, pictureScale)
        return InkText.fontSize(pictureShortSide: picShort) * short / max(1, picShort)
    }

    private func beginText(at p: CGPoint) {
        textSize = textFontSize
        textAt = p
        let tb = InkTextBox(frame: NSRect(x: p.x, y: p.y, width: 40, height: textSize * 1.3))
        tb.isRichText = false
        tb.importsGraphics = false
        tb.allowsUndo = true
        tb.drawsBackground = false
        tb.font = inkTextFont(textSize)
        tb.textColor = color.ns
        tb.insertionPointColor = color.ns
        tb.textContainerInset = .zero
        tb.textContainer?.lineFragmentPadding = 0
        tb.textContainer?.widthTracksTextView = false
        tb.textContainer?.containerSize = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        tb.isHorizontallyResizable = false
        tb.isVerticallyResizable = false
        tb.delegate = self
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(color.outlineIsLight ? 0.25 : 0.55)
        sh.shadowBlurRadius = max(1.5, textSize * 0.16)
        tb.shadow = sh
        // the box while it is typed in: a hairline the picture shows through
        let outline = NSView()
        outline.wantsLayer = true
        outline.layer?.borderWidth = 1
        outline.layer?.borderColor = color.ns.withAlphaComponent(0.85).cgColor
        outline.layer?.cornerRadius = 3
        outline.layer?.shadowOpacity = 0.5
        outline.layer?.shadowRadius = 1
        outline.layer?.shadowOffset = .zero
        textOutline = outline
        addSubview(outline)
        addSubview(tb)
        textBox = tb
        layoutText()
        onTextBegan?()
        window?.makeFirstResponder(tb)
        emit(["event": "ink_text", "phase": "begin", "at": norm(p), "size": Double(textSize)])
        onStrokeBegan?()
    }
    private var textOutline: NSView?

    private func layoutText() {
        guard let tb = textBox, let lm = tb.layoutManager, let tc = tb.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let line = ceil(lm.defaultLineHeight(for: inkTextFont(textSize)))
        let size = CGSize(width: max(ceil(used.width) + 2, textSize * 0.6), height: max(ceil(used.height), line))
        let box = InkText.box(at: textAt, size: size, lineHeight: line, in: bounds)
        tb.frame = box
        textOutline?.frame = box.insetBy(dx: -4, dy: -3)
    }

    func textDidChange(_ notification: Notification) { layoutText() }

    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): endText(commit: true); return true
        case #selector(NSResponder.cancelOperation(_:)): endText(commit: false); return true
        case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            textView.insertText("\n", replacementRange: textView.selectedRange()); return true
        case #selector(NSResponder.insertTab(_:)): endText(commit: true); return true
        default: return false
        }
    }

    /// The text box ends: kept as a mark (↩, a click elsewhere, the note closing) or dropped (Esc). The note's field
    /// takes the keys again.
    func endText(commit: Bool) {
        guard let tb = textBox else { return }
        textBox = nil
        let text = InkText.clean(tb.string)
        let origin = tb.frame.origin
        tb.delegate = nil
        tb.removeFromSuperview()
        textOutline?.removeFromSuperview()
        textOutline = nil
        emit(["event": "ink_text", "phase": commit && text != nil ? "kept" : "dropped", "chars": text?.count ?? 0])
        if commit, let t = text {
            add(InkMark(kind: .text, color: color, points: [norm(origin)], text: t, size: Double(textSize / short)))
        }
        onTextEnded?()
    }

    /// Tests: a text box at `p` (0–1) with `text` typed into it, then ↩ (`end` true) — the same path a click, typing and
    /// ↩ take.
    func testText(at p: CGPoint, _ text: String, end: Bool) {
        if textBox == nil { beginText(at: CGPoint(x: p.x * bounds.width, y: p.y * bounds.height)) }
        textBox?.insertText(text, replacementRange: textBox?.selectedRange() ?? NSRange(location: 0, length: 0))
        if end, let tb = textBox { _ = textView(tb, doCommandBy: #selector(NSResponder.insertNewline(_:))) }
    }

    // MARK: marks

    private func add(_ m: InkMark) {
        history.add(m)
        redrawInk()
        onChange?()
        onToolChange?()
    }

    /// The mark being drawn becomes a mark now (mouse-up, or the bubble closing under the pen: ⏎, ⌥A); a text box being
    /// typed is kept.
    func flush() {
        restTimer?.invalidate()
        restTimer = nil
        endText(commit: true)
        if mosaicDrag != nil {
            if let m = endMosaic() {
                emit(["event": "ink_stroke", "shape": m.brush ? "mosaic_brush" : "mosaic", "points": m.points.count, "strokes": marks.count + 1])
                add(m)
            }
            return
        }
        guard let s = stroke else { return }
        stroke = nil
        let keep = s.kept(minGap: 2)
        let arrow = s.tool == .arrow && s.isShape
        let m = InkMark(kind: arrow ? .arrow : .pen, color: color, points: keep.map(norm))
        emit(["event": "ink_stroke", "shape": s.kind, "points": keep.count, "strokes": marks.count + 1, "color": color.rawValue])
        live.path = nil
        live.fillColor = nil
        add(m)
    }

    /// ⌘Z: the last mark goes. False when there was none.
    @discardableResult
    func undo() -> Bool {
        endText(commit: true)
        guard history.undo() else { return false }
        emit(["event": "ink_undo", "strokes": marks.count])
        redrawInk()
        onChange?()
        onToolChange?()
        return true
    }

    /// ⇧⌘Z: the last mark undone comes back. False when there was none.
    @discardableResult
    func redo() -> Bool {
        guard history.redo() else { return false }
        emit(["event": "ink_redo", "strokes": marks.count])
        redrawInk()
        onChange?()
        onToolChange?()
        return true
    }
}

// MARK: - Pen: draw on the screen while recording

final class InkView: NSView {
    static let visible = 3.0          // seconds the ink stays after the last stroke
    weak var rec: Recorder?
    var stroke: InkStroke?
    var live: CAShapeLayer?
    var done: [CAShapeLayer] = []     // finished strokes still on screen
    var fade: DispatchWorkItem?
    var restTimer: Timer?
    var t0 = 0.0
    /// the line in points (InkStyle: the display the recording is on)
    var lineWidth: CGFloat = 4
    let halo = CAShapeLayer()         // small ring at the cursor: "the pen is on"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        halo.path = CGPath(ellipseIn: CGRect(x: -9, y: -9, width: 18, height: 18), transform: nil)
        halo.fillColor = BrandColor.Island.markup.withAlphaComponent(0.25).cgColor     // the pen
        halo.strokeColor = BrandColor.Island.markup.cgColor
        halo.lineWidth = 2
        halo.isHidden = true
        layer?.addSublayer(halo)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }    // top-left origin, like events.jsonl
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // a transparent view says yes by default: the pen's drag must never move its own (borderless) window
    override var mouseDownCanMoveWindow: Bool { false }

    /// BA-65: the recorder's panel is made `isFloatingPanel` after its level is set, and that puts it back at .floating
    /// (3) — under any floating panel ordered after it (a card's preview, the permission helper, the
    /// command palette, other apps' floating windows), which then took the pen's drag. The level is set again here, once
    /// the view is in its window (the panel is configured by then): .statusBar, under the island (+1) and the note bubble.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let w = window else { return }
        w.level = InkView.level
        w.isMovable = false
    }
    static let level = NSWindow.Level.statusBar

    func setOn(_ on: Bool) {
        guard live == nil else { return }     // finish the stroke in progress first
        if on, let w = window {
            if w.level != InkView.level { w.level = InkView.level }
            w.orderFrontRegardless()          // above anything at its level shown since (the island is a level higher)
        }
        window?.ignoresMouseEvents = !on
        // a fully transparent window lets clicks fall through; a whisper of fill makes it take them
        layer?.backgroundColor = on ? NSColor(white: 0, alpha: 0.02).cgColor : nil
        if on, let w = window { moveHalo(convert(w.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)) }
        halo.isHidden = !on
    }

    func moveHalo(_ p: NSPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.position = p
        CATransaction.commit()
    }

    /// What a drag draws now: the keys held, in whatever order they went down (⌃⇧ box, ⌃⌥ ellipse); a latched pen (⌥D)
    /// takes ⇧ / ⌥ alone (BlurtCore InkModifiers.dragTool).
    func tool(_ flags: NSEvent.ModifierFlags) -> InkTool {
        InkModifiers.dragTool(pen: rec?.penKind, held: InkView.held(flags))
    }

    static func held(_ f: NSEvent.ModifierFlags) -> InkModifiers.Held {
        var h: InkModifiers.Held = []
        if f.contains(.control) { h.insert(.control) }
        if f.contains(.option) { h.insert(.option) }
        if f.contains(.shift) { h.insert(.shift) }
        if f.contains(.command) { h.insert(.command) }
        if f.contains(.function) { h.insert(.fn) }
        return h
    }

    private func showLive() {
        guard let l = live, let s = stroke else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.path = inkPath(s.display, ring: 18)
        l.fillColor = s.tool == .arrow && s.isShape ? BrandColor.Island.markup.cgColor : nil      // an arrow's head is solid
        CATransaction.commit()
    }

    override func mouseMoved(with e: NSEvent) { moveHalo(convert(e.locationInWindow, from: nil)) }

    override func mouseDown(with e: NSEvent) { begin(at: convert(e.locationInWindow, from: nil), tool: tool(e.modifierFlags)) }

    func begin(at p: CGPoint, tool t: InkTool) {
        fade?.cancel()
        stroke = InkStroke(at: p, tool: t, lineWidth: lineWidth)
        t0 = rec?.elapsed() ?? 0
        let l = CAShapeLayer()
        styleInk(l, width: lineWidth)
        layer?.insertSublayer(l, below: halo)
        live = l
        restTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let s = self.stroke else { return }
            if s.checkRest() { self.showLive(); emit(["event": "ink_snap", "shape": s.kind, "recording": true]) }
        }
        RunLoop.main.add(timer, forMode: .common)
        restTimer = timer
    }

    override func mouseDragged(with e: NSEvent) { move(to: convert(e.locationInWindow, from: nil), tool: tool(e.modifierFlags)) }

    func move(to p: CGPoint, tool t: InkTool) {
        guard let s = stroke else { return }
        moveHalo(p)
        if s.move(to: p, tool: t) { showLive() }
    }

    override func mouseUp(with e: NSEvent) { end() }

    func end() {
        restTimer?.invalidate()
        restTimer = nil
        guard let l = live, let s = stroke else { return }
        live = nil
        stroke = nil
        var keep = s.kept(minGap: 3)                   // thinned out for the log: ≥ 3 pt apart, at most ~120 points
        if keep.count == 1 { l.path = inkPath(keep, ring: 18) }       // a tap: ring the spot
        if !s.isShape, keep.count > 120 {
            keep = stride(from: 0, to: keep.count, by: keep.count / 120 + 1).map { keep[$0] } + [keep[keep.count - 1]]
        }
        let r3 = { (v: CGFloat) in (max(0, min(1, v)) * 1000).rounded() / 1000 }
        rec?.log("stroke", ["t0": (t0 * 1000).rounded() / 1000, "visible": InkView.visible, "shape": s.kind,
                            "points": keep.map { [r3($0.x / bounds.width), r3($0.y / bounds.height)] }])
        emit(["event": "ink_stroke", "shape": s.kind, "points": keep.count, "recording": true])
        done.append(l)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let layers = self.done
            self.done = []
            CATransaction.begin()
            CATransaction.setCompletionBlock { layers.forEach { $0.removeFromSuperlayer() } }
            for l in layers {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 1
                a.toValue = 0
                a.duration = 0.5
                l.opacity = 0
                l.add(a, forKey: "fade")
            }
            CATransaction.commit()
        }
        fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + InkView.visible, execute: work)
        island.orderFront()          // keep the island clickable above the ink
        rec?.syncInk()
    }
}
