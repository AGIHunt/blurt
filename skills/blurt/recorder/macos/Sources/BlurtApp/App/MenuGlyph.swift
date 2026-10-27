// The menu-bar Peep: the native template glyph (22 × 18 pt, black + alpha, tinted by macOS like every other menu-bar icon),
// moving a little with what Blurt does. The frames are the Peep release package's glyph frames, projected from the same
// 3D model as the clay renders and snapped to the pixel grid (Resources/Peep/glyph-<state>.png @2x, -@1x; peep.json):
//
//   idle       at rest; a blink every few seconds (only the blink's frames, then rest)
//   talking    dictation listening: the beak opens with the voice level (the frame whose opening is nearest it)
//   listening  a voice note, the countdown before a take: eye wide, swelling
//   thinking   dictation transcribing or polishing, captures being organised: the eye looks round (15 fps)
//   done       one quick peep and a hop (sent, saved, a batch organised, an item fixed); a one-shot over the rest
//   error      a head shake and a droop (a job or a dictation that failed); a one-shot
//
// The status item can only show an image, so this swaps images — only while something moves. Every frame is the same
// 22 × 18 pt canvas (the hop stays inside it), so nothing beside it ever shifts. Reduce Motion: no timer; a state
// that lasts shows its still frame (listening, talking, thinking), the one-shots and the blink don't play. The same
// still frame while the island shows Peep in its ear (`held`): one Peep moves at a time — the one by the notch — and
// the status item, redrawn in every menu bar, costs more per frame than the island.
// BlurtCore PeepGlyphMode decides the state; MenuGlyph.sync() reads the app (dictation, voice note, countdown, the
// island's organising) — called when any of them changes.
import AppKit
import BlurtCore

final class MenuGlyph {
    static let shared = MenuGlyph()
    /// What the status item shows right now (nil = the rest icon).
    private(set) var current: NSImage?
    var onFrame: ((NSImage?) -> Void)?

    /// The glyph's canvas, pt: 22 × 18 (wider than tall, so the body can be as tall as its neighbours and the beak
    /// still has room), from peep.json.
    static var size: CGSize { PeepSprites.shared.glyphSize }

    /// v0.8 betas had a colour menu-bar hen behind Settings → General (app.menu_icon_color, before that
    /// app.menu_icon_mono). The glyph is monochrome only, so the old keys just go.
    static func migrateSetting() {
        for k in ["app.menu_icon_mono", "app.menu_icon_color"] where Config.shared[k] != nil { Config.shared.set(k, nil) }
    }

    /// The island shows Peep in its ear (Island.updateEars): a state that lasts holds its still frame here.
    var held = false { didSet { if held != oldValue { run() } } }

    /// The countdown before a take is up (CountdownWindow): Peep listens.
    var countdown = false { didSet { if countdown != oldValue { sync() } } }

    private(set) var mode: PeepGlyphMode = .idle
    private var modeSince: CFTimeInterval = 0
    private var oneShot: (state: PeepState, since: CFTimeInterval)?
    private var blinkSince: CFTimeInterval?
    private var nextBlink: CFTimeInterval = CACurrentMediaTime() + 4
    private var level: Double = 0
    private var lastTick: CFTimeInterval = 0
    private var timer: Timer?
    private var blinkTimer: Timer?
    private var shown: String?
    private var frames: [String: NSImage] = [:]

    private init() {}

    /// Tests (`menupeep STATE`): the glyph held in a state, the voice made up (Island.testVoice); nil = the app's own.
    var testMode: PeepGlyphMode? { didSet { mode = .idle; sync() } }

    /// Re-reads what the app is doing; cheap, so anything that changes it calls this.
    func sync() {
        let d = Dictation.shared
        let m = testMode ?? PeepGlyphMode.from(dictating: d.phase == .listening && d.micLive,
                                   voiceNote: VoiceInput.shared.active, countdown: countdown,
                                   transcribing: d.phase == .transcribing || d.phase == .polishing,
                                   organizing: AppEnvironment.island != nil && island.organizing)
        guard m != mode else { return }
        mode = m
        modeSince = CACurrentMediaTime()
        level = 0
        run()
    }

