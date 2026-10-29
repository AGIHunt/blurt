// In-place markup (v0.9-next). After ⌥A's selection the picture freezes where it was, at 1:1, the rest of that
// screen dimmed as the picker had it (the picker's dim stays up until the stage is there, so nothing flickers), and the
// user draws straight on it — no enlarged copy under the notch. The note bubble docks beside the selection
// (NoteBubble, BlurtCore BubbleDock: never over it, flipped near the screen's edges, on the selection's own display).
//
//  • the pen: InkCanvas (InkView.swift) at the selection's size — a plain drag freehand, ⇧ a box, ⌥ an ellipse, holding
//    still at the end snaps a rough shape clean, ⌘Z takes the last stroke back. One markup colour, a soft shadow, the
//    width of the display (InkStyle).
//  • its edge (FrozenEdge): the picker's gradient line, now solid and closed — dashed while choosing, solid once frozen
//    — 2 pt between two 1 pt dark keylines, the picture lifted off the dim on a shadow you can see.
//  • a faint one-line hint above the picture, "Drag to draw · ⇧ box · ⌥ ellipse · Esc discards", the first few times
//    only (record.ink_hint_shown counts them; BlurtCore InkHint); it goes when the first stroke starts. It is the one
//    place Esc is taught: the bubble's footer holds state only (the bin's tooltip names Esc too).
//  • a click on the dimmed part outside the picture is "done" (the bubble saves); Esc and ⏎ are the bubble's.
//  • the words of a spoken note are in ("Saved"): the dim lifts at once (`lift`) — only the picture and the bubble
//    stay for the short correction window (v0.9-fix2: a 1 s sentence kept the whole screen dimmed for ~4 s).
//  • finishing: the stage drops below the flight and fades while the marked picture flies from the selection to the
//    notch and becomes the card (HangingCards.catchCapture; Reduce Motion: it fades in at the card instead). Discarded
//    (Esc), it just fades. The unmarked picture stays as shots/NNN.png; the strokes stay editable (Edit Note).
//  • its window is never captured (chromeSharing) and never takes the keys (the bubble has them).
// Tests: the bubble's `noteink` command draws here while the stage is up; `stage` reports it (SnapApp).
import AppKit
import BlurtCore

/// Takes the pointer, never the keys: the note bubble stays key while the user draws.
final class StagePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The dim around the frozen picture (black 42 %, as the picker's), and a click outside it.
final class StageView: NSView {
    var hole: NSRect = .zero { didSet { needsDisplay = true } }
    static let dim: CGFloat = 0.42
    var dimAlpha: CGFloat = StageView.dim { didSet { needsDisplay = true } }
    var onClickOutside: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirty: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: hole))
        dim.windingRule = .evenOdd
        NSColor(white: 0, alpha: dimAlpha).setFill()
        dim.fill()
    }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if !hole.contains(p) { onClickOutside?() }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
}

/// The frozen picture's edge: the one solid 2 pt line every area picker draws (BrandColor.Island.selection), just
/// outside the picture, the same line it had while it was being chosen (the founder, 2026-10-29: one colour, one line,
/// before and after); the picture lifts off the dim on a shadow you can see at a glance (black 55 %, 24 pt, 8 pt down).
final class FrozenEdge: NSView {
    private let lift = CALayer()
    private let line = CAShapeLayer()
    /// the band outside the picture the line takes
    static let band: CGFloat = 2

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        lift.shadowColor = NSColor.black.cgColor
        lift.shadowOpacity = 0.55
        lift.shadowRadius = 24
        lift.shadowOffset = CGSize(width: 0, height: -8)
        line.fillColor = nil
        line.strokeColor = BrandColor.Island.selection.cgColor
        line.lineWidth = 2
        for l in [lift, line] as [CALayer] { layer?.addSublayer(l) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `sel` in this view's coordinates. `lifted`: the shadow (off once the dim lifts — the screen is given back).
    func update(_ sel: NSRect, lifted: Bool = true) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        lift.frame = bounds
        lift.shadowPath = CGPath(rect: sel.insetBy(dx: -FrozenEdge.band, dy: -FrozenEdge.band), transform: nil)
        lift.isHidden = !lifted
        line.frame = bounds
        line.path = CGPath(rect: sel.insetBy(dx: -1, dy: -1), transform: nil)
    }

    func setLifted(_ on: Bool) { lift.isHidden = !on }
}

final class InkStage {
    static let shared = InkStage()
    private(set) var shot: Shot?
    private var panel: StagePanel?
    private let view = StageView()
    /// the pen on the frozen picture, at the selection's size (1:1)
    let canvas = InkCanvas(frame: .zero, corner: 0)
    private let outline = FrozenEdge()
    private let hint = NSView()                 // the pill
    private let hintLabel = NSTextField(labelWithString: "")
    /// the frozen selection, global AppKit points
    private(set) var selection: NSRect = .zero
    private(set) var screen: NSScreen?
    private var generation = 0
    var onClickOutside: (() -> Void)?
    /// this snap is one of the first few: the hint showed (the bubble names its keys then too)
    private(set) var hintShown = false

    var isOpen: Bool { shot != nil }
    /// where the bubble may go: the selection's screen, minus the menu bar and the Dock
    var visibleFrame: NSRect { screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero }

