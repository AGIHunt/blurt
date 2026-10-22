// Menu-bar app glue for captures (K7): menu items, the voice / project hotkeys, start-up, and (BLURT_TEST_COMMANDS=1
// only) a distributed-notification command channel so scripted UI tests can drive the app without global hotkeys:
//   dev.blurt.recorder.command[.$BLURT_TEST_CHANNEL]  userInfo {"cmd": …}
//     record · snap · snapregion x,y,w,h · commit · cancel · edit N · notes · stop · shortcuts · menu · toast TEXT …
//     cards [show|hide]       the claws down / up; every card's rect as "card" events (global top-left points)
//     island open|close|switcher|frame   open / close the island, ⌥⇧O, or report its frame ("island" event)
//     voice down|up|tap       ⌥⇧V pressed / released (a tap = down + up)
//     assign N PROJECT|inbox  = dropping card N (of the inbox's batches) on that target · aisort · deleteall
//     project ID|auto         switch the current project · hatch DIR · hatched DIR ok|fail (v0.6 AgentHub calls)
//     peck [to_verify|done] TITLE   the completion chicken · axcards  the cards' accessibility elements ("ax" event)
//     menuicon DIR            renders the menu-bar template offscreen on light and dark menu bars, 1x and 2x

import AppKit
import Carbon.HIToolbox
import WebKit
import BlurtCore

var testMenu: NSMenu?

