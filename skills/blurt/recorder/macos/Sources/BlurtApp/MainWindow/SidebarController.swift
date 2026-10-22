// The source list: the places (Inbox, In Progress, Unassigned, All Items) and the projects — the folders opened in
// Blurt, most recently used first — with an "Open Folder…" button at the bottom. Folders dropped anywhere on the
// sidebar open as projects; items dragged onto a project (or Unassigned) move there. Vibrancy comes from
// NSSplitViewItem(sidebarWithViewController:).
import AppKit
import BlurtCore

final class SidebarNode: NSObject {
    let title: String
    let scope: Scope?            // nil = a group header
    let symbol: String?
    var count: Int?
    var children: [SidebarNode] = []
    var accessibility: String?
    var dimmed = false
    var detail: String?          // the project key, quiet
    /// counts of what needs you are tinted (attention), plain counts aren't
    var alert = false

    init(_ title: String, scope: Scope?, symbol: String? = nil, count: Int? = nil, children: [SidebarNode] = []) {
        self.title = title; self.scope = scope; self.symbol = symbol; self.count = count; self.children = children
    }
    var isGroup: Bool { scope == nil }
}

protocol SidebarActions: AnyObject {
    func sidebarSelected(_ s: Scope)
    func sidebarMenu(_ s: Scope) -> NSMenu?
    func openFolder()
    func openFolders(_ urls: [URL])
    func move(uids: [String], to project: String)
}

final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let model: MainModel
    let outline = NSOutlineView()
    var roots: [SidebarNode] = []
    weak var actions: SidebarActions?
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
        outline.setAccessibilityLabel(T("main.sidebar.label"))
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.registerForDraggedTypes([.fileURL, .blurtItems])
        outline.setDraggingSourceOperationMask(.every, forLocal: false)
        scroll.documentView = outline

        let open = NSButton(title: T("project.open_folder"), image: Look.symbol("folder.badge.plus", "", size: 13) ?? NSImage(),
                            target: self, action: #selector(openTapped))
        open.bezelStyle = .recessed
        open.isBordered = false
        open.imagePosition = .imageLeading
        open.contentTintColor = .secondaryLabelColor
        open.font = .systemFont(ofSize: 12)
        open.toolTip = T("main.sidebar.open_folder.tip")
        open.setAccessibilityLabel(T("project.open_folder"))   // not the symbol's own name ("New Folder")
        let root = NSView()
        for v in [scroll, open] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: open.topAnchor, constant: -6),
            open.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            open.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        view = root
        view.frame = NSRect(x: 0, y: 0, width: 220, height: 600)
    }

    @objc func openTapped() { actions?.openFolder() }

    func rebuild() {
        let c = model.counts
        func place(_ t: String, _ s: Scope, _ sym: String, _ n: Int?, alert: Bool = false, ax: String? = nil) -> SidebarNode {
            let node = SidebarNode(t, scope: s, symbol: sym, count: n)
            node.alert = alert
            node.accessibility = ax
            return node
        }
        let top = [
            place(T("main.place.inbox"), .inbox, "tray", c.attention, alert: true, ax: T("main.sidebar.inbox.ax")),
            place(T("main.place.progress"), .inProgress, "circle.dashed", c.active + c.toVerify, ax: T("main.sidebar.progress.ax")),
            place(T("project.inbox"), .unassigned, "tray.2", c.unassigned, ax: T("main.sidebar.unassigned.ax")),
            place(T("main.place.all"), .all, "list.bullet.rectangle", c.all),
        ]
        let projectNodes = model.projects.map { p -> SidebarNode in
            let n = SidebarNode(p.name, scope: .project(p.id), symbol: p.exists ? "folder" : "questionmark.folder",
                                count: p.attention > 0 ? p.attention : nil)
            n.alert = p.attention > 0
            n.detail = p.key
            n.dimmed = !p.registered || !p.exists
            let path = (p.path.path as NSString).abbreviatingWithTildeInPath
            n.accessibility = [p.name, path, !p.exists ? T("main.sidebar.missing") : nil, !p.registered ? T("main.sidebar.not_opened") : nil]
                .compactMap { $0 }.joined(separator: ", ")
            return n
        }
        let projects = SidebarNode(T("main.sidebar.projects"), scope: nil, children: projectNodes)
        let selected = selectedScope
        roots = top + [projects]
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
        let was = reloading
        reloading = true
        defer { reloading = was }
        guard let n = find(roots) else { outline.deselectAll(nil); return }
        let row = outline.row(forItem: n)
        if row >= 0, outline.selectedRow != row { outline.selectRowIndexes([row], byExtendingSelection: false) }
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
        actions?.sidebarSelected(s)
    }

    // MARK: drops: folders open as projects, items move

    func outlineView(_ o: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let pb = info.draggingPasteboard
        if pb.types?.contains(.blurtItems) == true {
            guard let n = item as? SidebarNode, index == NSOutlineViewDropOnItemIndex, let s = n.scope else { return [] }
            switch s {
            case .project(let p) where model.project(id: p)?.registered == true: return .move
            case .unassigned: return .move
            default: return []
            }
        }
        if !folders(pb).isEmpty {
            o.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)     // the whole list highlights
            return .link
        }
        return []
    }

    func outlineView(_ o: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let pb = info.draggingPasteboard
        if let items = pb.pasteboardItems?.compactMap({ $0.string(forType: .blurtItems) }), !items.isEmpty {
            guard let s = (item as? SidebarNode)?.scope else { return false }
            switch s {
            case .project(let p): actions?.move(uids: items, to: p)
            case .unassigned: actions?.move(uids: items, to: "inbox")
            default: return false
            }
            return true
        }
        let dirs = folders(pb)
        guard !dirs.isEmpty else { return false }
        actions?.openFolders(dirs)
        return true
    }

    func folders(_ pb: NSPasteboard) -> [URL] {
        ((pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []).filter {
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &dir) && dir.boolValue
        }
    }
}

extension SidebarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard outline.clickedRow >= 0, let n = outline.item(atRow: outline.clickedRow) as? SidebarNode, let s = n.scope,
              let m = actions?.sidebarMenu(s) else { return }
        for it in m.items { m.removeItem(it); menu.addItem(it) }
    }
}

final class SourceCell: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let key = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        for v in [icon, title, key, badge] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        key.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        key.textColor = .tertiaryLabelColor
        key.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
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
            key.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 5),
            key.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: key.trailingAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ n: SidebarNode) {
        title.stringValue = n.title
        title.textColor = n.dimmed ? .secondaryLabelColor : .labelColor
        key.stringValue = n.detail ?? ""
        key.isHidden = n.detail == nil
        icon.image = n.symbol.flatMap { Look.symbol($0, n.title, size: 13) }
        icon.contentTintColor = n.dimmed ? .tertiaryLabelColor : nil
        icon.alphaValue = 1
        badge.stringValue = n.count.map { $0 > 0 ? Loc.number($0) : "" } ?? ""
        badge.textColor = n.alert ? Look.brand : .secondaryLabelColor
        setAccessibilityLabel([n.accessibility ?? n.title, badge.stringValue.isEmpty ? nil : badge.stringValue].compactMap { $0 }.joined(separator: ", "))
    }
}
