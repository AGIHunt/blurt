// The middle column: the running jobs (K4) above a filter bar and a view-based NSTableView with a fixed row height.
// Dense one-line rows everywhere; All Items shows the same table with a header and every column. Keyboard-first:
// J/K, ↩, ⌘↩ (hand off), E, 1–4 (kind), Space (Quick Look), ⌘C (path), and K3's state keys — A keep, D done,
// R the one way back (send back / take back / reopen / restore), W won't do, X / ⌫ discard, S the state menu. Rows
// drag out as their primary frame (a file) and onto a project in the sidebar (move). Empty states for first run, no
// matches, nothing yet.
import AppKit
import BlurtCore
import Quartz

protocol ItemListActions: AnyObject {
    func listSelectionChanged()
    func openSelection()                       // ↩: focus the detail
    func handOffSelection()                    // ⌘↩
    func renameSelection()                     // E
    func setKind(_ kind: String)               // 1–4
    func act(key: String)                      // A D R W X ⌫: K3's actions, each item from its own state
    func showStateMenu(row: Int?, from view: NSView?)   // S, a click on a row's ring
    func copyPaths()                           // ⌘C
    func contextMenu(for rows: IndexSet) -> NSMenu?
    func showShortcuts()                       // ?
    func focusSearch()                         // /
    func emptyAction(_ tag: Int)               // buttons in the empty states
    func selectJob(_ id: String)               // a row of the jobs section
}

/// Pasteboard type for item uids dragged inside the window (onto a project in the sidebar).
extension NSPasteboard.PasteboardType {
    static let blurtItems = NSPasteboard.PasteboardType("dev.blurt.items")
}

final class ItemTableView: NSTableView {
    weak var actions: ItemListActions?
    var quickLook: (() -> Void)?

    override func keyDown(with e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let ch = e.charactersIgnoringModifiers ?? ""
        if mods == .command, e.keyCode == 36 || e.keyCode == 76 { actions?.handOffSelection(); return }
        if mods.isEmpty || mods == .shift {
            switch (e.keyCode, ch) {
            case (36, _), (76, _): actions?.openSelection(); return
            case (49, _): quickLook?(); return
            case (51, _), (117, _): actions?.act(key: "delete"); return
            case (_, "j"): move(1); return
            case (_, "k"): move(-1); return
            case (_, "e"): actions?.renameSelection(); return
            case (_, "s"): actions?.showStateMenu(row: selectedRowIndexes.first, from: nil); return
            case (_, "a"), (_, "d"), (_, "r"), (_, "w"), (_, "x"): actions?.act(key: ch.lowercased()); return
            case (_, "/"): actions?.focusSearch(); return
            case (_, "?"): actions?.showShortcuts(); return
            case (_, "1"): actions?.setKind("issue"); return
            case (_, "2"): actions?.setKind("idea"); return
            case (_, "3"): actions?.setKind("note"); return
            case (_, "4"): actions?.setKind("task"); return
            default: break
            }
        }
        super.keyDown(with: e)
    }

    func move(_ d: Int) {
        guard numberOfRows > 0 else { return }
        let cur = selectedRow < 0 ? (d > 0 ? -1 : numberOfRows) : selectedRow
        let n = max(0, min(numberOfRows - 1, cur + d))
        selectRowIndexes([n], byExtendingSelection: false)
        scrollRowToVisible(n)
    }

    @objc func copy(_ sender: Any?) { actions?.copyPaths() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let r = row(at: p)
        guard r >= 0 else { return nil }
        if !selectedRowIndexes.contains(r) { selectRowIndexes([r], byExtendingSelection: false) }
        return actions?.contextMenu(for: selectedRowIndexes)
    }

