// What the island's ears show (Island.swift): a few small, live layers — a breathing record dot and the time, counts
// with an SF Symbol, the mic level, a voice waveform, the hatching egg (the mascot: it wobbles while captures are
// organised, then cracks and the chick pops out — Icons/Mascot.swift), an alert marker.
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
        /// dictation (Dictation.swift): our keyboard glyph + a mirrored mint level — not the voice note's coral wave
        case dictation([Float])
        /// one of our icons, breathing while `pulse` (dictation: transcribing = keyboard, polishing = wand)
        case glyph(BlurtIcon, pulse: Bool)
        /// three dots taking turns: working on it
        case dots
        /// one of our icons before a short text: dictation's style chip with the clock (list = Structured)
        case iconText(BlurtIcon, String)

        /// Same kind of thing (so a changing number doesn't rebuild the layers)
        func sameKind(_ o: Content) -> Bool {
            switch (self, o) {
            case (.none, .none), (.recording, .recording), (.count, .count), (.level, .level), (.wave, .wave), (.text, .text),
                 (.egg, .egg), (.cracking, .cracking), (.alert, .alert), (.dictation, .dictation), (.dots, .dots): return true
            case (.glyph(let a, _), .glyph(let b, _)): return a == b
            case (.iconText(let a, _), .iconText(let b, _)): return a == b
            default: return false
            }
        }
    }

    let layer = CALayer()
    private let icon = CALayer()
    private let label = CATextLayer()
    private let dot = CALayer()
    private let bars = CAShapeLayer()
    private let chick = MascotLayer()
    /// How long the egg takes to crack and the chick to come out (the `hatching` clip).
    static var hatchSeconds: Double { MascotLibrary.shared.clip(.hatching)?.duration ?? 1.6 }
    static let chickSize: CGFloat = 24
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
        for l in [icon, label, dot, bars, chick] { layer.addSublayer(l); l.isHidden = true }
        icon.contentsGravity = .resizeAspect
        icon.contentsScale = 2
    }

    var animating: Bool {
        switch content {
        case .recording(let p, _): return !p && !reduceMotion
        case .wave, .level: return true
        case .egg: return false            // the mascot runs its own timer
        case .cracking(let s, _, _): return CACurrentMediaTime() - s < EarSlot.hatchSeconds + 0.3
        case .alert: return CACurrentMediaTime() - pulseAt < 1
        case .dictation, .dots: return true
        case .glyph(_, let p): return p && !reduceMotion
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
        for l in [icon, label, dot, bars] {
            l.isHidden = true
            l.opacity = 1
            l.setAffineTransform(.identity)
        }
        switch c {
        case .egg, .cracking: break
        default: chick.stop(); chick.isHidden = true; chick.contents = nil
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
        func glyph(_ ic: BlurtIcon, _ size: CGFloat) {
            icon.contents = ic.cgImage(size: size, scale: 2, color: NSColor(white: 1, alpha: 0.92).cgColor, weight: 1.1)
            icon.frame = CGRect(x: x, y: -size / 2, width: size, height: size)
            icon.isHidden = false
            x += size + 4
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
            placeChick()
            if chick.clip != .wobble || !chick.isPlaying { chick.play(.wobble) }
            x = EarSlot.chickSize + 1
            text(Loc.number(n))
        case .cracking(_, let ok, let n):
            placeChick()
            chick.opacity = ok ? 1 : 0.5
            if ok { chick.play(.hatching) } else { chick.show(.wobble) }
            x = EarSlot.chickSize + 1
            text(ok ? "+" + Loc.number(n) : "", color: NSColor(white: 1, alpha: 0.95))
            label.opacity = 0
        case .alert:
            dot.backgroundColor = amber.cgColor
            dot.frame = CGRect(x: 0, y: -4, width: 8, height: 8)
            dot.isHidden = false
            x = 8
        case .dictation(let v):
            glyph(.keyboard, 14)
            drawMirror(v, from: x)
            x += 21
        case .glyph(let ic, _):
            glyph(ic, 15)
            x -= 4
        case .dots:
            drawDots(t: 0)
            x = 20
        case .iconText(let ic, let s):
            icon.contents = ic.cgImage(size: 12, scale: 2, color: EarSlot.dictationTint.cgColor, weight: 1.2)
            icon.frame = CGRect(x: 0, y: -6, width: 12, height: 12)
            icon.isHidden = false
            x = 16
            text(s)
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
        bars.fillColor = nil
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
        bars.fillColor = nil
        bars.lineWidth = 2
        bars.strokeColor = accent.cgColor
        bars.isHidden = false
    }

    static let dictationTint = NSColor(calibratedRed: 0.38, green: 0.86, blue: 0.74, alpha: 1)   // mint

    /// Dictation's level: 5 bars mirrored around the centre line, newest in the middle-right, mint.
    private func drawMirror(_ v: [Float], from x0: CGFloat) {
        let p = CGMutablePath()
        let last = Array(v.suffix(5))
        for i in 0..<5 {
            let a = i < last.count ? CGFloat(last[i]) : 0
            let hh = max(2.5, a * 15)
            let x = x0 + CGFloat(i) * 4 + 1
            p.move(to: CGPoint(x: x, y: -hh / 2)); p.addLine(to: CGPoint(x: x, y: hh / 2))
        }
        bars.path = p
        bars.fillColor = nil
        bars.lineWidth = 2.2
        bars.strokeColor = EarSlot.dictationTint.cgColor
        bars.isHidden = false
    }

    /// Three dots, each lifting in turn (static with Reduce Motion).
    private func drawDots(t: Double) {
        let p = CGMutablePath()
        for i in 0..<3 {
            let ph = reduceMotion ? 0 : max(0, sin((t * 2.2 - Double(i) * 0.22) * 2 * .pi))
            let y = -CGFloat(ph) * 3
            p.addEllipse(in: CGRect(x: 2 + CGFloat(i) * 6.5 - 1.5, y: y - 1.5, width: 3, height: 3))
        }
        bars.path = p
        bars.lineWidth = 1.2
        bars.strokeColor = NSColor(white: 1, alpha: 0.9).cgColor
        bars.fillColor = NSColor(white: 1, alpha: 0.9).cgColor
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
        case .cracking(let s, let ok, _):
            if reduce || !ok {
                let k = CGFloat(min(1, (now - s) / 0.6))
                if !ok { chick.opacity = Float(0.5 * (1 - k)) }
                label.opacity = Float(k)
                break
            }
            // the egg cracks and the chick pops out (the clip), then the count appears beside it
            let d = EarSlot.hatchSeconds
            let open = Ease.outCubic(CGFloat(max(0, ((now - s) - d * 0.6) / (d * 0.4))))
            label.opacity = Float(open)
            label.setAffineTransform(CGAffineTransform(scaleX: 0.7 + 0.3 * Ease.outBack(open), y: 0.7 + 0.3 * Ease.outBack(open)))
        case .alert:
            let p = now - pulseAt
            let s: CGFloat = p < 1 && !reduce ? 1 + 0.5 * CGFloat(sin(.pi * p)) : 1
            dot.setAffineTransform(CGAffineTransform(scaleX: s, y: s))
        case .glyph(_, let pulse):
            icon.opacity = pulse && !reduce ? Float(0.5 + 0.5 * (0.5 + 0.5 * cos(t * 2 * .pi * 0.9))) : 1
        case .dots:
            drawDots(t: t)
        default: break
        }
    }

    private func placeChick() {
        let z = EarSlot.chickSize
        chick.frame = CGRect(x: -2, y: -z / 2 - 1, width: z, height: z)
        chick.isHidden = false
        chick.opacity = 1
    }
}
