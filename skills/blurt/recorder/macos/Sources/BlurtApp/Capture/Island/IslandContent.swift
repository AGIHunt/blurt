// The island, open (Island.swift draws the shape): what is under the ears row.
//
// One grid (v0.9-island r2): every leading glyph — a row's icon, the project chip's, a toast's mark — is our line
// family at 15 pt centred on one column (IslandLayout.iconColumn, 26 pt in), and every line of text starts on one
// column (textColumn, 42 pt in); row titles 13 regular; chevrons and accessories at 45 % white (the line chevron).
//
//   home        the current project (click = switch: its folder in its colour, or "Unassigned" with a dashed ring —
//               the tray is only ever the Inbox) · record / snap / voice — quiet glyph buttons, a fill only under the
//               pointer, one stroke (record is a ring and a dot drawn at the family's stroke) · up to 3 jobs in
//               progress (a row on the grid: the spinner in the icon column, the title and its step, a 2 pt progress
//               line under the text column) · agent sessions that need you (click = their terminal) · the cards
//               waiting ("2 cards"), with "Organize" (the sparkle: the view's one filled button) · the Inbox row (its
//               count as a quiet accessory, a chevron: the backlog lives here, not beside the notch)
//   recording   on one grid with the ears (they ride out to the open shape's corners, 14 pt in): pause (paused: the
//               same circle, Resume's play glyph in amber — nothing moves) · snap + note (pauses) … ··· · Finish (the one
//               filled thing; paused, a neutral pill with its red stop square, so Resume leads); the ··· menu (dark,
//               keys right-aligned) holds the rare things: the pen (⌥⇧D), a marker (⌥⇧M), where the take goes
//               (Change…), Discard or Restart… (asks first: the question alone on its line, what goes with it — the
//               snaps and the markers apart — on a quiet second line, then Discard · Restart · Keep Recording ↩, the
//               last where Finish was, so nothing destructive lands under the hand that stops). Then, only when it has
//               something to say, one quiet line: "Pen on" (a tint chip) + "[esc] Pen off", or (first three takes)
//               "[⌃] Hold for the pen  [⌃⇧] Box  [⌃⌥] Ellipse" (a keycap per chord) · how many items were spotted
//   voice       two rows on the body's edges (bodyInset — the ears' mic and clock line up with them): Peep
//               listening (eye wide, swelling with the voice), the live waveform and Done (with the key held there is no Done:
//               the hint says "Let go to finish"); then the Structured chip (list glyph; on = the mint tint chip — the
//               view's one mint thing), how it ends ("⌥V to finish · Esc to discard"; the time left in its last
//               minute) and, on the right edge, where it will go — the words themselves hang under the island
//   drawer      switcher (⌥O): a filter field beside the notch (magnifier, placeholder, caret; typed text in white)
//               and the title across it; recent projects (≤ 8, "More…"; a project whose folder is gone shows so,
//               dimmed, and choosing it asks where the folder is now instead of making it current:
//               MissingFolder.locate — ProjectPick), Unassigned (the dashed ring), Add Project… ⌘O. Its pick form
//               (Island.Pick: "Filed to X · Change") has the same rows and files that one thing instead.
//               drop (a card dragged in, or a ⌘-click selection of them): recent projects, Unassigned, Organize
//               ↑↓ select · ↩ choose · Esc close; the target under the pointer / selection: the island's mint tint (r 8);
//               a project's key shows on the row being chosen unless it is the current one (one trailing mark: the check)
//   toast       one component, one layout: the leading slot always filled (✓ ok for done, the spinner for working, the
//               amber ⚠ for needs you, Peep for a done line, the project's folder for a filing, else Peep's quiet glyph
//               glyph), the title (13 medium) and an optional detail (11.5, 60 %) on the text column, an optional quiet
//               pill 14 pt from the right. Nothing centred. A detail line still at work leads with a small spinner, a
//               peck's state with its ✓ / ⚠; a line that is its own button (a peck) ends in a chevron, "Open" beside
//               it while pointed at. A line too long for the open width wraps (up to three lines), never "…" mid-word
// Dark on black in both appearances (it is the notch); white text at 92 / 60 / 40 %.

import AppKit
import BlurtCore

private let ink = NSColor(white: 1, alpha: 0.92)
private let ink2 = NSColor(white: 1, alpha: 0.6)
private let ink3 = NSColor(white: 1, alpha: 0.38)
/// Chevrons and accessories (⌘O, a project's key): the line chevron at 45 % reads at about 40 % on black (the SF chevron
/// at 38 % peaked at 14 %, too faint to say "this opens").
private let inkAcc = NSColor(white: 1, alpha: 0.45)

/// The island's glyphs that the line family doesn't have as such, drawn at the family's stroke (BlurtIcon.strokeWidth
/// on a 24 grid) so they sit beside snap and mic at one weight.
enum IslandGlyph {
    case record, noProject
    /// A project: the family's folder in the project's colour, its body washed at 28 % so the colour reads at 15 pt (a
    /// red line alone came out brown on the black) — the one project identity (chip, switcher, drop drawer, filings).
    case project(NSColor)

    func cgImage(size: CGFloat, scale: CGFloat = 2, color: CGColor, weight: CGFloat) -> CGImage? {
        let px = Int((size * scale).rounded(.up))
        guard px > 0, let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let k = CGFloat(px) / 24
        ctx.scaleBy(x: k, y: k)
        ctx.setLineCap(.round)
        ctx.setLineWidth(BlurtIcon.strokeWidth * weight)
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        switch self {
        case .record:
            // the ring as the family's record, the dot no heavier than a stroke's end (the filled 4.2 pt dot read bold)
            ctx.strokeEllipse(in: CGRect(x: 3.5, y: 3.5, width: 17, height: 17))
            ctx.fillEllipse(in: CGRect(x: 9.4, y: 9.4, width: 5.2, height: 5.2))
        case .noProject:
            // nothing chosen: a dashed ring (eight dashes) — never a second tray beside the Inbox's
            ctx.setLineDash(phase: 0, lengths: [1.7, 4.58])
            ctx.strokeEllipse(in: CGRect(x: 4, y: 4, width: 16, height: 16))
        case .project(let c):
            ctx.translateBy(x: 0, y: 24)
            ctx.scaleBy(x: 1, y: -1)
            ctx.setLineJoin(.round)
            let cg = c.usingColorSpace(.sRGB) ?? c
            for l in BlurtIcon.folder.layers {
                ctx.addPath(l.path)
                ctx.setFillColor(cg.withAlphaComponent(0.28).cgColor)
                ctx.fillPath()
                ctx.addPath(l.path)
                ctx.setStrokeColor(cg.cgColor)
                ctx.strokePath()
            }
        }
        return ctx.makeImage()
    }

    func image(size: CGFloat, color: NSColor, weight: CGFloat = 1.1) -> NSImage? {
        guard let cg = cgImage(size: size, color: color.cgColor, weight: weight) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }
}

/// A control on the island: a round icon button, or a pill with a title. The island's primary actions ("Hand to AI",
/// AI sort, Done, a question's suggested answer) take `gradient` (BrandGradient.buttonStops) with a white title: hover is
/// a white film (×1.04), pressed a black one (×0.92). `fg`: the title and symbol colour.
/// Composed of layers (wantsUpdateLayer), never drawn: while the island grows, AppKit draws a drawn view piece by piece
/// as the clip uncovers it, and the seams of those pieces showed as dark scanlines and stair-step ghosts through the
/// gradient (dogfood: 排成清单 / Undo / 在访达中显示 for most of the grow animation). Layers are whole at every frame.
/// The title is a picture of the line drawn with font smoothing (BlurtCore TextImage), not a CATextLayer: a text layer
/// draws without smoothing, and the semibold title came out ~20 % lighter than the drawn button's.
final class IslandButton: NSView {
    /// A toast's action, a way back or a way on that isn't the view's primary (Undo, Organize after a failed take,
    /// Download): a quiet pill — white 12 %, a medium title in the island's white, 24 pt.
    static func quiet(_ title: String, tip: String? = nil, action: @escaping () -> Void) -> IslandButton {
        let b = IslandButton(title: title, tip: tip ?? title, fill: NSColor(white: 1, alpha: 0.12), fg: NSColor(white: 1, alpha: 0.92), action: action)
        b.titleWeight = .medium
        b.setFrameSize(NSSize(width: b.intrinsicContentSize.width - 2, height: 24))
        return b
    }

    var action: () -> Void
    var symbol: String { didSet { needsDisplay = true } }
    /// One of our line glyphs in place of an SF Symbol (the island's own buttons: record, snap, mic, pause, trash, stop).
    var icon: BlurtIcon? { didSet { needsDisplay = true } }
    /// A glyph drawn here at the family's stroke (home's record: a ring and a dot; the chip's "Unassigned" ring).
    var drawn: IslandGlyph? { didSet { needsDisplay = true } }
    /// The glyph's own colour when it isn't the title's (the chip: the project's folder in its colour; paused Finish:
    /// the red stop square under a white title).
    var iconColor: NSColor? { didSet { needsDisplay = true } }
    /// The glyph's size beside a title (14; the chip's is the rows' 15, on their icon column).
    var iconSize: CGFloat = 14 { didSet { setFrameSize(intrinsicContentSize); needsDisplay = true } }
    /// From the glyph's right edge to the title (the chip: so its name lands on the rows' text column).
    var titleGap: CGFloat = 6 { didSet { setFrameSize(intrinsicContentSize); needsDisplay = true } }
    var title: String? { didSet { needsDisplay = true } }
    var fill: NSColor? { didSet { needsDisplay = true } }
    var gradient: [(UInt32, CGFloat)]? { didSet { needsDisplay = true } }
    var fg: NSColor = .white { didSet { needsDisplay = true } }
    /// The key that does the same, after the title in the title's colour at 60 % ("Keep Recording  ↩"): every default
    /// answer on the capture surfaces carries its ↩, as the picker's primary does.
    var key: String? { didSet { setFrameSize(intrinsicContentSize); needsDisplay = true } }
    var tip: String
    /// No fill at rest, the island's white film under the pointer: home's record / snap / voice and the project chip —
    /// controls that are always there stay quiet until they are pointed at.
    var ghost = false { didSet { needsDisplay = true } }
    /// The title's weight: semibold on a filled (gradient) button, medium on a quiet one.
    var titleWeight: NSFont.Weight = .semibold { didSet { setFrameSize(intrinsicContentSize); needsDisplay = true } }
    var titleFont: NSFont { NSFont.systemFont(ofSize: 12.5, weight: titleWeight) }
    /// A project's key badge before the title — the current-project chip.
    var badge: (text: String, color: NSColor)? { didSet { setFrameSize(intrinsicContentSize); needsDisplay = true } }
    /// Where a titled button's symbol starts. The project chip sets it to the key badge's inset, so "Unassigned" (a
    /// tray) sits where "AW Atlas Web" does.
    var symbolInset: CGFloat = 14 { didSet { setFrameSize(intrinsicContentSize); needsDisplay = true } }
    static let badgeInset: CGFloat = 7
    private var hover = false, pressed = false
    private let gradientLayer = CAGradientLayer()
    private let film = CALayer()             // hover / pressed
    private let highlight = CALayer()        // the 1 pt inner highlight along the top of a gradient pill
    private let iconLayer = CALayer()
    private let titleLayer = CALayer()
    private let badgeLayer = CALayer()
    private let keyLayer = CALayer()

