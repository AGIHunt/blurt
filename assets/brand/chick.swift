// The blurt brand mark — the 4A line chick (v0.8): front-facing round chick, a tuft of three bumps, dot eyes, a small
// diamond beak, wing nubs and two sound arcs at the top right, in one even line. This file is the geometry; it writes
// every SVG source in assets/brand/ (build.py renders the bitmaps from those):
//
//     swift assets/brand/chick.swift                 # → chick-line.svg, chick-filled.svg, app-icon*.svg, glyph.svg
//     swift assets/brand/chick.swift --alts DIR      # also the three tile treatments (a / b / c), for comparing
//
// Why code: the outline is a union (body ∪ tuft) and the wings are the part of their loop outside the body, which
// CoreGraphics computes exactly (CGPath.union / lineSubtracting, macOS 13+); the menu-bar glyph is the line art turned
// into filled outlines (CGPath.copy(strokingWithWidth:)) so it can carry its own, heavier line in the icon family's
// fixed-stroke 24 grid. The icon art is drawn in "hero space" (the 1254 px d4a-hero raster the design came from) and
// placed with an affine transform; the glyph is drawn directly in 18 pt, so it can be hinted.
import CoreGraphics
import Foundation

// MARK: - geometry

struct Chick {
    // body: a gumdrop, symmetric about cx; `top` is the dome's top (hidden under the tuft), widest `hw` at `yw`
    var cx: CGFloat = 626, top: CGFloat = 300, hw: CGFloat = 412, yw: CGFloat = 735, yb: CGFloat = 1100
    var k1: CGFloat = 0.66, k2: CGFloat = 0.62, k3: CGFloat = 0.66, k4: CGFloat = 0.62
    // tuft: three circles (dx from cx, cy, r) — merged into the outline
    var tuft: [(CGFloat, CGFloat, CGFloat)] = [(-128, 296, 64), (0, 266, 78), (128, 296, 64)]
    // wing: an ellipse per side (dx of its centre from cx, cy, rx, ry, angle in degrees for the left one), outside part only
    var wing: (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (-440, 805, 112, 64, -48)
    var wings = true
    // eyes (dx, cy, r) and their highlight (offset x, offset y, r; r 0 = none)
    var eye: (CGFloat, CGFloat, CGFloat) = (178, 632, 60)
    var glint: (CGFloat, CGFloat, CGFloat) = (-18, -20, 14)
    // beak: a diamond centred (cx, cy): half width, up, down; `slit` = the line between upper and lower beak
    var beak: (CGFloat, CGFloat, CGFloat, CGFloat) = (724, 94, 82, 98)
    var slit = true
    var filledBeak = false
    // sound arcs about (ax, ay): (r, from°, to°), angles clockwise from +x in y-down space (−90 = up)
    var arcCentre = CGPoint(x: 972, y: 446)
    var arcs: [(CGFloat, CGFloat, CGFloat)] = [(128, -86, -6), (208, -80, -10)]

    var bodyPath: CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: cx, y: top))
        p.addCurve(to: CGPoint(x: cx + hw, y: yw), control1: CGPoint(x: cx + k1 * hw, y: top),
                   control2: CGPoint(x: cx + hw, y: yw - k2 * (yw - top)))
        p.addCurve(to: CGPoint(x: cx, y: yb), control1: CGPoint(x: cx + hw, y: yw + k3 * (yb - yw)),
                   control2: CGPoint(x: cx + k4 * hw, y: yb))
        p.addCurve(to: CGPoint(x: cx - hw, y: yw), control1: CGPoint(x: cx - k4 * hw, y: yb),
                   control2: CGPoint(x: cx - hw, y: yw + k3 * (yb - yw)))
        p.addCurve(to: CGPoint(x: cx, y: top), control1: CGPoint(x: cx - hw, y: yw - k2 * (yw - top)),
                   control2: CGPoint(x: cx - k1 * hw, y: top))
        p.closeSubpath()
        return p
    }

    /// The head outline: body ∪ tuft (closed; stroke it).
    var outline: CGPath {
        var o: CGPath = bodyPath
        for (dx, cy, r) in tuft {
            o = o.union(CGPath(ellipseIn: CGRect(x: cx + dx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil))
        }
        // the bumps sit on a base that reaches into the dome, so no pocket opens between them and the body
        if let l = tuft.first, let r = tuft.last {
            let base = CGMutablePath()
            base.addRect(CGRect(x: cx + l.0, y: min(l.1, r.1), width: r.0 - l.0, height: (yw - top) * 0.6))
            o = o.union(base)
        }
        // keep only the outside contour
        return o.componentsSeparated().max { $0.boundingBoxOfPath.width < $1.boundingBoxOfPath.width } ?? o
    }

    func wingLoop(_ side: CGFloat) -> CGPath {
        let (dx, cy, rx, ry, deg) = wing
        var t = CGAffineTransform(translationX: cx + side * dx, y: cy)
        t = t.rotated(by: side * deg * .pi / 180)
        return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry), transform: &t)
    }

    /// The visible wing lines (the loop outside the body), left and right; open paths.
    var wingLines: CGPath {
        let p = CGMutablePath()
        guard wings else { return p }
        for side: CGFloat in [1, -1] { p.addPath(wingLoop(side).lineSubtracting(bodyPath)) }
        return p
    }

    /// The wings as areas (for the fill under the line).
    var wingAreas: CGPath {
        guard wings else { return CGMutablePath() }
        return wingLoop(1).union(wingLoop(-1))
    }

    var eyes: CGPath {
        let p = CGMutablePath()
        let (dx, cy, r) = eye
        for s: CGFloat in [-1, 1] { p.addEllipse(in: CGRect(x: cx + s * dx - r, y: cy - r, width: 2 * r, height: 2 * r)) }
        return p
    }

    var glints: CGPath {
        let p = CGMutablePath()
        let (dx, cy, _) = eye
        let (ox, oy, r) = glint
        guard r > 0 else { return p }
        for s: CGFloat in [-1, 1] { p.addEllipse(in: CGRect(x: cx + s * dx + ox - r, y: cy + oy - r, width: 2 * r, height: 2 * r)) }
        return p
    }

    var beakPath: CGPath {
        let (cy, w, up, down) = beak
        let p = CGMutablePath()
        p.move(to: CGPoint(x: cx, y: cy - up))
        p.addLine(to: CGPoint(x: cx + w, y: cy))
        p.addLine(to: CGPoint(x: cx, y: cy + down))
        p.addLine(to: CGPoint(x: cx - w, y: cy))
        p.closeSubpath()
        return p
    }

    var slitPath: CGPath {
        let (cy, w, _, _) = beak
        let p = CGMutablePath()
        if slit && !filledBeak {
            p.move(to: CGPoint(x: cx - w, y: cy))
            p.addLine(to: CGPoint(x: cx + w, y: cy))
        }
        return p
    }

    func arc(_ i: Int) -> CGPath {
        let (r, a0, a1) = arcs[i]
        let p = CGMutablePath()
        p.addArc(center: arcCentre, radius: r, startAngle: a0 * .pi / 180, endAngle: a1 * .pi / 180, clockwise: false)
        return p
    }
}

