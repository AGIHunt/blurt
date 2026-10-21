// BLURT_TEST_COMMANDS=1 only: scripted checks for WP6, over a distributed notification like the shell's channel —
//   dev.blurt.recorder.wp6[.$BLURT_TEST_CHANNEL]  userInfo {"cmd": "…"}; every answer is one JSON line on stdout.
//   settings PANE | onboarding [STEP] | appearance dark|light | windowid settings|onboarding
//   route URL                    parse a blurt:// URL (no action)         url URL   handle it like macOS would
//   mainstub                     a stand-in main window that reports reveal(uid:) / reveal(session:) (until WP5 lands)
//   spotlight-index              index now → {"count"}                    spotlight-search TEXT → {"found": [uid…]}
//   spotlight-clear              remove our domain's entries
//   service TEXT                 "Add to Blurt" with TEXT on a private pasteboard, through the real service method
//   fix UIDS [AGENT bg|it]       the "fix with an agent" panel (autostarted when AGENT is given)
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
        emit(["event": "wp6_ready", "channel": channel])
    }

    @MainActor
    static func run(_ cmd: String) {
        let parts = cmd.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        func out(_ o: [String: Any]) { emit(["event": "wp6", "cmd": parts.first ?? ""].merging(o) { _, n in n }) }
        switch parts.first ?? "" {
        case "settings": SettingsController.shared.show(pane: arg.isEmpty ? nil : arg)
        case "onboarding": Onboarding.shared.show(step: Int(arg) ?? 0)
        case "appearance": NSApp.appearance = NSAppearance(named: arg == "dark" ? .darkAqua : .aqua)
        case "windowid":
            let n: Int? = arg == "onboarding" ? Onboarding.shared.windowNumber : arg == "fix" ? FixRunner.shared.windowNumber
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
            let a = arg.split(separator: " ").map(String.init)
            let uids = (a.first ?? "").split(separator: ",").map(String.init)
            if a.count >= 3 { FixRunner.shared.start(uids, autostart: (a[1], a[2] != "it")) } else { FixRunner.shared.start(uids) }
            out(["uids": uids])
        case "peck": PeckCard.shared.play(title: arg.isEmpty ? "Login button does nothing" : arg, detail: L("由 codex 修复", "by codex"), uid: "test")
        case "peckframes":
            let a = arg.split(separator: " ").map(String.init)
            out(["frames": PeckCard.renderFrames(to: URL(fileURLWithPath: a.first ?? "/tmp/peck"), dark: a.dropFirst().first == "dark")])
        case "perms":
            let p = Permissions()
            out(["screen": p.screen.rawValue, "mic": p.mic.rawValue, "accessibility": p.accessibility.rawValue])
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
}
