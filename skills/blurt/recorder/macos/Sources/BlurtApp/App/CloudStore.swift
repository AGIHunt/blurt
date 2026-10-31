// The cloud services the user connected and which model does each text job (Settings → Models; the rules are BlurtCore's
// CloudServices.swift and CloudCurated.swift): record.cloud, the keys in the login Keychain, and what each job's request
// carries — read by dictation's polish and translate, ⌥T and ⌥C's second reading. Which models a job offers is the
// curated list's (CuratedModels); no service's own model list is read any more. The speech jobs keep their own settings (asr.*); a Model Studio or OpenAI key connected here is
// also what cloud speech uses (CloudSpeech.environment).
//
// Keys: service "Blurt Cloud Polish", account = the service's id — the accounts cloud polish used before (deepseek,
// dashscope, openai, anthropic), so nothing is entered again. Model Studio falls back to the key saved for cloud speech
// ("Blurt Cloud Speech" / qwen3-asr-flash). A key is read when a request goes out, sent to the local script with it
// (stdin or the warm server's local socket), never written to a file or a log.
//
// Migration (once, the first time record.cloud is read): CloudMigration — every old service with a key is connected,
// every job stays where it ran. record.cloud v1 (Auto took a service's newest model): CuratedMigration pins an Auto job
// that ran on a model the curated list doesn't have, read from the model lists v1 cached ($BLURT_HOME/cloud-models.json).
import Foundation
import Security
import BlurtCore

enum CloudStore {
    /// posted (main queue) when a service, a key, a job's choice or a model list changes
    static let changed = Notification.Name("dev.blurt.cloud.changed")

    private static let lock = NSLock()
    private static var cachedSetup: CloudSetup?
    private static var keyed: [String: Bool] = [:]
    private static var lists: [String: [CloudModelInfo]]?

    // MARK: record.cloud

    static var setup: CloudSetup {
        lock.lock()
        if let s = cachedSetup { lock.unlock(); return s }
        lock.unlock()
        let s = loadOrMigrate()
        lock.lock(); cachedSetup = s; lock.unlock()
        return s
    }

    static func save(_ s: CloudSetup) {
        setRecordConfig("cloud", s.json)
        lock.lock(); cachedSetup = s; lock.unlock()
        didChange()
    }

    static func setChoice(_ c: CloudJobChoice, for job: CloudJob) {
        var s = setup
        s.jobs[job] = c == .auto ? nil : c
        save(s)
        emit(["event": "cloud_job", "job": job.rawValue, "choice": choiceName(c)])
    }

    private static func choiceName(_ c: CloudJobChoice) -> String {
        switch c {
        case .auto: return "auto"
        case .local: return "local"
        case .cloud(let s, let m): return m.isEmpty ? s : "\(s):\(m)"
        }
    }

    private static func loadOrMigrate() -> CloudSetup {
        if let o = recordConfig()["cloud"] as? [String: Any] {
            let s = CloudSetup(json: o)
            guard (o["v"] as? Int ?? 1) < 2 else { return s }
            // v1: an Auto job keeps the model it ran on when the curated list doesn't have it
            let services = s.services.filter { key($0) != nil }
            let pinned = CuratedMigration.pin(s, connected: services, list: CuratedModels.list) { job in
                CloudRouting.resolve(job, choice: .auto, connected: services, models: { v1Models($0) })
            }
            setRecordConfig("cloud", pinned.json)
            if pinned != s {
                emit(["event": "cloud_pinned", "jobs": Dictionary(uniqueKeysWithValues: pinned.jobs.map { ($0.key.rawValue, choiceName($0.value)) })])
            }
            return pinned
        }
        let dictation = recordConfig()["dictation"] as? [String: Any] ?? [:]
        let screen = recordConfig()["screen_text"] as? [String: Any] ?? [:]
        var keys = Set<String>()
        if Key.testBuild {
            // a test build: the one service the old setup named, when the test gave a key
            if Key.read("deepseek") != nil { keys.insert((dictation["cloud_polish"] as? [String: Any])?["provider"] as? String ?? "deepseek") }
        } else {
            for p in ["deepseek", "dashscope", "openai", "anthropic"] where Key.read(p) != nil { keys.insert(p) }
        }
        let speech = !Key.testBuild && CloudSpeech.Key.has(CloudSpeech.dashScopeModel)
        let s = CloudMigration.migrate(dictation: dictation, screenText: screen, keys: keys, speechKey: speech)
        setRecordConfig("cloud", s.json)
        emit(["event": "cloud_migrated", "services": s.services.map(\.id), "jobs": Dictionary(uniqueKeysWithValues: s.jobs.map { ($0.key.rawValue, choiceName($0.value)) })])
        return s
    }

