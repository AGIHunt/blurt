// Recording chrome that isn't the island: the border around the recorded area, the 3-2-1 countdown, the live caption
// line, and the overlay windows they live in. All of it is excluded from the recording (and from screen captures).
import AppKit
import BlurtCore

/// The recorded area's frame: `rec` solid while the tape rolls, `attn` dashed while paused (the dashes are the shape
/// twin of the colour: they still say "paused" in grayscale). Still in both states: stillness is the signal. A black
/// 35 % under-stroke, 0.75 pt wider each side on the same path (the twin of the selection outline's), holds it on red,
/// white and busy content alike — under the dashes it is dashed too, never a solid line showing through the gaps. The
/// dashes are fitted to each side so every corner is the same: a solid corner, then dashes that start and end on it.
/// All of it stays outside the recorded pixels (the window is the area plus 4 pt a side).
final class BorderView: NSView {
    var color: NSColor = BrandColor.Island.rec { didSet { if color != oldValue { needsDisplay = true } } }
    var dashed = false { didSet { if dashed != oldValue { needsDisplay = true } } }
    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        for (c, w) in [(NSColor(white: 0, alpha: 0.35), CGFloat(4)), (color, CGFloat(2.5))] {
            c.setStroke()
            for p in dashed ? BorderView.dashedPieces(r, radius: 4) : [NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)] {
                p.lineWidth = w
                p.lineCapStyle = dashed ? .butt : .square
                p.stroke()
            }
        }
    }

    /// The paused frame as pieces: four solid corners (the arc and a 5 pt leg each way), and on each side between
    /// them dashes of about 10 pt with 6 pt gaps, stretched a little so a whole number of them fits with a gap at
    /// both ends — so all four corners look alike.
    static func dashedPieces(_ r: NSRect, radius: CGFloat, leg: CGFloat = 5, dash: CGFloat = 10, gap: CGFloat = 6) -> [NSBezierPath] {
        var out: [NSBezierPath] = []
        let k = radius + leg
        // corners: (centre of the arc, start angle) counter-clockwise from the bottom-left, AppKit coordinates
        let corners: [(NSPoint, CGFloat)] = [(NSPoint(x: r.minX + radius, y: r.minY + radius), 180), (NSPoint(x: r.maxX - radius, y: r.minY + radius), 270),
                                             (NSPoint(x: r.maxX - radius, y: r.maxY - radius), 0), (NSPoint(x: r.minX + radius, y: r.maxY - radius), 90)]
        for (c, a) in corners {
            let p = NSBezierPath()
            let rad = a * .pi / 180
            let start = NSPoint(x: c.x + radius * cos(rad), y: c.y + radius * sin(rad))
            // the leg in, the arc, the leg out
            let inDir = NSPoint(x: sin(rad), y: -cos(rad))        // back along the side the arc starts on
            p.move(to: NSPoint(x: start.x + inDir.x * leg, y: start.y + inDir.y * leg))
            p.line(to: start)
            p.appendArc(withCenter: c, radius: radius, startAngle: a, endAngle: a + 90)
            let endRad = (a + 90) * .pi / 180
            let end = NSPoint(x: c.x + radius * cos(endRad), y: c.y + radius * sin(endRad))
            let outDir = NSPoint(x: -sin(endRad), y: cos(endRad))
            p.line(to: NSPoint(x: end.x + outDir.x * leg, y: end.y + outDir.y * leg))
            out.append(p)
        }
        // sides, between the corners' legs
        let sides: [(NSPoint, NSPoint)] = [(NSPoint(x: r.minX + k, y: r.minY), NSPoint(x: r.maxX - k, y: r.minY)),
                                           (NSPoint(x: r.maxX, y: r.minY + k), NSPoint(x: r.maxX, y: r.maxY - k)),
                                           (NSPoint(x: r.maxX - k, y: r.maxY), NSPoint(x: r.minX + k, y: r.maxY)),
                                           (NSPoint(x: r.minX, y: r.maxY - k), NSPoint(x: r.minX, y: r.minY + k))]
        for (a, b) in sides {
            let len = hypot(b.x - a.x, b.y - a.y)
            let n = max(0, Int(((len - gap) / (dash + gap)).rounded()))
            guard n > 0 else { continue }
            let u = len / (CGFloat(n) * dash + CGFloat(n + 1) * gap)
            let d = dash * u, g = gap * u
            let dx = (b.x - a.x) / len, dy = (b.y - a.y) / len
            for i in 0..<n {
                let s0 = g + CGFloat(i) * (d + g)
                let p = NSBezierPath()
                p.move(to: NSPoint(x: a.x + dx * s0, y: a.y + dy * s0))
                p.line(to: NSPoint(x: a.x + dx * (s0 + d), y: a.y + dy * (s0 + d)))
                out.append(p)
            }
        }
        return out
    }
}

