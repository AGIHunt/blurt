// What the recording HUD shows besides time / level / pause / pen / finish:
//  • 📸 — snaps taken during this take (count badge; thumbnails fly in). Click: no shots yet → take one; else the
//    note popover for the shots (the recording pauses while it is open, resumes when it closes).
//  • a little nest — one egg per live draft from <session>/live/drafts.jsonl (≈1 s polls; a missing file is fine);
//    "drop" ops take an egg out. Silent: the mic is recording.
//  • a one-line live caption under the HUD from live/transcript.jsonl (latest line, fades; menu toggle, default on).

import AppKit
import QuartzCore

final class SnapButton: NSButton {
    var count = 0 { didSet { needsDisplay = true } }
    var hovering = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    convenience init(_ click: @escaping () -> Void) {
        self.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        isBordered = false
        title = ""
        onClick = click
        target = self
        action = #selector(fire)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        wantsLayer = true
        layer?.masksToBounds = false
    }
    @objc func fire() { onClick?() }
    override var allowsVibrancy: Bool { false }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirty: NSRect) {
        let bg = NSColor(white: 1, alpha: 0.1)
        (hovering ? bg.blended(withFraction: 0.25, of: .white) ?? bg : bg).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        if let img = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: "snap")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .bold).applying(.init(paletteColors: [.white]))) {
            let s = img.size
            img.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
        }
        guard count > 0 else { return }
        let t = NSAttributedString(string: "\(count)", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold),
                                                                     .foregroundColor: NSColor.white])
        let w = max(15, t.size().width + 7)
        let r = NSRect(x: bounds.maxX - w + 3, y: bounds.maxY - 15 + 2, width: w, height: 15)
        accent.setFill()
        NSBezierPath(roundedRect: r, xRadius: 7.5, yRadius: 7.5).fill()
        t.draw(at: NSPoint(x: r.midX - t.size().width / 2, y: r.midY - t.size().height / 2))
    }

    func pulse() {
        guard let l = layer, !reduceMotion else { return }
        l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        l.position = CGPoint(x: frame.midX, y: frame.midY)
        let a = CASpringAnimation(keyPath: "transform.scale")
        a.fromValue = 1.3; a.toValue = 1
        a.mass = 0.5; a.stiffness = 320; a.damping = 9
        a.duration = a.settlingDuration
        l.add(a, forKey: "pulse")
    }
}

