// Blurt's main window: sidebar (places + projects) | items | detail in an NSSplitViewController, a unified toolbar
// (the place's title and counts, Record and Snap, Filter, search; on the Dictation page the title and search only —
// moving and handing off belong to the selection: the detail, the Item menu, the context menu, M / ⌘↩, ⌘K), a
// command palette, context
// menus, Quick Look, a blank detail while there are no items at all (the list's first-run state speaks), window state
// restored from $BLURT_HOME/ui/main-window.json (not UserDefaults: test builds share the bundle id with the user's
// real app and must not disturb its state).
//
// Reads come from index.db (MainModel / IndexReader v3), projects.json (ProjectStore) and $BLURT_HOME/jobs
// (JobStore). Every write goes through the CLIs (Scripts): items.py user-ops / state / move, projects.py,
// handoff.py, sessions.py (AppEnvironment.dispatch, P3); Export Hand-off Bundle… (Item menu, context menu, the Hand Off
// ⌘K) runs export_local.py bundle into a .zip picked in a Save sheet ("Packing…" on the island, the action
// off, until it is done). The index follows (items.py updates it in-process, FSEvents
// + `index.py update` catch everything else) and the model reloads when index.db's data_version moves. The writes run
// one after another (writes: SerialWork), and each undoable one is on the window's NSUndoManager from the moment it is
// asked for, so ⌘Z always takes back the latest step, after it has been written.
// This window never opens by itself: no review pops up when processing finishes (K4 notification rules).
import AppKit
import BlurtCore
import Combine
import Quartz
import UniformTypeIdentifiers

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
    /// this window's writes (items.py, projects.py), in the order they were asked for — an undo after its action
    let writes = SerialWork()
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
    /// ⌘Q's one-time "still in the menu bar" toast was shown (saved with the window state).
    var quitHintShown = false
    /// Export Hand-off Bundle…'s Save panel while it is up (tests read its suggested name, then cancel it).
    var bundlePanel: NSSavePanel?
    /// A hand-off bundle is being packed: the action is off until it is done (one at a time).
    private(set) var bundling = false

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
        // the place's name is ours: the list's heading (ListHeading), which keeps its weight in a window that isn't
        // key — the title still names the window (Window menu, Mission Control); the Dictation page's is a bar item
        w.titleVisibility = .hidden
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
        list.bar.makeMenu = { [weak self] in self?.filterMenu() }
        detail.actions = self
        sidebar.actions = self
        model.onReload = { [weak self] in
            guard let self = self else { return }
            self.syncPage()             // every way to a place (go, reveal, restore) reloads: the columns follow the scope
            self.list.reload()
            // the same item still selected, but its row changed under it (a state, a move, a renamed folder)
            if self.shownJob == nil, self.list.selectedIDs.count == 1, let it = self.list.selectedItems.first {
                self.detail.refresh(item: it, projects: self.model.projects)
            } else if self.shownJob == nil, self.list.selectedIDs.count > 1, self.detail.showsSelection {
                self.showSelectionSummary()     // a state or a move changed what the buttons can do
            } else if self.shownJob == nil, self.list.selectedIDs.isEmpty, self.detail.showsQuietNothing != self.quietDetail,
                      self.detail.showsNothing {
                self.listSelectionChanged()     // the first item arrived (or the last one went): "Nothing selected" or blank
            }
            self.updateTitle()
            self.fitDetailToPlace()
            self.scheduleSave()
        }
        model.onSidebar = { [weak self] in self?.sidebar.rebuild(); self?.updateWatcher() }
        model.onJobs = { [weak self] in self?.list.reloadJobs() }
        model.onIndexState = { [weak self] in
            guard let self = self else { return }
            self.list.reload()
            self.updateTitle()
            self.syncIndexChrome()
            self.fitDetailToPlace()
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

    /// Search follows the index: off (with a placeholder that says when it comes) while nothing is listed yet. A
    /// window that finds no index starts reading one by itself — there is nothing to ask.
    func syncIndexChrome() {
        guard let f = searchItem?.searchField, model.scope != .dictation else { return }
        let ready = !model.nothingListed
        if f.isEnabled != ready {
            if !ready, window?.firstResponder === f.currentEditor() { window?.makeFirstResponder(list.table) }
            f.isEnabled = ready
        }
        f.placeholderString = ready ? T("main.search.placeholder") : T("main.search.placeholder_wait")
        if window?.isVisible == true { model.startFirstScan() }
    }

    func show() {
        if !restored { restoreState(); restored = true } else { model.reloadAll() }
        defer { syncIndexChrome() }
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
            appDelegate?.toast(T("app.url.no_item"))
            return
        }
        model.text = ""
        searchItem?.searchField.stringValue = ""
        // the place on show if it lists the item (with the filters that show it), else its project, else All Items
        func look(in s: Scope) -> Bool {
            model.scope = s
            model.kinds = []
            model.state = row.discarded ? "discarded" : nil
            model.reload()
            return model.row(of: uid) != nil
        }
        _ = look(in: model.scope) || look(in: row.projectID == "inbox" ? .unassigned : .project(row.projectID)) || look(in: .all)
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
        focusBanner(nil)
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
        defer {
            titleView.set(title: window?.title ?? "", subtitle: window?.subtitle ?? "")
            list.heading.set(title: window?.title ?? "", counts: window?.subtitle ?? "")
            syncFilterItem()
        }
        let q = model.text.trimmingCharacters(in: .whitespaces)
        // a search is a mode of its own: the heading says what it looks for, the counts how much of the place it found
        window?.title = q.isEmpty || model.scope == .dictation ? model.scopeTitle : T("main.search.title", q)
        if model.scope == .dictation {
            if let p = page, p.model.tab == .lab {
                window?.subtitle = T("dictation.lab.subtitle", T("dictation.lab.cases", p.lab.cases.count))
                return
            }
            let n = page?.model.entries.count ?? 0
            window?.subtitle = n > 0 ? TP("main.dictation.count", n) : ""
            return
        }
        window?.subtitle = listSubtitle
    }

    /// What the heading says beside the place's name: nothing while the empty state speaks; "Updating…" over a rescan;
    /// "12 of 52" (and where) while a search or a filter narrows the place; the Inbox's "3 new · 2 to verify"; a
    /// project's count, and that it is the current one (where new captures go) — the one mark of it everywhere.
    var listSubtitle: String {
        // nothing listed, or no rows: the empty state speaks
        if model.indexState != .ready || model.rowCount == 0 { return "" }
        if model.rescanning { return T("main.updating") }
        let searching = !model.text.trimmingCharacters(in: .whitespaces).isEmpty
        if model.filtered {
            let of = T("main.items.of", Loc.number(model.rowCount), Loc.number(model.placeTotal))
            return searching ? T("main.items.of_in", of, model.scopeTitle) : of
        }
        if model.scope == .inbox { return needsYou }
        if case .project(let p) = model.scope, ProjectStore.shared.currentID == p {
            return T("main.project.current_count", TP("main.items.count", model.rowCount))
        }
        return TP("main.items.count", model.rowCount)
    }

    /// An empty place (no rows, no search or filter emptied it) or nothing listed yet: the detail column steps aside, so
    /// the empty state is the window's one focus; it comes back at its width with the first row (or a job shown). A
    /// detail the user hides or shows (⌥⌘I) is theirs.
    private(set) var foldedForEmpty = false
    func forgetFold() { foldedForEmpty = false }
    private var detailWidthBeforeFold = 0.0
    func fitDetailToPlace() {
        let items = split.splitViewItems
        guard items.count == 3 else { return }
        let d = items[2]
        let fold = model.scope != .dictation && shownJob == nil && (model.placeIsEmpty || model.nothingListed)
        if fold, !d.isCollapsed {
            detailWidthBeforeFold = Double(d.viewController.view.frame.width)
            foldedForEmpty = true
            d.isCollapsed = true
        } else if !fold, foldedForEmpty {
            foldedForEmpty = false
            d.isCollapsed = false
        }
    }

    /// The detail stays blank (no placeholder pointing at rows that aren't there) while the list has no rows or there
    /// is nothing listed at all: the list's empty state is the window's one focus.
    var quietDetail: Bool { model.isEmptyWorld || model.nothingListed || model.rowCount == 0 }

    /// The Dictation page's title in the toolbar (the item places have the list's heading instead).
    let titleView = ToolbarTitle()

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
        if !items.isEmpty { shownJob = nil; list.jobs.selected = nil; if focusedBanner != nil { focusBanner(nil) } }
        if shownJob != nil { return }
        if items.count == 1, let it = items.first {
            detail.show(item: it, projects: model.projects)
        } else if items.count > 1 {
            showSelectionSummary()
        } else {
            detail.showNothing(quiet: quietDetail)
        }
        scheduleSave()
    }

    // MARK: several selected (SelectionView)

    func showSelectionSummary() {
        let items = list.selectedItems
        guard items.count > 1 else { return }
        detail.showSelection(items, plan: selectionPlan(items))
    }

    /// The agent the hand-off panel will start with, when it is already decided (the last one used, the project's,
    /// the global default) — the primary names it; nil: "Hand Off…" and the panel picks.
    func handOffAgentName(_ items: [ItemRow]) -> String? {
        let projects = Set(items.map(\.projectID))
        let project = projects.count == 1 ? projects.first.flatMap { ProjectStore.shared.project(id: $0) }?.defaultAgent : nil
        let ids = [Config.shared["sessions.agent"] as? String, project, Config.shared["record.default_agent"] as? String]
        return ids.compactMap { $0 }.lazy.compactMap { AgentHub.shared.def($0)?.name }.first
    }

    /// What the selection summary offers. Inline: Hand Off…, Move to Project… and the one state action that moves the
    /// batch on (Keep for new items, Mark as Done for those in work, Reopen / Restore for closed ones); everything else
    /// in ⋯ — the same entries the state menu and the Item menu have. The primary is the one that can go: Hand Off when
    /// HandOffCheck lets it, else the way out of what blocks it (Move to Project… for Unassigned or mixed projects,
    /// Reopen, Restore), with the reason on one line under the buttons.
    func selectionPlan(_ items: [ItemRow]) -> SelectionPlan {
        var p = SelectionPlan()
        let writable = Scripts.canWrite && items.contains { !$0.readOnly }
        let block = dispatchBlock(items)
        let n = items.count
        let agent = handOffAgentName(items)
        let handOff = SelectionPlan.Action(
            id: "hand_off", title: agent.map { T("main.selection.hand_off_to", $0) } ?? T("main.selection.hand_off"),
            tip: block.map(Self.blockText) ?? TP("main.selection.hand_off.tip", n),
            enabled: block == nil && writable && AppEnvironment.dispatch != nil)
        let move = SelectionPlan.Action(id: "move", title: T("main.selection.move"), tip: TP("main.selection.move.tip", n),
                                        enabled: writable)
        let states = writable ? StateMenu.actions(for: items, canHandOff: false) : []
        var way: String?
        switch block {
        case .finished?: way = states.contains("reopen") ? "reopen" : nil
        case .discarded?: way = states.contains("restore") ? "restore" : nil
        default: break
        }
        let state = way ?? states.first { $0 != "discard" }
        p.actions = [handOff, move]
        if let a = state {
            let valid = StateMenu.valid(a, items).count
            let title = StateMenu.title(a) + (valid < n ? " (\(Loc.number(valid)))" : "")
            let (k, mods) = StateMenu.key(a)
            let key = k.isEmpty ? "" : " (\(mods.contains(.command) ? "⌘" : "")\(k == "\u{8}" ? "⌫" : k.uppercased()))"
            p.actions.append(.init(id: a, title: title, tip: StateMenu.hint(a, items) + key))
        }
        switch block {
        case nil: p.primary = handOff.enabled ? "hand_off" : nil
        case .needsProject?, .mixedProjects?: p.primary = writable ? "move" : nil
        default: p.primary = way
        }
        if let b = block, writable {
            // under the buttons the line says why Hand Off is off and what the primary does about it
            switch b {
            case .mixedProjects: p.blocked = T("main.selection.blocked.mixed")
            case .needsProject: p.blocked = T("main.selection.blocked.needs_project")
            case .finished: p.blocked = T("main.selection.blocked.finished")     // about the batch, not "this item"
            default: p.blocked = Self.blockText(b)
            }
        }
        // the primary leads the row
        if let pr = p.primary, let i = p.actions.firstIndex(where: { $0.id == pr }) { p.actions.insert(p.actions.remove(at: i), at: 0) }
        p.more = selectionMoreMenu(items, inline: Set(p.actions.map(\.id)), states: states)
        return p
    }

    /// ⋯: the state actions not inline (StateMenu's entries, "(n)" where they apply to some), then the Item menu's
    /// actions without the two already inline (Hand Off, Move to Project).
    func selectionMoreMenu(_ items: [ItemRow], inline: Set<String>, states: [String]) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = true
        let rest = states.filter { !inline.contains($0) }
        for a in rest {
            if a == "discard", !m.items.isEmpty { m.addItem(.separator()) }
            m.addItem(StateMenu.item(a, items: items, selector: #selector(mState(_:)), target: self))
        }
        if !rest.isEmpty { m.addItem(.separator()) }
        itemActions(into: m, items: items, inSelection: true)
        return m
    }

    func selectionAction(_ id: String, from v: NSView) {
        let items = list.selectedItems
        switch id {
        case "hand_off": handOffSelection()
        case "move": pickProject(from: v)
        default: apply(id, to: items)
        }
    }

    func deselect(uid: String) {
        guard let row = model.row(of: uid) else { return }
        list.table.deselectRow(row)
    }

    /// The rows above the list from the keyboard (micro 15): the "Unfiled captures" and "Recently dragged out"
    /// banners, then the running jobs. ↑ on the first item goes to the last of them, ↑ / ↓ walk them (the detail
    /// shows a job, as a click does), ↓ from the last one is the first item again; ↩ on a banner opens what it opens.
    func stepJobs(_ d: Int, fromRow row: Int) -> Bool {
        var tops: [String] = []
        if !list.captures.isHidden { tops.append("banner:captures") }
        if !list.taken.isHidden { tops.append("banner:taken") }
        tops += model.jobs.map(\.id)
        switch TopRows.step(tops, current: focusedBanner.map { "banner:" + $0 } ?? shownJob, by: d, fromRow: row, hasItems: model.rowCount > 0) {
        case .pass: return false
        case .beep: NSSound.beep()
        case .firstItem:
            focusBanner(nil)
            list.table.selectRowIndexes([0], byExtendingSelection: false)
            list.table.scrollRowToVisible(0)
        case .row(let id) where id.hasPrefix("banner:"):
            focusBanner(String(id.dropFirst("banner:".count)))
        case .row(let id):
            focusBanner(nil)
            selectJob(id)
        }
        return true
    }

    /// The banner the keyboard cursor is on ("captures" | "taken"), drawn selected like a job row.
    private(set) var focusedBanner: String?
    func focusBanner(_ name: String?) {
        if name != nil {
            list.table.deselectAll(nil)
            shownJob = nil
            list.jobs.selected = nil
        }
        focusedBanner = name
        list.captures.selected = name == "captures"
        list.taken.selected = name == "taken"
    }

    func selectJob(_ id: String) {
        guard let j = JobStore.shared.job(id) else { return }
        if focusedBanner != nil { focusBanner(nil) }
        list.table.deselectAll(nil)
        shownJob = id
        list.jobs.selected = id
        detail.show(job: j, projectName: j.project.flatMap { ProjectStore.shared.project(id: $0) }?.name)
        fitDetailToPlace()          // a job shown over an empty place brings the detail back
    }

    /// ↩: into the detail, the caret at the end of its title (E renames in the row instead).
    func openSelection() {
        if let b = focusedBanner { (b == "captures" ? list.captures.onClick : list.taken.onClick)?(); return }
        // ↩ on a list with no rows: the empty state's primary (Open Folder…, Record, Locate Folder…)
        if model.rowCount == 0, list.empty.pressPrimary() { return }
        guard !detail.web.isHidden else { return }
        window?.makeFirstResponder(detail.web)
        detail.web.evaluateJavaScript("window.blurtReview && window.blurtReview.focusTitle && window.blurtReview.focusTitle()")
    }

    func handOffSelection() {
        let uids = list.selectedItems.map(\.uid)
        guard !uids.isEmpty else { NSSound.beep(); return }
        dispatch(uids: uids)
    }

    func renameSelection() {
        // in place, in the row (micro 1): no sheet; Return / Tab / a click away commits, Esc reverts
        let sel = list.selectedItems
        guard sel.count == 1, let it = sel.first, !it.readOnly, Scripts.canWrite else { NSSound.beep(); return }
        window?.makeFirstResponder(list.table)
        if !list.beginRename(commit: { [weak self] it, t in self?.edit([it], ["title": t]) }) { NSSound.beep() }
    }

    func setKind(_ kind: String) { edit(list.selectedItems.filter { $0.kind != kind }, ["kind": kind]) }

    // MARK: state (K3)

    /// An action on the items it is valid for (the others are left alone). Hand off opens the dispatch panel; the rest
    /// go to items.py state.
    func apply(_ action: String, to items: [ItemRow]) {
        let ok = StateMenu.valid(action, items)
        guard !ok.isEmpty else { NSSound.beep(); return }
        if action == "hand_off" { return dispatch(uids: ok.map(\.uid)) }
        guard Scripts.canWrite else { return alert(T("main.error.cant_edit"), T("main.error.no_scripts")) }
        // shown at once (the row takes its new state, or leaves a place that no longer lists it); the index agrees a
        // moment later, or puts it back if the write failed
        if action != "restore" {
            model.optimistic(states: Dictionary(ok.compactMap { it in Lifecycle.target(of: action, state: it.state).map { (it.uid, $0) } },
                                                uniquingKeysWith: { a, _ in a }))
        }
        apply(action, uids: ok.map(\.uid), redoing: false)
    }

    /// The write itself. Its ⌘Z is on the window's stack at once — in the key press or click that asked for it (or
    /// inside the ⇧⌘Z that redoes it) — so a quick ⌘Z takes back this step, never an older one. The script runs after
    /// whatever this window is still writing (writes), against the items as they are by then; a failure takes the
    /// step off again. `redoing`: ⇧⌘Z (no toast).
    private func apply(_ action: String, uids: [String], redoing: Bool) {
        let step = UndoStep<[(String, String)]>()
        register(StateMenu.title(action), step) { c, s in c.undoState(action, uids: uids, s) }
        writes.run { [weak self] in
            guard let self = self else { return }
            let items = StateMenu.valid(action, self.model.items(uids: uids))
            guard !items.isEmpty else { return self.drop(step) }
            step.value = items.map { ($0.uid, $0.state) }
            switch await Scripts.awaiting({ Scripts.state(items.map(\.uid), action: action, done: $0) }) {
            case .success:
                self.wrote(items)
                // taken back from a session that is over: it leaves no worktree, branch or window behind
                if action == "take_back" { SessionRecovery.cleanUp(jobs: items.compactMap(\.workJob)) }
                guard !redoing else { return }
                // where it went, and the way back — the row may just have left the list (like the review page's toast)
                let to = StateMenu.target(action, items)
                let what = items.count == 1 ? items[0].itemID : TP("main.items.count", items.count)
                appDelegate?.toast(T("main.state.toast", Look.stateName(to), what),
                                   icon: ["todo", "done"].contains(to) ? .check : nil, undo: self.undoToast(StateMenu.title(action)))
            case .failure(let f):
                self.drop(step)
                self.model.reload()            // the optimistic state goes: the index has the truth
                self.alert(T("main.error.save_title"), f.localized)
            }
        }
    }

    /// Why a key does nothing for the selection: a discarded item has to be restored first; otherwise the state's
    /// own menu (S) has what can be done from there.
    func notHere(_ key: String, _ items: [ItemRow]) -> String? {
        if !items.isEmpty, items.allSatisfy(\.unreadable) { return T("main.unreadable.fix_first") }
        switch Lifecycle.refusal(forKey: key, states: items.filter { !$0.readOnly }.map(\.state)) {
        case .discarded: return T("main.state.restore_first")
        case .state(let s): return T("main.state.not_here", s.map(Look.stateName) ?? T("main.state.these"))
        case nil: return nil
        }
    }

    /// ⌘Z after a state action (A D R W X ⌫, the ring, the menus): each item back to the state it had, through
    /// items.py's --undo (the user taking back their own change); ⇧⌘Z does the action again. Runs after the action's
    /// own write (step holds what it changed).
    private func undoState(_ action: String, uids: [String], _ step: UndoStep<[(String, String)]>) {
        let redo = UndoStep<Void>()
        register(StateMenu.title(action), redo) { c, _ in c.apply(action, uids: uids, redoing: true) }
        writes.run { [weak self] in
            guard let self = self, let before = step.value else { return }      // the action never ran: nothing to take back
            for (state, group) in Dictionary(grouping: before, by: \.1) {
                let ids = group.map(\.0)
                switch await Scripts.awaiting({ Scripts.undoState(ids, to: state, done: $0) }) {
                case .success:
                    self.wrote(self.model.items(uids: ids))
                    self.model.reloadAll()                  // back in this list (a discard undone): selected again
                    if ids.contains(where: { self.model.row(of: $0) != nil }) { self.list.reload(keep: ids) }
                case .failure(let f):
                    self.drop(redo)
                    self.alert(T("main.error.save_title"), f.localized)
                }
            }
        }
    }

    /// One step on the window's undo stack, registered now; `step` carries what its write found (filled in by the
    /// write, read by the undo — which runs after it, in writes).
    /// NSUndoManager doesn't retain its targets: the handler holds the step, so it lives exactly as long as the step
    /// is on the stack.
    private func register<V>(_ name: String, _ step: UndoStep<V>, _ undo: @escaping (MainWindowController, UndoStep<V>) -> Void) {
        guard let um = window?.undoManager else { return }
        um.registerUndo(withTarget: step) { [weak self] _ in if let c = self { undo(c, step) } }
        um.setActionName(name)
    }
    /// A step whose write failed (or found nothing to do) leaves the stack: ⌘Z goes to the one before it.
    private func drop(_ step: AnyObject) { window?.undoManager?.removeAllActions(withTarget: step) }

    func applyState(_ action: String, uids: [String]) { apply(action, to: model.items(uids: uids)) }

    /// A list key (A, D, R, W, X / ⌫) on the selection: each item gets what the key means from its own state — R sends
    /// back what is waiting to be verified and reopens what is done in the same press.
    func act(key: String) {
        let byAction = Dictionary(grouping: list.selectedItems.filter { !$0.readOnly }) { Lifecycle.action(forKey: key, state: $0.state) ?? "" }
        let runs = byAction.filter { !$0.key.isEmpty }
        guard !runs.isEmpty else {
            NSSound.beep()
            if let why = notHere(key, list.selectedItems) { appDelegate?.toast(why) }
            return
        }
        for a in Lifecycle.actions where runs[a] != nil { apply(a, to: runs[a]!) }
    }

    /// The state menu of the selection, under a row's ring (S, or a click on the ring).
    func showStateMenu(row: Int?, from view: NSView?) {
        let items = list.selectedItems
        guard !items.isEmpty, Scripts.canWrite else { NSSound.beep(); return }
        let m = StateMenu.menu(for: items, canHandOff: true, selector: #selector(mState(_:)), target: self)
        guard !m.items.isEmpty else { NSSound.beep(); return }
        if let r = row ?? list.table.selectedRowIndexes.first, let v = view ?? list.ringView(row: r), v.window != nil {
            StateMenu.popUp(m, from: v, in: list.table, row: r)
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
        let items = items.filter { !$0.readOnly }
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
            writes.run { [weak self] in
                let r = await Scripts.awaiting({ Scripts.userOps(["--project", p], ops, done: $0) })
                if case .failure(let f) = r { self?.alert(T("main.error.save_title"), f.localized) }
                self?.wrote(group)
            }
        }
    }

    /// After a write: make sure the index catches up even when items.py couldn't update it in-process; the detail page
    /// re-reads its doc in place (its scroll, media and caret stay) — an item that moved elsewhere is shown again
    /// from there by the model's reload (WebHostController.refresh(item:)).
    func wrote(_ items: [ItemRow]) {
        Scripts.indexUpdate(items.map(\.fileURL))
        detail.pollNow()
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
        case 8: list.elsewhereUID.map(reveal(uid:))
        case 9: go(.all)                // the search stays: the same words over every item
        case 10: if case .project(let p) = model.scope { removeProject(p) }
        case 11: go(.inbox)
        default: break
        }
    }

    /// A project whose folder is gone: pick where it is now (MissingFolder.ask, the island's Locate… too). Only a
    /// folder that holds this project's store is taken (the panel refuses another), and opening it is the same project
    /// again (projects.py add relocates a store whose registered folder has disappeared); the index follows.
    func locateFolder(_ id: String) {
        guard let p = model.project(id: id) else { return }
        MissingFolder.ask(id: p.id, name: p.name, path: p.path, on: window) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .found(let f):
                self.model.reloadSidebar()
                self.reveal(project: f.id)
            case .failed(let why):
                self.alert(T("main.open.failed", p.name), why)
            }
        }
    }

    func clearFilters() {
        model.kinds = []; model.state = nil; model.text = ""
        searchItem?.searchField.stringValue = ""
        model.reload()
        list.scrollToStart()
    }

    func showShortcuts() { ShortcutsSheet.show(on: window) }

    // MARK: projects

    @objc func openFolder() { pickFolder(then: nil) }

    /// `then` (the Move popover's Open Folder…): one folder, and what to do with its project once it is open.
    func pickFolder(then: ((Project) -> Void)?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = then == nil
        panel.canCreateDirectories = true
        panel.prompt = T("main.open.prompt")
        panel.message = T("main.open.message")
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .OK else { return }
            self?.openFolders(panel.urls, then: then)
        }
        if let w = window, w.isVisible { panel.beginSheetModal(for: w, completionHandler: done) } else { activateApp(); done(panel.runModal()) }
    }

    /// Registers the folders as projects (projects.py add) and shows the last one (or hands it to `then`).
    func openFolders(_ urls: [URL]) { openFolders(urls, then: nil) }

    func openFolders(_ urls: [URL], then: ((Project) -> Void)?) {
        Task { @MainActor in
            var last: Project?
            for u in urls {
                do { last = try await ProjectStore.shared.open(folder: u) }
                catch { alert(T("main.open.failed", u.lastPathComponent), peopleText(error, context: "open folder")) }
            }
            if let p = last {
                model.reloadSidebar()
                if let then = then { then(p) } else { reveal(project: p.id) }
            }
        }
    }

    /// Items to a project (or "inbox" = Unassigned), as the user's choice (items.py move --by user) — from the toolbar,
    /// the menus, the palette, a drop on the sidebar or the banner's suggestion. ⌘Z (or the toast's Undo) sends each
    /// item back to the project it came from, with its old id. The step is on the stack at once; the move runs in
    /// writes, after anything still being written.
    func move(uids: [String], to project: String) {
        guard model.items(uids: uids).contains(where: { $0.projectID != project && !$0.readOnly }) else { return }
        move(uids: uids, to: project, toast: true)
    }

    /// `toast`: false for ⇧⌘Z.
    private func move(uids: [String], to project: String, toast: Bool) {
        let step = UndoStep<[(uid: String, project: String)]>()
        register(moveUndoName(project), step) { c, s in c.undoMove(uids: uids, to: project, s) }
        writes.run { [weak self] in
            guard let self = self else { return }
            let items = self.model.items(uids: uids).filter { $0.projectID != project && !$0.readOnly }
            guard !items.isEmpty else { return self.drop(step) }
            step.value = items.map { (uid: $0.uid, project: $0.projectID) }
            switch await Scripts.awaiting({ Scripts.move(items.map(\.uid), to: project, done: $0) }) {
            case .success(let o):
                let n = (o["moved"] as? [Any])?.count ?? items.count
                self.wrote(items)
                if toast {
                    appDelegate?.toast(TP("main.move.done", n, Self.projectName(project)), icon: .check, undo: self.undoToast(self.moveUndoName(project)))
                }
            case .failure(let f):
                self.drop(step)
                self.alert(T("main.move.failed"), f.localized)
            }
        }
    }

    static func projectName(_ id: String) -> String {
        id == "inbox" ? T("project.inbox") : ProjectStore.shared.project(id: id)?.name ?? T("main.project.removed_name")
    }
    private func moveUndoName(_ project: String) -> String { T("main.move.undo_name", Self.projectName(project)) }

    /// ⌘Z: each item back where it was (after the move itself has been written); ⇧⌘Z moves them again.
    private func undoMove(uids: [String], to project: String, _ step: UndoStep<[(uid: String, project: String)]>) {
        let redo = UndoStep<Void>()
        register(moveUndoName(project), redo) { c, _ in c.move(uids: uids, to: project, toast: false) }
        writes.run { [weak self] in
            guard let self = self, let before = step.value else { return }
            for back in MoveBack.plan(before, movedTo: project) {
                let rows = self.model.items(uids: back.uids)
                switch await Scripts.awaiting({ Scripts.move(back.uids, to: back.project, done: $0) }) {
                case .success:
                    self.wrote(rows)
                    // back in this list (moved out of the project on show): selected again
                    self.model.reloadAll()
                    if back.uids.contains(where: { self.model.row(of: $0) != nil }) { self.list.reload(keep: back.uids) }
                case .failure(let f):
                    self.drop(redo)
                    self.alert(T("main.move.failed"), f.localized)
                }
            }
        }
    }

    /// A toast's Undo: the window's ⌘Z, as long as the step it names is still the one ⌘Z would take back.
    func undoToast(_ name: String) -> () -> Void {
        { [weak self] in
            guard let um = self?.window?.undoManager, um.canUndo, um.undoActionName == name else { NSSound.beep(); return }
            um.undo()
        }
    }

    func projectSettings(_ id: String) {
        guard let p = ProjectStore.shared.project(id: id), !p.isInbox, let w = window else { return }
        ProjectSettingsSheet.show(p, on: w) { [weak self] patch in
            self?.writes.run { [weak self] in
                do { try await ProjectStore.shared.update(id, patch) }
                catch { self?.alert(T("main.project.save_failed"), Self.projectFailure(error)) }
            }
        }
    }

    /// What to tell the user when projects.py said no: its code's own sentence (K10), never the code or an id.
    static func projectFailure(_ error: Error) -> String {
        (error as? ProjectError).map { Scripts.Failure(code: $0.code, message: "\($0)").localized } ?? T("main.error.generic")
    }

    /// Remove from Blurt: at once, no question (micro 9) — the folder and its items stay where they are, and Undo
    /// (⌘Z, the toast) puts the project back exactly as it was (projects.py restore: name, key, settings, its place in
    /// the list, current or not). On the stack at once; the write runs in writes.
    func removeProject(_ id: String) {
        guard ProjectStore.shared.project(id: id) != nil else { return }
        let name = T("main.project.remove.undo_name")
        let step = UndoStep<[String: Any]>()
        register(name, step) { c, s in c.restoreProject(id, s, name: name) }
        writes.run { [weak self] in
            guard let self = self else { return }
            guard let p = ProjectStore.shared.project(id: id) else { return self.drop(step) }
            do {
                let removed = try await ProjectStore.shared.remove(id)
                guard !removed.isEmpty else { return self.drop(step) }
                step.value = removed
                self.model.filters.forget(Scope.project(id).key)
                if self.model.scope == .project(id) { self.go(.inbox) }
                appDelegate?.toast(T("main.project.removed", p.name), undo: self.undoToast(name))
            } catch {
                self.drop(step)
                self.alert(T("main.project.save_failed"), Self.projectFailure(error))
            }
        }
    }

    private func restoreProject(_ id: String, _ step: UndoStep<[String: Any]>, name: String) {
        let redo = UndoStep<Void>()
        register(name, redo) { c, _ in c.removeProject(id) }      // ⇧⌘Z removes it again
        writes.run { [weak self] in
            guard let self = self, let removed = step.value else { return }
            do {
                try await ProjectStore.shared.restore(removed)
                self.model.reloadSidebar()
                self.reveal(project: id)
            } catch {
                self.drop(redo)
                self.alert(T("main.project.save_failed"), Self.projectFailure(error))
            }
        }
    }

    /// A project's name typed in place in the sidebar; ⌘Z puts the old one back.
    func renameProject(_ id: String, to name: String) {
        guard let old = ProjectStore.shared.project(id: id)?.name, old != name else { return }
        renameProject(id, resolve: { name })
    }

    /// `resolve`: the new name, read when the write runs (an undo's is the name its rename found).
    private func renameProject(_ id: String, resolve: @escaping () -> String?) {
        let step = UndoStep<String>()
        register(T("main.project.rename.undo_name"), step) { c, s in c.renameProject(id, resolve: { s.value }) }
        writes.run { [weak self] in
            guard let self = self else { return }
            guard let name = resolve(), let old = ProjectStore.shared.project(id: id)?.name, old != name else { return self.drop(step) }
            step.value = old
            do { try await ProjectStore.shared.update(id, ["name": name]) }
            catch {
                self.drop(step)
                self.alert(T("main.project.save_failed"), Self.projectFailure(error))
            }
        }
    }

    /// The projects dragged into a new order (⌘5–⌘9 follow it); ⌘Z puts the old order back.
    func reorderProjects(_ ids: [String]) {
        guard ProjectStore.shared.ordered.map(\.id) != ids else { return }
        reorderProjects(resolve: { ids })
    }

    private func reorderProjects(resolve: @escaping () -> [String]?) {
        let step = UndoStep<[String]>()
        register(T("main.project.reorder.undo_name"), step) { c, s in c.reorderProjects(resolve: { s.value }) }
        writes.run { [weak self] in
            guard let self = self else { return }
            let old = ProjectStore.shared.ordered.map(\.id)
            // the order as it is by now: a project removed meanwhile drops out, one added stays where it is
            guard let want = resolve().map({ ProjectStore.reconciled($0, with: old) }), want != old else { return self.drop(step) }
            step.value = old
            do { try await ProjectStore.shared.order(want) }
            catch {
                self.drop(step)
                self.alert(T("main.project.save_failed"), Self.projectFailure(error))
            }
        }
    }

    /// The project on show (the menu bar's Project menu acts on it).
    var shownProject: String? {
        if case .project(let p) = model.scope, model.project(id: p)?.registered == true { return p }
        return nil
    }
    @objc func mRenameShownProject() {
        guard let p = shownProject else { return }
        sidebar.select(.project(p))
        window?.makeFirstResponder(sidebar.outline)
        sidebar.renameSelected()
    }
    @objc func mShownProjectSettings() { shownProject.map(projectSettings) }
    @objc func mUseShownProject() {
        guard let p = shownProject else { return }
        useProject(ProjectStore.shared.currentID == p ? nil : p)
    }
    @objc func mRevealShownProject() { shownProject.flatMap { model.project(id: $0) }.map { NSWorkspace.shared.activateFileViewerSelecting([$0.path]) } }
    @objc func mRemoveShownProject() { shownProject.map(removeProject) }
    /// Pin to Top / Unpin (the sidebar's project menu): ⌘Z puts it back.
    @objc func mPinProject(_ i: NSMenuItem) {
        guard let id = i.representedObject as? String, let p = ProjectStore.shared.project(id: id) else { return }
        setPinned(id, !p.pinned)
    }

    func setPinned(_ id: String, _ on: Bool) {
        let step = UndoStep<Bool>()
        register(T("main.project.pin.undo_name"), step) { c, s in c.setPinned(id, s.value ?? !on) }
        writes.run { [weak self] in
            guard let self = self else { return }
            guard let p = ProjectStore.shared.project(id: id), p.pinned != on else { return self.drop(step) }
            step.value = p.pinned
            do { try await ProjectStore.shared.update(id, ["pinned": on]) }
            catch {
                self.drop(step)
                self.alert(T("main.project.save_failed"), Self.projectFailure(error))
            }
        }
    }

    @objc func mRenameProject(_ i: NSMenuItem) {
        guard let p = i.representedObject as? String else { return }
        sidebar.select(.project(p))
        window?.makeFirstResponder(sidebar.outline)
        DispatchQueue.main.async { [weak self] in self?.sidebar.renameSelected() }   // after the context menu closed
    }

    /// The current project — where new captures go — set by the user (nil = none: Unassigned).
    func useProject(_ id: String?) {
        Task { @MainActor in
            do { try await ProjectStore.shared.use(id) } catch { appDelegate?.toast(T("main.project.use_failed")) }
            AppEnvironment.island?.projectChanged()
        }
    }

    // MARK: handing off (K5 in Blurt, K6 to your own agent)

    /// Why these items can't go to a session in Blurt, decided here before the panel opens (HandOffCheck: the rules
    /// sessions.py enforces) — the menus show it as the item's tooltip, ⌘Return as a toast with the way out. The panel
    /// never opens on something it would refuse.
    func dispatchBlock(_ items: [ItemRow]) -> HandOffBlock? {
        let check = items.filter { !$0.legacy }.map {
            HandOffCheck.Item(itemID: $0.itemID, state: $0.state, projectID: $0.projectID, job: $0.workJob, unreadable: $0.unreadable)
        }
        return HandOffCheck.block(check) { JobStore.shared.job($0)?.isActive == true }
    }

    func dispatchBlocker(_ items: [ItemRow]) -> String? { dispatchBlock(items).map(Self.blockText) }

    static func blockText(_ b: HandOffBlock) -> String {
        switch b {
        case .unreadable: return T("main.unreadable.fix_first")
        case .discarded: return T("main.dispatch.discarded")
        case .finished(let s): return T("main.dispatch.reopen_first", Look.stateName(s))
        case .withSession(let id, _): return T("main.dispatch.with_session", id)
        case .mixedProjects: return T("main.dispatch.one_project")
        case .needsProject: return T("main.dispatch.needs_project")
        }
    }

    /// Start an agent session in Blurt: the dispatch panel (agent, mode, worktree, the concurrent-edit reminder —
    /// inline, Terminal/DispatchPanel). Items that can't go say why at once, with the way out (Move to Project…,
    /// Restore, Reopen, Open Its Session).
    func dispatch(uids: [String]) {
        let all = model.items(uids: uids)
        guard !all.isEmpty else { NSSound.beep(); return }
        if let b = dispatchBlock(all) {
            NSSound.beep()
            let why = Self.blockText(b)
            let way: (String, () -> Void)?
            switch b {
            case .needsProject: way = (T("main.dispatch.move_first"), { [weak self] in self?.showMoveMenu() })
            case .discarded: way = (StateMenu.title("restore"), { [weak self] in self?.apply("restore", to: all) })
            case .finished: way = (StateMenu.title("reopen"), { [weak self] in self?.apply("reopen", to: all) })
            case .withSession(_, let job): way = (T("main.dispatch.open_session"), { TerminalModule.reveal(job: job) })
            case .unreadable:
                let f = all.first(where: \.unreadable)?.fileURL
                way = f.map { u in (T("main.unreadable.open"), { NSWorkspace.shared.open(u) }) }
            case .mixedProjects: way = nil
            }
            emit(["event": "dispatch_blocked", "why": "\(b)"])
            if let island = AppEnvironment.island {
                island.toast(why, actionTitle: way?.0, action: way?.1)
            } else {
                appDelegate?.toast(why)
            }
            return
        }
        let items = all.filter { !$0.discarded && !$0.readOnly }
        guard !items.isEmpty, let d = AppEnvironment.dispatch else { NSSound.beep(); return }
        d(items.map(\.uid))
    }

    /// Copy instruction / full text for your own agent app (K6). The sheet is written and the items marked handed off
    /// when you copy — that click is the hand-off.
    func handOff(uids: [String], what: String, reply: @escaping ([String: Any]?) -> Void) {
        let items = model.items(uids: uids).filter { !$0.discarded && !$0.readOnly }
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
    @objc func mExportBundle() { exportBundle(uids: list.selectedItems.map(\.uid)) }
    /// The app's own sentence for a script's error code ("main.error.<code>"), nil when it has none.
    static func errorSentence(_ code: String) -> String? {
        let k = "main.error.\(code)"
        return T(k) == k ? nil : T(k)
    }

    /// Export Hand-off Bundle…: the selected items as one .zip for someone else (a summary, every item, its
    /// screenshots and clips; relative paths, so it opens on their machine) — export_local.py bundle. The Save panel
    /// is a sheet on this window, with the skill's name for it; nothing changes state. While it packs (uv, copying the
    /// clips: seconds) the island says so and the action is off; then "Saved" with Show in Finder takes that line's
    /// place, or an alert says why not (the script's own reason under ours). `to` (tests): skip the panel.
    func exportBundle(uids: [String], to fixed: URL? = nil, done: ((URL?) -> Void)? = nil) {
        let items = model.items(uids: uids).filter { !$0.readOnly }
        guard !items.isEmpty, Scripts.canWrite, !bundling else { NSSound.beep(); done?(nil); return }
        let one = Set(items.map(\.projectID)).count == 1
        let name = HandoffBundle.fileName(project: one ? items[0].projectName : nil, count: items.count, chinese: Loc.isChinese)
        let write: (URL) -> Void = { [weak self] url in
            emit(["event": "bundle_export", "items": items.count, "path": url.path])
            self?.bundling = true
            let packing = T("main.bundle.packing", TP("main.items.count", items.count))
            if let island = AppEnvironment.island {
                island.toast(packing, key: "bundle", icon: nil, seconds: 300, actionTitle: nil, action: nil)
            } else {
                self?.window?.subtitle = packing
            }
            Scripts.call("export_local.py", ["bundle", "--items"] + items.map(\.uid) + ["-o", url.path, "--lang", Loc.isChinese ? "zh" : "en"],
                         timeout: 300) { r in
                self?.bundling = false
                if AppEnvironment.island == nil { self?.updateTitle() }
                switch r {
                case .success(let o):
                    let path = URL(fileURLWithPath: o["path"] as? String ?? url.path)
                    emit(["event": "bundle_exported", "path": path.path, "items": o["items"] ?? 0, "missing": o["missing"] ?? []])
                    let text = T("main.bundle.saved", path.lastPathComponent)
                    if let island = AppEnvironment.island {
                        island.toast(text, key: "bundle", icon: .check, seconds: 8, actionTitle: T("action.reveal_in_finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([path])
                        }
                    } else {
                        appDelegate?.toast(text, icon: .check)
                    }
                    done?(path)
                case .failure(let f):
                    emit(["event": "bundle_failed", "code": f.code, "error": f.message])
                    AppEnvironment.island?.dropToasts(key: "bundle")
                    NSLog("blurt bundle: %@: %@", f.code, f.message)
                    let ours = Loc.has("main.bundle.error.\(f.code)", table: "Main") ? T("main.bundle.error.\(f.code)") : Self.errorSentence(f.code)
                    self?.alert(T("main.bundle.failed"), HandoffBundle.failureText(ours: ours, fallback: f.localized))
                    done?(nil)
                }
            }
        }
        if let u = fixed { return write(u) }
        let p = NSSavePanel()
        p.nameFieldStringValue = name
        p.allowedContentTypes = [.zip]
        p.canCreateDirectories = true
        p.isExtensionHidden = false
        p.message = T("main.bundle.message")
        p.prompt = T("main.bundle.save")
        guard let w = window else { if p.runModal() == .OK, let u = p.url { write(u) }; return }
        p.beginSheetModal(for: w) { r in
            if r == .OK, let u = p.url { write(u) } else { done?(nil) }
        }
        bundlePanel = p
    }
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
        // the primary verb first (the detail's one primary button, ⌘↩)
        handOffActions(into: m, items: items)
        // what you can do from the items' state (K3), one line a row: no header and no hints (the rings say what each
        // leads to; the hint is the tooltip, and the ring's own menu, S, shows it in full). Discard waits for the end.
        let states = Scripts.canWrite ? StateMenu.actions(for: items, canHandOff: false) : []
        func state(_ a: String) -> NSMenuItem { StateMenu.item(a, items: items, selector: #selector(mState(_:)), target: self, hints: false) }
        let lead = states.filter { $0 != "discard" }
        if !lead.isEmpty {
            m.addItem(.separator())
            lead.forEach { m.addItem(state($0)) }
        }
        m.addItem(.separator())
        itemActions(into: m, items: items)
        // the one destructive verb last, on its own (as in StateMenu.menu and the Item menu)
        if states.contains("discard") {
            m.addItem(.separator())
            m.addItem(state("discard"))
        }
        return m
    }

    /// The first group of the context menu and the menu bar's Item menu: Hand Off to Agent, and the agent session it
    /// started when there is one to open. `items` nil: the menu bar.
    func handOffActions(into m: NSMenu, items: [ItemRow]?) {
        let n = items?.count ?? 1
        let one = items.map { $0.count == 1 } ?? true
        _ = add(m, n > 1 ? TP("main.menu.start_session_n", n) : T("main.menu.start_session"), #selector(mHandOff), "paperplane", key: "\r")
        if items == nil || (one && items.flatMap { $0.first }.flatMap(sessionJob) != nil) {
            _ = add(m, T("main.menu.open_session"), #selector(mOpenSession), "apple.terminal")
        }
    }

    /// The item actions between the state rows and Discard — one builder for the context menu and the menu bar's Item
    /// menu, so both have the same entries in the same order with the same titles, symbols and keys (the menu bar's are
    /// all there and enabled per selection; the context menu leaves out what doesn't apply). `items` nil: the menu bar.
    /// Three groups: change the item, take it out of Blurt (every copy in one Copy submenu), look at its files. One
    /// symbol per action (system.md §2.7): `folder` only for projects, `sparkles` only for Organise.
    /// `inSelection`: the selection summary's ⋯ menu, which has its own Move to Project… button.
    func itemActions(into m: NSMenu, items: [ItemRow]?, inSelection: Bool = false) {
        let one = items.map { $0.count == 1 } ?? true
        let bar = items == nil
        if !inSelection { m.addItem(submenu(T("main.menu.move_to"), "arrow.turn.up.right", moveMenu())) }
        m.addItem(submenu(T("main.menu.kind"), "tag", kindMenu(items ?? [])))
        if bar || one { _ = add(m, T("main.menu.rename"), #selector(mRename), "pencil", key: "e", mods: []) }
        _ = add(m, T("main.menu.enrich"), #selector(mEnrich), "text.badge.plus")
        m.addItem(.separator())
        m.addItem(submenu(T("menu.copy"), "doc.on.doc", copyMenu()))
        _ = add(m, T("main.menu.export_bundle"), #selector(mExportBundle), "archivebox")
        m.addItem(.separator())
        _ = add(m, T("main.menu.quick_look"), #selector(mQuickLook), "eye", key: "y")
        _ = add(m, T("action.reveal_in_finder"), #selector(mReveal), "arrow.up.forward.app", key: "r", mods: [.command, .shift])
        if one, let e = Editor.preferred { _ = add(m, T("main.menu.open_in", e.name), #selector(mOpenInEditor), "chevron.left.forwardslash.chevron.right") }
        if bar || (one && items?.first?.sessionURL != nil) {
            _ = add(m, T("main.menu.review_batch"), #selector(mReviewBatch), "rectangle.stack")
        }
    }

    /// Copy ▸: the instruction for your own agent first (⇧⌘C), then the item's text, its link and its file's path
    /// (⌥⌘C). Words only — the parent row carries the copy glyph.
    func copyMenu() -> NSMenu {
        let m = NSMenu()
        _ = add(m, T("main.cmd.copy_instruction"), #selector(mCopyInstruction), key: "c", mods: [.command, .shift])
        _ = add(m, T("main.cmd.copy_full"), #selector(mCopyFull))
        _ = add(m, T("main.menu.copy_link"), #selector(mCopyLink))
        _ = add(m, T("action.copy_path"), #selector(mCopyPath), key: "c", mods: [.command, .option])
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

    /// M (and Move to Project… in the palette): a small popover at the selection — type to filter, ↩ moves every
    /// selected item there (one ⌘Z for all of them). Nothing selected, or items that can't move: a beep.
    func pickProject() { pickProject(from: nil) }

    /// `anchor`: hang the popover from that view (the selection summary's button) instead of the selected rows.
    func pickProject(from anchor: NSView?) {
        let items = list.selectedItems.filter { !$0.readOnly }
        guard !items.isEmpty, Scripts.canWrite else { NSSound.beep(); return }
        let here = Set(items.map(\.projectID))
        let uids = items.map(\.uid)
        // what moves, in the field: "Move BA-1 to…", "Move 3 items to…"
        let subject = items.count == 1 && !items[0].itemID.isEmpty ? T("main.move.placeholder.one", items[0].itemID)
            : TP("main.move.placeholder.many", items.count)
        let p = ProjectPopover(checked: here.count == 1 ? here.first : nil, subject: subject,
                               choose: { [weak self] pid in self?.move(uids: uids, to: pid) },
                               openFolder: { [weak self] in self?.pickFolder { self?.move(uids: uids, to: $0.id) } })
        movePopover = p
        if let v = anchor {         // the selection summary's Move to Project… button: the popover hangs from it
            p.show(relativeTo: v.bounds, of: v)
            return
        }
        let t = list.table
        let rows = t.selectedRowIndexes
        let visible = rows.filter { t.rows(in: t.visibleRect).contains($0) }
        let anchor = visible.last ?? rows.first ?? 0       // under the selection, not over part of it
        if visible.isEmpty { t.scrollRowToVisible(anchor) }
        var r = t.rect(ofRow: anchor)
        if let col = t.tableColumns.firstIndex(where: { $0.identifier.rawValue == "title" }) {
            // the arrow points at the start of the title: the popover hangs from the item it moves
            r = r.intersection(t.rect(ofColumn: col))
            r.size.width = min(r.width, 24)
        }
        p.show(relativeTo: r, of: t)
    }
    /// the Move popover on show (wp6 tests read it)
    private(set) weak var movePopover: ProjectPopover?

    func moveMenu() -> NSMenu {
        let m = NSMenu()
        let here = Set(list.selectedItems.map(\.projectID))
        for p in ProjectStore.shared.projects {         // the one order: pinned, then the most recently used
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
            i.image = Look.kindImage(key, size: KindStyle.smallSize)
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
        let use = add(m, cur ? T("main.project.use_none") : T("main.project.use"), #selector(mUseProject(_:)), "scope", obj: cur ? nil : id)
        use.toolTip = T("main.project.use.tip")
        // the projects' one order is pinned, then the most recently used: pinning is how one stays on top
        _ = add(m, p.pinned ? T("main.project.unpin") : T("main.project.pin"), #selector(mPinProject(_:)), p.pinned ? "pin.slash" : "pin", obj: id)
        _ = add(m, T("main.project.rename"), #selector(mRenameProject(_:)), "pencil", obj: id)
        _ = add(m, T("main.project.settings"), #selector(mProjectSettings(_:)), "slider.horizontal.3", obj: id)
        m.addItem(.separator())
        _ = add(m, T("action.reveal_in_finder"), #selector(mRevealURL(_:)), "arrow.up.forward.app", obj: p.path)
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

    /// The item sits in the menu bar (at any depth), not in a context or toolbar menu.
    func inMenuBar(_ item: NSMenuItem) -> Bool {
        var m = item.menu
        while let s = m?.supermenu { m = s }
        return m != nil && m === NSApp.mainMenu
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let items = list.selectedItems
        if inMenuBar(item), isKeyMatch(item) {
            return false        // a menu-bar item's single key: the list's keyDown handles it there (MainMenu.displayKey)
        }
        switch item.action {
        case #selector(mHandOff):
            // disabled with the reason as its tooltip, never an alert after the click (micro 23)
            let why = dispatchBlocker(items)
            item.toolTip = why
            return Scripts.canWrite && why == nil && items.contains { !$0.discarded && !$0.readOnly }
        case #selector(mCopyInstruction), #selector(mCopyFull):
            return Scripts.canWrite && items.contains { !$0.discarded && !$0.readOnly }
        case #selector(mExportBundle):
            return Scripts.canWrite && !bundling && items.contains { !$0.readOnly }
        case #selector(mState(_:)):
            guard Scripts.canWrite, let a = item.representedObject as? String else { return false }
            if a == "back" {
                // the menu bar's one "back" entry says what R does for the selection
                let back = items.filter { !$0.readOnly }.compactMap { Lifecycle.backAction($0.state) }
                item.title = StateMenu.title(Set(back).count == 1 ? back[0] : "send_back")
                return !back.isEmpty
            }
            return !StateMenu.valid(a, items).isEmpty
        case #selector(mStateMenu):
            return Scripts.canWrite && !StateMenu.actions(for: items, canHandOff: true).isEmpty
        case #selector(mMove(_:)):
            guard let p = item.representedObject as? String else { return false }
            return Scripts.canWrite && items.contains { $0.projectID != p && !$0.readOnly }
        case #selector(mOpenSession):
            return items.count == 1 && sessionJob(items[0]) != nil
        case #selector(mRename):
            // one title at a time: with several rows selected Rename is off and E beeps
            return Scripts.canWrite && items.count == 1 && !items[0].readOnly
        case #selector(mSetKind(_:)):
            if inMenuBar(item), let k = item.representedObject as? String { item.state = !items.isEmpty && items.allSatisfy { $0.kind == k } ? .on : .off }
            return Scripts.canWrite && items.contains { !$0.readOnly }
        case #selector(mRenameShownProject), #selector(mShownProjectSettings), #selector(mRevealShownProject):
            return shownProject != nil
        case #selector(mUseShownProject):
            item.title = shownProject != nil && ProjectStore.shared.currentID == shownProject ? T("main.project.use_none") : T("main.project.use")
            return shownProject != nil
        case #selector(mRemoveShownProject):
            return shownProject != nil
        case #selector(mSort(_:)):
            item.state = item.representedObject as? String == model.sort ? .on : .off
            return model.scope != .dictation
        case #selector(mClearFilters):
            return model.filtered
        case #selector(mEnrich):
            return Scripts.canWrite && items.contains { !$0.readOnly && !$0.discarded }
        case #selector(mReviewBatch):
            return items.count == 1 && items[0].sessionURL != nil
        case #selector(mReveal), #selector(mCopyPath), #selector(mCopyLink), #selector(mQuickLook), #selector(mOpenInEditor):
            return !items.isEmpty
        default: return true
        }
    }

    // MARK: WebHostActions

    func reveal(file: URL) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    func quickLook(files: [URL]) { list.toggleQuickLook(files) }
    func webWrote() { detail.currentItem.map { Scripts.indexUpdate([$0.fileURL]) } }
    /// ⌘Z took back a step the detail page made on another item than the one selected: show that one, like the
    /// list's own undo does.
    func webUndid(_ uid: String) {
        guard detail.currentItem?.uid != uid, !uid.isEmpty else { return }
        if model.row(of: uid) != nil { list.select(id: uid) }
    }
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
        case let a where a.hasPrefix("item:"):          // an item the job wrote, from its detail
            reveal(uid: String(a.dropFirst(5)))
        case "stop" where job.type != .agent:            // an organising run: Stop in its detail (⌘.)
            JobStop.stop(job)
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
            case "q": mCloseToMenuBar(); return true     // not Quit: the window goes, Blurt stays in the menu bar
            case "1": go(.inbox); return true
            case "2": go(.inProgress); return true
            case "3": go(.unassigned); return true
            case "4": go(.all); return true
            default: break
            }
            if let n = Int(ch), n >= 5, n <= 9 {
                let ps = shortcutProjects
                if n - 5 < ps.count { go(.project(ps[n - 5].id)) } else { NSSound.beep() }
                return true
            }
            if e.keyCode == 36 || e.keyCode == 76, window?.firstResponder === list.table { handOffSelection(); return true }
        }
        if mods == [.command, .shift], ch == "r" { mReveal(); return true }
        if mods == [.command, .shift], ch == "c", window?.firstResponder === list.table { mCopyInstruction(); return true }
        if mods == [.command, .option], ch == "c" { copyPaths(); return true }
        return false
    }

    // MARK: toolbar

    static let recordID = NSToolbarItem.Identifier("record"), snapID = NSToolbarItem.Identifier("snap")
    static let filterID = NSToolbarItem.Identifier("filter"), titleID = NSToolbarItem.Identifier("title")
    static let searchID = NSToolbarItem.Identifier("search")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.toolbarItems(dictation: false) }

    /// The items' toolbar: Record and Snap (the capture pair), Filter and search; the place's name is the list's
    /// heading. Moving and handing off act on the selection, so they live with it (the detail, the Item and context
    /// menus, M / ⌘↩, ⌘K) — not twice on screen. The Dictation page has its own: its title and search (its header
    /// links to Dictation Settings).
    static func toolbarItems(dictation: Bool) -> [NSToolbarItem.Identifier] {
        dictation ? [.toggleSidebar, .sidebarTrackingSeparator, titleID, .flexibleSpace, searchID]
                  : [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, recordID, snapID, .space, filterID, searchID]
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
        case Self.filterID:
            let i = menuItem(T("main.toolbar.filter"), "line.3.horizontal.decrease.circle", tip: T("main.toolbar.filter.tip"), tag: 3)
            (i as? NSMenuToolbarItem)?.showsIndicator = false
            filterItem = i as? NSMenuToolbarItem
            return i
        case Self.titleID:
            let i = NSToolbarItem(itemIdentifier: id)
            i.view = titleView
            i.label = T("main.toolbar.title")
            i.paletteLabel = i.label
            i.isBordered = false
            i.visibilityPriority = .high
            return i
        case Self.searchID:
            let s = NSSearchToolbarItem(itemIdentifier: id)
            s.searchField.placeholderString = T("main.search.placeholder")
            s.searchField.delegate = self
            s.searchField.sendsSearchStringImmediately = true
            s.searchField.sendsWholeSearchString = false
            s.searchField.setAccessibilityLabel(T("main.search.label"))
            s.searchField.toolTip = T("main.search.tip")
            s.preferredWidthForSearchField = 220
            // a fixed field (Mail's, Linear's), not one that takes a third of the window
            let cap = s.searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 240)
            cap.priority = .required
            cap.isActive = true
            searchItem = s
            return s
        default: return nil
        }
    }

    /// The toolbar's Filter menu, built when it opens (the counts are the place's, now).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        switch menu.identifier?.rawValue {
        case "toolbar-3":
            for it in filterMenu().items { it.menu?.removeItem(it); menu.addItem(it) }
        default: break
        }
    }

    // MARK: the filter (toolbar Filter, View ▸ Filter, the filter line above the list)

    private(set) var filterItem: NSMenuToolbarItem?

    /// Kinds (any number; none = all, each with its count here) and, where the place has one, the State filter; then
    /// Clear Filters. The same menu everywhere it opens.
    func filterMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(menuHeader(T("main.filter.kind_header")))
        let all = add(m, T("main.filter.all_kinds"), #selector(mFilterKind(_:)), obj: "")
        all.state = model.kinds.isEmpty ? .on : .off
        let counts = model.kindCounts()
        for k in KindStyle.builtIn {
            let i = add(m, Look.kindPlural(k), #selector(mFilterKind(_:)), obj: k)
            i.image = Look.kindImage(k, size: KindStyle.smallSize)
            i.state = model.kinds.contains(k) ? .on : .off
            if let n = counts[k] {
                if #available(macOS 14.0, *) { i.badge = NSMenuItemBadge(string: Loc.number(n)) }
                else { i.title += "  \(Loc.number(n))" }
            }
        }
        if PlaceFilters.showsState(model.scope.key) {
            m.addItem(.separator())
            m.addItem(menuHeader(T("main.filter.state_header")))
            func st(_ title: String, _ value: String?, ring: String?, symbol: String? = nil) {
                let i = add(m, title, #selector(mFilterState(_:)), obj: value ?? "")
                i.image = ring.map { Look.ring($0, size: 14) } ?? symbol.flatMap { Look.symbol($0, "", size: 12) }
                i.state = model.state == value ? .on : .off
            }
            st(T("main.filter.live"), nil, ring: nil)
            // "needs you" is a place (the Inbox), not a state: an old saved filter that says it still works
            if model.state == "inbox" { st(T("main.filter.needs_you"), "inbox", ring: nil, symbol: "tray") }
            for s in Lifecycle.live { st(Look.stateName(s), s, ring: s) }
            st(Look.stateName("discarded"), "discarded", ring: "discarded")
        }
        // the order lives here too (and in View ▸ Sort By): the list has no column header to click
        m.addItem(.separator())
        let sort = NSMenu()
        for (key, title) in Self.sortKeys {
            let i = add(sort, title, #selector(mSort(_:)), obj: key)
            i.state = model.sort == key ? .on : .off
        }
        m.addItem(submenu(T("menu.sort_by"), "arrow.up.arrow.down", sort))
        m.addItem(.separator())
        let clear = add(m, T("main.empty.clear_filters"), #selector(mClearKindAndState))
        clear.isEnabled = !model.kinds.isEmpty || model.shownState != nil
        return m
    }

    /// The Filter menu at the top of the list (tests and View ▸ Filter…; the toolbar button opens its own).
    @objc func showFilterMenu() {
        // under the toolbar's Filter button (it sits just before the search field), as a click on it opens it
        if let f = searchItem?.searchField, let sv = f.superview, f.window != nil {
            filterMenu().popUp(positioning: nil, at: NSPoint(x: f.frame.minX - 44, y: sv.isFlipped ? f.frame.maxY + 6 : f.frame.minY - 6), in: sv)
            return
        }
        let v = list.view
        filterMenu().popUp(positioning: nil, at: NSPoint(x: 16, y: v.isFlipped ? 8 : v.bounds.maxY - 8), in: v)
    }

    @objc func mFilterKind(_ i: NSMenuItem) {
        guard let k = i.representedObject as? String else { return }
        if k.isEmpty { model.kinds = [] } else if model.kinds.contains(k) { model.kinds.remove(k) } else { model.kinds.insert(k) }
        list.filtersChanged()
    }
    @objc func mFilterState(_ i: NSMenuItem) {
        guard let v = i.representedObject as? String else { return }
        model.state = v.isEmpty ? nil : v
        list.filtersChanged()
    }
    @objc func mClearKindAndState() { list.clearKindAndState() }

    /// The Filter button says when a filter is on: the filled glyph in brand ink.
    func syncFilterItem() {
        guard let i = filterItem else { return }
        let on = !model.kinds.isEmpty || model.shownState != nil
        i.image = Look.symbol(on ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle", T("main.toolbar.filter"), size: 15)
        i.toolTip = on ? (FilterBar.describe(model) ?? T("main.toolbar.filter.tip")) : T("main.toolbar.filter.tip")
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
        var scope: String?, sort: String?, ascending: Bool?
        /// each place's kinds and State filter (PlaceFilters)
        var filters: PlaceFilters?
        /// before 0.9: one filter for the whole window (read once, for the place it was saved in)
        var kinds: [String]?, state: String?
        var selected: [String]?, open: Bool?
        /// ⌘Q's "Blurt is still in the menu bar" was shown
        var quitHint: Bool?
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
        s.detail = foldedForEmpty ? detailWidthBeforeFold : Double(items[2].viewController.view.frame.width)
        if case .session = model.scope {} else { s.scope = model.scope.key }
        s.filters = model.allFilters
        s.quitHint = quitHintShown ? true : nil
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
        var filters = s?.filters ?? PlaceFilters()
        if s?.filters == nil, let old = s, old.kinds?.isEmpty == false || old.state != nil {
            filters.set(PlaceFilter(kinds: old.kinds ?? [], state: old.state), for: model.scope.key)   // never a state the place can't show
        }
        model.filters = filters
        model.applyFilters()
        quitHintShown = s?.quitHint == true
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

/// The Dictation page's toolbar title: its name in 17 pt semibold (system.md §7, window titles 17–20), its count under
/// it in 11 pt secondary (the item places name themselves in the list's heading, ListHeading).
final class ToolbarTitle: NSView {
    /// a label drawn as itself over the toolbar's material (not the vibrant, washed-out text of a bar item)
    final class Label: NSTextField {
        override var allowsVibrancy: Bool { false }
    }
    let title = Label(labelWithString: "")
    let subtitle = Label(labelWithString: "")
    override var allowsVibrancy: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .labelColor
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        for t in [title, subtitle] {
            t.lineBreakMode = .byTruncatingTail
            t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            t.translatesAutoresizingMaskIntoConstraints = false
            addSubview(t)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: -1),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var centred: NSLayoutConstraint?
    func set(title t: String, subtitle s: String) {
        title.stringValue = t
        subtitle.stringValue = s
        subtitle.isHidden = s.isEmpty
        // without counts the title sits in the middle on its own
        centred?.isActive = false
        centred = title.centerYAnchor.constraint(equalTo: centerYAnchor, constant: s.isEmpty ? 0 : -7)
        centred?.isActive = true
        setAccessibilityLabel([t, s].filter { !$0.isEmpty }.joined(separator: ", "))
        invalidateIntrinsicContentSize()
    }
    override var intrinsicContentSize: NSSize {
        let w = max(title.intrinsicContentSize.width, subtitle.isHidden ? 0 : subtitle.intrinsicContentSize.width) + 8
        return NSSize(width: min(320, ceil(w)), height: 38)
    }
}
