// The one model download manager (docs/design/desktop-app.md §2.2 "Models"): every model download in the app goes
// through it — the setup assistant's "Download Recommended Models" (ModelSetup), Settings → Speech (dictation's
// recogniser and polish models, DictationModels; the recording / voice-note models, SpeechModel), and the dictation
// key's "no speech model yet · Download". The rule (one at a time, never the same model twice, one bar over the batch,
// what counts as stopped) is BlurtCore's ModelDownloadQueue.
//
//   runs       `transcribe.py setup --model-id ID --parent PID` / `polish.py setup --model ID [--use] --parent PID`
//              (BLURT_HF_MIRROR=1 when ModelBundle.mirror says so); the scripts take a lock per model, resume a partial
//              file and only call a model installed once every file is complete. --parent: a setup outliving the app
//              stops by itself. Test builds: BLURT_TEST_ASR_SETUP / BLURT_TEST_POLISH_SETUP stand in for the scripts.
//   shows      Settings → Speech's rows (the running one's bar and Stop, "Queued" for the rest, "Unpacking…" after an
//              archive's download), the menu-bar menu's first row while it runs ("Downloading speech models · 2.1 of
//              6.1 GB": Show / Stop), the assistant's models step; a toast when the assistant closes mid-download, when
//              the batch is in ("Speech models are ready · tap Fn to try") and when a request stopped on an error (Try
//              Again). "Stop" on every surface.
//   errors     a failed model ends its own request (the assistant's batch, one Settings row…): the rest of that
//              request is marked not downloaded in its rows, and models other surfaces asked for carry on.
//   Stop       one model: a queued one leaves the queue, the running one ends. Everything: the running one ends and
//              what was waiting then goes — one that finishes in that moment is kept, and one asked for after Stop runs.
//   lasts      $BLURT_HOME/model-downloads.json while anything is left: a quit (the setup is ended, its partial file
//              kept), a relaunch or a crash carries on quietly at the next launch, with one launch line — posted
//              once the first progress line shows it really carries on ("· 4.4 GB to go": what is left, the part
//              already down not counted again), and dropped if it stopped before the line went up. Offline at that
//              launch (the script says "network", or macOS says the Mac is offline — ModelDownloadQueue
//              .waitsForNetwork; a crash or a full disk while online is an ordinary failure with its error): the file
//              is kept, one line says the models finish once the Mac is online (Try Again), and they carry on by
//              themselves when it is (NetworkWatch) or at the next launch. A retry on the network coming back that
//              fails again stays quiet (a flapping Wi-Fi, a captive portal): said again only after a Try Again.
//   progress   only a line about the running model counts (ModelBundle.acceptProgress: a file fetched on the way
//              never moves the bar, and it never moves back).
//   after      each model that comes in: dictation's state is read again (DictationModels — the dictation key needs a
//              model), the voice-note models re-picked (SpeechModel.reapply), polish picks its model up, and once
//              dictation's model is there it is loaded straight away (Dictation.prewarm), so the first Fn isn't cold.
// Test hooks: `downloads state|add ID[,ID…] KIND|stop [ID]|resume|online` (DictationTestHooks → testCommand).
import AppKit
import BlurtCore
import Combine

@MainActor
final class ModelDownloads: ObservableObject {
    static let shared = ModelDownloads()
    typealias Job = ModelDownloadQueue.Job

    @Published private(set) var queue = ModelDownloadQueue()
    /// the running job (nil between jobs and when idle)
    @Published private(set) var current: String?
    /// the running job's last "N/M MB" line
    @Published private(set) var line: (done: Double, total: Double)? { didSet { updateMenuRow() } }
    /// model id → why its last download stopped on an error, or that it was left out because another model of its
    /// request failed (cleared when it is asked for again)
    @Published private(set) var failed: [String: String] = [:]
    /// the running job is unpacking its archive (the setup said "unpacking …"): the bar is full, the row says so
    @Published private(set) var unpacking = false
    private var proc: Process?
    /// Stop was pressed: nil = not stopping, "" = everything, else that model
    private var stopping: String?
    /// Stop for everything: the models waiting when it was pressed — one asked for after it (before the running
    /// setup has ended) is not among them, and runs
    private var stopSet: Set<String> = []
    /// the app is quitting: the setup's end changes nothing
    private var quitting = false
    /// the surface that started the batch ("onboarding", "settings", "dictation", "launch")
    private(set) var via = ""
    /// a batch carried over at launch couldn't reach the network: model-downloads.json is kept for when it can
    private(set) var waitingForNetwork = false
    /// the batch resumed at launch: its launch line goes up with the first progress line (then it is true)
    private var announceResume = false
    /// "finish once you're online" was said: a retry the network's return started stays quiet if it fails again
    private var offlineSaid = false

