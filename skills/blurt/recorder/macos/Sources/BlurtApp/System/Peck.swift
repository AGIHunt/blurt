// "Fixed" moment: when an agent marks an item fixed (MCP mark_fixed / items.py fix → fix.state "fixed"), a small card
// slides in under the menu bar and the chicken pecks the bug away (~1 s), with the item's title. Vector art in the
// eggs' style (Eggs.swift): the hen's body is a golden egg (eggPath + the idea egg's palette), the bug is drawBug.
// Reduce motion: no pecking, the bug just fades. Clicking the card opens the item.
import AppKit
import BlurtCore

/// Pure drawing of the scene at time t (seconds), y-up, in a 110 × 110 box. Shared by the live view and the GIF export.
enum PeckArt {
    static let duration: Double = 1.15

    private static let ink = CGColor(srgbRed: 0.17, green: 0.13, blue: 0.09, alpha: 1)
    private static let comb = CGColor(srgbRed: 0.95, green: 0.30, blue: 0.20, alpha: 1)
    private static let beakC = CGColor(srgbRed: 1.0, green: 0.55, blue: 0.16, alpha: 1)
    private static let yellow = CGColor(srgbRed: 1.0, green: 0.80, blue: 0.20, alpha: 1)
    private static let yellowDark = CGColor(srgbRed: 0.93, green: 0.64, blue: 0.10, alpha: 1)

    /// 0 = upright, 1 = beak on the bug. Two pecks; the second one lands at 0.58 s.
    static func peck(_ t: Double) -> CGFloat {
        func bump(_ a: Double, _ b: Double, _ c: Double) -> Double {      // ease down a→b, up b→c
            if t <= a || t >= c { return 0 }
            if t < b { let u = (t - a) / (b - a); return u * u * (3 - 2 * u) }
            let u = (t - b) / (c - b); return 1 - u * u * (3 - 2 * u)
        }
        return CGFloat(max(bump(0.10, 0.24, 0.38) * 0.75, bump(0.42, 0.58, 0.80)))
    }
    static let squashAt: Double = 0.58

