// The perch's line: a twine rope between two little pegs, simulated as a damped string so it sags under the cards
// hanging on it and bounces when one is hung, taken, lifted or gathered (docs/design/snap-and-live.md §3).
//
// Model — a taut string of `segments` pieces, vertical displacement only:
//     ü = c²·∂²u/∂x² + β·c²·∂²u̇/∂x² − γ·u̇ + g + loads − a_frame
//   c (wave speed) is set from the unloaded fundamental period: c₀ = 2L / period, so every screen width feels the same;
//   the rope stiffens as weight is added (c² = c₀²·τ, τ = 1 + stiffen·(W − 1)), so the sag grows less than linearly.
//   g is chosen so the empty rope sags `restSag` in the middle, a card's load so one card in the middle adds `cardSag`.
//   γ damps every mode (a hang's ~6 px dip is under 1 px after ~1 s, still by ~1.7 s); β (Kelvin–Voigt) quiets the
//   short, fast wiggles.
//   a_frame: the strip's own acceleration (sliding down / tucking away) — the rope lags behind it and settles.
// Integrated with semi-implicit Euler at 1/480 s steps; at rest it snaps to the exact equilibrium (a tridiagonal
// solve) and reports `settled`, so the perch can stop its display link. Reduce Motion: always the equilibrium.

import AppKit
import QuartzCore

struct RopeLook {
    let body: CGColor, outline: CGColor, twist: CGColor, shine: CGColor, shadow: CGColor
    let peg: CGColor, pegDark: CGColor, pegShine: CGColor

    private static func c(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    /// Cream twine: light enough to read as a cord (not a beam) over dark windows, while its tan outline and soft shadow
    /// keep it visible over white ones; warm like the nest and the eggs. (Tried as well: a peach tone from the accent —
    /// it fought the coral buttons and the orange feet — and a neutral silver cord, which read cold, like a cable.)
    static func current(dark: Bool) -> RopeLook {
        dark ? RopeLook(body: c(0xEADBB8), outline: c(0x3A2A12, 0.55), twist: c(0xA8895A, 0.75), shine: c(0xFFFFFF, 0.5),
                        shadow: c(0x000000, 0.5), peg: c(0xE9D6AE), pegDark: c(0x9C7A48), pegShine: c(0xFFF8E8, 0.9))
             : RopeLook(body: c(0xF2E4C4), outline: c(0x9C7A48, 0.75), twist: c(0xB4915C, 0.7), shine: c(0xFFFFFF, 0.7),
                        shadow: c(0x3C280A, 0.30), peg: c(0xF0DDB4), pegDark: c(0x9C7A48), pegShine: c(0xFFFBF0, 0.95))
    }
}

final class Rope {
    // physics (see the header)
    static let segments = 48
    static let period: CGFloat = 0.62        // s, fundamental of the empty rope
    static let restSag: CGFloat = 10         // px, empty rope, middle
    static let cardSag: CGFloat = 5          // px added by one card hanging in the middle
    static let stiffen: CGFloat = 0.03       // tension added per extra card's worth of weight
    static let damping: CGFloat = 4          // γ, 1/s
    static let kelvin: CGFloat = 0.0018      // β, s
    static let frameCoupling: CGFloat = 0.02  // share of the strip's acceleration the rope feels
    // look
    static let width: CGFloat = 2.4

    private(set) var x0: CGFloat = 0, x1: CGFloat = 100, y0: CGFloat = 0
    private var u = [CGFloat](repeating: 0, count: Rope.segments + 1)
    private var v = [CGFloat](repeating: 0, count: Rope.segments + 1)
    private var eq = [CGFloat](repeating: 0, count: Rope.segments + 1)
    private var force = [CGFloat](repeating: 0, count: Rope.segments + 1)
    private var tau: CGFloat = 1
    private(set) var settled = true
    /// (x, weight): weight 1 = one card; negative lifts the rope.
    var loads: [(x: CGFloat, w: CGFloat)] = [] { didSet { solveEquilibrium() } }

