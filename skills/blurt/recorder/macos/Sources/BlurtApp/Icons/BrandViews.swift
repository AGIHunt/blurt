// The views every surface builds the brand from (docs/design/system.md §5.1). Colours and gradient stops come from
// the generated BrandColor.swift (assets/color/tokens.json); this file only draws them.
//
//   BrandButton       primary button: the deeper button gradient, white bold title (AppKit)
//   BrandButtonStyle  the same for SwiftUI
//   GradientLabel     gradient text for large headlines / hero numbers (AppKit); `.brandGradientText()` in SwiftUI
//   FieldView         the field (light) / deep (dark) with grain, for heroes and empty-state art; `BrandField` in SwiftUI
//   GlowLayer         the listening aura: the base gradient, blurred
//   WorkingOutline    "AI is working on this": one static 1 pt brand-ink hairline (`.aiWorking` in SwiftUI)
//   BrandMarkView     the empty states' mark: Peep alone, idling (Icons/Mascot.swift); MascotImage in SwiftUI
//
// Accessibility: Reduce Transparency → no grain, no glow (flat colours only); Increase Contrast → gradient text turns
// flat brand ink (the generated colours switch to their `hc` values by themselves); Reduce Motion → the listening
// glow doesn't breathe.
import AppKit
import QuartzCore
import SwiftUI

/// System "Reduce transparency" (BLURT_REDUCE_TRANSPARENCY=1 forces it, for tests).
var reduceTransparency: Bool { reduceTransparencyForced || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
private let reduceTransparencyForced = ProcessInfo.processInfo.environment["BLURT_REDUCE_TRANSPARENCY"] == "1"

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
    /// a key after the title, lighter (white 70 %, regular): "Done ↩" — the shortcut said once, on the button
    var keyHint: String? { didSet { updateTitle(); invalidateIntrinsicContentSize() } }
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
        // (`title` reads back the attributed title, key and all: a redraw — isEnabled flipping — never adds it twice)
        let base = keyHint.map { k in title.hasSuffix("  " + k) ? String(title.dropLast(k.count + 2)) : title } ?? title
        let t = NSMutableAttributedString(string: base, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: fg, .paragraphStyle: p])
        if let k = keyHint {
            t.append(NSAttributedString(string: "  " + k, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize - 1, weight: .regular),
                .foregroundColor: isEnabled ? NSColor(white: 1, alpha: 0.7) : NSColor.tertiaryLabelColor, .paragraphStyle: p]))
        }
        attributedTitle = t
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
    static let brandWorking = Color(nsColor: BrandColor.working)
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
        // one line at its own width: squeezed by its neighbours it never wraps a glyph per line (dogfood v0.9)
        return configuration.label
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
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

/// The field (light) or deep (dark) with grain: the onboarding hero (≥ 64 pt). Reduce Transparency drops
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

// MARK: - AI working

/// The job spinner (§3.3 "job spinner arc"), the one "working" motion of the main window: a quarter arc in brand ink
/// going round, 1.1 s a turn — the same arc as the running step's marker (JobViews StepMarker), so a job's row, its
/// banner, the scanning empty state and its steps spin alike, never the system's grey spokes. Reduce Motion: the
/// arc stands still. Hidden while stopped (it takes no room's worth of drawing then), like a stopped NSProgressIndicator
/// with isDisplayedWhenStopped off.
final class BrandSpinner: NSView {
    private let ring = CAShapeLayer()
    private let diameter: CGFloat
    private(set) var isAnimating = false

    init(size: CGFloat = 14) {
        diameter = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        ring.fillColor = nil
        ring.lineWidth = size >= 24 ? 2.25 : 1.75
        ring.strokeStart = 0
        ring.strokeEnd = 0.3
        ring.lineCap = .round
        layer?.addSublayer(ring)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    override func layout() {
        super.layout()
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: ring.lineWidth, dy: ring.lineWidth), transform: nil)
        effectiveAppearance.performAsCurrentDrawingAppearance { ring.strokeColor = BrandColor.ink.cgColor }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { ring.strokeColor = BrandColor.ink.cgColor }
    }

    func startAnimation(_ sender: Any? = nil) {
        isHidden = false
        guard !isAnimating else { return }
        isAnimating = true
        needsLayout = true
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -Double.pi * 2
        spin.duration = 1.1
        spin.repeatCount = .infinity
        ring.add(spin, forKey: "spin")
    }

    func stopAnimation(_ sender: Any? = nil) {
        isAnimating = false
        ring.removeAnimation(forKey: "spin")
        isHidden = true
    }
}

