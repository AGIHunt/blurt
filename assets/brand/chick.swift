// The blurt brand mark — the 4A line chick (v0.8): front-facing round chick, a tuft of three bumps, dot eyes, a small
// diamond beak, wing nubs and two sound arcs at the top right, in one even line. This file is the geometry; it writes
// every SVG source in assets/brand/ (build.py renders the bitmaps from those) and the mac app's mascot drawing:
//
//     swift assets/brand/chick.swift                 # → chick-line.svg, chick-filled.svg, app-icon*.svg, glyph.svg,
//                                                    #   …/BlurtApp/Icons/MascotGeometry.swift (the mascot, in colour),
//                                                    #   …/BlurtApp/App/MenuGlyphGeometry.swift (the menu bar's arcs)
//     swift assets/brand/chick.swift --alts DIR      # also the three v0.8 yellow / dark / white tile treatments
//     swift assets/brand/chick.swift --check         # write nothing; exit 1 if an output is stale (tests run this)
//
// The icon tile's colour is not here: it is `gradient.field` (and `gradient.linear` for 32 / 16 px, `gradient.deep`
// for the dark variant, `gradient.grain` for the grain) in assets/color/tokens.json, read at run time, so colour stays
// single-sourced (docs/design/system.md §2.2, §6).
//
// Why code: the outline is a union (body ∪ tuft) and the wings are the part of their loop outside the body, which
// CoreGraphics computes exactly (CGPath.union / lineSubtracting, macOS 13+); the menu-bar glyph is the same chick as a
// filled silhouette with the face knocked out (CGPath.subtracting), stored as a fill in the icon family's 24 grid. The
// icon art is drawn in "hero space" (the 1254 px d4a-hero raster the design came from) and placed with an affine
// transform; the glyph is drawn directly in 18 pt, so it can be hinted.
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

// MARK: - tiles

/// A gradient stop: colour, alpha, position (0…1).
struct GStop { var hex: String; var alpha: CGFloat = 1; var at: CGFloat }

/// One layer of a field, as in tokens.json: centre and radius are fractions of the tile's box, y down; a linear
/// layer's angle is CSS's (180 = top → bottom).
enum FieldLayer {
    case linear(angle: CGFloat, stops: [GStop])
    case radial(centre: CGPoint, radius: CGSize, stops: [GStop])
}

/// A tile fill: a plain vertical gradient over the 824 box (32 / 16 px, and the v0.8 alternatives), or a layered
/// field (bottom → top) with monochrome grain on top (`grain` = its opacity, 0 = none; `frequency` per unit of the
/// 1024 canvas, so the grain scales with the art).
enum Tile {
    case vertical([GStop])
    case field(layers: [FieldLayer], grain: CGFloat, frequency: CGFloat)
}

// MARK: - looks

struct Look {
    var name: String
    var line: String            // line colour
    var fill: String?           // body + wing fill (nil = none)
    var arcs: String            // arc colour
    var eyes: String
    var glint: String?          // eye highlight colour (nil = none)
    var tile: Tile?             // the tile's fill (nil = no tile)
    var rim: String = "#000"    // line on the tile edge
    var rimOpacity: CGFloat = 0.06
    var rimWidth: CGFloat = 2
    var halo: String? = nil     // a sticker edge around the art (transparent logo)
    var title: String
}

let cream = Look(name: "a", line: "#17140f", fill: "#ffffff", arcs: "#17140f", eyes: "#17140f", glint: "#ffffff",
                 tile: .vertical([GStop(hex: "#ffe36b", at: 0), GStop(hex: "#ffc93a", at: 1)]), title: "black line chick, white body, on a warm yellow tile")
let dark = Look(name: "b", line: "#ffffff", fill: nil, arcs: "#ffffff", eyes: "#ffffff", glint: "#1b1b1f",
                tile: .vertical([GStop(hex: "#2b2b30", at: 0), GStop(hex: "#121214", at: 1)]), rim: "#fff", rimOpacity: 0.10, title: "white line chick on a near-black tile")
let white = Look(name: "c", line: "#17140f", fill: "#ffd43b", arcs: "#ff5a36", eyes: "#17140f", glint: "#ffffff",
                 tile: .vertical([GStop(hex: "#ffffff", at: 0), GStop(hex: "#f1f0ec", at: 1)]), title: "black line chick with a yellow body and coral sound arcs, on a white tile")

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

