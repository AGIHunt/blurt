// The brand egg — drawn in code (CoreGraphics vectors): crisp on Retina, the same in light and dark. Eggs are brand and
// motion only (K8): the island's hatching egg and its shell halves. Items show kind icons, never eggs.

import AppKit
import QuartzCore

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

private func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    rgb(CGFloat(v >> 16 & 0xFF) / 255, CGFloat(v >> 8 & 0xFF) / 255, CGFloat(v & 0xFF) / 255, a)
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

/// Draws one egg (with its soft ground shadow) into `r` of a y-up context.
func drawEgg(_ ctx: CGContext, in r: CGRect, shadow: Bool = true) {
    let pal = (light: hex(0xffffff), base: hex(0xf2efe9), dark: hex(0xd6d0c4), rim: hex(0x6f695e, 0.75))
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
    // terminator: darken the lower right a touch more
    if let g = CGGradient(colorsSpace: space, colors: [rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.10)] as CFArray, locations: [0.55, 1]) {
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: body.minX + body.width * 0.35, y: body.minY + body.height * 0.65), startRadius: 0,
                               endCenter: CGPoint(x: body.minX + body.width * 0.35, y: body.minY + body.height * 0.65),
                               endRadius: body.height * 0.78, options: [.drawsAfterEndLocation])
    }
    // specular highlight
    let hl = CGRect(x: body.minX + body.width * 0.20, y: body.minY + body.height * 0.58, width: body.width * 0.30, height: body.height * 0.26)
    if let g = CGGradient(colorsSpace: space, colors: [rgb(1, 1, 1, 0.85), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1]) {
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
func eggImage(size: CGSize, shadow: Bool = true) -> CGImage? {
    let key = "\(Int(size.width * 10))x\(Int(size.height * 10))-\(shadow)"
    if let c = eggCache[key] { return c }
    let img = renderImage(size) { drawEgg($0, in: CGRect(origin: .zero, size: size), shadow: shadow) }
    eggCache[key] = img
    return img
}