    // Quick Look panel (Space): the controller supplies the items
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = (delegate as? QLPreviewPanelDataSource)
        panel.delegate = (delegate as? QLPreviewPanelDelegate)
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

/// Big centred message with an image (or the mascot, for the friendly ones) and up to two buttons.
final class EmptyStateView: NSView {
    let icon = NSImageView()
    let chick = MascotView(size: 80)
    let title = NSTextField(labelWithString: "")
    let message = NSTextField(wrappingLabelWithString: "")
    let buttons = NSStackView()
    let spinner = NSProgressIndicator()
    var onButton: ((Int) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.preferredMaxLayoutWidth = 300
        icon.symbolConfiguration = .init(pointSize: 34, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [icon, chick, spinner, title, message, buttons])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(14, after: message)
        stack.setCustomSpacing(2, after: chick)
        chick.translatesAutoresizingMaskIntoConstraints = false
        chick.widthAnchor.constraint(equalToConstant: 80).isActive = true
        chick.heightAnchor.constraint(equalToConstant: 80).isActive = true
        chick.isHidden = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
                                     stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40)])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `mascot`: the chick instead of the symbol (a loop keeps playing; a one-shot plays once each time the state appears).
    func show(symbol: String?, image: NSImage? = nil, mascot: MascotClip? = nil, title t: String, message m: String,
              buttons bs: [(String, Int)] = [], busy: Bool = false) {
        icon.image = mascot == nil ? image ?? symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) } : nil
        icon.isHidden = icon.image == nil || busy
        if let c = mascot, !busy {
            let fresh = chick.isHidden || chick.mascot.clip != c
            chick.isHidden = false
            if fresh { chick.play(c) }
        } else {
            chick.stop()
            chick.isHidden = true
        }
        icon.setAccessibilityElement(false); icon.cell?.setAccessibilityElement(false)      // decoration (an SF Symbol's own name, e.g. "split view", says nothing here)
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        title.stringValue = t
        message.stringValue = m
        message.isHidden = m.isEmpty
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (k, (label, tag)) in bs.enumerated() {
            let b = NSButton(title: label, target: self, action: #selector(tap(_:)))
            b.tag = tag
            b.bezelStyle = .rounded
            if k == 0 { b.keyEquivalent = "\r" }
            buttons.addArrangedSubview(b)
        }
        buttons.isHidden = bs.isEmpty
        isHidden = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel([t, m].filter { !$0.isEmpty }.joined(separator: ". "))
    }

    @objc func tap(_ b: NSButton) { onButton?(b.tag) }
}

/// The inbox's top row while captures hang under the island waiting for a project (K7): "Unfiled captures: 3" — a click
/// opens the island with every card down (they stay until the pointer has come and gone). Hidden when there are none.
final class CapturesBanner: NSView {
    var onClick: (() -> Void)?
    private let row = JobRow()

    override init(frame: NSRect) {
        super.init(frame: frame)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.title.font = .systemFont(ofSize: 12, weight: .semibold)
        row.status.textColor = .controlAccentColor
        row.bar.isHidden = true
        row.spinner.isHidden = true
        row.icon.image = BlurtIcon.snap.image(size: 15)
        row.icon.contentTintColor = .controlAccentColor
        row.onClick = { [weak self] in self?.onClick?() }
        addSubview(row)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6), row.bottomAnchor.constraint(equalTo: line.topAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(count: Int) {
        isHidden = count == 0
        guard count > 0 else { return }
        row.title.stringValue = TP("main.captures.unfiled", count)
        row.status.stringValue = T("main.captures.show")
        row.setAccessibilityLabel("\(row.title.stringValue), \(row.status.stringValue)")
        row.toolTip = T("main.captures.tip")
    }
}

/// Kind segments and the state filter (the count is the window's subtitle).
final class FilterBar: NSView {
    let kinds = NSSegmentedControl()
    let state = NSPopUpButton()
    var onChange: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        kinds.segmentCount = KindStyle.builtIn.count
        kinds.trackingMode = .selectAny
        kinds.segmentStyle = .roundRect
        kinds.controlSize = .small
        for (k, key) in KindStyle.builtIn.enumerated() {
            kinds.setImage(Look.kindImage(key), forSegment: k)
            kinds.setImageScaling(.scaleNone, forSegment: k)
            kinds.setWidth(28, forSegment: k)
            kinds.setToolTip(T("main.filter.only_kind", Look.kindName(key), k + 1), forSegment: k)
        }
        kinds.target = self
        kinds.action = #selector(changed)
        kinds.setAccessibilityLabel(T("main.filter.kind"))
        state.controlSize = .small
        state.font = .systemFont(ofSize: 11)
        state.bezelStyle = .recessed
        state.isBordered = true
        state.target = self
        state.action = #selector(changed)
        // All but discarded · Needs you · each live state · Discarded (only here: K3)
        func add(_ title: String, _ value: String?, ring: String?) {
            state.addItem(withTitle: title)
            state.lastItem?.representedObject = value
            state.lastItem?.image = ring.map { Look.ring($0, size: 12) }
        }
        add(T("main.filter.live"), nil, ring: nil)
        add(T("main.filter.needs_you"), "inbox", ring: nil)
        state.lastItem?.image = Look.symbol("tray", "", size: 11)
        state.menu?.addItem(.separator())
        for s in Lifecycle.live { add(Look.stateName(s), s, ring: s) }
        state.menu?.addItem(.separator())
        add(Look.stateName("discarded"), "discarded", ring: "discarded")
        state.setAccessibilityLabel(T("main.filter.state"))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [kinds, state, spacer])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func changed() { onChange?() }

