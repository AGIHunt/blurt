// The island, open (Island.swift draws the shape): what is under the ears row.
//
//   home        the current project (click = switch) · record / snap / voice (our line glyphs: the island's buttons
//               and ears are one family — BlurtIcon; the drawer's list rows keep SF Symbols, like any Mac list) · up to 3 jobs in progress (step,
//               progress) · agent sessions that need you (click = their terminal) · "5 to review" · "Organize" the
//               waiting cards (into the current project; with none, into Unassigned with a suggested project each)
//   recording   on one grid with the ears (they ride out to the open shape's corners, 14 pt in): pause (paused: the
//               same circle, Resume's play glyph in amber — nothing moves) · snap + note (pauses) … ··· · Finish (the one
//               filled thing; paused, a neutral pill with its red stop square, so Resume leads); the ··· menu (dark,
//               keys right-aligned) holds the rare things: the pen (⌥⇧D), a marker (⌥⇧M), where the take goes
//               (Change…), Discard or Restart… (asks first: the question alone on its line, what goes with it — the
//               snaps and the markers apart — on a quiet second line, then Discard · Restart · Keep Recording ↩, the
//               last where Finish was, so nothing destructive lands under the hand that stops). Then, only when it has
//               something to say, one quiet line: "Pen on" (a tint chip) + "[esc] Pen off", or (first three takes)
//               "[⌃] Hold for the pen  [⌃⇧] Box  [⌃⌥] Ellipse" (a keycap per chord) · how many items were spotted
//   voice       the listening chick (mascot), the live waveform, Done, the Structured chip (list glyph; on = the mint
//               tint chip, as "Pen on"; ⇧ alone does the same), how it ends ("press ⌥⇧V again to finish · Esc to
//               discard"; "pause to finish" with record.voice.end_on_pause; the time left in its last minute), where it
//               will go — the words themselves hang under the island (LiveTranscript.swift)
//   drawer      switcher (⌥⇧O): Unassigned (no current project; tray.2, as in the sidebar — the tray is the Inbox),
//               recent projects (≤ 8, "More…", type to filter; a project whose folder is gone shows so, dimmed, and
//               choosing it asks where the folder is now instead of making it current: MissingFolder.locate —
//               ProjectPick), Open Folder… ⌘O. Its pick form (Island.Pick: "Filed to X · Change") has the same rows and
//               files that one thing instead of changing the current project.
//               drop (a card dragged in, or a ⌘-click selection of them): recent projects, Unassigned, Organize
//               ↑↓ select · ↩ choose · Esc close; the target under the pointer / selection: ×1.02 on the island's mint tint
//   toast       one quiet line (K4), optionally with art (the mascot: done, fixed), the ok check and an action — spanning
//               the whole shape (IslandLayout.toast): text 18 pt in, the button under the right ear's number, a lone
//               line centred; a line too long for the open width wraps (up to three lines), never "…" mid-word
// Dark on black in both appearances (it is the notch); white text at 92 / 60 / 40 %.

import AppKit
import BlurtCore

private let ink = NSColor(white: 1, alpha: 0.92)
private let ink2 = NSColor(white: 1, alpha: 0.6)
private let ink3 = NSColor(white: 1, alpha: 0.38)

