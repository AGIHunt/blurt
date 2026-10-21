// The Perch (鸡舍): a twine rope just under the menu bar, knotted to a peg at each end; every shot hangs from it like a
// polaroid, held by a chicken-foot clip (docs/design/snap-and-live.md §3). The rope is a small physical simulation
// (Rope.swift): it sags under the cards, each card sits on the curve and tilts with its slope, and it bounces when a
// card is hung, taken, lifted, gathered, or when the strip slides down.
//
//  • hidden by default; slides down for 3 s when a shot arrives, when the pointer rests ~250 ms in the top-middle of
//    the screen (the notch, on notched Macs), or from the menu; tucks away 400 ms after the pointer leaves.
//  • cards land with a damped pendulum swing around the rope's local slope; hovering lifts a card (and the rope with
//    it) and stops it, its neighbours make room; a breeze now and then; × drops a card with gravity; reduce motion =
//    fades and a still, sagging rope.
//  • click = copy (the inked version if any) · drag = the file (+ the note as text) into any app · double-click =
//    edit the note · hover = the note, ▶ plays the voice.
//  • right end: "🐔 整理 N 张" / "清空". While an agent processes a batch or a recording, a nest of wobbling eggs
//    hangs here ("孵化中…") until the review page is up.
// Window: a non-activating panel on all spaces, never captured (sharingType none), mouse-transparent except over
// what it draws, on the screen with the pointer. Animation runs on the display link (up to 120 Hz) only while
// something moves; settled, a slow timer just watches the pointer.
//
// Motion constants follow tendedero.app's published line.js (spring response/damping, pendulum k = 46; damping 3.4 here, c = 2.6 there).

import AppKit
import AVFoundation
import QuartzCore

// MARK: - Springs

struct Spring {
    var value: CGFloat
    var target: CGFloat
    var velocity: CGFloat = 0
    var k: CGFloat
    var c: CGFloat

    init(_ v: CGFloat, response: CGFloat = 0.42, damping: CGFloat = 0.82) {
        value = v; target = v
        let w = 2 * .pi / response
        k = w * w
        c = 2 * damping * w
    }

    mutating func step(_ dt: CGFloat) -> CGFloat {
        var t = min(dt, 0.05)
        while t > 0 {
            let h = min(t, 1.0 / 240)
            let a = -k * (value - target) - c * velocity
            velocity += a * h
            value += velocity * h
            t -= h
        }
        return value
    }

    var resting: Bool { abs(value - target) < 0.01 && abs(velocity) < 0.01 }
    mutating func snap() { value = target; velocity = 0 }
}

/// System "Reduce motion" (BLURT_REDUCE_MOTION=1 forces it, for tests).
var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ProcessInfo.processInfo.environment["BLURT_REDUCE_MOTION"] == "1"
}
var isDarkMode: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

// MARK: - Vector art: chicken-foot clip

/// A chicken foot gripping the top edge of a card (y-up drawing; the leg goes up to the rod).
func drawFoot(_ ctx: CGContext, in r: CGRect) {
    let w = r.width, h = r.height
    let cx = r.midX
    let top = r.maxY, knuckle = r.minY + h * 0.42
    let skin = CGColor(srgbRed: 0.98, green: 0.69, blue: 0.24, alpha: 1)
    let skinDark = CGColor(srgbRed: 0.80, green: 0.47, blue: 0.10, alpha: 1)
    let outline = CGColor(srgbRed: 0.45, green: 0.24, blue: 0.04, alpha: 0.85)
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    // toes: outline pass, then fill pass
    let toes: [(CGPoint, CGPoint)] = [
        (CGPoint(x: cx - w * 0.30, y: r.minY + h * 0.18), CGPoint(x: cx - w * 0.40, y: r.minY + h * 0.02)),
        (CGPoint(x: cx, y: r.minY + h * 0.12), CGPoint(x: cx + w * 0.02, y: r.minY - h * 0.02)),
        (CGPoint(x: cx + w * 0.30, y: r.minY + h * 0.18), CGPoint(x: cx + w * 0.40, y: r.minY + h * 0.02)),
    ]
    for pass in 0..<2 {
        ctx.setStrokeColor(pass == 0 ? outline : skin)
        ctx.setLineWidth(pass == 0 ? w * 0.22 : w * 0.15)
        for (mid, tip) in toes {
            ctx.move(to: CGPoint(x: cx, y: knuckle))
            ctx.addQuadCurve(to: tip, control: mid)
        }
        ctx.strokePath()
    }
    // claws
    ctx.setFillColor(CGColor(srgbRed: 0.30, green: 0.18, blue: 0.08, alpha: 1))
    for (_, tip) in toes {
        ctx.fillEllipse(in: CGRect(x: tip.x - w * 0.065, y: tip.y - w * 0.065, width: w * 0.13, height: w * 0.13))
    }
    // leg
    let leg = CGRect(x: cx - w * 0.12, y: knuckle - h * 0.02, width: w * 0.24, height: top - knuckle - h * 0.02)
    let lp = CGPath(roundedRect: leg, cornerWidth: leg.width / 2, cornerHeight: leg.width / 2, transform: nil)
    ctx.addPath(lp)
    ctx.setFillColor(skin)
    ctx.fillPath()
    ctx.addPath(lp)
    ctx.setStrokeColor(outline)
    ctx.setLineWidth(w * 0.04)
    ctx.strokePath()
    // scales on the leg
    ctx.setStrokeColor(skinDark)
    ctx.setLineWidth(w * 0.035)
    var y = knuckle + h * 0.08
    while y < top - h * 0.08 {
        ctx.move(to: CGPoint(x: leg.minX + leg.width * 0.2, y: y))
        ctx.addQuadCurve(to: CGPoint(x: leg.maxX - leg.width * 0.2, y: y), control: CGPoint(x: cx, y: y - h * 0.04))
        y += h * 0.09
    }
    ctx.strokePath()
    // knuckle
    ctx.setFillColor(skin)
    ctx.fillEllipse(in: CGRect(x: cx - w * 0.15, y: knuckle - w * 0.13, width: w * 0.30, height: w * 0.26))
    ctx.setStrokeColor(outline)
    ctx.setLineWidth(w * 0.04)
    ctx.strokeEllipse(in: CGRect(x: cx - w * 0.15, y: knuckle - w * 0.13, width: w * 0.30, height: w * 0.26))
    // highlight
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.9, blue: 0.7, alpha: 0.7))
    ctx.setLineWidth(w * 0.035)
    ctx.move(to: CGPoint(x: leg.minX + leg.width * 0.3, y: top - h * 0.10))
    ctx.addLine(to: CGPoint(x: leg.minX + leg.width * 0.3, y: knuckle + h * 0.10))
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Cards

final class PerchCard {
    let shot: Shot
    let root = CALayer()          // pivot = the clip on the rod; everything else hangs from here
    let foot = CALayer()
    let frame = CALayer()         // the polaroid
    let photo = CALayer()
    let caption = CATextLayer()
    let badge = CATextLayer()     // 🎙 / ✎ indicators
    let close = CALayer()
    let copied = CATextLayer()
    var x: Spring
    var drop = Spring(0, response: 0.42, damping: 0.72)
    var lift = Spring(0, response: 0.28, damping: 0.72)
    var theta: CGFloat = 0, omega: CGFloat = 0     // swing, degrees, absolute (rests at slopeFollow × the rope's slope)
    var landed = true                              // false while dropping onto the rope (no weight on it yet)
    var nudge: (from: CGFloat, to: CGFloat, start: CFTimeInterval)?
    let tilt: CGFloat
    var flying = false
    var hovered = false
    var dragging = false
    var opacity: CGFloat = 0
    var photoSize = CGSize(width: 136, height: 90)
    var copiedUntil: CFTimeInterval = 0
    var piled = false
    // leaving the perch: a gravity fall, or flying into the hatching nest
    var leaving: (start: CFTimeInterval, gather: CGPoint?)?
    var leaveFrom = CGPoint.zero