    static func draw(_ ctx: CGContext, t: Double, reduceMotion: Bool = false) {
        let p: CGFloat = reduceMotion ? 0 : peck(t)
        let hop: CGFloat = reduceMotion ? 0 : CGFloat(max(0, sin((t - 0.85) / 0.25 * .pi))) * (t > 0.85 && t < 1.10 ? 5 : 0)
        ctx.saveGState()
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        // ground shadow
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.13))
        ctx.fillEllipse(in: CGRect(x: 22, y: 8, width: 52, height: 7))

        // the bug, then its end
        let squash = reduceMotion ? min(1, max(0, (t - 0.3) / 0.5)) : min(1, max(0, (t - squashAt) / 0.14))
        if squash < 1 {
            ctx.saveGState()
            let wiggle = squash == 0 && !reduceMotion ? CGFloat(sin(t * 38)) * 1.2 : 0
            ctx.translateBy(x: 98 + wiggle, y: 13)
            ctx.scaleBy(x: 1 + squash * 0.5, y: 1 - squash * 0.75)
            ctx.setAlpha(1 - squash)
            drawBug(ctx, at: .zero, size: 19)
            ctx.restoreGState()
        }
        if !reduceMotion, t > squashAt, t < squashAt + 0.45 {             // poof: little stars flying off
            let u = CGFloat((t - squashAt) / 0.45)
            ctx.saveGState()
            ctx.setAlpha(1 - u)
            for (i, ang) in [CGFloat(2.2), 1.4, 0.6].enumerated() {
                let r = 6 + u * (16 + CGFloat(i) * 3)
                let c = CGPoint(x: 98 + cos(ang) * r, y: 14 + sin(ang) * r)
                star(ctx, at: c, size: 11 - u * 4)
            }
            ctx.restoreGState()
        }

        ctx.translateBy(x: 0, y: hop)
        // legs (stay planted)
        ctx.setStrokeColor(beakC)
        ctx.setLineWidth(3)
        for x in [CGFloat(40), 52] {
            ctx.move(to: CGPoint(x: x, y: 28)); ctx.addLine(to: CGPoint(x: x, y: 13))
            ctx.move(to: CGPoint(x: x - 4, y: 12)); ctx.addLine(to: CGPoint(x: x + 5, y: 12))
        }
        ctx.strokePath()

        // body: a golden egg on its side, tilting forward around the hip while pecking
        let hip = CGPoint(x: 46, y: 28)
        let tilt = -0.32 * p
        ctx.saveGState()
        ctx.translateBy(x: hip.x, y: hip.y)
        ctx.rotate(by: tilt)
        ctx.translateBy(x: -hip.x, y: -hip.y)
        // tail feathers
        ctx.setFillColor(yellowDark)
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(2.2)
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: 26, y: 50))
        tail.addQuadCurve(to: CGPoint(x: 10, y: 66), control: CGPoint(x: 12, y: 52))
        tail.addQuadCurve(to: CGPoint(x: 20, y: 60), control: CGPoint(x: 16, y: 64))
        tail.addQuadCurve(to: CGPoint(x: 14, y: 74), control: CGPoint(x: 14, y: 66))
        tail.addQuadCurve(to: CGPoint(x: 34, y: 56), control: CGPoint(x: 30, y: 70))
        tail.closeSubpath()
        ctx.addPath(tail); ctx.drawPath(using: .fillStroke)
        // the egg body
        ctx.saveGState()
        ctx.translateBy(x: 46, y: 44)
        ctx.rotate(by: -1.75)                                  // narrow end towards the tail
        let body = eggPath(in: CGRect(x: -22, y: -27, width: 44, height: 54))
        ctx.addPath(body)
        ctx.saveGState()
        ctx.clip()
        let pal = eggPalette(.idea, seed: 1)
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [pal.light, pal.base, pal.dark] as CFArray,
                              locations: [0, 0.5, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: -8, y: 10), startRadius: 0, endCenter: .zero, endRadius: 34,
                                   options: [.drawsAfterEndLocation])
        }
        ctx.restoreGState()
        ctx.addPath(body)
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(2.4)
        ctx.strokePath()
        ctx.restoreGState()
        // wing
        let wing = CGMutablePath()
        wing.move(to: CGPoint(x: 34, y: 48))
        wing.addQuadCurve(to: CGPoint(x: 58, y: 42), control: CGPoint(x: 46, y: 58))
        wing.addQuadCurve(to: CGPoint(x: 34, y: 48), control: CGPoint(x: 46, y: 34))
        ctx.setFillColor(yellowDark)
        ctx.addPath(wing); ctx.drawPath(using: .fillStroke)
        let neckBase = CGPoint(x: 60, y: 56)
        ctx.restoreGState()

        // neck + head, swinging from upright to the bug
        let base = rotate(neckBase, around: hip, by: tilt)
        let rest = CGPoint(x: 70, y: 76), down = CGPoint(x: 90, y: 32)
        let head = CGPoint(x: rest.x + (down.x - rest.x) * p, y: rest.y + (down.y - rest.y) * p)
        ctx.setStrokeColor(ink); ctx.setLineWidth(15.5)
        ctx.move(to: base); ctx.addLine(to: head); ctx.strokePath()
        ctx.setStrokeColor(yellow); ctx.setLineWidth(11)
        ctx.move(to: base); ctx.addLine(to: head); ctx.strokePath()

        ctx.saveGState()
        ctx.translateBy(x: head.x, y: head.y)
        ctx.rotate(by: -1.05 * p)
        // comb
        ctx.setFillColor(comb); ctx.setStrokeColor(ink); ctx.setLineWidth(2)
        for (dx, dy, r) in [(CGFloat(-7), CGFloat(13), CGFloat(5)), (0, 15, 5.5), (7, 12.5, 4.5)] {
            ctx.addEllipse(in: CGRect(x: dx - r, y: dy - r, width: r * 2, height: r * 2))
        }
        ctx.drawPath(using: .fillStroke)
        // wattle
        ctx.addEllipse(in: CGRect(x: 6, y: -15, width: 7, height: 9))
        ctx.drawPath(using: .fillStroke)
        // head
        ctx.setFillColor(yellow)
        ctx.addEllipse(in: CGRect(x: -12, y: -12, width: 24, height: 24))
        ctx.drawPath(using: .fillStroke)
        // beak
        let beak = CGMutablePath()
        beak.move(to: CGPoint(x: 9, y: 4)); beak.addLine(to: CGPoint(x: 21, y: -1)); beak.addLine(to: CGPoint(x: 9, y: -5)); beak.closeSubpath()
        ctx.setFillColor(beakC)
        ctx.addPath(beak); ctx.drawPath(using: .fillStroke)
        // eye (a happy squint once the bug is gone)
        ctx.setFillColor(ink)
        if t > squashAt + 0.1 && !reduceMotion {
            ctx.setLineWidth(1.8)
            ctx.move(to: CGPoint(x: 0, y: 2)); ctx.addQuadCurve(to: CGPoint(x: 7, y: 2), control: CGPoint(x: 3.5, y: 6.5)); ctx.strokePath()
        } else {
            ctx.fillEllipse(in: CGRect(x: 1.5, y: 0.5, width: 5, height: 5.5))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 3.6, y: 3.2, width: 1.6, height: 1.6))
        }
        ctx.restoreGState()
        ctx.restoreGState()
    }

    private static func rotate(_ p: CGPoint, around c: CGPoint, by a: CGFloat) -> CGPoint {
        let dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * cos(a) - dy * sin(a), y: c.y + dx * sin(a) + dy * cos(a))
    }

    private static func star(_ ctx: CGContext, at c: CGPoint, size s: CGFloat) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x, y: c.y + s / 2))
        p.addQuadCurve(to: CGPoint(x: c.x + s / 2, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - s / 2), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x - s / 2, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + s / 2), control: c)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.72, blue: 0.15, alpha: 1))
        ctx.addPath(p); ctx.fillPath()
    }
}

