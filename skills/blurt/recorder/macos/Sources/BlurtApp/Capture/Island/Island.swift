// The island (K7): one component at the top centre of the screen that holds the recording controls, the current
// project, voice input, the capture counts and the work in progress. It replaces the recording HUD and the perch.
//
// Geometry — on a screen with a notch (safeAreaInsets.top > 0) the island *is* the notch: pure black, flush with the
// top edge, 10 pt bottom corners, with concave shoulders into the screen edge. When there is something to show it grows
// "ears" (56 pt each side). Without a notch it is a capsule 6 pt under the menu bar (30 high, ≥ 120 wide) that hides
// when idle and appears after the pointer rests 250 ms in the top-middle 320 × 8 pt. Hovering 150 ms (or a hotkey)
// opens it: 480 wide, as tall as its content (≤ 420), 22 pt corners; it closes 400 ms after the pointer leaves.
//
// Collapsed (ears)        left                         right
//   idle                  cards waiting (n)             hatching egg + n processing, else captures to review (n)
//   recording             red dot (1 Hz breath) + time  snaps (n), else the mic level
//   voice input           live waveform                 duration
// Open: IslandContent.swift (home, recording, voice, the project drawer / switcher, one-line toasts).
//
// Motion: the shape is three springs (width, height, corner) — response 0.42 s, damping 0.78 — so it can be
// interrupted at any point; a bump (1.04 → 1, 0.25 s) when it swallows a capture; Reduce Motion = 0.2 s cross-fades.
// Window: a non-activating panel above the menu bar, on all spaces, never captured (sharingType none, and excluded
// from every recording by process), on the screen with the pointer; mouse-transparent except over the island itself.

import AppKit
import BlurtCore
import QuartzCore

final class IslandPanel: NSPanel {
    var keyable = false
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ r: NSRect, to screen: NSScreen?) -> NSRect { r }
}

final class IslandView: NSView {
    weak var island: Island?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { if island?.key(e) != true { super.keyDown(with: e) } }
    override func mouseDown(with e: NSEvent) { island?.clicked(at: convert(e.locationInWindow, from: nil)) }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { island?.dragOver(convert(s.draggingLocation, from: nil)) ?? [] }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { island?.dragOver(convert(s.draggingLocation, from: nil)) ?? [] }
    override func draggingExited(_ s: NSDraggingInfo?) { _ = island?.dragOver(nil) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        island?.drop(s.draggingPasteboard, at: convert(s.draggingLocation, from: nil)) ?? false
    }
}

final class Island: NSObject, IslandHosting {
    static let earW: CGFloat = 56
    static let openW: CGFloat = 480
    static let maxH: CGFloat = 420
    static let panelSize = CGSize(width: 640, height: 470)

    // MARK: geometry of the current screen (panel coordinates: y down from the screen's top edge)

    struct Geo {
        var notch = false
        var notchW: CGFloat = 0, notchH: CGFloat = 0
        var top: CGFloat = 0           // the island's top edge (0 with a notch, under the menu bar without)
        var row: CGFloat = 30          // height of the ears row
        var cx: CGFloat = 320          // centre x in the panel
    }

    private(set) var screen: NSScreen?
    private var geo = Geo()
    private var panel: IslandPanel?
    private var view: IslandView!
    private let shape = CAShapeLayer()
    private let ears = CALayer()
    private let left = EarSlot(), right = EarSlot()
    let content = IslandContent()
    private let contentMask = CAShapeLayer()
    private var driver: MotionDriver?

    private var w = Spring(200, response: 0.42, damping: 0.78)
    private var h = Spring(32, response: 0.42, damping: 0.78)
    private var r = Spring(10, response: 0.42, damping: 0.78)
    private var vis = Spring(0, response: 0.3, damping: 1)       // capsule screens: shown or not
    private var bumpStart: CFTimeInterval = 0

    // MARK: state

