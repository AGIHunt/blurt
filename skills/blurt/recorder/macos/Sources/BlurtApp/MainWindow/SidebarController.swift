// The source list: Inbox and All Items, smart filters, projects (workspaces), recent sessions (recordings and snap
// batches, each with its state egg). Vibrancy comes from NSSplitViewItem(sidebarWithViewController:).
import AppKit
import BlurtCore

final class SidebarNode: NSObject {
    let title: String
    let scope: Scope?            // nil = a group header
    let symbol: String?
    var image: NSImage?
    var count: Int?
    var children: [SidebarNode] = []
    var accessibility: String?

    init(_ title: String, scope: Scope?, symbol: String? = nil, image: NSImage? = nil, count: Int? = nil, children: [SidebarNode] = []) {
        self.title = title; self.scope = scope; self.symbol = symbol; self.image = image; self.count = count; self.children = children
    }
    var isGroup: Bool { scope == nil }
}

final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let model: MainModel
    let outline = NSOutlineView()
    var roots: [SidebarNode] = []
    var onSelect: ((Scope) -> Void)?
    var menuProvider: ((Scope) -> NSMenu?)?
    private var reloading = false

    init(model: MainModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let col = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 0
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.backgroundColor = .clear
        outline.setAccessibilityLabel(L("侧栏", "Sidebar"))
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        scroll.documentView = outline
        view = scroll
        view.frame = NSRect(x: 0, y: 0, width: 220, height: 600)
    }

    func rebuild() {
        let c = model.counts
        let top = [
            SidebarNode(L("收件箱", "Inbox"), scope: .inbox, symbol: "tray", count: c.inbox),
            SidebarNode(L("全部条目", "All Items"), scope: .all, symbol: "square.stack", count: c.all),
        ]
        top[0].accessibility = L("收件箱：待整理和待审核的录制", "Inbox: recordings to process or review")
        let smart = SidebarNode(L("智能筛选", "Smart Filters"), scope: nil, children: [
            SidebarNode(L("待修问题", "Open Issues"), scope: .smart(.openIssues), symbol: "ladybug", count: c.openIssues),
            SidebarNode(L("想法", "Ideas"), scope: .smart(.ideas), symbol: "lightbulb", count: c.ideas),
            SidebarNode(L("Agent 修复中", "Agent Fixing"), scope: .smart(.fixing), symbol: "hammer", count: c.fixing),
            SidebarNode(L("已修复", "Fixed"), scope: .smart(.fixed), symbol: "checkmark.seal", count: c.fixed),
        ])
        let projects = SidebarNode(L("项目", "Projects"), scope: nil, children: model.workspaces.map { w in
            let n = SidebarNode(w.name, scope: .workspace(w.id), symbol: w.kind == "default" ? "house" : "folder", count: w.openItems)
            n.accessibility = "\(w.name), \((w.path as NSString).abbreviatingWithTildeInPath)"
            return n
        })
        var sessionNodes = [SidebarNode(L("全部会话", "All Sessions"), scope: .sessions, symbol: "clock", count: c.sessions)]
        sessionNodes += model.recentSessions.map { s in
            let n = SidebarNode(MainModel.title(of: s), scope: .session(s.id), symbol: s.mode == "shots" ? "camera.viewfinder" : "video",
                                count: s.itemCount > 0 ? s.itemCount : nil)
            n.image = Look.sessionEgg(s, size: NSSize(width: 13, height: 17))
            n.accessibility = "\(MainModel.title(of: s)), \(s.mode == "shots" ? L("截图批次", "snap batch") : L("录屏", "recording")), \(Look.sessionStateName(s.state))"
            return n
        }
        let sessions = SidebarNode(L("最近会话", "Recent Sessions"), scope: nil, children: sessionNodes)
        let selected = selectedScope
        roots = top + [smart] + (projects.children.isEmpty ? [] : [projects]) + [sessions]
        reloading = true
        outline.reloadData()
        for r in roots where r.isGroup { outline.expandItem(r) }
        if let s = selected { select(s) }
        reloading = false
    }

    var selectedScope: Scope? { (outline.item(atRow: outline.selectedRow) as? SidebarNode)?.scope }

    func select(_ scope: Scope) {
        func find(_ nodes: [SidebarNode]) -> SidebarNode? {
            for n in nodes { if n.scope == scope { return n }; if let f = find(n.children) { return f } }
            return nil
        }
        guard let n = find(roots) else { outline.deselectAll(nil); return }
        let row = outline.row(forItem: n)
        if row >= 0, outline.selectedRow != row {
            let was = reloading
            reloading = true
            outline.selectRowIndexes([row], byExtendingSelection: false)
            reloading = was
        }
    }

    // MARK: data source

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? roots.count
    }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? roots[index]
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? SidebarNode)?.isGroup ?? false }
    func outlineView(_ o: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? SidebarNode)?.isGroup ?? false }
    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool { !((item as? SidebarNode)?.isGroup ?? true) }
    func outlineView(_ o: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { true }

    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? SidebarNode else { return nil }
        if n.isGroup {
            let id = NSUserInterfaceItemIdentifier("HeaderCell")
            let v = o.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = id
                let t = NSTextField(labelWithString: "")
                t.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(t)
                c.textField = t
                NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                                             t.centerYAnchor.constraint(equalTo: c.centerYAnchor)])
                return c
            }()
            v.textField?.stringValue = n.title
            return v
        }
        let id = NSUserInterfaceItemIdentifier("SourceCell")
        let v = o.makeView(withIdentifier: id, owner: self) as? SourceCell ?? SourceCell(id: id)
        v.set(n)
        return v
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, let s = selectedScope else { return }
        onSelect?(s)
    }
}

extension SidebarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard outline.clickedRow >= 0, let n = outline.item(atRow: outline.clickedRow) as? SidebarNode, let s = n.scope,
              let m = menuProvider?(s) else { return }
        for it in m.items { m.removeItem(it); menu.addItem(it) }
    }
}

final class SourceCell: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        for v in [icon, title, badge] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        badge.textColor = .secondaryLabelColor
        badge.alignment = .right
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        imageView = icon
        textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ n: SidebarNode) {
        title.stringValue = n.title
        if let img = n.image {
            icon.image = img
            icon.contentTintColor = nil
        } else {
            icon.image = n.symbol.flatMap { Look.symbol($0, n.title, size: 13) }
            icon.contentTintColor = n.scope == .inbox ? Look.brand : nil
        }
        badge.stringValue = n.count.map { $0 > 0 ? NumberFormatter.localizedString(from: $0 as NSNumber, number: .decimal) : "" } ?? ""
        setAccessibilityLabel([n.accessibility ?? n.title, badge.stringValue.isEmpty ? nil : badge.stringValue].compactMap { $0 }.joined(separator: ", "))
    }
}
