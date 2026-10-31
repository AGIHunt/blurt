// The models dictation runs on, in one place (docs/design/dictation.md §Recognition model, §Polish): the speech models
// it can use (`transcribe.py dictation-models`) and the polish models (`polish.py models`), their downloads (only when
// the user asks, through the app's one download manager, App/ModelDownloads.swift: a model the assistant is already
// fetching shows its bar here, "Queued" while it waits, never a second Download), whether dictation has a recogniser
// to run on (`dictationReady`: the dictation key waits on it), the choice, the recommended pair with its total size, and
// their names (the Dictation page's history shows names, not ids). Settings → Speech picks them in its "Dictation" and
// "Dictation polish" rows (automatic while Choose automatically is on and nothing is pinned), offers the recommended
// pair in its one recommendation, and lists them in the model library sheet; Settings → Dictation shows the current
// choice with a link there (show(pane: "speech/dictation")). Sizes come from the catalogues' size_mb, formatted by
// `modelSize`. Strings: Resources/*.lproj/Speech.strings.
import AppKit
import Combine
import SwiftUI
import BlurtCore

private func S(_ key: String, _ args: CVarArg...) -> String {
    let fmt = Loc.string(key, table: "Speech")
    return args.isEmpty ? fmt : String(format: fmt, locale: Loc.locale, arguments: args)
}

struct PolishModel: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var family: String
    var sizeMB: Double
    var installed: Bool
    var recommended: Bool
    var ramMB: Double?
    enum CodingKeys: String, CodingKey { case id, name, family, installed, recommended, sizeMB = "size_mb", ramMB = "ram_mb" }
}

/// `transcribe.py dictation-models`: what dictation can use here.
struct DictationASRModel: Decodable, Identifiable, Hashable {
    var id: String
    var name: String?
    var sizeMB: Double
    /// it can run: its files and the VAD every local model hears through
    var installed: Bool
    /// its own files are in (without the VAD: `setup` of it fetches only that, 0.6 MB); nil from an older script
    var files: Bool?
    var recommended: Bool
    /// none | prompt | context | hotwords: how the model takes the custom words
    var vocab: String
    /// it runs here beside the polish model (nil from an older script)
    var fits: Bool?
    /// macOS's own recogniser: nothing to download
    var builtin: Bool?
    enum CodingKeys: String, CodingKey { case id, name, installed, files, recommended, vocab, fits, builtin, sizeMB = "size_mb" }
}

struct DictationASRState: Decodable {
    var configured: String?
    var recommended: String
    var selected: String
    var models: [DictationASRModel]
    // can a dictation run with nothing downloaded (the selected model and the VAD), and what is missing for that
    var ready: Bool?
    var selectedInstalled: Bool?
    var configuredInstalled: Bool?
    var missing: [String]?
    /// the selected model is a cloud service (first-minute-speech.md §2.4)
    var selectedCloud: Bool?
    enum CodingKeys: String, CodingKey {
        case configured, recommended, selected, models, ready, missing
        case selectedInstalled = "selected_installed", configuredInstalled = "configured_installed"
        case selectedCloud = "selected_cloud"
    }

    /// The CLI's shape again, for Dictation (BlurtCore's DictationSpeechModels reads it).
    var dictionary: [String: Any] {
        var d: [String: Any] = ["selected": selected, "recommended": recommended,
                                "models": models.map { ["id": $0.id, "installed": $0.installed] as [String: Any] }]
        if let c = configured { d["configured"] = c }
        if let r = ready { d["ready"] = r }
        if let s = selectedInstalled { d["selected_installed"] = s }
        if let c = configuredInstalled { d["configured_installed"] = c }
        if let m = missing { d["missing"] = m }
        if let c = selectedCloud { d["selected_cloud"] = c }
        return d
    }
}

struct PolishState: Decodable {
    var supported: Bool
    var tier: String
    /// nil: no local polish model by default on this Mac (8 GB: polish_models.json defaults)
    var recommended: String?
    var selected: String?
    var configured: String?
    var models: [PolishModel]
}