/// A control on the island: a round icon button, or a pill with a title. The island's primary actions ("Hand to AI",
/// AI sort, Done, a question's suggested answer) take `gradient` (BrandGradient.buttonStops) with a white title: hover is
/// a white film (×1.04), pressed a black one (×0.92). `fg`: the title and symbol colour.
/// Composed of layers (wantsUpdateLayer), never drawn: while the island grows, AppKit draws a drawn view piece by piece
/// as the clip uncovers it, and the seams of those pieces showed as dark scanlines and stair-step ghosts through the
/// gradient (dogfood: 排成清单 / Undo / 在访达中显示 for most of the grow animation). Layers are whole at every frame.
/// The title is a picture of the line drawn with font smoothing (BlurtCore TextImage), not a CATextLayer: a text layer
/// draws without smoothing, and the semibold title came out ~20 % lighter than the drawn button's.
final class IslandButton: NSView {
    var action: () -> Void
    var symbol: String { didSet { needsDisplay = true } }
    /// One of our line glyphs in place of an SF Symbol (the island's own buttons: record, snap, mic, pause, trash, stop).
    var icon: BlurtIcon? { didSet { needsDisplay = true } }
    var title: String? { didSet { needsDisplay = true } }
    var fill: NSColor? { didSet { needsDisplay = true } }
    var gradient: [(UInt32, CGFloat)]? { didSet { needsDisplay = true } }
    var fg: NSColor = .white { didSet { needsDisplay = true } }
    /// The glyph's own colour when it differs from the title's (paused Finish: the red stop square, a white title).
    var glyphColor: NSColor? { didSet { needsDisplay = true } }
    /// The key that does the same, after the title in the title's colour at 60 % ("Keep Recording  ↩"): every default
    /// answer on the capture surfaces carries its ↩, as the picker's primary does.
    var key: String? { didSet { setFrameSize(intrinsicContentSize); needsDisplay = true } }
    var tip: String
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

    static let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let keyFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private var keyWidth: CGFloat { key.map { ceil(($0 as NSString).size(withAttributes: [.font: IslandButton.keyFont]).width) + 7 } ?? 0 }
    /// No implicit animations on the parts: a state change is instant (no cross-fade of one title over another).
    static let noActions: [String: CAAction] = ["contents": NSNull(), "string": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                                "hidden": NSNull(), "backgroundColor": NSNull(), "colors": NSNull(),
                                                "frame": NSNull(), "foregroundColor": NSNull(), "locations": NSNull(),
                                                "startPoint": NSNull(), "endPoint": NSNull()]

