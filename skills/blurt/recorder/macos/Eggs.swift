// Eggs — one item = one egg. Drawn in code (CoreGraphics vectors), never bitmaps: crisp on Retina, fine in dark mode,
// and the same shapes can be exported as SVG for the website.
//
//   issue  speckled egg with a tiny bug        idea  golden egg (a golden idea)
//   note   white egg                            task  brown egg with a check stripe
//   custom pastel egg (hue from the lens name)
//
// Also here: the woven nest the eggs sit in (HUD + perch), and NestView — the HUD's little nest that eggs drop into
// while live drafts come in during a recording.

import AppKit
import QuartzCore

enum EggKind: String, CaseIterable {
    case issue, idea, note, task, custom

    init(_ s: String?) { self = EggKind(rawValue: (s ?? "").lowercased()) ?? ((s ?? "").isEmpty ? .note : .custom) }
}

/// Small deterministic PRNG so an egg's speckles don't change between redraws.
struct SeededRandom {
    var s: UInt64
    init(_ seed: UInt64) { s = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> CGFloat {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((s >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
    }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * next() }
}

func stableSeed(_ s: String) -> UInt64 {
    var h: UInt64 = 1469598103934665603
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
    return h
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// An egg outline in a y-up rect: narrower at the top, widest a little below the middle.
func eggPath(in r: CGRect) -> CGPath {
    let p = CGMutablePath()
    let cx = r.midX, cy = r.midY - r.height * 0.02
    let a = r.width / 2 * 0.985, b = r.height / 2 * 0.985
    let n = 96
    for i in 0...n {
        let t = CGFloat(i) / CGFloat(n) * 2 * .pi
        let s = sin(t)
        let x = cx + a * cos(t) * (s > 0 ? 1 - 0.24 * s * s : 1 - 0.04 * s * s)
        let y = cy + b * s * (s > 0 ? 1.04 : 0.96)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

struct EggPalette { let light: CGColor; let base: CGColor; let dark: CGColor; let rim: CGColor }

func eggPalette(_ kind: EggKind, seed: UInt64) -> EggPalette {
    switch kind {
    case .issue: return EggPalette(light: rgb(1.0, 0.97, 0.90), base: rgb(0.94, 0.86, 0.73), dark: rgb(0.74, 0.62, 0.47), rim: rgb(0.45, 0.34, 0.22, 0.35))
    case .idea: return EggPalette(light: rgb(1.0, 0.95, 0.62), base: rgb(0.98, 0.78, 0.25), dark: rgb(0.78, 0.50, 0.06), rim: rgb(0.55, 0.33, 0.0, 0.45))
    case .note: return EggPalette(light: rgb(1, 1, 1), base: rgb(0.96, 0.96, 0.95), dark: rgb(0.78, 0.78, 0.80), rim: rgb(0.35, 0.35, 0.40, 0.28))
    case .task: return EggPalette(light: rgb(0.93, 0.74, 0.55), base: rgb(0.78, 0.53, 0.33), dark: rgb(0.52, 0.31, 0.17), rim: rgb(0.30, 0.16, 0.06, 0.45))
    case .custom:
        var g = SeededRandom(seed)
        let h = g.next()
        let c = { (s: CGFloat, b: CGFloat, a: CGFloat) -> CGColor in
            NSColor(calibratedHue: h, saturation: s, brightness: b, alpha: a).usingColorSpace(.sRGB)!.cgColor
        }
        return EggPalette(light: c(0.12, 1.0, 1), base: c(0.30, 0.97, 1), dark: c(0.42, 0.80, 1), rim: c(0.6, 0.45, 0.35))
    }
}

/// Draws one egg (with its soft ground shadow) into `r` of a y-up context.
func drawEgg(_ ctx: CGContext, in r: CGRect, kind: EggKind, seed: UInt64 = 7, shadow: Bool = true) {
    let pal = eggPalette(kind, seed: seed)
    let body = r.insetBy(dx: r.width * 0.04, dy: r.height * 0.02).offsetBy(dx: 0, dy: shadow ? r.height * 0.02 : 0)
    let path = eggPath(in: body)
    ctx.saveGState()
    if shadow {   // contact shadow under the egg
        let sh = CGRect(x: body.midX - body.width * 0.36, y: r.minY, width: body.width * 0.72, height: max(1.5, r.height * 0.07))
        ctx.setFillColor(rgb(0, 0, 0, 0.18))
        ctx.addEllipse(in: sh)
        ctx.fillPath()
    }
    ctx.addPath(path)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // body: lit from the upper left
    if let g = CGGradient(colorsSpace: space, colors: [pal.light, pal.base, pal.dark] as CFArray, locations: [0, 0.45, 1]) {
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: body.minX + body.width * 0.36, y: body.minY + body.height * 0.68),
                               startRadius: 0, endCenter: CGPoint(x: body.midX + body.width * 0.05, y: body.midY - body.height * 0.05),
                               endRadius: body.height * 0.62, options: [.drawsAfterEndLocation])
    }
    var rnd = SeededRandom(seed)
    switch kind {
    case .issue:   // speckles
        for _ in 0..<Int(18 + rnd.next() * 10) {
            let rr = body.width * rnd.range(0.018, 0.05)
            let p = CGPoint(x: rnd.range(body.minX, body.maxX), y: rnd.range(body.minY, body.maxY))
            ctx.setFillColor(rgb(0.42 + rnd.range(-0.06, 0.06), 0.27, 0.14, rnd.range(0.35, 0.75)))
            ctx.addEllipse(in: CGRect(x: p.x - rr, y: p.y - rr * rnd.range(0.7, 1), width: rr * 2, height: rr * 2 * rnd.range(0.7, 1)))
            ctx.fillPath()
        }
    case .task:    // a pale band around the middle, with a check
        let bandY = body.minY + body.height * 0.40, bandH = body.height * 0.17
        ctx.setFillColor(rgb(0.98, 0.90, 0.76, 0.85))
        ctx.fill(CGRect(x: body.minX, y: bandY, width: body.width, height: bandH))
        ctx.setStrokeColor(rgb(0.42, 0.24, 0.10, 0.95))
        ctx.setLineWidth(max(1, body.width * 0.075))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let cy = bandY + bandH / 2
        ctx.move(to: CGPoint(x: body.midX - body.width * 0.13, y: cy + bandH * 0.02))
        ctx.addLine(to: CGPoint(x: body.midX - body.width * 0.03, y: cy - bandH * 0.32))
        ctx.addLine(to: CGPoint(x: body.midX + body.width * 0.16, y: cy + bandH * 0.40))
        ctx.strokePath()
    case .idea:    // a faint second sheen
        if let g = CGGradient(colorsSpace: space, colors: [rgb(1, 1, 0.85, 0.0), rgb(1, 1, 0.85, 0.35), rgb(1, 1, 0.85, 0)] as CFArray,
                              locations: [0, 0.5, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: body.minX, y: body.minY + body.height * 0.2),
                                   end: CGPoint(x: body.maxX, y: body.maxY - body.height * 0.1), options: [])
        }
    case .custom:  // a few soft dots
        for _ in 0..<5 {
            let rr = body.width * rnd.range(0.05, 0.09)
            let p = CGPoint(x: rnd.range(body.minX + rr, body.maxX - rr), y: rnd.range(body.minY + rr, body.maxY - rr))
            ctx.setFillColor(rgb(1, 1, 1, 0.35))
            ctx.addEllipse(in: CGRect(x: p.x - rr, y: p.y - rr, width: rr * 2, height: rr * 2))
            ctx.fillPath()
        }
    case .note: break
    }
    // terminator: darken the lower right a touch more
    if let g = CGGradient(colorsSpace: space, colors: [rgb(0, 0, 0, 0), rgb(0, 0, 0, kind == .note ? 0.10 : 0.16)] as CFArray, locations: [0.55, 1]) {
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: body.minX + body.width * 0.35, y: body.minY + body.height * 0.65), startRadius: 0,
                               endCenter: CGPoint(x: body.minX + body.width * 0.35, y: body.minY + body.height * 0.65),
                               endRadius: body.height * 0.78, options: [.drawsAfterEndLocation])
    }
    // specular highlight
    let hl = CGRect(x: body.minX + body.width * 0.20, y: body.minY + body.height * 0.58, width: body.width * 0.30, height: body.height * 0.26)
    if let g = CGGradient(colorsSpace: space, colors: [rgb(1, 1, 1, kind == .idea ? 0.95 : 0.85), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1]) {
        ctx.saveGState()
        ctx.translateBy(x: hl.midX, y: hl.midY)
        ctx.rotate(by: 0.45)
        ctx.scaleBy(x: 1, y: hl.height / hl.width)
        ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: hl.width / 2, options: [])
        ctx.restoreGState()
    }
    ctx.restoreGState()
    // rim
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(pal.rim)
    ctx.setLineWidth(max(0.5, r.width * 0.022))
    ctx.strokePath()
    ctx.restoreGState()
    if kind == .issue { drawBug(ctx, at: CGPoint(x: body.minX + body.width * 0.66, y: body.minY + body.height * 0.34), size: body.width * 0.30) }
    if kind == .idea { drawSparkle(ctx, at: CGPoint(x: body.maxX - body.width * 0.02, y: body.maxY - body.height * 0.12), size: body.width * 0.26) }
}

