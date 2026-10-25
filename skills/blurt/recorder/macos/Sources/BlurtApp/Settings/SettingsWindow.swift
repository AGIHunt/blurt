// The Settings window (⌘, from the menu; blurt://settings/<pane>[/<row>]): one resizable window, a sidebar and a page.
//   Sidebar  the search field on top (⌘F focuses it, Esc clears it, ↓ / ↑ walk the results, ↩ opens one), then the
//            panes in three small groups — Preferences: General, Dictation, Speech, Shortcuts · Work: Agents ·
//            This Mac: Privacy, Storage (SettingsCatalog.panes) — in an NSOutlineView like the main window's sidebar:
//            the brand-tint selection (BrandRowView), ↑ / ↓ move between panes. While searching, the panes with
//            matches show how many; the others are dimmed.
//   Page     the pane (SwiftUI, SettingsKit's SettingsPage), or the search results (SettingsSearch.swift). Each pane's
//            page is kept once made, so switching back doesn't reload it.
// State (pane, query) lives in SettingsNavigator, the row to scroll to in SettingsFlash. The last pane is remembered
// (app.settings_pane).
// show(pane:) takes "speech" or "speech/dictation" (a row or section of that pane: scrolled to and flashed); nil opens
// the last pane, a name that isn't a pane (a stale link) opens General — never an unrelated pane from last time. A pane
// that moved (SettingsCatalog.moved: the old Export pane) opens where its settings went: Agents, at "Ask your agent".
import AppKit
import Combine
import SwiftUI
import BlurtCore

enum SettingsPane: String, CaseIterable {
    // the sidebar's order (SettingsCatalog.panes)
    case general, dictation, speech, shortcuts, agents, privacy, storage

    var info: SettingsPaneInfo? { SettingsCatalog.pane(rawValue) }
    var title: String { info.flatMap { SettingsCatalog.text($0.title) } ?? rawValue }
    var symbol: String { info?.symbol ?? "gearshape" }

    @MainActor
    func makeController() -> NSViewController {
        let view: AnyView
        switch self {
        case .general: view = AnyView(GeneralPane())
        case .shortcuts: view = AnyView(ShortcutsPane())
        case .speech: view = AnyView(SpeechPane())
        case .dictation: view = AnyView(DictationPane())
        case .agents: view = AnyView(AgentsPane())
        case .privacy: view = AnyView(PrivacyPane())
        case .storage: view = AnyView(StoragePane())
        }
        let vc = NSHostingController(rootView: view)
        vc.sizingOptions = []           // the window sizes the page, not the other way round
        vc.title = title
        return vc
    }
}

/// ⌘F (and the menu's Find) focuses the search field, wherever the focus is.
final class SettingsWindow: NSWindow {
    var onFind: (() -> Void)?
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, e.charactersIgnoringModifiers == "f" {
            onFind?()
            return true
        }
        return super.performKeyEquivalent(with: e)
    }
    @objc func mFind() { onFind?() }
}

final class SettingsController: NSObject, SettingsHosting, NSWindowDelegate {
    static let shared = SettingsController()
    private var window: SettingsWindow?
    private var sidebar: SettingsSidebarController?
    private var detail: SettingsDetailController?
    private var subs: Set<AnyCancellable> = []

    @MainActor
    private func build() {
        let nav = SettingsNavigator.shared
        let side = SettingsSidebarController()
        let page = SettingsDetailController()
        let split = NSSplitViewController()
        let sideItem = NSSplitViewItem(sidebarWithViewController: side)
        sideItem.minimumThickness = 190
        sideItem.maximumThickness = 260
        sideItem.canCollapse = false
        let pageItem = NSSplitViewItem(viewController: page)
        pageItem.minimumThickness = 540
        split.addSplitViewItem(sideItem)
        split.addSplitViewItem(pageItem)

        let w = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        w.contentViewController = split
        w.title = T("settings.window.title")
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.minSize = NSSize(width: 760, height: 520)
        w.setContentSize(NSSize(width: 860, height: 620))
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.onFind = { [weak side] in side?.focusSearch() }
        w.setFrameAutosaveName("BlurtSettingsWindow")
        // an ordinary window: screenshots (yours or ours) can show it; our own recordings leave it out by their filter
        window = w
        sidebar = side
        detail = page
        // the last pane, for next time (a pane chosen while the window is open counts, not only the one at closing)
        nav.$pane.removeDuplicates().sink { p in Config.shared.set("app.settings_pane", p.rawValue) }.store(in: &subs)
    }