/// The 3-2-1 before a take (v0.9-userfix: the old one was a grey disc with a red rim and two loose pills under it,
/// not the island's family). Now a piece of the island over the area about to be recorded: the island's black
/// (`#000`, radius 24, the window's soft shadow), the number in a thin ring that drains once a second in `rec` — the
/// recording is committed (system.md §3.1 / §4) — Peep listening beside "Get ready" (eye wide, swelling), the keys that pause and
/// finish (white 60 %), and "Start now" as the island's tint chip in mint. A click anywhere on it starts at once, as
/// before. Restrained: the ring is the one thing that moves — it drains once over the whole countdown, on the number's
/// own clock (the time left of `total`: at "3" of 3 it is between full and two thirds, at "2" between two thirds and
/// one third), linear, the number swapped with a 0.14 s fade; Reduce Motion keeps the ring full and still. `hold`
/// (tests): the clock stops part-way through the number's second.
final class CountdownView: NSView {
    var n = 3 { didSet { if n != oldValue { numberChanged() } } }
    /// The countdown's length (its first number): the ring is the time left of it.
    var total = 3 { didSet { if total != oldValue { drain() } } }
    var onSkip: (() -> Void)?
    /// tests: the ring stays at this much (no animation)
    var held: CGFloat?

    private let panel = NSView()
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let number = NSTextField(labelWithString: "")
    private let chick = MascotView(size: 26, backdrop: .dark)
    private let title = NSTextField(labelWithString: Loc.t("capture.countdown.ready", table: "Capture"))
    /// the keys that pause and finish the take, as keycaps ("[⌥P] Pause  [⌥S] Finish"); nil when both are off
    private let hint: KeyLine? = {
        let pairs = [(hk(.pause), "capture.countdown.pause"), (hk(.finish), "capture.countdown.finish")]
            .filter { !$0.0.isEmpty }.map { (key: $0.0, word: Loc.t($0.1, table: "Capture")) }
        return pairs.isEmpty ? nil : KeyLine(KeyLine.pairs(pairs), size: 11.5, color: NSColor(white: 1, alpha: 0.6))
    }()
    private var start: IslandButton?
    static let ringD: CGFloat = 92

    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { onSkip?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.black.cgColor
        panel.layer?.cornerRadius = 24
        panel.layer?.borderWidth = 0.5
        panel.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        panel.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor(white: 0, alpha: 0.35)
            s.shadowBlurRadius = 24
            s.shadowOffset = NSSize(width: 0, height: -8)
            return s
        }()
        addSubview(panel)
        for l in [track, ring] {
            l.fillColor = nil
            l.lineWidth = 3
            l.lineCap = .round
            panel.layer?.addSublayer(l)
        }
        track.strokeColor = NSColor(white: 1, alpha: 0.12).cgColor
        ring.strokeColor = BrandColor.Island.rec.cgColor
        number.font = NSFont.monospacedDigitSystemFont(ofSize: 44, weight: .semibold)
        number.textColor = NSColor(white: 1, alpha: 0.92)
        number.alignment = .center
        number.wantsLayer = true
        title.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        title.textColor = NSColor(white: 1, alpha: 0.92)
        for v in [number, title, hint, chick].compactMap({ $0 }) as [NSView] { panel.addSubview(v) }
        let b = IslandButton(title: Loc.t("capture.countdown.start_now", table: "Capture"),
                             tip: Loc.t("capture.countdown.skip", table: "Capture"), fill: BrandColor.Island.tint) { [weak self] in self?.onSkip?() }
        b.fg = BrandColor.Island.fill
        b.setFrameSize(NSSize(width: b.frame.width, height: 24))
        panel.addSubview(b)
        start = b
        chick.play(.listening)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        numberChanged()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The panel's own size (its text decides the width); the window around it needs `panelMargin` more each side
    /// for the shadow.
    var panelSize: NSSize {
        let titleW = ceil(title.intrinsicContentSize.width)
        let hintW = hint?.frame.width ?? 0
        let w = max(232, max(hintW, 26 + 8 + titleW) + 48)
        let h: CGFloat = 20 + CountdownView.ringD + 16 + 26 + (hintW > 0 ? 10 + KeyLine.capH : 0) + 14 + 24 + 18
        return NSSize(width: w, height: h)
    }
    static let panelMargin: CGFloat = 40

    override func layout() {
        super.layout()
        let startW = start?.frame.width ?? 0
        let titleW = ceil(title.intrinsicContentSize.width)
        let size = panelSize
        let w = size.width, h = size.height
        let showsHint = hint != nil
        panel.frame = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        // panel coordinates (not flipped: from the bottom)
        var y = h - 20 - CountdownView.ringD
        let ringRect = CGRect(x: (w - CountdownView.ringD) / 2, y: y, width: CountdownView.ringD, height: CountdownView.ringD)
        let path = CGMutablePath()
        // from 12 o'clock, clockwise as it drains (the stroke's end goes back toward the top)
        path.addArc(center: CGPoint(x: ringRect.midX, y: ringRect.midY), radius: ringRect.width / 2 - 1.5,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.path = path
        ring.path = path
        CATransaction.commit()
        let nh = ceil(number.intrinsicContentSize.height)
        number.frame = NSRect(x: ringRect.minX, y: ringRect.midY - nh / 2, width: ringRect.width, height: nh)
        y -= 16 + 26
        let groupW = 26 + 8 + titleW
        let gx = (w - groupW) / 2
        chick.frame = NSRect(x: gx, y: y, width: 26, height: 26)
        let th = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: gx + 34, y: y + (26 - th) / 2, width: titleW + 2, height: th)
        if showsHint {
            y -= 10 + KeyLine.capH
            if let k = hint { k.frame.origin = NSPoint(x: ((w - k.frame.width) / 2).rounded(), y: y - (k.frame.height - KeyLine.capH) / 2) }
        }
        y -= 14 + 24
        start?.frame.origin = NSPoint(x: (w - startW) / 2, y: y)
    }

