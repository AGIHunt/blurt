import AppKit
import BlurtCore
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import ServiceManagement

// MARK: - App

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var picker: PickerController?
    var rec: Recorder?
    var countdownWin: NSWindow?
    var statusItem: NSStatusItem?
    var busy = false                 // picking / counting down / recording
    var processing: [String] = []    // sessions being processed by an agent
    var statusTimer: Timer?
    var lastSession: URL?

    var resident: Bool { opts.standalone }

    func applicationDidFinishLaunching(_ n: Notification) {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in
                guard let self = self else { return }
                if self.rec != nil { self.command("stop") } else if !self.resident { self.command("stop") } else { NSApp.terminate(nil) }
            }
            s.resume()
            signalSources.append(s)
        }
        BlurtLocale.lang = opts.lang
        if resident { AppEnvironment.installModules() }
        installHotkeyHandler()
        hotkeyHandler = { [weak self] k in self?.hotkey(k) }
        Hotkeys.shared.resident = resident      // record / menu only in the menu-bar app
        Hotkeys.shared.disabled = AppEnvironment.mainWindow == nil ? [.openMain] : []
        Hotkeys.shared.apply()
        if resident {
            startResident()
            return
        }
        DispatchQueue.global().async {
            while let line = readLine() {
                let cmd = line.trimmingCharacters(in: .whitespaces).lowercased()
                DispatchQueue.main.async { self.command(cmd) }
            }
        }
        // Probe permission early so the user isn't asked mid-flow.
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { _, err in
            DispatchQueue.main.async {
                if let err = err {
                    sessionEnded(3, ["event": "error", "code": "screen_permission", "message": err.localizedDescription])
                    return
                }
                if let r = opts.region { self.begin(r) } else { self.pick() }
            }
        }
    }

    func hotkey(_ k: HK) {
        switch k {
        case .pause: command("toggle")
        case .marker: command("marker")
        case .stop: command("stop")
        case .pen: command("pen")
        case .penEsc: if rec?.penSticky == true { command("pen") }
        case .snap: if let r = rec { r.snap(via: "hotkey") } else if resident { snapper.hotkey() }
        case .toggleRec: rec != nil ? command("stop") : (busy ? nil : startRecording(useLast: false))
        case .menu: popMenu()
        case .pickEnter: picker?.finish(true)
        case .pickEsc: picker?.finish(false)
        case .pickFull: picker?.fullScreen()
        }
    }

    func command(_ c: String) {
        switch c {
        case "stop":
            if let r = rec { r.stop() } else if let p = picker { p.finish(false) } else if !resident { sessionEnded(2, ["event": "cancelled"]) }
        case "discard": rec?.stop(discard: true)
        case "restart": rec?.stop(discard: true, restart: true)
        case "pause": if rec?.isPaused == false { rec?.togglePause() }
        case "resume": if rec?.isPaused == true { rec?.togglePause() }
        case "toggle": rec?.togglePause()
        case "marker": rec?.marker()
        case "snap": if let r = rec { r.snap(via: "command") } else if resident { snapper.hotkey() }
        case "notes": rec?.hud?.live?.openNotes()
        case "pen": rec?.togglePen()
        default: break
        }
    }

    func pick() {
        busy = true
        let p = PickerController()
        p.onDone = { [weak self] r in
            guard let self = self else { return }
            unregisterHotkey(.pickEnter); unregisterHotkey(.pickEsc); unregisterHotkey(.pickFull)
            self.picker = nil
            guard let r = r else { self.busy = false; sessionEnded(2, ["event": "cancelled"]); return }
            self.begin(r)
        }
        picker = p
        // Esc / Enter / F must work even if macOS refuses to make us the active app
        registerHotkey(.pickEnter, key: kVK_Return, mods: 0)
        registerHotkey(.pickEsc, key: kVK_Escape, mods: 0)
        registerHotkey(.pickFull, key: kVK_ANSI_F, mods: 0)
        p.show(preselect: opts.preselect)
    }

    func begin(_ region: CGRect) {
        busy = true
        emit(["event": "selected", "region": [region.minX, region.minY, region.width, region.height]])
        saveLastRegion(region)
        opts.lastRegion = region
        let r = Recorder(region: region)
        r.onRestart = { [weak self] in
            FileManager.default.createFile(atPath: opts.events ?? "/dev/null", contents: nil)
            self?.rec = nil
            self?.begin(region)
        }
        rec = r
        r.prepare { err in
            if let err = err {
                sessionEnded(3, ["event": "error", "code": "setup", "message": err.localizedDescription])
                return
            }
            self.countdown(opts.countdown, over: region) {
                r.start()
                if self.resident, let dir = self.lastSession { launchLive(dir) }
            }
        }
    }

    func countdown(_ n: Int, over region: CGRect, then: @escaping () -> Void) {
        guard n > 0 else { return then() }
        let v = CountdownView()
        let w = overlayWindow(toNS(region), view: v)
        w.ignoresMouseEvents = false
        w.orderFrontRegardless()
        countdownWin = w
        var left = n
        var fired = false
        v.n = left
        emit(["event": "countdown", "n": left])
        NSSound(named: "Pop")?.play()
        var timer: Timer?
        let go = {
            guard !fired else { return }
            fired = true                 // a short beat after hiding so the countdown never lands in frame 1
            timer?.invalidate()
            w.orderOut(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { then() }
        }
        v.onSkip = go
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            left -= 1
            if left == 0 {
                go()
                return
            }
            v.n = left
            NSSound(named: "Pop")?.play()
            emit(["event": "countdown", "n": left])
        }
    }

    // MARK: menu-bar app

    func startResident() {
        ensureDefaultWorkspace()
        DispatchQueue.global().async { _ = agentEnvironment() }   // ask the login shell now, not when a recording ends
        writeAppInfo()
        Updater.shared.start()
        ReviewHub.shared.listen()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.autosaveName = "blurt"
        item.isVisible = true
        statusItem = item
        refreshStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshStatus() }
        sessionEnded = { [weak self] code, event in
            emit(event)
            self?.takeEnded(code, event)
        }
        // A second launch (double-click the app again) → start recording in the running instance
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.blurt.recorder.start"), object: nil, queue: .main) { [weak self] _ in
            guard let self = self, !self.busy else { return }
            self.startRecording(useLast: false)
        }
        startSnapMode()                 // the perch, a batch left from last time, test commands (SnapApp.swift)
        if recordConfig()["welcomed"] == nil {
            setRecordConfig("welcomed", true)
            let r = hkHint(.toggleRecord, "开始 / 结束录制", "start / finish"), m = hkHint(.openMenu, "打开菜单", "menu")
            toast(L("口喷鸡已常驻 🐔  ", "blurt is running 🐔  ") + [r, m].compactMap { $0 }.joined(separator: " · "))
        } else {
            Hotkeys.shared.warnOnce { [weak self] in self?.toast($0, seconds: 8) }
        }
        // `--process <session dir> [--agent <id>]`: process an existing recording (also handy for testing);
        // `--review <url> [--review-session <dir>]`: review.py asked us to show its page (we weren't running)
        let args = CommandLine.arguments
        func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if let p = arg("--process") {
            process(URL(fileURLWithPath: p), only: arg("--agent"))
        } else if let r = arg("--review"), let u = URL(string: r) {
            ReviewHub.shared.open(u, session: arg("--review-session").map { URL(fileURLWithPath: $0) }, title: nil)
        } else if !args.contains("--background") {
            startRecording(useLast: false)
        }
    }

    /// $BLURT_HOME/app.json: how review.py (run by an agent in a terminal) finds this instance to open its page here.
    func writeAppInfo() {
        let info: [String: Any] = ["pid": Int(getpid()), "path": Bundle.main.bundlePath,
                                   "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""]
        if let d = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: blurtHome, withIntermediateDirectories: true)
            try? d.write(to: blurtHome.appendingPathComponent("app.json"))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ReviewHub.shared.quitting = true
        for p in ReviewHub.shared.procs.values where p.isRunning { p.terminate() }   // our review servers go with us
        guard resident else { return }
        Hotkeys.shared.unpublish()
        let f = blurtHome.appendingPathComponent("app.json")
        if let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           o["pid"] as? Int == Int(getpid()) { try? FileManager.default.removeItem(at: f) }
    }

    /// The menu-bar icon can be hidden behind the notch on a crowded menu bar — ⌥⇧B shows the same menu at the pointer.
    func popMenu() {
        let m = NSMenu()
        menuNeedsUpdate(m)
        activateApp()
        m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// blurt:// / blurt-app:// (Info.plist CFBundleURLTypes). WP6 handles them via AppEnvironment.openURL; until then
    /// the shell understands blurt://record and blurt://snap.
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls where u.scheme == "blurt" || u.scheme == "blurt-app" {
            if AppEnvironment.openURL?(u) == true { continue }
            switch u.host {
            case "record": if resident && !busy { startRecording(useLast: false) }
            case "snap": if resident { snapper.hotkey() }
            default: break
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if resident && !busy { startRecording(useLast: false) }
        return false
    }

    func startRecording(useLast: Bool) {
        if NoteBubble.shared.isOpen { NoteBubble.shared.commit() }
        guard !busy else { return }
        let dir = newSessionDir()
        opts.out = dir.appendingPathComponent("recording.mp4").path
        opts.events = dir.appendingPathComponent("events.jsonl").path
        opts.lastRegion = lastRegionFromConfig()
        opts.countdown = recordConfig()["countdown"] as? Int ?? 3
        opts.systemAudio = recordConfig()["system_audio"] as? Bool ?? false
        lastSession = dir
        busy = true
        if (recordConfig()["process"] as? String ?? "off") != "off" {
            AgentHub.shared.check(AgentHub.shared.order(), force: true) { _ in }   // warm the cache while recording
        }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { _, err in
            DispatchQueue.main.async {
                if err != nil {
                    self.busy = false
                    try? FileManager.default.removeItem(at: dir)
                    self.permissionHelp()
                    return
                }
                if useLast, let r = opts.lastRegion { self.begin(r) } else { self.pick() }
            }
        }
    }

    func takeEnded(_ code: Int32, _ event: [String: Any]) {
        rec = nil
        busy = false
        picker = nil
        guard let dir = lastSession else { return }
        cleanupLive(dir)
        if code != 0 {
            try? FileManager.default.removeItem(at: dir)       // cancelled / failed take: leave no empty folder
            if event["event"] as? String == "error" {
                alert(L("录制失败", "Recording failed"), event["message"] as? String ?? "")
            }
            refreshStatus()
            return
        }
        let dur = event["duration"] as? Double ?? 0
        let meta: [String: Any] = [
            "engine": "native-app", "duration": dur, "video": "recording.mp4", "region": event["region"] ?? [],
            "started_at": ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -dur)),
            "author": recordConfig()["author"] as? String ?? NSFullUserName(),
            "workspace": currentWorkspace().path,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("meta.json"))
        }
        let mode = recordConfig()["process"] as? String ?? "off"
        if mode == "off" {
            toast(L("已保存 \(fmtDur(dur)) 的录屏 · 在菜单里可以拷贝发给同事，或让 agent 处理", "Saved a \(fmtDur(dur)) recording · copy it from the menu or let your agent process it"))
        } else {
            process(dir)
        }
        refreshStatus()
    }

    /// In a Blurt window (ReviewWindow.swift), or the browser with review.open_in = "browser".
    @discardableResult
    func openReview(_ dir: URL) -> Bool { ReviewHub.shared.openSession(dir) }

    func fmtDur(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    func refreshStatus() {
        guard let b = statusItem?.button else { return }
        if let r = rec, r.sessionStart.isValid {
            let s = Int(r.elapsed())
            b.image = nil
            b.attributedTitle = NSAttributedString(string: (r.isPaused ? "❚❚ " : "● ") + String(format: "%02d:%02d", s / 60, s % 60), attributes: [
                .foregroundColor: r.isPaused ? amber : NSColor.systemRed, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)])
        } else {
            b.image = menuIcon
            b.imagePosition = .imageLeft
            b.attributedTitle = NSAttributedString(string: processing.isEmpty ? "" : " …", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
            b.toolTip = processing.isEmpty ? ([L("口喷鸡", "blurt")] + [hkHint(.toggleRecord, "开始录制", "record"), hkHint(.openMenu, "菜单", "menu")].compactMap { $0 })
                                               .joined(separator: " · ")
                                           : L("口喷鸡 · 正在后台整理…", "blurt · processing in the background…")
        }
    }

    /// The chicken as a monochrome template image, like every other menu-bar icon (macOS tints it).
    lazy var menuIcon: NSImage? = {
        let img = Bundle.main.image(forResource: "MenuIconTemplate")
            ?? NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: "blurt")
        if let i = img, i.size.height > 0 {
            i.size = NSSize(width: 18 * i.size.width / i.size.height, height: 18)
            i.isTemplate = true
        }
        return img
    }()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        @discardableResult
        func add(_ title: String, _ sel: Selector?, key: String = "", to m: NSMenu = menu, obj: Any? = nil, on: Bool = false) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.target = self
            it.representedObject = obj
            it.state = on ? .on : .off
            m.addItem(it)
            return it
        }
        if let r = rec {
            add(L("完成录制", "Finish recording"), #selector(mStop)).showHotkey(.finish)
            add(r.isPaused ? L("继续", "Resume") : L("暂停", "Pause"), #selector(mPause)).showHotkey(.pause)
            _ = add(L("重新录制", "Restart"), #selector(mRestart))
            _ = add(L("放弃这次录制", "Discard"), #selector(mDiscard))
            addSnapMenuItems(menu, recording: true)
            return
        }
        if busy { _ = add(L("正在选择区域…", "Selecting an area…"), nil); return }
        add(L("开始录制", "Start recording"), #selector(mStart)).showHotkey(.toggleRecord)
        if lastRegionFromConfig() != nil { _ = add(L("录制上次的区域", "Record the last area"), #selector(mStartLast)) }
        addSnapMenuItems(menu, recording: false)
        menu.addItem(.separator())
        if AppEnvironment.mainWindow != nil {
            add(L("打开口喷鸡", "Open Blurt"), #selector(mOpenMain)).showHotkey(.openMain)
            menu.addItem(.separator())
        }

        let ws = currentWorkspace()
        let wsItem = NSMenuItem(title: L("工作区：", "Workspace: ") + ws.lastPathComponent, action: nil, keyEquivalent: "")
        let wsMenu = NSMenu()
        _ = add(L("默认（~/Blurt）", "Default (~/Blurt)"), #selector(mWorkspace(_:)), to: wsMenu, obj: defaultWorkspace.path,
                on: ws.standardizedFileURL == defaultWorkspace.standardizedFileURL)
        for w in knownWorkspaces() where w.standardizedFileURL != defaultWorkspace.standardizedFileURL {
            _ = add(w.lastPathComponent + "  ·  " + (w.path as NSString).abbreviatingWithTildeInPath, #selector(mWorkspace(_:)), to: wsMenu,
                    obj: w.path, on: w.standardizedFileURL == ws.standardizedFileURL)
        }
        wsMenu.addItem(.separator())
        _ = add(L("绑定一个项目文件夹…", "Bind a project folder…"), #selector(mChooseWorkspace), to: wsMenu)
        _ = add(L("在访达中打开工作区", "Open workspace in Finder"), #selector(mOpenWorkspace), to: wsMenu)
        wsItem.submenu = wsMenu
        menu.addItem(wsItem)

        let recents = recentSessions()
        let rItem = NSMenuItem(title: L("最近的录制", "Recent recordings"), action: nil, keyEquivalent: "")
        let rMenu = NSMenu()
        if recents.isEmpty { _ = add(L("还没有录制", "No recordings yet"), nil, to: rMenu) }
        for d in recents {
            let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: d.appendingPathComponent("meta.json")))) as? [String: Any]
            let dur = isShotsSession(d) ? "📸 \(meta?["shots"] as? Int ?? 0)" : fmtDur(meta?["duration"] as? Double ?? 0)
            let done = FileManager.default.fileExists(atPath: d.appendingPathComponent("items.json").path)
            let name = d.lastPathComponent
            let pretty = name.count >= 15 ? "\(name.dropFirst(4).prefix(2))/\(name.dropFirst(6).prefix(2)) \(name.dropFirst(9).prefix(2)):\(name.dropFirst(11).prefix(2))" : name
            let busyHere = processing.contains(d.path)
            let failed = done || busyHere ? nil : agentFailureNote(d)
            let it = NSMenuItem(title: "\(pretty)  ·  \(dur)\(done ? "  ✓" : "")\(busyHere ? "  …" : "")\(failed.map { "  ✗ " + $0 } ?? "")",
                                action: nil, keyEquivalent: "")
            let sub = NSMenu()
            if done { add(L("打开审核页", "Open review"), #selector(mOpenReview(_:)), to: sub, obj: d.path) }
            add(L("拷贝视频（粘贴发给同事）", "Copy video (paste to share)"), #selector(mCopyVideo(_:)), to: sub, obj: d.path)
            add(L("在访达中显示", "Show in Finder"), #selector(mReveal(_:)), to: sub, obj: d.path)
            if FileManager.default.fileExists(atPath: d.appendingPathComponent("agent.log").path) {
                add(L("查看 agent.log", "Show agent.log"), #selector(mAgentLog(_:)), to: sub, obj: d.path)
            }
            sub.addItem(.separator())
            add(done ? L("重新整理", "Process again") : L("整理（自动选 agent）", "Process (pick an agent)"), busyHere ? nil : #selector(mProcessAuto(_:)), to: sub, obj: d.path)
            for a in AgentHub.shared.order() {
                let st = AgentHub.shared.cached(a.id)
                let li = add(L("用 \(a.name) 整理", "Process with \(a.name)") + (st.map { $0.state.usable ? "" : "  ✗ " + $0.why } ?? ""),
                             busyHere ? nil : #selector(mProcessWith(_:)), to: sub, obj: "\(a.id)\u{1}\(d.path)")
                li.indentationLevel = 1
            }
            it.submenu = sub
            rMenu.addItem(it)
        }
        rItem.submenu = rMenu
        menu.addItem(rItem)
        menu.addItem(.separator())

        let mode = recordConfig()["process"] as? String ?? "off"
        let pItem = NSMenuItem(title: L("录完自动整理", "After recording"), action: nil, keyEquivalent: "")
        let pMenu = NSMenu()
        add(L("只保存（手动处理 / 发给别人）", "Just save (process later / share)"), #selector(mProcessMode(_:)), to: pMenu, obj: "off", on: mode == "off")
        add(L("交给 agent 后台整理", "Process with an agent in the background"), #selector(mProcessMode(_:)), to: pMenu, obj: "auto", on: mode != "off")
        pItem.submenu = pMenu
        menu.addItem(pItem)
        addAgentMenu(menu)
        add(L("审核页在口喷鸡窗口里打开", "Open reviews in a Blurt window"), #selector(mReviewInApp), on: ReviewHub.shared.openInApp)

        let cd = recordConfig()["countdown"] as? Int ?? 3
        let cItem = NSMenuItem(title: L("倒计时", "Countdown"), action: nil, keyEquivalent: "")
        let cMenu = NSMenu()
        for n in [0, 3, 5] { _ = add(n == 0 ? L("不倒计时", "None") : L("\(n) 秒", "\(n) s"), #selector(mCountdown(_:)), to: cMenu, obj: n, on: cd == n) }
        cItem.submenu = cMenu
        menu.addItem(cItem)
        if #available(macOS 13.0, *) {
            _ = add(L("同时录系统声音（会议、演示）", "Also record system audio (calls, demos)"), #selector(mSystemAudio),
                    on: recordConfig()["system_audio"] as? Bool ?? false)
        }
        if #available(macOS 13.0, *) {
            _ = add(L("开机时启动", "Open at login"), #selector(mLogin), on: SMAppService.mainApp.status == .enabled)
        }
        add(L("快捷键…", "Shortcuts…"), #selector(mShortcuts), key: AppEnvironment.settings == nil ? "," : "")
        if AppEnvironment.settings != nil { add(L("设置…", "Settings…"), #selector(mSettings), key: ",") }
        menu.addItem(.separator())
        if Updater.shared.available {
            let u = add(L("检查更新…", "Check for Updates…"), Updater.shared.canCheck ? #selector(Updater.checkForUpdates(_:)) : nil)
            u.target = Updater.shared
        }
        _ = add(L("使用说明 / GitHub", "Help / GitHub"), #selector(mHelp))
        _ = add(L("退出口喷鸡", "Quit blurt"), #selector(mQuit), key: "q")
    }

    @objc func mOpenMain() { AppEnvironment.mainWindow?.show() }
    @objc func mSettings() { AppEnvironment.settings?.show(pane: nil) }
    @objc func mStart() { startRecording(useLast: false) }
    @objc func mStartLast() { startRecording(useLast: true) }
    @objc func mStop() { command("stop") }
    @objc func mPause() { command("toggle") }
    @objc func mRestart() { command("restart") }
    @objc func mDiscard() { command("discard") }
    @objc func mWorkspace(_ it: NSMenuItem) {
        guard let p = it.representedObject as? String else { return }
        setRecordConfig("workspace", p == defaultWorkspace.path ? nil : p)
    }
    @objc func mChooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("绑定", "Bind")
        panel.message = L("录屏会保存到这个项目的 .blurt/sessions 里，agent 可以直接结合代码处理", "Recordings go to <project>/.blurt/sessions so your agent can process them with the code")
        activateApp()
        guard panel.runModal() == .OK, let u = panel.url else { return }
        var list = recordConfig()["workspaces"] as? [String] ?? []
        if !list.contains(u.path) { list.insert(u.path, at: 0) }
        setRecordConfig("workspaces", Array(list.prefix(8)))
        setRecordConfig("workspace", u.path)
    }
    @objc func mOpenWorkspace() { NSWorkspace.shared.open(currentWorkspace()) }
    @objc func mReveal(_ it: NSMenuItem) {
        guard let p = it.representedObject as? String else { return }
        let d = URL(fileURLWithPath: p)
        NSWorkspace.shared.activateFileViewerSelecting([isShotsSession(d) ? d : d.appendingPathComponent("recording.mp4")])
    }
    @objc func mCopyVideo(_ it: NSMenuItem) {
        guard let p = it.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let d = URL(fileURLWithPath: p)
        let shots = ((try? FileManager.default.contentsOfDirectory(at: d.appendingPathComponent("shots"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" && !$0.lastPathComponent.contains(".marked.") }.sorted { $0.path < $1.path }
        pb.writeObjects(isShotsSession(d) ? shots as [NSURL] : [d.appendingPathComponent("recording.mp4") as NSURL])
        toast(L("已拷贝，去飞书 / 微信 / Slack 里直接粘贴", "Copied — paste it into Slack, Feishu, email…"))
    }
    @objc func mProcessAuto(_ it: NSMenuItem) { if let p = it.representedObject as? String { process(URL(fileURLWithPath: p)) } }
    @objc func mProcessWith(_ it: NSMenuItem) {
        guard let v = it.representedObject as? String, let sep = v.firstIndex(of: "\u{1}") else { return }
        process(URL(fileURLWithPath: String(v[v.index(after: sep)...])), only: String(v[..<sep]))
    }
    @objc func mOpenReview(_ it: NSMenuItem) {
        guard let p = it.representedObject as? String else { return }
        if !openReview(URL(fileURLWithPath: p)) { alert(L("打不开审核页", "Can't open the review"), L("需要 uv 和 blurt skill（运行一次 record.py build）。", "Needs uv and the blurt skill (run record.py build once).")) }
    }
    @objc func mAgentLog(_ it: NSMenuItem) {
        guard let p = it.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: p).appendingPathComponent("agent.log"))
    }
    @objc func mProcessMode(_ it: NSMenuItem) { setRecordConfig("process", it.representedObject as? String) }
    @objc func mReviewInApp() {
        var r = readConfig()["review"] as? [String: Any] ?? [:]
        r["open_in"] = ReviewHub.shared.openInApp ? "browser" : "app"
        var cfg = readConfig()
        cfg["review"] = r
        if let d = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: configURL) }
    }
    @objc func mShortcuts() { if let s = AppEnvironment.settings { s.show(pane: "shortcuts") } else { HotkeySettings.shared.show() } }
    @objc func mCountdown(_ it: NSMenuItem) { setRecordConfig("countdown", it.representedObject as? Int) }
    @objc func mSystemAudio() { setRecordConfig("system_audio", !(recordConfig()["system_audio"] as? Bool ?? false)) }
    @objc func mLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { alert(L("设置失败", "Couldn't change it"), error.localizedDescription) }
    }
    @objc func mHelp() { NSWorkspace.shared.open(URL(string: "https://github.com/AGIHunt/blurt")!) }
    @objc func mQuit() { NSApp.terminate(nil) }

    // tiny, non-blocking toast under the menu bar (no notification permission needed)
    var toastWin: NSWindow?
    /// Several lines ("\n") are fine: the first is the headline, the rest a quieter detail.
    func toast(_ text: String, seconds: Double = 4.5) {
        let seconds = max(seconds, Double(ProcessInfo.processInfo.environment["BLURT_TOAST_MIN_SECONDS"] ?? "") ?? 0)   // tests: time to screenshot
        toastWin?.orderOut(nil)
        emit(["event": "toast", "text": text])
        let f = NSFont.systemFont(ofSize: 13, weight: .medium)
        let lines = text.components(separatedBy: "\n")
        let body = NSMutableAttributedString(string: lines[0], attributes: [.font: f, .foregroundColor: NSColor.white])
        if lines.count > 1 {
            let para = NSMutableParagraphStyle()
            para.paragraphSpacingBefore = 3
            body.append(NSAttributedString(string: "\n" + lines.dropFirst().joined(separator: "\n"), attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 1, alpha: 0.78), .paragraphStyle: para]))
        }
        let maxW: CGFloat = 560
        let fit = body.boundingRect(with: NSSize(width: maxW, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let w = ceil(fit.width) + 36, h = ceil(fit.height) + 22
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let frame = NSRect(x: screen.maxX - w - 16, y: screen.maxY - h - 16, width: w, height: h)
        let v = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        v.material = .hudWindow
        v.state = .active
        v.appearance = NSAppearance(named: .vibrantDark)
        v.wantsLayer = true
        v.layer?.cornerRadius = 12
        let label = NSTextField(labelWithAttributedString: body)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.frame = NSRect(x: 18, y: 11, width: w - 30, height: ceil(fit.height))
        v.addSubview(label)
        let win = overlayWindow(frame, view: v)
        win.level = .statusBar
        win.orderFrontRegardless()
        toastWin = win
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self, weak win] in
            if self?.toastWin === win { win?.orderOut(nil) }
        }
    }

    func permissionHelp() {
        let a = NSAlert()
        a.messageText = L("需要「录屏」权限", "Screen Recording permission needed")
        a.informativeText = L("""
            在 系统设置 → 隐私与安全性 → 录屏与系统录音 里打开「Blurt」，然后退出并重新打开口喷鸡（macOS 只在启动时读取权限）。

            如果列表里已经是打开的：选中「Blurt」点下面的「−」删掉，再重新打开口喷鸡授权一次（旧版本留下的授权对新版本无效）。
            """, """
            Turn on “Blurt” in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen blurt \
            (macOS reads the permission at launch).

            Already on? Select “Blurt”, remove it with “−”, reopen blurt and allow it again (a grant from an older build doesn't carry over).
            """)
        a.addButton(withTitle: L("打开系统设置", "Open System Settings"))
        a.addButton(withTitle: L("退出口喷鸡", "Quit blurt"))
        a.addButton(withTitle: L("稍后", "Later"))
        activateApp()
        switch a.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        case .alertSecondButtonReturn:
            NSApp.terminate(nil)
        default: break
        }
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        activateApp()
        a.runModal()
    }
}