    /// One quick peep and a hop: something is done (sent, saved, sorted, fixed).
    func done() { play(.done) }
    /// The done moment's old name (callers that hop).
    func hop() { done() }
    /// A head shake and a droop: something really failed (never a cancel).
    func error() { play(.error) }

    private func play(_ s: PeepState) {
        guard !reduceMotion, PeepSprites.shared.glyph[s] != nil else { return }
        oneShot = (s, CACurrentMediaTime())
        run()
    }

    private var moving: Bool { oneShot != nil || blinkSince != nil || (mode != .idle && !reduceMotion && !held) }

    private func run() {
        scheduleBlink()
        if !moving {
            timer?.invalidate(); timer = nil
            show(mode == .idle ? nil : still(mode.state))
            return
        }
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    /// The idle blink: every 4–9 s while nothing else moves (never with Reduce Motion).
    private func scheduleBlink() {
        blinkTimer?.invalidate(); blinkTimer = nil
        guard mode == .idle, oneShot == nil, blinkSince == nil, !reduceMotion, PeepSprites.shared.glyphBlink != nil else { return }
        let wait = Double.random(in: 4...9)
        let t = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            guard let self = self, self.mode == .idle, self.oneShot == nil else { return }
            self.blinkSince = CACurrentMediaTime()
            self.run()
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        blinkTimer = t
    }

    private func tick() {
        if reduceMotion { oneShot = nil; blinkSince = nil; timer?.invalidate(); timer = nil; run(); return }
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now
        let lib = PeepSprites.shared
        if let o = oneShot, let k = lib.glyph[o.state] {
            let t = now - o.since
            if t < k.duration { return show(frame(o.state, PeepPlayback.frame(at: t, clip: k, loops: false))) }
            oneShot = nil
        }
        if held, mode != .idle { timer?.invalidate(); timer = nil; return show(still(mode.state)) }
        switch mode {
        case .idle:
            if let b = blinkSince, let r = lib.glyphBlink, let k = lib.glyph[.idle] {
                let i = r.lowerBound + Int((now - b) * k.fps)
                if i <= r.upperBound { return show(frame(.idle, i)) }
                blinkSince = nil
            }
            timer?.invalidate(); timer = nil
            show(nil)
            scheduleBlink()
        case .talking:
            guard let k = lib.glyph[.talking] else { return }
            let heard = testMode == nil ? Dictation.shared.levels.last ?? 0 : Island.testVoice(now - modeSince)
            level = PeepPlayback.smooth(level, toward: Double(heard), dt: dt)
            show(frame(.talking, PeepPlayback.talkingFrame(level: level, clip: k)))
        case .listening, .thinking:
            let s = mode.state
            guard let k = lib.glyph[s] else { return }
            // thinking can last minutes (organising): every other frame is plenty for an eye that looks round
            let t = now - modeSince
            let i = PeepPlayback.frame(at: t, clip: k, loops: true)
            show(frame(s, mode == .thinking ? i - i % 2 : i))
        }
    }

    private func show(_ img: NSImage?) {
        let key = img?.name()
        guard key != shown else { return }
        shown = key
        current = img
        onFrame?(img)
    }

    private func still(_ s: PeepState) -> NSImage? {
        guard let k = PeepSprites.shared.glyph[s] else { return nil }
        return frame(s, PeepPlayback.stillFrame(s, clip: k))
    }

    /// Frame `i` of a glyph clip as an 18 pt template image with its @1x and @2x pixels (cached).
    func frame(_ s: PeepState, _ i: Int) -> NSImage? {
        let key = "peep-glyph-\(s.rawValue)-\(i)"
        if let f = frames[key] { return f }
        guard let img = MenuGlyph.image(s, i) else { return nil }
        img.setName(key)
        img.accessibilityDescription = T("app.name")
        frames[key] = img
        return img
    }

    static func image(_ s: PeepState, _ i: Int, template: Bool = true) -> NSImage? {
        let lib = PeepSprites.shared
        guard let k = lib.glyph[s], let s2 = lib.sheet("glyph-\(s.rawValue).png") else { return nil }
        let n = max(0, min(k.frames - 1, i))
        let pt = size
        let img = NSImage(size: pt)
        for (sheet, scale) in [(lib.sheet("glyph-\(s.rawValue)@1x.png"), 1), (s2, 2)] {
            let w = Int(pt.width) * scale, h = Int(pt.height) * scale
            guard let sh = sheet, let c = sh.cropping(to: CGRect(x: n * w, y: 0, width: w, height: h)) else { continue }
            let rep = NSBitmapImageRep(cgImage: c)
            rep.size = pt
            img.addRepresentation(rep)
        }
        img.isTemplate = template
        return img.representations.isEmpty ? nil : img
    }

    /// The rest glyph (idle, frame 0), in one colour, `height` pt tall (the island's toasts lead with it in white).
    static func tinted(_ color: NSColor, size height: CGFloat) -> NSImage {
        let base = image(.idle, 0) ?? BlurtIcon.blurt.image(size: size.height)
        let img = NSImage(size: NSSize(width: (height * size.width / size.height).rounded(), height: height), flipped: false) { r in
            base.draw(in: r)
            color.set()
            r.fill(using: .sourceIn)
            return true
        }
        return img
    }
}

extension MenuGlyph {
    /// Self-test (`menuglyph DIR`): the status item's images as the menu bar shows them, at 1x and 2x —
    ///   menuglyph-<state>-<light|dark>@<n>x.png   a strip of the state's frames (every third; the blink's for idle)
    ///                                             tinted like a template image (black on a light bar, white on a
    ///                                             dark one)
    ///   statusbutton-<aqua|dark>-<rest|open|talking>@<n>x.png
    ///                                             the real status button (image + a stand-in count of 3) drawn in that
    ///                                             appearance: at rest, highlighted (its menu open), and talking
    /// Returns the file names.
    @MainActor
    static func renderPoses(to dir: URL) -> [String] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var names: [String] = []
        func bitmap(_ size: NSSize, scale: Int, _ draw: () -> Void) -> NSBitmapImageRep? {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = size
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
        let lib = PeepSprites.shared
        for s in PeepState.allCases {
            guard let k = lib.glyph[s] else { continue }
            let picks: [Int] = s == .idle ? Array(lib.glyphBlink ?? 0...0) : Array(stride(from: 0, to: k.frames, by: 3))
            let imgs = picks.compactMap { image(s, $0) }
            let gap: CGFloat = 4
            let box = MenuGlyph.size
            let size = NSSize(width: CGFloat(imgs.count) * (box.width + gap), height: 22)
            for scale in [1, 2] {
                for (bar, tint) in [("light", NSColor.black), ("dark", NSColor.white)] {
                    write(bitmap(size, scale: scale) {
                        for (i, im) in imgs.enumerated() { im.draw(in: NSRect(x: CGFloat(i) * (box.width + gap), y: 2, width: box.width, height: box.height)) }
                        tint.set()
                        NSRect(origin: .zero, size: size).fill(using: .sourceIn)
                    }, "menuglyph-\(s.rawValue)-\(bar)@\(scale)x.png")
                }
            }
        }
        guard let app = NSApp.delegate as? App, let b = app.statusItem?.button else { return names }
        let savedAppearance = b.appearance
        MenuBadge.shared.testCount = 3
        defer {
            MenuBadge.shared.testCount = nil
            b.appearance = savedAppearance
            app.testMenuOpen(false)
        }
        for (name, appearance) in [("aqua", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for state in ["rest", "open", "talking"] {
                b.appearance = NSAppearance(named: appearance)
                app.testMenuOpen(state == "open")
                if state == "talking", let k = lib.glyph[.talking] { b.image = image(.talking, PeepPlayback.talkingFrame(level: 0.8, clip: k)) }
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
