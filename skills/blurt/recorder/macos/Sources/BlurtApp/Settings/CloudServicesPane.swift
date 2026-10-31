// Settings → Models: Cloud services and the text jobs' rows (2026-10-31; docs/design/system.md §3.4). CloudStore holds the
// data, BlurtCore's CloudServices and CloudCurated the rules.
//
//   Cloud services   one line per connected service — its name (DeepSeek marked Recommended), where it is (China /
//                    International, a custom service's host), whether its key does speech too, "Not tested by Blurt"
//                    for a service the curated list doesn't use — and Edit…; then Add Service… while a curated
//                    service is left to add. Empty: one line on what a key is for, and DeepSeek's price.
//   the sheet        Service (the curated list's: DeepSeek, Model Studio), Region where a service has a China and an
//                    international address (from the system region), the base URL filled in (editable), the API key
//                    (Keychain; never shown back; a key with characters no key has is refused; another service's key,
//                    known by its start, points to Custom Model), Test: one tiny request on the service's curated
//                    model → "OK · 320 ms" or one plain sentence (Model Studio and OpenAI: the speech check too,
//                    CloudSpeech.check). Connect tests first. Volcengine Speech (speech only, China) asks for its
//                    App ID and Access Token instead of a key and an address; its Test is the speech clip
//                    (CloudSpeech.checkVolcengine), and the pair is one Keychain item (BlurtCore VolcengineSpeech).
//   the job rows     Polish, Translate, Copy Text from Screen: This Mac, then the curated models for the job (a
//                    service with no key yet says so: picking it adds the key, then uses it), then Advanced: a model
//                    kept from an earlier setup ("Not tested by Blurt") and Custom Model…. The line under says where
//                    the content goes; on a model Blurt didn't measure, "Recommended: DeepSeek V4.1 Flash" with Switch.
//   Custom Model     any service's model for the job by its id (a connected service, or a new one: base URL and key);
//                    Save runs the job itself first (polish_cloud.py check --job) and saves only when it passes.
//   feature pages    one row per job they use: "Uses DeepSeek V4.1 Flash · cloud" (CloudText.uses) with Change…
//                    (JobChangeButton), which opens the job's row here.
// Test hooks: `settings speech/speech.services` (the section), `dictation settings-scroll cloud_sheet` or
// BLURT_TEST_CLOUD_SHEET=add opens Add Service, BLURT_TEST_CLOUD_SHEET=<service id> that service's sheet.
import AppKit
import SwiftUI
import BlurtCore

/// Re-draws the cloud rows when CloudStore changes (a key, a service, a job, a model list).
@MainActor
final class CloudModelsUI: ObservableObject {
    static let shared = CloudModelsUI()
    @Published private(set) var tick = 0
    private var token: NSObjectProtocol?
    init() {
        token = NotificationCenter.default.addObserver(forName: CloudStore.changed, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick += 1 }
        }
    }
    func bump() { tick += 1 }
}

// MARK: - text

enum CloudText {
    static func region(_ r: CloudRegion) -> String { r == .china ? M("models.region.china") : M("models.region.global") }

    /// A curated option's measured line ("Accurate, about 0.8 s"), nil when it has none (or this build lacks it).
    static func note(_ o: CuratedOption) -> String? {
        guard let k = o.noteKey, Loc.has(k, table: "Dictation") else { return nil }
        return Loc.string(k, table: "Dictation")
    }

    /// Whether a service is one the curated list uses (else: "Not tested by Blurt").
    static func curated(_ s: CloudService) -> Bool { CuratedModels.list.services.contains(s.preset) }

    /// What runs a job on this Mac (its name), nil: nothing yet.
    @MainActor static func localModel(_ job: CloudJob) -> String? {
        switch job {
        case .polish, .translate:
            let d = DictationModels.shared
            guard d.polish?.supported != false, let id = d.polish?.selected ?? Dictation.shared.polishModel,
                  d.polish?.models.first(where: { $0.id == id })?.installed ?? true else { return nil }
            return d.polishName(id)
        case .vision: return "PaddleOCR-VL"
        }
    }

    /// The row's line: where the job's content goes — or, on a model Blurt didn't measure, the one it recommends.
    @MainActor static func line(_ job: CloudJob) -> String {
        if let r = CloudStore.recommendation(job) { return M("models.job.recommend", r.option.name) }
        if let c = CloudStore.cloudModel(job) {
            return ChoiceText.tight(job == .vision ? M("models.job.goes.images", c.service) : M("models.job.goes.text", c.service), c.service)
        }
        return localModel(job) == nil ? M("models.job.none") : M("models.job.local")
    }

    /// A feature page's line: "DeepSeek V4.1 Flash · cloud", "Gemma 4 E2B · this Mac", "No model yet".
    @MainActor static func uses(_ job: CloudJob) -> String {
        if let c = CloudStore.cloudModel(job) { return M("models.uses.cloud", c.model) }
        return localModel(job).map { M("models.uses.local", $0) } ?? M("models.uses.none")
    }

    static func sentences(_ parts: [String]) -> String { parts.joined(separator: Loc.isChinese ? "" : " ") }

    static func checkFailure(_ code: String) -> String {
        switch code {
        case "auth": return M("models.check.auth")
        case "network", "timeout": return M("models.check.network")
        case "rate_limited": return M("models.check.rate")
        case "no_key": return M("models.check.no_key")
        case "no_model": return M("models.check.no_model")
        case "model": return M("models.check.model")
        case "vision": return M("models.check.vision")
        case "empty": return M("models.check.empty")
        default: return M("models.check.other")
        }
    }

    /// A speech-only service's Test (CloudSpeechCheck's sentence key) in the sheet's words: no base URL to check there.
    static func speechFailure(_ key: String) -> String {
        switch key {
        case "speech.cloud.check.auth": return M("models.check.pair_auth")
        case "speech.cloud.check.network": return M("models.check.offline")
        case "speech.cloud.check.quota": return M("models.check.rate")
        case "speech.cloud.check.privacy": return Loc.string(key, table: "Speech")
        case "speech.cloud.check.bad_key": return M("models.token.invalid")
        case "speech.cloud.check.no_key": return M("models.check.no_token")
        default: return M("models.check.error")
        }
    }

