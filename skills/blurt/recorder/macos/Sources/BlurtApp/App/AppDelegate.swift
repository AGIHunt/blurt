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
        case .voice, .project, .voiceEsc, .cards, .cardsEsc, .dictationEsc, .reformat: captureHotkey(k)     // K7 (P5, SnapApp.swift)
        }
        // voice input started or stopped: the chick pulses now, not at the idle timer's next tick
        if k == .voice || k == .voiceEsc { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.refreshStatus() } }
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
        refreshStatus()                 // the clock's timer (twice a second) from here
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
        LaunchMessages.shared.start()   // at most one island message at launch: everything below posts through it
        for (name, active) in [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in App.activeSince = active ? Date() : nil }
        }
        FilePrivacy.lockDown()          // Blurt's data is this account's alone (0700 / 0600)
        Config.shared.onUnreadable = { bak in DispatchQueue.main.async { App.configUnreadable(bak) } }
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
            b.image = img ?? self.menuIcon
        }
        refreshStatus()                 // and schedules its own timer (scheduleStatusTimer)
        sessionEnded = { [weak self] code, event in
            emit(event)
            self?.takeEnded(code, event)
        }
        // A second launch (double-click the app again) → bring up the running instance's main window
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.blurt.recorder.start"), object: nil, queue: .main) { [weak self] _ in
            guard let self = self, !self.busy else { return }
            self.openFromLaunch()
        }
        startSnapMode()                 // the perch, a batch left from last time, test commands (SnapApp.swift)
        Dictation.shared.install()      // the dictation key (right ⌥ / Fn), history retention
        // the setup assistant greets a first run itself: no second hello next to it
        let assisted = Onboarding.needed && ProcessInfo.processInfo.environment["BLURT_NO_ONBOARDING"] == nil
        MainActor.assumeIsolated { ModelDownloads.shared.resumeAtLaunch() }    // a download a quit or a crash cut short carries on
        watchOtherInstances()
        if recordConfig()["welcomed"] == nil, !assisted {
            postWelcome()
        } else {
            // a shortcut another app holds: the first line, and the way to change it (the reason is in Settings)
            Hotkeys.shared.warnOnce { text in
                var t = Island.Toast(text: text.components(separatedBy: "\n")[0], actionTitle: T("app.toast.change_shortcut")) {
                    AppEnvironment.settings?.show(pane: SettingsPane.shortcuts.rawValue)
                }
                t.seconds = 8
                LaunchMessages.shared.post(.shortcuts, t)
            }
        }
        // `--process <session dir> [--agent <id>]`: process an existing recording (also handy for testing);
        // `--review <url> --review-session <dir>`: review.py asked for its batch (we weren't running) → the main window
        let args = CommandLine.arguments
        func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if let p = arg("--process") {
            process(URL(fileURLWithPath: p), only: arg("--agent"))
        } else if let s = arg("--review-session") {
            ReviewHandoff.show(url: arg("--review"), session: s)
        } else if !args.contains("--background") && !App.launchedAtLogin {
            openFromLaunch()
        }
    }

    /// The first launch's line (BlurtCore WelcomeLine): where Blurt lives and only keys that work now — dictation's key
    /// once it is heard and has a model (else how to get there, with its button), the snap / record keys when they are
    /// registered, and a shortcut that doesn't work named on the same line. Marked welcomed once it was seen.
    func postWelcome() {
        Task { @MainActor in
            await DictationModels.shared.load()         // has dictation a speech model?
            let d: WelcomeLine.Dictation = !Dictation.enabled ? .off : Dictation.shared.needsSetup ? .needsSetup
                : DictationModels.shared.dictationReady == false ? .noModel : .works
            func working(_ a: HotAction) -> String? { Hotkeys.shared.state(a) == .ok ? hk(a) : nil }
            let conflicts = Hotkeys.shared.conflicts.map { Hotkeys.shared.label($0) }
            let line = WelcomeLine.compose(dictation: d, dictationKey: Dictation.keyShort, snap: working(.snap),
                                           record: working(.toggleRecord), conflicts: conflicts)
            var text = Loc.format(Loc.string(line.key, table: "Main"), line.args)
            if !line.conflicts.isEmpty {
                text += " · " + Loc.t("capture.keys.wont_work", table: "Capture", ListFormatter.localizedString(byJoining: line.conflicts))
            }
            var t: Island.Toast
            switch line.action {
            case .turnOnDictation?:
                t = Island.Toast(text: text, actionTitle: T("app.toast.welcome_setup.action")) { Dictation.shared.openSetup(from: "welcome") }
            case .downloadModel?:
                t = Island.Toast(text: text, actionTitle: T("app.toast.welcome_no_model.action")) { Dictation.shared.downloadModel(via: "welcome") }
            case .changeShortcut?:
                t = Island.Toast(text: text, actionTitle: T("app.toast.change_shortcut")) {
                    AppEnvironment.settings?.show(pane: SettingsPane.shortcuts.rawValue)
                }
            case nil:
                t = Island.Toast(text: text, actionTitle: nil, action: nil)
            }
            t.seconds = 7
            emit(["event": "welcome_line", "key": line.key, "dictation": "\(d)", "conflicts": line.conflicts])
            LaunchMessages.shared.post(.welcome, t) {
                setRecordConfig("welcomed", true)
                Hotkeys.shared.markWarned()             // the conflicts were named here: no second line for them
            }
        }
    }

    /// Another Blurt (a dev build next to a release, `open -n`) quitting: its hotkeys and the dictation key come over
    /// to this one. Again 3 s after launch, for one that started at the same moment and hadn't published yet.
    func watchOtherInstances() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                                          queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  FileManager.default.fileExists(atPath: HotkeyCenter.registryDir.appendingPathComponent("\(app.processIdentifier).json").path)
                    || app.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { App.otherInstancesChanged("quit \(app.processIdentifier)") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { App.otherInstancesChanged("launch") }
    }

    static func otherInstancesChanged(_ why: String) {
        let before = Hotkeys.shared.states
        Hotkeys.shared.apply()
        Dictation.shared.checkOwner(via: why)
        if before != Hotkeys.shared.states { emit(["event": "hotkeys_reapplied", "why": why, "taken": Hotkeys.shared.conflicts.map(\.rawValue)]) }
    }

    /// Opening the app (Finder, Dock, Spotlight, a second launch) shows the main window; recording starts from the
    /// menu or ⌥⇧R. The one-shot recorder (`record.py start`, not resident) still records straight away.
    func openFromLaunch() {
        if resident, let mw = AppEnvironment.mainWindow { mw.show(); NSApp.activate(ignoringOtherApps: true) }
        else if !busy { startRecording(useLast: false) }
    }

    /// Started by "Open at Login": stay in the menu bar.
    static let launchedAtLogin: Bool = {
        let e = NSAppleEventManager.shared().currentAppleEvent
        return e?.eventID == kAEOpenApplication
            && e?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }()

    /// review.py started by an agent in a terminal asks for its batch (dev.blurt.recorder.review {url, session, home}):
    /// the user asked for that review, so the batch opens in the main window — the only window that ever shows one —
    /// and review.py hears back that it did, and later that it was confirmed (ReviewHandoff).
    func listenForReviews() {
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.blurt.recorder.review"), object: nil, queue: .main) { n in
            guard let info = n.userInfo, let s = info["session"] as? String else { return }
            if let home = info["home"] as? String, !home.isEmpty,
               URL(fileURLWithPath: home).standardizedFileURL.path != blurtHome.standardizedFileURL.path { return }
            ReviewHandoff.show(url: info["url"] as? String, session: s)
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
        MainActor.assumeIsolated { ModelDownloads.shared.atQuit() }   // the setup ends now; the next launch carries on
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
            case "record": if resident && !busy { confirmFromURL("record") { $0.startRecording(useLast: false) } }
            case "snap": if resident { confirmFromURL("snap") { _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { snapper.hotkey() } } }
            default: break
            }
        }
    }

    /// When Blurt last became the active app (nil while it isn't): confirmFromURL.
    static var activeSince: Date?

    /// blurt://record and blurt://snap can come from any link (a web page, a document): unless Blurt itself was in front
    /// already (its own windows, a shortcut run from Blurt), the island asks first — one click to go ahead. "Already":
    /// opening a URL can bring Blurt to the front just before it arrives, so being active only counts from a second
    /// before the URL.
    func confirmFromURL(_ what: String, _ go: @escaping (App) -> Void) {
        if NSApp.isActive, let s = App.activeSince, Date().timeIntervalSince(s) > 1 { go(self); return }
        emit(["event": "url_confirm", "what": what])
        guard island.started else { return }       // no island to ask in: nothing starts from a link
        island.ask(T("app.url.ask_\(what)"), T(what == "record" ? "app.menu.record" : "app.url.snap"), { [weak self] in
            emit(["event": "url_confirmed", "what": what])
            if let self = self { go(self) }
        }, T("settings.privacy.cancel"), {
            emit(["event": "url_declined", "what": what])
        })
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !busy { openFromLaunch() }
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
            toast(T("app.toast.saved", Loc.duration(dur)), icon: .check)
        }
        refreshStatus()
    }

    /// The status item: the clock while recording, the chick (moving while voice input listens) and the count of what
    /// waits for you otherwise. It only touches the button when something it shows changed, and its timer runs twice
    /// a second only while a recording's clock or voice input needs it — every 2 s otherwise (an idle menu-bar app
    /// shouldn't keep the CPU awake).
    func refreshStatus() {
        defer { scheduleStatusTimer() }
        guard let b = statusItem?.button else { return }
        let image: NSImage, title: NSAttributedString, tip: String?, ax: String
        if let r = rec, r.sessionStart.isValid {
            // the tape is rolling: the rec dot and time; paused: attention (§3.6)
            image = r.isPaused ? App.pausedImage : App.recordingImage
            title = NSAttributedString(string: " " + Loc.duration(r.elapsed()), attributes: [
                .foregroundColor: r.isPaused ? BrandColor.attn : BrandColor.rec, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)])
            tip = nil
            ax = T("app.name")
        } else {
            MenuGlyph.shared.listening = VoiceInput.shared.active
            image = MenuGlyph.shared.current ?? menuIcon
            let badge = MenuBadge.shared
            // K4: the count of what waits for you, next to the icon; nothing at all when there is nothing
            title = badge.count > 0
                ? NSAttributedString(string: " " + Loc.number(badge.count), attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: badge.urgent ? BrandColor.attn : NSColor.labelColor])
                : NSAttributedString(string: "")
            tip = badge.tooltip
            ax = badge.count > 0 ? T("app.status.ax_count", badge.tooltip) : T("app.name")
        }
        if b.image !== image { b.image = image }
        if b.imagePosition != .imageLeft { b.imagePosition = .imageLeft }
        if shownTitle != title { b.attributedTitle = title; shownTitle = title }
        if b.toolTip != tip { b.toolTip = tip }
        if shownAX != ax { b.setAccessibilityLabel(ax); shownAX = ax }
    }
    private var shownTitle: NSAttributedString?
    private var shownAX: String?

    static let recordingImage = BlurtIcon.recordFill.image(size: 11, color: BrandColor.rec)
    static let pausedImage = BlurtIcon.pauseFill.image(size: 11, color: BrandColor.attn)

    func scheduleStatusTimer() {
        guard statusItem != nil else { return }
        let want: TimeInterval = rec != nil || VoiceInput.shared.active ? 0.5 : 2
        guard statusTimer?.timeInterval != want else { return }
        statusTimer?.invalidate()
        let t = Timer(timeInterval: want, repeats: true) { [weak self] _ in self?.refreshStatus() }
        t.tolerance = want / 5
        RunLoop.main.add(t, forMode: .common)
        statusTimer = t
    }

    /// The menu-bar icon at rest: the monochrome template chick (below), like every other menu-bar icon. The recording
    /// state (red dot / pause) replaces it.
    lazy var menuIcon: NSImage = App.makeMenuIcon()

    /// The `menuglyph` self-test: the button as it looks with its menu open (highlighted), without opening it.
    func testMenuOpen(_ open: Bool) {
        statusItem?.button?.highlight(open)
        refreshStatus()
    }

    /// The `blurt` glyph (assets/icons/blurt.svg — the same mark as the Tauri tray): the 4A line chick with its sound
    /// arcs, a 1.5 pt line drawn on the 18 pt grid (assets/brand/chick.swift), as a monochrome template image like every
    /// other menu-bar icon: macOS tints it for light, dark and highlighted bars, and it is vector, so it is crisp at
    /// every scale.
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
            App.giveSymbols(menu)
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
        // a model download runs: where it is (live while the menu is open), with Show and Stop
        if let title = MainActor.assumeIsolated({ ModelDownloads.shared.menuTitle }) {
            let it = add(title, nil)
            it.image = App.menuSymbol("arrow.down.circle")
            let sub = NSMenu()
            add(T("app.models.show"), #selector(mShowDownloads), to: sub)
            add(T("app.models.stop"), #selector(mStopDownloads), to: sub)
            it.submenu = sub
            downloadItem = it
            menu.addItem(.separator())
        }
        // the skill and the app don't speak the same contract: says so until it's fixed (Settings → General too)
        if let m = SkillContract.check(skill: SkillContract.skillVersion()) {
            let it = add(T(m.appIsOlder ? "app.contract.app_older" : "app.contract.skill_older"), #selector(mContractHelp))
            it.image = App.warningImage
            it.toolTip = T("app.contract.how")
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
            // the inbox in one row: "Inbox · 9 new · 6 to verify"
            let badge = MenuBadge.shared
            let counts = (badge.new > 0 ? [T("main.inbox.new", badge.new)] : []) + (badge.verify > 0 ? [T("main.inbox.verify", badge.verify)] : [])
            if !counts.isEmpty { add(([T("main.place.inbox")] + counts).joined(separator: " · "), #selector(mOpenInbox)) }
            for j in JobStore.shared.active.prefix(5) {
                let i = add("\(JobLook.title(j)) · \(JobLook.status(j))", #selector(mOpenJob(_:)), obj: j.id)
                i.image = App.menuSymbol(j.agent?.status == .waitingInput ? "exclamationmark.bubble" : JobLook.symbol(j))
            }
            menu.addItem(.separator())
        }

        // the current project (K2): where new captures go
        let store = ProjectStore.shared
        let pItem = NSMenuItem(title: T("app.menu.project", store.current?.name ?? T("project.auto")), action: nil, keyEquivalent: "")
        let pMenu = NSMenu()
        let auto = add(T("project.auto"), #selector(mUseProject(_:)), to: pMenu, obj: nil, on: store.currentID == nil)
        auto.toolTip = T("app.menu.project.auto_tip")
        auto.image = App.menuSymbol("sparkles")         // like the island's chip
        if !store.projects.isEmpty { pMenu.addItem(.separator()) }
        for p in store.projects.prefix(12) {
            let i = add(p.name, #selector(mUseProject(_:)), to: pMenu, obj: p.id, on: store.currentID == p.id)
            i.image = App.menuSymbol(p.exists ? "folder" : "questionmark.folder")
            i.toolTip = (p.path.path as NSString).abbreviatingWithTildeInPath
        }
        pMenu.addItem(.separator())
        add(Loc.t("capture.menu.switch_project", table: "Capture"), #selector(mSwitchProject), to: pMenu).showHotkey(.project)
        _ = add(T("project.open_folder"), #selector(mOpenFolder), to: pMenu)
        App.giveSymbols(pMenu)
        pItem.submenu = pMenu
        menu.addItem(pItem)
        menu.addItem(.separator())

        // without the Settings window (a stripped-down build) the shortcuts window is the only place left for ⌘,
        if AppEnvironment.settings != nil { add(T("menu.settings"), #selector(mSettings), key: ",") }
        else { add(T("app.menu.shortcuts"), #selector(mShortcuts), key: ",") }
        if Updater.shared.available {
            let u = add(T("app.menu.updates"), Updater.shared.canCheck ? #selector(Updater.checkForUpdates(_:)) : nil)
            u.target = Updater.shared
            u.image = App.menuSymbol("arrow.down.circle")   // with no action giveSymbols can't tell which row it is
        }
        menu.addItem(.separator())
        _ = add(T("app.menu.quit"), #selector(mQuit), key: "q")
        App.giveSymbols(menu)
    }

    /// Every row of the menu carries a symbol, so every title starts at the same inset: AppKit lines a group's titles
    /// up past the image column as soon as one row in it has an image, which left some rows at the edge and others an
    /// icon's width in. By action (the snap rows are added in SnapApp.swift); rows that set their own image keep it.
    static func giveSymbols(_ menu: NSMenu) {
        let symbols = [
            "mStart": "record.circle", "mStartLast": "record.circle", "mStop": "stop.circle", "mPause": "playpause",
            "mRestart": "arrow.counterclockwise", "mDiscard": "trash", "mSnap": "camera.viewfinder", "mVoice": "mic",
            "mLiveCaption": "captions.bubble", "mDictationHistory": "character.cursor.ibeam", "mShowCards": "rectangle.stack",
            "mShowTaken": "clock.arrow.circlepath", "mOpenMain": "macwindow", "mOpenInbox": "tray", "mSettings": "gearshape",
            "mShortcuts": "keyboard", "checkForUpdates:": "arrow.down.circle", "mQuit": "power",
            "mSwitchProject": "arrow.left.arrow.right", "mOpenFolder": "folder.badge.plus",
        ]
        for it in menu.items where !it.isSeparatorItem && it.image == nil {
            if it.submenu != nil { it.image = menuSymbol("folder"); continue }      // Project: …
            if let a = it.action, let s = symbols[NSStringFromSelector(a)] { it.image = menuSymbol(s) }
            if it.image == nil { it.image = blankSymbol }   // a row no symbol names still starts where the others do
        }
    }

    static func menuSymbol(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }
    /// An empty image a symbol's size: holds a row's title in line when it has no symbol of its own.
    static let blankSymbol: NSImage = {
        let size = menuSymbol("circle")?.size ?? NSSize(width: 16, height: 16)
        return NSImage(size: size, flipped: false) { _ in true }
    }()

    @objc func mOpenMain() { AppEnvironment.mainWindow?.show() }
    @objc func mOpenInbox() { AppEnvironment.mainWindow?.showInbox() }
    @objc func mOpenJob(_ it: NSMenuItem) { (it.representedObject as? String).map { AppEnvironment.mainWindow?.reveal(job: $0) } }
    @objc func mSettings() { AppEnvironment.settings?.show(pane: nil) }
    @objc func mDictationSetup() { Dictation.shared.openSetup(from: "menu") }
    @objc func mShowDownloads() { MainActor.assumeIsolated { ModelDownloads.showProgress() } }
    @objc func mStopDownloads() { MainActor.assumeIsolated { ModelDownloads.shared.stop() } }
    @objc func mContractHelp() { Housekeeping.contractHelp() }
    /// The menu's download row while the menu is open (its title follows the progress).
    weak var downloadItem: NSMenuItem?

    /// The menu row's small warning sign (BlurtIcon.warning), in attention amber so it stands out from the rows.
    static let warningImage: NSImage = {
        let w = BlurtIcon.warning.menuImage
        let im = NSImage(size: w.size, flipped: false) { r in
            w.draw(in: r)
            BrandColor.attn.set()
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

    /// One toast system: the island's quiet line (K4), whenever the island runs — one line, so several lines join
    /// with " · ". The small HUD under the menu bar below is only for a build without the island (the one-shot
    /// recorder a chat starts); there several lines are fine: the first is the headline, the rest a quieter detail.
    /// `icon: .check` is a done toast, in the island or the HUD: the check in ok green (§2.3).
    func toast(_ text: String, seconds: Double = 4.5, icon: BlurtIcon? = nil) {
        if island.started {
            emit(["event": "toast", "text": text, "via": "island"])
            var t = Island.Toast(text: text.components(separatedBy: "\n").filter { !$0.isEmpty }.joined(separator: " · "),
                                 actionTitle: nil, action: nil)
            t.seconds = seconds
            t.icon = icon
            island.toast(t)
            return
        }
        hudToast(text, seconds: seconds, icon: icon)
    }

    /// Settings can't be saved: config.json doesn't parse (a hand edit?). It was copied aside; the file stays as it is.
    static func configUnreadable(_ backup: URL) {
        emit(["event": "config_unreadable", "backup": backup.path])
        var t = Island.Toast(text: T("app.config.unreadable"), actionTitle: T("action.reveal_in_finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([BlurtPaths.config])
        }
        t.seconds = 10
        LaunchMessages.shared.post(.config, t)
    }

    // tiny, non-blocking toast under the menu bar (no notification permission needed) — only without the island
    var toastWin: NSWindow?
    func hudToast(_ text: String, seconds: Double = 4.5, icon: BlurtIcon? = nil) {
        let seconds = max(seconds, Double(ProcessInfo.processInfo.environment["BLURT_TOAST_MIN_SECONDS"] ?? "") ?? 0)   // tests: time to screenshot
        toastWin?.orderOut(nil)
        emit(["event": "toast", "text": text])
        let f = NSFont.systemFont(ofSize: 13, weight: .medium)
        let lines = text.components(separatedBy: "\n")
        let body = NSMutableAttributedString(attributedString: icon.map { $0.label(lines[0], font: f, color: .white,
                                                                                  iconColor: $0 == .check ? BrandColor.Island.ok : nil) }
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
            // the permission guide (Blurt in the list, the pane, the helper panel with Restart Blurt); a grant macOS
            // already reports (an older build's): just the pane, to remove and add Blurt again
            if SystemAccess.granted(.screen) { SystemAccess.openPane(.screen) } else {
                MainActor.assumeIsolated { PermissionGuide.shared.start(.all, only: [.screen], source: .capture) }
            }
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
