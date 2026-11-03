// The note bubble's type chip (the founder, 2026-10-31), next to the place chip in the footer and in the same look
// (ProjectChip.paint): what this snap is — 问题 / 想法 / 笔记 / 待办, the item kinds (BlurtCore NoteKind). Optional:
// unset it reads "Type" with a tag in secondary ink (undecided: the organizing run decides, as before) — not the dashed
// ring, which is Unassigned's mark for the place next to it (the founder read the two as one thing); set,
// the kind's own icon and name (KindStyle, the main window's). A click opens its list under it, in the bubble, on the
// place list's grid: the four kinds, then "Not set" under a hairline; each row says its key (⌘1–⌘4, ⌘0) — the one place
// the keys are shown (the footer is full). ↑↓ move, ↩ picks, Esc / Tab go back to the note (BlurtCore NoteKeys); the
// keyboard stays in the note's field, so typing goes on there (the list closes).
import AppKit
import BlurtCore

/// "◌ Type ⌃⌄" / "🐞 Issue ⌃⌄": a borderless pop-up, the place chip's twin.
final class KindChip: NSButton {
    var onClick: (() -> Void)?
    private(set) var kind: NoteKind?
    /// its list is open (the chip stays pressed)
    var open = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    convenience init(_ click: @escaping () -> Void) {
        self.init(frame: NSRect(x: 0, y: 0, width: 80, height: ProjectChip.height))
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        onClick = click
        target = self
        action = #selector(fire)
        setAccessibilityRole(.popUpButton)
        set(nil)
    }
    @objc private func fire() { onClick?() }

    /// The kind's name (the main window's: "Issue" / "问题"), or "Type" while it is not set.
    var label: String { kind.map(KindChip.name) ?? Loc.t("capture.note.kind_chip", table: "Capture") }

    static func name(_ k: NoteKind) -> String { Loc.t("kind.\(k.rawValue)") }

    func set(_ k: NoteKind?) {
        kind = k
        title = label
        setFrameSize(NSSize(width: ProjectChip.width(label), height: ProjectChip.height))
        setAccessibilityLabel(Loc.t("capture.note.kind_ax", table: "Capture",
                                    k.map(KindChip.name) ?? Loc.t("capture.note.kind_none", table: "Capture")))
        setAccessibilityValue(label)
        toolTip = Loc.t("capture.note.kind_tip", table: "Capture")
        needsDisplay = true
    }

    /// The kind's icon in its colour (the main window's list), or a tag in secondary ink for "not set" (never the dashed
    /// ring: that is Unassigned's, the place chip's, right beside it).
    static func glyph(_ k: NoteKind?) -> NSImage? {
        guard let k = k else {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.labelColor.withAlphaComponent(0.62)]))
            return NSImage(systemSymbolName: "tag", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        }
        return KindStyle.image(k.rawValue, size: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    /// Tests: the pointer on the chip.
    func testHover(_ on: Bool) { hovering = on }

    override func draw(_ dirty: NSRect) {
        ProjectChip.paint(bounds, glyph: KindChip.glyph(kind), label: label, ink: hovering || open ? .labelColor : .secondaryLabelColor,
                          fill: hovering || isHighlighted || open, pressed: open || isHighlighted)
    }
}

/// The type chip's list, inside the bubble under the footer: a hairline, the four kinds, a hairline, "Not set". No
/// filter (four rows): the note's field keeps the keyboard and the bubble passes ↑↓ ↩ here (NoteKeys).
final class KindPickView: NSView {
    /// nil = not set
    let rows: [NoteKind?] = NoteKind.allCases.map { Optional($0) } + [nil]
    private(set) var selected = 0
    private var rowViews: [KindRow] = []
    /// the snap's type now (its row carries the check)
    var current: NoteKind?
    var onPick: ((NoteKind?) -> Void)?
    static let top: CGFloat = 5
    override var isFlipped: Bool { true }

    var height: CGFloat { KindPickView.top + CGFloat(rows.count) * ProjectPickView.rowH + ProjectPickView.gap + 4 }

    /// the width its longest row needs (the bubble widens to it, up to its cap)
    var wantWidth: CGFloat {
        ceil(ProjectPickView.textX + (rowViews.map(\.textWidth).max() ?? 0) + KindRow.trailing + ProjectPickView.inset)
    }

    /// The row the snap's type is on now ("Not set" when there is none): the cursor opens there.
    var currentIndex: Int { rows.firstIndex { $0 == current } ?? rows.count - 1 }

