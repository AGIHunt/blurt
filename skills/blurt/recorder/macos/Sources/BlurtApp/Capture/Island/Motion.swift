// Motion shared by the island and the hanging cards: a critically-tunable spring (response / damping, as in SwiftUI), the
// system's Reduce Motion, easing curves, and a display-link driver that runs only while something moves.
import AppKit
import QuartzCore

struct Spring {
    var value: CGFloat
    var target: CGFloat
    var velocity: CGFloat = 0
    var k: CGFloat
    var c: CGFloat

    /// response: the period of the undamped oscillation (s); damping: 1 = no overshoot.
    init(_ v: CGFloat, response: CGFloat = 0.42, damping: CGFloat = 0.82) {
        value = v; target = v
        let w = 2 * .pi / response
        k = w * w
        c = 2 * damping * w
    }

    mutating func step(_ dt: CGFloat) -> CGFloat {
        var t = min(dt, 0.05)
        while t > 0 {
            let h = min(t, 1.0 / 240)
            let a = -k * (value - target) - c * velocity
            velocity += a * h
            value += velocity * h
            t -= h
        }
        return value
    }

    var resting: Bool { abs(value - target) < 0.01 && abs(velocity) < 0.01 }
    mutating func snap() { value = target; velocity = 0 }
}

/// System "Reduce motion" (BLURT_REDUCE_MOTION=1 forces it, for tests).
var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ProcessInfo.processInfo.environment["BLURT_REDUCE_MOTION"] == "1"
}
var isDarkMode: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

enum Ease {
    static func outCubic(_ t: CGFloat) -> CGFloat { let u = 1 - min(max(t, 0), 1); return 1 - u * u * u }
    static func inCubic(_ t: CGFloat) -> CGFloat { let u = min(max(t, 0), 1); return u * u * u }
    static func inOutCubic(_ t: CGFloat) -> CGFloat {
        let u = min(max(t, 0), 1)
        return u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
    }
    static func outBack(_ t: CGFloat, _ s: CGFloat = 1.6) -> CGFloat {
        let u = min(max(t, 0), 1) - 1
        return 1 + (s + 1) * u * u * u + s * u * u
    }
}

/// Calls `tick(dt)` on the display (up to 120 Hz) while it returns true; then idles at `idleRate` calling `idle()`
/// (pointer polls), or stops entirely when `idle` is nil. `wake()` restarts the fast loop.
final class MotionDriver: NSObject {
    var tick: ((CGFloat) -> Bool)?
    var idle: (() -> Void)?
    var idleRate: Double = 1.0 / 20
    private weak var view: NSView?
    private var link: AnyObject?
    private var slow: Timer?
    private var last = CACurrentMediaTime()
    private var still = 0

    init(view: NSView) { self.view = view }

    func wake() {
        still = 0
        guard link == nil, let v = view else { return }
        slow?.invalidate()
        slow = nil
        last = CACurrentMediaTime()
        if #available(macOS 14.0, *) {
            let l = v.displayLink(target: self, selector: #selector(fired))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.fired() }
            RunLoop.main.add(t, forMode: .common)
            link = t
        }
    }

    @objc private func fired() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.05, now - last))
        last = now
        let moving = tick?(dt) ?? false
        if moving { still = 0 } else {
            still += 1
            if still >= 3 { settle() }
        }
    }

    private func settle() {
        if #available(macOS 14.0, *), let l = link as? CADisplayLink { l.invalidate() }
        (link as? Timer)?.invalidate()
        link = nil
        guard idle != nil, slow == nil else { return }
        let t = Timer(timeInterval: idleRate, repeats: true) { [weak self] _ in self?.idle?() }
        t.tolerance = idleRate / 2
        RunLoop.main.add(t, forMode: .common)
        slow = t
    }

    func stop() {
        if #available(macOS 14.0, *), let l = link as? CADisplayLink { l.invalidate() }
        (link as? Timer)?.invalidate()
        link = nil
        slow?.invalidate()
        slow = nil
    }
}
