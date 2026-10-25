// The one "working" motion of the main window (design system §3.3, job spinner arc): a quarter arc in brand ink
// going round once every 1.1 s on a faint track — still under Reduce Motion. Job rows, the item banner and the job
// timeline's running step all use it, never the system's grey spokes next to it.
import AppKit
import QuartzCore

final class BrandSpinner: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private(set) var isAnimating = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [track, arc] {
            l.fillColor = nil
            l.lineWidth = 1.75
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        arc.strokeEnd = 0.3
        isHidden = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 14) }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        let r = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side).insetBy(dx: 1.5, dy: 1.5)
        for l in [track, arc] {
            l.frame = bounds
            l.path = CGPath(ellipseIn: r, transform: nil)
        }
        arc.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        arc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        colors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colors()
    }

    private func colors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = NSColor.separatorColor.cgColor
            arc.strokeColor = BrandColor.ink.cgColor
        }
    }

    func startAnimation() {
        isHidden = false
        guard !isAnimating else { return }
        isAnimating = true
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -Double.pi * 2
        spin.duration = 1.1
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "spin")
    }

    func stopAnimation() {
        isHidden = true
        isAnimating = false
        arc.removeAnimation(forKey: "spin")
    }
}
