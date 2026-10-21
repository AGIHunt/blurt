// The completion hen (K7 / K8): when an item reaches "to verify" (an agent says it's fixed) or "done" (you confirmed
// it), the island shows one quiet line with the hen beside it — never a window of its own, never one per item: news
// within 10 s of each other becomes one line ("3 items to verify"). Click = that item (or the inbox).
//
// The hen is a layered vector illustration (CoreGraphics, gradients, no bitmaps): ground shadow, tail plumes, legs,
// body, scalloped wing, neck and head, comb, beak, wattle, eye with a catch-light, cheek. Moods:
//   pleased (to verify)  a double nod, a little "ta-da" of the wing, a blink
//   delighted (done)     a hop with squash and stretch, both wings up, happy closed eyes, a burst of sparkles
//   neutral              idle breathing and blinks (docs, the rest pose)
// Reduce Motion: the rest pose of the mood, no movement.
import AppKit
import BlurtCore

enum HenMood: String { case pleased, delighted, neutral }

enum ChickenArt {
    static let box: CGFloat = 120
    static let duration: Double = 1.5

    private static func c(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }
    private static let ink = c(0x3B2A1E)
    private static let rim = c(0xA9814F, 0.55)
    private static let featherLight = c(0xFFFCF5), featherMid = c(0xF7E9D0), featherShade = c(0xE3C79C)
    private static let wingMid = c(0xF1DDBA), wingShade = c(0xD9B784)
    private static let tail1 = c(0xC9762A), tail2 = c(0xE3963A), tail3 = c(0xF2BC55)
    private static let combLight = c(0xF46B5B), comb = c(0xE0443A), combDark = c(0xB52E28)
    private static let beakLight = c(0xFFC34D), beak = c(0xF5A524), beakDark = c(0xD9850F)
    private static let leg = c(0xEE9F33), legDark = c(0xC77A17)
    private static let blush = c(0xFF8A80, 0.38)
    private static let spark = c(0xFFC93D)

