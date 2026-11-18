// How fingers become pointer movement. A phone's glass is about a tenth of a Mac trackpad's width and the screen it steers
// may be 4K, so one fixed gain can't do both: a slow finger must place the pointer on a single character and a quick
// flick must cross the display. The curve is flat and precise below `slow`, then rises smoothly to `gain`, the way macOS's
// own pointer acceleration feels.
import Foundation

public struct RemotePointerCurve: Equatable, Sendable {
    /// points on the Mac per point on the glass, for a slow finger
    public var slowGain: Float = 1.0
    /// the same, for a fast one
    public var fastGain: Float = 5.5
    /// finger speeds (points/s) between which the gain rises
    public var slow: Float = 60
    public var fast: Float = 900
    public init() {}

    /// The user's one "speed" setting scales the whole curve, 1 = default.
    public func scaled(_ s: Float) -> RemotePointerCurve {
        var c = self
        c.slowGain *= s; c.fastGain *= s
        return c
    }

    public func gain(speed: Float) -> Float {
        let t = max(0, min(1, (speed - slow) / (fast - slow)))
        let smooth = t * t * (3 - 2 * t)
        return slowGain + (fastGain - slowGain) * smooth
    }

    /// One step of the finger, in points, over `dt` seconds → the step for the Mac.
    public func apply(dx: Float, dy: Float, dt: Float) -> (Float, Float) {
        let g = gain(speed: (dx * dx + dy * dy).squareRoot() / max(dt, 0.001))
        return (dx * g, dy * g)
    }
}

/// Keeps the fractions of a point that one-step rounding would lose: a slow drag must add up exactly.
public struct RemoteSubpixel: Sendable {
    private var x: Float = 0
    private var y: Float = 0
    public init() {}
    public mutating func whole(_ dx: Float, _ dy: Float) -> (Int, Int) {
        x += dx; y += dy
        let ix = x.rounded(.towardZero), iy = y.rounded(.towardZero)
        x -= ix; y -= iy
        return (Int(ix), Int(iy))
    }
    public mutating func reset() { x = 0; y = 0 }
}
