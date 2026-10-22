// The menu-bar chick (the 4A line glyph, `blurt`) moves a little, in code: it tilts its head while voice input listens,
// and hops once when something is done (an item fixed / confirmed, a batch organised). The status item can only show
// an image, so this swaps template images at 24 fps — only while it moves; Reduce Motion: it stays still.
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
        let now = CACurrentMediaTime()
        var angle: CGFloat = 0, lift: CGFloat = 0, squash: CGFloat = 0
        if let s = tiltSince {
            // 0 → 12° → hold → 0 every 1.4 s, eased
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
                lift = u < 0.18 ? 0 : u < 0.72 ? 0.2 * CGFloat(sin(.pi * (u - 0.18) / 0.54)) : 0
                squash = u < 0.18 ? 0.12 * CGFloat(sin(.pi * u / 0.36)) : u < 0.72 ? -0.06 * CGFloat(sin(.pi * (u - 0.18) / 0.54))
                    : 0.08 * CGFloat(sin(.pi * (u - 0.72) / 0.28))
            }
        }
        guard moving else { run(); return }
        // quantised, so a few dozen images cover every frame
        let q = { (v: CGFloat) in (v * 50).rounded() / 50 }
        let key = "\(q(angle))|\(q(lift))|\(q(squash))"
        let img = cache[key] ?? {
            let i = GlyphMotion.image(.blurt, size: size, angle: q(angle), lift: q(lift), squash: q(squash))
            i.accessibilityDescription = T("app.name")
            cache[key] = i
            return i
        }()
        current = img
        onFrame?(img)
    }
}