    override var intrinsicContentSize: NSSize {
        guard let t = title else { return NSSize(width: 30, height: 30) }
        let tw = (t as NSString).size(withAttributes: [.font: IslandButton.titleFont]).width
        if let b = badge { return NSSize(width: ceil(tw) + ProjectLook.badgeSize(b.text).width + Self.badgeInset + 7 + 13, height: 28) }
        return NSSize(width: ceil(tw) + keyWidth + (hasGlyph ? 30 + symbolInset : 26), height: 28)
    }
    private var hasGlyph: Bool { icon != nil || !symbol.isEmpty }
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
            l.backgroundColor = c.cgColor
            film.backgroundColor = nil
        }
        film.frame = b
        var x: CGFloat = title == nil ? 0 : symbolInset
        iconLayer.isHidden = true
        // our glyph: 15 pt alone in a round button, 14 beside a title (docs/design/system.md §2.6), the family's line
        let glyph = icon.flatMap { ic -> CGImage? in
            ic.cgImage(size: title == nil ? 15 : 14, scale: 2, color: (glyphColor ?? fg).cgColor, weight: title == nil ? 1.1 : 1.2)
        } ?? (symbol.isEmpty ? nil : symbolImage(symbol, size: 12, weight: .semibold, color: glyphColor ?? fg))
        if let img = glyph {
            let s = CGSize(width: CGFloat(img.width) / 2, height: CGFloat(img.height) / 2)
            let ix = title == nil ? (b.width - s.width) / 2 : x
            iconLayer.contents = img
            iconLayer.contentsScale = 2
            iconLayer.frame = CGRect(x: ix.rounded(), y: ((b.height - s.height) / 2).rounded(), width: s.width, height: s.height)
            iconLayer.isHidden = false
            x = ix + s.width + 6
        }
        titleLayer.isHidden = title == nil
        badgeLayer.isHidden = badge == nil
        keyLayer.isHidden = key == nil || title == nil
        if let t = title {
            let attrs: [NSAttributedString.Key: Any] = [.font: IslandButton.titleFont]
            var tx = hasGlyph ? x : 13
            var room = b.width - tx - 8 - keyWidth
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
            let shown = name == t ? t : name + "…"
            // the line as AppKit draws it (smoothed: its full weight), measured from the picture itself so it centres
            if let line = TextImage.line(shown, font: IslandButton.titleFont, color: fg.cgColor, scale: scale) {
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

/// A row: icon, title (+ subtitle), an accessory on the right, an optional progress line. Hover / selection wash.
final class IslandRow: NSView {
    var icon: NSImage?
    var title: String
    var subtitle: String?
    var accessory: String?
    var accessoryIsKey = false
    var checked = false
    var progress: Double?
    var dot: NSColor?
    /// Not available as it is (a project whose folder is gone): the title in the island's secondary white.
    var dimmed = false
    var action: (() -> Void)?
    var selected = false { didSet { if selected != oldValue { needsDisplay = true; animateScale() } } }
    var onHover: (() -> Void)?
    var target: IslandContent.Target?

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

    private func animateScale() {
        guard let l = layer else { return }
        let s: CGFloat = selected && !reduceMotion ? 1.02 : 1
        l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        l.position = CGPoint(x: frame.midX, y: frame.midY)
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduceMotion ? 0 : 0.14)
        l.transform = CATransform3DMakeScale(s, s, 1)
        CATransaction.commit()
    }

    override func draw(_ dirty: NSRect) {
        if selected {
            BrandColor.Island.tint.setFill()                     // brand.tint, island value (mint @ 20 %)
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 9, yRadius: 9).fill()
        }
        var x: CGFloat = 18
        if let d = dot {
            d.setFill()
            NSBezierPath(ovalIn: NSRect(x: x + 3, y: bounds.midY - 4, width: 8, height: 8)).fill()
            x += 24
        } else if let im = icon {
            let s = im.size
            im.draw(in: NSRect(x: x + (16 - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += 26
        }
        var right = bounds.width - 18
        if checked, let c = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .bold).applying(.init(paletteColors: [BrandColor.Island.fill]))) {
            right -= c.size.width
            c.draw(in: NSRect(x: right, y: (bounds.height - c.size.height) / 2, width: c.size.width, height: c.size.height))
            right -= 10
        }
        if let a = accessory {
            let f = accessoryIsKey ? NSFont.systemFont(ofSize: 10.5, weight: .semibold) : NSFont.systemFont(ofSize: 11.5)
            let s = NSAttributedString(string: a, attributes: [.font: f, .foregroundColor: ink2])
            let sz = s.size()
            if accessoryIsKey {
                let r = NSRect(x: right - sz.width - 10, y: (bounds.height - 18) / 2, width: sz.width + 10, height: 18)
                NSColor(white: 1, alpha: 0.22).setStroke()
                let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
                p.lineWidth = 1
                p.stroke()
                s.draw(at: NSPoint(x: r.minX + 5, y: r.midY - sz.height / 2))
                right = r.minX - 10
            } else {
                s.draw(at: NSPoint(x: right - sz.width, y: (bounds.height - sz.height) / 2))
                right -= sz.width + 10
            }
        }
        let tf = NSFont.systemFont(ofSize: 13, weight: .medium)
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byTruncatingTail
        let t = NSAttributedString(string: title, attributes: [.font: tf, .foregroundColor: dimmed ? ink2 : ink, .paragraphStyle: ps])
        if let sub = subtitle {
            let st = NSAttributedString(string: sub, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: ink2, .paragraphStyle: ps])
            t.draw(in: NSRect(x: x, y: bounds.midY - 17, width: right - x, height: 17))
            st.draw(in: NSRect(x: x, y: bounds.midY + 1, width: right - x, height: 15))
        } else {
            t.draw(in: NSRect(x: x, y: (bounds.height - 17) / 2, width: right - x, height: 17))
        }
        if let p = progress {
            let track = NSRect(x: x, y: bounds.height - 4, width: bounds.width - x - 18, height: 2)
            NSColor(white: 1, alpha: 0.12).setFill()
            NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
            BrandColor.Island.fill.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * CGFloat(min(1, max(0, p))), height: 2), xRadius: 1, yRadius: 1).fill()
        }
    }
}

