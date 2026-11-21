// The snap's markup tools (v1.0.23; the rules and the key decision: BlurtCore Ink.swift's header, InkMarks.swift).
//
//  • InkToolStrip — the compact row attached to the frozen selection (InkStage places it: BlurtCore StripDock, under
//    it right-aligned, never over the note bubble): pen · box · ellipse · arrow · text · mosaic, the colours (the brand
//    markup colour first), undo, and copy-and-done (⌘↩: no card). The capture chrome's surface (CaptureGlass, the
//    picker toolbar's: black 88 % with a white hairline, the same in light and dark — it sits on the dimmed screen,
//    like the picker it follows). The chosen tool on a white 18 % wash, the chosen colour ringed. Each control's
//    tooltip names its key; it takes the pointer, never the keys (the note keeps typing).
//  • renderMarks — every mark burnt into NNN.marked.png (what a copy or a drag hands out): mosaics first, over the
//    original pixels (pixelate: block averages, BlurtCore InkMosaic.block), then lines, arrows (head filled) and text,
//    in the order they were made.
//  • inkTextImage — a text mark as drawn on the canvas and in the PNG alike: the UI's font, semibold, the colour, an
//    outline in the opposite tone and a soft shadow, so it reads on any picture.
//  • InkTextBox — the text box being typed on the picture (InkCanvas): plain text, the mark's font and colour.
import AppKit
import BlurtCore

extension InkColor {
    var ns: NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
    var name: String { Loc.t("capture.ink.color_\(rawValue)", table: "Capture") }
}

extension InkPick {
    var symbol: String {
        switch self {
        case .pen: return "scribble"
        case .box: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        // our own line glyphs (assets/icons letter-t, mosaic), drawn at the SF tools' size and weight: the typed 17 pt
        // "T" and SF's filled checkerboard read as another set beside the thin outlines (SF's text symbols also turn
        // into 格式 / 字 under zh)
        case .text: return "brand:letter-t"
        case .mosaic: return "brand:mosaic"
        }
    }
    var name: String { Loc.t("capture.ink.tool_\(rawValue)", table: "Capture") }
    /// "Arrow (⌘L) · ⇧ keeps it on 45°"
    var tip: String { Loc.t("capture.ink.tip_\(rawValue)", table: "Capture", keyLabel) }
}

// MARK: - Mosaic

/// `img` with every `block`-pixel square (from its top-left) the average of its pixels.
func pixelate(_ img: CGImage, block: Int) -> CGImage? {
    let w = img.width, h = img.height, b = max(1, block)
    let sw = max(1, (w + b - 1) / b), sh = max(1, (h + b - 1) / b)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let small = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    small.interpolationQuality = .high
    // the picture's top-left on the small one's top-left (CG's y is up): the partial blocks fall right and bottom
    let fw = CGFloat(w) / CGFloat(b), fh = CGFloat(h) / CGFloat(b)
    small.draw(img, in: CGRect(x: 0, y: CGFloat(sh) - fh, width: fw, height: fh))
    guard let tiny = small.makeImage(),
          let big = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    big.interpolationQuality = .none
    big.draw(tiny, in: CGRect(x: 0, y: CGFloat(h - sh * b), width: CGFloat(sw * b), height: CGFloat(sh * b)))
    return big.makeImage()
}

// MARK: - Text

/// The font a text mark is set in: the UI's own, semibold.
func inkTextFont(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }

/// The room round a text mark's image for its outline and shadow.
func inkTextPad(_ fontSize: CGFloat) -> CGFloat { ceil(fontSize * 0.3) + 2 }