    static func keyProblem(_ p: CloudKeyCheck.Problem) -> String {
        switch p {
        case .empty: return M("models.check.no_key")
        case .spaces: return M("models.key.spaces")
        case .characters: return M("models.key.characters")
        }
    }
}

// MARK: - Cloud services

struct CloudServicesSection: View {
    /// open Add Service (the dictation reminder; the job rows' Add Service…)
    static let addRequest = Notification.Name("BlurtCloudServiceAdd")
    @ObservedObject var ui = CloudModelsUI.shared
    @ObservedObject private var agents = AgentSetupAgents.shared
    @State private var adding = ProcessInfo.processInfo.environment["BLURT_TEST_CLOUD_SHEET"] == "add"
    @State private var editing: CloudService?

    var body: some View {
        let setup = CloudStore.setup
        SettingsGroup("speech.services") {
            ForEach(setup.services) { s in serviceLine(s) }
            // each curated service once; the rest are added as a Custom Model in a job's pop-up
            let taken = Set(setup.services.map(\.preset))
            if CloudServiceSheetModel.curated.contains(where: { !taken.contains($0) }) || setup.services.isEmpty {
                addLine(empty: setup.services.isEmpty)
            }
            // what an agent set up (Set Up with Agent…, or one the user allowed), as it happens
            AgentSetupProgressView(look: .settings)
        }
        .sheet(isPresented: $adding) {
            CloudServiceSheet(editing: nil) { adding = false }.buttonStyle(.automatic)
        }
        .sheet(item: $editing) { s in
            CloudServiceSheet(editing: s) { editing = nil }.buttonStyle(.automatic)
        }
        .onReceive(NotificationCenter.default.publisher(for: CloudServicesSection.addRequest)) { _ in adding = true }
        // tests: `dictation settings-scroll cloud_sheet` (what opened cloud polish's sheet before)
        .onReceive(NotificationCenter.default.publisher(for: DictationPane.scrollRequest)) { n in
            if n.object as? String == "cloud_sheet" { adding = true }
        }
        .onAppear {
            CloudStore.refreshStale()
            if let id = ProcessInfo.processInfo.environment["BLURT_TEST_CLOUD_SHEET"], let s = setup.service(id) { editing = s }
        }
    }

    func detail(_ s: CloudService) -> (String, Bool) {
        guard CloudStore.hasKey(s) else { return (M("models.service.no_key"), true) }
        var parts: [String] = []
        if s.info.custom { parts.append(s.host) }
        else if s.info.regional, let r = s.region ?? s.endpoint?.region { parts.append(CloudText.region(r)) }
        if !s.baseURL.isEmpty && !s.info.custom { parts.append(s.host) }
        if s.info.speech { parts.append(M("models.service.speech")) }
        if !CloudText.curated(s) { parts.append(M("models.untested")) }
        return (parts.isEmpty ? M("models.service.connected") : parts.joined(separator: " · "), false)
    }