    func show(pane: String?) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                let nav = SettingsNavigator.shared
                // "speech" or "speech/dictation": the pane, then a row or section of it; a pane that moved: where it went
                let link = SettingsCatalog.redirect(pane ?? "")
                if link != (pane ?? "") { emit(["event": "settings_moved_pane", "from": pane ?? "", "to": link]) }
                let parts = link.split(separator: "/", maxSplits: 1).map(String.init)
                let asked = parts.first.flatMap(SettingsPane.init(rawValue:))
                // no pane named: the last one picked; a name that isn't a pane (a stale link): General, never an
                // unrelated pane from last time
                if asked == nil, let p = parts.first, !p.isEmpty { emit(["event": "settings_unknown_pane", "pane": p]) }
                let last = SettingsCatalog.redirect(Config.shared["app.settings_pane"] as? String ?? "").split(separator: "/").first
                let want = asked ?? (parts.first?.isEmpty == false ? .general
                    : last.flatMap { SettingsPane(rawValue: String($0)) } ?? .general)
                nav.go(want)                    // before the window is made: only the pane asked for is built
                if window == nil { build() }
                if parts.count > 1 { nav.reveal(parts[1].contains(".") ? parts[1] : "\(want.rawValue).\(parts[1])") }
                MainMenu.ensureEditKeys()       // ⌘V into its fields while the main window has never been open
                activateApp()
                if window?.isVisible != true {
                    window?.center()
                    sidebar?.focusList()
                }
                window?.makeKeyAndOrderFront(nil)
                // in front even when macOS doesn't hand Blurt the focus (the permission guide brings it back from
                // System Settings without a click on Blurt)
                window?.orderFrontRegardless()
                emit(["event": "settings", "pane": want.rawValue])
                // dictation can't hear its key: say so (≈ daily) — not over its own pane, which shows it
                if want != .dictation { Dictation.shared.nudge("settings") }
            }
        }
    }

    var visiblePane: String? {
        guard window?.isVisible == true else { return nil }
        return MainActor.assumeIsolated { SettingsNavigator.shared.pane.rawValue }
    }

    var windowNumber: Int? { window?.isVisible == true ? window?.windowNumber : nil }

    /// Tests (`settingsscroll top|bottom|N`): scroll the visible page, for a screenshot of its lower part.
    @MainActor
    func scrollPane(_ to: String) -> Bool {
        guard let root = detail?.view else { return false }
        var queue = [root]
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if let s = v as? NSScrollView, let doc = s.documentView {
                let maxY = max(0, doc.frame.height - s.contentView.bounds.height)
                let y = to == "bottom" ? maxY : to == "top" ? 0 : min(maxY, Double(to) ?? 0)
                s.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? y : maxY - y))
                s.reflectScrolledClipView(s.contentView)
                return true
            }
            queue += v.subviews
        }
        return false
    }

    /// Tests (`settingssearch TEXT`): type into the search field as a person would.
    @MainActor
    func testSearch(_ text: String) { sidebar?.setSearch(text) }

    func windowWillClose(_ notification: Notification) {
        ShortcutField.active?.stop()
        if let p = visiblePane { Config.shared.set("app.settings_pane", p) }
    }
}

// MARK: - The page

