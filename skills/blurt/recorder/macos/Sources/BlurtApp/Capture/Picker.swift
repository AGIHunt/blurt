import AppKit
import BlurtCore
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import ServiceManagement

// MARK: - Region picker

/// A non-activating panel: it takes the keys (Esc, Enter, F, L) without activating Blurt, so opening the picker
/// never brings Blurt's own windows (the main window) above the app the user is about to snap.
final class KeyWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) { contentView?.keyDown(with: event) }
    override func cancelOperation(_ sender: Any?) { (contentView as? PickerView)?.controller?.finish(false) }
}

final class PickerController {
    var windows: [KeyWindow] = []
    var selection: NSRect?          // global AppKit coords
    var snapped = false             // selection came from clicking a window (or F / last area): drag = draw new
    var hovered: NSRect?
    var onDone: ((CGRect?) -> Void)?
    var snapMode = false            // ⌥⇧A: release (or click a window / F / L) captures right away
    let toolbar = PickerToolbar()
    var toolbarHost: NSView?
    /// The app in front when the picker opened: its windows can be picked even if it's a background-style app.
    var frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    /// A drag is drawing / moving / resizing the selection: its dashes march.
    var dragging = false

    /// Visual checks (test commands only), all global top-left points: BLURT_TEST_PICKER_SELECTION=X,Y,W,H opens the
    /// picker with that selection, BLURT_TEST_PICKER_HOVER=X,Y,W,H with that window hovered (no selection), and
    /// BLURT_TEST_PICKER_DRAGGING=1 keeps the selection's dashes marching as if it were being dragged, and
    /// BLURT_TEST_PICKER_MODE=record shows the snap picker (the `snap` command) as the recording picker looks (hint,
    /// window label, the Record button) — it still only snaps.
    private func applyTestState() {
        let env = ProcessInfo.processInfo.environment
        guard env["BLURT_TEST_COMMANDS"] == "1" else { return }
        if env["BLURT_TEST_PICKER_MODE"] == "record" { snapMode = false }
        func rect(_ k: String) -> NSRect? {
            let v = (env[k] ?? "").split(separator: ",").compactMap { Double($0) }
            return v.count == 4 ? toNS(CGRect(x: v[0], y: v[1], width: v[2], height: v[3])) : nil
        }
        if let s = rect("BLURT_TEST_PICKER_SELECTION") { selection = s; snapped = false }
        if selection == nil, let h = rect("BLURT_TEST_PICKER_HOVER") { hovered = h }
        if env["BLURT_TEST_PICKER_DRAGGING"] == "1" { dragging = true }
    }

