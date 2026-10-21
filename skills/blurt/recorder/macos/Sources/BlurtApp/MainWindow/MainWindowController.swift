// Blurt's main window (§2.1, WP5): sidebar | items | detail in an NSSplitViewController, a unified toolbar
// (Record, Snap, Let Agent Fix, filters, search), ⌘K command palette, the keyboard map of §2.5, context menus,
// Quick Look, window state restored from $BLURT_HOME/ui/main-window.json (not UserDefaults: test builds share the
// bundle id with the user's real app and must not disturb its state).
//
// Reads come from index.db (MainModel / IndexReader). Every write goes through items.py (Scripts.userOps); the index
// follows (items.py updates it in-process, FSEvents + `index.py update` catch everything else) and the model reloads
// when index.db's data_version moves.
import AppKit
import BlurtCore
import Quartz

final class MainWindow: NSWindow {
    weak var controller: MainWindowController?
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if controller?.handleKeyEquivalent(e) == true { return true }
        return super.performKeyEquivalent(with: e)
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate,
                                  NSMenuDelegate, NSMenuItemValidation, ItemListActions, WebHostActions, MainWindowHosting {
    static let shared = MainWindowController()

    let model = MainModel()
    let split = NSSplitViewController()
    let sidebar: SidebarController
    let list: ItemListController
    let detail = WebHostController()
    var searchItem: NSSearchToolbarItem?
    var watcher: IndexWatcher?
    var watchedRoots: [String] = []
    lazy var palette = CommandPalette(controller: self)
    private var saveTimer: Timer?
    private var restored = false

    init() {
        sidebar = SidebarController(model: model)
        list = ItemListController(model: model)
        let w = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: true)
        super.init(window: w)
        w.controller = self
        w.title = "Blurt"
        w.minSize = NSSize(width: 860, height: 480)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.titlebarSeparatorStyle = .automatic
        w.toolbarStyle = .unified
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.delegate = self
        w.setAccessibilityLabel(L("口喷鸡", "Blurt"))
        if let appearance = ProcessInfo.processInfo.environment["BLURT_APPEARANCE"] {   // screenshots of both themes
            w.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }

        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.minimumThickness = 180
        side.maximumThickness = 320
        side.canCollapse = true
        let content = NSSplitViewItem(contentListWithViewController: list)
        content.minimumThickness = 340
        let det = NSSplitViewItem(viewController: detail)
        det.minimumThickness = 360
        det.canCollapse = true
        det.holdingPriority = .init(249)
        split.addSplitViewItem(side)
        split.addSplitViewItem(content)
        split.addSplitViewItem(det)
        split.splitView.dividerStyle = .thin
        w.contentViewController = split
        w.setContentSize(NSSize(width: 1280, height: 800))   // the content VC sized the window to its views

        let tb = NSToolbar(identifier: "BlurtMain")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        w.toolbar = tb

        list.actions = self
        detail.actions = self
        sidebar.onSelect = { [weak self] s in self?.go(s) }
        sidebar.menuProvider = { [weak self] s in self?.sidebarMenu(s) }
        model.onReload = { [weak self] in self?.list.reload(); self?.updateTitle(); self?.scheduleSave() }
        model.onSidebar = { [weak self] in self?.sidebar.rebuild(); self?.updateWatcher() }
        model.onIndexState = { [weak self] in
            guard let self = self else { return }
            self.list.reload()
            self.updateTitle()
            if self.model.indexState == .ready, self.list.table.selectedRow < 0, self.model.rowCount > 0 {
                self.list.table.selectRowIndexes([0], byExtendingSelection: false)
            }
        }

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] n in
            guard let self = self, (n.object as? NSWindow) !== self.window else { return }
            // a review window closing makes ReviewHub drop the app back to menu-bar-only: not while we're open
            DispatchQueue.main.async { if self.window?.isVisible == true { self.becomeRegular() } }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.saveState(open: self?.window?.isVisible == true)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: MainWindowHosting

    func show() {
        if !restored { restoreState(); restored = true } else { model.reloadAll() }
        becomeRegular()
        activateApp()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        window?.makeFirstResponder(list.table)
    }

