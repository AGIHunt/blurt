// The menu bar while the main window is open (the app is a regular app then: Dock, ⌘Tab, menus), the keyboard
// shortcuts panel (?), and opening code / folders in the user's editor.
import AppKit
import BlurtCore

/// About Blurt: the standard panel (name, version) with Peep in place of the icon — the clay render alone, idling still,
/// in the light set for the current appearance (no tile: the panel is the frame) — and one line of credits.
final class AboutPanel: NSObject {
    static let shared = AboutPanel()
    @objc func orderFrontStandardAboutPanel(_ sender: Any?) {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var opts: [NSApplication.AboutPanelOptionKey: Any] = [
            .credits: NSAttributedString(string: T("menu.about.credits"), attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }()]),
        ]
        if let img = MascotLibrary.shared.image(.idle, points: 64, scale: 4, dark: dark, bleed: 0.1) {
            opts[.applicationIcon] = NSImage(cgImage: img, size: NSSize(width: 64, height: 64))
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: opts)
        emit(["event": "about_panel"])
    }
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let c = MainWindowController.shared
        func item(_ t: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, obj: Any? = nil,
                  target: AnyObject? = c) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            i.representedObject = obj
            return i
        }
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            it.submenu = m
            main.addItem(it)
            return m
        }
        // Check for Updates… under About (the Mac's place) and in Help (where people look for it): a release build only —
        // a local build has no updater (Updater: no key, no Sparkle), so it offers none
        let updates = { () -> [NSMenuItem] in
            Updater.shared.available ? [item(T("app.menu.updates"), #selector(Updater.checkForUpdates(_:)), target: Updater.shared)] : []
        }
        var app = [item(T("menu.about"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: AboutPanel.shared)]
            + updates() + [NSMenuItem.separator()]
        if AppEnvironment.settings != nil { app += [item(T("menu.settings"), #selector(MainWindowController.mSettings), ","), .separator()] }
        // no ⌘Q on Quit: it's the resident app. ⌘Q in the main window closes it back to the menu bar instead
        // (MainWindowController.handleKeyEquivalent → mCloseToMenuBar, which says so once)
        app += [item(T("menu.hide"), #selector(NSApplication.hide(_:)), "h", target: nil), .separator(),
                item(T("menu.quit"), #selector(NSApplication.terminate(_:)), "", target: nil)]
        _ = menu("Blurt", app)

        let recent = NSMenu()
        for p in ProjectStore.shared.projects.prefix(10) {
            let i = item(p.name, #selector(MainWindowController.mGoProject(_:)), obj: p.id)
            i.image = Look.symbol("folder", p.name)
            i.toolTip = (p.path.path as NSString).abbreviatingWithTildeInPath
            recent.addItem(i)
        }
        let recentItem = NSMenuItem(title: T("menu.open_recent"), action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        recentItem.isEnabled = !recent.items.isEmpty
        let rec = item(T("main.action.record"), #selector(MainWindowController.record))
        rec.showHotkey(.toggleRecord)
        let sn = item(T("main.action.snap"), #selector(MainWindowController.snap))
        sn.showHotkey(.snap)
        _ = menu(T("menu.file"), [item(T("main.new_item.menu"), #selector(MainWindowController.newItem), "n"),
                                  item(T("project.open_folder"), #selector(MainWindowController.openFolder), "o"), recentItem, .separator(),
                                  rec, sn, .separator(),
                                  item(T("menu.rescan"), #selector(MainWindowController.mRescan)), .separator(),
                                  item(T("menu.close"), #selector(NSWindow.performClose(_:)), "w", target: nil)])
        _ = menu(T("menu.edit"), [item(T("menu.undo"), Selector(("undo:")), "z", target: nil),
                                  item(T("menu.redo"), Selector(("redo:")), "z", [.command, .shift], target: nil), .separator(),
                                  item(T("menu.cut"), #selector(NSText.cut(_:)), "x", target: nil), item(T("menu.copy"), #selector(NSText.copy(_:)), "c", target: nil),
                                  item(T("menu.paste"), #selector(NSText.paste(_:)), "v", target: nil),
                                  item(T("menu.select_all"), #selector(NSText.selectAll(_:)), "a", target: nil)])
        var go = [item(T("menu.palette"), #selector(MainWindowController.showPalette), "k"),
                  item(T("menu.find"), #selector(MainWindowController.mFind), "f"), .separator(),
                  item(T("main.place.inbox"), #selector(MainWindowController.mGo(_:)), "1", obj: "inbox"),
                  item(T("main.place.progress"), #selector(MainWindowController.mGo(_:)), "2", obj: "progress"),
                  item(T("project.inbox"), #selector(MainWindowController.mGo(_:)), "3", obj: "unassigned"),
                  item(T("main.place.all"), #selector(MainWindowController.mGo(_:)), "4", obj: "all"),
                  item(T("dictation.history.sidebar"), #selector(MainWindowController.mDictationHistory), "d", [.command, .option])]
        if DictationLabModel.enabled {
            go.append(item(T("dictation.lab.menu"), #selector(MainWindowController.mDictationLab), "l", [.command, .option]))
        }
        // ⌘5–⌘9: the same five projects the key handler goes to (MainWindowController.shortcutProjects)
        for (k, p) in c.shortcutProjects.enumerated() {
            go.append(item(p.name, #selector(MainWindowController.mGoProject(_:)), "\(k + 5)", obj: p.id))
        }
        _ = menu(T("menu.go"), go)
        // View: the columns, the sort (the same as the table's header) and the filters
        let sort = NSMenu()
        for (key, title) in MainWindowController.sortKeys {
            sort.addItem(item(title, #selector(MainWindowController.mSort(_:)), obj: key))
        }
        let sortItem = NSMenuItem(title: T("menu.sort_by"), action: nil, keyEquivalent: "")
        sortItem.submenu = sort
        _ = menu(T("menu.view"), [item(T("menu.toggle_sidebar"), #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control], target: nil),
                                  item(T("menu.toggle_detail"), #selector(MainWindowController.mToggleDetail), "i", [.command, .option]), .separator(),
                                  sortItem,
                                  item(T("main.empty.clear_filters"), #selector(MainWindowController.mClearFilters))])
        // K3's actions, enabled per selection (validateMenuItem); the single-key equivalents only show here — the list
        // handles A D R W X ⌫ S E 1–4 itself, so typing in the search field or the detail never triggers them
        func state(_ a: String, _ key: String) -> NSMenuItem {
            let i = item(StateMenu.title(a == "back" ? "send_back" : a), #selector(MainWindowController.mState(_:)), obj: a)
            i.image = Look.target(Lifecycle.transitions[a]?.to ?? "todo", size: 14)
            displayKey(i, key)
            return i
        }
        let changeState = item(T("main.menu.change_state"), #selector(MainWindowController.mStateMenu))
        displayKey(changeState, "s")
        // the context menu's order (MainWindowController.contextMenu): hand off, the states, the item actions (one
        // builder), Discard last after a separator; the menu bar adds Change State… (S) and every state's row
        let itemMenu = menu(T("menu.item"), [])
        c.handOffActions(into: itemMenu, items: nil)
        for i in [NSMenuItem.separator(), changeState, state("keep", "a"), state("done", "d"), state("back", "r"), state("wontfix", "w"),
                  .separator()] { itemMenu.addItem(i) }
        c.itemActions(into: itemMenu, items: nil)
        itemMenu.addItem(.separator())
        itemMenu.addItem(state("discard", "\u{8}"))
        // the project on show: what its sidebar row's menu offers. Remove from Blurt has no key: ⌘⌫ on a selection
        // means "delete these" on the Mac (Finder), so in the list it discards the items, never the project
        _ = menu(T("menu.project"), [item(T("main.project.settings"), #selector(MainWindowController.mShownProjectSettings), "i"),
                                     item(T("main.project.rename"), #selector(MainWindowController.mRenameShownProject)),
                                     item(T("main.project.use"), #selector(MainWindowController.mUseShownProject)), .separator(),
                                     item(T("action.reveal_in_finder"), #selector(MainWindowController.mRevealShownProject)), .separator(),
                                     item(T("main.project.remove"), #selector(MainWindowController.mRemoveShownProject))])
        _ = menu(T("menu.window"), [item(T("menu.minimize"), #selector(NSWindow.performMiniaturize(_:)), "m", target: nil),
                                    item(T("menu.zoom"), #selector(NSWindow.performZoom(_:)), "", target: nil)])
        // ⌘/ (as Linear and Raycast): AppKit keeps ⇧⌘/ (⌘?) for the Help menu's search field, so that key never
        // reached this item
        let help = menu(T("menu.help"), [item(T("menu.shortcuts"), #selector(MainWindowController.mShortcuts), "/", [.command]),
                                         item(T("menu.website"), #selector(MainWindowController.mHelp))]
                                        + (Updater.shared.available ? [.separator()] + updates() : []))
        NSApp.helpMenu = help
        NSApp.windowsMenu = main.items.first { $0.title == T("menu.window") }?.submenu
        return main
    }
}

extension MainMenu {
    /// While only a small window of ours is open (Settings) the app is a menu-bar app without a
    /// main menu — and without one ⌘C / ⌘V / ⌘A / ⌘Z / ⌘W do nothing, in its search field too. This gives it the
    /// Edit keys (the menu bar itself stays hidden); the main window replaces it with the full menu when it opens.
    static func ensureEditKeys() {
        if let m = NSApp.mainMenu, m.items.contains(where: { $0.submenu?.items.contains { $0.action == #selector(NSText.paste(_:)) } == true }) { return }
        func item(_ t: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let edit = NSMenu(title: T("menu.edit"))
        for i in [item(T("menu.undo"), Selector(("undo:")), "z"), item(T("menu.redo"), Selector(("redo:")), "z", [.command, .shift]), .separator(),
                  item(T("menu.cut"), #selector(NSText.cut(_:)), "x"), item(T("menu.copy"), #selector(NSText.copy(_:)), "c"),
                  item(T("menu.paste"), #selector(NSText.paste(_:)), "v"), item(T("menu.select_all"), #selector(NSText.selectAll(_:)), "a"),
                  .separator(), item(T("menu.close"), #selector(NSWindow.performClose(_:)), "w")] { edit.addItem(i) }
        let main = NSMenu()
        let app = NSMenuItem(title: "Blurt", action: nil, keyEquivalent: "")
        app.submenu = NSMenu(title: "Blurt")
        main.addItem(app)
        let e = NSMenuItem(title: edit.title, action: nil, keyEquivalent: "")
        e.submenu = edit
        main.addItem(e)
        NSApp.mainMenu = main
    }
}

/// Shows a single-key equivalent next to a menu-bar item without letting the menu bar act on it: a key equivalent
/// without ⌘ would also fire while typing in the search field or the detail. MainWindowController.validateMenuItem
/// disables these items while a key press is being matched (isKeyMatch), so the key reaches the list's keyDown —
/// which handles it there and only there.
func displayKey(_ i: NSMenuItem, _ key: String) {
    i.keyEquivalent = key
    i.keyEquivalentModifierMask = []
}

extension MainWindowController {
    @objc func mSettings() { AppEnvironment.settings?.show(pane: nil) }
    @objc func mRescan() { model.scan() }
    @objc func mFind() { focusSearch() }
    @objc func mGo(_ i: NSMenuItem) { (i.representedObject as? String).flatMap(Scope.init(key:)).map(go) }
    @objc func mGoProject(_ i: NSMenuItem) { (i.representedObject as? String).map { reveal(project: $0) } }
    @objc func mShortcuts() { showShortcuts() }
    @objc func mDictationHistory() { showDictation() }
    @objc func mDictationLab() { showDictationLab() }
    @objc func mHelp() { NSWorkspace.shared.open(Help.guideURL()) }      // the user guide, in the app's language

    /// ⌘1–⌘4 the places, ⌘5–⌘9 these: the first five opened projects in the sidebar's order — the Go menu and the key
    /// handler read the same list, so a key never goes somewhere its menu doesn't show.
    var shortcutProjects: [ProjectEntry] { Array(model.projects.filter(\.registered).prefix(5)) }

    /// The View menu's Sort By: the table header's sort keys, in its order.
    static var sortKeys: [(String, String)] {
        [("updated", T("main.col.updated")), ("title", T("main.col.title")), ("id", T("main.col.id")), ("kind", T("main.col.kind")),
         ("state", T("main.col.state")), ("project", T("main.col.project"))]
    }

    @objc func mSort(_ i: NSMenuItem) {
        guard let key = i.representedObject as? String else { return }
        // the header's own default direction for the key; picking the current key again flips it, like a header click
        let asc = key == model.sort ? !model.ascending : ["title", "kind", "state", "project", "id"].contains(key)
        list.table.sortDescriptors = [NSSortDescriptor(key: key, ascending: asc)]   // sortDescriptorsDidChange reloads
    }

    @objc func mToggleDetail() {
        let d = split.splitViewItems[2]
        if foldedForEmpty { forgetFold() }          // the user's call from here on
        d.animator().isCollapsed.toggle()
    }

    @objc func mClearFilters() { clearFilters() }

    /// ⌘Q in the main window: close it to the menu bar — Blurt stays for dictation and the capture keys. The first
    /// time, a toast says so (and where Quit is).
    @objc func mCloseToMenuBar() {
        let first = !quitHintShown
        quitHintShown = true                // before the close, which saves the window state
        window?.performClose(nil)
        if first { appDelegate?.toast(T("main.quit.kept"), seconds: 7) }
    }
}

/// A section title in a menu (NSMenuItem.sectionHeader on macOS 14+, a disabled item before).
func menuHeader(_ title: String) -> NSMenuItem {
    if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
    let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    i.isEnabled = false
    return i
}

/// "?" — the keyboard map, in four short sections: where you go, an item's state, what you do with an item, the app
/// and its window. Each row is the action first, in the label colour, and its keys at the trailing edge as keycaps
/// (system.md §2.7: the UI font with tabular figures, never a monospace, where O reads as zero). A floating panel of a
/// fixed width with a search field that filters the rows; ?, ⌘/ or Esc closes it.
enum ShortcutsSheet {
    /// One action. `keys` are alternatives ("or" between them), each a run of keycaps; "–" between two caps makes a
    /// range (⌘1–⌘4). A row never holds two actions.
    struct Row {
        let label: String
        var note: String? = nil
        let keys: [[String]]
    }

    static var sections: [(String, [Row])] {
        func plain(_ s: String) -> String { s.replacingOccurrences(of: "…", with: "") }
        return [
            (T("main.keys.section.navigate"), [
                Row(label: T("main.keys.palette"), keys: [["⌘K"]]),
                Row(label: T("main.keys.search"), keys: [["⌘F"], ["/"]]),
                Row(label: T("main.keys.next"), keys: [["J"], ["↓"]]),
                Row(label: T("main.keys.previous"), keys: [["K"], ["↑"]]),
                Row(label: T("main.keys.open"), keys: [["↩"]]),
                Row(label: T("main.keys.back_to_list"), keys: [["esc"], ["⇧⇥"]]),
                Row(label: T("main.keys.places"), keys: [["⌘1", "–", "⌘4"]]),
                Row(label: T("main.keys.projects"), keys: [["⌘5", "–", "⌘9"]]),
            ]),
            (T("main.keys.section.triage"), [
                Row(label: T("state.menu"), keys: [["S"]]),
                Row(label: T("action.keep"), note: T("main.keys.keep.note"), keys: [["A"]]),
                Row(label: T("action.done"), keys: [["D"]]),
                Row(label: T("action.wontfix"), keys: [["W"]]),
                Row(label: T("action.discard"), keys: [["X"], ["⌫"], ["⌘⌫"]]),
                Row(label: T("main.keys.back"), note: T("main.keys.back.note"), keys: [["R"]]),
                Row(label: T("main.keys.kind"), keys: [["1", "–", "4"]]),
            ]),
            (T("main.keys.section.item"), [
                Row(label: plain(T("action.hand_off")), keys: [["⌘↩"]]),
                Row(label: T("main.keys.copy_instruction"), keys: [["⇧⌘C"]]),
                Row(label: plain(T("main.menu.rename")), keys: [["E"]]),
                Row(label: T("main.keys.move"), keys: [["M"]]),
                Row(label: T("main.menu.quick_look"), keys: [[T("main.keys.space")]]),
                Row(label: T("action.reveal_in_finder"), keys: [["⇧⌘R"]]),
                Row(label: T("main.keys.copy_path"), keys: [["⌥⌘C"]]),
            ]),
            (T("main.keys.section.general"), [
                Row(label: T("main.keys.dictation"), keys: [["⌥⌘D"]]),
                Row(label: T("main.keys.open_folder"), keys: [["⌘O"]]),
                Row(label: T("main.keys.project_settings"), keys: [["⌘I"]]),
                Row(label: T("main.keys.sidebar"), keys: [["⌃⌘S"]]),
                Row(label: T("main.keys.detail"), keys: [["⌥⌘I"]]),
                Row(label: T("menu.undo"), keys: [["⌘Z"]]),
                Row(label: T("menu.redo"), keys: [["⇧⌘Z"]]),
                // ⌘Q in the main window closes it too (mCloseToMenuBar): Blurt is the resident app
                Row(label: T("main.keys.close_window"), note: T("main.keys.close_window.note"), keys: [["⌘W"], ["⌘Q"]]),
                Row(label: T("main.keys.this"), keys: [["?"], ["⌘/"]]),
            ]),
        ]
    }

    static let width: CGFloat = 440
    static let inset: CGFloat = 20
    static let listHeight: CGFloat = 440       // the list scrolls past this; the panel never grows to the screen's height

    static func show(on window: NSWindow?) {
        // a floating panel, not a sheet: it never blocks the window (or quitting); ?, ⌘/ or Esc closes it
        if let p = panel, p.isVisible { p.orderOut(nil); return }
        let p = ShortcutsPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                               styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        p.appearance = window?.appearance
        p.title = T("menu.shortcuts")
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.hidesOnDeactivate = true
        p.isReleasedWhenClosed = false
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        let titleBar = p.frame.height - p.contentLayoutRect.height
        p.build(sections: sections, titleBar: titleBar)
        if let w = window {
            p.setFrameOrigin(NSPoint(x: w.frame.midX - p.frame.width / 2, y: w.frame.midY - p.frame.height / 2))
        } else { p.center() }
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(p.field)
        panel = p
    }
    static var panel: ShortcutsPanel?

    /// What VoiceOver reads for a key, and what the search matches besides the glyph ("delete" finds ⌫).
    static func spoken(_ key: String) -> String {
        let names: [Character: String] = ["⌘": "Command", "⇧": "Shift", "⌥": "Option", "⌃": "Control", "↩": "Return",
                                          "⌫": "Delete", "⇥": "Tab", "↑": "Up Arrow", "↓": "Down Arrow"]
        if key == "esc" { return "Escape" }
        return key.map { names[$0] ?? String($0) }.joined(separator: " ")
    }
}

final class ShortcutsPanel: NSPanel, NSSearchFieldDelegate {
    private(set) var field: NSSearchField!
    private var groups: [(section: ShortcutsSection, rows: [ShortcutRowView])] = []
    private let noMatch = NSTextField(labelWithString: T("main.keys.no_match"))

    func build(sections: [(String, [ShortcutsSheet.Row])], titleBar: CGFloat) {
        let inset = ShortcutsSheet.inset
        let box = NSView()
        field = NSSearchField()
        field.placeholderString = T("main.keys.search_field")
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.focusRingType = .default

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.detachesHiddenViews = true
        list.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        for (n, (title, rows)) in sections.enumerated() {
            let views = rows.map { ShortcutRowView($0, section: title) }
            let s = ShortcutsSection(title: title, rows: views, first: n == 0)
            list.addArrangedSubview(s)
            s.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            groups.append((s, views))
        }
        let doc = FlippedView()
        list.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = doc
        doc.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView
        let full = list.fittingSize.height

        noMatch.font = .systemFont(ofSize: 13)
        noMatch.textColor = .secondaryLabelColor
        noMatch.isHidden = true

        let footer = NSTextField(labelWithString: T("main.keys.footer"))
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        let top = NSBox(), bottom = NSBox()
        top.boxType = .separator
        bottom.boxType = .separator
        for v in [field!, top, scroll, bottom, footer, noMatch] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(v)
        }
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: ShortcutsSheet.width),
            field.topAnchor.constraint(equalTo: box.topAnchor, constant: titleBar + 4),
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -inset),
            top.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: box.leadingAnchor), top.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: min(full, ShortcutsSheet.listHeight)),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor), list.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor), list.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            noMatch.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            noMatch.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 40),
            bottom.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            bottom.leadingAnchor.constraint(equalTo: box.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            footer.topAnchor.constraint(equalTo: bottom.bottomAnchor, constant: 9),
            footer.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset),
            footer.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
        ])
        contentView = box
        setContentSize(NSSize(width: ShortcutsSheet.width, height: box.fittingSize.height))
    }

    /// Shows the rows whose label, note, section or keys (by name too: "delete", "space") contain every word typed.
    func search(_ q: String) {
        let words = q.lowercased().split(separator: " ").map(String.init)
        var anyShown = false
        for (section, rows) in groups {
            var shown = 0
            for r in rows {
                r.isHidden = !words.allSatisfy { r.haystack.contains($0) }
                if !r.isHidden { shown += 1 }
            }
            section.isHidden = shown == 0
            section.showsRule = anyShown && shown > 0
            if shown > 0 { anyShown = true }
        }
        noMatch.isHidden = anyShown
        scrollView?.documentView?.scroll(.zero)
    }

    private var scrollView: NSScrollView? { contentView?.subviews.compactMap { $0 as? NSScrollView }.first }

    /// The list's last rows in view (for a screenshot of the whole map in two captures).
    func scrollToEnd() {
        guard let s = scrollView, let doc = s.documentView else { return }
        doc.scroll(NSPoint(x: 0, y: max(0, doc.frame.height - s.contentView.bounds.height)))
    }

    func controlTextDidChange(_ n: Notification) {
        // "?" closes the panel as it opened it (the field has the focus, so the key arrives here as text)
        if field.stringValue == "?" { field.stringValue = ""; orderOut(nil); return }
        search(field.stringValue)
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.cancelOperation(_:)) else { return false }
        // Esc clears what was typed first, then closes
        if field.stringValue.isEmpty { orderOut(nil) } else { field.stringValue = ""; search("") }
        return true
    }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           e.charactersIgnoringModifiers == "/" { orderOut(nil); return }
        super.sendEvent(e)
    }
    override func keyDown(with e: NSEvent) {
        if e.charactersIgnoringModifiers == "?" { orderOut(nil) } else { super.keyDown(with: e) }
    }
}

/// A section: a hairline above it (not above the first one shown), its title, its rows.
final class ShortcutsSection: NSView {
    private let stack = NSStackView()
    private let rule = ShortcutsRule()
    var showsRule: Bool {
        get { !rule.isHidden }
        set { rule.isHidden = !newValue; stack.edgeInsets.top = newValue ? 0 : 12 }
    }

    init(title: String, rows: [ShortcutRowView], first: Bool) {
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.detachesHiddenViews = true
        let head = NSTextField(labelWithString: title)
        head.font = .systemFont(ofSize: 13, weight: .semibold)
        head.textColor = .labelColor
        head.setAccessibilityRole(.staticText)
        let header = NSView()
        head.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(head)
        NSLayoutConstraint.activate([head.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: ShortcutsSheet.inset),
                                     head.topAnchor.constraint(equalTo: header.topAnchor),
                                     head.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -4)])
        for v in [rule, header] + rows as [NSView] {
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor)])
        showsRule = !first
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The hairline between sections: 10 pt above, 14 below, inset like the rows.
final class ShortcutsRule: NSView {
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 25) }
    override func draw(_ dirtyRect: NSRect) {
        let px = 1 / (window?.backingScaleFactor ?? 2)
        NSColor.separatorColor.setFill()
        NSRect(x: ShortcutsSheet.inset, y: 10, width: bounds.width - ShortcutsSheet.inset * 2, height: px).fill()
    }
}

/// One row: the action (and a short note under it, when the label alone can't say it) on the left in the label
/// colour; its keys right-aligned to the trailing inset, "or" between alternatives.
final class ShortcutRowView: NSView {
    let haystack: String

    init(_ row: ShortcutsSheet.Row, section: String) {
        haystack = ([row.label, row.note ?? "", section] + row.keys.flatMap { $0 }.flatMap { [$0, ShortcutsSheet.spoken($0)] })
            .joined(separator: " ").lowercased()
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: row.label)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [label])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        if let n = row.note {
            let note = NSTextField(labelWithString: n)
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            note.lineBreakMode = .byTruncatingTail
            note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            text.addArrangedSubview(note)
        }
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let keys = NSStackView()
        keys.orientation = .horizontal
        keys.alignment = .centerY
        keys.spacing = 4
        for (i, alt) in row.keys.enumerated() {
            if i > 0 {
                let or = NSTextField(labelWithString: T("main.keys.or"))
                or.font = .systemFont(ofSize: 11)
                or.textColor = .secondaryLabelColor
                keys.setCustomSpacing(6, after: keys.arrangedSubviews.last!)
                keys.addArrangedSubview(or)
                keys.setCustomSpacing(6, after: or)
            }
            for k in alt {
                if k == "–" {
                    let dash = NSTextField(labelWithString: "–")
                    dash.font = .systemFont(ofSize: 11)
                    dash.textColor = .secondaryLabelColor
                    keys.addArrangedSubview(dash)
                } else {
                    keys.addArrangedSubview(KeyCapsView([k]))
                }
            }
        }
        keys.setContentHuggingPriority(.required, for: .horizontal)
        keys.setContentCompressionResistancePriority(.required, for: .horizontal)
        keys.setAccessibilityElement(true)
        keys.setAccessibilityRole(.staticText)
        keys.setAccessibilityLabel(row.keys.map { alt in alt.map { $0 == "–" ? "to" : ShortcutsSheet.spoken($0) }.joined(separator: " ") }
            .joined(separator: ", \(T("main.keys.or")) "))

        let inset = ShortcutsSheet.inset
        for v in [text, keys] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 5),
            keys.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            keys.centerYAnchor.constraint(equalTo: centerYAnchor),
            keys.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 16),
        ])
        toolTip = row.note.map { "\(row.label) — \($0)" }
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The user's code editor: config `editor` ("cursor" | "vscode" | "zed" | "windsurf"), else the first one installed.
enum Editor {
    struct App { let name: String; let bundleID: String; let scheme: String }
    static let known = [App(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", scheme: "cursor"),
                        App(name: "VS Code", bundleID: "com.microsoft.VSCode", scheme: "vscode"),
                        App(name: "Zed", bundleID: "dev.zed.Zed", scheme: "zed"),
                        App(name: "Windsurf", bundleID: "com.exafunction.windsurf", scheme: "windsurf")]

    static var preferred: App? {
        let want = (readConfig()["editor"] as? String)?.lowercased()
        let installed = known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
        return installed.first { $0.scheme == want || $0.name.lowercased() == want } ?? installed.first
    }

    /// "src/a.ts:42" relative to the project folder (or the session), or absolute.
    static func open(ref: String, repo: URL?, session: URL?) {
        var path = ref, line: Int?
        let parts = ref.split(separator: ":")
        if parts.count >= 2, let l = Int(parts[1]) { path = String(parts[0]); line = l }
        let candidates = path.hasPrefix("/") ? [URL(fileURLWithPath: path)]
            : [repo?.appendingPathComponent(path), session?.appendingPathComponent(path)].compactMap { $0 }
        guard let f = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) ?? candidates.first else { return }
        open(file: f, line: line)
    }

    static func open(file: URL, line: Int?) {
        if let e = preferred, let u = URL(string: "\(e.scheme)://file\(file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path)\(line.map { ":\($0)" } ?? "")") {
            NSWorkspace.shared.open(u)
        } else {
            NSWorkspace.shared.open(file)
        }
    }

    static func open(folder: URL) {
        if let e = preferred, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: e.bundleID) {
            NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(folder)
        }
    }
}
