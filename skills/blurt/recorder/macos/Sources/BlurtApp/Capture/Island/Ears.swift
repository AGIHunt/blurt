// What the island's ears show (Island.swift): a few small, live layers — a breathing record dot and the time, counts
// with an SF Symbol, the mic level, a voice waveform, the hatching egg that wobbles and cracks open, an alert marker.
import AppKit
import BlurtCore
import QuartzCore

/// SF Symbol → CGImage in one colour, cached.
func symbolImage(_ name: String, size: CGFloat, weight: NSFont.Weight = .semibold, color: NSColor = .white) -> CGImage? {
    let key = "\(name)-\(size)-\(weight.rawValue)-\(color.description)" as NSString
    if let c = symbolCache.object(forKey: key) { return (c as! CGImage) }   // swiftlint:disable:this force_cast
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color]))) else { return nil }
    var r = NSRect(origin: .zero, size: base.size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(base.size.width * 2), pixelsHigh: Int(base.size.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)
    rep?.size = base.size
    guard let rep = rep, let g = NSGraphicsContext(bitmapImageRep: rep) else { return base.cgImage(forProposedRect: &r, context: nil, hints: nil) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = g
    base.draw(in: r)
    NSGraphicsContext.restoreGraphicsState()
    guard let img = rep.cgImage else { return nil }
    symbolCache.setObject(img as AnyObject, forKey: key)
    return img
}
private let symbolCache = NSCache<NSString, AnyObject>()

extension Loc {
    /// A count in the interface locale's digits and grouping.
    static func number(_ n: Int) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        return f.string(from: n as NSNumber) ?? "\(n)"
    }
}

final class EarSlot {
    enum Content: Equatable {
        case none
        case recording(paused: Bool, time: String)
        case count(symbol: String, n: Int, tint: NSColor?)
        case level(Float)
        case wave([Float])
        case text(String, mono: Bool)
        case egg(n: Int)
        case cracking(since: CFTimeInterval, ok: Bool, n: Int)
        case alert

        /// Same kind of thing (so a changing number doesn't rebuild the layers)
        func sameKind(_ o: Content) -> Bool {
            switch (self, o) {
            case (.none, .none), (.recording, .recording), (.count, .count), (.level, .level), (.wave, .wave), (.text, .text),
                 (.egg, .egg), (.cracking, .cracking), (.alert, .alert): return true
            default: return false
            }
        }
    }

    let layer = CALayer()
    private let icon = CALayer()
    private let label = CATextLayer()
    private let dot = CALayer()
    private let bars = CAShapeLayer()
    private let eggTop = CALayer(), eggBottom = CALayer()
    private(set) var content: Content = .none
    private var since = CACurrentMediaTime()
    private var pulseAt: CFTimeInterval = 0
    private(set) var width: CGFloat = 0
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

    init() {
        label.contentsScale = 2
        label.alignmentMode = .left
        dot.cornerRadius = 4
        bars.fillColor = nil
        bars.lineCap = .round
        bars.lineWidth = 2.2
        for l in [icon, label, dot, bars, eggTop, eggBottom] { layer.addSublayer(l); l.isHidden = true }
        icon.contentsGravity = .resizeAspect
        icon.contentsScale = 2
        for e in [eggTop, eggBottom] { e.contentsScale = 2; e.contentsGravity = .resizeAspect }
    }

    var animating: Bool {
        switch content {
        case .recording(let p, _): return !p && !reduceMotion
        case .egg, .wave, .level: return true
        case .cracking(let s, _, _): return CACurrentMediaTime() - s < 1.0
        case .alert: return CACurrentMediaTime() - pulseAt < 1
        default: return false
        }
    }

    func pulse() { pulseAt = CACurrentMediaTime() }

