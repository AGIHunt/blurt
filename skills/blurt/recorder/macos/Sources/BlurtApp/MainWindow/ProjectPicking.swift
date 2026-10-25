// Moving items to a project in the main window, cheaply (K2, v0.9 — the user moves items; Blurt never does):
//
//   ProjectPopover     M (or Move to Project… in the palette, the toolbar's Move ▸ Other…): a small popover at the
//                      selection — "Move BA-1 to…" / "Move 3 items to…"; type to filter (ProjectPick: key, name, a word
//                      of it; the typed letters in semibold), ↑↓ or the pointer, ↩ moves, Esc closes. Projects recently
//                      used first, then a line and Unassigned (last, as in every project picker). Where the items are
//                      now says "Current" and is never the default (↩ on it just closes). The chosen row is the
//                      brand-tint wash of the ⌘K palette and the lists; the rows look like the sidebar's (an outline
//                      folder, the key). No match: one line saying so, then Open Folder… (that folder, then the move).
//   SuggestChip        an Unassigned row an organizing run suggested a project for: "Looks like Atlas Web · Move" at
//                      the end of its title — one click moves it (⌘Z / the toast's Undo moves it back).
//   SuggestionsBanner  above the Unassigned list, one line per suggested project: "Looks like Atlas Web"
//                      [Move All (3)] — one move, one Undo for the whole group. The rows below are in the same groups.
// Every move goes through MainWindowController.move(uids:to:) (items.py move, the user's own; ⌘Z puts each item back).
import AppKit
import BlurtCore

// MARK: - the Move popover

final class ProjectPopover: NSViewController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSPopoverDelegate {
    enum Kind { case project, inbox, none, open }
    struct Entry { let id: String; let name: String; let key: String; let kind: Kind }

    private let projects: [Project]
    private let checked: String?
    private let subject: String
    private let choose: (String) -> Void
    private let openFolder: (() -> Void)?
    private var shown: [Entry] = []
    private var query = ""
    private let field = NSTextField()
    private let table = NSTableView()
    // held while it shows (it holds us as its content): let go in popoverDidClose
    private var popover: NSPopover?
    private var listHeight: NSLayoutConstraint!

    /// `checked`: where the items are now (all of them), "inbox" for Unassigned. `subject`: what moves, for the field
    /// ("Move BA-1 to…", "Move 3 items to…"). `choose` gets a project id or "inbox"; `openFolder` (no project matches):
    /// opens a folder as a project and moves the items there.
    init(checked: String?, subject: String, choose: @escaping (String) -> Void, openFolder: (() -> Void)? = nil) {
        projects = ProjectStore.shared.projects
        self.checked = checked
        self.subject = subject
        self.choose = choose
        self.openFolder = openFolder
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // One grid (docs/design/system.md §3.3, the palette's chosen row): 12 pt from the popover's edge to the glyph
    // column (16 pt: the field's magnifier, the folders, the tray), 8 pt more to the text (the field's text and the
    // names start on one vertical), 12 pt from the trailing edge. The chosen row is the brand-tint wash, inset 6 pt.
    static let rowHeight: CGFloat = 28
    static let maxRows = 9
    static let inset: CGFloat = 12
    static let glyph: CGFloat = 16
    static var textX: CGFloat { inset + glyph + 8 }
    static let minWidth: CGFloat = 300, maxWidth: CGFloat = 360
    static let nameFont = NSFont.systemFont(ofSize: 13)
    static let keyFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)      // the sidebar's key

