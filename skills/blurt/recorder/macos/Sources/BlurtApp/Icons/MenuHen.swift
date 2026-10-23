// The colour menu-bar hen (brand direction A, assets/brand/app-icon-small.svg): the yellow hen head in profile with
// its red comb and wattle, the open orange beak and two red shout strokes — no tile — redrawn for an 18 pt status
// item. It is drawn in code on a 36-unit grid (1 unit = 1 px at 2x, ½ px at 1x); the eye is centred on a pixel at
// 1x and 2x, so it stays a crisp dot.
//
//   bold dark outline   every shape is stroked 2 units (1 pt) outside its fill, back to front, so overlapping parts
//                       keep a dark line between them and the whole hen has a dark silhouette on a light bar
//   rim                 on a dark, tinted or highlighted bar the dark outline melts into the bar: `.dark` adds a thin
//                       light ring outside it (App picks the look from the status button's effectiveAppearance)
//
// Self-contained (AppKit + CoreGraphics only). The self-test `menuglyph DIR` renders it on fake menu bars.
import AppKit

enum MenuHen {
    enum Look: String, CaseIterable {
        /// a light menu bar: the dark outline does the separating
        case light
        /// a dark, tinted or highlighted menu bar: a light rim outside the outline
        case dark
    }

    // the palette of app-icon-small.svg, flattened for 18 pt
    private static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
    static let ink = rgb(0x1F1A1A)
    static let headTop = rgb(0xFFE14A)
    static let headBottom = rgb(0xFBB91F)
    static let red = rgb(0xF6492F)
    static let beak = rgb(0xFFA22E)
    static let mouth = rgb(0xC81C2A)
    static let shout = rgb(0xFF5A3C)
    static let rimColor = rgb(0xFFFFFF, 0.85)

    /// The outline (units outside each fill) and the rim (units outside the outline).
    static let outline: CGFloat = 2
    static let rimWidth: CGFloat = 1.25
    /// 2x and up: the line between overlapping parts (the comb's lobes, the head over the comb), units each side
    static let innerLine: CGFloat = 1.25

    // MARK: geometry (36 × 36, y down, facing right; fills stay inside 3.5…32.5 so outline and rim fit)

    /// the comb's three lobes, back to front: each is outlined over the one behind it, so they read as lobes
    static let combLobes: [CGPath] = [
        CGPath(ellipseIn: CGRect(x: 3.5, y: 10, width: 7, height: 7), transform: nil),          // low, at the back
        CGPath(ellipseIn: CGRect(x: 6.5, y: 5, width: 8, height: 8), transform: nil),           // the middle one
        {                                                                                       // the front one, tallest
            let p = CGMutablePath()
            p.addEllipse(in: CGRect(x: 12.5, y: 3.5, width: 8.5, height: 8.5))
            p.addRect(CGRect(x: 10, y: 8, width: 8, height: 6))                                  // down behind the head
            return p
        }(),
    ]

    static var comb: CGPath {
        let p = CGMutablePath()
        for l in combLobes { p.addPath(l) }
        return p
    }

