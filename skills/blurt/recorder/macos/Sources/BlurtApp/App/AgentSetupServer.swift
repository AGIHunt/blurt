// Agent-assisted model setup, the app's side (docs/design/agent-setup.md): the control socket scripts/setup.py talks to
// (BlurtCore ControlSocket: $BLURT_HOME/run/control.sock, this user only), and what each request does — the same
// steps Settings → Models takes, through the same code:
//
//   hello · status    anyone of this user: the Mac, the languages, dictation's models and choices (the comparison's
//                     levels, never an error rate), the connected services (never a key), each job's choice and route,
//                     the curated options with their measured lines, where each service's key is made
//   connect           a curated service's key (Volcengine Speech: App ID + Access Token): tested as the Add Service sheet
//                     tests it (polish_cloud.py check on its curated model; Volcengine: the speech clip), then
//                     CloudStore.connect — the login Keychain — and the jobs follow (CloudServiceSheetModel.afterChange)
//   test              a connected service, with the key the app holds
//   use               a job's model: the job row's pop-up (JobModelControl.set) or the comparison's Use
//                     (DictationChoiceAction.use); a model Blurt didn't measure only with `custom`, after the job's own
//                     test passes (the Custom Model sheet's gate)
//   download          a dictation or polish model, through the one download manager
//   verify            a spoken clip (macOS `say`) through the recogniser and the polish a take uses — no microphone,
//                     no field, nothing pasted: what it heard, the polished text, the timings
//
// Changes need a grant (BlurtCore AgentSetupGrant): the token of the session "Set Up with Agent…" started, or the
// user's Allow — Blurt asks, naming the agent it finds among the requesting process's ancestors. A key is only ever
// read from a `connect` request, handed to the test on stdin and to the Keychain; it is never logged, written to a
// file or sent back. Tests (BLURT_TEST_COMMANDS=1) answer the Allow question from BLURT_TEST_SETUP_ALLOW (1 | 0)
// instead of showing it, and keep keys in memory (CloudStore.Key.testBuild).
import AppKit
import BlurtCore

enum AgentSetupServer {
    private static var socket: ControlSocket?
    private static let lock = NSLock()
    private static var grant = AgentSetupGrant()
    /// one Allow question at a time; a request waiting behind it gets its answer
    private static let asking = DispatchQueue(label: "blurt.agent-setup.ask")

    static func start() {
        let path = AgentSetup.socketPath(home: BlurtPaths.home)
        let s = ControlSocket(path: path) { req, peer in handle(req, peer: peer) }
        do {
            try s.start()
            socket = s
            emit(["event": "agent_setup_server", "state": "listening"])
        } catch {
            emit(["event": "agent_setup_server", "state": "not_started", "why": "\(error)"])
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            socket?.stop()
        }
    }

    // MARK: grants

    /// A token for a session the app starts.
    static func issueToken() -> String { lock.lock(); defer { lock.unlock() }; return grant.issue() }
    static func revoke(_ token: String) { lock.lock(); grant.revoke(token); lock.unlock() }
    /// Stop: nothing may change things any more until asked again.
    static func revokeAll() { lock.lock(); grant.revokeAll(); lock.unlock() }

    private static func allows(_ token: String?) -> Bool { lock.lock(); defer { lock.unlock() }; return grant.allows(token: token) }

    /// The agent that asks (agents.json's name), else nil.
    static func requester(_ peer: ControlSocket.Peer) -> String? {
        guard peer.pid > 0 else { return nil }
        let bins = AgentHub.shared.defs.map { (id: $0.id, bins: $0.bins) }
        return AgentSetupPeer.agent(chain: ProcessProbe.ancestry(peer.pid), bins: bins).map { AgentNames.name($0) }
    }

    /// May this request change things: a live grant, else the user's answer (asked once; later requests wait for it).
    private static func granted(_ r: AgentSetupRequest, peer: ControlSocket.Peer) -> Bool {
        if allows(r.token) { return true }
        return asking.sync {
            if allows(r.token) { return true }
            let who = requester(peer)
            let ok = ask(who)
            emit(["event": "agent_setup_allow", "agent": nul(who), "allowed": ok])
            if ok {
                lock.lock(); grant.approve(); lock.unlock()
                DispatchQueue.main.async { MainActor.assumeIsolated { AgentSetupProgress.shared.allowed(agent: who) } }
            }
            return ok
        }
    }

