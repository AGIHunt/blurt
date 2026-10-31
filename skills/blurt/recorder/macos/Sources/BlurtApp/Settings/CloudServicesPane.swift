// Settings → Models: Cloud services and the text jobs' rows (2026-10-31; docs/design/system.md §3.4). CloudStore holds the
// data, BlurtCore's CloudServices the rules.
//
//   Cloud services   one line per connected service — its name (DeepSeek marked Recommended), where it is (China /
//                    International, a custom service's host), whether its key does speech too — and Edit…; then
//                    Add Service…. Empty: one line on what a key is for, and DeepSeek's price, the one shown anywhere.
//   the sheet        Service (the presets, DeepSeek first; Custom for any OpenAI- or Anthropic-compatible API), Region
//                    where a service has a China and an international address (from the system region), the base URL
//                    filled in (editable), the API key (Keychain; never shown back; a key with characters no key has
//                    is refused), Test: the model list, then one tiny request → "OK · 320 ms" or one plain sentence
//                    (Model Studio and OpenAI: the speech check too, CloudSpeech.check). Connect tests first.
//   the job rows     Polish, Translate, Copy Text from Screen: Auto / this Mac / a connected service's models (its live
//                    list, the default first, newest first; measured ids carry their note) / Other Model… / Add
//                    Service…; the line under says where the content goes.
//   feature pages    one row per job they use: "Uses deepseek-flash · cloud" (CloudText.uses) with Change…
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

    /// "deepseek-flash" with its measured note when it has one.
    static func note(_ job: CloudJob, _ s: CloudService, _ model: String) -> String? {
        CloudModelList.note(job, preset: s.preset, model: model).map { Loc.string($0, table: "Dictation") }
    }

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

    /// The row's line: where the job's content goes (and, on Auto, which model it is now).
    @MainActor static func line(_ job: CloudJob) -> String {
        let auto = CloudStore.setup.choice(job) == .auto
        if let c = CloudStore.cloudModel(job) {
            let goes = job == .vision ? M("models.job.goes.images", c.service) : M("models.job.goes.text", c.service)
            return auto ? sentences([M("models.job.auto", c.model), goes]) : goes
        }
        guard let local = localModel(job) else { return M("models.job.none") }
        return auto ? M("models.job.auto_local", local) : M("models.job.local")
    }

    /// A feature page's line: "deepseek-flash · cloud", "Gemma 4 E2B · this Mac", "No model yet".
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
        default: return M("models.check.other")
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
    @State private var adding = ProcessInfo.processInfo.environment["BLURT_TEST_CLOUD_SHEET"] == "add"
    @State private var editing: CloudService?

    var body: some View {
        let setup = CloudStore.setup
        SettingsGroup("speech.services") {
            ForEach(setup.services) { s in serviceLine(s) }
            addLine(empty: setup.services.isEmpty)
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
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Group {
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
    @Published var stored = false
    @Published var check: Check = .idle
    /// Model Studio / OpenAI: the speech check's line
    @Published var speech: String?
    @Published var connecting = false

    init(editing: CloudService?, preset: String? = nil) {
        self.editing = editing
        let taken = Set(CloudStore.setup.services.map(\.preset))
        let first = preset ?? CloudPreset.all.first { !taken.contains($0.id) }?.id ?? "custom-openai"
        let p = editing?.preset ?? first
        self.preset = p
        region = editing?.region ?? editing?.endpoint?.region ?? CloudRegion.forSystem(Locale.current.region?.identifier)
        baseURL = editing.map { $0.effectiveBaseURL } ?? ""
        name = editing?.name ?? ""
        if let e = editing {
            Task.detached(priority: .userInitiated) {
                let has = CloudStore.key(e) != nil
                await MainActor.run { self.stored = has }
            }
        }
        if editing == nil { baseURL = info.endpoint(region)?.baseURL ?? "" }
    }

    var info: CloudPreset { CloudPreset.preset(preset) ?? CloudPreset.all.last! }

    /// Presets offered when adding: each service once (the user's own, any number of times).
    var presets: [CloudPreset] {
        let taken = Set(CloudStore.setup.services.map(\.preset))
        return CloudPreset.all.filter { $0.custom || !taken.contains($0.id) || $0.id == editing?.preset }
    }

    func pick(_ p: String) {
        guard p != preset else { return }
        preset = p
        baseURL = info.endpoint(region)?.baseURL ?? ""
        check = .idle; speech = nil
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
        if editing == nil, let p = CloudPreset.detect(key: k), presets.contains(where: { $0.id == p }) { pick(p) }
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
        !service.effectiveBaseURL.isEmpty && (stored || !key.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// The key to use: typed, else saved. nil + the sentence when there is none or it can't be a key.
    func keyToUse() async -> (String?, String?) {
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Test: the model list (the key and the address), then one tiny request on the polish default (the protocol and
    /// the model); Model Studio and OpenAI also hear a short clip (CloudSpeech.check). true when it works.
    @discardableResult
    func test() async -> Bool {
        check = .running; speech = nil
        let (k, problem) = await keyToUse()
        guard let key = k else { check = .failed(problem ?? CloudText.checkFailure("no_key")); return false }
        let svc = service
        emit(["event": "cloud_service", "action": "test", "preset": svc.preset])
        let t0 = Date()
        let listed = await CloudStore.fetchModels(svc, key: key)
        let listMs = Int(Date().timeIntervalSince(t0) * 1000)
        var models: [CloudModelInfo]?
        var listOK = false
        switch listed {
        case .success(let m): models = m; listOK = true
        case .failure(.auth): check = .failed(CloudText.checkFailure("auth")); return false
        case .failure(.network): check = .failed(CloudText.checkFailure("network")); return false
        case .failure: models = svc.known.isEmpty ? nil : svc.known
        }
        guard let model = CloudModelList.defaultModel(.polish, preset: svc.info, models: models)
                ?? models.flatMap({ CloudModelList.suitable($0, .polish, preset: svc.info).first?.id }) else {
            check = .failed(CloudText.checkFailure("no_model")); return false
        }
        let body = try? JSONSerialization.data(withJSONObject: ["cloud": CloudStore.payload(svc, model: model, key: key)])
        let result: Check = await withCheckedContinuation { c in
            Scripts.call("polish_cloud.py", ["check"], stdin: body, timeout: 30) { r in
                switch r {
                case .success(let o): c.resume(returning: .ok(o["ms"] as? Int ?? 0))
                // the scripts can't run yet (uv still installing, a first launch): the list already proved the key
                case .failure(let f) where listOK && ["no_uv", "no_scripts", "failed"].contains(f.code): c.resume(returning: .ok(listMs))
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

    private func checkSpeech(_ key: String) {
        let dashscope = preset == "dashscope"
        let id = dashscope ? CloudSpeech.dashScopeModel : CloudSpeech.openAIModel
        var setup = CloudSpeech.setup
        if !dashscope { setup = CloudSpeech.Setup(service: .openai, baseURL: "", model: setup.service == .openai ? setup.model : "") }
        CloudSpeech.check(modelID: id, typedKey: key, setup: setup, dsModel: CloudSpeech.dashScopeChoice) { [weak self] r in
            switch r {
            case .ok(let ms, _): self?.speech = M("models.check.speech_ok", Loc.number(ms))
            case .failed(let k): self?.speech = M("models.check.speech_failed", Loc.string(k, table: "Dictation"))
            }
        }
    }

    /// Save: the key (when typed) and the service. A new service is tested first and saved when the key works (a
    /// service that lists no models but takes the key is saved too).
    func save(then done: @escaping () -> Void) {
        Task {
            let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty, let p = CloudKeyCheck.problem(typed) { check = .failed(CloudText.keyProblem(p)); return }
            if editing == nil {
                connecting = true
                let ok = await test()
                connecting = false
                guard ok else { return }
            }
            let svc = service
            let speechBefore = CloudSpeech.environment()
            CloudStore.connect(svc, key: typed.isEmpty ? nil : typed)
            key = ""
            if case .ok = check {} else { Task.detached { _ = await CloudStore.fetchModels(svc) } }
            afterChange(speechBefore: speechBefore)
            done()
        }
    }

    func remove(then done: () -> Void) {
        guard let e = editing else { return done() }
        let speechBefore = CloudSpeech.environment()
        CloudStore.remove(e)
        afterChange(speechBefore: speechBefore)
        done()
    }

    /// The jobs follow: polish and translate on their next request, ⌥C's server, the speech jobs' list.
    private func afterChange(speechBefore: [String: String]) {
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
            Text(M("models.sheet.note")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
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
            if !keyFirst || m.info.custom {
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
        GridRow {
            label(M("models.sheet.key"))
            VStack(alignment: .leading, spacing: 5) {
                SecureField(m.stored ? M("models.sheet.key.stored") : M("models.sheet.key.placeholder"),
                            text: Binding(get: { m.key }, set: { m.keyChanged($0) }))
                    .textFieldStyle(.roundedBorder)
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
                    .disabled(m.check == .running || !m.canSave)
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

/// A job row's control (Settings → Models): the pop-up, and the sheets it opens.
struct JobModelControl: View {
    let job: CloudJob
    /// the model library (Get More Models…)
    var library: () -> Void
    @ObservedObject var ui = CloudModelsUI.shared
    @ObservedObject var d = DictationModels.shared
    @State private var adding = false
    @State private var other = false

    private static let auto = "auto", add = "add", more = "more", otherTag = "other"

    var body: some View {
        _ = ui.tick
        return Group {
            if job != .vision, d.polish == nil, CloudStore.setup.services.isEmpty {
                BrandSpinnerView(size: 12)
            } else {
                ModelMenuPopup(label: SettingsCatalog.entry(job.rowID).map(SettingsCatalog.title) ?? "", items: items,
                               current: current) { pick($0) }
            }
        }
        .sheet(isPresented: $adding) { CloudServiceSheet(editing: nil) { adding = false }.buttonStyle(.automatic) }
        .sheet(isPresented: $other) { OtherModelSheet(job: job) { other = false }.buttonStyle(.automatic) }
    }

    /// The pop-up's value now.
    var current: String {
        switch CloudStore.setup.choice(job) {
        case .auto: return Self.auto
        case .local: return "local:" + (job == .polish ? d.polish?.selected ?? "" : "")
        case .cloud(let s, let m):
            let model = m.isEmpty ? CloudStore.route(job).model ?? "" : m
            return "cloud:\(s)\t\(model)"
        }
    }

    var items: [ModelMenuPopup.Item] {
        var out: [ModelMenuPopup.Item] = [.init(value: Self.auto, title: M("models.job.auto_item"))]
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
        // each connected service: its models for the job, the default first
        let keep: (CloudService) -> String? = { s in
            if case .cloud(let id, let m) = CloudStore.setup.choice(job), id == s.id { return m }
            return nil
        }
        for s in CloudRouting.ranked(CloudStore.connected) {
            let list = CloudModelList.menu(job, preset: s.info, models: CloudStore.choices(s) ?? [], keep: keep(s) ?? nil)
            guard !list.isEmpty else { continue }
            out.append(.header(CloudStore.name(s)))
            out += list.map { .init(value: "cloud:\(s.id)\t\($0.id)", title: $0.name ?? $0.id, note: CloudText.note(job, s, $0.id)) }
        }
        out.append(.divider)
        if !CloudStore.connected.isEmpty { out.append(.init(value: Self.otherTag, title: M("models.job.other"))) }
        out.append(.init(value: Self.add, title: M("models.job.add")))
        if job == .polish && d.polish?.supported == true { out.append(.init(value: Self.more, title: M("models.job.more"))) }
        return out
    }

    func pick(_ v: String) {
        switch v {
        case Self.auto:
            CloudStore.setChoice(.auto, for: job)
            if job == .polish { d.unpinPolish() }
        case Self.add: adding = true; return
        case Self.otherTag: other = true; return
        case Self.more: library(); return
        default:
            if v.hasPrefix("local:") {
                CloudStore.setChoice(.local, for: job)
                let id = String(v.dropFirst("local:".count))
                if job == .polish, let x = d.polish?.models.first(where: { $0.id == id }) { d.choose(x) }
            } else if v.hasPrefix("cloud:") {
                let parts = v.dropFirst("cloud:".count).split(separator: "\t", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return }
                CloudStore.setChoice(.cloud(service: parts[0], model: parts[1]), for: job)
            }
        }
        Dictation.shared.apply()
        if job == .vision { ScreenTextRefine.modeChanged() }
        ui.bump()
    }
}

/// Any model of a connected service by its id: the service, a field, and the service's models that match it.
struct OtherModelSheet: View {
    let job: CloudJob
    var close: () -> Void
    @State private var service: String = CloudRouting.ranked(CloudStore.connected).first?.id ?? ""
    @State private var model = ""

    var matches: [CloudModelInfo] {
        guard let s = CloudStore.setup.service(service) else { return [] }
        let all = CloudModelList.suitable(CloudStore.choices(s) ?? [], job, preset: s.info)
        let q = model.trimmingCharacters(in: .whitespaces).lowercased()
        return Array((q.isEmpty ? all : all.filter { $0.id.lowercased().contains(q) || ($0.name ?? "").lowercased().contains(q) }).prefix(12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(M("models.other.title")).font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
            ChoicePopup(label: M("models.sheet.service"),
                        choices: CloudRouting.ranked(CloudStore.connected).map { ($0.id, CloudStore.name($0)) },
                        selection: $service, width: 260)
            TextField(M("models.other.placeholder"), text: $model).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(matches, id: \.id) { x in
                    Button { model = x.id } label: {
                        Text(x.id).font(.system(size: SettingsMetrics.detailSize)).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button(M("models.cancel"), action: close).keyboardShortcut(.cancelAction)
                Button(M("models.other.use")) {
                    CloudStore.setChoice(.cloud(service: service, model: model.trimmingCharacters(in: .whitespaces)), for: job)
                    Dictation.shared.apply()
                    if job == .vision { ScreenTextRefine.modeChanged() }
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(service.isEmpty || model.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 18)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A feature page's Change… for a job (its row: "Uses deepseek-flash · cloud", CloudText.uses): opens Settings → Models
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
