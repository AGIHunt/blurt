// The source list: the places (Inbox, In Progress, Unassigned, All Items, Dictation) and the projects — the folders opened in
// Blurt, in the user's own order (ProjectStore.ordered: a folder opened goes last, dragging a project reorders, using
// one never does — so ⌘5–⌘9 stay put) — with an "Open Folder…" button at the bottom. A project renames in place
// (double-click, Return, Rename). Folders dropped anywhere on the sidebar open as projects; items dragged onto a
// project (or Unassigned) move there. Vibrancy comes from NSSplitViewItem(sidebarWithViewController:).
import AppKit
import BlurtCore

final class SidebarNode: NSObject {
    let title: String
    let scope: Scope?            // nil = a group header
    let symbol: String?
    /// a drawn mark instead of the symbol: a project's coloured folder, Unassigned's dashed ring, a missing folder's
    /// question mark — the island's one mark per concept (IslandGlyph.place)
    var image: NSImage?
    var count: Int?
    var children: [SidebarNode] = []
    var accessibility: String?
    var dimmed = false
    var current = false
    var detail: String?          // quiet text after the name (unused by the places and projects today)
    var tip: String?             // the row's tooltip: a project's name and its id prefix
    /// the current project (where new recordings and snaps go): the scope mark after its name — the same mark the
    /// Move popover, ⌘K and the project's heading use
    /// counts of what needs you are tinted (attention), plain counts aren't
    var alert = false

    init(_ title: String, scope: Scope?, symbol: String? = nil, count: Int? = nil, children: [SidebarNode] = []) {
        self.title = title; self.scope = scope; self.symbol = symbol; self.count = count; self.children = children
    }
    /// a row that does something instead of going somewhere (Recently Dragged Out opens its panel): never selected
    var action: (() -> Void)?
    var isGroup: Bool { scope == nil && action == nil }
}

protocol SidebarActions: AnyObject {
    func sidebarSelected(_ s: Scope)
    func sidebarMenu(_ s: Scope) -> NSMenu?
    func openFolder()
    func openFolders(_ urls: [URL])
    func move(uids: [String], to project: String)
    /// the name typed in place (double-click, Return, Rename)
    func renameProject(_ id: String, to name: String)
    /// the projects dragged into a new order
    func reorderProjects(_ ids: [String])
}

extension NSPasteboard.PasteboardType {
    /// a project row dragged inside the sidebar (reordering)
    static let blurtProject = NSPasteboard.PasteboardType("dev.blurt.project")
}

/// Return on a project renames it in place (Finder's sidebar does the same for its items).
final class SidebarOutline: NSOutlineView {
    var onReturn: (() -> Bool)?
    override func keyDown(with e: NSEvent) {
        if [36, 76].contains(e.keyCode), e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, onReturn?() == true { return }
        super.keyDown(with: e)
    }
}