/// A text mark drawn: `text` at `fontSize` (any unit; `scale` pixels to it) with its outline and shadow. The image is
/// the text's box grown by `inkTextPad` all round (the text's top-left sits that far in).
func inkTextImage(_ text: String, fontSize: CGFloat, color: InkColor, scale: CGFloat) -> CGImage? {
    let font = inkTextFont(fontSize)
    let ps = NSMutableParagraphStyle()
    ps.lineBreakMode = .byClipping
    let base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: ps]
    let size = (text as NSString).boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin], attributes: base).size
    let pad = inkTextPad(fontSize)
    let W = Int(ceil((ceil(size.width) + pad * 2) * scale)), H = Int(ceil((ceil(size.height) + pad * 2) * scale))
    guard W > 0, H > 0, let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: CGFloat(H) / scale)
    ctx.scaleBy(x: 1, y: -1)
    ctx.setLineJoin(.round)
    let g = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = g
    let outline = color.outlineIsLight ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.72)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(color.outlineIsLight ? 0.25 : 0.4)
    shadow.shadowBlurRadius = max(1.5, fontSize * 0.16)
    shadow.shadowOffset = .zero
    // the outline (stroke only, 9 % of the size: about 4.5 % shows outside the glyphs) under its shadow, then the fill
    var o = base
    o[.strokeColor] = outline
    o[.strokeWidth] = 9
    o[.shadow] = shadow
    (text as NSString).draw(at: NSPoint(x: pad, y: pad), withAttributes: o)
    var f = base
    f[.foregroundColor] = color.ns
    (text as NSString).draw(at: NSPoint(x: pad, y: pad), withAttributes: f)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()
}

// MARK: - The marked picture

/// Burns `marks` (BlurtCore InkMark, 0–1 points) into a copy of the shot → NNN.marked.png. `lineWidthPx`: the line as
/// wide in the picture as it was drawn; `pixelsPerPoint`: the picture's scale (the mosaic's block).
func renderMarks(_ img: CGImage, marks: [InkMark], lineWidthPx: CGFloat, pixelsPerPoint: CGFloat) -> CGImage? {
    let w = CGFloat(img.width), h = CGFloat(img.height), short = min(w, h)
    guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let full = CGRect(x: 0, y: 0, width: w, height: h)
    ctx.draw(img, in: full)
    // (CG's y is up: a 0–1 point from the top)
    let pt = { (p: [Double]) in CGPoint(x: CGFloat(p[0]) * w, y: (1 - CGFloat(p[1])) * h) }
    var pixels: CGImage?
    for m in InkMark.drawOrder(marks) where !m.points.isEmpty {
        switch m.kind {
        case .mosaic:
            if pixels == nil { pixels = pixelate(img, block: InkMosaic.block(pixelsPerPoint: pixelsPerPoint, shortSidePx: Int(short))) }
            guard let px = pixels else { continue }
            ctx.saveGState()
            if m.brush {
                ctx.addPath(inkPath(m.points.map(pt), ring: 0.5))
                ctx.setLineWidth(CGFloat(m.size ?? 0.05) * short)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.replacePathWithStrokedPath()
            } else if m.points.count >= 2 {
                let a = pt(m.points[0]), b = pt(m.points[1])
                ctx.addRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
            }
            ctx.clip()
            ctx.interpolationQuality = .none
            ctx.draw(px, in: full)
            ctx.restoreGState()
        case .pen, .arrow:
            ctx.saveGState()
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(lineWidthPx)
            ctx.setStrokeColor(m.color.ns.cgColor)
            ctx.setFillColor(m.color.ns.cgColor)
            // one shadow for the whole mark (a transparency layer): an arrow's shaft never shades its own head
            ctx.setShadow(offset: .zero, blur: lineWidthPx * 0.4, color: NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            defer { ctx.endTransparencyLayer(); ctx.restoreGState() }
            let pts = m.points.map(pt)
            if pts.count == 1 {
                let r = lineWidthPx * 4.5
                ctx.strokeEllipse(in: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: r * 2, height: r * 2))
            } else {
                ctx.addPath(inkPath(pts, ring: 0))
                ctx.drawPath(using: m.kind == .arrow ? .fillStroke : .stroke)
            }
        case .text:
            guard let t = m.text, let ti = inkTextImage(t, fontSize: CGFloat(m.size ?? 0.05) * short, color: m.color, scale: 1) else { continue }
            let pad = inkTextPad(CGFloat(m.size ?? 0.05) * short)
            let tl = pt(m.points[0])
            ctx.draw(ti, in: CGRect(x: tl.x - pad, y: tl.y + pad - CGFloat(ti.height), width: CGFloat(ti.width), height: CGFloat(ti.height)))
        }
    }
    return ctx.makeImage()
}

