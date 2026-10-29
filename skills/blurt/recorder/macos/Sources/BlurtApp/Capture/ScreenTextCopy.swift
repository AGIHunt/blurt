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

/// A crosshair and the loupe (Loupe.swift) until the drag starts, as Bob's: transparent windows over every screen take
/// the mouse, invisible until the screen's stills are in (so no still holds the picker itself); the selection is the
/// one solid line every area picker draws (BrandColor.Island.selection) with a faint fill of it, the same while it is
/// drawn and after; the loupe's label says the point, then the selection's size. Letting go reads the selection from
/// the same still (what the user saw, no second capture); Esc or a click without a drag cancels.
final class TextDragPicker {
    private var windows: [KeyWindow] = []
    private let done: (CGRect?, CGImage?) -> Void
    private var finished = false
    var start: NSPoint?
    var current: NSPoint?
    /// the pointer, global AppKit points
    var pointer = NSEvent.mouseLocation
    let stills = LoupeStills()
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
            w.alphaValue = 0
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let v = TextDragView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.picker = self
            w.contentView = v
            w.setFrame(screen.frame, display: false)
            w.orderFrontRegardless()
            windows.append(w)
        }
        stills.capture(NSScreen.screens) { [weak self] in
            guard let self = self, !self.finished else { return }
            self.windows.forEach { $0.alphaValue = 1 }
            self.redraw()
        }
        // the key window under the pointer takes Esc without activating Blurt; the crosshair from the first move
        windows.first { $0.frame.contains(NSEvent.mouseLocation) }?.makeKey()
        NSCursor.crosshair.push()
        emit(["event": "screen_text_picker", "screens": windows.count])
    }

    func moved(to p: NSPoint) {
        let old = pointer
        pointer = p
        for w in windows {
            guard let v = w.contentView else { continue }
            if selection != nil { v.needsDisplay = true; continue }
            v.setNeedsDisplay(Loupe.frame(for: old, in: v).insetBy(dx: -12, dy: -12))
            v.setNeedsDisplay(Loupe.frame(for: p, in: v).insetBy(dx: -12, dy: -12))
        }
    }

    func redraw() { windows.forEach { $0.contentView?.needsDisplay = true } }

    func finish() {
        let r = selection
        let crop = r.flatMap { stills.crop($0) }
        close()
        guard let s = r, s.width >= 4, s.height >= 4 else { return done(nil, nil) }
        done(toCG(s).integral, crop)
    }

    func close() {
        guard !finished else { return }
        finished = true
        stills.cancel()
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

final class TextDragView: NSView {
    weak var picker: TextDragPicker?

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
            let r = s.offsetBy(dx: -w.frame.minX, dy: -w.frame.minY)
            if !r.intersection(bounds).isEmpty {
                BrandColor.Island.selection.withAlphaComponent(0.10).setFill()
                r.intersection(bounds).fill()
                // the one line, just outside the area (nothing of it lands in what is read)
                let edge = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1))
                edge.lineWidth = 2
                BrandColor.Island.selection.setStroke()
                edge.stroke()
            }
        }
        Loupe.draw(pointer: p.pointer, in: self, stills: p.stills,
                   label: p.selection.map(Loupe.sizeLabel) ?? Loupe.pointLabel(p.pointer))
    }
}
