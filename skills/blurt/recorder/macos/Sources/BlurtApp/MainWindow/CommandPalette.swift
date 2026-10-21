// ⌘K: one field for every action, place and item. Commands and places match by fuzzy subsequence; items come from
// the index (same search as the toolbar field, top 8). ↑/↓ choose, ↩ runs, Esc closes.
import AppKit
import BlurtCore

final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

final class CommandPalette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    struct Entry {
        let title: String
        let detail: String
        let image: NSImage?
        let keys: String
        let enabled: Bool
        let run: () -> Void
    }

    unowned let controller: MainWindowController
    let panel: PalettePanel
    let field = NSTextField()
    let table = NSTableView()
    var entries: [Entry] = []

    init(controller: MainWindowController) {
        self.controller = controller
        panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 380),
                             styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.setAccessibilityLabel(T("menu.palette"))

        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        panel.contentView = fx

        let icon = NSImageView(image: Look.symbol("magnifyingglass", "", size: 17, weight: .medium) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.placeholderString = T("main.palette.placeholder")
        field.delegate = self
        field.cell?.isScrollable = true
        field.setAccessibilityLabel(T("main.palette.field"))
        let sep = NSBox()
        sep.boxType = .separator

        let col = NSTableColumn(identifier: .init("e"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 34
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(runSelected)
        table.action = #selector(clicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        for v in [icon, field, sep, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; fx.addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 18), icon.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -18),
            field.topAnchor.constraint(equalTo: fx.topAnchor, constant: 16),
            sep.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            sep.leadingAnchor.constraint(equalTo: fx.leadingAnchor), sep.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 8), scroll.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: fx.bottomAnchor, constant: -8),
        ])
    }

    var isOpen: Bool { panel.isVisible }

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard let w = controller.window else { return }
        field.stringValue = ""
        refresh()
        let f = w.frame
        panel.setFrame(NSRect(x: f.midX - 300, y: f.maxY - 110 - 380, width: 600, height: 380), display: false)
        resize()
        w.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func close() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    // MARK: entries

    func commands() -> [Entry] {
        let c = controller
        func e(_ t: String, _ sym: String, _ keys: String = "", enabled: Bool = true, detail: String = "", _ run: @escaping () -> Void) -> Entry {
            Entry(title: t, detail: detail, image: Look.symbol(sym, t, size: 14), keys: keys, enabled: enabled, run: run)
        }
        let items = c.list.selectedItems
        let has = !items.isEmpty
        var out = [
            e(T("main.action.record"), "record.circle", hk(.toggleRecord)) { c.record() },
            e(T("main.action.snap"), "camera.viewfinder", hk(.snap)) { c.snap() },
            e(T("project.open_folder"), "folder.badge.plus", "⌘O") { c.openFolder() },
            e(T("main.menu.start_session"), "apple.terminal", "⌘↩", enabled: has) { c.handOffSelection() },
            e(T("handoff.copy_instruction"), "doc.on.clipboard", "⇧⌘C", enabled: has) { c.mCopyInstruction() },
            e(T("handoff.copy_full"), "text.alignleft", enabled: has) { c.mCopyFull() },
            e(T("work.confirm_done"), "checkmark.circle", "D", enabled: items.contains { c.allowed("done", $0) }) { c.setWork("done") },
            e(T("work.reopen"), "arrow.uturn.backward.circle", "R", enabled: items.contains { c.allowed("todo", $0) }) { c.setWork("todo") },
            e(T("main.menu.quick_look"), "eye", T("main.keys.space"), enabled: has) { c.list.toggleQuickLook() },
            e(T("action.reveal_in_finder"), "folder", "⇧⌘R", enabled: has) { c.mReveal() },
            e(T("action.copy_path"), "doc.on.doc", "⌥⌘C", enabled: has) { c.copyPaths() },
            e(T("main.menu.rename"), "pencil", "E", enabled: has) { c.renameSelection() },
            e(T("review.confirmed"), "checkmark", "S", enabled: has) { c.setStatus("confirmed") },
            e(T("review.deleted"), "trash", "⌫", enabled: has) { c.setStatus("deleted") },
            e(T("main.place.inbox"), "tray", "⌘1") { c.go(.inbox) },
            e(T("main.place.progress"), "circle.dashed", "⌘2") { c.go(.inProgress) },
            e(T("project.inbox"), "tray.2", "⌘3") { c.go(.unassigned) },
            e(T("main.place.all"), "square.stack", "⌘4") { c.go(.all) },
            e(T("main.empty.clear_filters"), "line.3.horizontal.decrease.circle", enabled: c.model.filtered) { c.clearFilters() },
            e(T("menu.rescan"), "arrow.clockwise") { c.model.scan() },
            e(T("menu.shortcuts"), "keyboard", "?") { c.showShortcuts() },
        ]
        for k in KindStyle.builtIn {
            out.append(Entry(title: T("main.palette.only_kind", Look.kindName(k)), detail: "", image: Look.kindImage(k), keys: "", enabled: true) {
                c.model.kinds = [k]; c.model.reload()
            })
        }
        if AppEnvironment.settings != nil { out.append(e(T("menu.settings"), "gearshape", "⌘,") { AppEnvironment.settings?.show(pane: nil) }) }
        for p in c.model.projects where p.registered {
            out.append(e(p.name, "folder", detail: T("main.palette.project", (p.path.path as NSString).abbreviatingWithTildeInPath)) { c.reveal(project: p.id) })
            if !items.isEmpty {
                out.append(e(T("main.palette.move_to", p.name), "arrow.right.doc.on.clipboard") { c.move(uids: items.map(\.uid), to: p.id) })
            }
        }
        return out
    }

    /// Fuzzy subsequence score (higher is better), nil = no match.
    static func score(_ text: String, _ q: String) -> Int? {
        let t = Array(text.lowercased()), p = Array(q.lowercased().filter { !$0.isWhitespace })
        guard !p.isEmpty else { return 0 }
        var i = 0, s = 0, last = -2
        for (k, ch) in t.enumerated() where i < p.count && ch == p[i] {
            s += (k == last + 1 ? 6 : 1) + (k == 0 || t[k - 1] == " " ? 4 : 0)
            last = k
            i += 1
        }
        return i == p.count ? s : nil
    }

    func refresh() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        var ranked = commands().compactMap { e -> (Int, Entry)? in Self.score(e.title, q).map { ($0, e) } }
        ranked.sort { $0.0 > $1.0 }
        entries = ranked.map(\.1)
        if !q.isEmpty, let r = controller.model.reader {
            let rows = (try? r.items(ItemQuery(text: q, limit: 8))) ?? []
            let items = rows.map { it in
                Entry(title: it.title.isEmpty ? it.itemID : it.title,
                      detail: [it.itemID, it.projectName, it.snippet.map { $0.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "") }]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                      image: Look.kindImage(it.kind), keys: "", enabled: true) { [weak self] in
                    self?.controller.reveal(uid: it.uid)
                }
            }
            // a few strong command matches first, then items
            entries = Array(entries.prefix(4)) + items + Array(entries.dropFirst(4))
        }
        table.reloadData()
        resize()
        if let k = entries.firstIndex(where: { $0.enabled }) { table.selectRowIndexes([k], byExtendingSelection: false); table.scrollRowToVisible(k) }
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    /// Grow with the results (up to 9 rows), anchored at the top.
    func resize() {
        let rows = CGFloat(min(max(entries.count, 1), 9))
        let h = 64 + rows * (table.rowHeight + table.intercellSpacing.height) + 16
        var f = panel.frame
        f.origin.y += f.height - h
        f.size.height = h
        panel.setFrame(f, display: panel.isVisible)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRowView() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): step(1); return true
        case #selector(NSResponder.moveUp(_:)): step(-1); return true
        case #selector(NSResponder.insertNewline(_:)): runSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    func step(_ d: Int) {
        guard !entries.isEmpty else { return }
        var k = table.selectedRow
        repeat { k = (k + d + entries.count) % entries.count } while !entries[k].enabled && k != table.selectedRow
        table.selectRowIndexes([k], byExtendingSelection: false)
        table.scrollRowToVisible(k)
    }

    @objc func clicked() { if table.clickedRow >= 0 { runSelected() } }

    @objc func runSelected() {
        let k = table.selectedRow
        guard k >= 0, k < entries.count, entries[k].enabled else { NSSound.beep(); return }
        let e = entries[k]
        close()
        controller.window?.makeKeyAndOrderFront(nil)
        e.run()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("pe")
        let v = tableView.makeView(withIdentifier: id, owner: self) as? PaletteCell ?? PaletteCell(id: id)
        v.set(entries[row])
        return v
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { entries[row].enabled }
}

/// The chosen row stays accent-coloured even though the panel never activates the app's main window.
final class PaletteRowView: NSTableRowView {
    override var isEmphasized: Bool { get { true } set {} }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }
}

final class PaletteCell: NSTableCellView {
    let icon = NSImageView(), title = NSTextField(labelWithString: ""), detail = NSTextField(labelWithString: ""), keys = NSTextField(labelWithString: "")
    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        for v in [icon, title, detail, keys] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        title.font = .systemFont(ofSize: 13)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.init(600), for: .horizontal)
        keys.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        keys.textColor = .tertiaryLabelColor
        keys.setContentCompressionResistancePriority(.required, for: .horizontal)
        imageView = icon
        textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8), detail.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            keys.leadingAnchor.constraint(greaterThanOrEqualTo: detail.trailingAnchor, constant: 8),
            keys.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), keys.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(_ e: CommandPalette.Entry) {
        icon.image = e.image
        title.stringValue = e.title
        title.textColor = e.enabled ? .labelColor : .tertiaryLabelColor
        detail.stringValue = e.detail
        keys.stringValue = e.keys
        setAccessibilityLabel([e.title, e.detail, e.keys].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}