/// The right side: the pane's page or the search results. Pages are made once and kept (their models keep what they
/// loaded), as the old tab view did.
final class SettingsDetailController: NSViewController {
    private var pages: [SettingsPane: NSViewController] = [:]
    private lazy var results: NSViewController = {
        let vc = NSHostingController(rootView: SettingsSearchResults())
        vc.sizingOptions = []
        return vc
    }()
    private var current: NSViewController?
    private var subs: Set<AnyCancellable> = []

    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 620)) }

    override func viewDidLoad() {
        super.viewDidLoad()
        let nav = SettingsNavigator.shared
        nav.$pane.combineLatest(nav.$query.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self] pane, searching in MainActor.assumeIsolated { self?.show(searching ? nil : pane) } }
            .store(in: &subs)
    }

    @MainActor
    private func show(_ pane: SettingsPane?) {
        let vc: NSViewController
        if let p = pane {
            if let made = pages[p] { vc = made } else { vc = p.makeController(); pages[p] = vc }
        } else { vc = results }
        guard vc !== current else { return }
        current?.view.removeFromSuperview()
        current?.removeFromParent()
        addChild(vc)
        vc.view.frame = view.bounds
        vc.view.autoresizingMask = [.width, .height]
        view.addSubview(vc.view)
        current = vc
    }
}

// MARK: - The sidebar

final class SettingsNode: NSObject {
    let title: String
    let pane: SettingsPane?          // nil = a group's label
    var children: [SettingsNode] = []
    init(_ title: String, pane: SettingsPane?, children: [SettingsNode] = []) {
        self.title = title; self.pane = pane; self.children = children
    }
}