final class PeckSceneView: NSView {
    var t: Double = 0 { didSet { needsDisplay = true } }
    var reduceMotion = false
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = min(bounds.width, bounds.height) / 110
        ctx.saveGState()
        ctx.translateBy(x: (bounds.width - 110 * s) / 2, y: (bounds.height - 110 * s) / 2)
        ctx.scaleBy(x: s, y: s)
        PeckArt.draw(ctx, t: t, reduceMotion: reduceMotion)
        ctx.restoreGState()
    }
}

/// The card: scene on the left, "Fixed" + the item title on the right. One at a time; more fixes queue up.
final class PeckCard: NSObject {
    static let shared = PeckCard()
    private var panel: NSPanel?
    private var scene: PeckSceneView?
    private var queue: [(title: String, detail: String, uid: String)] = []
    private var busy = false
    private var timer: Timer?
    private var clickUID: String?
    var leadIn: Double = 0.15          // card visible → pecking starts (tests record the screen: longer)

    func play(title: String, detail: String, uid: String) {
        queue.append((title, detail, uid))
        if !busy { next() }
    }

    private func next() {
        guard !queue.isEmpty else { busy = false; return }
        busy = true
        let job = queue.removeFirst()
        clickUID = job.uid
        let w: CGFloat = 340, h: CGFloat = 104
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: screen.maxX - w - 16, y: screen.maxY - h - 16, width: w, height: h)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.sharingType = chromeSharing
        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        fx.material = .popover
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 14
        fx.layer?.masksToBounds = true
        let sc = PeckSceneView(frame: NSRect(x: 6, y: 2, width: 100, height: 100))
        sc.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        fx.addSubview(sc)
        let headText = NSTextField(labelWithString: L("修好了", "Fixed"))
        headText.font = .systemFont(ofSize: 13, weight: .semibold)
        headText.textColor = .systemGreen
        let check = NSImageView(image: brandNSImage(.peck, size: 16))
        check.contentTintColor = .systemGreen
        let head = NSStackView(views: [check, headText])
        head.spacing = 4
        let title = NSTextField(wrappingLabelWithString: job.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 2
        title.preferredMaxLayoutWidth = w - 126
        title.cell?.wraps = true
        let detail = NSTextField(labelWithString: job.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [head, title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.frame = NSRect(x: 112, y: 14, width: w - 126, height: h - 28)
        fx.addSubview(stack)
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        fx.addGestureRecognizer(click)
        p.contentView = fx
        p.alphaValue = 0
        p.orderFrontRegardless()
        panel = p
        scene = sc
        let cg = toCG(frame)
        emit(["event": "peck", "uid": job.uid, "title": job.title, "frame": [Int(cg.minX), Int(cg.minY), Int(cg.width), Int(cg.height)]])
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; p.animator().alphaValue = 1 }
        let t0 = CACurrentMediaTime() + leadIn
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] tm in
            guard let self = self else { tm.invalidate(); return }
            let t = CACurrentMediaTime() - t0
            self.scene?.t = max(0, min(t, PeckArt.duration + 0.4))
            if t > PeckArt.duration + 2.6 {
                tm.invalidate()
                self.dismiss()
            }
        }
    }

    @objc private func clicked() {
        if let u = clickUID { _ = URLRouter.handle(URL(string: "blurt://item/\(u)")!) }
        dismiss()
    }

    private func dismiss() {
        timer?.invalidate()
        guard let p = panel else { return next() }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }, completionHandler: {
            p.orderOut(nil)
            self.next()
        })
    }

    /// Frames of the animation as PNGs (tests / docs: the GIF in the report is made from these).
    static func renderFrames(to dir: URL, fps: Double = 30, scale: CGFloat = 2, dark: Bool = false) -> Int {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let n = Int((PeckArt.duration + 0.5) * fps)
        for i in 0..<n {
            let t = Double(i) / fps
            let w = Int(110 * scale), h = Int(110 * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            ctx.setFillColor(dark ? CGColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1) : CGColor(srgbRed: 0.97, green: 0.96, blue: 0.94, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            PeckArt.draw(ctx, t: t)
            guard let img = ctx.makeImage() else { continue }
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(String(format: "f%03d.png", i)))
        }
        return n
    }
}
