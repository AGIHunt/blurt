// The claws (K7): every capture that has no project yet (auto mode) hangs on a chicken's foot that reaches down from
// the top edge of the screen, under the island. Replaces the perch and its rope.
//
//  • a capture flies up (a spring) while its claw reaches down (0.35 s ease-out, toes open) and closes on it; the card
//    swings on the claw and settles within about a second.
//  • the cards hang only while you look: for a few seconds after a capture, while the island is hovered or open, while
//    the pointer is over them or a note is open. Otherwise the claws pull them up out of sight and the island's left
//    ear counts them.
//  • hover lifts a card (its neighbours make room) and shows its note · click = copy · double-click = edit the note ·
//    drag = the file (+ its note) into any app, or onto a project in the island · × = the claw lets go and it falls.
//  • assigned (dropped on a project, a capture with a current project, "Let AI sort"): the claw pulls the card up into
//    the island, which swallows it with a small bump.
//  • at most 7 cards show, centred on the island, 12 pt apart, tilted ±2° in turn; older ones stack into "+N".
//  • Reduce Motion: 0.2 s fades, no swing.
// Window: a non-activating panel on all spaces, never captured, mouse-transparent except over a card; it lives on the
// island's screen. The display link runs only while something moves.

import AppKit
import AVFoundation
import BlurtCore
import QuartzCore

final class ClawCard {
    let shot: Shot
    let root = CALayer()            // pivot: the grip point (the card's top centre); the card and the toes hang from it
    let leg: CAGradientLayer
    let scutes: CAReplicatorLayer
    let hind = CALayer(), front = CALayer()
    let card = CALayer()            // shadow + shape
    let face = CALayer()            // photo / voice face, clipped
    let title = CATextLayer()       // voice cards: the words
    let badge = CALayer()
    let close = CALayer()
    let copied = CATextLayer()
    var size: CGSize
    /// where the claw grips the top edge, from the card's left: the middle of a picture; a voice card's waveform disc
    /// (its words stay clear of the toes)
    let gripX: CGFloat
    var x: Spring
    var grip: Spring                // y of the card's top edge (the claw's reach), panel coordinates (y down)
    var theta: CGFloat = 0, omega: CGFloat = 0     // swing, degrees
    let tilt: CGFloat
    var open: CGFloat = 1, openTarget: CGFloat = 0
    var opacity: CGFloat = 0
    var lift = Spring(0, response: 0.28, damping: 0.75)
    var hovered = false
    var dragging = false
    var flying = false              // the capture is still in the air
    var copiedUntil: CFTimeInterval = 0
    /// leaving: falling (delete) or pulled into the island
    var leaving: (start: CFTimeInterval, into: CGPoint?, from: CGPoint)?
    /// the claw reaching down: 0.35 s ease-out from `from` to `to`, starting at `start` (then the spring takes over)
    var reach: (start: CFTimeInterval, from: CGFloat, to: CGFloat)?
    /// assigned while still in the air: pulled into the island right after the catch
    var pullAfterCatch = false

    init(_ s: Shot, x: CGFloat, tilt: CGFloat) {
        shot = s
        size = s.kind == .voice ? Claws.voiceSize : Claws.shotSize
        gripX = s.kind == .voice ? 22 : size.width / 2
        self.x = Spring(x, response: 0.5, damping: 0.82)
        grip = Spring(-Claws.shotSize.height - 40, response: 0.55, damping: 0.72)
        self.tilt = tilt
        (leg, scutes) = ClawArt.makeLeg()
    }
}

final class ClawPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ r: NSRect, to screen: NSScreen?) -> NSRect { r }
}

final class ClawView: NSView, NSDraggingSource {
    weak var claws: Claws?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { claws?.mouseDown(e, at: convert(e.locationInWindow, from: nil)) }
    override func mouseDragged(with e: NSEvent) { claws?.mouseDragged(e, at: convert(e.locationInWindow, from: nil)) }
    override func mouseUp(with e: NSEvent) { claws?.mouseUp(e, at: convert(e.locationInWindow, from: nil)) }
    override func rightMouseDown(with e: NSEvent) { claws?.rightMouseDown(e, at: convert(e.locationInWindow, from: nil)) }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { Loc.t("capture.cards.ax", table: "Capture") }
    override func accessibilityChildren() -> [Any]? { claws?.accessibilityElements() ?? [] }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        (claws?.accessibilityElements() ?? []).reversed().first { $0.accessibilityFrame().contains(point) } ?? self
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : [.generic, .move]
    }
    func draggingSession(_ session: NSDraggingSession, movedTo p: NSPoint) { claws?.dragMoved(to: p) }
    func draggingSession(_ session: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        claws?.dragEnded(at: p, operation: operation)
    }
}

/// A drawn card as an accessibility element: its frame follows the layer.
final class LayerAXElement: NSAccessibilityElement {
    weak var layer: CALayer?
    weak var host: NSView?
    var press: (() -> Void)?

    static func make(role: NSAccessibility.Role, layer: CALayer, host: NSView) -> LayerAXElement {
        let e = LayerAXElement()
        e.setAccessibilityRole(role)
        e.setAccessibilityParent(host)
        e.layer = layer
        e.host = host
        return e
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityFrame() -> NSRect {
        guard let l = layer, let v = host, let root = v.layer, let w = v.window else { return .zero }
        return w.convertToScreen(v.convert(l.convert(l.bounds, to: root), to: nil))
    }
    override func accessibilityPerformPress() -> Bool { press?(); return press != nil }
}

/// The pasteboard type a card carries inside the app: "<batch dir>\n<n>".
let capturePasteboardType = NSPasteboard.PasteboardType("dev.blurt.capture")

final class Claws: NSObject {
    static let shotSize = CGSize(width: 112, height: 84)
    static let voiceSize = CGSize(width: 168, height: 44)
    static let gap: CGFloat = 12
    static let maxShown = 7
    static let below: CGFloat = 18                 // the cards' top edge under the island
    static let panelH: CGFloat = 640

