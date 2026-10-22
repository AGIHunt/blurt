// Eggs — one item = one egg. Drawn in code (CoreGraphics vectors), never bitmaps: crisp on Retina, fine in dark mode,
// and the same shapes can be exported as SVG for the website.
//
//   issue  speckled egg with a tiny bug        idea  golden egg (a golden idea)
//   note   white egg                            task  brown egg with a check stripe
//   custom pastel egg (hue from the lens name)
//
// Eggs are brand and motion only (K8): the island's hatching egg, the kind eggs in the main window's legacy rows.
// Also here: the readers for a recording's live/*.jsonl (drafts, transcript).

import AppKit
import QuartzCore

enum EggKind: String, CaseIterable {
    case issue, idea, note, task, custom

    init(_ s: String?) { self = EggKind(rawValue: (s ?? "").lowercased()) ?? ((s ?? "").isEmpty ? .note : .custom) }

    /// Seed for eggImage: custom lenses take their hue from the lens name (same hash as the review page).
    static func seed(_ name: String?, id: String) -> UInt64 {
        EggKind(name) == .custom ? customEggHue(name ?? "") : stableSeed(id)
    }
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

private func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    rgb(CGFloat(v >> 16 & 0xFF) / 255, CGFloat(v >> 8 & 0xFF) / 255, CGFloat(v & 0xFF) / 255, a)
}

/// The review page's hue for a custom lens: h = (h*31 + charCode) % 360, shown as hsl(h 62% 80%) — keep in sync
/// with egg() in scripts/review.html.
func customEggHue(_ name: String) -> UInt64 {
    var h: UInt64 = 0
    for c in name.utf16 { h = (h * 31 + UInt64(c)) % 360 }
    return h
}

private func hsl(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat, _ a: CGFloat = 1) -> CGColor {
    let c = (1 - abs(2 * l - 1)) * s, hp = h / 60, x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1)), m = l - c / 2
    let (r, g, b): (CGFloat, CGFloat, CGFloat) = hp < 1 ? (c, x, 0) : hp < 2 ? (x, c, 0) : hp < 3 ? (0, c, x) : hp < 4 ? (0, x, c) : hp < 5 ? (x, 0, c) : (c, 0, x)
    return rgb(r + m, g + m, b + m, a)
}

/// Same stops as the review page's SVG sprite (eg-issue / eg-idea / eg-note / eg-task), so both read as one set.
func eggPalette(_ kind: EggKind, seed: UInt64) -> EggPalette {
    switch kind {
    case .issue: return EggPalette(light: hex(0xfbf4e6), base: hex(0xead7b5), dark: hex(0xc9ad80), rim: hex(0x7a5c38, 0.5))
    case .idea: return EggPalette(light: hex(0xfff1a8), base: hex(0xf4c22e), dark: hex(0xbf830a), rim: hex(0x8a5d05, 0.55))
    case .note: return EggPalette(light: hex(0xffffff), base: hex(0xf2efe9), dark: hex(0xd6d0c4), rim: hex(0x6f695e, 0.75))
    case .task: return EggPalette(light: hex(0xe9b783), base: hex(0xc3824a), dark: hex(0x8e5427), rim: hex(0x5e3615, 0.55))
    case .custom:
        let h = CGFloat(seed % 360)
        return EggPalette(light: hsl(h, 0.62, 0.90), base: hsl(h, 0.62, 0.80), dark: hsl(h, 0.45, 0.66), rim: rgb(0, 0, 0, 0.22))
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
        for _ in 0..<Int(10 + rnd.next() * 6) {
            let rr = body.width * rnd.range(0.018, 0.05)
            let p = CGPoint(x: rnd.range(body.minX, body.maxX), y: rnd.range(body.minY, body.maxY))
            ctx.setFillColor(hex(0x9a7650, rnd.range(0.55, 0.95)))
            ctx.addEllipse(in: CGRect(x: p.x - rr, y: p.y - rr * rnd.range(0.7, 1), width: rr * 2, height: rr * 2 * rnd.range(0.7, 1)))
            ctx.fillPath()
        }
    case .task: break      // the white check goes on top, after the shading
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
    if kind == .issue { drawBug(ctx, at: CGPoint(x: body.minX + body.width * 0.62, y: body.minY + body.height * 0.30), size: body.width * 0.36) }
    if kind == .idea { drawSparkle(ctx, at: CGPoint(x: body.minX + body.width * 0.74, y: body.minY + body.height * 0.72), size: body.width * 0.26) }
    if kind == .task {   // a white check, as on the review page
        ctx.saveGState()
        ctx.setStrokeColor(rgb(1, 1, 1))
        ctx.setLineWidth(max(1.2, body.width * 1.55 / 10.1))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // the sprite's 16×16 coordinates (egg spans x 2.95…13.05, y 1.1…14.9, y down) mapped onto this egg
        let P = { (x: CGFloat, y: CGFloat) in
            CGPoint(x: body.minX + (x - 2.95) / 10.1 * body.width, y: body.maxY - (y - 1.1) / 13.8 * body.height)
        }
        ctx.move(to: P(5.5, 9.6)); ctx.addLine(to: P(7.25, 11.35)); ctx.addLine(to: P(10.55, 7.75))
        ctx.strokePath()
        ctx.restoreGState()
    }
}

/// A tiny beetle (not scary: round, glossy, short legs).
func drawBug(_ ctx: CGContext, at c: CGPoint, size s: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y)
    ctx.setStrokeColor(hex(0x33261d))
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
    ctx.setFillColor(hex(0x33261d))
    ctx.fillEllipse(in: CGRect(x: -s * 0.14, y: s * 0.20, width: s * 0.28, height: s * 0.28))           // head
    ctx.setFillColor(hex(0x33261d))
    ctx.fillEllipse(in: CGRect(x: -s * 0.25, y: -s * 0.30, width: s * 0.50, height: s * 0.58))         // shell
    ctx.setFillColor(rgb(1, 1, 1, 0.28))
    ctx.fillEllipse(in: CGRect(x: -s * 0.15, y: s * 0.04, width: s * 0.10, height: s * 0.10))
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
    ctx.setShadow(offset: .zero, blur: s * 0.25, color: rgb(1, 1, 1, 0.8))
    ctx.addPath(p)
    ctx.setFillColor(rgb(1, 1, 1, 1))
    ctx.fillPath()
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
    var onAdd: ((String, String?) -> Void)?
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
                onAdd?(id, o["kind"] as? String)
            } else {
                current[id] = (current[id] ?? [:]).merging(o) { $1 }
            }
        }
    }

    var kinds: [String] { order.compactMap { current[$0] }.map { $0["kind"] as? String ?? "note" } }
}