/// The tile's box on the 1024 canvas (the superellipse's bounds); field centres and radii are fractions of it.
let tileBox = CGRect(x: 100, y: 100, width: 824, height: 824)

func stopsSVG(_ stops: [GStop]) -> String {
    stops.map { st in
        "<stop offset=\"\(fmt(st.at, 3))\" stop-color=\"\(st.hex)\"" + (st.alpha < 1 ? " stop-opacity=\"\(fmt(st.alpha, 3))\"" : "") + "/>"
    }.joined()
}

/// A CSS-style linear gradient (angle 0 = up, 90 = right, 180 = down) across the tile box, in user space.
func linearDef(_ id: String, angle: CGFloat, _ stops: [GStop]) -> String {
    let a = angle * .pi / 180, dx = sin(a), dy = -cos(a)
    let half = (tileBox.width * abs(dx) + tileBox.height * abs(dy)) / 2
    let x1 = tileBox.midX - dx * half, y1 = tileBox.midY - dy * half, x2 = tileBox.midX + dx * half, y2 = tileBox.midY + dy * half
    return "  <linearGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" x1=\"\(fmt(x1, 1))\" y1=\"\(fmt(y1, 1))\" x2=\"\(fmt(x2, 1))\" y2=\"\(fmt(y2, 1))\">\(stopsSVG(stops))</linearGradient>\n"
}

/// An elliptical radial gradient (CSS `radial-gradient(rx ry at cx cy)` in fractions of the tile box), in user space.
func radialDef(_ id: String, centre: CGPoint, radius: CGSize, _ stops: [GStop]) -> String {
    let x = tileBox.minX + centre.x * tileBox.width, y = tileBox.minY + centre.y * tileBox.height
    let rx = radius.width * tileBox.width, ry = radius.height * tileBox.height
    return "  <radialGradient id=\"\(id)\" cx=\"0\" cy=\"0\" r=\"1\" gradientUnits=\"userSpaceOnUse\" gradientTransform=\"translate(\(fmt(x, 2)) \(fmt(y, 2))) scale(\(fmt(rx, 2)) \(fmt(ry, 2)))\">\(stopsSVG(stops))</radialGradient>\n"
}

/// Monochrome fractal noise, 2 octaves, contrast ×3, at `opacity` (drawn with mix-blend-mode overlay) — the brand grain.
func grainFilter(_ id: String, opacity: CGFloat, frequency: CGFloat) -> String {
    let f = ["R", "G", "B"].map { "<feFunc\($0) type=\"linear\" slope=\"3\" intercept=\"-1\"/>" }.joined()
    return "  <filter id=\"\(id)\" filterUnits=\"userSpaceOnUse\" x=\"\(fmt(tileBox.minX, 0))\" y=\"\(fmt(tileBox.minY, 0))\" width=\"\(fmt(tileBox.width, 0))\" height=\"\(fmt(tileBox.height, 0))\"><feTurbulence type=\"fractalNoise\" baseFrequency=\"\(fmt(frequency, 3))\" numOctaves=\"2\" stitchTiles=\"stitch\"/><feColorMatrix type=\"saturate\" values=\"0\"/><feComponentTransfer>\(f)<feFuncA type=\"linear\" slope=\"0\" intercept=\"\(fmt(opacity, 3))\"/></feComponentTransfer></filter>\n"
}

