// The menu-bar chick's hop and crouch (BlurtApp MenuGlyph.pose) as plain numbers, so they can be tested: how far a pose
// may stretch the chick before its ink leaves the frame. A crouch widens the chick; the wing nubs already reach to within
// half a point of the 18 pt box's sides, so the widening is capped there rather than cut off flat by the image's edge.
import CoreGraphics

public enum GlyphPose {
    /// Air kept between the chick's ink and the frame's edges, in pt: one pixel at 2x.
    public static let margin: CGFloat = 0.5

    /// The x and y scale for a pose squashed by `squash` (y × (1 − squash), x × (1 + squash), about the foot and the box's
    /// centre line) and lifted by `lift` pt, clamped so the ink stays `margin` inside the frame. `ink` and `foot` are in
    /// the box's points (y down); the box (`box` pt square) sits centred in a frame `barHeight` tall and `box` wide (the
    /// arcs, when shown, widen the frame to the right only, so the left edge is the one that limits).
    public static func scales(squash: CGFloat, lift: CGFloat, ink: CGRect, foot: CGFloat, box: CGFloat, barHeight: CGFloat)
        -> (x: CGFloat, y: CGFloat) {
        let mid = box / 2
        let half = max(mid - ink.minX, ink.maxX - mid)
        let sx = min(1 + squash, max(1, (mid - margin) / half))
        let above = (barHeight - box) / 2 + foot - lift - margin        // room from the lifted foot up to the frame's top
        let sy = min(1 - squash, max(0, above / (foot - ink.minY)))
        return (sx, sy)
    }
}