    /// The question, in Blurt (blocking this connection's thread, never the main one): Allow / Don't Allow.
    private static func ask(_ who: String?) -> Bool {
        let env = ProcessInfo.processInfo.environment
        var wait: TimeInterval = 180
        if env["BLURT_TEST_COMMANDS"] == "1" {
            // tests answer it, unless they want to see it (ask; BLURT_TEST_SETUP_ASK_SECONDS: how long it waits)
            guard env["BLURT_TEST_SETUP_ALLOW"] == "ask" else { return env["BLURT_TEST_SETUP_ALLOW"] == "1" }
            wait = env["BLURT_TEST_SETUP_ASK_SECONDS"].flatMap(Double.init) ?? wait
        }
        let sem = DispatchSemaphore(value: 0)
        let box = Box<Bool>()
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = who.map { M("models.agent.ask.title", $0) } ?? M("models.agent.ask.unknown")
            a.informativeText = M("models.agent.ask.detail")
            // asked while the user may be typing in the agent's terminal: Return must not allow (only a click does);
            // Esc is Don't Allow
            a.addButton(withTitle: M("models.agent.ask.allow")).keyEquivalent = ""
            a.addButton(withTitle: M("models.agent.ask.deny")).keyEquivalent = "\u{1b}"
            activateApp()
            // nobody there: no — and the question goes, so a late click can't answer a request already refused (it
            // stayed on screen before: dogfood 2026-10-31). A timer of the modal loop's own mode ends it.
            let t = Timer(timeInterval: wait, repeats: false) { _ in NSApp.abortModal() }
            RunLoop.main.add(t, forMode: .modalPanel)
            box.value = a.runModal() == .alertFirstButtonReturn
            t.invalidate()
            sem.signal()
        }
        // the main thread busy for good: no
        if sem.wait(timeout: .now() + wait + 60) == .timedOut { return false }
        return box.value ?? false
    }

    // MARK: requests

    static func handle(_ o: [String: Any], peer: ControlSocket.Peer) -> [String: Any] {
        let r: AgentSetupRequest
        switch AgentSetupRequest.parse(o) {
        case .failure(let e): return e.json
        case .success(let x): r = x
        }
        // what was asked, never what was sent with it
        emit(["event": "agent_setup_request", "op": r.op.rawValue, "pid": Int(peer.pid), "job": nul(r.job),
              "preset": nul(r.preset)])
        if r.op.needsGrant, !granted(r, peer: peer) {
            return AgentSetupError("denied", "the user didn't allow changes in Blurt; ask them to click Allow, or to use Set Up with Agent… in Settings → Models").json
        }
        switch r.op {
        case .hello:
            return ["ok": true, "app": "Blurt", "protocol": AgentSetup.protocolVersion, "pid": Int(getpid()),
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                    "granted": allows(r.token)]
        case .status: return status(granted: allows(r.token))
        case .connect: return connect(r)
        case .test: return test(r)
        case .use: return use(r)
        case .download: return download(r)
        case .verify: return verify(r)
        }
    }

    // MARK: status

    private static func status(granted: Bool) -> [String: Any] {
        // the models' lists read once if nothing has read them yet (Settings not opened since launch)
        if onMain({ DictationModels.shared.asr == nil }) { wait { await DictationModels.shared.load() } }
        let connected = CloudStore.connected
        return onMain {
            let now = DictationNow.read()
            let d = DictationModels.shared
            let dl = ModelDownloads.shared
            let setup = CloudStore.setup
            let list = CuratedModels.list
            let os = ProcessInfo.processInfo.operatingSystemVersion
            var out: [String: Any] = ["ok": true, "app": "running", "protocol": AgentSetup.protocolVersion, "granted": granted]
            out["mac"] = ["chip": nul(DictationModels.chip), "ram_gb": (now.mac.ramGB * 10).rounded() / 10,
                          "apple_silicon": now.mac.appleSilicon, "macos": "\(os.majorVersion).\(os.minorVersion)",
                          "macos_speech": now.mac.macOSSpeech, "languages": now.mac.languages,
                          "region": nul(Locale.current.region?.identifier), "ui_language": Loc.isChinese ? "zh" : "en"]
            // dictation: what runs, what is recommended here, every model with whether it is in
            let inUse = now.inUse == .cloudPolish ? now.base : now.inUse
            out["dictation"] = [
                "recognizer": nul(now.recognizer), "in_use": nul(now.inUse?.rawValue),
                "recommended": now.recommended.rawValue, "recommended_local": DictationChoices.recommendedLocal(now.mac).rawValue,
                "polish_base": now.base.rawValue, "auto": d.asrAuto, "ready": nul(d.dictationReady),
                "own_language": nul(DictationChoices.ownLanguage(now.mac.languages)),
                "choices": DictationChoices.choices(now.mac, inUse: inUse).map { c in
                    AgentSetupJSON.facts(now.facts(c), fit: now.fit(c), recommended: c == now.recommended, inUse: c == now.inUse)
                },
                "models": (d.asr?.models ?? []).map { m -> [String: Any] in
                    ["id": m.id, "name": m.name ?? m.id, "installed": m.installed, "size_mb": m.sizeMB,
                     "fits": nul(m.fits), "recommended": m.recommended]
                },
            ]
            out["polish_local"] = ["supported": nul(d.polish?.supported), "selected": nul(d.polish?.selected),
                                   "models": (d.polish?.models ?? []).map { ["id": $0.id, "name": $0.name, "installed": $0.installed,
                                                                             "size_mb": $0.sizeMB, "recommended": $0.recommended] }]
            out["downloads"] = dl.queue.pending.map { j -> [String: Any] in
                var o: [String: Any] = ["id": j.id, "name": j.name, "size_mb": j.sizeMB, "running": dl.isRunning(j.id)]
                if let p = dl.progress(j.id) { o["done_mb"] = p.done }
                return o
            }
            if !dl.failed.isEmpty { out["download_failed"] = Array(dl.failed.keys) }
            out["services"] = setup.services.map { s -> [String: Any] in
                ["id": s.id, "preset": s.preset, "name": CloudStore.name(s), "region": nul((s.region ?? s.endpoint?.region)?.rawValue),
                 "key": connected.contains { $0.id == s.id }, "speech": s.info.speech, "curated": CloudText.curated(s)]
            }
            var jobs: [String: Any] = [:]
            for job in CloudJob.allCases {
                jobs[job.rawValue] = ["choice": AgentSetupJSON.choice(setup.choice(job)),
                                      "route": AgentSetupJSON.route(CloudStore.route(job), job: job, setup: setup, list: list)]
            }
            out["jobs"] = jobs
            var options: [String: Any] = [:]
            for job in CloudJob.allCases {
                options[job.rawValue] = list.options(job).map { AgentSetupJSON.option($0, connected: connected, note: CloudText.note($0)) }
            }
            options["speech"] = list.options(CuratedJob.speech).map { AgentSetupJSON.option($0, connected: connected, note: CloudText.note($0)) }
            out["options"] = options
            out["curated_updated"] = list.updated
            let offered = CloudServiceSheetModel.curated
            out["providers"] = offered.compactMap { id -> [String: Any]? in
                guard let p = CloudPreset.preset(id) else { return nil }
                var o: [String: Any] = ["preset": id, "name": CloudStore.presetName(id), "pair": p.pairCredential,
                                        "speech_only": p.speechOnly]
                o["key_pages"] = Dictionary(uniqueKeysWithValues: p.endpoints.map { (($0.region?.rawValue ?? "any"), $0.keyPage) })
                return o
            }
            out["progress"] = AgentSetupProgress.shared.steps.steps.map { ["kind": $0.kind.rawValue, "subject": $0.subject, "state": $0.state.rawValue] }
            return out
        }
    }

    // MARK: connect / test

    private static func connect(_ r: AgentSetupRequest) -> [String: Any] {
        let offered = onMain { CloudServiceSheetModel.curated }
        let plan: (preset: CloudPreset, region: CloudRegion?, credential: String)
        switch r.connectPlan(offered: offered, systemRegion: CloudRegion.forSystem(Locale.current.region?.identifier)) {
        case .failure(let e): return e.json
        case .success(let p): plan = p
        }
        let setup = CloudStore.setup
        // one service per preset (Add Service offers each once): a new key replaces the one there
        let id = setup.services.first { $0.preset == plan.preset.id }?.id
            ?? CloudService.newID(preset: plan.preset.id, taken: Set(setup.services.map(\.id)))
        let svc = CloudService(id: id, preset: plan.preset.id, region: plan.preset.regional ? plan.region : nil)
        let name = CloudStore.presetName(svc.preset)
        step(.connect, svc.id, .running, name)
        let check = check(svc, key: plan.credential)
        guard check["ok"] as? Bool == true else {
            step(.connect, svc.id, .failed, name)
            return check
        }
        onMain {
            let before = CloudSpeech.environment()
            CloudStore.connect(svc, key: plan.credential)
            CloudServiceSheetModel.afterChange(speechBefore: before)
            CloudModelsUI.shared.bump()
        }
        step(.connect, svc.id, .done, name)
        var out = check
        out["service"] = svc.id
        out["region"] = nul(svc.region?.rawValue)
        return out
    }

    private static func test(_ r: AgentSetupRequest) -> [String: Any] {
        guard let who = r.service ?? r.preset else { return AgentSetupError("bad_request", "test needs a service").json }
        let connected = CloudStore.connected
        guard let svc = connected.first(where: { $0.id == who }) ?? connected.first(where: { $0.preset == who }) else {
            return AgentSetupError("not_connected", "\(who) is not connected").json
        }
        guard let key = CloudStore.key(svc) else { return AgentSetupError("no_key", "\(who) has no key in Keychain").json }
        var out = check(svc, key: key)
        out["service"] = svc.id
        return out
    }

    /// The Add Service sheet's Test: one tiny request on the service's curated model (polish_cloud.py check, the key
    /// on stdin); a speech-only service hears the short clip (transcribe.py check-cloud); a service that also
    /// recognises speech (Model Studio) hears it too. → {"ok", "ms", "speech"?} or the failure in English.
    private static func check(_ svc: CloudService, key: String) -> [String: Any] {
        if svc.info.speechOnly {
            guard let pair = VolcengineSpeech.split(key) else { return AgentSetupError("bad_key", "not an App ID and Access Token").json }
            let body = try? JSONSerialization.data(withJSONObject: ["app_id": pair.appID, "token": pair.token])
            let o = script("transcribe.py", ["check-cloud", "--model-id", VolcengineSpeech.modelID], stdin: body, timeout: 45)
            return o["ok"] as? Bool == true ? ["ok": true, "ms": o["ms"] ?? 0, "heard": o["text"] ?? ""] : failure(o, speech: true)
        }
        let list = CuratedModels.list
        guard let model = CloudJob.allCases.lazy.compactMap({ job in list.options(job).first(where: { $0.runs(on: svc) })?.model }).first else {
            return AgentSetupError("no_model", "Blurt has no measured model on \(svc.id) to test with").json
        }
        let body = try? JSONSerialization.data(withJSONObject: ["cloud": CloudStore.payload(svc, model: model, key: key)])
        let o = script("polish_cloud.py", ["check"], stdin: body, timeout: 30)
        guard o["ok"] as? Bool == true else { return failure(o, speech: false) }
        var out: [String: Any] = ["ok": true, "ms": o["ms"] ?? 0, "model": model]
        if svc.preset == "dashscope" {
            // as dictation sends it (CloudSpeech.environment): the service's own address unless it is Beijing's
            var given = ["key": key]
            if svc.effectiveBaseURL != CloudPreset.preset("dashscope")?.endpoint(.china)?.baseURL { given["base_url"] = svc.effectiveBaseURL }
            let sb = try? JSONSerialization.data(withJSONObject: given)
            let s = script("transcribe.py", ["check-cloud", "--model-id", CloudSpeech.dashScopeModel], stdin: sb, timeout: 45)
            out["speech"] = s["ok"] as? Bool == true ? ["ok": true, "ms": s["ms"] ?? 0] as [String: Any] : failure(s, speech: true)
        }
        return out
    }

    /// A check's failure for the agent: its code and one English sentence.
    private static func failure(_ o: [String: Any], speech: Bool) -> [String: Any] {
        let code = o["code"] as? String ?? "failed"
        let message: String
        switch code {
        case "auth": message = speech ? "the App ID or Access Token was refused; check both in the Volcengine console" : "the key was refused; check the key and its region"
        case "network", "timeout": message = "couldn't reach the service; check the network"
        case "rate_limited", "quota": message = "the service says too many requests or no quota left; check the account's balance"
        case "model": message = "the service doesn't know this model id"
        case "vision": message = "this model can't read images"
        case "empty": message = "the model answered nothing"
        case "privacy": message = "recognition is set to stay on this Mac (Settings → Privacy)"
        case "no_uv", "uv_missing": message = "Blurt's tools aren't installed yet; open Blurt and finish its setup"
        default: message = "the service answered with an error"
        }
        return ["ok": false, "code": code, "error": message]
    }

    // MARK: use

    private static func use(_ r: AgentSetupRequest) -> [String: Any] {
        guard let job = r.job, let option = r.option else { return AgentSetupError("bad_request", "use needs a job and an option").json }
        let connected = CloudStore.connected
        let parsed: (choice: AgentSetupChoice, needsTest: Bool)
        switch AgentSetupChoice.parse(job: job, option: option, custom: r.custom, connected: connected, list: CuratedModels.list) {
        case .failure(let e): return e.json
        case .success(let p): parsed = p
        }
        switch parsed.choice {
        case .text(let j, let c):
            if parsed.needsTest, case .cloud(let id, let model) = c {
                // the Custom Model sheet's gate: the job itself first, saved only when it passes
                guard let svc = connected.first(where: { $0.id == id }), let key = CloudStore.key(svc) else {
                    return AgentSetupError("no_key", "\(id) has no key in Keychain").json
                }
                let body = try? JSONSerialization.data(withJSONObject: ["cloud": CloudStore.payload(svc, model: model, key: key), "job": j.rawValue])
                let o = script("polish_cloud.py", ["check"], stdin: body, timeout: 45)
                guard CloudCustom.outcome(o) == .save else {
                    step(.use, j.rawValue, .failed, model)
                    return failure(o, speech: false)
                }
            }
            let name: String = onMain {
                CloudStore.setChoice(c, for: j)
                Dictation.shared.apply()
                if j == .vision { ScreenTextRefine.modeChanged() }
                CloudModelsUI.shared.bump()
                return CloudStore.cloudModel(j)?.model ?? CloudText.localModel(j) ?? M("models.uses.none")
            }
            step(.use, j.rawValue, .done, name)
            let route = onMain { AgentSetupJSON.route(CloudStore.route(j), job: j, setup: CloudStore.setup, list: CuratedModels.list) }
            return ["ok": true, "job": j.rawValue, "route": route]
        case .dictationAuto:
            onMain {
                Dictation.set("asr_model", nil)
                Dictation.shared.apply()
                CloudModelsUI.shared.bump()
            }
            wait { await DictationModels.shared.load() }
            let rec = onMain { DictationModels.shared.asr?.selected }
            step(.use, "dictation", .done, rec.map { id in onMain { DictationModels.shared.asrName(id) } } ?? "")
            return ["ok": true, "job": "dictation", "recognizer": nul(rec)]
        case .dictation(let c):
            if onMain({ DictationModels.shared.asr == nil }) { wait { await DictationModels.shared.load() } }
            let (fit, missing): (DictationChoices.Fit, Bool) = onMain {
                let now = DictationNow.read()
                return (now.fit(c), DictationChoiceAction.needsDownload(c, now: now))
            }
            switch fit {
            case .fits: break
            case .needsKey:
                let need = c == .volcengine ? VolcengineSpeech.preset : c == .cloudRecognizer ? "dashscope" : "deepseek"
                return AgentSetupError("needs_key", "\(c.rawValue) needs a connected \(need) key; connect it first").json
            case .needsMemory(let gb): return AgentSetupError("doesnt_fit", "\(c.rawValue) needs \(gb) GB of memory").json
            case .needsAppleSilicon: return AgentSetupError("doesnt_fit", "\(c.rawValue) needs Apple silicon").json
            case .needsMacOS26: return AgentSetupError("doesnt_fit", "macOS Speech needs macOS 26 and a language it speaks").json
            }
            let name: String = onMain {
                let now = DictationNow.read()
                DictationChoiceAction.use(c, now: now)
                // the live list names the model in full ("Qwen3-ASR 1.7B + cloud polish"), as its other rows do
                return ChoiceText.name(c, base: now.base, short: false)
            }
            step(.use, "dictation", missing ? .running : .done, name)
            var out: [String: Any] = ["ok": true, "job": "dictation", "choice": c.rawValue]
            if missing { out["downloading"] = c == .cloudPolish ? onMain { DictationNow.read().base.rawValue } : c.rawValue }
            return out
        }
    }

    // MARK: download

    private static func download(_ r: AgentSetupRequest) -> [String: Any] {
        if onMain({ DictationModels.shared.asr == nil || DictationModels.shared.polish == nil }) { wait { await DictationModels.shared.load() } }
        return onMain {
            let d = DictationModels.shared
            let want = r.model ?? "recommended"
            if want == "recommended" {
                let (total, missing) = d.recommendedMB
                guard missing > 0 else { return ["ok": true, "installed": true, "size_mb": total] }
                d.downloadRecommended()
                for m in [d.recommendedASR?.id, d.recommendedPolish?.id].compactMap({ $0 }) {
                    step(.download, m, .running, ModelCatalog.name(m, live: nil) ?? m)
                }
                return ["ok": true, "started": [d.recommendedASR?.id, d.recommendedPolish?.id].compactMap { $0 }, "size_mb": missing]
            }
            if let m = d.asr?.models.first(where: { $0.id == want }) {
                if m.installed { return ["ok": true, "installed": true, "model": m.id] }
                if m.fits == false { return AgentSetupError("doesnt_fit", "\(m.id) doesn't fit this Mac's memory").json }
                d.download(m)
                step(.download, m.id, .running, m.name ?? m.id)
                return ["ok": true, "started": [m.id], "size_mb": m.sizeMB]
            }
            if let m = d.polish?.models.first(where: { $0.id == want }) {
                if m.installed { return ["ok": true, "installed": true, "model": m.id] }
                d.download(m)
                step(.download, m.id, .running, m.name)
                return ["ok": true, "started": [m.id], "size_mb": m.sizeMB]
            }
            return AgentSetupError("unknown_model", "\(want) is not one of this Mac's dictation or polish models (see status)").json
        }
    }

    // MARK: verify

    private static func verify(_ r: AgentSetupRequest) -> [String: Any] {
        if onMain({ DictationModels.shared.asr == nil }) { wait { await DictationModels.shared.load() } }
        guard onMain({ DictationModels.shared.dictationReady }) != false else {
            return AgentSetupError("model_missing", "dictation's model isn't downloaded yet; download it first (status: downloads)").json
        }
        let langs = onMain { DictationNow.read().mac.languages }
        let lang = r.language ?? langs.first ?? "en"
        let (said, locale) = AgentSetupVerify.phrase(lang)
        step(.verify, "", .running, "")
        let dir = BlurtPaths.home.appendingPathComponent("tmp")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let wav = dir.appendingPathComponent("agent-verify-\(UUID().uuidString.prefix(8)).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        guard speak(said, locale: locale, to: wav) else {
            step(.verify, "", .failed, "")
            return AgentSetupError("no_voice", "macOS couldn't speak the test clip (say)").json
        }
        let seconds = Double((try? FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? Int) ?? 0) / 32_000
        let vocab = onMain { DictationVocabulary.shared.payload() }
        let language = Config.shared["asr.language"] as? String ?? "auto"
        // a take's key-down starts the polish server; nothing had here, so verify reported cloud polish "unavailable"
        // (dogfood 2026-10-31): start it now, so it comes up while the clip is heard
        if Dictation.polishOn { onMain { Dictation.shared.warmPolish() } }
        let t0 = Date()
        let heard = Dictation.transcribe(wav, vocab: vocab, language: language, prior: "", budget: 30, audioSeconds: seconds)
        let asrMS = Int(Date().timeIntervalSince(t0) * 1000)
        guard heard["ok"] as? Bool == true, let raw = heard["text"] as? String else {
            step(.verify, "", .failed, "")
            return ["ok": false, "code": heard["code"] as? String ?? "asr_failed", "error": "the recogniser didn't answer",
                    "recognizer": nul(heard["model"]), "asr_ms": asrMS]
        }
        // polish as a take does it: on when a style polishes, the cloud model when one is set (the local one its fall-back)
        let cloud = DictationCloud.payload()
        var polished: [String: Any]?
        var polishMS = 0
        if Dictation.polishOn, onMain({ Dictation.shared.polishModel != nil }) || cloud != nil {
            let t1 = Date()
            // a cold server (uv, then the local model the cloud falls back to) can take longer than a take's budget
            polished = Dictation.polish(raw, timeout: Dictation.polishTimeout, loadBudget: max(Dictation.loadBudget, 60),
                                        vocab: vocab, context: nil, cloud: cloud)
            polishMS = Int(Date().timeIntervalSince(t1) * 1000)
        }
        let text = polished?["text"] as? String ?? raw
        let match = AgentSetupVerify.match(said: said, heard: text)
        let ok = match >= 0.6
        step(.verify, "", ok ? .done : .failed, "")
        var out: [String: Any] = ["ok": true, "passed": ok, "said": said, "heard": raw, "text": text,
                                  "match": (match * 100).rounded() / 100, "recognizer": nul(heard["model"]),
                                  "asr_ms": asrMS, "polish_ms": polishMS, "audio_s": (seconds * 10).rounded() / 10]
        if let p = polished {
            out["polish"] = ["where": (cloud != nil && p["fell_back"] as? Bool != true) ? "cloud" : "local",
                             "model": nul(p["model"]), "fell_back": p["fell_back"] ?? false, "reason": nul(p["reason"])]
        } else {
            out["polish"] = ["where": "off"]
        }
        emit(["event": "agent_setup_verify", "passed": ok, "match": match, "asr_ms": asrMS, "polish_ms": polishMS])
        return out
    }

    /// macOS `say` into a 16 kHz wav, in a plain voice of the locale (Samantha, Tingting) when there is one, else
    /// the first voice of the locale, else the default.
    private static func speak(_ text: String, locale: String, to wav: URL) -> Bool {
        var args = ["-o", wav.path, "--data-format=LEI16@16000"]
        let (st, out) = ShellEnv.runCapture("/usr/bin/say", ["-v", "?"], timeout: 10)
        if st == 0 {
            // "Tingting            zh_CN    # 你好…" → "Tingting"
            let voices = String(decoding: out, as: UTF8.self).split(separator: "\n").filter { $0.contains(" " + locale + " ") }
                .map { String($0.prefix { $0 != "#" }).replacingOccurrences(of: locale, with: "").trimmingCharacters(in: .whitespaces) }
            let plain = ["Samantha", "Tingting"]
            if let v = voices.first(where: plain.contains) ?? voices.first, !v.isEmpty { args += ["-v", v] }
        }
        let (code, _) = ShellEnv.runCapture("/usr/bin/say", args + [text], timeout: 30)
        return code == 0 && FileManager.default.fileExists(atPath: wav.path)
    }

    // MARK: helpers

    /// The live list in Settings and onboarding.
    private static func step(_ kind: AgentSetupStep.Kind, _ subject: String, _ state: AgentSetupStep.State, _ name: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AgentSetupProgress.shared.record(AgentSetupStep(kind, subject, state, name: name)) }
        }
    }

    /// A script's JSON answer ({"ok": false, "code"} for every failure), blocking this thread.
    private static func script(_ name: String, _ args: [String], stdin: Data?, timeout: TimeInterval) -> [String: Any] {
        let box = Box<[String: Any]>()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let d = try await ScriptRunner.shared.run(name, args, stdin: stdin, timeout: timeout)
                box.value = lastJSON(d) ?? ["ok": false, "code": "bad_response"]
            } catch ScriptError.failed(_, let out, _) {
                box.value = lastJSON(out) ?? ["ok": false, "code": "failed"]
            } catch ScriptError.timeout {
                box.value = ["ok": false, "code": "timeout"]
            } catch ScriptError.uvMissing {
                box.value = ["ok": false, "code": "no_uv"]
            } catch {
                box.value = ["ok": false, "code": "failed"]
            }
            sem.signal()
        }
        sem.wait()
        var o = box.value ?? ["ok": false, "code": "failed"]
        if o["ok"] as? Bool != true { o["ok"] = false }
        return o
    }

    private static func lastJSON(_ d: Data) -> [String: Any]? {
        for l in String(decoding: d, as: UTF8.self).split(separator: "\n").reversed() where l.hasPrefix("{") {
            if let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any] { return o }
        }
        return nil
    }

    final class Box<T>: @unchecked Sendable { var value: T? }

    /// JSON's null for a missing value.
    private static func nul(_ v: Any?) -> Any { v ?? NSNull() }

    /// Main-actor work from a connection's thread (never called on the main thread itself but tolerated).
    private static func onMain<T>(_ f: @escaping @MainActor () -> T) -> T {
        let box = Box<T>()
        let run = { MainActor.assumeIsolated { box.value = f() } }
        if Thread.isMainThread { run() } else { DispatchQueue.main.sync(execute: run) }
        return box.value!
    }

    /// Awaits main-actor async work from a connection's thread.
    private static func wait(_ f: @escaping @MainActor () async -> Void) {
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in await f(); sem.signal() }
        _ = sem.wait(timeout: .now() + 120)
    }
}