// MARK: - The text box being typed

/// Plain text in the mark's font and colour, no background; its keys are its own (↩ ends, Esc drops: InkCanvas).
final class InkTextBox: NSTextView {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }
}

// MARK: - The tool strip

/// One control on the strip: a tool, a colour, an action. Takes the first click (the app isn't active under a snap).
final class StripButton: NSView {
    enum Look { case tool(String), swatch(NSColor), action(String) }
    let look: Look
    var on = false { didSet { needsDisplay = true } }
    var enabled = true { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var over = false { didSet { needsDisplay = true } }
    private var down = false { didSet { needsDisplay = true } }

    init(_ look: Look, tip: String, size: NSSize) {
        self.look = look
        super.init(frame: NSRect(origin: .zero, size: size))
        toolTip = tip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tip)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseEntered(with event: NSEvent) { over = true }
    override func mouseExited(with event: NSEvent) { over = false }
    override func mouseDown(with event: NSEvent) { if enabled { down = true } }
    override func mouseUp(with event: NSEvent) {
        let hit = bounds.contains(convert(event.locationInWindow, from: nil))
        let was = down
        down = false
        if was, hit, enabled { onClick?() }
    }

    override func draw(_ dirty: NSRect) {
        switch look {
        case .tool(let sym), .action(let sym):
            let wash: CGFloat = on ? 0.2 : down ? 0.16 : over && enabled ? 0.1 : 0
            if wash > 0 {
                NSColor(white: 1, alpha: wash).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
            }
            let tint = NSColor(white: 1, alpha: !enabled ? 0.3 : on || over ? 1 : 0.78)
            if sym.hasPrefix("brand:"), let icon = BlurtIcon(rawValue: String(sym.dropFirst(6))) {
                // a family glyph in the SF symbols' box: 18 pt draws its 17-unit live area as tall as a 14 pt symbol
                let d: CGFloat = 18
                icon.image(size: d, color: tint, weight: on ? 1.2 : 1)
                    .draw(in: NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d))
                return
            }
            if sym.count == 1 {
                // a letter for a glyph (the text tool's T), the symbols' weight and size
                let a = NSAttributedString(string: sym, attributes: [.font: NSFont.systemFont(ofSize: 17, weight: on ? .semibold : .regular),
                                                                     .foregroundColor: tint])
                let sz = a.size()
                a.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2))
                return
            }
            guard let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: on ? .semibold : .regular)) else { return }
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r)
                tint.set()
                r.fill(using: .sourceAtop)
                return true
            }
            let r = NSRect(x: (bounds.width - img.size.width) / 2, y: (bounds.height - img.size.height) / 2,
                           width: img.size.width, height: img.size.height)
            tinted.draw(in: r)
        case .swatch(let c):
            let d: CGFloat = 14
            let r = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
            if on || over {
                NSColor(white: 1, alpha: on ? 0.95 : 0.4).setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -3.5, dy: -3.5))
                ring.lineWidth = on ? 2 : 1.5
                ring.stroke()
            }
            c.setFill()
            NSBezierPath(ovalIn: r).fill()
            NSColor(white: 1, alpha: 0.3).setStroke()
            let rim = NSBezierPath(ovalIn: r.insetBy(dx: 0.25, dy: 0.25))
            rim.lineWidth = 0.5
            rim.stroke()
        }
    }
}

