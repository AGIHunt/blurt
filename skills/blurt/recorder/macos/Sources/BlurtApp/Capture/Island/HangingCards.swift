// The hanging cards (K7): every capture that has no project yet (auto mode) hangs from the island on a thin thread,
// a small clasp in the brand colour where it holds the card. A few cards read like a wind chime: one thread each,
// lengths a little uneven. Replaces the v0.6 perch and its rope.
//
//  • a capture flies up while its thread drops out of the island (0.35 s ease-out) and catches it; the card sways on
//    the thread and settles within about a second.
//  • the cards hang only while you look: for a few seconds after a capture, while a note is open, and while the pointer
//    is on the island or on the cards — hovering (or opening) the island drops every card together with the island's
//    detail, and the island stays open while the pointer is on the cards. About 0.4 s after the pointer has left both,
//    the threads reel the cards back into the island, whose left ear counts them.
//  • brought down on purpose — a click on the left ear's count, ⌥⇧H "Show hanging cards" (record.hotkeys "cards"),
//    the menu, the main window's "Unfiled captures" — they stay (sticky) until the pointer has come to the cards and
//    gone again, or Esc.
//    The pointer resting on the ear itself opens the island a little later (0.45 s), so its count can be clicked.
//  • hover shortens the thread and lifts the card (its neighbours make room) and shows its note · click = copy (a voice
//    card: its words; a shot: the image — inked if marked — with its note / words as the same item's text, for apps
//    that only take text) · right-click: Copy Image / Copy Text (only with text), edit, move, delete · double-click =
//    edit the note · drag = the file (+ its words) into any app, or onto a project in the island: the thread stretches
//    after it, then snaps and springs back up · × = the thread lets go and the card falls.
//  • assigned (dropped on a project, a capture with a current project, "Let AI sort"): the thread reels the card up
//    into the island, which swallows it with a small bump.
//  • at most 7 cards show, centred on the island, 12 pt apart, tilted ±2° in turn; older ones stack into "+N".
//  • Reduce Motion: 0.2 s fades, no sway.
// Window: a non-activating panel on all spaces, never captured, mouse-transparent except over a card; it lives on the
// island's screen. The display link runs only while something moves, and stops before the panel is ordered out (an
// off-screen window's link never fires again: the idle polls that bring the cards back on hover would stop with it).

import AppKit
import AVFoundation
import BlurtCore
import Carbon.HIToolbox
import QuartzCore

final class HangingCard {
    let shot: Shot
    let root = CALayer()            // pivot: the clasp (the card's top centre); the card hangs from it
    let thread = CAShapeLayer()     // from inside the island down to the clasp (in the stage: it never rotates)
    let clasp = CALayer()
    let card = CALayer()            // shadow + shape
    let face = CALayer()            // photo / voice face, clipped
    let title = CATextLayer()       // voice cards: the words
    let badge = CALayer()
    let close = CALayer()
    let copied = CATextLayer()
    var size: CGSize
    /// where the thread holds the top edge, from the card's left: the middle of a picture; above a voice card's
    /// waveform disc (its words stay clear)
    let gripX: CGFloat
    var x: Spring
    var grip: Spring                // y of the card's top edge (the thread's end), panel coordinates (y down)
    var theta: CGFloat = 0, omega: CGFloat = 0     // sway, degrees
    let tilt: CGFloat
    var slack: CGFloat = 0          // this card's extra thread length: the chime's uneven ends
    var opacity: CGFloat = 0
    var lift = Spring(0, response: 0.28, damping: 0.75)
    var hovered = false
    var dragging = false
    var flying = false              // the capture is still in the air
    var copiedUntil: CFTimeInterval = 0
    /// leaving: falling (delete) or pulled into the island
    var leaving: (start: CFTimeInterval, into: CGPoint?, from: CGPoint)?
    /// the thread dropping out of the island: 0.35 s ease-out from `from` to `to`, starting at `start` (then the spring)
    var reach: (start: CFTimeInterval, from: CGFloat, to: CGFloat)?
    /// how much of the thread shows, from the island down (0…1): it unreels again after a drag comes back
    var unreel: (start: CFTimeInterval, duration: CFTimeInterval)?
    /// dragged away: the thread follows the pointer (`end`, panel coordinates) until it snaps at `snapped`
    var tether: (end: CGPoint, snapped: CFTimeInterval?, from: CGPoint)?
    /// assigned while still in the air: pulled into the island right after the catch
    var pullAfterCatch = false
    /// behind the "+N" stack: it fades out as it slides under it (a voice card is wider than the stack)
    var piled = false

    init(_ s: Shot, x: CGFloat, tilt: CGFloat) {
        shot = s
        size = s.kind == .voice ? HangingCards.voiceSize : HangingCards.shotSize
        gripX = s.kind == .voice ? 22 : size.width / 2
        self.x = Spring(x, response: 0.5, damping: 0.82)
        grip = Spring(-HangingCards.shotSize.height - 40, response: 0.55, damping: 0.72)
        self.tilt = tilt
    }
}

final class CardsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ r: NSRect, to screen: NSScreen?) -> NSRect { r }
}

