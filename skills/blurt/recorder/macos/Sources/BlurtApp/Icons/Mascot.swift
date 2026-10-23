// The colour mascot (the 1A round chick) for moments: done, hatching, listening, thinking, onboarding, empty states.
// Frame animations drawn with an image model and cut into strips by assets/mascot/tools/cut.py; this plays them.
//
//   Resources/Mascot/<sheet>.webp   one horizontal strip of 160 × 160 px frames (2× pixels: up to 80 pt on screen)
//   Resources/Mascot/mascot.json    clips: sheet, loop, still, timeline [[frame, ticks]…] at `fps`
//
//   let v = MascotView(clip: .peck, size: 44); v.play(.peck) { … }   AppKit
//   let l = MascotLayer(); l.play(.wobble)                            layer-built UIs (the island's ears)
//   MascotImage(clip: .idle, size: 64)                                SwiftUI
//
// One shared 12 fps timer drives every playing layer and stops when none plays. Frames are set as the layer's model
// `contents` (no CAAnimation), so offscreen renders (FrameCapture, `mascotframes`) see the same frame the screen does.
// Reduce Motion: the clip's still frame, no movement; a one-shot's completion still runs.
// The line glyphs (BlurtIcon.chicken, the menu-bar chick .blurt) move in code instead: see GlyphMotion below.
import AppKit
import BlurtCore
import SwiftUI
import UserNotifications

enum MascotClip: String, CaseIterable {
    case idle, listening, thinking, wobble, hatching, happy, peck
}

final class MascotLibrary {
    static let shared = MascotLibrary()

    struct Clip {
        let frames: [CGImage]
        let ticks: [Int]          // the timeline, one frame index per tick
        let loop: Bool
        let still: Int
        var duration: Double { Double(ticks.count) / MascotLibrary.shared.fps }
        func frame(atTick t: Int) -> CGImage? {
            guard !frames.isEmpty, !ticks.isEmpty else { return nil }
            let i = loop ? ticks[t % ticks.count] : ticks[min(t, ticks.count - 1)]
            return frames[min(i, frames.count - 1)]
        }
        var stillFrame: CGImage? { frames.isEmpty ? nil : frames[min(still, frames.count - 1)] }
    }

    private(set) var fps: Double = 12
    private(set) var pixelSize: Int = 160
    private var clips: [MascotClip: Clip] = [:]
    private var loaded = false

    /// Blurt.app/Contents/Resources/Mascot, or the source tree for a plain `swift build` run ($BLURT_MASCOT_DIR first).
    static var directory: URL? {
        var dirs: [URL] = []
        if let d = ProcessInfo.processInfo.environment["BLURT_MASCOT_DIR"] { dirs.append(URL(fileURLWithPath: d)) }
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("Mascot")) }
        dirs.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Mascot"))
        return dirs.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("mascot.json").path) }
    }

    private let lock = NSLock()

    func clip(_ c: MascotClip) -> Clip? {
        lock.lock()
        defer { lock.unlock() }
        load()
        return clips[c]
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let dir = MascotLibrary.directory,
              let data = try? Data(contentsOf: dir.appendingPathComponent("mascot.json")),
              let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cs = m["clips"] as? [String: [String: Any]] else { return }
        fps = m["fps"] as? Double ?? 12
        pixelSize = m["size"] as? Int ?? 160
        var strips: [String: [CGImage]] = [:]
        for (name, c) in cs {
            guard let clip = MascotClip(rawValue: name), let sheet = c["sheet"] as? String else { continue }
            if strips[sheet] == nil { strips[sheet] = loadStrip(dir.appendingPathComponent("\(sheet).webp")) }
            var ticks: [Int] = []
            for pair in c["timeline"] as? [[Int]] ?? [] where pair.count == 2 {
                ticks += Array(repeating: pair[0], count: max(1, pair[1]))
            }
            clips[clip] = Clip(frames: strips[sheet] ?? [], ticks: ticks, loop: c["loop"] as? Bool ?? false, still: c["still"] as? Int ?? 0)
        }
    }

    private func loadStrip(_ url: URL) -> [CGImage] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let strip = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return [] }
        let s = strip.height
        return (0..<(strip.width / max(1, s))).compactMap { strip.cropping(to: CGRect(x: $0 * s, y: 0, width: s, height: s)) }
    }

    /// The clip's still frame as a notification attachment (the system moves the file away, so a fresh copy each time).
    func attachment(_ c: MascotClip) -> [UNNotificationAttachment] {
        guard let img = clip(c)?.stillFrame else { return [] }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-mascot-\(c.rawValue)-\(UUID().uuidString).png")
        guard let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil,
              let a = try? UNNotificationAttachment(identifier: "mascot", url: url) else { return [] }
        return [a]
    }

    /// The clip's frames in timeline order (docs / tests turn them into GIFs).
    func timelineFrames(_ c: MascotClip) -> [CGImage] {
        guard let clip = clip(c) else { return [] }
        return clip.ticks.indices.compactMap { clip.frame(atTick: $0) }
    }
}

