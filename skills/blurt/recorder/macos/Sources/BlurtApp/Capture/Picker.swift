import AppKit
import BlurtCore
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import ServiceManagement

// MARK: - Region picker

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
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

    func show(preselect: CGRect?) {
        frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for screen in NSScreen.screens {
            let w = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
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
        activateApp()
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
        windows.forEach { $0.contentView?.needsDisplay = true }
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
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let b = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
            b.lineWidth = 1.5
            b.stroke()
            for p in handles(sel) {
                let r = NSRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
                NSColor.white.setFill()
                NSBezierPath(roundedRect: r, xRadius: 2.5, yRadius: 2.5).fill()
                accent.setStroke()
                let hb = NSBezierPath(roundedRect: r, xRadius: 2.5, yRadius: 2.5)
                hb.lineWidth = 1
                hb.stroke()
            }
            let scale = screen?.backingScaleFactor ?? 2
            let label = "\(Int(sel.width)) × \(Int(sel.height))  ·  \(Int(sel.width * scale))×\(Int(sel.height * scale))px"
            let f = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            var at = NSPoint(x: sel.minX, y: sel.maxY + 8)
            if at.y + 26 > bounds.height { at.y = sel.maxY - 30; at.x = sel.minX + 8 }
            _ = pill(label, font: f, fg: .white, bg: NSColor(white: 0.08, alpha: 0.82), at: at)
        } else if let h = hole {
            accent.withAlphaComponent(0.9).setStroke()
            let b = NSBezierPath(rect: h.insetBy(dx: 1.5, dy: 1.5))
            b.lineWidth = 3
            b.setLineDash([10, 6], count: 2, phase: 0)
            b.stroke()
            let f = NSFont.systemFont(ofSize: 12, weight: .semibold)
            _ = pill(c.snapMode ? Loc.t("capture.picker.window_snap", table: "Capture")
                                : Loc.t("capture.picker.window_record", table: "Capture"), font: f, fg: .white,
                     bg: accent.withAlphaComponent(0.92), at: NSPoint(x: h.minX + 10, y: max(10, h.maxY - 34)))
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
            guard (w[kCGWindowLayer as String] as? Int) == 0, let pid = w[kCGWindowOwnerPID as String] as? Int, pid != me,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            // windows you can't see: fully transparent ones, and windows of background apps (agents / helpers
            // such as MobileDeviceUpdater keep an "on-screen" window you never see) unless that app is in front
            if (w[kCGWindowAlpha as String] as? Double ?? 1) < 0.05 { continue }
            if pid_t(pid) != controller?.frontPID,
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

final class PillButton: NSButton {
    var fill: NSColor = NSColor(white: 1, alpha: 0.12)
    var fg: NSColor = .white
    var hovering = false { didSet { needsDisplay = true } }

    convenience init(_ title: String, symbol: String? = nil, fill: NSColor, fg: NSColor = .white, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.fill = fill
        self.fg = fg
        self.target = target
        self.action = action
        isBordered = false
        if let s = symbol { image = NSImage(systemSymbolName: s, accessibilityDescription: title) }
        let w = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
            .size().width + (symbol == nil ? 28 : 46)
        setFrameSize(NSSize(width: w, height: 32))
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override var allowsVibrancy: Bool { false }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        (hovering ? fill.blended(withFraction: 0.18, of: .white) ?? fill : fill).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        let s = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: fg])
        var x = (bounds.width - s.size().width) / 2
        if let img = image?.withSymbolConfiguration(
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
        buttons.append(PillButton(snap ? Loc.t("capture.picker.snap", table: "Capture") : Loc.t("capture.picker.start", table: "Capture"), symbol: snap ? "camera.fill" : "record.circle.fill",
                                  fill: accent, target: self, action: #selector(start)))
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
