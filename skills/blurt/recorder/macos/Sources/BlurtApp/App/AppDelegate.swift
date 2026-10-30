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
    /// Organising / AI fill-in runs in flight: job id → the process group of the agent's shell (ProcessGroup). They
    /// stop with the app (applicationWillTerminate); a crash leaves them for the next launch to stop.
    var organisers: [String: pid_t] = [:]
    /// The quit came from SIGTERM / SIGINT (a script, a logout): no question to ask.
    var quitBySignal = false
    var statusTimer: Timer?
    var lastSession: URL?
    /// when the take in `lastSession` was started (a failed take's meta.json says so)
    var takeStartedAt: Date?
    /// where the take in `lastSession` goes — decided when it starts, so a project located (or switched) during the
    /// take doesn't make its meta.json name another project than the store it is in. nil: Unassigned.
    var takeProject: Project?

    var resident: Bool { opts.standalone }

    func applicationDidFinishLaunching(_ n: Notification) {
        CloudSpeech.install()
        UVSetup.ensure(via: "launch")           // quietly, only when no usable uv is there (first-minute-speech.md)
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in
                guard let self = self else { return }
                // (from the run loop, not this main-queue block: quitting waits for captures on the main queue)
                if self.rec != nil { self.command("stop") } else if !self.resident { self.command("stop") } else {
                    self.quitBySignal = true
                    RunLoop.main.perform { NSApp.terminate(nil) }
                }
            }
            s.resume()
            signalSources.append(s)
        }
        if let l = opts.lang { Loc.setting = l }
        // a release app's own skill where its scripts run from (~/.blurt/skill), before anything runs one
        switch BundledSkill.syncAtLaunch() {
        case .success(let copied)?: if copied { emit(["event": "skill_synced", "to": BundledSkill.installed.path]) }
        case .failure(let e)?: NSLog("blurt: copying the bundled skill: \(e)"); emit(["event": "skill_synced", "error": "\(e)"])
        case nil: break
        }
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
                    sessionEnded(3, ["event": "error", "code": "screen_permission", "message": err.localizedDescription,
                                     "reason": RecordingFailure.permission.rawValue])
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
        case .pickEsc: picker?.finish(false); ScreenTextCopy.shared.cancel()
        case .pickFull: picker?.fullScreen()
        case .pickLast: picker?.useLast()
        case .voice, .project, .voiceEsc, .cards, .cardsEsc, .dictationEsc, .reformat, .text, .translateText, .translateEsc: captureHotkey(k)     // K7 (P5, SnapApp.swift)
        }
        // voice input started or stopped: the menu-bar Peep follows now, not at the idle timer's next tick
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
            unregisterHotkey(.pickEnter); unregisterHotkey(.pickEsc); unregisterHotkey(.pickFull); unregisterHotkey(.pickLast)
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
                sessionEnded(3, ["event": "error", "code": "setup", "message": err.localizedDescription,
                                 "reason": RecordingFailure.reason(code: "setup", error: err).rawValue])
                return
            }
            self.countdown(opts.countdown, over: region) {
                r.start()
                if self.resident, let dir = self.lastSession { launchLive(dir) }
            }
        }
    }

    func countdown(_ n: Int, over region: CGRect, hold: Bool = false, of total: Int? = nil, then: @escaping () -> Void) {
        guard n > 0 else { return then() }
        let v = CountdownView()
        v.total = max(n, total ?? n)
        let r = toNS(region)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: r.midX, y: r.midY)) })?.frame
        let w = overlayWindow(OverlayFit.frame(region: r, panel: v.panelSize, margin: CountdownView.panelMargin, screen: screen),
                              view: v)
        w.ignoresMouseEvents = false
        w.orderFrontRegardless()
        countdownWin = w
        MenuGlyph.shared.countdown = true            // Peep listens in the menu bar too
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
            MenuGlyph.shared.countdown = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { then() }
        }
        v.onSkip = go
        if hold { v.hold(at: 0.62); return }    // tests: stays at n, its ring part-drained, until `countdown close`
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
        Config.shared.onWriteRefused = { key in DispatchQueue.main.async { App.configWriteRefused(key) } }
        Config.shared.checkReadable()   // a hand edit gone wrong: said at launch (defaults until fixed), not at the first write
        ScreenTextCopy.migrateTranslateConfig()     // ⌥T's own translate settings, once (from dictation's)
        watchNetwork()
        ensureDefaultWorkspace()
        DispatchQueue.global().async { _ = agentEnvironment() }   // ask the login shell now, not when a recording ends
        writeAppInfo()
        Updater.shared.start()
        ProjectStore.shared.watch()
        JobStore.shared.start()
        JobNotifier.shared.start()
        Housekeeping.atLaunch()
        MemoryPressure.shared.start()
        AppEnvironment.process = { [weak self] session, captures, project in self?.process(session, captures: captures, project: project) ?? nil }
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
        watchConfigEdits()
        // an unreadable config.json reads as empty: that's no first launch (its own line says what happened)
        if Config.shared.readable, recordConfig()["welcomed"] == nil, !assisted {
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
        // v1.0.5: the default shortcuts lost their ⇧ (⌥A, ⌥C, ⌥V…). Someone who used the ⌥⇧ ones is told once; a new
        // user never knew them
        if recordConfig()["hotkeys_v2"] == nil {
            if recordConfig()["welcomed"] == nil || assisted {
                setRecordConfig("hotkeys_v2", true)
            } else {
                var t = Island.Toast(text: T("app.toast.hotkeys_v2", hk(.snap), hk(.text), hk(.voice)),
                                     actionTitle: T("app.toast.change_shortcut")) {
                    AppEnvironment.settings?.show(pane: SettingsPane.shortcuts.rawValue)
                }
                t.seconds = 10
                LaunchMessages.shared.post(.shortcuts, t, shown: { setRecordConfig("hotkeys_v2", true) })
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
                : DictationModels.shared.asrUnreadable ? .unknown : DictationModels.shared.dictationReady == false ? .noModel : .works
            func working(_ a: HotAction) -> String? { Hotkeys.shared.state(a) == .ok ? hk(a) : nil }
            // counted as Settings → Shortcuts counts them: the dictation key another copy listens to is one of them
            let conflicts = Hotkeys.shared.conflicts.map { Hotkeys.shared.label($0) }
                + (HotkeySettings.shared.dictationTaken ? [Dictation.keyShort.trimmingCharacters(in: .whitespaces)] : [])
            let line = WelcomeLine.compose(dictation: d, dictationKey: Dictation.keyShort, snap: working(.snap),
                                           record: working(.toggleRecord), conflicts: conflicts)
            let text = Loc.format(Loc.string(line.key, table: "Main"), line.args)
            // one line, one button: with a more urgent button (turn dictation on, download its model) the shortcut
            // conflicts aren't squeezed in — those keys aren't advertised, and their own line comes at a later launch
            let saysConflicts = line.action == .changeShortcut
            var t: Island.Toast
            switch line.action {
            case .turnOnDictation?:
                t = Island.Toast(text: text, actionTitle: T("app.toast.welcome_setup.action")) { Dictation.shared.openSetup(from: "welcome") }
            case .downloadModel?:
                t = Island.Toast(text: text, actionTitle: T("app.toast.welcome_no_model.action")) { Dictation.getSpeechModel(from: "welcome") }
            case .setUpDictation?:
                t = Island.Toast(text: text, actionTitle: T("app.toast.welcome_not_set_up.action")) { Onboarding.shared.show(step: 2) }
            case .changeShortcut?:
                t = Island.Toast(text: text, actionTitle: T("app.toast.change_shortcut")) {
                    AppEnvironment.settings?.show(pane: SettingsPane.shortcuts.rawValue)
                }
            case nil:
                t = Island.Toast(text: text, actionTitle: nil, action: nil)
            }
            t.seconds = 7
            emit(["event": "welcome_line", "key": line.key, "dictation": "\(d)", "conflicts": line.conflicts])
            LaunchMessages.shared.post(.welcome, t, shown: {
                setRecordConfig("welcomed", true)
                if saysConflicts { Hotkeys.shared.markWarned() }     // named here: no second line for them
            })
        }
    }

    /// What waited for the network carries on once the Mac is back online: a model download a launch kept, the
    /// assistant's speech setup, the model list dictation couldn't read.
    func watchNetwork() {
        let w = NetworkWatch.shared
        w.onBackOnline { MainActor.assumeIsolated { ModelDownloads.shared.backOnline() } }
        w.onBackOnline { Onboarding.shared.backOnline() }
        w.onBackOnline {
            MainActor.assumeIsolated { if DictationModels.shared.asrUnreadable { Dictation.shared.refreshSpeechModels() } }
        }
        w.start()
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
        // a background app's end isn't always announced: while another instance holds something of ours, look every
        // few seconds whether it is still there (its registry entry still live: HotkeyCenter.isLive) — and whether the
        // one that has the dictation key still hears it (it unpublishes the key when its listener goes)
        let t = Timer(timeInterval: 3, repeats: true) { _ in
            var holders = Set(Hotkeys.shared.states.values.compactMap { s -> pid_t? in if case .taken(let p) = s { return p }; return nil })
            let deferred = Dictation.shared.deferredTo
            if let p = deferred { holders.insert(p) }
            guard !holders.isEmpty else { return }
            let alive = Set(Hotkeys.shared.otherInstances().map(\.pid))
            if holders.contains(where: { !alive.contains($0) }) { App.otherInstancesChanged("gone") }
            else if let p = deferred, Hotkeys.shared.dictationOwner(Dictation.key.rawValue) != p { App.otherInstancesChanged("owner") }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
    }

    /// BA-49: shortcuts and the dictation key changed outside Settings (~/.blurt/config.json by hand or by an agent)
    /// work without a relaunch: looked at when Blurt comes to the front and every 2 s (Config caches by the file's
    /// signature: a look is a stat()). Settings' own writes load themselves, so they never count twice.
    func watchConfigEdits() {
        func look(_ via: String) {
            // a file that stopped parsing: the last good settings stay (Config keeps them), the bad version is copied
            // aside and the island says so once — never the defaults registered over the user's own keys
            guard Config.shared.checkReadable() else { return }
            if Hotkeys.shared.reloadIfChanged() { emit(["event": "hotkeys_reloaded", "via": via, "taken": Hotkeys.shared.conflicts.map(\.rawValue)]) }
            Dictation.shared.reloadIfChanged()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in look("activate") }
        let t = Timer(timeInterval: 2, repeats: true) { _ in look("timer") }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
    }

    static func otherInstancesChanged(_ why: String) {
        let before = Hotkeys.shared.states
        Hotkeys.shared.apply()
        Dictation.shared.checkOwner(via: why)
        if before != Hotkeys.shared.states { emit(["event": "hotkeys_reapplied", "why": why, "taken": Hotkeys.shared.conflicts.map(\.rawValue)]) }
    }

    /// Opening the app (Finder, Dock, Spotlight, a second launch) shows the main window; recording starts from the
    /// menu or ⌥R. The one-shot recorder (`record.py start`, not resident) still records straight away.
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

    /// Quitting (the menu, an update's relaunch, logging out, SIGTERM) never loses a capture on its way: the open note
    /// is saved, a voice note finished, words and filings get a moment, shots.jsonl is flushed (Snapper.prepareForQuit;
    /// at most ~3 s). What is still on its way comes back at the next launch (Snapper.restore).
    /// Quitting while an agent organises a recording stops it (it would go on spending tokens unseen and write items
    /// after the app said it failed): ask first, as a Mac app asks before it drops work in progress — not on a
    /// logout, restart or shutdown (the quit Apple Event carries kAEQuitReason: a modal would hold the Mac up behind
    /// it) nor on SIGTERM / SIGINT; the organisers stop all the same (applicationWillTerminate) and their jobs say so.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard resident, !quitting else { App.terminating = true; return .terminateNow }
        if !organisers.isEmpty, !quitBySignal, !Self.quitBySystem {
            let jobs = organisers.keys.compactMap { JobStore.shared.job($0) }
            let a = NSAlert()
            a.messageText = jobs.count == 1 ? JobLook.quitTitle(jobs[0]) : T("app.quit.organizing.title_n", jobs.count)
            a.informativeText = T("app.quit.organizing.detail")
            // Return keeps the work going: Cancel is the default, Quit Anyway the destructive second choice
            a.addButton(withTitle: T("action.cancel"))
            let quit = a.addButton(withTitle: T("app.quit.organizing.quit"))
            quit.hasDestructiveAction = true
            quit.keyEquivalent = ""
            a.buttons[0].keyEquivalent = "\r"
            activateApp()
            guard a.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        quitting = true
        App.terminating = true
        // a dictation listening or on its way is typed, or kept as interrupted with Retry (never lost), then the
        // captures' own work
        Dictation.shared.prepareForQuit { snapper.prepareForQuit { NSApp.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }
    private var quitting = false
    /// The app is on its way out (the quit was not cancelled): windows closing now are not the user closing them —
    /// the setup assistant isn't "skipped" by a quit (Onboarding.windowWillClose).
    static private(set) var terminating = false

    /// The quit comes from a logout, restart or shutdown.
    static var quitBySystem: Bool {
        guard let e = NSAppleEventManager.shared().currentAppleEvent, e.eventClass == kCoreEventClass,
              e.eventID == kAEQuitApplication else { return false }
        return e.attributeDescriptor(forKeyword: kAEQuitReason) != nil
    }

    /// Every organiser still running stops with the app — together, one grace period — and its job says so.
    func stopOrganisers() {
        let groups = organisers
        organisers.removeAll()
        guard !groups.isEmpty else { return }
        for g in groups.values { killpg(g, SIGTERM) }
        let deadline = Date().addingTimeInterval(1.5)
        while groups.values.contains(where: ProcessGroup.alive), Date() < deadline { usleep(50_000) }
        for g in groups.values where ProcessGroup.alive(g) { killpg(g, SIGKILL) }
        for id in groups.keys { Housekeeping.markInterrupted(id, hint: "main.job.hint.stopped_at_quit") }
        emit(["event": "organisers_stopped", "jobs": Array(groups.keys)])
    }

    func applicationWillTerminate(_ notification: Notification) {
        App.terminating = true
        guard resident else { return }
        stopOrganisers()
        Housekeeping.atQuit()
        MainActor.assumeIsolated { ModelDownloads.shared.atQuit() }   // the setup ends now; the next launch carries on
        Hotkeys.shared.unpublish()
        let f = blurtHome.appendingPathComponent("app.json")
        if let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           o["pid"] as? Int == Int(getpid()) { try? FileManager.default.removeItem(at: f) }
    }

    /// The menu-bar icon can be hidden behind the notch on a crowded menu bar — ⌥B shows the same menu at the pointer.
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
        MissingFolder.warnIfCurrentMissing(recording: true)     // its folder is gone: this one goes to Unassigned
        let target = ProjectStore.shared.captureTarget
        let dir = newSessionDir(in: target)
        takeProject = target.isInbox ? nil : target
        // little room left: say so before the take, not after it failed (BlurtCore RecordingFailure.lowSpace)
        let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        if RecordingFailure.lowSpace(freeBytes: free), let f = free {
            emit(["event": "record_low_space", "free_bytes": f])
            island.toast(T("app.record.low_space", ByteCountFormatter.string(fromByteCount: f, countStyle: .file)), key: "record-low-space", seconds: 6)
        }
        opts.out = dir.appendingPathComponent("recording.mp4").path
        opts.events = dir.appendingPathComponent("events.jsonl").path
        opts.lastRegion = lastRegionFromConfig()
        opts.countdown = recordConfig()["countdown"] as? Int ?? 3
        opts.systemAudio = recordConfig()["system_audio"] as? Bool ?? false
        lastSession = dir
        takeStartedAt = Date()
        busy = true
        if autoProcess {
            AgentHub.shared.check(AgentHub.shared.order(), force: true) { _ in }   // warm the cache while recording
        }
        // no Screen Recording: the island says so, with the permission guide (the snap's way; no alert) — and a grant
        // macOS reports but ScreenCaptureKit refuses (an older build's) is "re-allow Screen Recording" (ScreenHelp)
        guard SystemAccess.granted(.screen) else {
            busy = false
            try? FileManager.default.removeItem(at: dir)
            emit(["event": "record_blocked", "grant": ScreenGrant.missing.rawValue])
            return ScreenHelp.show(.record, grant: .missing)
        }
        ScreenHelp.probe { ok in
            guard ok else {
                self.busy = false
                try? FileManager.default.removeItem(at: dir)
                emit(["event": "record_blocked", "grant": ScreenGrant.stale.rawValue])
                return ScreenHelp.show(.record, grant: .stale)
            }
            if useLast, let r = opts.lastRegion { self.begin(r) } else { self.pick() }
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
            // a failed take keeps what was taken during it — the video up to its last fragment (Recorder writes 4 s
            // fragments), the stills, their notes, the live transcript (BlurtCore TakeEnd); only a cancelled or empty
            // one leaves no folder behind
            let video = dir.appendingPathComponent("recording.mp4")
            Task { @MainActor in
                let played = code == 2 ? 0 : await App.playableSeconds(video)
                self.failedTake(dir, code: code, event: event, video: played)
                self.refreshStatus()
            }
            return
        }
        let dur = event["duration"] as? Double ?? 0
        // where the take went: the capture target when it started (`takeProject`)
        let project = takeProject
        let meta: [String: Any] = [
            "engine": "native-app", "duration": dur, "video": "recording.mp4", "region": event["region"] ?? [],
            "started_at": ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -dur)),
            "author": recordConfig()["author"] as? String ?? NSFullUserName(),
            "project": project?.id as Any? ?? NSNull(),
            "workspace": currentWorkspace().path,
        ]
        var m = meta
        for k in App.errorKeys { if let x = event[k] { m[k] = x } }
        if let e = event["ended_early"] { m["ended_early"] = e }
        if let d = try? JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("meta.json"))
        }
        App.sayRecovered(event, duration: dur)
        if autoProcess {
            process(dir, project: project?.id)
            // where its items go, and the way to put them elsewhere (Refile) — the user's pick, never a guess
            Refile.offerRecording(dir, project: project?.id)
        } else if island.started {
            // the take's end already said "✓ 0:42" in place of the dot (RecordingDone): no second moment for one take
            if !RecordingDone.saidRecently {
                island.doneMoment(T("app.ear.saved", Island.clock(dur)), lead: .record, toast: T("app.toast.saved", Island.clock(dur)))
            }
        } else {
            toast(T("app.toast.saved", Island.clock(dur)), icon: .check)
        }
        refreshStatus()
    }

    /// A saved take that wasn't plain sailing, said once on the island (after its "saved" line): it ended before
    /// Finish ("macOS stopped the recording — the first 3:12 is kept"), or a piece of it was lost while the writer was
    /// replaced ("Saved · the video file failed partway, about 3 s is missing"). Nothing for a capture restarted
    /// without loss.
    static func sayRecovered(_ event: [String: Any], duration: Double) {
        var line: String?
        if let early = event["ended_early"] as? [String: Any] {
            line = T("app.record.partial", App.failureReason(early), Island.clock(duration))
        } else if (event["segments"] as? Int ?? 1) > 1
                    || (event["recovered"] as? [[String: Any]] ?? []).contains(where: { $0["kind"] as? String == "writer" }) {
            let lost = Int((event["lost_seconds"] as? Double ?? 0).rounded(.up))
            line = event["stitch_error"] != nil ? T("app.record.recovered_parts")
                : lost > 0 ? T("app.record.recovered_lost", Loc.number(lost)) : T("app.record.recovered")
        }
        guard let l = line else { return }
        emit(["event": "take_recovered_said", "text": l])
        island.toast(l, key: "record-recovered", seconds: 8)
    }

    private func failedTake(_ dir: URL, code: Int32, event: [String: Any], video: Double) {
        let fm = FileManager.default
        let stills = ((try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent("shots").path)) ?? [])
            .filter { $0.hasSuffix(".png") && !$0.contains(".marked") }.count
        let notes = ["shots.jsonl", "live"].contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        let partial = TakeEnd.keepsVideo(seconds: video)
        if TakeEnd.keepsFolder(code: code, stills: stills, notes: notes, video: partial) {
            // a file that doesn't play isn't kept as if it were the take's video
            if !partial { try? fm.removeItem(at: dir.appendingPathComponent("recording.mp4")) }
            keepFailedTake(dir, code: code, event: event, stills: stills, video: partial ? video : nil)
        } else {
            try? fm.removeItem(at: dir)
            if event["event"] as? String == "error" {
                // the reason in words (BlurtCore RecordingFailure); the raw message is in the log already. Refused by
                // macOS: the way to System Settings, as every other permission question in the app offers it
                // nothing of the take was kept: a loss (critical). Refused: Open System Settings is the way out (the
                // default, Not Now beside it); a take that failed on its own: Record Again beside OK
                let reason = RecordingFailure(rawValue: event["reason"] as? String ?? "") ?? .unknown
                switch reason {
                case .permission:
                    alert(T("app.record.failed"), App.failureText(event), also: (T("settings.perm.open_settings"), {
                        if let u = URL(string: PermissionKind.screen.paneURL) { NSWorkspace.shared.open(u) }
                    }), primary: true, cancel: T("app.alert.not_now"), critical: true)
                case .diskFull:
                    alert(T("app.record.failed"), App.failureText(event), critical: true)
                case .stopped, .noFrames, .unknown, .displayGone, .interrupted, .writer:
                    alert(T("app.record.failed"), App.failureText(event), also: (T("app.record.again"), { [weak self] in
                        self?.startRecording(useLast: true)
                    }), critical: true)
                }
            }
        }
    }

    /// How much of a failed take's video plays (0: none, or no file) — AVFoundation reads the fragments written.
    static func playableSeconds(_ url: URL) async -> Double {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let a = AVURLAsset(url: url)
        guard let d = try? await a.load(.duration), d.isNumeric,
              let tracks = try? await a.loadTracks(withMediaType: .video), !tracks.isEmpty else { return 0 }
        return d.seconds
    }

    /// What the recorder's events say about an error (RecordingFailure.detail) and what a take recovered from —
    /// kept in meta.json as they are.
    static let errorKeys = ["error_domain", "error_code", "error_underlying", "error_message", "error_failure_reason",
                            "recovered", "segments", "lost_seconds", "stitch_error", "parts"]

    /// Why a take failed, for the alert (BlurtCore RecordingFailure; never the raw error).
    static func failureText(_ event: [String: Any]) -> String {
        switch RecordingFailure(rawValue: event["reason"] as? String ?? "") ?? .unknown {
        case .diskFull: return T("app.record.failed.disk_full")
        case .permission: return T("app.record.failed.permission")
        case .stopped: return T("app.record.failed.stopped")
        case .noFrames: return T("app.record.failed.no_frames")
        case .displayGone: return T("app.record.failed.display_gone")
        case .interrupted: return T("app.record.failed.interrupted")
        case .writer: return T("app.record.failed.writer")
        case .unknown: return T("app.record.failed.unknown")
        }
    }

    /// The reason alone, for the island line ("The disk is full — recording not saved · its 2 snaps are kept",
    /// "The disk is full — the first 3:12 is kept").
    static func failureReason(_ event: [String: Any]) -> String {
        switch RecordingFailure(rawValue: event["reason"] as? String ?? "") ?? .unknown {
        case .diskFull: return T("app.record.reason.disk_full")
        case .permission: return T("app.record.reason.permission")
        case .stopped: return T("app.record.reason.stopped")
        case .noFrames: return T("app.record.reason.no_frames")
        case .displayGone: return T("app.record.reason.display_gone")
        case .interrupted: return T("app.record.reason.interrupted")
        case .writer: return T("app.record.reason.writer")
        case .unknown: return T("app.record.reason.unknown")
        }
    }

    /// A recording that couldn't be finished but has something in it — the video up to where it stopped (`video`: its
    /// playable seconds), stills, notes: the folder stays, meta.json says it failed (and names the partial video),
    /// and the island offers to organise what was kept.
    private func keepFailedTake(_ dir: URL, code: Int32, event: [String: Any], stills: Int, video: Double?) {
        let project = takeProject
        var meta: [String: Any] = [
            "engine": "native-app", "state": "failed", "error": event["message"] as? String ?? "",
            "reason": event["reason"] as? String ?? RecordingFailure.unknown.rawValue,
            "started_at": ISO8601DateFormatter().string(from: takeStartedAt ?? Date()),
            "author": recordConfig()["author"] as? String ?? NSFullUserName(),
            "project": project?.id as Any? ?? NSNull(), "workspace": currentWorkspace().path,
        ]
        if let v = video { meta["video"] = "recording.mp4"; meta["duration"] = v; meta["partial"] = true }
        // what exactly went wrong (v0.9-userfix: a take kept only "这项操作无法完成" and reason "unknown")
        for k in App.errorKeys { if let x = event[k] { meta[k] = x } }
        meta["error_code_name"] = event["code"] ?? NSNull()
        if let d = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("meta.json"))
        }
        // (the raw error is in meta.json and the log: the island line says why, in words, and what is kept)
        emit(["event": "take_failed_kept", "session": dir.path, "code": code, "stills": stills, "video": video ?? NSNull(),
              "error": event["message"] as? String ?? NSNull(), "reason": event["reason"] as? String ?? NSNull(),
              "error_domain": event["error_domain"] ?? NSNull(), "error_code": event["error_code"] ?? NSNull(),
              "error_underlying": event["error_underlying"] ?? NSNull()])
        // a headline and a detail line (the island's two-tier toast): what happened, then why and what is kept
        let why = App.failureReason(event)
        let line = video.map { T("app.record.partial_title") + "\n" + why + " · " + T("app.record.partial_kept", Island.clock($0)) }
            ?? T("app.record.not_saved_title") + "\n" + why + " · " + TP("app.record.kept", stills)
        // what the user wants next: the part that was kept — the video's start goes to be organized; a take with only
        // its snaps shows them (not "Organize" right after "not saved")
        var t = video != nil
            ? Island.Toast(text: line, actionTitle: T("app.record.organize")) { [weak self] in self?.process(dir, project: project?.id) }
            : Island.Toast(text: line, actionTitle: TP("app.record.show_snaps", stills)) {
                AppEnvironment.mainWindow?.reveal(session: dir)
            }
        t.icon = .warning
        t.seconds = 12
        island.toast(t)
    }

    /// The status item: the clock while recording, Peep (moving with what Blurt does: MenuGlyph) and the count of what
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
            MenuGlyph.shared.sync()          // Peep: talking while you dictate, listening to a voice note, thinking…
            image = MenuGlyph.shared.current ?? menuIcon
            let badge = MenuBadge.shared
            // K4: the count of what waits for you, next to the icon; nothing at all when there is nothing. No leading
            // space: the button's own image–title gap is enough now that the glyph fills its box (with the space the
            // count sat 6 pt off, looking like a separate item)
            title = badge.count > 0
                ? NSAttributedString(string: Loc.number(badge.count), attributes: [
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

    /// The menu-bar icon at rest: Peep's monochrome template glyph (below), like every other menu-bar icon. The recording
    /// state (red dot / pause) replaces it.
    lazy var menuIcon: NSImage = App.makeMenuIcon()

    /// The `menuglyph` self-test: the button as it looks with its menu open (highlighted), without opening it.
    func testMenuOpen(_ open: Bool) {
        statusItem?.button?.highlight(open)
        refreshStatus()
    }

    /// Peep at rest: the release package's menu-bar glyph (Resources/Peep, idle frame 0) — the sphere with the eye knocked
    /// out and the beak shut, 18 pt, a monochrome template image like every other menu-bar icon: macOS tints it for light,
    /// dark and highlighted bars, with pixels drawn for @1x and @2x. MenuGlyph moves it.
    static func makeMenuIcon() -> NSImage {
        let img = MenuGlyph.shared.frame(.idle, 0) ?? BlurtIcon.blurt.image(size: 18)
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
        // dictation can't work yet: the first row says why and leads to the fix (BlurtCore SpeechSetup.menuRow) — its
        // key isn't heard (permissions), its speech tools aren't set up, or it has no speech model
        let dm = MainActor.assumeIsolated { DictationModels.shared }
        let row = MainActor.assumeIsolated {
            SpeechSetup.menuRow(enabled: Dictation.enabled, deferred: Dictation.shared.deferredTo != nil,
                                needsPermissions: Dictation.shared.needsSetup, ready: dm.dictationReady,
                                readable: !dm.asrUnreadable, downloading: ModelDownloads.shared.active)
        }
        switch row {
        case .turnOn?:
            let d = add(T("dictation.menu.turn_on"), #selector(mDictationSetup))
            d.image = App.warningImage
            d.toolTip = T("dictation.menu.turn_on.tip", Dictation.keyInline)
            if #available(macOS 14.4, *) { d.subtitle = T("dictation.menu.turn_on.subtitle", Dictation.keyInline) }
            menu.addItem(.separator())
        case .setUp?:
            let d = add(T("dictation.menu.set_up"), #selector(mDictationSetUpSpeech))
            d.image = App.warningImage
            if #available(macOS 14.4, *) { d.subtitle = T("dictation.menu.set_up.subtitle") }
            menu.addItem(.separator())
        case .getModel?:
            let size = MainActor.assumeIsolated { dm.dictationJob.map { modelSize($0.sizeMB) } }
            let d = add(T("dictation.menu.get_model"), #selector(mDictationGetModel))
            d.image = App.warningImage
            if #available(macOS 14.4, *) {
                d.subtitle = size.map { T("dictation.menu.get_model.subtitle", $0) } ?? T("dictation.menu.get_model.subtitle_plain")
            }
            menu.addItem(.separator())
        case nil:
            break
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
        // Kept short, like other menu-bar apps, in four groups: the capture verbs (each with its key, in one column),
        // what waits for you (Open Blurt with the inbox's counts as its badge and subtitle, the cards, Recently Dragged
        // Out, Dictation History, running jobs), where new captures go, then the app (Settings, updates; Quit apart).
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

        // what waits for you, and what is running — each opens the main window there (nothing opens by itself). One
        // row opens Blurt: with new items or items to verify it opens the inbox, the new count as its badge and the
        // verify count under it ("6 to verify") — never a second row that opens the same window.
        if AppEnvironment.mainWindow != nil {
            let badge = MenuBadge.shared
            let waiting = badge.new > 0 || badge.verify > 0
            let open = add(T("app.menu.open"), waiting ? #selector(mOpenInbox) : #selector(mOpenMain))
            open.showHotkey(.openMain)
            open.image = App.menuSymbol("macwindow")
            if #available(macOS 14.4, *) {
                if badge.new > 0 { open.badge = NSMenuItemBadge(string: T("main.inbox.new", badge.new)) }     // the window's own words ("9 new"), not the system's
                if badge.verify > 0 { open.subtitle = T("main.inbox.verify", badge.verify) }
            } else if waiting {
                // (macOS 13–14.3: no subtitle) the counts in the title, as the window's subtitle says them
                let counts = (badge.new > 0 ? [T("main.inbox.new", badge.new)] : []) + (badge.verify > 0 ? [T("main.inbox.verify", badge.verify)] : [])
                open.title = ([T("app.menu.open")] + counts).joined(separator: " · ")
            }
        }
        addWaitingMenuItems(menu)
        if AppEnvironment.mainWindow != nil {
            for j in JobStore.shared.active.prefix(5) {
                let i = add("\(JobLook.title(j)) · \(JobLook.status(j))", #selector(mOpenJob(_:)), obj: j.id)
                i.image = App.menuSymbol(j.agent?.status == .waitingInput ? "exclamationmark.bubble" : JobLook.symbol(j))
            }
        }
        menu.addItem(.separator())

        // the current project (K2): where new captures go — the user's pick (recently used first), or none. The row
        // is the project itself (its folder, or Unassigned's tray) under a small "Project" heading; Unassigned leads
        // its submenu, then the projects, then the two ways to more.
        let store = ProjectStore.shared
        let current = store.current
        let pItem: NSMenuItem
        if #available(macOS 14.0, *) {
            menu.addItem(NSMenuItem.sectionHeader(title: T("app.menu.project_header")))
            pItem = NSMenuItem(title: current?.name ?? T("project.inbox"), action: nil, keyEquivalent: "")
        } else {
            pItem = NSMenuItem(title: T("app.menu.project", current?.name ?? T("project.inbox")), action: nil, keyEquivalent: "")
        }
        // one mark per concept, as the island and the sidebar (IslandGlyph.place): the project's coloured folder,
        // Unassigned's dashed ring, a missing folder's question mark
        pItem.image = IslandGlyph.place(current, size: 16)
        let pMenu = NSMenu()
        let none = add(T("project.inbox"), #selector(mUseProject(_:)), to: pMenu, obj: nil, on: store.currentID == nil)
        none.toolTip = T("app.menu.project.none_tip")
        none.image = IslandGlyph.place(nil, size: 16)    // Unassigned, as the island and the sidebar (the tray is the Inbox)
        if !store.projects.isEmpty { pMenu.addItem(.separator()) }
        for p in store.projects.prefix(12) {
            let i = add(p.name, #selector(mUseProject(_:)), to: pMenu, obj: p.id, on: store.currentID == p.id)
            i.image = IslandGlyph.place(p, size: 16)
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
            // a version found in the background and not looked at yet: the row names it
            let found = Updater.shared.pending
            let u = add(found.map { T("app.menu.update_to", $0) } ?? T("app.menu.updates"),
                        Updater.shared.canCheck || found != nil ? #selector(Updater.checkForUpdates(_:)) : nil)
            u.target = Updater.shared
            u.image = App.menuSymbol(found == nil ? "arrow.down.circle" : "arrow.down.circle.fill")   // with no action giveSymbols can't tell which row it is
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
            "mText": "text.viewfinder", "mTranslate": "translate",
            "mLiveCaption": "captions.bubble", "mDictationHistory": "text.bubble", "mShowCards": "rectangle.stack",
            "mShowTaken": "clock.arrow.circlepath", "mOpenMain": "macwindow", "mOpenInbox": "tray", "mSettings": "gearshape",
            "mShortcuts": "keyboard", "checkForUpdates:": "arrow.down.circle", "mQuit": "power",
            "mSwitchProject": "arrow.left.arrow.right", "mOpenFolder": "folder.badge.plus",
        ]
        for it in menu.items where !it.isSeparatorItem && it.image == nil {
            if #available(macOS 14.0, *), it.isSectionHeader { continue }     // a heading sits at the edge, as macOS sets it
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
    @objc func mDictationSetUpSpeech() { Onboarding.shared.show(step: 2) }
    @objc func mDictationGetModel() { Dictation.getSpeechModel(from: "menu") }
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
        // a project whose folder is gone asks where it is first (MissingFolder.use)
        MissingFolder.use(it.representedObject as? String, via: "menu") { [weak self] in self?.toast(T("main.error.generic")) }
    }
    @objc func mOpenFolder() {
        if let mw = AppEnvironment.mainWindow { mw.show(); MainWindowController.shared.openFolder() }
    }
    @objc func mShortcuts() { if let s = AppEnvironment.settings { s.show(pane: "shortcuts") } else { HotkeySettings.shared.show() } }
    @objc func mQuit() { NSApp.terminate(nil) }

    /// One toast system: the island's quiet line (K4), whenever the island runs — the first line the headline, the rest
    /// one quieter detail line under it (joined with " · "). The small HUD under the menu bar below is only for a build without the island (the one-shot
    /// recorder a chat starts); there several lines are fine: the first is the headline, the rest a quieter detail.
    /// `icon: .check` is a done toast, in the island or the HUD: the check in ok green (§2.3).
    /// `undo`: the main window's "Moved … · Undo" — the button is a shortcut to that window's ⌘Z (the HUD has no
    /// button; ⌘Z works all the same). A newer undo toast takes the place of the one on show (`key`).
    func toast(_ text: String, seconds: Double = 4.5, icon: BlurtIcon? = nil, undo: (() -> Void)? = nil) {
        if island.started {
            emit(["event": "toast", "text": text, "via": "island", "undo": undo != nil])
            let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            var t = Island.Toast(text: lines.prefix(1).joined() + (lines.count > 1 ? "\n" + lines.dropFirst().joined(separator: " · ") : ""),
                                 actionTitle: undo == nil ? nil : T("action.undo"), action: undo)
            t.seconds = undo == nil ? seconds : max(seconds, 6)
            t.icon = icon
            if undo != nil { t.key = "main.undo"; t.overOpen = true }
            island.toast(t)
            return
        }
        hudToast(text, seconds: seconds, icon: icon)
    }

    /// config.json doesn't parse (a hand edit?): Blurt and its scripts run on the defaults until it is fixed, and
    /// changes can't be saved. It was copied aside; the file stays as it is. One line at launch, with Show File.
    static func configUnreadable(_ backup: URL) {
        emit(["event": "config_unreadable", "backup": backup.path])
        // broken while Blurt runs: the settings it read last stay; broken at launch: the defaults
        var t = Island.Toast(text: T(Config.shared.keepsLast ? "app.config.unreadable_kept" : "app.config.unreadable"),
                             actionTitle: T("app.config.show")) {
            NSWorkspace.shared.activateFileViewerSelecting([BlurtPaths.config])
        }
        t.seconds = 10
        LaunchMessages.shared.post(.config, t)
    }

    /// A setting couldn't be saved because config.json doesn't parse: once per session, an ordinary line (what the
    /// user just did — the launch line may be long gone, and a launch message would be dropped by then). Not while
    /// the launch's messages are held: the launch line says it in a moment ("can't save").
    private static var writeRefusedSaid = false
    static func configWriteRefused(_ key: String) {
        emit(["event": "config_write_refused", "key": key, "said": !writeRefusedSaid && !LaunchMessages.shared.holding])
        guard !writeRefusedSaid, !LaunchMessages.shared.holding else { return }
        writeRefusedSaid = true
        var t = Island.Toast(text: T("app.config.not_saved"), actionTitle: T("app.config.show")) {
            NSWorkspace.shared.activateFileViewerSelecting([BlurtPaths.config])
        }
        t.seconds = 8
        island.toast(t)
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

    /// A native alert. `also`: a second button (the first is OK) and what it does. `primary`: that button is the way
    /// out instead (the default, ↩), with `cancel` as the plain second (Esc) — "Open System Settings" / "Not Now".
    /// `critical`: something was lost (the caution badge on the app icon), not just said. Shown key, so its default
    /// button is drawn as the default.
    func alert(_ title: String, _ text: String, also: (String, () -> Void)? = nil, primary: Bool = false, cancel: String? = nil,
               critical: Bool = false) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = critical ? .critical : .warning
        var titles: [String] = []
        if let b = also, primary {
            titles = [b.0, cancel ?? T("action.cancel")]
        } else {
            titles = [T("action.ok")] + (also.map { [$0.0] } ?? [])
        }
        for t in titles { a.addButton(withTitle: t) }
        if titles.count > 1 { a.buttons[1].keyEquivalent = "\u{1b}" }      // the second is Esc
        emit(["event": "alert", "title": title, "text": text, "buttons": titles])
        activateApp()
        a.layout()
        a.window.makeKeyAndOrderFront(nil)
        let r = a.runModal()
        if primary { if r == .alertFirstButtonReturn { also?.1() } }
        else if r == .alertSecondButtonReturn { also?.1() }
    }
}