/// The tile: defs and the `#tile` group. `#tile-bg` is the base gradient (the whole tile for a vertical tile; the
/// bottom layer of a field). A field is drawn as `#tile-field`, a group clipped to the superellipse: the base again,
/// each layer as a box-sized rect, then the grain rect `#tile-grain` (overlay). The base sits inside the group too, so
/// the overlay blends with the whole field whether or not the renderer isolates the clipped group. build.py drops
/// `#tile-grain` below 64 px and turns `#tile-field` into the full-bleed square.
func tileSVG(_ look: Look) -> (defs: String, body: String) {
    guard let tile = look.tile else { return ("", "") }
    let rect = "<rect x=\"\(fmt(tileBox.minX, 0))\" y=\"\(fmt(tileBox.minY, 0))\" width=\"\(fmt(tileBox.width, 0))\" height=\"\(fmt(tileBox.height, 0))\""
    var defs = "", field = ""
    switch tile {
    case .vertical(let stops):
        defs += linearDef("tile-bg", angle: 180, stops)
    case .field(let layers, let grain, let frequency):
        defs += "  <clipPath id=\"tile-clip\"><path d=\"\(tilePath)\"/></clipPath>\n"
        field += "  <g id=\"tile-field\" clip-path=\"url(#tile-clip)\">\n"
        for (i, layer) in layers.enumerated() {
            let id = i == 0 ? "tile-bg" : "tile-l\(i)"
            switch layer {
            case .linear(let angle, let stops): defs += linearDef(id, angle: angle, stops)
            case .radial(let c, let r, let stops): defs += radialDef(id, centre: c, radius: r, stops)
            }
            field += "    \(rect) fill=\"url(#\(id))\"/>\n"
        }
        if grain > 0 {
            defs += grainFilter("tile-noise", opacity: grain, frequency: frequency)
            field += "    \(rect) id=\"tile-grain\" filter=\"url(#tile-noise)\" style=\"mix-blend-mode:overlay\"/>\n"
        }
        field += "  </g>\n"
    }
    var body = "<g id=\"tile\">\n  <path d=\"\(tilePath)\" fill=\"url(#tile-bg)\" filter=\"url(#tile-shadow)\"/>\n" + field
    body += "  <path d=\"\(tilePath)\" fill=\"none\" stroke=\"\(look.rim)\" stroke-opacity=\"\(fmt(look.rimOpacity, 2))\" stroke-width=\"\(fmt(look.rimWidth, 2))\"/>\n</g>\n"
    return (defs, body)
}