    func reveal(uid: String) {
        show()
        guard let row = model.itemRow(uid: uid) else { return }
        model.text = ""
        searchItem?.searchField.stringValue = ""
        if row.status == "deleted" { model.status = "deleted" } else { model.status = nil }
        model.kinds = []
        model.fix = nil
        if !model.scope.listsSessions, model.row(of: uid) == nil || model.scope == .inbox { model.scope = .all }
        model.reload()
        if model.row(of: uid) == nil { model.scope = .all; model.reload() }
        sidebar.select(model.scope)
        list.select(id: uid)
        window?.makeFirstResponder(list.table)
    }

    func reveal(session: URL) {
        show()
        let dir = session.resolvingSymlinksInPath().standardizedFileURL.path
        guard let s = (try? model.reader?.sessions(SessionQuery(limit: 0)))?.first(where: {
            URL(fileURLWithPath: $0.dir).resolvingSymlinksInPath().standardizedFileURL.path == dir }) else { return }
        if s.processed && s.itemCount > 0 {
            go(.session(s.id))
        } else {
            go(.sessions)
            list.select(id: s.id)
        }
    }

    func becomeRegular() {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = MainMenu.build()
    }

    // MARK: navigation

    func go(_ s: Scope) {
        guard s != model.scope || model.rowCount == 0 else { return }
        list.forgetSelection()        // a new place starts at its first row
        model.scope = s
        model.reload()
        sidebar.select(s)
        if list.table.selectedRow < 0, model.rowCount > 0 { list.table.selectRowIndexes([0], byExtendingSelection: false) }
        listSelectionChanged()
    }

    func updateTitle() {
        window?.title = model.scopeTitle
        let n = NumberFormatter.localizedString(from: model.rowCount as NSNumber, number: .decimal)
        window?.subtitle = model.indexState != .ready ? "" : model.scope.listsSessions ? L("\(n) 个会话", "\(n) sessions") : L("\(n) 条", "\(n) items")
    }

    // MARK: ItemListActions

    func listSelectionChanged() {
        let n = list.table.selectedRowIndexes.count
        if n == 1, let it = list.selectedItems.first { detail.show(item: it) }
        else if n == 1, let s = list.selectedSessions.first { detail.show(session: s) }
        else { detail.showNothing(n) }
        scheduleSave()
    }

    func openSelection() {
        if list.selectedSessions.first.map({ !$0.processed }) == true, let s = list.selectedSessions.first {
            process(session: s.url)
            return
        }
        window?.makeFirstResponder(detail.web)
    }

    func fixSelection() {
        let uids = list.selectedItems.map(\.uid)
        guard !uids.isEmpty else { NSSound.beep(); return }
        fixWithAgent(uids: uids)
    }

    func renameSelection() {
        guard let it = list.selectedItems.first, let w = window else { return }
        let a = NSAlert()
        a.messageText = L("改标题", "Rename Item")
        a.informativeText = "\(Look.kindName(it.kind)) · \(it.itemID)"
        let f = NSTextField(string: it.title)
        f.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        a.accessoryView = f
        a.addButton(withTitle: L("保存", "Save"))
        a.addButton(withTitle: L("取消", "Cancel"))
        a.window.initialFirstResponder = f
        a.beginSheetModal(for: w) { [weak self] r in
            let t = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard r == .alertFirstButtonReturn, !t.isEmpty, t != it.title else { return }
            self?.edit([it], ["title": t])
        }
    }

    func setKind(_ kind: String) { edit(list.selectedItems.filter { $0.kind != kind }, ["kind": kind]) }

    func cycleStatus() {
        let items = list.selectedItems
        guard let first = items.first else { return }
        setStatus(first.status == "confirmed" ? "draft" : "confirmed")
    }

    func setStatus(_ status: String) { edit(list.selectedItems.filter { $0.status != status }, ["status": status]) }

    /// User edits = items.py user-ops, per session (the same ops the review page sends).
    func edit(_ items: [ItemRow], _ set: [String: Any]) {
        guard !items.isEmpty else { return }
        guard Scripts.canWrite else { return alert(L("现在不能修改", "Can't edit right now"), L("需要 uv 和 blurt skill 的 items.py。", "This needs uv and the blurt skill's items.py.")) }
        for (dir, group) in Dictionary(grouping: items, by: \.sessionDir) {
            let ops: [[String: Any]] = group.map { ["op": "set", "id": $0.itemID, "set": set, "unset": [] as [String]] }
            Scripts.userOps(URL(fileURLWithPath: dir), ops) { [weak self] r in
                if case .failure(let e) = r { self?.alert(L("保存失败", "Couldn't save"), "\(e)") }
                // items.py re-indexed in-process; make sure the list catches up even without it
                Scripts.indexUpdate([URL(fileURLWithPath: dir)])
                self?.detail.reload()
            }
        }
    }