    let layer = CALayer()
    private let shadow = CAShapeLayer(), outline = CAShapeLayer(), body = CAShapeLayer()
    private let twist = CAShapeLayer(), shine = CAShapeLayer()
    private let pegL = CALayer(), pegR = CALayer()

    init() {
        for l in [shadow, outline, body, twist, shine] {
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
            layer.addSublayer(l)
        }
        shadow.lineWidth = Rope.width + 1.4
        outline.lineWidth = Rope.width + 1.3
        body.lineWidth = Rope.width
        twist.lineWidth = 0.75
        twist.lineCap = .butt
        shine.lineWidth = 0.7
        shine.lineDashPattern = [5, 4]
        layer.addSublayer(pegL)
        layer.addSublayer(pegR)
    }

    private var length: CGFloat { max(40, x1 - x0) }
    private var dx: CGFloat { length / CGFloat(Rope.segments) }
    private var c0sq: CGFloat { let c = 2 * length / Rope.period; return c * c }
    private var gravity: CGFloat { 8 * c0sq * Rope.restSag / (length * length) }
    private var cardForce: CGFloat { 4 * c0sq * Rope.cardSag / length }   // a point load, per card

    // MARK: geometry

    func setSpan(from a: CGFloat, to b: CGFloat, y: CGFloat) {
        x0 = a; x1 = b; y0 = y
        solveEquilibrium()
        if settled { u = eq }
    }

    /// The rope's height at x (strip coordinates, y down), and its slope dy/dx — Catmull-Rom through the nodes, the
    /// same curve that is drawn.
    func y(at x: CGFloat) -> CGFloat { y0 + sample(u, x).y }
    func slope(at x: CGFloat) -> CGFloat { sample(u, x).dy }
    /// Where the rope will come to rest at x with the current loads.
    func restY(at x: CGFloat) -> CGFloat { y0 + sample(eq, x).y }
    var maxSag: CGFloat { max(u.max() ?? 0, eq.max() ?? 0) }

    private func sample(_ a: [CGFloat], _ x: CGFloat) -> (y: CGFloat, dy: CGFloat) {
        let n = Rope.segments
        let f = min(max((x - x0) / dx, 0), CGFloat(n) - 0.0001)
        let i = Int(f), t = f - CGFloat(i)
        let p0 = a[max(i - 1, 0)], p1 = a[i], p2 = a[i + 1], p3 = a[min(i + 2, n)]
        let t2 = t * t, t3 = t2 * t
        let y = 0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (3 * p1 - p0 - 3 * p2 + p3) * t3)
        let d = 0.5 * ((p2 - p0) + 2 * (2 * p0 - 5 * p1 + 4 * p2 - p3) * t + 3 * (3 * p1 - p0 - 3 * p2 + p3) * t2)
        return (y, d / dx)
    }

    // MARK: physics

    private func solveEquilibrium() {
        let n = Rope.segments
        let total = loads.reduce(CGFloat(0)) { $0 + max(0, $1.w) }
        tau = 1 + Rope.stiffen * max(0, total - 1)
        for i in 0...n { force[i] = gravity }
        let h = dx
        for l in loads where l.w != 0 {
            let f = min(max((l.x - x0) / h, 0), CGFloat(n))
            let i = min(Int(f), n - 1), t = f - CGFloat(i)
            let p = cardForce * l.w / h
            force[i] += p * (1 - t)
            force[i + 1] += p * t
        }
        // c²τ(u[i-1] − 2u[i] + u[i+1])/dx² = −force[i], u[0] = u[n] = 0  (Thomas algorithm; −1, 2, −1)
        let k = h * h / (c0sq * tau)
        var cp = [CGFloat](repeating: 0, count: n + 1), dp = [CGFloat](repeating: 0, count: n + 1)
        for i in 1..<n {
            let denom = 2 - (i > 1 ? cp[i - 1] : 0)
            cp[i] = 1 / denom
            dp[i] = (force[i] * k + (i > 1 ? dp[i - 1] : 0)) / denom
        }
        eq[n] = 0; eq[0] = 0
        var i = n - 1
        while i >= 1 { eq[i] = dp[i] + cp[i] * eq[i + 1]; i -= 1 }
        if reduceMotion { u = eq; v = v.map { _ in 0 } }
        settled = settled && zip(u, eq).allSatisfy { abs($0 - $1) < 0.05 }
        if settled { u = eq }
    }

