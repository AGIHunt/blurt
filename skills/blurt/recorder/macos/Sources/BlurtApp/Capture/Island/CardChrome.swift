// The cards' small shared parts (v0.9.2, docs/design/system.md §3.2) — one family for the hanging row's hover note, the
// cards overview and Recently Dragged Out, so the same thing never looks two ways:
//   • CardTime: one relative time ("Just now", "1 min ago" / "刚刚", "1 分钟前"), never a live count of seconds.
//   • KeyHint: the keys as drawn keycaps with one verb each ("← → Choose · ↩ Copy · ⌫ Delete · esc Close") — the
//     row's hover note and both panels' footers use the same items and the same words.
//   • CardActions: a card's actions in one cluster, [··· chip][Copy chip], the same order, size and "···" everywhere;
//     shown on hover and on keyboard focus only.
//   • PanelHeader: a panel's one header row — its title left-aligned (13 semibold) with the count in secondary, an
//     accessory on the right ("Kept for 7 days", "···") and a real × that closes it (never a grey traffic light that
//     reads as an inactive window).

import AppKit
import BlurtCore

enum CardTime {
    /// "Just now" · "4 min ago" · "2 hr ago" · "Yesterday" · "3 days ago" (zh: "刚刚" · "4 分钟前" …, spaced numbers).
    static func ago(_ wall: Double, now: Double = Snapper.now) -> String {
        switch CardAgo.of(now - wall) {
        case .justNow: return Loc.t("capture.time.just_now", table: "Capture")
        case .minutes(let n): return Loc.plural("capture.time.minutes_ago", table: "Capture", count: n)
        case .hours(let n): return Loc.plural("capture.time.hours_ago", table: "Capture", count: n)
        case .yesterday: return Loc.t("capture.time.yesterday", table: "Capture")
        case .days(let n): return Loc.plural("capture.time.days_ago", table: "Capture", count: n)
        }
    }
}

/// Keys as small keycaps, each run of caps followed by its verb.
enum KeyHint {
    typealias Item = (keys: [String], verb: String)

    /// The cards' keys (the row with the keyboard, the overview with the keyboard): the same words in both.
    static var cards: [Item] {
        [(["←", "→"], Loc.t("capture.keys.choose", table: "Capture")), (["↩"], Loc.t("capture.keys.copy", table: "Capture")),
         (["⌫"], Loc.t("capture.keys.delete", table: "Capture")), (["esc"], Loc.t("capture.keys.close", table: "Capture"))]
    }

    static let capFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    static let verbFont = NSFont.systemFont(ofSize: 11)
    static let capH: CGFloat = 17, capPad: CGFloat = 4.5, capGap: CGFloat = 3, verbGap: CGFloat = 5, itemGap: CGFloat = 12

    private static func capW(_ k: String) -> CGFloat {
        max(capH, ceil((k as NSString).size(withAttributes: [.font: capFont]).width) + capPad * 2)
    }

    static func size(_ items: [Item]) -> CGSize {
        var w: CGFloat = 0
        for (i, it) in items.enumerated() {
            if i > 0 { w += itemGap }
            w += it.keys.map(capW).reduce(0, +) + capGap * CGFloat(max(0, it.keys.count - 1))
            w += verbGap + ceil((it.verb as NSString).size(withAttributes: [.font: verbFont]).width)
        }
        return CGSize(width: ceil(w), height: capH)
    }

    /// Draws into the current NSGraphicsContext (y up), the caps from `origin`.
    static func draw(_ items: [Item], at origin: CGPoint, ink: NSColor, cap: NSColor) {
        var x = origin.x
        let y = origin.y
        for (i, it) in items.enumerated() {
            if i > 0 { x += itemGap }
            for (j, k) in it.keys.enumerated() {
                if j > 0 { x += capGap }
                let w = capW(k)
                let r = NSRect(x: x, y: y, width: w, height: capH)
                cap.setFill()
                NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
                let a: [NSAttributedString.Key: Any] = [.font: capFont, .foregroundColor: ink]
                let sz = (k as NSString).size(withAttributes: a)
                (k as NSString).draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2 + 0.5), withAttributes: a)
                x += w
            }
            x += verbGap
            let va: [NSAttributedString.Key: Any] = [.font: verbFont, .foregroundColor: ink]
            let vs = (it.verb as NSString).size(withAttributes: va)
            (it.verb as NSString).draw(at: NSPoint(x: x, y: y + (capH - vs.height) / 2 + 0.5), withAttributes: va)
            x += ceil(vs.width)
        }
    }

    /// The hint as an image (the hover note is drawn in layers), in light or dark ink.
    static func image(_ items: [Item], dark: Bool) -> CGImage? {
        let sz = size(items)
        return renderImage(sz) { ctx in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            draw(items, at: .zero, ink: dark ? NSColor(white: 1, alpha: 0.55) : NSColor(white: 0, alpha: 0.5),
                 cap: dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.07))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static func label(_ items: [Item]) -> String { items.map { $0.keys.joined(separator: " ") + " " + $0.verb }.joined(separator: " · ") }
}

/// A keycap hint as a view (the panels' footers).
final class KeyHintView: NSView {
    var items: [KeyHint.Item] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
            setAccessibilityLabel(KeyHint.label(items))
        }
    }
    override var intrinsicContentSize: NSSize { KeyHint.size(items) }
    override func draw(_ dirtyRect: NSRect) {
        KeyHint.draw(items, at: CGPoint(x: 0, y: (bounds.height - KeyHint.capH) / 2), ink: .secondaryLabelColor, cap: .quaternaryLabelColor)
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
}