final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let model: MainModel
    let outline = SidebarOutline()
    private(set) var renaming: InlineRename?
    private var rebuildAfterRename = false
    var roots: [SidebarNode] = []
    /// Tests (wp6 `mainbanner taken N`): the Recently Dragged Out row with N cards, none needed
    var testTaken: Int?
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
        outline.registerForDraggedTypes([.fileURL, .blurtItems, .blurtProject, capturePasteboardType])
        outline.setDraggingSourceOperationMask(.every, forLocal: false)
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.target = self
        outline.action = #selector(clicked)
        outline.doubleAction = #selector(doubleClicked)
        outline.onReturn = { [weak self] in self?.renameSelected() ?? false }
        NotificationCenter.default.addObserver(forName: .blurtTakenChanged, object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        scroll.documentView = outline

        // Notes' "New Folder": a plus and the words, in the rows' own size and ink (secondary), not a faint caption
        let open = NSButton(title: " " + T("project.open_folder"), image: Look.symbol("plus", "", size: 12, weight: .medium) ?? NSImage(),
                            target: self, action: #selector(openTapped))
        open.bezelStyle = .recessed
        open.isBordered = false
        open.imagePosition = .imageLeading
        open.contentTintColor = .secondaryLabelColor
        open.font = .systemFont(ofSize: 13)
        open.toolTip = T("main.sidebar.open_folder.tip")
        open.setAccessibilityLabel(T("project.open_folder"))   // not the symbol's own name ("New Folder")
        let root = NSView()
        for v in [scroll, open] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: open.topAnchor, constant: -6),
            open.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            open.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        view = root
        view.frame = NSRect(x: 0, y: 0, width: 220, height: 600)
    }

    @objc func openTapped() { actions?.openFolder() }

    // MARK: rename in place

    @objc func doubleClicked() {
        guard outline.clickedRow >= 0, outline.clickedRow == outline.selectedRow else { return }
        _ = renameSelected()
    }

    /// The selected project's name becomes editable in its row. false: not a project that can be renamed here.
    @discardableResult
    func renameSelected() -> Bool {
        guard renaming == nil, case .project(let id)? = selectedScope, let p = model.project(id: id), p.registered,
              let cell = outline.view(atColumn: 0, row: outline.selectedRow, makeIfNecessary: true) as? SourceCell else { return false }
        let e = InlineRename(cell: cell, uid: id, original: p.name, commit: { [weak self] in self?.actions?.renameProject(id, to: $0) }) { [weak self] in
            guard let self = self else { return }
            self.renaming = nil
            self.view.window?.makeFirstResponder(self.outline)
            if self.rebuildAfterRename { self.rebuildAfterRename = false; self.rebuild() }
        }
        renaming = e
        e.start()
        return true
    }

    func rebuild() {
        if renaming != nil { rebuildAfterRename = true; return }      // never under a name being typed
        let c = model.counts
        func place(_ t: String, _ s: Scope, _ sym: String, _ n: Int?, alert: Bool = false, ax: String? = nil) -> SidebarNode {
            let node = SidebarNode(t, scope: s, symbol: sym, count: n)
            node.alert = alert
            node.accessibility = ax
            return node
        }
        // not items: what was dictated into other apps — a page of its own (DictationPage.swift); text typed at a cursor, as
        // Settings → Dictation, the menu bar and ⌘K mark it (the mic is a voice note's)
        let dictation = place(T("dictation.history.sidebar"), .dictation, "character.cursor.ibeam", nil, ax: T("main.sidebar.dictation.ax"))
        // Recently Dragged Out: a place of its own while it holds cards (Photos' Recently Deleted), not a banner over
        // the list — a click opens its panel (copy, drag out again, put back); the menu bar and the island reach it too
        let takenCount = testTaken ?? (AppEnvironment.island == nil ? 0 : snapper.recentlyTaken.count)
        let taken: [SidebarNode] = takenCount > 0 ? [{
            // short enough for the sidebar; the panel's own name (Recently Dragged Out) is its tooltip and VoiceOver label
            let n = SidebarNode(T("main.sidebar.taken"), scope: nil, symbol: "arrow.up.right.square", count: takenCount)
            n.action = { [weak self] in
                let w = self?.view.window
                TakenPanel.shared.show(near: w.map { NSRect(x: $0.frame.midX - 1, y: $0.frame.maxY - 80, width: 2, height: 2) })
            }
            n.tip = [Loc.t("capture.taken.title", table: "Capture"), T("main.captures.taken.tip")].joined(separator: "\n")
            n.accessibility = Loc.t("capture.taken.title", table: "Capture")
            return n
        }()] : []
        let top = [
            place(T("main.place.inbox"), .inbox, "tray", c.inbox, alert: true, ax: T("main.sidebar.inbox.ax")),
            place(T("main.place.progress"), .inProgress, "circle.righthalf.filled", c.active, ax: T("main.sidebar.progress.ax")),
            { () -> SidebarNode in
                let n = place(T("project.inbox"), .unassigned, "tray.2", c.unassigned, ax: T("main.sidebar.unassigned.ax"))
                n.image = IslandGlyph.place(nil, size: 16)
                return n
            }(),
            place(T("main.place.all"), .all, "list.bullet.rectangle", c.all),
            dictation,
        ] + taken
        let projectNodes = model.projects.map { p -> SidebarNode in
            // a project's count is plain secondary digits: the one mint pill is the Inbox's (what's new for you, §3.3),
            // so the brand marks on screen stay few. The key ("AW", its ids' prefix) is the row's tooltip, not text.
            let n = SidebarNode(p.name, scope: .project(p.id), symbol: p.exists ? "folder" : "questionmark.folder",
                                count: p.inbox > 0 ? p.inbox : nil)
            n.alert = false
            n.image = !p.exists ? IslandGlyph.missing.template(size: 16)
                : ProjectStore.shared.project(id: p.id).flatMap { IslandGlyph.project(ProjectLook.color($0)).image(size: 16, color: .black) }
            n.tip = p.key.isEmpty ? p.name : T("main.sidebar.project_tip", p.name, p.key)
            n.dimmed = !p.registered || !p.exists
            n.current = ProjectStore.shared.currentID == p.id
            let path = (p.path.path as NSString).abbreviatingWithTildeInPath
            n.accessibility = [p.name, path, !p.exists ? T("main.sidebar.missing") : nil, !p.registered ? T("main.sidebar.not_opened") : nil]
                .compactMap { $0 }.joined(separator: ", ")
            return n
        }
        let projects = SidebarNode(T("main.sidebar.projects"), scope: nil, children: projectNodes)
        let selected = selectedScope
        roots = top + (projectNodes.isEmpty ? [] : [projects])     // no bare "Projects" header before the first one
        reloading = true
        outline.reloadData()
        for r in roots where r.isGroup { outline.expandItem(r) }
        if let s = selected { select(s) }
        reloading = false
    }

    var selectedScope: Scope? { (outline.item(atRow: outline.selectedRow) as? SidebarNode)?.scope }

    /// A click on an action row (Recently Dragged Out): do it; the selection stays where it was.
    @objc func clicked() {
        guard outline.clickedRow >= 0, let n = outline.item(atRow: outline.clickedRow) as? SidebarNode, let a = n.action else { return }
        a()
    }

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
    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let n = item as? SidebarNode else { return false }
        return !n.isGroup && n.action == nil
    }
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

    /// The brand selection (a rounded tint, text stays `labelColor`), not the source list's accent-coloured one.
    func outlineView(_ o: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        BrandRowView()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, let s = selectedScope else { return }
        actions?.sidebarSelected(s)
    }

    // MARK: drags: projects reorder (Finder's Favorites); folders open as projects; items move

    func outlineView(_ o: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        // the projects keep the one order every list uses (pinned, then the most recently used: Pin to Top in their
        // menu), so a project isn't dragged into an order of its own
        guard Self.reorderByDrag, let n = item as? SidebarNode, case .project(let id)? = n.scope, model.project(id: id)?.registered == true else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(id, forType: .blurtProject)
        return pb
    }

    static let reorderByDrag = false

    /// The projects group node (where a dragged project lands).
    private var projectsGroup: SidebarNode? { roots.first(where: \.isGroup) }

    func outlineView(_ o: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let pb = info.draggingPasteboard
        if pb.types?.contains(.blurtProject) == true {
            // between two projects only (an unopened folder listed after them stays last), and inside the dragged
            // one's own section: the line snaps to the nearest place it can really go (pinned stay above the rest)
            guard let g = projectsGroup, (item as? SidebarNode) === g, index != NSOutlineViewDropOnItemIndex,
                  let id = pb.pasteboardItems?.first?.string(forType: .blurtProject) else { return [] }
            let reg = model.projects.filter(\.registered)
            let ok = ProjectStore.dropRange(reg.map(\.id), pinned: Set(reg.filter(\.pinned).map(\.id)), moving: id)
            let at = min(max(index, ok.lowerBound), ok.upperBound)
            if at != index { o.setDropItem(g, dropChildIndex: at) }
            return .move
        }
        // items from the list, or a hanging card (BA-50: filed here as on the island's project rows)
        if pb.types?.contains(.blurtItems) == true || pb.types?.contains(capturePasteboardType) == true {
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
        if let id = pb.pasteboardItems?.first?.string(forType: .blurtProject) {
            let ids = model.projects.filter(\.registered).map(\.id)
            let new = ProjectStore.reordered(ids, moving: id, to: index)
            guard new != ids else { return false }
            actions?.reorderProjects(new)
            return true
        }
        if let items = pb.pasteboardItems?.compactMap({ $0.string(forType: .blurtItems) }), !items.isEmpty {
            guard let s = (item as? SidebarNode)?.scope else { return false }
            switch s {
            case .project(let p): actions?.move(uids: items, to: p)
            case .unassigned: actions?.move(uids: items, to: "inbox")
            default: return false
            }
            return true
        }
        if let raw = pb.pasteboardItems?.first?.string(forType: capturePasteboardType), let shot = Island.shot(fromPasteboard: raw) {
            guard let s = (item as? SidebarNode)?.scope else { return false }
            switch s {
            case .project(let p): snapper.assign(hanging.withSelection(shot), to: p)
            case .unassigned: snapper.assign(hanging.withSelection(shot), to: "inbox")
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

final class SourceCell: NSTableCellView, InlineEditable {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    var editField: NSTextField { title }

    // MARK: rename in place (double-click, Return, the menus' Rename)

    private var shownName = ""
    func beginEditing(_ text: String, delegate: NSTextFieldDelegate) {
        shownName = title.stringValue
        key.isHidden = true
        badge.isHidden = true
        title.isEditable = true
        title.isSelectable = true
        title.drawsBackground = true
        title.backgroundColor = .textBackgroundColor
        title.stringValue = text
        title.delegate = delegate
    }
    func setInvalid(_ on: Bool) {
        title.wantsLayer = true
        title.layer?.borderWidth = on ? 1 : 0
        title.layer?.borderColor = NSColor.systemRed.cgColor
        title.layer?.cornerRadius = 3
    }
    func endEditing(showing text: String?) {
        setInvalid(false)
        title.delegate = nil
        title.isEditable = false
        title.isSelectable = false
        title.drawsBackground = false
        title.stringValue = text ?? shownName
        key.isHidden = key.stringValue.isEmpty
        badge.isHidden = false
    }
    let key = NSTextField(labelWithString: "")
    let badge = CountPill()
    /// the current project's mark (SidebarNode.current)
    let mark = NSImageView()

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        for v in [icon, title, key, mark, badge] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        mark.image = SourceCell.currentImage
        mark.contentTintColor = .secondaryLabelColor
        mark.isHidden = true
        mark.setContentCompressionResistancePriority(.required, for: .horizontal)
        // a long project name keeps both ends ("口喷鸡 iOS…截断）"): the tooltip has it whole
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        key.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        key.textColor = .secondaryLabelColor
        // the name wins: the key (which only repeats it) gives way first, and goes when it doesn't fit whole
        key.setContentCompressionResistancePriority(.init(NSLayoutConstraint.Priority.defaultLow.rawValue - 1), for: .horizontal)
        key.lineBreakMode = .byClipping
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        // not the cell's textField / imageView: a source list restyles those for a selected row (the accent-coloured
        // name); the brand wash is the selection, the name stays ink (the row's accessibility label says it all)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            key.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 5),
            key.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            mark.leadingAnchor.constraint(equalTo: key.trailingAnchor, constant: 5),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: mark.trailingAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        key.alphaValue = key.frame.width + 0.5 < key.intrinsicContentSize.width ? 0 : 1      // never a cut-off key
    }

    private var dimmed = false
    private func applyInk() {
        title.textColor = dimmed ? .secondaryLabelColor : .labelColor
        icon.contentTintColor = dimmed ? .tertiaryLabelColor : .secondaryLabelColor
        key.textColor = .secondaryLabelColor
    }

    func set(_ n: SidebarNode) {
        dimmed = n.dimmed
        title.stringValue = n.title
        title.textColor = n.dimmed ? .secondaryLabelColor : .labelColor
        key.stringValue = n.detail ?? ""
        key.isHidden = n.detail == nil
        icon.image = n.image ?? n.symbol.flatMap { Look.symbol($0, n.title, size: 13) }
        icon.alphaValue = 1
        toolTip = n.current ? [n.tip, T("main.project.current_mark")].compactMap { $0 }.joined(separator: "\n") : n.tip
        mark.isHidden = !n.current
        applyInk()
        badge.text = n.count.map { $0 > 0 ? Loc.number($0) : "" } ?? ""
        badge.mint = n.alert
        setAccessibilityLabel([n.accessibility ?? n.title, n.current ? T("main.project.current_mark") : nil,
                               badge.text.isEmpty ? nil : badge.text].compactMap { $0 }.joined(separator: ", "))
    }

    /// The current project's mark: the scope (a target), small and quiet — "Make Current Project" uses the same glyph.
    static let currentImage = Look.symbol("scope", T("main.project.current_mark"), size: 11, weight: .medium)
}

/// A count at the end of a sidebar row. What's new for you (the Inbox, a project's inbox) is a mint pill with
/// `BrandColor.on` digits (§3.3 "New counts and badges"); plain counts are quiet secondary digits.
final class CountPill: NSView {
    var text = "" { didSet { if text != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    var mint = false { didSet { if mint != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private let pillFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)

    private var attributed: NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: mint ? pillFont : font,
                                                      .foregroundColor: mint ? BrandColor.on : NSColor.secondaryLabelColor])
    }
    override var intrinsicContentSize: NSSize {
        guard !text.isEmpty else { return NSSize(width: 0, height: 16) }
        let w = ceil(attributed.size().width)
        return NSSize(width: mint ? max(18, w + 10) : w, height: 16)
    }
    override var allowsVibrancy: Bool { false }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirty: NSRect) {
        guard !text.isEmpty else { return }
        let s = attributed, ts = s.size()
        if mint {
            BrandColor.fill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }
        s.draw(at: NSPoint(x: bounds.midX - ts.width / 2, y: bounds.midY - ts.height / 2))
    }
    override func isAccessibilityElement() -> Bool { false }      // the row says the count
}