    func set(_ c: Content) {
        guard c != content else { return }
        if !c.sameKind(content) { since = CACurrentMediaTime() }
        content = c
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [icon, label, dot, bars, eggTop, eggBottom] {
            l.isHidden = true
            l.opacity = 1
            l.setAffineTransform(.identity)
        }
        var x: CGFloat = 0
        func text(_ s: String, color: NSColor = NSColor(white: 1, alpha: 0.92)) {
            let a = NSAttributedString(string: s, attributes: [.font: EarSlot.font, .foregroundColor: color])
            let sz = a.size()
            label.string = a
            label.frame = CGRect(x: x, y: -ceil(sz.height) / 2, width: ceil(sz.width) + 1, height: ceil(sz.height))
            label.isHidden = false
            x += ceil(sz.width)
        }
        func sym(_ name: String, _ size: CGFloat, color: NSColor = NSColor(white: 1, alpha: 0.85)) {
            guard let img = symbolImage(name, size: size, color: color) else { return }
            let s = CGSize(width: CGFloat(img.width) / 2, height: CGFloat(img.height) / 2)
            icon.contents = img
            icon.frame = CGRect(x: x, y: -s.height / 2, width: s.width, height: s.height)
            icon.isHidden = false
            x += s.width + 4
        }
        switch c {
        case .none: break
        case .recording(let paused, let time):
            dot.backgroundColor = (paused ? amber : NSColor.systemRed).cgColor
            dot.frame = CGRect(x: 0, y: -4, width: 8, height: 8)
            dot.isHidden = false
            x = 13
            text(time, color: paused ? amber : NSColor(white: 1, alpha: 0.95))
        case .count(let symbol, let n, let tint):
            sym(symbol, 11, color: tint ?? NSColor(white: 1, alpha: 0.8))
            text(Loc.number(n))
        case .level(let v):
            drawLevel(v)
            x = 22
        case .wave(let v):
            drawWave(v)
            x = 40
        case .text(let s, _):
            text(s)
        case .egg(let n):
            eggTop.contents = eggImage(.note, size: CGSize(width: 14, height: 18), seed: 11, shadow: false)
            eggTop.frame = CGRect(x: 0, y: -9, width: 14, height: 18)
            eggTop.anchorPoint = CGPoint(x: 0.5, y: 0.9)
            eggTop.position = CGPoint(x: 7, y: 7)
            eggTop.isHidden = false
            x = 18
            text(Loc.number(n))
        case .cracking(_, let ok, let n):
            let halves = EarSlot.eggHalves()
            eggTop.contents = halves.top
            eggBottom.contents = halves.bottom
            for e in [eggTop, eggBottom] {
                e.bounds = CGRect(x: 0, y: 0, width: 14, height: 18)
                e.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                e.position = CGPoint(x: 7, y: 0)
                e.isHidden = false
                e.opacity = ok ? 1 : 0.5
            }
            x = 18
            text(ok ? "+" + Loc.number(n) : "", color: NSColor(white: 1, alpha: 0.95))
            label.opacity = 0
        case .alert:
            dot.backgroundColor = amber.cgColor
            dot.frame = CGRect(x: 0, y: -4, width: 8, height: 8)
            dot.isHidden = false
            x = 8
        }
        width = x
        layer.bounds = CGRect(x: 0, y: -10, width: max(1, x), height: 20)
        CATransaction.commit()
    }

    private func drawLevel(_ v: Float) {
        let p = CGMutablePath()
        for i in 0..<4 {
            let th = Float(i + 1) / 5
            let hh: CGFloat = v >= th ? CGFloat(5 + i * 3) : 3
            let x = CGFloat(i) * 5 + 1
            p.move(to: CGPoint(x: x, y: -hh / 2)); p.addLine(to: CGPoint(x: x, y: hh / 2))
        }
        bars.path = p
        bars.strokeColor = NSColor.systemGreen.cgColor
        bars.isHidden = false
    }

    private func drawWave(_ v: [Float]) {
        let p = CGMutablePath()
        let n = min(10, v.count)
        for (i, a) in v.suffix(n).enumerated() {
            let hh = max(3, CGFloat(a) * 16)
            let x = CGFloat(i) * 4 + 1
            p.move(to: CGPoint(x: x, y: -hh / 2)); p.addLine(to: CGPoint(x: x, y: hh / 2))
        }
        bars.path = p
        bars.lineWidth = 2
        bars.strokeColor = accent.cgColor
        bars.isHidden = false
    }