final class SettingsSidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    let search = NSSearchField()
    let outline = NSOutlineView()
    private var roots: [SettingsNode] = []
    private var syncing = false
    private var subs: Set<AnyCancellable> = []

    override func loadView() {
        search.placeholderString = T("settings.search.placeholder")
        search.setAccessibilityLabel(T("settings.search.placeholder"))
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.controlSize = .regular
        (search.cell as? NSSearchFieldCell)?.sendsWholeSearchString = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let col = NSTableColumn(identifier: .init("pane"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 0
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel(T("settings.window.title"))
        scroll.documentView = outline

        let root = NSView()
        for v in [search, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            // under the window's buttons (the titlebar is transparent; the sidebar runs to the top)
            search.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        view.frame = NSRect(x: 0, y: 0, width: 210, height: 620)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        roots = SettingsCatalog.groups.map { g in
            SettingsNode(SettingsCatalog.text(g.title) ?? g.id, pane: nil,
                         children: SettingsPane.allCases.filter { $0.info?.group == g.id }.map { SettingsNode($0.title, pane: $0) })
        }
        outline.reloadData()
        for r in roots { outline.expandItem(r) }
        let nav = SettingsNavigator.shared
        nav.$pane.receive(on: RunLoop.main).sink { [weak self] p in MainActor.assumeIsolated { self?.reflect(pane: p) } }.store(in: &subs)
        nav.$hits.receive(on: RunLoop.main).sink { [weak self] _ in MainActor.assumeIsolated { self?.reflectSearch() } }.store(in: &subs)
        nav.$query.receive(on: RunLoop.main).sink { [weak self] q in
            guard let self = self, self.search.stringValue != q else { return }
            self.search.stringValue = q
        }.store(in: &subs)
    }

    @MainActor func focusSearch() {
        view.window?.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)
    }
    @MainActor func focusList() { view.window?.makeFirstResponder(outline) }
    @MainActor func setSearch(_ text: String) {
        search.stringValue = text
        SettingsNavigator.shared.query = text
    }

    /// The selected row follows the pane; while searching nothing is selected (the page shows the results).
    @MainActor private func reflect(pane: SettingsPane) {
        syncing = true
        defer { syncing = false }
        if SettingsNavigator.shared.searching { outline.deselectAll(nil); return }
        for r in roots { for c in r.children where c.pane == pane {
            let row = outline.row(forItem: c)
            if row >= 0, outline.selectedRow != row { outline.selectRowIndexes([row], byExtendingSelection: false) }
        } }
    }

    @MainActor private func reflectSearch() {
        syncing = true
        if SettingsNavigator.shared.searching { outline.deselectAll(nil) }
        syncing = false
        for r in roots { for c in r.children { outline.reloadItem(c) } }
        if !SettingsNavigator.shared.searching { reflect(pane: SettingsNavigator.shared.pane) }
    }

    // MARK: search field

    func controlTextDidChange(_ obj: Notification) {
        MainActor.assumeIsolated { SettingsNavigator.shared.query = search.stringValue }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        MainActor.assumeIsolated {
            let nav = SettingsNavigator.shared
            switch sel {
            case #selector(NSResponder.moveDown(_:)):
                if nav.searching { nav.moveSelection(1) } else { focusList() }
                return true
            case #selector(NSResponder.moveUp(_:)):
                if nav.searching { nav.moveSelection(-1); return true }
                return false
            case #selector(NSResponder.insertNewline(_:)):
                guard nav.searching else { return false }
                nav.openSelected()
                focusList()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if search.stringValue.isEmpty { return false }
                setSearch("")
                return true
            default:
                return false
            }
        }
    }

    // MARK: outline

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SettingsNode)?.children.count ?? roots.count
    }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SettingsNode)?.children[index] ?? roots[index]
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? SettingsNode)?.pane == nil }
    func outlineView(_ o: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? SettingsNode)?.pane == nil }
    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? SettingsNode)?.pane != nil }
    func outlineView(_ o: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }
    func outlineView(_ o: NSOutlineView, shouldCollapseItem item: Any) -> Bool { false }

    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? SettingsNode else { return nil }
        guard let pane = n.pane else {
            let id = NSUserInterfaceItemIdentifier("SettingsHeader")
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
        let id = NSUserInterfaceItemIdentifier("SettingsPaneCell")
        let v = o.makeView(withIdentifier: id, owner: self) as? SettingsPaneCell ?? SettingsPaneCell(id: id)
        let nav = SettingsNavigator.shared
        v.set(title: n.title, symbol: pane.symbol, count: nav.searching ? nav.count(pane) : nil)
        return v
    }

    /// The brand selection (a rounded tint, text stays `labelColor`), like the main window's sidebar.
    func outlineView(_ o: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { BrandRowView() }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let p = (outline.item(atRow: outline.selectedRow) as? SettingsNode)?.pane else { return }
        MainActor.assumeIsolated { SettingsNavigator.shared.go(p) }
    }
}

/// A pane in the sidebar: its symbol, its name, and while searching how many of its settings match (dimmed at none).
/// Like the main window's sidebar (system.md §3.3): the name and symbol are not the cell's textField / imageView, which
/// a source list repaints in the accent when selected — the selected pane reads in ink on its highlight, never green
/// text. The symbol has no description of its own (the cell's label says the pane once).
final class SettingsPaneCell: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let badge = CountPill()

    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        for v in [icon, title, badge] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        // not wired as imageView / textField: the source list would repaint them in the accent when selected — the
        // name stays labelColor on the brand tint, as in the main window's sidebar (system.md §3.3)
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
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

    /// count: nil = not searching; 0 = no match here (dimmed)
    func set(title t: String, symbol: String, count: Int?) {
        title.stringValue = t
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        icon.setAccessibilityElement(false)
        title.setAccessibilityElement(false)
        let dim = count == 0
        title.textColor = dim ? .tertiaryLabelColor : .labelColor
        icon.contentTintColor = dim ? .tertiaryLabelColor : .secondaryLabelColor
        badge.text = count.map { $0 > 0 ? Loc.number($0) : "" } ?? ""
        badge.mint = false
        setAccessibilityLabel([t, badge.text.isEmpty ? nil : badge.text].compactMap { $0 }.joined(separator: ", "))
    }
}
