// The menu bar while the main window is open (the app is a regular app then: Dock, ⌘Tab, menus), the keyboard
// shortcuts sheet (?), and opening code / folders in the user's editor.
import AppKit
import BlurtCore

enum MainMenu {
    static func build() -> NSMenu {
        let main = ReviewHub.mainMenu()          // Blurt / Edit / View / Window, shared with review windows
        let c = MainWindowController.shared
        func item(_ t: String, _ sel: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, obj: Any? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = c
            i.representedObject = obj
            return i
        }
        func menu(_ title: String, _ items: [NSMenuItem], at index: Int) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            it.submenu = m
            main.insertItem(it, at: min(index, main.items.count))
        }
        if let app = main.items.first?.submenu {
            if AppEnvironment.settings != nil {
                let s = NSMenuItem(title: L("设置…", "Settings…"), action: #selector(MainWindowController.mSettings), keyEquivalent: ",")
                s.target = c
                app.insertItem(s, at: 0)
                app.insertItem(.separator(), at: 1)
            }
        }
        let file = [item(L("录制", "Record"), #selector(MainWindowController.record)),
                    item(L("截图", "Snap"), #selector(MainWindowController.snap)),
                    .separator(),
                    item(L("重新扫描录制", "Rescan Recordings"), #selector(MainWindowController.mRescan)),
                    .separator(),
                    item(L("关闭窗口", "Close Window"), #selector(NSWindow.performClose(_:)), "w")]
        file.forEach { if $0.action == #selector(MainWindowController.record) { $0.showHotkey(.toggleRecord) } else if $0.action == #selector(MainWindowController.snap) { $0.showHotkey(.snap) } }
        file.last?.target = nil
        menu(L("文件", "File"), file, at: 1)
        let go = [item(L("命令面板…", "Command Palette…"), #selector(MainWindowController.showPalette), "k"),
                  item(L("搜索", "Find"), #selector(MainWindowController.mFind), "f"),
                  .separator(),
                  item(L("收件箱", "Inbox"), #selector(MainWindowController.mGo(_:)), "1", obj: "inbox"),
                  item(L("全部条目", "All Items"), #selector(MainWindowController.mGo(_:)), "2", obj: "all"),
                  item(L("待修问题", "Open Issues"), #selector(MainWindowController.mGo(_:)), "3", obj: "smart:openIssues"),
                  item(L("想法", "Ideas"), #selector(MainWindowController.mGo(_:)), "4", obj: "smart:ideas"),
                  item(L("Agent 修复中", "Agent Fixing"), #selector(MainWindowController.mGo(_:)), "5", obj: "smart:fixing"),
                  item(L("已修复", "Fixed"), #selector(MainWindowController.mGo(_:)), "6", obj: "smart:fixed"),
                  item(L("全部会话", "All Sessions"), #selector(MainWindowController.mGo(_:)), "7", obj: "sessions"),
                  .separator(),
                  item(L("显示 / 隐藏侧栏", "Toggle Sidebar"), #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control])]
        go.last?.target = nil
        menu(L("前往", "Go"), go, at: 4)
        let it = [item(L("让 Agent 修", "Let Agent Fix"), #selector(MainWindowController.mFix), "\r"),
                  item(L("预览主帧", "Quick Look"), #selector(MainWindowController.mQuickLook), "y"),
                  item(L("审核模式", "Review Mode"), #selector(MainWindowController.mReview)),
                  .separator(),
                  item(L("改标题…", "Rename…"), #selector(MainWindowController.mRename)),
                  item(L("标为已确认", "Mark Confirmed"), #selector(MainWindowController.mSetStatus(_:)), obj: "confirmed"),
                  item(L("标为待审", "Mark Draft"), #selector(MainWindowController.mSetStatus(_:)), obj: "draft"),
                  item(L("丢弃", "Drop"), #selector(MainWindowController.mSetStatus(_:)), "\u{8}", obj: "deleted"),
                  .separator(),
                  item(L("在访达中显示", "Reveal in Finder"), #selector(MainWindowController.mReveal), "r", [.command, .shift]),
                  item(L("拷贝路径", "Copy Path"), #selector(MainWindowController.mCopyPath), "c", [.command, .option]),
                  item(L("拷贝链接", "Copy Link"), #selector(MainWindowController.mCopyLink))]
        menu(L("条目", "Item"), it, at: 5)
        let help = [item(L("键盘快捷键", "Keyboard Shortcuts"), #selector(MainWindowController.mShortcuts), "/", [.command, .shift]),
                    item(L("口喷鸡主页", "Blurt Website"), #selector(MainWindowController.mHelp))]
        menu(L("帮助", "Help"), help, at: main.items.count)
        NSApp.helpMenu = main.items.last?.submenu
        return main
    }
}

extension MainWindowController {
    @objc func mSettings() { AppEnvironment.settings?.show(pane: nil) }
    @objc func mRescan() { model.scan() }
    @objc func mFind() { focusSearch() }
    @objc func mGo(_ i: NSMenuItem) { (i.representedObject as? String).flatMap(Scope.init(key:)).map(go) }
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

/// "?" — the keyboard map (§2.5)
enum ShortcutsSheet {
    static func show(on window: NSWindow?) {
        let rows: [(String, String)] = [
            ("⌘K", L("命令面板", "Command palette")), ("/  ⌘F", L("搜索", "Search")),
            ("J / K  ↓ / ↑", L("下一条 / 上一条", "Next / previous")), ("↩", L("打开（进入详情）", "Open (focus the detail)")),
            ("⌘↩", L("交给 agent 修", "Let the agent fix it")), ("E", L("改标题", "Rename")),
            ("1 2 3 4", L("改类型：问题 想法 笔记 任务", "Kind: issue idea note task")), ("S", L("切换 待审 / 已确认", "Toggle draft / confirmed")),
            ("⌫", L("丢弃", "Drop")), ("R", L("审核模式", "Review mode")), (L("空格", "Space"), "Quick Look"),
            ("⌘1 … ⌘7", L("收件箱、全部条目、智能筛选、会话", "Inbox, All Items, smart filters, sessions")),
            ("⇧⌘R  ⌥⌘C", L("在访达中显示 · 拷贝路径", "Reveal in Finder · copy path")), ("?", L("这张表", "This sheet")),
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
        let a = NSAlert()
        a.messageText = L("键盘快捷键", "Keyboard Shortcuts")
        a.accessoryView = grid
        grid.frame.size = grid.fittingSize
        a.addButton(withTitle: L("好", "OK"))
        if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
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

    /// code_refs of one item ("src/a.ts:42", or {path, line})
    static func codeRefs(_ it: ItemRow) -> [String] {
        guard it.hasCodeRefs,
              let doc = (try? JSONSerialization.jsonObject(with: Data(contentsOf: it.sessionURL.appendingPathComponent("items.json")))) as? [String: Any],
              let item = (doc["items"] as? [[String: Any]])?.first(where: { $0["id"] as? String == it.itemID }) else { return [] }
        return (item["code_refs"] as? [Any] ?? []).compactMap { r in
            if let s = r as? String { return s }
            if let d = r as? [String: Any], let p = (d["path"] ?? d["file"]) as? String {
                return (d["line"] as? Int).map { "\(p):\($0)" } ?? p
            }
            return nil
        }
    }

    static func open(ref: String, repo: URL?, session: URL) {
        var path = ref, line: Int?
        let parts = ref.split(separator: ":")
        if parts.count >= 2, let l = Int(parts[1]) { path = String(parts[0]); line = l }
        let candidates = path.hasPrefix("/") ? [URL(fileURLWithPath: path)]
            : [repo?.appendingPathComponent(path), session.appendingPathComponent(path)].compactMap { $0 }
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
