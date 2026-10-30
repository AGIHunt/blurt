// ⌥C Copy Text from Screen, ⌥T Translate Text from Screen (docs/design/screen-text.md): a crosshair, one drag,
// let go — no dim over the screen, no window to click, no toolbar (as Bob's OCR and ⌘⇧4's drag). The text in the area
// (BlurtCore ScreenText: what the edges cut is left out, wrapped lines are one again, lists, tables and code keep
// their shape) — or its translation — is on the clipboard, and ⌘V'd into the app the key was pressed in by dictation's rules
// (BlurtCore ScreenTextPaste over DictationPastePolicy: also WeChat's input box and other fields Accessibility can't
// read; never a password field, Blurt itself, an app the user switched to meanwhile, or a focus Accessibility reads as
// no text field). The clipboard keeps it either way, as Bob's does. Nothing is saved: no card, no file, no sound.
//
// What the island says is true (2026-10-30): "Pasted" only once the field, read back, shows the text
// (DictationInsert.confirmLanding — dictation's landing check); a paste that can't be confirmed (an unreadable field,
// a field that didn't show it within 1.5 s) says "Copied · ⌘V to paste"; no paste says "Copied".
//
// The optional second pass (ScreenTextRefine) reads the same picture again: when it can answer within a moment (this
// Mac's model, warm) the copy waits for it before pasting; otherwise the draft goes at once and the merge replaces it
// on the clipboard only while the clipboard still holds the draft — never something the user copied since.
// Translate: the text, then polish.py's `translate` into Settings → Copy Text from Screen → "⌥T translates into" (⌥T's
// own: ScreenTranslateConfig; Auto = your own language ↔ the other one, TranslateAutoPair; a fixed language always
// gives that language — a text already in it is copied as it is, and the island says so), by the cloud model when it
// is set up and ⌥T's own cloud switch is on, else this Mac's polish model. "Translating…" in the island meanwhile; then one status line in the island and the translation
// in a card under it (ScreenTextCard: Copy, Esc, gone after 10 s unless pointed at).
import AppKit
import BlurtCore
import Carbon.HIToolbox

final class ScreenTextCopy {
    static let shared = ScreenTextCopy()
    var app: App? { NSApp.delegate as? App }
    static let toastKey = "screen_text"
    private var drag: TextDragPicker?

    /// The clipboard the result goes on: the general one; a test build's own (DictationInsert.pasteboard:
    /// BLURT_TEST_PASTEBOARD, else one of the process's) — a test never touches the user's clipboard.
    static var pasteboard: NSPasteboard { DictationInsert.pasteboard }

    /// The app the key was pressed in (the drag's windows never take the focus from it): the result is pasted only
    /// there — never into an app the user switched to while it was read or translated (as a slow dictation's).
    struct Target { let pid: pid_t? }

    static func target() -> Target { Target(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier) }

    /// What ScreenTextPaste decides now, from what DictationInsert.situation() reads now (as a dictation's paste does
    /// at its paste: an Electron app's field woken at the key-down is readable by then), plus whether the app in front
    /// is still `t`'s. Test builds: the test pad when it is open (a text view of our own, never another app), else
    /// the clipboard only. → the decision and the focused element's role (for the log).
    static func decide(_ t: Target?) -> (decision: ScreenTextPaste.Decision, role: String?) {
        guard let t = t else { return (.copy(reason: "no_target"), nil) }
        if DictationInsert.testMode {
            guard DictationTestPad.textView != nil else { return (.copy(reason: "test_mode"), nil) }
            return (ScreenTextPaste.decide(.init(hasFrontApp: true, frontIsBlurt: false, secureInput: false, accessibility: true,
                                                 focusIsText: true)), "test_pad")
        }
        var now = DictationInsert.situation()
        now.situation.appChanged = now.front?.processIdentifier != t.pid
        return (ScreenTextPaste.decide(now.situation), now.focus.role)
    }

    func cancel() { drag?.close(); drag = nil }