/// A layer that plays one clip at a time.
final class MascotLayer: CALayer {
    private(set) var clip: MascotClip?
    private var tick = 0
    private var done: (() -> Void)?
    var isPlaying: Bool { MascotDriver.shared.has(self) }

    override init() {
        super.init()
        contentsGravity = .resizeAspect
        contentsScale = 2
        actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    /// Plays `c` from its first tick (a loop runs until stop / another play). `completion` after a one-shot's last frame.
    func play(_ c: MascotClip, completion: (() -> Void)? = nil) {
        clip = c
        tick = 0
        done = completion
        guard let cl = MascotLibrary.shared.clip(c) else { completion?(); return }
        if reduceMotion {
            set(cl.stillFrame)
            MascotDriver.shared.remove(self)
            if let d = done { done = nil; DispatchQueue.main.async(execute: d) }
            return
        }
        set(cl.frame(atTick: 0))
        MascotDriver.shared.add(self)
    }

    /// Shows one frame of a clip, still (`frame` nil = the clip's still frame).
    func show(_ c: MascotClip, frame: Int? = nil) {
        clip = c
        MascotDriver.shared.remove(self)
        guard let cl = MascotLibrary.shared.clip(c) else { return }
        set(frame.map { cl.frames[min(max(0, $0), cl.frames.count - 1)] } ?? cl.stillFrame)
    }

    func stop() { MascotDriver.shared.remove(self); done = nil }

    fileprivate func step() -> Bool {
        guard let c = clip, let cl = MascotLibrary.shared.clip(c) else { return false }
        tick += 1
        if !cl.loop && tick >= cl.ticks.count {
            set(cl.frame(atTick: cl.ticks.count - 1))
            if let d = done { done = nil; d() }
            return false
        }
        set(cl.frame(atTick: tick))
        return true
    }

    private func set(_ img: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contents = img
        CATransaction.commit()
    }
}

/// One timer for every playing mascot, only while one plays.
private final class MascotDriver {
    static let shared = MascotDriver()
    private var layers = NSHashTable<MascotLayer>.weakObjects()
    private var timer: Timer?

    func has(_ l: MascotLayer) -> Bool { layers.contains(l) }
    func add(_ l: MascotLayer) {
        layers.add(l)
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1 / MascotLibrary.shared.fps, repeats: true) { [weak self] _ in self?.fire() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    func remove(_ l: MascotLayer) {
        layers.remove(l)
        if layers.count == 0 { timer?.invalidate(); timer = nil }
    }
    private func fire() {
        for l in layers.allObjects where !l.step() { layers.remove(l) }
        if layers.count == 0 { timer?.invalidate(); timer = nil }
    }
}

/// AppKit host for a MascotLayer (decoration: hidden from VoiceOver unless given a label).
final class MascotView: NSView {
    let mascot = MascotLayer()

    init(clip: MascotClip? = nil, size: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.addSublayer(mascot)
        mascot.frame = bounds
        if let c = clip { show(c) }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { frame.size }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mascot.frame = bounds
        mascot.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    func play(_ c: MascotClip, completion: (() -> Void)? = nil) { mascot.play(c, completion: completion) }
    func show(_ c: MascotClip, frame: Int? = nil) { mascot.show(c, frame: frame) }
    func stop() { mascot.stop() }
    override func viewDidMoveToWindow() { if window == nil { mascot.stop() } }
}

/// SwiftUI: plays `clip` (a one-shot then rests on its last frame, or goes on with `then`); a new `clip` plays again.
struct MascotImage: NSViewRepresentable {
    var clip: MascotClip
    var then: MascotClip?
    var size: CGFloat

