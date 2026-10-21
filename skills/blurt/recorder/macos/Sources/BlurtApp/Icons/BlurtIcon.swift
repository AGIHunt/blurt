// BlurtIcon — the app's icons, never emoji. Two kinds (docs: assets/icons/REPLACEMENTS.md):
//
//   brand    chicken, egg, hatch, nest, perch, claw, peck, bug, spark, note, task, mic, waveform, snap, agent, mcp…
//            our own vectors (assets/icons/*.svg → BlurtIconPaths.swift, generated) — template-tintable at any size
//   generic  pause, play, stop, check, x, search, folder, trash…  → the SF Symbol, like every native Mac app
//            (`symbolImage`), falling back to our vector of the same name when this macOS lacks the symbol
//
//   BlurtIcon.chicken.image(size: 16)                       template NSImage (tints like text / menu items)
//   BlurtIcon.check.symbolImage(pointSize: 13)              SF Symbol "checkmark" (or our check)
//   BlurtIcon.chicken.attributed(font: f, color: .white)    inline in a label / button title / CATextLayer string
//   BlurtIcon.mic.cgImage(size: 12, scale: 2, color: c)     for CALayer.contents
//   BlurtIcon.egg(.idea, size: 14)                          the full-colour kind eggs (drawEgg in Capture/Eggs.swift)
//   BlurtIcon(named: "close")                               names and aliases as in the web package

import AppKit
import SwiftUI

/// One painted shape of an icon: a CGPath in the 24×24 y-down grid, stroked (1.75, round caps/joins) or filled.
struct BlurtIconLayer {
    enum Mode { case stroke, fill }
    let mode: Mode
    let opacity: CGFloat
    let path: CGPath

    init(_ mode: Mode, opacity: CGFloat = 1, _ build: (CGMutablePath) -> Void) {
        self.mode = mode
        self.opacity = opacity
        let p = CGMutablePath()
        build(p)
        path = p
    }
}

// Path DSL used by the generated file (absolute M / L / C / Z, grid units).
extension CGMutablePath {
    @inline(__always) func m(_ x: CGFloat, _ y: CGFloat) { move(to: CGPoint(x: x, y: y)) }
    @inline(__always) func l(_ x: CGFloat, _ y: CGFloat) { addLine(to: CGPoint(x: x, y: y)) }
    @inline(__always) func c(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat, _ y: CGFloat) {
        addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
    }
    @inline(__always) func z() { closeSubpath() }
}

extension BlurtIcon {
    /// The family's stroke width in grid units (24 = the icon's size).
    static let strokeWidth: CGFloat = 1.75

    /// Looks up a name or alias ("close" → .x, "process" → .chicken).
    init?(named name: String) {
        if let i = BlurtIcon(rawValue: name) { self = i } else if let i = BlurtIcon.aliases[name] { self = i } else { return nil }
    }

