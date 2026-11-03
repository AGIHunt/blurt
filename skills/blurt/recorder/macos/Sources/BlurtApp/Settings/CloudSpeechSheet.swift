// Settings → Models → Advanced → the cloud recognition services (v1.0.4): each row's Set Up… opens this sheet (the
// speech model, the speed, a Groq or other OpenAI-compatible address). A Model Studio or OpenAI key connected under
// Cloud services (CloudStore) recognises speech too, with nothing to set here; a key set here wins. The sheet: the
// service (OpenAI, Groq or another OpenAI-compatible API: base URL and model; or DashScope), the API key (kept in the login Keychain, service "Blurt Cloud Speech", account = the model's id; the field never
// shows it back). Before, these keys only came from the user's shell profile (`export GROQ_API_KEY=…`), which a person
// who doesn't live in a terminal could not set; those variables still work when nothing is set here.
//
// transcribe.py still reads the environment: every script the app starts (ScriptRunner) gets the keys set here as
// BLURT_ASR_API_KEY / BLURT_ASR_BASE_URL / BLURT_ASR_MODEL (the OpenAI-compatible service) and DASHSCOPE_API_KEY —
// over whatever the shell exports. Nothing is written to a file or a log.
import AppKit
import Security
import SwiftUI
import BlurtCore

enum CloudSpeech {
    /// the registry's two cloud entries (asr_models.json)
    static let openAIModel = "openai-compatible"
    static let dashScopeModel = "qwen3-asr-flash"

    enum Service: String, CaseIterable, Identifiable {
        case openai, groq, custom
        var id: String { rawValue }
        var defaultBaseURL: String {
            switch self {
            case .openai: return "https://api.openai.com/v1"
            case .groq: return "https://api.groq.com/openai/v1"
            case .custom: return ""
            }
        }
        /// transcribe.py's own defaults for these services
        var defaultModel: String {
            switch self {
            case .openai: return "whisper-1"
            case .groq: return "whisper-large-v3-turbo"
            case .custom: return ""
            }
        }
        var keyPage: URL? {
            switch self {
            case .openai: return URL(string: "https://platform.openai.com/api-keys")
            case .groq: return URL(string: "https://console.groq.com/keys")
            case .custom: return nil
            }
        }
    }

    /// The OpenAI-compatible service's choices (asr.cloud.openai-compatible = {"service", "base_url", "model"}).
    struct Setup: Equatable {
        var service: Service = .groq
        var baseURL = ""
        var model = ""
        var effectiveBaseURL: String { trimmed(baseURL).isEmpty ? service.defaultBaseURL : trimmed(baseURL) }
        var effectiveModel: String { trimmed(model).isEmpty ? service.defaultModel : trimmed(model) }
        /// enough to send a request: "Other" needs its address and its model
        var complete: Bool { !effectiveBaseURL.isEmpty && !effectiveModel.isEmpty }
    }

    static var setup: Setup {
        let all = Config.shared["asr.cloud"] as? [String: Any] ?? [:]
        let o = all[openAIModel] as? [String: Any] ?? [:]
        return Setup(service: Service(rawValue: o["service"] as? String ?? "") ?? .groq,
                     baseURL: o["base_url"] as? String ?? "", model: o["model"] as? String ?? "")
    }

    /// DashScope's model (asr.cloud["qwen3-asr-flash"].model; "" = qwen3-asr-flash, the one measured: CloudModels)
    static var dashScopeChoice: String {
        ((Config.shared["asr.cloud"] as? [String: Any])?[dashScopeModel] as? [String: Any])?["model"] as? String ?? ""
    }
    static func saveDashScope(model: String) {
        var all = Config.shared["asr.cloud"] as? [String: Any] ?? [:]
        let t = trimmed(model)
        all[dashScopeModel] = t.isEmpty ? nil : ["model": t]
        Config.shared.set("asr.cloud", all)
        invalidate()
    }

    static func save(_ s: Setup) {
        var o: [String: Any] = ["service": s.service.rawValue]
        if !trimmed(s.baseURL).isEmpty { o["base_url"] = trimmed(s.baseURL) }
        if !trimmed(s.model).isEmpty { o["model"] = trimmed(s.model) }
        var all = Config.shared["asr.cloud"] as? [String: Any] ?? [:]
        all[openAIModel] = o
        Config.shared.set("asr.cloud", all)
        invalidate()
    }