    var active: Bool { queue.active }
    var progress: (done: Double, total: Double) { queue.progress(current: current, line: line) }
    /// What is left to download (MB): the batch less what came down, the running model's part included.
    var remainingMB: Double { queue.remaining(current: current, line: line) }

    func isQueued(_ id: String) -> Bool { queue.contains(id) && current != id }
    func isRunning(_ id: String) -> Bool { current == id }
    /// One model's own bar: the running one's "N/M MB" (its size until the first line), nil when it isn't running.
    func progress(_ id: String) -> (done: Double, total: Double)? {
        guard current == id, let j = queue.pending.first(where: { $0.id == id }) else { return nil }
        if unpacking { return (j.sizeMB, j.sizeMB) }
        return line ?? (0, j.sizeMB)
    }
    /// The running model is being unpacked (after its download).
    func isUnpacking(_ id: String) -> Bool { current == id && unpacking }

    // MARK: asking

    /// Queue these models (the ones already queued or running are not asked for twice) and start if idle.
    func download(_ jobs: [Job], via source: String) {
        for j in jobs { failed[j.id] = nil }
        // the batch a launch kept for the network comes along (the file would otherwise be overwritten without it)
        if waitingForNetwork, let kept = ModelDownloadQueue.load() {
            waitingForNetwork = false
            queue.add(kept.pending)
        }
        if !queue.active { via = source }
        let added = queue.add(jobs, group: String(UUID().uuidString.prefix(8)))
        queue.save()
        emit(["event": "model_download", "op": "add", "via": source, "models": jobs.map(\.id), "added": added.map(\.id),
              "queue": queue.pending.map(\.id)])
        if proc == nil { runNext() }
    }

    /// Stop: one model (`id`: a queued one just leaves the queue, the running one ends — what came down is kept and
    /// picked up again next time), or everything (nil).
    func stop(_ id: String? = nil) {
        emit(["event": "model_download", "op": "stop", "model": id ?? NSNull(), "current": current ?? NSNull()])
        if let id = id, id != current {
            queue.remove(id)
            queue.save()
            return
        }
        guard let p = proc else { queue.clear(); queue.save(); return }
        stopping = id ?? ""
        if id == nil { stopSet = Set(queue.pending.map(\.id)) }
        p.terminate()
    }

    // MARK: launch / quit

    /// At launch: what a quit, a relaunch or a crash left carries on, quietly, with one launch line.
    func resumeAtLaunch() {
        guard proc == nil, let q = ModelDownloadQueue.load() else { return }
        emit(["event": "model_download", "op": "resume", "models": q.pending.map(\.id), "finished": q.finished])
        waitingForNetwork = false
        announceResume = true           // the line goes up with the first progress line: it carries on for real
        queue = q
        via = "launch"
        runNext()
    }

    /// "Finishing the speech models · 4.4 GB to go": once the resumed batch really moves; dropped if it stopped while
    /// the launch's messages were held.
    private func announceResumed() {
        guard announceResume else { return }
        announceResume = false
        var t = Island.Toast(text: T("app.models.resuming", modelSize(remainingMB)), actionTitle: T("app.models.show")) {
            ModelDownloads.showProgress()
        }
        t.seconds = 6
        LaunchMessages.shared.post(.models, t, stillTrue: { MainActor.assumeIsolated { ModelDownloads.shared.active } })
    }

    /// The line's Try Again: the kept batch again, and if it fails again that is said again (the user asked).
    func retryKept() {
        offlineSaid = false
        resumeAtLaunch()
    }

    /// The Mac is online again (NetworkWatch): a batch a launch kept for the network carries on.
    func backOnline() {
        guard waitingForNetwork, proc == nil else { return }
        emit(["event": "model_download", "op": "online"])
        resumeAtLaunch()
    }

    /// Quitting: the setup ends now (its partial files stay for the next launch, and so does the queue's file).
    func atQuit() {
        quitting = true
        guard let p = proc, p.isRunning else { return }
        emit(["event": "model_download", "op": "quit", "model": current ?? NSNull()])
        p.terminate()
    }

    /// Where the progress shows: the assistant's models step while it is open, else Settings → Speech.
    static func showProgress() {
        if ModelSetup.shared.shown { Onboarding.shared.show(step: 2) } else { SpeechPane.showDictationModels() }
    }

    // MARK: running

