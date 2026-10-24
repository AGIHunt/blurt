// What the menu-bar app does in the background at launch (v0.7 contract), silently, in this order:
//   projects.py migrate      v0.6 record.workspace(s) → projects.json (K2; idempotent)
//   items.py migrate --all   v1/v2 sessions (items.json, no batch.json) → Markdown stores (K1; idempotent)
//   jobs.py gc               jobs that ended 14+ days ago, beyond the last 300 (K4)
//   transcribe.py auto --apply   speech models for this Mac (K9); after a hardware change that wants a download, one
//                            quiet line in the island offers Settings → Speech (once: --apply records the hardware)
//   Snapper.expireTaken      captures dragged out into another app 7+ days ago (Recently Taken) go to the Trash —
//                            also hourly while the app runs
//                            (BlurtCore TakenCaptures; the app's own, no script)
//   videos                   only when the user turned it on (Settings → Storage, record.delete_videos_after_days):
//                            organized recordings' videos older than that go to the Trash (BlurtCore VideoRetention) —
//                            also daily while the app runs
//   the skill's contract     scripts/_common.py CONTRACT against the app's (BlurtCore SkillContract): when they differ,
//                            one line in the island says which to update (once per app version and skill contract)
// Whatever wants a word in the island at launch goes through LaunchMessages: only one is shown.
// and keeps one `sessions.py monitor` running while it lives (K5: tmux windows → session status; it takes its own lock,
// so a second copy just exits). Any of them missing (an older skill) is skipped.
import AppKit
import BlurtCore

enum Housekeeping {
    private static var monitor: Process?