    /// How fast every cloud service hears the audio (asr.cloud.speed; transcribe.py `cloud_speed`): billing is per
    /// second sent. 1x is the default since dictation sends the whole take (2026-10-31: Qwen3-ASR Flash on the
    /// founder's 95 takes, whole, 2.0 % errors at 1x against 3.3 % at 1.5x — docs/design/dictation.md §Cloud
    /// recognition; $0.11 an hour of speech); 1.5x is a third cheaper, 2x halves the cost but errs a lot more
    /// (docs/design/first-minute-speech.md §2.4).
    static let speeds: [Double] = [1.0, 1.5, 2.0]
    static let defaultSpeed = 1.0
    static var speed: Double {
        let v = (Config.shared["asr.cloud"] as? [String: Any])?["speed"] as? Double ?? defaultSpeed
        return speeds.min { abs($0 - v) < abs($1 - v) } ?? defaultSpeed
    }
    static func setSpeed(_ v: Double) {
        var all = Config.shared["asr.cloud"] as? [String: Any] ?? [:]
        all["speed"] = v
        Config.shared.set("asr.cloud", all)
    }
    /// "1" / "1.5" / "2": the strings' suffix
    static func speedKey(_ v: Double) -> String { v == 1.5 ? "15" : String(Int(v)) }

    // MARK: what the scripts get

    private static let lock = NSLock()
    private static var cached: [String: String]?