    private var panel: ClawPanel?
    private var view: ClawView!
    private let stage = CALayer()
    private var cards: [ClawCard] = []
    private var leaving: [ClawCard] = []
    private let stack = CALayer(), stackText = CATextLayer()
    private let tip = CALayer(), tipText = CATextLayer(), tipPlay = CALayer()
    private var driver: MotionDriver?
    private(set) var screen: NSScreen?
    private var width: CGFloat = 1440

    private var peekUntil: CFTimeInterval = 0
    private var holds = 0
    private var awaySince: CFTimeInterval?
    private var shown = false                      // the claws are down
    private var hoverCard: ClawCard?
    private var hoverSince: CFTimeInterval = 0
    private var down: (p: NSPoint, card: ClawCard?, event: NSEvent, dragged: Bool)?
    private(set) var dragging: ClawCard?
    private var player: AVAudioPlayer?

    var count: Int { cards.count }
    private var visible: Bool { shown || !leaving.isEmpty || cards.contains { $0.grip.value > -$0.size.height - 30 } }

    // MARK: window

    private func ensurePanel(on s: NSScreen) {
        let f = NSRect(x: s.frame.minX, y: s.frame.maxY - Claws.panelH, width: s.frame.width, height: Claws.panelH)
        if panel == nil {
            let p = ClawPanel(contentRect: f, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.isFloatingPanel = true          // (before the level: it resets the level to .floating)
            p.level = .statusBar
            p.hidesOnDeactivate = false
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.acceptsMouseMovedEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.sharingType = chromeSharing
            p.setAccessibilityTitle(Loc.t("capture.cards.ax", table: "Capture"))
            let v = ClawView(frame: NSRect(origin: .zero, size: f.size))
            v.claws = self
            v.wantsLayer = true
            v.layer?.masksToBounds = true
            v.layer?.addSublayer(stage)
            p.contentView = v
            view = v
            panel = p
            buildChrome()
            let d = MotionDriver(view: v)
            d.tick = { [weak self] dt in self?.frame(dt) ?? false }
            d.idle = { [weak self] in self?.poll(CACurrentMediaTime()) }
            driver = d
        }
        screen = s
        width = f.width
        panel?.setFrame(f, display: false)
        view.frame = NSRect(origin: .zero, size: f.size)
        stage.frame = view.bounds
    }

    private func buildChrome() {
        stack.cornerRadius = 8
        stack.shadowOpacity = 0.25
        stack.shadowRadius = 10
        stack.shadowOffset = CGSize(width: 0, height: 5)
        stack.isHidden = true
        stackText.contentsScale = 2
        stackText.alignmentMode = .center
        stack.addSublayer(stackText)
        stage.addSublayer(stack)
        tip.cornerRadius = 10
        tip.shadowOpacity = 0.22
        tip.shadowRadius = 10
        tip.shadowOffset = CGSize(width: 0, height: 4)
        tip.isHidden = true
        tipText.contentsScale = 2
        tipText.isWrapped = true
        tipText.truncationMode = .end
        tip.addSublayer(tipText)
        tipPlay.cornerRadius = 11
        tip.addSublayer(tipPlay)
        stage.addSublayer(tip)
        restyle()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(themeChanged),
                                                            name: .init("AppleInterfaceThemeChangedNotification"), object: nil)
    }

