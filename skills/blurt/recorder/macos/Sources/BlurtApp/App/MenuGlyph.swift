// The menu-bar hen moves a little, in code: while voice input listens it lifts its beak — the head tips back about the
// nape (`pivot`), as if about to shout — and it hops once when something is done (an item fixed / confirmed, a batch
// organised). The status item can only show an image, so this swaps images at 24 fps — only while it moves; Reduce
// Motion: it stays still (no timer, the plain icon).
//
// Which hen: the colour one (Icons/MenuHen.swift, brand direction A) in the `look` App picks for the bar, or — with
// Settings → General → "Monochrome menu-bar icon" (app.menu_icon_mono) — the template `blurt` glyph
// (assets/brand/glyph.svg). `look == nil` = the template glyph.
import AppKit
import BlurtCore

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

    /// The user prefers the monochrome template glyph (off by default).
    static var monochrome: Bool { Config.shared["app.menu_icon_mono"] as? Bool ?? false }

    /// The colour hen's look for the bar it is on; nil = the template glyph. Set by App before each refresh.
    var look: MenuHen.Look? = nil {
        didSet { if look != oldValue, moving { frame() } }
    }

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

    /// How high the hop goes (a fraction of the size): the comb is at the top of the image, so a higher hop would clip
    /// it — less for the colour hen, whose outline and rim sit closer to the edge.
    static func hopHeight(_ look: MenuHen.Look?) -> CGFloat { look == nil ? 0.09 : 0.04 }
    /// The colour hen rises this much (a fraction of the size) as it tips back.
    static let tiltLift: CGFloat = 0.035

    private func frame() {
        if reduceMotion { run(); return }      // turned on mid-move: back to the still icon
        let now = CACurrentMediaTime()
        var angle: CGFloat = 0, lift: CGFloat = 0, squash: CGFloat = 0
        if let s = tiltSince {
            // 0 → 12° beak up (counter-clockwise) → hold → 0 every 1.4 s, eased
            let u = (now - s).truncatingRemainder(dividingBy: 1.4) / 1.4
            let e = u < 0.35 ? Ease.inOutCubic(CGFloat(u / 0.35)) : u < 0.65 ? 1 : 1 - Ease.inOutCubic(CGFloat((u - 0.65) / 0.35))
            angle = 0.21 * e
            // the colour hen fills its 18 pt: tipping back would push the nape's feathers out of the bottom
            if look != nil { lift = MenuGlyph.tiltLift * e }
        }
        if let s = hopSince {
            let u = (now - s) / 0.62
            if u >= 1 {
                hopSince = nil
            } else {
                // squash (crouch) → up, stretched → land, squash → rest
                lift = u < 0.18 ? 0 : u < 0.72 ? MenuGlyph.hopHeight(look) * CGFloat(sin(.pi * (u - 0.18) / 0.54)) : 0
                squash = u < 0.18 ? 0.12 * CGFloat(sin(.pi * u / 0.36)) : u < 0.72 ? -0.06 * CGFloat(sin(.pi * (u - 0.18) / 0.54))
                    : 0.08 * CGFloat(sin(.pi * (u - 0.72) / 0.28))
            }
        }
        guard moving else { run(); return }
        // quantised, so a few dozen images cover every frame
        let q = { (v: CGFloat) in (v * 50).rounded() / 50 }
        let key = "\(look?.rawValue ?? "mono")|\(q(angle))|\(q(lift))|\(q(squash))"
        let img = cache[key] ?? {
            let i = MenuGlyph.pose(look, size: size, angle: q(angle), lift: q(lift), squash: q(squash))
            i.accessibilityDescription = T("app.name")
            cache[key] = i
            return i
        }()
        current = img
        onFrame?(img)
    }

    /// One frame: the template glyph or the colour hen, tilted / lifted / squashed.
    static func pose(_ look: MenuHen.Look?, size: CGFloat = 18, angle: CGFloat = 0, lift: CGFloat = 0, squash: CGFloat = 0) -> NSImage {
        guard let l = look else { return GlyphMotion.image(.blurt, size: size, angle: angle, pivot: pivot, lift: lift, squash: squash) }
        return GlyphMotion.image(size: size, angle: angle, pivot: pivot, lift: lift, squash: squash, template: false) { ctx, r in
            MenuHen.draw(in: ctx, rect: r, look: l)
        }
    }
}

