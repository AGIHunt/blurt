// BLURT_TEST_COMMANDS=1 only: scripted checks for WP6, over a distributed notification like the shell's channel —
//   dev.blurt.recorder.wp6[.$BLURT_TEST_CHANNEL]  userInfo {"cmd": "…"}; every answer is one JSON line on stdout.
//   settings PANE | settingsscroll top|bottom|N | onboarding [STEP] | appearance dark|light | windowid settings|onboarding
//   route URL                    parse a blurt:// URL (no action)         url URL   handle it like macOS would
//   mainopen PATH[|PATH…]       open folders as projects (the Open panel's OK)
//   mainstub                     a stand-in main window that reports reveal(uid:) / reveal(session:) (until WP5 lands)
//   spotlight-index              index now → {"count"}                    spotlight-search TEXT → {"found": [uid…]}
//   spotlight-clear              remove our domain's entries
//   service TEXT                 "Add to Blurt" with TEXT on a private pasteboard, through the real service method
//   fix UIDS                     the dispatch panel for those items (agent, mode, worktree)
//   peck TITLE | peckframes DIR [dark] | perms
import AppKit
import Carbon.HIToolbox
import BlurtCore

enum SelfTests {
    static var channel: String { "dev.blurt.recorder.wp6" + (ProcessInfo.processInfo.environment["BLURT_TEST_CHANNEL"].map { ".\($0)" } ?? "") }

