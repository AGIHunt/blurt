// The claw that holds a card: a chicken's leg reaching down from the top edge of the screen and a foot gripping the
// card's top edge — three front toes curl over it, the hind toe sits behind. Vector art (CoreGraphics), rendered at the
// screen's scale; the foot is pre-rendered at a few openings so opening / closing is just a frame change.
//
// Palette: warm yellow-ochre skin with a cylindrical shade, darker scutes, umber nails. Same colours in light and
// dark mode (it is an object, not chrome) — the outline and the shadow keep it legible on both.
import AppKit
import QuartzCore

enum ClawArt {
    static let skin = CGColor(srgbRed: 0.949, green: 0.694, blue: 0.239, alpha: 1)       // #F2B13D
    static let skinLight = CGColor(srgbRed: 1.0, green: 0.851, blue: 0.541, alpha: 1)    // #FFD98A
    static let skinShade = CGColor(srgbRed: 0.769, green: 0.478, blue: 0.086, alpha: 1)  // #C47A16
    static let outline = CGColor(srgbRed: 0.43, green: 0.235, blue: 0.04, alpha: 0.55)
    static let scute = CGColor(srgbRed: 0.62, green: 0.36, blue: 0.06, alpha: 0.45)
    static let nail = CGColor(srgbRed: 0.29, green: 0.204, blue: 0.125, alpha: 1)        // #4A3420
    static let nailShine = CGColor(srgbRed: 1, green: 0.95, blue: 0.85, alpha: 0.55)

    /// The foot's box (pt) and where its knuckle (the leg's end) sits in it, y down.
    static let footSize = CGSize(width: 40, height: 30)
    static let knuckle = CGPoint(x: 20, y: 7)
    /// The leg's width.
    static let legWidth: CGFloat = 6

    /// The front toes (over the card) at `open` 0…1, y-down coordinates in the foot box.
    static func drawFront(_ ctx: CGContext, open: CGFloat) {
        let k = knuckle
        // each toe: an angle from straight down (rad), a length, a curl; opening swings them out and up
        let toes: [(a: CGFloat, len: CGFloat, w: CGFloat)] = [(-0.55, 15, 4.2), (0.0, 17, 4.6), (0.55, 15, 4.2)]
        for (i, t) in toes.enumerated() {
            let side: CGFloat = i == 0 ? -1 : i == 2 ? 1 : 0
            let a = t.a + side * open * 0.75
            let len = t.len * (1 - 0.32 * open * (side == 0 ? 1 : 0.4))
            toe(ctx, from: k, angle: a, length: len, width: t.w, curl: (1 - open) * 0.5 * (side == 0 ? 0.6 : 1) * (side < 0 ? -1 : 1))
        }
        // the knuckle pad over the toes' roots
        let pad = CGRect(x: k.x - 5.2, y: k.y - 4.6, width: 10.4, height: 9.4)
        ctx.saveGState()
        ctx.addEllipse(in: pad)
        ctx.clip()
        gradient(ctx, [skinLight, skin, skinShade], from: CGPoint(x: pad.minX + 2, y: pad.minY + 2), to: CGPoint(x: pad.maxX, y: pad.maxY))
        ctx.restoreGState()
        ctx.setStrokeColor(outline)
        ctx.setLineWidth(0.8)
        ctx.strokeEllipse(in: pad.insetBy(dx: 0.4, dy: 0.4))
    }

    /// The hind toe (behind the card): a short spur pointing back-up.
    static func drawHind(_ ctx: CGContext, open: CGFloat) {
        toe(ctx, from: CGPoint(x: knuckle.x, y: knuckle.y + 1), angle: .pi - 0.25 - open * 0.5, length: 8, width: 3.6, curl: 0.2, shade: 0.8)
    }