/// A tiny beetle (not scary: round, glossy, short legs).
func drawBug(_ ctx: CGContext, at c: CGPoint, size s: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y)
    ctx.rotate(by: -0.5)
    ctx.setStrokeColor(rgb(0.13, 0.11, 0.10, 0.95))
    ctx.setLineWidth(max(0.6, s * 0.07))
    ctx.setLineCap(.round)
    for i in -1...1 {                      // legs
        let y = CGFloat(i) * s * 0.17
        ctx.move(to: CGPoint(x: -s * 0.18, y: y)); ctx.addLine(to: CGPoint(x: -s * 0.33, y: y - s * 0.04 + CGFloat(i) * s * 0.05))
        ctx.move(to: CGPoint(x: s * 0.18, y: y)); ctx.addLine(to: CGPoint(x: s * 0.33, y: y - s * 0.04 + CGFloat(i) * s * 0.05))
    }
    ctx.move(to: CGPoint(x: -s * 0.06, y: s * 0.36)); ctx.addLine(to: CGPoint(x: -s * 0.16, y: s * 0.52))   // antennae
    ctx.move(to: CGPoint(x: s * 0.06, y: s * 0.36)); ctx.addLine(to: CGPoint(x: s * 0.16, y: s * 0.52))
    ctx.strokePath()
    ctx.setFillColor(rgb(0.16, 0.13, 0.12))
    ctx.fillEllipse(in: CGRect(x: -s * 0.13, y: s * 0.20, width: s * 0.26, height: s * 0.20))           // head
    ctx.setFillColor(rgb(0.86, 0.22, 0.16))
    ctx.fillEllipse(in: CGRect(x: -s * 0.25, y: -s * 0.30, width: s * 0.50, height: s * 0.58))         // shell
    ctx.setStrokeColor(rgb(0.16, 0.10, 0.10, 0.9))
    ctx.setLineWidth(max(0.5, s * 0.045))
    ctx.move(to: CGPoint(x: 0, y: -s * 0.29)); ctx.addLine(to: CGPoint(x: 0, y: s * 0.27))
    ctx.strokePath()
    ctx.setFillColor(rgb(0.16, 0.10, 0.10, 0.9))
    for (x, y) in [(-0.12, 0.05), (0.12, 0.05), (-0.10, -0.15), (0.11, -0.16)] as [(CGFloat, CGFloat)] {
        ctx.fillEllipse(in: CGRect(x: x * s - s * 0.045, y: y * s - s * 0.045, width: s * 0.09, height: s * 0.09))
    }
    ctx.setFillColor(rgb(1, 1, 1, 0.55))
    ctx.fillEllipse(in: CGRect(x: -s * 0.17, y: s * 0.06, width: s * 0.10, height: s * 0.08))
    ctx.restoreGState()
}

