// Moving items to a project in the main window, cheaply (K2, v0.9 — the user moves items; Blurt never does):
//
//   ProjectPopover     M (or Move to Project… in the palette, the toolbar's Move ▸ Other…): a small popover at the
//                      selection — type to filter (ProjectPick: key, name, a word of it), ↑↓, ↩ moves, Esc closes.
//                      Projects recently used first, Unassigned last; the place the items are in is checked.
//   SuggestChip        an Unassigned row an organizing run suggested a project for: "Looks like Atlas Web · Move" at
//                      the end of its title — one click moves it (⌘Z / the toast's Undo moves it back).
//   SuggestionsBanner  above the Unassigned list, one line per suggested project: "Looks like Atlas Web · 3 items"
//                      [Move All (3)] — one move, one Undo for the whole group. The rows below are in the same groups.
// Every move goes through MainWindowController.move(uids:to:) (items.py move, the user's own; ⌘Z puts each item back).
import AppKit
import BlurtCore

// MARK: - the Move popover

final class ProjectPopover: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSPopoverDelegate {
    struct Entry { let id: String; let name: String; let key: String; let color: NSColor; let inbox: Bool }

    private let all: [Entry]
    private let checked: String?
    private let choose: (String) -> Void
    private var shown: [Entry] = []
    private let field = NSSearchField()
    private let table = NSTableView()
    private let none = NSTextField(labelWithString: T("main.move.no_match"))
    // held while it shows (it holds us as its content): let go in popoverDidClose
    private var popover: NSPopover?
    private var listHeight: NSLayoutConstraint!

    /// `checked`: where the items are now (all of them), "inbox" for Unassigned; `choose` gets a project id or "inbox".
    init(checked: String?, choose: @escaping (String) -> Void) {
        let store = ProjectStore.shared
        all = store.projects.map { Entry(id: $0.id, name: $0.name, key: $0.key, color: ProjectLook.color($0), inbox: false) }
            + [Entry(id: "inbox", name: T("project.inbox"), key: "", color: .systemGray, inbox: true)]
        self.checked = checked
        self.choose = choose
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    static let rowHeight: CGFloat = 26
    static let maxRows = 9

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 200))
        field.placeholderString = T("main.move.placeholder")
        field.delegate = self
        field.focusRingType = .none
        field.setAccessibilityLabel(T("main.move.placeholder"))
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
        none.textColor = .secondaryLabelColor
        none.font = .systemFont(ofSize: 12)
        none.isHidden = true
        for v in [field, scroll, none] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        listHeight = scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight * 4)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 280),
            field.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            listHeight,
            none.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), none.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        view = root
        refresh()
    }

    /// Shows it under `rect` of `view` (the selected row), the field taking the keys.
    func show(relativeTo rect: NSRect, of v: NSView) {
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = self
        p.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        p.delegate = self
        popover = p
        p.show(relativeTo: rect, of: v, preferredEdge: .maxY)
        view.window?.makeFirstResponder(field)
        emit(["event": "move_popover", "shown": shown.map(\.id)])
    }

    func popoverDidClose(_ notification: Notification) {
        popover?.contentViewController = nil
        popover = nil
    }

    func close() { popover?.close() }

    private func refresh() {
        let projects = all.filter { !$0.inbox }, inbox = all.filter(\.inbox)
        let q = field.stringValue
        // Unassigned stays last; it matches its own name too
        shown = ProjectPick.filter(projects, q, name: \.name, key: \.key) + ProjectPick.filter(inbox, q, name: \.name, key: \.key)
        table.reloadData()
        none.isHidden = !shown.isEmpty
        listHeight.constant = Self.rowHeight * CGFloat(min(max(shown.count, 2), Self.maxRows))
        let start = q.isEmpty ? (shown.firstIndex { $0.id != checked } ?? 0) : 0
        if !shown.isEmpty { table.selectRowIndexes([start], byExtendingSelection: false); table.scrollRowToVisible(start) }
    }

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
        guard !shown.isEmpty else { return }
        let n = max(0, min(shown.count - 1, table.selectedRow + d))
        table.selectRowIndexes([n], byExtendingSelection: false)
        table.scrollRowToVisible(n)
    }

    @objc private func clicked() { pick(table.clickedRow) }

    private func pick(_ row: Int) {
        guard row >= 0, row < shown.count else { NSSound.beep(); return }
        let id = shown[row].id
        popover?.close()
        emit(["event": "move_popover_pick", "project": id])
        choose(id)
    }

    // MARK: rows

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = shown[row]
        let c = NSTableCellView()
        let icon = NSImageView(image: Look.symbol(e.inbox ? "tray.2" : "folder.fill", e.name, size: 12) ?? NSImage())
        icon.contentTintColor = e.inbox ? .secondaryLabelColor : e.color
        let name = NSTextField(labelWithString: e.name)
        name.lineBreakMode = .byTruncatingTail
        name.font = .systemFont(ofSize: 13)
        let key = NSTextField(labelWithString: e.key)
        key.font = Look.monoSub
        key.textColor = .secondaryLabelColor
        let check = NSImageView(image: Look.symbol("checkmark", T("main.move.here"), size: 11, weight: .semibold) ?? NSImage())
        check.contentTintColor = BrandColor.ink
        check.isHidden = e.id != checked
        for v in [icon, name, key, check] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(v) }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6), check.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 12),
            icon.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 4), icon.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7), name.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            key.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            key.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8), key.centerYAnchor.constraint(equalTo: c.centerYAnchor),
        ])
        c.textField = name
        c.setAccessibilityLabel(e.id == checked ? "\(e.name), \(T("main.move.here"))" : e.name)
        return c
    }

    /// Tests (wp6 `movepopover`): the rows as shown.
    var shownIDs: [String] { shown.map(\.id) }
    func type(_ s: String) { field.stringValue = s; refresh() }
    /// Tests: ↩ on the selected row.
    func testPick() { pick(table.selectedRow) }
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
        let s = NSMutableAttributedString(string: T("main.suggest.looks_like", p.name), attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
        s.append(NSAttributedString(string: " · " + TP("main.suggest.items", g.uids.count),
                                    attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        text.attributedStringValue = s
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
