// ⌥⇧C Copy Text from Screen, ⌥⇧T Translate Text from Screen (docs/design/screen-text.md): a crosshair, one drag,
// let go — no dim over the screen, no window to click, no toolbar (as Bob's OCR and ⌘⇧4's drag). The text in the area
// (BlurtCore ScreenText: what the edges cut is left out, wrapped lines are one again, lists, tables and code keep
// their shape) — or its translation — is on the clipboard, and when the cursor was in a text field it is typed there
// too (⌘V; the clipboard keeps it, as Bob's does). Nothing is saved: no card, no file, no sound.
//
// The optional second pass (ScreenTextRefine) reads the same picture again: when it can answer within a moment (this
// Mac's model, warm) the copy waits for it before typing into a field; otherwise the draft goes at once and the merge
// replaces it on the clipboard only while the clipboard still holds the draft — never something the user copied since.
// Translate: the text, then polish.py's `translate` (the cloud polish model when set up, else the local polish model),
// "Translating…" in the island meanwhile and the translation in it after.
import AppKit
import BlurtCore
import Carbon.HIToolbox

final class ScreenTextCopy {
    static let shared = ScreenTextCopy()
    var app: App? { NSApp.delegate as? App }
    static let toastKey = "screen_text"
    private var drag: TextDragPicker?

    /// The general pasteboard; tests: BLURT_TEST_PASTEBOARD names a private one (the user's clipboard stays theirs).
    static var pasteboard: NSPasteboard {
        let env = ProcessInfo.processInfo.environment
        if env["BLURT_TEST_COMMANDS"] == "1", let n = env["BLURT_TEST_PASTEBOARD"], !n.isEmpty { return NSPasteboard(name: .init(n)) }
        return .general
    }