/// Bars that follow a level (recording: the mic) or a history (voice input: a scrolling waveform). The live bars are one
/// vertical base gradient across the whole group (gradient.vertical: each bar shows the slice at its height); quiet
/// ones are a faint white. `gradient` nil: flat `color`.
final class Bars: NSView {
    var values: [Float] = [] { didSet { needsDisplay = true } }
    var gradient: [(UInt32, CGFloat)]? = BrandGradient.linearStops
    var color: NSColor = BrandColor.Island.fill
    var bar: CGFloat = 3, gap: CGFloat = 2.5
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        let n = max(1, Int((bounds.width + gap) / (bar + gap)))
        let vals = Array(values.suffix(n))
        let pad = n - vals.count
        let live = NSBezierPath(), quiet = NSBezierPath()
        for i in 0..<n {
            let v = i < pad ? 0 : CGFloat(vals[i - pad])
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
    /// The pen was latched when the recording row was built (it changes from the key, ⌥⇧D): rebuilt when it differs.
    private var penShown = false

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

    func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
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
        fittingHeight = y
    }

    private func place(_ v: NSView, x: CGFloat, y: CGFloat, w: CGFloat? = nil, h: CGFloat? = nil) {
        v.frame = NSRect(x: x, y: y, width: w ?? v.frame.width, height: h ?? v.frame.height)
        addSubview(v)
    }

