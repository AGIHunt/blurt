// The middle column: a filter bar (kind eggs, status, fix state, count) over a view-based NSTableView with a fixed
// row height. Lists items, or sessions for Inbox / All Sessions. Keyboard-first (§2.5): J/K, ↩, ⌘↩, E, 1–4, S, R,
// Space (Quick Look of the primary frame), ⌘C (path), ⌫ (drop). Empty states for first run, no matches, nothing yet.
import AppKit
import BlurtCore
import Quartz

protocol ItemListActions: AnyObject {
    func listSelectionChanged()
    func openSelection()                       // ↩: focus the detail
    func fixSelection()                        // ⌘↩
    func renameSelection()                     // E
    func setKind(_ kind: String)               // 1–4
    func cycleStatus()                         // S
    func setStatus(_ status: String)
    func reviewMode()                          // R
    func copyPaths()                           // ⌘C
    func contextMenu(for rows: IndexSet) -> NSMenu?
    func showShortcuts()                       // ?
    func focusSearch()                         // /
    func emptyAction(_ tag: Int)               // buttons in the empty states
}

final class ItemTableView: NSTableView {
    weak var actions: ItemListActions?
    var quickLook: (() -> Void)?

    override func keyDown(with e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let ch = e.charactersIgnoringModifiers ?? ""
        if mods == .command, e.keyCode == 36 || e.keyCode == 76 { actions?.fixSelection(); return }
        if mods.isEmpty || mods == .shift {
            switch (e.keyCode, ch) {
            case (36, _), (76, _): actions?.openSelection(); return
            case (49, _): quickLook?(); return
            case (51, _), (117, _): actions?.setStatus("deleted"); return
            case (_, "j"): move(1); return
            case (_, "k"): move(-1); return
            case (_, "e"): actions?.renameSelection(); return
            case (_, "s"): actions?.cycleStatus(); return
            case (_, "r"): actions?.reviewMode(); return
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

/// Big centred message with an SF Symbol and up to two buttons.
final class EmptyStateView: NSView {
    let icon = NSImageView()
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
        let stack = NSStackView(views: [icon, spinner, title, message, buttons])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(14, after: message)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
                                     stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40)])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(symbol: String?, image: NSImage? = nil, title t: String, message m: String, buttons bs: [(String, Int)] = [], busy: Bool = false) {
        icon.image = image ?? symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.isHidden = icon.image == nil || busy
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        title.stringValue = t
        message.stringValue = m
        message.isHidden = m.isEmpty
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (k, (label, tag)) in bs.enumerated() {
            let b = NSButton(title: label, target: self, action: #selector(tap(_:)))
            b.tag = tag
            b.bezelStyle = .rounded
            if k == 0 { b.keyEquivalent = "\r"; b.bezelColor = Look.brand }
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

final class FilterBar: NSView {
    let kinds = NSSegmentedControl()
    let status = NSPopUpButton()
    let fix = NSPopUpButton()
    let count = NSTextField(labelWithString: "")
    var onChange: (() -> Void)?
    static let kindKeys = ["issue", "idea", "note", "task"]

    override init(frame: NSRect) {
        super.init(frame: frame)
        kinds.segmentCount = 4
        kinds.trackingMode = .selectAny
        kinds.segmentStyle = .rounded
        kinds.controlSize = .small
        for (k, key) in Self.kindKeys.enumerated() {
            kinds.setImage(BrandIcon.kind(key, variant: "bar", size: 14), forSegment: k)
            kinds.setLabel(Look.kindName(key), forSegment: k)
            kinds.setImageScaling(.scaleProportionallyDown, forSegment: k)
            kinds.setToolTip(L("只看", "Only ") + Look.kindName(key) + " (\(k + 1))", forSegment: k)
        }
        kinds.target = self
        kinds.action = #selector(changed)
        kinds.setAccessibilityLabel(L("按类型筛选", "Filter by kind"))
        for p in [status, fix] {
            p.controlSize = .small
            p.font = .systemFont(ofSize: 11)
            p.bezelStyle = .recessed
            p.isBordered = true
            p.target = self
            p.action = #selector(changed)
        }
        let st: [(String, String?)] = [(L("全部状态", "Any Status"), nil), (L("待审", "Draft"), "draft"),
                                        (L("已确认", "Confirmed"), "confirmed"), (L("已丢弃", "Dropped"), "deleted")]
        for (t, v) in st { status.addItem(withTitle: t); status.lastItem?.representedObject = v }
        let fx: [(String, String?)] = [(L("修复：全部", "Any Fix State"), nil), (L("没交给 agent", "Not Sent"), "none"),
                                        (L("修复中", "Fixing"), "fixing"), (L("已修复", "Fixed"), "fixed"),
                                        (L("不修", "Won't Fix"), "wontfix"), (L("重新打开", "Reopened"), "reopened")]
        for (t, v) in fx { fix.addItem(withTitle: t); fix.lastItem?.representedObject = v }
        status.setAccessibilityLabel(L("按状态筛选", "Filter by status"))
        fix.setAccessibilityLabel(L("按修复状态筛选", "Filter by fix state"))
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [kinds, status, fix, spacer, count])
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
            heightAnchor.constraint(equalToConstant: 34),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func changed() { onChange?() }

    var selectedKinds: Set<String> {
        Set(Self.kindKeys.enumerated().filter { kinds.isSelected(forSegment: $0.offset) }.map(\.element))
    }

    func sync(_ m: MainModel) {
        for (k, key) in Self.kindKeys.enumerated() { kinds.setSelected(m.kinds.contains(key), forSegment: k) }
        status.selectItem(at: status.itemArray.firstIndex { $0.representedObject as? String == m.status } ?? 0)
        fix.selectItem(at: fix.itemArray.firstIndex { $0.representedObject as? String == m.fix } ?? 0)
        let listsSessions = m.scope.listsSessions || m.indexState != .ready
        kinds.isHidden = listsSessions
        status.isHidden = listsSessions
        count.isHidden = m.indexState != .ready
        fix.isHidden = listsSessions || m.scope == .smart(.fixing) || m.scope == .smart(.fixed)
        let n = NumberFormatter.localizedString(from: m.rowCount as NSNumber, number: .decimal)
        count.stringValue = listsSessions ? L("\(n) 个会话", "\(n) sessions") : L("\(n) 条", m.rowCount == 1 ? "1 item" : "\(n) items")
    }
}

final class ItemListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let model: MainModel
    weak var actions: ItemListActions? { didSet { table.actions = actions } }
    let table = ItemTableView()
    let bar = FilterBar()
    let empty = EmptyStateView()
    let scroll = NSScrollView()
    private var suppressSelection = false

    init(model: MainModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    struct Col { let id: String; let title: String; let width: CGFloat; let min: CGFloat; let max: CGFloat; let sort: String? }
    static let columns = [
        Col(id: "egg", title: "", width: 30, min: 30, max: 30, sort: "kind"),
        Col(id: "title", title: L("标题", "Title"), width: 220, min: 140, max: 2000, sort: "title"),
        Col(id: "status", title: L("状态", "Status"), width: 84, min: 60, max: 120, sort: "status"),
        Col(id: "fix", title: L("修复", "Fix"), width: 92, min: 60, max: 140, sort: "fix"),
        Col(id: "project", title: L("项目", "Project"), width: 104, min: 60, max: 220, sort: nil),
        Col(id: "time", title: L("更新", "Updated"), width: 86, min: 60, max: 140, sort: "updated"),
    ]

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 600))
        for c in Self.columns {
            let col = NSTableColumn(identifier: .init(c.id))
            col.title = c.title
            col.width = c.width
            col.minWidth = c.min
            col.maxWidth = c.max
            if let s = c.sort { col.sortDescriptorPrototype = NSSortDescriptor(key: s, ascending: s == "title" || s == "kind" || s == "status") }
            if c.id == "egg" { col.headerToolTip = L("类型", "Kind") }
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
        table.setAccessibilityLabel(L("条目", "Items"))
        table.quickLook = { [weak self] in self?.toggleQuickLook() }
        table.registerForDraggedTypes([])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        // let the title column take the slack
        table.tableColumns.forEach { $0.resizingMask = $0.identifier.rawValue == "title" ? [.autoresizingMask, .userResizingMask] : .userResizingMask }
        table.sizeLastColumnToFit()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        bar.onChange = { [weak self] in self?.filtersChanged() }
        empty.isHidden = true
        empty.onButton = { [weak self] t in self?.actions?.emptyAction(t) }
        for v in [bar, scroll, empty] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor), bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.topAnchor.constraint(equalTo: bar.bottomAnchor), empty.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.leadingAnchor.constraint(equalTo: root.leadingAnchor), empty.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
    }

    /// The title column takes whatever the fixed columns leave (users can still resize those).
    override func viewDidLayout() {
        super.viewDidLayout()
        fitTitle()
    }

    func fitTitle() {
        guard let title = table.tableColumn(withIdentifier: .init("title")) else { return }
        let others = table.tableColumns.filter { $0 !== title && !$0.isHidden }
        let spacing = table.intercellSpacing.width * CGFloat(others.count + 1) + 24   // + the inset style's margins
        let w = scroll.contentView.bounds.width - others.reduce(0) { $0 + $1.width } - spacing
        if abs(title.width - max(title.minWidth, w)) > 0.5 { title.width = max(title.minWidth, w) }
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard let c = notification.userInfo?["NSTableColumn"] as? NSTableColumn, c.identifier.rawValue != "title" else { return }
        DispatchQueue.main.async { [weak self] in self?.fitTitle() }
    }

    // MARK: reload

    /// Reload rows, keeping the selection (by uid / session id) and the scroll position where possible.
    func reload(keep: [String]? = nil) {
        let keepIDs = keep ?? selectionIDs     // captured before the model changed (row numbers mean other rows now)
        let top = table.rows(in: table.visibleRect).location
        let topID = id(at: top)
        suppressSelection = true
        table.reloadData()
        var set = IndexSet()
        for k in keepIDs { if let r = row(of: k) { set.insert(r) } }
        table.selectRowIndexes(set, byExtendingSelection: false)
        if let t = topID, let r = row(of: t), r != top, keep == nil {
            table.scroll(NSPoint(x: 0, y: table.rect(ofRow: r).minY - table.headerView!.frame.height))
        } else if keep != nil, let first = set.first {
            table.scrollRowToVisible(first)
        }
        suppressSelection = false
        bar.sync(model)
        updateEmpty()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
        let ids = set.compactMap { id(at: $0) }
        if ids != selectionIDs { selectionIDs = ids; actions?.listSelectionChanged() }
    }
    /// The selected uids / session ids, kept up to date on every selection change.
    private(set) var selectionIDs: [String] = []
    func forgetSelection() { selectionIDs = [] }

    func id(at row: Int) -> String? {
        model.scope.listsSessions ? model.session(at: row)?.id : (row >= 0 && row < model.uids.count ? model.uids[row] : nil)
    }
    func row(of id: String) -> Int? { model.scope.listsSessions ? model.row(ofSession: id) : model.row(of: id) }
    var selectedIDs: [String] { table.selectedRowIndexes.compactMap { id(at: $0) } }
    var selectedItems: [ItemRow] { model.scope.listsSessions ? [] : table.selectedRowIndexes.compactMap { model.item(at: $0) } }
    var selectedSessions: [SessionRow] { model.scope.listsSessions ? table.selectedRowIndexes.compactMap { model.session(at: $0) } : [] }

    func select(id: String) {
        guard let r = row(of: id) else { return }
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    func filtersChanged() {
        model.kinds = bar.selectedKinds
        model.status = bar.status.selectedItem?.representedObject as? String
        model.fix = bar.fix.selectedItem?.representedObject as? String
        model.reload()
    }

    func updateEmpty() {
        let titleCol = table.tableColumn(withIdentifier: .init("title"))
        titleCol?.title = model.scope.listsSessions ? L("会话", "Session") : L("标题", "Title")
        table.tableColumn(withIdentifier: .init("status"))?.title = model.scope.listsSessions ? L("进度", "Progress") : L("状态", "Status")
        table.tableColumn(withIdentifier: .init("fix"))?.title = model.scope.listsSessions ? L("条目", "Items") : L("修复", "Fix")
        table.tableColumn(withIdentifier: .init("time"))?.title = model.scope.listsSessions ? L("录制于", "Recorded") : L("更新", "Updated")
        let hideProject: Bool = { if case .workspace = model.scope { return true }; return false }()
        if projectColumn?.isHidden != hideProject { projectColumn?.isHidden = hideProject; fitTitle() }
        switch model.indexState {
        case .scanning:
            empty.show(symbol: nil, title: L("正在扫描录制…", "Scanning your recordings…"), message: "", busy: true)
            return
        case .noScripts:
            empty.show(symbol: "puzzlepiece.extension", title: L("找不到 blurt skill 的脚本", "The blurt skill's scripts are missing"),
                       message: L("先在终端里装好或更新 skill（npx skills add AGIHunt/blurt），然后重开这个窗口。",
                                  "Install or update the skill (npx skills add AGIHunt/blurt), then reopen this window."))
            return
        case .missing:
            empty.show(symbol: nil, image: BrandIcon.image(.egg, size: 44),
                       title: L("还没有索引", "No index yet"),
                       message: L("Blurt 会扫描 ~/Blurt 和绑定的项目里的录屏、截图批次，建一份本地搜索索引。不会上传任何东西。",
                                  "Blurt scans the recordings and snap batches in ~\u{2060}/\u{2060}Blurt and your bound projects into a local search index. Nothing is uploaded."),
                       buttons: [(L("扫描录制", "Scan Recordings"), 1)])
            return
        case .failed(let e):
            empty.show(symbol: "exclamationmark.triangle", title: L("扫描失败", "The scan failed"), message: e,
                       buttons: [(L("重试", "Try Again"), 1)])
            return
        case .ready: break
        }
        guard model.rowCount == 0 else { empty.isHidden = true; return }
        let q = model.text.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            empty.show(symbol: "magnifyingglass", title: L("没有找到「\(q)」", "No results for “\(q)”"),
                       message: model.filtered && (model.kinds.count + (model.status == nil ? 0 : 1) + (model.fix == nil ? 0 : 1)) > 0
                           ? L("还开着筛选条件。", "Filters are on, too.") : L("试试更短的词，或者别的说法。", "Try a shorter word or another phrasing."),
                       buttons: [(L("清除搜索和筛选", "Clear Search & Filters"), 2)])
        } else if model.filtered {
            empty.show(symbol: "line.3.horizontal.decrease.circle", title: L("没有符合筛选的条目", "Nothing matches these filters"),
                       message: "", buttons: [(L("清除筛选", "Clear Filters"), 2)])
        } else if model.scope == .inbox {
            empty.show(symbol: nil, image: BrandIcon.image(.nest, size: 44),
                       title: L("收件箱清空了", "Inbox zero"),
                       message: L("所有录屏和截图批次都整理、审核完了。", "Every recording and snap batch is processed and reviewed."))
        } else if model.counts.all == 0 && model.counts.sessions == 0 {
            empty.show(symbol: nil, image: BrandIcon.kind("idea", size: 44),
                       title: L("还什么都没有", "Nothing here yet"),
                       message: L("边用你的产品边说出想法和 bug：录一段屏（\(hint(.toggleRecord))），或者截几张图（\(hint(.snap))）。",
                                  "Talk through your product while you use it: record your screen (\(hint(.toggleRecord))) or snap a few shots (\(hint(.snap)))."),
                       buttons: [(L("录制", "Record"), 3), (L("截图", "Snap"), 4)])
        } else {
            empty.show(symbol: "tray", title: L("这里是空的", "Nothing here"), message: "")
        }
    }

    var projectColumn: NSTableColumn? { table.tableColumn(withIdentifier: .init("project")) }

    func hint(_ a: HotAction) -> String { hk(a) }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { model.indexState == .ready ? model.rowCount : 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn?.identifier.rawValue else { return nil }
        if model.scope.listsSessions, let s = model.session(at: row) { return sessionCell(col, s) }
        guard let it = model.item(at: row) else { return nil }
        return itemCell(col, it, row: row)
    }

    func make<T: NSView>(_ id: String, _ f: () -> T) -> T {
        if let v = table.makeView(withIdentifier: .init(id), owner: self) as? T { return v }
        let v = f()
        v.identifier = .init(id)
        return v
    }

    func itemCell(_ col: String, _ it: ItemRow, row: Int) -> NSView? {
        switch col {
        case "egg":
            let c = make("egg") { EggCell() }
            c.egg.image = BrandIcon.kind(it.kind, variant: it.uid, size: 23)
            c.egg.alphaValue = it.status == "deleted" ? 0.4 : 1
            c.setAccessibilityLabel(Look.kindName(it.kind))
            c.spinner.stopAnimation(nil)
            c.egg.isHidden = false
            return c
        case "title":
            let c = make("title") { TitleCell() }
            let session = it.sessionTitle.flatMap { $0.isEmpty ? nil : $0 } ?? URL(fileURLWithPath: it.sessionDir).lastPathComponent
            // the search hit, unless it is just the title again
            let plain = (it.snippet ?? "").replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "…"))
            let hasHit = !plain.isEmpty && !model.text.trimmingCharacters(in: .whitespaces).isEmpty && !it.title.contains(plain)
            let sub = hasHit ? it.snippet! : [session, it.itemID, it.quote.isEmpty ? nil : "“\(it.quote)”"].compactMap { $0 }.joined(separator: " · ")
            c.set(title: it.title, struck: it.status == "deleted" || it.fixState == "fixed", sub: sub, highlight: hasHit)
            c.setAccessibilityLabel((it.title.isEmpty ? L("无标题", "untitled") : it.title) + ", " + c.sub.stringValue)
            return c
        case "status":
            let c = make("pill") { PillCell() }
            c.pill.text = Look.statusName(it.status)
            c.setAccessibilityLabel(L("状态：", "Status: ") + Look.statusName(it.status))
            c.pill.color = it.status == "confirmed" ? .systemGreen : it.status == "deleted" ? .systemRed : .secondaryLabelColor
            return c
        case "fix":
            let c = make("icontext") { IconTextCell() }
            c.set(Look.fixName(it.fixState) ?? "—", symbol: Look.fixSymbol(it.fixState),
                  color: it.fixState == nil ? .tertiaryLabelColor : .secondaryLabelColor)
            c.setAccessibilityLabel(L("修复：", "Fix: ") + (Look.fixName(it.fixState) ?? L("没交给 agent", "not sent")))
            return c
        case "project":
            let c = make("icontext") { IconTextCell() }
            c.set(it.workspaceName ?? "")
            return c
        case "time":
            let c = make("icontext") { IconTextCell() }
            c.set(MainModel.relative(it.updated))
            c.toolTip = MainModel.shortDate(it.updated)
            return c
        default: return nil
        }
    }