    private static func grad(_ ctx: CGContext, _ cs: [CGColor], _ locs: [CGFloat]? = nil, from a: CGPoint, to b: CGPoint) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: cs as CFArray, locations: locs) else { return }
        ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    private static func radial(_ ctx: CGContext, _ cs: [CGColor], _ locs: [CGFloat]? = nil, at c0: CGPoint, r0: CGFloat = 0, to c1: CGPoint, r1: CGFloat) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: cs as CFArray, locations: locs) else { return }
        ctx.drawRadialGradient(g, startCenter: c0, startRadius: r0, endCenter: c1, endRadius: r1, options: [.drawsAfterEndLocation])
    }
    private static func fill(_ ctx: CGContext, _ p: CGPath, _ body: () -> Void, stroke: CGColor? = rim, width: CGFloat = 1.1) {
        ctx.saveGState()
        ctx.addPath(p)
        ctx.clip()
        body()
        ctx.restoreGState()
        if let s = stroke {
            ctx.addPath(p)
            ctx.setStrokeColor(s)
            ctx.setLineWidth(width)
            ctx.strokePath()
        }
    }

    private static func smooth(_ t: Double, _ a: Double, _ b: Double) -> CGFloat {
        let u = min(1, max(0, (t - a) / (b - a)))
        return CGFloat(u * u * (3 - 2 * u))
    }
    /// 0 → 1 → 0 between a and c, peaking at b
    private static func bump(_ t: Double, _ a: Double, _ b: Double, _ c: Double) -> CGFloat {
        t <= a || t >= c ? 0 : t < b ? smooth(t, a, b) : 1 - smooth(t, b, c)
    }

    /// One frame at time t (s), y-up, in a 120 × 120 box.
    static func draw(_ ctx: CGContext, t: Double, mood: HenMood, reduceMotion: Bool = false) {
        let t = reduceMotion ? 3.0 : t
        ctx.saveGState()
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        // pose
        var hop: CGFloat = 0, squash: CGFloat = 0, nod: CGFloat = 0, wingLift: CGFloat = 0, tilt: CGFloat = 0
        var eyesClosed = false, blink: CGFloat = 0
        let breathe = CGFloat(sin(t * 2 * .pi / 2.4)) * 0.6
        switch mood {
        case .delighted:
            let up = bump(t, 0.12, 0.36, 0.62)
            hop = up * 9
            squash = bump(t, 0.0, 0.08, 0.16) * 0.08 - up * 0.04 + bump(t, 0.6, 0.68, 0.8) * 0.07
            wingLift = max(bump(t, 0.1, 0.3, 0.55), bump(t, 0.55, 0.75, 1.0) * 0.8)
            eyesClosed = true
            tilt = -0.06 * up
        case .pleased:
            nod = max(bump(t, 0.05, 0.18, 0.32), bump(t, 0.32, 0.45, 0.6) * 0.8)
            wingLift = bump(t, 0.55, 0.8, 1.15) * 0.7
            tilt = 0.08 * smooth(t, 0.6, 0.9)
            blink = bump(t, 1.25, 1.31, 1.38)
        case .neutral:
            blink = bump(t.truncatingRemainder(dividingBy: 3.2), 2.6, 2.66, 2.74)
        }

        // ground shadow (shrinks while the hen is in the air)
        let sh = 1 - hop / 18
        ctx.saveGState()
        ctx.translateBy(x: 58, y: 14)
        ctx.scaleBy(x: 1, y: 0.22)
        radial(ctx, [c(0x000000, 0.2), c(0x000000, 0)], at: .zero, to: .zero, r1: 26 * sh)
        ctx.restoreGState()

        ctx.translateBy(x: 0, y: hop)
        // squash and stretch around the feet
        ctx.translateBy(x: 58, y: 16)
        ctx.scaleBy(x: 1 + squash, y: 1 - squash)
        ctx.translateBy(x: -58, y: -16)

        // legs and feet
        for (x, dx) in [(CGFloat(50), CGFloat(-1.5)), (64, 1.5)] {
            ctx.setStrokeColor(legDark)
            ctx.setLineWidth(4.2)
            ctx.move(to: CGPoint(x: x, y: 34)); ctx.addLine(to: CGPoint(x: x + dx, y: 17)); ctx.strokePath()
            ctx.setStrokeColor(leg)
            ctx.setLineWidth(2.8)
            ctx.move(to: CGPoint(x: x, y: 34)); ctx.addLine(to: CGPoint(x: x + dx, y: 17)); ctx.strokePath()
            for (tx, ty) in [(CGFloat(-6), CGFloat(-1)), (1, -3), (7, -1.5)] {
                ctx.setStrokeColor(legDark)
                ctx.setLineWidth(3)
                ctx.move(to: CGPoint(x: x + dx, y: 17)); ctx.addLine(to: CGPoint(x: x + dx + tx, y: 17 + ty)); ctx.strokePath()
                ctx.setStrokeColor(leg)
                ctx.setLineWidth(1.8)
                ctx.move(to: CGPoint(x: x + dx, y: 17)); ctx.addLine(to: CGPoint(x: x + dx + tx, y: 17 + ty)); ctx.strokePath()
            }
        }

        // the whole bird breathes and tilts a touch around its middle
        ctx.translateBy(x: 56, y: 52)
        ctx.rotate(by: tilt)
        ctx.scaleBy(x: 1, y: 1 + breathe * 0.008)
        ctx.translateBy(x: -56, y: -52)

        // tail plumes (behind the body): three layered feathers fanning up-left
        for (i, (col, ang, len)) in [(tail1, CGFloat(0.95), CGFloat(30)), (tail2, 0.7, 34), (tail3, 0.42, 29)].enumerated() {
            let base = CGPoint(x: 30, y: 56 + CGFloat(i) * 2)
            let a = ang + CGFloat(sin(t * 3 + Double(i))) * 0.02
            let tip = CGPoint(x: base.x - cos(a) * len, y: base.y + sin(a) * len)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: base.x + 6, y: base.y - 6))
            p.addQuadCurve(to: tip, control: CGPoint(x: base.x - cos(a - 0.5) * len * 0.6, y: base.y + sin(a - 0.5) * len * 0.6))
            p.addQuadCurve(to: CGPoint(x: base.x + 8, y: base.y + 6), control: CGPoint(x: base.x - cos(a + 0.45) * len * 0.55, y: base.y + sin(a + 0.45) * len * 0.55))
            p.closeSubpath()
            fill(ctx, p, { grad(ctx, [col, tail3], from: base, to: tip) }, stroke: c(0x8E5216, 0.45), width: 0.9)
        }

        // body: a soft teardrop leaning forward
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 26, y: 58))
        body.addCurve(to: CGPoint(x: 60, y: 30), control1: CGPoint(x: 24, y: 40), control2: CGPoint(x: 40, y: 30))
        body.addCurve(to: CGPoint(x: 90, y: 54), control1: CGPoint(x: 80, y: 30), control2: CGPoint(x: 92, y: 40))
        body.addCurve(to: CGPoint(x: 72, y: 76), control1: CGPoint(x: 89, y: 66), control2: CGPoint(x: 80, y: 74))
        body.addCurve(to: CGPoint(x: 26, y: 58), control1: CGPoint(x: 56, y: 80), control2: CGPoint(x: 30, y: 74))
        body.closeSubpath()
        // neck and head (nodding swings them down and forward)
        let headC = CGPoint(x: 82 + nod * 5, y: 84 - nod * 9)
        let headTurn = -nod * 0.5 + tilt * 1.5
        let neck = CGMutablePath()
        neck.move(to: CGPoint(x: 64, y: 70))
        neck.addQuadCurve(to: CGPoint(x: headC.x - 10, y: headC.y + 3), control: CGPoint(x: 68, y: headC.y - 3))
        neck.addLine(to: CGPoint(x: headC.x + 10, y: headC.y - 6))
        neck.addQuadCurve(to: CGPoint(x: 90, y: 52), control: CGPoint(x: 94, y: 68))
        neck.closeSubpath()
        var headT = CGAffineTransform(translationX: headC.x, y: headC.y).rotated(by: headTurn)
        let headP = CGPath(ellipseIn: CGRect(x: -12.5, y: -12, width: 25, height: 24), transform: &headT)
        // one silhouette: outline everything first, then fill on top, so only the outer contour shows
        for p in [body as CGPath, neck, headP] { ctx.addPath(p) }
        ctx.setStrokeColor(rim)
        ctx.setLineWidth(2.2)
        ctx.strokePath()
        fill(ctx, body, {
            radial(ctx, [featherLight, featherMid, featherShade], [0, 0.55, 1], at: CGPoint(x: 66, y: 62), to: CGPoint(x: 56, y: 50), r1: 44)
            // breast sheen
            radial(ctx, [c(0xFFFFFF, 0.65), c(0xFFFFFF, 0)], at: CGPoint(x: 78, y: 58), to: CGPoint(x: 78, y: 58), r1: 14)
        }, stroke: nil)
        fill(ctx, neck, { radial(ctx, [featherLight, featherMid], at: CGPoint(x: 80, y: 74), to: CGPoint(x: 80, y: 66), r1: 20) }, stroke: nil)

        // wing: three overlapping scalloped feathers, lifting for "ta-da" / joy
        ctx.saveGState()
        ctx.translateBy(x: 44, y: 58)
        ctx.rotate(by: wingLift * 0.65)
        ctx.translateBy(x: -44, y: -58)
        let wing = CGMutablePath()
        wing.move(to: CGPoint(x: 40, y: 62))
        wing.addCurve(to: CGPoint(x: 72, y: 50), control1: CGPoint(x: 50, y: 66), control2: CGPoint(x: 66, y: 60))
        wing.addCurve(to: CGPoint(x: 38, y: 44), control1: CGPoint(x: 66, y: 40), control2: CGPoint(x: 46, y: 38))
        wing.closeSubpath()
        fill(ctx, wing, { grad(ctx, [wingMid, wingShade], from: CGPoint(x: 52, y: 62), to: CGPoint(x: 52, y: 40)) })
        ctx.setStrokeColor(c(0xB28A57, 0.55))
        ctx.setLineWidth(1)
        for k in 0..<3 {
            let y = 55 - CGFloat(k) * 5
            ctx.move(to: CGPoint(x: 44 + CGFloat(k) * 3, y: y))
            ctx.addQuadCurve(to: CGPoint(x: 66 - CGFloat(k) * 2, y: y - 2), control: CGPoint(x: 56, y: y - 6))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // head
        ctx.saveGState()
        ctx.translateBy(x: headC.x, y: headC.y)
        ctx.rotate(by: headTurn)
        // comb: three lobes, back to front
        let comb3 = CGMutablePath()
        for (dx, dy, r) in [(CGFloat(-8), CGFloat(11), CGFloat(5.2)), (-1.5, 14, 6), (5.5, 12, 5)] {
            comb3.addEllipse(in: CGRect(x: dx - r, y: dy - r, width: r * 2, height: r * 2.15))
        }
        fill(ctx, comb3, { grad(ctx, [combLight, comb, combDark], from: CGPoint(x: -4, y: 20), to: CGPoint(x: 0, y: 6)) }, stroke: c(0x8F2420, 0.5), width: 0.9)
        // the head's fill (its outline is part of the silhouette above; the comb peeks out behind it)
        ctx.saveGState()
        ctx.addPath(CGPath(ellipseIn: CGRect(x: -12.5, y: -12, width: 25, height: 24), transform: nil))
        ctx.setStrokeColor(rim)
        ctx.setLineWidth(2.2)
        ctx.strokePath()
        ctx.restoreGState()
        fill(ctx, CGPath(ellipseIn: CGRect(x: -12.5, y: -12, width: 25, height: 24), transform: nil), {
            radial(ctx, [featherLight, featherMid, featherShade], [0, 0.6, 1], at: CGPoint(x: -3, y: 5), to: CGPoint(x: 0, y: 0), r1: 16)
        }, stroke: nil)
        // where the neck joins: fill over the head's outline on that side so the silhouette stays continuous
        ctx.saveGState()
        ctx.rotate(by: -headTurn)
        ctx.translateBy(x: -headC.x, y: -headC.y)
        fill(ctx, neck, { radial(ctx, [featherLight, featherMid], at: CGPoint(x: 80, y: 74), to: CGPoint(x: 80, y: 66), r1: 20) }, stroke: nil)
        ctx.restoreGState()
        ctx.addPath(CGPath(ellipseIn: CGRect(x: -11.4, y: -10.9, width: 22.8, height: 21.8), transform: nil))
        ctx.saveGState()
        ctx.clip()
        radial(ctx, [featherLight, featherMid, featherShade], [0, 0.6, 1], at: CGPoint(x: -3, y: 5), to: CGPoint(x: 0, y: 0), r1: 16)
        ctx.restoreGState()
        // wattle
        let wattle = CGMutablePath()
        wattle.move(to: CGPoint(x: 8, y: -4))
        wattle.addQuadCurve(to: CGPoint(x: 10.5, y: -14), control: CGPoint(x: 14.5, y: -8))
        wattle.addQuadCurve(to: CGPoint(x: 8, y: -4), control: CGPoint(x: 5, y: -10))
        fill(ctx, wattle, { grad(ctx, [comb, combDark], from: CGPoint(x: 9, y: -4), to: CGPoint(x: 10, y: -14)) }, stroke: c(0x8F2420, 0.45), width: 0.8)
        // beak: upper and lower, a hair open when delighted
        let open: CGFloat = mood == .delighted ? 1.6 * bump(t, 0.2, 0.4, 0.9) + 0.4 : 0
        let upper = CGMutablePath()
        upper.move(to: CGPoint(x: 10, y: 3.5))
        upper.addQuadCurve(to: CGPoint(x: 21, y: -0.5 + open * 0.2), control: CGPoint(x: 17, y: 3.5))
        upper.addLine(to: CGPoint(x: 10, y: -1))
        upper.closeSubpath()
        fill(ctx, upper, { grad(ctx, [beakLight, beak], from: CGPoint(x: 12, y: 4), to: CGPoint(x: 14, y: -1)) }, stroke: c(0x9C5B08, 0.55), width: 0.8)
        let lower = CGMutablePath()
        lower.move(to: CGPoint(x: 10, y: -1 - open))
        lower.addLine(to: CGPoint(x: 18.5, y: -1.5 - open))
        lower.addQuadCurve(to: CGPoint(x: 10, y: -4.5 - open), control: CGPoint(x: 14, y: -4.5 - open))
        lower.closeSubpath()
        fill(ctx, lower, { grad(ctx, [beak, beakDark], from: CGPoint(x: 12, y: -1), to: CGPoint(x: 12, y: -5)) }, stroke: c(0x9C5B08, 0.55), width: 0.8)
        // cheek and eye
        ctx.setFillColor(blush)
        ctx.fillEllipse(in: CGRect(x: -1, y: -7.5, width: 8, height: 5))
        if eyesClosed {
            ctx.setStrokeColor(ink)
            ctx.setLineWidth(1.8)
            ctx.move(to: CGPoint(x: -1.5, y: 2.5))
            ctx.addQuadCurve(to: CGPoint(x: 6, y: 2.5), control: CGPoint(x: 2.25, y: 7))
            ctx.strokePath()
        } else {
            let eh = 6.2 * (1 - blink * 0.9)
            ctx.setFillColor(ink)
            ctx.fillEllipse(in: CGRect(x: 0, y: 3 - eh / 2 + 0.2, width: 5.4, height: eh))
            if blink < 0.5 {
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.95))
                ctx.fillEllipse(in: CGRect(x: 2.6, y: 3.6, width: 1.9, height: 1.9))
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.6))
                ctx.fillEllipse(in: CGRect(x: 1.1, y: 1.3, width: 0.9, height: 0.9))
            }
        }
        ctx.restoreGState()
        ctx.restoreGState()

        // joy: a burst of four-point sparkles around the hen
        if mood == .delighted, !reduceMotion, t > 0.28, t < 1.25 {
            let u = CGFloat((t - 0.28) / 0.97)
            ctx.saveGState()
            ctx.setAlpha(u < 0.7 ? 1 : (1 - u) / 0.3)
            for (i, (ang, d0)) in [(CGFloat(2.3), CGFloat(34)), (1.6, 40), (0.85, 36), (0.25, 34)].enumerated() {
                let d = d0 + u * 12
                let p = CGPoint(x: 64 + cos(ang) * d, y: 64 + sin(ang) * d + hop)
                star(ctx, at: p, size: (i % 2 == 0 ? 9 : 6.5) * (0.6 + 0.4 * sin(.pi * u)))
            }
            ctx.restoreGState()
        }
    }

    private static func star(_ ctx: CGContext, at c0: CGPoint, size s: CGFloat) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c0.x, y: c0.y + s / 2))
        p.addQuadCurve(to: CGPoint(x: c0.x + s / 2, y: c0.y), control: c0)
        p.addQuadCurve(to: CGPoint(x: c0.x, y: c0.y - s / 2), control: c0)
        p.addQuadCurve(to: CGPoint(x: c0.x - s / 2, y: c0.y), control: c0)
        p.addQuadCurve(to: CGPoint(x: c0.x, y: c0.y + s / 2), control: c0)
        ctx.addPath(p)
        ctx.setFillColor(spark)
        ctx.fillPath()
    }
}

