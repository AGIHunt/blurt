// Menu-bar app glue for snap mode: menu items, start-up, and (BLURT_TEST_COMMANDS=1 only) a distributed-notification
// command channel so scripted UI tests can drive the app without global hotkeys:
//   dev.blurt.recorder.command  userInfo {"cmd": "snap" | "snapregion x,y,w,h" | "perch" | "hide" | "process" |
//                                         "commit" | "cancel" | "edit N" | "hatch DIR" | "hatched DIR ok|fail" | "stop"}

import AppKit

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
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.blurt.recorder.command"), object: nil, queue: .main) { [weak self] n in
            guard let cmd = n.userInfo?["cmd"] as? String else { return }
            self?.testCommand(cmd)
        }
    }

    func testCommand(_ cmd: String) {
        let parts = cmd.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        emit(["event": "test_command", "cmd": cmd])
        switch parts.first ?? "" {
        case "snap": snapper.hotkey()
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
        func item(_ title: String, _ sel: Selector, on: Bool = false) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            it.state = on ? .on : .off
            menu.addItem(it)
        }
        if recording {
            menu.addItem(.separator())
            item(L("截图", "Snap") + "   ⌥⇧A", #selector(mSnap))
            item(L("实时字幕", "Live caption"), #selector(mLiveCaption), on: liveCaptionOn)
            return
        }
        item(L("截图", "Snap") + "   ⌥⇧A", #selector(mSnap))
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