    override func loadView() {
        let width = Self.width(for: projects)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        let glass = NSImageView(image: Look.symbol("magnifyingglass", "", size: 13) ?? NSImage())
        glass.contentTintColor = .secondaryLabelColor
        // one surface: a borderless field on the popover itself, a hairline under it, the list
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderString = subject
        field.delegate = self
        field.setAccessibilityLabel(subject)
        let line = NSBox()
        line.boxType = .separator
        let col = NSTableColumn(identifier: .init("p"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true
        table.setAccessibilityLabel(T("main.move.list"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        for v in [glass, field, line, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        listHeight = scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight * 4)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: width),
            glass.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.inset),
            glass.widthAnchor.constraint(equalToConstant: Self.glyph),
            glass.centerYAnchor.constraint(equalTo: root.topAnchor, constant: 21),
            // a borderless field draws its text at its edge: on the names' vertical
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.textX),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.inset),
            field.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
            line.topAnchor.constraint(equalTo: root.topAnchor, constant: 41),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 5),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            listHeight,
        ])
        view = root
        table.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        refresh()
    }

    /// Wide enough for the longest name and its key (or "Current"), between 300 and 360 pt; a longer name gives way in
    /// the middle, so the end that tells two projects apart stays (the whole name is the row's tooltip).
    static func width(for ps: [Project]) -> CGFloat {
        let here = (T("main.move.current") as NSString).size(withAttributes: [.font: Look.subFont]).width + 15
        let need = ps.map { p -> CGFloat in
            let n = (p.name as NSString).size(withAttributes: [.font: nameFont]).width
            let k = (p.key as NSString).size(withAttributes: [.font: keyFont]).width
            return ceil(n + 12 + max(k, here))
        }.max() ?? 0
        return min(maxWidth, max(minWidth, textX + need + inset))
    }

    /// Shows it under `rect` of `view` (the start of the selected row's title), the field taking the keys.
    func show(relativeTo rect: NSRect, of v: NSView) {
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = self
        p.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        p.delegate = self
        popover = p
        p.show(relativeTo: rect, of: v, preferredEdge: .maxY)
        view.window?.makeFirstResponder(field)
        emit(["event": "move_popover", "shown": shown.map(\.id), "selected": selectedID])
    }

    func popoverDidClose(_ notification: Notification) {
        popover?.contentViewController = nil
        popover = nil
    }

    func close() { popover?.close() }

    private func refresh() {
        query = field.stringValue.trimmingCharacters(in: .whitespaces)
        // the rows every project picker shows: recent projects, then Unassigned last (it matches its own name too)
        shown = ProjectPick.choices(projects, query: query, unassigned: T("project.inbox")).map { c in
            c.project.map { Entry(id: $0.id, name: $0.name, key: $0.key, kind: .project) }
                ?? Entry(id: "inbox", name: T("project.inbox"), key: "", kind: .inbox)
        }
        // no project matches: one line saying so, and the way to add the one that's missing
        if shown.isEmpty {
            shown = [Entry(id: "none", name: T("project.no_match"), key: "", kind: .none)]
            if openFolder != nil { shown.append(Entry(id: "open", name: T("project.open_folder"), key: "", kind: .open)) }
        }
        table.reloadData()
        // as tall as its rows: no empty band under a single result
        listHeight.constant = shown.indices.prefix(Self.maxRows).reduce(CGFloat(0)) { $0 + rowHeight($1) }
        // the place the items already are is never the default: ↩ goes somewhere else, or nowhere
        if let start = shown.indices.first(where: { selectable($0) && shown[$0].id != checked }) {
            table.selectRowIndexes([start], byExtendingSelection: false)
            table.scrollRowToVisible(start)
        } else {
            table.deselectAll(nil)
        }
    }

    private func selectable(_ row: Int) -> Bool { shown[row].kind != .none }
    private func lineAbove(_ row: Int) -> Bool { row > 0 && [.inbox, .open].contains(shown[row].kind) }
    private func rowHeight(_ row: Int) -> CGFloat { Self.rowHeight + (lineAbove(row) ? PickRowView.gap : 0) }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): step(1); return true
        case #selector(NSResponder.moveUp(_:)): step(-1); return true
        case #selector(NSResponder.insertNewline(_:)): pick(table.selectedRow); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty { popover?.close() } else { field.stringValue = ""; refresh() }
            return true
        default: return false
        }
    }

    private func step(_ d: Int) {
        let rows = shown.indices.filter(selectable)
        guard !rows.isEmpty else { return }
        let at = rows.firstIndex(of: table.selectedRow) ?? (d > 0 ? -1 : rows.count)
        let n = rows[max(0, min(rows.count - 1, at + d))]
        table.selectRowIndexes([n], byExtendingSelection: false)
        table.scrollRowToVisible(n)
    }

    @objc private func clicked() { if table.clickedRow >= 0 { pick(table.clickedRow) } }

    override func mouseMoved(with event: NSEvent) {
        // the row under the pointer becomes the keyboard's choice: only one row is ever highlighted
        let r = table.row(at: table.convert(event.locationInWindow, from: nil))
        if r >= 0, r < shown.count, selectable(r), r != table.selectedRow { table.selectRowIndexes([r], byExtendingSelection: false) }
    }

    private func pick(_ row: Int) {
        let valid = row >= 0 && row < shown.count
        if valid, !selectable(row) { return }
        // nothing chosen (only where the items already are matched), or that place itself: close quietly, no move
        guard valid, shown[row].id != checked else {
            popover?.close()
            emit(["event": "move_popover_pick", "project": ""])
            return
        }
        let e = shown[row]
        popover?.close()
        emit(["event": "move_popover_pick", "project": e.id])
        if e.kind == .open { openFolder?() } else { choose(e.id) }
    }

    // MARK: rows

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeight(row) }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { selectable(row) }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let r = PickRowView()
        r.lineAbove = lineAbove(row)
        return r
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = shown[row]
        let here = e.id == checked && e.kind != .none
        let c = PickCell()
        let top = lineAbove(row) ? PickRowView.gap : 0
        // the sidebar's glyphs in its secondary ink: an outline folder, the tray for Unassigned (no project colours)
        let symbol: String?
        switch e.kind {
        case .project: symbol = "folder"
        case .inbox: symbol = "tray.2"
        case .open: symbol = "folder.badge.plus"
        case .none: symbol = nil
        }
        let icon = NSImageView(image: symbol.flatMap { Look.symbol($0, "", size: 13) } ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let name = NSTextField(labelWithString: "")
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingMiddle
        let ink: NSColor = e.kind == .none || here ? .secondaryLabelColor : .labelColor
        let s = NSMutableAttributedString(string: e.name, attributes: [.font: Self.nameFont, .foregroundColor: ink, .paragraphStyle: p])
        // the typed letters in semibold, so it shows why a row is here
        if e.kind == .project || e.kind == .inbox, let r = Self.match(e.name, query) {
            s.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .semibold), range: NSRange(r, in: e.name))
        }
        // the current project (where new captures go) wears the same mark as in the sidebar
        if e.kind == .project, e.id == ProjectStore.shared.currentID, let img = SourceCell.currentImage {
            let a = NSTextAttachment()
            let tinted = img.copy() as! NSImage
            tinted.isTemplate = true
            a.image = tinted
            a.bounds = NSRect(x: 0, y: -1, width: img.size.width, height: img.size.height)
            s.append(NSAttributedString(string: "  "))
            let m = NSMutableAttributedString(attachment: a)
            m.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: m.length))
            s.append(m)
        }
        name.attributedStringValue = s
        name.toolTip = e.kind == .project && e.id == ProjectStore.shared.currentID ? T("main.project.current_mark") : nil
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // trailing: the key, as in the sidebar; where the items are now, a check and "Here now" instead
        let trail: NSView
        if here {
            let check = NSImageView(image: Look.symbol("checkmark", "", size: 10, weight: .semibold) ?? NSImage())
            check.contentTintColor = BrandColor.ink
            let word = NSTextField(labelWithString: T("main.move.current"))
            word.font = Look.subFont
            word.textColor = .secondaryLabelColor
            let st = NSStackView(views: [check, word])
            st.spacing = 4
            st.alignment = .centerY
            trail = st
        } else {
            let key = NSTextField(labelWithString: e.key)
            let typed = !query.isEmpty && e.key.range(of: query, options: [.anchored, .caseInsensitive, .widthInsensitive]) != nil
            key.font = typed ? .monospacedSystemFont(ofSize: 10, weight: .semibold) : Self.keyFont
            key.textColor = .secondaryLabelColor
            trail = key
        }
        trail.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [icon, name, trail] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: Self.inset), icon.widthAnchor.constraint(equalToConstant: Self.glyph),
            icon.centerYAnchor.constraint(equalTo: c.centerYAnchor, constant: top / 2),
            name.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: Self.textX),
            name.centerYAnchor.constraint(equalTo: c.centerYAnchor, constant: top / 2),
            trail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 12),
            trail.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -Self.inset),
            here ? trail.centerYAnchor.constraint(equalTo: name.centerYAnchor) : trail.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ])
        c.name = name
        c.full = e.name
        c.setAccessibilityLabel(here ? "\(e.name), \(T("main.move.here"))" : e.name)
        return c
    }

    /// Where `query` sits in `name` (case, accents and width ignored): at the start of a word when it is there too.
    static func match(_ name: String, _ query: String) -> Range<String.Index>? {
        guard !query.isEmpty else { return nil }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        var first: Range<String.Index>?
        var from = name.startIndex
        while from < name.endIndex, let r = name.range(of: query, options: opts, range: from..<name.endIndex) {
            if first == nil { first = r }
            if r.lowerBound == name.startIndex { return r }
            let before = name[name.index(before: r.lowerBound)]
            if !before.isLetter && !before.isNumber { return r }
            from = name.index(after: r.lowerBound)
        }
        return first
    }

    /// Tests (wp6 `mainmovepop`): the rows as shown, and the one ↩ would choose ("" for none).
    var shownIDs: [String] { shown.map(\.id) }
    var selectedID: String { table.selectedRow >= 0 && table.selectedRow < shown.count ? shown[table.selectedRow].id : "" }
    func type(_ s: String) {
        field.stringValue = s
        field.currentEditor()?.selectedRange = NSRange(location: (s as NSString).length, length: 0)    // as if typed
        refresh()
    }
    /// Tests: ↩ on the selected row.
    func testPick() { pick(table.selectedRow) }
}