    func serviceLine(_ s: CloudService) -> some View {
        let (text, warn) = detail(s)
        return SettingsLine(flashID: "speech_service_" + s.id) {
            HStack(alignment: .center, spacing: 14) {
                HStack(alignment: .center, spacing: SettingsMetrics.iconGap) {
                    SettingsIcon("cloud")
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(CloudStore.name(s)).font(.system(size: SettingsMetrics.titleSize))
                                .gridProbe(.iconText, CloudStore.name(s))
                            if s.info.recommended { Badge(M("models.recommended")) }
                        }
                        Text(text).font(.system(size: SettingsMetrics.detailSize))
                            .foregroundStyle(warn ? AnyShapeStyle(Color.brandAttnInk) : AnyShapeStyle(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(M("models.service.edit")) { editing = s }
                    .buttonStyle(SettingsOutlinedButtonStyle())
                    .gridProbe(.trailing, CloudStore.name(s))
            }
        }
    }

    func addLine(empty: Bool) -> some View {
        SettingsLine(flashID: "speech_service_add") {
            HStack(alignment: .center, spacing: 14) {
                HStack(alignment: .center, spacing: SettingsMetrics.iconGap) {
                    SettingsIcon("plus.circle")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(M("models.services.add.title")).font(.system(size: SettingsMetrics.titleSize))
                            .gridProbe(.iconText, "add service")
                        if empty {
                            Text(sentencesOf([M("models.services.empty"), M("models.price.deepseek")]))
                                .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !agents.list.isEmpty {
                            Text(M("models.agent.note")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    // the user's own agent does it (agent-setup.md §4); hidden while none can run a session
                    AgentSetupButton(look: .settings)
                    if empty {
                        Button(M("models.services.add")) { adding = true }.buttonStyle(SettingsPrimaryButtonStyle())
                    } else {
                        Button(M("models.services.add")) { adding = true }.buttonStyle(SettingsOutlinedButtonStyle())
                    }
                }
                .gridProbe(.trailing, "add service")
            }
        }
    }

    private func sentencesOf(_ p: [String]) -> String { CloudText.sentences(p) }
}

// MARK: - the sheet

@MainActor
final class CloudServiceSheetModel: ObservableObject {
    enum Check: Equatable { case idle, running, ok(Int), failed(String) }

    let editing: CloudService?
    @Published var preset: String
    @Published var region: CloudRegion
    @Published var baseURL: String
    @Published var name: String
    @Published var key = ""
    /// Volcengine Speech: the App ID typed (or the saved one, when editing); `key` is then its Access Token
    @Published var appID = ""
    @Published var stored = false
    @Published var check: Check = .idle
    /// Model Studio / OpenAI: the speech check's line
    @Published var speech: String?
    @Published var connecting = false
    /// a pasted key another service's (by its start): that service's name, for the line pointing to Custom Model
    @Published var otherService: String?

    /// The services Add Service offers: the curated list's (DeepSeek, Model Studio, Volcengine Speech), in its order —
    /// Volcengine Speech only where it can serve (VolcengineSpeech.offered).
    static var curated: [String] {
        let l = CuratedModels.list.services.filter { $0 != VolcengineSpeech.preset || volcengineOffered }
        return l.isEmpty ? ["dashscope", "deepseek"] : l
    }

    static var volcengineOffered: Bool {
        VolcengineSpeech.offered(regionCode: Locale.current.region?.identifier, languages: Locale.preferredLanguages)
    }

    init(editing: CloudService?, preset: String? = nil) {
        self.editing = editing
        let taken = Set(CloudStore.setup.services.map(\.preset))
        // DeepSeek first when both are free (the founder: it leads the list), else the first one left
        let order = Self.curated.sorted { ($0 == "deepseek" ? 0 : 1) < ($1 == "deepseek" ? 0 : 1) }
        let first = preset ?? order.first { !taken.contains($0) } ?? order.first ?? "deepseek"
        let p = editing?.preset ?? first
        self.preset = p
        region = editing?.region ?? editing?.endpoint?.region ?? CloudRegion.forSystem(Locale.current.region?.identifier)
        baseURL = editing.map { $0.effectiveBaseURL } ?? ""
        name = editing?.name ?? ""
        if let e = editing {
            Task.detached(priority: .userInitiated) {
                let k = CloudStore.key(e)
                // the App ID is no secret: shown again, so a new token can go with it
                let id = e.info.pairCredential ? VolcengineSpeech.split(k)?.appID : nil
                await MainActor.run {
                    self.stored = k != nil
                    if let id, self.appID.isEmpty { self.appID = id }
                }
            }
        }
        if editing == nil { baseURL = info.endpoint(region)?.baseURL ?? "" }
    }

    var info: CloudPreset { CloudPreset.preset(preset) ?? CloudPreset.all.last! }

    /// Presets offered when adding: each curated service once (DeepSeek first, as everywhere); any other is a Custom
    /// Model's.
    var presets: [CloudPreset] {
        let taken = Set(CloudStore.setup.services.map(\.preset))
        let offered = Set(Self.curated)
        return CloudPreset.all.filter { (offered.contains($0.id) && !taken.contains($0.id)) || $0.id == editing?.preset || $0.id == preset }
    }

    func pick(_ p: String) {
        guard p != preset else { return }
        preset = p
        baseURL = info.endpoint(region)?.baseURL ?? ""
        check = .idle; speech = nil
    }

    func appIDChanged(_ s: String) {
        appID = s
        check = .idle
    }

    func pickRegion(_ r: CloudRegion) {
        // the address follows the region unless the user typed their own
        let wasDefault = baseURL.isEmpty || info.endpoints.contains { $0.baseURL == baseURL }
        region = r
        if wasDefault { baseURL = info.endpoint(r)?.baseURL ?? "" }
        check = .idle; speech = nil
    }

    /// A pasted key: its service when its start says so.
    func keyChanged(_ k: String) {
        key = k
        check = .idle; speech = nil
        otherService = nil
        guard editing == nil, let p = CloudPreset.detect(key: k) else { return }
        if presets.contains(where: { $0.id == p }) { pick(p) } else { otherService = CloudStore.presetName(p) }
    }

    /// The service as it would be saved.
    var service: CloudService {
        let id = editing?.id ?? CloudService.newID(preset: preset, taken: Set(CloudStore.setup.services.map(\.id)))
        let b = baseURL.trimmingCharacters(in: .whitespaces)
        let own = b == info.endpoint(info.regional ? region : nil)?.baseURL ? "" : b
        return CloudService(id: id, preset: preset, region: info.regional ? region : nil, baseURL: own,
                            name: info.custom ? name.trimmingCharacters(in: .whitespaces) : "")
    }

    var canSave: Bool {
        if info.pairCredential {
            return !appID.trimmingCharacters(in: .whitespaces).isEmpty && (stored || !key.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        return !service.effectiveBaseURL.isEmpty && (stored || !key.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Test can run: a model to ask, or (a speech-only service) the clip.
    var canTest: Bool { canSave && (info.speechOnly || testModel != nil) }

    /// The model Test asks: the service's curated model (polish's first), else one a job uses on it; nil: nothing to ask.
    var testModel: String? {
        let svc = service
        for job in CloudJob.allCases {
            if let o = CuratedModels.list.options(job).first(where: { $0.runs(on: svc) }) { return o.model }
        }
        for (_, c) in CloudStore.setup.jobs { if case .cloud(let id, let m) = c, id == svc.id, !m.isEmpty { return m } }
        return nil
    }

    /// The key to use: typed, else saved. nil + the sentence when there is none or it can't be a key. Volcengine
    /// Speech: the App ID with the token typed, else with the saved one, as the pair's one item.
    func keyToUse() async -> (String?, String?) {
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if info.pairCredential {
            let id = appID.trimmingCharacters(in: .whitespacesAndNewlines)
            var token = typed
            if token.isEmpty, let e = editing {
                token = await Task.detached { VolcengineSpeech.split(CloudStore.key(e))?.token }.value ?? ""
            }
            guard !token.isEmpty else { return (nil, M(VolcengineSpeech.validAppID(id) ? "models.check.no_token" : "models.check.app_id")) }
            switch VolcengineSpeech.problem(appID: id, token: token) {
            case .appID?: return (nil, M("models.check.app_id"))
            case .token?: return (nil, M("models.token.invalid"))
            case nil: return (VolcengineSpeech.credential(appID: id, token: token), nil)
            }
        }
        if !typed.isEmpty {
            if let p = CloudKeyCheck.problem(typed) { return (nil, CloudText.keyProblem(p)) }
            return (typed, nil)
        }
        guard let e = editing else { return (nil, CloudText.checkFailure("no_key")) }
        let saved = await Task.detached { CloudStore.key(e) }.value
        guard let k = saved else { return (nil, CloudText.checkFailure("no_key")) }
        if let p = CloudKeyCheck.problem(k) { return (nil, CloudText.keyProblem(p)) }
        return (k, nil)
    }

    /// Test: one tiny request on the service's curated model (the key, the address, the protocol); Model Studio and
    /// OpenAI also hear a short clip (CloudSpeech.check). true when it works.
    @discardableResult
    func test() async -> Bool {
        check = .running; speech = nil
        let (k, problem) = await keyToUse()
        guard let key = k else { check = .failed(problem ?? CloudText.checkFailure("no_key")); return false }
        if info.speechOnly { return await testSpeechOnly(key) }
        guard let model = testModel else { check = .failed(CloudText.checkFailure("no_model")); return false }
        let svc = service
        emit(["event": "cloud_service", "action": "test", "preset": svc.preset])
        let body = try? JSONSerialization.data(withJSONObject: ["cloud": CloudStore.payload(svc, model: model, key: key)])
        let result: Check = await withCheckedContinuation { c in
            Scripts.call("polish_cloud.py", ["check"], stdin: body, timeout: 30) { r in
                switch r {
                case .success(let o): c.resume(returning: .ok(o["ms"] as? Int ?? 0))
                case .failure(let f): c.resume(returning: .failed(CloudText.checkFailure(f.code)))
                }
            }
        }
        check = result
        emit(["event": "cloud_service", "action": "tested", "preset": svc.preset, "ok": { if case .ok = result { return true }; return false }()])
        if svc.info.speech { checkSpeech(key) }
        if case .ok = result { return true }
        return false
    }

    /// A speech-only service (Volcengine Speech): Test is the short clip itself.
    private func testSpeechOnly(_ credential: String) async -> Bool {
        guard let pair = VolcengineSpeech.split(credential) else { check = .failed(M("models.check.app_id")); return false }
        emit(["event": "cloud_service", "action": "test", "preset": preset])
        let r: CloudSpeechCheck.Result = await withCheckedContinuation { c in
            CloudSpeech.checkVolcengine(appID: pair.appID, token: pair.token) { c.resume(returning: $0) }
        }
        let ok: Bool
        switch r {
        case .ok(let ms, _): check = .ok(ms); ok = true
        case .failed(let k): check = .failed(CloudText.speechFailure(k)); ok = false
        }
        emit(["event": "cloud_service", "action": "tested", "preset": preset, "ok": ok])
        return ok
    }

    private func checkSpeech(_ key: String) {
        let dashscope = preset == "dashscope"
        let id = dashscope ? CloudSpeech.dashScopeModel : CloudSpeech.openAIModel
        var setup = CloudSpeech.setup
        if !dashscope { setup = CloudSpeech.Setup(service: .openai, baseURL: "", model: setup.service == .openai ? setup.model : "") }
        CloudSpeech.check(modelID: id, typedKey: key, setup: setup, dsModel: CloudSpeech.dashScopeChoice) { [weak self] r in
            switch r {
            case .ok(let ms, _): self?.speech = M("models.check.speech_ok", Loc.number(ms))
            case .failed(let k): self?.speech = M("models.check.speech_failed", Loc.string(k, table: "Speech"))
            }
        }
    }

    /// Save: the key (when typed) and the service. A new service is tested first and saved when the key works.
    func save(then done: @escaping () -> Void) {
        Task {
            var typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if info.pairCredential {
                // the pair as one item: saved when the token or the App ID changed, tested first like a new service
                let (k, problem) = await keyToUse()
                guard let pair = k else { check = .failed(problem ?? M("models.check.no_token")); return }
                let e = editing
                let saved = await Task.detached { e.flatMap { CloudStore.key($0) } }.value
                typed = pair == saved ? "" : pair
                if !typed.isEmpty || editing == nil {
                    connecting = true
                    let ok = await test()
                    connecting = false
                    guard ok else { return }
                }
            } else {
                if !typed.isEmpty, let p = CloudKeyCheck.problem(typed) { check = .failed(CloudText.keyProblem(p)); return }
                if editing == nil {
                    connecting = true
                    let ok = await test()
                    connecting = false
                    guard ok else { return }
                }
            }
            let svc = service
            let speechBefore = CloudSpeech.environment()
            CloudStore.connect(svc, key: typed.isEmpty ? nil : typed)
            key = ""
            Self.afterChange(speechBefore: speechBefore)
            done()
        }
    }

    func remove(then done: () -> Void) {
        guard let e = editing else { return done() }
        let speechBefore = CloudSpeech.environment()
        CloudStore.remove(e)
        Self.afterChange(speechBefore: speechBefore)
        done()
    }

    /// The jobs follow: polish and translate on their next request, ⌥C's server, the speech jobs' list.
    static func afterChange(speechBefore: [String: String]) {
        Dictation.shared.apply()
        ScreenTextRefine.modeChanged()
        if CloudSpeech.environment() != speechBefore {
            // a speech job already on this service started with the old key: the next take starts a new server
            _ = VoiceInput.endUnresponsiveServer(why: "cloud_key")
            Task { await SpeechModel.shared.load() }
            Dictation.shared.refreshSpeechModels()
        }
    }
}

struct CloudServiceSheet: View {
    @StateObject var m: CloudServiceSheetModel
    /// the setup assistant: the key first, its service found from it
    var keyFirst = false
    var close: () -> Void
    @State private var confirmRemove = false

    init(editing: CloudService?, preset: String? = nil, keyFirst: Bool = false, close: @escaping () -> Void) {
        _m = StateObject(wrappedValue: CloudServiceSheetModel(editing: editing, preset: preset))
        self.keyFirst = keyFirst
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(m.editing.map(CloudStore.name) ?? M(keyFirst ? "models.sheet.paste_title" : "models.sheet.add_title"))
                .font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(M(m.info.pairCredential ? "models.sheet.note.pair" : "models.sheet.note")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            form.padding(.top, 16)
            footer.padding(.top, 18)
        }
        .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 18)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .alert(M("models.remove.title", m.editing.map(CloudStore.name) ?? ""), isPresented: $confirmRemove) {
            Button(M("models.remove.confirm"), role: .destructive) { m.remove(then: close) }
            Button(M("models.cancel"), role: .cancel) {}
        } message: { Text(M("models.remove.message")) }
    }

    var form: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            if keyFirst { keyRow }
            if m.editing == nil {
                GridRow {
                    label(M("models.sheet.service"))
                    VStack(alignment: .leading, spacing: 5) {
                        ChoicePopup(label: M("models.sheet.service"),
                                    choices: m.presets.map { ($0.id, $0.recommended ? M("models.preset.recommended", CloudStore.presetName($0.id)) : CloudStore.presetName($0.id)) },
                                    selection: Binding(get: { m.preset }, set: { m.pick($0) }), width: 260,
                                    dividers: Set(m.presets.firstIndex(where: \.custom).map { [$0] } ?? []))
                        if m.info.recommended {
                            detail(M("models.price.deepseek"))
                        }
                    }
                }
            }
            if m.info.regional {
                GridRow {
                    label(M("models.sheet.region"))
                    ChoicePopup(label: M("models.sheet.region"), choices: CloudRegion.allCases.map { ($0, CloudText.region($0)) },
                                selection: Binding(get: { m.region }, set: { m.pickRegion($0) }), width: 260)
                }
            }
            if m.info.custom {
                GridRow {
                    label(M("models.sheet.name"))
                    TextField(M("models.sheet.name.placeholder"), text: $m.name).textFieldStyle(.roundedBorder)
                }
            }
            if (!keyFirst || m.info.custom) && !m.info.speechOnly {
                GridRow {
                    label(M("models.sheet.base_url"))
                    TextField("https://…/v1", text: Binding(get: { m.baseURL }, set: { m.baseURL = $0; m.check = .idle }))
                        .textFieldStyle(.roundedBorder)
                }
            }
            if !keyFirst { keyRow }
        }
    }

    @ViewBuilder var keyRow: some View {
        if m.info.pairCredential { pairRows } else { apiKeyRow }
    }

    /// Volcengine Speech: App ID, then Access Token (Keychain, never shown back), then where to get them.
    @ViewBuilder var pairRows: some View {
        GridRow {
            label(M("models.sheet.app_id"))
            TextField(M("models.sheet.app_id.placeholder"), text: Binding(get: { m.appID }, set: { m.appIDChanged($0) }))
                .textFieldStyle(.roundedBorder)
        }
        GridRow {
            label(M("models.sheet.token"))
            VStack(alignment: .leading, spacing: 5) {
                SecureField(m.stored ? M("models.sheet.token.stored") : M("models.sheet.token.placeholder"),
                            text: Binding(get: { m.key }, set: { m.key = $0; m.check = .idle }))
                    .textFieldStyle(.roundedBorder)
                if let page = m.info.endpoint(nil)?.keyPage, let u = URL(string: page) {
                    TextLinkButton(M("models.sheet.key.get")) { NSWorkspace.shared.open(u) }
                        .font(.system(size: SettingsMetrics.detailSize))
                        .padding(.leading, SettingsMetrics.fieldTextInset)
                }
            }
        }
    }

    @ViewBuilder var apiKeyRow: some View {
        GridRow {
            label(M("models.sheet.key"))
            VStack(alignment: .leading, spacing: 5) {
                SecureField(m.stored ? M("models.sheet.key.stored") : M("models.sheet.key.placeholder"),
                            text: Binding(get: { m.key }, set: { m.keyChanged($0) }))
                    .textFieldStyle(.roundedBorder)
                if let other = m.otherService {
                    detail(M("models.key.custom", other))
                }
                if let page = m.info.endpoint(m.region)?.keyPage, let u = URL(string: page) {
                    TextLinkButton(M("models.sheet.key.get")) { NSWorkspace.shared.open(u) }
                        .font(.system(size: SettingsMetrics.detailSize))
                        .padding(.leading, SettingsMetrics.fieldTextInset)
                }
            }
        }
    }

    func label(_ s: String) -> some View { Text(s).foregroundStyle(.secondary).fixedSize().gridColumnAlignment(.trailing) }

    func detail(_ s: String) -> some View {
        Text(s).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).padding(.leading, SettingsMetrics.fieldTextInset)
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Button(M("models.sheet.test")) { Task { await m.test() } }
                    .disabled(m.check == .running || !m.canTest)
                result
                Spacer()
                if m.editing != nil {
                    Button(M("models.remove.button")) { confirmRemove = true }
                }
                Button(M("models.cancel"), action: close).keyboardShortcut(.cancelAction)
                Button(M(m.editing == nil ? "models.sheet.connect" : "models.sheet.done")) { m.save(then: close) }
                    .keyboardShortcut(.defaultAction).disabled(!m.canSave || m.connecting)
            }
            if let s = m.speech {
                Text(s).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder var result: some View {
        switch m.check {
        case .idle: EmptyView()
        case .running: BrandSpinnerView(size: 12)
        case .ok(let ms):
            Text(M("models.check.ok", Loc.number(ms))).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandOk)
        case .failed(let s):
            Text(s).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandErr).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - the job rows (Polish, Translate, Copy Text from Screen)

extension CloudJob {
    /// its row on Settings → Models
    var rowID: String {
        switch self {
        case .polish: return "speech.polish"
        case .translate: return "speech.translate"
        case .vision: return "speech.vision"
        }
    }
    var symbol: String {
        switch self {
        case .polish: return "wand.and.stars"
        case .translate: return "character.bubble"
        case .vision: return "text.viewfinder"
        }
    }
}

/// Re-draws its content when CloudStore changes: a row whose line says where a job goes.
struct CloudObserving<Content: View>: View {
    @ObservedObject var ui = CloudModelsUI.shared
    @ObservedObject var d = DictationModels.shared
    @ViewBuilder var content: () -> Content
    var body: some View {
        _ = ui.tick
        return content()
    }
}

/// A job row's control (Settings → Models): Switch while the job is on a model Blurt didn't measure, the pop-up, and the
/// sheets they open.
struct JobModelControl: View {
    let job: CloudJob
    /// the model library (Get More Models…)
    var library: () -> Void
    @ObservedObject var ui = CloudModelsUI.shared
    @ObservedObject var d = DictationModels.shared
    /// a curated option whose service has no key yet: Add Service for it, then the job uses it
    @State private var adding: Adding?
    @State private var custom = false

    struct Adding: Identifiable { var preset: String; var id: String { preset } }

    private static let custom = "custom", more = "more"

    var body: some View {
        _ = ui.tick
        return HStack(spacing: 8) {
            if let r = CloudStore.recommendation(job) {
                Button(M("models.job.switch")) { use(r.option, on: r.service) }
                    .help(M("models.job.recommend", r.option.name))
            }
            if job != .vision, d.polish == nil, CloudStore.setup.services.isEmpty {
                BrandSpinnerView(size: 12)
            } else {
                ModelMenuPopup(label: SettingsCatalog.entry(job.rowID).map(SettingsCatalog.title) ?? "", items: items,
                               current: current) { pick($0) }
            }
        }
        .sheet(item: $adding) { a in
            // a service of it kept without a key: that one's sheet, to paste the key
            CloudServiceSheet(editing: CloudStore.setup.services.first { $0.preset == a.preset }, preset: a.preset) {
                adding = nil
                // the key went in: the job takes the service's curated model
                if let s = CloudStore.connected.first(where: { $0.preset == a.preset }) { set(.cloud(service: s.id, model: "")) }
            }
            .buttonStyle(.automatic)
        }
        .sheet(isPresented: $custom) { CustomModelSheet(job: job) { custom = false }.buttonStyle(.automatic) }
    }

    /// The pop-up's value now: where the job runs (Auto shows the option it took).
    var current: String {
        switch CloudStore.route(job) {
        case .local: return "local:" + (job == .polish ? d.polish?.selected ?? "" : "")
        case .cloud(let s, let m): return "cloud:\(s)\t\(m)"
        }
    }

    var items: [ModelMenuPopup.Item] {
        var out: [ModelMenuPopup.Item] = []
        // this Mac
        var local: [ModelMenuPopup.Item] = []
        switch job {
        case .polish:
            if d.polish?.supported == true {
                local = (d.polish?.models ?? []).filter(\.installed).map { .init(value: "local:" + $0.id, title: $0.name) }
            }
        case .translate:
            if let n = CloudText.localModel(.translate) { local = [.init(value: "local:", title: n)] }
        case .vision:
            local = [.init(value: "local:", title: "PaddleOCR-VL")]
        }
        if !local.isEmpty { out.append(.header(M("models.job.this_mac"))); out += local }
        // the curated models: on a connected service, or "No API key" (picking it adds the key)
        let connected = CloudStore.connected
        var cloud: [ModelMenuPopup.Item] = []
        for o in CuratedModels.list.options(job) {
            let service = CloudStore.presetName(o.service)
            if let s = connected.first(where: o.runs(on:)) {
                let note = [service, CloudText.note(o)].compactMap { $0 }.joined(separator: " · ")
                cloud.append(.init(value: "cloud:\(s.id)\t\(o.model)", title: o.name, note: note))
            } else if !connected.contains(where: { $0.preset == o.service }) {
                cloud.append(.init(value: "add:\(o.service)", title: o.name, note: service + " · " + M("models.service.no_key")))
            }
        }
        if !cloud.isEmpty { out.append(.header(M("models.section.services"))); out += cloud }
        // Advanced: a model kept from before (or added as a Custom Model), and Custom Model…
        out.append(.header(M("models.job.advanced")))
        if case .cloud(let id, let m) = CloudStore.route(job), let s = CloudStore.setup.service(id),
           CuratedModels.list.option(job, on: s, model: m) == nil {
            out.append(.init(value: current, title: m, note: CloudStore.name(s) + " · " + M("models.untested")))
        }
        out.append(.init(value: Self.custom, title: M("models.job.custom")))
        if job == .polish && d.polish?.supported == true {
            out.append(.divider)
            out.append(.init(value: Self.more, title: M("models.job.more")))
        }
        return out
    }

    func pick(_ v: String) {
        switch v {
        case Self.custom: custom = true
        case Self.more: library()
        default:
            if v.hasPrefix("local:") {
                set(.local)
                let id = String(v.dropFirst("local:".count))
                if job == .polish, let x = d.polish?.models.first(where: { $0.id == id }) { d.choose(x) }
            } else if v.hasPrefix("add:") {
                adding = Adding(preset: String(v.dropFirst("add:".count)))
            } else if v.hasPrefix("cloud:") {
                let parts = v.dropFirst("cloud:".count).split(separator: "\t", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return }
                // a curated model is kept as the service alone: a better one in the list reaches the user
                let svc = CloudStore.setup.service(parts[0])
                let curated = svc.flatMap { CuratedModels.list.option(job, on: $0, model: parts[1]) } != nil
                set(.cloud(service: parts[0], model: curated ? "" : parts[1]))
            }
        }
    }

    /// Switch: the recommended model on its connected service, or its key first.
    func use(_ o: CuratedOption, on s: CloudService?) {
        if let s = s { set(.cloud(service: s.id, model: "")) } else { adding = Adding(preset: o.service) }
        emit(["event": "cloud_job", "action": "switch", "job": job.rawValue, "to": o.service + ":" + o.model])
    }

    func set(_ c: CloudJobChoice) {
        CloudStore.setChoice(c, for: job)
        Dictation.shared.apply()
        if job == .vision { ScreenTextRefine.modeChanged() }
        ui.bump()
    }
}

// MARK: - Custom Model

/// Advanced → Custom Model…: any service's model for one job, by its id — a connected service (its key), or a new one
/// (its address and key). Save runs the job itself first (polish_cloud.py check with the job: a sentence, or a small
/// picture with text) and saves nothing when it fails, with one short reason.
@MainActor
final class CustomModelModel: ObservableObject {
    enum Check: Equatable { case idle, running, failed(String) }

    let job: CloudJob
    /// "svc:<id>" (a connected service) or "new:<preset>"
    @Published var choice: String
    @Published var region: CloudRegion = CloudRegion.forSystem(Locale.current.region?.identifier)
    @Published var baseURL = ""
    @Published var name = ""
    @Published var key = ""
    @Published var model = ""
    @Published var check: Check = .idle

    init(job: CloudJob) {
        self.job = job
        // the service the job is on, else the first connected one, else the first preset
        let on: String? = { if case .cloud(let id, _) = CloudStore.route(job) { return id }; return nil }()
        let connected = Self.textServices
        if let id = on ?? connected.first?.id { choice = "svc:" + id }
        else { choice = "new:" + (CustomModelModel.newPresets.first?.id ?? "custom-openai") }
        if case .cloud(let id, let m) = CloudStore.route(job), let s = CloudStore.setup.service(id),
           CuratedModels.list.option(job, on: s, model: m) == nil { model = m }
        fillAddress()
    }

    /// Presets with no service yet: every one the app knows, the user's own (OpenAI- / Anthropic-compatible) last — not
    /// a speech-only one (Volcengine Speech has no text models).
    static var newPresets: [CloudPreset] {
        let taken = Set(CloudStore.setup.services.map(\.preset))
        return CloudPreset.all.filter { ($0.custom || !taken.contains($0.id)) && !$0.speechOnly }
    }

    /// The connected services a text job can run on (a speech-only one can't).
    static var textServices: [CloudService] { CloudStore.connected.filter { !$0.info.speechOnly } }

    /// The connected services (their keys), then a new one of any preset not added yet.
    var choices: [(String, String)] {
        Self.textServices.map { ("svc:" + $0.id, CloudStore.name($0)) }
            + Self.newPresets.map { ("new:" + $0.id, CloudStore.presetName($0.id)) }
    }
    var divider: Set<Int> { Self.textServices.isEmpty ? [] : [Self.textServices.count] }

    var existing: CloudService? {
        choice.hasPrefix("svc:") ? CloudStore.setup.service(String(choice.dropFirst(4))) : nil
    }
    var preset: CloudPreset {
        if let e = existing { return e.info }
        return CloudPreset.preset(String(choice.dropFirst(4))) ?? CloudPreset.all.last!
    }

    func pick(_ c: String) {
        guard c != choice else { return }
        choice = c
        fillAddress()
        check = .idle
    }

    func pickRegion(_ r: CloudRegion) {
        let wasDefault = baseURL.isEmpty || preset.endpoints.contains { $0.baseURL == baseURL }
        region = r
        if wasDefault { fillAddress() }
        check = .idle
    }

    private func fillAddress() { baseURL = existing?.effectiveBaseURL ?? preset.endpoint(preset.regional ? region : nil)?.baseURL ?? "" }

    /// The service as it would be saved: the connected one, or a new one of the preset.
    var service: CloudService {
        if let e = existing { return e }
        let p = preset
        let b = baseURL.trimmingCharacters(in: .whitespaces)
        let own = b == p.endpoint(p.regional ? region : nil)?.baseURL ? "" : b
        return CloudService(id: CloudService.newID(preset: p.id, taken: Set(CloudStore.setup.services.map(\.id))), preset: p.id,
                            region: p.regional ? region : nil, baseURL: own, name: p.custom ? name.trimmingCharacters(in: .whitespaces) : "")
    }

    var canSave: Bool {
        let m = model.trimmingCharacters(in: .whitespaces)
        return check != .running && !m.isEmpty && (existing != nil || !baseURL.isEmpty && !key.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Save: what can be checked here first (address, model id, key), then the job itself; saved only when it passes.
    func save(then done: @escaping () -> Void) {
        let svc = service
        let m = model.trimmingCharacters(in: .whitespaces)
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = CloudCustom.problem(baseURL: svc.effectiveBaseURL, model: m, typedKey: typed, keySaved: existing != nil) {
            switch p {
            case .address: check = .failed(M("models.check.address"))
            case .model: check = .failed(M("models.check.model_id"))
            case .key(let k): check = .failed(CloudText.keyProblem(k))
            }
            return
        }
        check = .running
        Task {
            let key: String? = typed.isEmpty ? await Task.detached { CloudStore.key(svc) }.value : typed
            guard let k = key else { check = .failed(CloudText.checkFailure("no_key")); return }
            emit(["event": "cloud_custom", "action": "test", "job": job.rawValue, "preset": svc.preset])
            let body = try? JSONSerialization.data(withJSONObject: ["cloud": CloudStore.payload(svc, model: m, key: k), "job": job.rawValue])
            let answer: [String: Any] = await withCheckedContinuation { c in
                Scripts.call("polish_cloud.py", ["check"], stdin: body, timeout: 45) { r in
                    switch r {
                    case .success(let o): c.resume(returning: o)
                    case .failure(let f): c.resume(returning: ["ok": false, "code": f.code])
                    }
                }
            }
            let outcome = CloudCustom.outcome(answer)
            emit(["event": "cloud_custom", "action": "tested", "job": job.rawValue, "preset": svc.preset, "ok": outcome == .save])
            guard outcome == .save else {
                if case .refuse(let code) = outcome { check = .failed(CloudText.checkFailure(code)) }
                return
            }
            let speechBefore = CloudSpeech.environment()
            if existing == nil || !typed.isEmpty { CloudStore.connect(svc, key: typed.isEmpty ? nil : typed) }
            CloudStore.setChoice(.cloud(service: svc.id, model: m), for: job)
            CloudServiceSheetModel.afterChange(speechBefore: speechBefore)
            CloudModelsUI.shared.bump()
            check = .idle
            done()
        }
    }
}

struct CustomModelSheet: View {
    @StateObject var m: CustomModelModel
    var close: () -> Void

    init(job: CloudJob, close: @escaping () -> Void) {
        _m = StateObject(wrappedValue: CustomModelModel(job: job))
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(M("models.custom.title")).font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(M("models.custom.note")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            form.padding(.top, 16)
            footer.padding(.top, 18)
        }
        .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 18)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }

    var form: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                label(M("models.sheet.service"))
                ChoicePopup(label: M("models.sheet.service"), choices: m.choices,
                            selection: Binding(get: { m.choice }, set: { m.pick($0) }), width: 260, dividers: m.divider)
            }
            if m.existing == nil {
                if m.preset.regional {
                    GridRow {
                        label(M("models.sheet.region"))
                        ChoicePopup(label: M("models.sheet.region"), choices: CloudRegion.allCases.map { ($0, CloudText.region($0)) },
                                    selection: Binding(get: { m.region }, set: { m.pickRegion($0) }), width: 260)
                    }
                }
                if m.preset.custom {
                    GridRow {
                        label(M("models.sheet.name"))
                        TextField(M("models.sheet.name.placeholder"), text: $m.name).textFieldStyle(.roundedBorder)
                    }
                }
                GridRow {
                    label(M("models.sheet.base_url"))
                    TextField("https://…/v1", text: Binding(get: { m.baseURL }, set: { m.baseURL = $0; m.check = .idle }))
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    label(M("models.sheet.key"))
                    VStack(alignment: .leading, spacing: 5) {
                        SecureField(M("models.sheet.key.placeholder"), text: Binding(get: { m.key }, set: { m.key = $0; m.check = .idle }))
                            .textFieldStyle(.roundedBorder)
                        if let page = m.preset.endpoint(m.preset.regional ? m.region : nil)?.keyPage, let u = URL(string: page) {
                            TextLinkButton(M("models.sheet.key.get")) { NSWorkspace.shared.open(u) }
                                .font(.system(size: SettingsMetrics.detailSize))
                                .padding(.leading, SettingsMetrics.fieldTextInset)
                        }
                    }
                }
            }
            GridRow {
                label(M("models.other.placeholder"))
                TextField(M("models.other.placeholder"), text: Binding(get: { m.model }, set: { m.model = $0; m.check = .idle }))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    func label(_ s: String) -> some View { Text(s).foregroundStyle(.secondary).fixedSize().gridColumnAlignment(.trailing) }

    var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            switch m.check {
            case .idle: EmptyView()
            case .running: BrandSpinnerView(size: 12)
            case .failed(let s):
                Text(s).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandErr).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(M("models.cancel"), action: close).keyboardShortcut(.cancelAction)
            Button(M("models.custom.save")) { m.save(then: close) }
                .keyboardShortcut(.defaultAction).disabled(!m.canSave)
        }
    }
}

/// A feature page's Change… for a job (its row: "Uses DeepSeek V4.1 Flash · cloud", CloudText.uses): opens Settings → Models
/// at the job's row.
struct JobChangeButton: View {
    let job: CloudJob
    var body: some View {
        Button(M("models.uses.change")) { AppEnvironment.settings?.show(pane: "speech/\(job.rowID)") }
    }
}

// MARK: - a pop-up with headings

/// The jobs' pop-up: values with section headings (This Mac, each service) and a muted note after a title (the
/// measured line). A pull-down whose title is the chosen item's plain title, so a note never shows in the button.
struct ModelMenuPopup: NSViewRepresentable {
    struct Item {
        var value: String?
        var title: String
        var note: String?
        var isHeader = false
        var isDivider = false
        init(value: String, title: String, note: String? = nil) { self.value = value; self.title = title; self.note = note }
        private init(header: String) { value = nil; title = header; isHeader = true }
        private init(divider: Bool) { value = nil; title = ""; isDivider = true }
        static func header(_ t: String) -> Item { Item(header: t) }
        static var divider: Item { Item(divider: true) }
    }

    var label: String
    var items: [Item]
    var current: String
    var width: CGFloat = SettingsMetrics.controlWidth
    var pick: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let b = OutlinedPopUpButton(frame: .zero, pullsDown: true)
        let cell = DownChevronPopUpCell(textCell: "", pullsDown: true)
        cell.arrowPosition = .noArrow
        b.cell = cell
        b.isBordered = false
        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) ?? NSImage())
        chevron.contentTintColor = .secondaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        b.addSubview(chevron)
        NSLayoutConstraint.activate([chevron.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -DownChevronPopUpCell.inset),
                                     chevron.centerYAnchor.constraint(equalTo: b.centerYAnchor)])
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return b
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView b: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: width, height: OutlinedPopUpButton.height)
    }

    func updateNSView(_ b: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let menu = NSMenu()
        menu.autoenablesItems = false
        // the pull-down's own title: the chosen item, plainly
        let chosen = items.first { $0.value == current }
        let title = chosen.map { $0.title } ?? current.split(separator: "\t").last.map(String.init) ?? ""
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        for (i, it) in items.enumerated() {
            if it.isDivider { menu.addItem(.separator()); continue }
            let m = NSMenuItem(title: it.title, action: #selector(Coordinator.picked(_:)), keyEquivalent: "")
            m.target = context.coordinator
            m.tag = i
            if it.isHeader {
                m.isEnabled = false
                m.attributedTitle = NSAttributedString(string: it.title, attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor])
            } else {
                m.state = it.value == current ? .on : .off
                m.indentationLevel = 0
                if let n = it.note {
                    let a = NSMutableAttributedString(string: it.title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
                    a.append(NSAttributedString(string: "   " + n, attributes: [
                        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]))
                    m.attributedTitle = a
                }
            }
            menu.addItem(m)
        }
        b.menu = menu
        b.isEnabled = context.environment.isEnabled
        b.setAccessibilityLabel(label)
        b.setAccessibilityValueDescription(title)
    }

    final class Coordinator: NSObject {
        var parent: ModelMenuPopup?
        @MainActor @objc func picked(_ m: NSMenuItem) {
            guard let p = parent, p.items.indices.contains(m.tag), let v = p.items[m.tag].value, v != p.current else { return }
            DispatchQueue.main.async { p.pick(v) }
        }
    }
}