    init(symbol: String = "", icon: BlurtIcon? = nil, title: String? = nil, tip: String, fill: NSColor? = nil,
         gradient: [(UInt32, CGFloat)]? = nil, fg: NSColor = .white, action: @escaping () -> Void) {
        self.symbol = symbol
        self.icon = icon
        self.title = title
        self.tip = tip
        self.fill = fill
        self.gradient = gradient
        self.fg = fg
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        if let l = layer {
            l.masksToBounds = true
            for sub in [gradientLayer, film, highlight, badgeLayer, iconLayer, titleLayer, keyLayer] as [CALayer] {
                sub.actions = IslandButton.noActions
                l.addSublayer(sub)
            }
        }
        highlight.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        iconLayer.contentsGravity = .resizeAspect
        titleLayer.contentsScale = 2
        badgeLayer.contentsScale = 2
        toolTip = tip
        setFrameSize(intrinsicContentSize)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title ?? tip)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    static let keyFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private var keyWidth: CGFloat { key.map { ceil(($0 as NSString).size(withAttributes: [.font: IslandButton.keyFont]).width) + 7 } ?? 0 }
    /// No implicit animations on the parts: a state change is instant (no cross-fade of one title over another).
    static let noActions: [String: CAAction] = ["contents": NSNull(), "string": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                                "hidden": NSNull(), "backgroundColor": NSNull(), "colors": NSNull(),
                                                "frame": NSNull(), "foregroundColor": NSNull(), "locations": NSNull(),
                                                "startPoint": NSNull(), "endPoint": NSNull()]

    override var intrinsicContentSize: NSSize {
        guard let t = title else { return NSSize(width: 30, height: 30) }
        let tw = (t as NSString).size(withAttributes: [.font: titleFont]).width
        if let b = badge { return NSSize(width: ceil(tw) + ProjectLook.badgeSize(b.text).width + Self.badgeInset + 7 + 13, height: 28) }
        return NSSize(width: ceil(tw) + keyWidth + (hasGlyph ? iconSize + titleGap + 10 + symbolInset : 26), height: 28)
    }
    private var hasGlyph: Bool { icon != nil || drawn != nil || !symbol.isEmpty }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); needsDisplay = true }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsDisplay = true }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; pressed = false; needsDisplay = true }
    override func mouseDown(with e: NSEvent) { pressed = true; needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        let inside = bounds.contains(convert(e.locationInWindow, from: nil))
        pressed = false
        needsDisplay = true
        if inside { action() }
    }
    override func accessibilityPerformPress() -> Bool { action(); return true }

    override func updateLayer() {
        guard let l = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        let b = bounds
        l.cornerRadius = b.height / 2
        if let g = gradient {
            BrandGradient.layer(g, .diagonal, flipped: true, into: gradientLayer)
            gradientLayer.frame = b
            gradientLayer.isHidden = false
            l.backgroundColor = nil
            film.backgroundColor = pressed ? NSColor(white: 0, alpha: 1 - BrandGradient.buttonPressed).cgColor
                : hover ? NSColor(white: 1, alpha: BrandGradient.buttonHover - 1).cgColor : nil
            highlight.frame = CGRect(x: b.height * 0.3, y: 0, width: max(0, b.width - b.height * 0.6), height: 1)
            highlight.isHidden = false
        } else {
            gradientLayer.isHidden = true
            highlight.isHidden = true
            let base = fill ?? NSColor(white: 1, alpha: 0.1)
            let c = pressed ? base.blended(withFraction: 0.3, of: .white) ?? base : hover ? base.blended(withFraction: 0.16, of: .white) ?? base : base
            l.backgroundColor = ghost ? (pressed ? NSColor(white: 1, alpha: 0.2) : hover ? NSColor(white: 1, alpha: 0.12) : nil)?.cgColor
                : c.cgColor
            film.backgroundColor = nil
        }
        film.frame = b
        var x: CGFloat = title == nil ? 0 : symbolInset
        iconLayer.isHidden = true
        // our glyph: 15 pt alone in a round button, 14 beside a title (docs/design/system.md §2.6), the family's line
        let gs = title == nil ? 15 : iconSize, gw: CGFloat = title == nil || iconSize >= 15 ? 1.1 : 1.2
        let gc = (iconColor ?? fg).cgColor
        let glyph = drawn.flatMap { $0.cgImage(size: gs, color: gc, weight: gw) }
            ?? icon.flatMap { $0.cgImage(size: gs, scale: 2, color: gc, weight: gw) }
            ?? (symbol.isEmpty ? nil : symbolImage(symbol, size: 12, weight: .semibold, color: fg))
        if let img = glyph {
            let s = CGSize(width: CGFloat(img.width) / 2, height: CGFloat(img.height) / 2)
            let ix = title == nil ? (b.width - s.width) / 2 : x
            iconLayer.contents = img
            iconLayer.contentsScale = 2
            iconLayer.frame = CGRect(x: ix.rounded(), y: ((b.height - s.height) / 2).rounded(), width: s.width, height: s.height)
            iconLayer.isHidden = false
            x = ix + s.width + titleGap
        }
        titleLayer.isHidden = title == nil
        badgeLayer.isHidden = badge == nil
        keyLayer.isHidden = key == nil || title == nil
        if let t = title {
            let attrs: [NSAttributedString.Key: Any] = [.font: titleFont]
            var tx = hasGlyph ? x : 13
            var room = b.width - tx - (subviews.isEmpty ? 8 : 22) - keyWidth     // (the chip's chevron; the key after the title)
            if let bd = badge {
                // the key leads (it carries the project's colour); the name gives way to it when room is short
                let bs = ProjectLook.badgeSize(bd.text)
                let img = NSImage(size: bs, flipped: true) { r in ProjectLook.drawBadge(bd.text, color: bd.color, in: r); return true }
                badgeLayer.contents = img.layerContents(forContentsScale: scale)
                badgeLayer.contentsScale = scale
                badgeLayer.frame = CGRect(x: Self.badgeInset, y: ((b.height - bs.height) / 2).rounded(), width: bs.width, height: bs.height)
                tx = Self.badgeInset + bs.width + 7
                room = b.width - tx - (subviews.isEmpty ? 12 : 22)
            }
            var name = t
            while !name.isEmpty && ((name + (name == t ? "" : "…")) as NSString).size(withAttributes: attrs).width > room { name.removeLast() }
            // ("Customer…", not "Customer …": the space the cut stopped at goes too)
            let shown = name == t ? t : name.trimmingCharacters(in: .whitespaces) + "…"
            // the line as AppKit draws it (smoothed: its full weight), measured from the picture itself so it centres
            if let line = TextImage.line(shown, font: titleFont, color: fg.cgColor, scale: scale) {
                titleLayer.contents = line.image
                titleLayer.contentsScale = scale
                titleLayer.frame = CGRect(x: tx, y: ((b.height - line.size.height) / 2).rounded(), width: line.size.width, height: line.size.height)
                if let k = key, let kl = TextImage.line(k, font: IslandButton.keyFont, color: fg.withAlphaComponent(0.6).cgColor, scale: scale) {
                    keyLayer.contents = kl.image
                    keyLayer.contentsScale = scale
                    keyLayer.frame = CGRect(x: titleLayer.frame.maxX + 7, y: ((b.height - kl.size.height) / 2).rounded(),
                                            width: kl.size.width, height: kl.size.height)
                }
            } else {
                titleLayer.contents = nil
            }
        }
        CATransaction.commit()
    }
}

/// A row on the island's grid: the icon centred on the icon column (or the spinner, or an agent's dot), the title on
/// the text column (13 regular; a job's step after it in secondary white, or a subtitle under it), an accessory on the
/// right, an optional 2 pt progress line under the text column. Hover / selection wash.
final class IslandRow: NSView {
    var icon: NSImage?
    var title: String
    var subtitle: String?
    /// Said after the title on its own line, in secondary white: a job's step ("Organizing  Preparing").
    var status: String?
    var accessory: String?
    /// The accessory is a project's key: shown only on the row under the pointer / the selection (quiet otherwise),
    /// and never beside the check (one trailing mark).
    var accessoryIsKey = false
    /// A chevron at the right edge: the row opens a place (the Inbox).
    var disclosure = false
    /// Room kept free at the right for a control placed over the row (home's Organize).
    var trailingReserve: CGFloat = 0
    var checked = false
    var progress: Double?
    var dot: NSColor?
    /// Not available as it is (a project whose folder is gone): the title in the island's secondary white.
    var dimmed = false
    /// At work: the spinner in the icon column instead of a glyph (as a list shows a running command).
    var working = false { didSet { placeSpinner() } }
    var action: (() -> Void)?
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    var onHover: (() -> Void)?
    var target: IslandContent.Target?
    private var spinner: IslandSpinner?

