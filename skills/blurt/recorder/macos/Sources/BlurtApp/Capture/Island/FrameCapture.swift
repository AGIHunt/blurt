// Frames of the app's own windows, rendered offscreen (CALayer.render, no screen capture, no Screen Recording grant):
// the island, the hanging cards, notes, flights — composited in z-order over a backdrop picture, cropped to a rect. For the
// docs / launch GIFs and scripted visual checks (test command `framerec`); never on in normal use.
import AppKit

final class FrameCapture {
    private static var running: FrameCapture?
    private let dir: URL
    private let rect: CGRect               // global top-left points
    private let backdrop: CGImage?
    private let until: CFTimeInterval
    private let cursor: Bool
    private var n = 0
    private var timer: Timer?
    static let scale: CGFloat = 2
    private static let io = DispatchQueue(label: "blurt.framecapture", qos: .utility)

    /// `framerec DIR SECS X,Y,W,H [BACKDROP.png|-] [fps] [cursor]`
    static func start(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        guard a.count >= 3, let secs = Double(a[1]) else { return }
        let r = a[2].split(separator: ",").compactMap { Double($0) }
        guard r.count == 4 else { return }
        let bd = a.count > 3 && a[3] != "-" ? loadCGImage(URL(fileURLWithPath: a[3])) : nil
        let fps = a.count > 4 ? Double(a[4]) ?? 30 : 30
        running?.stop()
        let f = FrameCapture(dir: URL(fileURLWithPath: a[0]), rect: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]), backdrop: bd,
                             secs: secs, cursor: a.contains("cursor"))
        running = f
        f.run(fps: fps)
    }

    private init(dir: URL, rect: CGRect, backdrop: CGImage?, secs: Double, cursor: Bool) {
        self.dir = dir
        self.rect = rect
        // crop the backdrop (the main screen at 2x) to the rect once, not every frame
        let s = FrameCapture.scale
        self.backdrop = backdrop.flatMap { $0.cropping(to: CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s)) }
        self.cursor = cursor
        until = CACurrentMediaTime() + secs
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func run(fps: Double) {
        let t = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in self?.grab() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        emit(["event": "framerec", "dir": dir.path, "frames": n])
        FrameCapture.running = nil
    }

    private func grab() {
        guard CACurrentMediaTime() < until || n == 0 else { stop(); return }
        let s = FrameCapture.scale
        let W = Int(rect.width * s), H = Int(rect.height * s)
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let ns = toNS(rect)
        if let b = backdrop { ctx.draw(b, in: CGRect(x: 0, y: 0, width: W, height: H)) }
        let order = NSApp.orderedWindows
        let wins = NSApp.windows.filter { $0.isVisible && $0.alphaValue > 0.01 && $0.frame.intersects(ns) }
            .sorted { a, b in
                if a.level != b.level { return a.level.rawValue < b.level.rawValue }
                return (order.firstIndex(of: a) ?? 0) > (order.firstIndex(of: b) ?? 0)
            }
        for w in wins {
            guard let v = w.contentView, let l = v.layer else { continue }
            ctx.saveGState()
            ctx.translateBy(x: (w.frame.minX - ns.minX) * s, y: (w.frame.minY - ns.minY) * s)
            ctx.scaleBy(x: s, y: s)
            ctx.setAlpha(w.alphaValue)
            if v.isFlipped || l.isGeometryFlipped {            // render(in:) draws in the layer's own (flipped) space
                ctx.translateBy(x: 0, y: v.bounds.height)
                ctx.scaleBy(x: 1, y: -1)
            }
            l.render(in: ctx)
            ctx.restoreGState()
        }
        if cursor { drawCursor(ctx, ns) }
        guard let img = ctx.makeImage() else { return }
        n += 1
        let u = dir.appendingPathComponent(String(format: "frame-%05d.png", n))
        FrameCapture.io.async { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: u) }
    }

    private func drawCursor(_ ctx: CGContext, _ ns: NSRect) {
        let m = NSEvent.mouseLocation
        let s = FrameCapture.scale
        let p = CGPoint(x: (m.x - ns.minX) * s, y: (m.y - ns.minY) * s)
        let arrow = CGMutablePath()
        arrow.move(to: p)
        arrow.addLine(to: CGPoint(x: p.x, y: p.y - 17 * s))
        arrow.addLine(to: CGPoint(x: p.x + 4.2 * s, y: p.y - 13 * s))
        arrow.addLine(to: CGPoint(x: p.x + 7 * s, y: p.y - 19 * s))
        arrow.addLine(to: CGPoint(x: p.x + 9.5 * s, y: p.y - 18 * s))
        arrow.addLine(to: CGPoint(x: p.x + 6.8 * s, y: p.y - 12 * s))
        arrow.addLine(to: CGPoint(x: p.x + 12 * s, y: p.y - 12 * s))
        arrow.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1 * s), blur: 3 * s, color: CGColor(gray: 0, alpha: 0.4))
        ctx.addPath(arrow); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(arrow); ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(1.2 * s); ctx.strokePath()
    }
}