// MARK: - output helpers

func fmt(_ v: CGFloat, _ digits: Int) -> String {
    var s = String(format: "%.\(digits)f", Double(v))
    if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
    return s == "-0" ? "0" : s
}

/// SVG path data with absolute M / L / C / Z (quads raised to cubics).
func d(_ path: CGPath, _ t: CGAffineTransform = .identity, digits: Int = 2) -> String {
    var out: [String] = []
    var cur = CGPoint.zero, start = CGPoint.zero
    func P(_ p: CGPoint) -> String { let q = p.applying(t); return fmt(q.x, digits) + " " + fmt(q.y, digits) }
    path.applyWithBlock { e in
        let el = e.pointee, pts = el.points
        switch el.type {
        case .moveToPoint: out.append("M" + P(pts[0])); cur = pts[0]; start = cur
        case .addLineToPoint: out.append("L" + P(pts[0])); cur = pts[0]
        case .addQuadCurveToPoint:
            let c1 = CGPoint(x: cur.x + 2 / 3 * (pts[0].x - cur.x), y: cur.y + 2 / 3 * (pts[0].y - cur.y))
            let c2 = CGPoint(x: pts[1].x + 2 / 3 * (pts[0].x - pts[1].x), y: pts[1].y + 2 / 3 * (pts[0].y - pts[1].y))
            out.append("C" + P(c1) + " " + P(c2) + " " + P(pts[1])); cur = pts[1]
        case .addCurveToPoint: out.append("C" + P(pts[0]) + " " + P(pts[1]) + " " + P(pts[2])); cur = pts[2]
        case .closeSubpath: out.append("Z"); cur = start
        @unknown default: break
        }
    }
    return out.joined()
}

