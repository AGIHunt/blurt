import AppKit
import BlurtCore
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit

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
        if let l = opts.lang { Loc.setting = l }
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
        case .voice, .project, .voiceEsc, .cards, .cardsEsc, .dictationEsc: captureHotkey(k)     // K7 (P5, SnapApp.swift)
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
        case "notes": island.openRecordingNotes()     // K7 (P5): the island replaced the HUD
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
        ProjectStore.shared.watch()
        JobStore.shared.start()
        JobNotifier.shared.start()
        Housekeeping.atLaunch()
        AppEnvironment.process = { [weak self] session, captures, project in self?.process(session, captures: captures, project: project) }
        listenForReviews()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.autosaveName = "blurt"
        item.isVisible = true
        statusItem = item
        MenuGlyph.migrateSetting()
        MenuGlyph.shared.onFrame = { [weak self] img in
            guard let self = self, self.rec == nil, let b = self.statusItem?.button else { return }
            b.image = img ?? self.menuIcon(self.menuLook(b))
        }
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
        Dictation.shared.install()      // the dictation key (right ⌥ / Fn), history retention
        if recordConfig()["welcomed"] == nil {
            setRecordConfig("welcomed", true)
            toast(T("app.toast.welcome", hk(.toggleRecord), hk(.openMenu)), icon: .blurt)   // the menu-bar hen: where to find blurt
        } else {
            Hotkeys.shared.warnOnce { [weak self] in self?.toast($0, seconds: 8) }
        }
        // `--process <session dir> [--agent <id>]`: process an existing recording (also handy for testing);
        // `--review <url> --review-session <dir>`: review.py asked for its batch (we weren't running) → the main window
        let args = CommandLine.arguments
        func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if let p = arg("--process") {
            process(URL(fileURLWithPath: p), only: arg("--agent"))
        } else if let s = arg("--review-session") {
            AppEnvironment.mainWindow?.reveal(session: URL(fileURLWithPath: s))
        } else if !args.contains("--background") {
            startRecording(useLast: false)
        }
    }

    /// review.py started by an agent in a terminal asks for its batch (dev.blurt.recorder.review {url, session, home}):
    /// the user asked for that review, so the batch opens in the main window — the only window that ever shows one.
    func listenForReviews() {
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.blurt.recorder.review"), object: nil, queue: .main) { n in
            guard let info = n.userInfo, let s = info["session"] as? String else { return }
            if let home = info["home"] as? String, !home.isEmpty,
               URL(fileURLWithPath: home).standardizedFileURL.path != blurtHome.standardizedFileURL.path { return }
            AppEnvironment.mainWindow?.reveal(session: URL(fileURLWithPath: s))
        }
    }

    /// $BLURT_HOME/app.json: how review.py (run by an agent in a terminal) finds this instance.
    func writeAppInfo() {
        let info: [String: Any] = ["pid": Int(getpid()), "path": Bundle.main.bundlePath,
                                   "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""]
        if let d = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: blurtHome, withIntermediateDirectories: true)
            try? d.write(to: blurtHome.appendingPathComponent("app.json"))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard resident else { return }
        Housekeeping.atQuit()
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

    /// blurt:// / blurt-app:// (Info.plist CFBundleURLTypes) via AppEnvironment.openURL; the shell itself understands
    /// blurt://record and blurt://snap. Folders (dropped on the Dock icon, "Open With") open as projects.
    func application(_ application: NSApplication, open urls: [URL]) {
        let folders = urls.filter { u in
            var dir: ObjCBool = false
            return u.isFileURL && FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) && dir.boolValue
        }
        if !folders.isEmpty, resident {
            AppEnvironment.mainWindow?.show()
            MainWindowController.shared.openFolders(folders)
        }
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
        if autoProcess {
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

    /// K7: a recording is organised as soon as it ends (record.process "off" = just keep the video).
    var autoProcess: Bool { (recordConfig()["process"] as? String ?? "auto") != "off" }

    func takeEnded(_ code: Int32, _ event: [String: Any]) {
        rec = nil
        busy = false
        picker = nil
        guard let dir = lastSession else { return }
        cleanupLive(dir)
        if code != 0 {
            try? FileManager.default.removeItem(at: dir)       // cancelled / failed take: leave no empty folder
            if event["event"] as? String == "error" {
                alert(T("app.record.failed"), event["message"] as? String ?? "")
            }
            refreshStatus()
            return
        }
        let dur = event["duration"] as? Double ?? 0
        let project = ProjectStore.shared.current
        let meta: [String: Any] = [
            "engine": "native-app", "duration": dur, "video": "recording.mp4", "region": event["region"] ?? [],
            "started_at": ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -dur)),
            "author": recordConfig()["author"] as? String ?? NSFullUserName(),
            "project": project?.id as Any? ?? NSNull(),
            "workspace": currentWorkspace().path,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("meta.json"))
        }
        if autoProcess {
            process(dir, project: project?.id)
        } else {
            toast(T("app.toast.saved", Loc.duration(dur)))
        }
        refreshStatus()
    }

    func refreshStatus() {
        guard let b = statusItem?.button else { return }
        if let r = rec, r.sessionStart.isValid {
            let s = r.elapsed()
            b.image = (r.isPaused ? BlurtIcon.pauseFill : BlurtIcon.recordFill).image(size: 11, color: r.isPaused ? amber : .systemRed)
            b.imagePosition = .imageLeft
            b.attributedTitle = NSAttributedString(string: " " + Loc.duration(s), attributes: [
                .foregroundColor: r.isPaused ? amber : NSColor.systemRed, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)])
            return
        }
        let look = menuLook(b)
        MenuGlyph.shared.look = look
        MenuGlyph.shared.listening = VoiceInput.shared.active
        b.image = MenuGlyph.shared.current ?? menuIcon(look)
        b.imagePosition = .imageLeft
        let badge = MenuBadge.shared
        // K4: the count of what waits for you, next to the icon; nothing at all when there is nothing. The colour hen
        // ends in its shout strokes, so the count sits a hair closer than after the template glyph (a thin space)
        b.attributedTitle = badge.count > 0
            ? NSAttributedString(string: (look == nil ? " " : "\u{2009}") + Loc.number(badge.count), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: badge.urgent ? StatusRing.attention : NSColor.labelColor])
            : NSAttributedString(string: "")
        b.toolTip = badge.tooltip
        b.setAccessibilityLabel(badge.count > 0 ? T("app.status.ax_count", badge.tooltip) : T("app.name"))
    }

    /// The menu-bar icon at rest: the monochrome template hen below (the default, like every other menu-bar icon), or —
    /// Settings → General → "Colour menu-bar icon" — the colour hen (Icons/MenuHen.swift, brand direction A) in the
    /// look that suits the bar. The recording state (red dot / pause) replaces either.
    func menuIcon(_ look: MenuHen.Look?) -> NSImage {
        let key = look?.rawValue ?? "mono"
        if let i = menuIcons[key] { return i }
        let i: NSImage
        if let l = look {
            i = MenuHen.image(size: 18, look: l)
            i.accessibilityDescription = T("app.name")
        } else {
            i = App.makeMenuIcon()
        }
        menuIcons[key] = i
        return i
    }
    private var menuIcons: [String: NSImage] = [:]

    /// Which colour hen this status button needs: a light rim where the hen's dark outline would melt into the bar —
    /// a dark or tinted-dark menu bar (the button's effectiveAppearance follows the wallpaper) — and while the menu is
    /// open (the highlight behind it); nil = the monochrome template hen (the default).
    func menuLook(_ b: NSStatusBarButton) -> MenuHen.Look? {
        if MenuGlyph.monochrome { return nil }
        let dark = b.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark || menuOpen ? .dark : .light
    }
    private var menuOpen = false

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menuOpen = true
        refreshStatus()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menuOpen = false
        refreshStatus()
    }

    /// The `menuglyph` self-test: the button as it looks with its menu open, without opening it.
    func testMenuOpen(_ open: Bool) {
        menuOpen = open
        refreshStatus()
    }

    /// The `blurt` glyph (assets/icons/blurt.svg — the same mark as the Tauri tray): the A hen as a solid silhouette
    /// (negative-space eye and open beak, the comb and wattle apart from the head, shout strokes), drawn at 18 pt as a
    /// monochrome template image like every other menu-bar icon: macOS tints it for light, dark and highlighted bars,
    /// and it is vector, so it is crisp at every scale. The default menu-bar icon.
    static func makeMenuIcon() -> NSImage {
        let img = BlurtIcon.blurt.image(size: 18)
        img.isTemplate = true
        img.accessibilityDescription = T("app.name")
        return img
    }

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
            add(T("app.menu.finish"), #selector(mStop)).showHotkey(.finish)
            add(r.isPaused ? T("app.menu.resume") : T("app.menu.pause"), #selector(mPause)).showHotkey(.pause)
            _ = add(T("app.menu.restart"), #selector(mRestart))
            _ = add(T("app.menu.discard"), #selector(mDiscard))
            addSnapMenuItems(menu, recording: true)
            return
        }
        if busy { _ = add(T("app.menu.selecting"), nil); return }
        // dictation is on but can't hear its key (no Input Monitoring): the first row until the tap works
        if Dictation.shared.needsSetup {
            let d = add(T("dictation.menu.turn_on"), #selector(mDictationSetup))
            d.image = App.warningImage
            d.toolTip = T("dictation.menu.turn_on.tip", Dictation.keyInline)
            if #available(macOS 14.4, *) { d.subtitle = T("dictation.menu.turn_on.subtitle", Dictation.keyInline) }
            menu.addItem(.separator())
        }
        // Kept short, like other menu-bar apps: capture, what waits for you, the current project, Settings, Quit.
        // After-recording, the agent order, countdown, system audio, open at login, shortcuts and help live in Settings.
        let record = add(T("app.menu.record"), #selector(mStart))
        record.showHotkey(.toggleRecord)
        if lastRegionFromConfig() != nil {
            // ⌥ turns the row into "Record the Last Area". AppKit only folds an alternate into the row above when both
            // have the same key equivalent, so it shares the record key and differs in the modifiers (⌥ alone).
            let last = add(T("app.menu.record_last"), #selector(mStartLast))
            last.keyEquivalent = record.keyEquivalent
            if record.keyEquivalent.isEmpty { record.keyEquivalentModifierMask = [] }
            last.keyEquivalentModifierMask = record.keyEquivalentModifierMask == [.option] ? [.option, .control] : [.option]
            last.isAlternate = true
        }
        addSnapMenuItems(menu, recording: false)
        menu.addItem(.separator())

        // what waits for you, and what is running — each opens the main window there (nothing opens by itself)
        if AppEnvironment.mainWindow != nil {
            add(T("app.menu.open"), #selector(mOpenMain)).showHotkey(.openMain)
            let badge = MenuBadge.shared
            if badge.new > 0 {
                let i = add(TP("app.menu.new", badge.new), #selector(mOpenInbox))
                i.image = Look.ring("new", size: 13)
                i.indentationLevel = 1
            }
            if badge.verify > 0 {
                let i = add(TP("app.menu.to_verify", badge.verify), #selector(mOpenInbox))
                i.image = Look.ring("to_verify", size: 13)
                i.indentationLevel = 1
            }
            for j in JobStore.shared.active.prefix(5) {
                let i = add("\(JobLook.title(j))  ·  \(JobLook.status(j))", #selector(mOpenJob(_:)), obj: j.id)
                i.image = Look.symbol(j.agent?.status == .waitingInput ? "exclamationmark.bubble" : JobLook.symbol(j), "", size: 13)
                i.indentationLevel = 1
            }
            menu.addItem(.separator())
        }

        // the current project (K2): where new captures go
        let store = ProjectStore.shared
        let pItem = NSMenuItem(title: T("app.menu.project", store.current?.name ?? T("project.auto")), action: nil, keyEquivalent: "")
        let pMenu = NSMenu()
        let auto = add(T("project.auto"), #selector(mUseProject(_:)), to: pMenu, obj: nil, on: store.currentID == nil)
        auto.toolTip = T("app.menu.project.auto_tip")
        if !store.projects.isEmpty { pMenu.addItem(.separator()) }
        for p in store.projects.prefix(12) {
            let i = add(p.name, #selector(mUseProject(_:)), to: pMenu, obj: p.id, on: store.currentID == p.id)
            i.image = Look.symbol(p.exists ? "folder" : "questionmark.folder", "", size: 13)
            i.toolTip = (p.path.path as NSString).abbreviatingWithTildeInPath
        }
        pMenu.addItem(.separator())
        add(Loc.t("capture.menu.switch_project", table: "Capture"), #selector(mSwitchProject), to: pMenu).showHotkey(.project)
        _ = add(T("project.open_folder"), #selector(mOpenFolder), to: pMenu)
        pItem.submenu = pMenu
        menu.addItem(pItem)
        menu.addItem(.separator())

        // without the Settings window (a stripped-down build) the shortcuts window is the only place left for ⌘,
        if AppEnvironment.settings != nil { add(T("menu.settings"), #selector(mSettings), key: ",") }
        else { add(T("app.menu.shortcuts"), #selector(mShortcuts), key: ",") }
        if Updater.shared.available {
            let u = add(T("app.menu.updates"), Updater.shared.canCheck ? #selector(Updater.checkForUpdates(_:)) : nil)
            u.target = Updater.shared
        }
        menu.addItem(.separator())
        _ = add(T("app.menu.quit"), #selector(mQuit), key: "q")
    }

    @objc func mOpenMain() { AppEnvironment.mainWindow?.show() }
    @objc func mOpenInbox() { AppEnvironment.mainWindow?.showInbox() }
    @objc func mOpenJob(_ it: NSMenuItem) { (it.representedObject as? String).map { AppEnvironment.mainWindow?.reveal(job: $0) } }
    @objc func mSettings() { AppEnvironment.settings?.show(pane: nil) }
    @objc func mDictationSetup() { Dictation.shared.openSetup(from: "menu") }

    /// The menu row's small warning sign (BlurtIcon.warning), in the system's orange so it stands out from the rows.
    static let warningImage: NSImage = {
        let w = BlurtIcon.warning.menuImage
        let im = NSImage(size: w.size, flipped: false) { r in
            w.draw(in: r)
            NSColor.systemOrange.set()
            r.fill(using: .sourceAtop)
            return true
        }
        im.accessibilityDescription = w.accessibilityDescription
        return im
    }()
    @objc func mStart() { startRecording(useLast: false) }
    @objc func mStartLast() { startRecording(useLast: true) }
    @objc func mStop() { command("stop") }
    @objc func mPause() { command("toggle") }
    @objc func mRestart() { command("restart") }
    @objc func mDiscard() { command("discard") }
    @objc func mUseProject(_ it: NSMenuItem) {
        let id = it.representedObject as? String
        Task { @MainActor in
            do { try await ProjectStore.shared.use(id) }
            catch { self.toast(T("main.error.generic")) }
        }
    }
    @objc func mOpenFolder() {
        if let mw = AppEnvironment.mainWindow { mw.show(); MainWindowController.shared.openFolder() }
    }
    @objc func mShortcuts() { if let s = AppEnvironment.settings { s.show(pane: "shortcuts") } else { HotkeySettings.shared.show() } }
    @objc func mQuit() { NSApp.terminate(nil) }

    // tiny, non-blocking toast under the menu bar (no notification permission needed)
    var toastWin: NSWindow?
    /// Several lines ("\n") are fine: the first is the headline, the rest a quieter detail.
    func toast(_ text: String, seconds: Double = 4.5, icon: BlurtIcon? = nil) {
        let seconds = max(seconds, Double(ProcessInfo.processInfo.environment["BLURT_TOAST_MIN_SECONDS"] ?? "") ?? 0)   // tests: time to screenshot
        toastWin?.orderOut(nil)
        emit(["event": "toast", "text": text])
        let f = NSFont.systemFont(ofSize: 13, weight: .medium)
        let lines = text.components(separatedBy: "\n")
        let body = NSMutableAttributedString(attributedString: icon.map { $0.label(lines[0], font: f, color: .white) }
                                             ?? NSAttributedString(string: lines[0], attributes: [.font: f, .foregroundColor: NSColor.white]))
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
        a.messageText = T("app.permission.title")
        a.informativeText = T("app.permission.detail")
        a.addButton(withTitle: T("app.permission.open_settings"))
        a.addButton(withTitle: T("app.menu.quit"))
        a.addButton(withTitle: T("app.permission.later"))
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