    /// The screen the selection is on (the one holding most of it).
    static func screen(for r: NSRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            let ia = a.frame.intersection(r), ib = b.frame.intersection(r)
            return ia.width * ia.height < ib.width * ib.height
        }
    }

    /// The picture frozen at `sel`, the pen on it. Before the bubble opens.
    func open(_ s: Shot, image: CGImage, selection sel: NSRect) {
        if panel?.isVisible == true { panel?.orderOut(nil) }
        generation += 1
        shot = s
        selection = sel
        let scr = InkStage.screen(for: sel) ?? NSScreen.main ?? NSScreen.screens[0]
        screen = scr
        let p = panel ?? makePanel()
        panel = p
        p.alphaValue = 1
        lifting?.invalidate()
        view.dimAlpha = StageView.dim
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.setFrame(scr.frame, display: false)
        view.frame = NSRect(origin: .zero, size: scr.frame.size)
        let local = sel.offsetBy(dx: -scr.frame.minX, dy: -scr.frame.minY)
        view.hole = local
        view.onClickOutside = { [weak self] in
            guard let self = self, self.isOpen else { return }
            emit(["event": "ink_stage_click_outside", "n": s.n])
            self.onClickOutside?()
        }
        canvas.isHidden = false
        canvas.frame = local
        canvas.image = image
        canvas.lineWidth = inkWidth(for: scr)
        canvas.strokes = s.strokes
        canvas.editable = true
        outline.frame = view.bounds
        outline.update(local)
        placeHint(local)
        p.orderFrontRegardless()
        emit(["event": "ink_stage", "open": true, "n": s.n, "selection": [sel.minX, sel.minY, sel.width, sel.height],
              "screen": [scr.frame.minX, scr.frame.minY, scr.frame.width, scr.frame.height],
              "line_width": Double(canvas.lineWidth), "hint": !hint.isHidden])
    }

    private func makePanel() -> StagePanel {
        let p = StagePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.sharingType = chromeSharing
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.acceptsMouseMovedEvents = true
        view.wantsLayer = true
        p.contentView = view
        view.addSubview(outline)               // (under the picture: its lift shadow)
        view.addSubview(canvas)
        // faint: quieter than the picture and the bubble — a soft glass tint, regular weight (never a banner)
        hintLabel.font = .systemFont(ofSize: 12, weight: .regular)
        hintLabel.textColor = NSColor(white: 1, alpha: 0.65)
        hintLabel.alignment = .center
        hint.wantsLayer = true
        hint.layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.42).cgColor
        hint.layer?.cornerRadius = 11
        hint.addSubview(hintLabel)
        view.addSubview(hint)
        return p
    }

    /// The faint hint, the first few times: above the picture, else below it, else just inside its top.
    private func placeHint(_ local: NSRect) {
        let shown = recordConfig()["ink_hint_shown"] as? Int ?? 0
        hint.isHidden = !InkHint.shows(alreadyShown: shown)
        hintShown = !hint.isHidden
        hint.alphaValue = 1
        guard !hint.isHidden else { return }
        setRecordConfig("ink_hint_shown", shown + 1)
        hintLabel.stringValue = Loc.t("capture.note.stage_hint", table: "Capture")
        hintLabel.sizeToFit()
        let w = hintLabel.frame.width + 24, h: CGFloat = 22
        hintLabel.frame.origin = NSPoint(x: 12, y: (h - hintLabel.frame.height) / 2)
        var y = local.maxY + 10
        if y + h > view.bounds.height - 30 { y = local.minY - 10 - h }         // the menu bar's side: below it
        if y < 8 { y = local.maxY - h - 10 }                                   // no room outside: inside, at the top
        let x = min(max(8, local.midX - w / 2), view.bounds.width - w - 8)
        hint.frame = NSRect(x: x, y: y, width: w, height: h)
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in if self?.generation == g { self?.hideHint() } }
    }

    /// The note is saved: the dim around the picture fades out now (0.2 s); the picture and the bubble stay.
    func lift() {
        guard isOpen, view.dimAlpha > 0 else { return }
        emit(["event": "ink_stage_lift", "n": shot?.n ?? 0])
        lifting?.invalidate()
        let from = view.dimAlpha, t0 = CACurrentMediaTime(), d = reduceMotion ? 0.0 : 0.2
        outline.setLifted(false)
        guard d > 0 else { view.dimAlpha = 0; return }
        lifting = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            let k = min(1, (CACurrentMediaTime() - t0) / d)
            self?.view.dimAlpha = from * CGFloat(1 - k * k * (3 - 2 * k))
            if k >= 1 { t.invalidate() }
        }
    }
    private var lifting: Timer?

    /// The hint goes (the first stroke, or after a while).
    func hideHint() {
        guard !hint.isHidden else { return }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = reduceMotion ? 0 : 0.25
            hint.animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.hint.isHidden = true })
    }

    /// The stage goes. `flying`: the marked picture is flying out of it (the picture is hidden at once and the stage
    /// drops under the flight while it fades); else it fades as it is (discarded).
    func close(flying: Bool) {
        guard let p = panel, shot != nil else { return }
        let n = shot?.n ?? 0
        shot = nil
        onClickOutside = nil
        view.onClickOutside = nil
        canvas.flush()
        canvas.editable = false
        generation += 1
        let g = generation
        if flying {
            canvas.isHidden = true
            p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        }
        emit(["event": "ink_stage", "open": false, "n": n, "flying": flying])
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = reduceMotion ? 0.12 : 0.2
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, self.generation == g else { return }
            p.orderOut(nil)
            p.alphaValue = 1
            self.canvas.image = nil
        })
    }

    /// Tests: a click on the dim outside the picture, as mouseDown takes it.
    func testClickOutside() { view.onClickOutside?() }

    /// Scripted checks.
    var testState: [String: Any] {
        ["open": isOpen, "visible": panel?.isVisible == true, "n": shot?.n ?? NSNull(),
         "selection": [selection.minX, selection.minY, selection.width, selection.height],
         "strokes": canvas.strokes.count, "drawing": canvas.isDrawing, "hint": !hint.isHidden,
         "line_width": Double(canvas.lineWidth), "window": panel?.windowNumber ?? 0, "dim": Double(view.dimAlpha)]
    }
}