    private func numberChanged() {
        if number.stringValue != "", !reduceMotion {
            let t = CATransition()
            t.type = .fade
            t.duration = 0.14
            number.layer?.add(t, forKey: "n")
        }
        number.stringValue = Loc.number(n)
        setAccessibilityLabel(Loc.t("capture.countdown.ready", table: "Capture") + " " + Loc.number(n))
        drain()
    }

    /// The time left as the ring shows it: `n - 1 + p` of `total` seconds, `p` the part of this second still to go.
    static func ringLeft(n: Int, total: Int, p: CGFloat) -> CGFloat {
        max(0, min(1, (CGFloat(n - 1) + max(0, min(1, p))) / CGFloat(max(1, total))))
    }

    /// The ring drains this second's share of the whole countdown (full and still with Reduce Motion; `held` in tests:
    /// that far into the number's second).
    private func drain() {
        ring.removeAnimation(forKey: "drain")
        let from = CountdownView.ringLeft(n: n, total: total, p: 1), to = CountdownView.ringLeft(n: n, total: total, p: 0)
        if let h = held { ring.strokeEnd = CountdownView.ringLeft(n: n, total: total, p: h); return }
        guard !reduceMotion else { ring.strokeEnd = 1; return }
        let a = CABasicAnimation(keyPath: "strokeEnd")
        a.fromValue = from
        a.toValue = to
        a.duration = 1
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        ring.strokeEnd = to
        ring.add(a, forKey: "drain")
    }

    func hold(at progress: CGFloat) { held = progress; drain() }
}

/// One line of what was just said, under the island while recording (record.live_caption, default on). Never captured.
final class CaptionPanel {
    let win: NSWindow
    let fx = NSVisualEffectView()
    let label = NSTextField(labelWithString: "")
    var hideWork: DispatchWorkItem?

    init() {
        win = overlayWindow(NSRect(x: 0, y: 0, width: 300, height: 28), view: fx)
        fx.material = .hudWindow
        fx.state = .active
        fx.appearance = NSAppearance(named: .vibrantDark)
        fx.wantsLayer = true
        fx.maskImage = roundedMask(14)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = NSColor(white: 1, alpha: 0.92)
        label.lineBreakMode = .byTruncatingHead      // the newest words matter most
        label.maximumNumberOfLines = 1
        fx.addSubview(label)
        win.alphaValue = 0
    }

    /// Centred under `anchor` (the island, in screen coordinates).
    func show(_ text: String, under anchor: NSRect) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        label.stringValue = t
        let tw = ceil((t as NSString).size(withAttributes: [.font: label.font!]).width)
        let w = min(max(160, tw + 36), 560)
        var f = NSRect(x: anchor.midX - w / 2, y: anchor.minY - 10 - 28, width: w, height: 28)
        if let s = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })?.frame {
            f.origin.x = max(s.minX + 8, min(f.minX, s.maxX - w - 8))
        }
        win.setFrame(f, display: true)
        fx.frame = NSRect(origin: .zero, size: f.size)
        label.frame = NSRect(x: 14, y: 6, width: w - 28, height: 16)
        win.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.2; win.animator().alphaValue = 1 }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup({ c in c.duration = 0.6; self.win.animator().alphaValue = 0 },
                                                 completionHandler: { if self.win.alphaValue == 0 { self.win.orderOut(nil) } })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func close() { hideWork?.cancel(); win.orderOut(nil) }
}

var liveCaptionOn: Bool { recordConfig()["live_caption"] as? Bool ?? true }

/// A stretchable rounded-rect mask. A layer corner radius doesn't clip a behind-window material on every macOS: the
/// blur then shows as a pale rectangle around the pill on light backgrounds. maskImage does clip it.
func roundedMask(_ radius: CGFloat) -> NSImage {
    let d = radius * 2 + 1
    let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { r in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        return true
    }
    img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    img.resizingMode = .stretch
    return img
}

func overlayWindow(_ frame: NSRect, view: NSView) -> NSWindow {
    let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.level = .statusBar
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = false
    w.ignoresMouseEvents = true
    w.sharingType = chromeSharing
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    view.frame = NSRect(origin: .zero, size: frame.size)
    w.contentView = view
    return w
}
