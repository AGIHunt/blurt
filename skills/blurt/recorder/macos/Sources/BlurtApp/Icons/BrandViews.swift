// The views every surface builds the brand from (docs/design/system.md §5.1). Colours and gradient stops come from
// the generated BrandColor.swift (assets/color/tokens.json); this file only draws them.
//
//   BrandButton       primary button: the deeper button gradient, white bold title (AppKit)
//   BrandButtonStyle  the same for SwiftUI
//   GradientLabel     gradient text for large headlines / hero numbers (AppKit); `.brandGradientText()` in SwiftUI
//   FieldView         the field (light) / deep (dark) with grain, for heroes and empty-state art; `BrandField` in SwiftUI
//   GlowLayer         the listening aura: the base gradient, blurred
//   AIGlowView        the spectrum rim while AI works (auto-sort, polish, Structured, the Lab run)
//   Celebration       the spectrum ring that blooms once when something big finishes
//
// Accessibility: Reduce Transparency → no grain, no glow (flat colours only); Increase Contrast → gradient text turns
// flat brand ink (the generated colours switch to their `hc` values by themselves); Reduce Motion → glows don't
// turn or breathe, the celebration doesn't play.
import AppKit
import QuartzCore
import SwiftUI

/// System "Reduce transparency" (BLURT_REDUCE_TRANSPARENCY=1 forces it, for tests).
var reduceTransparency: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        || ProcessInfo.processInfo.environment["BLURT_REDUCE_TRANSPARENCY"] == "1"
}

extension NSView {
    var isDarkAppearance: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

// MARK: - BrandButton

/// The one primary action of a view: the button gradient (green → teal → azure, deep enough for white text at
/// ≥ 4.5:1), a white semibold title, a 1 pt inner top highlight and a 1 pt shadow. Hover 1.04, pressed 0.92; disabled is
/// a neutral fill. `radius` nil = a pill.
final class BrandButton: NSButton {
    private let fill = CAGradientLayer()
    private let shade = CALayer()          // hover / pressed: a white or black film over the gradient
    private let highlight = CALayer()
    var radius: CGFloat? = 7 { didSet { needsLayout = true } }
    var fontSize: CGFloat = 13 { didSet { updateTitle(); invalidateIntrinsicContentSize() } }
    var hPad: CGFloat = 14 { didSet { invalidateIntrinsicContentSize() } }
    private var hovering = false { didSet { updateShade() } }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        wantsLayer = true
        focusRingType = .default
        BrandGradient.layer(BrandGradient.buttonStops, .diagonal, flipped: false, into: fill)
        layer?.addSublayer(fill)
        fill.addSublayer(shade)
        highlight.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        fill.addSublayer(highlight)
        layer?.shadowColor = NSColor(srgbRed: 4 / 255, green: 38 / 255, blue: 30 / 255, alpha: 1).cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 1
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.masksToBounds = false
        updateTitle()
    }

    override var title: String { didSet { updateTitle(); invalidateIntrinsicContentSize() } }
    override var isEnabled: Bool { didSet { updateTitle(); needsLayout = true } }
    override var isHighlighted: Bool { didSet { updateShade() } }
    override var allowsVibrancy: Bool { false }

