// BLURT_TEST_COMMANDS=1 only: scripted checks for WP6, over a distributed notification like the shell's channel —
//   dev.blurt.recorder.wp6[.$BLURT_TEST_CHANNEL]  userInfo {"cmd": "…"}; every answer is one JSON line on stdout.
//   settings PANE[/ROW] | settingsscroll top|bottom|N | onboarding [STEP] | appearance dark|light | windowid settings|onboarding
//   settingssearch TEXT          type TEXT into Settings' search field → {"hits": [id…]} (settingssearch alone clears it)
//   settingskey down|up|return|esc   a key in that field: ↓ / ↑ walk the results, ↩ opens one, Esc clears
//   route URL                    parse a blurt:// URL (no action)         url URL   handle it like macOS would
//   mainopen PATH[|PATH…]       open folders as projects (the Open panel's OK)
//   mainstub                     a stand-in main window that reports reveal(uid:) / reveal(session:) (until WP5 lands)
//   spotlight-index              index now → {"count"}                    spotlight-search TEXT → {"found": [uid…]}
//   spotlight-clear              remove our domain's entries
//   service TEXT                 "Add to Blurt" with TEXT on a private pasteboard, through the real service method
//   fix UIDS                     the dispatch panel for those items (agent, mode, worktree)
//   peck TITLE | peckframes DIR [dark] | mascotcheck | perms
//   menuglyph DIR                the menu-bar chick: the template glyph (rest / listen / hop; 1x / 2x) and the real
//                                status button with a count of 3 (aqua / dark; rest / open) as PNGs
//   design system v2 moments (screenshots, no real work behind them):
//   onboardingdone               Done on the onboarding's last step: it closes
//   onboardingtest step N|setup|download|small|retry|reload|login on|off|done|state   the assistant's buttons → onboarding_state
//   network [online|offline|real] as if the Mac just came back online (NetworkWatch's handlers run) / reads offline
//   mainempty KIND               one main-window empty state (ItemListController.testEmpty: first | inbox_zero | …)
//   mainfakejob process|route|record [SESSION] | done | clear   a running job in the list's jobs section (the AI-working
//                                hairline on process / route; SESSION: the "organising" banner over that batch's items)
//   dictationworking ID|off      the Dictation page's "Make Item" for ID as if the AI were writing it (the spinner)
//   toastdone TEXT               the small toast with the done check (ok)
//   mainbundle [PATH.zip|cancel] Export Hand-off Bundle… on the selection (PATH: bundling + the action's state at once,
//                            then the result): its Save sheet (suggested name back), or
//                                written straight to PATH (no panel); cancel closes the sheet
//   mainsuggest [moveall P | move ROW]   Unassigned's suggestion groups and rows ("Looks like X · Move"), pressing one
//   mainmovepop [open | QUERY | return | esc]   M on the list: the Move popover, typing into it, choosing
//   layoutcheck [min|restore|dump]   the layout lint: every visible window's controls and texts inside the window, not
//                                on top of each other, not truncated → {"event": "layoutcheck", "windows": [{"title",
//                                "size", "problems": [{"kind", "role", "label", "frame", "bounds"}]}]} (LayoutCheck.swift)
import AppKit
import Carbon.HIToolbox
import BlurtCore

