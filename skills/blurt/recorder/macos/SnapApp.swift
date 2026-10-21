// Menu-bar app glue for snap mode: menu items, start-up, and (BLURT_TEST_COMMANDS=1 only) a distributed-notification
// command channel so scripted UI tests can drive the app without global hotkeys:
//   dev.blurt.recorder.command[.$BLURT_TEST_CHANNEL]  userInfo {"cmd": "record" | "snap" |"snapregion x,y,w,h" | "perch" |
//       "hide" | "process" | "commit" | "cancel" | "edit N" | "hatch DIR" | "hatched DIR ok|fail" | "stop" | "shortcuts" |
//       "menu" | "review DIR" | "processdir [AGENT ]DIR" | "toast TEXT"}

import AppKit
import Carbon.HIToolbox

var testMenu: NSMenu?

extension App {
    func startSnapMode() {
        switch ProcessInfo.processInfo.environment["BLURT_APPEARANCE"] {   // screenshots of both themes in tests
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        snapper.restore()
        snapper.syncCollector()
        guard ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1" else { return }
        let channel = ProcessInfo.processInfo.environment["BLURT_TEST_CHANNEL"].map { ".\($0)" } ?? ""
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.blurt.recorder.command" + channel), object: nil, queue: .main) { [weak self] n in
            guard let cmd = n.userInfo?["cmd"] as? String else { return }
            self?.testCommand(cmd)
        }
    }