    var selectedKinds: Set<String> {
        Set(KindStyle.builtIn.enumerated().filter { kinds.isSelected(forSegment: $0.offset) }.map(\.element))
    }

    func sync(_ m: MainModel) {
        for (k, key) in KindStyle.builtIn.enumerated() { kinds.setSelected(m.kinds.contains(key), forSegment: k) }
        state.selectItem(at: state.itemArray.firstIndex { !$0.isSeparatorItem && $0.representedObject as? String == m.state } ?? 0)
        let ready = m.indexState == .ready
        kinds.isHidden = !ready
        state.isHidden = !ready || m.scope == .inbox
    }
}

final class ItemListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let model: MainModel
    weak var actions: ItemListActions? { didSet { table.actions = actions } }
    let table = ItemTableView()
    let jobs = JobsSection()
    let captures = CapturesBanner()
    let bar = FilterBar()
    let empty = EmptyStateView()
    let scroll = NSScrollView()
    private var suppressSelection = false
    private var header: NSTableHeaderView?
    private var appliedLayout: [Bool] = []

    init(model: MainModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    struct Col { let id: String; let title: String; let width: CGFloat; let min: CGFloat; let max: CGFloat; let sort: String? }
    static var columns: [Col] { [
        Col(id: "lead", title: "", width: 44, min: 22, max: 44, sort: "kind"),
        Col(id: "title", title: T("main.col.title"), width: 260, min: 140, max: 4000, sort: "title"),
        Col(id: "meta", title: T("main.col.id"), width: 64, min: 48, max: 120, sort: "id"),
        Col(id: "project", title: T("main.col.project"), width: 110, min: 60, max: 240, sort: "project"),
        Col(id: "state", title: T("main.col.state"), width: 120, min: 60, max: 220, sort: "state"),
        Col(id: "time", title: T("main.col.updated"), width: 78, min: 56, max: 140, sort: "updated"),
    ] }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 600))
        for c in Self.columns {
            let col = NSTableColumn(identifier: .init(c.id))
            col.title = c.title
            col.width = c.width
            col.minWidth = c.min
            col.maxWidth = c.max
            if let s = c.sort { col.sortDescriptorPrototype = NSSortDescriptor(key: s, ascending: ["title", "kind", "state", "project"].contains(s)) }
            if c.id == "lead" { col.headerToolTip = T("main.col.kind") }
            if c.id == "time" { col.headerCell.alignment = .right }
            table.addTableColumn(col)
        }
        table.style = .inset
        table.rowHeight = Look.rowHeight
        table.usesAutomaticRowHeights = false
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.setAccessibilityLabel(T("main.list.label"))
        table.quickLook = { [weak self] in self?.toggleQuickLook() }
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        header = table.headerView
        table.tableColumns.forEach { $0.resizingMask = $0.identifier.rawValue == "title" ? [.autoresizingMask, .userResizingMask] : .userResizingMask }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        bar.onChange = { [weak self] in self?.filtersChanged() }
        jobs.onSelect = { [weak self] id in self?.actions?.selectJob(id) }
        empty.isHidden = true
        empty.onButton = { [weak self] t in self?.actions?.emptyAction(t) }
        captures.onClick = { AppEnvironment.island?.revealCards() }
        NotificationCenter.default.addObserver(forName: .blurtCardsChanged, object: nil, queue: .main) { [weak self] _ in self?.reloadCaptures() }
        let stack = NSStackView(views: [captures, jobs, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        for v in [stack, scroll, empty] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            captures.widthAnchor.constraint(equalTo: stack.widthAnchor),
            jobs.widthAnchor.constraint(equalTo: stack.widthAnchor), bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: stack.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.topAnchor.constraint(equalTo: stack.bottomAnchor), empty.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.leadingAnchor.constraint(equalTo: root.leadingAnchor), empty.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
        applyLayout()
    }

    /// Dense list vs. full table: which columns show, whether there is a header.
    func applyLayout() {
        let full = model.scope.isTable
        let inProject: Bool = { if case .project = model.scope { return true }; return model.scope == .unassigned }()
        // only when the layout changes: a column the user resized keeps its width across reloads
        guard appliedLayout != [full, inProject] else { return }
        appliedLayout = [full, inProject]
        metaWant = full ? 0 : (inProject ? 56 : 132)
        for c in table.tableColumns {
            switch c.identifier.rawValue {
            case "lead": c.width = full ? 22 : 44
            case "project": c.isHidden = inProject || !full; c.width = 100
            case "meta": c.width = full ? 58 : (inProject ? 56 : 132); c.maxWidth = full ? 120 : 200
            case "state": c.isHidden = !full; c.width = 120
            case "time": c.width = 72
            default: break
            }
        }
        table.headerView = full ? header : nil
        fitTitle()
    }

    /// The title column takes whatever the fixed columns leave (users can still resize those).
    override func viewDidLayout() {
        super.viewDidLayout()
        fitTitle()
    }

    /// The dense list's id column at full width ("AW-2 · Atlas Web"); 0 in the table, where the user sizes it.
    private var metaWant: CGFloat = 0
    /// Below this the id column shows the key alone.
    static let metaWithProject: CGFloat = 110

    func fitTitle() {
        guard let title = table.tableColumn(withIdentifier: .init("title")) else { return }
        let others = table.tableColumns.filter { $0 !== title && !$0.isHidden }
        let spacing = table.intercellSpacing.width * CGFloat(others.count + 1) + 24   // + the inset style's margins
        func room() -> CGFloat { scroll.contentView.bounds.width - others.reduce(0) { $0 + $1.width } - spacing }
        // a narrow list (a job's detail beside it): the id column gives up the project name before the title is
        // squeezed, and no column ever ends up past the list's edge
        if metaWant > 0, let meta = table.tableColumn(withIdentifier: .init("meta")) {
            let mw = min(metaWant, max(meta.minWidth, room() + meta.width - 200))
            if abs(meta.width - mw) > 0.5 {
                let crossed = (meta.width < Self.metaWithProject) != (mw < Self.metaWithProject)
                meta.width = mw
                if crossed, let col = table.tableColumns.firstIndex(of: meta) {
                    table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows), columnIndexes: [col])
                }
            }
        }
        let w = room()
        if abs(title.width - max(title.minWidth, w)) > 0.5 { title.width = max(title.minWidth, w) }
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard let c = notification.userInfo?["NSTableColumn"] as? NSTableColumn, c.identifier.rawValue != "title" else { return }
        DispatchQueue.main.async { [weak self] in self?.fitTitle() }
    }

    // MARK: reload

    /// Reload rows, keeping the selection (by uid) and the scroll position where possible.
    func reload(keep: [String]? = nil) {
        let keepIDs = keep ?? selectionIDs     // captured before the model changed (row numbers mean other rows now)
        let top = table.rows(in: table.visibleRect).location
        let topID = id(at: top)
        let firstSelected = table.selectedRowIndexes.first
        suppressSelection = true
        applyLayout()
        table.reloadData()
        var set = IndexSet()
        for k in keepIDs { if let r = model.row(of: k) { set.insert(r) } }
        // the selection left this list (kept out of the inbox, discarded, moved): the next row takes its place, like Mail
        if set.isEmpty, keep == nil, !keepIDs.isEmpty, let f = firstSelected, model.rowCount > 0, view.window?.firstResponder === table {
            set.insert(min(f, model.rowCount - 1))
        }
        table.selectRowIndexes(set, byExtendingSelection: false)
        if let t = topID, let r = model.row(of: t), r != top, keep == nil {
            table.scroll(NSPoint(x: 0, y: table.rect(ofRow: r).minY - (table.headerView?.frame.height ?? 0)))
        } else if keep != nil, let first = set.first {
            table.scrollRowToVisible(first)
        }
        suppressSelection = false
        bar.sync(model)
        reloadCaptures()
        updateEmpty()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
        let ids = set.compactMap { id(at: $0) }
        if ids != selectionIDs { selectionIDs = ids; actions?.listSelectionChanged() }
    }
    /// The selected uids, kept up to date on every selection change.
    private(set) var selectionIDs: [String] = []
    func forgetSelection() { selectionIDs = [] }

    func id(at row: Int) -> String? { row >= 0 && row < model.uids.count ? model.uids[row] : nil }
    var selectedIDs: [String] { table.selectedRowIndexes.compactMap { id(at: $0) } }
    var selectedItems: [ItemRow] { table.selectedRowIndexes.compactMap { model.item(at: $0) } }

    func select(id: String) {
        guard let r = model.row(of: id) else { return }
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    func filtersChanged() {
        model.kinds = bar.selectedKinds
        model.state = bar.state.selectedItem?.representedObject as? String
        model.reload()
    }

    func reloadJobs() { jobs.set(model.jobs, store: ProjectStore.shared, showProject: model.scope.projectID == nil) }
    /// "Unfiled captures: N" on top of the inbox while cards hang under the island.
    func reloadCaptures() { captures.set(count: model.scope == .inbox ? AppEnvironment.island?.hangingCount ?? 0 : 0) }

    func updateEmpty() {
        switch model.indexState {
        case .scanning:
            empty.show(symbol: nil, title: T("main.empty.scanning"), message: "", busy: true)
            return
        case .noScripts:
            empty.show(symbol: "puzzlepiece.extension", title: T("main.empty.no_scripts"), message: T("main.empty.no_scripts.detail"))
            return
        case .missing:
            empty.show(symbol: "tray.full", title: T("main.empty.no_index"), message: T("main.empty.no_index.detail"),
                       buttons: [(T("main.empty.scan"), 1)])
            return
        case .outdated:
            empty.show(symbol: "arrow.triangle.2.circlepath", title: T("main.empty.outdated"), message: T("main.empty.outdated.detail"),
                       buttons: [(T("main.empty.rebuild"), 1)])
            return
        case .failed(let e):
            empty.show(symbol: "exclamationmark.triangle", title: T("main.empty.scan_failed"), message: e, buttons: [(T("action.retry"), 1)])
            return
        case .ready: break
        }
        guard model.rowCount == 0 else { empty.isHidden = true; return }
        let q = model.text.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            empty.show(symbol: "magnifyingglass", title: T("main.empty.no_results", q),
                       message: model.kinds.count + (model.state == nil ? 0 : 1) > 0
                           ? T("main.empty.filters_on") : T("main.empty.try_shorter"),
                       buttons: [(T("main.empty.clear_all"), 2)])
        } else if model.state == "discarded", model.kinds.isEmpty {
            empty.show(symbol: nil, image: Look.ring("discarded", size: 34), title: T("main.empty.discarded"), message: T("main.empty.discarded.detail"),
                       buttons: [(T("main.empty.clear_filters"), 2)])
        } else if model.filtered {
            empty.show(symbol: "line.3.horizontal.decrease.circle", title: T("main.empty.no_match"), message: "",
                       buttons: [(T("main.empty.clear_filters"), 2)])
        } else {
            switch model.scope {
            case .inbox where model.counts.all > 0:
                empty.show(symbol: nil, mascot: .happy, title: T("main.empty.inbox_zero"), message: T("main.empty.inbox_zero.detail"))
            case .inProgress:
                empty.show(symbol: nil, mascot: .idle, title: T("main.empty.nothing_in_progress"), message: T("main.empty.nothing_in_progress.detail"))
            case .unassigned:
                empty.show(symbol: nil, mascot: .idle, title: T("main.empty.all_filed"), message: T("main.empty.all_filed.detail"))
            case .project(let p):
                let current = ProjectStore.shared.currentID == p
                empty.show(symbol: nil, mascot: .idle, title: T("main.empty.project"), message: T("main.empty.project.detail", hk(.toggleRecord), hk(.snap)),
                           buttons: current ? [(T("main.action.record"), 3), (T("main.action.snap"), 4)]
                                            : [(T("main.project.use"), 6), (T("main.action.record"), 3)])
            default:
                empty.show(symbol: nil, mascot: .idle, title: T("main.empty.first"), message: T("main.empty.first.detail", hk(.toggleRecord), hk(.snap)),
                           buttons: [(T("project.open_folder"), 5), (T("main.action.record"), 3)])
            }
        }
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { model.indexState == .ready ? model.rowCount : 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn?.identifier.rawValue, let it = model.item(at: row) else { return nil }
        return itemCell(col, it)
    }

    func make<T: NSView>(_ id: String, _ f: () -> T) -> T {
        if let v = table.makeView(withIdentifier: .init(id), owner: self) as? T { return v }
        let v = f()
        v.identifier = .init(id)
        return v
    }

    var inOwnProject: Bool { if case .project = model.scope { return true }; return model.scope == .unassigned }

    func itemCell(_ col: String, _ it: ItemRow) -> NSView? {
        let quiet = it.discarded || Lifecycle.closed.contains(it.state)
        switch col {
        case "lead":
            let c = make("lead") { () -> LeadCell in
                let c = LeadCell()
                c.ring.target = self
                c.ring.action = #selector(ringClicked(_:))
                return c
            }
            c.kindImage = Look.kindImage(it.kind)
            c.icon.alphaValue = it.discarded ? 0.4 : 1
            c.icon.setAccessibilityLabel(Look.kindName(it.kind))
            c.showsRing = !model.scope.isTable
            c.ring.set(it.state, label: Look.stateLabel(it))
            c.ring.isEnabled = !it.legacy
            return c
        case "title":
            let c = make("title") { TitleCell() }
            // the search hit, unless it is just the title again
            let plain = (it.snippet ?? "").replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "…"))
            let searching = !model.text.trimmingCharacters(in: .whitespaces).isEmpty
            let hit = searching && !plain.isEmpty && !it.title.contains(plain) ? it.snippet : nil
            c.set(title: it.title, unread: it.state == "new", dimmed: quiet, struck: false, hit: hit)
            c.toolTip = [it.quote.isEmpty ? nil : "“\(it.quote)”", it.sessionTitle].compactMap { $0 }.joined(separator: "\n")
            return c
        case "meta":
            let c = make("meta") { MetaCell() }
            let full = model.scope.isTable
            let roomy = (table.tableColumn(withIdentifier: .init("meta"))?.width ?? 0) >= Self.metaWithProject
            c.key.stringValue = full || inOwnProject || it.projectID == "inbox" || !roomy ? it.itemID : "\(it.itemID) · \(it.projectName)"
            c.toolTip = it.projectID == "inbox" ? nil : it.projectName
            c.key.alignment = full ? .left : .right
            return c
        case "project":
            let c = make("icontext") { IconTextCell() }
            c.set(it.projectID == "inbox" ? T("project.inbox") : it.projectName)
            return c
        case "state":
            let c = make("state") { () -> StateCell in
                let c = StateCell()
                c.button.target = self
                c.button.action = #selector(ringClicked(_:))
                return c
            }
            c.set(it.state, label: Look.stateLabel(it))
            c.button.isEnabled = !it.legacy
            return c
        case "time":
            let c = make("time") { IconTextCell() }
            c.set(MainModel.relative(it.updated), font: Look.monoSub, align: .right)
            c.label.textColor = .tertiaryLabelColor
            c.toolTip = MainModel.shortDate(it.updated)
            return c
        default: return nil
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = make("row") { ItemRowView() }
        if let it = model.item(at: row) {
            v.label = [Look.kindName(it.kind), it.title.isEmpty ? T("main.item.untitled") : it.title, it.itemID, Look.stateLabel(it),
                       it.projectID == "inbox" ? T("project.inbox") : it.projectName,
                       MainModel.relative(it.updated)].joined(separator: ", ")
        }
        return v
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }    // reload() settles the selection itself
        selectionIDs = selectedIDs
        actions?.listSelectionChanged()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key, key != model.sort || d.ascending != model.ascending else { return }
        model.sort = key
        model.ascending = d.ascending
        model.reload()
    }

    /// A row's ring (or the State column): select that row unless it is part of the selection, then its state menu.
    @objc func ringClicked(_ sender: NSButton) {
        let r = table.row(for: sender)
        guard r >= 0 else { return }
        if !table.selectedRowIndexes.contains(r) { table.selectRowIndexes([r], byExtendingSelection: false) }
        view.window?.makeFirstResponder(table)
        actions?.showStateMenu(row: r, from: sender)
    }

    /// The ring of a row on screen (the S key opens the menu under it).
    func ringView(row r: Int) -> NSView? {
        let id = model.scope.isTable ? "state" : "lead"
        guard let col = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }) else { return nil }
        table.scrollRowToVisible(r)
        switch table.view(atColumn: col, row: r, makeIfNecessary: false) {
        case let c as LeadCell: return c.ring
        case let c as StateCell: return c.button
        default: return nil
        }
    }

    @objc func doubleClicked() {
        guard table.clickedRow >= 0 else { return }
        actions?.openSelection()
    }

    // drag rows: the uids (onto a project), the primary frame as a file (Finder makes a copy, Terminal pastes the path)
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let it = model.item(at: row) else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(it.uid, forType: .blurtItems)
        if let f = it.primaryFrame, FileManager.default.fileExists(atPath: f) {
            pb.setString(URL(fileURLWithPath: f).absoluteString, forType: .fileURL)
        }
        pb.setString(it.title, forType: .string)
        return pb
    }

    // MARK: Quick Look

    var previewURLs: [URL] {
        selectedItems.compactMap { $0.primaryFrame.map { URL(fileURLWithPath: $0) } }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    var quickLookOverride: [URL]?

    func toggleQuickLook(_ urls: [URL]? = nil) {
        quickLookOverride = urls
        let p = QLPreviewPanel.shared()!
        if p.isVisible && urls == nil {
            p.orderOut(nil)
        } else {
            guard !(urls ?? previewURLs).isEmpty else { NSSound.beep(); return }
            view.window?.makeFirstResponder(table)
            p.makeKeyAndOrderFront(nil)
            p.reloadData()
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { (quickLookOverride ?? previewURLs).count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let u = quickLookOverride ?? previewURLs
        return index < u.count ? u[index] as NSURL : nil
    }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, quickLookOverride == nil, [125, 126].contains(event.keyCode) || ["j", "k"].contains(event.charactersIgnoringModifiers ?? "") {
            table.move(event.keyCode == 125 || event.charactersIgnoringModifiers == "j" ? 1 : -1)
            return true
        }
        return false
    }
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard quickLookOverride == nil, let r = table.selectedRowIndexes.first, let w = view.window else { return .zero }
        let cell = table.frameOfCell(atColumn: 0, row: r)
        return w.convertToScreen(table.convert(cell, to: nil))
    }
}