/// One small chip button: a solid surface with a hairline (it reads on a picture and on a row's wash alike), a glyph
/// or a short word in ink; pressed / pointed at, a little darker.
final class CardChip: ClosureButton {
    static let height: CGFloat = 24
    private var over = false { didSet { needsDisplay = true } }
    private var word: String?

    /// A round chip with a symbol ("···").
    static func symbol(_ name: String, label: String) -> CardChip {
        let b = CardChip("", {})
        b.image = Look.symbol(name, label, size: 11, weight: .bold)
        b.imagePosition = .imageOnly
        b.toolTip = label
        b.setAccessibilityLabel(label)
        b.setup(width: height)
        return b
    }

    /// A capsule chip with a word ("Copy").
    static func text(_ title: String, _ fn: @escaping () -> Void) -> CardChip {
        let b = CardChip("", fn)
        b.word = title
        b.setAccessibilityLabel(title)
        let w = ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width) + 22
        b.setup(width: w)
        return b
    }

    private func setup(width: CGFloat) {
        isBordered = false
        title = ""
        contentTintColor = .secondaryLabelColor
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: CardChip.height).isActive = true
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(calibratedWhite: 0.2, alpha: 1) : NSColor(calibratedWhite: 1, alpha: 1)).setFill()
        p.fill()
        if over || isHighlighted { NSColor(white: dark ? 1 : 0, alpha: dark ? 0.1 : 0.06).setFill(); p.fill() }
        NSColor(white: dark ? 1 : 0, alpha: dark ? 0.16 : 0.12).setStroke()
        p.lineWidth = 0.5
        p.stroke()
        if let w = word {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor]
            let sz = (w as NSString).size(withAttributes: a)
            (w as NSString).draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2), withAttributes: a)
        } else if let img = image {
            let tinted = img.copy() as! NSImage      // swiftlint:disable:this force_cast
            tinted.lockFocus()
            NSColor.labelColor.withAlphaComponent(0.8).set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: NSRect(x: bounds.midX - img.size.width / 2, y: bounds.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { over = true }
    override func mouseExited(with event: NSEvent) { over = false }
}

/// A card's actions, one cluster everywhere: [··· chip][Copy chip] — "···" opens `menu()`, Copy runs `copy`.
final class CardActions: NSStackView {
    let more: CardChip
    let copy: CardChip

    init(menu: @escaping () -> NSMenu?, copy run: @escaping () -> Void) {
        let moreTitle = Loc.t("capture.taken.more", table: "Capture")
        more = CardChip.symbol("ellipsis", label: moreTitle)
        copy = CardChip.text(Loc.t("capture.taken.copy", table: "Capture"), run)
        super.init(frame: .zero)
        more.set { [weak more] in
            guard let b = more, let m = menu() else { return }
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 3), in: b)
        }
        orientation = .horizontal
        spacing = 6
        addArrangedSubview(more)
        addArrangedSubview(copy)
        setHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A panel's header row: the title (left, 13 semibold) and its count (secondary), an accessory on the right, then ×.
final class PanelHeader: NSView {
    static let height: CGFloat = 40
    let title = NSTextField(labelWithString: "")
    let count = NSTextField(labelWithString: "")
    let close: NSButton

    init(title t: String, accessory: NSView?, close fn: @escaping () -> Void) {
        close = PanelCloseButton.make(fn)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        title.stringValue = t
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        count.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        count.textColor = .secondaryLabelColor
        let head = NSStackView(views: [title, count])
        head.spacing = 6
        var views: [NSView] = [head, close]
        if let a = accessory { views.insert(a, at: 1) }
        for v in views { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        var cs = [
            heightAnchor.constraint(equalToConstant: PanelHeader.height),
            head.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            head.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 22), close.heightAnchor.constraint(equalToConstant: 22),
        ]
        if let a = accessory {
            cs += [a.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8), a.centerYAnchor.constraint(equalTo: centerYAnchor),
                   a.leadingAnchor.constraint(greaterThanOrEqualTo: head.trailingAnchor, constant: 12)]
        }
        NSLayoutConstraint.activate(cs)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The header's ×: a ghost circle — the glyph in secondary ink, a quiet fill under the pointer. Always enabled.
final class PanelCloseButton: ClosureButton {
    private var over = false { didSet { needsDisplay = true } }

    static func make(_ fn: @escaping () -> Void) -> PanelCloseButton {
        let label = Loc.t("capture.panel.close", table: "Capture")
        let b = PanelCloseButton("", fn)
        b.image = Look.symbol("xmark", label, size: 10, weight: .semibold)
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.toolTip = label
        b.setAccessibilityLabel(label)
        b.setAccessibilitySubrole(.closeButton)
        return b
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if over || isHighlighted {
            NSColor(white: dark ? 1 : 0, alpha: isHighlighted ? 0.14 : 0.08).setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        guard let img = image else { return }
        let t = img.copy() as! NSImage      // swiftlint:disable:this force_cast
        t.lockFocus()
        (over ? NSColor.labelColor : NSColor.secondaryLabelColor).set()
        NSRect(origin: .zero, size: t.size).fill(using: .sourceAtop)
        t.unlockFocus()
        t.draw(in: NSRect(x: bounds.midX - img.size.width / 2, y: bounds.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { over = true }
    override func mouseExited(with event: NSEvent) { over = false }
    override var mouseDownCanMoveWindow: Bool { false }
}