    init(_ s: Shot, x: CGFloat) {
        shot = s
        self.x = Spring(x, response: 0.5, damping: 0.8)
        tilt = CGFloat.random(in: -2.5...2.5)
    }

    var height: CGFloat { Perch.cardTop + Perch.padTop + photoSize.height + Perch.padBottom }
}

final class PerchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PerchView: NSView, NSDraggingSource {
    weak var perch: Perch?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { perch?.mouseDown(e, at: convert(e.locationInWindow, from: nil)) }
    override func mouseDragged(with e: NSEvent) { perch?.mouseDragged(e, at: convert(e.locationInWindow, from: nil)) }
    override func mouseUp(with e: NSEvent) { perch?.mouseUp(e, at: convert(e.locationInWindow, from: nil)) }
    override func rightMouseDown(with e: NSEvent) { perch?.rightMouseDown(e, at: convert(e.locationInWindow, from: nil)) }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        perch?.dragEnded(operation: operation)
    }
}

// MARK: - The perch

final class Perch: NSObject {
    // geometry (points, y down from the panel top, which sits just under the menu bar)
    static let rodY: CGFloat = 9               // the rope's anchors (the pegs)
    static let ropeInset: CGFloat = 16         // pegs from the screen edges
    static let slopeFollow: CGFloat = 0.85     // how much a card tilts with the rope under its clip
    static let hangKick: CGFloat = 300         // px/s pushed into the rope where a card lands
    static let cardTop: CGFloat = 20           // polaroid top, from the rod's pivot
    static let cardW: CGFloat = 150, padSide: CGFloat = 7, padTop: CGFloat = 7, padBottom: CGFloat = 28
    static let photoMaxH: CGFloat = 100
    static let spacing: CGFloat = cardW + 22
    static let panelH: CGFloat = 330
    static let controlsW: CGFloat = 230

    var batch: ShotBatch? { didSet { refreshControls() } }
    private var panel: PerchPanel?
    private var view: PerchView!
    private let strip = CALayer()
    private let rope = Rope()
    private let cardsLayer = CALayer()
    private let hint = CATextLayer()
    private let processBtn = CALayer(), clearBtn = CALayer()
    private let processText = CATextLayer(), clearText = CATextLayer()
    private let pileBadge = CATextLayer()
    private let noteTip = CALayer(), noteText = CATextLayer(), notePlay = CATextLayer(), noteWave = CAShapeLayer()
    private var cards: [PerchCard] = []
    private var leaving: [PerchCard] = []
    private(set) var screen: NSScreen?
    private var width: CGFloat = 1440