    @objc private func themeChanged() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.restyle() } }

    private func restyle() {
        let dark = isDarkMode
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for c in cards { style(c) }
        stack.backgroundColor = (dark ? NSColor(calibratedWhite: 0.2, alpha: 0.97) : NSColor(calibratedWhite: 0.985, alpha: 0.98)).cgColor
        stack.borderColor = (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.08)).cgColor
        stack.borderWidth = 0.5
        tip.backgroundColor = (dark ? NSColor(calibratedWhite: 0.16, alpha: 0.98) : NSColor(calibratedWhite: 1, alpha: 0.98)).cgColor
        tip.borderColor = (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.08)).cgColor
        tip.borderWidth = 0.5
        tipPlay.backgroundColor = accent.cgColor
        CATransaction.commit()
    }

    // MARK: building a card

    private func style(_ c: ClawCard) {
        let dark = isDarkMode
        let s = c.shot
        if s.kind == .voice {
            c.card.backgroundColor = (dark ? NSColor(calibratedWhite: 0.17, alpha: 0.98) : NSColor(calibratedWhite: 0.995, alpha: 0.99)).cgColor
            c.card.borderColor = (dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.08)).cgColor
            let f = NSFont.systemFont(ofSize: 12.5, weight: .medium)
            let words = s.words
            let dur = Claws.clock(s.duration ?? 0)
            let text = words ?? Loc.t("capture.voice.card_empty", table: "Capture", dur)
            c.title.string = NSAttributedString(string: text, attributes: [
                .font: f, .foregroundColor: words == nil ? NSColor(white: dark ? 1 : 0, alpha: 0.5) : (dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0.08, alpha: 1))])
        } else {
            c.card.backgroundColor = NSColor(white: 0.5, alpha: 0.2).cgColor
            c.card.borderColor = (dark ? NSColor(white: 1, alpha: 0.22) : NSColor(white: 0, alpha: 0.12)).cgColor
            c.face.contents = s.markedThumb ?? s.thumb
        }
        c.card.shadowOpacity = dark ? 0.55 : 0.3
        let marks: [BlurtIcon] = (s.kind == .shot && s.voice != nil ? [.mic] : []) + (s.marked != nil ? [.ink] : [])
        c.badge.contents = marks.isEmpty ? nil : Claws.badgeImage(marks)
        c.badge.isHidden = marks.isEmpty
    }

    static func clock(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

    /// The small dark capsule with the card's indicator icons (voice note, ink).
    static func badgeImage(_ icons: [BlurtIcon]) -> CGImage? {
        let side: CGFloat = 10, gap: CGFloat = 3, pad: CGFloat = 5
        let w = pad * 2 + CGFloat(icons.count) * side + CGFloat(icons.count - 1) * gap, h: CGFloat = 16
        return renderImage(CGSize(width: w, height: h)) { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.fillPath()
            for (i, ic) in icons.enumerated() {
                ic.draw(in: ctx, rect: CGRect(x: pad + CGFloat(i) * (side + gap), y: 3, width: side, height: side), color: CGColor(gray: 1, alpha: 0.95))
            }
        }
    }

    private func makeCard(_ s: Shot, x: CGFloat) -> ClawCard {
        let i = cards.count + leaving.count
        let c = ClawCard(s, x: x, tilt: i % 2 == 0 ? 2 : -2)
        let w = c.size.width, h = c.size.height
        // the leg and its scutes live in the stage (vertical, never rotate); the card + toes hang from root
        c.leg.anchorPoint = CGPoint(x: 0.5, y: 0)
        c.scutes.anchorPoint = CGPoint(x: 0.5, y: 0)
        c.leg.addSublayer(c.scutes)
        stage.insertSublayer(c.leg, below: stack)
        c.root.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        c.root.anchorPoint = CGPoint(x: c.gripX / w, y: 0)
        c.root.opacity = 0
        let fs = ClawArt.footSize, k = ClawArt.knuckle
        c.hind.frame = CGRect(x: c.gripX - k.x, y: -k.y - 3, width: fs.width, height: fs.height)
        c.front.frame = c.hind.frame
        c.card.frame = CGRect(x: 0, y: 0, width: w, height: h)
        c.card.cornerRadius = s.kind == .voice ? 12 : 7
        c.card.borderWidth = 0.5
        c.card.shadowColor = NSColor.black.cgColor
        c.card.shadowRadius = 12
        c.card.shadowOffset = CGSize(width: 0, height: 6)
        c.face.frame = c.card.bounds
        c.face.cornerRadius = c.card.cornerRadius
        c.face.masksToBounds = true
        c.face.contentsGravity = .resizeAspectFill
        c.card.addSublayer(c.face)
        if s.kind == .voice {
            let disc = CALayer()
            disc.frame = CGRect(x: 8, y: (h - 28) / 2, width: 28, height: 28)
            disc.cornerRadius = 14
            disc.backgroundColor = accent.withAlphaComponent(0.14).cgColor
            let wave = BlurtIcon.waveform.makeLayer(size: 16, color: accent.cgColor)
            wave.position = CGPoint(x: 14, y: 14)
            disc.addSublayer(wave)
            c.card.addSublayer(disc)
            c.title.frame = CGRect(x: 44, y: (h - 17) / 2, width: w - 52, height: 17)
            c.title.contentsScale = 2
            c.title.truncationMode = .end
            c.card.addSublayer(c.title)
        }
        c.badge.frame = CGRect(x: w - 6 - 31, y: h - 6 - 16, width: 31, height: 16)
        c.badge.contentsGravity = .topRight
        c.badge.contentsScale = 2
        c.card.addSublayer(c.badge)
        c.close.frame = CGRect(x: -8, y: -8, width: 20, height: 20)
        c.close.cornerRadius = 10
        c.close.backgroundColor = NSColor(white: 0.12, alpha: 0.9).cgColor
        c.close.borderColor = NSColor(white: 1, alpha: 0.85).cgColor
        c.close.borderWidth = 1
        let x = BlurtIcon.x.makeLayer(size: 11, color: NSColor.white.cgColor)
        x.position = CGPoint(x: 10, y: 10)
        c.close.addSublayer(x)
        c.close.opacity = 0
        c.copied.frame = CGRect(x: w / 2 - 40, y: h + 8, width: 80, height: 22)
        c.copied.contentsScale = 2
        c.copied.alignmentMode = .center
        c.copied.cornerRadius = 11
        c.copied.backgroundColor = NSColor(white: 0.08, alpha: 0.88).cgColor
        let cf = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        c.copied.string = NSAttributedString(string: Loc.t("capture.card.copied", table: "Capture"), attributes: [.font: cf, .foregroundColor: NSColor.white])
        c.copied.opacity = 0
        c.root.addSublayer(c.hind)
        c.root.addSublayer(c.card)
        c.root.addSublayer(c.front)
        c.root.addSublayer(c.close)
        c.root.addSublayer(c.copied)
        stage.insertSublayer(c.root, below: stack)
        style(c)
        return c
    }

    // MARK: layout

    /// The island's centre and the cards' top edge, in panel coordinates.
    private var anchor: (x: CGFloat, y: CGFloat) {
        guard let s = screen else { return (width / 2, 60) }
        let f = island.frameOnScreen
        return (f.midX - s.frame.minX, s.frame.maxY - f.minY + Claws.below)
    }

    private var pile: Int { max(0, cards.count - Claws.maxShown) }

    /// Rest x for each card (the piled ones under the stack), and the stack's x.
    private func targets() -> (xs: [CGFloat], stackX: CGFloat?) {
        let shown = Array(cards.suffix(Claws.maxShown))
        var widths = shown.map(\.size.width)
        let hasStack = pile > 0
        if hasStack { widths.insert(Claws.shotSize.width, at: 0) }
        let total = widths.reduce(0, +) + Claws.gap * CGFloat(max(0, widths.count - 1))
        var x = anchor.x - total / 2
        var centres: [CGFloat] = []
        for w in widths { centres.append(x + w / 2); x += w + Claws.gap }
        let stackX = hasStack ? centres.removeFirst() : nil
        let hi = hoverCard.flatMap { h in shown.firstIndex { $0 === h } }
        var xs: [CGFloat] = []
        for (i, c) in cards.enumerated() {
            let j = i - pile
            if j < 0 { xs.append(stackX ?? anchor.x); continue }
            var cx = centres[j]
            if let h = hi, j != h { cx += j < h ? -10 : 10 }        // neighbours make room
            _ = c
            xs.append(cx)
        }
        return (xs, stackX)
    }

    /// Sync the cards with the captures (new ones appear quietly, gone ones leave).
    func refresh(quiet: Bool = false) {
        let want = snapper.cards
        // a capture that came with a project hangs only until it is pulled into the island (pullIn removes it)
        for c in cards where !want.contains(where: { $0 === c.shot }) && dragging !== c
            && !(c.shot.assignedBy == "capture" && !c.shot.deleted) { remove(c, fall: false) }
        for s in want where !cards.contains(where: { $0.shot === s }) {
            if panel == nil { ensurePanel(on: island.screen ?? NSScreen.main ?? NSScreen.screens[0]) }
            let c = makeCard(s, x: anchor.x)
            c.opacity = 1
            c.open = 0
            c.openTarget = 0
            cards.append(c)
        }
        layout(instant: quiet)
        island.cardsChanged(cards.filter { $0.shot.isCard }.count)
    }

    func layout(instant: Bool = false) {
        guard view != nil else { return }
        let t = targets()
        for (i, c) in cards.enumerated() {
            c.x.target = t.xs[i]
            if instant { c.x.snap() }
            c.root.zPosition = CGFloat(i)
            c.leg.zPosition = CGFloat(i) - 0.5
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stack.isHidden = t.stackX == nil
        if let sx = t.stackX {
            let sz = Claws.shotSize
            stack.bounds = CGRect(origin: .zero, size: sz)
            stack.position = CGPoint(x: sx, y: 0)
            stack.anchorPoint = CGPoint(x: 0.5, y: 0)
            let f = NSFont.systemFont(ofSize: 18, weight: .semibold)
            stackText.string = NSAttributedString(string: "+\(pile)", attributes: [.font: f, .foregroundColor: isDarkMode ? NSColor.white : NSColor(white: 0.1, alpha: 1)])
            stackText.frame = CGRect(x: 0, y: (sz.height - 24) / 2, width: sz.width, height: 24)
        }
        CATransaction.commit()
        wake()
    }

    private func remove(_ c: ClawCard, fall: Bool) {
        guard let i = cards.firstIndex(where: { $0 === c }) else { return }
        cards.remove(at: i)
        if hoverCard === c { hoverCard = nil; tip.isHidden = true }
        if fall, visible, !reduceMotion {
            c.leaving = (CACurrentMediaTime(), nil, c.root.position)
            c.openTarget = 1
            leaving.append(c)
        } else {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            CATransaction.setCompletionBlock { c.root.removeFromSuperlayer(); c.leg.removeFromSuperlayer() }
            c.root.opacity = 0
            c.leg.opacity = 0
            CATransaction.commit()
        }
        layout()
        island.cardsChanged(cards.filter { $0.shot.isCard }.count)
    }

    // MARK: arrivals and departures

    /// A capture is complete: its claw reaches down and catches it as it flies up from `from` (a screen rect).
    func catchCapture(_ s: Shot, from: NSRect?) {
        let target = island.screen ?? from.flatMap { r in NSScreen.screens.first { $0.frame.intersects(r) } } ?? NSScreen.main ?? NSScreen.screens[0]
        if panel == nil || screen != target { ensurePanel(on: target) }
        // the batch's change callback may have hung it already (quietly): catch that card
        let c = cards.first { $0.shot === s } ?? makeCard(s, x: anchor.x)
        if !cards.contains(where: { $0 === c }) { cards.append(c) }
        layout()
        if let i = cards.firstIndex(where: { $0 === c }) { c.x.value = targets().xs[i]; c.x.snap() }
        show(peek: 3.2)
        island.cardsChanged(cards.filter { $0.shot.isCard }.count)
        let restY = anchor.y
        if reduceMotion {
            c.grip.value = restY; c.grip.snap()
            c.open = 0; c.openTarget = 0
            fadeIn(c)
            return
        }
        c.flying = true
        c.open = 1
        c.openTarget = 1
        c.grip.value = -c.size.height - 30
        c.reach = (CACurrentMediaTime() + 0.15, c.grip.value, restY)   // reaches the catch point as the capture arrives
        let img = s.kind == .voice ? Claws.voiceSnapshot(c) : (s.markedThumb ?? s.thumb)
        if let f = from, let img = img {
            flyImage(img, from: f, to: screenRect(of: c, at: restY), springy: true, cornerRadius: c.card.cornerRadius) { [weak self] in
                self?.caught(c)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in self?.caught(c) }
        }
        wake()
    }

    private func caught(_ c: ClawCard) {
        c.flying = false
        c.opacity = 1
        c.openTarget = 0
        c.omega += 30            // the catch sets it swinging
        wake()
        if c.pullAfterCatch {    // a capture with a project: caught, a beat, then up into the island
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.pullIn(c.shot) }
        }
    }

    private func fadeIn(_ c: ClawCard) {
        c.opacity = 1
        c.root.opacity = 0
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0; a.toValue = 1; a.duration = 0.2
        c.root.add(a, forKey: "in")
        wake()
    }

    /// Assigned: the claw pulls the card up into the island (0.45 s ease-in, shrinking to 0.2), which bumps.
    func pullIn(_ s: Shot) {
        guard let c = cards.first(where: { $0.shot === s }) else { island.bump(); return }
        if c.flying { c.pullAfterCatch = true; return }
        if let i = cards.firstIndex(where: { $0 === c }) { cards.remove(at: i) }
        if hoverCard === c { hoverCard = nil; tip.isHidden = true }
        let a = anchor
        c.leaving = (CACurrentMediaTime(), CGPoint(x: a.x, y: a.y - Claws.below - island.frameOnScreen.height / 2), c.root.position)
        if !c.flying { show(peek: 1.0) }
        leaving.append(c)
        layout()
        island.cardsChanged(cards.filter { $0.shot.isCard }.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.2 : 0.45)) { island.bump() }
    }

    func pullInAll(_ shots: [Shot]) {
        for (i, s) in shots.enumerated() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.07 * Double(i)) { self.pullIn(s) } }
    }

    /// Deleted: the claw lets go and the card falls (0.5 s) — if it is in view; else it just goes.
    func drop(_ s: Shot) {
        guard let c = cards.first(where: { $0.shot === s }) else { return }
        remove(c, fall: true)
    }

    func update(_ s: Shot) {
        guard let c = cards.first(where: { $0.shot === s }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        style(c)
        CATransaction.commit()
        if hoverCard === c { tip.isHidden = true }
    }

    /// The note bubble (or a drag) keeps the cards down.
    func hold(_ on: Bool) {
        holds = max(0, holds + (on ? 1 : -1))
        if on { show() }
        wake()
    }

    func show(peek: Double = 0) {
        if panel == nil { ensurePanel(on: island.screen ?? NSScreen.main ?? NSScreen.screens[0]) }
        if peek > 0 { peekUntil = max(peekUntil, CACurrentMediaTime() + peek) }
        awaySince = nil
        guard !shown else { return }
        shown = true
        panel?.orderFrontRegardless()
        island.orderFront()                 // the island stays above the claws
        wake()
    }

    private func retract() {
        guard shown else { return }
        shown = false
        hoverCard?.hovered = false
        hoverCard = nil
        tip.isHidden = true
        panel?.ignoresMouseEvents = true
        wake()
    }

    func screenRect(of s: Shot) -> NSRect? {
        guard let c = cards.first(where: { $0.shot === s }) else { return nil }
        return screenRect(of: c, at: c.grip.target)
    }

    private func screenRect(of c: ClawCard, at y: CGFloat) -> NSRect {
        guard let p = panel else { return .zero }
        return NSRect(x: p.frame.minX + c.x.target - c.size.width / 2, y: p.frame.maxY - y - c.size.height, width: c.size.width, height: c.size.height)
    }

    /// The cards' swing right now (degrees; tests check Reduce Motion keeps them still).
    var swing: [CGFloat] { cards.map(\.theta) }

    /// Where every card is, for tests (global top-left points).
    func cardRects() -> [(Shot, CGRect)] { cards.compactMap { c in screenRect(of: c.shot).map { (c.shot, toCG($0)) } } }

    // MARK: animation

    private func wake() { driver?.wake() }

    /// The island changed size or place: the cards hang from under it.
    func islandMoved() {
        if let s = island.screen, s != screen, !shown, dragging == nil { ensurePanel(on: s) }
        if shown || !leaving.isEmpty { wake() }
    }

    private func frame(_ dt: CGFloat) -> Bool {
        let now = CACurrentMediaTime()
        poll(now)
        let a = anchor
        let reduce = reduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var moving = false
        for c in cards {
            // the claw's reach: down to the island when shown, up out of sight when not
            let rest = a.y - 6 * c.lift.value
            let hiddenY = -c.size.height - 34
            if let r = c.reach {
                let k = CGFloat(max(0, now - r.start) / 0.35)
                c.grip.value = r.from + (rest - r.from) * Ease.outCubic(k)
                c.grip.velocity = 0
                c.grip.target = rest
                if k >= 1 { c.reach = nil }
                moving = true
            } else {
                c.grip.target = c.dragging ? hiddenY : (shown || c.flying ? rest : hiddenY)
                if c.grip.target < c.grip.value - 0.5, !c.dragging, !shown {
                    // pulling up: an ease-in, not a spring (nothing bounces off the top of the screen)
                    c.grip.value += (c.grip.target - c.grip.value) * min(1, dt * 9)
                    c.grip.velocity = 0
                } else { _ = c.grip.step(dt) }
            }
            if reduce { c.grip.snap() }
            _ = c.x.step(dt)
            c.lift.target = c.hovered && !c.dragging ? 1 : 0
            _ = c.lift.step(dt)
            // swing: a damped pendulum around the grip; sideways motion of the claw drives it
            let restTheta: CGFloat = 0
            let drive = -c.x.velocity * 0.012
            var left = dt
            let damp: CGFloat = c.hovered ? 16 : 4.4
            while left > 0 {
                let h = min(left, 1.0 / 240)
                let acc = -46 * (c.theta - restTheta) - damp * c.omega + drive * 46
                c.omega += acc * h
                c.theta += c.omega * h
                left -= h
            }
            if reduce { c.theta = 0; c.omega = 0; c.x.snap(); c.lift.snap() }
            c.open += (c.openTarget - c.open) * min(1, dt * (c.openTarget > c.open ? 22 : 14))
            if abs(c.open - c.openTarget) < 0.02 { c.open = c.openTarget }
            place(c, now: now)
            if !c.x.resting || !c.grip.resting || !c.lift.resting || abs(c.theta) > 0.12 || abs(c.omega) > 0.4
                || c.open != c.openTarget || c.flying || now < c.copiedUntil + 0.1 { moving = true }
        }
        stack.position = CGPoint(x: stack.position.x, y: cards.first.map { $0.grip.value } ?? 0)
        for c in leaving { stepLeaving(c, now) }
        leaving.removeAll { c in
            guard let l = c.leaving, now - l.start > 0.55 else { return false }
            c.root.removeFromSuperlayer()
            c.leg.removeFromSuperlayer()
            return true
        }
        positionTip(now)
        CATransaction.commit()
        if !leaving.isEmpty { moving = true }
        if hoverCard?.shot.hasNote == true || hoverCard?.shot.kind == .voice, tip.isHidden, now - hoverSince < 0.6 { moving = true }
        if !visible { panel?.orderOut(nil) } else if moving == false, !shown { panel?.orderOut(nil) }
        return moving || shown && (now < peekUntil)
    }

    private func place(_ c: ClawCard, now: CFTimeInterval) {
        let y = c.grip.value
        let swing = reduceMotion ? 0 : c.theta + c.tilt * (1 - c.lift.value)
        let gx = c.x.value - c.size.width / 2 + c.gripX
        c.root.position = CGPoint(x: gx, y: y)
        var t = CATransform3DMakeRotation(swing * .pi / 180, 0, 0, 1)
        let sc = 1 + 0.04 * c.lift.value
        t = CATransform3DScale(t, sc, sc, 1)
        c.root.transform = t
        c.root.opacity = Float(c.flying ? 0 : (c.dragging ? 0 : c.opacity))
        // the leg: from the top of the screen down to the knuckle (just above the card's edge)
        let legH = max(0, y - ClawArt.knuckle.y + 3)
        c.leg.bounds = CGRect(x: 0, y: 0, width: ClawArt.legWidth, height: legH)
        c.leg.position = CGPoint(x: gx, y: 0)
        c.scutes.instanceCount = max(0, Int(legH / 6.5))
        c.scutes.frame = c.leg.bounds
        c.leg.opacity = legH > 0.5 ? 1 : 0
        c.front.contents = ClawArt.foot(front: true, open: c.open)
        c.hind.contents = ClawArt.foot(front: false, open: c.open)
        c.card.shadowRadius = 12 + 6 * c.lift.value
        c.card.shadowOffset = CGSize(width: 0, height: 6 + 4 * c.lift.value)
        c.close.opacity = c.hovered && !c.dragging ? 1 : 0
        c.copied.opacity = now < c.copiedUntil ? 1 : 0
    }

    private func stepLeaving(_ c: ClawCard, _ now: CFTimeInterval) {
        guard let l = c.leaving else { return }
        let raw = CGFloat(max(0, min(1, (now - l.start) / (reduceMotion ? 0.2 : (l.into == nil ? 0.5 : 0.45)))))
        if reduceMotion {
            c.root.opacity = Float(1 - raw)
            c.leg.opacity = Float(1 - raw)
            return
        }
        c.open += (1 - c.open) * 0.3
        c.front.contents = ClawArt.foot(front: true, open: c.open)
        c.hind.contents = ClawArt.foot(front: false, open: c.open)
        if let g = l.into {
            // pulled into the island: ease-in towards its centre, shrinking to 0.2
            let k = Ease.inCubic(raw)
            let p = CGPoint(x: l.from.x + (g.x - l.from.x) * k, y: l.from.y + (g.y - l.from.y) * k)
            c.root.position = p
            let s = 1 - 0.8 * k
            c.root.transform = CATransform3DScale(CATransform3DMakeRotation(c.theta * (1 - k) * .pi / 180, 0, 0, 1), s, s, 1)
            c.root.opacity = Float(raw > 0.8 ? (1 - raw) / 0.2 : 1)
            c.leg.bounds = CGRect(x: 0, y: 0, width: ClawArt.legWidth, height: max(0, p.y - ClawArt.knuckle.y + 3))
            c.leg.position = CGPoint(x: p.x, y: 0)
            c.scutes.instanceCount = max(0, Int(c.leg.bounds.height / 6.5))
            c.scutes.frame = c.leg.bounds
        } else {
            // the claw lets go: gravity, a turn, a fade; the empty claw goes back up
            let e = raw * raw
            let angle = c.tilt + c.theta + (c.tilt >= 0 ? 1 : -1) * 28 * e
            var t = CATransform3DMakeTranslation(0, 560 * e, 0)
            t = CATransform3DRotate(t, angle * .pi / 180, 0, 0, 1)
            c.root.transform = t
            c.root.opacity = Float(1 - raw)
            let legH = max(0, (l.from.y - ClawArt.knuckle.y + 3) * (1 - Ease.inOutCubic(min(1, raw * 1.6))))
            c.leg.bounds = CGRect(x: 0, y: 0, width: ClawArt.legWidth, height: legH)
            c.scutes.instanceCount = max(0, Int(legH / 6.5))
            c.scutes.frame = c.leg.bounds
        }
    }

    // MARK: pointer

    private var busy: Bool { holds > 0 || dragging != nil || down != nil || CACurrentMediaTime() < peekUntil }

    private func poll(_ now: CFTimeInterval) {
        guard let p = panel else { return }
        let m = NSEvent.mouseLocation
        let attention = island.wantsCards
        if !shown {
            if attention && !cards.isEmpty { show() }
            return
        }
        let local = NSPoint(x: m.x - p.frame.minX, y: p.frame.maxY - m.y)
        let over = card(at: local) != nil || (stack.isHidden == false && stack.frame.insetBy(dx: -6, dy: -6).contains(local))
            || (!tip.isHidden && tip.frame.insetBy(dx: -6, dy: -10).contains(local))
        if over || busy || attention { awaySince = nil } else {
            awaySince = awaySince ?? now
            if now - awaySince! >= 0.4 { awaySince = nil; retract(); return }
        }
        let hit = dragging == nil ? card(at: local) : nil
        if hit !== hoverCard && down == nil {
            hoverCard?.hovered = false
            hoverCard = hit
            hit?.hovered = true
            hoverSince = now
            if hit == nil { tip.isHidden = true }
            layout()
        }
        let interactive = hit != nil || down != nil || (!tip.isHidden && tip.frame.insetBy(dx: -4, dy: -10).contains(local))
        if p.ignoresMouseEvents == interactive { p.ignoresMouseEvents = !interactive }
    }

    private func card(at p: NSPoint) -> ClawCard? {
        for c in cards.suffix(Claws.maxShown).reversed() where !c.flying && !c.dragging {
            let r = CGRect(x: c.x.value - c.size.width / 2, y: c.grip.value - 8, width: c.size.width, height: c.size.height + 8).insetBy(dx: -4, dy: -4)
            if r.contains(p) { return c }
        }
        return nil
    }

    // MARK: the note under a hovered card

    private weak var tipFor: ClawCard?

    private func positionTip(_ now: CFTimeInterval) {
        guard let c = hoverCard, !c.dragging, c.shot.hasNote || c.shot.kind == .voice, now - hoverSince > 0.35, !NoteBubble.shared.isOpen else {
            if !tip.isHidden, hoverCard == nil || dragging != nil || NoteBubble.shared.isOpen { tip.isHidden = true }
            return
        }
        if tip.isHidden || tipFor !== c { buildTip(c) }
        tip.isHidden = false
        let w = tip.bounds.width
        let top = c.grip.value + c.size.height * 1.04 + 12
        tip.position = CGPoint(x: min(max(c.x.value, w / 2 + 12), width - w / 2 - 12), y: top + tip.bounds.height / 2)
    }

    private func buildTip(_ c: ClawCard) {
        tipFor = c
        let w: CGFloat = 260
        let dark = isDarkMode
        let text = c.shot.words ?? ""
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0.1, alpha: 1)])
        let th = text.isEmpty ? 0 : min(72, ceil(attr.boundingRect(with: NSSize(width: w - 24, height: 200), options: [.usesLineFragmentOrigin]).height) + 2)
        let hasVoice = c.shot.voiceURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let h = 12 + th + (hasVoice ? (th > 0 ? 8 : 0) + 22 : 0) + 12
        tip.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        tipText.frame = CGRect(x: 12, y: 12, width: w - 24, height: th)
        tipText.string = attr
        tipPlay.isHidden = !hasVoice
        if hasVoice {
            tipPlay.frame = CGRect(x: 12, y: 12 + th + (th > 0 ? 8 : 0), width: 22, height: 22)
            if tipPlay.sublayers == nil {
                let play = BlurtIcon.playFill.makeLayer(size: 10, color: NSColor.white.cgColor)
                play.position = CGPoint(x: 11.6, y: 11)
                tipPlay.addSublayer(play)
            }
        }
    }

    // MARK: mouse

    func mouseDown(_ e: NSEvent, at p: NSPoint) {
        let c = card(at: p)
        down = (p, c, e, false)
        if let c = c {
            let local = CGPoint(x: p.x - (c.x.value - c.size.width / 2), y: p.y - c.grip.value)
            if c.hovered, local.x < 16, local.y < 16 {          // ×
                down = nil
                snapper.delete(c.shot)
                return
            }
        }
        if !tip.isHidden, !tipPlay.isHidden, tip.convert(tipPlay.frame, to: stage).insetBy(dx: -6, dy: -6).contains(p),
           let u = tipFor?.shot.voiceURL {
            player = try? AVAudioPlayer(contentsOf: u)
            player?.play()
            down = nil
        }
    }

    func mouseDragged(_ e: NSEvent, at p: NSPoint) {
        guard var d = down, let c = d.card, !d.dragged, hypot(p.x - d.p.x, p.y - d.p.y) > 4 else { return }
        d.dragged = true
        down = d
        startDrag(c, event: d.event)
    }

    func mouseUp(_ e: NSEvent, at p: NSPoint) {
        defer { down = nil }
        guard let d = down, !d.dragged, let c = d.card, c === card(at: p) else { return }
        if e.clickCount >= 2 {
            c.copiedUntil = 0
            NoteBubble.shared.begin(c.shot, mode: .edit)
        } else if c.shot.kind == .shot, let u = c.shot.bestURL {
            copyImageToPasteboard(u)
            c.copiedUntil = CACurrentMediaTime() + 1.2
            c.omega += 30
            wake()
        } else if c.shot.kind == .voice, let t = c.shot.words {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(t, forType: .string)
            c.copiedUntil = CACurrentMediaTime() + 1.2
            wake()
        }
    }

    func rightMouseDown(_ e: NSEvent, at p: NSPoint) {
        guard let c = card(at: p), let v = view else { return }
        let m = NSMenu()
        let s = c.shot
        var items: [(String, () -> Void)] = []
        if s.kind == .shot { items.append((Loc.t("capture.card.copy_image", table: "Capture"), { if let u = s.bestURL { copyImageToPasteboard(u) } })) }
        items.append((Loc.t("capture.card.edit_note", table: "Capture"), { NoteBubble.shared.begin(s, mode: .edit) }))
        items.append((Loc.t("capture.card.reveal", table: "Capture"), { if let u = s.bestURL { NSWorkspace.shared.activateFileViewerSelecting([u]) } }))
        for (t, f) in items { m.addItem(ClosureMenuItem(t, f)) }
        m.addItem(.separator())
        let move = NSMenuItem(title: Loc.t("capture.card.move_to", table: "Capture"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for proj in ProjectStore.shared.projects.prefix(12) {
            sub.addItem(ClosureMenuItem(proj.name) { snapper.assign(s, to: proj.id) })
        }
        sub.addItem(.separator())
        sub.addItem(ClosureMenuItem(Loc.t("project.inbox")) { snapper.assign(s, to: "inbox") })
        move.submenu = sub
        m.addItem(move)
        m.addItem(ClosureMenuItem(Loc.t("project.ai_sort")) { snapper.aiSort() })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(Loc.t("capture.card.delete", table: "Capture")) { snapper.delete(s) })
        if cards.count > 1 {
            m.addItem(ClosureMenuItem(Loc.plural("capture.card.delete_all", table: "Capture", count: cards.count)) { snapper.deleteAllCards() })
        }
        m.popUp(positioning: nil, at: p, in: v)
    }

    private func startDrag(_ c: ClawCard, event: NSEvent) {
        guard let v = view else { return }
        let item = NSPasteboardItem()
        if let u = c.shot.bestURL { item.setString(u.absoluteString, forType: .fileURL) }
        if let t = c.shot.words { item.setString(t, forType: .string) }
        if let b = c.shot.batch { item.setString("\(b.dir.path)\n\(c.shot.n)", forType: capturePasteboardType) }
        let di = NSDraggingItem(pasteboardWriter: item)
        let img = NSImage(size: c.size)
        if let rep = Claws.snapshot(c) { img.addRepresentation(rep) }
        di.setDraggingFrame(NSRect(x: c.x.value - c.size.width / 2, y: c.grip.value, width: c.size.width, height: c.size.height), contents: img)
        c.dragging = true
        c.openTarget = 1                     // the claw lets go and goes back up (0.3 s)
        dragging = c
        island.dragBegan()
        let session = v.beginDraggingSession(with: [di], event: event, source: v)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        wake()
    }

    func dragMoved(to p: NSPoint) { island.dragMoved(to: p) }

    func dragEnded(at p: NSPoint, operation: NSDragOperation) {
        guard let c = dragging else { return }
        dragging = nil
        down = nil
        let taken = island.dragEnded(at: p)
        c.dragging = false
        if taken || !c.shot.isCard {
            remove(c, fall: false)
            return
        }
        // back on the claw: it reaches down again and closes on the card
        c.reach = (CACurrentMediaTime() + (operation.isEmpty ? 0.25 : 0), c.grip.value, anchor.y)
        c.openTarget = 0
        c.omega += operation.isEmpty ? 60 : 30
        show(peek: 1.5)
        wake()
    }

    // MARK: images of a card

    static func snapshot(_ c: ClawCard) -> NSBitmapImageRep? {
        let size = c.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let g = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        let ctx = g.cgContext
        ctx.scaleBy(x: 2, y: 2)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        let shadow = c.card.shadowOpacity
        c.card.shadowOpacity = 0
        c.card.render(in: ctx)
        c.card.shadowOpacity = shadow
        return rep
    }

    static func voiceSnapshot(_ c: ClawCard) -> CGImage? { snapshot(c)?.cgImage }

    // MARK: accessibility

    private var axCards: [ObjectIdentifier: LayerAXElement] = [:]

    func accessibilityElements() -> [LayerAXElement] {
        guard let v = view else { return [] }
        var out: [LayerAXElement] = []
        var keep: [ObjectIdentifier: LayerAXElement] = [:]
        for c in cards.suffix(Claws.maxShown) where !c.flying {
            let key = ObjectIdentifier(c)
            let e = axCards[key] ?? {
                let e = LayerAXElement.make(role: .button, layer: c.card, host: v)
                let s = c.shot
                e.press = { [weak self] in
                    if s.kind == .shot, let u = s.bestURL { copyImageToPasteboard(u) }
                    c.copiedUntil = CACurrentMediaTime() + 1.2
                    self?.wake()
                }
                var actions = [NSAccessibilityCustomAction(name: Loc.t("capture.card.edit_note", table: "Capture")) { NoteBubble.shared.begin(s, mode: .edit); return true }]
                for p in ProjectStore.shared.projects.prefix(8) {
                    actions.append(NSAccessibilityCustomAction(name: Loc.t("capture.card.ax_move", table: "Capture", p.name)) { snapper.assign(s, to: p.id); return true })
                }
                actions.append(NSAccessibilityCustomAction(name: Loc.t("project.ai_sort")) { snapper.aiSort(); return true })
                actions.append(NSAccessibilityCustomAction(name: Loc.t("capture.card.delete", table: "Capture")) { snapper.delete(s); return true })
                e.setAccessibilityCustomActions(actions)
                return e
            }()
            e.setAccessibilityLabel(Claws.cardLabel(c.shot))
            e.setAccessibilityRoleDescription(Loc.t(c.shot.kind == .voice ? "capture.card.ax_voice" : "capture.card.ax_shot", table: "Capture"))
            e.setAccessibilityHelp(Loc.t("capture.card.ax_help", table: "Capture"))
            keep[key] = e
            out.append(e)
        }
        axCards = keep
        return out
    }

    /// A card's spoken name: its words, or "Screenshot N" / "Voice note N".
    static func cardLabel(_ s: Shot) -> String {
        if let t = s.words { return t }
        return Loc.t(s.kind == .voice ? "capture.card.ax_voice_n" : "capture.card.ax_shot_n", table: "Capture", s.n)
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

let claws = Claws()