    init(icon: NSImage?, title: String, subtitle: String? = nil, height: CGFloat = 36, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: height))
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(action == nil ? .staticText : .button)
        setAccessibilityLabel([title, subtitle].compactMap { $0 }.joined(separator: ", "))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with e: NSEvent) { if action != nil || target != nil { onHover?(); selected = true } }
    override func mouseExited(with e: NSEvent) { if onHover == nil { selected = false } }
    override func mouseUp(with e: NSEvent) { if bounds.contains(convert(e.locationInWindow, from: nil)) { action?() } }
    override func accessibilityPerformPress() -> Bool { action?(); return action != nil }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); placeSpinner() }

    static let lineH: CGFloat = 17, subH: CGFloat = 15
    /// The text block (the title line, a subtitle, the progress line under them) centred in the row.
    private var textTop: CGFloat {
        let h = IslandRow.lineH + (subtitle == nil ? 0 : IslandRow.subH) + (progress == nil ? 0 : 6)
        return ((bounds.height - h) / 2).rounded()
    }
    /// Where the icon column's glyph is centred: the title line's middle (the title with its subtitle when there is one).
    private var iconMid: CGFloat { textTop + (subtitle == nil ? IslandRow.lineH / 2 : (IslandRow.lineH + IslandRow.subH) / 2) }

    private func placeSpinner() {
        if working, spinner == nil { let sp = IslandSpinner(frame: NSRect(x: 0, y: 0, width: 13, height: 13)); addSubview(sp); spinner = sp }
        if !working { spinner?.removeFromSuperview(); spinner = nil }
        spinner?.frame.origin = NSPoint(x: IslandLayout.iconColumn - 6.5, y: (iconMid - 6.5).rounded())
    }

    override func draw(_ dirty: NSRect) {
        if selected {
            BrandColor.Island.tint.setFill()                     // brand.tint, island value (mint @ 20 %), the rows' r 8
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        let ic = IslandLayout.iconColumn, x = IslandLayout.textColumn, mid = iconMid
        if let d = dot {
            d.setFill()
            NSBezierPath(ovalIn: NSRect(x: ic - 4, y: mid - 4, width: 8, height: 8)).fill()
        } else if let im = icon, !working {
            let s = im.size
            im.draw(in: NSRect(x: (ic - s.width / 2).rounded(), y: (mid - s.height / 2).rounded(), width: s.width, height: s.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        var right = bounds.width - 18 - trailingReserve
        func mark(_ ic: BlurtIcon, size: CGFloat, color: NSColor, weight: CGFloat) {
            let im = ic.image(size: size, color: color, weight: weight)
            right -= size
            im.draw(in: NSRect(x: right, y: (mid - size / 2).rounded(), width: size, height: size))
        }
        // the current one: a white check in a column of its own (the wash under the pointer is the mint; the two never
        // merge into one mark)
        if checked { mark(.check, size: 14, color: ink, weight: 1.3); right -= 10 }
        if disclosure { mark(.chevronRight, size: 13, color: inkAcc, weight: 1.35); right -= 6 }
        // a project's key only on the row being chosen, never beside the check (one trailing mark); other accessories always
        if let a = accessory, !accessoryIsKey || (selected && !checked) {
            let f = accessoryIsKey ? NSFont.monospacedSystemFont(ofSize: 11, weight: .medium) : NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
            let s = NSAttributedString(string: a, attributes: [.font: f, .foregroundColor: accessoryIsKey ? inkAcc : ink2])
            let sz = s.size()
            s.draw(at: NSPoint(x: right - sz.width, y: (mid - sz.height / 2).rounded()))
            right -= sz.width + 10
        }
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byTruncatingTail
        let t = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: dimmed ? ink2 : ink,
                                                                       .paragraphStyle: ps])
        if let st = status {
            t.append(NSAttributedString(string: "  " + st, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ink2, .paragraphStyle: ps]))
        }
        let top = textTop
        t.draw(in: NSRect(x: x, y: top, width: max(0, right - x), height: IslandRow.lineH))
        var bottom = top + IslandRow.lineH
        if let sub = subtitle {
            let st = NSAttributedString(string: sub, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: ink2, .paragraphStyle: ps])
            st.draw(in: NSRect(x: x, y: bottom, width: max(0, right - x), height: IslandRow.subH))
            bottom += IslandRow.subH
        }
        if let p = progress {
            // under the text column, 4 pt below the text: the job's own line, inside its row
            let track = NSRect(x: x, y: bottom + 4, width: bounds.width - x - 18 - trailingReserve, height: 2)
            NSColor(white: 1, alpha: 0.12).setFill()
            NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
            BrandColor.Island.fill.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * CGFloat(min(1, max(0, p))), height: 2), xRadius: 1, yRadius: 1).fill()
        }
    }
}

/// Bars that follow a level (recording: the mic) or a history (voice input: a scrolling waveform, newest at the right).
/// The live bars are one vertical base gradient across the whole group (gradient.vertical: each bar shows the slice at
/// its height); quiet ones are a faint white. `gradient` nil: flat `color`. `track`: one empty mark for silence and
/// for before any audio — a faint centre line under the bars, never a row of dots (the voice note's strip showed both).
final class Bars: NSView {
    var values: [Float] = [] { didSet { needsDisplay = true } }
    var gradient: [(UInt32, CGFloat)]? = BrandGradient.linearStops
    var color: NSColor = BrandColor.Island.fill
    var bar: CGFloat = 3, gap: CGFloat = 2.5
    var track = false
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        let n = max(1, Int((bounds.width + gap) / (bar + gap)))
        let vals = Array(values.suffix(n))
        let pad = n - vals.count
        let live = NSBezierPath(), quiet = NSBezierPath()
        if track {
            NSColor(white: 1, alpha: 0.16).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: (bounds.height - 1) / 2, width: CGFloat(n) * (bar + gap) - gap, height: 1)).fill()
        }
        for i in pad..<n {
            let v = CGFloat(vals[i - pad])
            if track && v <= 0.02 { continue }            // silence: the line shows through
            let hh = max(bar, v * bounds.height)
            let r = NSRect(x: CGFloat(i) * (bar + gap), y: (bounds.height - hh) / 2, width: bar, height: hh)
            (v > 0.02 ? live : quiet).appendRoundedRect(r, xRadius: bar / 2, yRadius: bar / 2)
        }
        NSColor(white: 1, alpha: 0.18).setFill()
        quiet.fill()
        guard !live.isEmpty else { return }
        if let g = gradient, let ctx = NSGraphicsContext.current?.cgContext {
            NSGraphicsContext.saveGraphicsState()
            live.addClip()
            BrandGradient.draw(g, in: bounds, ctx: ctx, .vertical, flipped: true)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            color.setFill()
            live.fill()
        }
    }
}

final class IslandContent: NSView {
    /// Every view of the open content redrawn in full (see Island.frame: the pieces drawn while the clip grew).
    func redrawAll() {
        func mark(_ v: NSView) { v.needsDisplay = true; v.subviews.forEach(mark) }
        mark(self)
    }
    weak var island: Island?
    override var isFlipped: Bool { true }
    var query = ""
    private(set) var fittingHeight: CGFloat = 0
    private(set) var toastWidth: CGFloat = 300
    var preferredWidth: CGFloat {
        guard let i = island else { return Island.openW }
        return i.drawer == nil && i.currentToast.map { !i.open || $0.isQuestion || $0.overOpen } == true ? toastWidth : Island.openW
    }

    /// `locate`: a project whose folder is gone — choosing it asks where the folder is now (never files into it: that
    /// recreated the old folder with a fresh store, and its ids clashed with the moved project's).
    enum Target: Equatable { case project(String), inbox, organize, none, openFolder, more, locate(String) }

    private var rows: [IslandRow] = []
    private var selected: Int?
    private var showAll = false
    // live parts
    private weak var level: Bars?
    private weak var wave: Bars?
    private weak var time: NSTextField?
    private weak var voiceText: NSTextField?
    /// the voice note's Structured chip (tests: its frame)
    private(set) weak var structuredChip: IslandButton?
    private weak var spotted: NSTextField?
    private weak var pauseBtn: IslandButton?
    /// the recording row's ··· (its menu: the pen, a marker, Discard or Restart…)
    private(set) weak var moreBtn: IslandButton?
    /// The pen was latched when the recording row was built (it changes from the key, ⌥D): rebuilt when it differs.
    private var penShown = false
    /// A peck's chevron: "Open" beside it while the pointer is on the island.
    private weak var openHint: OpenHint?

