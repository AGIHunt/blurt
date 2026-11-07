// What's in view of the Mac's screen, on the phone: the phone owns this. Fingers move it at once over the picture already here, and the
// Mac is asked for that part when it can send it. The stage is all the room the phone has, and the picture sits in it like a photo: whole
// and letterboxed at first, then filling the stage as it's zoomed. Everything is 0…1 of the screen, so it's plain arithmetic and testable.
import BlurtRemoteKit
import CoreGraphics

struct ViewPort: Equatable {
    static let closest: CGFloat = 8
    /// how far out a pinch stretches before it springs back
    static let stretch: CGFloat = 0.8
    /// let go this close to the whole screen and it's the whole screen
    static let snap: CGFloat = 1.08
    /// the pointer stays this far inside the view: past it, the view moves on
    static let margin: CGFloat = 0.12

    private(set) var zoom: CGFloat = 1
    /// the stage in screen units: may stick out of 0…1 where the picture doesn't fill it
    private(set) var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// the stage's shape over the picture's: above 1 it's wider than the picture, so that way has room to spare
    private var shape: CGFloat = 1
    /// where a picture smaller than the stage sits, top to bottom, 0…1: near the thumb in portrait
    private var alignY: CGFloat = 0.5

    var isWhole: Bool { zoom <= 1 }

    /// The part of the screen in view.
    var visible: CGRect { rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)) }

    /// The stage changed: the same middle stays in the middle.
    mutating func reshape(_ s: CGFloat, alignY a: CGFloat) {
        guard s > 0, s.isFinite, s != shape || a != alignY else { return }
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        shape = s
        alignY = a
        let size = size(zoom)
        set(zoom, x: mid.x - size.width / 2, y: mid.y - size.height / 2)
    }

    private func size(_ z: CGFloat) -> CGSize { CGSize(width: max(1, shape) / z, height: max(1, 1 / shape) / z) }

    /// Scaled about `anchor` (0…1 of the stage), moved by `move` (a fraction of the stage).
    mutating func change(scale: CGFloat, move: CGPoint, anchor: CGPoint) {
        guard scale > 0, scale.isFinite else { return }
        let z = max(Self.stretch, min(Self.closest, zoom * scale))
        let world = CGPoint(x: rect.minX + anchor.x * rect.width, y: rect.minY + anchor.y * rect.height)
        let s = size(z)
        set(z, x: world.x - (anchor.x + move.x) * s.width, y: world.y - (anchor.y + move.y) * s.height)
    }

    /// The fingers lifted: past the whole screen it comes back.
    mutating func settle() {
        if zoom < Self.snap { set(1, x: 0, y: 0) }
    }

    /// The pointer near the edge of the view takes the view along. True if it moved.
    mutating func follow(_ p: CGPoint) -> Bool {
        guard !isWhole else { return false }
        let v = visible
        let inner = v.insetBy(dx: v.width * Self.margin, dy: v.height * Self.margin)
        let dx = p.x < inner.minX ? p.x - inner.minX : p.x > inner.maxX ? p.x - inner.maxX : 0
        let dy = p.y < inner.minY ? p.y - inner.minY : p.y > inner.maxY ? p.y - inner.maxY : 0
        guard dx != 0 || dy != 0 else { return false }
        let was = rect
        set(zoom, x: rect.minX + dx, y: rect.minY + dy)
        return rect != was
    }

    private mutating func set(_ z: CGFloat, x: CGFloat, y: CGFloat) {
        zoom = z
        let s = size(z)
        // smaller than the screen it stays inside; larger, the picture sits still in it
        rect = CGRect(x: s.width < 1 ? min(1 - s.width, max(0, x)) : (1 - s.width) / 2,
                      y: s.height < 1 ? min(1 - s.height, max(0, y)) : (1 - s.height) * alignY,
                      width: s.width, height: s.height)
    }

    /// What to ask the Mac for: the screen's shape, around what's in view. The stage may be another shape, so it can be a little more than that.
    var crop: RemoteCrop {
        guard !isWhole else { return .whole }
        let v = visible, side = min(1, max(v.width, v.height))
        guard side < 1 else { return .whole }
        return RemoteCrop(x: Float(min(1 - side, max(0, v.midX - side / 2))), y: Float(min(1 - side, max(0, v.midY - side / 2))), w: Float(side), h: Float(side))
    }
}