/// The hen, animating (60 Hz while it moves, then still).
final class HenView: NSView {
    var mood: HenMood = .pleased
    var t: Double = 0 { didSet { needsDisplay = true } }
    private var timer: Timer?
    private var start = CACurrentMediaTime()
    var leadIn: Double = 0.15

    override var isFlipped: Bool { false }

    func play() {
        start = CACurrentMediaTime() + leadIn
        timer?.invalidate()
        let tm = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] tm in
            guard let self = self, self.window != nil || CACurrentMediaTime() - self.start < 1 else { tm.invalidate(); return }
            self.t = max(0, CACurrentMediaTime() - self.start)
            if self.t > ChickenArt.duration + 0.3 { self.t = ChickenArt.duration + 0.3; tm.invalidate() }
        }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = min(bounds.width, bounds.height) / ChickenArt.box
        ctx.saveGState()
        ctx.translateBy(x: (bounds.width - ChickenArt.box * s) / 2, y: (bounds.height - ChickenArt.box * s) / 2)
        ctx.scaleBy(x: s, y: s)
        ChickenArt.draw(ctx, t: t, mood: mood, reduceMotion: reduceMotion)
        ctx.restoreGState()
    }
}

/// "Fixed" news: the hen in the island. One line per 10 s, however many items arrived in it.
final class PeckCard: NSObject {
    static let shared = PeckCard()
    private var pending: [(title: String, uid: String, state: String)] = []
    private var flush: DispatchWorkItem?
    private var lastShown: CFTimeInterval = -100
    var leadIn: Double = 0.15          // tests that record the screen want a longer one

