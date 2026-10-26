// What the island's ears show (Island.swift): a few small, live layers — a breathing record dot and the time (pause
// bars when paused), counts with one of our line glyphs (the cards' stack with its count in mint, the cards' clasp
// colour; the inbox's tray, the stills' snap frame, the markers' flag), the mic level, a voice waveform, the hatching
// egg (the mascot: it wobbles while captures are organised, then cracks and the chick pops out — Icons/Mascot.swift),
// an alert marker, "Sent" with the ok check. Every glyph in the ears is the BlurtIcon line family at one weight —
// the dogfood found filled SF Symbols (tray.full.fill, rectangle.stack.fill, camera.fill) opposite dictation's line
// keyboard in the same 20 pt strip, the filled tray a blob at 11 pt. No implicit animations: a new state replaces the
// old at once, never drawn over it.
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
        /// a count with one of our line glyphs; `tint` colours both (a quieter count: white at 60 %)
        case count(icon: BlurtIcon, n: Int, tint: NSColor?)
        /// the hanging cards waiting (the left ear): the cards glyph and its count in mint (the cards' clasp colour),
        /// so it never reads like the inbox's tray count beside it (white at 60 %) — a mint dot on the glyph's top edge
        /// read as a jar's lid at 11 pt
        case cards(Int)
        case level(Float)
        case wave([Float])
        /// `attn`: in the attention colour (dictation's clock counting down to the 5-minute limit)
        case text(String, mono: Bool, attn: Bool = false)
        case egg(n: Int)
        case cracking(since: CFTimeInterval, ok: Bool, n: Int)
        case alert
        /// dictation (Dictation.swift): our keyboard glyph (mint) + a mirrored gradient level — not the voice note's wave
        case dictation([Float])
        /// one of our icons, breathing while `pulse` (dictation: transcribing = keyboard, polishing = wand)
        case glyph(BlurtIcon, pulse: Bool)
        /// three dots taking turns: working on it
        case dots
        /// one of our icons before a short text: dictation's style chip with the clock (list = Structured)
        case iconText(BlurtIcon, String, attn: Bool = false)
        /// the ok check before a short text: a moment that worked ("Sent", after a double tap)
        case done(String)
        /// a take that just ended (RecordingDone): the ok check on a filled disc where the red dot was, centred on the
        /// dot, and the take's length at the time's own x — nothing moves, the ear keeps its width
        case finished(String)

        /// Same kind of thing (so a changing number doesn't rebuild the layers)
        func sameKind(_ o: Content) -> Bool {
            switch (self, o) {
            case (.none, .none), (.recording, .recording), (.count, .count), (.cards, .cards), (.level, .level), (.wave, .wave), (.text, .text),
                 (.egg, .egg), (.cracking, .cracking), (.alert, .alert), (.dictation, .dictation), (.dots, .dots),
                 (.done, .done), (.finished, .finished): return true
            case (.glyph(let a, _), .glyph(let b, _)): return a == b
            case (.iconText(let a, _, _), .iconText(let b, _, _)): return a == b
            default: return false
            }
        }
    }

    let layer = CALayer()
    private let icon = CALayer()
    private let label = CATextLayer()
    private let dot = CALayer()
    private let bars = CAShapeLayer()          // the working dots
    /// level bars (recording, voice note, dictation): the base gradient, vertical, seen through the bars
    private let level = CAGradientLayer()
    private let levelMask = CAShapeLayer()
    private let chick = MascotLayer()
    /// How long the egg takes to crack and the chick to come out (the `hatching` clip).
    static var hatchSeconds: Double { MascotLibrary.shared.clip(.hatching)?.duration ?? 1.6 }
    static let chickSize: CGFloat = 24
    private(set) var content: Content = .none
    private var since = CACurrentMediaTime()
    private var pulseAt: CFTimeInterval = 0
    private(set) var width: CGFloat = 0
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    /// A count's glyph (cards, tray, snap, flag): 13 pt, the family's floor (docs/design/system.md §2.6).
    static let countGlyph: CGFloat = 13
    static let noActions: [String: CAAction] = ["contents": NSNull(), "string": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                                "hidden": NSNull(), "opacity": NSNull(), "frame": NSNull(), "path": NSNull(),
                                                "transform": NSNull(), "backgroundColor": NSNull(), "foregroundColor": NSNull(),
                                                "anchorPoint": NSNull(), "sublayerTransform": NSNull(), "strokeColor": NSNull(),
                                                "fillColor": NSNull(), "lineWidth": NSNull()]

    init() {
        label.contentsScale = 2
        label.alignmentMode = .left
        dot.cornerRadius = 4
        bars.fillColor = nil
        bars.lineCap = .round
        bars.lineWidth = 2.2
        // the island's layers are y-down (a flipped view): green at the top of the group
        BrandGradient.layer(BrandGradient.linearStops, .vertical, flipped: true, into: level)
        levelMask.fillColor = nil
        levelMask.strokeColor = NSColor.black.cgColor
        levelMask.lineCap = .round
        level.mask = levelMask
        for l in [icon, label, dot, bars, level, chick] { layer.addSublayer(l); l.isHidden = true }
        // nothing changes by itself: a CATextLayer renders its new string at the next display pass, outside the
        // transaction that disabled actions, so its implicit 0.25 s "contents" fade drew the new number over the old
        // one ("15" over "0:02" right after a take)
        for l in [layer, icon, label, dot, bars, level, levelMask, chick] { l.actions = EarSlot.noActions }
        icon.contentsGravity = .resizeAspect
        icon.contentsScale = 2
        chick.backdrop = .dark                 // the island is always black
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
        for l in [icon, label, dot, bars, level] {
            l.isHidden = true
            l.opacity = 1
            l.setAffineTransform(.identity)
        }
        dot.cornerRadius = 4
        dot.borderWidth = 0
        dot.contents = nil
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
        // dictation's own glyphs (keyboard, wand) are mint: blurt is listening / working for you
        func glyph(_ ic: BlurtIcon, _ size: CGFloat) {
            icon.contents = ic.cgImage(size: size, scale: 2, color: BrandColor.Island.fill.cgColor, weight: 1.1)
            icon.frame = CGRect(x: x, y: -size / 2, width: size, height: size)
            icon.isHidden = false
            x += size + 4
        }
        // a count's glyph: the line family at the ears' one weight (as `iconText` and `done`), in the count's colour
        func line(_ ic: BlurtIcon, color: NSColor) {
            let size = EarSlot.countGlyph
            icon.contents = ic.cgImage(size: size, scale: 2, color: color.cgColor, weight: 1.2)
            icon.frame = CGRect(x: x, y: -size / 2, width: size, height: size)
            icon.isHidden = false
            x += size + 4
        }
        switch c {
        case .none: break
        case .recording(let paused, let time):
            if paused {
                // paused says so in shape too, not only in colour: the pause bars where the red dot was
                icon.contents = BlurtIcon.pauseFill.cgImage(size: 10, scale: 2, color: BrandColor.Island.attn.cgColor)
                icon.frame = CGRect(x: -1, y: -5, width: 10, height: 10)
                icon.isHidden = false
            } else {
                dot.backgroundColor = BrandColor.Island.rec.cgColor
                dot.frame = CGRect(x: 0, y: -4, width: 8, height: 8)
                dot.isHidden = false
            }
            x = EarSlot.timeX
            text(time, color: paused ? BrandColor.Island.attn : NSColor(white: 1, alpha: 0.95))
        case .count(let ic, let n, let tint):
            line(ic, color: tint ?? NSColor(white: 1, alpha: 0.85))
            text(Loc.number(n), color: tint ?? NSColor(white: 1, alpha: 0.92))
        case .cards(let n):
            line(.cards, color: NSColor(white: 1, alpha: 0.85))
            text(Loc.number(n), color: BrandColor.Island.fill)
        case .level(let v):
            drawLevel(v)
            x = EarSlot.levelW
        case .wave(let v):
            drawWave(v)
            x = 40
        case .text(let s, _, let attn):
            text(s, color: attn ? BrandColor.Island.attn : NSColor(white: 1, alpha: 0.92))
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
            dot.backgroundColor = BrandColor.Island.attn.cgColor
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
        case .iconText(let ic, let s, let attn):
            icon.contents = ic.cgImage(size: 12, scale: 2, color: BrandColor.Island.fill.cgColor, weight: 1.2)
            icon.frame = CGRect(x: 0, y: -6, width: 12, height: 12)
            icon.isHidden = false
            x = 16
            text(s, color: attn ? BrandColor.Island.attn : NSColor(white: 1, alpha: 0.92))
        case .finished(let s):
            // the disc in the dot's place (centred where the dot's centre was), the check knocked out in black
            let d: CGFloat = 14
            dot.backgroundColor = BrandColor.Island.ok.cgColor
            dot.cornerRadius = d / 2
            dot.frame = CGRect(x: 4 - d / 2, y: -d / 2, width: d, height: d)
            dot.isHidden = false
            // the check is the disc's own contents (the dot layer sits above the icon layer)
            dot.contents = BlurtIcon.check.cgImage(size: 10, scale: 2, color: NSColor.black.cgColor, weight: 1.9)
            dot.contentsGravity = .center
            dot.contentsScale = 2
            x = EarSlot.timeX
            text(s, color: NSColor(white: 1, alpha: 0.95))
        case .done(let s):
            icon.contents = BlurtIcon.check.cgImage(size: 12, scale: 2, color: BrandColor.Island.ok.cgColor, weight: 1.3)
            icon.frame = CGRect(x: 0, y: -6, width: 12, height: 12)
            icon.isHidden = false
            x = 16
            text(s)
        }
        width = x
        layer.bounds = CGRect(x: 0, y: -10, width: max(1, x), height: 20)
        CATransaction.commit()
    }

    /// The bars (`p`, ear coordinates, round-capped strokes of `width`) as the mask of one vertical base gradient over
    /// the whole 18 pt group box: each bar shows the slice at its height — short bars read mint, tall ones show green
    /// tips and azure feet (gradient.vertical).
    private func showLevel(_ p: CGPath, width lw: CGFloat) {
        let box = CGRect(x: 0, y: -EarSlot.levelBox / 2, width: max(1, p.boundingBoxOfPath.maxX + lw), height: EarSlot.levelBox)
        level.frame = box
        levelMask.frame = level.bounds
        var t = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        levelMask.path = p.copy(using: &t)
        levelMask.lineWidth = lw
        level.isHidden = false
    }
    static let levelBox: CGFloat = 18
    /// The recording time's x after the dot (and after the finished take's disc: the number never moves).
    static let timeX: CGFloat = 15
    /// The level's width as drawn (four 2.2 pt bars 5 pt apart): the ear's trailing edge is the last bar's, so the
    /// meter ends where the pencil, the snap count and the flag end.
    static let levelW: CGFloat = 17

    /// Recording: the mic level (4 steps). Gradient too — blurt hears you — but no glow: red owns that moment. In
    /// silence the bars rest at clearly staggered heights (4 / 7 / 5 / 3) in white 30 %, so they still read as a meter
    /// and never as four mint dots (dictation's "working" dots) or a flat tick; the gradient comes in with the voice.
    /// Paused, the ear shows no meter at all (Island.updateEars): the mic isn't listening.
    private func drawLevel(_ v: Float) {
        let p = CGMutablePath()
        let rest: [CGFloat] = [4, 7, 5, 3]
        let heard = v >= 0.2
        for i in 0..<4 {
            let th = Float(i + 1) / 5
            let hh: CGFloat = v >= th ? CGFloat(5 + i * 3) : rest[i]
            let x = CGFloat(i) * 5 + 1
            p.move(to: CGPoint(x: x, y: -hh / 2)); p.addLine(to: CGPoint(x: x, y: hh / 2))
        }
        if heard { showLevel(p, width: 2.2); return }
        bars.path = p
        bars.lineWidth = 2.2
        bars.strokeColor = NSColor(white: 1, alpha: 0.3).cgColor
        bars.fillColor = nil
        bars.isHidden = false
    }

    /// The voice note's live waveform.
    private func drawWave(_ v: [Float]) {
        let p = CGMutablePath()
        let n = min(10, v.count)
        for (i, a) in v.suffix(n).enumerated() {
            let hh = max(3, CGFloat(a) * 16)
            let x = CGFloat(i) * 4 + 1
            p.move(to: CGPoint(x: x, y: -hh / 2)); p.addLine(to: CGPoint(x: x, y: hh / 2))
        }
        showLevel(p, width: 2)
    }

    /// Dictation's level: 5 bars mirrored around the centre line, newest in the middle-right; they settle to 2.5 pt
    /// dots in silence.
    private func drawMirror(_ v: [Float], from x0: CGFloat) {
        let p = CGMutablePath()
        let last = Array(v.suffix(5))
        for i in 0..<5 {
            let a = i < last.count ? CGFloat(last[i]) : 0
            let hh = max(2.5, a * 15)
            let x = x0 + CGFloat(i) * 4 + 1
            p.move(to: CGPoint(x: x, y: -hh / 2)); p.addLine(to: CGPoint(x: x, y: hh / 2))
        }
        showLevel(p, width: 2.2)
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
            // a shallow breath (1.6 s, never below 80 %: any frame still reads as live red), still when paused or
            // with Reduce Motion
            dot.opacity = paused || reduce ? 1 : Float(0.8 + 0.2 * (0.5 + 0.5 * cos(t * 2 * .pi / 1.6)))
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