/// The popover's row: the chosen one is the brand-tint wash of the ⌘K palette and the lists (§3.3; r 6, inset 6 pt from
/// the popover's edges), never the accent block, and the text on it stays ink. Drawn whoever has first responder (the
/// field keeps it). A row after the projects (Unassigned, Open Folder…) has a hairline above it, on the 12 pt grid.
private final class PickRowView: NSTableRowView {
    static let gap: CGFloat = 9
    var lineAbove = false
    override var isEmphasized: Bool { get { false } set {} }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        BrandColor.tint.setFill()
        var r = bounds
        if lineAbove { r.origin.y += Self.gap; r.size.height -= Self.gap }
        NSBezierPath(roundedRect: r.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
    override func drawBackground(in dirtyRect: NSRect) {
        guard lineAbove else { return }
        NSColor.separatorColor.setFill()
        let px = 1 / (window?.backingScaleFactor ?? 2)
        NSRect(x: ProjectPopover.inset, y: floor(Self.gap / 2), width: bounds.width - 2 * ProjectPopover.inset, height: px).fill()
    }
}

/// Its cell: a name cut in the middle has the whole name as its tooltip.
private final class PickCell: NSTableCellView {
    weak var name: NSTextField?
    var full = ""
    override func layout() {
        super.layout()
        guard let n = name else { return }
        n.toolTip = n.attributedStringValue.size().width > n.frame.width + 0.5 ? full : nil
    }
}

// MARK: - "Looks like X · Move" at the end of an Unassigned row

/// A row's suggested project as a quiet inline button; `onMove` moves that row's item there.
final class SuggestChip: NSButton {
    var onMove: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        target = self
        action = #selector(tapped)
        focusRingType = .none
        cell?.wraps = false
        cell?.lineBreakMode = .byClipping
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// "Looks like Atlas Web · Move" — the project quiet, the action in brand ink.
    func set(project name: String) {
        // one line, always ending in "Move": a long name gives way, never the action
        let short = name.count > Self.nameMax ? String(name.prefix(Self.nameMax - 1)) + "…" : name
        let s = NSMutableAttributedString(string: T("main.list.suggested", short),
                                          attributes: [.font: Look.subFont, .foregroundColor: NSColor.secondaryLabelColor])
        s.append(NSAttributedString(string: " · ", attributes: [.font: Look.subFont, .foregroundColor: NSColor.tertiaryLabelColor]))
        s.append(NSAttributedString(string: T("main.list.move"), attributes: [.font: Look.smallFont, .foregroundColor: BrandColor.ink]))
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byClipping
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        attributedTitle = s
        toolTip = T("main.list.move.tip", name)
        setAccessibilityLabel(T("main.list.move.tip", name))
        invalidateIntrinsicContentSize()
    }