    func show(preselect: CGRect?) {
        frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for screen in NSScreen.screens {
            let w = KeyWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.becomesKeyOnlyIfNeeded = false
            w.hidesOnDeactivate = false
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.acceptsMouseMovedEvents = true
            let v = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.controller = self
            v.screen = screen
            w.contentView = v
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        toolbar.controller = self
        if let p = preselect { selection = toNS(p) }
        applyTestState()
        let mouse = NSEvent.mouseLocation
        let keyWin = windows.first(where: { $0.frame.contains(mouse) }) ?? windows.first
        keyWin?.makeKeyAndOrderFront(nil)
        if let w = keyWin { w.makeFirstResponder(w.contentView) }
        refresh()
        emit(["event": "ready"])
    }

    func screenFrame(containing p: NSPoint) -> NSRect {
        (NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.screens[0]).frame
    }

    func refresh() {
        windows.forEach { $0.contentView?.needsDisplay = true; ($0.contentView as? PickerView)?.syncOutline() }
        placeToolbar()
    }

    func placeToolbar() {
        toolbar.removeFromSuperview()
        guard let sel = selection, sel.width >= 8, sel.height >= 8,
              let win = windows.first(where: { $0.frame.intersects(sel) }), let host = win.contentView else { return }
        toolbar.layoutButtons(hasLast: opts.lastRegion != nil)
        let size = toolbar.frame.size
        let local = NSRect(origin: NSPoint(x: sel.minX - win.frame.minX, y: sel.minY - win.frame.minY), size: sel.size)
        var origin = NSPoint(x: local.midX - size.width / 2, y: local.minY - size.height - 14)
        if origin.y < 12 { origin.y = local.maxY + 14 }                            // no room below → above
        if origin.y + size.height > host.bounds.height - 12 { origin.y = local.minY + 14 } // inside, bottom
        origin.x = max(12, min(origin.x, host.bounds.width - size.width - 12))
        toolbar.setFrameOrigin(origin)
        host.addSubview(toolbar)
        toolbarHost = host
    }

    func finish(_ start: Bool) {
        let result = start ? selection.map { toCG($0).integral } : nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        onDone?(result)
    }

    func fullScreen() {
        selection = screenFrame(containing: NSEvent.mouseLocation)
        snapped = true
        refresh()
        if snapMode { finish(true) }
    }

    func useLast() {
        if let l = opts.lastRegion { selection = toNS(l); snapped = true; refresh(); if snapMode { finish(true) } }
    }
}

final class PickerView: NSView {
    weak var controller: PickerController?
    weak var screen: NSScreen?
    enum Mode { case none, create(NSPoint), move(NSPoint, NSRect), resize(Int, NSRect) }
    var mode: Mode = .none
    var downAt: NSPoint = .zero
    /// the selection's gradient outline and handles (layers, above what draw() paints, under the toolbar)
    private let outline = SelectionOutline()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        outline.frame = bounds
        outline.autoresizingMask = [.width, .height]
        addSubview(outline)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The outline follows the controller's selection (called from refresh()).
    func syncOutline() {
        guard let c = controller, window != nil else { outline.update(nil, handles: [], marching: false); return }
        let sel = c.selection.map(local)
        outline.update(sel, handles: sel.map(handles) ?? [], marching: c.dragging)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    func global(_ e: NSEvent) -> NSPoint { window!.convertPoint(toScreen: e.locationInWindow) }
    func local(_ r: NSRect) -> NSRect { r.offsetBy(dx: -window!.frame.minX, dy: -window!.frame.minY) }

    func handles(_ r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
         NSPoint(x: r.maxX, y: r.midY), NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.midX, y: r.maxY),
         NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.minX, y: r.midY)]
    }

    override func draw(_ dirty: NSRect) {
        guard let c = controller else { return }
        let hole = (c.selection ?? c.hovered).map(local)
        let dim = NSBezierPath(rect: bounds)
        if let h = hole {
            dim.append(NSBezierPath(rect: h))
            dim.windingRule = .evenOdd
        }
        NSColor(white: 0, alpha: 0.42).setFill()
        dim.fill()
        // Fully transparent pixels let clicks fall through to the app underneath — keep the hole a hair opaque.
        if let h = hole {
            NSColor(white: 0, alpha: 0.012).setFill()
            NSBezierPath(rect: h).fill()
        }

        if let sel = c.selection.map(local) {
            // the outline and the handles are layers (SelectionOutline); the size label: a mint pill, dark digits
            let scale = screen?.backingScaleFactor ?? 2
            let label = "\(Int(sel.width)) × \(Int(sel.height))  ·  \(Int(sel.width * scale))×\(Int(sel.height * scale))px"
            let f = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            var at = NSPoint(x: sel.minX, y: sel.maxY + 8)
            if at.y + 26 > bounds.height { at.y = sel.maxY - 30; at.x = sel.minX + 8 }
            _ = pill(label, font: f, fg: BrandColor.Island.on, bg: BrandColor.Island.fill, at: at)
        } else if let h = hole {
            // the window under the pointer: the field at 22 % inside, a 2 pt mint line, a mint label
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.clip(to: h)
                ctx.setAlpha(BrandGradient.washHover)
                ctx.beginTransparencyLayer(in: h, auxiliaryInfo: nil)
                BrandGradient.drawField(in: h, ctx: ctx, deep: false)
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
            BrandColor.Island.fill.setStroke()
            let b = NSBezierPath(rect: h.insetBy(dx: 1, dy: 1))
            b.lineWidth = 2
            b.stroke()
            let f = NSFont.systemFont(ofSize: 12, weight: .semibold)
            _ = pill(c.snapMode ? Loc.t("capture.picker.window_snap", table: "Capture")
                                : Loc.t("capture.picker.window_record", table: "Capture"), font: f, fg: BrandColor.Island.on,
                     bg: BrandColor.Island.fill, at: NSPoint(x: h.minX + 10, y: max(10, h.maxY - 34)))
        }

        // hint on every screen, top centre
        let hint = c.snapMode ? Loc.t("capture.picker.hint_snap", table: "Capture")
                              : Loc.t("capture.picker.hint_record", table: "Capture")
        let f = NSFont.systemFont(ofSize: 13, weight: .medium)
        let icon: BlurtIcon? = c.snapMode ? .snap : nil
        let w = NSAttributedString(string: hint, attributes: [.font: f]).size().width + 28 + (icon == nil ? 0 : pillIconWidth(f))
        _ = pill(hint, font: f, fg: .white, bg: NSColor(white: 0.06, alpha: 0.78),
                 at: NSPoint(x: bounds.midX - w / 2, y: bounds.height - 64), pad: 14, icon: icon)
    }

    override func mouseMoved(with e: NSEvent) {
        guard let c = controller, c.selection == nil else { return }
        let r = windowRect(at: global(e))
        if r != c.hovered { c.hovered = r; c.refresh() }
    }

    func windowRect(at p: NSPoint) -> NSRect? {
        let cg = CGPoint(x: p.x, y: primaryHeight - p.y)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let me = Int(getpid())
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0, let pid = w[kCGWindowOwnerPID as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            // windows you can't see: fully transparent ones, and windows of background apps (agents / helpers
            // such as MobileDeviceUpdater keep an "on-screen" window you never see) unless that app is in front
            if (w[kCGWindowAlpha as String] as? Double ?? 1) < 0.05 { continue }
            if pid != me, pid_t(pid) != controller?.frontPID,
               NSRunningApplication(processIdentifier: pid_t(pid))?.activationPolicy != .regular { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.width > 40, r.height > 40, r.contains(cg) {
                return toNS(r).intersection(controller!.screenFrame(containing: p))
            }
        }
        return nil
    }

    override func mouseDown(with e: NSEvent) {
        guard let c = controller else { return }
        let p = global(e)
        downAt = p
        if e.clickCount == 2, let s = c.selection, s.contains(p) { c.finish(true); return }
        if let s = c.selection {
            for (i, h) in handles(s).enumerated() where hypot(h.x - p.x, h.y - p.y) < 10 {
                mode = .resize(i, s); return
            }
            if s.contains(p) && !c.snapped { mode = .move(p, s); return }
        }
        mode = .create(p)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let c = controller else { return }
        let p = global(e)
        let bounds = c.screenFrame(containing: downAt)
        switch mode {
        case .create(let s):
            guard hypot(p.x - s.x, p.y - s.y) > 4 else { return }
            drawRect(from: s, to: p, in: bounds)
        case .move(let s, let r):
            var n = r.offsetBy(dx: p.x - s.x, dy: p.y - s.y)
            n.origin.x = min(max(n.minX, bounds.minX), bounds.maxX - n.width)
            n.origin.y = min(max(n.minY, bounds.minY), bounds.maxY - n.height)
            c.selection = n
        case .resize(let i, let r):
            var (x0, y0, x1, y1) = (r.minX, r.minY, r.maxX, r.maxY)
            if [0, 6, 7].contains(i) { x0 = p.x }
            if [2, 3, 4].contains(i) { x1 = p.x }
            if [0, 1, 2].contains(i) { y0 = p.y }
            if [4, 5, 6].contains(i) { y1 = p.y }
            c.selection = NSRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
                .intersection(bounds)
            c.snapped = false
        case .none: break
        }
        if case .none = mode {} else { c.dragging = c.selection != nil }
        c.refresh()
    }

    func drawRect(from s: NSPoint, to p: NSPoint, in bounds: NSRect) {
        guard let c = controller else { return }
        let q = NSPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
        c.selection = NSRect(x: min(s.x, q.x), y: min(s.y, q.y), width: abs(q.x - s.x), height: abs(q.y - s.y))
        c.snapped = false
        c.hovered = nil
    }

    override func mouseUp(with e: NSEvent) {
        guard let c = controller else { return }
        if case .create(let s) = mode {
            let p = global(e)
            if hypot(p.x - s.x, p.y - s.y) <= 4 {
                if let h = c.hovered ?? windowRect(at: s) { c.selection = h; c.snapped = true; c.hovered = nil }
            } else {
                drawRect(from: s, to: p, in: c.screenFrame(containing: downAt))   // drag events can be coalesced
            }
        }
        if let s = c.selection, s.width < 16 || s.height < 16 { c.selection = nil }
        mode = .none
        c.dragging = false
        c.refresh()
        if c.snapMode, c.selection != nil { c.finish(true) }   // like ⌘⇧4: letting go takes the shot
    }

    override func keyDown(with e: NSEvent) {
        guard let c = controller else { return }
        switch Int(e.keyCode) {
        case kVK_Escape:
            if c.selection != nil && e.modifierFlags.contains(.shift) { c.selection = nil; c.refresh() } else { c.finish(false) }
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: if c.selection != nil { c.finish(true) }
        case kVK_ANSI_F: c.fullScreen()
        case kVK_ANSI_L: c.useLast()
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            guard var s = c.selection else { return }
            let d: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
            switch Int(e.keyCode) {
            case kVK_LeftArrow: s.origin.x -= d
            case kVK_RightArrow: s.origin.x += d
            case kVK_UpArrow: s.origin.y += d
            default: s.origin.y -= d
            }
            c.selection = s
            c.refresh()
        default: super.keyDown(with: e)
        }
    }
}