    /// The variables transcribe.py reads, for the keys set here (empty when none is).
    static func environment() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        var env: [String: String] = [:]
        let services = CloudStore.setup.services
        // a key no request can carry (stray "ç" from ⌥C, a space) is never sent: the other key, if any, is
        func usable(_ k: String?) -> String? { k.flatMap { CloudKeyCheck.problem($0) == nil ? $0 : nil } }
        if let k = usable(Key.read(openAIModel)) {
            let s = setup
            env["BLURT_ASR_API_KEY"] = k
            if !s.effectiveBaseURL.isEmpty { env["BLURT_ASR_BASE_URL"] = s.effectiveBaseURL }
            if !s.effectiveModel.isEmpty { env["BLURT_ASR_MODEL"] = s.effectiveModel }
        } else if let o = services.first(where: { $0.preset == "openai" }), let k = usable(CloudStore.key(o)) {
            // OpenAI connected under Settings → Models → Cloud services: its key recognises speech too (its own
            // address; the model picked here for OpenAI, else whisper-1 for its timestamps)
            let s = setup
            env["BLURT_ASR_API_KEY"] = k
            env["BLURT_ASR_BASE_URL"] = o.effectiveBaseURL
            env["BLURT_ASR_MODEL"] = s.service == .openai && !s.model.trimmingCharacters(in: .whitespaces).isEmpty
                ? s.effectiveModel : Service.openai.defaultModel
        }
        // Volcengine Speech: its App ID and Access Token, one Keychain item (VolcengineSpeech) — only a pair that can be
        // sent; a value that isn't one is left out (the model then isn't offered: transcribe.py needs both)
        if let v = services.first(where: { $0.preset == VolcengineSpeech.preset }),
           let pair = VolcengineSpeech.split(CloudStore.Key.read(v.id)),
           VolcengineSpeech.problem(appID: pair.appID, token: pair.token) == nil {
            env[VolcengineSpeech.appIDVariable] = pair.appID
            env[VolcengineSpeech.tokenVariable] = pair.token
        }
        // DashScope: Model Studio's key under Cloud services (one key: first-minute-speech.md §4.3), else the key set
        // for speech alone, at that service's address (Singapore for an international account). Cloud services first:
        // the key the user last pasted and tested there must be the one dictation sends (2026-10-31: an older
        // speech-only key with stray characters won, so Test passed and every take failed)
        let ms = services.first { $0.preset == "dashscope" }
        if let k = usable(ms.flatMap({ CloudStore.Key.read($0.id) })) ?? usable(Key.read(dashScopeModel)) {
            env["DASHSCOPE_API_KEY"] = k
            if !dashScopeChoice.isEmpty { env["DASHSCOPE_ASR_MODEL"] = dashScopeChoice }
            if let m = ms, m.effectiveBaseURL != CloudPreset.preset("dashscope")?.endpoint(.china)?.baseURL {
                env["DASHSCOPE_BASE_URL"] = m.effectiveBaseURL
            }
        }
        cached = env
        return env
    }

    /// The keys changed (saved, removed, a service connected): read again next time. A speech server Blurt started
    /// already holds the old ones in its environment — when what it would get now differs, it is ended and warmed
    /// again, so the next take sends the key the user just saved (2026-10-31: Test passed on the new key while the
    /// server kept sending the old one).
    static func invalidate() {
        lock.lock(); let before = cached; cached = nil; lock.unlock()
        guard let before else { return }
        DispatchQueue.global(qos: .utility).async {
            guard environment() != before else { return }
            DispatchQueue.main.async { VoiceInput.restartForNewKeys() }
        }
    }

    // MARK: Test (CloudSpeechCheck)

    /// Settings' Test: `transcribe.py check-cloud` — a short spoken clip to the service as dictation would send it,
    /// with these choices; a key typed and not saved yet goes on stdin (never on the command line or in a log), else
    /// the saved one (from the environment, as every script gets it). `done` on the main queue. UI-free: the cloud
    /// settings can move without it.
    static func check(modelID: String, typedKey: String, setup: Setup, dsModel: String,
                      done: @escaping (CloudSpeechCheck.Result) -> Void) {
        guard let typed = CloudSpeechCheck.clean(typedKey) else { return done(.failed("speech.cloud.check.bad_key")) }
        guard typed.isEmpty else { return run(modelID, ["key": typed], setup, dsModel, done) }
        // the saved key: read off the main thread (a Keychain read can wait for macOS to ask)
        DispatchQueue.global(qos: .userInitiated).async {
            let saved = Key.read(modelID) ?? (modelID == dashScopeModel ? DictationCloud.Key.read(.dashscope) : nil) ?? ""
            DispatchQueue.main.async {
                if saved.isEmpty { return done(.failed("speech.cloud.check.no_key")) }
                if CloudSpeechCheck.clean(saved) == nil { return done(.failed("speech.cloud.check.bad_key")) }
                run(modelID, [:], setup, dsModel, done)
            }
        }
    }

    private static func run(_ modelID: String, _ key: [String: String], _ setup: Setup, _ dsModel: String,
                            _ done: @escaping (CloudSpeechCheck.Result) -> Void) {
        var given = key
        if modelID == openAIModel {
            given["base_url"] = setup.effectiveBaseURL
            given["model"] = setup.effectiveModel
        } else if !dsModel.trimmingCharacters(in: .whitespaces).isEmpty {
            given["model"] = dsModel.trimmingCharacters(in: .whitespaces)
        }
        let body = try? JSONSerialization.data(withJSONObject: given)
        Scripts.call("transcribe.py", ["check-cloud", "--model-id", modelID], stdin: body, timeout: 45) { r in
            switch r {
            case .success(let o): done(CloudSpeechCheck.result(o))
            case .failure(let f): done(.failed(CloudSpeechCheck.sentence(f.code)))
            }
        }
    }

    /// Settings' Test for Volcengine Speech: the same short clip through `transcribe.py check-cloud`, with an App ID and
    /// Access Token typed and not saved yet on stdin (never on the command line or in a log), else the saved pair (from
    /// the environment, as every script gets it). `done` on the main queue.
    static func checkVolcengine(appID: String, token: String, done: @escaping (CloudSpeechCheck.Result) -> Void) {
        let given: [String: String] = token.isEmpty ? [:] : ["app_id": appID, "token": token]
        let body = try? JSONSerialization.data(withJSONObject: given)
        Scripts.call("transcribe.py", ["check-cloud", "--model-id", VolcengineSpeech.modelID], stdin: body, timeout: 45) { r in
            switch r {
            case .success(let o): done(CloudSpeechCheck.result(o))
            case .failure(let f): done(.failed(CloudSpeechCheck.sentence(f.code)))
            }
        }
    }

    /// At launch: every script the app starts gets the keys (ScriptRunner.extraEnvironment).
    static func install() { ScriptRunner.extraEnvironment = { CloudSpeech.environment() } }

    // MARK: the key (login Keychain)

    enum Key {
        static let service = "Blurt Cloud Speech"
        /// test builds (test commands) keep keys in memory: they never touch the login Keychain
        private static var testKeys: [String: String] = [:]
        private static var testing: Bool { ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1" }

        private static func query(_ account: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        }

        static func read(_ account: String) -> String? {
            if testing { return testKeys[account] }
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
            defer { CloudSpeech.invalidate() }
            let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if testing { testKeys[account] = k.isEmpty ? nil : k; return true }
            // deleted only when asked to (an empty key); a new key replaces the old one in place, so a failed write
            // (a locked Keychain, an item another signature made) never loses the key that was there
            guard !k.isEmpty else {
                let r = SecItemDelete(query(account) as CFDictionary)
                return r == errSecSuccess || r == errSecItemNotFound
            }
            let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: Data(k.utf8)] as CFDictionary)
            guard update == errSecItemNotFound else { return update == errSecSuccess }
            var q = query(account)
            q[kSecValueData as String] = Data(k.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            q[kSecAttrLabel as String] = "Blurt Cloud Speech (\(account))"
            return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        }

        static func has(_ account: String) -> Bool { read(account) != nil }
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
}