    private func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = ink, mono: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        l.sizeToFit()
        return l
    }

    /// A label that wraps at `width` (at most `lines` lines), sized to what it says.
    private func wrapping(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, width: CGFloat,
                          lines: Int = 3) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.maximumNumberOfLines = lines
        l.lineBreakMode = .byWordWrapping
        l.preferredMaxLayoutWidth = width
        let h = ceil(l.sizeThatFits(NSSize(width: width, height: 400)).height)
        l.frame = NSRect(x: 0, y: 0, width: width, height: h)
        return l
    }

    private func hk(_ a: HotAction) -> String { Hotkeys.shared.label(a) }

    private func tip(_ key: String, _ a: HotAction) -> String {
        let k = hk(a)
        return k.isEmpty ? Loc.t(key, table: "Capture") : Loc.t("capture.island.tip_with_key", table: "Capture", Loc.t(key, table: "Capture"), k)
    }

    // MARK: build

    /// Home and the drawer put their first row beside the notch (in the ears row); the others start under it.
    private(set) var usesRow = false

    /// The ears row: its height, and the room on each side of the notch (the whole width without one).
    private var row: CGFloat { island?.rowHeight ?? 30 }
    /// The open island's first row (home, drawer): the ears row beside a notch; on a capsule, whose top edge shows,
    /// a little taller, so its controls clear the 22 pt corners instead of grazing them.
    private var firstRow: CGFloat { (island?.notchGap ?? 0) > 0 ? row : row + 8 }
    private func side(_ w: CGFloat) -> CGFloat { island.map { $0.notchGap > 0 ? (w - $0.notchGap) / 2 : w / 2 } ?? w / 2 }

    /// The open island's Peep: one view kept across rebuilds (a job's progress, a toast, the review count rebuild the
    /// content often), so its idle — the breath and the blink — runs on instead of starting over at every one.
    private let homePeep: MascotView = {
        let p = MascotView(size: 24, backdrop: .dark)
        p.setAccessibilityElement(false)
        return p
    }()

    /// Peep runs only while the open content can be seen (closed, the content is still there under a 0 alpha), and
    /// waits while the ear's Peep rides over to its spot (`peepHeld`: Island.peepRidesEdge).
    func contentSeen(_ seen: Bool, peepHeld: Bool = false) {
        let hide = !seen || peepHeld
        if homePeep.isHidden != hide { homePeep.isHidden = hide }
    }

    func rebuild() {
        subviews.forEach { if $0 !== homePeep { $0.removeFromSuperview() } }
        rows = []
        selected = nil
        guard let i = island else { return }
        let w = preferredWidth
        var y: CGFloat = 0
        usesRow = false
        if let d = i.drawer {
            usesRow = true
            y = buildDrawer(d, w)
        } else if let t = i.currentToast, !i.open || t.isQuestion || t.overOpen {
            y = t.isQuestion ? buildQuestion(t, top: row) : buildToast(t, w, top: row)
        } else if i.isRecording {
            y = buildRecording(w, top: row)
        } else if VoiceInput.shared.active {
            y = buildVoice(w, top: row)
        } else {
            usesRow = true
            y = buildHome(w)
        }
        if !usesRow || i.drawer != nil { homePeep.removeFromSuperview() }
        fittingHeight = y
    }

    private func place(_ v: NSView, x: CGFloat, y: CGFloat, w: CGFloat? = nil, h: CGFloat? = nil) {
        v.frame = NSRect(x: x, y: y, width: w ?? v.frame.width, height: h ?? v.frame.height)
        addSubview(v)
    }

    /// The project chip, by the open island's Peep: the name alone (Peep stands in the icon column), its text on the rows'
    /// text column — the chip itself starts 13 pt before it (a title-only button's inset), so its hover film has air.
    static let chipX: CGFloat = IslandLayout.textColumn - 13

    private func chip(_ w: CGFloat) -> IslandButton {
        let p = ProjectStore.shared.current
        // one name for nothing chosen: "Unassigned" / 未归类 (the one term everywhere), dimmed
        let name = p?.name ?? Loc.t("capture.island.no_project", table: "Capture")
        // the current project's folder is gone: captures hang as cards meanwhile (Snapper.target) — the chip says so,
        // dimmed, and the switcher it opens offers Locate…
        let gone = p.map { !$0.exists } ?? false
        // a context, not a button-pill: no fill at rest (the white film under the pointer), the name in the island's
        // white; the project's coloured folder is in the switcher it opens and the drop drawer
        let b = IslandButton(title: name, tip: gone ? Loc.t("capture.drawer.missing_sub", table: "Capture")
                                                    : tip("capture.island.switch_project", .project),
                             fg: gone || p == nil ? ink2 : ink) { [weak self] in self?.island?.showSwitcher() }
        b.ghost = true
        b.titleWeight = .medium
        b.setAccessibilityLabel(Loc.t("capture.island.project_ax", table: "Capture", gone ? name + ", " + T("main.sidebar.missing") : name))
        // the name, the chevron after it (a title-only button keeps 8 pt after its name; the chevron wants 22)
        b.setFrameSize(NSSize(width: min(side(w) - 6 - IslandContent.chipX, b.intrinsicContentSize.width + 10), height: 26))
        let chev = NSImageView(image: BlurtIcon.chevronDown.image(size: 11, color: inkAcc, weight: 1.35))
        chev.frame = NSRect(x: b.frame.width - 19, y: 7.5, width: 11, height: 11)
        chev.setAccessibilityElement(false); chev.cell?.setAccessibilityElement(false)      // decoration: the button already says what it does
        b.addSubview(chev)
        return b
    }

    private func buildHome(_ w: CGFloat) -> CGFloat {
        guard let i = island else { return 0 }
        // the ears row: the project on the left of the notch, record / snap / voice on its right — quiet glyphs, a
        // fill only under the pointer; Peep on the rows' icon column, the chip after it
        let row = firstRow
        let rowY = (row - 26) / 2
        // Peep at the row's left end whenever the island is open (BA-17, v1.0.4), on the rows' icon column, facing
        // right as everywhere: which app this is, and the brand — never a second one (the ears are hidden while the
        // island is open; a voice note's open view has its own). The project chip follows it.
        // as the ear's Peep: thinking while captures are organised, so opening the island never changes its mood
        let mood = i.earPeepMood
        homePeep.frame.origin = NSPoint(x: IslandLayout.iconColumn - 12, y: (row - 24) / 2)
        let fresh = homePeep.superview !== self
        if fresh { addSubview(homePeep) }
        if fresh || homePeep.mascot.clip != mood { homePeep.play(mood) }
        place(chip(w), x: IslandContent.chipX, y: rowY)
        // the brand actions in one stroke: record a ring and a dot drawn at the family's weight (the family's record
        // fills a heavy dot), the snap frame, the mic (the mic that starts a voice note is the mic on its card)
        let buttons: [(BlurtIcon?, IslandGlyph?, String, HotAction, () -> Void)] = [
            (nil, .record, "capture.island.record", .toggleRecord, { (NSApp.delegate as? App)?.startRecording(useLast: false) }),
            (.snap, nil, "capture.island.snap", .snap, { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { snapper.hotkey() } }),
            (.mic, nil, "capture.island.voice", .voice, { VoiceInput.shared.toggle() }),
        ]
        var bx = w - 12
        for (ic, dr, key, act, f) in buttons.reversed() {
            let b = IslandButton(icon: ic, tip: tip(key, act)) { [weak i] in i?.setOpen(false); f() }
            b.drawn = dr
            b.ghost = true
            b.setAccessibilityLabel(Loc.t(key, table: "Capture"))
            b.setFrameSize(NSSize(width: 26, height: 26))
            bx -= 26
            place(b, x: bx, y: rowY)
            bx -= 4
        }
        var y = row + 4
        let jobs = i.activeJobs
        for j in jobs {
            // a job at work is a row on the grid: the spinner in the icon column (the sparkle is only ever "Organize"),
            // its title and step on one line, its progress a 2 pt line under the text column — no box round it
            let step = j.steps.last { $0.state == .running } ?? j.steps.last { $0.state != .pending }
            let r = IslandRow(icon: nil, title: IslandContent.jobTitle(j), height: 36) { [weak i] in
                i?.setOpen(false)
                AppEnvironment.mainWindow?.reveal(job: j.id)
            }
            r.status = step.map { Loc.t("job.step.\($0.id)") }
            r.working = true
            r.progress = j.progress ?? step?.progress ?? 0
            r.setAccessibilityLabel([r.title, r.status].compactMap { $0 }.joined(separator: ", "))
            place(r, x: 0, y: y, w: w, h: 36)
            y += 36
        }
        for j in i.sessionsNeedingYou {
            guard let a = j.agent else { continue }
            let st = a.status
            // what it is about first ("Sign-in button does nothing"), then which item, its state and the agent
            let ids = a.windowName?.replacingOccurrences(of: ",", with: ", ")
            let r = IslandRow(icon: nil, title: j.title ?? ids ?? Loc.t("job.type.agent"),
                              subtitle: [j.title == nil ? nil : ids, Loc.t("session.\(st.rawValue)"), AgentNames.name(a.agent)]
                                  .compactMap { $0 }.joined(separator: " · "), height: 44) { [weak i] in
                i?.setOpen(false)
                AppEnvironment.mainWindow?.reveal(job: j.id)
            }
            r.dot = st == .waitingInput ? BrandColor.Island.attn : st == .error ? BrandColor.Island.err
                : st == .running ? BrandColor.Island.fill : BrandColor.Island.ok
            place(r, x: 0, y: y, w: w, h: 44)
            y += 44
        }
        let review = i.toReview, cards = i.cardCount
        if cards > 0 {
            // the cards waiting ("2 cards" — one noun; the Inbox is the row under it), and the view's one filled button,
            // the sparkle: with a current project they are organised into it; with none, into Unassigned, each item
            // with the project the run suggests (one agent run for all). A click on the row brings the cards down.
            let cur = ProjectStore.shared.organizeTarget.flatMap { ProjectStore.shared.project(id: $0) }
            let b = cur.map { p in
                IslandButton(icon: .spark, title: Loc.t("capture.island.organize", table: "Capture"),
                             tip: Loc.t("capture.island.organize_tip", table: "Capture", p.name),
                             gradient: BrandGradient.buttonStops) { snapper.handToAI(project: p.id) }
            } ?? IslandButton(icon: .spark, title: Loc.t("capture.island.organize", table: "Capture"),
                              tip: Loc.plural("capture.island.organize_all_tip", table: "Capture", count: cards),
                              gradient: BrandGradient.buttonStops) { snapper.handToAI() }
            let r = IslandRow(icon: IslandContent.lineIcon(.cards), title: Loc.plural("capture.island.cards_waiting", table: "Capture", count: cards),
                              height: 36) { hanging.reveal(via: "island_row") }
            r.trailingReserve = b.frame.width + 4
            place(r, x: 0, y: y, w: w, h: 36)
            b.frame.origin = NSPoint(x: w - 18 - b.frame.width, y: ((36 - b.frame.height) / 2).rounded())   // the rows' trailing edge
            r.addSubview(b)                    // the row's own button (its wash runs under it, as a hovered list row's does)
            y += 36
        }
        if review > 0 {
            // the Inbox: its name, its count as a quiet accessory, a chevron — the backlog lives here (and in the menu
            // bar), not beside the notch
            let r = IslandRow(icon: IslandContent.lineIcon(.inbox), title: T("main.place.inbox"), height: 36) { [weak i] in
                i?.setOpen(false)
                AppEnvironment.mainWindow?.showInbox()
            }
            r.accessory = Loc.number(review)
            r.disclosure = true
            r.setAccessibilityLabel(T("main.place.inbox") + ", " + Loc.plural("capture.island.to_review", table: "Capture", count: review))
            place(r, x: 0, y: y, w: w, h: 36)
            y += 36
        }
        if jobs.isEmpty && i.sessionsNeedingYou.isEmpty && review == 0 && cards == 0 {
            // nothing going on: what the keys do, on the text column
            let hint = [hkHint(.snap, "capture.island.snap"), hkHint(.voice, "capture.island.voice"), hkHint(.project, "capture.island.switch_project")]
                .compactMap { $0 }.joined(separator: "   ·   ")
            let l = label(hint, size: 11.5, color: ink3)
            place(l, x: IslandLayout.textColumn - 2, y: y + 4, w: w - IslandLayout.textColumn - 16)
            y += 26
        }
        return y + 8
    }

    /// One of our line glyphs as a row's icon: 15 pt on the icon column, in the rows' secondary white (or `color`).
    static func lineIcon(_ ic: BlurtIcon, color: NSColor = ink2) -> NSImage? {
        guard let cg = ic.cgImage(size: 15, scale: 2, color: color.cgColor, weight: 1.1) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 15, height: 15))
    }

    static func jobTitle(_ j: Job) -> String { j.title ?? Loc.t("job.type.\(j.type.rawValue)") }

    // MARK: recording

    /// Finish's red: the tape's `rec` a step deeper, so its white title clears 4.5 : 1 (#D92D20, 4.8 : 1; #FF453A was 3.3).
    static let finishRed = NSColor(srgbRed: 0.851, green: 0.176, blue: 0.125, alpha: 1)

    /// The open island while recording, on one grid: the ears ride out to the open shape's corners (Island.layoutEars:
    /// the time over the pause circle, the right ear's glyph over Finish — as an expanded Live Activity lines its
    /// regions up), and everything below starts and ends `earInset` (14 pt) in:
    ///   ● 0:06                                                  ||||
    ///   (pause) (snap)                                  (···) [■ Finish]
    ///   [⌃] Hold for the pen  [⌃⇧] Box  [⌃⌥] Ellipse  · 2 markers
    /// The secondaries are one control (white 10 % circles); Finish is the one filled thing. Paused, the pause circle
    /// becomes Resume in the same place and size — the play glyph in `attn` on its tint, the lead — and Finish quiets
    /// to the neutral fill with its red stop square, so one coloured thing leads; the ear's amber bars and time and
    /// the dashed frame say "paused" too. The second line only when it has something to say (the pen's state, the
    /// pen hint for the first three takes, what was spotted). The rare things are in the ··· menu: the pen, a marker,
    /// where the take goes (Change…), Discard or Restart… (the question below).
    private func buildRecording(_ w: CGFloat, top: CGFloat) -> CGFloat {
        guard let i = island, let rec = i.rec else { return 0 }
        let y: CGFloat = top + 6
        let inset = IslandLayout.earInset
        moreBtn = nil
        if i.isConfirmingDiscard { return buildDiscardQuestion(rec, w, top: y) }
        let paused = rec.isPaused
        // one family, one weight across the row: our line glyphs (pause / play, the snap frame, more, the stop square)
        let pb = IslandButton(icon: paused ? .play : .pause, tip: tip(paused ? "capture.rec.resume" : "capture.rec.pause", .pause),
                              fill: paused ? BrandColor.Island.attn.withAlphaComponent(0.22) : CaptureGlass.control,
                              fg: paused ? BrandColor.Island.attn : .white) { rec.togglePause() }
        place(pb, x: inset, y: y)
        pauseBtn = pb
        let sb = IslandButton(icon: .snap, tip: Loc.t("capture.rec.snap_note", table: "Capture"), fill: CaptureGlass.control) { [weak i] in
            i?.snapWithNote()
        }
        place(sb, x: pb.frame.maxX + 8, y: y)
        let fin = IslandButton(icon: .stop, title: Loc.t("capture.rec.finish", table: "Capture"), tip: tip("capture.rec.finish_tip", .finish),
                               fill: paused ? NSColor(white: 1, alpha: 0.14) : IslandContent.finishRed) { rec.stop() }      // Stop: the tape
        if paused { fin.iconColor = BrandColor.Island.rec }
        place(fin, x: w - inset - fin.frame.width, y: y + 1)
        let more = IslandButton(icon: .more, tip: Loc.t("capture.rec.more_tip", table: "Capture"), fill: CaptureGlass.control) { [weak self] in
            self?.showRecordingMenu()
        }
        place(more, x: fin.frame.minX - 8 - more.frame.width, y: y)
        moreBtn = more
        level = nil
        var bottom = y + 30

        // the quiet line: the pen's state or its keys (first takes only), then what live.py spotted
        penShown = rec.penSticky
        let lineY = bottom + 10
        var end = inset
        var any = false
        if rec.penSticky {
            let pen = IslandButton(icon: .pencil, title: Loc.t("capture.rec.pen_on", table: "Capture"),
                                   tip: Loc.t("capture.rec.pen_off_tip", table: "Capture"), fill: BrandColor.Island.tint) { rec.togglePen() }
            pen.fg = BrandColor.Island.fill
            pen.setFrameSize(NSSize(width: pen.frame.width, height: 24))
            place(pen, x: inset, y: lineY)
            let k = KeyLine([.key("esc"), .text(Loc.t("capture.rec.pen_off", table: "Capture"))], size: 11.5, color: ink2)
            place(k, x: pen.frame.maxX + 10, y: lineY + (24 - k.frame.height) / 2)
            end = k.frame.maxX
            any = true
        } else if penHintThisTake, !paused, let key = rec.penKey?.1 {
            // every key of the pen as one keycap per chord: the box and the ellipse are the pen key plus one more
            let ell = rec.penKind == .option ? "⌃" : "⌥"
            let h = KeyLine(KeyLine.pairs([(key, Loc.t("capture.rec.pen_hold", table: "Capture")),
                                           (KeyLine.chord(key, "⇧"), Loc.t("capture.rec.pen_box", table: "Capture")),
                                           (KeyLine.chord(key, ell), Loc.t("capture.rec.pen_ellipse", table: "Capture"))]),
                            size: 11.5, color: ink2)
            place(h, x: inset, y: lineY + (24 - h.frame.height) / 2)
            end = h.frame.maxX
            any = true
        }
        let said = spottedText(rec)
        if !said.isEmpty {
            let sp = label(said, size: 11.5, color: ink2)
            place(sp, x: any ? end + 12 : inset - 2, y: lineY + (24 - sp.frame.height) / 2, w: min(sp.frame.width + 8, 200))
            spotted = sp
            any = true
        } else {
            spotted = nil
        }
        if any { bottom = lineY + 24 }
        return bottom + inset
    }

    /// What the take has spotted and marked so far ("3 items spotted · 2 markers").
    private func spottedText(_ rec: Recorder) -> String {
        let n = island?.spottedCount ?? 0, markers = rec.snaps?.markers ?? 0
        return [n > 0 ? Loc.plural("capture.rec.spotted", table: "Capture", count: n) : nil,
                markers > 0 ? Loc.plural("capture.rec.markers", table: "Capture", count: markers) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The ··· menu: the rare things, each with its key as the menu's own right-aligned key equivalent. Dark, as the
    /// island it hangs from (never a pale system menu off the black).
    func showRecordingMenu() {
        guard let rec = island?.rec, let b = moreBtn else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.appearance = NSAppearance(named: .darkAqua)
        let pen = ClosureMenuItem(Loc.t("capture.rec.menu_pen", table: "Capture")) { rec.togglePen() }
        pen.state = rec.penSticky ? .on : .off
        pen.showHotkey(.pen)
        menu.addItem(pen)
        let mark = ClosureMenuItem(Loc.t("capture.rec.menu_marker", table: "Capture")) { rec.marker() }
        mark.showHotkey(.marker)
        menu.addItem(mark)
        if (NSApp.delegate as? App)?.resident == true {      // a recording started from the chat has its session already
            // where the take goes: the project, changeable (the switcher) — a rare change mid-take, so not on the row
            menu.addItem(.separator())
            let p = ProjectStore.shared.current
            let goes = Loc.t("capture.rec.menu_goes_to", table: "Capture", p?.name ?? Loc.t("project.inbox"))
            let item = ClosureMenuItem(goes) { [weak self] in self?.island?.showSwitcher() }
            if let p = p {
                let c = ProjectLook.color(p), bs = ProjectLook.badgeSize(p.key)
                item.image = NSImage(size: bs, flipped: true) { r in ProjectLook.drawBadge(p.key, color: c, in: r); return true }
            } else {
                item.image = NSImage(systemSymbolName: "tray.2", accessibilityDescription: nil)
            }
            item.showHotkey(.project)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(Loc.t("capture.rec.discard_tip", table: "Capture")) { [weak self] in self?.island?.confirmDiscard(true) })
        emit(["event": "rec_menu", "items": menu.items.filter { !$0.isSeparatorItem }.map(\.title),
              "keys": menu.items.filter { !$0.isSeparatorItem }.map { $0.keyEquivalent.isEmpty ? "" : $0.keyEquivalent }])
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.frame.height + 6), in: b)
    }

    /// Discard's question, the way a Mac asks: the question alone on its line (13 semibold, never cut), what goes with
    /// it on a quiet second line, then the answers on the right — Discard furthest from the hand that stops, a neutral
    /// pill with its title in `err` (a destructive answer is never the one that stands out), Restart, and Keep Recording
    /// where Finish was: the default, filled like every suggested answer in the island, its "↩" after it (Island.key).
    /// On the open island's grid: the question at the time's x, the answers ending at Finish's right edge.
    private func buildDiscardQuestion(_ rec: Recorder, _ w: CGFloat, top: CGFloat) -> CGFloat {
        let inset = IslandLayout.earInset
        let q = wrapping(Loc.t("capture.rec.discard_q", table: "Capture"), size: 13, weight: .semibold, color: ink, width: w - 2 * inset + 4)
        place(q, x: inset - 2, y: top + 4)
        var y = q.frame.maxY
        if let lost = IslandContent.discardLost(rec) {
            let l = wrapping(Loc.t("capture.rec.discard_also", table: "Capture", lost), size: 11.5, color: ink2, width: w - 2 * inset + 4, lines: 2)
            place(l, x: inset - 2, y: y + 2)
            y = l.frame.maxY
        }
        y += 12
        let buttons: [IslandButton] = RecordingDiscard.order.map { a in
            switch a {
            case .discard:
                let t = Loc.t("capture.rec.discard", table: "Capture")
                return IslandButton(title: t, tip: t, fill: NSColor(white: 1, alpha: 0.12), fg: BrandColor.Island.err) { rec.stop(discard: true) }
            case .restart:
                let t = Loc.t("capture.rec.restart", table: "Capture")
                return IslandButton(title: t, tip: t, fill: NSColor(white: 1, alpha: 0.12)) { rec.stop(discard: true, restart: true) }
            case .keep:
                let t = Loc.t("capture.rec.keep", table: "Capture")
                let k = IslandButton(title: t, tip: t, gradient: BrandGradient.buttonStops) { [weak island] in island?.confirmDiscard(false) }
                k.key = "↩"
                return k
            }
        }
        var bx = w - inset
        for b in buttons.reversed() {
            bx -= b.frame.width
            place(b, x: bx, y: y)
            bx -= 8
        }
        return y + 28 + inset
    }

    /// What goes with a discarded take, as the island counts it — the snaps and the markers apart (BlurtCore
    /// RecordingDiscard): "2 snaps and 1 marker"; nil when nothing does.
    static func discardLost(_ rec: Recorder) -> String? {
        switch RecordingDiscard.lost(stills: rec.snaps?.stills ?? 0, markers: rec.snaps?.markers ?? 0) {
        case .nothing: return nil
        case let .snaps(n): return Loc.plural("capture.rec.snaps", table: "Capture", count: n)
        case let .markers(m): return Loc.plural("capture.rec.markers", table: "Capture", count: m)
        case let .both(n, m):
            return Loc.t("capture.rec.and", table: "Capture", Loc.plural("capture.rec.snaps", table: "Capture", count: n),
                         Loc.plural("capture.rec.markers", table: "Capture", count: m))
        }
    }

    // MARK: voice input

    /// How the voice note ends, said on the island in the hints' one grammar — key, then verb, as the note bubble and
    /// the picker say it: "⌥V to finish · Esc discard" (the user's key; "Click Done to finish" without one), "Pause
    /// to finish" with record.voice.end_on_pause, "Let go to finish" while held — and in its last minute, the time
    /// left. Not "Listening": the waveform and Peep say that.
    static func voiceHint() -> String {
        let v = VoiceInput.shared
        var s: String
        if v.holding {
            s = Loc.t("capture.voice.hold_hint", table: "Capture")
        } else if v.endsOnPause {
            s = Loc.t("capture.voice.hint", table: "Capture")
        } else if !Hotkeys.shared.label(.voice).isEmpty {
            s = Loc.t("capture.voice.hint_key", table: "Capture", Hotkeys.shared.label(.voice))
        } else {
            s = Loc.t("capture.voice.hint_done", table: "Capture")
        }
        // Esc cancels only in the note's first seconds (VoiceInput.escSeconds): then it is the other apps' again
        if v.escCancels { s += " · " + Loc.t("capture.voice.esc_hint", table: "Capture") }
        // rounded up, so it adds up with the clock in the ear ("0:37" · "0:03 left" on a 40 s limit)
        let left = IslandLayout.timeLeft(limit: v.maxSeconds, elapsed: v.elapsed)
        if v.active, left <= 60 { s += " · " + Loc.t("capture.voice.time_left", table: "Capture", Island.clock(Double(left))) }
        return s
    }

    private func buildVoice(_ w: CGFloat, top: CGFloat) -> CGFloat {
        let v = VoiceInput.shared
        // the body's edges: the ears' mic and clock line up with them (Island.layoutEars), as a live activity's
        let L = IslandLayout.bodyInset, R = w - IslandLayout.bodyInset
        // row 1: Peep listening (eye wide, swelling with the voice), the live waveform — the one focal thing, the one
        // brand colour that moves — and Done (the view's one filled button) on the right edge. With the key held there
        // is no Done: letting go finishes it, and the hint under it says so
        var y: CGFloat = top + 4
        let rowH: CGFloat = 40
        let cs: CGFloat = 32
        let chick = MascotView(size: cs, backdrop: .dark)
        chick.frame.origin = NSPoint(x: L - 3, y: y + (rowH - cs) / 2)      // (Peep has a little air in its square)
        addSubview(chick)
        chick.play(.listening)
        let wx = L - 3 + cs + 8
        // Done: the voice note ends when you say so (v0.8.6) — this button, the key again, or letting go of it
        let done = IslandButton(icon: .check, title: Loc.t("capture.voice.done", table: "Capture"),
                                tip: tip("capture.voice.done_tip", .voice), gradient: BrandGradient.buttonStops) { VoiceInput.shared.toggle() }
        done.isHidden = v.holding
        let we = v.holding ? R : R - done.frame.width - 14
        let wv = Bars(frame: NSRect(x: wx, y: y + (rowH - 28) / 2, width: we - wx, height: 28))
        wv.bar = 3; wv.gap = 2.5                // the gradient across the group (Bars' default)
        wv.track = true                         // one empty mark: the centre line (before audio, and in silence)
        addSubview(wv)
        wave = wv
        place(done, x: R - done.frame.width, y: y + (rowH - done.frame.height) / 2)
        y += rowH + 4
        // row 2: Structured, as dictation's (⇧ alone, or this chip): a quiet chip with the list glyph; on, the tint chip
        // in mint like "Pen on" (click = off) — the only place it shows (the ear keeps the plain clock). Then how it
        // ends, and where it goes, on the right edge in secondary white
        let on = v.structured
        let st = IslandButton(icon: .list, title: Loc.t("capture.voice.structured", table: "Capture"),
                              tip: Loc.t(on ? "capture.voice.structured_off_tip" : "capture.voice.structured_tip", table: "Capture"),
                              fill: on ? BrandColor.Island.tint : NSColor(white: 1, alpha: 0.08)) { VoiceInput.shared.toggleStructured(via: "island") }
        st.fg = on ? BrandColor.Island.fill : ink2
        st.titleWeight = .medium
        st.symbolInset = 10
        st.setFrameSize(NSSize(width: st.intrinsicContentSize.width, height: 24))
        st.setAccessibilityValue(on ? Loc.t("capture.voice.structured_ax_on", table: "Capture") : Loc.t("capture.voice.structured_ax_off", table: "Capture"))
        place(st, x: L, y: y)
        structuredChip = st
        let dest: String
        if let m = ProjectStore.shared.missingCurrent { dest = Loc.t("capture.project.missing_card", table: "Capture", m.name) }
        else if let p = ProjectStore.shared.current { dest = Loc.t("capture.voice.goes_to", table: "Capture", p.name) } else {
            dest = Loc.t("capture.voice.goes_card", table: "Capture")
        }
        let hx = st.frame.maxX + 10
        let tx = label(IslandContent.voiceHint(), size: 12, color: ink2)
        let d = label(dest, size: 12, color: ink2)
        d.alignment = .right
        d.toolTip = dest                       // (cut short when the hint needs the room: the whole of it on hover)
        let room = R - hx
        let hintW = min(tx.frame.width, room)
        let destW = min(d.frame.width, max(0, room - hintW - 14))
        place(tx, x: hx, y: y + (24 - tx.frame.height) / 2, w: hintW)
        voiceText = tx
        // its right edge on the body's (a label's cell keeps 2 pt inside its frame)
        if destW > 40 { place(d, x: R + 2 - destW, y: y + (24 - d.frame.height) / 2, w: destW) }
        y += 24
        return y + 12
    }

    // MARK: the drawer

    private func buildDrawer(_ d: Island.Drawer, _ w: CGFloat) -> CGFloat {
        let store = ProjectStore.shared
        func folder(_ p: Project) -> NSImage? { IslandGlyph.project(p.exists ? ProjectLook.color(p) : ink3).image(size: 15, color: ink) }
        let noProject = IslandGlyph.noProject.image(size: 15, color: ink2)
        // the ears row: the filter field on the left of the notch (a real field: the magnifier on the icon column, the
        // placeholder or what was typed on the text column, the caret after it), what this is across the notch
        let row = firstRow
        let pick = d == .switcher ? island?.pick : nil
        let headText = d == .drop ? Loc.t("capture.drawer.drop_title", table: "Capture")
            : pick?.title ?? Loc.t("capture.drawer.switch_title", table: "Capture")
        let head = label(headText, size: 12, weight: .medium, color: ink3)
        head.alignment = .right
        let hw = min(head.frame.width, side(w) - 24)
        if d == .switcher {
            place(head, x: w - 18 - hw, y: (row - head.frame.height) / 2, w: hw)
            let f = FilterField(text: query, placeholder: Loc.t("capture.drawer.type_to_filter", table: "Capture"),
                                width: side(w) - 8)
            place(f, x: 0, y: ((row - f.frame.height) / 2).rounded())
        } else {
            place(head, x: IslandLayout.textColumn - 2, y: (row - head.frame.height) / 2, w: min(head.frame.width, side(w) - 46))
            head.alignment = .left
        }
        var y = row + 4
        func add(_ r: IslandRow, _ t: Target) {
            r.target = t
            let idx = rows.count
            r.onHover = { [weak self] in self?.select(idx) }
            r.action = { [weak self] in self?.choose(t) }
            r.setAccessibilityRole(.button)
            rows.append(r)
            place(r, x: 0, y: y, w: w, h: r.frame.height)
            y += r.frame.height
        }
        // what is checked: the current project (nil = none), or where the thing being re-filed went
        let checkedID: String? = pick.map { $0.current } ?? (store.currentID ?? "inbox")
        // the rows every project picker shows (ProjectPick.choices): recent projects, then Unassigned last
        let choices = ProjectPick.choices(store.projects, query: query, unassigned: Loc.t("project.inbox"))
        let none = d == .switcher && choices.last == .unassigned
        let matches = choices.compactMap(\.project)
        let shown = query.isEmpty && !showAll ? Array(matches.prefix(8)) : matches
        for p in shown {
            guard p.exists else {
                // its folder is gone (moved, renamed, on a drive that isn't there): said, dimmed, and chosen = Locate…
                // — as the sidebar, the menu bar and Settings show it
                let r = IslandRow(icon: folder(p), title: p.name, subtitle: Loc.t("capture.drawer.missing_sub", table: "Capture"), height: 44)
                r.accessory = p.key
                r.accessoryIsKey = true
                r.checked = d == .switcher && checkedID == p.id
                r.dimmed = true
                add(r, .locate(p.id))
                continue
            }
            // the project's one identity: its folder in its colour (as the home chip shows it)
            let r = IslandRow(icon: folder(p), title: p.name, height: 36)
            r.accessory = p.key
            r.accessoryIsKey = true
            r.checked = d == .switcher && checkedID == p.id
            add(r, .project(p.id))
        }
        if query.isEmpty && !showAll && matches.count > 8 {
            add(IslandRow(icon: IslandContent.lineIcon(.more), title: Loc.t("capture.drawer.more", table: "Capture"), height: 36), .more)
        }
        if store.projects.isEmpty {
            let l = label(Loc.t("capture.drawer.no_projects", table: "Capture"), size: 12, color: ink3)
            place(l, x: IslandLayout.textColumn - 2, y: y + 6, w: w - IslandLayout.textColumn - 16)
            y += 30
        }
        // Unassigned comes last, under a line, in every project picker (this one, the menu bar's, the main
        // window's M popover, a card's Move To ▸): the same place each time
        if d == .switcher && (none || pick == nil) {
            let sep = NSView(frame: NSRect(x: IslandLayout.textColumn, y: y + 4, width: w - IslandLayout.textColumn - 18, height: 1))
            sep.wantsLayer = true
            sep.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
            addSubview(sep)
            y += 9
        }
        if d == .switcher {
            if none {
                // no current project: recordings go to Unassigned until the user picks one — never a guess. Said as the
                // chip says it ("Unassigned", the dashed ring): the tray glyph is only ever the Inbox. What it means is its
                // tooltip (and VoiceOver's hint)
                let r = IslandRow(icon: noProject, title: pick == nil ? Loc.t("capture.island.no_project", table: "Capture") : Loc.t("project.inbox"), height: 36)
                r.toolTip = Loc.t(pick == nil ? "capture.drawer.none_sub" : "capture.drawer.inbox_sub", table: "Capture")
                r.setAccessibilityHelp(r.toolTip)
                r.checked = checkedID == "inbox"
                add(r, .none)
            }
            if pick == nil {
                let r = IslandRow(icon: IslandContent.lineIcon(.folderPlus), title: Loc.t("capture.drawer.add_project", table: "Capture"), height: 36)
                r.accessory = "\u{2318}O"
                add(r, .openFolder)
            }
        } else {
            let un = IslandRow(icon: noProject, title: Loc.t("project.inbox"), height: 36)
            un.toolTip = Loc.t("capture.drawer.inbox_sub", table: "Capture")
            un.setAccessibilityHelp(un.toolTip)
            add(un, .inbox)
            // with no current project: one run for the cards, into Unassigned with a suggested project each
            let n = island?.dropCount ?? 1
            add(IslandRow(icon: IslandContent.lineIcon(.spark, color: BrandColor.Island.fill), title: Loc.t("capture.island.organize", table: "Capture"),
                          subtitle: Loc.plural("capture.drawer.organize_sub", table: "Capture", count: n), height: 44), .organize)
        }
        if d == .switcher { select(rows.firstIndex { $0.checked } ?? 0) }
        return y + 8
    }

    /// Tests: the drawer's rows as shown ("[on] " before the checked one).
    var rowTitles: [String] { rows.map { ($0.checked ? "[on] " : "") + $0.title } }

    private func select(_ i: Int?) {
        selected = i
        for (k, r) in rows.enumerated() { r.selected = k == i }
    }

    /// The drop target under a point (content coordinates), highlighted; nil clears.
    @discardableResult
    func highlight(at p: NSPoint?) -> Target? {
        guard let p = p, let i = rows.firstIndex(where: { $0.frame.contains(p) }), rows[i].target != .more else {
            if p == nil || selected != nil { select(nil) }
            return nil
        }
        if selected != i { select(i) }
        return rows[i].target
    }

    /// A card dropped on a target: that card — or the ⌘-click selection it is part of — goes there (Organize: those
    /// cards, organized into Unassigned with suggestions; from the island itself, every card).
    func perform(_ t: Target, shot: Shot?) {
        let shots = shot.map { hanging.withSelection($0) }
        switch t {
        case .project(let id): if let s = shots { snapper.assign(s, to: id) }
        case .inbox: if let s = shots { snapper.assign(s, to: "inbox") }
        case .organize: snapper.handToAI(shots: shots)
        case .locate(let id):
            // a card dropped on a project whose folder is gone: it stays a card; the island says so and offers Locate…
            // (Snapper.assign refuses it, as every other way into that project)
            if let s = shots { snapper.assign(s, to: id) }
        default: break
        }
    }

    private func choose(_ t: Target) {
        switch t {
        case .more: showAll = true; rebuild(); island?.wake()
        case .openFolder: island?.closeSwitcher(); IslandContent.openFolder()
        case .none, .project:
            let id: String? = { if case .project(let i) = t { return i }; return nil }()
            if let p = island?.pick {
                // the pick form: file that one thing there; the current project stays as it is
                island?.closeSwitcher()
                island?.setOpen(false)
                return p.choose(id ?? "inbox")
            }
            island?.closeSwitcher()
            island?.setOpen(false)
            Task {
                do { try await ProjectStore.shared.use(id) } catch { await MainActor.run { appDelegate?.toast(T("main.project.use_failed")) } }
                await MainActor.run { island?.projectChanged() }
            }
        case .inbox, .organize:
            perform(t, shot: nil)
        case .locate(let id):
            guard let p = ProjectStore.shared.project(id: id) else { return }
            let pick = island?.pick
            island?.closeSwitcher()
            island?.setOpen(false)
            emit(["event": "island_missing_project", "project": id, "via": pick == nil ? "switch" : "pick"])
            // found again: the pick form files its one thing there, the switcher makes it current
            MissingFolder.locate(p) { found in
                if let pick = pick { pick.choose(found.id); return }
                Task {
                    do { try await ProjectStore.shared.use(found.id) } catch { await MainActor.run { appDelegate?.toast(T("main.project.use_failed")) } }
                    await MainActor.run { Island.shared.projectChanged() }
                }
            }
        }
    }

    static func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = Loc.t("capture.drawer.open_prompt", table: "Capture")
        panel.message = Loc.t("capture.drawer.open_message", table: "Capture")
        activateApp()
        guard panel.runModal() == .OK, let u = panel.url else { return }
        Task {
            do {
                let p = try await ProjectStore.shared.open(folder: u)
                try await ProjectStore.shared.use(p.id)
                await MainActor.run { Island.shared.projectChanged() }
            } catch {
                await MainActor.run { Island.shared.toast(Loc.t("capture.drawer.open_failed", table: "Capture"), actionTitle: nil, action: nil) }
            }
        }
    }

    func key(_ e: NSEvent) -> Bool {
        switch Int(e.keyCode) {
        case 53: island?.closeSwitcher(); return true                                     // Esc
        case 125: select(min(rows.count - 1, (selected ?? -1) + 1)); return true           // ↓
        case 126: select(max(0, (selected ?? rows.count) - 1)); return true                // ↑
        case 36, 76: if let i = selected, i < rows.count, let t = rows[i].target { choose(t) }; return true
        case 51:                                                                           // ⌫
            if !query.isEmpty { query.removeLast(); rebuild(); island?.wake() }
            return true
        default: break
        }
        if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "o", island?.pick == nil { choose(.openFolder); return true }
        if let c = e.characters, !c.isEmpty, !e.modifierFlags.contains(.command), !e.modifierFlags.contains(.control),
           c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            query += c
            rebuild()
            select(rows.isEmpty ? nil : rows.firstIndex { if case .project = $0.target { return true }; return false } ?? 0)
            island?.wake()
            return true
        }
        return false
    }

    // MARK: toast

    /// A toast's line: what it says, then — after the first " · " — the detail, in secondary white (one line, two
    /// weights: "Recording saved · 0:42", "Copied, not sent · paste with ⌘V").
    static func toastLine(_ s: String) -> NSAttributedString {
        let a = NSMutableAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: ink])
        if let r = s.range(of: " · ") {
            a.addAttributes([.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ink2], range: NSRange(r.lowerBound..<s.endIndex, in: s))
        }
        return a
    }

    /// The mark a toast leads with when it names none: Peep's glyph at rest, quiet — Blurt telling you something.
    static func toastDefaultMark(_ color: NSColor) -> NSImage { MenuGlyph.tinted(color, size: 15) }

    private func buildToast(_ t: Island.Toast, _ w: CGFloat, top: CGFloat) -> CGFloat {
        // one component, one layout: the leading slot (always filled) centred on the icon column, the headline (13
        // medium) and a detail line (11.5, secondary white) on the text column, an optional quiet pill on the right
        let parts = t.text.components(separatedBy: "\n")
        var headline = parts[0]
        var detail = parts.count > 1 ? parts[1...].joined(separator: " · ") : nil
        // a passive line still at work ("Organizing 4 captures…"): the spinner in the slot says "at work", the text says
        // what — no trailing dots to be read as text cut short
        let working = t.passive && t.action == nil && headline.hasSuffix("…")
        if working { headline = String(headline.dropLast()) }
        // a detail line still at work ("Organizing it into items…" under "Recording saved"): a small spinner before it,
        // the headline keeps its own mark
        var detailWorking = false
        if let d = detail, d.hasSuffix("…") { detail = String(d.dropLast()); detailWorking = true }
        // the label's own fitted width (its cell has an inset): at the string's measured width the field ended in "…"
        // (the Claude Code fallback notice read "…organizing with Codex inste…")
        let l = label(headline, size: 13, weight: .medium)
        l.attributedStringValue = IslandContent.toastLine(headline)
        l.sizeToFit()
        let dl = detail.map { label($0, size: 11.5, color: ink2) }
        let detailLead: CGFloat = t.detailMark != nil || detailWorking ? 15 : 0
        let tw = ceil(l.frame.width)
        let textW = max(tw, ceil(dl?.frame.width ?? 0) + detailLead)
        var btn: IslandButton?
        if let a = t.actionTitle, let act = t.action {
            // a toast's action is never the gradient: Undo takes a step back, the others move on from a line the user
            // didn't ask for — a quiet pill (the gradient stays for the open island's primary and a question's answer)
            btn = IslandButton.quiet(a) { [weak self] in
                act(); self?.island?.dismissToast()
            }
        }
        // a line with no button that is its own button (a peck's "open the item"): a chevron where a button would be,
        // "Open" beside it while the pointer is on the island
        let opens = btn == nil && t.action != nil && t.art != nil
        let hint = opens ? OpenHint() : nil
        // the text column; a done line's Peep (it hops) gets 8 pt more room
        let textX = IslandLayout.textColumn + (t.art == nil ? 0 : 8)
        let fit = IslandLayout.toast(text: textW, lead: textX - IslandLayout.toastInset, button: hint?.frame.width ?? btn?.frame.width,
                                     floor: island?.toastFloor ?? IslandLayout.capsuleToastWidth, maxWidth: Island.openW,
                                     buttonGap: 16)
        toastWidth = fit.width
        // too long for one line at the open width: the text wraps (up to three lines; the row grows a line for each)
        // instead of "Couldn't snap — macOS needs Screen Recording allo…"; the mark keeps to its first line
        var text: NSTextField = l
        var textH = l.frame.height
        var lines = 1
        if fit.wraps, l.frame.width > fit.textWidth + 0.5 {
            let wl = wrapping(headline, size: 13, weight: .medium, color: ink, width: fit.textWidth,
                              lines: detail == nil ? IslandLayout.toastMaxLines : 2)
            wl.attributedStringValue = IslandContent.toastLine(headline)
            wl.cell?.truncatesLastVisibleLine = true
            lines = IslandLayout.toastLines(wrapped: wl.frame.height, line: l.frame.height)
            textH = min(wl.frame.height, l.frame.height + CGFloat(lines - 1) * IslandLayout.toastLineHeight + 2)
            text = wl
        }
        var detailH: CGFloat = 0
        var detailField = dl
        if let d = dl {
            let room = fit.textWidth - detailLead
            if d.frame.width > room + 0.5, let s = detail {
                let wd = wrapping(s, size: 11.5, color: ink2, width: room, lines: 2)
                wd.cell?.truncatesLastVisibleLine = true
                detailField = wd
                detailH = wd.frame.height
                if wd.frame.height > d.frame.height + 4 { lines += 1 }
            } else {
                detailH = d.frame.height
            }
            lines += 1
        }
        let rowH = IslandLayout.toastHeight(lines: lines)
        // the text block (headline, then the detail 1 pt under it) centred in the row; the mark on the headline's first
        // line, Peep on the whole block, the button on the row
        let blockH = textH + (detailField == nil ? 0 : 1 + detailH)
        let rowMid = top + rowH / 2
        let textTop = (rowMid - blockH / 2).rounded()
        let mid = textTop + l.frame.height / 2
        let ic = IslandLayout.iconColumn
        if let art = t.art {
            // Peep in the slot: its square from 12 pt in, its hop clear of the text
            let z: CGFloat = 28
            art.frame = NSRect(x: 12, y: (rowMid - z / 2).rounded() - 1, width: z, height: z)
            addSubview(art)
        } else if working {
            addSubview(IslandSpinner(frame: NSRect(x: ic - 6.5, y: (mid - 6.5).rounded(), width: 13, height: 13)))
        } else {
            // done = the ok check, needs you = the attention triangle (never colour alone: each has its shape), a
            // filing = the project's folder in its colour, anything else Peep's quiet glyph — one 15 pt slot
            let (mark, color): (BlurtIcon?, NSColor) = {
                switch t.icon {
                case .check?: return (.check, BrandColor.Island.ok)
                case .warning?: return (.warning, BrandColor.Island.attn)
                case let i?: return (i, ink2)
                case nil: return (nil, ink2)
                }
            }()
            let im = t.badge.flatMap { IslandGlyph.project($0.color).image(size: 15, color: ink) }
                ?? mark.map { $0.image(size: 15, color: color, weight: $0 == .check ? 1.35 : 1.15) }
                ?? IslandContent.toastDefaultMark(color)
            place(NSImageView(image: im), x: ic - 7.5, y: (mid - 7.5).rounded(), w: 15, h: 15)
        }
        // (a label draws 2 pt inside its frame: its first letter on the text column, as a row's)
        place(text, x: textX - 2, y: textTop, w: fit.textWidth + 4, h: textH)
        if let d = detailField {
            var dx = textX
            let dmid = (textTop + textH + 1 + min(detailH, 15) / 2).rounded()
            if detailWorking {
                addSubview(IslandSpinner(frame: NSRect(x: dx + 0.5, y: dmid - 5, width: 10, height: 10)))
                dx += detailLead
            } else if let m = t.detailMark {
                // the state in shape and colour, the same marks as a toast's slot: ✓ done, ⚠ to verify
                let im = m.icon.image(size: 11, color: m.color, weight: 1.4)
                place(NSImageView(image: im), x: dx, y: dmid - 5.5, w: 11, h: 11)
                dx += detailLead
            }
            place(d, x: dx - 2, y: textTop + textH + 1, w: min(d.frame.width, fit.textWidth + 4 - (dx - textX)), h: detailH)
        }
        if let b = btn, let bx = fit.buttonX { place(b, x: bx, y: (rowMid - b.frame.height / 2).rounded()) }
        if let h = hint, let bx = fit.buttonX {
            place(h, x: bx, y: (rowMid - h.frame.height / 2).rounded())
            openHint = h
            h.hover = island?.pointerInside ?? false
        }
        return top + rowH
    }

    /// A question (Island.ask): the text, wrapped, then the two answers on the right — the suggested one filled.
    private func buildQuestion(_ t: Island.Toast, top: CGFloat) -> CGFloat {
        let w = Island.openW
        toastWidth = w
        let l = NSTextField(wrappingLabelWithString: t.text)
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.textColor = ink
        l.preferredMaxLayoutWidth = w - 40
        let h = ceil(l.sizeThatFits(NSSize(width: w - 40, height: 200)).height)
        place(l, x: 20, y: top + 10, w: w - 40, h: h)
        var y = top + 10 + h + 10
        if let quote = t.quote {
            let q = NSTextField(wrappingLabelWithString: quote)
            q.font = .systemFont(ofSize: 13)
            q.textColor = ink2
            q.maximumNumberOfLines = 3
            q.cell?.truncatesLastVisibleLine = true      // wraps, and the third line ends with "…" (DictationKeptText)
            q.preferredMaxLayoutWidth = w - 40
            let qh = ceil(q.sizeThatFits(NSSize(width: w - 40, height: 200)).height)
            place(q, x: 20, y: y - 6, w: w - 40, h: qh)
            y += qh + 4
        }
        var bx = w - 16
        for (title, act, filled) in [(t.secondTitle, t.second, false), (t.actionTitle, t.action, true)].reversed() {
            guard let title = title, let act = act else { continue }
            let b = IslandButton(symbol: "", title: title, tip: title, fill: NSColor(white: 1, alpha: 0.14),
                                 gradient: filled ? BrandGradient.buttonStops : nil) {
                [weak self] in self?.island?.dismissToast(); act()
            }
            bx -= b.frame.width
            place(b, x: bx, y: y)
            bx -= 8
        }
        y += 28 + 14
        return y
    }

    // MARK: live values

    func tick(_ now: CFTimeInterval) {
        guard let i = island, i.open || i.currentToast != nil else { return }
        openHint?.hover = i.pointerInside
        if let rec = i.rec, rec.sessionStart.isValid {
            time?.stringValue = Island.clock(rec.elapsed())
            level?.values = [Float](repeating: rec.isPaused ? 0 : rec.micLevel, count: 1).flatMap { v in (0..<5).map { k in Float(k + 1) / 6 <= v ? Float(0.35 + 0.13 * Double(k)) : 0 } }
            // the quiet line comes (or goes) with what it says: rebuilt when that starts or stops, else just updated
            let said = spottedText(rec)
            if pauseBtn != nil, (pauseBtn?.icon == .play) != rec.isPaused || penShown != rec.penSticky || (spotted == nil) != said.isEmpty {
                rebuild()
            } else if let sp = spotted, sp.stringValue != said {
                sp.stringValue = said
                sp.frame.size.width = min(ceil(sp.intrinsicContentSize.width) + 8, 200)
            }
        } else if VoiceInput.shared.active {
            wave?.values = VoiceInput.shared.levels
            time?.stringValue = Island.clock(VoiceInput.shared.elapsed)
            let hint = IslandContent.voiceHint()
            if voiceText?.stringValue != hint { voiceText?.stringValue = hint; voiceText?.toolTip = hint }
        }
    }
}

