// The note bubble's destination chip (v0.9-next; r1 of the overlays redesign): where this capture goes, switched right
// there. It names the place the way its list does — one name for one choice: the project's coloured folder and its
// name, or the dashed ring and "Unassigned" (the list's row says what that means: it stays as a card). A click (or Tab from the
// note's field) opens the list under it, in the bubble — the same rows and the same grid as the main window's Move
// popover (ProjectPopover: 12 pt to a 16 pt glyph column, 8 pt more to the text, 28 pt rows, a borderless filter with
// the magnifier, a hairline under it): BlurtCore ProjectPick.choices (recent projects first, typing filters them by
// name or key, Unassigned last, under a line), ↑↓ move, ↩ picks, Esc goes back to the note. The cursor opens on the
// row the capture goes to now, so the wash and the check never disagree. Only this capture moves (Snapper.retarget);
// the island’s current project stays as it is. A project whose folder is gone: the question-mark folder, its name dimmed,
// "folder not found" in its tooltip — picked, the capture stays a card and the island offers Locate… (Snapper.file,
// MissingFolder).
import AppKit
import BlurtCore

/// "▭ Unassigned ⌃⌄" / "■ ordo-platform ⌃⌄": a borderless pop-up — its glyph on the bubble's glyph column, its name on
/// the text column; a faint fill only under the pointer and while its list is open.
final class ProjectChip: NSButton {
    enum Place: Equatable { case unassigned, project(Project), missing(String) }
    var onClick: (() -> Void)?
    private(set) var place: Place = .unassigned
    /// the list is open (the chip stays pressed)
    var open = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    static let font = NSFont.systemFont(ofSize: 12)
    static let height: CGFloat = 24
    /// the glyph starts this far in (the fill reaches past the bubble's columns by as much)
    static let lead: CGFloat = 6

