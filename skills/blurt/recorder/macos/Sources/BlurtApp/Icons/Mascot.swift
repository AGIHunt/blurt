// The mascot is Peep, the brand character: a soft 3D clay chick (a gradient sphere, two glossy eyes, a dark slate beak)
// rendered in Blender from one model (blurt-media/logo/peep/peep.py). Nothing here draws it: the frames come from the
// Peep release package as sprite sheets (assets/brand/import_peep.py → Resources/Peep/<set>-<state>.webp, peep.json),
// in two light sets — `paper` for light backgrounds, `dark` for the notch and dark mode (its beak keeps an edge on
// black). The clips (BlurtCore PeepState): idle (breath and a blink), hello, listening, talking (the beak; driven by the
// voice level where there is one), thinking (the eye looks round), done (a peep and a hop), error (a shake, a droop).
//
//   let v = MascotView(clip: .done, size: 44, backdrop: .dark); v.play(.done) { … }   AppKit
//   let l = MascotLayer(); l.backdrop = .dark; l.play(.thinking)                     layer-built UIs (the island's ears)
//   l.level = { Dictation.shared.levels.last ?? 0 }; l.play(.talking)                 talking with the voice
//   MascotImage(clip: .hello, then: .idle, size: 108, backdrop: .light)                SwiftUI
//
// `backdrop`: what Peep sits on — the island is always dark, the onboarding field reads as light; `.auto` follows the
// view's appearance. The layer's square is Peep at rest (body and beak, a little air); the frames reach past it on
// every side by the sheet's bleed (the hop, the shake, the contact shadow), on a sublayer that is not clipped.
//
// One shared 30 fps timer drives every playing layer and stops when none plays. Each tick puts the clip's frame at
// that moment into the sublayer's contents (a crop of the decoded sheet: no drawing), so offscreen renders
// (FrameCapture, `mascotframes`) see the frame the screen does. Reduce Motion: the clip's still frame, no movement; a
// one-shot's completion still runs. Sheets decode on first use and live in a cache the system may empty.
import AppKit
import BlurtCore
import ImageIO
import SwiftUI
import UserNotifications

typealias MascotClip = PeepState

/// What the mascot sits on.
enum MascotBackdrop {
    case auto, light, dark
}

/// The frames: peep.json and the sheets, found in the app bundle (Contents/Resources/Peep) or, for a plain
/// `swift build` run, next to the sources.
final class PeepSprites {
    static let shared = PeepSprites()

    struct Sheet {
        let square: CGFloat        // px of the chick's square in a cell
        let cell: CGFloat          // px of a cell
        let cols: Int
        let clips: [PeepState: PeepClip]
        var bleed: CGFloat { (cell - square) / 2 / square }
    }

    let dir: URL?
    private(set) var sets: [String: Sheet] = [:]
    private(set) var glyph: [PeepState: PeepClip] = [:]
    private(set) var glyphBlink: ClosedRange<Int>?
    private(set) var stillDone = 26
    private let cache = NSCache<NSString, CGImage>()