    func reload() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = rows.enumerated().map { i, k in
            let r = KindRow(kind: k, checked: k == current)
            r.lineAbove = k == nil
            r.onClick = { [weak self] in self?.pick(i) }
            r.onHover = { [weak self] in self?.select(i) }
            addSubview(r)
            return r
        }
        layoutRows()
    }

    func layoutRows() {
        var y = KindPickView.top
        for (k, r) in rowViews.enumerated() {
            let h = ProjectPickView.rowH + (r.lineAbove ? ProjectPickView.gap : 0)
            r.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            r.selected = k == selected
            y += h
        }
    }

    override func layout() { super.layout(); layoutRows() }

    override func draw(_ dirty: NSRect) {
        // one hairline over the list (it hangs from the footer), on the 12 pt grid — the place list's
        NSColor.separatorColor.setFill()
        let px = 1 / (window?.backingScaleFactor ?? 2)
        let i = ProjectPickView.inset
        NSRect(x: i, y: 0, width: bounds.width - 2 * i, height: px).fill()
    }

    func select(_ i: Int) {
        selected = (i + rows.count) % rows.count
        for (k, r) in rowViews.enumerated() { r.selected = k == selected }
    }

    func pick(_ i: Int? = nil) {
        let k = i ?? selected
        guard rows.indices.contains(k) else { return }
        onPick?(rows[k])
    }
}

/// One row of the type list, on the place list's grid: the kind's icon in the 16 pt column (the dashed ring for "Not
/// set"), its name in 13 pt ("Not set" adds what that means), then a check on the current one and its key, quiet,
/// at the trailing edge — as a menu shows its keys.
final class KindRow: NSView {
    let kind: NoteKind?
    let checked: Bool
    var lineAbove = false
    var selected = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    /// the check and the key: kept on every row, so the names line up
    static let trailing: CGFloat = 16 + 6 + 26
    override var isFlipped: Bool { true }

    init(kind: NoteKind?, checked: Bool) {
        self.kind = kind
        self.checked = checked
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(kind == nil ? title + ", " + Loc.t("capture.note.kind_none_caption", table: "Capture") : title)
        setAccessibilityHelp(key)
        if kind == nil { toolTip = Loc.t("capture.note.kind_none_tip", table: "Capture") }
    }
    required init?(coder: NSCoder) { fatalError() }

    var title: String { kind.map(KindChip.name) ?? Loc.t("capture.note.kind_none", table: "Capture") }
    /// "⌘1" … "⌘4", "⌘0"
    var key: String { "⌘\(kind?.digit ?? 0)" }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    private var text: NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        let s = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
                                                                       .paragraphStyle: p])
        if kind == nil {
            s.append(NSAttributedString(string: "  " + Loc.t("capture.note.kind_none_caption", table: "Capture"),
                                        attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                                                     .paragraphStyle: p]))
        }
        return s
    }
    var textWidth: CGFloat { ceil(text.size().width) }

    override func draw(_ dirty: NSRect) {
        let i = ProjectPickView.inset
        var body = bounds
        if lineAbove {
            NSColor.separatorColor.setFill()
            let px = 1 / (window?.backingScaleFactor ?? 2)
            NSRect(x: i, y: floor(ProjectPickView.gap / 2), width: bounds.width - 2 * i, height: px).fill()
            body.origin.y += ProjectPickView.gap
            body.size.height -= ProjectPickView.gap
        }
        if selected {
            BrandColor.tint.setFill()
            NSBezierPath(roundedRect: body.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        if let img = KindChip.glyph(kind) {
            let s = img.size
            img.draw(in: NSRect(x: i + (16 - s.width) / 2, y: body.midY - s.height / 2, width: s.width, height: s.height))
        }
        let x = ProjectPickView.textX
        let s = text
        let h = s.size().height
        s.draw(in: NSRect(x: x, y: body.midY - h / 2, width: bounds.width - x - i - KindRow.trailing, height: h))
        // the key, right-aligned at the trailing edge (medium, as the footer's keys), quiet
        let k = NSAttributedString(string: key, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                             .foregroundColor: NSColor.secondaryLabelColor])
        let ks = k.size()
        k.draw(at: NSPoint(x: bounds.width - i - ceil(ks.width), y: body.midY - ks.height / 2))
        if checked, let img = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [BrandColor.ink]))) {
            let cx = bounds.width - i - 26 - 6 - 16
            img.draw(in: NSRect(x: cx + (16 - img.size.width) / 2, y: body.midY - img.size.height / 2,
                                width: img.size.width, height: img.size.height))
        }
    }
}