/// One line of what was just said, under the HUD. Never captured.
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
        fx.layer?.cornerRadius = 14
        fx.layer?.masksToBounds = true
        fx.maskImage = roundedMask(14)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = NSColor(white: 1, alpha: 0.92)
        label.lineBreakMode = .byTruncatingHead      // the newest words matter most
        label.maximumNumberOfLines = 1
        fx.addSubview(label)
        win.alphaValue = 0
    }

    func show(_ text: String, near hud: NSRect, region: NSRect) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        label.stringValue = t
        let tw = ceil((t as NSString).size(withAttributes: [.font: label.font!]).width)
        let w = min(max(160, tw + 36), 520)
        let below = hud.midY <= region.midY        // HUD under the area (or in its lower half): caption further down
        var f = NSRect(x: hud.midX - w / 2, y: below ? hud.minY - 6 - 28 : hud.maxY + 6, width: w, height: 28)
        if let s = NSScreen.screens.first(where: { $0.frame.intersects(hud) })?.visibleFrame {
            f.origin.x = max(s.minX + 8, min(f.minX, s.maxX - w - 8))
            if f.minY < s.minY + 4 { f.origin.y = hud.maxY + 6 }
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

final class HUDLive {
    weak var hud: HUD?
    weak var rec: Recorder?
    let snapBtn: SnapButton
    let nest = NestView(frame: .zero)
    let caption = CaptionPanel()
    private weak var pen: NSView?
    private weak var redo: NSView?
    private weak var done: NSView?
    private var drafts: DraftsWatcher?
    private var transcript: JSONLTail?
    private var lastCaption = ""
    private var pendingCaption: String?
    private var timer: Timer?
    private var nestShown = false

    init(hud: HUD, rec: Recorder, fx: NSView, pen: NSView, redo: NSView, done: NSView) {
        self.hud = hud
        self.rec = rec
        self.pen = pen
        self.redo = redo
        self.done = done
        snapBtn = SnapButton {}
        snapBtn.onClick = { [weak self] in self?.snapClicked() }
        snapBtn.toolTip = L("截图\(hkTip(.snap))：这一刻、这个画面，全分辨率。截过之后点这里给截图补一句（会自动暂停）",
                            "Snap\(hkTip(.snap)): this exact moment, full resolution. After a snap, click to add a note (pauses meanwhile)")
        (fx as? NSVisualEffectView)?.maskImage = roundedMask(24)
        hud.hasShadow = true
        fx.addSubview(snapBtn)
        nest.isHidden = true
        fx.addSubview(nest)
        relayout()
        let session = URL(fileURLWithPath: opts.out).deletingLastPathComponent()
        let d = DraftsWatcher(session: session)
        d.onAdd = { [weak self] id, kind in self?.eggAdded(id, kind) }
        d.onDrop = { [weak self] id in self?.nest.remove(id: id) }
        drafts = d
        transcript = JSONLTail(session.appendingPathComponent("live/transcript.jsonl"))
        rec.snaps?.onLanded = { [weak self] s in self?.shotLanded(s) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak hud] in hud?.invalidateShadow() }  // after the rounded mask is drawn
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// pen · 📸 · ↺ · [nest] · Finish — the HUD grows (centred where it was) when the nest appears.
    func relayout() {
        guard let hud = hud, let pen = pen, let redo = redo, let done = done else { return }
        var x = pen.frame.maxX + 4
        snapBtn.frame.origin = NSPoint(x: x, y: 8)
        x += 36
        redo.frame.origin = NSPoint(x: x, y: 8)
        x += 38
        if nestShown {
            nest.frame.origin = NSPoint(x: x - 2, y: 8)
            x += NestView.size.width + 2
        }
        done.frame.origin = NSPoint(x: x, y: 8)
        let w = done.frame.maxX + 8
        guard abs(hud.frame.width - w) > 0.5 else { return }
        var f = hud.frame
        let mid = f.midX
        f.size.width = w
        f.origin.x = mid - w / 2
        hud.contentView?.frame.size.width = w
        hud.setFrame(f, display: true, animate: hud.isVisible && !reduceMotion)
        hud.invalidateShadow()
    }

    private func eggAdded(_ id: String, _ kind: String?) {
        if !nestShown {
            nestShown = true
            nest.isHidden = false
            relayout()
        }
        nest.add(id: id, kindName: kind)
    }

    private func poll() {
        drafts?.poll()
        if let last = transcript?.poll().last, let text = last["text"] as? String { pendingCaption = text }
        // a sentence that closes while paused is shown on resume rather than dropped
        guard liveCaptionOn, let text = pendingCaption, let hud = hud, let rec = rec, !rec.isPaused else { return }
        pendingCaption = nil
        guard text != lastCaption else { return }
        lastCaption = text
        caption.show(text, near: hud.frame, region: toNS(rec.region))
    }

    private func snapClicked() {
        guard let rec = rec else { return }
        if (rec.snaps?.count ?? 0) == 0 { rec.snap(via: "hud"); return }
        openNotes()
    }

    func openNotes() {
        guard let rec = rec, let snaps = rec.snaps, let last = snaps.batch.live.last else { return }
        let wasPaused = rec.isPaused
        if !wasPaused { rec.togglePause() }
        let nb = NoteBubble.shared
        nb.recordingShots = snaps.batch.live
        nb.begin(last, mode: .recording, anchor: { [weak self] in self?.hud?.frame })
        nb.onClose = { [weak rec] in
            guard let rec = rec, !rec.stopping else { return }
            if !wasPaused && rec.isPaused { rec.togglePause() }
        }
    }

    private func shotLanded(_ s: Shot) {
        guard let hud = hud, let rec = rec, let thumb = s.thumb else { return }
        let to = snapBtn.convert(snapBtn.bounds, to: nil)
        let target = hud.convertToScreen(to).insetBy(dx: 4, dy: 6)
        let count = rec.snaps?.count ?? 0
        flyImage(thumb, from: toNS(rec.region), to: target, duration: 0.5, polaroid: false, shrinkAway: true) { [weak self] in
            self?.snapBtn.count = count
            self?.snapBtn.pulse()
        }
    }

    func stop() {
        timer?.invalidate()
        caption.close()
        if NoteBubble.shared.isOpen, NoteBubble.shared.mode == .recording { NoteBubble.shared.commit() }
    }
}