/// The selection's outline (§3.1, the one thin gradient line in the system): a 2 pt `Island.on` @ 60 % solid
/// under-stroke so it holds on white and on black, then the base gradient, corner to corner across the selection, seen
/// through 2 pt [6, 4] dashes; the handles on top (flat mint, a 1.5 pt white ring, a 1 pt shadow). The dashes march
/// (10 pt/s) while a drag draws, moves or resizes it; still with Reduce Motion. Layers, so the marching costs no redraw
/// of the screen-sized picker view.
final class SelectionOutline: NSView {
    private let under = CAShapeLayer()
    private let stroke = CAGradientLayer()
    private let dashes = CAShapeLayer()
    private let knobs = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        under.fillColor = nil
        under.strokeColor = BrandColor.Island.on.withAlphaComponent(0.6).cgColor
        under.lineWidth = 2
        BrandGradient.layer(BrandGradient.linearStops, .diagonal, flipped: false, into: stroke)
        dashes.fillColor = nil
        dashes.strokeColor = NSColor.black.cgColor
        dashes.lineWidth = 2
        dashes.lineDashPattern = [6, 4]
        stroke.mask = dashes
        knobs.fillColor = BrandColor.Island.fill.cgColor
        knobs.strokeColor = NSColor.white.cgColor
        knobs.lineWidth = 1.5
        knobs.shadowColor = NSColor.black.cgColor
        knobs.shadowOpacity = 0.35
        knobs.shadowRadius = 1
        knobs.shadowOffset = CGSize(width: 0, height: -0.5)
        for l in [under, stroke, knobs] as [CALayer] { layer?.addSublayer(l); l.isHidden = true }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `sel` in this view's coordinates (nil hides it), its handle centres, and whether a drag is on.
    func update(_ sel: NSRect?, handles: [NSPoint], marching: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let sel = sel, sel.width > 0, sel.height > 0 else {
            for l in [under, stroke, knobs] as [CALayer] { l.isHidden = true }
            dashes.removeAnimation(forKey: "march")
            return
        }
        // on the selection's edge, outside it: nothing of the outline lands in the captured pixels
        let edge = sel.insetBy(dx: -1, dy: -1)
        under.frame = bounds
        under.path = CGPath(rect: edge, transform: nil)
        stroke.frame = sel.insetBy(dx: -2, dy: -2)
        dashes.frame = stroke.bounds
        dashes.path = CGPath(rect: edge.offsetBy(dx: -stroke.frame.minX, dy: -stroke.frame.minY), transform: nil)
        let p = CGMutablePath()
        for h in handles {
            p.addRoundedRect(in: CGRect(x: h.x - 4.5, y: h.y - 4.5, width: 9, height: 9), cornerWidth: 2.5, cornerHeight: 2.5)
        }
        knobs.frame = bounds
        knobs.path = p
        for l in [under, stroke, knobs] as [CALayer] { l.isHidden = false }
        if marching && !reduceMotion {
            if dashes.animation(forKey: "march") == nil {
                let a = CABasicAnimation(keyPath: "lineDashPhase")
                a.fromValue = 0
                a.toValue = -10                    // one dash + gap (6 + 4) per second: 10 pt/s
                a.duration = 1
                a.repeatCount = .infinity
                dashes.add(a, forKey: "march")
            }
        } else {
            dashes.removeAnimation(forKey: "march")
        }
    }
}