    private init() {
        var roots: [URL] = []
        if let r = Bundle.main.resourceURL { roots.append(r.appendingPathComponent("Peep")) }
        // Sources/BlurtApp/Icons/Mascot.swift → Sources/BlurtApp/Resources/Peep
        roots.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Peep"))
        dir = roots.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("peep.json").path) }
        cache.totalCostLimit = 64 << 20
        guard let d = dir, let data = try? Data(contentsOf: d.appendingPathComponent("peep.json")),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        func clips(_ o: Any?) -> [PeepState: PeepClip] {
            var out: [PeepState: PeepClip] = [:]
            for (k, v) in o as? [String: [String: Any]] ?? [:] {
                guard let s = PeepState(rawValue: k) else { continue }
                out[s] = PeepClip(frames: v["frames"] as? Int ?? 1, fps: v["fps"] as? Double ?? 30,
                                  open: (v["open"] as? [NSNumber])?.map(\.doubleValue) ?? [])
            }
            return out
        }
        for (name, v) in j["sets"] as? [String: [String: Any]] ?? [:] {
            sets[name] = Sheet(square: CGFloat(v["square"] as? Double ?? 160), cell: CGFloat(v["cell"] as? Double ?? 192),
                               cols: v["cols"] as? Int ?? 10, clips: clips(v["clips"]))
        }
        let g = j["glyph"] as? [String: Any]
        glyph = clips(g?["clips"])
        if let b = ((g?["clips"] as? [String: Any])?["idle"] as? [String: Any])?["blink"] as? [Int], b.count == 2, b[0] <= b[1] {
            glyphBlink = b[0]...b[1]
        }
        if let s = (j["stills"] as? [String: Any])?["done"] as? Int { stillDone = s }
    }

    /// The set for a backdrop: paper on light when it has the clip, else dark (the notch's, and dark mode's).
    func set(dark: Bool, clip: PeepState) -> String {
        !dark && sets["paper"]?.clips[clip] != nil ? "paper" : "dark"
    }

    func clip(_ c: PeepState, set: String = "dark") -> PeepClip? { sets[set]?.clips[c] }

    /// One frame of a clip as a CGImage (`cell` px square, the chick's square centred in it).
    func frame(_ c: PeepState, set name: String, index: Int) -> CGImage? {
        guard let s = sets[name], let clip = s.clips[c], let sheet = sheet("\(name)-\(c.rawValue).webp") else { return nil }
        let i = max(0, min(clip.frames - 1, index))
        let r = CGRect(x: CGFloat(i % s.cols) * s.cell, y: CGFloat(i / s.cols) * s.cell, width: s.cell, height: s.cell)
        return sheet.cropping(to: r)
    }

    /// A strip of the package (decoded once; the cache may let it go).
    func sheet(_ file: String) -> CGImage? {
        if let c = cache.object(forKey: file as NSString) { return c }
        guard let d = dir, let src = CGImageSourceCreateWithURL(d.appendingPathComponent(file) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        cache.setObject(img, forKey: file as NSString, cost: img.bytesPerRow * img.height)
        return img
    }
}

/// The clips' timing and pictures of them (notifications, About, docs, tests).
final class MascotLibrary {
    static let shared = MascotLibrary()

    struct Clip {
        let duration: Double
        let loop: Bool
        /// the moment shown with Reduce Motion (and in pictures of the clip), in seconds
        let still: Double
    }

    func clip(_ c: MascotClip) -> Clip? {
        guard let k = PeepSprites.shared.clip(c) else { return nil }
        return Clip(duration: k.duration, loop: c.loops, still: Double(PeepPlayback.stillFrame(c, clip: k)) / k.fps)
    }