    func reviewMode() {
        let dir = list.selectedItems.first?.sessionURL ?? list.selectedSessions.first.flatMap { $0.processed ? $0.url : nil }
        guard let d = dir else { NSSound.beep(); return }
        if !ReviewHub.shared.openSession(d) { alert(L("打不开审核页", "Can't open the review"), L("需要 uv 和 blurt skill 的 review.py。", "This needs uv and the blurt skill's review.py.")) }
    }

    func copyPaths() {
        let paths = list.selectedItems.map { $0.primaryFrame.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? $0.sessionDir }
            + list.selectedSessions.map(\.dir)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func focusSearch() {
        if let s = searchItem { s.beginSearchInteraction(); window?.makeFirstResponder(s.searchField) }
    }

    func emptyAction(_ tag: Int) {
        switch tag {
        case 1: model.scan()
        case 2: clearFilters()
        case 3: record()
        case 4: snap()
        default: break
        }
    }

    func clearFilters() {
        model.kinds = []; model.status = nil; model.fix = nil; model.text = ""
        searchItem?.searchField.stringValue = ""
        model.reload()
    }

    func showShortcuts() { ShortcutsSheet.show(on: window) }

    // MARK: context menu

    func contextMenu(for rows: IndexSet) -> NSMenu? {
        let m = NSMenu()
        func add(_ t: String, _ sel: Selector, _ sym: String? = nil, key: String = "", mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = self
            if let s = sym { i.image = Look.symbol(s, t) }
            m.addItem(i)
            return i
        }
        if model.scope.listsSessions {
            let s = list.selectedSessions
            if s.count == 1, let one = s.first {
                if one.processed { _ = add(L("打开会话的条目", "Show Items"), #selector(mShowSessionItems), "square.stack") }
                else { _ = add(L("交给 Agent 整理", "Process with Agent"), #selector(mProcess)).image = BrandIcon.image(.chicken, size: 15) }
                if one.processed { _ = add(L("审核模式", "Review Mode"), #selector(mReview), "rectangle.stack", key: "r", mods: []) }
                m.addItem(.separator())
            }
            _ = add(L("在访达中显示", "Reveal in Finder"), #selector(mReveal), "folder", key: "r", mods: [.command, .shift])
            _ = add(L("拷贝路径", "Copy Path"), #selector(mCopyPath), "doc.on.doc", key: "c", mods: [.command, .option])
            return m
        }
        let items = list.selectedItems
        let fix = add(items.count > 1 ? L("让 Agent 修这 \(items.count) 条", "Let Agent Fix \(items.count) Items") : L("让 Agent 修", "Let Agent Fix"),
                      #selector(mFix), key: "\r")
        fix.image = BrandIcon.image(.peck, size: 15)
        fix.isEnabled = AppEnvironment.fixWithAgent != nil
        if AppEnvironment.fixWithAgent == nil { fix.toolTip = L("在设置里配好 agent 后可用", "Available once an agent is set up in Settings") }
        _ = add(L("预览主帧", "Quick Look"), #selector(mQuickLook), "eye", key: " ", mods: [])
        m.addItem(.separator())
        let kindItem = NSMenuItem(title: L("类型", "Kind"), action: nil, keyEquivalent: "")
        let km = NSMenu()
        for (k, key) in FilterBar.kindKeys.enumerated() {
            let i = NSMenuItem(title: Look.kindName(key), action: #selector(mSetKind(_:)), keyEquivalent: "\(k + 1)")
            i.keyEquivalentModifierMask = []
            i.representedObject = key
            i.target = self
            i.image = BrandIcon.kind(key, variant: "menu", size: 15)
            i.state = items.allSatisfy { $0.kind == key } ? .on : .off
            km.addItem(i)
        }
        kindItem.submenu = km
        m.addItem(kindItem)
        let st = NSMenuItem(title: L("状态", "Status"), action: nil, keyEquivalent: "")
        let sm = NSMenu()
        for s in ["draft", "confirmed", "deleted"] {
            let i = NSMenuItem(title: Look.statusName(s), action: #selector(mSetStatus(_:)), keyEquivalent: s == "deleted" ? "\u{8}" : "")
            i.keyEquivalentModifierMask = []
            i.representedObject = s
            i.target = self
            i.state = items.allSatisfy { $0.status == s } ? .on : .off
            sm.addItem(i)
        }
        st.submenu = sm
        m.addItem(st)
        if items.count == 1 { _ = add(L("改标题…", "Rename…"), #selector(mRename), "pencil", key: "e", mods: []) }
        m.addItem(.separator())
        _ = add(L("在访达中显示", "Reveal in Finder"), #selector(mReveal), "folder", key: "r", mods: [.command, .shift])
        _ = add(L("拷贝路径", "Copy Path"), #selector(mCopyPath), "doc.on.doc", key: "c", mods: [.command, .option])
        _ = add(L("拷贝链接", "Copy Link"), #selector(mCopyLink), "link")
        if items.count == 1, let it = items.first {
            let ed = NSMenuItem(title: L("在编辑器中打开", "Open in Editor"), action: nil, keyEquivalent: "")
            ed.image = Look.symbol("chevron.left.forwardslash.chevron.right", "")
            ed.submenu = editorMenu(for: it)
            m.addItem(ed)
            m.addItem(.separator())
            _ = add(L("审核模式", "Review Mode"), #selector(mReview), "rectangle.stack", key: "r", mods: [])
        }
        return m
    }

    func editorMenu(for it: ItemRow) -> NSMenu {
        let m = NSMenu()
        let editor = Editor.preferred
        for ref in Editor.codeRefs(it) {
            let i = NSMenuItem(title: ref, action: #selector(mOpenRef(_:)), keyEquivalent: "")
            i.representedObject = ref
            i.target = self
            m.addItem(i)
        }
        if !m.items.isEmpty { m.addItem(.separator()) }
        let f = NSMenuItem(title: L("会话文件夹", "Session Folder"), action: #selector(mOpenFolder), keyEquivalent: "")
        f.target = self
        m.addItem(f)
        let j = NSMenuItem(title: "items.json", action: #selector(mOpenItemsJSON), keyEquivalent: "")
        j.target = self
        m.addItem(j)
        if let e = editor { m.insertItem(menuHeader(e.name), at: 0) }
        return m
    }

    func sidebarMenu(_ s: Scope) -> NSMenu? {
        let m = NSMenu()
        var url: URL?
        switch s {
        case .workspace(let w): url = model.workspace(id: w).map { URL(fileURLWithPath: $0.path) }
        case .session(let id): url = model.sessionRow(id: id)?.url
        default: return nil
        }
        guard let u = url else { return nil }
        let r = NSMenuItem(title: L("在访达中显示", "Reveal in Finder"), action: #selector(mRevealURL(_:)), keyEquivalent: "")
        r.representedObject = u; r.target = self
        m.addItem(r)
        let c = NSMenuItem(title: L("拷贝路径", "Copy Path"), action: #selector(mCopyURL(_:)), keyEquivalent: "")
        c.representedObject = u; c.target = self
        m.addItem(c)
        if let e = Editor.preferred {
            let o = NSMenuItem(title: L("在 \(e.name) 中打开", "Open in \(e.name)"), action: #selector(mOpenURLInEditor(_:)), keyEquivalent: "")
            o.representedObject = u; o.target = self
            m.addItem(o)
        }
        return m
    }

    @objc func mFix() { fixSelection() }
    @objc func mQuickLook() { list.toggleQuickLook() }
    @objc func mSetKind(_ i: NSMenuItem) { (i.representedObject as? String).map(setKind) }
    @objc func mSetStatus(_ i: NSMenuItem) { (i.representedObject as? String).map(setStatus) }
    @objc func mRename() { renameSelection() }
    @objc func mReview() { reviewMode() }
    @objc func mCopyPath() { copyPaths() }
    @objc func mCopyLink() {
        let links = list.selectedItems.map { "blurt://item/\($0.uid)" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
    }
    @objc func mReveal() {
        let urls = list.selectedItems.map { it -> URL in
            if let f = it.primaryFrame, FileManager.default.fileExists(atPath: f) { return URL(fileURLWithPath: f) }
            return it.sessionURL
        } + list.selectedSessions.map(\.url)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
    @objc func mRevealURL(_ i: NSMenuItem) { (i.representedObject as? URL).map { NSWorkspace.shared.activateFileViewerSelecting([$0]) } }
    @objc func mCopyURL(_ i: NSMenuItem) {
        guard let u = i.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u.path, forType: .string)
    }
    @objc func mOpenURLInEditor(_ i: NSMenuItem) { (i.representedObject as? URL).map { Editor.open(folder: $0) } }
    @objc func mOpenRef(_ i: NSMenuItem) {
        guard let ref = i.representedObject as? String, let it = list.selectedItems.first else { return }
        openCode(ref, session: it.sessionURL)
    }
    @objc func mOpenFolder() { list.selectedItems.first.map { Editor.open(folder: $0.sessionURL) } }
    @objc func mOpenItemsJSON() { list.selectedItems.first.map { Editor.open(file: $0.sessionURL.appendingPathComponent("items.json"), line: nil) } }
    @objc func mShowSessionItems() { list.selectedSessions.first.map { go(.session($0.id)) } }
    @objc func mProcess() { list.selectedSessions.first.map { process(session: $0.url) } }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(mFix): return AppEnvironment.fixWithAgent != nil && !list.selectedItems.isEmpty
        case #selector(mRename), #selector(mSetKind(_:)), #selector(mSetStatus(_:)): return Scripts.canWrite && !list.selectedItems.isEmpty
        default: return true
        }
    }

    // MARK: WebHostActions

    func reveal(file: URL) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    func quickLook(files: [URL]) { list.toggleQuickLook(files) }
    func canFix() -> Bool { AppEnvironment.fixWithAgent != nil }
    func webWrote(_ session: URL) { Scripts.indexUpdate([session]) }

    func openCode(_ ref: String, session: URL) {
        let ws = model.workspace(ofSession: list.selectedItems.first?.sessionID ?? "").map { URL(fileURLWithPath: $0.path) }
        Editor.open(ref: ref, repo: ws, session: session)
    }

    func fixWithAgent(uids: [String]) {
        guard let fix = AppEnvironment.fixWithAgent else {
            return alert(L("还没配好 agent", "No agent set up yet"),
                         L("在设置里选一个 coding agent（Claude Code、Codex、Kimi…）后，就能一键把条目交给它修。",
                           "Pick a coding agent (Claude Code, Codex, Kimi…) in Settings to hand items over with one key."))
        }
        fix(uids)
    }

    func process(session: URL) { (NSApp.delegate as? App)?.process(session) }

    // MARK: toolbar actions

    @objc func record() { (NSApp.delegate as? App)?.startRecording(useLast: false) }
    @objc func snap() { snapper.hotkey() }
    @objc func toolbarFix() { fixSelection() }
    @objc func showPalette() { palette.toggle() }

    // MARK: keys that work wherever the focus is

    func handleKeyEquivalent(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == .command {
            switch ch {
            case "k": palette.toggle(); return true
            case "f": focusSearch(); return true
            case "1": go(.inbox); return true
            case "2": go(.all); return true
            case "3": go(.smart(.openIssues)); return true
            case "4": go(.smart(.ideas)); return true
            case "5": go(.smart(.fixing)); return true
            case "6": go(.smart(.fixed)); return true
            case "7": go(.sessions); return true
            default: break
            }
            if e.keyCode == 36 || e.keyCode == 76, window?.firstResponder === list.table { fixSelection(); return true }
        }
        if mods == [.command, .shift], ch == "r" { mReveal(); return true }
        if mods == [.command, .option], ch == "c" { copyPaths(); return true }
        return false
    }

    // MARK: toolbar

    static let recordID = NSToolbarItem.Identifier("record"), snapID = NSToolbarItem.Identifier("snap")
    static let fixID = NSToolbarItem.Identifier("fix"), filterID = NSToolbarItem.Identifier("filter")
    static let searchID = NSToolbarItem.Identifier("search")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.recordID, Self.snapID, .flexibleSpace, Self.fixID, Self.filterID, Self.searchID]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ label: String, _ sym: String, _ sel: Selector, tip: String) -> NSToolbarItem {
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = label
            i.paletteLabel = label
            i.toolTip = tip
            i.image = Look.symbol(sym, label, size: 15)
            i.target = self
            i.action = sel
            i.isBordered = true
            return i
        }
        switch id {
        case Self.recordID:
            let i = button(L("录制", "Record"), "record.circle", #selector(record), tip: L("录制屏幕和讲解 ", "Record your screen and voice ") + hk(.toggleRecord))
            return i
        case Self.snapID:
            let i = button(L("截图", "Snap"), "camera.viewfinder", #selector(snap), tip: L("截一张图，随口说两句 ", "Snap a shot and say a word ") + hk(.snap))
            i.image = BrandIcon.image(.snap, size: 19)
            return i
        case Self.fixID:
            let i = button(L("让 Agent 修", "Let Agent Fix"), "wand.and.stars", #selector(toolbarFix), tip: L("把选中的条目交给 coding agent（⌘↩）", "Hand the selected items to your coding agent (⌘↩)"))
            i.image = BrandIcon.image(.peck, size: 19)
            return i
        case Self.filterID:
            let i = NSMenuToolbarItem(itemIdentifier: id)
            i.label = L("筛选", "Filter")
            i.image = Look.symbol("line.3.horizontal.decrease.circle", L("筛选", "Filter"), size: 15)
            i.toolTip = L("按类型、状态、修复状态筛选", "Filter by kind, status and fix state")
            let m = NSMenu()
            m.delegate = self
            i.menu = m
            i.showsIndicator = false
            return i
        case Self.searchID:
            let s = NSSearchToolbarItem(itemIdentifier: id)
            s.searchField.placeholderString = L("搜索条目、原话、字段", "Search items, quotes, fields")
            s.searchField.delegate = self
            s.searchField.sendsSearchStringImmediately = true
            s.searchField.sendsWholeSearchString = false
            s.searchField.setAccessibilityLabel(L("搜索", "Search"))
            s.preferredWidthForSearchField = 240
            searchItem = s
            return s
        default: return nil
        }
    }

    func controlTextDidChange(_ n: Notification) {
        guard let f = n.object as? NSSearchField, f === searchItem?.searchField else { return }
        model.text = f.stringValue
        model.reload()
        if list.table.selectedRow < 0, model.rowCount > 0 { list.table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === searchItem?.searchField else { return false }
        if sel == #selector(NSResponder.moveDown(_:)) || sel == #selector(NSResponder.insertNewline(_:)) {
            window?.makeFirstResponder(list.table)
            if list.table.selectedRow < 0, model.rowCount > 0 { list.table.selectRowIndexes([0], byExtendingSelection: false) }
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            if control.stringValue.isEmpty { window?.makeFirstResponder(list.table); return true }
            return false
        }
        return false
    }

    // the filter menu (toolbar)
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ t: String, _ on: Bool, _ sel: Selector, _ obj: Any?) {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            i.target = self
            i.state = on ? .on : .off
            i.representedObject = obj
            menu.addItem(i)
        }
        menu.addItem(menuHeader(L("类型", "Kind")))
        for k in FilterBar.kindKeys { item(Look.kindName(k), model.kinds.contains(k), #selector(fKind(_:)), k) }
        menu.addItem(menuHeader(L("状态", "Status")))
        for (t, v) in [(L("全部（除丢弃）", "All but Dropped"), nil), (Look.statusName("draft"), "draft"),
                       (Look.statusName("confirmed"), "confirmed"), (Look.statusName("deleted"), "deleted")] as [(String, String?)] {
            item(t, model.status == v, #selector(fStatus(_:)), v)
        }
        menu.addItem(menuHeader(L("修复", "Fix")))
        for (t, v) in [(L("全部", "Any"), nil), (L("没交给 agent", "Not Sent"), "none"), (Look.fixName("fixing")!, "fixing"),
                       (Look.fixName("fixed")!, "fixed"), (Look.fixName("wontfix")!, "wontfix"), (Look.fixName("reopened")!, "reopened")] as [(String, String?)] {
            item(t, model.fix == v, #selector(fFix(_:)), v)
        }
        menu.addItem(.separator())
        let c = NSMenuItem(title: L("清除筛选", "Clear Filters"), action: #selector(fClear), keyEquivalent: "")
        c.target = self
        c.isEnabled = model.filtered
        menu.addItem(c)
    }
    @objc func fKind(_ i: NSMenuItem) {
        guard let k = i.representedObject as? String else { return }
        if model.kinds.contains(k) { model.kinds.remove(k) } else { model.kinds.insert(k) }
        model.reload()
    }
    @objc func fStatus(_ i: NSMenuItem) { model.status = i.representedObject as? String; model.reload() }
    @objc func fFix(_ i: NSMenuItem) { model.fix = i.representedObject as? String; model.reload() }
    @objc func fClear() { clearFilters() }

    // MARK: index watcher (FSEvents → index.py update)

    func updateWatcher() {
        var roots = [BlurtPaths.workspace.appendingPathComponent("recordings").path]
        for w in model.workspaces {
            roots.append(w.kind == "default" ? w.path + "/recordings" : w.path + "/.blurt/sessions")
        }
        for w in recordConfig()["workspaces"] as? [String] ?? [] { roots.append(w + "/.blurt/sessions") }
        let uniq = Array(Set(roots)).sorted()
        guard uniq != watchedRoots else { return }
        watchedRoots = uniq
        watcher?.stop()
        let w = IndexWatcher(roots: uniq.map { URL(fileURLWithPath: $0) })
        w.onChange = { dirs in Scripts.indexUpdate(dirs) }
        w.start()
        watcher = w
    }

    // MARK: window state

    struct State: Codable {
        var frame: String?, sidebar: Double?, detail: Double?, sidebarCollapsed: Bool?
        var scope: String?, kinds: [String]?, status: String?, fix: String?, text: String?, sort: String?, ascending: Bool?
        var selected: [String]?, open: Bool?
    }
    static var stateURL: URL { blurtHome.appendingPathComponent("ui/main-window.json") }

    static func loadState() -> State? {
        (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    }

    func scheduleSave() {
        guard restored else { return }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.saveState(open: self?.window?.isVisible == true) }
    }

    func saveState(open: Bool) {
        guard restored, let w = window else { return }
        let items = split.splitViewItems
        var s = State()
        s.frame = w.frameDescriptor
        s.sidebar = items[0].isCollapsed ? nil : Double(items[0].viewController.view.frame.width)
        s.sidebarCollapsed = items[0].isCollapsed
        s.detail = Double(items[2].viewController.view.frame.width)
        s.scope = model.scope.key
        s.kinds = model.kinds.sorted(); s.status = model.status; s.fix = model.fix; s.text = model.text
        s.sort = model.sort; s.ascending = model.ascending
        s.selected = list.selectedIDs
        s.open = open
        try? FileManager.default.createDirectory(at: Self.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: Self.stateURL, options: .atomic) }
    }

    func restoreState() {
        guard let w = window else { return }
        _ = list.view; _ = sidebar.view; _ = detail.view
        let s = Self.loadState()
        if let f = s?.frame { w.setFrame(from: f) } else { w.center() }
        if let sc = s?.scope.flatMap(Scope.init(key:)) { model.scope = sc }
        model.kinds = Set(s?.kinds ?? [])
        model.status = s?.status
        model.fix = s?.fix
        model.text = ""          // like Finder and Mail: a new window starts without the last search
        model.sort = s?.sort ?? "updated"
        model.ascending = s?.ascending ?? false
        searchItem?.searchField.stringValue = model.text
        if let key = Optional(model.sort) {
            list.table.sortDescriptors = [NSSortDescriptor(key: key, ascending: model.ascending)]
        }
        model.reloadAll()
        sidebar.select(model.scope)
        list.reload(keep: s?.selected ?? [])
        if list.table.selectedRow < 0, model.rowCount > 0 { list.table.selectRowIndexes([0], byExtendingSelection: false) }
        listSelectionChanged()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let sv = self.split.splitView
            if s?.sidebarCollapsed == true { self.split.splitViewItems[0].isCollapsed = true }
            else if let sb = s?.sidebar { sv.setPosition(CGFloat(sb), ofDividerAt: 0) }
            if let d = s?.detail, d > 0 { sv.setPosition(sv.bounds.width - CGFloat(d) - sv.dividerThickness, ofDividerAt: 1) }
            else {
                let side = self.split.splitViewItems[0].isCollapsed ? 0 : self.sidebar.view.frame.width
                sv.setPosition(min(sv.bounds.width - 440, side + 620), ofDividerAt: 1)
            }
        }
    }

    func windowDidResize(_ notification: Notification) { scheduleSave() }
    func windowDidMove(_ notification: Notification) { scheduleSave() }
    func windowDidBecomeKey(_ notification: Notification) { NSApp.mainMenu = MainMenu.build() }

    func windowWillClose(_ notification: Notification) {
        saveState(open: false)
        palette.close()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        DispatchQueue.main.async {
            if ReviewHub.shared.windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        if let w = window, w.isVisible { a.beginSheetModal(for: w) } else { a.runModal() }
    }
}