    private func updateTitle() {
        let fg: NSColor = isEnabled ? .white : .tertiaryLabelColor
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: fg, .paragraphStyle: p])
    }

    private func updateShade() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        if isHighlighted {
            shade.backgroundColor = NSColor(white: 0, alpha: 1 - BrandGradient.buttonPressed).cgColor
        } else if hovering && isEnabled {
            shade.backgroundColor = NSColor(white: 1, alpha: BrandGradient.buttonHover - 1).cgColor
        } else {
            shade.backgroundColor = NSColor.clear.cgColor
        }
        CATransaction.commit()
    }

    override var intrinsicContentSize: NSSize {
        let w = attributedTitle.size().width
        return NSSize(width: ceil(w + hPad * 2), height: max(24, ceil(fontSize * 1.85)))
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = radius ?? bounds.height / 2
        fill.frame = bounds
        fill.cornerRadius = r
        fill.masksToBounds = true
        shade.frame = bounds
        highlight.frame = CGRect(x: r * 0.6, y: bounds.height - 1, width: max(0, bounds.width - r * 1.2), height: 1)
        if isEnabled {
            BrandGradient.layer(BrandGradient.buttonStops, .diagonal, flipped: false, into: fill)
            fill.backgroundColor = nil
            highlight.isHidden = false
            layer?.shadowOpacity = 0.25
        } else {
            fill.colors = nil
            fill.backgroundColor = (isDarkAppearance ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.06)).cgColor
            highlight.isHidden = true
            layer?.shadowOpacity = 0
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func drawFocusRingMask() {
        let r = radius ?? bounds.height / 2
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}

// MARK: - SwiftUI

extension Color {
    static let brandFill = Color(nsColor: BrandColor.fill)
    static let brandInk = Color(nsColor: BrandColor.ink)
    static let brandTint = Color(nsColor: BrandColor.tint)
    static let brandOn = Color(nsColor: BrandColor.on)
    static let brandAccent = Color(nsColor: BrandColor.accent)
    static let brandRec = Color(nsColor: BrandColor.rec)
    static let brandAttn = Color(nsColor: BrandColor.attn)
    static let brandAttnInk = Color(nsColor: BrandColor.attnInk)
    static let brandOk = Color(nsColor: BrandColor.ok)
    static let brandOnOk = Color(nsColor: BrandColor.onOk)
    static let brandErr = Color(nsColor: BrandColor.err)
    static let brandInfo = Color(nsColor: BrandColor.info)
}

extension BrandGradient {
    static func swiftUI(_ st: [(UInt32, CGFloat)], start: UnitPoint = .topLeading, end: UnitPoint = .bottomTrailing) -> LinearGradient {
        LinearGradient(stops: st.map { .init(color: Color(nsColor: BrandColor.srgb($0.0)), location: $0.1) },
                       startPoint: start, endPoint: end)
    }
}

/// The primary button in SwiftUI: the button gradient, white semibold title.
struct BrandButtonStyle: ButtonStyle {
    var pill = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: pill ? 100 : 7, style: .continuous)
        return configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(enabled ? Color.white : Color(nsColor: .tertiaryLabelColor))
            .padding(.horizontal, 14).frame(minHeight: 24)
            .background {
                if enabled {
                    shape.fill(BrandGradient.swiftUI(BrandGradient.buttonStops))
                        .overlay(shape.fill(configuration.isPressed ? Color.black.opacity(1 - BrandGradient.buttonPressed)
                                            : hovering ? Color.white.opacity(BrandGradient.buttonHover - 1) : .clear))
                        .overlay(alignment: .top) {
                            Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1).padding(.horizontal, 4)
                        }
                        .clipShape(shape)
                        .shadow(color: Color(red: 4 / 255, green: 38 / 255, blue: 30 / 255).opacity(0.25), radius: 0.5, y: 1)
                } else {
                    shape.fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension ButtonStyle where Self == BrandButtonStyle {
    static var brand: BrandButtonStyle { BrandButtonStyle() }
}

/// Gradient text for large headlines and hero numbers only (≥ BrandGradient.textMinPoints pt): the deeper text
/// gradient on light, the base on dark; flat brand ink under Increase Contrast.
struct BrandGradientText: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if contrast == .increased || BrandColor.increaseContrast {
            content.foregroundStyle(Color.brandInk)
        } else {
            content.foregroundStyle(BrandGradient.swiftUI(BrandGradient.textStops(dark: scheme == .dark), start: .leading, end: .trailing))
        }
    }
}

extension View {
    func brandGradientText() -> some View { modifier(BrandGradientText()) }
}

// MARK: - GradientLabel (AppKit)