    func hotkey(via: String, translate: Bool = false) {
        guard let app = app, app.resident, app.picker == nil, drag == nil else { return }
        guard Snapper.screenAllowed else {
            emit(["event": "screen_text_failed", "screen_recording": false, "stage": "picker"])
            return ScreenHelp.show(.text, grant: .missing)
        }
        if NoteBubble.shared.isOpen { NoteBubble.shared.commit() }
        ScreenTextCard.shared.close(why: "new_capture")
        // the second pass on this Mac (or the translation's model): asked to warm up while the user drags
        if ScreenTextRefine.mode == .local {
            if ScreenTextRefine.installed == true { ScreenTextRefine.shared.warm() } else { ScreenTextRefine.refreshInstalled { if ScreenTextRefine.installed == true { ScreenTextRefine.shared.warm() } } }
        }
        if translate { Self.warmTranslator() }
        // an Electron app's text field is only readable once its tree is asked for (as dictation's key-down does):
        // then the paste can be confirmed
        DictationField.wakeWebAccessibility(NSWorkspace.shared.frontmostApplication)
        let target = Self.target()
        let p = TextDragPicker { [weak self] r, crop in
            unregisterHotkey(.pickEsc)
            self?.drag = nil
            guard let r = r else { return }
            self?.read(r, via: via, translate: translate, target: target, still: crop)
        }
        drag = p
        registerHotkey(.pickEsc, key: kVK_Escape, mods: 0)
        p.show()
    }

    /// `region`: global top-left points. Tests call it directly (`screentext x,y,w,h [PNG]`, `screentranslate …`).
    func read(_ region: CGRect, via: String, translate: Bool = false, target: Target? = nil, still: CGImage? = nil) {
        let t0 = CACurrentMediaTime()
        // the drag's own still when it has one (what the user saw), else a capture of the region
        let take: (@escaping (CGImage?, CGFloat) -> Void) -> Void = { f in
            if let s = still { f(s, 2) } else { captureStill(rect: region, showsCursor: false, completion: f) }
        }
        take { [weak self] img, _ in
            guard let self = self else { return }
            guard let img = img else { return snapper.snapFailed(use: .text) }
            let words = Array(DictationVocabulary.shared.active().prefix(100).map(\.term))
            let shot = CACurrentMediaTime()
            DispatchQueue.global(qos: .userInitiated).async {
                let r = try? ScreenText.text(in: img, words: words)
                DispatchQueue.main.async {
                    let text = r?.text ?? ""
                    var ev: [String: Any] = ["event": "screen_text", "via": via, "chars": text.count, "lines": text.split(separator: "\n").count,
                                             "capture_ms": Int((shot - t0) * 1000), "vision_ms": r?.ms ?? 0,
                                             "ms": Int((CACurrentMediaTime() - t0) * 1000), "translate": translate,
                                             "target": target != nil]
                    if ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1" { ev["text"] = text }   // never in a real run's log
                    emit(ev)
                    guard !text.isEmpty else {
                        island.toast(Loc.t("capture.text.none", table: "Capture"), key: Self.toastKey, seconds: 3)
                        return
                    }
                    if translate { self.translate(text, image: img, target: target) } else { self.copy(text, image: img, target: target) }
                }
            }
        }
    }

    // MARK: copy