/// A model's download size the same way everywhere — the assistant, Settings, the menu, the toasts (BlurtCore
/// ModelBundle.size: decimal units, whole MB below 1 GB, one decimal above: "228 MB", "2.5 GB").
func modelSize(_ mb: Double) -> String { ModelBundle.size(mb, locale: Loc.locale) }

@MainActor
final class DictationModels: ObservableObject {
    static let shared = DictationModels()

    @Published var asr: DictationASRState?
    @Published var polish: PolishState?
    /// `dictation-models` ran and couldn't answer, offline or on an error (not a timeout: BlurtCore
    /// SpeechSetup.refusesDictation): the speech tools aren't set up (an offline first run — uv couldn't install
    /// them). Dictation then refuses before listening ("isn't set up yet · Set Up…", Dictation.notSetUp), the menu
    /// offers Set Up Dictation…, and the welcome line says so — instead of listening and failing without a reason.
    @Published private(set) var asrUnreadable = false
    /// Why the last `dictation-models` didn't answer (nil: it did).
    @Published private(set) var asrFailure: SpeechSetup.ListFailure?
    private var loaded = false
    private var sub: AnyCancellable?

    init() {
        // the download manager's progress shows in these rows
        sub = ModelDownloads.shared.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private var dl: ModelDownloads { ModelDownloads.shared }
    /// A model's download: its bar while it runs, "Queued" (0 of its size) while it waits, nil otherwise.
    func progress(_ id: String) -> (done: Double, total: Double)? { dl.progress(id) }
    func queued(_ id: String) -> Bool { dl.isQueued(id) }
    func unpacking(_ id: String) -> Bool { dl.isUnpacking(id) }
    func failed(_ id: String) -> Bool { dl.failed[id] != nil }
    /// any of dictation's models is coming down or waiting
    var downloading: Bool { (asr?.models.map(\.id) ?? []).contains(where: dl.queue.contains) || (polish?.models.map(\.id) ?? []).contains(where: dl.queue.contains) }

    /// The CLI's answer as BlurtCore reads it (DictationSpeechModels: ready, what is missing, what to get) — the same
    /// rule the dictation key goes by (Dictation.speechModels is fed from `asr`: Dictation.watchModelChanges).
    var speechModels: DictationSpeechModels? { asr.flatMap { DictationSpeechModels($0.dictionary) } }
    /// Dictation has a recogniser to run on: the selected model (a local one on this Mac, or a cloud one with its key)
    /// and the VAD every take goes through (`ready`; an older script: the selected row). nil = not read yet, or not
    /// known (the Fn key then doesn't wait on this).
    var dictationReady: Bool? { asr?.ready ?? selectedASR.map(\.installed) }
    /// What dictation's "Download" gets, as one job for the download manager (DictationSpeechModels.toGet): the
    /// configured model when that is the one missing, else the recommended one; with the model's files in and only
    /// the VAD missing, the selected model's setup, which fetches just the VAD (0.6 MB, not the model again). Never
    /// pinned (`select` off): an automatic choice stays automatic, a configured one stays as it is. nil = the list
    /// isn't read, or what is missing can't be downloaded from here (the models' page then).
    var dictationJob: ModelDownloadQueue.Job? {
        // the state the key went by (Dictation.speechModels, fed from `asr`), else `asr` itself
        guard let a = asr, let sm = Dictation.shared.speechModels ?? speechModels, let get = sm.toGet else { return nil }
        let row = a.models.first { $0.id == get.id }
        let vadOnly = (get.id == sm.selected && sm.selectedInstalled) || (row?.files == true && row?.installed == false)
        if vadOnly { return ModelDownloadQueue.Job(id: get.id, kind: .dictation, name: row?.name ?? get.id, sizeMB: DictationModels.vadMB) }
        guard let r = row else { return nil }
        return ModelDownloadQueue.Job(id: r.id, kind: .dictation, name: r.name ?? r.id, sizeMB: r.sizeMB)
    }
    /// The island's first offer when this Mac has no speech model at all (DictationSpeechModels.firstOffer): the
    /// smallest model that fits; the recommended one stays in Settings. nil: `dictationJob` is what to get.
    var firstModelJob: ModelDownloadQueue.Job? {
        guard let a = asr, let sm = Dictation.shared.speechModels ?? speechModels else { return nil }
        let rows = a.models.map { (id: $0.id, sizeMB: $0.builtin == true ? 0 : $0.sizeMB, fits: $0.fits ?? true) }
        guard let o = sm.firstOffer(rows), let r = a.models.first(where: { $0.id == o.id }) else { return nil }
        return ModelDownloadQueue.Job(id: r.id, kind: .dictation, name: r.name ?? r.id, sizeMB: r.sizeMB)
    }

    /// silero_vad.onnx
    static let vadMB = 0.6

    func load() async {
        loaded = true
        async let a = SkillCLI.shared.run("transcribe.py", ["dictation-models"], timeout: 120)
        async let p = SkillCLI.shared.run("polish.py", ["models"], timeout: 60)
        var timedOut = false, detail = ""
        do {
            let r = try await a
            asr = r.decode(DictationASRState.self)
            if asr == nil { detail = r.errorText }
        } catch {
            asr = nil
            if case ScriptError.timeout = error { timedOut = true }
            detail = "\(error)"
        }
        polish = (try? await p)?.decode(PolishState.self)
        asrFailure = asr != nil ? nil : SpeechSetup.listFailure(timedOut: timedOut, online: NetworkWatch.shared.isOnline)
        let unreadable = SpeechSetup.refusesDictation(asrFailure)
        if asrUnreadable != unreadable || asrFailure != nil {
            emit(["event": "dictation_models_readable", "readable": asr != nil, "failure": asrFailure?.rawValue ?? NSNull(),
                  "detail": detail.isEmpty ? NSNull() : String(detail.suffix(400))])
        }
        asrUnreadable = unreadable
    }

    /// Once per run (the history's names); Settings reloads whenever it opens.
    func loadIfNeeded() { if !loaded { Task { await load() } } }

    // MARK: names

    /// A model's name for people: the live list's, else the catalogues the app ships with the skill (ModelCatalog:
    /// read once, no script run) — so an id ("qwen3-asr-1.7b-mlx") never shows while the list loads or can't be read.
    func asrName(_ id: String) -> String {
        ModelCatalog.name(id, live: asr?.models.first { $0.id == id }?.name) ?? S("speech.model.other")
    }
    func polishName(_ id: String) -> String {
        ModelCatalog.name(id, live: polish?.models.first { $0.id == id }?.name) ?? S("speech.model.other")
    }
    var selectedASR: DictationASRModel? { asr.flatMap { a in a.models.first { $0.id == a.selected } } }
    var selectedPolish: PolishModel? { polish.flatMap { p in p.models.first { $0.id == p.selected } } }

    // MARK: the recommended pair

    /// This Mac's defaults — recogniser, its window and field context, local polish, cloud polish with macOS's
    /// transcript as the second opinion — by the rule `transcribe.py dictation-models` applies to Automatic
    /// (BlurtCore DictationTier.recommended; docs/design/dictation.md §Defaults by Mac): the memory, the 1.7B's
    /// measured rtf (Settings → Speech's Measure, `transcribe.py bench`) or else the chip, and whether polish has a
    /// cloud service.
    var tier: DictationTier.Choice {
        DictationTier.recommended(ramGB: (Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 * 10).rounded() / 10,
                                  rtf: SpeechModel.shared.model(DictationTier.large)?.bench?.rtf,
                                  hasCloudKey: DictationCloud.ready, slowChip: DictationTier.slowChip(Self.chip))
    }
    /// "Apple M5 Max" (machdep.cpu.brand_string), as transcribe.py's probe reads it
    static let chip: String? = {
        var n = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &n, nil, 0) == 0, n > 0 else { return nil }
        var b = [CChar](repeating: 0, count: n)
        guard sysctlbyname("machdep.cpu.brand_string", &b, &n, nil, 0) == 0 else { return nil }
        return String(cString: b)
    }()