    private var revealed = false
    private var reveal = Spring(-Perch.panelH, response: 0.42, damping: 0.82)
    private var tuck: (from: CGFloat, start: CFTimeInterval)?
    private var fade: CGFloat = 0                 // reduce motion: the strip fades instead of sliding
    private var peekUntil: CFTimeInterval = 0
    private var pinned = false
    private var holds = 0
    private var hotSince: CFTimeInterval?
    private var awaySince: CFTimeInterval?
    private var last = CACurrentMediaTime()
    private var nextGust = CACurrentMediaTime() + 9
    private var hoverCard: PerchCard?
    private var hoverSince: CFTimeInterval = 0
    private var hoverButton: CALayer?
    private var down: (p: NSPoint, card: PerchCard?, event: NSEvent, dragged: Bool)?
    private var draggingCard: PerchCard?
    private var player: AVAudioPlayer?
    private var waves: [String: [Float]] = [:]
    // hatching nests: one per session being processed
    private var hatches: [(id: String, layer: CALayer, eggs: [CALayer], label: CATextLayer, state: Int, since: CFTimeInterval)] = []

    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(themeChanged),
                                                            name: .init("AppleInterfaceThemeChangedNotification"), object: nil)
    }

    var hasContent: Bool { !cards.isEmpty || !hatches.isEmpty }
    private var isRecording: Bool { (NSApp.delegate as? App)?.rec != nil }

    // MARK: window

    private func ensurePanel(on s: NSScreen) {
        let menuH = max(s.frame.maxY - s.visibleFrame.maxY, s.safeAreaInsets.top)
        let top = s.frame.maxY - min(menuH, 44)
        let f = NSRect(x: s.frame.minX, y: top - Perch.panelH, width: s.frame.width, height: Perch.panelH)
        if panel == nil {
            let p = PerchPanel(contentRect: f, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.acceptsMouseMovedEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.sharingType = chromeSharing
            let v = PerchView(frame: NSRect(origin: .zero, size: f.size))
            v.perch = self
            v.wantsLayer = true
            p.contentView = v
            view = v
            panel = p
            buildLayers()
        }
        screen = s
        width = f.width
        panel?.setFrame(f, display: false)
        view.frame = NSRect(origin: .zero, size: f.size)
        strip.frame = view.bounds
        cardsLayer.frame = view.bounds
        layoutRope()
        layout(instant: true)
        syncLoads()
        rope.snapToRest()
    }

    private func buildLayers() {
        guard let root = view.layer else { return }
        root.masksToBounds = true
        strip.masksToBounds = false
        root.addSublayer(strip)
        strip.addSublayer(rope.layer)
        strip.addSublayer(cardsLayer)
        for (b, t) in [(processBtn, processText), (clearBtn, clearText)] {
            t.contentsScale = 2
            t.alignmentMode = .center
            b.addSublayer(t)
            b.cornerRadius = 13
            b.masksToBounds = false
            b.shadowOpacity = 0.18
            b.shadowRadius = 4
            b.shadowOffset = CGSize(width: 0, height: 2)
            strip.addSublayer(b)
        }
        hint.contentsScale = 2
        hint.alignmentMode = .center
        hint.fontSize = 13
        hint.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        strip.addSublayer(hint)
        pileBadge.contentsScale = 2
        pileBadge.alignmentMode = .center
        pileBadge.fontSize = 11
        pileBadge.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        pileBadge.foregroundColor = NSColor.white.cgColor
        pileBadge.backgroundColor = accent.cgColor
        pileBadge.cornerRadius = 9
        pileBadge.isHidden = true
        strip.addSublayer(pileBadge)
        noteTip.cornerRadius = 10
        noteTip.shadowOpacity = 0.25
        noteTip.shadowRadius = 8
        noteTip.shadowOffset = CGSize(width: 0, height: 3)
        noteTip.isHidden = true
        noteText.contentsScale = 2
        noteText.isWrapped = true
        noteText.truncationMode = .end
        notePlay.contentsScale = 2
        notePlay.alignmentMode = .center
        notePlay.cornerRadius = 11
        noteWave.fillColor = nil
        noteWave.lineWidth = 2
        noteWave.lineCap = .round
        [noteText, notePlay, noteWave].forEach { noteTip.addSublayer($0) }
        strip.addSublayer(noteTip)
        restyle()
    }

    @objc private func themeChanged() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.restyle() } }

    private func restyle() {
        guard view != nil else { return }
        let dark = isDarkMode
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rope.restyle(dark: dark)
        for c in cards { style(c) }
        hint.foregroundColor = (dark ? NSColor(white: 1, alpha: 0.8) : NSColor(white: 0, alpha: 0.6)).cgColor
        noteTip.backgroundColor = (dark ? NSColor(calibratedWhite: 0.18, alpha: 0.97) : NSColor(calibratedWhite: 1, alpha: 0.98)).cgColor
        noteTip.borderColor = (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.08)).cgColor
        noteTip.borderWidth = 0.5
        noteWave.strokeColor = accent.withAlphaComponent(0.85).cgColor
        notePlay.backgroundColor = accent.cgColor
        CATransaction.commit()
        refreshControls()
    }

    private func layoutRope() {
        guard view != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rope.layer.frame = view.bounds
        rope.setSpan(from: Perch.ropeInset, to: width - Perch.ropeInset, y: Perch.rodY)
        rope.draw()
        CATransaction.commit()
    }

    /// What hangs on the rope and how heavily: cards (a lifted one no longer weighs, so the rope rises there; one dragged
    /// away barely weighs), the pile at the left end, the hatching nests.
    private func syncLoads() {
        var l: [(x: CGFloat, w: CGFloat)] = []
        for c in cards where c.landed && !c.flying {
            var w: CGFloat = c.piled ? 0.5 : 1
            if c.dragging { w = 0.3 } else { w *= 1 - max(0, min(1, c.lift.value)) }
            l.append((c.x.value, w))
        }
        let now = CACurrentMediaTime()
        for c in leaving where c.landed { if let lv = c.leaving, now < lv.start { l.append((c.x.value, 1)) } }   // gathering, not yet gone
        for h in hatches { l.append((h.layer.position.x, 1.6)) }
        rope.loads = l
    }

    private static let footImage: CGImage? = renderImage(CGSize(width: 18, height: 30)) {
        drawFoot($0, in: CGRect(x: 0, y: 2, width: 18, height: 26))
    }

    // MARK: cards

    private func style(_ c: PerchCard) {
        let dark = isDarkMode
        c.frame.backgroundColor = (dark ? NSColor(calibratedRed: 0.89, green: 0.875, blue: 0.85, alpha: 1)
                                        : NSColor(calibratedRed: 1, green: 0.995, blue: 0.98, alpha: 1)).cgColor
        c.frame.borderColor = (dark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.07)).cgColor
        c.frame.borderWidth = 0.5
        c.frame.shadowOpacity = dark ? 0.5 : 0.22
        c.photo.borderColor = (dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.10)).cgColor
        setCaption(c)
    }

    /// Handwriting for the polaroid caption: Noteworthy for Latin; for Chinese a hand-lettered face if installed
    /// (Hannotate / Kaiti), else PingFang. One font per caption — mixed cascades get tall, clipped line boxes.
    private func captionFont(_ size: CGFloat, for text: String) -> NSFont {
        let cjk = text.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
        let names = cjk ? ["HannotateSC-W5", "STKaitiSC-Regular", "PingFangSC-Regular"] : ["Noteworthy-Light", "Bradley Hand"]
        for n in names { if let f = NSFont(name: n, size: cjk ? size - 0.5 : size) { return f } }
        return .systemFont(ofSize: size)
    }

    private func setCaption(_ c: PerchCard) {
        let dark = isDarkMode
        let s = c.shot
        var text = (s.text ?? "").replacingOccurrences(of: "\n", with: " ")
        if text.isEmpty, s.voice != nil { text = L("🎙 语音备注", "🎙 voice note") }
        if text.isEmpty { text = s.t.map { L("录制中 \(fmtClock($0))", "at \(fmtClock($0))") } ?? timeLabel(s.wall) }
        let ps = NSMutableParagraphStyle()
        ps.minimumLineHeight = 17
        ps.maximumLineHeight = 17          // hand-lettered CJK faces have very tall line boxes
        let font = captionFont(12.5, for: text)
        text = fitted(text, font: font, width: c.caption.bounds.width - 2)
        c.caption.string = NSAttributedString(string: text, attributes: [
            .font: font, .paragraphStyle: ps,
            // a polaroid stays a (slightly dimmed) paper card in dark mode too, so its ink stays dark
            .foregroundColor: (s.text ?? "").isEmpty ? NSColor(white: 0, alpha: dark ? 0.45 : 0.38)
                                                    : NSColor(calibratedRed: 0.17, green: 0.15, blue: 0.13, alpha: 1),
        ])
        var marks = ""
        if s.voice != nil, !(s.text ?? "").isEmpty { marks += "🎙" }
        if s.marked != nil { marks += "✎" }
        c.badge.string = NSAttributedString(string: marks, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold),
                                                                         .foregroundColor: accent])
        c.photo.contents = s.markedThumb ?? s.thumb
    }

    /// CATextLayer's own truncation is unreliable with attributed strings: cut to fit, with an ellipsis.
    private func fitted(_ text: String, font: NSFont, width: CGFloat) -> String {
        let w = { (s: String) in (s as NSString).size(withAttributes: [.font: font]).width }
        guard w(text) > width else { return text }
        var chars = Array(text)
        while !chars.isEmpty && w(String(chars) + "…") > width { chars.removeLast() }
        return String(chars).trimmingCharacters(in: .whitespaces) + "…"
    }

    private func fmtClock(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
    private func timeLabel(_ wall: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: wall))
    }

    private func makeCard(_ s: Shot, x: CGFloat) -> PerchCard {
        let c = PerchCard(s, x: x)
        let px = s.pixelSize.width > 0 ? s.pixelSize : CGSize(width: 1600, height: 1000)
        let maxW = Perch.cardW - Perch.padSide * 2
        let sc = min(maxW / px.width, Perch.photoMaxH / px.height)
        c.photoSize = CGSize(width: maxW, height: max(40, (px.height * sc).rounded()))
        let h = Perch.padTop + c.photoSize.height + Perch.padBottom
        c.root.bounds = CGRect(x: 0, y: 0, width: Perch.cardW, height: Perch.cardTop + h)
        c.root.anchorPoint = CGPoint(x: 0.5, y: 0)
        c.root.opacity = 0
        c.frame.frame = CGRect(x: 0, y: Perch.cardTop, width: Perch.cardW, height: h)
        c.frame.cornerRadius = 3
        c.frame.shadowColor = NSColor.black.cgColor
        c.frame.shadowRadius = 6
        c.frame.shadowOffset = CGSize(width: 0, height: 3)
        c.photo.frame = CGRect(x: Perch.padSide, y: Perch.padTop, width: c.photoSize.width, height: c.photoSize.height)
        c.photo.contentsGravity = .resizeAspectFill
        c.photo.masksToBounds = true
        c.photo.cornerRadius = 1.5
        c.photo.borderWidth = 0.5
        c.photo.backgroundColor = NSColor(white: 0.5, alpha: 0.15).cgColor
        c.caption.frame = CGRect(x: Perch.padSide + 1, y: Perch.padTop + c.photoSize.height + 5, width: Perch.cardW - Perch.padSide * 2 - 18, height: 18)
        c.caption.contentsScale = 2
        c.caption.truncationMode = .end
        c.caption.isWrapped = false
        c.badge.frame = CGRect(x: Perch.cardW - Perch.padSide - 22, y: Perch.padTop + c.photoSize.height + 7, width: 22, height: 14)
        c.badge.contentsScale = 2
        c.badge.alignmentMode = .right
        c.frame.addSublayer(c.photo)
        c.frame.addSublayer(c.caption)
        c.frame.addSublayer(c.badge)
        // × (hover)
        c.close.frame = CGRect(x: -7, y: -7, width: 20, height: 20)
        c.close.cornerRadius = 10
        c.close.backgroundColor = NSColor(white: 0.15, alpha: 0.85).cgColor
        c.close.borderColor = NSColor(white: 1, alpha: 0.9).cgColor
        c.close.borderWidth = 1
        c.close.contents = renderImage(CGSize(width: 20, height: 20)) { ctx in
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(1.6)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: 6.5, y: 6.5)); ctx.addLine(to: CGPoint(x: 13.5, y: 13.5))
            ctx.move(to: CGPoint(x: 13.5, y: 6.5)); ctx.addLine(to: CGPoint(x: 6.5, y: 13.5))
            ctx.strokePath()
        }
        c.close.opacity = 0
        c.frame.addSublayer(c.close)
        // "copied" capsule
        c.copied.frame = CGRect(x: Perch.cardW / 2 - 38, y: h + 6, width: 76, height: 20)
        c.copied.contentsScale = 2
        c.copied.alignmentMode = .center
        c.copied.cornerRadius = 10
        c.copied.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
        c.copied.string = NSAttributedString(string: L("✓ 已复制", "✓ Copied"), attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.white])
        c.copied.opacity = 0
        c.frame.addSublayer(c.copied)
        // the clip: a chicken foot from the rod gripping the card's top edge
        c.foot.frame = CGRect(x: Perch.cardW / 2 - 9, y: -4, width: 18, height: 30)
        c.foot.contents = Perch.footImage
        c.root.addSublayer(c.frame)
        c.root.addSublayer(c.foot)
        style(c)
        return c
    }

    private var capacity: Int {
        max(3, min(12, Int((width - 220 - Perch.controlsW) / Perch.spacing)))
    }

    private var pileCount: Int { max(0, cards.count - capacity) }

    /// Rest x for each card: the visible ones centred in the free span, older overflow stacked at the left end.
    private func targets() -> [CGFloat] {
        let n = cards.count, pile = pileCount, shown = n - pile
        let left: CGFloat = 70 + (pile > 0 ? Perch.cardW + 20 : 0)
        let right = width - Perch.controlsW - 40
        let gaps = CGFloat(max(shown - 1, 0))
        let step = gaps > 0 ? min(Perch.spacing, max(0, right - left - Perch.cardW) / gaps) : 0
        let mid = (left + right) / 2
        var out: [CGFloat] = []
        for i in 0..<n {
            if i < pile {
                out.append(70 + Perch.cardW / 2 + CGFloat(min(i, 3)) * 5 - CGFloat(max(0, min(pile, 4) - 1)) * 2.5)
            } else {
                out.append(mid - gaps * step / 2 + CGFloat(i - pile) * step)
            }
        }
        return out
    }

    func layout(instant: Bool = false) {
        guard view != nil else { return }
        let xs = targets()
        let hi = hoverCard.flatMap { h in cards.firstIndex { $0 === h } }
        for (i, c) in cards.enumerated() {
            c.piled = i < pileCount
            var x = xs[i]
            if let h = hi, !cards[h].piled, !c.piled, i != h { x += i < h ? -16 : 16 }    // neighbours make room
            c.x.target = x
            if instant { c.x.snap() }
            c.root.zPosition = c.piled ? CGFloat(i) : 100 + CGFloat(i)
        }
        hint.isHidden = !(cards.isEmpty && hatches.isEmpty)
        hint.string = hkHint(.snap, "截一张图，它会挂在这里", "takes a shot — it hangs here")
            ?? L("从菜单截一张图，它会挂在这里", "Take a shot from the menu — it hangs here")
        hint.frame = CGRect(x: width / 2 - 200, y: rope.restY(at: width / 2) + Perch.cardTop + 6, width: 400, height: 20)
        refreshControls()
        wake()
    }

    func refreshControls() {
        guard view != nil else { return }
        let n = batch?.live.count ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let dark = isDarkMode
        let pf = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let ps = NSAttributedString(string: L("🐔 整理 \(n) 张", "🐔 Process \(n)"), attributes: [.font: pf, .foregroundColor: NSColor.white])
        let cs = NSAttributedString(string: L("清空", "Clear"), attributes: [
            .font: pf, .foregroundColor: dark ? NSColor(white: 1, alpha: 0.85) : NSColor(white: 0, alpha: 0.7)])
        processText.string = ps
        clearText.string = cs
        let pw = ps.size().width + 26
        let cw = cs.size().width + 24
        let y = Perch.cardTop + 4
        processBtn.frame = CGRect(x: width - 40 - pw, y: y, width: pw, height: 26)
        clearBtn.frame = CGRect(x: processBtn.frame.minX - 8 - cw, y: y, width: cw, height: 26)
        for b in [processBtn, clearBtn] {
            b.isHidden = n == 0
            let hot = hoverButton === b
            if b === processBtn {
                b.backgroundColor = (hot ? accent.blended(withFraction: 0.15, of: .white) ?? accent : accent).cgColor
            } else {
                b.backgroundColor = (dark ? NSColor(white: hot ? 0.34 : 0.26, alpha: 0.95) : NSColor(white: hot ? 0.90 : 0.97, alpha: 0.97)).cgColor
                b.borderColor = (dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.1)).cgColor
                b.borderWidth = 0.5
            }
        }
        for (b, t, a) in [(processBtn, processText, ps), (clearBtn, clearText, cs)] {
            let th = ceil(a.size().height)
            t.frame = CGRect(x: 0, y: (b.bounds.height - th) / 2, width: b.bounds.width, height: th)
        }
        let pile = pileCount
        pileBadge.isHidden = pile == 0
        pileBadge.string = "+\(pile)"
        pileBadge.frame = CGRect(x: 70 + Perch.cardW - 18, y: rope.restY(at: 70 + Perch.cardW / 2) + Perch.cardTop - 12, width: 30, height: 18)
        CATransaction.commit()
    }

    func hang(_ s: Shot, from: NSRect?, quiet: Bool = false) {
        guard !cards.contains(where: { $0.shot === s }) else { return }
        let target = from.flatMap { r in NSScreen.screens.first { $0.frame.intersects(r) } } ?? screenWithPointer()
        if panel == nil || (!revealed && screen != target) { ensurePanel(on: target) }
        let c = makeCard(s, x: width / 2)
        cards.append(c)
        cardsLayer.addSublayer(c.root)
        layout()
        if let i = cards.firstIndex(where: { $0 === c }) { c.x.value = targets()[i]; c.x.snap() }
        c.theta = Perch.slopeFollow * slopeDeg(c.x.value)
        if quiet {
            c.opacity = 1
            syncLoads()
            rope.snapToRest()
            c.theta = Perch.slopeFollow * slopeDeg(c.x.value, rest: true)
            place(c, now: CACurrentMediaTime())
            return
        }
        // the flight / drop aims at where the rope will rest once this card weighs on it
        c.landed = false
        syncLoads()
        c.landed = true
        place(c, now: CACurrentMediaTime())
        c.landed = false
        show(peek: 3)
        if let f = from, !reduceMotion, let img = s.thumb, let to = cardScreenRect(s) {
            c.flying = true
            c.opacity = 0
            flyImage(img, from: f, to: to, tilt: c.tilt + c.theta) { [weak self] in
                guard let self = self else { return }
                c.flying = false
                c.opacity = 1
                self.land(c, kick: Perch.hangKick)
                self.startNudge(c, 2.2)
            }
        } else if reduceMotion {
            c.opacity = 0
            c.landed = true
        } else {
            c.opacity = 1
            c.drop.value = -46
            c.drop.target = 0
            c.theta += 16
        }
        wake()
    }

    func update(_ s: Shot) {
        guard let c = cards.first(where: { $0.shot === s }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setCaption(c)
        CATransaction.commit()
        if s.deleted { remove(c, fall: true) }
    }

    func remove(_ c: PerchCard, fall: Bool) {
        guard let i = cards.firstIndex(where: { $0 === c }) else { return }
        cards.remove(at: i)
        if hoverCard === c { hoverCard = nil; noteTip.isHidden = true }
        if fall && revealed && !reduceMotion {
            c.leaving = (CACurrentMediaTime(), nil)
            c.leaveFrom = .zero
            leaving.append(c)
        } else {
            CATransaction.begin()
            CATransaction.setCompletionBlock { c.root.removeFromSuperlayer() }
            c.root.opacity = 0
            CATransaction.commit()
        }
        layout()
    }

    /// "清空": everything falls off, one after the other.
    func dropAll() {
        let all = cards
        for (i, c) in all.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(i)) { self.remove(c, fall: true) }
        }
    }

    /// "整理": the cards fly into a nest that starts hatching.
    func gather(into kinds: [String]) {
        let id = "gather-\(Date().timeIntervalSince1970)"
        hatch(id: id, kinds: kinds, reveal: false)
        pendingGatherID = id
        let nest = hatches.last.map { CGPoint(x: $0.layer.frame.midX, y: $0.layer.frame.midY) } ?? CGPoint(x: width - 200, y: 60)
        let all = cards
        cards.removeAll()
        hoverCard = nil
        noteTip.isHidden = true
        for (i, c) in all.enumerated() {
            c.leaving = (CACurrentMediaTime() + 0.08 * Double(i), nest)
            c.leaveFrom = .zero
            leaving.append(c)
        }
        layout()
        show(peek: 3)
    }
    private var pendingGatherID: String?

    func cardScreenRect(_ s: Shot) -> NSRect? {
        guard let p = panel, let i = cards.firstIndex(where: { $0.shot === s }) else { return nil }
        let c = cards[i]
        let x = c.x.target
        let local = NSRect(x: x - Perch.cardW / 2, y: rope.restY(at: x) + Perch.cardTop, width: Perch.cardW,
                           height: Perch.padTop + c.photoSize.height + Perch.padBottom)
        return NSRect(x: p.frame.minX + local.minX, y: p.frame.maxY - local.maxY, width: local.width, height: local.height)
    }

    /// The note bubble (or anything else) keeps the perch down while it is open.
    func hold(_ on: Bool) {
        holds = max(0, holds + (on ? 1 : -1))
        if on { show() }
        wake()
    }

    func show(peek: Double = 0, pinned pin: Bool = false) {
        if panel == nil || (!revealed && screen != screenWithPointer() && peek == 0) { ensurePanel(on: screenWithPointer()) }
        if pin { pinned = true; peekUntil = max(peekUntil, CACurrentMediaTime() + 6) }
        if peek > 0 { peekUntil = max(peekUntil, CACurrentMediaTime() + peek) }
        awaySince = nil
        setRevealed(true)
    }

    func hide() { setRevealed(false) }

    private func setRevealed(_ on: Bool) {
        guard on != revealed else { return }
        revealed = on
        if on {
            tuck = nil
            panel?.orderFrontRegardless()
            if reduceMotion { reveal.value = 0; reveal.snap() }
        } else {
            tuck = (reveal.value, CACurrentMediaTime())
            pinned = false
            peekUntil = 0
            hoverCard = nil
            noteTip.isHidden = true
            panel?.ignoresMouseEvents = true
        }
        wake()
    }

    private func screenWithPointer() -> NSScreen {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: hatching

    func hatch(id: String, kinds: [String], reveal: Bool = true) {
        if panel == nil { ensurePanel(on: screenWithPointer()) }
        if let g = pendingGatherID, let i = hatches.firstIndex(where: { $0.id == g }) {
            // the gathered batch's nest becomes this session's nest
            hatches[i].id = id
            pendingGatherID = nil
            return
        }
        guard !hatches.contains(where: { $0.id == id }) else { return }
        let ks = kinds.isEmpty ? ["issue", "idea", "note"] : Array(kinds.prefix(5))
        let nest = CALayer()
        let nestSize = CGSize(width: 96, height: 48)
        let eggSize = CGSize(width: 22, height: 29)
        let h: CGFloat = 26 + nestSize.height + 22
        nest.bounds = CGRect(x: 0, y: 0, width: 120, height: h)
        nest.anchorPoint = CGPoint(x: 0.5, y: 0)
        let foot = CALayer()
        foot.frame = CGRect(x: 51, y: -4, width: 18, height: 30)
        foot.contents = Perch.footImage
        let back = CALayer(), front = CALayer()
        back.frame = CGRect(x: 12, y: 22, width: nestSize.width, height: nestSize.height)
        back.contents = nestImage(nestSize, part: 0)
        front.frame = back.frame
        front.contents = nestImage(nestSize, part: 1)
        nest.addSublayer(back)
        var eggs: [CALayer] = []
        let step: CGFloat = min(16, 64 / CGFloat(max(1, ks.count - 1)))
        for (i, k) in ks.enumerated() {
            let e = CALayer()
            e.bounds = CGRect(origin: .zero, size: eggSize)
            e.anchorPoint = CGPoint(x: 0.5, y: 0.9)
            e.position = CGPoint(x: 60 - CGFloat(ks.count - 1) * step / 2 + CGFloat(i) * step, y: 22 + nestSize.height * 0.52)
            e.contents = eggImage(EggKind(k), size: eggSize, seed: EggKind.seed(k, id: "\(id)-\(i)"), shadow: false)
            nest.addSublayer(e)
            eggs.append(e)
        }
        nest.addSublayer(front)
        nest.addSublayer(foot)
        let label = CATextLayer()
        label.contentsScale = 2
        label.alignmentMode = .center
        label.frame = CGRect(x: -20, y: 22 + nestSize.height + 2, width: 160, height: 18)
        nest.addSublayer(label)
        strip.addSublayer(nest)
        hatches.append((id, nest, eggs, label, 0, CACurrentMediaTime()))
        layoutHatches()
        rope.impulse(at: nest.position.x, Perch.hangKick, spread: 120)
        if reveal { show(peek: 3) }
        wake()
    }

    /// ok: the review page is up → the eggs hatch and the nest leaves. Failed: grey eggs + a hint for a while.
    func hatched(id: String, ok: Bool) {
        guard let i = hatches.firstIndex(where: { $0.id == id }), hatches[i].state == 0 else { return }
        hatches[i].state = ok ? 1 : 2
        hatches[i].since = CACurrentMediaTime()
        let h = hatches[i]
        if ok {
            for (j, e) in h.eggs.enumerated() {
                let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                pop.values = [1, 1.35, 0.2]
                pop.keyTimes = [0, 0.45, 1]
                pop.duration = reduceMotion ? 0.01 : 0.45
                pop.beginTime = CACurrentMediaTime() + 0.08 * Double(j)
                pop.fillMode = .both
                pop.isRemovedOnCompletion = false
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1; fade.toValue = 0
                fade.duration = 0.45
                fade.beginTime = pop.beginTime
                fade.fillMode = .both
                fade.isRemovedOnCompletion = false
                e.add(pop, forKey: "pop")
                e.add(fade, forKey: "fade")
            }
        } else {
            for e in h.eggs { e.opacity = 0.45 }
        }
        show(peek: ok ? 2.5 : 6)
        DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 2.2 : 8)) { [weak self] in
            guard let self = self, let k = self.hatches.firstIndex(where: { $0.id == id }) else { return }
            let l = self.hatches[k].layer
            self.hatches.remove(at: k)
            CATransaction.begin()
            CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
            l.opacity = 0
            CATransaction.commit()
            self.layoutHatches()
            self.layout()
        }
        wake()
    }

    private func layoutHatches() {
        let hasButtons = (batch?.live.count ?? 0) > 0
        var x = width - (hasButtons ? Perch.controlsW + 40 : 110)
        for h in hatches.reversed() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            h.layer.position = CGPoint(x: x, y: rope.y(at: x) - 2)
            CATransaction.commit()
            x -= 130
        }
    }

    private func tickHatches(_ now: CFTimeInterval) {
        for h in hatches {
            let x = h.layer.position.x
            h.layer.position = CGPoint(x: x, y: rope.y(at: x) - 2)
            h.layer.setAffineTransform(CGAffineTransform(rotationAngle: reduceMotion ? 0 : atan(rope.slope(at: x)) * Perch.slopeFollow))
            let t = now - h.since
            let dots = String(repeating: "·", count: 1 + Int(now * 2.5) % 3)
            let text: String
            switch h.state {
            case 1: text = L("孵出来了 🐣", "Hatched 🐣")
            case 2: text = L("整理失败 · 详见 agent.log", "Failed · see agent.log")
            default: text = L("孵化中 ", "Hatching ") + dots
            }
            if (h.label.string as? NSAttributedString)?.string != text {
                h.label.string = NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                    .foregroundColor: h.state == 2 ? amber : (isDarkMode ? NSColor(white: 1, alpha: 0.85) : NSColor(white: 0, alpha: 0.6))])
            }
            guard h.state == 0, !reduceMotion else { continue }
            for (j, e) in h.eggs.enumerated() {
                // wobble in little bursts, each egg on its own beat — "something is going on in there"
                let beat = (t + Double(j) * 0.37).truncatingRemainder(dividingBy: 1.9)
                let env = beat < 0.7 ? sin(.pi * beat / 0.7) : 0
                let a = CGFloat(env * sin(t * 2 * .pi * 3.2 + Double(j)) * 0.16)
                e.setAffineTransform(CGAffineTransform(rotationAngle: a))
            }
        }
    }

    // MARK: animation loop
    //
    // Fast: a display link (CADisplayLink on macOS 14+, up to 120 Hz; a 60 Hz timer before) while anything moves.
    // When everything has settled for a few frames it stops; a slow timer then only polls the pointer (hover, the
    // hot zone) and the next breeze, and any event calls wake() to start the display link again.

    private var link: AnyObject?
    private var slowTimer: Timer?
    private var stillFrames = 0
    private var stripY: CGFloat = -1e6
    private var stripVel: CGFloat = 0

    private var visible: Bool { revealed || tuck != nil || !leaving.isEmpty }

    private func wake() {
        stillFrames = 0
        if visible { startLink() } else { goIdle() }
    }

    private func startLink() {
        guard link == nil, let v = view else { return }
        slowTimer?.invalidate()
        slowTimer = nil
        last = CACurrentMediaTime()
        stats = (0, 0, 0, 0, 0, 0, last, [:])
        if #available(macOS 14.0, *) {
            let l = v.displayLink(target: self, selector: #selector(linkFired(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.frame() }
            RunLoop.main.add(t, forMode: .common)
            link = t
        }
    }

    @objc private func linkFired(_ l: AnyObject) {
        let t0 = CACurrentMediaTime()
        if #available(macOS 14.0, *), let l = l as? CADisplayLink { stats.interval = l.targetTimestamp - l.timestamp }
        if stats.lastFire > 0 {
            let gap = t0 - stats.lastFire
            stats.maxGap = max(stats.maxGap, gap)
            if stats.interval > 0, gap > stats.interval * 1.5 { stats.late += 1 }
        }
        stats.lastFire = t0
        frame()
        stats.frames += 1
        stats.maxWork = max(stats.maxWork, CACurrentMediaTime() - t0)
    }

    /// BLURT_PERCH_FPS=1 (tests): one line per burst of animation — frames, late frames, the longest frame's work.
    private var stats = (frames: 0, late: 0, maxGap: 0.0, maxWork: 0.0, lastFire: 0.0, interval: 0.0, start: 0.0, why: [String: Int]())
    private func reportFrames() {
        defer { stats = (0, 0, 0, 0, 0, 0, CACurrentMediaTime(), [:]) }
        guard ProcessInfo.processInfo.environment["BLURT_PERCH_FPS"] == "1", stats.frames > 0 else { return }
        emit(["event": "perch_frames", "frames": stats.frames, "secs": CACurrentMediaTime() - stats.start,
              "late": stats.late, "max_gap_ms": stats.maxGap * 1000, "max_work_ms": stats.maxWork * 1000,
              "interval_ms": stats.interval * 1000, "busy_with": stats.why])
    }

    private func stopLink() {
        if link != nil { reportFrames() }
        if #available(macOS 14.0, *), let l = link as? CADisplayLink { l.invalidate() }
        (link as? Timer)?.invalidate()
        link = nil
    }

    /// Nothing moves: drop to a slow pointer poll (or nothing at all, with nothing to show).
    private func goIdle() {
        stopLink()
        let rate: Double = revealed ? 1.0 / 20 : 1.0 / 12
        if let t = slowTimer, t.isValid, t.timeInterval == rate { return }
        slowTimer?.invalidate()
        slowTimer = nil
        guard hasContent || revealed else { return }
        let t = Timer(timeInterval: rate, repeats: true) { [weak self] _ in self?.idleTick() }
        t.tolerance = rate / 2
        RunLoop.main.add(t, forMode: .common)
        slowTimer = t
    }

    private func idleTick() {
        let now = CACurrentMediaTime()
        poll(now)
        if revealed, now > nextGust { wake() }
    }

    private func frame() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.05, now - last))
        last = now
        poll(now)
        guard visible else { goIdle(); return }
        let hidden = -(maxBottom() + 24)
        var y: CGFloat
        if let tk = tuck {
            let k = CGFloat(min(1, (now - tk.start) / 0.22))
            y = tk.from + (hidden - tk.from) * k * k
            reveal.value = y
            reveal.velocity = 0
            if k >= 1 {
                tuck = nil
                if !hasContent || !revealed { panel?.orderOut(nil) }
            }
        } else {
            reveal.target = revealed ? 0 : hidden
            y = reduceMotion ? reveal.target : reveal.step(dt)
        }
        if reduceMotion {
            fade += (revealed ? 1 : -1) * dt * 6
            fade = max(0, min(1, fade))
            y = revealed || fade > 0 ? 0 : hidden
        } else { fade = 1 }
        // the strip's own acceleration shakes the rope: it lags as the strip slides down, then settles
        var accel: CGFloat = 0
        if dt > 0.001 {
            let vel = stripY > -1e5 ? (y - stripY) / dt : 0
            accel = (vel - stripVel) / dt
            stripVel = vel
        }
        stripY = y
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.setAffineTransform(CGAffineTransform(translationX: 0, y: y))
        strip.opacity = Float(fade)
        if now > nextGust {
            nextGust = now + Double.random(in: 7...16)
            if revealed, draggingCard == nil, !cards.isEmpty, !reduceMotion {
                rope.impulse(at: CGFloat.random(in: width * 0.25...width * 0.75), CGFloat.random(in: -45...45), spread: width * 0.2)
                for c in cards where !c.hovered { let d = CGFloat.random(in: 1.6...3.4); let c2 = c
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0...0.35)) { self.startNudge(c2, d) } }
            }
        }
        for c in cards { step(c, dt, now) }
        syncLoads()
        rope.step(dt, frameAccel: accel)
        rope.draw()
        for c in cards { place(c, now: now) }
        for c in leaving { stepLeaving(c, now) }
        leaving.removeAll { c in
            guard let l = c.leaving, now - l.start > 0.6 else { return false }
            c.root.removeFromSuperlayer()
            return true
        }
        tickHatches(now)
        positionNoteTip(now)
        CATransaction.commit()
        if tuck == nil && !revealed && leaving.isEmpty { panel?.orderOut(nil); stripY = -1e6; stripVel = 0; goIdle(); return }
        let why = moving(now)
        if stats.frames % 60 == 59 { stats.why[why ?? "-", default: 0] += 1 }
        if why != nil { stillFrames = 0 } else {
            stillFrames += 1
            if stillFrames >= 3 { goIdle() }
        }
    }

    /// What is still animating (or about to change on its own), nil when everything has settled.
    private func moving(_ now: CFTimeInterval) -> String? {
        if tuck != nil { return "tuck" }
        if !leaving.isEmpty { return "leaving" }
        if !rope.settled { return "rope" }
        if !reduceMotion && !reveal.resting { return "reveal" }
        if reduceMotion && fade < 1 && revealed { return "fade" }
        if hatches.contains(where: { $0.state == 0 }) { return "hatching" }
        if let h = hoverCard, h.shot.hasNote, noteTip.isHidden, now - hoverSince < 0.6 { return "note tip" }
        for c in cards {
            if c.flying || !c.landed { return "landing" }
            if c.nudge != nil || c.opacity < 1 || now < c.copiedUntil + 0.1 { return "card" }
            if !c.x.resting || !c.drop.resting || !c.lift.resting { return "card spring" }
            if abs(c.theta - Perch.slopeFollow * slopeDeg(c.x.value)) > 0.15 || abs(c.omega) > 0.5 { return "swing" }
        }
        return nil
    }

    private func maxBottom() -> CGFloat {
        let cb = cards.map { $0.height }.max() ?? 60
        let hb: CGFloat = hatches.isEmpty ? 0 : 26 + 48 + 40
        return Perch.rodY + rope.maxSag + max(cb, hb, 50) + 40
    }

    /// The rope's slope at x, in degrees (now, or once it has come to rest).
    private func slopeDeg(_ x: CGFloat, rest: Bool = false) -> CGFloat {
        let s = rest ? (rope.restY(at: x + 1) - rope.restY(at: x - 1)) / 2 : rope.slope(at: x)
        return atan(s) * 180 / .pi
    }

    /// A card arrives on the rope: from now on it weighs on it, and its momentum pushes the rope down there.
    private func land(_ c: PerchCard, kick: CGFloat) {
        c.landed = true
        rope.impulse(at: c.x.value, kick, spread: 120)
        wake()
    }

    private func place(_ c: PerchCard, now: CFTimeInterval) {
        let swing = reduceMotion ? Perch.slopeFollow * slopeDeg(c.x.value) : c.theta
        let scale = 1 + 0.05 * c.lift.value
        var t = CATransform3DMakeTranslation(0, c.drop.value - 3 * c.lift.value, 0)
        t = CATransform3DRotate(t, (swing + c.tilt * (1 - c.lift.value)) * .pi / 180, 0, 0, 1)
        t = CATransform3DScale(t, scale, scale, 1)
        c.root.position = CGPoint(x: c.x.value, y: rope.y(at: c.x.value))
        c.root.transform = t
        c.root.opacity = Float(c.flying ? 0 : (c.dragging ? 0.45 : c.opacity))
        c.frame.shadowRadius = 6 + 6 * c.lift.value
        c.frame.shadowOffset = CGSize(width: 0, height: 3 + 4 * c.lift.value)
        c.close.opacity = c.hovered && !c.piled ? 1 : 0
        c.copied.opacity = now < c.copiedUntil ? 1 : 0
    }

    private func step(_ c: PerchCard, _ dt: CGFloat, _ now: CFTimeInterval) {
        // the swing rests at the rope's slope under the clip, so when the rope moves the card lags and swings
        let rest = Perch.slopeFollow * slopeDeg(c.x.value)
        if let n = c.nudge {
            let k = CGFloat(min(1, (now - n.start) / 0.3))
            c.theta = rest + n.from + (n.to - n.from) * (1 - pow(1 - k, 3))
            c.omega = 0
            if k >= 1 { c.nudge = nil }
        } else {
            var left = dt
            let damp: CGFloat = c.hovered ? 16 : 3.4     // hovered: lifted and still
            while left > 0 {
                let h = min(left, 1.0 / 240)
                let a = -46 * (c.theta - rest) - damp * c.omega
                c.omega += a * h
                c.theta += c.omega * h
                left -= h
            }
        }
        _ = c.x.step(dt)
        if !c.landed && !c.flying {
            let v = c.drop.velocity
            _ = c.drop.step(dt)
            if c.drop.value >= 0 {          // reached the rope: it takes the weight and the momentum
                c.drop.snap()
                land(c, kick: min(Perch.hangKick, max(120, v * 0.6)))
            }
        } else { _ = c.drop.step(dt) }
        c.lift.target = c.hovered && !c.dragging ? 1 : 0
        _ = c.lift.step(dt)
        if !c.flying { c.opacity = min(1, c.opacity + dt * 6) }
        if reduceMotion { c.x.snap(); c.drop.snap(); c.lift.snap(); c.theta = rest; c.omega = 0; c.landed = true }
    }

    private func stepLeaving(_ c: PerchCard, _ now: CFTimeInterval) {
        guard let l = c.leaving else { return }
        if now < l.start {                 // waiting its turn (gathering): still hanging on the rope
            c.root.position = CGPoint(x: c.x.value, y: rope.y(at: c.x.value))
            return
        }
        if c.leaveFrom == .zero {
            c.leaveFrom = c.root.position
            if l.gather == nil { rope.impulse(at: c.x.value, 70, spread: 90) }    // yanked off: a tug, then it springs up
        }
        let raw = CGFloat(max(0, min(1, (now - l.start) / 0.55)))
        if let g = l.gather {
            // into the nest: shrink along an arc and vanish
            let k = raw < 0.5 ? 4 * raw * raw * raw : 1 - pow(-2 * raw + 2, 3) / 2
            let x = c.leaveFrom.x + (g.x - c.leaveFrom.x) * k
            let y = c.leaveFrom.y + (g.y - 30 - c.leaveFrom.y) * k - sin(.pi * k) * 20
            c.root.position = CGPoint(x: x, y: y)
            let s = 1 - 0.85 * k
            c.root.transform = CATransform3DScale(CATransform3DMakeRotation((c.tilt + c.theta + 30 * k) * .pi / 180, 0, 0, 1), s, s, 1)
            c.root.opacity = Float(1 - k * k)
        } else {
            // gravity
            let e = raw * raw * raw
            let angle = c.tilt + c.theta + ((c.tilt + c.theta) * 7 + 20) * e
            var t = CATransform3DMakeTranslation(0, 520 * e, 0)
            t = CATransform3DRotate(t, angle * .pi / 180, 0, 0, 1)
            c.root.transform = t
            c.root.opacity = Float(1 - e)
        }
    }

    func startNudge(_ c: PerchCard, _ deg: CGFloat) {
        guard !reduceMotion else { return }
        c.nudge = (c.theta - Perch.slopeFollow * slopeDeg(c.x.value), deg, CACurrentMediaTime())
        wake()
    }

    // MARK: pointer: reveal / hide, hover, mouse-through

    private func hotZone(_ m: NSPoint, _ s: NSScreen) -> Bool {
        let menuH = max(s.frame.maxY - s.visibleFrame.maxY, s.safeAreaInsets.top, 6)
        guard m.y >= s.frame.maxY - menuH - 1 else { return false }
        if #available(macOS 12.0, *), let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            return m.x >= l.maxX - 24 && m.x <= r.minX + 24                  // the notch
        }
        return abs(m.x - s.frame.midX) < s.frame.width * 0.16
    }

    private var busy: Bool {
        holds > 0 || draggingCard != nil || down != nil || CACurrentMediaTime() < peekUntil
    }

    private func poll(_ now: CFTimeInterval) {
        let m = NSEvent.mouseLocation
        if !revealed {
            let s = screenWithPointer()
            if hasContent, !isRecording, (NSApp.delegate as? App)?.picker == nil, hotZone(m, s) {
                hotSince = hotSince ?? now
                if now - hotSince! >= 0.25 {
                    hotSince = nil
                    if screen != s { ensurePanel(on: s) }
                    show()
                }
            } else { hotSince = nil }
            return
        }
        guard let p = panel else { return }
        let lowest = p.frame.maxY - maxBottom() - 10
        let over = m.x >= p.frame.minX && m.x <= p.frame.maxX && m.y >= lowest && m.y <= p.frame.maxY + 40
        if over && pinned { pinned = false }
        if over || busy || pinned {
            awaySince = nil
        } else {
            awaySince = awaySince ?? now
            if now - awaySince! >= 0.4 { awaySince = nil; hide(); return }
        }
        // hover + whether the panel should take the mouse at all
        let local = NSPoint(x: m.x - p.frame.minX, y: p.frame.maxY - m.y)     // flipped, strip coordinates (revealed: y = 0)
        let hit = draggingCard == nil ? card(at: local) : nil
        if hit !== hoverCard && down == nil {
            hoverCard?.hovered = false
            hoverCard = hit
            hit?.hovered = true
            hoverSince = now
            if hit == nil { noteTip.isHidden = true }
            layout()
        }
        let btn = button(at: local)
        if btn !== hoverButton { hoverButton = btn; refreshControls() }
        let interactive = hit != nil || btn != nil || (!noteTip.isHidden && noteTip.frame.insetBy(dx: -4, dy: -10).contains(local)) || down != nil
        if p.ignoresMouseEvents == interactive { p.ignoresMouseEvents = !interactive }
    }

    private func card(at p: NSPoint) -> PerchCard? {
        for c in cards.reversed() where !c.flying {
            let r = CGRect(x: c.x.value - Perch.cardW / 2, y: rope.y(at: c.x.value) + Perch.cardTop - 2, width: Perch.cardW,
                           height: Perch.padTop + c.photoSize.height + Perch.padBottom + 2).insetBy(dx: -3, dy: -3)
            if r.contains(p) { return c }
        }
        return nil
    }

    private func button(at p: NSPoint) -> CALayer? {
        for b in [processBtn, clearBtn] where !b.isHidden && b.frame.insetBy(dx: -2, dy: -2).contains(p) { return b }
        return nil
    }

    private func positionNoteTip(_ now: CFTimeInterval) {
        guard let c = hoverCard, !c.dragging, c.shot.hasNote, now - hoverSince > 0.35, !NoteBubble.shared.isOpen else {
            if !noteTip.isHidden && (hoverCard == nil || hoverCard?.shot.hasNote == false || hoverCard?.dragging == true
                                     || draggingCard != nil || NoteBubble.shared.isOpen) { noteTip.isHidden = true }
            return
        }
        if noteTip.isHidden || noteTipFor !== c { buildNoteTip(c) }
        noteTip.isHidden = false
        let w = noteTip.bounds.width
        let top = rope.y(at: c.x.value) + Perch.cardTop + (Perch.padTop + c.photoSize.height + Perch.padBottom) * 1.05 + 10
        noteTip.position = CGPoint(x: min(max(c.x.value, w / 2 + 12), width - w / 2 - 12), y: top + noteTip.bounds.height / 2)
    }
    private weak var noteTipFor: PerchCard?

    private func buildNoteTip(_ c: PerchCard) {
        noteTipFor = c
        let w: CGFloat = 240
        let dark = isDarkMode
        let text = c.shot.text ?? ""
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0.1, alpha: 1)])
        let th = text.isEmpty ? 0 : min(72, ceil(attr.boundingRect(with: NSSize(width: w - 24, height: 200), options: [.usesLineFragmentOrigin]).height) + 2)
        let hasVoice = c.shot.voiceURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let h = 12 + th + (hasVoice ? (th > 0 ? 8 : 0) + 24 : 0) + 12
        noteTip.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        noteText.frame = CGRect(x: 12, y: 12, width: w - 24, height: th)
        noteText.string = attr
        notePlay.isHidden = !hasVoice
        noteWave.isHidden = !hasVoice
        if hasVoice {
            let y = 12 + th + (th > 0 ? 8 : 0)
            notePlay.frame = CGRect(x: 12, y: y, width: 22, height: 22)
            notePlay.string = NSAttributedString(string: "▶", attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold),
                                                                           .foregroundColor: NSColor.white])
            let wave = waveform(c.shot)
            let p = CGMutablePath()
            let x0: CGFloat = 42, ww = w - x0 - 14
            for (i, v) in wave.enumerated() {
                let x = x0 + ww * CGFloat(i) / CGFloat(max(1, wave.count - 1))
                let hh = max(2, CGFloat(v) * 18)
                p.move(to: CGPoint(x: x, y: y + 11 - hh / 2)); p.addLine(to: CGPoint(x: x, y: y + 11 + hh / 2))
            }
            noteWave.frame = noteTip.bounds
            noteWave.path = p
        }
    }

    private func waveform(_ s: Shot) -> [Float] {
        guard let u = s.voiceURL else { return [] }
        if let w = waves[u.path] { return w }
        var out: [Float] = []
        if let f = try? AVAudioFile(forReading: u), let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) {
            try? f.read(into: b)
            let n = Int(b.frameLength), bins = 44
            if let d = b.floatChannelData?[0], n > 0 {
                for i in 0..<bins {
                    let a = i * n / bins, e = max(a + 1, (i + 1) * n / bins)
                    var m: Float = 0
                    for j in a..<e { m = max(m, abs(d[j])) }
                    out.append(m)
                }
                let mx = max(out.max() ?? 1, 0.05)
                out = out.map { sqrt($0 / mx) }
            }
        }
        waves[u.path] = out
        return out
    }

    // MARK: mouse

    func mouseDown(_ e: NSEvent, at p: NSPoint) {
        let c = card(at: p)
        down = (p, c, e, false)
        if let c = c {
            let local = CGPoint(x: p.x - (c.x.value - Perch.cardW / 2), y: p.y - rope.y(at: c.x.value) - Perch.cardTop)
            if c.hovered, !c.piled, local.x < 18, local.y < 18 {      // ×
                down = nil
                snapper.delete(c.shot)
                update(c.shot)
                return
            }
        }
        if !noteTip.isHidden, notePlay.isHidden == false {
            let r = noteTip.convert(notePlay.frame, to: strip)
            if r.insetBy(dx: -6, dy: -6).contains(p), let s = hoverCard?.shot, let u = s.voiceURL {
                player = try? AVAudioPlayer(contentsOf: u)
                player?.play()
                down = nil
            }
        }
    }

    func mouseDragged(_ e: NSEvent, at p: NSPoint) {
        guard var d = down, let c = d.card, !d.dragged else { return }
        guard hypot(p.x - d.p.x, p.y - d.p.y) > 4 else { return }
        d.dragged = true
        down = d
        startDrag(c, event: d.event, at: p)
    }

    func mouseUp(_ e: NSEvent, at p: NSPoint) {
        defer { down = nil }
        guard let d = down, !d.dragged else { return }
        if let b = button(at: p) {
            if b === processBtn { snapper.processBatch() } else { snapper.clearBatch() }
            return
        }
        guard let c = d.card, c === card(at: p) else { return }
        if e.clickCount >= 2 {
            c.copiedUntil = 0
            NoteBubble.shared.begin(c.shot, mode: .edit)
        } else if let u = c.shot.bestURL {
            copyImageToPasteboard(u)
            c.copiedUntil = CACurrentMediaTime() + 1.2
            startNudge(c, 3)
        }
    }

    func rightMouseDown(_ e: NSEvent, at p: NSPoint) {
        guard let c = card(at: p), let v = view else { return }
        let m = NSMenu()
        let items: [(String, () -> Void)] = [
            (L("拷贝图片", "Copy image"), { if let u = c.shot.bestURL { copyImageToPasteboard(u) } }),
            (L("编辑备注…", "Edit note…"), { NoteBubble.shared.begin(c.shot, mode: .edit) }),
            (L("在访达中显示", "Show in Finder"), { if let u = c.shot.bestURL { NSWorkspace.shared.activateFileViewerSelecting([u]) } }),
            (L("删除", "Delete"), { snapper.delete(c.shot); self.update(c.shot) }),
        ]
        for (t, f) in items { m.addItem(ClosureMenuItem(t, f)) }
        m.popUp(positioning: nil, at: p, in: v)
    }

    private func startDrag(_ c: PerchCard, event: NSEvent, at p: NSPoint) {
        guard let u = c.shot.bestURL, let v = view else { return }
        let item = NSPasteboardItem()
        item.setString(u.absoluteString, forType: .fileURL)
        if let t = c.shot.text, !t.isEmpty { item.setString(t, forType: .string) }
        let di = NSDraggingItem(pasteboardWriter: item)
        let size = CGSize(width: Perch.cardW, height: Perch.padTop + c.photoSize.height + Perch.padBottom)
        let img = NSImage(size: size)
        if let rep = cardSnapshot(c) { img.addRepresentation(rep) }
        let origin = NSPoint(x: c.x.value - size.width / 2, y: rope.y(at: c.x.value) + Perch.cardTop)
        di.setDraggingFrame(NSRect(origin: origin, size: size), contents: img)
        c.dragging = true
        draggingCard = c
        // pulling it off the clip sets it swinging and tugs the rope down before it springs back up
        c.omega += CGFloat((p.x - (down?.p.x ?? p.x)) * 6)
        rope.impulse(at: c.x.value, 90 + max(0, p.y - (down?.p.y ?? p.y)) * 4, spread: 90)
        let session = v.beginDraggingSession(with: [di], event: event, source: v)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        wake()
    }

    func dragEnded(operation: NSDragOperation) {
        guard let c = draggingCard else { return }
        c.dragging = false
        draggingCard = nil
        down = nil
        rope.impulse(at: c.x.value, operation.isEmpty ? 110 : 50, spread: 90)   // back on the clip: its weight drops in
        startNudge(c, operation.isEmpty ? 4 : 2)
    }

    private func cardSnapshot(_ c: PerchCard) -> NSBitmapImageRep? {
        let size = c.frame.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let g = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        let ctx = g.cgContext
        ctx.scaleBy(x: 2, y: 2)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        let closeOp = c.close.opacity
        c.close.opacity = 0
        c.frame.render(in: ctx)
        c.close.opacity = closeOp
        return rep
    }
}

final class ClosureMenuItem: NSMenuItem {
    private var fn: (() -> Void)?
    convenience init(_ title: String, _ fn: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.fn = fn
        target = self
    }
    @objc func fire() { fn?() }
}

let perch = Perch()