    /// A push at x (px/s, + = down), spread over ~`spread` px either side.
    func impulse(at x: CGFloat, _ dv: CGFloat, spread: CGFloat = 40) {
        guard !reduceMotion else { return }
        for i in 1..<Rope.segments {
            let d = (x0 + CGFloat(i) * dx - x) / max(spread, 1)
            v[i] += dv * exp(-d * d)
        }
        settled = false
    }

    /// The whole rope at once (the first mode's shape), e.g. a breeze.
    func swell(_ dv: CGFloat) {
        guard !reduceMotion else { return }
        for i in 1..<Rope.segments { v[i] += dv * sin(.pi * CGFloat(i) / CGFloat(Rope.segments)) }
        settled = false
    }

    /// Advance by dt. `frameAccel`: the strip's acceleration (px/s², + = down). Returns whether it still moves.
    @discardableResult
    func step(_ dt: CGFloat, frameAccel: CGFloat = 0) -> Bool {
        let n = Rope.segments
        if reduceMotion { u = eq; settled = true; return false }
        let a = max(-20000, min(20000, frameAccel)) * Rope.frameCoupling
        if settled && abs(a) < 1 { return false }
        settled = false
        let csq = c0sq * tau / (dx * dx)
        var rest = min(dt, 1.0 / 20)
        var acc = [CGFloat](repeating: 0, count: n + 1)
        while rest > 0 {
            let h = min(rest, 1.0 / 480)
            for i in 1..<n {
                let lap = u[i - 1] - 2 * u[i] + u[i + 1]
                let lapv = v[i - 1] - 2 * v[i] + v[i + 1]
                acc[i] = csq * (lap + Rope.kelvin * lapv) - Rope.damping * v[i] + force[i] - a
            }
            for i in 1..<n { v[i] += acc[i] * h; u[i] += v[i] * h }
            rest -= h
        }
        var dev: CGFloat = 0, vel: CGFloat = 0
        for i in 1..<n { dev = max(dev, abs(u[i] - eq[i])); vel = max(vel, abs(v[i])) }
        if dev < 0.1 && vel < 1.5 && abs(a) < 1 {
            u = eq
            for i in 0...n { v[i] = 0 }
            settled = true
        }
        return !settled
    }

    func snapToRest() {
        u = eq
        for i in 0...Rope.segments { v[i] = 0 }
        settled = true
    }

    // MARK: drawing

    func restyle(dark: Bool) {
        let look = RopeLook.current(dark: dark)
        shadow.strokeColor = look.shadow
        outline.strokeColor = look.outline
        body.strokeColor = look.body
        twist.strokeColor = look.twist
        shine.strokeColor = look.shine
        let img = Rope.pegImage(look)
        pegL.contents = img
        pegR.contents = img
        pegR.transform = CATransform3DMakeScale(-1, 1, 1)
        draw()
    }

