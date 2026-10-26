// A window laid over a screen region that must show a panel whole (the recording countdown, App.countdown). Review
// v0.9-userfix: the countdown's window was the region's size, so a small region cut the ring and "Start now" off.
// The window is the region, or — when the region is smaller than the panel and its shadow — that much, centred on
// the region and kept on its screen. Pure: OverlayFitTests.
import CoreGraphics

public enum OverlayFit {
    /// `region`, `screen`: one coordinate space (either origin); `margin`: room for the panel's shadow on each side.
    public static func frame(region: CGRect, panel: CGSize, margin: CGFloat, screen: CGRect?) -> CGRect {
        let w = max(region.width, panel.width + 2 * margin), h = max(region.height, panel.height + 2 * margin)
        var f = CGRect(x: region.midX - w / 2, y: region.midY - h / 2, width: w, height: h)
        if let s = screen {
            f.origin.x = min(max(f.minX, s.minX), max(s.minX, s.maxX - w))
            f.origin.y = min(max(f.minY, s.minY), max(s.minY, s.maxY - h))
        }
        return f.integral
    }
}