    static func install() {
        guard ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1" else { return }
        DistributedNotificationCenter.default().addObserver(forName: .init(channel), object: nil, queue: .main) { n in
            guard let cmd = n.userInfo?["cmd"] as? String else { return }
            MainActor.assumeIsolated { run(cmd) }
        }
        // a menu that opens (the state menu, a context menu, a popup) runs its own loop, where these commands don't
        // arrive: it closes by itself after 3 s, time enough for a screenshot
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
            guard let m = n.object as? NSMenu, m.supermenu == nil, m !== NSApp.mainMenu else { return }
            let t = Timer(timeInterval: 3, repeats: false) { _ in m.cancelTracking() }
            RunLoop.main.add(t, forMode: .common)
        }
        emit(["event": "wp6_ready", "channel": channel])
    }

    @MainActor
    static func run(_ cmd: String) {
        let parts = cmd.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        func out(_ o: [String: Any]) { emit(["event": "wp6", "cmd": parts.first ?? ""].merging(o) { _, n in n }) }
        switch parts.first ?? "" {
        case "settings": SettingsController.shared.show(pane: arg.isEmpty ? nil : arg)
        case "settingsscroll":          // settingsscroll top|bottom|POINTS: scroll the visible pane
            out(["scrolled": SettingsController.shared.scrollPane(arg.isEmpty ? "bottom" : arg)])
        case "onboarding": Onboarding.shared.show(step: Int(arg) ?? 0)
        case "appearance": NSApp.appearance = NSAppearance(named: arg == "dark" ? .darkAqua : .aqua)
        case "windowid":
            let n: Int? = arg == "onboarding" ? Onboarding.shared.windowNumber : arg == "fix" || arg == "dispatch" ? MainActor.assumeIsolated { DispatchPanel.windowNumber }
                        : SettingsController.shared.windowNumber
            out(["window": n ?? -1])
        case "route": out(["route": URL(string: arg).map { "\(URLRouter.route($0))" } ?? "bad url"])
        case "url": if let u = URL(string: arg) { out(["handled": URLRouter.handle(u)]) }
        case "mainstub":
            AppEnvironment.mainWindow = StubMainWindow.shared
            out(["ok": true])
        case "spotlight-index":
            Spotlight.shared.refresh { n, err in out(["count": n, "error": err.map { "\($0)" } ?? NSNull(), "domain": Spotlight.domain]) }
        case "spotlight-search":
            Spotlight.shared.search(arg) { found in out(["query": arg, "found": found]) }
        case "spotlight-clear":
            Spotlight.shared.removeAll { err in out(["cleared": err == nil]) }
        case "service":
            let pb = NSPasteboard(name: NSPasteboard.Name("blurt-test-\(UUID().uuidString)"))
            pb.clearContents()
            pb.setString(arg, forType: .string)
            var err: NSString?
            ServiceProvider.shared.addToBlurt(pb, userData: nil, error: &err)
            out(["called": true, "error": err.map { $0 as String } ?? NSNull()])
            pb.releaseGlobally()
        case "service-image":
            let pb = NSPasteboard(name: NSPasteboard.Name("blurt-test-\(UUID().uuidString)"))
            pb.clearContents()
            if let img = NSImage(contentsOfFile: arg) { pb.writeObjects([img]) }
            var err: NSString?
            ServiceProvider.shared.addToBlurt(pb, userData: nil, error: &err)
            out(["called": true, "error": err.map { $0 as String } ?? NSNull()])
            pb.releaseGlobally()
        case "shortcut":                // shortcut ACTION SPEC: click the field in Settings → Shortcuts, press SPEC there
            let a = arg.split(separator: " ").map(String.init)
            guard a.count == 2, let act = HotAction(rawValue: a[0]), let combo = KeyCombo.parse(a[1]) else { out(["error": "usage"]); return }
            SettingsController.shared.show(pane: "shortcuts")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let f = HotkeySettings.shared.fields[act], let w = f.window else { out(["error": "no field"]); return }
                f.start()
                var flags: NSEvent.ModifierFlags = []
                if combo.mods & controlKey != 0 { flags.insert(.control) }
                if combo.mods & optionKey != 0 { flags.insert(.option) }
                if combo.mods & shiftKey != 0 { flags.insert(.shift) }
                if combo.mods & cmdKey != 0 { flags.insert(.command) }
                let ch = combo.key.count == 1 ? combo.key.lowercased() : ""
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: w.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                            isARepeat: false, keyCode: UInt16(combo.code)) {
                    NSApp.postEvent(e, atStart: false)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    out(["action": act.rawValue, "now": Hotkeys.shared.shortcut(act)?.spec ?? "off",
                         "config": (Config.shared["record.hotkeys"] as? [String: Any])?[act.rawValue] ?? NSNull(),
                         "state": "\(Hotkeys.shared.states[act].map { "\($0)" } ?? "")"])
                }
            }
        case "fix":
            let uids = (arg.split(separator: " ").first ?? "").split(separator: ",").map(String.init)
            if !uids.isEmpty { MainActor.assumeIsolated { DispatchPanel.show(items: uids) } }
            out(["uids": uids])
        case "peck": PeckCard.shared.leadIn = 1.6; PeckCard.shared.play(title: arg.isEmpty ? "Login button does nothing" : arg, detail: T("main.misc.by_codex"), uid: "test")
        case "peckframes":
            let a = arg.split(separator: " ").map(String.init)
            out(["frames": PeckCard.renderFrames(to: URL(fileURLWithPath: a.first ?? "/tmp/peck"), dark: a.contains("dark"))])
        case "install":                 // install ID: the dry-run preview (sheet in Settings → Agents); install-apply: confirm it
            SettingsController.shared.show(pane: "agents")
            Task { @MainActor in
                await AgentsModel.shared.load(login: false)
                if let a = AgentsModel.shared.rows.first(where: { $0.id == arg }) { await AgentsModel.shared.preview(a) }
                out(["previewed": AgentsModel.shared.plan != nil, "env_home": Agents.shared.installEnvironment()["HOME"] ?? "",
                     "codex_home": Agents.shared.installEnvironment()["CODEX_HOME"] ?? ""])
            }
        case "install-apply":
            Task { @MainActor in
                await AgentsModel.shared.apply()
                out(["applied": AgentsModel.shared.plan?.plan.applied ?? false,
                     "changes": AgentsModel.shared.plan?.plan.changes.map(\.summary) ?? []])
            }
        case "bench":                   // bench MODEL-ID|BACKEND: Settings → Speech → Measure
            SettingsController.shared.show(pane: "speech")
            Task { @MainActor in
                let sm = SpeechModel.shared
                await sm.load()
                guard let m = sm.models.first(where: { $0.id == arg || $0.backend == arg }) else { out(["error": "no model \(arg)"]); return }
                await sm.runBench(m)
                out(["backend": m.backend, "model": m.id, "installed": m.installed, "rtf": sm.bench[m.id]?.rtf ?? -1,
                     "error": sm.bench[m.id]?.error ?? NSNull()])
            }
        case "main":                    // main SCOPE (inbox | progress | unassigned | all | project:<id>): go there
            let c = MainWindowController.shared
            c.show()
            if let s = Scope(key: arg) { c.go(s) }
            out(["scope": c.model.scope.key, "rows": c.model.rowCount, "jobs": c.model.jobs.count, "ms": c.model.lastReloadMS])
        case "mainsel":                 // mainsel N[,M…]: select those rows of the list
            let c = MainWindowController.shared
            let rows = IndexSet(arg.split(separator: ",").compactMap { Int($0) })
            c.list.table.selectRowIndexes(rows, byExtendingSelection: false)
            c.window?.makeFirstResponder(c.list.table)
            out(["selected": c.list.selectedIDs])
        case "mainselid":               // mainselid UID[,UID…]: select those items in the current list
            let c = MainWindowController.shared
            let rows = IndexSet(arg.split(separator: ",").compactMap { c.model.row(of: String($0)) })
            c.list.table.selectRowIndexes(rows, byExtendingSelection: false)
            c.window?.makeFirstResponder(c.list.table)
            out(["selected": c.list.selectedIDs, "states": c.list.selectedItems.map(\.state)])
        case "maincounts":              // what the sidebar and the menu-bar badge say
            let c = MainWindowController.shared
            MenuBadge.shared.refresh()
            out(["inbox": c.model.counts.inbox, "new": c.model.counts.new, "to_verify": c.model.counts.toVerify,
                 "active": c.model.counts.active, "badge": MenuBadge.shared.count, "subtitle": c.window?.subtitle ?? "",
                 "rows": c.model.rowCount, "projects": c.model.projects.map { "\($0.name)=\($0.inbox)" }])
        case "mainopen":                // mainopen PATH[|PATH…]: what the Open panel's OK / a folder drop does
            MainWindowController.shared.show()
            MainWindowController.shared.openFolders(arg.split(separator: "|").map { URL(fileURLWithPath: String($0)) })
        case "mainjob":                 // mainjob ID: the job's detail
            MainWindowController.shared.selectJob(arg)
            out(["job": arg, "found": JobStore.shared.job(arg) != nil])
        case "maindispatch":            // ⌘↩ on the selection (the concurrent-edit reminder may come up)
            MainWindowController.shared.handOffSelection()
        case "alertbutton":             // alertbutton N: answer the reminder sheet
            if let a = MainWindowController.shared.openAlert, let n = Int(arg), n < a.buttons.count { a.buttons[n].performClick(nil) }
            out(["answered": arg])
        case "mainreveal":              // mainreveal UID: what blurt://item/<uid> does in the main window
            MainWindowController.shared.reveal(uid: arg)
            out(["scope": MainWindowController.shared.model.scope.key, "selected": MainWindowController.shared.list.selectedIDs])
        case "mainclose":               // close the main window (then nothing may reopen it by itself)
            MainWindowController.shared.window?.performClose(nil)
            out(["visible": MainWindowController.shared.window?.isVisible ?? false])
        case "badge":                   // the menu-bar count and its tooltip
            MenuBadge.shared.refresh()
            out(["count": MenuBadge.shared.count, "tooltip": MenuBadge.shared.tooltip, "title": appDelegate?.statusItem?.button?.title ?? ""])
        case "mainsize":                // mainsize W H: the window's size (screenshots)
            let a = arg.split(separator: " ").compactMap { Double($0) }
            if a.count == 2, let w = MainWindowController.shared.window, let sc = w.screen?.visibleFrame {
                w.setFrame(NSRect(x: sc.midX - a[0] / 2, y: sc.midY - a[1] / 2, width: a[0], height: a[1]), display: true)
            }
        case "mainsplit":               // the three columns' frames and the table's columns
            let c = MainWindowController.shared
            out(["columns": c.split.splitViewItems.map { "\($0.viewController.view.frame)" },
                 "table": c.list.table.tableColumns.map { "\($0.identifier.rawValue)=\(Int($0.width))\($0.isHidden ? "h" : "")" }])
        case "mainviews":               // frames of the detail's views (layout checks)
            let d = MainWindowController.shared.detail
            func dump(_ v: NSView, _ depth: Int) -> [String] {
                guard depth < 4 else { return [] }
                return ["\(String(repeating: " ", count: depth))\(type(of: v)) \(v.frame) hidden=\(v.isHidden)"] + v.subviews.flatMap { dump($0, depth + 1) }
            }
            out(["views": dump(d.jobView, 0)])
        case "mainsearch":
            let c = MainWindowController.shared
            c.searchItem?.searchField.stringValue = arg
            c.model.text = arg
            c.model.reload()
            out(["rows": c.model.rowCount, "ms": c.model.lastReloadMS])
        case "mainproject":             // mainproject ID: its settings sheet
            MainWindowController.shared.projectSettings(arg)
        case "mainstate", "mainmove":   // mainstate ACTION (K3: keep, done, back, …) / mainmove PROJECT: on the selection
            let c = MainWindowController.shared
            if parts[0] == "mainstate" {
                if arg == "back" { c.act(key: "r") } else { c.apply(arg, to: c.list.selectedItems) }
            } else { c.move(uids: c.list.selectedItems.map(\.uid), to: arg) }
        case "mainringclick":           // mainringclick ROW: a click on that row's state ring (selects it, opens the state menu)
            let c = MainWindowController.shared
            let b = Int(arg).flatMap { c.list.ringView(row: $0) } as? NSButton
            out(["found": b != nil])
            DispatchQueue.main.async { b?.performClick(nil) }
        case "mainsearchkey", "mainlistkey":   // CHAR typed into the search field / the list, through NSApp (menus first)
            let c = MainWindowController.shared
            if parts[0] == "mainsearchkey" { c.focusSearch() } else { c.window?.makeFirstResponder(c.list.table) }
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: c.window?.windowNumber ?? 0, context: nil, characters: arg,
                                        charactersIgnoringModifiers: arg, isARepeat: false, keyCode: 2) {
                NSApp.sendEvent(e)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                out(["search": c.searchItem?.searchField.stringValue ?? "", "responder": "\(type(of: c.window?.firstResponder as Any))"])
            }
        case "mainkey":                 // mainkey CHAR: a key on the list (a d r w x s …), as typed
            let c = MainWindowController.shared
            c.window?.makeFirstResponder(c.list.table)
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: c.window?.windowNumber ?? 0,
                                        context: nil, characters: arg, charactersIgnoringModifiers: arg, isARepeat: false,
                                        keyCode: arg == "\u{7f}" ? 51 : 0) {
                // async: S opens a menu, which runs its own loop until it closes
                DispatchQueue.main.async { c.list.table.keyDown(with: e) }
            }
            out(["key": arg])
        case "mainfilter":              // mainfilter STATE|inbox|all: the State filter
            let c = MainWindowController.shared
            c.model.state = arg == "all" || arg.isEmpty ? nil : arg
            c.model.reload()
            out(["state": c.model.state ?? NSNull(), "rows": c.model.rowCount])
        case "mainpopup":               // mainpopup filter|context: open the State filter / the selection's context menu
            let c = MainWindowController.shared
            DispatchQueue.main.async {
                if arg == "filter" { c.list.bar.state.performClick(nil); return }
                guard let r = c.list.table.selectedRowIndexes.first, let m = c.contextMenu(for: c.list.table.selectedRowIndexes) else { return }
                let rect = c.list.table.rect(ofRow: r)
                m.popUp(positioning: nil, at: NSPoint(x: rect.minX + 160, y: rect.midY), in: c.list.table)
            }
        case "mainitemmenu":            // the menu bar's Item menu for the selection: titles, keys, enabled
            let c = MainWindowController.shared
            let m = NSApp.mainMenu?.items.first { $0.title == T("menu.item") }?.submenu
            m?.update()
            out(["items": m?.items.filter { !$0.isSeparatorItem }.map { "\($0.title) [\($0.keyEquivalent)]\($0.isEnabled ? "" : " (off)")" } ?? [],
                 "selected": c.list.selectedIDs.count])
        case "mainstatemenu":           // the state menu of the selection, as titles + subtitles (what the ring offers)
            let c = MainWindowController.shared
            let m = StateMenu.menu(for: c.list.selectedItems, canHandOff: true, selector: #selector(MainWindowController.mState(_:)), target: c)
            out(["items": m.items.filter { !$0.isSeparatorItem }.map { i -> String in
                if #available(macOS 14.4, *) { return "\(i.title) — \(i.subtitle ?? "")" }
                return i.title
            }])
        case "mainhandoff":             // mainhandoff instruction|full: copy for your own agent
            let c = MainWindowController.shared
            c.handOff(uids: c.list.selectedItems.map(\.uid), what: arg.isEmpty ? "instruction" : arg) { r in
                out(["text": r?["text"] ?? NSNull(), "clipboard": NSPasteboard.general.string(forType: .string) ?? ""])
            }
        case "mainmenu":                // mainmenu: the context menu of the selection, as titles (enabled ones)
            let c = MainWindowController.shared
            let m = c.contextMenu(for: c.list.table.selectedRowIndexes)
            m?.update()
            out(["items": m?.items.filter { !$0.isSeparatorItem }.map { "\($0.title)\($0.isEnabled ? "" : " (off)")" } ?? []])
        case "perfscopes":              // filter / search timings on the current index
            let c = MainWindowController.shared
            var res: [String: Double] = [:]
            for s in ["inbox", "progress", "unassigned", "all"] {
                c.go(Scope(key: s)!)
                let t0 = DispatchTime.now().uptimeNanoseconds
                c.model.reload()
                res[s] = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            }
            for q in ["login", "按钮", "ui"] {
                let t0 = DispatchTime.now().uptimeNanoseconds
                c.model.text = q
                c.model.reload()
                res["search:" + q] = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            }
            c.model.text = ""
            c.model.reload()
            out(["ms": res])
        case "perms":
            let p = Permissions()
            out(["screen": p.screen.rawValue, "mic": p.mic.rawValue, "accessibility": p.accessibility.rawValue,
                 "input_monitoring": p.inputMonitoring.rawValue])
        default: out(["error": "unknown command"])
        }
    }
}

/// Stands in for WP5's main window in tests: proves blurt://item/<uid> reaches MainWindowHosting.reveal(uid:).
final class StubMainWindow: MainWindowHosting {
    static let shared = StubMainWindow()
    func show() { emit(["event": "mainwindow", "call": "show"]) }
    func reveal(uid: String) {
        let it = IndexLookup.item(uid: uid)
        emit(["event": "mainwindow", "call": "reveal_uid", "uid": uid, "found": it != nil, "title": it?.title ?? "", "session": it?.sessionDir ?? ""])
    }
    func reveal(session: URL) { emit(["event": "mainwindow", "call": "reveal_session", "session": session.path]) }
    func reveal(job: String) { emit(["event": "mainwindow", "call": "reveal_job", "job": job]) }
    func reveal(project: String) { emit(["event": "mainwindow", "call": "reveal_project", "project": project]) }
    func showInbox() { emit(["event": "mainwindow", "call": "show_inbox"]) }
}
