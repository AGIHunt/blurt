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

/// System "Reduce motion" (BLURT_REDUCE_MOTION=1 forces it, for tests). Read every frame, several times: the environment
/// is read once (building it was most of the island's work per frame).
var reduceMotion: Bool { reduceMotionForced || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
private let reduceMotionForced = ProcessInfo.processInfo.environment["BLURT_REDUCE_MOTION"] == "1"
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
/// (pointer polls), or stops entirely when `idle` is nil. `wake()` restarts the fast loop — only while the view's window
/// is on screen (macOS 14+: a view's display link doesn't fire for an ordered-out window; it idles meanwhile).
/// `maxFPS`: a tick may lower the rate while only small things move (the island's ears: 30); `wake()` puts it back to
/// 120, so whatever woke it springs at the display's rate from its first frame.
final class MotionDriver: NSObject {
    var tick: ((CGFloat) -> Bool)?
    var idle: (() -> Void)?
    var idleRate: Double = 1.0 / 20
    private weak var view: NSView?
    private var link: AnyObject?
    private var slow: Timer?
    private var last = CACurrentMediaTime()
    private var still = 0
    var maxFPS: Float = 120 {
        didSet {
            guard maxFPS != oldValue, #available(macOS 14.0, *), let l = link as? CADisplayLink else { return }
            l.preferredFrameRateRange = MotionDriver.range(maxFPS)
        }
    }

    init(view: NSView) { self.view = view }

    @available(macOS 14.0, *)
    private static func range(_ fps: Float) -> CAFrameRateRange {
        CAFrameRateRange(minimum: min(60, fps), maximum: fps, preferred: fps)
    }

    func wake() {
        still = 0
        maxFPS = 120
        // A view's display link only fires while its window is on screen. One left running when the window was ordered
        // out never fires again, so it never settles into the idle polls — and every later wake() found it "running"
        // and did nothing. (That is how the hanging cards stopped coming back on hover: their poll never ran again.)
        if link != nil, CACurrentMediaTime() - last > 0.5 { invalidateLink() }
        guard link == nil, let v = view else { return }
        // ordered out: nothing to draw, and a display link would not fire — keep polling until it is ordered in again
        // (whoever orders it in wakes us again)
        if #available(macOS 14.0, *), v.window?.isVisible != true { settle(); return }
        slow?.invalidate()
        slow = nil
        last = CACurrentMediaTime()
        if #available(macOS 14.0, *) {
            let l = v.displayLink(target: self, selector: #selector(fired))
            l.preferredFrameRateRange = MotionDriver.range(maxFPS)
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
        let gap = now - last, fps = maxFPS
        let dt = CGFloat(min(0.05, gap))
        last = now
        let moving = tick?(dt) ?? false
        if PerfFrames.on, view is IslandView { PerfFrames.shared.tick(gap: gap, work: CACurrentMediaTime() - now, fps: fps) }
        if moving { still = 0 } else {
            still += 1
            if still >= 3 { settle() }
        }
    }

    /// Nothing moves (or the window is about to be ordered out): stop the display link now and go back to the idle
    /// polls. Call it before ordering the view's window out — an off-screen window's display link stops firing.
    func rest() { settle() }

    private func invalidateLink() {
        if #available(macOS 14.0, *), let l = link as? CADisplayLink { l.invalidate() }
        (link as? Timer)?.invalidate()
        link = nil
    }

    private func settle() {
        invalidateLink()
        guard idle != nil, slow == nil else { return }
        let t = Timer(timeInterval: idleRate, repeats: true) { [weak self] _ in self?.idle?() }
        t.tolerance = idleRate / 2
        RunLoop.main.add(t, forMode: .common)
        slow = t
    }

    func stop() {
        invalidateLink()
        slow?.invalidate()
        slow = nil
    }
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

/// BLURT_PERF_FRAMES=1 (scratch measurements): the island's ticks — the gap since the last one, late when over 1.5 frames
/// at the rate asked for — and Peep's frame steps, said once a second as a `perf_frames` event. Off: nothing is timed.
final class PerfFrames {
    static let on = ProcessInfo.processInfo.environment["BLURT_PERF_FRAMES"] == "1"
    static let shared = PerfFrames()
    private var ticks = 0, late = 0, work = 0.0, worstGap = 0.0, peep = 0, peepWork = 0.0, peepWorst = 0.0
    private var since = CACurrentMediaTime()

    func tick(gap: Double, work w: Double, fps: Float) {
        ticks += 1
        work += w
        worstGap = max(worstGap, gap)
        if gap > 1.5 / Double(fps) && gap < 0.25 { late += 1 }      // (a first tick after a rest is no late frame)
        flush()
    }
    func peepStep(_ w: Double) { peep += 1; peepWork += w; peepWorst = max(peepWorst, w); flush() }

    private func flush() {
        let now = CACurrentMediaTime()
        guard now - since >= 1 else { return }
        let ms = { (x: Double) in (x * 10000).rounded() / 10 }
        emit(["event": "perf_frames", "secs": ms(now - since) / 1000, "ticks": ticks, "late": late, "gap_max_ms": ms(worstGap),
              "island_ms": ms(work), "peep_steps": peep, "peep_ms": ms(peepWork), "peep_max_ms": ms(peepWorst)])
        ticks = 0; late = 0; work = 0; worstGap = 0; peep = 0; peepWork = 0; peepWorst = 0
        since = now
    }
}