enum SelfTests {
    /// The jobs `mainfakejob` started (finished by `mainfakejob done|clear`).
    @MainActor static var fakeJobs: [JobWriter] = []
    /// `storagetrash`: the Storage model whose last Move to Trash `storagetrash undo` takes back
    @MainActor static var storage: StorageModel?
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
        case "settingssearch":
            SettingsController.shared.show(pane: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                SettingsController.shared.testSearch(arg)
                out(["query": SettingsNavigator.shared.query, "hits": SettingsNavigator.shared.hits.map(\.entry.id)])
            }
        case "settingskey":
            let nav = SettingsNavigator.shared
            switch arg {
            case "down": nav.moveSelection(1)
            case "up": nav.moveSelection(-1)
            case "return": nav.openSelected()
            default: SettingsController.shared.testSearch("")
            }
            out(["selected": nav.selected, "pane": nav.pane.rawValue, "query": nav.query])
        case "onboarding":Onboarding.shared.show(step: Int(arg) ?? 0)
        case "onboardingdone": Onboarding.shared.testDone()
        case "onboardingtest": Onboarding.shared.testCommand(arg)
        case "network": NetworkWatch.shared.testCommand(arg)
        case "mainempty":
            let c = MainWindowController.shared
            c.show()
            c.list.testEmpty(arg)
            out(["empty": arg])
        case "mainfakejob":
            let a = arg.split(separator: " ", maxSplits: 1).map(String.init)
            switch a.first ?? "process" {
            case "done": fakeJobs.forEach { $0.finish(.done) }; fakeJobs = []
            case "clear": fakeJobs.forEach { $0.finish(.cancelled) }; fakeJobs = []
            default:
                let type = JobType(rawValue: a.first ?? "process") ?? .process
                let j = JobWriter(type: type, project: ProjectStore.shared.currentID, session: a.count > 1 ? URL(fileURLWithPath: a[1]) : nil,
                                  title: "Test \(type.rawValue)")
                if let first = jobSteps[type]?.first { j.step(first, .running, progress: 0.4) }
                fakeJobs.append(j)
                out(["job": j.id])
            }
        case "dictationworking":
            let m = MainWindowController.shared.dictation.model
            if arg == "off" || arg.isEmpty { m.working = [] } else { m.working.insert(arg == "first" ? m.entries.first?.id ?? "" : arg) }
            out(["working": Array(m.working)])
        case "toastdone": appDelegate?.toast(arg.isEmpty ? T("app.toast.saved", Loc.duration(42)) : arg, icon: .check)
        case "appearance": NSApp.appearance = NSAppearance(named: arg == "dark" ? .darkAqua : .aqua)
        case "windowid":
            let n: Int? = arg == "onboarding" ? Onboarding.shared.windowNumber : arg == "fix" || arg == "dispatch" ? MainActor.assumeIsolated { DispatchPanel.windowNumber }
                        : SettingsController.shared.windowNumber
            out(["window": n ?? -1])
        case "route": out(["route": URL(string: arg).map { "\(URLRouter.route($0))" } ?? "bad url"])
        case "url":                     // url URL: as if it came from outside (the shell's record / snap included)
            if let u = URL(string: arg) {
                let handled = URLRouter.handle(u)
                if !handled { appDelegate?.application(NSApp, open: [u]) }
                out(["handled": handled])
            }
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
                    let m = HotkeySettings.shared
                    out(["action": act.rawValue, "now": Hotkeys.shared.shortcut(act)?.spec ?? "off",
                         "config": (Config.shared["record.hotkeys"] as? [String: Any])?[act.rawValue] ?? NSNull(),
                         "state": "\(Hotkeys.shared.states[act].map { "\($0)" } ?? "")",
                         "refused": m.refusals[act] ?? NSNull(), "note": m.note(act)?.text ?? NSNull(),
                         "asking": m.asking?.messageText ?? NSNull()])
                    if f.recording { f.stop() }
                }
            }
        case "storagetrash":            // storagetrash REL: Settings → Storage's Move to Trash on $BLURT_HOME/REL; storagetrash undo
            MainActor.assumeIsolated {
                if arg == "undo" { SelfTests.storage?.lastTrash?(); out(["undo": true]); return }
                let m = StorageModel()
                SelfTests.storage = m
                let u = BlurtPaths.home.appendingPathComponent(arg)
                m.trash([u], name: arg, window: NSApp.keyWindow)
                out(["trashing": u.path])
            }
        case "shortcutswap":            // shortcutswap yes|no: answer the "already used" question; undo: ⌘Z's undo
            let m = HotkeySettings.shared
            if arg == "undo" { m.fields.values.first?.window?.undoManager?.undo() } else { m.testAnswerSwap(arg == "yes") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                out(["hotkeys": Dictionary(uniqueKeysWithValues: HotAction.allCases.map { ($0.rawValue, Hotkeys.shared.shortcut($0)?.spec ?? "off") }),
                     "states": Dictionary(uniqueKeysWithValues: HotAction.allCases.map { ($0.rawValue, "\(Hotkeys.shared.state($0))") }),
                     "asking": m.asking?.messageText ?? NSNull()])
            }
        case "fix":
            let uids = (arg.split(separator: " ").first ?? "").split(separator: ",").map(String.init)
            if !uids.isEmpty { MainActor.assumeIsolated { DispatchPanel.show(items: uids) } }
            out(["uids": uids])
        case "peck": PeckCard.shared.leadIn = 1.6; PeckCard.shared.play(title: arg.isEmpty ? "Login button does nothing" : arg, detail: T("main.misc.by_codex"), uid: "test")
        case "peckframes":
            let a = arg.split(separator: " ").map(String.init)
            out(["frames": PeckCard.renderFrames(to: URL(fileURLWithPath: a.first ?? "/tmp/peck"), dark: a.contains("dark"))])
        case "mascotcheck":             // the mascot's clips: one-shots end at rest, loops join up (MascotArt.check)
            out(["problems": MascotArt.check()])
        case "menuglyph":              // menuglyph DIR: the menu-bar chick as the status item draws it, as PNGs
            out(["files": MenuGlyph.renderPoses(to: URL(fileURLWithPath: arg.isEmpty ? "/tmp/menuglyph" : arg))])
        case "install":                 // install ID: the dry-run preview (sheet in Settings → Agents); install-apply: confirm it
            SettingsController.shared.show(pane: "agents")
            Task { @MainActor in
                await AgentsModel.shared.load(login: false)
                if let a = AgentsModel.shared.rows.first(where: { $0.id == arg }) { await AgentsModel.shared.preview(a) }
                out(["previewed": AgentsModel.shared.plan != nil, "env_home": Agents.shared.installEnvironment()["HOME"] ?? "",
                     "codex_home": Agents.shared.installEnvironment()["CODEX_HOME"] ?? ""])
            }
        case "agents":                  // agents toggle ID on|off | up ID | processing ID [recording|cards] MODEL [EFFORT] | state: Settings → Agents
            let a = arg.split(separator: " ").map(String.init)
            Task { @MainActor in
                let m = AgentsModel.shared
                if m.rows.isEmpty { await m.load(login: false) }
                switch a.first ?? "state" {
                case "toggle" where a.count == 3: m.toggle(a[1], a[2] == "on")
                case "up" where a.count == 2: m.moveUp(a[1])
                case "processing" where a.count >= 3:
                    // processing AGENT [recording|cards] MODEL [EFFORT] (no kind: cards)
                    let kind = ProcessingKind(rawValue: a[2])
                    let rest = Array(a.dropFirst(kind == nil ? 2 : 3))
                    if let model = rest.first {
                        m.setProcessing(a[1], kind ?? .cards, model: model, effort: rest.count > 1 ? rest[1] : nil)
                    }
                default: break
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)      // save() reloads
                out(["shown": m.headless.map { "\($0.id)\(m.enabled.contains($0.id) ? "" : " (off)")" },
                     "config": Config.shared["record.agents"] ?? NSNull(),
                     "processing": Config.shared["record.agent_processing"] ?? NSNull(), "pick": m.pick ?? NSNull()])
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
        case "mainfront":               // mainfront on | off: the window above others without activating (screenshots
                                        // of a popover, whose blur shows what is behind it), then back behind them
            if let w = MainWindowController.shared.window { arg == "off" ? w.orderBack(nil) : w.orderFrontRegardless() }
        case "mainsplit":               // the three columns' frames and the table's columns
            let c = MainWindowController.shared
            out(["columns": c.split.splitViewItems.map { "\($0.viewController.view.frame)" },
                 "table": c.list.table.tableColumns.map { "\($0.identifier.rawValue)=\(Int($0.width))\($0.isHidden ? "h" : "")" }])
        case "mainselection":           // the several-selected detail: title, summary, buttons, ⋯ menu, rows; "click ID" presses one
            let d = MainWindowController.shared.detail
            if arg.hasPrefix("click ") {
                let id = String(arg.dropFirst(6))
                d.selection.button(id)?.performClick(nil)
            }
            out(["shown": d.showsSelection].merging(d.selection.testDescription) { a, _ in a })
        case "mainviews":               // frames of the detail's views (layout checks)
            let d = MainWindowController.shared.detail
            func dump(_ v: NSView, _ depth: Int) -> [String] {
                guard depth < 4 else { return [] }
                return ["\(String(repeating: " ", count: depth))\(type(of: v)) \(v.frame) hidden=\(v.isHidden)"] + v.subviews.flatMap { dump($0, depth + 1) }
            }
            out(["views": dump(d.jobView, 0)])
        case "mainrename":              // mainrename [TEXT | esc | -]: the row title being renamed in place: its state, or
            let c = MainWindowController.shared   // TEXT typed then Return, Esc, "-" an empty title then Return
            if let r = c.list.renaming, let tv = r.cell.editField.currentEditor() as? NSTextView {
                switch arg {
                case "": break
                case "esc": _ = r.control(r.cell.editField, textView: tv, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
                default:
                    tv.string = arg == "-" ? "" : arg
                    r.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
                    _ = r.control(r.cell.editField, textView: tv, doCommandBy: #selector(NSResponder.insertNewline(_:)))
                }
            }
            out(["renaming": c.list.renaming != nil, "field": c.list.renaming?.cell.editField.stringValue ?? NSNull(),
                 "responder": "\(type(of: c.window?.firstResponder as Any))", "selected": c.list.selectedIDs])
        case "mainprojects":            // mainprojects [rename ID NAME | order ID,ID… | remove ID]: the sidebar's projects
            let c = MainWindowController.shared
            let w = arg.split(separator: " ", maxSplits: 2).map(String.init)
            switch w.first ?? "" {
            case "rename" where w.count == 3:
                c.sidebar.select(.project(w[1]))
                c.window?.makeFirstResponder(c.sidebar.outline)
                if c.sidebar.renameSelected(), let r = c.sidebar.renaming, let tv = r.cell.editField.currentEditor() as? NSTextView {
                    tv.string = w[2]
                    _ = r.control(r.cell.editField, textView: tv, doCommandBy: #selector(NSResponder.insertNewline(_:)))
                }
            case "order" where w.count == 2: c.reorderProjects(w[1].split(separator: ",").map(String.init))
            case "remove" where w.count == 2: c.removeProject(w[1])
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                out(["projects": c.model.projects.map { "\($0.name) \($0.key)" }, "go": c.shortcutProjects.map(\.name),
                     "undo": c.window?.undoManager?.undoMenuItemTitle ?? ""])
            }
        case "mainshortcuts":           // mainshortcuts [QUERY | @end]: the ? panel, kept up for a screenshot of a build launched in
            let c = MainWindowController.shared   // the background; QUERY is typed into its search field
            if ShortcutsSheet.panel?.isVisible != true { c.showShortcuts() }
            ShortcutsSheet.panel?.hidesOnDeactivate = false
            ShortcutsSheet.panel?.orderFrontRegardless()
            if let p = ShortcutsSheet.panel {
                if arg == "@end" { p.scrollToEnd() } else {
                    p.field.stringValue = arg
                    p.field.currentEditor()?.selectedRange = NSRange(location: (arg as NSString).length, length: 0)
                    p.search(arg)
                }
            }
            out(["shown": ShortcutsSheet.panel?.isVisible ?? false, "title": ShortcutsSheet.panel?.title ?? "",
                 "size": ShortcutsSheet.panel.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? ""])
        case "mainjs":                  // mainjs EXPR: run EXPR in the detail page (as the page's own UI would), its value back
            MainWindowController.shared.detail.web.evaluateJavaScript("JSON.stringify((() => { return \(arg); })())") { r, e in
                out(["value": (r as? String) ?? NSNull(), "error": e.map { "\($0)" } ?? NSNull()])
            }
        case "maindetail":              // the item the detail page shows (uid, id, title) — never another than the selected one
            let c = MainWindowController.shared
            let js = "(() => { const s = window.blurtReview && window.blurtReview.store; const i = s && s.item;"
                + " return JSON.stringify({uid: i ? i.uid : null, id: i ? i.id : null, title: i ? i.title : null, missing: s ? s.missing : null,"
                + " loaded: s ? s.loaded : false}); })()"
            c.detail.web.evaluateJavaScript(js) { r, e in
                out(["page": (r as? String) ?? "\(e.map { "\($0)" } ?? "nil")", "selected": c.list.selectedIDs,
                     "shown": c.detail.currentItem?.uid ?? NSNull(), "job": c.shownJob ?? NSNull()])
            }
        case "mainsearch":
            let c = MainWindowController.shared
            c.searchItem?.searchField.stringValue = arg
            c.model.text = arg
            c.model.reload()
            c.list.updateEmpty()
            out(["rows": c.model.rowCount, "ms": c.model.lastReloadMS,
                 "empty": c.list.empty.isHidden ? NSNull() : (c.list.empty.accessibilityLabel() ?? "") as Any])
        case "mainproject":             // mainproject ID: its settings sheet
            MainWindowController.shared.projectSettings(arg)
        case "mainprojectset":          // mainprojectset key|description VALUE: type into the open settings sheet
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            out(ProjectSettingsSheet.testSet(f.first ?? "", f.count > 1 ? f[1] : ""))
        case "mainstate", "mainmove":   // mainstate ACTION (K3: keep, done, back, …) / mainmove PROJECT: on the selection
            let c = MainWindowController.shared
            if parts[0] == "mainstate" {
                if arg == "back" { c.act(key: "r") } else { c.apply(arg, to: c.list.selectedItems) }
            } else { c.move(uids: c.list.selectedItems.map(\.uid), to: arg) }
        case "mainundo", "mainredo":    // ⌘Z / ⇧⌘Z in the main window (the state actions register their undo)
            let um = MainWindowController.shared.window?.undoManager
            if parts[0] == "mainundo" { if um?.canUndo == true { um?.undo() } } else if um?.canRedo == true { um?.redo() }
            out(["can_undo": um?.canUndo ?? false, "can_redo": um?.canRedo ?? false,
                 "undo_title": um?.undoMenuItemTitle ?? "", "redo_title": um?.redoMenuItemTitle ?? ""])
        case "mainpalette":             // mainpalette [QUERY | down | up | close]: ⌘K, typing, ↓ / ↑ — the rows after it
            let pal = MainWindowController.shared.palette
            switch arg {
            case "down": pal.step(1)
            case "up": pal.step(-1)
            case "close": pal.close()
            default:
                if !pal.isOpen { pal.open() }
                pal.setQuery(arg)
            }
            // rows as shown: "# Section" for a header; selected = the chosen row's title
            let shown: [String] = pal.rows.prefix(16).map {
                switch $0 {
                case .header(let s, _): return "# \(s)"
                case .note(let s): return "~ \(s)"
                case .entry(let e): return e.kind == .item ? "\(e.itemID) \(e.title)" : e.title
                }
            }
            let k = pal.table.selectedRow
            var chosen = ""
            if k >= 0, k < pal.rows.count, case .entry(let e) = pal.rows[k] { chosen = e.title }
            out(["open": pal.isOpen, "selected": k, "chosen": chosen, "scope": pal.scope.map(\.itemID),
                 "rows": shown, "count": pal.entries.count])
        case "maindrag":                // maindrag ROW: what dragging that row out carries (Finder, Terminal, a project)
            let c = MainWindowController.shared
            let w = Int(arg).flatMap { c.list.tableView(c.list.table, pasteboardWriterForRow: $0) } as? NSPasteboardItem
            out(["types": w?.types.map(\.rawValue) ?? [], "file": w?.string(forType: .fileURL) ?? NSNull()])
        case "mainringclick":           // mainringclick ROW [front]: a click on that row's state ring (selects it, opens the
                                        // state menu); front: the window key first, as after a real click (screenshots)
            let c = MainWindowController.shared
            let a = arg.split(separator: " ").map(String.init)
            if a.contains("front") { NSApp.activate(ignoringOtherApps: true); c.window?.makeKeyAndOrderFront(nil) }
            let b = a.first.flatMap(Int.init).flatMap { c.list.ringView(row: $0) } as? NSButton
            out(["found": b != nil, "ring": b.map { "\($0.convert($0.bounds, to: nil))" } ?? ""])
            DispatchQueue.main.asyncAfter(deadline: .now() + (a.contains("front") ? 0.3 : 0)) { b?.performClick(nil) }
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
                                        keyCode: arg == "\u{7f}" ? 51 : arg == "\r" ? 36 : 0) {
                // async: S opens a menu, which runs its own loop until it closes
                DispatchQueue.main.async { c.list.table.keyDown(with: e) }
            }
            out(["key": arg])
        case "mainsuggest":             // mainsuggest [moveall PROJECT | move ROW]: Unassigned's suggestions — the groups
                                        // above the list and each row's "Looks like X · Move" (pressing one)
            let c = MainWindowController.shared
            let a = arg.split(separator: " ").map(String.init)
            let t = c.list.table
            let col = t.tableColumns.firstIndex { $0.identifier.rawValue == "title" } ?? 1
            func chip(_ r: Int) -> SuggestChip? {
                (t.view(atColumn: col, row: r, makeIfNecessary: true) as? TitleCell).flatMap { $0.suggest.isHidden ? nil : $0.suggest }
            }
            if a.first == "moveall", a.count == 2, let g = c.list.suggestions.groups.first(where: { $0.project == a[1] }) {
                c.move(uids: g.uids, to: g.project)
            } else if a.first == "move", a.count == 2, let r = Int(a[1]) {
                chip(r)?.performClick(nil)
            }
            let rows = (0..<min(t.numberOfRows, 40)).map { r -> String in
                let it = c.model.item(at: r)
                return "\(it?.itemID ?? "?") \(it?.title ?? "")" + (chip(r).map { " -> " + $0.attributedTitle.string } ?? "")
            }
            out(["groups": c.list.suggestions.groups.map { "\($0.project)=\($0.uids.count)" }, "banner": !c.list.suggestions.isHidden,
                 "rows": rows])
        case "mainmovepop":             // mainmovepop [open | QUERY | return | esc | close]: M on the list and its popover
            let c = MainWindowController.shared
            switch arg {
            case "", "open": c.window?.makeFirstResponder(c.list.table); c.pickProject()
            case "return": c.movePopover?.testPick()
            case "esc", "close": c.movePopover?.close()
            default: c.movePopover?.type(arg)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                out(["open": c.movePopover != nil, "shown": c.movePopover?.shownIDs ?? [], "selected": c.movePopover?.selectedID ?? ""])
            }
        case "mainchord":               // mainchord cmd+delete: ⌘⌫ on the list, through NSApp (the menus get it first)
            let c = MainWindowController.shared
            c.window?.makeFirstResponder(c.list.table)
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: c.window?.windowNumber ?? 0, context: nil, characters: "\u{7f}",
                                        charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51) {
                NSApp.sendEvent(e)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                out(["scope": c.model.scope.key, "projects": c.model.projects.filter(\.registered).map(\.name),
                     "undo": c.window?.undoManager?.undoMenuItemTitle ?? ""])
            }
        case "mainbanner":              // mainbanner captures|taken N: show that banner with N (no cards needed), for the ↑ walk
            let c = MainWindowController.shared
            let w = arg.split(separator: " ").map(String.init)
            let n = w.count > 1 ? Int(w[1]) ?? 0 : 0
            if w.first == "captures" { c.list.captures.set(count: n) } else { c.list.taken.set(count: n) }
            out(["captures": !c.list.captures.isHidden, "taken": !c.list.taken.isHidden])
        case "mainresponder":           // the main window's first responder (the list, the detail page, the sidebar…)
            let c = MainWindowController.shared
            out(["responder": c.window?.firstResponder.map { "\(type(of: $0))" } ?? "nil", "selected": c.list.selectedIDs,
                 "banner": c.focusedBanner ?? NSNull(), "job": c.shownJob ?? NSNull()])
        case "mainkinds":               // mainkinds issue,idea|all: the Filter menu's kinds
            let c = MainWindowController.shared
            c.model.kinds = arg == "all" || arg.isEmpty ? [] : Set(arg.split(separator: ",").map(String.init))
            c.list.filtersChanged()
            out(["kinds": c.model.kinds.sorted(), "rows": c.model.rowCount, "line": FilterBar.describe(c.model) ?? NSNull()])
        case "mainfilter":              // mainfilter STATE|inbox|all: the State filter
            let c = MainWindowController.shared
            c.model.state = arg == "all" || arg.isEmpty ? nil : arg
            c.model.reload()
            out(["state": c.model.state ?? NSNull(), "rows": c.model.rowCount])
        case "mainpopup":               // mainpopup filter|context: open the toolbar's Filter menu / the selection's context menu
            let c = MainWindowController.shared
            DispatchQueue.main.async {
                if arg == "filter" { c.showFilterMenu(); return }
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
        case "mainreviewbatch":         // = the context menu's "Review the Whole Batch" on the selection
            MainWindowController.shared.mReviewBatch()
            out(["mode": MainWindowController.shared.detail.web?.url?.query ?? ""])
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
        case "mainbundle":              // mainbundle [PATH.zip | cancel]: Export Hand-off Bundle… on the selection —
                                        // no PATH: its Save sheet (the suggested name back); PATH: written there, no panel
            let c = MainWindowController.shared
            if arg == "cancel" {
                if let p = c.bundlePanel, let w = c.window, let s = w.attachedSheet, s === p { w.endSheet(p, returnCode: .cancel) }
                c.bundlePanel = nil
                return out(["cancelled": true])
            }
            if arg.isEmpty {
                c.exportBundle(uids: c.list.selectedItems.map(\.uid)) { u in out(["path": u?.path ?? NSNull(), "via": "panel"]) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    out(["panel": c.bundlePanel?.nameFieldStringValue ?? NSNull(), "message": c.bundlePanel?.message ?? "",
                         "sheet": c.window?.attachedSheet != nil])
                }
                return
            }
            c.exportBundle(uids: c.list.selectedItems.map(\.uid), to: URL(fileURLWithPath: arg)) { u in
                out(["path": u?.path ?? NSNull(), "exists": u.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                     "bundling": c.bundling])
            }
            // while it packs: the action is off (one bundle at a time) and the island says so
            let probe = NSMenuItem(title: "", action: #selector(MainWindowController.mExportBundle), keyEquivalent: "")
            out(["bundling": c.bundling, "action_enabled": c.validateMenuItem(probe)])
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
        case "perfscroll":              // perfscroll [STEP]: page through the whole list, drawing each screenful
            let c = MainWindowController.shared
            let step = max(1, Int(arg) ?? 30)
            var worst = 0.0, total = 0.0, n = 0
            for r in stride(from: 0, to: c.model.rowCount, by: step) {
                let t0 = DispatchTime.now().uptimeNanoseconds
                c.list.table.scrollRowToVisible(r)
                c.list.table.displayIfNeeded()
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                worst = max(worst, ms); total += ms; n += 1
            }
            out(["rows": c.model.rowCount, "steps": n, "avg_ms": n > 0 ? total / Double(n) : 0, "worst_ms": worst])
        case "layoutcheck":             // layoutcheck [min|restore|dump]: the layout lint over every visible window
            LayoutCheck.run(arg)        // (LayoutCheck.swift) → {"event": "layoutcheck", "windows": [...]}
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
    func reveal(session: URL) -> Bool { emit(["event": "mainwindow", "call": "reveal_session", "session": session.path]); return true }
    func reveal(job: String) { emit(["event": "mainwindow", "call": "reveal_job", "job": job]) }
    func reveal(project: String) { emit(["event": "mainwindow", "call": "reveal_project", "project": project]) }
    func showInbox() { emit(["event": "mainwindow", "call": "show_inbox"]) }
}