    enum Drawer: Equatable { case switcher, drop }
    private(set) var drawer: Drawer?
    private var hoverSince: CFTimeInterval?
    private var awaySince: CFTimeInterval?
    private var hotSince: CFTimeInterval?
    private var revealed = false                 // capsule screens: brought out by the hot zone
    private(set) var open = false
    private var confirmingDiscard = false
    private var dragActive = false
    private var dropped = false
    private(set) var cardCount = 0
    private var reviewCount = 0
    private var toastNow: Toast?
    private var toasts: [Toast] = []
    private var hatches: [Hatch] = []
    private var lastAgentAlert: [String: String] = [:]
    private(set) var started = false
    var watch: RecordingWatch?

    struct Toast {
        var text: String
        var actionTitle: String?
        var action: (() -> Void)?
        var art: NSView?
        var seconds: Double = 2.4
        var since: CFTimeInterval = 0
    }

    final class Hatch {
        let session: URL
        var captures: [Int]
        var job: String?
        let since = CACurrentMediaTime()
        var ended: (at: CFTimeInterval, ok: Bool, items: Int)?
        init(session: URL, captures: [Int]) { self.session = session; self.captures = captures }
    }

    var isRecording: Bool { rec.map { !$0.stopping } ?? false }
    var rec: Recorder? { (NSApp.delegate as? App)?.rec }

    /// The island as it is drawn now, in screen coordinates.
    var frameOnScreen: NSRect {
        guard let p = panel else {
            let s = NSScreen.main?.frame ?? .zero
            return NSRect(x: s.midX - 100, y: s.maxY - 32, width: 200, height: 32)
        }
        return NSRect(x: p.frame.minX + geo.cx - w.value / 2, y: p.frame.maxY - geo.top - h.value, width: w.value, height: h.value)
    }

    /// The cards should hang: the island is open or being hovered, or a drag is on.
    var wantsCards: Bool { open || hoverSince != nil || dragActive || drawer != nil }

    // MARK: setup

