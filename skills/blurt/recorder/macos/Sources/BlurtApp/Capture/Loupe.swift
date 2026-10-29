// The loupe every area picker shows (⌥A snap, ⌥R record, ⌥C / ⌥T text, as Bob's OCR): the screen frozen into one
// still per display the moment the picker opens, magnified 8× around the pointer (nearest neighbour: a pixel grid),
// the pixel under it framed, a crosshair through it, and a label under it (the point, or the selection's size).
//
// The picker's windows stay invisible (alpha 0) until the stills are in: a still taken while they show would hold the
// picker itself — the first loupe, drawn black before there was anything to magnify, came back inside the loupe when
// the pointer crossed that spot (ScreenCaptureKit doesn't list a window ordered front a moment ago, so it isn't
// excluded). No still (no Screen Recording, a capture that failed): the windows show after 0.6 s, without a loupe.
import AppKit
import BlurtCore

final class LoupeStills {
    private(set) var stills: [(frame: NSRect, image: CGImage, scale: CGFloat)] = []
    private var cancelled = false

    /// One still per screen, then `done` (main queue) once all are in or 0.6 s passed, whichever is first.
    func capture(_ screens: [NSScreen], done: @escaping () -> Void) {
        var left = screens.count, called = false
        let finish = { if !called { called = true; done() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { finish() }
        for s in screens {
            let frame = s.frame
            captureStill(rect: toCG(frame), showsCursor: false) { [weak self] img, scale in
                guard let self = self, !self.cancelled else { return }
                if let img = img { self.stills.append((frame, img, scale)) }
                left -= 1
                if left == 0 { finish() }
            }
        }
        if screens.isEmpty { finish() }
    }

    func cancel() { cancelled = true }

    func still(at p: NSPoint) -> (frame: NSRect, image: CGImage, scale: CGFloat)? { stills.first { $0.frame.contains(p) } }

    /// The selection (global AppKit points) cut out of the still it lies in; nil across screens or without one.
    func crop(_ s: NSRect) -> CGImage? {
        guard let st = stills.first(where: { $0.frame.contains(s) }) else { return nil }
        let px = CGRect(x: (s.minX - st.frame.minX) * st.scale, y: (st.frame.maxY - s.maxY) * st.scale,
                        width: s.width * st.scale, height: s.height * st.scale).integral
        return st.image.cropping(to: px)
    }
}

enum Loupe {
    static let size: CGFloat = 120          // points
    static let zoom: CGFloat = 8
    static let gap: CGFloat = 18
    static let labelH: CGFloat = 22

    /// Where the loupe and its label sit for `pointer` (global) in `view` (its window's coordinates): below-right of
    /// the pointer, flipped at the screen's edges. What to invalidate when the pointer moves.
    static func frame(for pointer: NSPoint, in view: NSView) -> NSRect {
        guard let w = view.window else { return .zero }
        let at = NSPoint(x: pointer.x - w.frame.minX, y: pointer.y - w.frame.minY)
        var o = NSPoint(x: at.x + gap, y: at.y - gap - size - labelH)
        if o.x + size > view.bounds.maxX - 4 { o.x = at.x - gap - size }
        if o.y < 4 { o.y = at.y + gap }
        return NSRect(x: o.x, y: o.y, width: size, height: size + labelH)
    }

    /// The label for the point under the pointer: top-left points, as selections are measured.
    static func pointLabel(_ pointer: NSPoint) -> String {
        let g = toCG(NSRect(origin: pointer, size: .zero))
        return "\(Int(g.minX.rounded())), \(Int(g.minY.rounded()))"
    }

    static func sizeLabel(_ s: NSRect) -> String { "\(Int(s.width.rounded()))\u{2009}×\u{2009}\(Int(s.height.rounded()))" }

    /// Draws it (inside the view's draw); nothing without a still under the pointer.
    static func draw(pointer: NSPoint, in view: NSView, stills: LoupeStills, label: String) {
        guard let w = view.window, w.frame.contains(pointer), let st = stills.still(at: pointer),
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        let f = frame(for: pointer, in: view)
        let box = NSRect(x: f.minX, y: f.minY + labelH, width: size, height: size)
        let shape = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
        shadow.set()
        NSColor(white: 0.08, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        ctx.saveGState()
        shape.addClip()
        let span = size / zoom                      // points of the screen shown
        let px = CGRect(x: (pointer.x - st.frame.minX - span / 2) * st.scale, y: (st.frame.maxY - pointer.y - span / 2) * st.scale,
                        width: span * st.scale, height: span * st.scale).integral
        if let part = st.image.cropping(to: px) {
            ctx.interpolationQuality = .none
            ctx.draw(part, in: box)
        }
        // the pixel under the pointer framed, the crosshair through it (the selection's colour)
        let cell = zoom / max(1, st.scale)
        let c = NSPoint(x: box.midX, y: box.midY)
        BrandColor.Island.selection.setStroke()
        let lines = NSBezierPath()
        lines.lineWidth = 1
        lines.move(to: NSPoint(x: box.minX, y: c.y)); lines.line(to: NSPoint(x: c.x - cell, y: c.y))
        lines.move(to: NSPoint(x: c.x + cell, y: c.y)); lines.line(to: NSPoint(x: box.maxX, y: c.y))
        lines.move(to: NSPoint(x: c.x, y: box.minY)); lines.line(to: NSPoint(x: c.x, y: c.y - cell))
        lines.move(to: NSPoint(x: c.x, y: c.y + cell)); lines.line(to: NSPoint(x: c.x, y: box.maxY))
        lines.stroke()
        NSBezierPath(rect: NSRect(x: c.x - cell, y: c.y - cell, width: cell * 2, height: cell * 2)).stroke()
        ctx.restoreGState()
        NSColor(white: 1, alpha: 0.9).setStroke()
        let rim = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        rim.lineWidth = 1
        rim.stroke()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let a = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor(white: 1, alpha: 0.92)])
        let tw = ceil(a.size().width) + 16
        let pill = NSRect(x: box.midX - tw / 2, y: f.minY, width: tw, height: labelH - 4)
        NSColor(white: 0.08, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        a.draw(at: NSPoint(x: pill.minX + 8, y: pill.midY - a.size().height / 2))
    }
}