/// A passive toast's "still at work": a quarter arc turning once every 1.1 s, in the island's secondary white (still
/// with Reduce Motion — the arc alone says it). Layers only, like the island's buttons.
final class IslandSpinner: NSView {
    private let arc = CAShapeLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let track = CAShapeLayer()
        let r = bounds.insetBy(dx: 1, dy: 1)
        track.path = CGPath(ellipseIn: r, transform: nil)
        track.fillColor = nil
        track.strokeColor = NSColor(white: 1, alpha: 0.16).cgColor
        track.lineWidth = 1.6
        arc.path = CGPath(ellipseIn: r, transform: nil)
        arc.fillColor = nil
        arc.strokeColor = NSColor(white: 1, alpha: 0.7).cgColor
        arc.lineWidth = 1.6
        arc.lineCap = .round
        arc.strokeEnd = 0.28
        arc.frame = bounds
        layer?.addSublayer(track)
        layer?.addSublayer(arc)
        setAccessibilityElement(false)
        guard !reduceMotion else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 1.1
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "spin")
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A peck's way in: the line chevron at 45 %, and "Open" (60 %) beside it while the pointer is on the island — the
/// toast is its own button, and says so when pointed at. Its width is kept either way, so nothing moves.
final class OpenHint: NSView {
    private let word = NSTextField(labelWithString: Loc.t("capture.peck.open", table: "Capture"))
    var hover = false { didSet { if hover != oldValue { word.isHidden = !hover } } }
    init() {
        word.font = .systemFont(ofSize: 11.5, weight: .medium)
        word.textColor = ink2
        word.sizeToFit()
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(word.frame.width) + 2 + 13, height: 18))
        word.frame.origin = NSPoint(x: 0, y: (18 - word.frame.height) / 2)
        word.isHidden = true
        addSubview(word)
        let chev = NSImageView(image: BlurtIcon.chevronRight.image(size: 13, color: inkAcc, weight: 1.35))
        chev.frame = NSRect(x: frame.width - 13, y: 2.5, width: 13, height: 13)
        addSubview(chev)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
}