func iconSVG(_ c: Chick, _ look: Look, w: CGFloat, artWidth: CGFloat, nudge: CGPoint = .zero, title: String, desc: String,
             arcW: CGFloat? = nil) -> String {
    let t = place(c, w: w, width: artWidth, centre: CGPoint(x: 512, y: 512), nudge: nudge)
    let tile = tileSVG(look)
    var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\" width=\"1024\" height=\"1024\">\n"
    s += "<title>\(title)</title>\n<desc>\(desc)</desc>\n<defs>\n" + shadowDefs + "\n" + tile.defs + "</defs>\n" + tile.body
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

/// The menu-bar glyph's width with its wings, in pt of its 18 pt box (it is then about 16.2 tall, tuft included).
let glyphWidth: CGFloat = 17.2

/// The menu-bar glyph (v0.9), in its 18 pt box (y down): the logo's chick as one bold filled silhouette — body, tuft
/// and wing nubs as one shape, the eyes and the beak knocked out. It is the master scaled uniformly: the app icon's
/// chick as it looks filled (its outline and wings grown by half the icon's line), so the silhouette has the logo's
/// proportions — `glyphWidth` wide, about 16.2 tall with the tuft. (The first v0.9 glyph was drawn on its own, 16.5 pt tall on a
/// 13 pt body: beside the logo it read thin and tall.) Only what a silhouette loses is redrawn for 18 pt: the tuft (as
/// bold as the 16 px icon's, and higher), 2.3 pt eye holes and a filled beak, so they stay open at 1x. No arcs at rest: the sound arcs show only while voice input listens, to the
/// right of the chick (MenuGlyphGeometry.swift, 2 pt lines), and the status item widens for them. The foot sits on a
/// whole point (y 17, so 19 in the 22 pt bar).
var glyphChick: Chick {
    let m = master
    // the icon's line in hero units: half of it lies outside the outline, and that is what the filled chick shows
    let half = iconW / 2 / place(m, w: iconW, width: iconArtW, centre: .zero).a
    var f = m
    f.top -= half; f.hw += half; f.yb += half
    // the tuft as bold as the 16 px icon's, its bumps further apart and higher: the logo's tuft reads by its line;
    // filled in at the master's size its three bumps melt into the dome at 1x and 2x
    f.tuft = tiny.tuft.map { ($0.0 * 1.45, $0.1 - 70, $0.2 + half) }
    f.wing = (m.wing.0, m.wing.1, m.wing.2 + half, m.wing.3 + half, m.wing.4)
    let box = f.outline.union(f.wingAreas).boundingBoxOfPath
    // one scale for x and y, about the centre line (x 9) and the foot (y 17)
    let s = glyphWidth / box.width
    func y(_ v: CGFloat) -> CGFloat { 17 + (v - f.yb) * s }
    var c = m
    c.cx = 9; c.top = y(f.top); c.hw = f.hw * s; c.yw = y(f.yw); c.yb = 17
    c.tuft = f.tuft.map { ($0.0 * s, y($0.1), $0.2 * s) }
    c.wing = (f.wing.0 * s, y(f.wing.1), f.wing.2 * s, f.wing.3 * s, f.wing.4)
    c.eye = (m.eye.0 * s, y(m.eye.1), 1.15)
    c.glint = (0, 0, 0)
    c.filledBeak = true
    c.slit = false
    c.beak = (y(m.beak.0), 1.55, 1.15, 1.45)
    // the arcs: just right of the body, 60 % of the way up from the foot to the tuft's top (beside the eyes)
    let head = c.tuft.map { $0.1 - $0.2 }.min() ?? c.top
    c.arcCentre = CGPoint(x: c.cx + c.hw + 0.1, y: 17 - 0.6 * (17 - head))
    c.arcs = [(3.1, -60, 30), (6.0, -56, 26)]
    return c
}
/// The listening arcs' line, in pt.
let menuArcLine: CGFloat = 2

/// The glyph's one shape: body ∪ tuft ∪ wings, minus the eyes and the (softened) beak.
func glyphShape(_ c: Chick) -> CGPath {
    let beak = outlined(c.beakPath, width: 0.6).union(c.beakPath)     // softened corners
    return c.outline.union(c.wingAreas).subtracting(c.eyes).subtracting(beak)
}

/// The glyph in the icon family's 24 grid: one filled shape (the silhouette), so the tray and every other place that
/// shows the `blurt` glyph get the same bold mark. The arcs are not in it (they sit outside the square box): they go to
/// MenuGlyphGeometry.swift.
func glyphSVG(_ c: Chick) -> String {
    let g = CGAffineTransform(scaleX: 4.0 / 3.0, y: 4.0 / 3.0)
    var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.75\" stroke-linecap=\"round\" stroke-linejoin=\"round\" data-group=\"brand\">\n"
    svg += "  <title>blurt — the chick that blurts it out (app mark: menu bar, tray)</title>\n"
    svg += "  <desc>The 4A chick for the menu bar (an 18 pt template image) and the tray: a bold filled silhouette (body, a tuft of three bumps, wing nubs) with the eyes and the beak knocked out, the logo's chick scaled uniformly to \(fmt(glyphWidth, 1)) pt of the 18 pt box wide. Drawn on the 18 pt grid, the foot on a whole point. One layer: the sound arcs show only while voice input listens and live in MenuGlyphGeometry.swift. Generated by assets/brand/chick.swift; do not edit by hand.</desc>\n"
    svg += "  <path d=\"\(d(transformed(glyphShape(c), g), digits: 3))\" fill=\"currentColor\" stroke=\"none\"/>\n"
    svg += "</svg>\n"
    return svg
}

/// The listening arcs for MenuGlyph, in the glyph's 18 pt box (y down; they reach past its right edge).
func menuGlyphSwift(_ c: Chick) -> String {
    func n(_ v: CGFloat) -> String { fmt(v, 3) }
    var right: CGFloat = 0
    for i in c.arcs.indices { right = max(right, outlined(c.arc(i), width: menuArcLine).boundingBoxOfPath.maxX) }
    let arcs = c.arcs.map { "(r: \(n($0.0)), from: \(n($0.1)), to: \(n($0.2)))" }.joined(separator: ", ")
    return """
    // GENERATED by assets/brand/chick.swift — do not edit; edit chick.swift and run `swift assets/brand/chick.swift`.
    //
    // The menu-bar glyph's sound arcs (assets/brand/glyph.svg is the chick alone): they show only while voice input
    // listens, to the right of the chick, in the glyph's 18 pt box (y down, degrees clockwise from +x).
    import CoreGraphics

    extension MenuGlyph {
        static let arcCentre = CGPoint(x: \(n(c.arcCentre.x)), y: \(n(c.arcCentre.y)))
        /// Inner, then outer.
        static let arcs: [(r: CGFloat, from: CGFloat, to: CGFloat)] = [\(arcs)]
        static let arcLine: CGFloat = \(n(menuArcLine))
        /// Where the outer arc's line ends on the right, in pt from the box's left edge.
        static let arcsRight: CGFloat = \(n(right))
        /// The chick's foot, in pt from the box's top.
        static let foot: CGFloat = \(n(c.yb))
    }

    """
}

// MARK: - write

let args = CommandLine.arguments
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
/// `--check`: write nothing, list the outputs that differ from what this run would write, exit 1 if any (tests run it).
let checkOnly = args.contains("--check")
var stale: [String] = []
func write(_ s: String, _ name: String, dir: URL = here) {
    let url = dir.appendingPathComponent(name)
    if checkOnly {
        if (try? String(contentsOf: url, encoding: .utf8)) != s { stale.append(url.path) }
        return
    }
    try! s.write(to: url, atomically: true, encoding: .utf8)
    print("wrote", url.path)
}

// MARK: - the tile's colour, from assets/color/tokens.json

let tokens: [String: Any] = {
    let url = here.deletingLastPathComponent().appendingPathComponent("color/tokens.json")
    guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { fatalError("can't read \(url.path)") }
    return json
}()
let gradientTokens = tokens["gradient"] as! [String: Any]

func num(_ v: Any?) -> CGFloat { CGFloat((v as! NSNumber).doubleValue) }

/// Stops as tokens.json writes them: [colour, at] or [colour, alpha, at]; a colour is a hex or a name in gradient.stops.
func tokenStops(_ v: Any?, names: [String: String]) -> [GStop] {
    (v as! [[Any]]).map { s in
        let c = s[0] as! String
        let hex = (c.hasPrefix("#") ? c : names[c]!).lowercased()
        return s.count == 3 ? GStop(hex: hex, alpha: num(s[1]), at: num(s[2])) : GStop(hex: hex, at: num(s[1]))
    }
}

/// gradient.<name> as an icon tile: its layers, then the icon grain (gradient.grain.icon at iconFrequency).
func fieldTile(_ name: String) -> Tile {
    let g = gradientTokens[name] as! [String: Any]
    let names = (g["stops"] ?? gradientTokens["stops"]) as! [String: String]
    let layers: [FieldLayer] = (g["layers"] as! [[String: Any]]).map { l in
        let stops = tokenStops(l["stops"], names: names)
        switch l["type"] as! String {
        case "linear": return .linear(angle: num(l["angle"]), stops: stops)
        case "radial":
            let c = (l["center"] as! [Any]).map(num), r = (l["radius"] as! [Any]).map(num)
            return .radial(centre: CGPoint(x: c[0], y: c[1]), radius: CGSize(width: r[0], height: r[1]), stops: stops)
        case let t: fatalError("tokens.json gradient.\(name): unknown layer type \(t)")
        }
    }
    let grain = gradientTokens["grain"] as! [String: Any]
    return .field(layers: layers, grain: num(grain["icon"]), frequency: num(grain["iconFrequency"]))
}

/// gradient.linear's stops, top → bottom (the 32 / 16 px tile: no radial layers, no grain).
let linearTile = Tile.vertical(tokenStops((gradientTokens["linear"] as! [String: Any])["stops"],
                                          names: gradientTokens["stops"] as! [String: String]))

// The chosen icon (see README): variant A, the 4A chick as drawn (white body, #17140f line, white glints) on the
// brand gradient field, with a 3 px white 22 % rim.
func iconLook(_ tile: Tile) -> Look {
    var l = cream
    l.tile = tile
    l.rim = "#ffffff"; l.rimOpacity = 0.22; l.rimWidth = 3
    l.title = "black line chick, white body, on the brand gradient field"
    return l
}
let chosen = iconLook(fieldTile("field"))
let chosenSmall = iconLook(linearTile)
let chosenDark = iconLook(fieldTile("deep"))
let iconW: CGFloat = 30            // line, 1024 canvas
let iconArtW: CGFloat = 604        // art width on the 824 tile
let iconNudge = CGPoint(x: -8, y: 10)

let descMaster = "Master app icon, 1024 canvas on the macOS 26 grid: 824 px superellipse tile at (100,100), soft shadow, 3 px white 22 % rim. The tile is gradient.field from assets/color/tokens.json (#tile-field: the base, the radial layers, the grain #tile-grain); group #chick is the logo. Generated by assets/brand/chick.swift; rendered by assets/brand/build.py."
write(iconSVG(master, chosen, w: iconW, artWidth: iconArtW, nudge: iconNudge, title: "blurt app icon (口喷鸡) — the 4A line chick", desc: descMaster), "app-icon.svg")
write(iconSVG(small, chosenSmall, w: 54, artWidth: 690, nudge: CGPoint(x: -4, y: 10), title: "blurt app icon — 32 px",
              desc: "The 32 px slot (16@2x) and the favicon: a heavier line, one sound arc, a filled beak, no glints; the tile is plain gradient.linear (green → mint → azure, top → bottom), no radial layers, no grain. Generated by chick.swift."),
      "app-icon-small.svg")
write(iconSVG(tiny, chosenSmall, w: 76, artWidth: 640, nudge: CGPoint(x: 0, y: 14), title: "blurt app icon — 16 px",
              desc: "The 16 px slot: no sound arcs, chunkier line, eyes and beak; the plain gradient.linear tile. Generated by chick.swift."),
      "app-icon-16.svg")
write(iconSVG(master, chosenDark, w: iconW, artWidth: iconArtW, nudge: iconNudge, title: "blurt app icon — dark appearance",
              desc: "The master on gradient.deep: the icon's optional dark appearance (macOS 26 shows it only from an asset-catalog / Icon Composer app icon, not from the .icns). Generated by chick.swift."),
      "app-icon-dark.svg")

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
write(menuGlyphSwift(glyphChick), "MenuGlyphGeometry.swift",
      dir: here.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("skills/blurt/recorder/macos/Sources/BlurtApp/App"))

// MARK: - the mascot (the app's animated chick)

/// The mascot's palette: the 4A chick in colour, for moments (onboarding, the island, notifications). The line, the
/// eyes and the glints are the icon's; the body is the warm yellow the earlier 1A mascot had (#FFC83D), the beak coral.
/// Colours of the art live with the art (like the icon's #17140f line and white body above); the UI's colours live in
/// assets/color/tokens.json.
let mascotPalette: [(String, String, String)] = [
    ("line", "17140F", "the line and the eyes (the icon's)"),
    ("inkOnDark", "F4F1EA", "the free marks (sound arcs, thought dots) on a dark backdrop, where the line would vanish"),
    ("body", "FFC83D", "body and tuft: warm butter yellow"),
    ("wing", "F7B52A", "the wings, a shade deeper than the body"),
    ("shade", "F2A81E", "the soft shade low on the body"),
    ("beak", "FF7A45", "the beak, coral"),
    ("blush", "FF8A65", "the cheeks (drawn at 30 %)"),
    ("glint", "FFFFFF", "the eye glints"),
    ("shell", "FFF8EC", "the egg's shell"),
    ("shellIn", "F3E2C2", "the shell's inside"),
]

/// The chick's parts as the app draws them (Icons/MascotArt.swift): the outline as a path, everything else as the
/// numbers chick.swift draws it from, so the app can pose each part (wings flap, eyes blink, arcs pulse).
func mascotSwift() -> String {
    func n(_ v: CGFloat) -> String { fmt(v, 2) }
    func pathCode(_ path: CGPath, indent: String) -> String {
        var out: [String] = []
        var cur = CGPoint.zero, start = CGPoint.zero
        func P(_ p: CGPoint) -> String { n(p.x) + ", " + n(p.y) }
        path.applyWithBlock { e in
            let el = e.pointee, pts = el.points
            switch el.type {
            case .moveToPoint: out.append("p.m(\(P(pts[0])))"); cur = pts[0]; start = cur
            case .addLineToPoint: out.append("p.l(\(P(pts[0])))"); cur = pts[0]
            case .addQuadCurveToPoint:
                let c1 = CGPoint(x: cur.x + 2 / 3 * (pts[0].x - cur.x), y: cur.y + 2 / 3 * (pts[0].y - cur.y))
                let c2 = CGPoint(x: pts[1].x + 2 / 3 * (pts[0].x - pts[1].x), y: pts[1].y + 2 / 3 * (pts[0].y - pts[1].y))
                out.append("p.c(\(P(c1)), \(P(c2)), \(P(pts[1])))"); cur = pts[1]
            case .addCurveToPoint: out.append("p.c(\(P(pts[0])), \(P(pts[1])), \(P(pts[2])))"); cur = pts[2]
            case .closeSubpath: out.append("p.z()"); cur = start
            @unknown default: break
            }
        }
        return out.map { indent + $0 }.joined(separator: "\n")
    }
    func geometry(_ name: String, _ c: Chick, line: CGFloat, doc: String) -> String {
        let (wdx, wcy, wrx, wry, wdeg) = c.wing
        let (edx, ecy, er) = c.eye
        let (gx, gy, gr) = c.glint
        let (bcy, bw, bup, bdown) = c.beak
        let arcs = c.arcs.map { "(r: \(n($0.0)), from: \(n($0.1)), to: \(n($0.2)))" }.joined(separator: ", ")
        var s = "    /// \(doc)\n"
        s += "    static let \(name) = MascotGeometry(\n"
        s += "        cx: \(n(c.cx)), foot: \(n(c.yb)), line: \(n(line)),\n"
        s += "        outline: MascotGeometry.path { p in\n" + pathCode(c.outline, indent: "            ") + "\n        },\n"
        s += "        wing: (dx: \(n(wdx)), cy: \(n(wcy)), rx: \(n(wrx)), ry: \(n(wry)), deg: \(n(wdeg))),\n"
        s += "        eye: (dx: \(n(edx)), cy: \(n(ecy)), r: \(n(er))), glint: (dx: \(n(gx)), dy: \(n(gy)), r: \(n(gr))),\n"
        s += "        beak: (cy: \(n(bcy)), w: \(n(bw)), up: \(n(bup)), down: \(n(bdown))), slit: \(c.slit && !c.filledBeak), filledBeak: \(c.filledBeak),\n"
        s += "        arcCentre: CGPoint(x: \(n(c.arcCentre.x)), y: \(n(c.arcCentre.y))), arcs: [\(arcs)])\n"
        return s
    }
    // the line in hero units, as thick as on the app icon (30 px of 1024; 54 px in the 32 px slot)
    let lineMaster = iconW / place(master, w: iconW, width: iconArtW, centre: .zero).a
    let lineSmall = 54 / place(small, w: 54, width: 690, centre: .zero).a
    var s = """
    // GENERATED by assets/brand/chick.swift — do not edit; edit chick.swift and run `swift assets/brand/chick.swift`.
    //
    // The mascot is the brand mark: the 4A line chick's own geometry, in the hero space chick.swift draws in (y down; the
    // body's foot at `foot`), for Icons/MascotArt.swift to pose and animate part by part. `master` is the logo's chick;
    // `small` the 32 px icon's (heavier line, one sound arc, a filled beak, no glints), for mascots of 32 pt and less.
    import CoreGraphics

    extension MascotGeometry {

    """
    s += geometry("master", master, line: lineMaster, doc: "The logo's chick (app-icon.svg, chick-line.svg); the line as on the 1024 icon.") + "\n"
    s += geometry("small", small, line: lineSmall, doc: "The 32 px icon's chick (app-icon-small.svg): for mascots of 32 pt and less.")
    s += "}\n\nextension MascotPalette {\n"
    for (k, hex, what) in mascotPalette { s += "    /// \(what)\n    static let \(k): UInt32 = 0x\(hex)\n" }
    s += "}\n"
    return s
}
write(mascotSwift(), "MascotGeometry.swift",
      dir: here.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("skills/blurt/recorder/macos/Sources/BlurtApp/Icons"))

if let i = args.firstIndex(of: "--alts"), i + 1 < args.count {
    let dir = URL(fileURLWithPath: args[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for look in [cream, dark, white] {
        write(iconSVG(master, look, w: iconW, artWidth: iconArtW, nudge: iconNudge, title: look.title, desc: ""), "tile-\(look.name).svg", dir: dir)
        write(iconSVG(small, look, w: 54, artWidth: 690, nudge: CGPoint(x: -4, y: 10), title: look.title, desc: ""), "tile-\(look.name)-small.svg", dir: dir)
        write(iconSVG(tiny, look, w: 76, artWidth: 640, nudge: CGPoint(x: 0, y: 14), title: look.title, desc: ""), "tile-\(look.name)-16.svg", dir: dir)
    }
}

if checkOnly {
    for p in stale { print("stale:", p) }
    exit(stale.isEmpty ? 0 : 1)
}
