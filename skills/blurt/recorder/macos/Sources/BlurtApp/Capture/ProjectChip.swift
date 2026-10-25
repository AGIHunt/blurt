// The note bubble's "Goes to X" chip (v0.9-next): where this capture goes, switched right there. A click (or Tab from the
// note's field) opens the list in the bubble itself — the same rows as every project picker (BlurtCore
// ProjectPick.choices: recent projects first, typing filters them by name or key, Unassigned last, under a line), ↑↓
// move, ↩ picks, Esc goes back to the note. Unassigned = no project: the snap hangs as a card. Only this capture moves
// (Snapper.retarget); the island's current project stays as it is.
import AppKit
import BlurtCore

/// "Goes to ordo-platform ⌄" / "Unassigned ⌄": quiet text on a faint fill, a little stronger under the pointer.
final class ProjectChip: NSButton {
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    convenience init(_ click: @escaping () -> Void) {
        self.init(frame: NSRect(x: 0, y: 0, width: 80, height: 18))
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        onClick = click
        target = self
        action = #selector(fire)
        toolTip = Loc.t("capture.note.chip_tip", table: "Capture")
        setAccessibilityRole(.popUpButton)
    }
    @objc private func fire() { onClick?() }

    /// The label, sized to fit (at most `maxWidth`).
    func set(_ text: String, maxWidth: CGFloat) {
        title = text
        setAccessibilityLabel(text)
        let w = (text as NSString).size(withAttributes: [.font: ProjectChip.font]).width
        setFrameSize(NSSize(width: min(maxWidth, ceil(w) + 8 + 14 + 6), height: 18))
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor.labelColor.withAlphaComponent(hovering || isHighlighted ? 0.12 : 0.06).setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        let s = NSAttributedString(string: title, attributes: [.font: ProjectChip.font, .foregroundColor: NSColor.secondaryLabelColor])
        let maxText = bounds.width - 8 - 14 - 4
        let ts = s.size()
        s.draw(with: NSRect(x: 8, y: (bounds.height - ts.height) / 2, width: maxText, height: ts.height),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let img = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold).applying(.init(paletteColors: [.secondaryLabelColor]))) {
            let sz = img.size
            img.draw(in: NSRect(x: bounds.width - 6 - sz.width, y: (bounds.height - sz.height) / 2, width: sz.width, height: sz.height))
        }
    }
}

/// The chip's list, inside the bubble: a filter field and up to six rows.
final class ProjectPickView: NSView, NSTextFieldDelegate {
    let filter = NSTextField()
    /// nil = Unassigned (the snap hangs as a card)
    private(set) var rows: [Project?] = []
    private(set) var selected = 0
    private var rowViews: [PickRow] = []
    private let none = NSTextField(labelWithString: "")
    /// the capture's project now (its row carries a check)
    var current: String?
    var onPick: ((Project?) -> Void)?
    var onCancel: (() -> Void)?
    static let rowH: CGFloat = 24
    /// projects shown while nothing is typed narrows them (the bubble is small)
    static let maxProjects = 6
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        filter.placeholderString = Loc.t("project.find")
        filter.font = .systemFont(ofSize: 12.5)
        filter.isBezeled = true
        filter.bezelStyle = .roundedBezel        // the system's own search-like field: the text sits centred
        filter.focusRingType = .none
        filter.delegate = self
        filter.cell?.isScrollable = true
        addSubview(filter)
        none.font = .systemFont(ofSize: 12)
        none.textColor = .tertiaryLabelColor
        none.stringValue = Loc.t("project.no_match")
        addSubview(none)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The height it needs for its rows now.
    var height: CGFloat { 6 + 24 + 6 + CGFloat(max(1, rows.count)) * ProjectPickView.rowH + 4 }

    func reload() {
        let q = filter.stringValue
        rows = ProjectPick.choices(ProjectStore.shared.projects, query: q, unassigned: Loc.t("project.inbox"),
                                   limit: Self.maxProjects).map(\.project)
        selected = min(selected, max(0, rows.count - 1))
        if !q.isEmpty { selected = 0 }
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = rows.enumerated().map { i, p in
            let r = PickRow(project: p, checked: p?.id == current && current != nil || (p == nil && current == nil))
            r.lineAbove = p == nil && i > 0
            r.onClick = { [weak self] in self?.pick(i) }
            r.onHover = { [weak self] in self?.select(i) }
            addSubview(r)
            return r
        }
        none.isHidden = !rows.isEmpty
        needsLayout = true
        layoutRows()
    }

    func layoutRows() {
        filter.frame = NSRect(x: 0, y: 6, width: bounds.width, height: 22)
        var y: CGFloat = 6 + 24 + 6
        for (i, r) in rowViews.enumerated() {
            r.frame = NSRect(x: 0, y: y, width: bounds.width, height: ProjectPickView.rowH)
            r.selected = i == selected
            y += ProjectPickView.rowH
        }
        none.frame = NSRect(x: 8, y: y + 4, width: bounds.width - 16, height: 16)
    }

    override func layout() { super.layout(); layoutRows() }

    func select(_ i: Int) {
        guard !rows.isEmpty else { return }
        selected = (i + rows.count) % rows.count
        for (k, r) in rowViews.enumerated() { r.selected = k == selected }
    }

    func pick(_ i: Int? = nil) {
        let k = i ?? selected
        guard rows.indices.contains(k) else { return }
        onPick?(rows[k])
    }

    // the filter field: ↑ ↓ move, ↩ picks, Esc goes back
    func controlTextDidChange(_ n: Notification) {
        reload()
        onFilterChange?()
    }
    var onFilterChange: (() -> Void)?

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveUp(_:)): select(selected - 1); return true
        case #selector(NSResponder.moveDown(_:)): select(selected + 1); return true
        case #selector(NSResponder.insertNewline(_:)): pick(); return true
        case #selector(NSResponder.cancelOperation(_:)): onCancel?(); return true
        default: return false
        }
    }
}

/// One project in the chip's list: its colour dot, its name, a check on the one the capture goes to now; Unassigned with
/// the tray, under a hairline, as in the island's switcher.
final class PickRow: NSView {
    let project: Project?
    let checked: Bool
    var lineAbove = false
    var selected = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    override var isFlipped: Bool { true }

    init(project: Project?, checked: Bool) {
        self.project = project
        self.checked = checked
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    var title: String { project?.name ?? Loc.t("project.inbox") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func draw(_ dirty: NSRect) {
        if lineAbove {
            NSColor.separatorColor.setFill()
            NSRect(x: 8, y: 0, width: bounds.width - 16, height: 1).fill()
        }
        if selected {
            BrandColor.tint.setFill()          // the selection in lists blurt draws
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        var x: CGFloat = 8
        if let p = project {
            ProjectLook.color(p).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY - 3.5, width: 7, height: 7)).fill()
        } else if let img = NSImage(systemSymbolName: "tray.2", accessibilityDescription: nil)?   // Unassigned (the tray is the Inbox)
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor]))) {
            img.draw(in: NSRect(x: x - 1, y: bounds.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
        }
        x += 16
        let s = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12.5),
                                                               .foregroundColor: project == nil ? NSColor.secondaryLabelColor : NSColor.labelColor])
        s.draw(with: NSRect(x: x, y: (bounds.height - s.size().height) / 2, width: bounds.width - x - 28, height: s.size().height),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if checked, let img = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [BrandColor.ink]))) {
            img.draw(in: NSRect(x: bounds.width - 8 - img.size.width, y: bounds.midY - img.size.height / 2,
                                width: img.size.width, height: img.size.height))
        }
    }
}
