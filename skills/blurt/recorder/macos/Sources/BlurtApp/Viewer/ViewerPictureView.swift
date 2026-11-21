// The host's screen in its window (docs/design/remote-desktop-viewer.md): decoded frames straight onto a layer, sized to the window with the
// host's shape, the host's pointer drawn here from the cursor stream, and the mouse as an absolute pointer: where the mouse is over the
// picture is where the host's pointer goes. This Mac's pointer is hidden over the picture while keys are captured.
import AppKit
import BlurtRemoteKit
import CoreImage
import IOSurface
import QuartzCore

final class ViewerPictureView: NSView {
    typealias Hint = ViewerHintPill.Hint
    weak var controller: ViewerWindowController?
    private let video = CALayer()
    /// a picture that stopped (the link dropped, the host locked): the last frame, blurred and greyed once, so it reads as stopped and
    /// none of its text competes with the cover's words; `dim` darkens it under the cover
    private let frozen = CALayer()
    private let dim = CALayer()
    private let cursorLayer = CALayer()
    /// the hint at the top of the picture (how to give the keys back, a file sent, no control there): the capture chrome's hint pill, under
    /// the toolbar where a remote desktop has its title bars, never over its taskbar or Dock; wrapped inside the window at any width
    private let hint = ViewerHintPill()
    private var hintTimer: Timer?
    /// the short hint's time, while one is up (nil: none, or only the lasting one)
    private var hintSeconds: Double?
    private var hintHovered = false
    /// a fade's turn: a later show or hide wins over an earlier fade still running
    private var hintTurn = 0
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
        // under the picture: #1E1E1E, a dark window's ground, never pure black (full screen on a screen of another shape, before the window
        // takes the host's shape, no picture yet)
        layer?.backgroundColor = NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 30 / 255, alpha: 1).cgColor
        video.contentsGravity = .resize
        video.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(video)
        frozen.contentsGravity = .resize
        frozen.isHidden = true
        frozen.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(frozen)
        dim.backgroundColor = NSColor.black.withAlphaComponent(Self.dimAlpha).cgColor
        dim.isHidden = true
        dim.actions = ["bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(dim)
        cursorLayer.contentsGravity = .resize
        cursorLayer.isHidden = true
        cursorLayer.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "contents": NSNull()]
        cursorLayer.contents = NSCursor.arrow.image
        cursorSize = NSCursor.arrow.image.size
        hot = NSCursor.arrow.hotSpot
        layer?.addSublayer(cursorLayer)
        hint.isHidden = true
        addSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: files dropped on the picture go to the host's Downloads (ViewerFileSender)

    func acceptFiles() { registerForDraggedTypes([.fileURL]) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let files = urls.filter { !$0.hasDirectoryPath }
        guard !files.isEmpty else { return false }
        controller?.sendFiles(files)
        return true
    }

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

    private static let hintMargin: CGFloat = 16
    /// under the toolbar: 12 pt into the picture, where macOS's own full-screen banner and the VM apps' release hint sit
    private static let hintTop: CGFloat = 12
    /// a line no longer than this reads in one glance; longer ones wrap
    private static let hintMaxText: CGFloat = 640

    override func layout() {
        super.layout()
        placeHint()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.frame = pictureRect
        frozen.frame = pictureRect
        dim.frame = bounds
        CATransaction.commit()
        placeCursor()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: the picture

    /// A frame is up. Until then the shape is only a placeholder (16 × 10): no host pointer is drawn at its scale, and this Mac's own
    /// pointer stays visible over a picture that isn't there (a screen that failed, one still on its way).
    var hasPicture: Bool { video.contents != nil }

    func show(_ image: CVImageBuffer) {
        let first = !hasPicture
        defer {
            if first { window?.invalidateCursorRects(for: self); placeCursor() }
            if stale { stale = false }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.contents = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue()
        CATransaction.commit()
    }

    /// A still picture for the measured screenshots (`viewer demo`): what a frame would put there.
    func show(still: CGImage) { video.contents = still }

    func clear() {
        video.contents = nil
        frozen.contents = nil
        frozen.isHidden = true
        dim.isHidden = true
        cursorLayer.isHidden = true
        window?.invalidateCursorRects(for: self)
    }

    /// The picture stopped but stays, frozen: the last thing seen of the host while it can't show more, blurred, greyed and darker, so
    /// it reads as a picture that stopped and not as live content under a card. A new frame lifts it.
    var stale = false {
        didSet {
            guard stale != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            frozen.contents = stale && hasPicture ? Self.freeze(video.contents, scale: frozenScale) : nil
            frozen.isHidden = frozen.contents == nil
            dim.isHidden = !stale || !hasPicture
            CATransaction.commit()
            if stale { cursorLayer.isHidden = true }
        }
    }

    /// the frozen picture's dim: enough that the cover is the one thing read, not so much that the picture is gone (§3.1 "Frozen snap": 42 %)
    static let dimAlpha: CGFloat = 0.45
    /// the blur, in the picture's points on screen (pixels of the frame scaled by how large it's shown)
    private static let blurPoints: CGFloat = 14
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// frame pixels per point shown: the blur is said in points, so it looks the same at any window size
    private var frozenScale: CGFloat {
        let r = pictureRect
        guard r.width > 0 else { return 1 }
        if let c = video.contents, CFGetTypeID(c as CFTypeRef) == CGImage.typeID { return CGFloat((c as! CGImage).width) / r.width }
        if let c = video.contents, CFGetTypeID(c as CFTypeRef) == IOSurfaceGetTypeID() { return CGFloat(IOSurfaceGetWidth(c as! IOSurfaceRef)) / r.width }
        return 1
    }

    /// The last frame, blurred and mostly grey: made once when the picture stops (a frame from the decoder is an IOSurface; a still, a CGImage).
    private static func freeze(_ contents: Any?, scale: CGFloat) -> CGImage? {
        guard let contents else { return nil }
        let image: CIImage
        if CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
            image = CIImage(cgImage: contents as! CGImage)
        } else if CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
            image = CIImage(ioSurface: contents as! IOSurfaceRef)
        } else { return nil }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let out = image.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(blurPoints * max(1, scale)) / 2)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.35, kCIInputBrightnessKey: 0, kCIInputContrastKey: 0.92])
            .cropped(to: extent)
        return context.createCGImage(out, from: extent)
    }

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
        guard captured, hasPicture, let p, p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1, r.width > 0 else { cursorLayer.isHidden = true; return }
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

    /// The hint that lasts (no control over the other computer): a short one shows over it, then it's back.
    private var lasting: ViewerHintPill.Hint?

    /// The pill's place: centred, 12 pt under the picture's top edge (the toolbar's, unless full screen leaves bars above the picture),
    /// at most 640 pt of text and 16 pt from the window's sides.
    private func placeHint() {
        let room = max(160, min(Self.hintMaxText + 2 * ViewerHintPill.padX, bounds.width - 2 * Self.hintMargin))
        let size = hint.fit(maxWidth: room)
        let top = max(bounds.minY, pictureRect.minY) + Self.hintTop
        hint.frame = NSRect(x: (bounds.midX - size.width / 2).rounded(), y: top, width: size.width, height: size.height)
    }

    /// `seconds` nil: it stays until `hideHint`.
    func showHint(_ text: String, seconds: Double? = 3) { showHint(ViewerHintPill.Hint(text: text), seconds: seconds) }

    func showHint(_ h: ViewerHintPill.Hint, seconds: Double? = 3) {
        hint.set(h)
        placeHint()
        fadeHint(in: true)
        hintTimer?.invalidate()
        hintTimer = nil
        hintSeconds = seconds
        guard let seconds else { lasting = h; return }
        if !hintHovered { startHintTimer(seconds) }
    }

    private func startHintTimer(_ seconds: Double) {
        hintTimer?.invalidate()
        hintTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endShortHint() }
        }
    }

    /// The short hint's time is up: what lasts comes back, or the pill fades out.
    private func endShortHint() {
        hintTimer?.invalidate()
        hintTimer = nil
        hintSeconds = nil
        if let l = lasting {
            hint.set(l)
            placeHint()
        } else {
            fadeHint(in: false)
        }
    }

    /// The short hint ends now, if it is of this kind (the keys given back: "press ⌃⌘" is no longer true) or of any kind (`kind` nil: a
    /// popover opened over the picture, and one floating thing at a time). What lasts stays.
    func endHint(kind: String? = nil) {
        guard !hint.isHidden, hintSeconds != nil else { return }
        if let kind, hint.content.kind != kind { return }
        endShortHint()
    }

    func hideHint() {
        lasting = nil
        hintTimer?.invalidate()
        hintTimer = nil
        hintSeconds = nil
        fadeHint(in: false)
    }

    /// In over 0.18 s, out over 0.25 s. It never takes a click: the picture's clicks go to the computer under it.
    private func fadeHint(in show: Bool) {
        hintTurn += 1
        let turn = hintTurn
        if show {
            if hint.isHidden { hint.alphaValue = 0; hint.isHidden = false }
        } else if hint.isHidden { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = show ? 0.18 : 0.25
            hint.animator().alphaValue = show ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hintTurn == turn, !show else { return }
                self.hint.isHidden = true
            }
        })
    }

    /// The pointer resting on the short hint keeps it up (it is being read); leaving gives it a moment more.
    private func hoverHint(_ e: NSEvent) {
        let over = !hint.isHidden && hint.frame.contains(convert(e.locationInWindow, from: nil))
        guard over != hintHovered else { return }
        hintHovered = over
        guard hintSeconds != nil else { return }
        if over {
            hintTimer?.invalidate()
            hintTimer = nil
        } else {
            startHintTimer(1.5)
        }
    }

    #if DEBUG || BLURT_TEST_HOOKS
    /// what the hint says and where it is, in the view's points (`viewer state`)
    var testHint: [String: Any] {
        let shown = !hint.isHidden
        return ["shown": shown, "text": hint.content.text, "keys": hint.content.keys, "note": hint.content.note ?? "",
                "frame": NSStringFromRect(hint.frame), "view": NSStringFromRect(bounds), "picture": NSStringFromRect(pictureRect),
                "top": shown ? Double(hint.frame.minY - max(bounds.minY, pictureRect.minY)) : 0,
                "inside": !shown || bounds.insetBy(dx: Self.hintMargin - 1, dy: 0).contains(hint.frame),
                "lines": shown ? hint.leadLines : 0, "oneRow": hint.oneRow, "fits": !shown || hint.fits]
    }
    #endif

    // MARK: the mouse

    override func resetCursorRects() {
        if captured, hasPicture { addCursorRect(pictureRect, cursor: Self.blank) }
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

    override func mouseMoved(with e: NSEvent) {
        hoverHint(e)
        pointer(e)
    }
    override func mouseDragged(with e: NSEvent) { pointer(e) }
    override func rightMouseDragged(with e: NSEvent) { pointer(e) }
    override func otherMouseDragged(with e: NSEvent) { pointer(e) }
    override func mouseExited(with e: NSEvent) {
        if hintHovered {
            hintHovered = false
            if hintSeconds != nil { startHintTimer(1.5) }
        }
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
        // ⌘-click, ⌃-click: a ⌘ or ⌃ held back as a possible release goes first
        if down { c.beforeInput() }
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
        c.beforeInput()
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

/// The viewer's hint as the capture chrome's hint pill (system.md, Hint pill; `PickerHint`): the island's black with its hairline and soft
/// shadow (`CaptureGlass`), so it keeps its edge over any picture, light or dark; one sentence (13 medium, white 92 %), then after a hairline
/// the keys as keycaps, one per key, and their word (12, white 62 %): "Keyboard and mouse go to Office PC | [⌃][⌘] Release". Never a
/// key typed into the sentence. A quieter note under it when there is one more thing to know (system shortcuts without Input Monitoring).
/// One row is a capsule; a window too narrow for it puts the keys under the sentence, centred, with 14 pt corners.
final class ViewerHintPill: NSView {
    struct Hint: Equatable {
        var text: String
        var keys: [String] = []
        var keysWord = ""
        var note: String?
        /// what it is about ("release"), so it can end the moment that's no longer true
        var kind = ""
    }

    static let padX: CGFloat = 14
    static let padY: CGFloat = 9
    /// one row, no note: the capsule's height
    static let rowH: CGFloat = 34
    private let lead = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let rule = NSView()
    private var keyLine: KeyLine?
    private(set) var content = Hint(text: "")
    private(set) var oneRow = true
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: Self.rowH))
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        lead.font = .systemFont(ofSize: 13, weight: .medium)
        lead.textColor = NSColor(white: 1, alpha: 0.92)
        lead.maximumNumberOfLines = 4
        lead.lineBreakMode = .byWordWrapping
        note.font = .systemFont(ofSize: 12)
        note.textColor = NSColor(white: 1, alpha: 0.62)
        note.maximumNumberOfLines = 4
        note.lineBreakMode = .byWordWrapping
        note.alignment = .center
        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        [lead, rule, note].forEach(addSubview)
        CaptureGlass.apply(layer, radius: Self.rowH / 2)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(_ h: Hint) {
        content = h
        lead.stringValue = h.text
        note.stringValue = h.note ?? ""
        note.isHidden = h.note == nil
        keyLine?.removeFromSuperview()
        keyLine = nil
        if !h.keys.isEmpty {
            let runs: [KeyLine.Run] = h.keys.map { KeyLine.Run.key($0) } + (h.keysWord.isEmpty ? [] : [.text(h.keysWord)])
            let k = KeyLine(runs, size: 12, color: NSColor(white: 1, alpha: 0.62))
            addSubview(k)
            keyLine = k
        }
        rule.isHidden = keyLine == nil
        let keys = h.keys.isEmpty ? "" : h.keys.joined() + " " + h.keysWord
        setAccessibilityLabel([h.text, keys, h.note ?? ""].filter { !$0.isEmpty }.joined(separator: ". "))
    }

    private static func measure(_ f: NSTextField, width: CGFloat) -> NSSize {
        let s = f.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)) ?? .zero
        return NSSize(width: ceil(min(s.width, width)), height: ceil(s.height))
    }

    /// Lays itself out within `maxWidth` (the pill's whole width) and says its size.
    func fit(maxWidth: CGFloat) -> NSSize {
        let avail = max(60, maxWidth - 2 * Self.padX)
        let one = Self.measure(lead, width: 10_000)
        let keyW = keyLine?.frame.width ?? 0
        let keyH = keyLine?.frame.height ?? 0
        // the keys sit 10 pt either side of a 1 pt hairline after the sentence
        let keyRun = keyLine == nil ? 0 : 21 + keyW
        oneRow = one.width + keyRun <= avail
        let leadSize = oneRow ? one : Self.measure(lead, width: avail)
        let rowW = oneRow ? one.width + keyRun : max(leadSize.width, keyW)
        let rowH = oneRow ? max(one.height, keyH) : leadSize.height + (keyLine == nil ? 0 : 5 + keyH)
        var noteSize = NSSize.zero
        // one line where the window allows (a two-line note under a one-line row read ragged)
        if !note.isHidden { noteSize = Self.measure(note, width: min(avail, max(rowW, 600))) }
        let inner = max(rowW, noteSize.width)
        let width = ceil(inner + 2 * Self.padX)
        let alone = note.isHidden && oneRow
        let height = alone ? Self.rowH : ceil(Self.padY + rowH + (note.isHidden ? 0 : 4 + noteSize.height) + Self.padY)
        let top = alone ? ((Self.rowH - rowH) / 2).rounded() : Self.padY
        let x0 = (Self.padX + (inner - rowW) / 2).rounded()
        if oneRow {
            lead.alignment = .left
            lead.frame = NSRect(x: x0, y: top + ((rowH - one.height) / 2).rounded(), width: one.width, height: one.height)
            rule.frame = NSRect(x: x0 + one.width + 10, y: top + ((rowH - 14) / 2).rounded(), width: 1, height: 14)
            keyLine?.frame.origin = NSPoint(x: x0 + one.width + 21, y: top + ((rowH - keyH) / 2).rounded())
        } else {
            lead.alignment = .center
            lead.frame = NSRect(x: (Self.padX + (inner - leadSize.width) / 2).rounded(), y: top, width: leadSize.width, height: leadSize.height)
            rule.isHidden = true
            keyLine?.frame.origin = NSPoint(x: (Self.padX + (inner - keyW) / 2).rounded(), y: lead.frame.maxY + 5)
        }
        if keyLine != nil, oneRow { rule.isHidden = false }
        note.frame = NSRect(x: (Self.padX + (inner - noteSize.width) / 2).rounded(), y: top + rowH + 4, width: noteSize.width, height: noteSize.height)
        layer?.cornerRadius = alone ? height / 2 : 14
        return NSSize(width: width, height: height)
    }

    /// the sentence's lines (tests)
    var leadLines: Int {
        Int((lead.frame.height / NSLayoutManager().defaultLineHeight(for: lead.font ?? .systemFont(ofSize: 13))).rounded())
    }

    /// every text shown whole in its frame (tests)
    var fits: Bool {
        [lead, note].allSatisfy { f in
            f.isHidden || Self.measure(f, width: f.frame.width).height <= f.frame.height + 1
        } && (keyLine.map { bounds.contains($0.frame) } ?? true)
    }
}
