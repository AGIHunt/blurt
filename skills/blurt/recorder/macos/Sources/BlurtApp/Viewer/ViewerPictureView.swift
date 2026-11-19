// The host's screen in its window (docs/design/remote-desktop-viewer.md): decoded frames straight onto a layer, sized to the window with the
// host's shape, the host's pointer drawn here from the cursor stream, and the mouse as an absolute pointer: where the mouse is over the
// picture is where the host's pointer goes. This Mac's pointer is hidden over the picture while keys are captured.
import AppKit
import BlurtRemoteKit
import QuartzCore

final class ViewerPictureView: NSView {
    weak var controller: ViewerWindowController?
    private let video = CALayer()
    private let cursorLayer = CALayer()
    private let hint = NSTextField(labelWithString: "")
    private var hintTimer: Timer?
    /// the host's display shown, in points: the picture keeps its shape
    var source = CGSize(width: 16, height: 10) { didSet { needsLayout = true } }
    /// keys captured: the pointer is the host's
    var captured = false {
        didSet {
            window?.invalidateCursorRects(for: self)
            if !captured { cursorLayer.isHidden = true }
        }
    }
    private var tracking: NSTrackingArea?
    private var cursorSize = CGSize(width: 12, height: 18)
    private var hot = CGPoint.zero
    /// the host's word on its pointer, 0…1 of the display shown, and which of this viewer's moves it includes
    private var hostPointer: CGPoint?
    private var hostSeq: UInt32?
    /// where this Mac's mouse put it, and when
    private var ownPointer: CGPoint?
    private var ownAt = 0.0
    private static let blank = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
    /// a wheel's scroll has no end of its own: it ends after this quiet
    private var wheelEnd: Timer?
    private var scrolling = false
    private var flingSamples: [(t: Double, dx: CGFloat, dy: CGFloat)] = []
    private var lastPointerSent = 0.0
    private var pendingPointer: CGPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        video.contentsGravity = .resize
        video.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(video)
        cursorLayer.contentsGravity = .resize
        cursorLayer.isHidden = true
        cursorLayer.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "contents": NSNull()]
        cursorLayer.contents = NSCursor.arrow.image
        cursorSize = NSCursor.arrow.image.size
        hot = NSCursor.arrow.hotSpot
        layer?.addSublayer(cursorLayer)
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textColor = .white
        hint.alignment = .center
        hint.wantsLayer = true
        hint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        hint.layer?.cornerRadius = 8
        hint.isHidden = true
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            hint.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The picture's place: the host's shape, as large as the view allows, centred.
    var pictureRect: CGRect {
        let b = bounds
        guard source.width > 0, source.height > 0, b.width > 0, b.height > 0 else { return b }
        let k = min(b.width / source.width, b.height / source.height)
        let w = source.width * k, h = source.height * k
        return CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h).integral
    }

    /// The window's picture in pixels, for the host's ceiling.
    var pixels: RemotePixelSize {
        let s = window?.backingScaleFactor ?? 2
        let r = pictureRect
        return RemotePixelSize(width: Int(r.width * s) / 2 * 2, height: Int(r.height * s) / 2 * 2)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.frame = pictureRect
        CATransaction.commit()
        placeCursor()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: the picture

    func show(_ image: CVImageBuffer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.contents = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue()
        CATransaction.commit()
    }

    /// A still picture for the measured screenshots (`viewer demo`): what a frame would put there.
    func show(still: CGImage) { video.contents = still }

    func clear() { video.contents = nil }

    // MARK: the host's pointer

    func cursor(_ c: RemoteCursor) {
        hostPointer = CGPoint(x: CGFloat(c.x), y: CGFloat(c.y))
        hostSeq = c.seq
        placeCursor()
    }

    func shape(png: Data, hot h: CGPoint, size: CGSize) {
        guard let img = NSImage(data: png) else { return }
        cursorLayer.contents = img
        cursorSize = size
        hot = h
        placeCursor()
    }

    /// This Mac's own guess while the mouse moves; the host's word once it includes the last move, or once the mouse has been still a while.
    private func placeCursor() {
        let r = pictureRect
        var p = hostPointer
        if let own = ownPointer {
            let sent = controller?.link.sentSeq ?? 0
            let wait = RemoteCursor.wait(host: hostSeq, sent: sent, quiet: CACurrentMediaTime() - ownAt, rtt: controller?.link.rtt ?? 0.02, lossless: false)
            if wait > 0 || hostPointer == nil { p = own }
        }
        guard captured, let p, p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1, r.width > 0 else { cursorLayer.isHidden = true; return }
        // the host's pointer at the picture's scale
        let k = source.width > 0 ? r.width / source.width : 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isHidden = false
        cursorLayer.frame = CGRect(x: r.minX + p.x * r.width - hot.x * k, y: r.minY + p.y * r.height - hot.y * k,
                                   width: cursorSize.width * k, height: cursorSize.height * k)
        CATransaction.commit()
    }

    // MARK: the hint

    func showHint(_ text: String, seconds: Double = 3) {
        hint.stringValue = "   \(text)   "
        hint.isHidden = false
        hintTimer?.invalidate()
        hintTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.hint.isHidden = true }
    }

    // MARK: the mouse

    override func resetCursorRects() {
        if captured { addCursorRect(pictureRect, cursor: Self.blank) }
    }

    override func updateTrackingAreas() {
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
        super.updateTrackingAreas()
    }

    /// 0…1 of the display shown; nil outside the picture.
    private func place(_ e: NSEvent) -> CGPoint? {
        let p = convert(e.locationInWindow, from: nil), r = pictureRect
        guard r.width > 0, r.height > 0 else { return nil }
        let x = (p.x - r.minX) / r.width, y = (p.y - r.minY) / r.height
        guard x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func pointer(_ e: NSEvent) {
        guard captured, let c = controller, let p = place(e) else { return }
        ownPointer = p
        ownAt = CACurrentMediaTime()
        placeCursor()
        // over the relay every message counts against someone's plan: 30 a second; otherwise each move as it comes
        let now = CACurrentMediaTime()
        if c.link.overRelay, now - lastPointerSent < 1.0 / 30 {
            if pendingPointer == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
                    guard let self, let q = self.pendingPointer else { return }
                    self.pendingPointer = nil
                    self.lastPointerSent = CACurrentMediaTime()
                    c.link.pointerTo(x: Float(q.x), y: Float(q.y))
                }
            }
            pendingPointer = p
            return
        }
        lastPointerSent = now
        c.link.pointerTo(x: Float(p.x), y: Float(p.y))
    }

    override func mouseMoved(with e: NSEvent) { pointer(e) }
    override func mouseDragged(with e: NSEvent) { pointer(e) }
    override func rightMouseDragged(with e: NSEvent) { pointer(e) }
    override func otherMouseDragged(with e: NSEvent) { pointer(e) }
    override func mouseExited(with e: NSEvent) {
        ownPointer = nil
        placeCursor()
    }

    private func button(_ b: RemoteMouseButton, _ e: NSEvent, down: Bool) {
        guard let c = controller else { return }
        // a click into the picture captures again; that click is this Mac's, not the host's
        if !captured {
            if down, place(e) != nil { c.setCaptured(true) }
            return
        }
        guard place(e) != nil || !down else { return }
        pointer(e)
        c.link.send(.button(b, down: down))
    }

    override func mouseDown(with e: NSEvent) { button(.left, e, down: true) }
    override func mouseUp(with e: NSEvent) { button(.left, e, down: false) }
    override func rightMouseDown(with e: NSEvent) { button(.right, e, down: true) }
    override func rightMouseUp(with e: NSEvent) { button(.right, e, down: false) }
    override func otherMouseDown(with e: NSEvent) { button(.middle, e, down: true) }
    override func otherMouseUp(with e: NSEvent) { button(.middle, e, down: false) }

    /// Wheel and trackpad scrolling go through as scrolling. The deltas go as the fingers moved (the host applies its own direction
    /// setting, as for a phone); a trackpad's own coasting stays here and the host coasts from the speed the fingers left with. In the
    /// stream, behind the pointer's last place, so the scroll lands where the pointer is.
    override func scrollWheel(with e: NSEvent) {
        guard captured, let c = controller, place(e) != nil else { return }
        if !e.momentumPhase.isEmpty { return }
        let sign: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 12
        let dx = e.scrollingDeltaX * k * sign, dy = e.scrollingDeltaY * k * sign
        let now = CACurrentMediaTime()
        if e.phase.contains(.began) {
            flingSamples = []
            scrolling = true
            c.link.sendPointer(.scroll(dx: Float(dx), dy: Float(dy), phase: .began), inOrder: true)
            return
        }
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            scrolling = false
            c.link.sendPointer(.scroll(dx: 0, dy: 0, phase: .ended), inOrder: true)
            let recent = flingSamples.filter { now - $0.t < 0.08 }
            if let first = recent.first, recent.count > 1 {
                let span = max(0.008, now - first.t)
                let vx = recent.reduce(0) { $0 + $1.dx } / span, vy = recent.reduce(0) { $0 + $1.dy } / span
                c.link.sendPointer(.scrollFling(vx: Float(vx), vy: Float(vy)), inOrder: true)
            }
            flingSamples = []
            return
        }
        if e.phase.isEmpty {
            // a wheel: one scroll, ended after a quiet moment
            wheelEnd?.invalidate()
            wheelEnd = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                self?.scrolling = false
                c.link.sendPointer(.scroll(dx: 0, dy: 0, phase: .ended), inOrder: true)
            }
        }
        flingSamples.append((now, dx, dy))
        if flingSamples.count > 12 { flingSamples.removeFirst() }
        c.link.sendPointer(.scroll(dx: Float(dx), dy: Float(dy), phase: scrolling ? .changed : .began), inOrder: true)
        scrolling = true
    }
}