    /// One moment of a clip as an image `points` square at `scale` (`time` nil = the still moment; the done clip's
    /// still is its happy closed eye). `backdrop` fills behind it (nil = transparent). `bleed`: extra room on every
    /// side, as a fraction of `points` (the image grows, Peep keeps its size), for the moments that reach past the
    /// square; at most the sheet's own.
    func image(_ c: MascotClip, at time: Double? = nil, points: CGFloat, scale: CGFloat = 2, dark: Bool = false,
               backdrop: CGColor? = nil, bleed: CGFloat = 0) -> CGImage? {
        let lib = PeepSprites.shared
        let set = lib.set(dark: dark, clip: c)
        guard let sheet = lib.sets[set], let k = sheet.clips[c] else { return nil }
        let index = time.map { PeepPlayback.frame(at: $0, clip: k, loops: c.loops) }
            ?? (c == .done ? min(k.frames - 1, lib.stillDone) : PeepPlayback.stillFrame(c, clip: k))
        guard let f = lib.frame(c, set: set, index: index) else { return nil }
        let px = Int((points * scale).rounded()), b = min(bleed, sheet.bleed), pad = Int((points * scale * b).rounded())
        guard px > 0, let ctx = CGContext(data: nil, width: px + 2 * pad, height: px + 2 * pad, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let bg = backdrop { ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: px + 2 * pad, height: px + 2 * pad)) }
        ctx.interpolationQuality = .high
        let full = CGFloat(px) * (1 + 2 * sheet.bleed)
        ctx.draw(f, in: CGRect(x: CGFloat(pad) + CGFloat(px) / 2 - full / 2, y: CGFloat(pad) + CGFloat(px) / 2 - full / 2, width: full, height: full))
        return ctx.makeImage()
    }

    /// The done pose (the happy closed eye after the peep) as a notification picture, in the set for the current
    /// appearance (the system moves the file away, so a fresh copy each time).
    func attachment(_ c: MascotClip = .done) -> [UNNotificationAttachment] {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard let img = image(c, points: 80, dark: dark, bleed: 0.06) else { return [] }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-peep-\(c.rawValue)-\(UUID().uuidString).png")
        guard let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil,
              let a = try? UNNotificationAttachment(identifier: "peep", url: url) else { return [] }
        return [a]
    }

    /// The clip sampled at `fps`, in order (docs / tests turn them into GIFs and contact sheets).
    func timelineFrames(_ c: MascotClip, points: CGFloat = 80, scale: CGFloat = 2, fps: Double = 12, dark: Bool = false,
                        backdrop: CGColor? = nil) -> [CGImage] {
        guard let t = clip(c) else { return [] }
        let n = max(1, Int((t.duration * fps).rounded()))
        return (0..<n + (t.loop ? 0 : 1)).compactMap {
            image(c, at: Double($0) / fps, points: points, scale: scale, dark: dark, backdrop: backdrop, bleed: 0.1)
        }
    }

    /// Self-test (`mascotcheck`): every clip the app plays is in the package, in both sets where it is used, with
    /// frames that decode at the sheet's size; talking has a beak opening per frame.
    func check() -> [String] {
        let lib = PeepSprites.shared
        guard lib.dir != nil else { return ["Resources/Peep/peep.json not found"] }
        var problems: [String] = []
        for c in PeepState.allCases {
            guard let k = lib.clip(c) else { problems.append("dark/\(c.rawValue): missing"); continue }
            for i in [0, k.frames - 1] {
                guard let f = lib.frame(c, set: "dark", index: i) else { problems.append("dark/\(c.rawValue)#\(i): no frame"); continue }
                if CGFloat(f.width) != lib.sets["dark"]?.cell { problems.append("dark/\(c.rawValue)#\(i): \(f.width) px") }
            }
        }
        for c in [PeepState.idle, .hello, .done] where lib.frame(c, set: "paper", index: 0) == nil {
            problems.append("paper/\(c.rawValue): missing")
        }
        if lib.clip(.talking)?.open.count != lib.clip(.talking)?.frames { problems.append("talking: no beak openings") }
        return problems
    }
}

/// A layer that plays one clip at a time from the frames. Its frame is Peep's square; the frames sit on a sublayer
/// the sheet's bleed larger on every side (not clipped), so a hop or the shadow is not cut off.
final class MascotLayer: CALayer {
    private let art = CALayer()
    private(set) var clip: MascotClip?
    private var started: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var shownIndex = -1
    private var holdUntil: CFTimeInterval = 0
    private var smoothed: Double = 0
    private var done: (() -> Void)?
    /// What it sits on (`.auto` = the app's appearance; MascotView passes its own).
    var backdrop: MascotBackdrop = .auto { didSet { if oldValue != backdrop { redraw(force: true) } } }
    /// Set by MascotView from its effective appearance, for `.auto`.
    var appearsDark: Bool? { didSet { if oldValue != appearsDark { redraw(force: true) } } }
    var isPlaying: Bool { MascotDriver.shared.has(self) }
    /// Talking with the voice: read every tick (0…1); nil = the clip's own beats.
    var level: (() -> Float)?