    // MARK: services and their keys

    /// The services with a key, in the order they were added.
    static var connected: [CloudService] { setup.services.filter(hasKey) }

    static func hasKey(_ s: CloudService) -> Bool {
        lock.lock()
        if let k = keyed[s.id] { lock.unlock(); return k }
        lock.unlock()
        let has = key(s) != nil
        lock.lock(); keyed[s.id] = has; lock.unlock()
        return has
    }

    /// The service's key: its own, else (Model Studio) the one saved for cloud speech.
    static func key(_ s: CloudService) -> String? {
        if let k = Key.read(s.id) { return k }
        if s.preset == "dashscope", !Key.testBuild { return CloudSpeech.Key.read(CloudSpeech.dashScopeModel) }
        return nil
    }

    /// Connect (or change) a service: its key (when one was typed) and its address; the jobs on Auto take it up when
    /// it runs one of their curated models.
    static func connect(_ svc: CloudService, key: String?) {
        var s = setup
        if let i = s.services.firstIndex(where: { $0.id == svc.id }) { s.services[i] = svc } else { s.services.append(svc) }
        if let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            Key.write(svc.id, k)
            // Model Studio's key is cloud speech's too: an older key set for speech alone goes, so one key is in use
            if svc.preset == "dashscope" { CloudSpeech.Key.write(CloudSpeech.dashScopeModel, "") }
        }
        lock.lock(); keyed[svc.id] = nil; lock.unlock()
        save(s)
        CloudSpeech.invalidate()        // a Model Studio or OpenAI key recognises speech too
        emit(["event": "cloud_service", "action": "connect", "service": svc.id, "preset": svc.preset, "key": key?.isEmpty == false])
    }

    /// Remove a service: its key leaves the Keychain; a job that was on it goes back to this Mac.
    static func remove(_ svc: CloudService) {
        var s = setup
        s.services.removeAll { $0.id == svc.id }
        for (job, c) in s.jobs { if case .cloud(let id, _) = c, id == svc.id { s.jobs[job] = .local } }
        Key.write(svc.id, "")
        lock.lock(); keyed[svc.id] = nil; lock.unlock()
        save(s)
        CloudSpeech.invalidate()
        emit(["event": "cloud_service", "action": "remove", "service": svc.id])
    }

    static func invalidateKeys() { lock.lock(); keyed = [:]; lock.unlock() }

    static func didChange() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// A service by name, for people: the preset's ("DeepSeek", "阿里云百炼"), or the user's own name or host.
    static func name(_ s: CloudService) -> String {
        if s.info.custom { return s.name.trimmingCharacters(in: .whitespaces).isEmpty ? s.host : s.name }
        return presetName(s.preset)
    }

    static func presetName(_ id: String) -> String {
        switch id {
        case "deepseek": return M("models.preset.deepseek")
        case "dashscope": return M("models.preset.dashscope")
        case "volcengine": return M("models.preset.volcengine")
        case VolcengineSpeech.preset: return M("models.preset.volcengine_speech")
        case "moonshot": return M("models.preset.moonshot")
        case "zhipu": return M("models.preset.zhipu")
        case "minimax": return M("models.preset.minimax")
        case "xiaomi": return M("models.preset.xiaomi")
        case "openai": return M("models.preset.openai")
        case "anthropic": return M("models.preset.anthropic")
        case "gemini": return M("models.preset.gemini")
        case "openrouter": return M("models.preset.openrouter")
        case "custom-anthropic": return M("models.preset.custom_anthropic")
        default: return M("models.preset.custom_openai")
        }
    }

    // MARK: v1's model lists (read once, to pin v1 setups)

    /// The list v1 cached for a service at its current address (nil: none).
    private static func v1Models(_ s: CloudService) -> [CloudModelInfo]? {
        lock.lock()
        if let l = lists { lock.unlock(); return l[s.id] }
        lock.unlock()
        var out: [String: [CloudModelInfo]] = [:]
        let file = BlurtPaths.home.appendingPathComponent("cloud-models.json")
        if let d = try? Data(contentsOf: file), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            let setup = CloudSetup(json: recordConfig()["cloud"] as? [String: Any])
            for (id, v) in o {
                guard let e = v as? [String: Any], let base = e["base"] as? String,
                      setup.service(id)?.effectiveBaseURL == base else { continue }
                out[id] = (e["models"] as? [[String: Any]] ?? []).compactMap(CloudModelInfo.init(json:))
            }
        }
        lock.lock(); lists = out; lock.unlock()
        return out[s.id]
    }

    /// At launch and when Settings → Models opens: record.cloud read (its one-time moves) and the keys looked up off
    /// the main thread, and the curated list fetched again when a day old.
    static func refreshStale() {
        Task.detached(priority: .utility) { _ = connected }
        CuratedModels.refreshIfDue()
    }

    // MARK: where a job goes

    static func route(_ job: CloudJob) -> CloudRoute {
        CuratedRouting.resolve(job, choice: setup.choice(job), connected: connected, list: CuratedModels.list)
    }

    /// A model Blurt didn't measure on a job: the curated option to switch to (CuratedRouting.recommendation).
    static func recommendation(_ job: CloudJob) -> CuratedRouting.Pick? {
        CuratedRouting.recommendation(job, route: route(job), connected: connected, list: CuratedModels.list)
    }

    /// The services connected with a key that run a curated option of the job (Compare's "a key for cloud polish").
    static func curatedConnected(_ job: CloudJob) -> Bool {
        CuratedModels.list.options(job).contains { o in connected.contains(where: o.runs(on:)) }
    }

    /// What a job's request carries to the scripts ({"provider", "base_url", "model", "protocol", "key"}, the model
    /// also as translate's and Copy Text from Screen's), nil when the job runs on this Mac or has no key.
    static func payload(_ job: CloudJob) -> [String: Any]? {
        guard case .cloud(let id, let model) = route(job), let s = setup.service(id), let k = key(s), !model.isEmpty else { return nil }
        return payload(s, model: model, key: k)
    }

    static func payload(_ s: CloudService, model: String, key: String) -> [String: Any] {
        ["provider": s.preset, "service": s.id, "base_url": s.effectiveBaseURL, "model": model, "protocol": s.api.rawValue,
         "key": key, "translate_model": model, "vision_model": model]
    }

    /// The job's model and where it runs, for a line: ("DeepSeek V4.1 Flash", "DeepSeek") — a curated model by its
    /// name, any other by its id —, or nil on this Mac.
    static func cloudModel(_ job: CloudJob) -> (model: String, service: String)? {
        guard case .cloud(let id, let model) = route(job), let s = setup.service(id) else { return nil }
        return (CuratedModels.list.option(job, on: s, model: model)?.name ?? model, name(s))
    }

    // MARK: the key (login Keychain)

    enum Key {
        static let service = "Blurt Cloud Polish"

        /// A test build (BLURT_TEST_COMMANDS=1) never touches the login Keychain — never reads the user's real key
        /// (it would go to the service), never deletes it: BLURT_TEST_CLOUD_KEY, else what this run saved.
        static var testBuild: Bool { ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1" }
        private static var testKeys: [String: String] = [:]
        private static let testLock = NSLock()

        private static func query(_ account: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        }

        static func read(_ account: String) -> String? {
            if testBuild {
                testLock.lock(); defer { testLock.unlock() }
                if let k = testKeys[account] { return k.isEmpty ? nil : k }
                return ProcessInfo.processInfo.environment["BLURT_TEST_CLOUD_KEY"].flatMap { $0.isEmpty ? nil : $0 }
            }
            var q = query(account)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
                  let k = String(data: d, encoding: .utf8), !k.isEmpty else { return nil }
            return k
        }

        @discardableResult
        static func write(_ account: String, _ key: String) -> Bool {
            defer { CloudStore.invalidateKeys(); CloudSpeech.invalidate() }
            let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if testBuild { testLock.lock(); testKeys[account] = k; testLock.unlock(); return true }
            // an empty key is the one way to remove it; otherwise update in place, and add only when there is none —
            // never delete first (a failed add, a locked Keychain, would lose the key that worked)
            guard !k.isEmpty else {
                let r = SecItemDelete(query(account) as CFDictionary)
                return r == errSecSuccess || r == errSecItemNotFound
            }
            let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: Data(k.utf8)] as CFDictionary)
            guard update == errSecItemNotFound else { return update == errSecSuccess }
            var q = query(account)
            q[kSecValueData as String] = Data(k.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            q[kSecAttrLabel as String] = "Blurt Cloud Polish (\(account))"
            return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        }
    }
}

/// Loc.t for the Models table (new in v1.0.8: Settings → Models' cloud services and jobs).
func M(_ key: String, _ args: CVarArg...) -> String {
    let fmt = Loc.string(key, table: "Models")
    return args.isEmpty ? fmt : String(format: fmt, locale: Loc.locale, arguments: args)
}