final class CardsView: NSView, NSDraggingSource {
    weak var cards: HangingCards?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { cards?.mouseDown(e, at: convert(e.locationInWindow, from: nil)) }
    override func mouseDragged(with e: NSEvent) { cards?.mouseDragged(e, at: convert(e.locationInWindow, from: nil)) }
    override func mouseUp(with e: NSEvent) { cards?.mouseUp(e, at: convert(e.locationInWindow, from: nil)) }
    override func rightMouseDown(with e: NSEvent) { cards?.rightMouseDown(e, at: convert(e.locationInWindow, from: nil)) }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { Loc.t("capture.cards.ax", table: "Capture") }
    override func accessibilityChildren() -> [Any]? { cards?.accessibilityElements() ?? [] }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        (cards?.accessibilityElements() ?? []).reversed().first { $0.accessibilityFrame().contains(point) } ?? self
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : [.generic, .move]
    }
    func draggingSession(_ session: NSDraggingSession, movedTo p: NSPoint) { cards?.dragMoved(to: p) }
    func draggingSession(_ session: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        cards?.dragEnded(at: p, operation: operation)
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

final class HangingCards: NSObject {
    static let shotSize = CGSize(width: 112, height: 84)
    static let voiceSize = CGSize(width: 168, height: 44)
    static let gap: CGFloat = 12
    static let maxShown = 7
    static let edge: CGFloat = 12                  // the cards keep this far from the screen's edges
    static let below: CGFloat = 18                 // the cards' top edge under the island (the shortest thread)
    /// Extra thread per position, so the ends don't line up like a shelf (a wind chime, not a washing line).
    static let slacks: [CGFloat] = [0, 9, 3, 12, 5, 10, 2]
    static let claspSize: CGFloat = 7
    static let panelH: CGFloat = 640

    private var panel: CardsPanel?
    private var view: CardsView!
    private let stage = CALayer()
    private var cards: [HangingCard] = []
    private var leaving: [HangingCard] = []
    private let stack = CALayer(), stackText = CATextLayer(), stackThread = CAShapeLayer(), stackClasp = CALayer()
    private let tip = CALayer(), tipText = CATextLayer(), tipPlay = CALayer()
    private var driver: MotionDriver?
    private(set) var screen: NSScreen?
    private var width: CGFloat = 1440

    private var peekUntil: CFTimeInterval = 0
    private var holds = 0
    private var awaySince: CFTimeInterval?
    private var shown = false                      // the cards are down
    /// Brought down on purpose (the ear's count, ⌥⇧H, the menu, the main window): down until the pointer has been on
    /// the cards (`visited`) and left them and the island, or Esc.
    private var sticky = false
    private var visited = false
    private var escHeld = false
    /// The pointer is over a card, the "+N" stack or a card's note (the island stays open meanwhile).
    private(set) var pointerOver = false
    private var hoverCard: HangingCard?
    private var hoverSince: CFTimeInterval = 0
    private var down: (p: NSPoint, card: HangingCard?, event: NSEvent, dragged: Bool)?
    private(set) var dragging: HangingCard?
    private var player: AVAudioPlayer?

    var count: Int { cards.count }
    private var visible: Bool { shown || !leaving.isEmpty || cards.contains { reeled($0) > 0.01 } }

    // MARK: window

    private func ensurePanel(on s: NSScreen) {
        let f = NSRect(x: s.frame.minX, y: s.frame.maxY - HangingCards.panelH, width: s.frame.width, height: HangingCards.panelH)
        if panel == nil {
            let p = CardsPanel(contentRect: f, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
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
            let v = CardsView(frame: NSRect(origin: .zero, size: f.size))
            v.cards = self
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
        stackThread.isHidden = true
        stackClasp.isHidden = true
        stage.addSublayer(stackThread)
        stage.addSublayer(stackClasp)
        stackText.contentsScale = 2
        stackText.alignmentMode = .center
        stack.addSublayer(stackText)
        stage.addSublayer(stack)
        // above every card (their zPosition is their index), so the piled ones go under it, not over "+N"
        stackThread.zPosition = 9_998
        stack.zPosition = 9_999
        stackClasp.zPosition = 10_000
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

    private var styledDark = false

    private func restyle() {
        let dark = isDarkMode
        styledDark = dark
        tipFor = nil                                  // the note's text colour follows on the next hover
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
        styleThread(stackThread, stackClasp)
        CATransaction.commit()
        if !stack.isHidden { layout() }              // "+N" in the new text colour
    }

    // MARK: building a card

    /// A hairline that reads on any wallpaper (a soft halo of the opposite tone), and a brand-colour clasp ringed in
    /// the card's own surface colour.
    private func styleThread(_ t: CAShapeLayer, _ k: CALayer) {
        let dark = isDarkMode
        t.strokeColor = (dark ? NSColor(white: 1, alpha: 0.55) : NSColor(white: 0, alpha: 0.42)).cgColor
        t.fillColor = nil
        t.lineWidth = 1
        t.lineCap = .round
        t.shadowColor = (dark ? NSColor.black : NSColor.white).cgColor
        t.shadowOpacity = dark ? 0.5 : 0.7
        t.shadowRadius = 1
        t.shadowOffset = .zero
        let d = HangingCards.claspSize
        k.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        k.cornerRadius = d / 2
        k.backgroundColor = accent.cgColor
        k.borderWidth = 1.5
        k.borderColor = (dark ? NSColor(calibratedWhite: 0.17, alpha: 1) : NSColor.white).cgColor
        k.shadowColor = NSColor.black.cgColor
        k.shadowOpacity = dark ? 0.45 : 0.22
        k.shadowRadius = 1.5
        k.shadowOffset = CGSize(width: 0, height: 0.5)
    }

    /// A plain string with the layer's own font and colour: an NSAttributedString in a CATextLayer with a truncation
    /// mode draws nothing at all once it overflows (macOS 26), so the voice cards' words and long tips went blank.
    static func setText(_ l: CATextLayer, _ text: String, font: NSFont, color: NSColor) {
        l.string = text
        l.font = font
        l.fontSize = font.pointSize
        l.foregroundColor = color.cgColor
    }
    private func setText(_ l: CATextLayer, _ text: String, font: NSFont, color: NSColor) { HangingCards.setText(l, text, font: font, color: color) }

    private func style(_ c: HangingCard) {
        let dark = isDarkMode
        styleThread(c.thread, c.clasp)
        let s = c.shot
        if s.kind == .voice {
            c.card.backgroundColor = (dark ? NSColor(calibratedWhite: 0.17, alpha: 0.98) : NSColor(calibratedWhite: 0.995, alpha: 0.99)).cgColor
            c.card.borderColor = (dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.08)).cgColor
            let f = NSFont.systemFont(ofSize: 12.5, weight: .medium)
            let words = s.words
            let dur = HangingCards.clock(s.duration ?? 0)
            let text = words ?? Loc.t("capture.voice.card_empty", table: "Capture", dur)
            setText(c.title, text, font: f,
                    color: words == nil ? NSColor(white: dark ? 1 : 0, alpha: 0.5) : (dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0.08, alpha: 1)))
        } else {
            c.card.backgroundColor = NSColor(white: 0.5, alpha: 0.2).cgColor
            c.card.borderColor = (dark ? NSColor(white: 1, alpha: 0.22) : NSColor(white: 0, alpha: 0.12)).cgColor
            c.face.contents = s.markedThumb ?? s.thumb
        }
        c.card.shadowOpacity = dark ? 0.55 : 0.3
        let marks: [BlurtIcon] = (s.kind == .shot && s.voice != nil ? [.mic] : []) + (s.marked != nil ? [.ink] : [])
        c.badge.contents = marks.isEmpty ? nil : HangingCards.badgeImage(marks)
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

    private func makeCard(_ s: Shot, x: CGFloat) -> HangingCard {
        let i = cards.count + leaving.count
        let c = HangingCard(s, x: x, tilt: i % 2 == 0 ? 2 : -2)
        let w = c.size.width, h = c.size.height
        // the thread lives in the stage (it never rotates); the card and its clasp hang from root
        c.grip.target = threadTop
        c.grip.snap()                        // a new card comes out of the island
        stage.insertSublayer(c.thread, below: stack)
        c.root.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        c.root.anchorPoint = CGPoint(x: c.gripX / w, y: 0)
        c.root.opacity = 0
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
        c.root.addSublayer(c.card)
        c.clasp.position = CGPoint(x: c.gripX, y: 0.5)
        c.root.addSublayer(c.clasp)
        c.root.addSublayer(c.close)
        c.root.addSublayer(c.copied)
        stage.insertSublayer(c.root, below: stack)
        style(c)
        return c
    }

    // MARK: layout

    /// Where the threads come out (the island's bottom edge, tucked in a little), in panel coordinates.
    private var threadTop: CGFloat { anchor.y - HangingCards.below - 3 }

    /// Where a card's thread comes out of the island: straight above it where the island is wide enough (a notch),
    /// else drawn in towards it, so the threads of a narrow pill fan out like a chime and none hangs from thin air.
    private func threadX(_ x: CGFloat) -> CGFloat {
        guard let s = screen else { return x }
        let f = island.frameOnScreen
        let inset = min(f.height / 2, f.width / 2)
        return min(max(x, f.minX - s.frame.minX + inset), f.maxX - s.frame.minX - inset)
    }

    /// A card's resting top edge: the shortest thread plus its slack, shortened while hovered.
    private func rest(_ c: HangingCard) -> CGFloat { anchor.y + c.slack - 6 * c.lift.value }

    /// 0 = reeled into the island, 1 = hanging at full length (drives the reel-in's scale and fade).
    private func reeled(_ c: HangingCard) -> CGFloat {
        let top = threadTop, full = anchor.y + c.slack - top
        return full > 0 ? min(1, max(0, (c.grip.value - top) / full)) : 1
    }

    /// The island's centre and the cards' top edge, in panel coordinates.
    private var anchor: (x: CGFloat, y: CGFloat) {
        guard let s = screen else { return (width / 2, 60) }
        let f = island.frameOnScreen
        return (f.midX - s.frame.minX, s.frame.maxY - f.minY + HangingCards.below)
    }

    private var pile: Int { max(0, cards.count - shownCount) }

    /// How many cards hang side by side: at most 7, and only as many as fit across the screen (with the "+N" stack) —
    /// seven voice cards are wider than a 1280-point display.
    private var shownCount: Int {
        let gap = HangingCards.gap, avail = width - 2 * HangingCards.edge
        var n = min(cards.count, HangingCards.maxShown)
        while n > 1 {
            let row = cards.suffix(n).reduce(0) { $0 + $1.size.width } + gap * CGFloat(n - 1)
            let stack = cards.count > n ? HangingCards.shotSize.width + gap : 0
            if row + stack <= avail { break }
            n -= 1
        }
        return n
    }

    /// Rest x for each card (the piled ones under the stack), and the stack's x.
    private func targets() -> (xs: [CGFloat], stackX: CGFloat?) {
        let shown = Array(cards.suffix(shownCount))
        var widths = shown.map(\.size.width)
        let hasStack = pile > 0
        if hasStack { widths.insert(HangingCards.shotSize.width, at: 0) }
        let total = widths.reduce(0, +) + HangingCards.gap * CGFloat(max(0, widths.count - 1))
        // centred on the island, but never off the screen's edge
        var x = min(max(anchor.x - total / 2, HangingCards.edge), max(HangingCards.edge, width - HangingCards.edge - total))
        var centres: [CGFloat] = []
        for w in widths { centres.append(x + w / 2); x += w + HangingCards.gap }
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
            let j = i - pile
            c.slack = j >= 0 ? HangingCards.slacks[j % HangingCards.slacks.count] : 0
            c.piled = j < 0
            c.root.zPosition = CGFloat(i)
            c.thread.zPosition = CGFloat(i) - 0.5
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stack.isHidden = t.stackX == nil
        if let sx = t.stackX {
            let sz = HangingCards.shotSize
            stack.bounds = CGRect(origin: .zero, size: sz)
            stack.position = CGPoint(x: sx, y: 0)
            stack.anchorPoint = CGPoint(x: 0.5, y: 0)
            let f = NSFont.systemFont(ofSize: 18, weight: .semibold)
            stackText.string = NSAttributedString(string: "+\(pile)", attributes: [.font: f, .foregroundColor: isDarkMode ? NSColor.white : NSColor(white: 0.1, alpha: 1)])
            stackText.frame = CGRect(x: 0, y: (sz.height - 24) / 2, width: sz.width, height: 24)
        }
        stackThread.isHidden = stack.isHidden
        stackClasp.isHidden = stack.isHidden
        CATransaction.commit()
        wake()
    }

    private func remove(_ c: HangingCard, fall: Bool) {
        guard let i = cards.firstIndex(where: { $0 === c }) else { return }
        cards.remove(at: i)
        if hoverCard === c { hoverCard = nil; tip.isHidden = true }
        if fall, visible, !reduceMotion {
            c.leaving = (CACurrentMediaTime(), nil, c.root.position)
            leaving.append(c)
        } else {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            CATransaction.setCompletionBlock { c.root.removeFromSuperlayer(); c.thread.removeFromSuperlayer() }
            c.root.opacity = 0
            c.thread.opacity = 0
            CATransaction.commit()
        }
        layout()
        island.cardsChanged(cards.filter { $0.shot.isCard }.count)
    }

    // MARK: arrivals and departures

    /// A capture is complete: a thread drops out of the island and catches it as it flies up from `from` (a screen rect).
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
        let restY = rest(c)
        if reduceMotion {
            c.grip.target = restY; c.grip.snap()
            fadeIn(c)
            return
        }
        c.flying = true
        c.grip.value = threadTop
        c.reach = (CACurrentMediaTime() + 0.15, c.grip.value, restY)   // reaches the catch point as the capture arrives
        let img = s.kind == .voice ? HangingCards.voiceSnapshot(c) : (s.markedThumb ?? s.thumb)
        if let f = from, let img = img {
            flyImage(img, from: f, to: screenRect(of: c, at: restY), springy: true, cornerRadius: c.card.cornerRadius) { [weak self] in
                self?.caught(c)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in self?.caught(c) }
        }
        wake()
    }

    private func caught(_ c: HangingCard) {
        c.flying = false
        c.opacity = 1
        c.omega += 30            // the catch sets it swaying
        popClasp(c)
        wake()
        if c.pullAfterCatch {    // a capture with a project: caught, a beat, then up into the island
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.pullIn(c.shot) }
        }
    }

    /// The clasp closing on the card: a small overshoot.
    private func popClasp(_ c: HangingCard) {
        guard !reduceMotion else { return }
        let a = CASpringAnimation(keyPath: "transform.scale")
        a.fromValue = 0.4
        a.toValue = 1
        a.mass = 1
        a.stiffness = 420
        a.damping = 16
        a.duration = a.settlingDuration
        c.clasp.add(a, forKey: "pop")
    }

    private func fadeIn(_ c: HangingCard) {
        c.opacity = 1
        c.root.opacity = 0
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0; a.toValue = 1; a.duration = 0.2
        c.root.add(a, forKey: "in")
        wake()
    }

    /// Assigned: the thread reels the card up into the island (0.45 s ease-in, shrinking to 0.2), which bumps.
    func pullIn(_ s: Shot) {
        guard let c = cards.first(where: { $0.shot === s }) else { island.bump(); return }
        if c.flying { c.pullAfterCatch = true; return }
        if let i = cards.firstIndex(where: { $0 === c }) { cards.remove(at: i) }
        if hoverCard === c { hoverCard = nil; tip.isHidden = true }
        let a = anchor
        c.leaving = (CACurrentMediaTime(), CGPoint(x: a.x, y: a.y - HangingCards.below - island.frameOnScreen.height / 2), c.root.position)
        if !c.flying { show(peek: 1.0) }
        leaving.append(c)
        layout()
        island.cardsChanged(cards.filter { $0.shot.isCard }.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.2 : 0.45)) { island.bump() }
    }

    func pullInAll(_ shots: [Shot]) {
        for (i, s) in shots.enumerated() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.07 * Double(i)) { self.pullIn(s) } }
    }

    /// Deleted: the thread lets go (and springs back up) and the card falls (0.5 s) — if it is in view; else it just goes.
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

    /// `sticky`: down until the pointer has come and gone (or Esc) — see `reveal()`.
    func show(peek: Double = 0, sticky: Bool = false) {
        if panel == nil { ensurePanel(on: island.screen ?? NSScreen.main ?? NSScreen.screens[0]) }
        if peek > 0 { peekUntil = max(peekUntil, CACurrentMediaTime() + peek) }
        if sticky {
            self.sticky = true
            visited = false
            holdEsc(true)
        }
        awaySince = nil
        guard !shown else { wake(); return }
        shown = true
        if styledDark != isDarkMode { restyle() }     // the appearance changed while they were up (or before launch)
        emit(["event": "cards_shown", "count": cards.count, "sticky": self.sticky, "wall": Date().timeIntervalSince1970])
        panel?.orderFrontRegardless()
        island.orderFront()                 // the island stays above the cards (the threads come out from under it)
        wake()
    }

    /// The pointer arrived on the island (or it opened): every card comes down with its detail. Pushed by the island,
    /// so it never waits for the cards' own (idle) poll.
    func islandAttention() {
        guard !cards.isEmpty, !island.isRecording else { return }
        show()
    }

    /// A recording started: the cards go up and stay there (K7: nothing hangs over what you are showing). Only ⌥⇧H
    /// or the menu brings them down meanwhile.
    func recordingStarted() {
        sticky = false
        peekUntil = 0
        holdEsc(false)
        guard holds == 0, dragging == nil, down == nil else { return }
        retract()
    }

    /// The ear's count, ⌥⇧H "Show hanging cards", the menu, the main window's "Unfiled captures": every card comes down
    /// and stays until the pointer has come and gone, or Esc. Nothing hanging: the island says so.
    func reveal(via: String) {
        emit(["event": "cards_reveal", "via": via, "count": cards.count])
        guard !cards.isEmpty else {
            island.toast(Loc.t("capture.cards.none", table: "Capture"), actionTitle: nil, action: nil)
            return
        }
        if let s = island.screen, s != screen, !shown, dragging == nil { ensurePanel(on: s) }
        show(sticky: true)
    }

    /// Esc while they were brought down on purpose: up they go.
    func dismiss() {
        sticky = false
        peekUntil = 0
        holdEsc(false)
        island.closeIfSticky()
        guard holds == 0, dragging == nil, down == nil else { return }
        retract()
    }

    /// Esc is ours only while the cards are down on purpose (like voice input's Esc).
    private func holdEsc(_ on: Bool) {
        guard on != escHeld else { return }
        escHeld = on
        if on { registerHotkey(.cardsEsc, key: kVK_Escape, mods: 0) } else { unregisterHotkey(.cardsEsc) }
    }

    private func retract() {
        sticky = false
        holdEsc(false)
        guard shown else { return }
        shown = false
        pointerOver = false
        hoverCard?.hovered = false
        hoverCard = nil
        tip.isHidden = true
        panel?.ignoresMouseEvents = true
        emit(["event": "cards_retracted", "count": cards.count, "wall": Date().timeIntervalSince1970])
        wake()
    }

    /// Down right now (tests, the main window).
    var isShown: Bool { shown }

    func screenRect(of s: Shot) -> NSRect? {
        guard let c = cards.first(where: { $0.shot === s }) else { return nil }
        return screenRect(of: c, at: c.grip.target)
    }

    private func screenRect(of c: HangingCard, at y: CGFloat) -> NSRect {
        guard let p = panel else { return .zero }
        return NSRect(x: p.frame.minX + c.x.target - c.size.width / 2, y: p.frame.maxY - y - c.size.height, width: c.size.width, height: c.size.height)
    }

    /// The cards' sway right now (degrees; tests check Reduce Motion keeps them still).
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
            // the thread's length: hanging when shown, reeled into the island when not
            let rest = a.y + c.slack - 6 * c.lift.value
            let hiddenY = threadTop
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
                    // reeling in: an ease-in, not a spring (nothing bounces into the island)
                    c.grip.value += (c.grip.target - c.grip.value) * min(1, dt * 9)
                    c.grip.velocity = 0
                } else { _ = c.grip.step(dt) }
            }
            if reduce { c.grip.snap() }
            _ = c.x.step(dt)
            c.lift.target = c.hovered && !c.dragging ? 1 : 0
            _ = c.lift.step(dt)
            // sway: a damped pendulum on the thread; sideways motion of the thread drives it
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
            place(c, now: now)
            if !c.x.resting || !c.grip.resting || !c.lift.resting || abs(c.theta) > 0.12 || abs(c.omega) > 0.4
                || c.unreel != nil || c.tether != nil || c.flying || now < c.copiedUntil + 0.1 { moving = true }
        }
        if let first = cards.first, !stack.isHidden {
            stack.position = CGPoint(x: stack.position.x, y: first.grip.value)
            let k = reeled(first)
            stack.opacity = Float(k)
            drawThread(stackThread, from: CGPoint(x: threadX(stack.position.x), y: threadTop), to: CGPoint(x: stack.position.x, y: first.grip.value))
            stackClasp.position = CGPoint(x: stack.position.x, y: first.grip.value + 0.5)
            stackClasp.opacity = Float(k)
        }
        for c in leaving { stepLeaving(c, now) }
        leaving.removeAll { c in
            guard let l = c.leaving, now - l.start > 0.55 else { return false }
            c.root.removeFromSuperlayer()
            c.thread.removeFromSuperlayer()
            return true
        }
        positionTip(now)
        CATransaction.commit()
        if !leaving.isEmpty { moving = true }
        if hoverCard?.shot.hasNote == true || hoverCard?.shot.kind == .voice, tip.isHidden, now - hoverSince < 0.6 { moving = true }
        if !visible || (!moving && !shown) {
            // reeled in: out of the way — and the display link stops first (an off-screen window's link never fires
            // again, so it would never settle into the idle polls that notice the pointer on the island)
            driver?.rest()
            panel?.orderOut(nil)
            return false
        }
        return moving || shown && (now < peekUntil)
    }

    private func drawThread(_ t: CAShapeLayer, from a: CGPoint, to b: CGPoint) {
        let p = CGMutablePath()
        if hypot(b.x - a.x, b.y - a.y) > 0.5 { p.move(to: a); p.addLine(to: b) }
        t.path = p
    }

    private func place(_ c: HangingCard, now: CFTimeInterval) {
        let y = c.grip.value
        let reduce = reduceMotion
        let swing = reduce ? 0 : c.theta + c.tilt * (1 - c.lift.value)
        let gx = c.x.value - c.size.width / 2 + c.gripX
        let top = threadTop
        // a pendulum: the clasp sways on the thread around the point where it comes out of the island
        let len = max(0, y - top)
        let th = (reduce ? 0 : c.theta) * .pi / 180
        let clasp = CGPoint(x: gx + len * sin(th) * 0.6, y: y)
        c.root.position = clasp
        // reeled in (hidden): the card shrinks a little and fades as it goes up into the island
        let k = reeled(c)
        var t = CATransform3DMakeRotation(swing * .pi / 180, 0, 0, 1)
        let sc = (1 + 0.04 * c.lift.value) * (0.7 + 0.3 * k)
        t = CATransform3DScale(t, sc, sc, 1)
        c.root.transform = t
        // piled behind the stack: gone once it is under it (only the stack's own thread shows)
        let under: CGFloat = c.piled && !stack.isHidden ? 1 - min(1, abs(c.x.value - stack.position.x) / 40) : 0
        c.root.opacity = Float(c.flying || c.dragging ? 0 : c.opacity * min(1, k * 1.4) * (1 - under))
        c.thread.opacity = Float(1 - under)
        // the thread: from inside the island to the clasp — or after the dragged card, springing back once it snapped
        let tx = threadX(gx)
        var end = CGPoint(x: clasp.x, y: y + 0.5)
        var show: CGFloat = 1
        if let u = c.unreel {
            let f = CGFloat((now - u.start) / u.duration)
            show = Ease.outCubic(f)
            if f >= 1 { c.unreel = nil }
        }
        if let tt = c.tether {
            if let snapped = tt.snapped {
                let f = CGFloat((now - snapped) / 0.32)
                let back = Ease.outBack(f, 1.2)
                end = CGPoint(x: tt.from.x + (tx - tt.from.x) * back, y: tt.from.y + (top - tt.from.y) * back)
                if f >= 1 { c.tether = nil; end = CGPoint(x: tx, y: top) }
            } else {
                end = tt.end
            }
        } else if c.dragging {
            end = CGPoint(x: tx, y: top)
        }
        drawThread(c.thread, from: CGPoint(x: tx, y: top), to: CGPoint(x: tx + (end.x - tx) * show, y: top + (end.y - top) * show))
        c.clasp.opacity = c.dragging || show < 0.98 ? 0 : 1
        c.card.shadowRadius = 12 + 6 * c.lift.value
        c.card.shadowOffset = CGSize(width: 0, height: 6 + 4 * c.lift.value)
        c.close.opacity = c.hovered && !c.dragging ? 1 : 0
        c.copied.opacity = now < c.copiedUntil ? 1 : 0
    }

    private func stepLeaving(_ c: HangingCard, _ now: CFTimeInterval) {
        guard let l = c.leaving else { return }
        let raw = CGFloat(max(0, min(1, (now - l.start) / (reduceMotion ? 0.2 : (l.into == nil ? 0.5 : 0.45)))))
        if reduceMotion {
            c.root.opacity = Float(1 - raw)
            c.thread.opacity = Float(1 - raw)
            return
        }
        let top = threadTop
        if let g = l.into {
            // reeled into the island: ease-in towards its centre, shrinking to 0.2; the thread shortens with it
            let k = Ease.inCubic(raw)
            let p = CGPoint(x: l.from.x + (g.x - l.from.x) * k, y: l.from.y + (g.y - l.from.y) * k)
            c.root.position = p
            let s = 1 - 0.8 * k
            c.root.transform = CATransform3DScale(CATransform3DMakeRotation(c.theta * (1 - k) * .pi / 180, 0, 0, 1), s, s, 1)
            c.root.opacity = Float(raw > 0.8 ? (1 - raw) / 0.2 : 1)
            drawThread(c.thread, from: CGPoint(x: threadX(p.x), y: top), to: CGPoint(x: p.x, y: max(top, p.y)))
        } else {
            // the thread lets go: the card drops with a turn and a fade; the empty thread springs back up
            let e = raw * raw
            let angle = c.tilt + c.theta + (c.tilt >= 0 ? 1 : -1) * 28 * e
            var t = CATransform3DMakeTranslation(0, 560 * e, 0)
            t = CATransform3DRotate(t, angle * .pi / 180, 0, 0, 1)
            c.root.transform = t
            c.root.opacity = Float(1 - raw)
            c.clasp.opacity = 0                 // the clasp stays on the thread
            let back = Ease.outCubic(min(1, raw * 1.8))
            let tx = threadX(l.from.x)
            drawThread(c.thread, from: CGPoint(x: tx, y: top), to: CGPoint(x: l.from.x + (tx - l.from.x) * back, y: l.from.y + (top - l.from.y) * back))
        }
    }

    // MARK: pointer

    private var busy: Bool { holds > 0 || dragging != nil || down != nil || CACurrentMediaTime() < peekUntil }

    /// The island stays open while the pointer is on the cards, or one is pressed or dragged.
    var holdsIsland: Bool { shown && (pointerOver || down != nil || dragging != nil) }

    private func poll(_ now: CFTimeInterval) {
        guard let p = panel else { return }
        let m = NSEvent.mouseLocation
        let onIsland = island.pointerInside
        let held = island.holdsCards           // open by a key or a command, a drawer, a drag
        let recording = island.isRecording     // only brought down on purpose while recording
        if !shown {
            pointerOver = false
            if (onIsland || held) && !cards.isEmpty && !recording { show() }
            return
        }
        let local = NSPoint(x: m.x - p.frame.minX, y: p.frame.maxY - m.y)
        let over = card(at: local) != nil || (stack.isHidden == false && stack.frame.insetBy(dx: -6, dy: -6).contains(local))
            || (!tip.isHidden && tip.frame.insetBy(dx: -6, dy: -10).contains(local))
        pointerOver = over
        // down on purpose: until the pointer has been on the cards and left them (and the island), or Esc
        if sticky {
            if cards.isEmpty { sticky = false; holdEsc(false) }
            else if over { visited = true }
            else if visited && !onIsland { sticky = false; holdEsc(false) }
        }
        if over || busy || sticky || (!recording && (onIsland || held)) { awaySince = nil } else {
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
        let interactive = hit != nil || down != nil || onStack(local)
            || (!tip.isHidden && tip.frame.insetBy(dx: -4, dy: -10).contains(local))
        if p.ignoresMouseEvents == interactive { p.ignoresMouseEvents = !interactive }
    }

    private func onStack(_ p: NSPoint) -> Bool { !stack.isHidden && shown && stack.frame.insetBy(dx: -4, dy: -4).contains(p) }

    /// A click on the "+N" stack: the older cards come forward (the ones showing go behind the stack), so every card
    /// can be reached; clicking again goes round.
    func showOlder() {
        let n = shownCount
        guard pile > 0, n > 0 else { return }
        let front = Array(cards.suffix(n))
        cards.removeLast(n)
        cards.insert(contentsOf: front, at: 0)
        hoverCard?.hovered = false
        hoverCard = nil
        tip.isHidden = true
        if !reduceMotion { for c in cards.suffix(shownCount) { c.omega += 18 } }
        emit(["event": "cards_older", "showing": cards.suffix(shownCount).map(\.shot.n)])
        layout()
    }

    private func card(at p: NSPoint) -> HangingCard? {
        for c in cards.suffix(shownCount).reversed() where !c.flying && !c.dragging {
            let r = CGRect(x: c.x.value - c.size.width / 2, y: c.grip.value - 8, width: c.size.width, height: c.size.height + 8).insetBy(dx: -4, dy: -4)
            if r.contains(p) { return c }
        }
        return nil
    }

    // MARK: the note under a hovered card

    private weak var tipFor: HangingCard?

    private func positionTip(_ now: CFTimeInterval) {
        // (it steps aside while the card says "Copied" — that sits where the note would)
        let copying = (hoverCard?.copiedUntil ?? 0) > now
        guard let c = hoverCard, !c.dragging, c.shot.hasNote || c.shot.kind == .voice, now - hoverSince > 0.35, !NoteBubble.shared.isOpen,
              !copying else {
            if !tip.isHidden, hoverCard == nil || dragging != nil || NoteBubble.shared.isOpen || copying { tip.isHidden = true }
            return
        }
        if tip.isHidden || tipFor !== c { buildTip(c) }
        tip.isHidden = false
        let w = tip.bounds.width
        let top = c.grip.value + c.size.height * 1.04 + 12
        tip.position = CGPoint(x: min(max(c.x.value, w / 2 + 12), width - w / 2 - 12), y: top + tip.bounds.height / 2)
    }

    private func buildTip(_ c: HangingCard) {
        tipFor = c
        let w: CGFloat = 260
        let dark = isDarkMode
        let text = c.shot.words ?? ""
        let tf = NSFont.systemFont(ofSize: 12.5)
        let attr = NSAttributedString(string: text, attributes: [
            .font: tf, .foregroundColor: dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0.1, alpha: 1)])
        let th = text.isEmpty ? 0 : min(72, ceil(attr.boundingRect(with: NSSize(width: w - 24, height: 200), options: [.usesLineFragmentOrigin]).height) + 2)
        let hasVoice = c.shot.voiceURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let h = 12 + th + (hasVoice ? (th > 0 ? 8 : 0) + 22 : 0) + 12
        tip.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        tipText.frame = CGRect(x: 12, y: 12, width: w - 24, height: th)
        setText(tipText, text, font: tf,
                color: dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0.1, alpha: 1))
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
        if let d = down, d.card == nil, !d.dragged, onStack(p), onStack(d.p) { return showOlder() }
        guard let d = down, !d.dragged, let c = d.card, c === card(at: p) else { return }
        if e.clickCount >= 2 {
            c.copiedUntil = 0
            NoteBubble.shared.begin(c.shot, mode: .edit)
        } else {
            copy(c, .click)
        }
    }

    // MARK: copy

    enum Copy: String { case click, image, text }

    /// click: a shot's image (inked if marked) with its words as the same pasteboard item's text, a voice card's
    /// words · image / text: just that (the right-click menu). Shows "Copied" on the card.
    @discardableResult
    func copy(_ c: HangingCard, _ what: Copy) -> Bool {
        let s = c.shot
        let text = s.copyText
        let ok: Bool
        switch what {
        case .click where s.kind == .shot, .image:
            ok = s.kind == .shot && s.bestURL.map { copyImageToPasteboard($0, text: what == .click ? text : nil) } ?? false
        case .click, .text:
            ok = text.map { t in
                let pb = capturePasteboard
                pb.clearContents()
                return pb.setString(t, forType: .string)
            } ?? false
        }
        guard ok else { return false }
        c.copiedUntil = CACurrentMediaTime() + 1.2
        if s.kind == .shot { c.omega += 30 }
        wake()
        emit(["event": "card_copied", "n": s.n, "what": what.rawValue,
              "types": (capturePasteboard.pasteboardItems?.first?.types ?? []).map(\.rawValue)])
        return true
    }

    /// The right-click menu's items for a card (tests read the titles).
    func menuItems(_ c: HangingCard) -> [(String, () -> Void)] {
        let s = c.shot
        var items: [(String, () -> Void)] = []
        if s.kind == .shot, s.bestURL != nil {
            items.append((Loc.t("capture.card.copy_image", table: "Capture"), { [weak self] in self?.copy(c, .image) }))
        }
        if s.copyText != nil {
            items.append((Loc.t("capture.card.copy_text", table: "Capture"), { [weak self] in self?.copy(c, .text) }))
        }
        items.append((Loc.t("capture.card.edit_note", table: "Capture"), { NoteBubble.shared.begin(s, mode: .edit) }))
        items.append((Loc.t("capture.card.reveal", table: "Capture"), { if let u = s.bestURL { NSWorkspace.shared.activateFileViewerSelecting([u]) } }))
        return items
    }

    /// Tests: copy capture N as a click / Copy Image / Copy Text would; the menu's titles for it.
    func testCopy(n: Int, _ what: Copy) -> Bool { cards.first { $0.shot.n == n }.map { copy($0, what) } ?? false }
    func testMenu(n: Int) -> [String] { cards.first { $0.shot.n == n }.map { menuItems($0).map(\.0) } ?? [] }
    /// Tests: what a drag of capture N carries, written to `pb`.
    func testDrag(n: Int, to pb: NSPasteboard) -> [String] {
        guard let s = cards.first(where: { $0.shot.n == n })?.shot else { return [] }
        let item = HangingCards.dragItem(s)
        pb.clearContents()
        pb.writeObjects([item])
        return item.types.map(\.rawValue)
    }

    func rightMouseDown(_ e: NSEvent, at p: NSPoint) {
        guard let c = card(at: p), let v = view else { return }
        let m = NSMenu()
        let s = c.shot
        let items = menuItems(c)
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
        m.addItem(ClosureMenuItem(Loc.t("project.ai_sort")) { snapper.handToAI() })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(Loc.t("capture.card.delete", table: "Capture")) { snapper.delete(s) })
        if cards.count > 1 {
            m.addItem(ClosureMenuItem(Loc.plural("capture.card.delete_all", table: "Capture", count: cards.count)) { snapper.deleteAllCards() })
        }
        m.popUp(positioning: nil, at: p, in: v)
    }

    private func startDrag(_ c: HangingCard, event: NSEvent) {
        guard let v = view else { return }
        let di = NSDraggingItem(pasteboardWriter: HangingCards.dragItem(c.shot))
        let img = NSImage(size: c.size)
        if let rep = HangingCards.snapshot(c) { img.addRepresentation(rep) }
        di.setDraggingFrame(NSRect(x: c.x.value - c.size.width / 2, y: c.grip.value, width: c.size.width, height: c.size.height), contents: img)
        c.dragging = true                    // the thread follows the pointer, then snaps (dragMoved)
        c.tether = (CGPoint(x: c.x.value - c.size.width / 2 + c.gripX, y: c.grip.value), nil, .zero)
        dragging = c
        island.dragBegan()
        let session = v.beginDraggingSession(with: [di], event: event, source: v)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        wake()
    }

    /// What a card carries when dragged out: the file (the inked shot, or the voice note's wav), its words as text, and
    /// (inside the app) which capture it is — for dropping on a project in the island.
    static func dragItem(_ s: Shot) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if let u = s.bestURL { item.setString(u.absoluteString, forType: .fileURL) }
        if let t = s.copyText { item.setString(t, forType: .string) }
        if let b = s.batch { item.setString("\(b.dir.path)\n\(s.n)", forType: capturePasteboardType) }
        return item
    }

    func dragMoved(to p: NSPoint) {
        island.dragMoved(to: p)
        guard let c = dragging, let f = panel?.frame, var t = c.tether, t.snapped == nil else { return }
        // the drag image's top edge, where the thread still holds it
        let end = CGPoint(x: p.x - f.minX, y: f.maxY - p.y - c.size.height / 2)
        let top = CGPoint(x: threadX(c.x.value - c.size.width / 2 + c.gripX), y: threadTop)
        if hypot(end.x - top.x, end.y - top.y) > (anchor.y + c.slack - top.y) + 44 || reduceMotion {
            t.snapped = CACurrentMediaTime()       // stretched as far as it goes: it snaps and springs back
            t.from = t.end
        } else {
            t.end = end
        }
        c.tether = t
        wake()
    }

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
        // back where it hung: a new thread drops out of the island and takes it
        c.tether = nil
        c.grip.target = rest(c); c.grip.snap()
        c.unreel = (CACurrentMediaTime() + (operation.isEmpty ? 0.25 : 0), 0.3)
        c.omega += operation.isEmpty ? 60 : 30
        DispatchQueue.main.asyncAfter(deadline: .now() + (operation.isEmpty ? 0.55 : 0.3)) { [weak self] in self?.popClasp(c) }
        show(peek: 1.5)
        wake()
    }

    // MARK: images of a card

    static func snapshot(_ c: HangingCard) -> NSBitmapImageRep? {
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

    static func voiceSnapshot(_ c: HangingCard) -> CGImage? { snapshot(c)?.cgImage }

    // MARK: accessibility

    private var axCards: [ObjectIdentifier: LayerAXElement] = [:]

    func accessibilityElements() -> [LayerAXElement] {
        guard let v = view else { return [] }
        var out: [LayerAXElement] = []
        var keep: [ObjectIdentifier: LayerAXElement] = [:]
        for c in cards.suffix(shownCount) where !c.flying {
            let key = ObjectIdentifier(c)
            let e = axCards[key] ?? {
                let e = LayerAXElement.make(role: .button, layer: c.card, host: v)
                let s = c.shot
                e.press = { [weak self] in self?.copy(c, .click) }
                var actions = [NSAccessibilityCustomAction(name: Loc.t("capture.card.edit_note", table: "Capture")) { NoteBubble.shared.begin(s, mode: .edit); return true }]
                for p in ProjectStore.shared.projects.prefix(8) {
                    actions.append(NSAccessibilityCustomAction(name: Loc.t("capture.card.ax_move", table: "Capture", p.name)) { snapper.assign(s, to: p.id); return true })
                }
                actions.append(NSAccessibilityCustomAction(name: Loc.t("project.ai_sort")) { snapper.handToAI(); return true })
                actions.append(NSAccessibilityCustomAction(name: Loc.t("capture.card.delete", table: "Capture")) { snapper.delete(s); return true })
                e.setAccessibilityCustomActions(actions)
                return e
            }()
            e.setAccessibilityLabel(HangingCards.cardLabel(c.shot))
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

let hanging = HangingCards()