    var recommendedASR: DictationASRModel? { asr.flatMap { a in a.models.first { $0.id == a.recommended } } }
    var recommendedPolish: PolishModel? {
        guard let p = polish, p.supported else { return nil }
        return p.models.first { $0.id == p.recommended }
    }
    /// The whole recommended set's size, and what of it still has to be downloaded.
    var recommendedMB: (total: Double, missing: Double) {
        var total = 0.0, missing = 0.0
        if let a = recommendedASR { total += a.sizeMB; if !a.installed { missing += a.sizeMB } }
        if let p = recommendedPolish { total += p.sizeMB; if !p.installed { missing += p.sizeMB } }
        return (total, missing)
    }
    /// The recommended pair, nothing pinned (dictation and polish stay automatic: the recommended model runs once in).
    func downloadRecommended() {
        var jobs: [ModelDownloadQueue.Job] = []
        if let a = recommendedASR, !a.installed { jobs.append(.init(id: a.id, kind: .dictation, name: a.name ?? a.id, sizeMB: a.sizeMB)) }
        if let p = recommendedPolish, !p.installed { jobs.append(.init(id: p.id, kind: .polish, name: p.name, sizeMB: p.sizeMB)) }
        if !jobs.isEmpty { dl.download(jobs, via: "settings") }
    }