func drawSparkle(_ ctx: CGContext, at c: CGPoint, size s: CGFloat) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x, y: c.y + s / 2))
    p.addQuadCurve(to: CGPoint(x: c.x + s / 2, y: c.y), control: c)
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - s / 2), control: c)
    p.addQuadCurve(to: CGPoint(x: c.x - s / 2, y: c.y), control: c)
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + s / 2), control: c)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.4, color: rgb(1, 0.9, 0.4, 0.9))
    ctx.addPath(p)
    ctx.setFillColor(rgb(1, 1, 0.92, 1))
    ctx.fillPath()
    ctx.restoreGState()
}

/// The woven nest: `back` is drawn behind the eggs, `front` over their lower halves. y-up rect.
func drawNest(_ ctx: CGContext, in r: CGRect, part: Int, seed: UInt64 = 3) {
    var g = SeededRandom(seed)
    let cx = r.midX
    let rimY = r.minY + r.height * 0.58
    let w = r.width / 2
    ctx.saveGState()
    ctx.setLineCap(.round)
    if part == 0 {
        // inside of the bowl (dark) + back rim
        let inner = CGRect(x: cx - w * 0.86, y: rimY - r.height * 0.16, width: w * 1.72, height: r.height * 0.34)
        ctx.setFillColor(rgb(0.30, 0.19, 0.09))
        ctx.fillEllipse(in: inner)
        for _ in 0..<26 {   // back rim: short straw arcs along the upper half of the rim ellipse
            let t0 = g.range(0.0, 1.0) * .pi, len = g.range(0.4, 1.0)
            ctx.setStrokeColor(rgb(0.58 + g.range(-0.08, 0.12), 0.42 + g.range(-0.06, 0.1), 0.20, 0.95))
            ctx.setLineWidth(r.height * g.range(0.03, 0.06))
            let rx = w * g.range(0.88, 0.98), ry = r.height * g.range(0.14, 0.22)
            for k in 0...8 {
                let t = t0 + len * CGFloat(k) / 8
                let p = CGPoint(x: cx + rx * cos(t), y: rimY + ry * sin(t))
                if k == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
            ctx.strokePath()
        }
    } else {
        // the front of the bowl: a half ellipse of woven straw
        let bowl = CGMutablePath()
        bowl.move(to: CGPoint(x: cx - w, y: rimY))
        bowl.addCurve(to: CGPoint(x: cx, y: r.minY + r.height * 0.04), control1: CGPoint(x: cx - w * 0.98, y: r.minY + r.height * 0.18),
                      control2: CGPoint(x: cx - w * 0.55, y: r.minY + r.height * 0.02))
        bowl.addCurve(to: CGPoint(x: cx + w, y: rimY), control1: CGPoint(x: cx + w * 0.55, y: r.minY + r.height * 0.02),
                      control2: CGPoint(x: cx + w * 0.98, y: r.minY + r.height * 0.18))
        bowl.addCurve(to: CGPoint(x: cx - w, y: rimY), control1: CGPoint(x: cx + w * 0.5, y: rimY - r.height * 0.20),
                      control2: CGPoint(x: cx - w * 0.5, y: rimY - r.height * 0.20))
        ctx.saveGState()
        ctx.addPath(bowl)
        ctx.clip()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let gr = CGGradient(colorsSpace: space, colors: [rgb(0.80, 0.62, 0.34), rgb(0.55, 0.38, 0.18)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gr, start: CGPoint(x: cx, y: rimY), end: CGPoint(x: cx, y: r.minY), options: [])
        }
        for i in 0..<34 {   // straw strands across the bowl
            let y = r.minY + r.height * g.range(0.02, 0.62)
            let x0 = cx - w * g.range(0.3, 1.1), x1 = x0 + w * g.range(0.5, 1.2)
            ctx.setStrokeColor(i % 3 == 0 ? rgb(0.95, 0.82, 0.52, 0.9) : rgb(0.45 + g.range(0, 0.2), 0.30 + g.range(0, 0.14), 0.12, 0.85))
            ctx.setLineWidth(r.height * g.range(0.025, 0.05))
            ctx.move(to: CGPoint(x: x0, y: y))
            ctx.addQuadCurve(to: CGPoint(x: x1, y: y + r.height * g.range(-0.08, 0.08)), control: CGPoint(x: (x0 + x1) / 2, y: y - r.height * 0.10))
            ctx.strokePath()
        }
        ctx.restoreGState()
        // a few loose ends sticking out of the rim
        for i in 0..<6 {
            let side: CGFloat = i % 2 == 0 ? -1 : 1
            let x = cx + side * w * g.range(0.72, 0.96)
            ctx.setStrokeColor(rgb(0.74, 0.56, 0.28, 0.9))
            ctx.setLineWidth(r.height * 0.03)
            ctx.move(to: CGPoint(x: x, y: rimY - r.height * 0.06))
            ctx.addLine(to: CGPoint(x: x + side * w * g.range(0.08, 0.2), y: rimY + r.height * g.range(0.02, 0.12)))
            ctx.strokePath()
        }
    }
    ctx.restoreGState()
}

/// Renders vector art into a CGImage at the best backing scale of any screen.
func renderImage(_ size: CGSize, _ draw: (CGContext) -> Void) -> CGImage? {
    let scale = max(2, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
    let w = Int(ceil(size.width * scale)), h = Int(ceil(size.height * scale))
    guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: scale, y: scale)
    draw(ctx)
    return ctx.makeImage()
}

private var eggCache: [String: CGImage] = [:]
func eggImage(_ kind: EggKind, size: CGSize, seed: UInt64 = 7, shadow: Bool = true) -> CGImage? {
    let key = "\(kind.rawValue)-\(Int(size.width * 10))x\(Int(size.height * 10))-\(seed)-\(shadow)"
    if let c = eggCache[key] { return c }
    let img = renderImage(size) { drawEgg($0, in: CGRect(origin: .zero, size: size), kind: kind, seed: seed, shadow: shadow) }
    eggCache[key] = img
    return img
}

func nestImage(_ size: CGSize, part: Int) -> CGImage? {
    renderImage(size) { drawNest($0, in: CGRect(origin: .zero, size: size), part: part) }
}

// MARK: - HUD nest: eggs drop in as live drafts arrive

final class NestView: NSView {
    struct Egg { let id: String; let layer: CALayer; let kind: EggKind }
    private(set) var eggs: [Egg] = []
    private let back = CALayer(), front = CALayer(), count = CATextLayer()
    private let eggLayer = CALayer()
    static let size = NSSize(width: 64, height: 32)
    let nestRect = CGRect(x: 2, y: 2, width: 40, height: 20)
    let eggSize = CGSize(width: 13, height: 17)

    override init(frame: NSRect) {
        super.init(frame: NSRect(origin: frame.origin, size: NestView.size))
        wantsLayer = true
        layer?.masksToBounds = false
        back.frame = nestRect
        back.contents = nestImage(nestRect.size, part: 0)
        front.frame = nestRect
        front.contents = nestImage(nestRect.size, part: 1)
        eggLayer.frame = bounds
        layer?.addSublayer(back)
        layer?.addSublayer(eggLayer)
        layer?.addSublayer(front)
        count.frame = CGRect(x: 44, y: 7, width: 20, height: 16)
        count.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        count.fontSize = 13
        count.foregroundColor = NSColor.white.cgColor
        count.contentsScale = 2
        count.alignmentMode = .left
        layer?.addSublayer(count)
        toolTip = L("实时草稿：每识别出一条就下一颗蛋", "Live drafts: one egg per item spotted so far")
        relayout(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var allowsVibrancy: Bool { false }

    var total: Int { eggs.count }

    /// Where egg i of n sits: up to 4 visible, nestled in a row and slightly overlapping.
    private func slot(_ i: Int, of n: Int) -> CGPoint {
        let shown = min(n, 4)
        let step: CGFloat = 8.5
        let x0 = nestRect.midX - CGFloat(shown - 1) * step / 2
        let j = i - (n - shown)
        return CGPoint(x: x0 + CGFloat(j) * step, y: nestRect.minY + 9 + eggSize.height / 2 + (j % 2 == 0 ? 0 : 1.5))
    }

    func add(id: String, kind: EggKind, animated: Bool = true) {
        guard !eggs.contains(where: { $0.id == id }) else { return }
        let l = CALayer()
        l.bounds = CGRect(origin: .zero, size: eggSize)
        l.contents = eggImage(kind, size: eggSize, seed: stableSeed(id), shadow: false)
        l.contentsGravity = .resizeAspect
        eggLayer.addSublayer(l)
        eggs.append(Egg(id: id, layer: l, kind: kind))
        relayout(animated: animated, dropped: animated ? l : nil)
    }

    func remove(id: String) {
        guard let i = eggs.firstIndex(where: { $0.id == id }) else { return }
        let e = eggs.remove(at: i)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setCompletionBlock { e.layer.removeFromSuperlayer() }
        e.layer.opacity = 0
        e.layer.transform = CATransform3DMakeScale(0.4, 0.4, 1)
        CATransaction.commit()
        relayout(animated: true)
    }

    private func relayout(animated: Bool, dropped: CALayer? = nil) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        for (i, e) in eggs.enumerated() {
            let visible = i >= eggs.count - 4
            let p = slot(i, of: eggs.count)
            if e.layer === dropped {
                CATransaction.setDisableActions(true)
                e.layer.position = p
                e.layer.opacity = 1
                CATransaction.setDisableActions(!animated)
                if reduce {
                    let f = CABasicAnimation(keyPath: "opacity")
                    f.fromValue = 0; f.toValue = 1; f.duration = 0.3
                    e.layer.add(f, forKey: "in")
                } else {
                    // falls in from above and settles with a little bounce + wobble
                    let drop = CASpringAnimation(keyPath: "position.y")
                    drop.fromValue = p.y + 26
                    drop.toValue = p.y
                    drop.mass = 0.6; drop.stiffness = 260; drop.damping = 9; drop.initialVelocity = -2
                    drop.duration = drop.settlingDuration
                    e.layer.add(drop, forKey: "drop")
                    let wob = CASpringAnimation(keyPath: "transform.rotation.z")
                    wob.fromValue = 0.5; wob.toValue = 0
                    wob.mass = 0.5; wob.stiffness = 180; wob.damping = 5
                    wob.duration = wob.settlingDuration
                    e.layer.add(wob, forKey: "wob")
                }
            } else {
                e.layer.position = p
                e.layer.opacity = visible ? 1 : 0
            }
        }
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        count.string = eggs.isEmpty ? "" : "\(eggs.count)"
        count.isHidden = eggs.isEmpty
        CATransaction.commit()
        if animated, dropped != nil, !reduce {
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 1.35; pop.toValue = 1
            pop.mass = 0.5; pop.stiffness = 300; pop.damping = 10
            pop.duration = pop.settlingDuration
            count.add(pop, forKey: "pop")
        }
    }
}

// MARK: - live/*.jsonl readers (tolerant: missing file, partial last line, truncation)

final class JSONLTail {
    let url: URL
    private var offset: UInt64 = 0
    private var carry = Data()
    init(_ url: URL) { self.url = url }

    func poll() -> [[String: Any]] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < offset { offset = 0; carry = Data() }      // rewritten from scratch
        guard size > offset else { return [] }
        try? fh.seek(toOffset: offset)
        let data = (try? fh.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        var buf = carry + data
        var out: [[String: Any]] = []
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = buf[buf.startIndex..<nl]
            buf = Data(buf[buf.index(after: nl)...])
            if let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { out.append(o) }
        }
        carry = buf
        return out
    }
}

/// Follows `<session>/live/drafts.jsonl` (≈1 s polls) and keeps the current set of drafts; reports adds / drops.
final class DraftsWatcher {
    private let tail: JSONLTail
    private(set) var current: [String: [String: Any]] = [:]
    private(set) var order: [String] = []
    var onAdd: ((String, EggKind) -> Void)?
    var onDrop: ((String) -> Void)?

    init(session: URL) { tail = JSONLTail(session.appendingPathComponent("live/drafts.jsonl")) }

    func poll() {
        for o in tail.poll() {
            guard let id = (o["id"] as? String) ?? (o["id"] as? NSNumber)?.stringValue else { continue }
            let op = o["op"] as? String ?? "add"
            if op == "drop" {
                if current.removeValue(forKey: id) != nil { order.removeAll { $0 == id }; onDrop?(id) }
            } else if current[id] == nil {
                current[id] = o
                order.append(id)
                onAdd?(id, EggKind(o["kind"] as? String))
            } else {
                current[id] = (current[id] ?? [:]).merging(o) { $1 }
            }
        }
    }

    var kinds: [EggKind] { order.compactMap { current[$0] }.map { EggKind($0["kind"] as? String) } }
}

/// Every kind's drafts from a finished / running session (for the hatching nest on the perch).
func draftKinds(in session: URL) -> [EggKind] {
    let w = DraftsWatcher(session: session)
    w.poll()
    return w.kinds
}