/// The same spinner in SwiftUI (Settings, the setup assistant, panels): never `ProgressView()`'s grey spokes, so the
/// app has one spinner everywhere (§3.3). `size` 10 for a row's dot column, 14 next to a line of text. Turns while
/// shown; Reduce Motion stands it still (BrandSpinner). `label`: what VoiceOver says it is busy with.
struct BrandSpinnerView: NSViewRepresentable {
    var size: CGFloat = 14
    var label: String?

    func makeNSView(context: Context) -> BrandSpinner {
        let s = BrandSpinner(size: size)
        s.setAccessibilityLabel(label)
        s.startAnimation()
        return s
    }

    func updateNSView(_ s: BrandSpinner, context: Context) {
        s.setAccessibilityLabel(label)
        if !s.isAnimating { s.startAnimation() }
    }

    @available(macOS 13.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BrandSpinner, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

/// "blurt's AI is working on this" (organizing cards or a batch, the Lab processing a take): one static 1 pt
/// hairline in translucent brand ink (`brand.working`; `BrandColor.Island.working` on the island) just inside the
/// working view's rounded edge. The spinner next to it carries the state; the line only says
/// which row the AI is on. No rotation, no spectrum, no halo — so Reduce Motion and Reduce Transparency change nothing.
/// It doesn't take clicks.
final class WorkingOutline: NSView {
    var cornerRadius: CGFloat = 6 { didSet { needsDisplay = true } }
    /// the always-dark island value (`BrandColor.Island.working`) instead of the dynamic `BrandColor.working`
    var island = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        alphaValue = 0
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirty: NSRect) {
        let w = BrandColor.workingWidth
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: w / 2, dy: w / 2), xRadius: cornerRadius, yRadius: cornerRadius)
        p.lineWidth = w
        (island ? BrandColor.Island.working : BrandColor.working).setStroke()
        p.stroke()
    }

    /// Show / hide with a short fade (none with Reduce Motion).
    func set(active: Bool) {
        if active { isHidden = false }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = reduceMotion ? 0 : 0.2
            animator().alphaValue = active ? 1 : 0
        }, completionHandler: { [weak self] in if !active { self?.isHidden = true } })
    }
}

/// SwiftUI: the AI-working hairline round a view while `active` (see `WorkingOutline`).
struct AIWorking: ViewModifier {
    var active: Bool
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.brandWorking, lineWidth: BrandColor.workingWidth)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: active)
    }
}

extension View {
    func aiWorking(_ active: Bool, cornerRadius: CGFloat = 10) -> some View { modifier(AIWorking(active: active, cornerRadius: cornerRadius)) }
}

// MARK: - Empty states

/// One empty state for every page (AppKit `EmptyStateView`, SwiftUI `EmptyStateContent`): the mark, a neutral title,
/// a neutral hint, at most one primary — the same sizes and spacing everywhere.
enum EmptyState {
    /// the mark's slot: Peep's square (its breath and shadow reach past it)
    static let markSide: CGFloat = 80
    static let markToTitle: CGFloat = 10
    static let titleToMessage: CGFloat = 4
    static let messageToButtons: CGFloat = 16
    static let titleSize: CGFloat = 15
    static let messageSize: CGFloat = 12
    static let messageWidth: CGFloat = 320
}

/// SwiftUI: the one empty state — the mark, a title, a hint, then `actions` (at most one primary).
struct EmptyStateContent<Actions: View>: View {
    var title: String
    var message: String = ""
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            // the mark: Peep alone, idling (BrandMarkView in AppKit), filling the 80 pt slot
            MascotImage(clip: .idle, size: EmptyState.markSide)
                .frame(width: EmptyState.markSide, height: EmptyState.markSide)
                .accessibilityHidden(true)
                .padding(.bottom, EmptyState.markToTitle)
            Text(title).font(.system(size: EmptyState.titleSize, weight: .semibold)).multilineTextAlignment(.center)
            if !message.isEmpty {
                Text(message).font(.system(size: EmptyState.messageSize)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: EmptyState.messageWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, EmptyState.titleToMessage)
            }
            if Actions.self != EmptyView.self { actions().padding(.top, EmptyState.messageToButtons) }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateContent where Actions == EmptyView {
    init(title: String, message: String = "") { self.init(title: title, message: message) { EmptyView() } }
}