extension MenuGlyph {
    /// Self-test (`menuglyph DIR`): the status item's images as the menu bar shows them, at 1x and 2x —
    ///   menuglyph-<pose>-<light|dark>@<n>x.png   the template glyph (rest / listen / hop), tinted like a template
    ///                                            image (black on a light bar, white on a dark one)
    ///   menuhen-<pose>-<light|dark>@<n>x.png     the colour hen in each look, transparent
    ///   statusbutton-<aqua|dark>-<rest|open|mono>@<n>x.png
    ///                                            the real status button (image + a stand-in count of 3) drawn in that
    ///                                            appearance, at rest, with its menu open (the highlight's look) and
    ///                                            monochrome — transparent, for a contact sheet on fake menu bars
    /// Returns the file names.
    @MainActor
    static func renderPoses(to dir: URL) -> [String] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var names: [String] = []
        func bitmap(_ size: NSSize, scale: Int, _ draw: () -> Void) -> NSBitmapImageRep? {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = size                                       // `size` pt at `scale` pixels per point
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            draw()
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        func write(_ rep: NSBitmapImageRep?, _ name: String) {
            if let d = rep?.representation(using: .png, properties: [:]), (try? d.write(to: dir.appendingPathComponent(name))) != nil {
                names.append(name)
            }
        }
        let r = NSRect(x: 0, y: 0, width: 18, height: 18)
        let looks: [MenuHen.Look?] = [nil, .light, .dark]
        for look in looks {
            let poses: [(String, NSImage)] = [
                ("rest", look == nil ? App.makeMenuIcon() : MenuHen.image(size: 18, look: look!)),
                ("listen", pose(look, angle: 0.21, lift: look == nil ? 0 : tiltLift)),
                ("hop", pose(look, lift: hopHeight(look), squash: -0.06)),
            ]
            for (name, img) in poses {
                for scale in [1, 2] {
                    if let l = look {
                        write(bitmap(r.size, scale: scale) { img.draw(in: r) }, "menuhen-\(name)-\(l.rawValue)@\(scale)x.png")
                        continue
                    }
                    for (bar, tint) in [("light", NSColor.black), ("dark", NSColor.white)] {
                        write(bitmap(r.size, scale: scale) {
                            img.draw(in: r)
                            tint.set()
                            r.fill(using: .sourceIn)                  // a template image takes the menu bar's colour
                        }, "menuglyph-\(name)-\(bar)@\(scale)x.png")
                    }
                }
            }
        }
        // the real status button, in each appearance and state, with a count
        guard let app = NSApp.delegate as? App, let b = app.statusItem?.button else { return names }
        let savedAppearance = b.appearance, savedMono = Config.shared["app.menu_icon_mono"]
        MenuBadge.shared.testCount = 3
        defer {
            MenuBadge.shared.testCount = nil
            Config.shared.set("app.menu_icon_mono", savedMono)
            b.appearance = savedAppearance
            app.testMenuOpen(false)
        }
        for (name, appearance) in [("aqua", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for state in ["rest", "open", "mono"] {
                b.appearance = NSAppearance(named: appearance)
                Config.shared.set("app.menu_icon_mono", state == "mono" ? true : nil)
                app.testMenuOpen(state == "open")             // refreshes the button
                let size = NSSize(width: ceil(b.intrinsicContentSize.width), height: max(22, b.bounds.height))
                for scale in [1, 2] {
                    let frame = b.frame
                    b.setFrameSize(size)
                    let rep = bitmap(size, scale: scale) {
                        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                            b.displayIgnoringOpacity(NSRect(origin: .zero, size: size), in: NSGraphicsContext.current!)
                        }
                    }
                    b.frame = frame
                    write(rep, "statusbutton-\(name)-\(state)@\(scale)x.png")
                }
            }
        }
        return names
    }
}
