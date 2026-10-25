// Blurt's main window: sidebar (places + projects) | items | detail in an NSSplitViewController, a unified toolbar
// (Record, Snap, Hand Off, Move to Project, search; on the Dictation page search only), ⌘K command palette, context
// menus, Quick Look, a blank detail while there are no items at all (the list's first-run state speaks), window state
// restored from $BLURT_HOME/ui/main-window.json (not UserDefaults: test builds share the bundle id with the user's
// real app and must not disturb its state).
//
// Reads come from index.db (MainModel / IndexReader v3), projects.json (ProjectStore) and $BLURT_HOME/jobs
// (JobStore). Every write goes through the CLIs (Scripts): items.py user-ops / state / move, projects.py,
// handoff.py, sessions.py (AppEnvironment.dispatch, P3). The index follows (items.py updates it in-process, FSEvents
// + `index.py update` catch everything else) and the model reloads when index.db's data_version moves.
// This window never opens by itself: no review pops up when processing finishes (K4 notification rules).
import AppKit
import BlurtCore
import Combine
import Quartz

final class MainWindow: NSWindow {
    weak var controller: MainWindowController?
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if controller?.handleKeyEquivalent(e) == true { return true }
        return super.performKeyEquivalent(with: e)
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate,
                                  NSMenuDelegate, NSMenuItemValidation, ItemListActions, WebHostActions, SidebarActions, MainWindowHosting {
    static let shared = MainWindowController()

    let model = MainModel()
    let split = NSSplitViewController()
    let sidebar: SidebarController
    let list: ItemListController
    let detail = WebHostController()
    /// The middle and detail columns: the items and their detail, or the Dictation page's two halves.
    let listColumn: ColumnController
    let detailColumn: ColumnController
    private var page: DictationPage?
    /// The Dictation page (DictationPage.swift), made on first use.
    var dictation: DictationPage {
        if let p = page { return p }
        let p = DictationPage()
        page = p
        entriesWatch = p.model.$entries.sink { [weak self] _ in DispatchQueue.main.async { self?.updateTitle() } }
        return p
    }
    var dictationIfLoaded: DictationPage? { page }
    private var entriesWatch: AnyCancellable?
    var searchItem: NSSearchToolbarItem?
    var watcher: IndexWatcher?
    var watchedRoots: [String] = []
    lazy var palette = CommandPalette(controller: self)
    private var saveTimer: Timer?
    private var restored = false
    /// The job the detail shows (selected in the jobs section), until another selection replaces it.
    private(set) var shownJob: String?
    /// The reminder sheet while it is up (tests answer it).
    var openAlert: NSAlert?

    init() {
        sidebar = SidebarController(model: model)
        list = ItemListController(model: model)
        listColumn = ColumnController(list)
        detailColumn = ColumnController(detail)
        let w = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: true)
        super.init(window: w)
        w.controller = self
        w.title = "Blurt"
        w.minSize = NSSize(width: 900, height: 520)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.titlebarSeparatorStyle = .automatic
        w.toolbarStyle = .unified
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.delegate = self
        w.setAccessibilityLabel(T("main.window.label"))
        if let appearance = ProcessInfo.processInfo.environment["BLURT_APPEARANCE"] {   // screenshots of both themes
            w.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }

        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.minimumThickness = 190
        side.maximumThickness = 320
        side.canCollapse = true
        let content = NSSplitViewItem(contentListWithViewController: listColumn)
        content.minimumThickness = 360
        let det = NSSplitViewItem(viewController: detailColumn)
        det.minimumThickness = 380
        det.canCollapse = true
        det.holdingPriority = .init(249)
        split.addSplitViewItem(side)
        split.addSplitViewItem(content)
        split.addSplitViewItem(det)
        split.splitView.dividerStyle = .thin
        w.contentViewController = split
        w.setContentSize(NSSize(width: 1320, height: 820))   // the content VC sized the window to its views

        let tb = NSToolbar(identifier: "BlurtMain")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        w.toolbar = tb

        list.actions = self
        detail.actions = self
        sidebar.actions = self
        model.onReload = { [weak self] in
            guard let self = self else { return }
            self.syncPage()             // every way to a place (go, reveal, restore) reloads: the columns follow the scope
            self.list.reload()
            // the same item still selected, but its row changed under it (a state, a move, a renamed folder)
            if self.shownJob == nil, self.list.selectedIDs.count == 1, let it = self.list.selectedItems.first {
                self.detail.refresh(item: it, projects: self.model.projects)
            } else if self.shownJob == nil, self.list.selectedIDs.isEmpty, self.detail.showsQuietNothing != self.model.isEmptyWorld,
                      self.detail.showsNothing {
                self.listSelectionChanged()     // the first item arrived (or the last one went): "Nothing selected" or blank
            }
            self.updateTitle()
            self.scheduleSave()
        }
        model.onSidebar = { [weak self] in self?.sidebar.rebuild(); self?.updateWatcher() }
        model.onJobs = { [weak self] in self?.list.reloadJobs() }
        model.onIndexState = { [weak self] in
            guard let self = self else { return }
            self.list.reload()
            self.updateTitle()
            if self.model.indexState == .ready, self.list.table.selectedRow < 0, self.model.rowCount > 0 {
                self.list.table.selectRowIndexes([0], byExtendingSelection: false)
            }
        }
        ProjectStore.shared.onChange = { [weak self] in self?.model.reloadSidebar(); self?.updateTitle(); self?.list.updateEmpty() }
        NotificationCenter.default.addObserver(forName: .blurtJobsChanged, object: nil, queue: .main) { [weak self] n in
            self?.jobsChanged(n.userInfo?["jobs"] as? [Job] ?? [])
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
        if model.scope == .dictation { dictation.didShow() }
        if window?.firstResponder == nil || window?.firstResponder === window { focusList() }
    }

    /// The Dictation page (⌥⌘D, the menu-bar menu, the palette, Settings → Dictation).
    func showDictation() {
        show()
        go(.dictation)
        focusList()
    }

    /// The Dictation page's Lab tab (the Go menu, the palette, the test hooks).
    func showDictationLab() {
        showDictation()
        guard DictationLabModel.enabled else { return }
        dictation.showLab()
    }

    /// The list that is showing: the items' table, or the Dictation page's.
    func focusList() {
        if model.scope == .dictation {
            // SwiftUI builds its table on the next pass
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self = self, self.model.scope == .dictation, let t = self.dictation.table else { return }
                    self.window?.makeFirstResponder(t)
                }
            }
        } else {
            window?.makeFirstResponder(list.table)
        }
    }

    /// The columns follow the scope: the Dictation page in place of the items and their detail, the toolbar's search
    /// field searching what is showing, and the toolbar without the items' actions there.
    func syncPage() {
        let on = model.scope == .dictation
        let showing = listColumn.current !== list
        guard on != showing else { return }
        syncToolbar(dictation: on)
        let field = searchItem?.searchField
        if on {
            let p = dictation
            listColumn.show(p.list)
            detailColumn.show(p.detail)
            p.didShow()
            field?.placeholderString = T("dictation.history.search")
            field?.stringValue = p.model.query
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        } else {
            page?.didHide()
            listColumn.show(list)
            detailColumn.show(detail)
            field?.placeholderString = T("main.search.placeholder")
            field?.stringValue = model.text
        }
    }

    /// Tests and the search field: the Dictation page's search.
    func setDictationQuery(_ q: String) {
        dictation.model.query = q
        if model.scope == .dictation { searchItem?.searchField.stringValue = q }
        dictationFollowsSearch()
    }

    /// After a search: keep a selection among what still matches (the first match otherwise).
    private func dictationFollowsSearch() {
        let m = dictation.model
        let ids = Set(m.filtered.map(\.id))
        if m.selection.isEmpty || !m.selection.isSubset(of: ids) { m.select(m.filtered.first?.id) }
    }

    func reveal(uid: String) {
        show()
        guard let row = model.itemRow(uid: uid) else {
            // a link, notification or job for an item that was deleted or moved out of every store
            appDelegate?.toast(T("app.url.no_item", String(uid.prefix(12))))
            return
        }
        model.text = ""
        searchItem?.searchField.stringValue = ""
        model.state = row.discarded ? "discarded" : nil
        model.kinds = []
        if model.row(of: uid) == nil {
            model.scope = row.projectID == "inbox" ? .unassigned : .project(row.projectID)
            model.reload()
        }
        if model.row(of: uid) == nil { model.scope = .all; model.reload() }
        sidebar.select(model.scope)
        list.select(id: uid)
        window?.makeFirstResponder(list.table)
    }

    /// A capture batch: its items, with the whole batch in the detail to triage. false: not a batch the index or the
    /// jobs know (the window still comes up).
    @discardableResult
    func reveal(session: URL) -> Bool {
        show()
        // realpath, not resolvingSymlinksInPath: that drops /private from /private/tmp, and index.py keeps it
        let dir = FixWatcher.real(session.standardizedFileURL.path)
        if let s = (try? model.reader?.session(dir: dir)) ?? nil {
            go(.session(s.id))
            if s.itemCount > 0, !s.legacy { detail.show(session: s.url) }
            return true
        } else if let j = JobStore.shared.jobs.first(where: { $0.session.map { FixWatcher.real($0.path) } == dir }) {
            reveal(job: j.id)       // still being captured or processed: its progress
            return true
        }
        return false
    }

    func reveal(job: String) {
        show()
        guard let j = JobStore.shared.job(job) else {
            // a session whose record is gone (a v0.6 run, a removed job): say so rather than doing nothing
            appDelegate?.toast(T("main.toast.session_gone"))
            return
        }
        if !model.scope.showsJobs || !model.jobs.contains(where: { $0.id == job }) {
            go(j.project.map { $0 == "inbox" ? .unassigned : .project($0) } ?? .inProgress)
            if !model.jobs.contains(where: { $0.id == job }) { go(.inProgress) }
        }
        selectJob(job)
    }

    func reveal(project: String) {
        show()
        go(project == "inbox" ? .unassigned : .project(project))
    }

    func showInbox() {
        show()
        go(.inbox)
    }

    func becomeRegular() {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = MainMenu.build()
    }

    // MARK: navigation

    func go(_ s: Scope) {
        guard s != model.scope || model.rowCount == 0 else { return }
        list.forgetSelection()        // a new place starts at its first row
        shownJob = nil
        model.scope = s
        if s.isTable { roomForTable() }
        model.reload()
        sidebar.select(s)
        if s == .dictation {
            list.table.deselectAll(nil)      // nothing of the items is acted on from here (the Item menu, the palette)
            dictation.model.selectFirstIfNone()
            focusList()
            return
        }
        if list.table.selectedRow < 0, model.rowCount > 0 { list.table.selectRowIndexes([0], byExtendingSelection: false) }
        list.scrollToStart()
        listSelectionChanged()
    }

    func sidebarSelected(_ s: Scope) { go(s) }

    /// The full table wants ~760 pt: take it from the detail column while that keeps its minimum.
    func roomForTable() {
        let sv = split.splitView
        let items = split.splitViewItems
        guard items.count == 3, !items[2].isCollapsed else { return }
        let list = sv.convert(items[1].viewController.view.bounds, from: items[1].viewController.view)
        let detail = items[2].viewController.view.frame
        let want: CGFloat = 760, minDetail: CGFloat = 400
        guard list.width < want, detail.width > minDetail else { return }
        let give = min(want - list.width, detail.width - minDetail)
        sv.setPosition(list.maxX + give, ofDividerAt: 1)
    }

    func updateTitle() {
        window?.title = model.scopeTitle
        if model.scope == .dictation {
            if let p = page, p.model.tab == .lab {
                window?.subtitle = T("dictation.lab.subtitle", T("dictation.lab.cases", p.lab.cases.count))
                return
            }
            let n = page?.model.entries.count ?? 0
            window?.subtitle = n > 0 ? TP("main.dictation.count", n) : ""
            return
        }
        window?.subtitle = model.indexState != .ready ? "" : model.scope == .inbox && !model.filtered ? needsYou : TP("main.items.count", model.rowCount)
    }

    /// The inbox's subtitle (K3): "3 new · 2 to verify" under the title "Inbox" — the same words as the menu bar
    /// menu's rows; a zero part left out; nothing when both are zero (the empty state says it).
    var needsYou: String {
        let c = model.counts
        return [c.new > 0 ? T("main.inbox.new", c.new) : nil, c.toVerify > 0 ? T("main.inbox.verify", c.toVerify) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    func jobsChanged(_ changed: [Job]) {
        model.reloadJobs()
        detail.refreshBanner(projects: model.projects)
        if let id = shownJob, let j = JobStore.shared.job(id) {
            detail.show(job: j, projectName: j.project.flatMap { ProjectStore.shared.project(id: $0) }?.name)
        }
    }

    // MARK: ItemListActions

    func listSelectionChanged() {
        let items = list.selectedItems
        if !items.isEmpty { shownJob = nil; list.jobs.selected = nil }
        if shownJob != nil { return }
        if items.count == 1, let it = items.first {
            detail.show(item: it, projects: model.projects)
        } else {
            detail.showNothing(items.count, quiet: items.isEmpty && model.isEmptyWorld)
        }
        scheduleSave()
    }

    func selectJob(_ id: String) {
        guard let j = JobStore.shared.job(id) else { return }
        list.table.deselectAll(nil)
        shownJob = id
        list.jobs.selected = id
        detail.show(job: j, projectName: j.project.flatMap { ProjectStore.shared.project(id: $0) }?.name)
    }

    func openSelection() { window?.makeFirstResponder(detail.web) }

    func handOffSelection() {
        let uids = list.selectedItems.map(\.uid)
        guard !uids.isEmpty else { NSSound.beep(); return }
        dispatch(uids: uids)
    }

    func renameSelection() {
        guard let it = list.selectedItems.first, let w = window else { return }
        let a = NSAlert()
        a.messageText = T("main.rename.title")
        a.informativeText = "\(Look.kindName(it.kind)) · \(it.itemID)"
        let f = NSTextField(string: it.title)
        f.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        a.accessoryView = f
        a.addButton(withTitle: T("action.save"))
        a.addButton(withTitle: T("action.cancel"))
        a.window.initialFirstResponder = f
        a.beginSheetModal(for: w) { [weak self] r in
            let t = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard r == .alertFirstButtonReturn, !t.isEmpty, t != it.title else { return }
            self?.edit([it], ["title": t])
        }
    }

    func setKind(_ kind: String) { edit(list.selectedItems.filter { $0.kind != kind }, ["kind": kind]) }

    // MARK: state (K3)

    /// An action on the items it is valid for (the others are left alone). Hand off opens the dispatch panel; the rest
    /// go to items.py state.
    func apply(_ action: String, to items: [ItemRow]) { apply(action, to: items, redoing: false) }

    /// `redoing`: called by ⇧⌘Z — its undo is registered right away, inside the redo (where it belongs), not later.
    private func apply(_ action: String, to items: [ItemRow], redoing: Bool) {
        let items = StateMenu.valid(action, items)
        guard !items.isEmpty else { NSSound.beep(); return }
        if action == "hand_off" { return dispatch(uids: items.map(\.uid)) }
        guard Scripts.canWrite else { return alert(T("main.error.cant_edit"), T("main.error.no_scripts")) }
        if redoing { registerStateUndo(action, items) }
        Scripts.state(items.map(\.uid), action: action) { [weak self] r in
            switch r {
            case .success:
                self?.wrote(items)
                if !redoing { self?.registerStateUndo(action, items) }
            case .failure(let f): self?.alert(T("main.error.save_title"), f.localized)
            }
        }
    }

    /// ⌘Z after a state action (A D R W X ⌫, the ring, the menus): each item back to the state it had, through
    /// items.py's --undo (the user taking back their own change); ⇧⌘Z does the action again.
    func registerStateUndo(_ action: String, _ items: [ItemRow]) {
        guard let um = window?.undoManager else { return }
        let before = items.map { ($0.uid, $0.state) }
        um.registerUndo(withTarget: self) { c in c.undoState(action, before) }
        um.setActionName(StateMenu.title(action))
    }

    private func undoState(_ action: String, _ before: [(String, String)]) {
        let uids = before.map(\.0)
        if let um = window?.undoManager {
            um.registerUndo(withTarget: self) { c in c.apply(action, to: c.model.items(uids: uids), redoing: true) }   // redo
            um.setActionName(StateMenu.title(action))
        }
        for (state, group) in Dictionary(grouping: before, by: \.1) {
            let ids = group.map(\.0)
            Scripts.undoState(ids, to: state) { [weak self] r in
                guard let self = self else { return }
                switch r {
                case .success:
                    self.wrote(self.model.items(uids: ids))
                    self.model.reloadAll()                  // back in this list (a discard undone): selected again
                    if ids.contains(where: { self.model.row(of: $0) != nil }) { self.list.reload(keep: ids) }
                case .failure(let f): self.alert(T("main.error.save_title"), f.localized)
                }
            }
        }
    }

    func applyState(_ action: String, uids: [String]) { apply(action, to: model.items(uids: uids)) }

    /// A list key (A, D, R, W, X / ⌫) on the selection: each item gets what the key means from its own state — R sends
    /// back what is waiting to be verified and reopens what is done in the same press.
    func act(key: String) {
        let byAction = Dictionary(grouping: list.selectedItems.filter { !$0.legacy }) { Lifecycle.action(forKey: key, state: $0.state) ?? "" }
        let runs = byAction.filter { !$0.key.isEmpty }
        guard !runs.isEmpty else { NSSound.beep(); return }
        for a in Lifecycle.actions where runs[a] != nil { apply(a, to: runs[a]!) }
    }

    /// The state menu of the selection, under a row's ring (S, or a click on the ring).
    func showStateMenu(row: Int?, from view: NSView?) {
        let items = list.selectedItems
        guard !items.isEmpty, Scripts.canWrite else { NSSound.beep(); return }
        let m = StateMenu.menu(for: items, canHandOff: true, selector: #selector(mState(_:)), target: self)
        guard !m.items.isEmpty else { NSSound.beep(); return }
        if let v = view ?? row.flatMap(list.ringView(row:)), v.window != nil {
            m.popUp(positioning: nil, at: NSPoint(x: -4, y: v.isFlipped ? v.bounds.height + 3 : -3), in: v)
        } else if let r = row ?? list.table.selectedRowIndexes.first {
            let rect = list.table.rect(ofRow: r)
            m.popUp(positioning: nil, at: NSPoint(x: rect.minX + 40, y: rect.maxY), in: list.table)
        }
    }

    @objc func mState(_ i: NSMenuItem) {
        guard let a = i.representedObject as? String else { return }
        if a == "back" { act(key: "r") } else { apply(a, to: list.selectedItems) }
    }
    @objc func mStateMenu() { showStateMenu(row: list.table.selectedRowIndexes.first, from: nil) }

    /// User edits = items.py user-ops by uid, per project (the same ops the review component sends).
    func edit(_ items: [ItemRow], _ set: [String: Any]) {
        let items = items.filter { !$0.legacy }
        guard !items.isEmpty else { return }
        guard Scripts.canWrite else { return alert(T("main.error.cant_edit"), T("main.error.no_scripts")) }
        // ⌘Z: each item's old title / kind back (registered now, so inside an undo it becomes the redo)
        let olds = items.map { it in (it.uid, set.keys.reduce(into: [String: Any]()) { d, k in
            switch k { case "title": d[k] = it.title; case "kind": d[k] = it.kind; default: break }
        }) }
        if let um = window?.undoManager, olds.allSatisfy({ $0.1.count == set.count }) {
            um.registerUndo(withTarget: self) { c in for (uid, old) in olds { c.edit(c.model.items(uids: [uid]), old) } }
            um.setActionName(set.keys.contains("title") ? T("main.menu.rename").replacingOccurrences(of: "…", with: "") : T("main.undo.kind"))
        }
        for (p, group) in Dictionary(grouping: items, by: \.projectID) {
            let ops: [[String: Any]] = group.map { ["op": "set", "id": $0.uid, "set": set, "unset": [] as [String]] }
            Scripts.userOps(["--project", p], ops) { [weak self] r in
                if case .failure(let f) = r { self?.alert(T("main.error.save_title"), f.localized) }
                self?.wrote(group)
            }
        }
    }

    /// After a write: make sure the index catches up even when items.py couldn't update it in-process.
    func wrote(_ items: [ItemRow]) {
        Scripts.indexUpdate(items.map(\.fileURL))
        detail.reload()
    }

    func copyPaths() {
        let paths = list.selectedItems.map { $0.primaryFrame.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? $0.fileURL.path }
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
        case 5: openFolder()
        case 6: if case .project(let p) = model.scope { useProject(p) }
        case 7: if case .project(let p) = model.scope { locateFolder(p) }
        default: break
        }
    }

    /// A project whose folder is gone: pick where it is now. Opening it again is the same project (projects.py add
    /// relocates a store whose registered folder has disappeared), and the index follows.
    func locateFolder(_ id: String) {
        guard let p = model.project(id: id) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = T("main.open.prompt")
        panel.message = T("main.missing.locate.message", p.name)
        var up = p.path.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: up.path), up.path != "/" { up.deleteLastPathComponent() }
        panel.directoryURL = up
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .OK, let u = panel.url else { return }
            self?.openFolders([u])
        }
        if let w = window, w.isVisible { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
    }

    func clearFilters() {
        model.kinds = []; model.state = nil; model.text = ""
        searchItem?.searchField.stringValue = ""
        model.reload()
        list.scrollToStart()
    }

    func showShortcuts() { ShortcutsSheet.show(on: window) }

    // MARK: projects

    @objc func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = T("main.open.prompt")
        panel.message = T("main.open.message")
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .OK else { return }
            self?.openFolders(panel.urls)
        }
        if let w = window, w.isVisible { panel.beginSheetModal(for: w, completionHandler: done) } else { activateApp(); done(panel.runModal()) }
    }

    /// Registers the folders as projects (projects.py add) and shows the last one.
    func openFolders(_ urls: [URL]) {
        Task { @MainActor in
            var last: Project?
            for u in urls {
                do { last = try await ProjectStore.shared.open(folder: u) }
                catch let e as ProjectError { alert(T("main.open.failed", u.lastPathComponent), Scripts.Failure(code: e.code, message: "\(e)").localized) }
                catch { alert(T("main.open.failed", u.lastPathComponent), "\(error)") }
            }
            if let p = last {
                model.reloadSidebar()
                reveal(project: p.id)
            }
        }
    }

    /// Items to a project (or "inbox" = Unassigned), as the user's choice (items.py move --by user).
    func move(uids: [String], to project: String) {
        let items = model.items(uids: uids).filter { $0.projectID != project && !$0.legacy }
        guard !items.isEmpty else { return }
        Scripts.move(items.map(\.uid), to: project) { [weak self] r in
            switch r {
            case .success(let o):
                let n = (o["moved"] as? [Any])?.count ?? items.count
                let name = project == "inbox" ? T("project.inbox") : ProjectStore.shared.project(id: project)?.name ?? project
                appDelegate?.toast(TP("main.move.done", n, name), icon: .check)
                self?.wrote(items)
            case .failure(let f): self?.alert(T("main.move.failed"), f.localized)
            }
        }
    }

    func projectSettings(_ id: String) {
        guard let p = ProjectStore.shared.project(id: id), !p.isInbox, let w = window else { return }
        ProjectSettingsSheet.show(p, on: w) { [weak self] patch in
            Task { @MainActor in
                do { try await ProjectStore.shared.update(id, patch) }
                catch let e as ProjectError { self?.alert(T("main.project.save_failed"), Scripts.Failure(code: e.code, message: "\(e)").localized) }
                catch { self?.alert(T("main.project.save_failed"), "\(error)") }
            }
        }
    }

    func removeProject(_ id: String) {
        guard let p = ProjectStore.shared.project(id: id), let w = window else { return }
        let a = NSAlert()
        a.messageText = T("main.project.remove.title", p.name)
        a.informativeText = T("main.project.remove.detail")
        a.addButton(withTitle: T("main.project.remove.confirm"))
        a.addButton(withTitle: T("action.cancel"))
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                do {
                    try await ProjectStore.shared.remove(id)
                    if self?.model.scope == .project(id) { self?.go(.inbox) }
                } catch { self?.alert(T("main.project.save_failed"), "\(error)") }
            }
        }
    }

    func useProject(_ id: String?) {
        Task { @MainActor in
            do { try await ProjectStore.shared.use(id) } catch { appDelegate?.toast(T("main.project.use_failed")) }
        }
    }

    // MARK: handing off (K5 in Blurt, K6 to your own agent)

    /// Why these items can't go to a session in Blurt, before anyone tries (the menus show it as the item's tooltip,
    /// ⌘Return as a toast): nil = they can.
    func dispatchBlocker(_ items: [ItemRow]) -> String? {
        let items = items.filter { !$0.discarded && !$0.legacy }
        if items.isEmpty { return nil }
        if Set(items.map(\.projectID)).count > 1 { return T("main.dispatch.one_project") }
        if items.first?.projectID == "inbox" { return T("main.dispatch.needs_project") }
        return nil
    }

    /// Start an agent session in Blurt: the dispatch panel (agent, mode, worktree, the concurrent-edit reminder —
    /// inline, Terminal/DispatchPanel). Items that can't go say why at once, with the way out (Move to Project…).
    func dispatch(uids: [String]) {
        let items = model.items(uids: uids).filter { !$0.discarded && !$0.legacy }
        guard !items.isEmpty else { NSSound.beep(); return }
        if let why = dispatchBlocker(items) {
            NSSound.beep()
            let inbox = items.first?.projectID == "inbox" && Set(items.map(\.projectID)).count == 1
            if let island = AppEnvironment.island {
                island.toast(why, actionTitle: inbox ? T("main.dispatch.move_first") : nil,
                             action: inbox ? { [weak self] in self?.showMoveMenu() } : nil)
            } else {
                appDelegate?.toast(why)
            }
            return
        }
        guard let d = AppEnvironment.dispatch else { NSSound.beep(); return }
        d(items.map(\.uid))
    }

    /// Copy instruction / full text for your own agent app (K6). The sheet is written and the items marked handed off
    /// when you copy — that click is the hand-off.
    func handOff(uids: [String], what: String, reply: @escaping ([String: Any]?) -> Void) {
        let items = model.items(uids: uids).filter { !$0.discarded && !$0.legacy }
        guard !items.isEmpty else { NSSound.beep(); return reply(nil) }
        Scripts.handoff(items.map(\.uid)) { [weak self] r in
            switch r {
            case .success(let o):
                let text = (what == "full" ? o["full"] : o["instruction"]) as? String ?? ""
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                appDelegate?.toast(T(what == "full" ? "main.handoff.copied_full" : "main.handoff.copied"), icon: .check)
                self?.wrote(items)
                reply(["id": o["id"] ?? "", "path": o["path"] ?? "", "text": text])
            case .failure(let f):
                self?.alert(T("main.handoff.failed"), f.localized)
                reply(nil)
            }
        }
    }

    @objc func mCopyInstruction() { handOff(uids: list.selectedItems.map(\.uid), what: "instruction") { _ in } }
    @objc func mCopyFull() { handOff(uids: list.selectedItems.map(\.uid), what: "full") { _ in } }
    /// AI fill-in (v0.7): items filed from notes without an agent get kind, steps, code refs — one agent run for all.
    @objc func mEnrich() {
        let items = list.selectedItems
        (NSApp.delegate as? App)?.enrich(items.map(\.uid), project: items.first.map(\.projectID).flatMap { $0 == "inbox" ? nil : $0 })
    }

    // MARK: context menus

    func contextMenu(for rows: IndexSet) -> NSMenu? {
        let items = list.selectedItems
        guard !items.isEmpty else { return nil }
        let m = NSMenu()
        m.autoenablesItems = true
        let n = items.count
        // what you can do from here (K3); handing off has its own section below
        let states = StateMenu.actions(for: items, canHandOff: false)
        if !states.isEmpty, Scripts.canWrite {
            m.addItem(menuHeader(T("state.menu")))
            for a in states { m.addItem(StateMenu.item(a, items: items, selector: #selector(mState(_:)), target: self)) }
            m.addItem(.separator())
        }
        // hand off
        _ = add(m, n > 1 ? TP("main.menu.start_session_n", n) : T("main.menu.start_session"), #selector(mHandOff), "apple.terminal", key: "\r")
        _ = add(m, T("main.cmd.copy_instruction"), #selector(mCopyInstruction), "doc.on.clipboard")
        _ = add(m, T("main.cmd.copy_full"), #selector(mCopyFull), "text.alignleft")
        _ = add(m, T("main.menu.enrich"), #selector(mEnrich), "sparkles")
        if n == 1, sessionJob(items[0]) != nil { _ = add(m, T("main.menu.open_session"), #selector(mOpenSession), "apple.terminal") }
        m.addItem(.separator())
        m.addItem(submenu(T("main.menu.move_to"), "folder", moveMenu()))
        m.addItem(submenu(T("main.menu.kind"), "tag", kindMenu(items)))
        if n == 1 { _ = add(m, T("main.menu.rename"), #selector(mRename), "pencil", key: "e", mods: []) }
        if n == 1, let it = items.first, it.sessionURL != nil {
            _ = add(m, T("main.menu.review_batch"), #selector(mReviewBatch), "rectangle.stack")
        }
        m.addItem(.separator())
        _ = add(m, T("action.reveal_in_finder"), #selector(mReveal), "folder", key: "r", mods: [.command, .shift])
        _ = add(m, T("action.copy_path"), #selector(mCopyPath), "doc.on.doc", key: "c", mods: [.command, .option])
        _ = add(m, T("main.menu.copy_link"), #selector(mCopyLink), "link")
        if n == 1, let e = Editor.preferred { _ = add(m, T("main.menu.open_in", e.name), #selector(mOpenInEditor), "chevron.left.forwardslash.chevron.right") }
        return m
    }

    @discardableResult
    func add(_ m: NSMenu, _ t: String, _ sel: Selector, _ sym: String? = nil, obj: Any? = nil, key: String = "",
             mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        i.representedObject = obj
        if let s = sym { i.image = Look.symbol(s, t) }
        m.addItem(i)
        return i
    }

    func submenu(_ t: String, _ sym: String, _ sub: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.image = Look.symbol(sym, t)
        i.submenu = sub
        return i
    }

    /// Projects (most recent first) and Unassigned — the selection's current one checked.
    /// The Move to Project menu at the selected row (the way out of "Move these items to a project first").
    func showMoveMenu() {
        let t = list.table
        let r = t.selectedRow >= 0 ? t.rect(ofRow: t.selectedRow) : t.visibleRect
        window?.makeKeyAndOrderFront(nil)
        moveMenu().popUp(positioning: nil, at: NSPoint(x: r.minX + 40, y: r.maxY), in: t)
    }

    func moveMenu() -> NSMenu {
        let m = NSMenu()
        let here = Set(list.selectedItems.map(\.projectID))
        for p in ProjectStore.shared.projects {
            let i = add(m, p.name, #selector(mMove(_:)), "folder", obj: p.id)
            i.state = here == [p.id] ? .on : .off
        }
        if !ProjectStore.shared.projects.isEmpty { m.addItem(.separator()) }
        let u = add(m, T("project.inbox"), #selector(mMove(_:)), "tray.2", obj: "inbox")
        u.state = here == ["inbox"] ? .on : .off
        m.addItem(.separator())
        _ = add(m, T("project.open_folder"), #selector(openFolder), "folder.badge.plus")
        return m
    }

    func kindMenu(_ items: [ItemRow]) -> NSMenu {
        let m = NSMenu()
        for (k, key) in KindStyle.builtIn.enumerated() {
            let i = add(m, Look.kindName(key), #selector(mSetKind(_:)), nil, obj: key, key: "\(k + 1)", mods: [])
            i.image = Look.kindImage(key)
            i.state = items.allSatisfy { $0.kind == key } ? .on : .off
        }
        return m
    }

    func sidebarMenu(_ s: Scope) -> NSMenu? {
        guard case .project(let id) = s, let p = model.project(id: id) else { return nil }
        let m = NSMenu()
        if !p.registered {
            _ = add(m, T("main.project.open_as"), #selector(mOpenUnregistered(_:)), "folder.badge.plus", obj: p.path)
            return m
        }
        if !FileManager.default.fileExists(atPath: p.path.path) {
            _ = add(m, T("main.missing.locate"), #selector(mLocate(_:)), "questionmark.folder", obj: id)
            m.addItem(.separator())
        }
        let cur = ProjectStore.shared.currentID == id
        let use = add(m, cur ? T("main.project.use_auto") : T("main.project.use"), #selector(mUseProject(_:)), "scope", obj: cur ? nil : id)
        use.toolTip = T("main.project.use.tip")
        _ = add(m, T("main.project.settings"), #selector(mProjectSettings(_:)), "slider.horizontal.3", obj: id)
        m.addItem(.separator())
        _ = add(m, T("action.reveal_in_finder"), #selector(mRevealURL(_:)), "folder", obj: p.path)
        if let e = Editor.preferred { _ = add(m, T("main.menu.open_in", e.name), #selector(mOpenURLInEditor(_:)), "chevron.left.forwardslash.chevron.right", obj: p.path) }
        _ = add(m, T("action.copy_path"), #selector(mCopyURL(_:)), "doc.on.doc", obj: p.path)
        m.addItem(.separator())
        _ = add(m, T("main.project.remove"), #selector(mRemoveProject(_:)), "minus.circle", obj: id)
        return m
    }

    @objc func mHandOff() { handOffSelection() }
    /// The one selected item's agent session, when there is one to open (the banner's Open Session, from the menus).
    func sessionJob(_ it: ItemRow) -> String? {
        guard let j = it.workJob, WorkSession.of(state: it.state, to: it.workTo, job: j, lookup: JobStore.shared.job)?.canOpen == true
        else { return nil }
        return j
    }
    @objc func mOpenSession() { list.selectedItems.first.flatMap(sessionJob).map(revealJob) }
    @objc func mMove(_ i: NSMenuItem) { (i.representedObject as? String).map { move(uids: list.selectedItems.map(\.uid), to: $0) } }
    @objc func mSetKind(_ i: NSMenuItem) { (i.representedObject as? String).map(setKind) }
    @objc func mRename() { renameSelection() }
    @objc func mReviewBatch() {
        guard let s = list.selectedItems.first?.sessionURL else { return }
        shownJob = nil
        detail.show(session: s)
    }
    @objc func mQuickLook() { list.toggleQuickLook() }
    @objc func mCopyPath() { copyPaths() }
    @objc func mCopyLink() {
        let links = list.selectedItems.map { "blurt://item/\($0.uid)" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
    }
    @objc func mReveal() {
        let urls = list.selectedItems.map { it -> URL in
            if let f = it.primaryFrame, FileManager.default.fileExists(atPath: f) { return URL(fileURLWithPath: f) }
            return it.fileURL
        }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
    @objc func mOpenInEditor() { list.selectedItems.first.map { Editor.open(file: $0.fileURL, line: nil) } }
    @objc func mRevealURL(_ i: NSMenuItem) { (i.representedObject as? URL).map { NSWorkspace.shared.activateFileViewerSelecting([$0]) } }
    @objc func mCopyURL(_ i: NSMenuItem) {
        guard let u = i.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u.path, forType: .string)
    }
    @objc func mOpenURLInEditor(_ i: NSMenuItem) { (i.representedObject as? URL).map { Editor.open(folder: $0) } }
    @objc func mOpenUnregistered(_ i: NSMenuItem) { (i.representedObject as? URL).map { openFolders([$0]) } }
    @objc func mUseProject(_ i: NSMenuItem) { useProject(i.representedObject as? String) }
    @objc func mProjectSettings(_ i: NSMenuItem) { (i.representedObject as? String).map(projectSettings) }
    @objc func mLocate(_ i: NSMenuItem) { (i.representedObject as? String).map(locateFolder) }
    @objc func mRemoveProject(_ i: NSMenuItem) { (i.representedObject as? String).map(removeProject) }

    /// This item is being validated because its own unmodified key was pressed (key-equivalent matching), not because
    /// a menu opened.
    func isKeyMatch(_ item: NSMenuItem) -> Bool {
        guard item.keyEquivalentModifierMask.isEmpty, !item.keyEquivalent.isEmpty, let e = NSApp.currentEvent, e.type == .keyDown,
              e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if item.keyEquivalent == "\u{8}" { return e.keyCode == 51 || e.keyCode == 117 }
        return e.charactersIgnoringModifiers?.lowercased() == item.keyEquivalent
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let items = list.selectedItems
        if item.action == #selector(mState(_:)) || item.action == #selector(mStateMenu), item.menu?.supermenu != nil, isKeyMatch(item) {
            return false        // a menu-bar item's single key: the list's keyDown handles it there (MainMenu.displayKey)
        }
        switch item.action {
        case #selector(mHandOff):
            // disabled with the reason as its tooltip, never an alert after the click (micro 23)
            let why = dispatchBlocker(items)
            item.toolTip = why
            return Scripts.canWrite && why == nil && items.contains { !$0.discarded && !$0.legacy }
        case #selector(mCopyInstruction), #selector(mCopyFull):
            return Scripts.canWrite && items.contains { !$0.discarded && !$0.legacy }
        case #selector(mState(_:)):
            guard Scripts.canWrite, let a = item.representedObject as? String else { return false }
            if a == "back" {
                // the menu bar's one "back" entry says what R does for the selection
                let back = items.filter { !$0.legacy }.compactMap { Lifecycle.backAction($0.state) }
                item.title = StateMenu.title(Set(back).count == 1 ? back[0] : "send_back")
                return !back.isEmpty
            }
            return !StateMenu.valid(a, items).isEmpty
        case #selector(mStateMenu):
            return Scripts.canWrite && !StateMenu.actions(for: items, canHandOff: true).isEmpty
        case #selector(mMove(_:)):
            guard let p = item.representedObject as? String else { return false }
            return Scripts.canWrite && items.contains { $0.projectID != p && !$0.legacy }
        case #selector(mOpenSession):
            return items.count == 1 && sessionJob(items[0]) != nil
        case #selector(mRename), #selector(mSetKind(_:)):
            return Scripts.canWrite && items.contains { !$0.legacy }
        case #selector(mReveal), #selector(mCopyPath), #selector(mCopyLink), #selector(mQuickLook), #selector(mOpenInEditor):
            return !items.isEmpty
        default: return true
        }
    }

    // MARK: WebHostActions

    func reveal(file: URL) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    func quickLook(files: [URL]) { list.toggleQuickLook(files) }
    func webWrote() { detail.currentItem.map { Scripts.indexUpdate([$0.fileURL]) } }
    func revealJob(_ id: String) { reveal(job: id) }

    func openCode(_ ref: String, item: ItemRow?) {
        let repo = item.flatMap { ProjectStore.shared.project(id: $0.projectID) }.map(\.path)
        Editor.open(ref: ref, repo: repo, session: item?.sessionURL)
    }

    func jobAction(_ action: String, job: Job) {
        switch action {
        case "log": NSWorkspace.shared.open(JobFiles.log(job.id))
        case "retry":
            // the detail follows the new run (or the one already at it), never the failed one's Try Again
            var new: String?
            if let s = job.session { new = AppEnvironment.process?(s, job.captures.isEmpty ? nil : job.captures, job.project == "inbox" ? nil : job.project) ?? nil }
            else if !job.items.isEmpty { new = (NSApp.delegate as? App)?.enrich(job.items, project: job.project == "inbox" ? nil : job.project) }   // AI fill-in
            if let n = new {
                JobStore.shared.rescan()
                selectJob(n)
            }
        case "dismiss":
            // a failure put away: it leaves the jobs section; the recording keeps its files
            JobFiles.rewrite(job.id) { $0["dismissed"] = true }
            JobStore.shared.rescan()
            if shownJob == job.id { shownJob = nil; list.jobs.selected = nil; listSelectionChanged() }
        case "items":
            if let first = job.items.first { reveal(uid: first) }
        // a failure is said, never dropped (the Sessions pane says the same for the same calls)
        case "external":
            Task { @MainActor in
                do { try await AgentSessions.shared.openExternal(job: job.id, terminal: nil) }
                catch { appDelegate?.toast(sessionsErrorText(error)) }
            }
        case "stop":
            Task { @MainActor in
                do { try await AgentSessions.shared.stop(job: job.id, kill: false) }
                catch { appDelegate?.toast(sessionsErrorText(error)) }
            }
        default: break
        }
    }

    // MARK: toolbar actions

    @objc func record() { appDelegate?.startRecording(useLast: false) }
    @objc func snap() { snapper.hotkey() }
    @objc func showPalette() { palette.toggle() }

    // MARK: keys that work wherever the focus is

    func handleKeyEquivalent(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == .command {
            switch ch {
            case "k": palette.toggle(); return true
            case "f": focusSearch(); return true
            case "o": openFolder(); return true
            case "1": go(.inbox); return true
            case "2": go(.inProgress); return true
            case "3": go(.unassigned); return true
            case "4": go(.all); return true
            default: break
            }
            if let n = Int(ch), n >= 5, n <= 9, n - 5 < model.projects.count { go(.project(model.projects[n - 5].id)); return true }
            if e.keyCode == 36 || e.keyCode == 76, window?.firstResponder === list.table { handOffSelection(); return true }
        }
        if mods == [.command, .shift], ch == "r" { mReveal(); return true }
        if mods == [.command, .shift], ch == "c", window?.firstResponder === list.table { mCopyInstruction(); return true }
        if mods == [.command, .option], ch == "c" { copyPaths(); return true }
        return false
    }

    // MARK: toolbar

    static let recordID = NSToolbarItem.Identifier("record"), snapID = NSToolbarItem.Identifier("snap")
    static let handOffID = NSToolbarItem.Identifier("handoff"), moveID = NSToolbarItem.Identifier("move")
    static let searchID = NSToolbarItem.Identifier("search")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.toolbarItems(dictation: false) }

    /// The items' toolbar: Record, Snap, Move, Hand Off and search. The Dictation page has its own: search only (its
    /// header links to Dictation Settings) — none of the items' actions apply to dictations.
    static func toolbarItems(dictation: Bool) -> [NSToolbarItem.Identifier] {
        dictation ? [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, searchID]
                  : [.toggleSidebar, .sidebarTrackingSeparator, recordID, snapID, .flexibleSpace, moveID, handOffID, searchID]
    }

    /// Swap the toolbar's items for the page's (the search item and the sidebar button stay as they are).
    func syncToolbar(dictation: Bool) {
        guard let tb = window?.toolbar else { return }
        let want = Self.toolbarItems(dictation: dictation)
        for (n, it) in tb.items.enumerated().reversed() where !want.contains(it.itemIdentifier) { tb.removeItem(at: n) }
        for (n, id) in want.enumerated() where n >= tb.items.count || tb.items[n].itemIdentifier != id {
            tb.insertItem(withItemIdentifier: id, at: n)
        }
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
        func menuItem(_ label: String, _ sym: String, tip: String, tag: Int) -> NSToolbarItem {
            let i = NSMenuToolbarItem(itemIdentifier: id)
            i.label = label
            i.paletteLabel = label
            i.toolTip = tip
            i.image = Look.symbol(sym, label, size: 15)
            let m = NSMenu()
            m.delegate = self
            m.identifier = .init("toolbar-\(tag)")
            i.menu = m
            i.showsIndicator = true
            return i
        }
        switch id {
        case Self.recordID:
            return button(T("main.action.record"), "record.circle", #selector(record), tip: T("main.toolbar.record.tip", hk(.toggleRecord)))
        case Self.snapID:
            return button(T("main.action.snap"), "camera.viewfinder", #selector(snap), tip: T("main.toolbar.snap.tip", hk(.snap)))
        case Self.handOffID:
            return menuItem(T("main.toolbar.handoff"), "paperplane", tip: T("main.toolbar.handoff.tip"), tag: 1)
        case Self.moveID:
            return menuItem(T("main.toolbar.move"), "folder", tip: T("main.toolbar.move.tip"), tag: 2)
        case Self.searchID:
            let s = NSSearchToolbarItem(itemIdentifier: id)
            s.searchField.placeholderString = T("main.search.placeholder")
            s.searchField.delegate = self
            s.searchField.sendsSearchStringImmediately = true
            s.searchField.sendsWholeSearchString = false
            s.searchField.setAccessibilityLabel(T("main.search.label"))
            s.preferredWidthForSearchField = 240
            searchItem = s
            return s
        default: return nil
        }
    }

    /// The two toolbar menus, built when they open (the selection decides what is enabled).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        switch menu.identifier?.rawValue {
        case "toolbar-1":
            let n = list.selectedItems.count
            _ = add(menu, n > 1 ? TP("main.menu.start_session_n", n) : T("main.menu.start_session"), #selector(mHandOff), "apple.terminal", key: "\r")
            menu.addItem(.separator())
            menu.addItem(menuHeader(T("main.toolbar.handoff.own")))
            _ = add(menu, T("main.cmd.copy_instruction"), #selector(mCopyInstruction), "doc.on.clipboard", key: "c", mods: [.command, .shift])
            _ = add(menu, T("main.cmd.copy_full"), #selector(mCopyFull), "text.alignleft")
        case "toolbar-2":
            for it in moveMenu().items { it.menu?.removeItem(it); menu.addItem(it) }
        default: break
        }
    }

    func controlTextDidChange(_ n: Notification) {
        guard let f = n.object as? NSSearchField, f === searchItem?.searchField else { return }
        if model.scope == .dictation { return setDictationQuery(f.stringValue) }
        model.text = f.stringValue
        model.reload()
        if list.table.selectedRow < 0, model.rowCount > 0 { list.table.selectRowIndexes([0], byExtendingSelection: false) }
        list.scrollToStart()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === searchItem?.searchField else { return false }
        if model.scope == .dictation {
            if sel == #selector(NSResponder.moveDown(_:)) || sel == #selector(NSResponder.insertNewline(_:))
                || (sel == #selector(NSResponder.cancelOperation(_:)) && control.stringValue.isEmpty) {
                dictation.model.selectFirstIfNone()
                focusList()
                return true
            }
            return false
        }
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

    // MARK: index watcher (FSEvents → index.py update)

    func updateWatcher() {
        let stores = ProjectStore.shared.projects.map(\.store.path) + [ProjectStore.shared.inbox.store.path]
        let legacy = [BlurtPaths.workspace.appendingPathComponent("recordings").path]
        let all = (stores + legacy).sorted()
        guard all != watchedRoots else { return }
        watchedRoots = all
        watcher?.stop()
        let w = IndexWatcher(stores: stores.map { URL(fileURLWithPath: $0) }, legacyRoots: legacy.map { URL(fileURLWithPath: $0) })
        w.onChange = { paths in Scripts.indexUpdate(paths) }
        w.start()
        watcher = w
    }

    // MARK: window state

    struct State: Codable {
        var frame: String?, sidebar: Double?, detail: Double?, sidebarCollapsed: Bool?
        var scope: String?, kinds: [String]?, state: String?, sort: String?, ascending: Bool?
        var selected: [String]?, open: Bool?
    }
    static var stateURL: URL { BlurtPaths.home.appendingPathComponent("ui/main-window.json") }

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
        if case .session = model.scope {} else { s.scope = model.scope.key }
        s.kinds = model.kinds.sorted(); s.state = model.state
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
        if case .project(let p) = model.scope, ProjectStore.shared.project(id: p) == nil { model.scope = .inbox }
        model.kinds = Set(s?.kinds ?? [])
        model.state = s?.state.flatMap { $0 == "inbox" || Lifecycle.isState($0) ? $0 : nil }
        model.text = ""          // like Finder and Mail: a new window starts without the last search
        model.sort = s.flatMap { ["status", "work"].contains($0.sort) ? "state" : $0.sort } ?? "updated"
        model.ascending = s?.ascending ?? false
        searchItem?.searchField.stringValue = model.text
        list.table.sortDescriptors = [NSSortDescriptor(key: model.sort, ascending: model.ascending)]
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
                sv.setPosition(min(sv.bounds.width - 460, side + 560), ofDividerAt: 1)
            }
        }
    }

    func windowDidResize(_ notification: Notification) { scheduleSave() }
    func windowDidMove(_ notification: Notification) { scheduleSave() }
    func windowDidBecomeKey(_ notification: Notification) { NSApp.mainMenu = MainMenu.build() }

    func windowWillClose(_ notification: Notification) {
        saveState(open: false)
        page?.didHide()
        palette.close()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        if let w = window, w.isVisible { a.beginSheetModal(for: w) } else { a.runModal() }
    }
}

/// One column of the split view whose content can be swapped — the items or the Dictation page — without touching
/// the split view itself (its divider positions and saved widths stay as they are).
final class ColumnController: NSViewController {
    private(set) var current: NSViewController

    init(_ vc: NSViewController) {
        current = vc
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        embed(current)
    }

    func show(_ vc: NSViewController) {
        guard vc !== current else { return }
        current.view.removeFromSuperview()
        current.removeFromParent()
        current = vc
        if isViewLoaded { embed(vc) }
    }

    private func embed(_ vc: NSViewController) {
        addChild(vc)
        let v = vc.view
        v.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(v)
        NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: view.topAnchor), v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                                     v.leadingAnchor.constraint(equalTo: view.leadingAnchor), v.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
    }
}