    private static let layerCache: [BlurtIcon: [BlurtIconLayer]] =
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.makeLayers()) })

    var layers: [BlurtIconLayer] { BlurtIcon.layerCache[self] ?? [] }

    var isBrand: Bool { group == "brand" }

    /// Draws the icon into `rect` (square; a non-square rect is fitted, centred). Works in flipped and unflipped
    /// contexts: pass `flipped: true` when the context's y axis already points down (NSImage(flipped: true), NSView
    /// with isFlipped). `weight` scales the stroke (1 = the family's 1.75 in a 24 pt icon).
    func draw(in ctx: CGContext, rect: CGRect, color: CGColor, flipped: Bool = false, weight: CGFloat = 1) {
        let side = min(rect.width, rect.height)
        let s = side / 24
        ctx.saveGState()
        ctx.translateBy(x: rect.midX - side / 2, y: flipped ? rect.midY - side / 2 : rect.midY + side / 2)
        ctx.scaleBy(x: s, y: flipped ? s : -s)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(BlurtIcon.strokeWidth * weight)
        // Paint opaque into one transparency layer, then apply the color's alpha once: overlapping strokes of a
        // translucent color (.labelColor, .secondaryLabelColor) must not double up where they cross.
        ctx.setAlpha(color.alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        let opaque = color.copy(alpha: 1) ?? color
        for l in layers {
            let c = l.opacity < 1 ? opaque.copy(alpha: l.opacity) ?? opaque : opaque
            ctx.addPath(l.path)
            switch l.mode {
            case .stroke: ctx.setStrokeColor(c); ctx.strokePath()
            case .fill: ctx.setFillColor(c); ctx.fillPath()
            }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// An NSImage `size` points square. `color == nil` → a template image (black, `isTemplate = true`): AppKit tints it
    /// like text (menu items, buttons, NSImageView.contentTintColor). With a color it draws in that color; dynamic
    /// colors (.labelColor…) resolve at draw time, so light/dark both work.
    func image(size: CGFloat = 16, color: NSColor? = nil, weight: CGFloat = 1) -> NSImage {
        let key = "\(rawValue)|\(size)|\(weight)|\(color.map { "\($0.hash)" } ?? "t")"
        if let im = BlurtIcon.imageCache.object(forKey: key as NSString) { return im }
        let im = NSImage(size: NSSize(width: size, height: size), flipped: true) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            self.draw(in: ctx, rect: r, color: (color ?? .black).cgColor, flipped: true, weight: weight)
            return true
        }
        im.isTemplate = color == nil
        im.accessibilityDescription = title
        BlurtIcon.imageCache.setObject(im, forKey: key as NSString)
        return im
    }

    private static let imageCache = NSCache<NSString, NSImage>()

    /// A bitmap for CALayer.contents (set the layer's contentsScale to `scale`).
    func cgImage(size: CGFloat, scale: CGFloat = 2, color: CGColor, weight: CGFloat = 1) -> CGImage? {
        let px = Int((size * scale).rounded(.up))
        guard px > 0, let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(in: ctx, rect: CGRect(x: 0, y: 0, width: px, height: px), color: color, flipped: false, weight: weight)
        return ctx.makeImage()
    }

    /// A CALayer showing the icon, for layer-built UIs (the perch, the HUD). CATextLayer can't draw NSTextAttachment, so
    /// an icon next to CATextLayer text is a sibling layer: place this one, then start the text after it.
    func makeLayer(size: CGFloat, color: CGColor, scale: CGFloat = 2) -> CALayer {
        let l = CALayer()
        l.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        l.contentsScale = scale
        l.contents = cgImage(size: size, scale: scale, color: color)
        return l
    }

    /// Inline SVG markup (currentColor) for HTML the app builds itself, e.g. the review window's error page.
    func svg(size: CGFloat = 24) -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(Int(size))\" height=\"\(Int(size))\" viewBox=\"0 0 24 24\" fill=\"none\" "
            + "stroke=\"currentColor\" stroke-width=\"1.75\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\">"
            + svgInner + "</svg>"
    }

    /// The SF Symbol for a generic icon (first of `sfSymbols` this macOS has), else our own vector. Brand icons always
    /// return our vector. Template image either way.
    func symbolImage(pointSize: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage {
        for name in sfSymbols {
            if let im = NSImage(systemSymbolName: name, accessibilityDescription: title),
               let sized = im.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)) {
                sized.isTemplate = true
                return sized
            }
        }
        // SF Symbols' glyphs sit a little smaller than their point size; match that optically.
        return image(size: (pointSize * 1.15).rounded(), weight: weight.rawValue > 0.2 ? 1.15 : 1)
    }

    /// For NSMenuItem.image: 16 pt, template (SF Symbol for generic icons).
    var menuImage: NSImage { isBrand ? image(size: 16) : symbolImage(pointSize: 13) }

    /// The icon as an inline text attachment, sized and baseline-aligned to `font`, so a title like
    /// "🐔 整理 3 张" becomes `BlurtIcon.chicken.attributed(font: f, color: .white) + " 整理 3 张"`.
    /// `color == nil` → .labelColor (dynamic). Generic icons use the SF Symbol when `preferSymbol`.
    func attributed(font: NSFont, color: NSColor? = nil, preferSymbol: Bool = false, scale: CGFloat = 1.2) -> NSAttributedString {
        let side = (font.capHeight * 1.0 / 0.7 * scale).rounded()      // ≈ 1.2 × cap height / the glyph's 70 % body
        let c = color ?? .labelColor
        let im: NSImage
        if preferSymbol, !isBrand {
            let s = symbolImage(pointSize: font.pointSize, weight: .regular)
            im = NSImage(size: s.size, flipped: false) { r in
                s.draw(in: r)
                c.set()
                r.fill(using: .sourceIn)      // the symbol's shape in exactly c (alpha included)
                return true
            }
        } else {
            im = image(size: side, color: c)
        }
        let a = NSTextAttachment()
        a.image = im
        a.bounds = CGRect(x: 0, y: ((font.capHeight - im.size.height) / 2).rounded(), width: im.size.width, height: im.size.height)
        return NSAttributedString(attachment: a)
    }

    /// The full-colour kind egg (issue speckled + bug, idea golden, note white, task brown + check, custom pastel),
    /// drawn by Capture/Eggs.swift's drawEgg — the same eggs as the web sprite (assets/icons/eggs/*.svg).
    static func egg(_ kind: EggKind, size: CGFloat = 16, seed: UInt64 = 7, shadow: Bool = false) -> NSImage {
        let im = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // the egg is 10.1 × 13.8 in its 16 grid: keep that aspect, centred
            let h = r.height * 13.8 / 16, w = h * 10.1 / 13.8
            drawEgg(ctx, in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h), kind: kind, seed: seed, shadow: shadow)
            return true
        }
        im.accessibilityDescription = "\(kind.rawValue) egg"
        return im
    }
}

extension BlurtIcon {
    /// SwiftUI: a template Image that tints with .foregroundStyle / .foregroundColor. Generic icons should prefer
    /// `Image(systemName: icon.sfSymbols[0])` in SwiftUI; this is for the brand glyphs.
    func swiftUIImage(size: CGFloat = 16) -> Image {
        Image(nsImage: image(size: size)).renderingMode(.template)
    }

    /// SwiftUI: a kind egg (full colour).
    static func swiftUIEgg(_ kind: EggKind, size: CGFloat = 16) -> Image {
        Image(nsImage: egg(kind, size: size))
    }
}

extension NSAttributedString {
    /// `BlurtIcon.chicken.attributed(font: f) + " 整理"` — joins an icon attachment and text in the same font/color.
    static func + (lhs: NSAttributedString, rhs: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: lhs)
        m.append(rhs)
        return m
    }
}

extension BlurtIcon {
    /// Icon + text in one font, a thin space between: the usual "🐔 整理 3 张" replacement. `iconColor` defaults to `color`.
    func label(_ text: String, font: NSFont, color: NSColor? = nil, iconColor: NSColor? = nil,
               preferSymbol: Bool = false) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: attributed(font: font, color: iconColor ?? color, preferSymbol: preferSymbol))
        m.append(NSAttributedString(string: "\u{2009}" + text, attributes: [.font: font, .foregroundColor: color ?? NSColor.labelColor]))
        return m
    }
}