    private func copy(_ draft: String, image: CGImage, target: Target?) {
        let refine = ScreenTextRefine.shared
        let said = { (o: ScreenTextPaste.Outcome) in
            island.toast(Loc.t(ScreenTextPaste.lineKey(o, translate: false), table: "Capture"), key: Self.toastKey, icon: .check,
                         seconds: o == .unconfirmed ? 5 : 2)
        }
        // pasting: wait for a second pass that can answer at once, so the field gets the better text
        if ScreenTextRefine.quick, Self.decide(target).decision == .paste {
            var sent = false
            let send: (String) -> Void = { [weak self] t in
                guard !sent else { return }
                sent = true
                self?.deliver(t, target: target, done: said)
            }
            refine.read(image: image, draft: draft) { r in send((r?["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? draft) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { send(draft) }
            return
        }
        let changeCount = deliver(draft, target: target, done: said)
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

    /// `text` on the clipboard, and ⌘V'd into the app in front when ScreenTextPaste says so → the clipboard's
    /// changeCount. `done` (main queue) gets what became of it — for a paste once the field, read back, shows the
    /// text, or once that can't be told (DictationInsert.confirmLanding; at most 1.5 s).
    @discardableResult
    private func deliver(_ text: String, target: Target?, done: @escaping (ScreenTextPaste.Outcome) -> Void) -> Int {
        let pb = Self.pasteboard
        let (decision, role) = Self.decide(target)
        var pasted = false
        // the field as it is before the paste (dictation's way): read back after it, it says whether the text went in
        var field: DictationField?, before: (text: String, selection: NSRange)?
        if decision == .paste {
            field = DictationField.focused()
            before = field?.read()
            pasted = DictationInsert.pasteKeeping(text, on: pb)
        } else {
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
        let count = pb.changeCount
        let t0 = CACurrentMediaTime()
        let finish = { (seen: Double?) in
            let o = ScreenTextPaste.outcome(pasted: pasted, seen: seen != nil)
            var ev: [String: Any] = ["event": "screen_text_delivered", "outcome": o.rawValue, "typed": o == .pasted,
                                     "pasted": pasted, "role": role ?? NSNull(), "readable": before != nil,
                                     "chars": text.count, "confirm_ms": Int((CACurrentMediaTime() - t0) * 1000)]
            if case .copy(let why) = decision { ev["why"] = why }
            emit(ev)
            done(o)
        }
        if pasted, let f = field, let b = before {
            DictationInsert.confirmLanding(text, field: f, before: b) { finish($0) }
        } else {
            finish(nil)
        }
        return count
    }

    // MARK: translate

    /// When this run asked polish-serve to start (⌥T's key-down): the translation waits for it from then, rather than
    /// loading a second copy of the model through the CLI.
    private static var warmSpawned: CFTimeInterval?
    /// How long a translation waits for a server it started (its run file appears ~0.7 s after the spawn with a warm uv
    /// cache; the model loads after — the request's own allowance covers that).
    static let serverWait: CFTimeInterval = 4

    /// ⌥T's settings (record.screen_text.translate): its target and its cloud switch.
    static var translateConfig: ScreenTranslateConfig {
        ScreenTranslateConfig(json: (recordConfig()["screen_text"] as? [String: Any])?["translate"] as? [String: Any])
    }
    static func setTranslateConfig(_ c: ScreenTranslateConfig) {
        var o = recordConfig()["screen_text"] as? [String: Any] ?? [:]
        o["translate"] = c.json
        setRecordConfig("screen_text", o)
    }
    /// The first launch with ⌥T's own settings (2026-10-30): Auto, the cloud switch as dictation's was.
    static func migrateTranslateConfig() {
        guard (recordConfig()["screen_text"] as? [String: Any])?["translate"] == nil else { return }
        setTranslateConfig(ScreenTranslateConfig.migrated(from: Dictation.translateConfig))
        emit(["event": "screen_translate_migrated", "cloud": Dictation.translateConfig.cloud])
    }
    /// The cloud model ⌥T translates with: the one set up for cloud polish (once, for everything), when ⌥T's switch lets it.
    static var translateCloud: [String: Any]? { translateConfig.cloud ? ScreenTextRefine.cloudPayload : nil }

    static func warmTranslator() {
        guard translateCloud == nil, !WarmServer.running("polish-serve") else { return }
        if WarmSpawn.start("polish.py", ["serve", "--preload"], server: "polish-serve") != nil { warmSpawned = CACurrentMediaTime() }
    }

    private func translate(_ text: String, image: CGImage, target: Target?) {
        island.toast(Loc.t("capture.text.translating", table: "Capture"), key: Self.toastKey, seconds: 30)
        let cloud = Self.translateCloud
        // "⌥T translates into": Auto (your own language ↔ the other one, "auto:H|O"), or a language — always that
        // language: a text already in it comes back as it is (`X|keep`, 2026-10-30)
        let into = Self.translateConfig.target.request(auto: TranslateTargets.pair)
        let t0 = CACurrentMediaTime()
        // the server this press started: wait for it (from the key-down), not the CLI — the dogfood's first ⌥T after
        // every launch checked once, found nothing yet, and fell to the CLI
        let until = Self.warmSpawned.map { $0 + Self.serverWait } ?? 0
        DispatchQueue.global(qos: .userInitiated).async {
            var r: [String: Any]?
            while !WarmServer.running("polish-serve") && CACurrentMediaTime() < until { usleep(50_000) }
            if WarmServer.running("polish-serve") {
                var req: [String: Any] = ["cmd": "translate", "text": text, "target": into]
                if let c = cloud { req["cloud"] = c }
                r = WarmServer.call("polish-serve", req, timeout: 40)
            }
            if r == nil {       // no server (yet): the CLI, the key on stdin
                var o: [String: Any] = ["text": text, "target": into]
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
                let kept = out.isEmpty ? nil : DictationTranslateRoute.keptAsIs(request: into, source: text, output: out)
                var ev: [String: Any] = ["event": "screen_translate", "ok": !out.isEmpty, "ms": Int((CACurrentMediaTime() - t0) * 1000),
                                         "cloud": r?["cloud"] ?? NSNull(), "model": r?["model"] ?? NSNull(), "target": into,
                                         "already": kept?.rawValue ?? NSNull()]
                if let e = r?["cloud_error"] { ev["cloud_error"] = e }
                if ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1" { ev["text"] = out }
                emit(ev)
                guard !out.isEmpty else { return self.failed(text, image: image, target: target) }
                if let x = kept { return self.alreadyIn(x, text) }
                // the card under the island shows the whole translation, with Copy; the translation is on the
                // clipboard (and pasted by dictation's rules), and the island's one line says what became of it
                ScreenTextCard.shared.show(out)
                self.deliver(out, target: target) { o in
                    island.toast(Loc.t(ScreenTextPaste.lineKey(o, translate: true), table: "Capture"), key: Self.toastKey,
                                 icon: .check, seconds: 5)
                }
            }
        }
    }

    /// The translation failed: the text itself still helps — copied, and said so, with Try Again on the same text (a
    /// server still loading answers the next try). Never pasted: it isn't what was asked for.
    private func failed(_ text: String, image: CGImage, target: Target?) {
        deliver(text, target: nil) { _ in
            island.toast(Loc.t("capture.text.translate_failed", table: "Capture"), key: Self.toastKey, icon: .warning, seconds: 8,
                         actionTitle: Loc.t("capture.text.try_again", table: "Capture"), action: { [weak self] in
                emit(["event": "screen_translate_retry"])
                Self.warmTranslator()
                self?.translate(text, image: image, target: target)
            })
        }
    }

    /// A fixed language the text is in already: the original, copied as it is (not pasted: it isn't a translation),
    /// and the island says so — "Already in English · original copied". No card: the text is on the screen.
    private func alreadyIn(_ setting: DictationTranslateTarget, _ text: String) {
        deliver(text, target: nil) { _ in
            island.toast(Loc.t(ScreenTextPaste.lineKey(.alreadyInTarget, translate: true), table: "Capture", Dictation.languageName(setting)),
                         key: Self.toastKey, icon: .check, seconds: 5)
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
            // no still at all with Screen Recording allowed: a stale grant, said before the drag
            Snapper.checkStills(self.stills.stills.count, use: .text) { [weak self] in
                guard let self = self, !self.finished else { return }
                self.start = nil
                self.finish()
            }
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
        Loupe.draw(pointer: p.pointer, in: self, stills: p.stills, label: p.selection.map(Loupe.sizeLabel))
    }
}