    static let head: CGPath = {
        // round and chubby, the face a little flatter, two neck feathers at the back
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 15, y: 11))
        p.addCurve(to: CGPoint(x: 23.5, y: 19), control1: CGPoint(x: 20, y: 11), control2: CGPoint(x: 23.5, y: 14.5))
        p.addCurve(to: CGPoint(x: 21, y: 28.5), control1: CGPoint(x: 23.5, y: 23), control2: CGPoint(x: 23, y: 26))
        p.addCurve(to: CGPoint(x: 13, y: 32.5), control1: CGPoint(x: 19, y: 31.5), control2: CGPoint(x: 16.5, y: 32.5))
        p.addLine(to: CGPoint(x: 7, y: 32.5))
        p.addLine(to: CGPoint(x: 8.5, y: 30.5))
        p.addLine(to: CGPoint(x: 3.5, y: 29.5))
        p.addLine(to: CGPoint(x: 5, y: 27))
        p.addCurve(to: CGPoint(x: 3.5, y: 20.5), control1: CGPoint(x: 3.8, y: 25.5), control2: CGPoint(x: 3.5, y: 23))
        p.addCurve(to: CGPoint(x: 15, y: 11), control1: CGPoint(x: 3.5, y: 14.5), control2: CGPoint(x: 9, y: 11))
        p.closeSubpath()
        return p
    }()

    /// hangs under the beak, on the chin
    static let wattle: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 19.5, y: 27))
        p.addLine(to: CGPoint(x: 24, y: 27))
        p.addCurve(to: CGPoint(x: 23.5, y: 32), control1: CGPoint(x: 25.5, y: 28.5), control2: CGPoint(x: 25.5, y: 31))
        p.addCurve(to: CGPoint(x: 19.5, y: 30), control1: CGPoint(x: 22, y: 33), control2: CGPoint(x: 19.5, y: 32))
        p.closeSubpath()
        return p
    }()

    /// the whole open beak as one outlined shape: the jaws part like a "<" turned round, and the mouth between them
    /// curves in, so it reads as shouting, not as a box
    static let beakOutline: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 22.5, y: 16))
        p.addCurve(to: CGPoint(x: 30.5, y: 14.5), control1: CGPoint(x: 25.5, y: 14), control2: CGPoint(x: 28.5, y: 13.5))
        p.addCurve(to: CGPoint(x: 28.5, y: 25), control1: CGPoint(x: 26.5, y: 18), control2: CGPoint(x: 26.5, y: 21.5))
        p.addCurve(to: CGPoint(x: 22.5, y: 26.5), control1: CGPoint(x: 26.5, y: 26.5), control2: CGPoint(x: 24.5, y: 27))
        p.closeSubpath()
        return p
    }()

    /// the upper jaw
    static let beakTop: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 22.5, y: 16))
        p.addCurve(to: CGPoint(x: 30.5, y: 14.5), control1: CGPoint(x: 25.5, y: 14), control2: CGPoint(x: 28.5, y: 13.5))
        p.addLine(to: CGPoint(x: 22.5, y: 20))
        p.closeSubpath()
        return p
    }()

    /// the lower jaw, dropped open
    static let beakBottom: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 22.5, y: 23.5))
        p.addLine(to: CGPoint(x: 28.5, y: 25))
        p.addCurve(to: CGPoint(x: 22.5, y: 26.5), control1: CGPoint(x: 26.5, y: 26.5), control2: CGPoint(x: 24.5, y: 27))
        p.closeSubpath()
        return p
    }()

    /// the eye at 2x and up: big, as in the app icon (7 px), with a 2 px highlight
    static let eye = CGRect(x: 15, y: 14.5, width: 7, height: 7)
    static let eyeLight = CGRect(x: 18.5, y: 15.5, width: 2, height: 2)
    /// 1x: a solid 2 × 2 px dot on whole pixels
    static let eyeSmall = CGRect(x: 16, y: 16, width: 4, height: 4)

    /// two shout strokes fanning out from the beak (centre lines; round caps)
    static let shouts: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 32, y: 17.5), CGPoint(x: 33.75, y: 16.25)),
        (CGPoint(x: 31.25, y: 23), CGPoint(x: 33.25, y: 24.5)),
    ]
    static let shoutWidth: CGFloat = 3

    // MARK: drawing

    /// Draws the hen into `rect` (square) of a y-up context (an NSImage drawing handler, a bitmap).
    static func draw(in ctx: CGContext, rect: CGRect, look: Look) {
        let s = min(rect.width, rect.height) / 36
        ctx.saveGState()
        ctx.translateBy(x: rect.midX - 18 * s, y: rect.midY + 18 * s)
        ctx.scaleBy(x: s, y: -s)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        let body: [CGPath] = [comb, head, wattle, beakOutline]
        let shoutPath = CGMutablePath()
        for (a, b) in shouts { shoutPath.move(to: a); shoutPath.addLine(to: b) }

        if look == .dark {
            // one light ring around the whole silhouette, outside the outline
            ctx.setStrokeColor(rimColor)
            ctx.setLineWidth(2 * (outline + rimWidth))
            for p in body { ctx.addPath(p) }
            ctx.strokePath()
            ctx.setLineWidth(shoutWidth + 2 * rimWidth)
            ctx.addPath(shoutPath); ctx.strokePath()
        }

        // 2x and up has the pixels for the comb's lobes, thinner inner lines and the eye's highlight; 1x keeps to
        // the silhouette and a 2 × 2 eye
        let m = ctx.userSpaceToDeviceSpaceTransform, hi = hypot(m.a, m.b) >= 0.9
        // the silhouette: every shape's outline at full width, under all the fills
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(2 * outline)
        for p in body { ctx.addPath(p) }
        ctx.strokePath()

        /// a thinner dark line where this shape overlaps the ones behind it, then the fill
        func shape(_ p: CGPath, _ fill: () -> Void) {
            ctx.setStrokeColor(ink)
            ctx.setLineWidth(2 * (hi ? innerLine : outline))
            ctx.addPath(p); ctx.strokePath()
            ctx.saveGState()
            ctx.addPath(p); ctx.clip()
            fill()
            ctx.restoreGState()
        }
        func flat(_ c: CGColor) -> () -> Void { { ctx.setFillColor(c); ctx.fill(CGRect(x: 0, y: 0, width: 36, height: 36)) } }

        if hi { for l in combLobes { shape(l, flat(red)) } } else { shape(comb, flat(red)) }
        shape(head) {
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [headTop, headBottom] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 13), end: CGPoint(x: 0, y: 32), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        shape(wattle, flat(red))
        shape(beakOutline) {
            ctx.setFillColor(mouth); ctx.fill(CGRect(x: 0, y: 0, width: 36, height: 36))
            ctx.setFillColor(beak)
            ctx.addPath(beakTop); ctx.fillPath()
            ctx.addPath(beakBottom); ctx.fillPath()
        }

        ctx.setFillColor(ink)
        ctx.fillEllipse(in: hi ? eye : eyeSmall)
        if hi { ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); ctx.fillEllipse(in: eyeLight) }

        ctx.setStrokeColor(shout)
        ctx.setLineWidth(shoutWidth)
        ctx.addPath(shoutPath); ctx.strokePath()
        ctx.restoreGState()
    }

    /// An `size`-point NSImage of the hen (not a template: it keeps its colours on every menu bar).
    static func image(size: CGFloat = 18, look: Look) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: ctx, rect: r, look: look)
            return true
        }
        img.isTemplate = false
        return img
    }
}