    // MARK: what dictation still needs (Settings → Dictation's Models row: one Download for all of it)

    /// The models dictation can't run without yet, as the download manager's jobs: the recogniser
    /// (`dictationJob`: the configured or recommended one, or only the VAD) and — when a style polishes — the polish
    /// model in use (or the recommended one). Nothing a download already has, nothing pinned. Empty: all in.
    func missingJobs(polish needsPolish: Bool) -> [ModelDownloadQueue.Job] {
        var jobs: [ModelDownloadQueue.Job] = []
        if dictationReady == false, let j = dictationJob { jobs.append(j) }
        if needsPolish, let p = polish, p.supported, selectedPolish?.installed != true,
           let x = selectedPolish ?? recommendedPolish {
            jobs.append(.init(id: x.id, kind: .polish, name: x.name, sizeMB: x.sizeMB))
        }
        return jobs.filter { !dl.queue.contains($0.id) }
    }
    func downloadMissing(polish: Bool) {
        let jobs = missingJobs(polish: polish)
        if !jobs.isEmpty { dl.download(jobs, via: "settings") }
    }

    // MARK: speech model

    func chooseASR(_ m: DictationASRModel) {
        save("asr_model", m.id)
        Task { await load() }
    }

    /// One model's Download: through the download manager, and used once it is in — only when the user asks.
    func installASR(_ m: DictationASRModel) {
        dl.download([.init(id: m.id, kind: .dictation, name: m.name ?? m.id, sizeMB: m.sizeMB, select: true)], via: "settings")
    }

    // MARK: polish model

    func choose(_ m: PolishModel) {
        save("polish_model", m.id)
        Dictation.shared.refreshPolishModel()
        Task { await load() }
    }

    /// `polish.py setup --model ID --use` through the download manager — only when the user asks.
    func install(_ m: PolishModel) {
        dl.download([.init(id: m.id, kind: .polish, name: m.name, sizeMB: m.sizeMB, select: true)], via: "settings")
    }

    /// The model library's Download: the model comes down; it is used once it's in only when polish has nothing to
    /// run on yet (an automatic choice stays automatic otherwise — the row's pop-up picks it).
    func download(_ m: PolishModel) {
        dl.download([.init(id: m.id, kind: .polish, name: m.name, sizeMB: m.sizeMB, select: polish?.selected == nil)], via: "settings")
    }
    func download(_ m: DictationASRModel) {
        dl.download([.init(id: m.id, kind: .dictation, name: m.name ?? m.id, sizeMB: m.sizeMB)], via: "settings")
    }