/// The switcher's filter, a real field in the ears row: the magnifier on the icon column, the placeholder (tertiary)
/// or what was typed (white) on the text column, and the caret after it — typing filters, and the field says so
/// before the first key. Drawn by the island (the panel takes the keys: IslandContent.key).
final class FilterField: NSView {
    init(text: String, placeholder: String, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 20))
        let mag = NSImageView(image: BlurtIcon.search.image(size: 15, color: ink2, weight: 1.1))
        mag.frame = NSRect(x: IslandLayout.iconColumn - 7.5, y: 2.5, width: 15, height: 15)
        addSubview(mag)
        let tx = IslandLayout.textColumn
        let l = NSTextField(labelWithString: text.isEmpty ? placeholder : text)
        l.font = .systemFont(ofSize: 13, weight: text.isEmpty ? .regular : .medium)
        l.textColor = text.isEmpty ? ink3 : ink
        l.lineBreakMode = .byTruncatingHead
        l.sizeToFit()
        let lw = min(ceil(l.frame.width), width - tx - 6)
        // the caret where the next letter goes: after the typed text, before the placeholder
        let caretX = text.isEmpty ? tx : tx + lw - 2
        l.frame = NSRect(x: text.isEmpty ? tx + 1 : tx - 2, y: (20 - l.frame.height) / 2, width: lw, height: l.frame.height)
        addSubview(l)
        let caret = NSView(frame: NSRect(x: caretX, y: 2, width: 1.5, height: 16))
        caret.wantsLayer = true
        caret.layer?.backgroundColor = BrandColor.Island.fill.cgColor        // the island's caret: flat mint, as live text's
        caret.layer?.cornerRadius = 0.75
        addSubview(caret)
        if !reduceMotion {
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [1, 1, 0, 0]
            blink.keyTimes = [0, 0.5, 0.55, 1]
            blink.duration = 1.06
            blink.repeatCount = .infinity
            caret.layer?.add(blink, forKey: "blink")
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.textField)
        setAccessibilityLabel(placeholder)
        setAccessibilityValue(text)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
}