/// A pill on the capture chrome (the picker's toolbar). Neutral glass by default; the primary action takes
/// `gradient` (BrandGradient.buttonStops) with a white semibold title — hover is a white film (×1.04), pressed a black
/// one (×0.92). `dot`: a small dot before the title (Record: `rec`).
final class PillButton: NSButton {
    var fill: NSColor = NSColor(white: 1, alpha: 0.12)
    var fg: NSColor = .white
    var gradient: [(UInt32, CGFloat)]?
    var dot: NSColor?
    var hovering = false { didSet { needsDisplay = true } }
    private static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let dotSize: CGFloat = 9

    convenience init(_ title: String, symbol: String? = nil, fill: NSColor = NSColor(white: 1, alpha: 0.1),
                     gradient: [(UInt32, CGFloat)]? = nil, fg: NSColor = .white, dot: NSColor? = nil,
                     target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.fill = fill
        self.gradient = gradient
        self.fg = fg
        self.dot = dot
        self.target = target
        self.action = action
        isBordered = false
        if let s = symbol { image = NSImage(systemSymbolName: s, accessibilityDescription: title) }
        let lead: CGFloat = dot != nil ? PillButton.dotSize + 6 : symbol != nil ? 18 : 0
        let w = NSAttributedString(string: title, attributes: [.font: PillButton.font]).size().width + 28 + lead
        setFrameSize(NSSize(width: ceil(w), height: 32))
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override var allowsVibrancy: Bool { false }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        if let g = gradient, let ctx = NSGraphicsContext.current?.cgContext {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            BrandGradient.draw(g, in: r, ctx: ctx, .diagonal, flipped: isFlipped)
            if isHighlighted {
                NSColor(white: 0, alpha: 1 - BrandGradient.buttonPressed).setFill()
                shape.fill()
            } else if hovering {
                NSColor(white: 1, alpha: BrandGradient.buttonHover - 1).setFill()
                shape.fill()
            }
            // a 1 pt inner highlight along the top, as on BrandButton
            NSColor(white: 1, alpha: 0.18).setFill()
            let top = isFlipped ? r.minY : r.maxY - 1
            NSRect(x: r.minX + r.height * 0.3, y: top, width: r.width - r.height * 0.6, height: 1).fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            (hovering ? fill.blended(withFraction: 0.18, of: .white) ?? fill : fill).setFill()
            shape.fill()
        }
        let s = NSAttributedString(string: title, attributes: [.font: PillButton.font, .foregroundColor: fg])
        var x = (bounds.width - s.size().width) / 2
        if let d = dot {
            let side = PillButton.dotSize
            x += (side + 6) / 2
            let o = NSRect(x: x - 6 - side, y: (bounds.height - side) / 2, width: side, height: side)
            d.setFill()
            NSBezierPath(ovalIn: o).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: o.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
        } else if let img = image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .bold).applying(.init(paletteColors: [fg]))) {
            x += 9
            let sz = img.size
            img.draw(in: NSRect(x: x - 9 - sz.width, y: (bounds.height - sz.height) / 2, width: sz.width, height: sz.height))
        }
        s.draw(at: NSPoint(x: x, y: (bounds.height - s.size().height) / 2))
    }
}

