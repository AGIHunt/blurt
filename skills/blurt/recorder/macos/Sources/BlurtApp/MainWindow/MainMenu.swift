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
        app += [item(T("menu.hide"), #selector(NSApplication.hide(_:)), "h", target: nil), .separator(),
                item(T("menu.quit"), #selector(NSApplication.terminate(_:)), "", target: nil)]   // no ⌘Q: it's the resident app
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
                  item(T("main.place.all"), #selector(MainWindowController.mGo(_:)), "4", obj: "all")]
        for (k, p) in c.model.projects.prefix(5).enumerated() where p.registered {
            go.append(item(p.name, #selector(MainWindowController.mGoProject(_:)), "\(k + 5)", obj: p.id))
        }
        go += [.separator(), item(T("menu.toggle_sidebar"), #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control], target: nil)]
        _ = menu(T("menu.go"), go)
        let move = NSMenuItem(title: T("main.menu.move_to"), action: nil, keyEquivalent: "")
        move.submenu = c.moveMenu()
        _ = menu(T("menu.item"), [item(T("main.menu.start_session"), #selector(MainWindowController.mHandOff), "\r"),
                                  item(T("main.cmd.copy_instruction"), #selector(MainWindowController.mCopyInstruction), "c", [.command, .shift]),
                                  item(T("main.cmd.copy_full"), #selector(MainWindowController.mCopyFull)), .separator(),
                                  item(T("main.cmd.mark_done"), #selector(MainWindowController.mWork(_:)), obj: "done"),
                                  item(T("main.cmd.reopen"), #selector(MainWindowController.mWork(_:)), obj: "todo"),
                                  item(T("main.cmd.wontfix"), #selector(MainWindowController.mWork(_:)), obj: "wontfix"), .separator(),
                                  move,
                                  item(T("main.menu.rename"), #selector(MainWindowController.mRename)),
                                  item(T("review.confirmed"), #selector(MainWindowController.mSetStatus(_:)), obj: "confirmed"),
                                  item(T("review.draft"), #selector(MainWindowController.mSetStatus(_:)), obj: "draft"),
                                  item(T("review.deleted"), #selector(MainWindowController.mSetStatus(_:)), "\u{8}", obj: "deleted"), .separator(),
                                  item(T("main.menu.quick_look"), #selector(MainWindowController.mQuickLook), "y"),
                                  item(T("action.reveal_in_finder"), #selector(MainWindowController.mReveal), "r", [.command, .shift]),
                                  item(T("action.copy_path"), #selector(MainWindowController.mCopyPath), "c", [.command, .option]),
                                  item(T("main.menu.copy_link"), #selector(MainWindowController.mCopyLink))])
        _ = menu(T("menu.window"), [item(T("menu.minimize"), #selector(NSWindow.performMiniaturize(_:)), "m", target: nil),
                                    item(T("menu.zoom"), #selector(NSWindow.performZoom(_:)), "", target: nil)])
        let help = menu(T("menu.help"), [item(T("menu.shortcuts"), #selector(MainWindowController.mShortcuts), "/", [.command, .shift]),
                                         item(T("menu.website"), #selector(MainWindowController.mHelp))])
        NSApp.helpMenu = help
        NSApp.windowsMenu = main.items.first { $0.title == T("menu.window") }?.submenu
        return main
    }
}

extension MainWindowController {
    @objc func mSettings() { AppEnvironment.settings?.show(pane: nil) }
    @objc func mRescan() { model.scan() }
    @objc func mFind() { focusSearch() }
    @objc func mGo(_ i: NSMenuItem) { (i.representedObject as? String).flatMap(Scope.init(key:)).map(go) }
    @objc func mGoProject(_ i: NSMenuItem) { (i.representedObject as? String).map { reveal(project: $0) } }
    @objc func mShortcuts() { showShortcuts() }
    @objc func mHelp() { NSWorkspace.shared.open(URL(string: "https://github.com/AGIHunt/blurt")!) }
}

/// A section title in a menu (NSMenuItem.sectionHeader on macOS 14+, a disabled item before).
func menuHeader(_ title: String) -> NSMenuItem {
    if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
    let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    i.isEnabled = false
    return i
}

/// "?" — the keyboard map
enum ShortcutsSheet {
    static func show(on window: NSWindow?) {
        let rows: [(String, String)] = [
            ("⌘K", T("main.keys.palette")), ("/  ⌘F", T("main.keys.search")), ("⌘O", T("project.open_folder")),
            ("J / K  ↓ / ↑", T("main.keys.next")), ("↩", T("main.keys.open")),
            ("⌘↩", T("main.menu.start_session")), ("⇧⌘C", T("main.cmd.copy_instruction")),
            ("D", T("main.cmd.mark_done")), ("R", T("main.cmd.reopen")), ("E", T("main.menu.rename")),
            ("1 2 3 4", T("main.keys.kind")), ("S", T("main.keys.keep")), ("⌫", T("review.deleted")),
            (T("main.keys.space"), "Quick Look"),
            ("⌘1 … ⌘4", T("main.keys.places")), ("⌘5 … ⌘9", T("main.keys.projects")),
            ("⇧⌘R  ⌥⌘C", T("main.keys.reveal_copy")), ("?", T("main.keys.this")),
        ]
        let grid = NSGridView(views: rows.map { k, v in
            let a = NSTextField(labelWithString: k)
            a.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            a.alignment = .right
            let b = NSTextField(labelWithString: v)
            b.font = .systemFont(ofSize: 12)
            b.textColor = .secondaryLabelColor
            return [a, b]
        })
        grid.rowSpacing = 7
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        // a floating panel, not a sheet: it never blocks the window (or quitting); ? or Esc closes it
        if let p = panel, p.isVisible { p.orderOut(nil); return }
        let p = ShortcutsPanel(contentRect: .zero, styleMask: [.titled, .closable, .utilityWindow, .hudWindow], backing: .buffered, defer: false)
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