/// Loc.t for the Speech table
private func S(_ key: String, _ args: CVarArg...) -> String {
    let fmt = Loc.string(key, table: "Speech")
    return args.isEmpty ? fmt : String(format: fmt, locale: Loc.locale, arguments: args)
}

/// One cloud service's sheet: the OpenAI-compatible one has a service, an address and a model; DashScope only a key.
/// Nothing changes until Done; Done with a new key restarts the recognition server when a job uses this service.
struct CloudSpeechSheet: View {
    let modelID: String
    let title: String
    var close: (_ saved: Bool) -> Void
    @State private var setup = CloudSpeech.setup
    @State private var speed = CloudSpeech.speed
    @State private var dsModel = CloudSpeech.dashScopeChoice
    @State private var key = ""
    @State private var stored: Bool
    /// Test's answer (nil: not run); `testing` while it runs
    @State private var checked: CloudSpeechCheck.Result?
    @State private var testing = false

    init(modelID: String, title: String, close: @escaping (_ saved: Bool) -> Void) {
        self.modelID = modelID
        self.title = title
        self.close = close
        _stored = State(initialValue: CloudSpeech.Key.has(modelID))
    }

    private var openAI: Bool { modelID == CloudSpeech.openAIModel }
    private var keyPage: URL? {
        openAI ? setup.service.keyPage : URL(string: "https://bailian.console.aliyun.com/")
    }
    private var canSave: Bool { !openAI || setup.complete || (key.isEmpty && !stored) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(S("speech.cloud.sheet.note"))
                .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            form.padding(.top, 16)
            HStack(spacing: 10) {
                Button(T("dictation.cloud.test")) { test() }
                    .disabled(testing || (!stored && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || (openAI && !setup.complete))
                if testing { BrandSpinnerView(size: 12) }
                if let c = checked, !testing {
                    Group {
                        switch c {
                        case .ok(let ms, let heard):
                            Text(heard ? T("dictation.cloud.check.ok", String(format: "%.1f", Double(ms) / 1000))
                                       : S("speech.cloud.check.ok_silent", String(format: "%.1f", Double(ms) / 1000)))
                                .foregroundStyle(Color.brandOk)
                        case .failed(let k):
                            Text(S(k)).foregroundStyle(Color.brandErr)
                        }
                    }
                    .font(.system(size: SettingsMetrics.detailSize)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(T("dictation.cloud.cancel")) { close(false) }.keyboardShortcut(.cancelAction)
                Button(T("dictation.cloud.done")) { save() }.keyboardShortcut(.defaultAction).disabled(!canSave || testing)
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 18)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    var form: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            if openAI {
                GridRow {
                    label("dictation.cloud.service")
                    ChoicePopup(label: T("dictation.cloud.service"),
                                choices: CloudSpeech.Service.allCases.map { ($0, S("speech.cloud.service.\($0.rawValue)")) },
                                selection: Binding(get: { setup.service }, set: {
                                    if $0 != setup.service { setup.model = "" }     // that service's own default
                                    setup.service = $0
                                }), width: 220)
                }
                GridRow {
                    label("dictation.cloud.base_url")
                    TextField(setup.service.defaultBaseURL.isEmpty ? "https://…/v1" : setup.service.defaultBaseURL, text: $setup.baseURL)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    label("dictation.cloud.model")
                    CloudModelPicker(label: T("dictation.cloud.model"), job: .speech, provider: setup.service.rawValue, model: $setup.model)
                        .id("speech-\(setup.service.rawValue)")
                }
            } else {
                GridRow {
                    label("dictation.cloud.model")
                    CloudModelPicker(label: T("dictation.cloud.model"), job: .speech, provider: "dashscope", model: $dsModel)
                }
            }
            GridRow {
                Text(S("speech.cloud.speed")).foregroundStyle(.secondary).fixedSize().gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 5) {
                    ChoicePopup(label: S("speech.cloud.speed"),
                                choices: CloudSpeech.speeds.map { ($0, S("speech.cloud.speed.\(CloudSpeech.speedKey($0))")) },
                                selection: $speed, width: 220)
                    Text(S("speech.cloud.speed.line", S("speech.cloud.speed.\(CloudSpeech.speedKey(speed)).hint"), S("speech.cloud.speed.all")))
                        .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, SettingsMetrics.fieldTextInset)
                }
            }
            GridRow {
                label("dictation.cloud.key")
                VStack(alignment: .leading, spacing: 5) {
                    SecureField(stored ? T("dictation.cloud.key.stored") : T("dictation.cloud.key.placeholder"), text: $key)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 12) {
                        if let u = keyPage { TextLinkButton(S("speech.cloud.key.get")) { NSWorkspace.shared.open(u) } }
                        if stored {
                            TextLinkButton(T("dictation.cloud.key.forget"), tint: .secondary) {
                                CloudSpeech.Key.write(modelID, "")
                                stored = false
                                key = ""
                                emit(["event": "speech_cloud", "action": "forget_key", "model": modelID])
                            }
                        }
                    }
                    .font(.system(size: SettingsMetrics.detailSize))
                    .padding(.leading, SettingsMetrics.fieldTextInset)      // under the field's text, not its outline
                }
            }
        }
    }

    func label(_ k: String) -> some View { Text(T(k)).foregroundStyle(.secondary).fixedSize().gridColumnAlignment(.trailing) }

    func test() {
        testing = true
        emit(["event": "speech_cloud", "action": "test", "model": modelID])
        CloudSpeech.check(modelID: modelID, typedKey: key, setup: setup, dsModel: dsModel) { r in
            testing = false
            checked = r
            emit(["event": "speech_cloud", "action": "tested", "model": modelID, "ok": { if case .ok = r { return true }; return false }()])
        }
    }

    func save() {
        // a key with characters no key has (what ⌥C types, "ç", after the founder's key): not kept, said here
        guard let k = CloudSpeechCheck.clean(key) else { checked = .failed("speech.cloud.check.bad_key"); return }
        // a service Blurt didn't test (OpenAI, Groq, another address): saved only once its clip comes back
        // (Settings → Models' Custom Model rule, docs/design/first-minute-speech.md §10.5)
        if openAI && (!k.isEmpty || stored) {
            testing = true
            CloudSpeech.check(modelID: modelID, typedKey: key, setup: setup, dsModel: dsModel) { r in
                testing = false
                checked = r
                emit(["event": "speech_cloud", "action": "save_tested", "model": modelID, "ok": { if case .ok = r { return true }; return false }()])
                if case .ok = r { commit(k) }
            }
            return
        }
        commit(k)
    }

    private func commit(_ k: String) {
        if openAI { CloudSpeech.save(setup) }
        if speed != CloudSpeech.speed { CloudSpeech.setSpeed(speed) }
        if !openAI, dsModel != CloudSpeech.dashScopeChoice { CloudSpeech.saveDashScope(model: dsModel) }
        if !k.isEmpty { CloudSpeech.Key.write(modelID, k) }
        emit(["event": "speech_cloud", "action": "save", "model": modelID, "service": openAI ? setup.service.rawValue : "dashscope",
              "key": !k.isEmpty, "speed": speed])
        close(true)
    }
}