    /// `state`: "to_verify" (an agent says it's handled) | "done" (you confirmed it).
    func play(title: String, detail: String, uid: String, state: String = "to_verify") {
        pending.append((title, uid, state))
        emit(["event": "peck", "uid": uid, "title": title, "state": state])
        flush?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.show() }
        flush = w
        // the first one shows right away; more within the next 10 s gather into one line
        let wait = CACurrentMediaTime() - lastShown > 10 ? 0.4 : 10 - (CACurrentMediaTime() - lastShown)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: w)
    }

    private func show() {
        guard !pending.isEmpty else { return }
        let items = pending
        pending = []
        lastShown = CACurrentMediaTime()
        let done = items.allSatisfy { $0.state == "done" }
        let text: String
        if items.count == 1 {
            text = Loc.t(done ? "capture.peck.done_one" : "capture.peck.verify_one", table: "Capture", items[0].title)
        } else {
            text = Loc.plural(done ? "capture.peck.done_many" : "capture.peck.verify_many", table: "Capture", count: items.count)
        }
        let hen = HenView(frame: NSRect(x: 0, y: 0, width: 42, height: 42))
        hen.mood = done ? .delighted : .pleased
        hen.leadIn = leadIn
        let uid = items.count == 1 ? items[0].uid : nil
        var t = Island.Toast(text: text, actionTitle: nil, action: {
            if let u = uid { _ = URLRouter.handle(URL(string: "blurt://item/\(u)")!) } else { AppEnvironment.mainWindow?.showInbox() }
        })
        t.art = hen
        t.seconds = 3.4
        island.toast(t)
        DispatchQueue.main.async { hen.play() }
    }

    /// Frames of the animation as PNGs (docs / tests make GIFs of them): `mood` per file name, both appearances.
    static func renderFrames(to dir: URL, fps: Double = 30, scale: CGFloat = 2, dark: Bool = false, mood: HenMood = .pleased) -> Int {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let n = Int((ChickenArt.duration + 0.5) * fps)
        for i in 0..<n {
            let t = Double(i) / fps
            let w = Int(ChickenArt.box * scale), h = Int(ChickenArt.box * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            ctx.setFillColor(dark ? CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1) : CGColor(srgbRed: 0.97, green: 0.96, blue: 0.94, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            ChickenArt.draw(ctx, t: t, mood: mood)
            guard let img = ctx.makeImage() else { continue }
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(String(format: "f%03d.png", i)))
        }
        return n
    }
}