    override init() {
        super.init()
        contentsScale = 2
        actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        art.contentsGravity = .resize
        art.minificationFilter = .trilinear
        art.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        addSublayer(art)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    private var dark: Bool {
        switch backdrop {
        case .light: return false
        case .dark: return true
        case .auto: return appearsDark ?? isDarkMode
        }
    }

    /// Plays `c` from its start (a loop runs until stop / another play). `completion` after a one-shot's end.
    func play(_ c: MascotClip, completion: (() -> Void)? = nil) {
        clip = c
        done = completion
        holdUntil = 0
        if reduceMotion {
            showStill(c)
            MascotDriver.shared.remove(self)
            if let d = done { done = nil; DispatchQueue.main.async(execute: d) }
            return
        }
        started = CACurrentMediaTime()
        lastTick = started
        smoothed = 0
        show(index: 0)
        MascotDriver.shared.add(self)
    }

    /// Shows one moment of a clip, still: `frame` counts frames of the clip from its start (0 = how it begins), nil =
    /// the clip's still moment.
    func show(_ c: MascotClip, frame: Int? = nil) {
        clip = c
        MascotDriver.shared.remove(self)
        if let f = frame { show(index: f) } else { showStill(c) }
    }

    func stop() { MascotDriver.shared.remove(self); done = nil }

    /// Stops and forgets the clip: the next play of any clip, the same one too, starts it afresh.
    func clear() { stop(); clip = nil; shownIndex = -1; art.contents = nil }

    private func showStill(_ c: MascotClip) {
        let lib = PeepSprites.shared
        guard let k = lib.clip(c, set: lib.set(dark: dark, clip: c)) else { return }
        show(index: c == .done ? min(k.frames - 1, lib.stillDone) : PeepPlayback.stillFrame(c, clip: k))
    }

    fileprivate func step(_ now: CFTimeInterval) -> Bool {
        guard let c = clip else { return false }
        let lib = PeepSprites.shared
        guard let k = lib.clip(c, set: lib.set(dark: dark, clip: c)) else { return false }
        let dt = now - lastTick
        lastTick = now
        if c == .talking, let lv = level {
            smoothed = PeepPlayback.smooth(smoothed, toward: Double(lv()), dt: dt)
            show(index: PeepPlayback.talkingFrame(level: smoothed, clip: k))
            return true
        }
        if now < holdUntil { return true }
        let t = now - started
        if !c.loops && t >= k.duration {
            // a one-shot rests on its last frame; error on its droop (the clip itself recovers, for a loop)
            show(index: c == .error ? PeepPlayback.stillFrame(.error, clip: k) : k.frames - 1)
            if let d = done { done = nil; d() }
            return false
        }
        if c == .idle && t >= k.duration {
            // one loop done: rest on the first frame a moment, then breathe and blink again
            started = now + PeepPlayback.idleHold(random: Double.random(in: 0...1))
            holdUntil = started
            show(index: 0)
            return true
        }
        show(index: PeepPlayback.frame(at: t, clip: k, loops: c.loops))
        return true
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        redraw(force: true)
    }

    /// Hidden or cleared by its host: drop the picture too.
    override var contents: Any? { didSet { if contents == nil { art.contents = nil; shownIndex = -1 } } }

    private func show(index: Int) {
        guard index != shownIndex || art.contents == nil else { return }
        shownIndex = index
        redraw(force: true)
    }

    /// Puts the current frame on the art layer, sized to the layer's square plus the sheet's bleed.
    private func redraw(force: Bool) {
        guard let c = clip, bounds.width >= 1 else { return }
        let lib = PeepSprites.shared
        let set = lib.set(dark: dark, clip: c)
        guard let sheet = lib.sets[set] else { return }
        let side = min(bounds.width, bounds.height)
        let b = sheet.bleed
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        art.contentsScale = contentsScale
        art.frame = CGRect(x: bounds.midX - side * (0.5 + b), y: bounds.midY - side * (0.5 + b),
                           width: side * (1 + 2 * b), height: side * (1 + 2 * b))
        art.contents = lib.frame(c, set: set, index: max(0, shownIndex))
        CATransaction.commit()
    }
}

/// One timer for every playing mascot, only while one plays (30 fps: the frames' own rate).
private final class MascotDriver {
    static let shared = MascotDriver()
    private var layers = NSHashTable<MascotLayer>.weakObjects()
    private var timer: Timer?

