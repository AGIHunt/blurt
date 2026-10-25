// The pen (v0.9-next): one set of rules for a snap and for a recording (BlurtCore Ink.swift).
//
//  • a plain drag draws freehand, ⇧-drag a box, ⌥-drag an ellipse (the modifiers are read on every move, so ⇧ pressed
//    mid-drag turns the stroke into a box); holding still ~0.5 s at the end of a freehand stroke snaps a rough line,
//    box or ellipse to a clean one (InkFit — plain geometry). While recording the same modifiers go with the pen key:
//    ⌃-drag, ⌃⇧, ⌃⌥ (record.draw_key; with ⌥ as the pen key the ellipse is ⌃⌥), the pen key first (PenArm: a ⌃⌥
//    chord pressed together is the window manager's). Letting go of ⇧ / ⌥ mid-drag carries on freehand from the pointer.
//  • one colour, BrandColor.markup, with a soft dark shadow so it reads on any background; the line is wider on a
//    bigger display (InkStyle.width).
//  • InkStroke (BlurtCore) builds the stroke being drawn (shared by both views); inkPath draws a point list the way every renderer
//    does (quadratic curves through the midpoints; renderMarked, the review page and frames.py read the same points).
//  • InkCanvas: the pen on a picture — the snap's frozen selection (InkStage) and Edit Note's picture (NoteBubble).
//    Strokes are 0–1 point lists of the picture (shots.jsonl "strokes"); ⌘Z takes back the last one (undo()).
//  • InkView: the pen while recording. It covers the recorded area, click-through until the pen is on (its key held, or
//    latched with ⌥⇧D); ink fades a few seconds after the last stroke, so a circle and the arrow drawn right after it
//    share a frame. Unlike the rest of the chrome this window *is* captured, and each stroke is logged to events.jsonl
//    in the same 0–1 coordinates as clicks ("shape": free | box | ellipse | line | rect, the fitted ones).
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

/// The pen's look on a layer: the markup colour, round ends, a soft dark shadow (reads on light and dark pages).
func styleInk(_ l: CAShapeLayer, width: CGFloat) {
    l.fillColor = nil
    l.strokeColor = BrandColor.Island.markup.cgColor      // BrandColor.markup: one value light and dark
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

final class InkCanvas: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var strokes: [[[Double]]] = [] { didSet { redrawInk() } }
    var editable = true { didSet { window?.invalidateCursorRects(for: self) } }
    /// the line in points (InkStyle.width for the display, or scaled for an enlarged preview)
    var lineWidth: CGFloat = 3.5 { didSet { styleInk(live, width: lineWidth); redrawInk() } }
    var onChange: (() -> Void)?
    /// a stroke went down / the pen moved / it was lifted (the bubble holds its close while the pen is on the picture)
    var onStrokeBegan: (() -> Void)?
    var onStrokeMoved: (() -> Void)?
    var onStrokeEnded: (() -> Void)?
    private var stroke: InkStroke?
    private var restTimer: Timer?
    /// a stroke is being drawn
    var isDrawing: Bool { stroke != nil }
    private let inkLayer = CALayer()
    private let live = CAShapeLayer()

    init(frame: NSRect, corner: CGFloat = 8) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = corner
        layer?.masksToBounds = true
        layer?.addSublayer(inkLayer)
        styleInk(live, width: lineWidth)
        inkLayer.addSublayer(live)
    }
    override convenience init(frame: NSRect) { self.init(frame: frame, corner: 8) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { if editable { addCursorRect(bounds, cursor: .crosshair) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // the app is not active while the pen is on a snap: cursor rects alone don't apply then
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { (editable ? NSCursor.crosshair : NSCursor.arrow).set() }

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

    func redrawInk() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkLayer.sublayers?.filter { $0 !== live }.forEach { $0.removeFromSuperlayer() }
        for s in strokes {
            let l = CAShapeLayer()
            styleInk(l, width: lineWidth)
            l.path = inkPath(s.map { CGPoint(x: CGFloat($0[0]) * bounds.width, y: CGFloat($0[1]) * bounds.height) }, ring: ring)
            inkLayer.insertSublayer(l, below: live)
        }
        CATransaction.commit()
    }

    func local(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    static func tool(_ flags: NSEvent.ModifierFlags) -> InkTool {
        InkModifiers.snapTool(shift: flags.contains(.shift), option: flags.contains(.option))
    }

    private func showLive() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        live.path = stroke.map { inkPath($0.display, ring: ring) }
        CATransaction.commit()
    }

    override func mouseDown(with e: NSEvent) {
        guard editable else { return }
        begin(at: local(e), tool: InkCanvas.tool(e.modifierFlags))
    }

    override func mouseDragged(with e: NSEvent) {
        guard editable, stroke != nil else { return }
        move(to: local(e), tool: InkCanvas.tool(e.modifierFlags))
    }

    override func mouseUp(with e: NSEvent) {
        guard editable, stroke != nil else { return }
        flush()
        onStrokeEnded?()
    }

    func begin(at p: CGPoint, tool: InkTool) {
        stroke = InkStroke(at: p, tool: tool)
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
        if s.move(to: p, tool: tool) { showLive() }
        onStrokeMoved?()
    }

    /// The stroke being drawn becomes a stroke now (mouse-up, or the bubble closing under the pen: ⏎, ⌥⇧A).
    func flush() {
        restTimer?.invalidate()
        restTimer = nil
        guard let s = stroke else { return }
        stroke = nil
        let keep = s.kept(minGap: 2)
        let r3 = { (v: CGFloat) in Double((v * 1000).rounded() / 1000) }
        strokes.append(keep.map { [r3(min(max($0.x, 0), bounds.width) / max(1, bounds.width)),
                                   r3(min(max($0.y, 0), bounds.height) / max(1, bounds.height))] })
        emit(["event": "ink_stroke", "shape": s.kind, "points": keep.count, "strokes": strokes.count])
        live.path = nil
        onChange?()
    }

    /// ⌘Z: the last stroke goes. False when there was none.
    @discardableResult
    func undo() -> Bool {
        guard !strokes.isEmpty else { return false }
        strokes.removeLast()
        emit(["event": "ink_undo", "strokes": strokes.count])
        onChange?()
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

    func setOn(_ on: Bool) {
        guard live == nil else { return }     // finish the stroke in progress first
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

    /// What a drag draws now: the pen key's modifiers (⌃⇧ box, ⌃⌥ ellipse); a latched pen (⌥⇧D) takes ⇧ / ⌥ alone.
    func tool(_ flags: NSEvent.ModifierFlags) -> InkTool {
        if let pen = rec?.penKind,
           let t = InkModifiers.recordingTool(pen: pen, control: flags.contains(.control), option: flags.contains(.option),
                                              shift: flags.contains(.shift), command: flags.contains(.command),
                                              fn: flags.contains(.function)) { return t }
        return InkModifiers.snapTool(shift: flags.contains(.shift), option: flags.contains(.option))
    }

    private func showLive() {
        guard let l = live, let s = stroke else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.path = inkPath(s.display, ring: 18)
        CATransaction.commit()
    }

    override func mouseMoved(with e: NSEvent) { moveHalo(convert(e.locationInWindow, from: nil)) }

    override func mouseDown(with e: NSEvent) { begin(at: convert(e.locationInWindow, from: nil), tool: tool(e.modifierFlags)) }

    func begin(at p: CGPoint, tool t: InkTool) {
        fade?.cancel()
        stroke = InkStroke(at: p, tool: t)
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