extension App {
    func startSnapMode() {
        switch ProcessInfo.processInfo.environment["BLURT_APPEARANCE"] {   // screenshots of both themes in tests
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
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
        case "snapregion":                              // snapregion x,y,w,h [PNG] [quiet]: PNG stands in for the screen; quiet = no note
            let a = arg.split(separator: " ").map(String.init)
            if a.count > 1 { setenv("BLURT_TEST_STILL", a[1], 1) }
            let p = (a.first ?? "").split(separator: ",").compactMap { Double($0) }
            guard p.count == 4 else { return }
            snapper.rememberFrontApp()
            snapper.capture(CGRect(x: p[0], y: p[1], width: p[2], height: p[3]), withNote: !a.contains("quiet"))
        case "cards":
            if arg == "show" { claws.show(peek: 8) }
            emit(["event": "swing", "degrees": claws.swing.map { Double(($0 * 100).rounded() / 100) }])
            emit(["event": "cards", "captures": snapper.cards.map { "\($0.n)@\(ObjectIdentifier($0).hashValue % 10000)/\(ObjectIdentifier($0.batch!).hashValue % 10000)" }])
            for (s, r) in claws.cardRects() { emit(["event": "card", "n": s.n, "session": s.batch?.dir.path ?? "", "rect": [r.minX, r.minY, r.width, r.height]]) }
            if let r = NoteBubble.shared.canvasScreenRect { let c = toCG(r); emit(["event": "canvas", "rect": [c.minX, c.minY, c.width, c.height]]) }
        case "island":
            switch arg {
            case "open": island.setOpen(true, sticky: true)
            case "close": island.setOpen(false); island.closeSwitcher()
            case "switcher": island.showSwitcher()
            default: break
            }
            let f = toCG(island.frameOnScreen)
            emit(["event": "island", "rect": [f.minX, f.minY, f.width, f.height], "open": island.open, "cards": claws.count])
        case "voice":
            if arg != "up" { Hotkeys.shared.simulate(.voice, released: false) }
            if arg == "tap" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { Hotkeys.shared.simulate(.voice, released: true) } }
            if arg == "up" { Hotkeys.shared.simulate(.voice, released: true) }
        case "assign":
            let a = arg.split(separator: " ").map(String.init)
            if a.count == 2, let n = Int(a[0]), let s = snapper.cards.first(where: { $0.n == n }) { snapper.assign(s, to: a[1]) }
        case "framerec": FrameCapture.start(arg)      // framerec DIR SECS X,Y,W,H [BACKDROP|-] [FPS] [cursor]
        case "henframes":                               // henframes DIR pleased|delighted|neutral [dark]
            let a = arg.split(separator: " ").map(String.init)
            guard let d = a.first else { return }
            let n = PeckCard.renderFrames(to: URL(fileURLWithPath: d), scale: 3, dark: a.contains("dark"), mood: HenMood(rawValue: a.count > 1 ? a[1] : "") ?? .pleased)
            emit(["event": "henframes", "frames": n])
        case "fakerecording":                           // fakerecording [stop]: the island's recording state without a capture stream
            if arg == "stop" { rec = nil; island.recordingStopping(); return }
            let r = Recorder(region: CGRect(x: 360, y: 260, width: 900, height: 560))
            rec = r
            r.sessionStart = hostNow()
            opts.out = snapper.openBatch(for: ProjectStore.shared.inbox).dir.deletingLastPathComponent().appendingPathComponent("fake-rec/recording.mp4").path
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: opts.out).deletingLastPathComponent(), withIntermediateDirectories: true)
            r.snaps = RecordingSnaps(rec: r, session: URL(fileURLWithPath: opts.out).deletingLastPathComponent())
            island.recordingStarted(r, on: NSScreen.main)
        case "aisort": snapper.aiSort()
        case "deleteall": snapper.deleteAllCards()
        case "project":
            Task { try? await ProjectStore.shared.use(arg == "auto" ? nil : arg); await MainActor.run { island.projectChanged() } }
        case "commit": NoteBubble.shared.commit()
        case "cancel": NoteBubble.shared.cancel()
        case "edit":
            if let n = Int(arg), let s = snapper.cards.first(where: { $0.n == n }) { NoteBubble.shared.begin(s, mode: .edit) }
        case "hatch": perch.hatch(id: arg, kinds: [])
        case "hatched":
            let a = arg.split(separator: " ").map(String.init)
            if let id = a.first { perch.hatched(id: id, ok: a.last == "ok") }
        case "peck":
            let a = arg.split(separator: " ", maxSplits: 1).map(String.init)
            let state = ["to_verify", "done"].contains(a.first ?? "") ? a[0] : "to_verify"
            let title = a.count > 1 || !["to_verify", "done"].contains(a.first ?? "") ? (a.last ?? "") : "Login button does nothing"
            PeckCard.shared.play(title: title, detail: "", uid: "test", state: state)
        case "notes": island.openRecordingNotes()
        case "shortcuts": HotkeySettings.shared.show()
        case "raise", "lower":                          // the main window above everything for a screenshot, and back
            if let w = MainWindowController.shared.window {
                w.level = parts[0] == "raise" ? .floating : .normal
                if parts[0] == "raise" { w.orderFrontRegardless() }
            }
            if parts[0] == "raise" { HotkeySettings.shared.window?.orderFrontRegardless() }
        case "js":                                      // js CODE: run in the main window's review canvas
            MainWindowController.shared.detail.web?.evaluateJavaScript(arg) { r, e in emit(["event": "js", "result": "\(r ?? e ?? "")"]) }
        case "webjs":                                   // webjs CODE: run in every blurt-app:// canvas (main window detail)
            func webViews(_ v: NSView) -> [WKWebView] { (v as? WKWebView).map { [$0] } ?? v.subviews.flatMap(webViews) }
            for w in NSApp.windows { for wv in webViews(w.contentView ?? NSView()) where wv.url?.scheme == "blurt-app" {
                wv.evaluateJavaScript(arg) { r, e in emit(["event": "webjs", "window": w.windowNumber, "result": "\(r ?? e ?? "")"]) }
            } }
        case "recordkey":                               // recordkey ACTION: click that recorder field
            HotkeySettings.shared.show()
            if let a = HotAction(rawValue: arg) { HotkeySettings.shared.fields[a]?.start() }
        case "presskey", "rkey":                        // presskey SPEC|esc|delete: a real key event through the app's queue,
                                                        // to the Shortcuts window (presskey) or the main window (rkey)
            guard let w = parts[0] == "rkey" ? MainWindowController.shared.window : HotkeySettings.shared.window else { return }
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
        case "checkupdates":                            // [probe]: = menu "Check for Updates…"; probe = no UI, emits update_probe
            emit(["event": "updater", "available": Updater.shared.available, "can_check": Updater.shared.canCheck])
            if arg == "probe" { Updater.shared.probe() } else if arg == "silent" { Updater.shared.silentUpdate() } else { Updater.shared.checkForUpdates(nil) }
        case "sethotkey":                             // sethotkey ACTION SPEC|off: HotkeyCenter.set, emits the result
            let a = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard a.count == 2, let act = HotAction(rawValue: a[0]) else { return }
            let r = Hotkeys.shared.set(Shortcut.isOff(a[1]) ? nil : Shortcut.parse(a[1]), for: act)
            emit(["event": "sethotkey", "action": act.rawValue, "keys": Hotkeys.shared.binding(act)?.spec ?? "off", "result": "\(r)"])
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
        case "review":                                  // review DIR: the batch in the main window
            AppEnvironment.mainWindow?.reveal(session: URL(fileURLWithPath: arg))
        case "processdir":                              // processdir [AGENT ]DIR
            let a = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if a.count == 2, AgentHub.shared.def(a[0]) != nil { process(URL(fileURLWithPath: a[1]), only: a[0]) } else { process(URL(fileURLWithPath: arg)) }
        case "toast": toast(arg.replacingOccurrences(of: "\\n", with: "\n"))
        case "axcards":
            let els = claws.accessibilityElements().map { e -> [String: Any] in
                let r = toCG(e.accessibilityFrame())
                return ["role": e.accessibilityRole()?.rawValue ?? "", "label": e.accessibilityLabel() ?? "",
                        "help": e.accessibilityHelp() ?? "", "actions": (e.accessibilityCustomActions() ?? []).map(\.name),
                        "rect": [r.minX, r.minY, r.width, r.height].map { ($0 * 10).rounded() / 10 }]
            }
            emit(["event": "ax", "elements": els])
        case "menuicon":
            let dir = URL(fileURLWithPath: arg.isEmpty ? NSTemporaryDirectory() : arg)
            emit(["event": "menuicon", "files": renderMenuIconPreviews(into: dir).map(\.path)])
        default: command(cmd)
        }
    }

    /// ⌥⇧V (voice input), ⌥⇧O (the project switcher), Esc while listening — K7.
    func captureHotkey(_ k: HK) {
        switch k {
        case .voice: VoiceInput.shared.pressed()
        case .voiceEsc: VoiceInput.shared.cancel()
        case .project: if resident { island.toggleSwitcher() }
        default: break
        }
    }

    func addSnapMenuItems(_ menu: NSMenu, recording: Bool) {
        @discardableResult
        func item(_ key: String, _ sel: Selector, on: Bool = false) -> NSMenuItem {
            let it = NSMenuItem(title: Loc.t(key, table: "Capture"), action: sel, keyEquivalent: "")
            it.target = self
            it.state = on ? .on : .off
            menu.addItem(it)
            return it
        }
        if recording {
            menu.addItem(.separator())
            item("capture.menu.snap", #selector(mSnap)).showHotkey(.snap)
            item("capture.menu.live_caption", #selector(mLiveCaption), on: liveCaptionOn)
            return
        }
        item("capture.menu.snap", #selector(mSnap)).showHotkey(.snap)
        item("capture.menu.voice", #selector(mVoice)).showHotkey(.voice)
        item("capture.menu.switch_project", #selector(mSwitchProject)).showHotkey(.project)
        if claws.count > 0 {
            let it = item("capture.menu.show_cards", #selector(mShowCards))
            it.title = Loc.plural("capture.menu.show_cards", table: "Capture", count: claws.count)
        }
        item("capture.menu.collect", #selector(mCollect), on: snapper.collecting)
    }

    @objc func mSnap() {
        if let r = rec { r.snap(via: "menu"); return }
        // the menu is still closing: let it go before the picker takes the screen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { snapper.hotkey() }
    }
    @objc func mVoice() { VoiceInput.shared.toggle() }
    @objc func mSwitchProject() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { island.showSwitcher() } }
    @objc func mShowCards() { claws.show(peek: 6) }
    @objc func mCollect() {
        setRecordConfig("collect_system_shots", !snapper.collecting)
        snapper.syncCollector()
    }
    @objc func mLiveCaption() { setRecordConfig("live_caption", !liveCaptionOn) }
}

/// The menu-bar icon as macOS would show it, without capturing the real menu bar: the template image tinted like a
/// status item (black 85 % on a light bar, white on a dark one) on a 24 pt strip, next to an SF Symbol for scale.
func renderMenuIconPreviews(into dir: URL) -> [URL] {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let icon = App.makeMenuIcon()
    let ref = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
    var out: [URL] = []
    for (theme, bar, ink) in [("light", NSColor(white: 0.93, alpha: 1), NSColor(white: 0, alpha: 0.85)),
                              ("dark", NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.17, alpha: 1), NSColor.white)] {
        for scale in [1, 2] {
            let size = NSSize(width: 96, height: 24)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let g = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = g
            g.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))   // the context is in pixels
            bar.setFill()
            NSRect(origin: .zero, size: size).fill()
            func tinted(_ im: NSImage, in r: NSRect) {
                let t = NSImage(size: r.size, flipped: false) { b in
                    im.draw(in: b)
                    ink.set()
                    b.fill(using: .sourceAtop)
                    return true
                }
                t.draw(in: r)
            }
            tinted(icon, in: NSRect(x: 14, y: 3, width: 18, height: 18))
            if let w = ref { tinted(w, in: NSRect(x: 56, y: (24 - w.size.height) / 2, width: w.size.width, height: w.size.height)) }
            NSGraphicsContext.restoreGraphicsState()
            let u = dir.appendingPathComponent("menuicon-\(theme)@\(scale)x.png")
            if let d = rep.representation(using: .png, properties: [:]) { try? d.write(to: u); out.append(u) }
        }
    }
    return out
}