    func has(_ l: MascotLayer) -> Bool { layers.contains(l) }
    func add(_ l: MascotLayer) {
        layers.add(l)
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.fire() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    func remove(_ l: MascotLayer) {
        layers.remove(l)
        if layers.count == 0 { timer?.invalidate(); timer = nil }
    }
    private func fire() {
        let now = CACurrentMediaTime()
        for l in layers.allObjects where !l.step(now) { layers.remove(l) }
        if layers.count == 0 { timer?.invalidate(); timer = nil }
    }
}

/// AppKit host for a MascotLayer (decoration: hidden from VoiceOver).
final class MascotView: NSView {
    let mascot = MascotLayer()

    init(clip: MascotClip? = nil, size: CGFloat, backdrop: MascotBackdrop = .auto) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        mascot.backdrop = backdrop
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
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        mascot.appearsDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    func play(_ c: MascotClip, completion: (() -> Void)? = nil) { mascot.play(c, completion: completion) }
    func show(_ c: MascotClip, frame: Int? = nil) { mascot.show(c, frame: frame) }
    func stop() { mascot.stop() }
    override func viewDidMoveToWindow() {
        if window == nil { mascot.stop() } else { viewDidChangeEffectiveAppearance() }
    }
}

/// The empty states' mark (docs/design/system.md §3.5): Peep alone, idling (a breath and a blink), on whatever the
/// page is — no tile (a view that shows Peep and the tile side by side would repeat the mark). `EmptyState.markSide`
/// square; decoration, hidden from VoiceOver.
final class BrandMarkView: NSView {
    private let peep = MascotView(size: EmptyState.markSide)
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: EmptyState.markSide, height: EmptyState.markSide))
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(peep)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: EmptyState.markSide),
                                     heightAnchor.constraint(equalToConstant: EmptyState.markSide)])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: EmptyState.markSide, height: EmptyState.markSide) }
    /// idle (a breath and a blink), or thinking while the page waits on work (a first read of the items)
    var state: MascotClip = .idle { didSet { if state != oldValue, window != nil, !isHiddenOrHasHiddenAncestor { peep.play(state) } } }
    override func layout() {
        super.layout()
        peep.frame = bounds                                  // its square: the frames' bleed holds the breath and shadow
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && !isHiddenOrHasHiddenAncestor { peep.play(state) }
    }
    // a hidden empty state does not keep a timer running
    override func viewDidHide() { super.viewDidHide(); peep.stop() }
    override func viewDidUnhide() { super.viewDidUnhide(); if window != nil { peep.play(state) } }
}

/// SwiftUI: plays `clip` (a one-shot then rests on its last moment, or goes on with `then`); a new `clip` plays again.
struct MascotImage: NSViewRepresentable {
    var clip: MascotClip
    var then: MascotClip?
    var size: CGFloat
    var backdrop: MascotBackdrop = .auto

    final class Coordinator { var requested: MascotClip? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MascotView {
        let v = MascotView(size: size, backdrop: backdrop)
        v.setContentHuggingPriority(.required, for: .horizontal)
        v.setContentHuggingPriority(.required, for: .vertical)
        return v
    }
    func updateNSView(_ v: MascotView, context: Context) {
        v.mascot.backdrop = backdrop
        guard context.coordinator.requested != clip else { return }
        context.coordinator.requested = clip
        let next = then
        v.play(clip) { [weak v] in if let n = next { v?.play(n) } }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MascotView, context: Context) -> CGSize? { CGSize(width: size, height: size) }
}