/// pen · box · ellipse · arrow · text · mosaic | colours | undo | copy and done
final class InkToolStrip: NSView {
    static let height: CGFloat = 40
    private var tools: [InkPick: StripButton] = [:]
    private var swatches: [InkColor: StripButton] = [:]
    private var undoBtn: StripButton!
    private var copyBtn: StripButton!
    private var seps: [NSView] = []
    var onPick: ((InkPick) -> Void)?
    var onColor: ((InkColor) -> Void)?
    var onUndo: (() -> Void)?
    var onCopy: (() -> Void)?
    /// ⌘↩ is offered (a snap of its own, not one going into a recording)
    var canCopy = true { didSet { layoutRow() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        CaptureGlass.apply(layer, radius: InkToolStrip.height / 2)
        for t in InkPick.allCases {
            let b = StripButton(.tool(t.symbol), tip: t.tip, size: NSSize(width: 30, height: 30))
            b.onClick = { [weak self] in self?.onPick?(t) }
            tools[t] = b
            addSubview(b)
        }
        for c in InkColor.allCases {
            let b = StripButton(.swatch(c.ns), tip: Loc.t("capture.ink.color_tip", table: "Capture", c.name), size: NSSize(width: 22, height: 30))
            b.onClick = { [weak self] in self?.onColor?(c) }
            swatches[c] = b
            addSubview(b)
        }
        undoBtn = StripButton(.action("arrow.uturn.backward"), tip: Loc.t("capture.ink.undo_tip", table: "Capture"), size: NSSize(width: 30, height: 30))
        undoBtn.onClick = { [weak self] in self?.onUndo?() }
        copyBtn = StripButton(.action("doc.on.doc"), tip: Loc.t("capture.ink.copy_tip", table: "Capture"), size: NSSize(width: 30, height: 30))
        copyBtn.onClick = { [weak self] in self?.onCopy?() }
        addSubview(undoBtn)
        addSubview(copyBtn)
        for _ in 0..<3 {
            let s = NSView()
            s.wantsLayer = true
            s.layer?.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor
            seps.append(s)
            addSubview(s)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(Loc.t("capture.ink.strip", table: "Capture"))
        layoutRow()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // a click between the buttons stays on the strip (never a "done" click on the dim behind it)
    override func mouseDown(with event: NSEvent) {}

    private func layoutRow() {
        var x: CGFloat = 5
        let mid = InkToolStrip.height / 2
        func put(_ v: NSView) {
            v.frame.origin = NSPoint(x: x, y: mid - v.frame.height / 2)
            x += v.frame.width + 1
        }
        func sep(_ i: Int) {
            x += 5
            seps[i].frame = NSRect(x: x, y: mid - 9, width: 1, height: 18)
            x += 7
        }
        for t in InkPick.allCases { put(tools[t]!) }
        sep(0)
        for c in InkColor.allCases { put(swatches[c]!) }
        sep(1)
        put(undoBtn)
        copyBtn.isHidden = !canCopy
        seps[2].isHidden = !canCopy
        if canCopy { sep(2); put(copyBtn) }
        setFrameSize(NSSize(width: x + 4, height: InkToolStrip.height))
    }

    func show(tool: InkPick, color: InkColor, canUndo: Bool) {
        for (t, b) in tools { b.on = t == tool }
        for (c, b) in swatches { b.on = c == color }
        undoBtn.enabled = canUndo
    }

    /// Tests: a click on a control, as the pointer gives it — `tool NAME` | `color NAME` | `undo` | `copy`.
    func testClick(_ what: String, _ name: String) {
        switch what {
        case "tool": InkPick(rawValue: name).flatMap { tools[$0] }?.onClick?()
        case "color": InkColor(rawValue: name).flatMap { swatches[$0] }?.onClick?()
        case "undo": undoBtn.onClick?()
        case "copy": if canCopy { copyBtn.onClick?() }
        default: break
        }
    }
}