    @objc private func tapped() { onMove?() }

    /// Characters of a project's name the chip shows before "…"
    static let nameMax = 16
    override var intrinsicContentSize: NSSize {
        let w = attributedTitle.size().width
        return NSSize(width: ceil(w) + 6, height: 18)
    }
}

// MARK: - the groups above the Unassigned list

final class SuggestionsBanner: NSView {
    /// "Move All (N)" on a group: (project id, the group's uids)
    var onMoveAll: ((String, [String]) -> Void)?
    private let stack = NSStackView()
    static let maxGroups = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6), stack.bottomAnchor.constraint(equalTo: line.topAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(T("main.suggest.label"))
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    private(set) var groups: [SuggestionGroup] = []

    func set(_ gs: [SuggestionGroup], projects: [ProjectEntry]) {
        groups = gs
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        isHidden = gs.isEmpty
        for g in gs.prefix(Self.maxGroups) {
            guard let p = projects.first(where: { $0.id == g.project }) else { continue }
            stack.addArrangedSubview(row(g, p))
            stack.arrangedSubviews.last?.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if gs.count > Self.maxGroups {
            let more = NSTextField(labelWithString: T("main.suggest.more", gs.count - Self.maxGroups))
            more.font = Look.subFont
            more.textColor = .secondaryLabelColor
            stack.addArrangedSubview(more)
        }
    }

    private func row(_ g: SuggestionGroup, _ p: ProjectEntry) -> NSView {
        let v = NSView()
        let color = ProjectStore.shared.project(id: p.id).map(ProjectLook.color) ?? .systemGray
        let icon = NSImageView(image: Look.symbol("folder.fill", p.name, size: 12) ?? NSImage())
        icon.contentTintColor = color
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        // the count is on the button (Move All (3)): the line names the project only
        text.attributedStringValue = NSAttributedString(string: T("main.suggest.looks_like", p.name),
                                                        attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let title = g.uids.count > 1 ? T("main.suggest.move_all", g.uids.count) : T("main.list.move")
        let b = NSButton(title: title, target: self, action: #selector(moveAll(_:)))
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.identifier = .init(g.project)
        b.toolTip = T("main.suggest.move_all.tip", g.uids.count, p.name)
        b.setAccessibilityLabel(b.toolTip)
        for x in [icon, text, b] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            v.heightAnchor.constraint(equalToConstant: 26),
            icon.leadingAnchor.constraint(equalTo: v.leadingAnchor), icon.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8), text.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            b.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 10),
            b.trailingAnchor.constraint(equalTo: v.trailingAnchor), b.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    @objc private func moveAll(_ b: NSButton) {
        guard let p = b.identifier?.rawValue, let g = groups.first(where: { $0.project == p }) else { return }
        b.isEnabled = false        // once: the reload brings the banner back without this group
        onMoveAll?(p, g.uids)
    }
}