    final class Coordinator { var requested: MascotClip? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MascotView {
        let v = MascotView(size: size)
        v.setContentHuggingPriority(.required, for: .horizontal)
        v.setContentHuggingPriority(.required, for: .vertical)
        return v
    }
    func updateNSView(_ v: MascotView, context: Context) {
        guard context.coordinator.requested != clip else { return }
        context.coordinator.requested = clip
        let next = then
        v.play(clip) { [weak v] in if let n = next { v?.play(n) } }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MascotView, context: Context) -> CGSize? { CGSize(width: size, height: size) }
}

// MARK: - 4A line glyph motion (procedural; the glyph is one vector, so no frames)

enum GlyphMotion {
    /// A gentle head tilt, repeating (listening): rotates about the glyph's foot.
    static func tilt(_ layer: CALayer) {
        guard !reduceMotion else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        a.values = [0, 0.2, 0.2, 0]
        a.keyTimes = [0, 0.35, 0.65, 1]
        a.duration = 1.4
        a.repeatCount = .infinity
        a.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
        layer.add(a, forKey: "blurt.tilt")
    }

    /// One small hop with squash and stretch (done).
    static func hop(_ layer: CALayer, height: CGFloat? = nil) {
        guard !reduceMotion else { return }
        let h = height ?? layer.bounds.height * 0.28
        let y = CAKeyframeAnimation(keyPath: "transform.translation.y")
        y.values = [0, 0, h, 0, 0]
        let sx = CAKeyframeAnimation(keyPath: "transform.scale.x")
        sx.values = [1, 1.12, 0.94, 1.08, 1]
        let sy = CAKeyframeAnimation(keyPath: "transform.scale.y")
        sy.values = [1, 0.86, 1.08, 0.92, 1]
        let g = CAAnimationGroup()
        for a in [y, sx, sy] { a.keyTimes = [0, 0.18, 0.45, 0.72, 1] }
        g.animations = [y, sx, sy]
        g.duration = 0.62
        g.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.7, 0.4, 1)
        layer.add(g, forKey: "blurt.hop")
    }

    static func stop(_ layer: CALayer) {
        layer.removeAnimation(forKey: "blurt.tilt")
        layer.removeAnimation(forKey: "blurt.hop")
    }

    /// For places that can only take an image (the menu-bar button): the glyph drawn tilted by `angle` (radians,
    /// positive = counter-clockwise, so a right-facing head lifts its beak) about `pivot` (unit coordinates of the
    /// image, y up from the bottom), and hopping: lifted by `lift` (fraction of its size) and squashed by `squash`
    /// about its foot. A template image.
    static func image(_ icon: BlurtIcon, size: CGFloat, angle: CGFloat = 0, pivot: CGPoint = CGPoint(x: 0.5, y: 0.1),
                      lift: CGFloat = 0, squash: CGFloat = 0) -> NSImage {
        image(size: size, angle: angle, pivot: pivot, lift: lift, squash: squash, template: true) { ctx, r in
            icon.draw(in: ctx, rect: r, color: NSColor.black.cgColor)
        }
    }

    /// The same motion for any drawing (the menu-bar chick, layer by layer): `draw` paints the still picture into `rect` of a
    /// y-up context; `template` = the result tints like a template image.
    static func image(size: CGFloat, angle: CGFloat = 0, pivot: CGPoint = CGPoint(x: 0.5, y: 0.1), lift: CGFloat = 0,
                      squash: CGFloat = 0, template: Bool, draw: @escaping (CGContext, CGRect) -> Void) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let foot = r.minY + r.height * 0.1
            ctx.translateBy(x: r.midX, y: foot + r.height * lift)
            ctx.scaleBy(x: 1 + squash, y: 1 - squash)
            ctx.translateBy(x: -r.midX, y: -foot)
            let p = CGPoint(x: r.minX + r.width * pivot.x, y: r.minY + r.height * pivot.y)
            ctx.translateBy(x: p.x, y: p.y)
            ctx.rotate(by: angle)
            ctx.translateBy(x: -p.x, y: -p.y)
            draw(ctx, r)
            return true
        }
        img.isTemplate = template
        return img
    }
}