/// A one- or two-line label drawn in the text gradient (large headlines, hero numbers). Under Increase Contrast it is
/// flat `BrandColor.ink`.
final class GradientLabel: NSView {
    var text: String = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityLabel(text) } }
    var font: NSFont = .systemFont(ofSize: 24, weight: .bold) { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var alignment: NSTextAlignment = .left { didSet { needsDisplay = true } }

    convenience init(_ text: String, font: NSFont) {
        self.init(frame: .zero)
        self.text = text
        self.font = font
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    private var attributed: NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.alignment = alignment
        return NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: p, .foregroundColor: BrandColor.ink])
    }

    override var intrinsicContentSize: NSSize {
        let s = attributed.size()
        return NSSize(width: ceil(s.width) + 1, height: ceil(s.height))
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = attributed
        if BrandColor.increaseContrast || effectiveAppearance.name.rawValue.contains("HighContrast") {
            s.draw(in: bounds)
            return
        }
        // the glyphs as a mask, the gradient through it
        let size = s.size()
        var r = bounds
        if alignment == .center { r = NSRect(x: (bounds.width - size.width) / 2, y: bounds.minY, width: size.width, height: bounds.height) }
        else if alignment == .right { r = NSRect(x: bounds.maxX - size.width, y: bounds.minY, width: size.width, height: bounds.height) }
        else { r.size.width = min(bounds.width, size.width) }
        let scale = window?.backingScaleFactor ?? 2
        let W = Int(ceil(bounds.width * scale)), H = Int(ceil(bounds.height * scale))
        guard W > 0, H > 0, let mask = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return }
        mask.scaleBy(x: scale, y: scale)
        let g = NSGraphicsContext(cgContext: mask, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: (s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle),
                                                      .foregroundColor: NSColor.white]).draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
        guard let img = mask.makeImage() else { return }
        ctx.saveGState()
        ctx.clip(to: bounds, mask: img)
        BrandGradient.draw(BrandGradient.textStops(dark: isDarkAppearance), in: r, ctx: ctx, .horizontal)
        ctx.restoreGState()
    }
}

// MARK: - FieldView

/// The field (light) or deep (dark) with grain: hero panels and empty-state art (≥ 64 pt). Reduce Transparency drops
/// the grain. Corners: `cornerRadius` (≈ 30 % of the side for art tiles).
final class FieldView: NSView {
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    /// override the appearance-driven choice (the app icon look on any background)
    var forceDeep: Bool?

    override var isFlipped: Bool { false }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let deep = forceDeep ?? isDarkAppearance
        ctx.saveGState()
        if cornerRadius > 0 {
            ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
            ctx.clip()
        }
        BrandGradient.drawField(in: bounds, ctx: ctx, deep: deep)
        if !reduceTransparency {
            BrandGradient.drawGrain(in: bounds, ctx: ctx, opacity: deep ? BrandGradient.grainDark : BrandGradient.grainLight,
                                    scale: window?.backingScaleFactor ?? 2)
        }
        ctx.restoreGState()
    }
}

/// SwiftUI wrapper for FieldView.
struct BrandField: NSViewRepresentable {
    var cornerRadius: CGFloat = 0
    func makeNSView(context: Context) -> FieldView { let v = FieldView(); v.cornerRadius = cornerRadius; return v }
    func updateNSView(_ v: FieldView, context: Context) { v.cornerRadius = cornerRadius; v.needsDisplay = true }
}

// MARK: - Glow

enum GlowLayer {
    /// A soft, blurred strip of `stops` (horizontal), `size` points, as an image for a layer's contents. Cached.
    private static var cache: [String: CGImage] = [:]