    /// Rebuild the paths (call inside a transaction with actions disabled).
    func draw() {
        let n = Rope.segments
        let pts = (0...n).map { CGPoint(x: x0 + CGFloat($0) * dx, y: y0 + u[$0]) }
        let path = CGMutablePath()
        path.move(to: pts[0])
        for i in 0..<n {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, n)]
            path.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        var down = CGAffineTransform(translationX: 0, y: 1.6), up = CGAffineTransform(translationX: 0, y: -0.55)
        shadow.path = path.copy(using: &down)
        outline.path = path
        body.path = path
        shine.path = path.copy(using: &up)
        // the twist: short slanted strokes across the cord, every 3.2 px along it
        let tw = CGMutablePath()
        let r = Rope.width / 2
        var x = x0 + 2
        while x < x1 - 2 {
            let s = sample(u, x)
            let y = y0 + s.y
            let len = sqrt(1 + s.dy * s.dy)
            let tx = 1 / len, ty = s.dy / len          // along
            let nx = -ty, ny = tx                       // across
            tw.move(to: CGPoint(x: x - nx * r - tx * 0.9, y: y - ny * r - ty * 0.9))
            tw.addLine(to: CGPoint(x: x + nx * r + tx * 0.9, y: y + ny * r + ty * 0.9))
            x += 3.2
        }
        twist.path = tw
        let ps: CGFloat = 16
        pegL.frame = CGRect(x: x0 - ps / 2 - 1.5, y: y0 - ps / 2, width: ps, height: ps)
        pegR.frame = CGRect(x: x1 - ps / 2 + 1.5, y: y0 - ps / 2, width: ps, height: ps)
    }

    /// A small round peg with the rope knotted on it and a short tail — drawn for the left end, mirrored for the right.
    static func pegImage(_ look: RopeLook) -> CGImage? {
        let s: CGFloat = 16
        return renderImage(CGSize(width: s, height: s)) { ctx in
            // y-up drawing; the rope leaves towards +x at the middle
            let c = CGPoint(x: s / 2, y: s / 2)
            let pr: CGFloat = 4.2
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: look.shadow)
            ctx.setFillColor(look.pegDark)
            ctx.fillEllipse(in: CGRect(x: c.x - pr, y: c.y - pr, width: pr * 2, height: pr * 2))
            ctx.restoreGState()
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [look.pegShine, look.peg, look.pegDark] as CFArray,
                                  locations: [0, 0.45, 1]) {
                ctx.saveGState()
                ctx.addEllipse(in: CGRect(x: c.x - pr + 0.7, y: c.y - pr + 0.7, width: pr * 2 - 1.4, height: pr * 2 - 1.4))
                ctx.clip()
                ctx.drawRadialGradient(g, startCenter: CGPoint(x: c.x - 1.4, y: c.y + 1.6), startRadius: 0,
                                       endCenter: c, endRadius: pr, options: [.drawsAfterEndLocation])
                ctx.restoreGState()
            }
            // the knot: a little bulb of twine just off the peg, two short tails dangling from it
            let k = CGPoint(x: c.x + 3.4, y: c.y)
            ctx.setLineCap(.round)
            for (w, col) in [(Rope.width * 0.8 + 1.1, look.outline), (Rope.width * 0.8, look.body)] {
                ctx.setStrokeColor(col)
                ctx.setLineWidth(w)
                ctx.move(to: CGPoint(x: k.x - 0.4, y: k.y - 1))
                ctx.addQuadCurve(to: CGPoint(x: k.x - 2.2, y: k.y - 6.6), control: CGPoint(x: k.x - 1.8, y: k.y - 3.4))
                ctx.move(to: CGPoint(x: k.x + 0.6, y: k.y - 1))
                ctx.addQuadCurve(to: CGPoint(x: k.x + 1.4, y: k.y - 5.6), control: CGPoint(x: k.x + 1.4, y: k.y - 3.2))
                ctx.strokePath()
            }
            for (inset, col) in [(CGFloat(0), look.outline), (0.65, look.body)] {
                ctx.setFillColor(col)
                ctx.fillEllipse(in: CGRect(x: k.x - 2.4 + inset, y: k.y - 2.1 + inset, width: 4.8 - inset * 2, height: 4.2 - inset * 2))
            }
            ctx.setStrokeColor(look.twist)
            ctx.setLineWidth(0.6)
            ctx.move(to: CGPoint(x: k.x - 1.2, y: k.y - 1.3)); ctx.addLine(to: CGPoint(x: k.x + 0.2, y: k.y + 1.4))
            ctx.move(to: CGPoint(x: k.x + 0.4, y: k.y - 1.4)); ctx.addLine(to: CGPoint(x: k.x + 1.6, y: k.y + 1.0))
            ctx.strokePath()
        }
    }
}