    func sessionCell(_ col: String, _ s: SessionRow) -> NSView? {
        switch col {
        case "egg":
            let c = make("egg") { EggCell() }
            c.egg.image = BrandIcon.sessionImage(s, size: 23)
            c.egg.alphaValue = 1
            if s.processing { c.spinner.startAnimation(nil); c.egg.isHidden = true } else { c.spinner.stopAnimation(nil); c.egg.isHidden = false }
            return c
        case "title":
            let c = make("title") { TitleCell() }
            var parts = [s.mode == "shots" ? L("截图批次", "Snap batch") + (s.shotCount > 0 ? " · \(s.shotCount)" + L(" 张", " shots") : "")
                                           : L("录屏", "Recording") + (s.duration.map { " · " + String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) } ?? "")]
            parts.append(URL(fileURLWithPath: s.dir).lastPathComponent)
            c.set(title: MainModel.title(of: s), struck: false, sub: parts.joined(separator: " · "), highlight: false)
            c.setAccessibilityLabel(MainModel.title(of: s) + ", " + parts.joined(separator: ", "))
            return c
        case "status":
            let c = make("pill") { PillCell() }
            c.pill.text = Look.sessionStateName(s.state)
            c.setAccessibilityLabel(Look.sessionStateName(s.state))
            c.pill.color = s.state == "unprocessed" ? Look.brand : s.state == "processing" ? .systemOrange : s.state == "unreviewed" ? .systemBlue : .systemGreen
            return c
        case "fix":
            let c = make("icontext") { IconTextCell() }
            c.set(s.processed ? "\(s.itemCount)" : "—", symbol: s.processed ? ("square.stack", .secondaryLabelColor) : nil)
            return c
        case "project":
            let c = make("icontext") { IconTextCell() }
            c.set(s.workspaceName ?? "")
            return c
        case "time":
            let c = make("icontext") { IconTextCell() }
            c.set(s.created.map(MainModel.relative) ?? "")
            c.toolTip = s.created.map(MainModel.shortDate)
            return c
        default: return nil
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = make("row") { ItemRowView() }
        if model.scope.listsSessions, let s = model.session(at: row) {
            v.label = [MainModel.title(of: s), s.mode == "shots" ? L("截图批次", "snap batch") : L("录屏", "recording"),
                       Look.sessionStateName(s.state), s.processed ? L("\(s.itemCount) 条", "\(s.itemCount) items") : nil,
                       s.workspaceName, s.created.map(MainModel.relative)].compactMap { $0 }.joined(separator: ", ")
        } else if let it = model.item(at: row) {
            v.label = [Look.kindName(it.kind), it.title.isEmpty ? L("无标题", "untitled") : it.title, Look.statusName(it.status),
                       Look.fixName(it.fixState).map { L("修复：", "fix: ") + $0 }, it.severity.map { L("严重度 ", "severity ") + $0 },
                       it.workspaceName, MainModel.relative(it.updated)].compactMap { $0 }.joined(separator: ", ")
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

    @objc func doubleClicked() {
        guard table.clickedRow >= 0 else { return }
        actions?.reviewMode()
    }

    // drag rows out: the primary frame as a file (Finder makes a copy, Terminal pastes the path)
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        if model.scope.listsSessions { return model.session(at: row).map { $0.url as NSURL } }
        guard let f = model.item(at: row)?.primaryFrame, FileManager.default.fileExists(atPath: f) else { return nil }
        return URL(fileURLWithPath: f) as NSURL
    }

    // MARK: Quick Look

    var previewURLs: [URL] {
        if model.scope.listsSessions {
            return selectedSessions.compactMap { s in
                let v = s.url.appendingPathComponent("recording.mp4")
                return FileManager.default.fileExists(atPath: v.path) ? v : s.url
            }
        }
        return selectedItems.compactMap { $0.primaryFrame.map { URL(fileURLWithPath: $0) } }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
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

/// Row view: VoiceOver reads the whole row as one sentence (kind, title, status, fix, project, time).
final class ItemRowView: NSTableRowView {
    var label = "" { didSet { setAccessibilityLabel(label) } }
}