    static func image(_ stops: [(UInt32, CGFloat)], size: CGSize, blur: CGFloat, scale: CGFloat = 2) -> CGImage? {
        let key = "\(stops.map { $0.0 })|\(Int(size.width))x\(Int(size.height))|\(blur)|\(scale)"
        if let c = cache[key] { return c }
        let pad = blur * 2
        let W = Int((size.width + pad * 2) * scale), H = Int((size.height + pad * 2) * scale)
        guard W > 0, H > 0, let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let r = CGRect(x: pad, y: pad, width: size.width, height: size.height)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(r.height, r.width) / 2, cornerHeight: min(r.height, r.width) / 2, transform: nil))
        ctx.clip()
        BrandGradient.draw(stops, in: r, ctx: ctx, .horizontal)
        guard let sharp = ctx.makeImage() else { return nil }
        let ci = CIImage(cgImage: sharp).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur * scale])
            .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        let out = CIContext(options: nil).createCGImage(ci, from: ci.extent)
        cache[key] = out
        return out
    }

    /// A layer showing the listening aura (base gradient) of `size`; place it centred under what listens. Its frame is
    /// larger than `size` by the blur on every side. nil with Reduce Transparency.
    static func make(size: CGSize, stops: [(UInt32, CGFloat)] = BrandGradient.linearStops,
                     blur: CGFloat = BrandGradient.glowBlur) -> CALayer? {
        if reduceTransparency { return nil }
        let l = CALayer()
        l.contents = image(stops, size: size, blur: blur)
        l.contentsGravity = .resize
        l.bounds = CGRect(x: 0, y: 0, width: size.width + blur * 4, height: size.height + blur * 4)
        l.opacity = Float(BrandGradient.glowOpacity)
        return l
    }

    /// Fade a glow layer in (200 ms) or out.
    static func fade(_ l: CALayer?, visible: Bool, opacity: CGFloat = BrandGradient.glowOpacity) {
        guard let l else { return }
        let to: Float = visible ? Float(opacity) : 0
        if l.opacity == to { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = l.presentation()?.opacity ?? l.opacity
        a.toValue = to
        a.duration = BrandGradient.glowFadeIn
        l.add(a, forKey: "fade")
        l.opacity = to
    }
}

// MARK: - AI glow

/// The spectrum as a soft rim around what AI is working on (auto-sort, polish, Structured, the Lab run). Put it over
/// (or just around) the working view; it doesn't take clicks. It turns once per `aiGlowPeriod`; still with Reduce Motion;
/// hidden with Reduce Transparency.
final class AIGlowView: NSView {
    var cornerRadius: CGFloat = 10 { didSet { needsLayout = true } }
    /// how far the glow reaches outside the working view's edge
    let outset: CGFloat = 8
    private let container = CALayer()
    private let soft = CALayer()
    private let crisp = CALayer()
    private let softGrad = CAGradientLayer()
    private let crispGrad = CAGradientLayer()
    private let softMask = CAShapeLayer()
    private let crispMask = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.addSublayer(container)
        for (holder, g, m) in [(soft, softGrad, softMask), (crisp, crispGrad, crispMask)] {
            g.type = .conic
            g.colors = (BrandGradient.spectrumStops + [BrandGradient.spectrumStops[0]]).map { BrandColor.srgb($0.0).cgColor }
            g.locations = (BrandGradient.spectrumStops.map { NSNumber(value: Double($0.1) * 0.92) } + [1])
            g.startPoint = CGPoint(x: 0.5, y: 0.5)
            g.endPoint = CGPoint(x: 0.5, y: 0)
            holder.addSublayer(g)
            m.fillColor = nil
            m.strokeColor = NSColor.black.cgColor
            holder.mask = m
            container.addSublayer(holder)
        }
        soft.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: BrandGradient.aiGlowBlur / 2])!]
        soft.opacity = Float(BrandGradient.aiGlowOpacity)
        crisp.opacity = 0.9
        isHidden = reduceTransparency
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        let inner = bounds.insetBy(dx: outset, dy: outset)
        let path = CGPath(roundedRect: inner, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        let side = hypot(bounds.width, bounds.height)
        for (holder, g, m, w) in [(soft, softGrad, softMask, BrandGradient.aiGlowBlur), (crisp, crispGrad, crispMask, BrandGradient.aiGlowWidth)] {
            holder.frame = bounds
            g.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            g.position = CGPoint(x: bounds.midX, y: bounds.midY)
            m.frame = bounds
            m.path = path
            m.lineWidth = w
        }
        CATransaction.commit()
        spin()
    }

    private func spin() {
        for g in [softGrad, crispGrad] {
            g.removeAnimation(forKey: "spin")
            guard !reduceMotion else { continue }
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0
            a.toValue = -2 * Double.pi
            a.duration = BrandGradient.aiGlowPeriod
            a.repeatCount = .infinity
            g.add(a, forKey: "spin")
        }
    }

    /// Show / hide with a short fade.
    func set(active: Bool) {
        if reduceTransparency { isHidden = true; return }
        if active { isHidden = false; spin() }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.25
            animator().alphaValue = active ? 1 : 0
        }, completionHandler: { [weak self] in if !active { self?.isHidden = true } })
    }

    /// Adds a glow around `view` (as a sibling just above it) and returns it.
    @discardableResult
    static func attach(around view: NSView, cornerRadius: CGFloat) -> AIGlowView? {
        guard let parent = view.superview else { return nil }
        let g = AIGlowView(frame: view.frame.insetBy(dx: -8, dy: -8))
        g.cornerRadius = cornerRadius
        g.autoresizingMask = view.autoresizingMask
        parent.addSubview(g, positioned: .above, relativeTo: view)
        return g
    }
}