    static func atLaunch() {
        guard ProcessInfo.processInfo.environment["BLURT_NO_HOUSEKEEPING"] == nil else { return }
        let launched = Date()
        Task.detached(priority: .utility) {
            let r = ScriptRunner.shared
            await finishInterruptedJobs(launchedAt: launched)
            for (script, args) in [("projects.py", ["migrate"]), ("items.py", ["migrate", "--all"]), ("jobs.py", ["gc"])] {
                guard (try? r.scriptURL(script)) != nil else { continue }
                do { _ = try await r.run(script, args, timeout: 600) } catch { NSLog("blurt: \(script) \(args.joined(separator: " ")): \(error)") }
            }
            await MainActor.run {
                ProjectStore.shared.reload()
                Scripts.indexUpdate([ProjectStore.shared.inbox.store])
                startMonitor()
                snapper.expireTaken()
                askAboutCarriedOverProject()
                checkSkillContract()
                deleteOldVideos()
                Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in deleteOldVideos() }
            }
            await speechModels()
        }
    }

    /// The app and the skill scripts it runs speak the same contract (SkillContract), or one line says which side to
    /// update — once per app version and skill contract (app.contract_warned).
    static func checkSkillContract() {
        let skill = SkillContract.skillVersion()
        guard let m = SkillContract.check(skill: skill) else { return }
        let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let sig = "\(app)/\(skill ?? -1)"
        guard Config.shared["app.contract_warned"] as? String != sig else { return }
        emit(["event": "skill_contract", "skill": skill ?? -1, "app": SkillContract.expected])
        var t: Island.Toast
        switch m {
        case .skillOlder:
            t = Island.Toast(text: T("app.contract.skill_older"), actionTitle: T("app.contract.how")) {
                NSWorkspace.shared.open(Help.guideURL(section: "update"))
            }
        case .appOlder:
            t = Island.Toast(text: T("app.contract.app_older"), actionTitle: Updater.shared.canCheck ? T("app.menu.updates") : nil) {
                Updater.shared.checkForUpdates(nil)
            }
        }
        t.seconds = 8
        LaunchMessages.shared.post(.skill, t) { Config.shared.set("app.contract_warned", sig) }   // said once it was seen
    }

    /// Settings → Storage's "Delete videos automatically" (off unless the user chose an age): organized recordings'
    /// videos older than that go to the Trash. The recording in progress is never touched.
    static func deleteOldVideos() {
        guard let days = VideoRetention.autoDays else { return }
        let current = (NSApp.delegate as? App)?.lastSession.map { Set([$0.standardizedFileURL.path]) } ?? []
        DispatchQueue.global(qos: .utility).async {
            let c = VideoRetention.candidates(roots: FixWatcher.sessionRoots(), olderThan: days, excluding: current)
            guard !c.isEmpty else { return }
            let files = c.flatMap(\.files)
            DispatchQueue.main.async {
                NSWorkspace.shared.recycle(files) { done, _ in
                    emit(["event": "videos_deleted", "auto": true, "sessions": c.count, "files": done.count,
                          "bytes": c.reduce(Int64(0)) { $0 + $1.bytes }])
                }
            }
        }
    }

    /// K9: pick the speech models for this machine. Skipped until onboarding is done (it downloads the first model);
    /// the hardware is recorded only then, so the first real launch afterwards may suggest a better model.
    static func speechModels() async {
        guard !Onboarding.needed, (try? ScriptRunner.shared.scriptURL("transcribe.py")) != nil else { return }
        guard let r = try? await ScriptRunner.shared.json("transcribe.py", ["auto", "--apply"], timeout: 120),
              r["ok"] as? Bool == true, r["hardware_changed"] as? Bool == true,
              let need = r["needs_download"] as? [[String: Any]], !need.isEmpty else { return }
        let mb = need.compactMap { ($0["size_mb"] as? NSNumber)?.doubleValue }.reduce(0, +)
        let size = ByteCountFormatter.string(fromByteCount: Int64(mb * 1_000_000), countStyle: .file)
        await MainActor.run {
            emit(["event": "asr_suggest", "models": need.compactMap { $0["model"] as? String }, "size_mb": mb])
            guard AppEnvironment.island != nil else { return }
            LaunchMessages.shared.post(.model, Island.Toast(text: T("main.speech.recommended", size), actionTitle: T("main.speech.recommended.action")) {
                AppEnvironment.settings?.show(pane: SettingsPane.speech.rawValue)
            })
        }
    }

    /// v0.6's bound repo became the current project in the migration, which nobody chose here: ask once, in the
    /// island, whether captures should keep going there. Either answer is recorded (current_by "user").
    static func askAboutCarriedOverProject() {
        let store = ProjectStore.shared
        guard store.currentBy == "migrate", let p = store.current else { return }
        emit(["event": "ask_current_project", "project": p.id])
        // Island.ask's question, through LaunchMessages (not shown or not answered: asked again next launch)
        var t = Island.Toast(text: T("app.migrate.ask", p.name), actionTitle: T("app.migrate.keep", p.name)) {
            emit(["event": "current_project_answer", "keep": true])
            Task { try? await store.use(p.id); await MainActor.run { island.projectChanged() } }
        }
        t.secondTitle = T("app.migrate.auto")
        t.second = {
            emit(["event": "current_project_answer", "keep": false])
            Task { try? await store.use(nil); await MainActor.run { island.projectChanged() } }
        }
        t.seconds = .infinity
        LaunchMessages.shared.post(.project, t)
    }

    static func startMonitor() {
        guard monitor == nil, (try? ScriptRunner.shared.scriptURL("sessions.py")) != nil else { return }
        // --parent: it ends with us, even when we don't get to atQuit (a crash, a kill, an update)
        monitor = try? ScriptRunner.shared.spawn("sessions.py", ["monitor", "--parent", "\(getpid())"]) { _ in }
    }

    /// Jobs the app owned (a recording, organizing, AI fill-in…) that were still running when it quit or crashed kept
    /// saying "running" — a spinner in the main window and the menu bar for good. They are marked failed here, with
    /// the step that was running failed and the rest skipped, so the job page explains it and offers Retry. A job is
    /// the previous app's when the process that wrote it is gone (app_pid), or, written by an older build without
    /// one, when it is older than this launch. The app owns these files (K4), so it rewrites them; agent sessions are
    /// sessions.py's and are left alone.
    static func finishInterruptedJobs(launchedAt: Date) async {
        let stale: [String] = await MainActor.run {
            JobStore.shared.rescan()
            return JobStore.shared.active.filter { j in
                guard j.type != .agent, j.raw["owner"] as? String == "app" else { return false }
                if let pid = (j.raw["app_pid"] as? NSNumber)?.int32Value { return pid != getpid() && kill(pid, 0) != 0 && errno == ESRCH }
                return j.created < launchedAt.addingTimeInterval(-5)
            }.map(\.id)
        }
        let now = JobFold.now()
        for id in stale {
            let url = JobFiles.json(id)
            guard let d = try? Data(contentsOf: url), var doc = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            doc["state"] = "failed"
            doc["ended"] = now
            doc["updated"] = now
            doc["error"] = ["code": "unknown", "message": "Blurt quit before this job finished", "hint_key": "main.job.hint.interrupted"]
            doc["steps"] = (doc["steps"] as? [[String: Any]] ?? []).map { st -> [String: Any] in
                var st = st
                switch st["state"] as? String {
                case "running": st["state"] = "failed"; st["ended"] = now
                case "pending": st["state"] = "skipped"
                default: break
                }
                return st
            }
            if let out = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]) { try? out.write(to: url, options: .atomic) }
        }
        if !stale.isEmpty {
            await MainActor.run { JobStore.shared.rescan() }
            emit(["event": "jobs_interrupted", "jobs": stale])
        }
    }

    static func atQuit() {
        if let m = monitor, m.isRunning { m.terminate() }
        monitor = nil
    }
}