    /// One toe: two tapered phalanges along a gentle curve, a nail at the tip.
    private static func toe(_ ctx: CGContext, from k: CGPoint, angle a: CGFloat, length L: CGFloat, width w: CGFloat, curl: CGFloat,
                            shade: CGFloat = 1) {
        let dir = CGPoint(x: sin(a), y: cos(a))                 // y down
        let nrm = CGPoint(x: dir.y, y: -dir.x)
        let mid = CGPoint(x: k.x + dir.x * L * 0.55 + nrm.x * curl * L * 0.25, y: k.y + dir.y * L * 0.55 + nrm.y * curl * L * 0.25)
        let tip = CGPoint(x: k.x + dir.x * L + nrm.x * curl * L * 0.55, y: k.y + dir.y * L + nrm.y * curl * L * 0.55)
        let path = CGMutablePath()
        // outline of a tapered tube along k → mid → tip
        func side(_ p: CGPoint, _ r: CGFloat, _ s: CGFloat) -> CGPoint { CGPoint(x: p.x + nrm.x * r * s, y: p.y + nrm.y * r * s) }
        path.move(to: side(k, w / 2, 1))
        path.addQuadCurve(to: side(tip, w * 0.22, 1), control: side(mid, w * 0.52, 1))
        path.addQuadCurve(to: side(tip, w * 0.22, -1), control: CGPoint(x: tip.x + dir.x * w * 0.35, y: tip.y + dir.y * w * 0.35))
        path.addQuadCurve(to: side(k, w / 2, -1), control: side(mid, w * 0.52, -1))
        path.closeSubpath()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let c0 = shade < 1 ? skinShade : skinLight
        gradient(ctx, [c0, skin, skinShade], from: side(mid, w, 1), to: side(mid, w, -1))
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(outline)
        ctx.setLineWidth(0.7)
        ctx.strokePath()
        // a scute crease at the joint
        ctx.setStrokeColor(scute)
        ctx.setLineWidth(0.6)
        ctx.move(to: side(mid, w * 0.45, 1))
        ctx.addQuadCurve(to: side(mid, w * 0.45, -1), control: CGPoint(x: mid.x - dir.x * 1.2, y: mid.y - dir.y * 1.2))
        ctx.strokePath()
        // the nail: a small curved cone past the tip
        let nTip = CGPoint(x: tip.x + dir.x * 3.2 + nrm.x * curl * 2.2, y: tip.y + dir.y * 3.2 + nrm.y * curl * 2.2)
        let n = CGMutablePath()
        n.move(to: side(tip, w * 0.3, 1))
        n.addQuadCurve(to: nTip, control: side(CGPoint(x: (tip.x + nTip.x) / 2, y: (tip.y + nTip.y) / 2), w * 0.25, 1))
        n.addQuadCurve(to: side(tip, w * 0.3, -1), control: side(CGPoint(x: (tip.x + nTip.x) / 2, y: (tip.y + nTip.y) / 2), w * 0.12, -1))
        n.closeSubpath()
        ctx.addPath(n)
        ctx.setFillColor(nail)
        ctx.fillPath()
        ctx.setStrokeColor(nailShine)
        ctx.setLineWidth(0.5)
        ctx.move(to: side(tip, w * 0.12, 1))
        ctx.addLine(to: CGPoint(x: (tip.x * 0.4 + nTip.x * 0.6), y: (tip.y * 0.4 + nTip.y * 0.6)))
        ctx.strokePath()
    }

    private static func gradient(_ ctx: CGContext, _ colors: [CGColor], from a: CGPoint, to b: CGPoint) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil) else { return }
        ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    // MARK: pre-rendered frames

    static let openings = 6
    private static var cache: [String: CGImage] = [:]

    /// `front`: the toes over the card; else the hind toe. `open` is quantised to `openings` frames.
    static func foot(front: Bool, open: CGFloat) -> CGImage? {
        let i = Int((min(max(open, 0), 1) * CGFloat(openings - 1)).rounded())
        let key = "\(front)-\(i)"
        if let c = cache[key] { return c }
        let o = CGFloat(i) / CGFloat(openings - 1)
        let img = renderImage(footSize) { ctx in
            ctx.translateBy(x: 0, y: footSize.height)
            ctx.scaleBy(x: 1, y: -1)                      // draw y down
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            if front { drawFront(ctx, open: o) } else { drawHind(ctx, open: o) }
        }
        cache[key] = img
        return img
    }

    /// The leg: a cylinder-shaded strip (gradient across) with scutes repeated along it (a replicator).
    static func makeLeg() -> (leg: CAGradientLayer, scutes: CAReplicatorLayer) {
        let leg = CAGradientLayer()
        leg.colors = [skinShade, skin, skinLight, skin, skinShade]
        leg.locations = [0, 0.28, 0.5, 0.72, 1]
        leg.startPoint = CGPoint(x: 0, y: 0.5)
        leg.endPoint = CGPoint(x: 1, y: 0.5)
        leg.cornerRadius = legWidth / 2
        leg.borderColor = outline
        leg.borderWidth = 0.6
        let rep = CAReplicatorLayer()
        let one = CAShapeLayer()
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 1.2, y: 0))
        p.addQuadCurve(to: CGPoint(x: legWidth - 1.2, y: 0), control: CGPoint(x: legWidth / 2, y: 2.2))
        one.path = p
        one.strokeColor = scute
        one.fillColor = nil
        one.lineWidth = 0.7
        one.lineCap = .round
        rep.addSublayer(one)
        rep.instanceTransform = CATransform3DMakeTranslation(0, 6.5, 0)
        return (leg, rep)
    }
}