    // MARK: automatic

    /// Dictation's speech model is chosen for this Mac (nothing configured).
    var asrAuto: Bool { asr != nil && asr?.configured == nil }
    var polishAuto: Bool { polish != nil && polish?.configured == nil }

    /// Settings → Speech's Choose automatically, for dictation's two models: on, both go back to automatic; off, each
    /// keeps what it uses now (pinned, so nothing changes under the user until they pick another).
    func setAuto(_ on: Bool) {
        if on {
            if asr?.configured != nil { save("asr_model", nil) }
            if polish?.configured != nil { save("polish_model", nil); Dictation.shared.refreshPolishModel() }
        } else {
            if let a = asr, a.configured == nil, a.selectedInstalled == true { save("asr_model", a.selected) }
            if let p = polish, p.configured == nil, let s = p.selected { save("polish_model", s) }
        }
        Task { await load() }
    }

    /// Polish back to automatic alone (Settings → Models' Polish row: Auto), the speech model untouched.
    func unpinPolish() {
        if polish?.configured != nil { save("polish_model", nil); Dictation.shared.refreshPolishModel() }
        Task { await load() }
    }

    /// A model's Stop: the running one ends, a queued one leaves the queue.
    func cancel(_ id: String) { dl.stop(id) }

    private func save(_ key: String, _ value: Any?) {
        Dictation.set(key, value)
        Dictation.shared.apply()
        emit(["event": "dictation_setting", "key": key, "value": value.map { "\($0)" } ?? "default"])
    }

    /// tests: `dictation polish install ID | cancel ID | use ID | state` — the model rows' buttons, then a
    /// "polish_settings" event with every row's state (whichever pane is showing); `fake ready|missing`: what the two
    /// lists say, without running them (a screenshot of either state on a Mac with nothing downloaded)
    func testCommand(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        if a.first == "fake", a.count == 2 {
            let ok = a[1] == "ready"
            asr = DictationASRState(configured: nil, recommended: "qwen3-asr-1.7b-mlx", selected: "qwen3-asr-1.7b-mlx",
                                    models: [DictationASRModel(id: "qwen3-asr-1.7b-mlx", name: "Qwen3-ASR 1.7B", sizeMB: 1_740, installed: ok,
                                                               files: ok, recommended: true, vocab: "context")],
                                    ready: ok, selectedInstalled: ok, configuredInstalled: nil, missing: ok ? [] : ["qwen3-asr-1.7b-mlx"])
            polish = PolishState(supported: true, tier: "pro", recommended: "gemma-4-e2b", selected: "gemma-4-e2b", configured: nil,
                                 models: [PolishModel(id: "gemma-4-e2b", name: "Gemma 4 E2B", family: "gemma", sizeMB: 3_200, installed: ok,
                                                      recommended: true)])
            emit(["event": "polish_settings", "fake": a[1]])
            return
        }
        Task {
            if polish == nil { await load() }
            if a.count == 2, let model = polish?.models.first(where: { $0.id == a[1] }) {
                switch a[0] {
                case "install": install(model)
                case "cancel": cancel(model.id)
                case "use": choose(model)
                default: break
                }
            }
            emit(["event": "polish_settings", "selected": polish?.selected ?? NSNull(), "polish": Dictation.polishOn,
                  "models": (polish?.models ?? []).map { x -> String in
                      let d = progress(x.id).map { " \(Int($0.done))/\(Int($0.total))" } ?? (queued(x.id) ? " queued" : "")
                      return "\(x.id)\(x.installed ? " installed" : "")\(x.recommended ? " recommended" : "")\(d)\(failed(x.id) ? " failed" : "")"
                  }])
        }
    }
}