/// A path's outline as an area (the stroke turned into a fill), round caps and joins.
func outlined(_ p: CGPath, width: CGFloat) -> CGPath {
    p.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

func transformed(_ p: CGPath, _ t: CGAffineTransform) -> CGPath {
    var t = t
    return p.copy(using: &t) ?? p
}

// MARK: - looks

struct Look {
    var name: String
    var line: String            // line colour
    var fill: String?           // body + wing fill (nil = none)
    var arcs: String            // arc colour
    var eyes: String
    var glint: String?          // eye highlight colour (nil = none)
    var tile: (String, String)? // tile gradient top → bottom (nil = no tile)
    var rim: String = "#000"    // hairline on the tile edge
    var rimOpacity: CGFloat = 0.06
    var halo: String? = nil     // a sticker edge around the art (transparent logo)
    var title: String
}

let cream = Look(name: "a", line: "#17140f", fill: "#ffffff", arcs: "#17140f", eyes: "#17140f", glint: "#ffffff",
                 tile: ("#ffe36b", "#ffc93a"), title: "black line chick, white body, on a warm yellow tile")
let dark = Look(name: "b", line: "#ffffff", fill: nil, arcs: "#ffffff", eyes: "#ffffff", glint: "#1b1b1f",
                tile: ("#2b2b30", "#121214"), rim: "#fff", rimOpacity: 0.10, title: "white line chick on a near-black tile")
let white = Look(name: "c", line: "#17140f", fill: "#ffd43b", arcs: "#ff5a36", eyes: "#17140f", glint: "#ffffff",
                 tile: ("#ffffff", "#f1f0ec"), title: "black line chick with a yellow body and coral sound arcs, on a white tile")

// The superellipse tile on the macOS 26 grid (824 px at (100, 100) in 1024), cubic fit to |x|^5 + |y|^5 = 1.
let tilePath = "M924 512C924 483.3 924 452.4 924 422.3C923.9 392.7 923.7 360 922.7 332.7C921.6 303 919.4 271.4 913.7 243C910.6 227.6 906.5 212.7 900.3 198.2C893.3 181.8 884 166.6 870.7 153.3C857.4 140 842.2 130.7 825.8 123.7C811.3 117.5 796.4 113.4 781 110.3C752.6 104.6 721 102.4 691.3 101.3C664 100.3 631.3 100.1 601.7 100C571.6 100 540.7 100 512 100C483.3 100 452.4 100 422.3 100C392.7 100.1 360 100.3 332.7 101.3C303 102.4 271.4 104.6 243 110.3C227.6 113.4 212.7 117.5 198.2 123.7C181.8 130.7 166.6 140 153.3 153.3C140 166.6 130.7 181.8 123.7 198.2C117.5 212.7 113.4 227.6 110.3 243C104.6 271.4 102.4 303 101.3 332.7C100.3 360 100.1 392.7 100 422.3C100 452.4 100 483.3 100 512C100 540.7 100 571.6 100 601.7C100.1 631.3 100.3 664 101.3 691.3C102.4 721 104.6 752.6 110.3 781C113.4 796.4 117.5 811.3 123.7 825.8C130.7 842.2 140 857.4 153.3 870.7C166.6 884 181.8 893.3 198.2 900.3C212.7 906.5 227.6 910.6 243 913.7C271.4 919.4 303 921.6 332.7 922.7C360 923.7 392.7 923.9 422.3 924C452.4 924 483.3 924 512 924C540.7 924 571.6 924 601.7 924C631.3 923.9 664 923.7 691.3 922.7C721 921.6 752.6 919.4 781 913.7C796.4 910.6 811.3 906.5 825.8 900.3C842.2 893.3 857.4 884 870.7 870.7C884 857.4 893.3 842.2 900.3 825.8C906.5 811.3 910.6 796.4 913.7 781C919.4 752.6 921.6 721 922.7 691.3C923.7 664 923.9 631.3 924 601.7C924 571.6 924 540.7 924 512Z"

/// The chick's art as SVG elements (stroked centrelines + fills), placed by `t`, line `w` in output units.
func artSVG(_ c: Chick, _ look: Look, _ t: CGAffineTransform, w: CGFloat, arcW: CGFloat? = nil) -> String {
    var s = ""
    let outline = c.outline
    if let h = look.halo {
        // a sticker edge behind everything (the transparent logo: it keeps the black line readable on dark pages)
        let area = c.wingAreas.union(outline)
        s += "  <g id=\"chick-halo\" fill=\"\(h)\" stroke=\"\(h)\" stroke-width=\"\(fmt(w * 2.4, 2))\" stroke-linecap=\"round\" stroke-linejoin=\"round\">\n"
        s += "    <path d=\"\(d(area, t))\"/>\n"
        for i in c.arcs.indices { s += "    <path d=\"\(d(c.arc(i), t))\" fill=\"none\"/>\n" }
        s += "  </g>\n"
    }
    if let f = look.fill {
        let area = c.wingAreas.union(outline)
        s += "  <path id=\"chick-fill\" d=\"\(d(area, t))\" fill=\"\(f)\"/>\n"
    }
    s += "  <g id=\"chick-line\" fill=\"none\" stroke=\"\(look.line)\" stroke-width=\"\(fmt(w, 2))\" stroke-linecap=\"round\" stroke-linejoin=\"round\">\n"
    s += "    <path id=\"chick-outline\" d=\"\(d(outline, t))\"/>\n"
    if c.wings { s += "    <path id=\"chick-wings\" d=\"\(d(c.wingLines, t))\"/>\n" }
    if c.filledBeak {
        s += "    <path id=\"chick-beak\" d=\"\(d(c.beakPath, t))\" fill=\"\(look.line)\"/>\n"
    } else {
        s += "    <path id=\"chick-beak\" d=\"\(d(c.beakPath, t))\"/>\n"
        if c.slit { s += "    <path id=\"chick-slit\" d=\"\(d(c.slitPath, t))\"/>\n" }
    }
    s += "  </g>\n"
    s += "  <path id=\"chick-eyes\" d=\"\(d(c.eyes, t))\" fill=\"\(look.eyes)\"/>\n"
    if let g = look.glint, c.glint.2 > 0 { s += "  <path id=\"chick-glints\" d=\"\(d(c.glints, t))\" fill=\"\(g)\"/>\n" }
    if !c.arcs.isEmpty {
        s += "  <g id=\"chick-arcs\" fill=\"none\" stroke=\"\(look.arcs)\" stroke-width=\"\(fmt(arcW ?? w, 2))\" stroke-linecap=\"round\">\n"
        for i in c.arcs.indices { s += "    <path d=\"\(d(c.arc(i), t))\"/>\n" }
        s += "  </g>\n"
    }
    return s
}

/// Bounding box of the art in hero space, line included (`w` in hero units).
func artBox(_ c: Chick, w: CGFloat) -> CGRect {
    var b = c.outline.boundingBoxOfPath.union(c.wingAreas.boundingBoxOfPath)
    for i in c.arcs.indices { b = b.union(c.arc(i).boundingBoxOfPath) }
    return b.insetBy(dx: -w / 2, dy: -w / 2)
}

/// Places the art: scale so the art's width is `width` output units, centred on (x, y) (the art box's centre).
func place(_ c: Chick, w: CGFloat, width: CGFloat, centre: CGPoint, nudge: CGPoint = .zero) -> CGAffineTransform {
    let s = width / artBox(c, w: w / (width / artBox(c, w: 0).width)).width
    let b = artBox(c, w: w / s)
    return CGAffineTransform(translationX: centre.x + nudge.x - b.midX * s, y: centre.y + nudge.y - b.midY * s).scaledBy(x: s, y: s)
}

let shadowDefs = """
  <filter id="tile-shadow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="12"/><feComponentTransfer><feFuncA type="linear" slope=".3"/></feComponentTransfer><feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>
"""

func iconSVG(_ c: Chick, _ look: Look, w: CGFloat, artWidth: CGFloat, nudge: CGPoint = .zero, title: String, desc: String,
             arcW: CGFloat? = nil) -> String {
    let t = place(c, w: w, width: artWidth, centre: CGPoint(x: 512, y: 512), nudge: nudge)
    var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\" width=\"1024\" height=\"1024\">\n"
    s += "<title>\(title)</title>\n<desc>\(desc)</desc>\n<defs>\n" + shadowDefs
    if let (a, b) = look.tile {
        s += "  <linearGradient id=\"tile-bg\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop offset=\"0\" stop-color=\"\(a)\"/><stop offset=\"1\" stop-color=\"\(b)\"/></linearGradient>\n"
    }
    s += "</defs>\n"
    if look.tile != nil {
        s += "<g id=\"tile\">\n  <path d=\"\(tilePath)\" fill=\"url(#tile-bg)\" filter=\"url(#tile-shadow)\"/>\n"
        s += "  <path d=\"\(tilePath)\" fill=\"none\" stroke=\"\(look.rim)\" stroke-opacity=\"\(fmt(look.rimOpacity, 2))\" stroke-width=\"2\"/>\n</g>\n"
    }
    s += "<g id=\"chick\">\n" + artSVG(c, look, t, w: w, arcW: arcW) + "</g>\n</svg>\n"
    return s
}

// MARK: - the variants

/// The master (hero pose), as drawn.
let master = Chick()

/// 32 px (and the 64 px favicon): heavier line, the chick a little bigger, no glints, filled beak.
var small: Chick {
    var c = Chick()
    c.glint = (0, 0, 0)
    c.filledBeak = true
    c.beak = (726, 70, 62, 74)
    c.eye = (176, 632, 70)
    c.tuft = [(-124, 300, 70), (0, 270, 84), (124, 300, 70)]
    c.arcs = [(150, -84, -8)]
    c.arcCentre = CGPoint(x: 950, y: 470)
    return c
}

/// 16 px: the arcs go, the wings shrink, everything chunkier.
var tiny: Chick {
    var c = small
    c.arcs = []
    c.wing = (-430, 790, 100, 70, -45)
    c.eye = (172, 640, 84)
    c.beak = (744, 78, 64, 80)
    c.tuft = [(-120, 300, 76), (0, 268, 92), (120, 300, 76)]
    return c
}

/// The menu-bar glyph, drawn directly in 18 pt (y down) with a 1.5 pt line (3 px at 2x), simplified for the size: the
/// tuft's bumps are bigger, the beak is a solid diamond, the arcs hug the top-right corner. Hinted by construction: the
/// body's outer edges (left, right, bottom) sit on whole points, so at 1x the outside of the line is crisp and at 2x
/// both sides; the eyes are 2 pt dots centred on whole points (2 × 2 px at 1x, 4 × 4 at 2x).
var glyphChick: Chick {
    var c = Chick()
    c.cx = 7.5; c.top = 7.0; c.hw = 4.75; c.yw = 11.7; c.yb = 16.25
    c.k1 = 0.92; c.k2 = 0.5; c.k3 = 0.62; c.k4 = 0.68
    c.tuft = [(-2.2, 6.5, 1.15), (0, 5.85, 1.4), (2.2, 6.5, 1.15)]
    c.wing = (-4.9, 12.7, 1.2, 0.8, -40)
    c.eye = (2.5, 11, 1)
    c.glint = (0, 0, 0)
    c.filledBeak = true
    c.slit = false
    c.beak = (13.15, 1.3, 1.0, 1.3)
    c.arcCentre = CGPoint(x: 12.2, y: 6.6)
    c.arcs = [(2.2, -86, -4), (4.45, -82, -10)]
    return c
}

/// The glyph in the icon family's 24 grid: filled outlines (the family's strokes are a fixed 1.75), three layers — the
/// chick, the inner sound arc, the outer one (MenuGlyph pulses the arcs while voice input listens).
func glyphSVG(_ c: Chick, w wPt: CGFloat = 1.5) -> String {
    let g = CGAffineTransform(scaleX: 4.0 / 3.0, y: 4.0 / 3.0)
    var body: CGPath = outlined(c.outline, width: wPt)
    if c.wings { body = body.union(outlined(c.wingLines, width: wPt)) }
    let beak = outlined(c.beakPath, width: 0.5).union(c.beakPath)     // softened corners
    body = body.union(beak).union(c.eyes)
    var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.75\" stroke-linecap=\"round\" stroke-linejoin=\"round\" data-group=\"brand\">\n"
    svg += "  <title>blurt — the chick that blurts it out (app mark: menu bar, tray)</title>\n"
    svg += "  <desc>The 4A line chick for the menu bar (an 18 pt template image) and the tray, as filled outlines with its own 1.5 pt line (2 grid units; the family strokes at 1.75). Drawn on the 18 pt grid: the body's outer edges sit on whole points, the eyes are 2 pt dots centred on whole points. Layers: the chick, the inner sound arc, the outer sound arc (MenuGlyph pulses the arcs while voice input listens). Generated by assets/brand/chick.swift; do not edit by hand.</desc>\n"
    svg += "  <g fill=\"currentColor\" stroke=\"none\">\n"
    svg += "    <path d=\"\(d(transformed(body, g), digits: 3))\"/>\n"
    for i in c.arcs.indices {
        svg += "    <path d=\"\(d(transformed(outlined(c.arc(i), width: wPt), g), digits: 3))\"/>\n"
    }
    svg += "  </g>\n</svg>\n"
    return svg
}

// MARK: - write

let args = CommandLine.arguments
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
func write(_ s: String, _ name: String, dir: URL = here) {
    try! s.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    print("wrote", dir.appendingPathComponent(name).path)
}

// the chosen tile (see README): a
let chosen = cream
let iconW: CGFloat = 30            // line, 1024 canvas
let iconArtW: CGFloat = 604        // art width on the 824 tile
let iconNudge = CGPoint(x: -8, y: 10)

let descMaster = "Master app icon, 1024 canvas on the macOS 26 grid: 824 px superellipse tile at (100,100), soft shadow; group #chick is the logo. Generated by assets/brand/chick.swift; rendered by assets/brand/build.py."
write(iconSVG(master, chosen, w: iconW, artWidth: iconArtW, nudge: iconNudge, title: "blurt app icon (口喷鸡) — the 4A line chick", desc: descMaster), "app-icon.svg")
write(iconSVG(small, chosen, w: 54, artWidth: 690, nudge: CGPoint(x: -4, y: 10), title: "blurt app icon — 32 px",
              desc: "The 32 px slot (16@2x) and the favicon: a heavier line, one sound arc, a filled beak, no glints. Generated by chick.swift."),
      "app-icon-small.svg")
write(iconSVG(tiny, chosen, w: 76, artWidth: 640, nudge: CGPoint(x: 0, y: 14), title: "blurt app icon — 16 px",
              desc: "The 16 px slot: no sound arcs, chunkier line, eyes and beak. Generated by chick.swift."),
      "app-icon-16.svg")

// line + filled masters, transparent, 1024
let lineLook = Look(name: "line", line: "#000", fill: nil, arcs: "#000", eyes: "#000", glint: nil, tile: nil, title: "")
let filledLook = Look(name: "filled", line: "#17140f", fill: "#ffffff", arcs: "#17140f", eyes: "#17140f", glint: "#ffffff", tile: nil, title: "")
write(iconSVG(master, lineLook, w: 40, artWidth: 960, title: "blurt — the 4A line chick (line master)",
              desc: "Line art for small and monochrome use: one even line, dot eyes, diamond beak, wing nubs, two sound arcs. Generated by chick.swift."),
      "chick-line.svg")
write(iconSVG(master, filledLook, w: 40, artWidth: 960, title: "blurt — the 4A line chick (filled master)",
              desc: "The line art over a flat fill (body and wings), as on the app icon. Generated by chick.swift."),
      "chick-filled.svg")
// the logo (README, site): the chosen tile's chick without the tile, on a white sticker edge so the black line and arcs
// read on dark pages too; the viewBox is cropped to the art
do {
    var logo = filledLook
    logo.halo = "#ffffff"
    let w: CGFloat = 40
    let t = place(master, w: w, width: 900, centre: CGPoint(x: 512, y: 512))
    var b = artBox(master, w: w * 2.4 / t.a).applying(t)
    b = b.insetBy(dx: -8, dy: -8)
    let side = max(b.width, b.height)
    let vb = "\(fmt(b.midX - side / 2, 1)) \(fmt(b.midY - side / 2, 1)) \(fmt(side, 1)) \(fmt(side, 1))"
    var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(vb)\" width=\"1024\" height=\"1024\">\n"
    svg += "<title>blurt logo — the 4A line chick</title>\n<desc>The app icon's chick without the tile, on a white sticker edge (transparent around it). Generated by chick.swift.</desc>\n"
    svg += "<g id=\"chick\">\n" + artSVG(master, logo, t, w: w) + "</g>\n</svg>\n"
    write(svg, "logo.svg")
}

write(glyphSVG(glyphChick), "glyph.svg")

if let i = args.firstIndex(of: "--alts"), i + 1 < args.count {
    let dir = URL(fileURLWithPath: args[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for look in [cream, dark, white] {
        write(iconSVG(master, look, w: iconW, artWidth: iconArtW, nudge: iconNudge, title: look.title, desc: ""), "tile-\(look.name).svg", dir: dir)
        write(iconSVG(small, look, w: 54, artWidth: 690, nudge: CGPoint(x: -4, y: 10), title: look.title, desc: ""), "tile-\(look.name)-small.svg", dir: dir)
        write(iconSVG(tiny, look, w: 76, artWidth: 640, nudge: CGPoint(x: 0, y: 14), title: look.title, desc: ""), "tile-\(look.name)-16.svg", dir: dir)
    }
}