    convenience init(_ click: @escaping () -> Void) {
        self.init(frame: NSRect(x: 0, y: 0, width: 80, height: ProjectChip.height))
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

    /// The name alone — a missing folder too: its question-mark folder says what is wrong, the tooltip and VoiceOver
    /// say it in words (the dogfood's "billing-api: f…er not found" cut out exactly the words that explained it).
    var label: String {
        switch place {
        case .unassigned: return Loc.t("project.inbox")
        case .project(let p): return p.name
        case .missing(let name): return name
        }
    }

    /// The place, sized to fit (at most `maxWidth`; a cut name has the whole of it as its tooltip).
    func set(_ p: Place, maxWidth: CGFloat) {
        place = p
        title = label
        var said = label
        if case .missing = p { said += ", " + Loc.t("capture.project.missing_short", table: "Capture") }
        setAccessibilityLabel(Loc.t("capture.note.chip_ax", table: "Capture", said))
        setAccessibilityValue(label)
        let want = ProjectChip.width(label)
        setFrameSize(NSSize(width: min(maxWidth, want), height: ProjectChip.height))
        var tip = [Loc.t("capture.note.chip_tip", table: "Capture")]
        if case .missing = p { tip.insert(Loc.t("capture.drawer.missing_sub", table: "Capture"), at: 0) }
        if want > maxWidth { tip.insert(label, at: 0) }
        toolTip = tip.joined(separator: "\n")
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    /// Tests: the pointer on the chip (its fill, its name in full ink).
    func testHover(_ on: Bool) { hovering = on }

    /// The place's glyph, as the list draws it (16 pt column): one mark per concept, the island's (IslandGlyph.place) —
    /// the project's coloured folder, Unassigned's dashed ring in secondary ink, a missing folder's question mark in
    /// tertiary. Drawn now, in the bubble's appearance.
    static func glyph(_ p: Place) -> NSImage? {
        let size: CGFloat = 16
        switch p {
        case .unassigned: return IslandGlyph.noProject.image(size: size, color: NSColor.labelColor.withAlphaComponent(0.62))
        case .project(let pr): return IslandGlyph.project(ProjectLook.color(pr)).image(size: size, color: .labelColor)
        case .missing: return IslandGlyph.missing.image(size: size, color: .tertiaryLabelColor)
        }
    }

    override func draw(_ dirty: NSRect) {
        // the name is quieter than the words it serves: secondary at rest, full ink under the pointer or open
        let ink: NSColor = { if case .missing = place { return .secondaryLabelColor }; return hovering || open ? .labelColor : .secondaryLabelColor }()
        ProjectChip.paint(bounds, glyph: ProjectChip.glyph(place), label: label, ink: ink, fill: hovering || isHighlighted || open,
                          pressed: open || isHighlighted)
    }

    /// The width a chip with this name wants: the glyph column, the name, the chevrons.
    static func width(_ label: String) -> CGFloat {
        let w = ceil((label as NSString).size(withAttributes: [.font: ProjectChip.font]).width)
        return ProjectChip.lead + 16 + 8 + w + 5 + 9 + 7
    }

    /// The footer chips' one look (the place chip, the type chip — KindChip): a faint fill under the pointer and while
    /// its list is open, the glyph on the glyph column, the name on the text column, a pop-up's chevrons after it.
    static func paint(_ bounds: NSRect, glyph: NSImage?, label: String, ink: NSColor, fill: Bool, pressed: Bool) {
        if fill {
            NSColor.labelColor.withAlphaComponent(pressed ? 0.10 : 0.06).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        if let img = glyph {
            let s = img.size
            img.draw(in: NSRect(x: ProjectChip.lead + (16 - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
        }
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingMiddle
        let s = NSAttributedString(string: label, attributes: [.font: ProjectChip.font, .foregroundColor: ink, .paragraphStyle: p])
        let x = ProjectChip.lead + 16 + 8
        let maxText = bounds.width - x - 5 - 9 - 7
        let th = s.size().height
        s.draw(in: NSRect(x: x, y: (bounds.height - th) / 2, width: maxText, height: th))
        // a pop-up's own mark: both chevrons, as NSPopUpButton draws them
        if let img = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold).applying(.init(paletteColors: [.secondaryLabelColor]))) {
            let sz = img.size
            let tx = min(x + ceil(s.size().width), x + maxText) + 5
            img.draw(in: NSRect(x: tx, y: (bounds.height - sz.height) / 2, width: sz.width, height: sz.height))
        }
    }
}

/// The chip's list, inside the bubble under the chip: a hairline, the filter line (the magnifier on the glyph column),
/// a hairline, up to six projects and Unassigned, and — the first few times — one faint row of its keys under them
/// (Raycast's action bar, not the filter line). The bubble widens for a long name (`wantWidth`, up to
/// NoteBubble.maxInner); the grid is the bubble's.
final class ProjectPickView: NSView, NSTextFieldDelegate {
    let filter = NSTextField()
    private let glass = NSImageView()
    /// nil = Unassigned (the snap hangs as a card)
    private(set) var rows: [Project?] = []
    private(set) var selected = 0
    private var rowViews: [PickRow] = []
    private let none = NSTextField(labelWithString: "")
    /// the list's keys, one faint row under the rows (the first few times only)
    private let keys = NSTextField(labelWithString: "")
    var showsKeys = false { didSet { keys.isHidden = !showsKeys } }
    static let keysH: CGFloat = 24
    /// the width its longest row needs, with the trailing check column (the bubble widens to it, up to its cap)
    private(set) var wantWidth: CGFloat = 0
    /// the capture's project now (its row carries the check)
    var current: String?
    var onPick: ((Project?) -> Void)?
    var onCancel: (() -> Void)?
    static let rowH: CGFloat = 28
    /// the room between the projects and Unassigned (the hairline sits in it)
    static let gap: CGFloat = 9
    static let inset: CGFloat = 12
    static var textX: CGFloat { inset + 16 + 8 }
    static let searchH: CGFloat = 30
    /// projects shown while nothing is typed narrows them (the bubble is small)
    static let maxProjects = 6
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        filter.placeholderString = Loc.t("project.find")
        filter.font = .systemFont(ofSize: 13)
        filter.isBordered = false
        filter.isBezeled = false
        filter.drawsBackground = false
        filter.focusRingType = .none
        filter.delegate = self
        filter.cell?.isScrollable = true
        filter.cell?.wraps = false
        filter.setAccessibilityLabel(Loc.t("project.find"))
        addSubview(filter)
        glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        glass.contentTintColor = .secondaryLabelColor
        addSubview(glass)
        none.font = .systemFont(ofSize: 12)
        none.textColor = .secondaryLabelColor
        none.stringValue = Loc.t("project.no_match")
        addSubview(none)
        keys.attributedStringValue = NoteBubble.keyLine(Loc.t("capture.note.st_pick", table: "Capture"))
        keys.isHidden = true
        addSubview(keys)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var listTop: CGFloat { 1 + ProjectPickView.searchH + 1 + 4 }

    /// The height it needs for its rows now.
    var height: CGFloat {
        let gaps = rows.enumerated().contains { $0.element == nil && $0.offset > 0 } ? ProjectPickView.gap : 0
        return listTop + CGFloat(max(1, rows.count)) * ProjectPickView.rowH + gaps + 2 + (showsKeys ? ProjectPickView.keysH : 0)
    }

    func reload() {
        let q = filter.stringValue
        rows = ProjectPick.choices(ProjectStore.shared.projects, query: q, unassigned: Loc.t("project.inbox"),
                                   limit: Self.maxProjects).map(\.project)
        selected = min(selected, max(0, rows.count - 1))
        if !q.isEmpty { selected = 0 }
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = rows.enumerated().map { i, p in
            let r = PickRow(project: p, checked: p?.id == current && current != nil || (p == nil && current == nil), query: q)
            r.lineAbove = p == nil && i > 0
            r.onClick = { [weak self] in self?.pick(i) }
            r.onHover = { [weak self] in self?.select(i) }
            addSubview(r)
            return r
        }
        none.isHidden = !rows.isEmpty
        let i = ProjectPickView.inset
        wantWidth = ceil(max(rowViews.map { ProjectPickView.textX + $0.textWidth + PickRow.trailing + i }.max() ?? 0,
                             ProjectPickView.textX + keys.attributedStringValue.size().width + i + 4))
        needsLayout = true
        layoutRows()
    }

    /// The row the capture goes to now (Unassigned too): the cursor opens there.
    var currentIndex: Int { rows.firstIndex { $0?.id == current } ?? 0 }

    func layoutRows() {
        let i = ProjectPickView.inset
        glass.frame = NSRect(x: i, y: 1 + (ProjectPickView.searchH - 16) / 2, width: 16, height: 16)
        // (the field's cell draws its text 2 pt in: the text starts on the text column)
        filter.frame = NSRect(x: ProjectPickView.textX - 2, y: 1 + (ProjectPickView.searchH - 18) / 2,
                              width: bounds.width - i - ProjectPickView.textX + 2, height: 18)
        var y = listTop
        for (k, r) in rowViews.enumerated() {
            let h = ProjectPickView.rowH + (r.lineAbove ? ProjectPickView.gap : 0)
            r.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            r.selected = k == selected
            y += h
        }
        none.frame = NSRect(x: ProjectPickView.textX, y: listTop + 6, width: bounds.width - ProjectPickView.textX - i, height: 16)
        // the keys: under the last row, on the text column
        let kh = ceil(keys.attributedStringValue.size().height)
        keys.frame = NSRect(x: ProjectPickView.textX, y: bounds.height - ProjectPickView.keysH + (ProjectPickView.keysH - kh) / 2 - 2,
                            width: bounds.width - ProjectPickView.textX - i, height: kh)
    }

    override func layout() { super.layout(); layoutRows() }

    override func draw(_ dirty: NSRect) {
        // one hairline over the list (it hangs from the chip's row) and one under the filter, on the 12 pt grid
        NSColor.separatorColor.setFill()
        let px = 1 / (window?.backingScaleFactor ?? 2)
        let i = ProjectPickView.inset
        NSRect(x: i, y: 0, width: bounds.width - 2 * i, height: px).fill()
        NSRect(x: i, y: 1 + ProjectPickView.searchH, width: bounds.width - 2 * i, height: px).fill()
    }

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

/// One place in the chip's list, on the Move popover's grid: its glyph in the 16 pt column (the project's coloured
/// folder, the island switcher's mark; tray.2 for Unassigned), its name on the text column in 13 pt, a check in the
/// trailing column on the one the capture goes to now. Unassigned (under a hairline) adds what it means: "stays as a
/// card". A project whose folder can't be found: a question-mark folder, its name dimmed, "folder not found" after it.
final class PickRow: NSView {
    let project: Project?
    let checked: Bool
    /// what is typed in the filter: those letters of the name in semibold (as the Move popover)
    let query: String
    /// the trailing column the check sits in, kept on every row: a name is cut before it, never runs into it
    static let trailing: CGFloat = 28
    var lineAbove = false
    var selected = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    override var isFlipped: Bool { true }

    init(project: Project?, checked: Bool, query: String = "") {
        self.project = project
        self.checked = checked
        self.query = query
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        let what = missing ? title + ", " + Loc.t("capture.project.missing_short", table: "Capture")
                 : project == nil ? title + ", " + Loc.t("capture.note.unassigned_caption", table: "Capture") : title
        setAccessibilityLabel(what)
        if missing { toolTip = Loc.t("capture.drawer.missing_sub", table: "Capture") }
        else if project == nil { toolTip = Loc.t("capture.note.unassigned_tip", table: "Capture") }
        else { toolTip = title }
    }
    required init?(coder: NSCoder) { fatalError() }

    var title: String { project?.name ?? Loc.t("project.inbox") }
    /// its folder is gone (moved or renamed): dimmed, with the folder-and-question-mark
    var missing: Bool { project.map { !$0.exists } ?? false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    /// The name (and Unassigned's caption) as drawn.
    private var text: NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingMiddle
        let s = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                                       .foregroundColor: missing ? NSColor.secondaryLabelColor : NSColor.labelColor,
                                                                       .paragraphStyle: p])
        if let r = ProjectPopover.match(title, query) {
            s.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .semibold), range: NSRange(r, in: title))
        }
        let caption = missing ? Loc.t("capture.project.missing_short", table: "Capture")
                    : project == nil ? Loc.t("capture.note.unassigned_caption", table: "Capture") : nil
        if let c = caption {
            s.append(NSAttributedString(string: "  " + c, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
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
            BrandColor.tint.setFill()          // the selection in lists blurt draws (inset 6, r 6: the Move popover's)
            NSBezierPath(roundedRect: body.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        let place: ProjectChip.Place = missing ? .missing(title) : project.map { .project($0) } ?? .unassigned
        if let img = ProjectChip.glyph(place) {
            let s = img.size
            img.draw(in: NSRect(x: i + (16 - s.width) / 2, y: body.midY - s.height / 2, width: s.width, height: s.height))
        }
        let x = ProjectPickView.textX
        let s = text
        let h = s.size().height
        s.draw(in: NSRect(x: x, y: body.midY - h / 2, width: bounds.width - x - i - PickRow.trailing, height: h))
        if checked, let img = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [BrandColor.ink]))) {
            img.draw(in: NSRect(x: bounds.width - i - 16 + (16 - img.size.width) / 2, y: body.midY - img.size.height / 2,
                                width: img.size.width, height: img.size.height))
        }
    }
}