final class PickerToolbar: NSVisualEffectView {
    weak var controller: PickerController?
    private var built = false

    func layoutButtons(hasLast: Bool) {
        if built { return }
        built = true
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .vibrantDark)
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        layer?.masksToBounds = true
        maskImage = roundedMask(22)     // clips the behind-window blur too
        var buttons: [NSButton] = []
        buttons.append(PillButton(Loc.t("capture.picker.full_screen", table: "Capture"), symbol: "arrow.up.left.and.arrow.down.right",
                                  fill: NSColor(white: 1, alpha: 0.1), target: self, action: #selector(full)))
        if hasLast {
            buttons.append(PillButton(Loc.t("capture.picker.last_area", table: "Capture"), symbol: "clock.arrow.circlepath",
                                      fill: NSColor(white: 1, alpha: 0.1), target: self, action: #selector(last)))
        }
        buttons.append(PillButton(Loc.t("capture.picker.cancel", table: "Capture"), fill: NSColor(white: 1, alpha: 0.1), target: self, action: #selector(cancel)))
        let snap = controller?.snapMode == true
        // the one primary action: the button gradient, a white title; Record leads with the red dot (the tape)
        buttons.append(PillButton(snap ? Loc.t("capture.picker.snap", table: "Capture") : Loc.t("capture.picker.start", table: "Capture"),
                                  symbol: snap ? "camera.fill" : nil, gradient: BrandGradient.buttonStops, fg: .white,
                                  dot: snap ? nil : BrandColor.Island.rec, target: self, action: #selector(start)))
        var x: CGFloat = 6
        for b in buttons {
            b.setFrameOrigin(NSPoint(x: x, y: 6))
            addSubview(b)
            x += b.frame.width + 6
        }
        setFrameSize(NSSize(width: x, height: 44))
    }
    @objc func full() { controller?.fullScreen() }
    @objc func last() { controller?.useLast() }
    @objc func cancel() { controller?.finish(false) }
    @objc func start() { controller?.finish(true) }
}