    private func chip(_ w: CGFloat, small: Bool = false) -> IslandButton {
        let p = ProjectStore.shared.current
        let name = p?.name ?? Loc.t("project.inbox")
        // the current project's folder is gone: captures hang as cards meanwhile (Snapper.target) — the chip says so,
        // dimmed with the folder-and-question-mark, and the switcher it opens offers Locate…
        let gone = p.map { !$0.exists } ?? false
        let b = IslandButton(symbol: gone ? "questionmark.folder" : p == nil ? "tray.2" : "", title: name,
                             tip: gone ? Loc.t("capture.drawer.missing_sub", table: "Capture")
                                       : tip("capture.island.switch_project", .project),
                             fg: gone ? NSColor(white: 1, alpha: 0.6) : .white) { [weak self] in self?.island?.showSwitcher() }
        // every capture with a note goes to the current project: its key in its colour leads, so it reads at a glance
        if gone {
            b.fill = NSColor(white: 1, alpha: 0.1)
            b.symbolInset = IslandButton.badgeInset + 2
        } else if let p = p {
            let c = ProjectLook.color(p)
            b.fill = c.withAlphaComponent(0.26)
            b.badge = (p.key, c)
        } else {
            b.fill = NSColor(white: 1, alpha: 0.1)
            b.symbolInset = IslandButton.badgeInset + 2     // the tray where the key badge would start (its glyph has air)
        }
        b.setAccessibilityLabel(Loc.t("capture.island.project_ax", table: "Capture", gone ? name + ", " + T("main.sidebar.missing") : name))
        let maxW = small ? 200 : max(110, side(w) - 14)
        b.setFrameSize(NSSize(width: min(maxW, b.intrinsicContentSize.width + 14), height: 26))
        let chev = NSImageView(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold).applying(.init(paletteColors: [ink2])))!)
        chev.frame = NSRect(x: b.frame.width - 18, y: 8, width: 10, height: 10)
        chev.setAccessibilityElement(false); chev.cell?.setAccessibilityElement(false)      // decoration: the button already says what it does
        b.addSubview(chev)
        return b
    }

    private func buildHome(_ w: CGFloat) -> CGFloat {
        guard let i = island else { return 0 }
        // the ears row: the project on the left of the notch, record / snap / voice on its right
        let row = firstRow
        let rowY = (row - 26) / 2
        let c = chip(w)
        place(c, x: 12, y: rowY)
        // the brand actions in our own glyphs, one line weight (the mic that starts a voice note is the mic on its card)
        let buttons: [(BlurtIcon, String, HotAction, () -> Void)] = [
            (.record, "capture.island.record", .toggleRecord, { (NSApp.delegate as? App)?.startRecording(useLast: false) }),
            (.snap, "capture.island.snap", .snap, { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { snapper.hotkey() } }),
            (.mic, "capture.island.voice", .voice, { VoiceInput.shared.toggle() }),
        ]
        var bx = w - 12
        for (ic, key, act, f) in buttons.reversed() {
            let b = IslandButton(icon: ic, tip: tip(key, act)) { [weak i] in i?.setOpen(false); f() }
            b.setFrameSize(NSSize(width: 26, height: 26))
            bx -= 26
            place(b, x: bx, y: rowY)
            bx -= 6
        }
        var y = row + 4
        let jobs = i.activeJobs
        if !jobs.isEmpty { y += 4 }
        for j in jobs {
            let step = j.steps.last { $0.state == .running } ?? j.steps.last { $0.state != .pending }
            let r = IslandRow(icon: IslandContent.jobIcon(j.type), title: IslandContent.jobTitle(j),
                              subtitle: step.map { Loc.t("job.step.\($0.id)") }, height: 42) { [weak i] in
                i?.setOpen(false)
                AppEnvironment.mainWindow?.reveal(job: j.id)
            }
            r.progress = j.progress ?? step?.progress
            place(r, x: 0, y: y, w: w, h: 42)
            if j.type == .process {
                // AI is working on the hand-off / sort: one static 1 pt hairline round its row (with the row's progress)
                let g = WorkingOutline(frame: r.frame.insetBy(dx: 6, dy: 1))
                g.cornerRadius = 9
                g.island = true
                addSubview(g, positioned: .above, relativeTo: r)
                g.isHidden = false
                g.alphaValue = 1
            }
            y += 42
        }
        for j in i.sessionsNeedingYou {
            guard let a = j.agent else { continue }
            let st = a.status
            // what it is about first ("Sign-in button does nothing"), then which item, its state and the agent
            let ids = a.windowName?.replacingOccurrences(of: ",", with: ", ")
            let r = IslandRow(icon: nil, title: j.title ?? ids ?? Loc.t("job.type.agent"),
                              subtitle: [j.title == nil ? nil : ids, Loc.t("session.\(st.rawValue)"), AgentNames.name(a.agent)]
                                  .compactMap { $0 }.joined(separator: " · "), height: 40) { [weak i] in
                i?.setOpen(false)
                AppEnvironment.mainWindow?.reveal(job: j.id)
            }
            r.dot = st == .waitingInput ? BrandColor.Island.attn : st == .error ? BrandColor.Island.err
                : st == .running ? BrandColor.Island.fill : BrandColor.Island.ok
            place(r, x: 0, y: y, w: w, h: 40)
            y += 40
        }
        let review = i.toReview, cards = i.cardCount
        if review > 0 || cards > 0 {
            let sep = NSView(frame: NSRect(x: 18, y: y + 4, width: w - 36, height: 1))
            sep.wantsLayer = true
            sep.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
            addSubview(sep)
            y += 9
            if review > 0 {
                let r = IslandRow(icon: NSImage(systemSymbolName: "tray.full", accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium).applying(.init(paletteColors: [ink2]))),
                                  title: Loc.plural("capture.island.to_review", table: "Capture", count: review), height: 36) { [weak i] in
                    i?.setOpen(false)
                    AppEnvironment.mainWindow?.showInbox()
                }
                r.accessory = ""
                place(r, x: 0, y: y, w: cards > 0 ? w - 150 : w, h: 36)
            }
            if cards > 0 {
                // with a current project the cards are organised into it; with none, into Unassigned, each item with
                // the project the run suggests (the user moves it with a click). Either way one agent run for all.
                let cur = ProjectStore.shared.organizeTarget.flatMap { ProjectStore.shared.project(id: $0) }
                let b = cur.map { p in
                    IslandButton(symbol: "sparkles", title: Loc.t("capture.island.organize", table: "Capture"),
                                 tip: Loc.t("capture.island.organize_tip", table: "Capture", p.name),
                                 gradient: BrandGradient.buttonStops) { snapper.handToAI(project: p.id) }
                } ?? IslandButton(symbol: "sparkles", title: Loc.t("capture.island.organize", table: "Capture"),
                                  tip: Loc.plural("capture.island.organize_all_tip", table: "Capture", count: cards),
                                  gradient: BrandGradient.buttonStops) { snapper.handToAI() }
                place(b, x: w - 14 - b.frame.width, y: y + 4)
                if review == 0 {
                    let l = label(Loc.plural("capture.island.cards_waiting", table: "Capture", count: cards), size: 12.5, color: ink2)
                    place(l, x: 20, y: y + 9)
                }
            }
            y += 36
        }
        if jobs.isEmpty && i.sessionsNeedingYou.isEmpty && review == 0 && cards == 0 {
            // nothing going on: what the keys do
            let hint = [hkHint(.snap, "capture.island.snap"), hkHint(.voice, "capture.island.voice"), hkHint(.project, "capture.island.switch_project")]
                .compactMap { $0 }.joined(separator: "   ·   ")
            let l = label(hint, size: 11.5, color: ink3)
            l.alignment = .center
            place(l, x: 16, y: y + 2, w: w - 32)
            y += 22
        }
        return y + 8
    }

    static func jobIcon(_ t: JobType) -> NSImage? {
        let sym: String
        switch t {
        case .record: sym = "record.circle"
        case .snap: sym = "camera.viewfinder"
        case .voice: sym = "mic"
        case .process: sym = "sparkles"
        case .route: sym = "arrow.triangle.branch"
        case .agent: sym = "terminal"
        }
        return NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium).applying(.init(paletteColors: [ink2])))
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
        if paused { fin.glyphColor = BrandColor.Island.rec }
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
    /// the picker say it: "Listening · ⌥⇧V done · Esc discard" (the user's key; "click Done" without one), "pause to
    /// finish" with record.voice.end_on_pause, "let go to finish" while held — and in its last minute, the time left.
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
        var y: CGFloat = top + 8
        // the chick listens (head tilted, sound arcs) beside the live waveform
        let chick = MascotView(size: 56, backdrop: .dark)
        chick.frame.origin = NSPoint(x: 8, y: y - 13)
        addSubview(chick)
        chick.play(.listening)
        let wx: CGFloat = 8 + 56 + 4
        // Done: the voice note ends when you say so (v0.8.6) — this button, the key again, or letting go of it
        let done = IslandButton(icon: .check, title: Loc.t("capture.voice.done", table: "Capture"),
                                tip: tip("capture.voice.done_tip", .voice), gradient: BrandGradient.buttonStops) { VoiceInput.shared.toggle() }
        done.isHidden = v.holding
        let wv = Bars(frame: NSRect(x: wx, y: y, width: w - wx - 18 - (v.holding ? 0 : done.frame.width + 12), height: 34))
        wv.bar = 3; wv.gap = 2.5                // the gradient across the group (Bars' default)
        addSubview(wv)
        wave = wv
        place(done, x: w - 16 - done.frame.width, y: y + (34 - done.frame.height) / 2)
        y += 44
        // Structured, as dictation's (⇧ alone, or this chip): a quiet chip with the list glyph; on, the tint chip in
        // mint like "Pen on" (click = off). Then how it ends — the words themselves show under the island (LiveTranscript)
        let on = v.structured
        let st = IslandButton(icon: .list, title: Loc.t("capture.voice.structured", table: "Capture"),
                              tip: Loc.t(on ? "capture.voice.structured_off_tip" : "capture.voice.structured_tip", table: "Capture"),
                              fill: on ? BrandColor.Island.tint : NSColor(white: 1, alpha: 0.08)) { VoiceInput.shared.toggleStructured(via: "island") }
        st.fg = on ? BrandColor.Island.fill : ink2
        st.symbolInset = 10
        st.setFrameSize(NSSize(width: st.frame.width, height: 24))
        st.setAccessibilityValue(on ? Loc.t("capture.voice.structured_ax_on", table: "Capture") : Loc.t("capture.voice.structured_ax_off", table: "Capture"))
        // a row of its own under the chick's feet (the chick stands 56 pt tall from 13 pt above the waveform)
        y += 2
        place(st, x: 12, y: y)
        structuredChip = st
        let hx = st.frame.maxX + 10
        let tx = label(IslandContent.voiceHint(), size: 12.5, color: ink2)
        place(tx, x: hx, y: y + (24 - tx.frame.height) / 2, w: w - hx - 18)
        voiceText = tx
        y += 30
        let dest: String
        if let m = ProjectStore.shared.missingCurrent { dest = Loc.t("capture.project.missing_card", table: "Capture", m.name) }
        else if let p = ProjectStore.shared.current { dest = Loc.t("capture.voice.goes_to", table: "Capture", p.name) } else {
            dest = Loc.t("capture.voice.goes_card", table: "Capture")
        }
        let d = label(dest, size: 11.5, color: ink3)
        place(d, x: 18, y: y, w: w - 36)
        return y + 26
    }

    // MARK: the drawer

    private func buildDrawer(_ d: Island.Drawer, _ w: CGFloat) -> CGFloat {
        let store = ProjectStore.shared
        func ic(_ s: String, _ c: NSColor = ink2) -> NSImage? {
            NSImage(systemSymbolName: s, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium).applying(.init(paletteColors: [c])))
        }
        // the ears row: what this is on the left of the notch, the filter typed so far on its right
        let row = firstRow
        let pick = d == .switcher ? island?.pick : nil
        let headText = d == .drop ? Loc.t("capture.drawer.drop_title", table: "Capture")
            : pick?.title ?? Loc.t("capture.drawer.switch_title", table: "Capture")
        let head = label(headText, size: 11, weight: .semibold, color: ink3)
        place(head, x: 20, y: (row - head.frame.height) / 2, w: min(head.frame.width, side(w) - 26))
        if !query.isEmpty {
            let q = label("\u{201C}\(query)\u{201D}", size: 12, weight: .medium, color: BrandColor.Island.fill)
            q.alignment = .right
            place(q, x: w - 20 - min(q.frame.width, side(w) - 26), y: (row - q.frame.height) / 2, w: min(q.frame.width, side(w) - 26))
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
                let r = IslandRow(icon: ic("questionmark.folder", ink3), title: p.name,
                                  subtitle: Loc.t("capture.drawer.missing_sub", table: "Capture"), height: 44)
                r.accessory = p.key
                r.accessoryIsKey = true
                r.checked = d == .switcher && checkedID == p.id
                r.dimmed = true
                add(r, .locate(p.id))
                continue
            }
            let r = IslandRow(icon: ic("folder.fill", ProjectLook.color(p)), title: p.name, height: 36)     // the project's colour
            r.accessory = p.key
            r.accessoryIsKey = true
            r.checked = d == .switcher && checkedID == p.id
            add(r, .project(p.id))
        }
        if query.isEmpty && !showAll && matches.count > 8 {
            add(IslandRow(icon: ic("ellipsis"), title: Loc.t("capture.drawer.more", table: "Capture"), height: 34), .more)
        }
        if store.projects.isEmpty {
            let l = label(Loc.t("capture.drawer.no_projects", table: "Capture"), size: 12, color: ink3)
            place(l, x: 20, y: y + 6, w: w - 40)
            y += 30
        }
        // Unassigned comes last, under a line, in every project picker (this one, the menu bar's, the main window's
        // M popover, a card's Move To ▸): the same place each time
        if d == .switcher && (none || pick == nil) {
            let sep = NSView(frame: NSRect(x: 18, y: y + 4, width: w - 36, height: 1))
            sep.wantsLayer = true
            sep.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
            addSubview(sep)
            y += 9
        }
        if d == .switcher {
            if none {
                // no current project: recordings go to Unassigned until the user picks one — never a guess
                // Unassigned is tray.2 everywhere (the sidebar, the palette, the menu bar): the tray is the Inbox
                let r = IslandRow(icon: ic("tray.2"), title: Loc.t("project.inbox"),
                                  subtitle: Loc.t(pick == nil ? "capture.drawer.none_sub" : "capture.drawer.inbox_sub", table: "Capture"), height: 44)
                r.checked = checkedID == "inbox"
                add(r, .none)
            }
            if pick == nil {
                let r = IslandRow(icon: ic("folder.badge.plus"), title: Loc.t("project.open_folder"), height: 36)
                r.accessory = "\u{2318}O"
                add(r, .openFolder)
            }
        } else {
            add(IslandRow(icon: ic("tray.2"), title: Loc.t("project.inbox"), subtitle: Loc.t("capture.drawer.inbox_sub", table: "Capture"), height: 44), .inbox)
            // with no current project: one run for the cards, into Unassigned with a suggested project each
            let n = island?.dropCount ?? 1
            add(IslandRow(icon: ic("sparkles", BrandColor.Island.fill), title: Loc.t("capture.island.organize", table: "Capture"),
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

    private func buildToast(_ t: Island.Toast, _ w: CGFloat, top: CGFloat) -> CGFloat {
        // the label's own fitted width (its cell has an inset): at the string's measured width the field ended in "…"
        // (the Claude Code fallback notice read "…organizing with Codex inste…")
        let l = label(t.text, size: 13, weight: .medium)
        let tw = ceil(l.frame.width)
        // what goes before the text: the chick (from the left edge), a done check, a project's key badge
        var lead: CGFloat = t.art == nil ? 0 : 64
        let iconW: CGFloat = 18, iconGap: CGFloat = 6
        if t.icon != nil { lead += iconW + iconGap }
        let badgeSize = t.badge.map { ProjectLook.badgeSize($0.text, height: 18) }
        if let s = badgeSize { lead += s.width + 8 }
        var btn: IslandButton?
        if let a = t.actionTitle, let act = t.action {
            btn = IslandButton(symbol: "", title: a, tip: a, gradient: BrandGradient.buttonStops) { [weak self] in
                act(); self?.island?.dismissToast()
            }
        }
        // the content spans the whole shape (IslandLayout.toast): text 18 pt in, the button under the right ear's
        // number, a line with nothing beside it centred
        let fit = IslandLayout.toast(text: tw, lead: lead, art: t.art != nil, button: btn?.frame.width,
                                     floor: island?.toastFloor ?? IslandLayout.capsuleToastWidth, maxWidth: Island.openW)
        toastWidth = fit.width
        // too long for one line at the open width: the text wraps (up to three lines; the row grows a line for each)
        // instead of "Couldn't snap — macOS needs Screen Recording allo…"; the icon and badge keep to its first line
        var text: NSTextField = l
        var rowH: CGFloat = 46
        var textH = l.frame.height
        if fit.wraps {
            let wl = wrapping(t.text, size: 13, weight: .medium, color: ink, width: fit.textWidth, lines: IslandLayout.toastMaxLines)
            wl.cell?.truncatesLastVisibleLine = true
            let lines = IslandLayout.toastLines(wrapped: wl.frame.height, line: l.frame.height)
            rowH = IslandLayout.toastHeight(lines: lines)
            textH = min(wl.frame.height, l.frame.height + CGFloat(lines - 1) * IslandLayout.toastLineHeight + 2)
            text = wl
        }
        // text, icon, key badge and button share one centre line (the row is 46 high; a wrapped line's first line)
        let rowMid = top + rowH / 2
        let textTop = (rowMid - textH / 2).rounded()
        let mid = fit.wraps ? textTop + l.frame.height / 2 : rowMid
        var x = fit.leadX
        if let art = t.art {
            art.frame = NSRect(x: 10, y: top - 9, width: 50, height: 50)   // the chick's foot sits on the text's baseline
            addSubview(art)
            x = 64
        }
        if let i = t.icon {
            let im = NSImageView(image: i.symbolImage(pointSize: 13, weight: .semibold))
            im.contentTintColor = i == .check ? BrandColor.Island.ok : ink
            place(im, x: x, y: (mid - iconW / 2).rounded(), w: iconW, h: iconW)
            x += iconW + iconGap
        }
        if let b = t.badge, let s = badgeSize {
            place(BadgeView(text: b.text, color: b.color), x: x, y: (mid - s.height / 2).rounded(), w: s.width, h: s.height)
            x += s.width + 8
        }
        place(text, x: x, y: textTop, w: fit.textWidth, h: textH)
        if let b = btn, let bx = fit.buttonX { place(b, x: bx, y: (rowMid - b.frame.height / 2).rounded()) }
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
        var bx = w - 16
        var y = top + 10 + h + 10
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
            if voiceText?.stringValue != hint { voiceText?.stringValue = hint }
        }
    }
}