    private func runNext() {
        guard proc == nil else { return }
        guard let j = queue.next else { return batchDone() }
        current = j.id
        line = nil
        unpacking = false
        let env = ProcessInfo.processInfo.environment
        let test = env["BLURT_TEST_COMMANDS"] == "1"
        let parent = ["--parent", "\(getpid())"]
        let (script, args): (String, [String])
        switch j.kind {
        case .polish: (script, args) = ((test ? env["BLURT_TEST_POLISH_SETUP"] : nil) ?? "polish.py", ["setup", "--model", j.id] + (j.select ? ["--use"] : []) + parent)
        case .screenText: (script, args) = ("screen_text.py", ["setup"] + parent)      // Copy Text from Screen's local model
        case .dictation, .note: (script, args) = ((test ? env["BLURT_TEST_ASR_SETUP"] : nil) ?? "transcribe.py", ["setup", "--model-id", j.id] + parent)
        }
        var extra: [String: String] = [:]
        if ModelBundle.mirror { extra["BLURT_HF_MIRROR"] = "1" }
        emit(["event": "model_download", "op": "start", "model": j.id, "kind": j.kind.rawValue, "mirror": extra["BLURT_HF_MIRROR"] != nil])
        var lastError = ""
        var lastErrLine = ""        // the last thing the script said on stderr (a traceback's last line), for the log
        var code: String?           // the script's own {"ok": false, "code": …}; nil: it never got to say (uv couldn't run it)
        do {
            proc = try SkillCLI.shared.spawn(script, args, env: extra, onLine: { [weak self] l, isErr in
                guard let self = self else { return }
                let t = l.trimmingCharacters(in: .whitespaces)
                if let q = ModelBundle.parseProgress(t) {
                    // only the running model's own line, never backwards (a file fetched on the way isn't the model)
                    if let ok = ModelBundle.acceptProgress(q, sizeMB: j.sizeMB, previous: self.line) {
                        self.line = ok
                        self.announceResumed()
                    }
                } else if t.hasPrefix("unpacking ") {
                    self.unpacking = true
                    self.updateMenuRow()
                } else if !isErr, t.hasPrefix("{"), let o = (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [String: Any] {
                    code = o["ok"] as? Bool == false ? o["code"] as? String ?? "error" : nil
                } else if isErr, l.hasPrefix("ERROR") || l.contains("failed") {
                    lastError = String(l.prefix(300))
                } else if isErr, !t.isEmpty {
                    lastErrLine = String(t.prefix(300))
                }
            }, onExit: { [weak self] st in self?.exited(j, status: st, error: lastError.isEmpty ? lastErrLine : lastError, code: code) })
        } catch {
            proc = nil
            exited(j, status: 1, error: "\(error)", code: nil)
        }
    }

    private func exited(_ j: Job, status st: Int32, error: String, code: String?) {
        proc = nil
        guard !quitting else { return }        // the queue's file stays as it is: the next launch carries on
        let stop = stopping
        stopping = nil
        let stopAll = stopSet
        stopSet = []
        let outcome = ModelDownloadQueue.outcome(status: st, stopping: stop != nil)
        emit(["event": "model_download", "op": "exit", "model": j.id, "status": Int(st), "outcome": outcome.rawValue,
              "error": error.isEmpty ? NSNull() : error, "code": code ?? NSNull()])
        // the scripts' own words for every outcome: the per-surface events tests read
        emit(["event": j.kind == .polish ? "polish_download" : "asr_download", "model": j.id, "status": Int(st)])
        current = nil
        line = nil
        unpacking = false
        let request: ModelDownloadQueue.Stop = stop == nil ? .none : stop == "" ? .all(stopAll) : .one(stop!)
        // a batch carried over from the last run that can't reach the network: kept on disk for when the Mac is
        // online, said once — not dropped for good behind a "still finishing" line. Anything else is a failure.
        if outcome == .failed, via == "launch", ModelDownloadQueue.waitsForNetwork(code: code, online: NetworkWatch.shared.isOnline) {
            return keepForNetwork(j)
        }
        if outcome == .failed {
            failed[j.id] = error.isEmpty ? "exit \(st)" : error
            announceResume = false          // no "finishing" line for a batch that just stopped on an error
        }
        let next = queue.ended(j.id, outcome: outcome, stop: request)
        queue.save()
        if outcome == .done { arrived(j) } else { Task { await refresh(); await ModelSetup.shared.load() } }
        switch next {
        case .go:
            runNext()
        case .stopped:
            // the rest carry on; nothing left: the batch just ends (no "ready" line after a Stop)
            if queue.active { runNext() } else { via = ""; Task { await ModelSetup.shared.load() } }
        case .failed(let left):
            // its request ends (the other models it asked for are marked, Try Again asks again); other requests go on
            for r in left where r.id != j.id { failed[r.id] = "not_started" }
            stoppedOnError(left.isEmpty ? [j] : left, via: via)
            if queue.active { runNext() } else { via = "" }
        }
    }

    /// The launch's batch is offline: the file stays (the next launch or the network coming back carries on), the
    /// queue in memory empties (nothing shows as downloading), one line says so — with Try Again. Once: a retry the
    /// network's return started that fails again says nothing more (Try Again says it again if it fails).
    private func keepForNetwork(_ j: Job) {
        emit(["event": "model_download", "op": "offline", "model": j.id, "kept": queue.pending.map(\.id), "said": !offlineSaid])
        announceResume = false
        queue.clear()                   // not saved: model-downloads.json keeps what is left
        via = ""
        waitingForNetwork = true
        Task { await ModelSetup.shared.load() }
        guard !offlineSaid else { return }
        offlineSaid = true
        var t = Island.Toast(text: T("app.models.offline"), actionTitle: T("onboarding.models.retry")) {
            MainActor.assumeIsolated { ModelDownloads.shared.retryKept() }
        }
        t.seconds = 8
        LaunchMessages.shared.post(.models, t)
    }

    /// One model is in: everything that depends on it reads it again; dictation's model loads now.
    private func arrived(_ j: Job) {
        if j.select && j.kind == .dictation {
            Dictation.set("asr_model", j.id)
            Dictation.shared.apply()
        }
        if j.kind == .polish { Dictation.shared.refreshPolishModel() }
        if j.kind == .screenText { ScreenTextRefine.refreshInstalled { if ScreenTextRefine.mode == .local { ScreenTextRefine.shared.warm() } } }
        Task {
            await refresh()
            if DictationModels.shared.dictationReady == true { Dictation.shared.prewarm("model_installed") }
        }
    }

    private func refresh() async {
        await DictationModels.shared.load()
        await SpeechModel.shared.reapply()
    }

    private func batchDone() {
        let source = via
        via = ""
        emit(["event": "model_download", "op": "done", "via": source])
        Task {
            await ModelSetup.shared.load()
            guard !ModelSetup.shared.shown else { return }
            // what to do next: with dictation's model in, try the key
            let t = DictationModels.shared.dictationReady == true && Dictation.enabled
                ? T("app.models.ready_try", Dictation.keyShort) : T("onboarding.models.ready_toast")
            AppEnvironment.island?.toast(t, actionTitle: nil, action: nil)
        }
    }

    /// The batch stopped on an error. Unless the assistant shows it: one line, and Try Again (the assistant's step
    /// when it started the batch, else the same models again).
    private func stoppedOnError(_ batch: [Job], via source: String) {
        guard !ModelSetup.shared.shown else { return }
        AppEnvironment.island?.toast(T("onboarding.models.failed_toast"), actionTitle: T("onboarding.models.failed_open")) {
            if source == "onboarding" { Onboarding.shared.show(step: 2) } else { ModelDownloads.shared.download(batch, via: source) }
        }
    }

    // MARK: menu

    /// The menu-bar menu's row while a batch runs: "Downloading speech models · 2.1 of 6.1 GB", Show and Stop.
    var menuTitle: String? {
        guard active else { return nil }
        if unpacking { return T("app.models.menu_unpacking") }
        let p = progress
        return T("app.models.menu", modelSize(p.done), modelSize(p.total))
    }

    /// The open menu's row follows the download.
    private func updateMenuRow() { if let it = (NSApp.delegate as? App)?.downloadItem, let t = menuTitle { it.title = t } }

    // MARK: tests

    /// `downloads state | add ID[,ID…] KIND [select] | stop [ID] | resume`, then a "downloads_state" event.
    func testCommand(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        switch a.first ?? "state" {
        case "add" where a.count >= 3:          // add ID[,ID…] KIND [select]: one request
            let kind = ModelBundle.Kind(rawValue: a[2]) ?? .note
            download(a[1].split(separator: ",").map { Job(id: String($0), kind: kind, name: String($0), sizeMB: 100, select: a.contains("select")) },
                     via: "test")
        case "stop": stop(a.count > 1 ? a[1] : nil)
        case "resume": resumeAtLaunch()
        case "online": backOnline()
        default: break
        }
        let p = progress
        emit(["event": "downloads_state", "current": current ?? NSNull(), "queue": queue.pending.map(\.id), "unpacking": unpacking,
              "finished": queue.finished, "progress": [Int(p.done), Int(p.total)], "failed": failed,
              "file": FileManager.default.fileExists(atPath: ModelDownloadQueue.url.path), "menu": menuTitle ?? NSNull(),
              "waiting_for_network": waitingForNetwork, "remaining_mb": Int(remainingMB)])
    }
}