    func testCommand(_ cmd: String) {
        let parts = cmd.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        emit(["event": "test_command", "cmd": cmd])
        switch parts.first ?? "" {
        case "snap": hotkey(.snap)                     // = ⌥⇧A: a still of the take while recording, else snap mode
        case "record": startRecording(useLast: true)   // = menu "录制上次的区域" (record.last_region), no picker
        case "snapregion":
            let p = arg.split(separator: ",").compactMap { Double($0) }
            guard p.count == 4 else { return }
            snapper.rememberFrontApp()
            snapper.capture(CGRect(x: p[0], y: p[1], width: p[2], height: p[3]))
        case "perch": perch.show(pinned: true)
        case "hide": perch.hide()
        case "process": snapper.processBatch()
        case "clear": snapper.clearBatch()
        case "commit": NoteBubble.shared.commit()
        case "cancel": NoteBubble.shared.cancel()
        case "edit":
            if let n = Int(arg), let s = snapper.batch?.live.first(where: { $0.n == n }) { NoteBubble.shared.begin(s, mode: .edit) }
        case "hatch": perch.hatch(id: arg, kinds: draftKinds(in: URL(fileURLWithPath: arg)))
        case "hatched":
            let a = arg.split(separator: " ").map(String.init)
            if let id = a.first { perch.hatched(id: id, ok: a.last == "ok") }
        case "notes": rec?.hud?.live?.openNotes()
        case "shortcuts": HotkeySettings.shared.show()
        case "raise", "lower":                          // review windows above everything for a screenshot, and back
            for w in ReviewHub.shared.windows {
                w.window?.level = parts[0] == "raise" ? .floating : .normal
                if parts[0] == "raise" { w.window?.orderFrontRegardless() }
            }
            if parts[0] == "raise" { HotkeySettings.shared.window?.orderFrontRegardless() }
        case "js":                                      // js CODE: run in the front review window (tests: switch views, open modals)
            ReviewHub.shared.windows.last?.web.evaluateJavaScript(arg) { r, e in emit(["event": "js", "result": "\(r ?? e ?? "")"]) }
        case "recordkey":                               // recordkey ACTION: click that recorder field
            HotkeySettings.shared.show()
            if let a = HotAction(rawValue: arg) { HotkeySettings.shared.fields[a]?.start() }
        case "presskey", "rkey":                        // presskey SPEC|esc|delete: a real key event through the app's queue,
                                                        // to the Shortcuts window (presskey) or the review window (rkey)
            guard let w = parts[0] == "rkey" ? ReviewHub.shared.windows.last?.window : HotkeySettings.shared.window else { return }
            if parts[0] == "rkey" {                     // key equivalents need us active with that window key
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
            }
            var code = 0, flags: NSEvent.ModifierFlags = []
            var chars = ""
            if arg == "esc" { code = 53 } else if arg == "delete" { code = 51 }
            else if let s = Shortcut.parse(arg) {
                code = s.code
                if s.key.count == 1 { chars = s.key.lowercased() }
                if s.mods & controlKey != 0 { flags.insert(.control) }
                if s.mods & optionKey != 0 { flags.insert(.option) }
                if s.mods & shiftKey != 0 { flags.insert(.shift) }
                if s.mods & cmdKey != 0 { flags.insert(.command) }
            } else if let s = hotkeyKeyTable.first(where: { $0.name == arg.uppercased() }) { code = s.code }   // no modifiers: refused
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: false, keyCode: UInt16(code)) {
                DispatchQueue.main.asyncAfter(deadline: .now() + (parts[0] == "rkey" ? 0.6 : 0)) { NSApp.postEvent(e, atStart: false) }
            }
        case "hotkeys":                                 // dump the state, for scripted checks
            emit(["event": "hotkeys", "keys": Dictionary(uniqueKeysWithValues: HotAction.allCases.map { ($0.rawValue, Hotkeys.shared.shortcut($0)?.spec ?? "off") }),
                  "states": Dictionary(uniqueKeysWithValues: HotAction.allCases.map { ($0.rawValue, Hotkeys.shared.states[$0].map { "\($0)" } ?? "") })])
        case "menu":                                    // menu [agents]: the ⌥⇧B menu, or just its agent submenu
            let m = NSMenu()
            menuNeedsUpdate(m)
            let target = arg == "agents" ? m.items.first(where: { $0.submenu?.items.contains { $0.action == #selector(mPreferAgent(_:)) } == true })?.submenu : m
            emit(["event": "menu", "items": target?.items.count ?? -1])
            if let t = target {
                if t !== m { m.removeAllItems() }        // a submenu can't pop up while attached
                testMenu = t
                // not from a GCD block: menu tracking would hold the main queue, and the statuses fill in through it.
                // Distributed notifications don't arrive while a menu tracks, so it closes itself after 8 s.
                let close = Timer(timeInterval: 8, repeats: false) { _ in t.cancelTracking() }
                RunLoop.main.add(close, forMode: .common)
                RunLoop.main.perform { t.popUp(positioning: nil, at: NSPoint(x: 900, y: 900), in: nil) }
            }
        case "closemenu": testMenu?.cancelTracking()
        case "review":                                  // review DIR: what the app does once items.json exists
            openReview(URL(fileURLWithPath: arg))
        case "processdir":                              // processdir [AGENT ]DIR
            let a = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if a.count == 2, AgentHub.shared.def(a[0]) != nil { process(URL(fileURLWithPath: a[1]), only: a[0]) } else { process(URL(fileURLWithPath: arg)) }
        case "toast": toast(arg.replacingOccurrences(of: "\\n", with: "\n"))
        case "gather": perch.gather(into: ["note", "note", "note"])
        case "cards":   // where things are, in global top-left points, so a test can point the mouse at them
            for s in snapper.batch?.live ?? [] {
                if let r = perch.cardScreenRect(s) { let c = toCG(r); emit(["event": "card", "n": s.n, "rect": [c.minX, c.minY, c.width, c.height]]) }
            }
            if let r = NoteBubble.shared.canvasScreenRect { let c = toCG(r); emit(["event": "canvas", "rect": [c.minX, c.minY, c.width, c.height]]) }
        default: command(cmd)
        }
    }

    func addSnapMenuItems(_ menu: NSMenu, recording: Bool) {
        @discardableResult
        func item(_ title: String, _ sel: Selector, on: Bool = false) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            it.state = on ? .on : .off
            menu.addItem(it)
            return it
        }
        if recording {
            menu.addItem(.separator())
            item(L("截图", "Snap"), #selector(mSnap)).showHotkey(.snap)
            item(L("实时字幕", "Live caption"), #selector(mLiveCaption), on: liveCaptionOn)
            return
        }
        item(L("截图", "Snap"), #selector(mSnap)).showHotkey(.snap)
        item(L("显示鸡舍", "Show the perch"), #selector(mShowPerch))
        item(L("收集系统截图（⌘⇧3/4/5）", "Collect system screenshots (⌘⇧3/4/5)"), #selector(mCollect), on: snapper.collecting)
    }

    @objc func mSnap() {
        if let r = rec { r.snap(via: "menu"); return }
        // the menu is still closing: let it go before the picker takes the screen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { snapper.hotkey() }
    }
    @objc func mShowPerch() { perch.show(pinned: true) }
    @objc func mCollect() {
        setRecordConfig("collect_system_shots", !snapper.collecting)
        snapper.syncCollector()
    }
    @objc func mLiveCaption() { setRecordConfig("live_caption", !liveCaptionOn) }
}