    /// Where the result is typed: the app in front and its focused element, read before the drag — only a text field
    /// Accessibility can see (never a password field, never with secure input on); nil = copy only.
    struct Field { let pid: pid_t; let role: String? }
    static func fieldInFront() -> Field? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(), let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != getpid() else { return nil }
        let f = DictationInsert.focusedElement()
        guard f.editable, !f.secure, f.pid == nil || f.pid == front.processIdentifier else { return nil }
        return Field(pid: front.processIdentifier, role: f.role)
    }

    func cancel() { drag?.close(); drag = nil }

    func hotkey(via: String, translate: Bool = false) {
        guard let app = app, app.resident, app.picker == nil, drag == nil else { return }
        guard Snapper.screenAllowed else {
            emit(["event": "screen_text_failed", "screen_recording": false, "stage": "picker"])
            return ScreenHelp.show(.snap, grant: .missing)
        }
        if NoteBubble.shared.isOpen { NoteBubble.shared.commit() }
        // the second pass on this Mac (or the translation's model): asked to warm up while the user drags
        if ScreenTextRefine.mode == .local {
            if ScreenTextRefine.installed == true { ScreenTextRefine.shared.warm() } else { ScreenTextRefine.refreshInstalled { if ScreenTextRefine.installed == true { ScreenTextRefine.shared.warm() } } }
        }
        if translate { Self.warmTranslator() }
        let field = Self.fieldInFront()
        let p = TextDragPicker { [weak self] r, crop in
            unregisterHotkey(.pickEsc)
            self?.drag = nil
            guard let r = r else { return }
            self?.read(r, via: via, translate: translate, field: field, still: crop)
        }
        drag = p
        registerHotkey(.pickEsc, key: kVK_Escape, mods: 0)
        p.show()
    }

    /// `region`: global top-left points. Tests call it directly (`screentext x,y,w,h [PNG]`, `screentranslate …`).
    func read(_ region: CGRect, via: String, translate: Bool = false, field: Field? = nil, still: CGImage? = nil) {
        let t0 = CACurrentMediaTime()
        // the drag's own still when it has one (what the user saw), else a capture of the region
        let take: (@escaping (CGImage?, CGFloat) -> Void) -> Void = { f in
            if let s = still { f(s, 2) } else { captureStill(rect: region, showsCursor: false, completion: f) }
        }
        take { [weak self] img, _ in
            guard let self = self else { return }
            guard let img = img else { return snapper.snapFailed() }
            let words = Array(DictationVocabulary.shared.active().prefix(100).map(\.term))
            let shot = CACurrentMediaTime()
            DispatchQueue.global(qos: .userInitiated).async {
                let r = try? ScreenText.text(in: img, words: words)
                DispatchQueue.main.async {
                    let text = r?.text ?? ""
                    var ev: [String: Any] = ["event": "screen_text", "via": via, "chars": text.count, "lines": text.split(separator: "\n").count,
                                             "capture_ms": Int((shot - t0) * 1000), "vision_ms": r?.ms ?? 0,
                                             "ms": Int((CACurrentMediaTime() - t0) * 1000), "translate": translate, "field": field != nil]
                    if ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1" { ev["text"] = text }   // never in a real run's log
                    emit(ev)
                    guard !text.isEmpty else {
                        island.toast(Loc.t("capture.text.none", table: "Capture"), key: Self.toastKey, seconds: 3)
                        return
                    }
                    if translate { self.translate(text, image: img, field: field) } else { self.copy(text, image: img, field: field) }
                }
            }
        }
    }

    // MARK: copy

    private func copy(_ draft: String, image: CGImage, field: Field?) {
        let refine = ScreenTextRefine.shared
        // typing into a field: wait for a second pass that can answer at once, so the field gets the better text
        if field != nil, ScreenTextRefine.quick {
            var sent = false
            let send: (String) -> Void = { [weak self] t in
                guard !sent else { return }
                sent = true
                self?.deliver(t, field: field)
            }
            refine.read(image: image, draft: draft) { r in send((r?["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? draft) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { send(draft) }
            return
        }
        let changeCount = deliver(draft, field: field)
        refine.read(image: image, draft: draft) { r in
            guard let t = r?["text"] as? String, !t.isEmpty, t != draft else { return }
            let pb = Self.pasteboard
            // only over our own draft: anything copied since is the user's
            guard pb.changeCount == changeCount else { return emit(["event": "screen_text_refine_applied", "applied": false, "why": "clipboard_changed"]) }
            pb.clearContents()
            pb.setString(t, forType: .string)
            var ev: [String: Any] = ["event": "screen_text_refine_applied", "applied": true]
            if ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1" { ev["text"] = t }
            emit(ev)
        }
    }

    /// `text` on the clipboard, and typed into `field` when it is still the app in front → the clipboard's changeCount.
    @discardableResult
    private func deliver(_ text: String, field: Field?, toast: String? = nil) -> Int {
        let pb = Self.pasteboard
        var typed = false
        if let f = field, NSWorkspace.shared.frontmostApplication?.processIdentifier == f.pid {
            typed = DictationInsert.pasteKeeping(text, on: pb)
        } else {
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
        emit(["event": "screen_text_delivered", "typed": typed, "field": field != nil, "chars": text.count])
        island.toast(toast ?? Loc.t(typed ? "capture.text.typed" : "capture.text.copied", table: "Capture"),
                     key: Self.toastKey, icon: toast == nil ? .check : nil, seconds: toast == nil ? 2 : 8)
        return pb.changeCount
    }

    // MARK: translate

    static func warmTranslator() {
        guard ScreenTextRefine.cloudPayload == nil, !WarmServer.running("polish-serve") else { return }
        _ = WarmSpawn.start("polish.py", ["serve", "--preload"], server: "polish-serve")
    }

    private func translate(_ text: String, image: CGImage, field: Field?) {
        island.toast(Loc.t("capture.text.translating", table: "Capture"), key: Self.toastKey, seconds: 30)
        let cloud = ScreenTextRefine.cloudPayload
        let t0 = CACurrentMediaTime()
        DispatchQueue.global(qos: .userInitiated).async {
            var r: [String: Any]?
            if WarmServer.running("polish-serve") {
                var req: [String: Any] = ["cmd": "translate", "text": text, "target": "auto"]
                if let c = cloud { req["cloud"] = c }
                r = WarmServer.call("polish-serve", req, timeout: 40)
            }
            if r == nil {       // no server (yet): the CLI, the key on stdin
                var o: [String: Any] = ["text": text, "target": "auto"]
                if let c = cloud { o["cloud"] = c }
                let body = try? JSONSerialization.data(withJSONObject: o)
                let sem = DispatchSemaphore(value: 0)
                Task {
                    r = try? await ScriptRunner.shared.json("polish.py", ["translate", "--stdin"], stdin: body, timeout: 60)
                    sem.signal()
                }
                sem.wait()
            }
            DispatchQueue.main.async {
                let out = (r?["ok"] as? Bool == true ? r?["text"] as? String : nil) ?? ""
                var ev: [String: Any] = ["event": "screen_translate", "ok": !out.isEmpty, "ms": Int((CACurrentMediaTime() - t0) * 1000),
                                         "cloud": r?["cloud"] ?? NSNull(), "model": r?["model"] ?? NSNull()]
                if let e = r?["cloud_error"] { ev["cloud_error"] = e }
                if ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1" { ev["text"] = out }
                emit(ev)
                guard !out.isEmpty else {
                    // the text itself still helps: copied, and said so
                    self.deliver(text, field: nil, toast: Loc.t("capture.text.translate_failed", table: "Capture"))
                    return
                }
                // the translation shows in the island (to read it here), and is on the clipboard / in the field
                self.deliver(out, field: field, toast: String(out.prefix(280)))
            }
        }
    }
}

// MARK: - The drag

/// A crosshair and a loupe until the drag starts (as Bob's): transparent windows over every screen take the mouse; the
/// screen is frozen into a still the moment it opens, the loupe magnifies that still around the pointer (8×, a pixel
/// grid's crosshair) with the point under it, and while the drag draws, the selection is a thin mint outline and the
/// loupe says its size. Letting go reads the selection from the same still (what the user saw, no second capture);
/// Esc or a click without a drag cancels. Never captured itself (above the normal window layer, like our other chrome).
final class TextDragPicker {
    private var windows: [KeyWindow] = []
    private let done: (CGRect?, CGImage?) -> Void
    private var finished = false
    var start: NSPoint?
    var current: NSPoint?
    /// the pointer, global AppKit points
    var pointer = NSEvent.mouseLocation
    /// each screen's still: (its frame, the picture, pixels a point)
    var stills: [(frame: NSRect, image: CGImage, scale: CGFloat)] = []
    var selection: NSRect? {
        guard let a = start, let b = current else { return nil }
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    init(done: @escaping (CGRect?, CGImage?) -> Void) { self.done = done }

    func show() {
        for screen in NSScreen.screens {
            let w = KeyWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = false
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let v = TextDragView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.picker = self
            w.contentView = v
            w.setFrame(screen.frame, display: false)
            w.orderFrontRegardless()
            windows.append(w)
            // the still the loupe magnifies and the selection is read from (our own windows are never in it)
            let frame = screen.frame
            captureStill(rect: toCG(frame), showsCursor: false) { [weak self] img, scale in
                guard let self = self, !self.finished, let img = img else { return }
                self.stills.append((frame, img, scale))
                self.redraw()
            }
        }
        // the key window under the pointer takes Esc without activating Blurt; the crosshair from the first move
        windows.first { $0.frame.contains(NSEvent.mouseLocation) }?.makeKey()
        NSCursor.crosshair.push()
        emit(["event": "screen_text_picker", "screens": windows.count])
    }

    func moved(to p: NSPoint) {
        pointer = p
        redraw()
    }

    func redraw() { windows.forEach { $0.contentView?.needsDisplay = true } }

    func still(at p: NSPoint) -> (frame: NSRect, image: CGImage, scale: CGFloat)? { stills.first { $0.frame.contains(p) } }

    func finish() {
        let r = selection
        let crop: CGImage? = r.flatMap { s in
            // the selection inside one screen's still: cut out of it (else a fresh capture across the screens)
            guard let st = stills.first(where: { $0.frame.contains(s) }) else { return nil }
            let px = CGRect(x: (s.minX - st.frame.minX) * st.scale, y: (st.frame.maxY - s.maxY) * st.scale,
                            width: s.width * st.scale, height: s.height * st.scale).integral
            return st.image.cropping(to: px)
        }
        close()
        guard let s = r, s.width >= 4, s.height >= 4 else { return done(nil, nil) }
        done(toCG(s).integral, crop)
    }

    func close() {
        guard !finished else { return }
        finished = true
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

final class TextDragView: NSView {
    weak var picker: TextDragPicker?
    static let loupe: CGFloat = 120          // points
    static let zoom: CGFloat = 8

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func keyDown(with event: NSEvent) { if event.keyCode == UInt16(kVK_Escape) { picker?.close(); ScreenTextCopy.shared.cancel() } }

    private func global(_ e: NSEvent) -> NSPoint { window!.convertPoint(toScreen: e.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set(); picker?.moved(to: global(event)) }
    override func mouseDown(with event: NSEvent) { picker?.start = global(event); picker?.current = global(event); picker?.moved(to: global(event)) }
    override func mouseDragged(with event: NSEvent) { picker?.current = global(event); picker?.moved(to: global(event)) }
    override func mouseUp(with event: NSEvent) { picker?.current = global(event); picker?.finish() }

    override func draw(_ dirty: NSRect) {
        guard let p = picker, let w = window else { return }
        if let s = p.selection {
            let r = s.offsetBy(dx: -w.frame.minX, dy: -w.frame.minY).intersection(bounds)
            if !r.isEmpty {
                BrandColor.Island.fill.withAlphaComponent(0.08).setFill()
                r.fill()
                let outer = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
                outer.lineWidth = 1
                NSColor(white: 0, alpha: 0.35).setStroke()
                outer.stroke()
                let edge = NSBezierPath(rect: r.insetBy(dx: 1.5, dy: 1.5))
                edge.lineWidth = 1.5
                BrandColor.Island.fill.setStroke()
                edge.stroke()
            }
        }
        guard w.frame.contains(p.pointer) else { return }
        drawLoupe(p, in: w)
    }

    /// The loupe below-right of the pointer (flipped at the screen's edges), its label under it: the point (top-left
    /// points, as the selection is measured) or, while dragging, the selection's size.
    private func drawLoupe(_ p: TextDragPicker, in w: NSWindow) {
        let L = Self.loupe, gap: CGFloat = 18, labelH: CGFloat = 22
        let at = NSPoint(x: p.pointer.x - w.frame.minX, y: p.pointer.y - w.frame.minY)
        var o = NSPoint(x: at.x + gap, y: at.y - gap - L - labelH)
        if o.x + L > bounds.maxX - 4 { o.x = at.x - gap - L }
        if o.y < 4 { o.y = at.y + gap }
        let box = NSRect(x: o.x, y: o.y + labelH, width: L, height: L)
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        let shape = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
        shadow.set()
        NSColor(white: 0.08, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        shape.addClip()
        if let st = p.still(at: p.pointer) {
            // the still's pixels around the pointer, each one Z points wide (nearest neighbour: a pixel grid)
            let span = L / Self.zoom                      // points of the screen shown
            let px = CGRect(x: (p.pointer.x - st.frame.minX - span / 2) * st.scale, y: (st.frame.maxY - p.pointer.y - span / 2) * st.scale,
                            width: span * st.scale, height: span * st.scale).integral
            if let part = st.image.cropping(to: px) {
                ctx.interpolationQuality = .none
                ctx.draw(part, in: box)
            }
        }
        // the crosshair: the pixel under the pointer framed, lines through it
        let cell = Self.zoom / max(1, p.still(at: p.pointer)?.scale ?? 2)
        let c = NSPoint(x: box.midX, y: box.midY)
        BrandColor.Island.fill.withAlphaComponent(0.85).setStroke()
        let lines = NSBezierPath()
        lines.lineWidth = 1
        lines.move(to: NSPoint(x: box.minX, y: c.y)); lines.line(to: NSPoint(x: c.x - cell, y: c.y))
        lines.move(to: NSPoint(x: c.x + cell, y: c.y)); lines.line(to: NSPoint(x: box.maxX, y: c.y))
        lines.move(to: NSPoint(x: c.x, y: box.minY)); lines.line(to: NSPoint(x: c.x, y: c.y - cell))
        lines.move(to: NSPoint(x: c.x, y: c.y + cell)); lines.line(to: NSPoint(x: c.x, y: box.maxY))
        lines.stroke()
        NSBezierPath(rect: NSRect(x: c.x - cell, y: c.y - cell, width: cell * 2, height: cell * 2)).stroke()
        ctx.restoreGState()
        NSColor(white: 1, alpha: 0.9).setStroke()
        let rim = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        rim.lineWidth = 1
        rim.stroke()
        // the label
        let text: String
        if let s = p.selection, s.width >= 1 || s.height >= 1 {
            text = "\(Int(s.width.rounded())) × \(Int(s.height.rounded()))"
        } else {
            let g = toCG(NSRect(origin: p.pointer, size: .zero))
            text = "\(Int(g.minX.rounded())), \(Int(g.minY.rounded()))"
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let a = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(white: 1, alpha: 0.92)])
        let tw = ceil(a.size().width) + 16
        let pill = NSRect(x: box.midX - tw / 2, y: o.y, width: tw, height: labelH - 4)
        NSColor(white: 0.08, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        a.draw(at: NSPoint(x: pill.minX + 8, y: pill.midY - a.size().height / 2))
    }
}