    func start() {
        guard !started else { return }
        started = true
        ensurePanel(on: screenWithPointer())
        JobStore.shared.start()
        JobStore.shared.onChange = { [weak self] changed in self?.jobsChanged(changed) }
        ProjectStore.shared.onChange = { [weak self] in self?.refresh() }
        refreshReviewCount()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refreshReviewCount() }
        refresh()
    }

    var screenUnderPointer: NSScreen { screenWithPointer() }
    func moveTo(_ s: NSScreen) { if s != screen { ensurePanel(on: s) } }
    func clearToast() { toastNow = nil }

    private func screenWithPointer() -> NSScreen {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func ensurePanel(on s: NSScreen) {
        var g = Geo()
        let menuH = max(s.frame.maxY - s.visibleFrame.maxY, 24)
        if #available(macOS 12.0, *), s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            g.notch = true
            g.notchW = s.frame.width - l.width - r.width
            g.notchH = s.safeAreaInsets.top
            g.top = 0
            g.row = g.notchH
            g.cx = Island.panelSize.width / 2 + ((l.maxX + r.minX) / 2 - s.frame.midX)
        } else {
            g.top = min(menuH, 40) + 6
            g.row = 30
            g.cx = Island.panelSize.width / 2
        }
        let f = NSRect(x: s.frame.midX - Island.panelSize.width / 2, y: s.frame.maxY - Island.panelSize.height,
                       width: Island.panelSize.width, height: Island.panelSize.height)
        if panel == nil {
            let p = IslandPanel(contentRect: f, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.acceptsMouseMovedEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.sharingType = chromeSharing
            p.setAccessibilityTitle(Loc.t("capture.island.ax", table: "Capture"))
            let v = IslandView(frame: NSRect(origin: .zero, size: f.size))
            v.island = self
            v.wantsLayer = true
            v.registerForDraggedTypes([capturePasteboardType])
            p.contentView = v
            view = v
            panel = p
            build()
            let d = MotionDriver(view: v)
            d.tick = { [weak self] dt in self?.frame(dt) ?? false }
            d.idle = { [weak self] in self?.poll(CACurrentMediaTime()) }
            d.idleRate = 1.0 / 15
            driver = d
        }
        let moved = screen != s
        screen = s
        geo = g
        panel?.setFrame(f, display: false)
        view.frame = NSRect(origin: .zero, size: f.size)
        if moved {
            let t = target()
            w.value = t.w; h.value = t.h; r.value = t.r
            w.snap(); h.snap(); r.snap()
        }
        panel?.orderFrontRegardless()
        wake()
    }

    private func build() {
        guard let root = view.layer else { return }
        shape.fillColor = NSColor.black.cgColor
        shape.shadowColor = NSColor.black.cgColor
        shape.shadowOpacity = 0
        shape.shadowRadius = 18
        shape.shadowOffset = CGSize(width: 0, height: 8)
        root.addSublayer(shape)
        ears.addSublayer(left.layer)
        ears.addSublayer(right.layer)
        root.addSublayer(ears)
        content.island = self
        content.wantsLayer = true
        content.layer?.mask = contentMask
        content.alphaValue = 0
        view.addSubview(content)
    }

    func orderFront() { panel?.orderFrontRegardless() }

    // MARK: what the island should look like now

    private var earsWanted: (left: Bool, right: Bool) {
        if isRecording || VoiceInput.shared.active { return (true, true) }
        return (cardCount > 0, !hatches.isEmpty || reviewCount > 0 || agentAlert != nil)
    }

    /// The shape's target: (width, height, corner radius).
    private func target() -> (w: CGFloat, h: CGFloat, r: CGFloat) {
        let e = earsWanted
        let anyEar = e.left || e.right
        if open || drawer != nil {
            let hh = min(Island.maxH, geo.row + content.fittingHeight)
            return (content.preferredWidth, hh, 22)
        }
        if let t = toastNow {
            _ = t
            let tw = min(Island.openW, max(geo.notch ? geo.notchW + 2 * Island.earW : 260, content.toastWidth))
            return (tw, geo.row + 46, 20)
        }
        if geo.notch {
            return (geo.notchW + (anyEar ? 2 * Island.earW : 0), geo.notchH, 10)
        }
        let cw = max(120, (e.left ? left.width + 24 : 0) + (e.right ? right.width + 24 : 0) + (anyEar ? 8 : 0))
        return (anyEar || revealed ? max(cw, revealed && !anyEar ? 150 : 0) : 120, 30, 15)
    }

    private var capsuleVisible: Bool {
        geo.notch || open || drawer != nil || toastNow != nil || revealed || earsWanted.left || earsWanted.right
    }

    func refresh() {
        updateEars()
        content.rebuild()
        wake()
    }

    func wake() { driver?.wake() }

    // MARK: animation

    private func frame(_ dt: CGFloat) -> Bool {
        let now = CACurrentMediaTime()
        poll(now)
        tickToasts(now)
        let t = target()
        w.target = t.w; h.target = t.h; r.target = t.r
        vis.target = capsuleVisible ? 1 : 0
        let reduce = reduceMotion
        if reduce {
            w.snap(); h.snap(); r.snap()
            vis.value += (vis.target - vis.value) * min(1, dt / 0.2 * 1.2)
        } else {
            _ = w.step(dt); _ = h.step(dt); _ = r.step(dt); _ = vis.step(dt)
        }
        let bt = now - bumpStart
        let bump: CGFloat = reduce || bt > 0.25 ? 1 : 1 + 0.04 * (1 - Ease.outCubic(CGFloat(bt / 0.25)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = CGRect(x: geo.cx - w.value / 2, y: geo.top, width: w.value, height: max(1, h.value))
        shape.path = Island.path(rect, radius: r.value, shoulders: geo.notch)
        shape.opacity = Float(max(0, min(1, vis.value)))
        let lifted = h.value > geo.row + 8
        shape.shadowOpacity = lifted ? Float(min(0.35, (h.value - geo.row) / 120)) : 0
        if bump != 1 {
            let c = CGPoint(x: geo.cx, y: geo.top + h.value / 2)
            var tr = CATransform3DMakeTranslation(c.x, c.y, 0)
            tr = CATransform3DScale(tr, bump, bump, 1)
            tr = CATransform3DTranslate(tr, -c.x, -c.y, 0)
            shape.transform = tr
            ears.transform = tr
        } else {
            shape.transform = CATransform3DIdentity
            ears.transform = CATransform3DIdentity
        }
        layoutEars(rect, now: now)
        ears.opacity = shape.opacity
        // the open content: pinned to the top of the shape, revealed as it grows, clipped to it
        let cw = content.preferredWidth
        content.frame = NSRect(x: geo.cx - cw / 2, y: geo.top + geo.row, width: cw, height: max(0, Island.maxH))
        let grown = (h.value - geo.row) / max(1, content.fittingHeight)
        let showing = open || drawer != nil || toastNow != nil
        content.alphaValue = showing ? max(0, min(1, (grown - 0.55) / 0.35)) * CGFloat(shape.opacity) : 0
        let local = CGRect(x: rect.minX - content.frame.minX, y: rect.minY - content.frame.minY, width: rect.width, height: rect.height)
        contentMask.path = Island.path(local, radius: r.value, shoulders: false)
        CATransaction.commit()
        content.tick(now)
        claws.islandMoved()
        let moving = !w.resting || !h.resting || !r.resting || abs(vis.value - vis.target) > 0.01 || bt < 0.3
        return moving || left.animating || right.animating || toastNow != nil || isRecording || VoiceInput.shared.active
    }

    /// The island's outline: flush top (with small concave shoulders on a notch screen), rounded bottom corners;
    /// a capsule / rounded rect without a notch.
    static func path(_ r: CGRect, radius: CGFloat, shoulders: Bool) -> CGPath {
        let p = CGMutablePath()
        let rad = min(radius, r.height / 2, r.width / 2)
        guard shoulders else {
            p.addRoundedRect(in: r, cornerWidth: rad, cornerHeight: rad)
            return p
        }
        let s: CGFloat = min(6, r.height / 3)
        p.move(to: CGPoint(x: r.minX - s, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + s), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - rad))
        p.addQuadCurve(to: CGPoint(x: r.minX + rad, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - rad, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - rad), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + s))
        p.addQuadCurve(to: CGPoint(x: r.maxX + s, y: r.minY), control: CGPoint(x: r.maxX, y: r.minY))
        p.closeSubpath()
        return p
    }

    // MARK: ears

    private var agentAlert: Job? {
        JobStore.shared.active.first { $0.type == .agent && $0.agent?.status == .waitingInput }
    }

    func updateEars() {
        let e = earsWanted
        if let rec = rec, rec.sessionStart.isValid {
            left.set(.recording(paused: rec.isPaused, time: Island.clock(rec.elapsed())))
            let n = rec.snaps?.count ?? 0
            right.set(n > 0 ? .count(symbol: "camera.fill", n: n, tint: nil) : .level(rec.isPaused ? 0 : rec.micLevel))
        } else if VoiceInput.shared.active {
            left.set(.wave(VoiceInput.shared.levels))
            right.set(.text(Island.clock(VoiceInput.shared.elapsed), mono: true))
        } else {
            left.set(e.left ? .count(symbol: "rectangle.stack.fill", n: cardCount, tint: nil) : .none)
            let processing = hatches.filter { $0.ended == nil }.reduce(0) { $0 + max(1, $1.captures.count) }
            if let h = hatches.first(where: { $0.ended != nil }), let end = h.ended {
                right.set(.cracking(since: end.at, ok: end.ok, n: end.items))
            } else if processing > 0 {
                right.set(.egg(n: processing))
            } else if agentAlert != nil {
                right.set(.alert)
            } else if reviewCount > 0 {
                right.set(.count(symbol: "tray.full.fill", n: reviewCount, tint: nil))
            } else {
                right.set(.none)
            }
        }
    }

    private func layoutEars(_ rect: CGRect, now: CFTimeInterval) {
        let y = geo.top + geo.row / 2
        if geo.notch {
            left.place(center: CGPoint(x: geo.cx - geo.notchW / 2 - Island.earW / 2 + 2, y: y), now: now)
            right.place(center: CGPoint(x: geo.cx + geo.notchW / 2 + Island.earW / 2 - 2, y: y), now: now)
        } else {
            left.place(leading: CGPoint(x: rect.minX + 14, y: y), now: now)
            right.place(trailing: CGPoint(x: rect.maxX - 14, y: y), now: now)
        }
        let e = earsWanted
        // ears only show while the shape is wide enough to hold them
        let roomy = geo.notch ? w.value > geo.notchW + Island.earW : w.value > 110
        left.layer.opacity = e.left && roomy ? 1 : 0
        right.layer.opacity = e.right && roomy ? 1 : 0
    }

    static func clock(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: pointer

    private func islandRect(margin: CGFloat) -> CGRect {
        CGRect(x: geo.cx - w.value / 2, y: geo.top, width: w.value, height: h.value).insetBy(dx: -margin, dy: -margin)
    }

    private func poll(_ now: CFTimeInterval) {
        guard let p = panel else { return }
        let m = NSEvent.mouseLocation
        let busyElsewhere = (NSApp.delegate as? App)?.picker != nil
        // follow the pointer to another screen while nothing is showing
        if !open && drawer == nil && toastNow == nil && !isRecording && !VoiceInput.shared.active, !dragActive,
           let s = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }), s != screen {
            ensurePanel(on: s)
            return
        }
        let local = NSPoint(x: m.x - p.frame.minX, y: p.frame.maxY - m.y)
        let inside = islandRect(margin: geo.notch && !open ? 4 : 2).contains(local) && vis.value > 0.5
        // capsule screens: the hot zone brings the capsule out
        if !geo.notch, !capsuleVisible || (revealed && !inside && !open) {
            let hot = abs(local.x - geo.cx) < 160 && m.y >= (screen?.frame.maxY ?? 0) - 8
            if hot && !busyElsewhere { hotSince = hotSince ?? now } else { hotSince = nil }
            if let h = hotSince, now - h >= 0.25, !revealed { revealed = true; hotSince = nil; refresh() }
        }
        if inside && !busyElsewhere {
            awaySince = nil
            hoverSince = hoverSince ?? now
            if !open, drawer == nil, now - hoverSince! >= 0.15 { setOpen(true) }
        } else {
            hoverSince = nil
            let pinned = drawer == .switcher || confirmingDiscard || dragActive || NoteBubble.shared.isOpen && isRecording
            if (open || revealed) && !pinned {
                awaySince = awaySince ?? now
                if now - awaySince! >= 0.4 {
                    awaySince = nil
                    if drawer == .drop { drawer = nil }
                    setOpen(false)
                    if revealed { revealed = false; refresh() }
                }
            }
        }
        let interactive = inside || drawer != nil || confirmingDiscard
        if p.ignoresMouseEvents == interactive { p.ignoresMouseEvents = !interactive }
    }

    func setOpen(_ on: Bool) {
        guard on != open else { return }
        open = on
        if !on {
            confirmingDiscard = false
            if drawer == .switcher { closeSwitcher() }
        }
        content.rebuild()
        claws.islandMoved()
        wake()
    }

    func clicked(at p: NSPoint) {
        // a click on the collapsed island opens it right away
        if !open && drawer == nil { setOpen(true) }
        if let t = toastNow, let a = t.action { toastNow = nil; a(); refresh() }
    }

    // MARK: drawer: switcher (⌥⇧O) and drop targets (a card dragged in)

    func showSwitcher() {
        ensurePanel(on: screenWithPointer())
        drawer = .switcher
        content.query = ""
        content.rebuild()
        panel?.keyable = true
        panel?.makeKey()
        panel?.makeFirstResponder(view)
        panel?.ignoresMouseEvents = false
        wake()
    }

    func closeSwitcher() {
        guard drawer == .switcher else { return }
        drawer = nil
        panel?.keyable = false
        panel?.resignKey()
        content.rebuild()
        wake()
    }

    func toggleSwitcher() { drawer == .switcher ? closeSwitcher() : showSwitcher() }

    func key(_ e: NSEvent) -> Bool {
        if drawer == .switcher { return content.key(e) }
        if e.keyCode == 53 { setOpen(false); return true }
        return false
    }

    func dragBegan() { dragActive = true; dropped = false; wake() }

    /// The pointer of a card drag (screen coordinates): near the island, the drawer opens and takes the drop.
    func dragMoved(to s: NSPoint) {
        guard let p = panel else { return }
        let local = NSPoint(x: s.x - p.frame.minX, y: p.frame.maxY - s.y)
        let zone = drawer == .drop ? islandRect(margin: 24) : islandRect(margin: 70)
        if zone.contains(local) {
            if drawer != .drop { drawer = .drop; content.rebuild(); wake() }
            if p.ignoresMouseEvents { p.ignoresMouseEvents = false }
            content.highlight(at: view.convert(local, to: content))
        } else if drawer == .drop {
            drawer = nil
            content.rebuild()
            wake()
        }
    }

    func dragOver(_ p: NSPoint?) -> NSDragOperation {
        guard let p = p, drawer == .drop else { content.highlight(at: nil); return [] }
        return content.highlight(at: view.convert(p, to: content)) != nil ? .move : []
    }

    func drop(_ pb: NSPasteboard, at p: NSPoint) -> Bool {
        guard let target = content.highlight(at: view.convert(p, to: content)),
              let raw = pb.string(forType: capturePasteboardType), let s = Island.shot(fromPasteboard: raw) else { return false }
        dropped = true
        content.perform(target, shot: s)
        return true
    }

    /// The drag is over: true when the island took the card.
    func dragEnded(at s: NSPoint) -> Bool {
        dragActive = false
        if !dropped, drawer == .drop, let p = panel, let card = claws.dragging?.shot {
            // the drop landed on us without a destination callback (rare): resolve it here
            let local = NSPoint(x: s.x - p.frame.minX, y: p.frame.maxY - s.y)
            if let t = content.highlight(at: view.convert(local, to: content)) { content.perform(t, shot: card); dropped = true }
        }
        if drawer == .drop { drawer = nil }
        content.highlight(at: nil)
        content.rebuild()
        wake()
        return dropped
    }

    static func shot(fromPasteboard raw: String) -> Shot? {
        let parts = raw.split(separator: "\n").map(String.init)
        guard parts.count == 2, let n = Int(parts[1]) else { return nil }
        return snapper.cards.first { $0.n == n && $0.batch?.dir.path == parts[0] }
    }

    // MARK: inputs from the rest of the app

    func cardsChanged(_ n: Int) {
        guard n != cardCount else { return }
        cardCount = n
        refresh()
    }

    /// The island swallows something (a capture pulled in, a dropped card).
    func bump() {
        bumpStart = CACurrentMediaTime()
        wake()
    }

    func recordingChanged() {
        if !isRecording { confirmingDiscard = false }
        refresh()
    }

    func confirmDiscard(_ on: Bool) {
        confirmingDiscard = on
        content.rebuild()
        wake()
    }
    var isConfirmingDiscard: Bool { confirmingDiscard }

    // MARK: toasts (K4: one quiet line, 2.4 s, never takes focus; the same text within 10 s merges)

    func toast(_ text: String, actionTitle: String?, action: (() -> Void)?) {
        toast(Toast(text: text, actionTitle: actionTitle, action: action))
    }

    func toast(_ t: Toast) {
        emit(["event": "island_toast", "text": t.text])
        if toastNow?.text == t.text { toastNow?.since = CACurrentMediaTime(); return }
        if toasts.contains(where: { $0.text == t.text }) { return }
        toasts.append(t)
        wake()
    }

    private func tickToasts(_ now: CFTimeInterval) {
        let minSecs = Double(ProcessInfo.processInfo.environment["BLURT_TOAST_MIN_SECONDS"] ?? "") ?? 0
        if let t = toastNow, now - t.since > max(t.seconds, minSecs), !(open && hoverSince != nil) {
            toastNow = nil
            content.rebuild()
        }
        if toastNow == nil, !open, drawer == nil, !toasts.isEmpty {
            var t = toasts.removeFirst()
            t.since = now
            toastNow = t
            content.rebuild()
        }
    }
    var currentToast: Toast? { toastNow }

    // MARK: hatching (only for captures being processed — K7)

    /// Captures were handed to processing: show the egg now; the process job that picks them up takes it over.
    func expectProcess(session: URL, captures: [Int]) {
        if let h = hatches.first(where: { $0.session == session && $0.job == nil && $0.ended == nil }) {
            h.captures = Array(Set(h.captures + captures)).sorted()
        } else {
            hatches.append(Hatch(session: session, captures: captures))
        }
        refresh()
        // nothing picked it up: let it go quietly
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self = self else { return }
            self.hatches.removeAll { $0.job == nil && $0.ended == nil && CACurrentMediaTime() - $0.since > 110 }
            self.refresh()
        }
    }

    private func jobsChanged(_ changed: [Job]) {
        for j in changed where j.type == .process {
            guard let s = j.session else { continue }
            let h = hatches.first { $0.job == j.id }
                ?? hatches.first { $0.job == nil && $0.session.standardizedFileURL == s.standardizedFileURL
                    && (j.captures.isEmpty || !Set(j.captures).isDisjoint(with: $0.captures)) }
            guard let hatch = h else { continue }
            hatch.job = j.id
            if !j.isActive, hatch.ended == nil {
                hatch.ended = (CACurrentMediaTime(), j.state == .done, j.items.count)
                DispatchQueue.main.asyncAfter(deadline: .now() + (j.state == .done ? 1.6 : 5)) { [weak self] in
                    self?.hatches.removeAll { $0 === hatch }
                    self?.refreshReviewCount()
                    self?.refresh()
                }
            }
        }
        // a session that started waiting on you: its marker pulses once
        for j in changed where j.type == .agent {
            let st = j.agent?.status.rawValue ?? ""
            if lastAgentAlert[j.id] != st { lastAgentAlert[j.id] = st; if j.agent?.status == .waitingInput { right.pulse() } }
        }
        refresh()
    }

    var activeJobs: [Job] { Array(JobStore.shared.active.filter { $0.type != .agent }.prefix(3)) }
    var sessionsNeedingYou: [Job] {
        JobStore.shared.active.filter { $0.type == .agent && [.waitingInput, .turnDone, .error].contains($0.agent?.status ?? .running) }
    }
    var toReview: Int { reviewCount }

    private func refreshReviewCount() {
        DispatchQueue.global(qos: .utility).async {
            let n = (try? IndexReader().count(ItemQuery(statuses: ["draft"], limit: 0))) ?? 0
            DispatchQueue.main.async { [weak self] in
                guard let self = self, n != self.reviewCount else { return }
                self.reviewCount = n
                self.refresh()
            }
        }
    }
}

let island = Island()
extension Island { static var shared: Island { island } }