/// SwiftUI: the AI-working rim around a view while `active`.
struct AIGlow: ViewModifier {
    var active: Bool
    var cornerRadius: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var turn = 0.0

    func body(content: Content) -> some View {
        content.overlay {
            if active && !reduceTransparency {
                let st = BrandGradient.spectrumStops + [BrandGradient.spectrumStops[0]]
                let grad = AngularGradient(stops: st.enumerated().map { i, s in
                    .init(color: Color(nsColor: BrandColor.srgb(s.0)), location: i == st.count - 1 ? 1 : s.1 * 0.92) },
                                           center: .center, angle: .degrees(turn))
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                ZStack {
                    shape.stroke(grad, lineWidth: BrandGradient.aiGlowBlur).blur(radius: BrandGradient.aiGlowBlur / 2)
                        .opacity(BrandGradient.aiGlowOpacity)
                    shape.stroke(grad, lineWidth: BrandGradient.aiGlowWidth).opacity(0.9)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
                .onAppear {
                    guard !(reduce || reduceMotion) else { return }
                    withAnimation(.linear(duration: BrandGradient.aiGlowPeriod).repeatForever(autoreverses: false)) { turn = 360 }
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: active)
    }
}

extension View {
    func aiGlow(_ active: Bool, cornerRadius: CGFloat = 10) -> some View { modifier(AIGlow(active: active, cornerRadius: cornerRadius)) }
}

// MARK: - Celebration

/// The completion celebration: a spectrum ring blooms out of `rect` (in `view`'s coordinates) once and fades
/// (0.9 s). Nothing with Reduce Motion or Reduce Transparency: the done state (ok + check) says it already.
enum Celebration {
    static func play(in view: NSView, around rect: NSRect, cornerRadius: CGFloat = 12) {
        guard !reduceMotion, !reduceTransparency, let host = view.layer else { return }
        let ring = CAGradientLayer()
        ring.type = .conic
        let st = BrandGradient.spectrumStops + [BrandGradient.spectrumStops[0]]
        ring.colors = st.map { BrandColor.srgb($0.0).cgColor }
        ring.locations = st.enumerated().map { i, s in NSNumber(value: i == st.count - 1 ? 1 : Double(s.1) * 0.92) }
        ring.startPoint = CGPoint(x: 0.5, y: 0.5)
        ring.endPoint = CGPoint(x: 0.5, y: 0)
        ring.frame = rect.insetBy(dx: -6, dy: -6)
        let m = CAShapeLayer()
        m.frame = ring.bounds
        m.path = CGPath(roundedRect: ring.bounds.insetBy(dx: 6, dy: 6), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        m.fillColor = nil
        m.strokeColor = NSColor.black.cgColor
        m.lineWidth = 3
        ring.mask = m
        host.addSublayer(ring)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 1.12
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [grow, fade]
        g.duration = 0.9
        g.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        ring.opacity = 0
        ring.add(g, forKey: "bloom")
        CATransaction.commit()
    }
}
