// The menu bar while the main window is open (the app is a regular app then: Dock, ⌘Tab, menus), the keyboard
// shortcuts panel (?), and opening code / folders in the user's editor.
import AppKit
import BlurtCore

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
        var app = [NSMenuItem]()
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
        _ = menu(T("menu.file"), [item(T("project.open_folder"), #selector(MainWindowController.openFolder), "o"), recentItem, .separator(),
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
            i.image = Look.ring(Lifecycle.transitions[a]?.to ?? "todo", size: 14)
            displayKey(i, key)
            return i
        }
        let changeState = item(T("main.menu.change_state"), #selector(MainWindowController.mStateMenu))
        displayKey(changeState, "s")
        let itemMenu = menu(T("menu.item"), [changeState, state("keep", "a"), state("done", "d"), state("back", "r"), state("wontfix", "w"),
                                             state("discard", "\u{8}"), .separator()])
        c.itemActions(into: itemMenu, items: nil)       // the rest as in the context menu (one builder)
        // the project on show: what its sidebar row's menu offers, with keys
        _ = menu(T("menu.project"), [item(T("main.project.settings"), #selector(MainWindowController.mShownProjectSettings), "i"),
                                     item(T("main.project.rename"), #selector(MainWindowController.mRenameShownProject)),
                                     item(T("main.project.use"), #selector(MainWindowController.mUseShownProject)), .separator(),
                                     item(T("action.reveal_in_finder"), #selector(MainWindowController.mRevealShownProject)), .separator(),
                                     item(T("main.project.remove"), #selector(MainWindowController.mRemoveShownProject), "\u{8}")])
        _ = menu(T("menu.window"), [item(T("menu.minimize"), #selector(NSWindow.performMiniaturize(_:)), "m", target: nil),
                                    item(T("menu.zoom"), #selector(NSWindow.performZoom(_:)), "", target: nil)])
        let help = menu(T("menu.help"), [item(T("menu.shortcuts"), #selector(MainWindowController.mShortcuts), "/", [.command, .shift]),
                                         item(T("menu.website"), #selector(MainWindowController.mHelp))])
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

/// "?" — the keyboard map, in three headed groups (where you go, what you do to an item, edit and window). A normal
/// utility panel that follows the app's appearance: label text on the window background (the old HUD measured 3.8:1),
/// every row in the user's language.
enum ShortcutsSheet {
    static var sections: [(String, [(String, String)])] {
        [(T("main.keys.section.navigate"), [
            ("⌘K", T("main.keys.palette")), ("/  ⌘F", T("main.keys.search")), ("J / K  ↓ / ↑", T("main.keys.next")),
            ("↩", T("main.keys.open")), ("⌘1 … ⌘4", T("main.keys.places")), ("⌘5 … ⌘9", T("main.keys.projects")),
            ("⌥⌘D", T("dictation.history.sidebar")), ("⌘O", T("project.open_folder")),
         ]),
         (T("main.keys.section.item"), [
            ("⌘↩", T("main.menu.start_session")), ("⇧⌘C", T("main.cmd.copy_instruction")),
            ("S", T("main.keys.state")), ("A", StateMenu.title("keep")), ("D", StateMenu.title("done")), ("R", T("main.keys.back")),
            ("W", StateMenu.title("wontfix")), ("X  ⌫", StateMenu.title("discard")),
            ("E", T("main.menu.rename").replacingOccurrences(of: "…", with: "")), ("1 2 3 4", T("main.keys.kind")),
            (T("main.keys.space"), T("main.menu.quick_look")), ("⇧⌘R  ⌥⌘C", T("main.keys.reveal_copy")),
         ]),
         (T("main.keys.section.window"), [
            ("⌘Z  ⇧⌘Z", T("main.keys.undo")), ("⌃⌘S", T("menu.toggle_sidebar")), ("⌥⌘I", T("main.keys.detail")),
            ("?", T("main.keys.this")),
         ])]
    }

    static func show(on window: NSWindow?) {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        for (n, (title, rows)) in sections.enumerated() {
            let h = NSTextField(labelWithString: title)
            h.font = .systemFont(ofSize: 11, weight: .semibold)
            h.textColor = .secondaryLabelColor
            grid.addRow(with: [h, NSGridCell.emptyContentView])
            let hr = grid.row(at: grid.numberOfRows - 1)
            hr.mergeCells(in: NSRange(location: 0, length: 2))
            hr.cell(at: 0).xPlacement = .leading
            hr.topPadding = n == 0 ? 0 : 12
            hr.bottomPadding = 2
            for (k, v) in rows {
                let a = NSTextField(labelWithString: k)
                a.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
                a.textColor = .labelColor
                a.alignment = .right
                let b = NSTextField(labelWithString: v)
                b.font = .systemFont(ofSize: 12)
                b.textColor = .secondaryLabelColor
                grid.addRow(with: [a, b])
            }
        }
        grid.rowSpacing = 7
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        // a floating panel, not a sheet: it never blocks the window (or quitting); ? or Esc closes it
        if let p = panel, p.isVisible { p.orderOut(nil); return }
        let p = ShortcutsPanel(contentRect: .zero, styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        p.appearance = window?.appearance
        p.title = T("menu.shortcuts")
        p.isFloatingPanel = true
        p.hidesOnDeactivate = true
        p.isReleasedWhenClosed = false
        let box = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(grid)
        NSLayoutConstraint.activate([grid.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 20),
                                     grid.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -20),
                                     grid.topAnchor.constraint(equalTo: box.topAnchor, constant: 16),
                                     grid.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -18)])
        p.contentView = box
        p.setContentSize(box.fittingSize)
        if let w = window {
            p.setFrameOrigin(NSPoint(x: w.frame.midX - p.frame.width / 2, y: w.frame.midY - p.frame.height / 2))
        } else { p.center() }
        p.makeKeyAndOrderFront(nil)
        panel = p
    }
    static var panel: NSPanel?
}

final class ShortcutsPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    override func keyDown(with e: NSEvent) {
        if e.charactersIgnoringModifiers == "?" { orderOut(nil) } else { super.keyDown(with: e) }
    }
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
