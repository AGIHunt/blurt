// The menu-bar hen (the `blurt` glyph, assets/brand/glyph.svg) moves a little, in code: while voice input listens it
// lifts its beak — the head tips back about the nape (`pivot`), as if about to shout — and it hops once when something
// is done (an item fixed / confirmed, a batch organised). The status item can only show an image, so this swaps
// template images at 24 fps — only while it moves; Reduce Motion: it stays still (no timer, the plain icon).
import AppKit

final class MenuGlyph {
    static let shared = MenuGlyph()
    /// What the status item shows right now while it moves (nil = the plain icon).
    private(set) var current: NSImage?
    var onFrame: ((NSImage?) -> Void)?

    private var timer: Timer?
    private var tiltSince: CFTimeInterval?
    private var hopSince: CFTimeInterval?
    private var cache: [String: NSImage] = [:]
    private let size: CGFloat = 18
    /// The back of the neck, in unit coordinates of the 18 pt image (y up): the head tips back about it.
    static let pivot = CGPoint(x: 0.4, y: 0.2)

    /// Voice input listening (the island and the status item follow it).
    var listening = false {
        didSet {
            guard listening != oldValue else { return }
            tiltSince = listening ? CACurrentMediaTime() : nil
            run()
        }
    }

    func hop() {
        hopSince = CACurrentMediaTime()
        run()
    }

    private var moving: Bool { tiltSince != nil || hopSince != nil }

    private func run() {
        if reduceMotion || !moving {
            timer?.invalidate(); timer = nil
            current = nil
            onFrame?(nil)
            return
        }
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 24, repeats: true) { [weak self] _ in self?.frame() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        frame()
    }

    private func frame() {
        if reduceMotion { run(); return }      // turned on mid-move: back to the still icon
        let now = CACurrentMediaTime()
        var angle: CGFloat = 0, lift: CGFloat = 0, squash: CGFloat = 0
        if let s = tiltSince {
            // 0 → 12° beak up (counter-clockwise) → hold → 0 every 1.4 s, eased
            let u = (now - s).truncatingRemainder(dividingBy: 1.4) / 1.4
            let e = u < 0.35 ? Ease.inOutCubic(CGFloat(u / 0.35)) : u < 0.65 ? 1 : 1 - Ease.inOutCubic(CGFloat((u - 0.65) / 0.35))
            angle = 0.21 * e
        }
        if let s = hopSince {
            let u = (now - s) / 0.62
            if u >= 1 {
                hopSince = nil
            } else {
                // squash (crouch) → up, stretched → land, squash → rest
                // 9 % of the size: the comb sits at the top of the 18 pt image, so a higher hop would clip it
                lift = u < 0.18 ? 0 : u < 0.72 ? 0.09 * CGFloat(sin(.pi * (u - 0.18) / 0.54)) : 0
                squash = u < 0.18 ? 0.12 * CGFloat(sin(.pi * u / 0.36)) : u < 0.72 ? -0.06 * CGFloat(sin(.pi * (u - 0.18) / 0.54))
                    : 0.08 * CGFloat(sin(.pi * (u - 0.72) / 0.28))
            }
        }
        guard moving else { run(); return }
        // quantised, so a few dozen images cover every frame
        let q = { (v: CGFloat) in (v * 50).rounded() / 50 }
        let key = "\(q(angle))|\(q(lift))|\(q(squash))"
        let img = cache[key] ?? {
            let i = GlyphMotion.image(.blurt, size: size, angle: q(angle), pivot: Self.pivot, lift: q(lift), squash: q(squash))
            i.accessibilityDescription = T("app.name")
            cache[key] = i
            return i
        }()
        current = img
        onFrame?(img)
    }
}

extension MenuGlyph {
    /// Self-test (`menuglyph DIR`): the status item's images as the menu bar shows them — the plain icon, the listening
    /// tilt at its peak and the hop at its top — tinted like a template image (black on a light menu bar, white on a
    /// dark one), at 1x and 2x. Writes menuglyph-<pose>-<light|dark>@<n>x.png; returns the file names.
    static func renderPoses(to dir: URL) -> [String] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let poses: [(String, NSImage)] = [
            ("rest", App.makeMenuIcon()),
            ("listen", GlyphMotion.image(.blurt, size: 18, angle: 0.21, pivot: pivot)),
            ("hop", GlyphMotion.image(.blurt, size: 18, lift: 0.09, squash: -0.06)),
        ]
        var names: [String] = []
        for (pose, img) in poses {
            for (look, tint) in [("light", NSColor.black), ("dark", NSColor.white)] {
                for scale in [1, 2] {
                    let px = 18 * scale
                    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                     bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                    rep.size = NSSize(width: 18, height: 18)          // 18 pt at `scale` pixels per point
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    let r = NSRect(x: 0, y: 0, width: 18, height: 18)
                    img.draw(in: r)
                    tint.set()
                    r.fill(using: .sourceIn)                           // a template image takes the menu bar's colour
                    NSGraphicsContext.restoreGraphicsState()
                    let name = "menuglyph-\(pose)-\(look)@\(scale)x.png"
                    if let d = rep.representation(using: .png, properties: [:]) {
                        try? d.write(to: dir.appendingPathComponent(name))
                        names.append(name)
                    }
                }
            }
        }
        return names
    }
}