    /// The ear's layer at a point (y = the ears row's centre line).
    func place(center c: CGPoint, now: CFTimeInterval) { position(CGPoint(x: c.x - width / 2, y: c.y), now) }
    func place(leading p: CGPoint, now: CFTimeInterval) { position(p, now) }
    func place(trailing p: CGPoint, now: CFTimeInterval) { position(CGPoint(x: p.x - width, y: p.y), now) }

    private func position(_ origin: CGPoint, _ now: CFTimeInterval) {
        layer.anchorPoint = .zero
        layer.position = CGPoint(x: origin.x.rounded(), y: origin.y - 10)
        layer.bounds = CGRect(x: 0, y: -10, width: max(1, width), height: 20)
        let t = now - since
        let reduce = reduceMotion
        switch content {
        case .recording(let paused, _):
            // 1 Hz breath, still when paused or with Reduce Motion
            dot.opacity = paused || reduce ? 1 : Float(0.55 + 0.45 * (0.5 + 0.5 * cos(t * 2 * .pi)))
        case .egg:
            guard !reduce else { break }
            // little bursts of wobble, as if something were moving inside
            let beat = t.truncatingRemainder(dividingBy: 1.6)
            let env = beat < 0.6 ? sin(.pi * beat / 0.6) : 0
            eggTop.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(env * sin(t * 2 * .pi * 3.4) * 0.2)))
        case .cracking(let s, let ok, _):
            let k = CGFloat(min(1, (now - s) / 0.6))
            if reduce || !ok {
                eggTop.opacity = Float(1 - k); eggBottom.opacity = Float(1 - k); label.opacity = Float(k)
                break
            }
            // 0.6 s: a shiver, then the top half lifts off and tips away, the bottom sinks, the count appears
            let shiver = k < 0.3 ? sin(Double(k) * 60) * 0.12 * Double(1 - k / 0.3) : 0
            let open = Ease.outCubic(max(0, (k - 0.3) / 0.7))
            eggTop.setAffineTransform(CGAffineTransform(translationX: 2 * open, y: -6 * open).rotated(by: CGFloat(shiver) - 0.6 * open))
            eggBottom.setAffineTransform(CGAffineTransform(translationX: 0, y: 3 * open).rotated(by: CGFloat(shiver)))
            eggTop.opacity = Float(1 - open)
            eggBottom.opacity = Float(1 - open)
            label.opacity = Float(open)
            label.setAffineTransform(CGAffineTransform(scaleX: 0.7 + 0.3 * Ease.outBack(open), y: 0.7 + 0.3 * Ease.outBack(open)))
        case .alert:
            let p = now - pulseAt
            let s: CGFloat = p < 1 && !reduce ? 1 + 0.5 * CGFloat(sin(.pi * p)) : 1
            dot.setAffineTransform(CGAffineTransform(scaleX: s, y: s))
        default: break
        }
    }

    /// The egg cut along a zig-zag: two images, top and bottom.
    static func eggHalves() -> (top: CGImage?, bottom: CGImage?) {
        let size = CGSize(width: 14, height: 18)
        func half(_ top: Bool) -> CGImage? {
            renderImage(size) { ctx in
                let p = CGMutablePath()
                let y: CGFloat = 8.5                 // y-up: the crack a little below the middle
                p.move(to: CGPoint(x: 0, y: top ? size.height : 0))
                p.addLine(to: CGPoint(x: 0, y: y))
                var x: CGFloat = 0
                var up = true
                while x < size.width {
                    x = min(size.width, x + 2.4)
                    p.addLine(to: CGPoint(x: x, y: y + (up ? 1.6 : -1.2)))
                    up.toggle()
                }
                p.addLine(to: CGPoint(x: size.width, y: top ? size.height : 0))
                p.closeSubpath()
                ctx.addPath(p)
                ctx.clip()
                drawEgg(ctx, in: CGRect(origin: .zero, size: size), kind: .note, seed: 11, shadow: false)
            }
        }
        return (half(true), half(false))
    }
}
