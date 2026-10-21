import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import ServiceManagement

// MARK: - Pen: draw on the screen while recording

/// Covers the recorded area. Click-through until the pen is on (pen key held, or toggled from the HUD / ⌥⇧D); then a
/// drag draws a stroke. Ink fades a few seconds after the last stroke, so a circle and the arrow drawn right after
/// it share a frame. Unlike the rest of the chrome this window *is* captured, and each stroke is logged to
/// events.jsonl in the same 0–1 coordinates as clicks.
final class InkView: NSView {
    static let visible = 3.0          // seconds the ink stays after the last stroke
    weak var rec: Recorder?
    var pts: [NSPoint] = []
    var live: CAShapeLayer?
    var done: [CAShapeLayer] = []     // finished strokes still on screen
    var fade: DispatchWorkItem?
    var t0 = 0.0
    let halo = CAShapeLayer()         // small ring at the cursor: "the pen is on"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        halo.path = CGPath(ellipseIn: CGRect(x: -9, y: -9, width: 18, height: 18), transform: nil)
        halo.fillColor = accent.withAlphaComponent(0.25).cgColor
        halo.strokeColor = accent.cgColor
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

    func shape() -> CAShapeLayer {
        let l = CAShapeLayer()
        l.fillColor = nil
        l.strokeColor = accent.cgColor
        l.lineWidth = 4
        l.lineCap = .round
        l.lineJoin = .round
        l.shadowColor = NSColor.black.cgColor     // stays readable on light and dark pages
        l.shadowOpacity = 0.45
        l.shadowRadius = 1.5
        l.shadowOffset = .zero
        return l
    }

    func path() -> CGPath {
        let p = CGMutablePath()
        guard let first = pts.first else { return p }
        p.move(to: first)
        if pts.count < 3 { pts.dropFirst().forEach { p.addLine(to: $0) }; return p }
        for i in 1..<pts.count - 1 {              // through the midpoints: smooth without lagging behind the hand
            p.addQuadCurve(to: NSPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2), control: pts[i])
        }
        p.addLine(to: pts[pts.count - 1])
        return p
    }

    override func mouseMoved(with e: NSEvent) { moveHalo(convert(e.locationInWindow, from: nil)) }

    override func mouseDown(with e: NSEvent) {
        fade?.cancel()
        pts = [convert(e.locationInWindow, from: nil)]
        t0 = rec?.elapsed() ?? 0
        let l = shape()
        layer?.insertSublayer(l, below: halo)
        live = l
    }

    override func mouseDragged(with e: NSEvent) {
        guard let l = live, let last = pts.last else { return }
        let p = convert(e.locationInWindow, from: nil)
        moveHalo(p)
        guard hypot(p.x - last.x, p.y - last.y) >= 1.5 else { return }
        pts.append(p)
        l.path = path()
    }

    override func mouseUp(with e: NSEvent) {
        guard let l = live else { return }
        live = nil
        let length = zip(pts, pts.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        if length < 6 {                            // a tap: ring the spot
            pts = [pts[0]]
            l.path = CGPath(ellipseIn: CGRect(x: pts[0].x - 18, y: pts[0].y - 18, width: 36, height: 36), transform: nil)
        }
        var keep: [NSPoint] = []                   // thin out for the log: ≥ 3 pt apart, at most ~120 points
        for p in pts where keep.last.map({ hypot(p.x - $0.x, p.y - $0.y) >= 3 }) ?? true { keep.append(p) }
        if let end = pts.last, keep.last != end { keep.append(end) }
        if keep.count > 120 { keep = stride(from: 0, to: keep.count, by: keep.count / 120 + 1).map { keep[$0] } + [keep[keep.count - 1]] }
        let r3 = { (v: CGFloat) in (max(0, min(1, v)) * 1000).rounded() / 1000 }
        rec?.log("stroke", ["t0": (t0 * 1000).rounded() / 1000, "visible": InkView.visible,
                            "points": keep.map { [r3($0.x / bounds.width), r3($0.y / bounds.height)] }])
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
        rec?.hud?.orderFrontRegardless()          // keep the pen and Done clickable when the HUD sits inside the region
        rec?.syncInk()
    }
}
