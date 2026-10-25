// ⌘K: one field for every action, place and item. Commands and places match by fuzzy subsequence; items come from
// the index (same search as the toolbar field, top 8), each with its ID, project, state (past To do) and the search
// hit when it isn't just the title again (on one line, ending where index.db cut it: SearchHit.shown). An item's id
// ("AW-11") puts that item on top, discarded or not. ↑/↓ choose, ↩ runs, Esc closes. The list shows whole rows only
// (up to 9).
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
    /// The list's height: whole rows, so no sliver of a next row shows at the bottom.
    private var listHeight: NSLayoutConstraint!
    static let maxRows = 9

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
        listHeight = scroll.heightAnchor.constraint(equalToConstant: table.rowHeight)
        listHeight.isActive = true
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
            e(T("main.menu.start_session"), "paperplane", "⌘↩", enabled: has) { c.handOffSelection() },
            e(T("main.cmd.copy_instruction"), "doc.on.doc", "⇧⌘C", enabled: has) { c.mCopyInstruction() },
            e(T("main.cmd.copy_full"), "text.alignleft", enabled: has) { c.mCopyFull() },
            e(T("main.menu.export_bundle"), "archivebox", enabled: has) { c.mExportBundle() },
            e(T("main.menu.quick_look"), "eye", T("main.keys.space"), enabled: has) { c.list.toggleQuickLook() },
            e(T("action.reveal_in_finder"), "arrow.up.forward.app", "⇧⌘R", enabled: has) { c.mReveal() },
            e(T("action.copy_path"), "doc.on.doc", "⌥⌘C", enabled: has) { c.copyPaths() },
            e(T("main.menu.rename"), "pencil", "E", enabled: has) { c.renameSelection() },
            e(T("main.palette.move_pick"), "arrow.turn.up.right", "M", enabled: has && Scripts.canWrite) { DispatchQueue.main.async { c.pickProject() } },
            e(T("main.palette.switch_project"), "arrow.left.arrow.right", hk(.project)) { AppEnvironment.island?.showSwitcher() },
            e(T("main.place.inbox"), "tray", "⌘1") { c.go(.inbox) },
            e(T("main.place.progress"), "circle.righthalf.filled", "⌘2") { c.go(.inProgress) },
            e(T("project.inbox"), "tray.2", "⌘3") { c.go(.unassigned) },
            e(T("main.place.all"), "list.bullet.rectangle", "⌘4") { c.go(.all) },
            e(T("main.empty.clear_filters"), "line.3.horizontal.decrease.circle", enabled: c.model.filtered) { c.clearFilters() },
            e(T("menu.rescan"), "arrow.clockwise") { c.model.scan() },
            e(T("dictation.history.menu"), "character.cursor.ibeam", "⌥⌘D") { c.showDictation() },
            e(T("menu.shortcuts"), "keyboard", "?") { c.showShortcuts() },
        ] + (DictationLabModel.enabled ? [e(T("dictation.lab.menu"), "waveform", "⌥⌘L") { c.showDictationLab() }] : [])
        // K3: what the selection can do from its state (hand off is above), with the hint as the detail
        out.insert(contentsOf: StateMenu.actions(for: items, canHandOff: false).map { a in
            Entry(title: StateMenu.title(a), detail: StateMenu.hint(a, items), image: Look.ring(StateMenu.target(a, items), size: 14),
                  keys: a == "discard" ? "⌫" : Lifecycle.keyLabel(a), enabled: Scripts.canWrite) { c.apply(a, to: items) }
        }, at: min(out.count, 6))
        for k in KindStyle.builtIn {
            out.append(Entry(title: T("main.palette.only_kind", Look.kindName(k)), detail: "", image: Look.kindImage(k, size: KindStyle.smallSize), keys: "", enabled: true) {
                c.model.kinds = [k]; c.model.reload()
            })
        }
        // what's running (organising, agent sessions): its progress or its terminal, as a click on its row
        for j in JobStore.shared.active {
            out.append(e(JobLook.title(j), JobLook.symbol(j), detail: JobLook.status(j)) { c.reveal(job: j.id) })
        }
        if AppEnvironment.settings != nil { out.append(e(T("menu.settings"), "gearshape", "⌘,") { AppEnvironment.settings?.show(pane: nil) }) }
        let current = ProjectStore.shared.currentID
        for p in c.model.projects where p.registered {
            out.append(e(p.name, "folder", detail: T("main.palette.project", (p.path.path as NSString).abbreviatingWithTildeInPath)) { c.reveal(project: p.id) })
            if !items.isEmpty {
                out.append(e(T("main.palette.move_to", p.name), "arrow.turn.up.right") { c.move(uids: items.map(\.uid), to: p.id) })
            }
            // where new captures go: the user's pick, never a guess (K2)
            if p.id != current {
                out.append(e(T("main.palette.use_project", p.name), "scope", detail: T("main.project.use.tip")) { c.useProject(p.id) })
            }
        }
        if current != nil {
            out.append(e(T("main.palette.use_none"), "tray.2", detail: T("app.menu.project.none_tip")) { c.useProject(nil) })
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
            // an id ("AW-11") is that item, wherever it is — a discarded one too — and it goes on top
            let byID = q.split(separator: " ").count == 1 && ItemQuery.isItemID(q)
            let rows = (try? r.items(ItemQuery(text: q, states: byID ? Lifecycle.states : [], limit: 8))) ?? []
            let items = rows.map { it in
                let title = it.title.isEmpty ? it.itemID : it.title
                let hit = SearchHit.adds(it.snippet, to: title) ? it.snippet.map { SearchHit.unmarked(SearchHit.shown($0)) } : nil
                // where it stands, once it is past To do (in progress, done…): the same words as the list
                let state = ["new", "todo"].contains(it.state) ? nil : Look.stateLabel(it)
                return Entry(title: title, detail: [it.itemID, it.projectName, state, hit].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                      image: Look.kindImage(it.kind, size: KindStyle.smallSize), keys: "", enabled: true) { [weak self] in
                    self?.controller.reveal(uid: it.uid)
                }
            }
            // a few strong command matches first, then items (the item itself first when its id was typed)
            let exact = byID && rows.first?.itemID.uppercased() == q.uppercased()
            entries = exact ? items + entries : Array(entries.prefix(4)) + items + Array(entries.dropFirst(4))
        }
        table.reloadData()
        resize()
        if let k = entries.firstIndex(where: { $0.enabled }) { table.selectRowIndexes([k], byExtendingSelection: false); table.scrollRowToVisible(k) }
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    /// Grow with the results (up to 9 rows), anchored at the top. The list is exactly that many rows tall and the panel
    /// fits around it.
    func resize() {
        let rows = CGFloat(min(max(entries.count, 1), Self.maxRows))
        listHeight.constant = rows * (table.rowHeight + table.intercellSpacing.height)
        panel.contentView?.layoutSubtreeIfNeeded()
        let h = panel.contentView?.fittingSize.height ?? 0
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

    /// The next enabled row, wrapping around. Nothing enabled (e.g. "copy" with nothing selected): stays put — the
    /// old loop never ended there, since no row was selected to come back to.
    func step(_ d: Int) {
        let n = entries.count
        guard n > 0, entries.contains(where: \.enabled) else { return }
        var k = table.selectedRow < 0 ? (d > 0 ? -1 : n) : table.selectedRow
        for _ in 0..<n {
            k = ((k + d) % n + n) % n
            if entries[k].enabled { break }
        }
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

/// The chosen row: the brand tint (§3.3), text stays `labelColor`. The panel never takes key from the main window, so
/// it doesn't fall back to the neutral not-key wash.
final class PaletteRowView: NSTableRowView {
    override var isEmphasized: Bool { get { false } set {} }
    override func drawSelection(in dirtyRect: NSRect) {
        BrandColor.tint.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
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
        keys.textColor = .secondaryLabelColor
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
        title.stringValue = SearchHit.oneLine(e.title)
        title.textColor = e.enabled ? .labelColor : .tertiaryLabelColor
        detail.stringValue = SearchHit.oneLine(e.detail)
        keys.stringValue = e.keys
        setAccessibilityLabel([e.title, e.detail, e.keys].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}
