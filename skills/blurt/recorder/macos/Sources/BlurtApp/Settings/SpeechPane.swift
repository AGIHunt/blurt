// Settings → Speech (K9; SettingsKit rows, titles and descriptions from SettingsCatalog), built around one question:
// which model does each job, and is the recommended set on this Mac? (docs/design/system.md §3.4)
//
//   lead       "Recommended for this Mac: Qwen3-ASR 1.7B" with Compare… at its end: dictation's
//              choices side by side in a sheet (DictationCompare.swift; also the dictation pop-up's Compare Choices…).
//   On this Mac  settings rows (no glyphs). At most one recommendation, only while something recommended is missing
//              (`transcribe.py models` for recordings / live captions / voice notes, `dictation-models` + `polish.py
//              models` for dictation): one row — the models by name, one line with the size and what they are for, the
//              page's one primary Download, a ⋯ on hover for one model at a time; what each job will use is its
//              tooltip. While anything downloads it becomes that download's bar and Stop. Then All models: Manage
//              Models… opens the library.
//   Cloud services  the services the user connected with their own key (CloudServicesPane.swift, CloudStore).
//   Each job   one row per job — Recordings, Live captions, Voice notes, Dictation (or one Speech recognition row
//              while they share a model), then Polish, Translate, Copy Text from Screen —, each with its glyph, one
//              line and the model in use in its pop-up; Choose Automatically (asr.auto, and dictation's two models
//              unpinned: DictationModels.setAuto) is a check item at the speech pop-ups' foot. The text jobs also list
//              each connected service's models. Every row's line says where its content goes ("Stays on this Mac.").
//              A job whose model isn't on this Mac says "· downloading" or "None", never names it as if in use.
//   Languages  the languages you speak (chips) and the recognition language (detect, or always one).
//   Advanced   folded at the page's foot (system.md §3.4: "› Advanced", closed at rest; a search or a link landing on
//              one of its rows unfolds it): one box for this Mac — processor threads, transcriptions at a time, GPU
//              memory, lighter models on battery — with the priority footnote right under it; then, each in a small
//              box of its own and only where it means something, Cloud recognition (once a cloud recogniser has a
//              key: its model and the audio speed, in CloudSpeechSheet) and the download mirror (in mainland China, once
//              it was set by hand, after a failed download, or when a search asks for it). The cloud services' keys are
//              never here: they live in Cloud services (CloudSpeechLines for the speech-only ones).
//   library    a sheet (ModelLibrary): one 32 pt row per model that runs here, recognition or polish — what it is
//              used for, accuracy for your languages, speed, memory, size as a table; numbers measured on this Mac
//              (`transcribe.py bench`) carry the seal; Download on hover, Measure / Show in Finder / Move to Trash in
//              the row's "…" menu (and its context menu). Move to Trash asks by the model's name and size.
// Every download goes through the app's one download manager (App/ModelDownloads.swift); this page is the one place
// that offers the recommended download (Settings → Dictation links here).
// Test hooks (BLURT_TEST_COMMANDS): `settings speech/speech.models` opens the library, `settings speech/speech.threads`
// (or `settings speech/speech.advanced`) unfolds Advanced; BLURT_TEST_SPEECH_ADVANCED=1 shows it open;
// BLURT_TEST_SPEECH_HOVER=ID shows a library row as hovered, BLURT_TEST_SPEECH_TAB=polish its tab.
// Strings: Resources/*.lproj/Speech.strings (Loc table "Speech").
import AppKit
import Combine
import SwiftUI
import BlurtCore

/// Loc.t for the Speech table (Loc.t's own variadic arguments can't be forwarded).
private func S(_ key: String, _ args: CVarArg...) -> String {
    let fmt = Loc.string(key, table: "Speech")
    return args.isEmpty ? fmt : String(format: fmt, locale: Loc.locale, arguments: args)
}

// MARK: - What transcribe.py reports

struct ASRBench: Decodable, Hashable {
    var rtf: Double?
    var peakRAM: Double?
    var cpuCores: Double?
    var rates: [String: Double]?
    var at: String?
    enum CodingKeys: String, CodingKey { case rtf, at, rates = "error", peakRAM = "peak_ram_mb", cpuCores = "cpu_cores" }
}

struct ASRModel: Decodable, Identifiable, Hashable {
    var id: String
    var name: String?
    var backend: String
    var role: String
    var local: Bool
    var sizeMB: Double
    var ramMB: Double?
    /// ISO codes, or ["multi"] for Whisper-style "every language"
    var languages: [String]
    var installed: Bool
    var path: String?
    var approx: Bool?
    var package: String?
    var runsHere: Bool?
    var fits: Bool?
    var purposes: [String]?
    var keys: [String]?
    var qualityNoteKey: String?
    var rtfRef: Double?
    var errorRef: [String: Double]?
    var bench: ASRBench?
    var isDefault: Bool?

    var multilingual: Bool { languages == ["multi"] }
    var title: String { name ?? id }

    enum CodingKeys: String, CodingKey {
        case id, name, backend, role, local, languages, installed, path, approx, package, purposes, keys, bench
        case sizeMB = "size_mb", ramMB = "ram_mb", runsHere = "runs_here", fits, qualityNoteKey = "quality_note_key"
        case rtfRef = "rtf_ref", errorRef = "error_ref", isDefault = "default"
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try? c.decode(String.self, forKey: .name)
        backend = try c.decode(String.self, forKey: .backend)
        role = (try? c.decode(String.self, forKey: .role)) ?? "asr"
        local = (try? c.decode(Bool.self, forKey: .local)) ?? true
        sizeMB = (try? c.decode(Double.self, forKey: .sizeMB)) ?? 0
        ramMB = try? c.decode(Double.self, forKey: .ramMB)
        if let l = try? c.decode([String].self, forKey: .languages) { languages = l }
        else { languages = ["multi"] }
        installed = (try? c.decode(Bool.self, forKey: .installed)) ?? false
        path = try? c.decode(String.self, forKey: .path)
        approx = try? c.decode(Bool.self, forKey: .approx)
        package = try? c.decode(String.self, forKey: .package)
        runsHere = try? c.decode(Bool.self, forKey: .runsHere)
        fits = try? c.decode(Bool.self, forKey: .fits)
        purposes = try? c.decode([String].self, forKey: .purposes)
        keys = try? c.decode([String].self, forKey: .keys)
        qualityNoteKey = try? c.decode(String.self, forKey: .qualityNoteKey)
        rtfRef = try? c.decode(Double.self, forKey: .rtfRef)
        errorRef = try? c.decode([String: Double].self, forKey: .errorRef)
        bench = try? c.decode(ASRBench.self, forKey: .bench)
        isDefault = try? c.decode(Bool.self, forKey: .isDefault)
    }

    func speaks(_ lang: String) -> Bool { multilingual || languages.contains(lang) }
}

struct ASRHardware: Decodable {
    struct GPU: Decodable { var kind: String; var name: String?; var cores: Int?; var vramGB: Double?
        enum CodingKeys: String, CodingKey { case kind, name, cores, vramGB = "vram_gb" } }
    var chip: String?
    var ramGB: Double
    var perfCores: Int
    var effCores: Int
    var gpu: GPU
    var tier: String
    var onBattery: Bool?
    enum CodingKeys: String, CodingKey {
        case chip, gpu, tier, ramGB = "ram_gb", perfCores = "perf_cores", effCores = "eff_cores", onBattery = "on_battery"
    }
}

struct ASRLimits: Decodable {
    var threads: Int
    var maxConcurrent: Int
    var maxMemoryFraction: Double
    enum CodingKeys: String, CodingKey { case threads, maxConcurrent = "max_concurrent", maxMemoryFraction = "max_memory_fraction" }
}

struct ASRState: Decodable {
    var auto: Bool
    var tier: String
    var hardware: ASRHardware
    var limits: ASRLimits
    var languages: [String]
    var languagesSet: Bool?
    var selected: [String: String?]
    var recommended: [String: String]
    var localOnly: Bool?
    var models: [ASRModel]
    enum CodingKeys: String, CodingKey {
        case auto, tier, hardware, limits, languages, selected, recommended, models
        case languagesSet = "languages_set", localOnly = "local_only"
    }
}

/// The three jobs speech recognition does, in the order the pane shows them.
enum ASRPurpose: String, CaseIterable, Identifiable {
    case batch, live, note
    var id: String { rawValue }
    var title: String { S("speech.purpose.\(rawValue)") }
    var detail: String { S("speech.purpose.\(rawValue).detail") }
    var symbol: String {
        switch self {
        case .batch: return "video"
        case .live: return "captions.bubble"
        case .note: return "mic"
        }
    }
}

/// A finished or failed measurement, kept for the session (the measured numbers themselves come back through
/// `transcribe.py models` from $BLURT_HOME/asr-bench.json).
struct BenchResult { var rtf: Double?; var error: String? }

// MARK: - Model

@MainActor
final class SpeechModel: ObservableObject {
    static let shared = SpeechModel()

    @Published var state: ASRState?
    @Published var models: [ASRModel] = []
    @Published var loading = false
    @Published var error: String?
    /// why the models couldn't be read (nil: they could): the error line's action follows it
    @Published var failure: SpeechSetup.ReadFailure?
    /// the end of what the failed read printed, for Copy Error
    var errorDetail = ""
    @Published var copied = false
    @Published var installingUV = false
    @Published var benching: Set<String> = []
    @Published var bench: [String: BenchResult] = [:]                                      // model id → last run
    @Published var language = "auto"
    @Published var mirror = false
    private var sub: AnyCancellable?

    var localOnly: Bool { Config.shared["privacy.local_asr"] as? Bool ?? false }
    var auto: Bool { state?.auto ?? true }
    var languages: [String] { state?.languages ?? [] }

    init() {
        language = Config.shared["asr.language"] as? String ?? "auto"
        mirror = ModelBundle.mirror
        // downloads are the app's one manager's (App/ModelDownloads.swift): its progress shows in these rows
        sub = ModelDownloads.shared.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // uv arrived (here, the setup assistant or the launch's quiet install): the models can be read now
        uvObserver = NotificationCenter.default.addObserver(forName: UVSetup.finished, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.installingUV = false
                if n.object != nil || self.failure == .noUV { Task { await self.load() } }
            }
        }
    }
    private var uvObserver: NSObjectProtocol?

    /// Install uv from the error line: UVSetup's quiet install (nothing when a usable one is there); its
    /// notification reloads. A uv already there answers without one, so look again shortly.
    func installUV() {
        installingUV = true
        UVSetup.ensure(via: "settings")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self = self, self.installingUV, !UVSetup.installing else { return }
            self.installingUV = false
            Task { await self.load() }
        }
    }

    /// A model's download as its bar shows it: the running one's "N of M", "Queued" while it waits; nil otherwise.
    func download(_ id: String) -> (done: Double, total: Double, text: String)? {
        let dl = ModelDownloads.shared
        if let p = dl.progress(id) {
            if dl.isUnpacking(id) { return (p.total, p.total, S("speech.download.unpacking")) }
            return (p.done, p.total, p.done == 0 ? S("speech.download.preparing") : S("speech.download.progress", mb(p.done), mb(p.total)))
        }
        if dl.isQueued(id) { return (0, model(id)?.sizeMB ?? 1, S("speech.download.queued")) }
        return nil
    }
    /// Why the model's last download stopped on an error (nil: it didn't).
    func failed(_ id: String) -> String? {
        ModelDownloads.shared.failed[id] == nil ? nil : ModelDownloads.shared.failedText(id) ?? S("speech.download.failed")
    }

    func model(_ id: String?) -> ASRModel? { id.flatMap { i in models.first { $0.id == i } } }
    func selected(_ p: ASRPurpose) -> ASRModel? { model(state?.selected[p.rawValue] ?? nil) }
    func recommended(_ p: ASRPurpose) -> ASRModel? { model(state?.recommended[p.rawValue]) }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await SkillCLI.shared.read("transcribe.py", ["models"], timeout: 180)
            guard r.ok, let s = r.decode(ASRState.self) else { failed(stderr: r.stderr.isEmpty ? r.errorText : r.stderr); return }
            // a finished download: the suggestion folds away and the jobs show their new model
            let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || state == nil
            withAnimation(calm ? nil : .easeInOut(duration: 0.25)) {
                state = s
                models = s.models.filter { $0.role == "asr" }  // not the VAD every local model uses
            }
            error = nil
            failure = nil
        } catch ScriptError.timeout {
            failed(stderr: "", timedOut: true)
        } catch { failed(stderr: "\(error)") }
    }

    /// The models couldn't be read: the line says why, and offers what can help — Install uv, Try Again (offline, a
    /// network error, a timeout), or for a package that can't be built its name and Copy Error (trying again would
    /// fail the same way).
    private func failed(stderr: String, timedOut: Bool = false) {
        let f = SpeechSetup.readFailure(uv: ScriptRunner.shared.uvPath != nil, timedOut: timedOut,
                                        online: NetworkWatch.shared.isOnline, stderr: stderr)
        failure = f
        errorDetail = SpeechSetup.errorTail(stderr)
        copied = false
        switch f {
        case .noUV: error = S("speech.error.no_uv")
        case .offline: error = S("speech.error.offline")
        case .network: error = S("speech.error.network")
        case .timeout: error = S("speech.error.timeout")
        case .broken(let p?, let tool?): error = S("speech.error.build_missing", p, tool)
        case .broken(let p?, nil): error = S("speech.error.build", p)
        case .broken(nil, _): error = S("speech.error.read")
        }
        emit(["event": "speech_read_failed", "failure": "\(f)", "detail": String(errorDetail.suffix(2000))])
    }

    /// Copy Error: the end of what the failed read printed, for an issue report.
    func copyError() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(error.map { "\($0)\n\n\(errorDetail)" } ?? errorDetail, forType: .string)
        copied = true
    }

    /// Re-pick for this Mac (auto) and reload.
    func reapply() async {
        if auto { _ = try? await SkillCLI.shared.run("transcribe.py", ["auto", "--apply"], timeout: 120) }
        await load()
    }

    func setAuto(_ on: Bool) {
        Config.shared.set("asr.auto", on)
        Task { await reapply() }
    }

    /// A hand-picked model for one purpose: automatic choice ends, the other purposes keep what they use now.
    func choose(_ m: ASRModel, for p: ASRPurpose) {
        var cur: [String: Any] = [:]
        for q in ASRPurpose.allCases { if let id = state?.selected[q.rawValue] ?? nil { cur[q.rawValue] = id } }
        cur[p.rawValue] = m.id
        Config.shared.set("asr.models", cur)
        Config.shared.set("asr.auto", false)
        Task { await load() }
    }

    /// One model for every job — recordings, live captions, voice notes and dictation (the library's Use, the
    /// Speech recognition row): automatic choice ends; polish keeps what it uses now.
    @MainActor func useEverywhere(_ x: ASRModel) {
        let d = DictationModels.shared
        d.setAuto(false)
        if let dm = d.asr?.models.first(where: { $0.id == x.id }) { d.chooseASR(dm) }
        Config.shared.set("asr.models", Dictionary(uniqueKeysWithValues: ASRPurpose.allCases.map { ($0.rawValue, x.id) }))
        Config.shared.set("asr.auto", false)
        emit(["event": "speech_model_use", "model": x.id])
        Task { await load() }
    }

    /// Back to automatic: every job, dictation's two models too.
    @MainActor func useAuto() {
        DictationModels.shared.setAuto(true)
        setAuto(true)
    }

    /// The model every job runs on now, when they all run on one (nil: they differ, or one has none yet).
    @MainActor var everywhere: ASRModel? {
        guard let a = DictationModels.shared.asr else { return nil }
        let ids = ASRPurpose.allCases.map { state?.selected[$0.rawValue] ?? nil } + [a.selected]
        guard let first = ids.first ?? nil, ids.allSatisfy({ $0 == first }) else { return nil }
        return model(first)
    }

    func setLanguages(_ l: [String]) {
        Config.shared.set("asr.languages", l.isEmpty ? nil : l)
        if language != "auto", !l.contains(language) { setLanguage("auto") }
        Task { await reapply() }
    }

    /// macOS's recogniser listens for one language: its files are asked for at once, so the next take uses it.
    func setLanguage(_ l: String) {
        language = l
        Config.shared.set("asr.language", l == "auto" ? nil : l)
        AppleSpeech.prepare(via: "settings") { _ in Dictation.shared.refreshSpeechModels() }
    }
    func setMirror(_ on: Bool) { mirror = on; Config.shared.set("asr.hf_mirror", on) }     // explicit either way: off stays off in China
    func setLimit(_ key: String, _ value: Any?) { Config.shared.set("asr.limits.\(key)", value); Task { await load() } }
    var onBattery: String { Config.shared["asr.on_battery"] as? String ?? "lighter" }
    func setOnBattery(_ lighter: Bool) { Config.shared.set("asr.on_battery", lighter ? nil : "same"); objectWillChange.send() }

    /// `transcribe.py setup --model-id ID` through the download manager (the voice-note / recording models; reapplied
    /// for this Mac once it is in).
    func startDownload(_ m: ASRModel) {
        ModelDownloads.shared.download([.init(id: m.id, kind: .note, name: m.title, sizeMB: m.sizeMB)], via: "settings")
    }

    /// Stop: the running download ends, a queued one leaves the queue (never "failed").
    func cancelDownload(_ m: ASRModel) { ModelDownloads.shared.stop(m.id) }

    /// `transcribe.py bench --model-id ID`: spoken samples in the user's languages (macOS `say`), measured here.
    func runBench(_ m: ASRModel) async {
        benching.insert(m.id)
        defer { benching.remove(m.id) }
        do {
            let r = try await SkillCLI.shared.run("transcribe.py", ["bench", "--model-id", m.id], timeout: 1200)
            let o = r.json
            bench[m.id] = BenchResult(rtf: o?["rtf"] as? Double, error: r.ok ? nil : S("speech.bench.failed"))
            emit(["event": "bench", "model": m.id, "rtf": bench[m.id]?.rtf ?? -1])
        } catch { bench[m.id] = BenchResult(rtf: nil, error: S("speech.bench.failed")) }
        await load()
    }

    /// Only our own downloads (inside ~/.blurt/models) can be removed from here — to the Trash. Models in the shared
    /// Hugging Face cache may be used by other apps.
    func canRemove(_ m: ASRModel) -> Bool {
        guard m.installed, let p = m.path else { return false }
        return URL(fileURLWithPath: p).standardizedFileURL.path.hasPrefix(BlurtPaths.home.appendingPathComponent("models").standardizedFileURL.path)
    }
    func remove(_ m: ASRModel) {
        guard canRemove(m), let p = m.path else { return }
        NSWorkspace.shared.recycle([URL(fileURLWithPath: p)]) { _, _ in Task { @MainActor in await self.reapply() } }
    }

    // MARK: numbers for the comparison

    /// Mean error rate over the user's languages this model speaks: measured here, else the reference machine's.
    func errorRate(_ m: ASRModel) -> (value: Double, measured: Bool)? {
        let langs = languages.filter { m.speaks($0) }
        if let r = m.bench?.rates {
            let v = langs.compactMap { r[$0] }
            if !v.isEmpty { return (v.reduce(0, +) / Double(v.count), true) }
        }
        if let r = m.errorRef {
            let v = langs.compactMap { r[$0] }
            if !v.isEmpty { return (v.reduce(0, +) / Double(v.count), false) }
        }
        return nil
    }
    func speed(_ m: ASRModel) -> (value: Double, measured: Bool)? {
        if let r = m.bench?.rtf, r > 0 { return (1 / r, true) }
        if let r = m.rtfRef, r > 0 { return (1 / r, false) }
        return nil
    }
    func memory(_ m: ASRModel) -> (value: Double, measured: Bool)? {
        if let p = m.bench?.peakRAM { return (p, true) }
        return m.ramMB.map { ($0, false) }
    }
    func missing(_ m: ASRModel) -> [String] { languages.filter { !m.speaks($0) } }
}

// MARK: - Formatting

private func mb(_ v: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(v * 1_048_576), countStyle: .memory)
}

private func percent(_ v: Double, digits: Int = 1) -> String {
    let f = NumberFormatter()
    f.locale = Loc.locale
    f.numberStyle = .percent
    f.minimumFractionDigits = 0
    f.maximumFractionDigits = digits
    return f.string(from: v as NSNumber) ?? "\(v)"
}

private func decimal(_ v: Double, digits: Int = 0) -> String {
    let f = NumberFormatter()
    f.locale = Loc.locale
    f.numberStyle = .decimal
    f.maximumFractionDigits = digits
    return f.string(from: v as NSNumber) ?? "\(v)"
}

/// Whole sentences one after another: a space between them in English, none after Chinese full stops.
private func sentences(_ parts: [String]) -> String {
    parts.filter { !$0.isEmpty }.joined(separator: Loc.isChinese ? "" : " ")
}

/// A language's name in the UI language ("Japanese" / "日语").
private func languageName(_ code: String) -> String {
    Loc.locale.localizedString(forLanguageCode: code) ?? code
}

/// A language's name in itself ("日本語"), for the list a person picks their own languages from.
func endonym(_ code: String) -> String {
    let l = Locale(identifier: code)
    let n = l.localizedString(forLanguageCode: code) ?? code
    return n.prefix(1).uppercased(with: l) + n.dropFirst()
}

/// Languages offered in the picker: the ones the bundled models have been measured on first, then the rest of what
/// the multilingual models understand.
private let offeredLanguages = ["en", "zh", "yue", "ja", "ko", "es", "fr", "de", "it", "pt", "ru", "ar", "hi", "vi", "th",
                                "id", "ms", "tr", "nl", "pl", "sv", "da", "fi", "cs", "el", "hu", "ro", "uk", "fa", "fil"]

/// The pop-ups' last items: open the library, or the comparison (dictation's), instead of choosing.
private let moreModels = "__more"
private let compareChoices = "__compare"

// MARK: - Pane

struct SpeechPane: View {
    @ObservedObject var m = SpeechModel.shared
    @ObservedObject var d = DictationModels.shared
    @ObservedObject private var dl = ModelDownloads.shared
    @ObservedObject private var cloud = CloudModelsUI.shared
    /// the capabilities turned off (General's switches): a job that only they have is dimmed and says so
    @ObservedObject private var features = SettingsFeatures.shared
    @State private var library = false
    /// dictation's choices side by side (DictationCompare.swift)
    @State private var compare = false
    /// the pointer is over the download row: its ⋯ shows
    @State private var hoveringDownload = false
    /// Advanced, folded at rest (a search or a link landing inside unfolds it)
    @State private var advanced = ProcessInfo.processInfo.environment["BLURT_TEST_SPEECH_ADVANCED"] != nil
    /// a search or a link asked for the mirror: its row shows wherever this Mac is
    @State private var mirrorAsked = false
    /// Cloud recognition's options (CloudSpeechSheet: the recogniser's model, the audio speed)
    @State private var cloudOptions: String?

    /// Settings → Speech at dictation's row, just under the recommendation and its download bar (Settings →
    /// Dictation's "Change…" / "Download…", the dictation key's "no model yet").
    @MainActor static func showDictationModels() {
        AppEnvironment.settings?.show(pane: SpeechModel.shared.everywhere == nil ? "speech/dictation" : "speech/recognition")
    }

    var body: some View {
        SettingsPage(.speech, lead: lead) {
            useSection
            // the page's one gradient primary is Download while it is there; Add Cloud Model… takes it only after
            CloudServicesSection(primary: !dl.active && picks.isEmpty)
            jobsSection
            languagesSection
            advancedSection
        }
        // the bottom edge as the top (the search results' fade): a row the window ends on slips under it, never cut
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [SettingsMetrics.ground.opacity(0), SettingsMetrics.ground], startPoint: .top, endPoint: .bottom)
                .frame(height: SettingsMetrics.bottomFade)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .task { await m.load() }
        .task { await d.load() }
        .sheet(isPresented: $library) { ModelLibrary { library = false }.buttonStyle(.automatic).closesOnOutsideClick { library = false } }
        .background {
            Color.clear.sheet(isPresented: $compare) {
                DictationCompareSheet { compare = false }.buttonStyle(.automatic).closesOnOutsideClick { compare = false }
            }
        }
        // a search or a link landing on the library or the comparison: open it first
        .onReceive(SettingsFlash.shared.$request) { r in
            if r?.id == "speech.models" { library = true }
            if r?.id == "speech.compare" { compare = true }
            if let id = r?.id, id == "speech.advanced" || SettingsCatalog.entry(id)?.section == "speech.advanced" {
                advanced = true
                if id == "speech.mirror" { mirrorAsked = true }
            }
        }
    }

    /// The page's lead: what is recommended for this Mac and how often it gets a word wrong, with Compare… at its end —
    /// the one place the choices are weighed; the rows under it stay as they were.
    var lead: SettingsLead {
        _ = cloud.tick
        // a read that failed says so on its own line below: "Checking this Mac…" beside it never ended
        let text = m.error != nil && m.state == nil ? "" : m.state == nil || d.asr == nil ? S("speech.loading") : ChoiceText.lead(DictationNow.read())
        return SettingsLead(text: Text(text), accessory: AnyView(
            Button(S("speech.compare.open")) { compare = true }
                .buttonStyle(.plain).foregroundStyle(Color.brandInk)
                .help(S("speech.compare.title"))))
    }

    // MARK: the Mac

    /// "Apple M5 Max, 128 GB": what Choose automatically picks for ("Checking this Mac…" while it is read); the GPU and
    /// the battery in the row's tooltip.
    var machineShort: String? {
        guard let hw = m.state?.hardware else { return nil }
        return S("speech.machine.short", hw.chip ?? S("speech.machine.unknown"), mb(hw.ramGB * 1024))
    }
    var machineLine: String {
        guard let hw = m.state?.hardware else { return S("speech.loading") }
        var parts = [hw.chip ?? S("speech.machine.unknown"), S("speech.machine.memory", mb(hw.ramGB * 1024))]
        if let c = hw.gpu.cores { parts.append(S("speech.machine.gpu_cores", decimal(Double(c)))) }
        else if let v = hw.gpu.vramGB, let n = hw.gpu.name { parts.append("\(n) · " + mb(v * 1024)) }
        else { parts.append(S("speech.machine.cpu_cores", decimal(Double(hw.perfCores + hw.effCores)))) }
        if hw.onBattery == true { parts.append(S("speech.machine.battery")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Models: the recommendation, automatic, one row per job, the library

    /// On this Mac: the recommendation, only while something recommended is missing (or downloading), then the
    /// library (All models). Automatic choice is each pop-up's first item (the jobs' footer says what it goes by).
    @ViewBuilder var useSection: some View {
        SettingsGroup("speech.use", title: S("speech.section.mac"), content: {
            if let e = m.error {
                SettingsLine {
                    HStack(spacing: 12) {
                        Text(e).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandErr)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if m.installingUV || m.loading {
                            BrandSpinnerView(size: 10)
                        } else if m.failure == .noUV {
                            Button(S("speech.install_uv")) { m.installUV() }.help(UVSetup.installCommand)
                        } else if m.failure?.retries == true {
                            Button(S("speech.rec.retry")) { Task { await m.load() } }
                        } else if !m.errorDetail.isEmpty {
                            // the same failure every time: no Try Again, the error for a report
                            Button(S(m.copied ? "speech.error.copied" : "speech.error.copy")) { m.copyError() }
                        }
                    }
                }
            }
            recommendation
            libraryRow
        }, accessory: {
            if (m.loading && m.state != nil) { BrandSpinnerView(size: 10) }
        })
    }

    /// Which model does each job: one row per job, with its glyph and its model — the speech jobs (this Mac's models,
    /// and the cloud ones whose key is set), then the text jobs (CloudServicesPane: Auto, this Mac, a connected
    /// service's models), each with a line on where its content goes.
    @ViewBuilder var jobsSection: some View {
        SettingsGroup("speech.jobs", title: S("speech.section.jobs"), footer: machineShort.map { S("speech.auto.footer", $0) }) {
            if let one = m.everywhere {
                recognitionRow(one)
            } else {
                ForEach(ASRPurpose.allCases) { p in purposeRow(p) }
                dictationRow
            }
            CloudObserving {
                SettingRow("speech.polish", detail: unused(.dictation) ?? (d.polish?.supported == false && CloudStore.connected.isEmpty
                           ? S("speech.purpose.polish.unsupported") : CloudText.line(.polish)), icon: "wand.and.stars") {
                    JobModelControl(job: .polish) { library = true }
                }
                .disabled(unused(.dictation) != nil)
                SettingRow("speech.translate", detail: unused(.dictation, .screenText) ?? CloudText.line(.translate), icon: CloudJob.translate.symbol) {
                    JobModelControl(job: .translate) { library = true }
                }
                .disabled(unused(.dictation, .screenText) != nil)
                SettingRow("speech.vision", detail: unused(.screenText) ?? CloudText.line(.vision), icon: CloudJob.vision.symbol) {
                    JobModelControl(job: .vision) { library = true }
                }
                .disabled(unused(.screenText) != nil)
            }
        }
    }

    /// "Feature is off" for a job that only capabilities turned off have (General's switches; translating is
    /// dictation's and Screen Text's, the one recognition model dictation's, the voice note's and the recording's): its
    /// row stays where it is, dimmed, with that line in place of its model's — and nothing is recommended for it.
    func unused(_ caps: Capability...) -> String? {
        caps.allSatisfy(features.off.contains) ? T("settings.feature.off") : nil
    }
    /// The capability a speech job is for: the recording's two, the voice note's.
    func capability(_ p: ASRPurpose) -> Capability { p == .note ? .cards : .recording }

    // the one recommendation

    struct Pick { var job: ModelDownloadQueue.Job; var uses: [String] }

    /// What is recommended for this Mac and not on it yet, with the jobs it is for. The recording / voice-note models
    /// only while they are chosen automatically (a hand-picked set isn't second-guessed); dictation's pair always.
    var picks: [Pick] {
        var out: [Pick] = []
        func add(_ j: ModelDownloadQueue.Job, _ use: String) {
            if let i = out.firstIndex(where: { $0.job.id == j.id }) {
                if !out[i].uses.contains(use) { out[i].uses.append(use) }
            } else { out.append(Pick(job: j, uses: [use])) }
        }
        if m.auto && m.state != nil {
            for p in ASRPurpose.allCases where unused(capability(p)) == nil {
                guard let r = m.recommended(p), !r.installed, r.local, r.runsHere ?? true else { continue }
                add(.init(id: r.id, kind: .note, name: r.title, sizeMB: r.sizeMB), p.title)
            }
        }
        // dictation turned off: its pair isn't asked for
        guard unused(.dictation) == nil else { return out }
        let dictation = S("speech.purpose.dictation")
        if let a = d.recommendedASR, !a.installed, a.files != true {
            add(.init(id: a.id, kind: .dictation, name: a.name ?? d.asrName(a.id), sizeMB: a.sizeMB), dictation)
        } else if d.dictationReady == false, let j = d.dictationJob {
            add(j, dictation)              // only the VAD (or the configured model) is missing: what the key needs
        }
        if let p = d.recommendedPolish, !p.installed {
            add(.init(id: p.id, kind: .polish, name: p.name, sizeMB: p.sizeMB), S("speech.purpose.polish"))
        }
        return out
    }

    /// One sentence per group of jobs the download changes, in the jobs' own words ("Voice notes will use SenseVoice
    /// Small."): the row's tooltip, so the row itself stays two lines.
    func pickLines(_ ps: [Pick]) -> [String] {
        var groups: [(uses: [String], names: [String])] = []
        for p in ps {
            if let i = groups.firstIndex(where: { $0.uses == p.uses }) { groups[i].names.append(p.job.name) }
            else { groups.append((p.uses, [p.job.name])) }
        }
        return groups.map { g in
            let uses = Loc.list(g.uses.enumerated().map { i, u in i == 0 ? u : u.lowercased(with: Loc.locale) })
            return S("speech.rec.line", uses, Loc.list(g.names))
        }
    }

    /// The download row's title: the models by name ("Qwen3-ASR 1.7B + Gemma 4 E2B"), each kept whole.
    func pickTitle(_ ps: [Pick]) -> String {
        ps.map { ModelBundle.unbreakable($0.job.name) }.joined(separator: " + ")
    }

    /// The download row's one line: its size and what it is for, in two words where it can ("5.9 GB · For speech
    /// recognition and dictation polish") — the four recognition jobs are one, Speech recognition.
    func pickUses(_ ps: [Pick]) -> String {
        var uses: [String] = []
        for p in ps { for u in p.uses where !uses.contains(u) { uses.append(u) } }
        let speech = ASRPurpose.allCases.map(\.title) + [S("speech.purpose.dictation")]
        if speech.allSatisfy(uses.contains) {
            uses = [S("speech.purpose.recognition")] + uses.filter { !speech.contains($0) }
        }
        let list = Loc.list(uses.map { $0.lowercased(with: Loc.locale) })
        let size = modelSize(ps.reduce(0) { $0 + $1.job.sizeMB }).replacingOccurrences(of: " ", with: "\u{00A0}")
        return S("speech.rec.for", size, list)
    }

    @ViewBuilder var recommendation: some View {
        if dl.active {
            // whatever is downloading (from here, the library, the assistant, the dictation key): one bar, one Stop
            let p = dl.progress
            let now = dl.queue.pending.first { $0.id == dl.current } ?? dl.queue.next
            SettingsLine(flashID: "speech.download") {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(S("speech.rec.downloading", now?.name ?? "")).font(.system(size: SettingsMetrics.titleSize)).lineLimit(1)
                            .gridProbe(.text, "download")
                        Text(dl.current.map(dl.isUnpacking) == true ? S("speech.download.unpacking")
                             : p.done == 0 ? S("speech.download.preparing")
                             : S("speech.download.progress", modelSize(p.done), modelSize(p.total)))
                            .font(.system(size: SettingsMetrics.detailSize)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 10) {
                        ProgressView(value: min(p.done, p.total), total: max(p.total, 1)).frame(width: 96)
                            .accessibilityLabel(S("speech.rec.downloading", now?.name ?? ""))
                        Button(S("speech.download.stop")) { dl.stop() }
                    }
                    .gridProbe(.trailing, "download")
                }
            }
        } else {
            let ps = picks
            if !ps.isEmpty {
                let failed = ps.contains { dl.failed[$0.job.id] != nil }
                // what Download changes, job by job, and the dictation model's published speed: the tooltip (Compare…
                // has the numbers side by side)
                let more = ((failed ? [S("speech.download.failed")] : []) + pickLines(ps)
                            + [DictationSpeedText.reference(ps.filter { $0.uses.contains(S("speech.purpose.dictation")) }.map(\.job.id)),
                               S("speech.rec.help")].compactMap { $0 }).joined(separator: "\n")
                SettingsLine(flashID: "speech.download") {
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            // the models by name, on one line; a set too long for it says "Recommended models"
                            ViewThatFits(in: .horizontal) {
                                Text(pickTitle(ps)).lineLimit(1)
                                Text(S("speech.rec.title.short")).lineLimit(1)
                            }
                            .font(.system(size: SettingsMetrics.titleSize))
                            .gridProbe(.text, "recommended")
                            if failed {
                                // a full disk says how much is needed and free, with Show Storage
                                let room = ps.compactMap { dl.failedText($0.job.id) }.first
                                HStack(spacing: 6) {
                                    Text(room ?? S("speech.download.failed.short")).font(.system(size: SettingsMetrics.detailSize))
                                        .foregroundStyle(Color.brandErr).lineLimit(1)
                                    if room != nil {
                                        TextLinkButton(T("app.models.show_storage")) { ModelDownloads.showStorage() }
                                            .font(.system(size: SettingsMetrics.detailSize))
                                    }
                                }
                            } else {
                                Text(pickUses(ps)).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(more)
                        HStack(spacing: 6) {
                            // one model at a time: on hover, its slot kept (RowMenu); the same in the context menu
                            if ps.count > 1 {
                                RowMenu(label: S("speech.rec.choose"), visible: hoveringDownload) { pickItems(ps) }
                            }
                            // the page's one primary (system.md §9), and the app's one place to get these models
                            Button(failed ? S("speech.rec.retry") : S("speech.download.button")) { get(ps) }
                                .buttonStyle(SettingsPrimaryButtonStyle())
                        }
                        .gridProbe(.trailing, "recommended")
                    }
                    .contentShape(Rectangle())
                    .onHover { hoveringDownload = $0 }
                    .contextMenu { if ps.count > 1 { pickItems(ps) } }
                }
            }
        }
    }

    /// One model at a time ("Download Gemma 4 E2B · 1.6 GB"): the download row's ⋯ and context menu.
    @ViewBuilder func pickItems(_ ps: [Pick]) -> some View {
        ForEach(ps, id: \.job.id) { p in
            Button(S("speech.rec.one", p.job.name, modelSize(p.job.sizeMB))) { get([p]) }
        }
    }

    /// One request for the download manager: nothing is pinned (an automatic choice stays automatic and takes each
    /// model once it is in).
    func get(_ ps: [Pick]) { dl.download(ps.map(\.job), via: "settings") }

    // the jobs

    /// A speech row's line: where the voice goes — "Stays on this Mac." for a model here, "Voice goes to Alibaba
    /// Cloud." for a cloud one (the text rows say the same of text). Nil before a model is known.
    func voiceGoes(_ x: ASRModel?) -> String? {
        guard let x = x else { return nil }
        if x.local { return M("models.job.local") }
        // an OpenAI-compatible recogniser by its own title (its service and model, as the Cloud services list names it)
        let to = x.backend == "dashscope" ? S("speech.compare.alibaba") : x.backend == "volcengine" ? S("speech.compare.volcengine")
            : x.title
        return ChoiceText.tight(S("speech.voice.goes", to), to)
    }

    /// The pop-ups' "Choose Automatically" check item: on, every job goes back to the models picked for this Mac; off,
    /// each keeps the one it uses now (`pin`).
    /// (Not a catalogue setting of its own: the same item is in each speech pop-up.)
    func autoCheck(_ on: Bool, pin: @escaping () -> Void) -> SettingMenuToggle {
        SettingMenuToggle(Self.autoCheckID, isOn: Binding(get: { on }, set: { $0 ? m.useAuto() : pin() }), title: S("speech.auto.check"))
    }
    static let autoCheckID = "speech.choose_automatically"

    func purposeRow(_ p: ASRPurpose) -> some View {
        SettingRow("speech.\(p.rawValue)", detail: unused(capability(p)), icon: p.symbol) {
            if m.state == nil {
                BrandSpinnerView(size: 12)
            } else {
                ModelPopUp(label: p.title, current: m.selected(p)?.id, missing: purposeValue(p),
                           choices: choices(p).map { ($0.id, $0.title) }, more: { library = true },
                           auto: autoCheck(m.auto) { if let x = m.selected(p) { m.choose(x, for: p) } else { m.setAuto(false) } }) { id in
                    if let x = m.model(id) { m.choose(x, for: p) }
                }
            }
        }
        .disabled(unused(capability(p)) != nil)
    }

    /// Every job on one model (Chinese and English on Apple silicon, by default): one row, its pop-up the model in use
    /// and the others every job can use. Picking one there (or the library's Use) gives it every job; Choose
    /// Automatically (a check item in it) gives them back to this Mac.
    func recognitionRow(_ one: ASRModel) -> some View {
        let dictation = Set((d.asr?.models ?? []).filter { $0.installed || $0.files == true }.map(\.id))
        let here = choices(.note).filter { dictation.contains($0.id) || $0.id == one.id }
        let off = unused(.dictation, .cards, .recording)
        return SettingRow("speech.recognition", detail: off ?? voiceGoes(one),
                          help: DictationSpeedText.withMeasured(S("speech.purpose.recognition.detail"), model: d.asr?.selected),
                          icon: "waveform") {
            ModelPopUp(label: S("speech.purpose.recognition"), current: one.id, missing: purposeValue(.note),
                       choices: here.map { ($0.id, $0.title) }, more: { library = true }, compare: { compare = true },
                       auto: autoCheck(m.auto && d.asrAuto) { m.useEverywhere(one) }) { id in
                if let x = m.model(id) { m.useEverywhere(x) }
            }
        }
        .disabled(off != nil)
    }

    /// What a purpose runs on: the model's name once it is on this Mac; "· downloading" while it comes down, "none
    /// yet" before — never a model that isn't there as if it were in use.
    /// `whole`: inside a sentence (the row's detail), the name kept whole on its line (ModelBundle.unbreakable).
    func purposeValue(_ p: ASRPurpose, whole: Bool = false) -> String {
        guard let x = m.selected(p) else { return S("speech.purpose.none_yet") }
        let name = whole ? ModelBundle.unbreakable(x.title) : x.title
        if x.installed || !x.local { return name }
        return dl.queue.contains(x.id) ? S("speech.purpose.downloading", name) : S("speech.purpose.none_yet")
    }

    /// Installed models that run here (cloud ones when a key is set and local-only is off).
    func choices(_ p: ASRPurpose) -> [ASRModel] {
        var out = m.models.filter { $0.installed && ($0.runsHere ?? true) && ($0.local || !m.localOnly) }
        if let cur = m.selected(p), !out.contains(cur) { out.insert(cur, at: 0) }
        return out
    }

    @ViewBuilder var dictationRow: some View {
        SettingRow("speech.dictation", detail: unused(.dictation),
                   help: DictationSpeedText.withMeasured(S("speech.purpose.dictation.detail"), model: d.asr?.selected),
                   icon: "character.cursor.ibeam") {
            if let a = d.asr {
                // a model whose own files are in can be chosen (its setup then fetches only the VAD); one not here yet
                // is "None" or "… · downloading", never named as if in use
                let ready = a.selectedInstalled ?? d.selectedASR?.installed ?? false
                let here = a.models.filter { $0.installed || $0.files == true || ($0.id == a.selected && ready) }
                ModelPopUp(label: S("speech.purpose.dictation"), current: a.selected, missing: dictationValue(a),
                           choices: here.map { ($0.id, $0.name ?? d.asrName($0.id)) },
                           more: { library = true }, compare: { compare = true },
                           auto: autoCheck(m.auto && d.asrAuto) {
                               if let x = a.models.first(where: { $0.id == a.selected }) { d.chooseASR(x) }
                           }) { id in
                    if let x = a.models.first(where: { $0.id == id }) { d.chooseASR(x) }
                }
            } else {
                BrandSpinnerView(size: 12)
            }
        }
        .disabled(unused(.dictation) != nil)
    }

    func dictationValue(_ a: DictationASRState, whole: Bool = false) -> String {
        let w: (String) -> String = { whole ? ModelBundle.unbreakable($0) : $0 }
        if a.selectedInstalled ?? d.selectedASR?.installed ?? false { return w(d.asrName(a.selected)) }
        if let j = d.queuedJob { return S("speech.purpose.downloading", w(j.name)) }
        return S("speech.purpose.none_yet")
    }

    /// All models: how many are on this Mac (a count, not a size — Storage measures the disk), and the library (the
    /// catalogue's "speech.models" is the library itself, which a search opens).
    var libraryRow: some View {
        let here = m.models.filter { $0.local && $0.installed }.count + (d.polish?.models.filter(\.installed).count ?? 0)
        // a settings row like the download above it (no glyph: one box never mixes the two, system.md §3.4)
        return SettingsLine(flashID: "speech.library") {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(S("speech.section.models")).font(.system(size: SettingsMetrics.titleSize))
                        .help(S("speech.manage.detail.none"))
                        .gridProbe(.text, "all models")
                    Text(here > 0 ? S("speech.manage.count", Loc.number(here)) : S("speech.manage.detail.none"))
                        .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(S("speech.manage.button")) { library = true }.gridProbe(.trailing, "all models")
            }
        }
    }

    // MARK: Languages

    @ViewBuilder var languagesSection: some View {
        SettingsGroup("speech.languages",
                      footer: S(m.state?.languagesSet == true ? "speech.languages.footer" : "speech.languages.footer.system")) {
            SettingsLine {
                HStack(alignment: .top, spacing: 0) {
                    FlowLayout(spacing: 6) {
                        ForEach(m.languages, id: \.self) { code in
                            LanguageChip(title: endonym(code), help: languageName(code), removable: m.languages.count > 1) {
                                m.setLanguages(m.languages.filter { $0 != code })
                            }
                        }
                        Menu {
                            ForEach(offeredLanguages.filter { !m.languages.contains($0) }, id: \.self) { code in
                                Button(endonym(code) + (endonym(code) == languageName(code) ? "" : " — " + languageName(code))) {
                                    m.setLanguages(m.languages + [code])
                                }
                            }
                        } label: {
                            Label(S("speech.languages.add"), systemImage: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .frame(height: LanguageChip.height)
                    }
                }
            }
            // macOS's recogniser hears one language, no detection: "Automatic" says which one it is
            let apple = AppleSpeech.forDictation
            let system = apple ? AppleSpeech.code(AppleSpeech.automatic) : nil
            let now = apple ? AppleSpeech.code(AppleSpeech.locale()) : nil
            SettingRow("speech.language", detail: now.map { S(AppleSpeech.mixed.contains($0) ? "speech.language.system" : "speech.language.system.one", endonym($0)) }) {
                let langs = m.languages + (m.language != "auto" && !m.languages.contains(m.language) ? [m.language] : [])
                ChoicePopup(label: S("speech.advanced.language"),
                            choices: [("auto", system.map { S("speech.advanced.language.auto.system", endonym($0)) } ?? S("speech.advanced.language.auto"))]
                                + langs.map { ($0, endonym($0)) },
                            selection: Binding(get: { m.language }, set: { m.setLanguage($0) }), dividers: [1])
            }
        }
    }

    // MARK: Advanced

    /// Advanced: folded at the page's foot (system.md §3.4). Open, this Mac's limits in one box with the footnote that
    /// explains them right under it; then Cloud recognition and the download mirror, each only where it applies.
    @ViewBuilder var advancedSection: some View {
        SettingsGroup("speech.advanced", footer: m.state == nil ? nil : S("speech.limits.footer"), disclosure: $advanced) {
            resourceRows
        }
        if advanced {
            if let id = cloudRecognizer {
                SettingsGroup { cloudOptionsRow(id) }
            }
            if showMirror {
                SettingsGroup {
                    SettingToggle("speech.mirror", isOn: Binding(get: { m.mirror }, set: { m.setMirror($0) }))
                }
            }
        }
    }

    @ViewBuilder var resourceRows: some View {
        if let s = m.state {
            let cores = max(1, s.hardware.perfCores + s.hardware.effCores)
            SettingRow("speech.threads", detail: S("speech.limits.threads.detail", decimal(Double(cores)))) {
                ChoicePopup(label: S("speech.limits.threads"), choices: (1...cores).map { ($0, decimal(Double($0))) },
                            selection: Binding(get: { min(max(1, s.limits.threads), cores) }, set: { m.setLimit("threads", $0) }))
            }
            SettingRow("speech.concurrent") {
                ChoicePopup(label: S("speech.limits.concurrent"), choices: (1...4).map { ($0, decimal(Double($0))) },
                            selection: Binding(get: { min(max(1, s.limits.maxConcurrent), 4) }, set: { m.setLimit("max_concurrent", $0) }))
            }
            if s.hardware.gpu.kind == "apple" {
                // the share of memory as what it means: "Up to 32 GB" (10–50 %, in 5 % steps)
                // typed apart: inline, the compiler gives up type-checking the call
                let memory: [(Int, String)] = stride(from: 10, through: 50, by: 5).map { (pct: Int) -> (Int, String) in
                    (pct, S("speech.limits.memory.value", mb(s.hardware.ramGB * 1024 * Double(pct) / 100)))
                }
                SettingRow("speech.memory") {
                    ChoicePopup(label: S("speech.limits.memory"),
                                choices: memory,
                                selection: Binding(get: { Int((s.limits.maxMemoryFraction * 20).rounded()) * 5 },
                                                   set: { m.setLimit("max_memory_fraction", Double($0) / 100) }))
                }
            }
            SettingToggle("speech.battery", isOn: Binding(get: { m.onBattery == "lighter" }, set: { m.setOnBattery($0) }))
        } else {
            // the limits come with the models' read: a quiet line while it runs (a failed read says why at the top)
            SettingsLine {
                HStack(spacing: 8) {
                    if m.loading { BrandSpinnerView(size: 10) }
                    Text(S("speech.loading")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The mirror's row only where it means something: mainland China (where it is on by itself), a setting made by
    /// hand either way, a download that failed, or a search that asked for it — never an unexplained domain elsewhere.
    var showMirror: Bool {
        mirrorAsked || Config.shared["asr.hf_mirror"] != nil || !dl.failed.isEmpty
            || ModelBundle.mirror(setting: nil, region: Locale.current.region?.identifier, timeZone: TimeZone.current.identifier)
    }

    /// The cloud recogniser whose options Cloud recognition opens: Model Studio's (it has a model to pick) before the
    /// OpenAI-compatible one, then Volcengine (the speed alone) — nil while none has a key, or Privacy keeps speech here.
    var cloudRecognizer: String? {
        guard !m.localOnly else { return nil }
        let ready = Set(m.models.filter { !$0.local && $0.installed }.map(\.backend))
        if ready.contains("dashscope") { return CloudSpeech.dashScopeModel }
        if ready.contains("openai") { return CloudSpeech.openAIModel }
        if ready.contains("volcengine") { return VolcengineSpeech.modelID }
        return nil
    }

    /// Cloud recognition: the model it runs and how fast its audio is sent ("Qwen3-ASR Flash · Normal speed"), and
    /// Options… — the sheet with the model and the speed (the key stays in Cloud services).
    func cloudOptionsRow(_ id: String) -> some View {
        let speed = S("speech.cloud.options.speed.\(CloudSpeech.speedKey(CloudSpeech.speed))")
        let model: String? = id == CloudSpeech.dashScopeModel ? CloudSpeech.dashScopeTitle
            : id == CloudSpeech.openAIModel ? CloudSpeech.setup.effectiveModel : nil
        return SettingRow("speech.cloud", detail: model.map { S("speech.cloud.options.detail", $0, speed) } ?? speed) {
            Button(S("speech.cloud.options.button")) { cloudOptions = id }
        }
        .sheet(item: Binding(get: { cloudOptions.map(SheetID.init) }, set: { cloudOptions = $0?.id })) { s in
            CloudSpeechSheet(modelID: s.id, title: S("speech.cloud.title"), options: true) { saved in
                cloudOptions = nil
                if saved { Task { await m.load() } }
            }
            .buttonStyle(.automatic)
        }
    }
}

/// A sheet's subject by its id (`.sheet(item:)` needs an Identifiable).
struct SheetID: Identifiable { let id: String }

// MARK: - Pieces

/// A job's model while it is chosen automatically: its name, quiet, one line in the control column ("Auto" is said
/// once, on Choose automatically).
private struct ModelName: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: SettingsMetrics.titleSize)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: SettingsMetrics.controlWidth, alignment: .trailing)
            .help(text)
    }
}

/// A job's model: the page's pop-up (one width) showing the model the job runs on — automatic or picked — then the
/// other models on this Mac, Get More Models… (the library) and, last, Choose Automatically as a check item (system.md
/// §3.4: no "Automatic" value; the pop-up says what is in use). `missing`: what it says while the job's model isn't
/// here ("None", "… · downloading").
private struct ModelPopUp: View {
    var label: String
    var current: String?
    var missing: String
    var choices: [(id: String, name: String)]
    var more: () -> Void
    /// dictation's pop-ups: Compare Choices… after Get More Models…
    var compare: (() -> Void)? = nil
    var auto: SettingMenuToggle
    var pick: (String) -> Void
    var body: some View {
        var items: [(value: String, title: String)] = []
        if current == nil || !choices.contains(where: { $0.id == current }) { items.append((current ?? "", missing)) }
        items += choices.map { ($0.id, $0.name) }
        let split = items.count
        items.append((moreModels, S("speech.purpose.more")))
        if compare != nil { items.append((compareChoices, S("speech.compare.menu"))) }
        return ChoicePopup(label: label, choices: items,
                           selection: Binding(get: { current ?? "" }, set: { id in
                               if id == moreModels { DispatchQueue.main.async(execute: more) }
                               else if id == compareChoices, let c = compare { DispatchQueue.main.async(execute: c) }
                               else if id != current && !id.isEmpty { pick(id) }
                           }), checks: [auto], dividers: [split])
    }
}

// MARK: - The library (a sheet)

private struct ModelLibrary: View {
    var close: () -> Void
    @ObservedObject var m = SpeechModel.shared
    @ObservedObject var d = DictationModels.shared
    @ObservedObject private var dl = ModelDownloads.shared
    @State private var tab = ProcessInfo.processInfo.environment["BLURT_TEST_SPEECH_TAB"] == "polish" ? Tab.polish : .asr
    @State private var hover: String? = ProcessInfo.processInfo.environment["BLURT_TEST_SPEECH_HOVER"]
    @State private var confirmRemove: ASRModel?
    /// the rest of the catalogue, folded under "More models" (v1.0.6: a dozen rows nobody could tell apart)
    @State private var more = ProcessInfo.processInfo.environment["BLURT_TEST_SPEECH_MORE"] != nil
    enum Tab: Hashable { case asr, polish }

    /// fixed columns, so numbers line up from row to row (right-aligned, tabular digits)
    enum Col {
        static let used: CGFloat = 220, speed: CGFloat = 46, memory: CGFloat = 62, size: CGFloat = 62
        static let action: CGFloat = 86, gap: CGFloat = 10
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text(S("speech.section.models")).font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                if d.polish?.supported == true {
                    Picker(S("speech.section.models"), selection: $tab) {
                        Text(S("speech.lib.recognition")).tag(Tab.asr)
                        Text(S("speech.purpose.polish")).tag(Tab.polish)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            note.padding(.top, 6).fixedSize(horizontal: false, vertical: true)
            // a dozen rows at most: the sheet grows to fit them instead of scrolling. Open, no box: the table shares the
            // title's and Done's edges
            SettingsGroup("speech.models", title: "", boxed: false) {
                header
                if tab == .asr {
                    ForEach(asrModels.filter(shown)) { asrRow($0) }
                    let rest = asrModels.filter { !shown($0) }
                    if !rest.isEmpty { moreToggle(rest.count); if more { ForEach(rest) { asrRow($0) } } }
                } else {
                    ForEach(polishModels.filter(shown)) { polishRow($0) }
                    let rest = polishModels.filter { !shown($0) }
                    if !rest.isEmpty { moreToggle(rest.count); if more { ForEach(rest) { polishRow($0) } } }
                }
            }
            .padding(.top, 16 - SettingsMetrics.groupGap)
            HStack(alignment: .center) {
                if tab == .asr && m.models.contains(where: { $0.local && !($0.runsHere ?? true) }) {
                    Text(S("speech.models.elsewhere")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(S("speech.lib.done"), action: close)
                    .buttonStyle(.borderedProminent).tint(Color.settingsDefault)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 18)
        // 740 pt, as Dictation Choices: inside the Settings window at its 760 pt minimum
        .frame(width: 740)
        .fixedSize(horizontal: false, vertical: true)
        // screenshots of a test build in the background: drawn as the key sheet people see, Done filled
        .modifier(TestKeyLook(on: SettingsTestKeyLook.on))
        .alert(S("speech.remove.title"), isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button(S("speech.remove.confirm"), role: .destructive) { if let r = confirmRemove { m.remove(r) }; confirmRemove = nil }
            Button(S("speech.cancel"), role: .cancel) { confirmRemove = nil }
        } message: {
            // the model by its name and size — never its folder's path (the Storage pane's rows say the same)
            Text(confirmRemove.map { S("speech.remove.message", $0.title, modelSize($0.sizeMB)) } ?? "")
        }
    }

    /// "Accuracy is for Chinese and English, from a reference test on Apple M5 Max." (+ the seal, once something is
    /// measured here); the polish tab says what polish does.
    var note: some View {
        var t = Text(tab == .polish ? S("speech.purpose.polish.detail") : S("speech.lib.note2"))
        if tab == .asr && m.models.contains(where: { $0.bench != nil }) {
            t = t + Text("  ") + Text(Image(systemName: "checkmark.seal.fill")).foregroundColor(Color.brandOk)
                + Text(" " + S("speech.lib.note.measured"))
        }
        return t.font(.system(size: SettingsMetrics.detailSize)).foregroundColor(.secondary)
    }

    // rows: in use first, then the rest on this Mac, then the others (the catalogue's order within each)

    var asrModels: [ASRModel] {
        let here = m.models.filter { $0.local && ($0.runsHere ?? true) }
        return here.enumerated().sorted { a, b in
            let ra = rank(installed: a.element.installed, used: !usedFor(a.element).isEmpty)
            let rb = rank(installed: b.element.installed, used: !usedFor(b.element).isEmpty)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }
    var polishModels: [PolishModel] {
        (d.polish?.models ?? []).enumerated().sorted { a, b in
            let ra = rank(installed: a.element.installed, used: d.polish?.selected == a.element.id)
            let rb = rank(installed: b.element.installed, used: d.polish?.selected == b.element.id)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }
    func rank(installed: Bool, used: Bool) -> Int { used ? 0 : installed ? 1 : 2 }

    // MARK: what each model is for, and which are folded

    /// Recommended for this Mac: dictation's pick, or any job's.
    func recommended(_ x: ASRModel) -> Bool {
        x.id == d.asr?.recommended || ASRPurpose.allCases.contains { m.recommended($0)?.id == x.id }
    }
    /// Shown without "More models": in use, on this Mac, recommended, built in, or downloading.
    func shown(_ x: ASRModel) -> Bool {
        x.installed || !usedFor(x).isEmpty || recommended(x) || x.id == "apple-speech" || m.download(x.id) != nil
    }
    func shown(_ x: PolishModel) -> Bool {
        x.installed || d.polish?.selected == x.id || d.polish?.recommended == x.id || m.download(x.id) != nil
    }
    /// The line in the For column: "Recommended · …", then what the model is good at (speech.tag.<id>), from the
    /// measurements in docs/design/first-minute-speech.md and dictation.md.
    func tag(id: String, recommended rec: Bool, tiers: [String]? = nil) -> String {
        var parts: [String] = []
        if rec { parts.append(S("speech.tag.recommended")) }
        if Loc.has("speech.tag.\(id)", table: "Speech") { parts.append(S("speech.tag.\(id)")) }
        else if let t = tiers, !t.contains("pro"), !t.contains("standard") { parts.append(S("speech.tag.small_mac")) }
        return parts.joined(separator: " · ")
    }

    func moreToggle(_ n: Int) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { more.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(more ? 90 : 0))
                Text(S("speech.lib.more", n)).font(.system(size: SettingsMetrics.detailSize))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
        .accessibilityLabel(S("speech.lib.more", n))
    }

    /// The jobs a model on this Mac does, as the page's rows show them (their icon and title): its purposes, and
    /// dictation when it is dictation's.
    func usedFor(_ x: ASRModel) -> [Job] {
        guard x.installed else { return [] }
        var out = (x.purposes ?? []).compactMap(ASRPurpose.init(rawValue:)).map { Job(symbol: $0.symbol, title: $0.title) }
        if let a = d.asr, a.selected == x.id, a.selectedInstalled ?? true { out.append(Job.dictation) }
        return out
    }

    /// What the Used for column says: the jobs' icons (the same as the page's rows; their names in the tooltip and
    /// to VoiceOver), or a line about the model's download or measurement.
    struct Used {
        var text = ""
        var err = false
        var jobs: [Job] = []
        /// the model's own line (what it is good for), not news about it
        var tag = false
    }
    struct Job: Hashable {
        var symbol: String
        var title: String
        static var dictation: Job { Job(symbol: "character.cursor.ibeam", title: S("speech.purpose.dictation")) }
        static var polish: Job { Job(symbol: "wand.and.stars", title: S("speech.purpose.polish")) }
    }

    var header: some View {
        HStack(spacing: Col.gap) {
            headerCell(S("speech.lib.col.model"), width: nil, trailing: false)
            headerCell(S("speech.lib.col.used"), width: Col.used, trailing: false)
            if tab == .asr {
                headerCell(S("speech.metric.speed"), width: Col.speed, seal: true, help: S("speech.metric.speed.help"))
            }
            headerCell(S("speech.metric.memory"), width: Col.memory, seal: tab == .asr, help: S("speech.metric.memory.help"))
            headerCell(S("speech.metric.size"), width: Col.size)
            Color.clear.frame(width: Col.action)
        }
        .padding(.bottom, 5)
    }

    /// `seal`: the column's numbers keep a slot for the seal after them — the heading sits over the number.
    func headerCell(_ t: String, width: CGFloat?, trailing: Bool = true, seal: Bool = false, help: String = "") -> some View {
        Text(t).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            .padding(.trailing, seal ? 11 : 0)
            .frame(maxWidth: width ?? .infinity, alignment: trailing ? .trailing : .leading)
            .frame(width: width)
            .help(help)
    }

    // MARK: recognition rows

    func asrRow(_ x: ASRModel) -> some View {
        let uses = usedFor(x)
        let picked = (x.purposes ?? []).compactMap(ASRPurpose.init(rawValue:))
        let speed = m.speed(x), memory = m.memory(x)
        let dash = x.installed ? S("speech.lib.dash.installed") : S("speech.lib.dash")
        var used = Used()
        if let p = m.download(x.id) { used.text = p.text }
        else if m.failed(x.id) != nil { used = Used(text: S(ModelDownloads.shared.failed[x.id] == "disk_full" ? "speech.download.no_space" : "speech.download.failed.short"), err: true) }
        else if m.benching.contains(x.id) { used.text = S("speech.bench.running") }
        else if m.bench[x.id]?.error != nil { used = Used(text: S("speech.bench.failed"), err: true) }
        else if !uses.isEmpty { used.jobs = uses }
        else if !x.installed, !picked.isEmpty {
            used.text = S("speech.model.picked_not_in", Loc.list(picked.map { $0.title.lowercased(with: Loc.locale) }))
        } else if !m.missing(x).isEmpty { used.text = S("speech.lib.missing", Loc.list(m.missing(x).map(languageName))) }
        else { used.text = tag(id: x.id, recommended: recommended(x)); used.tag = true }
        return row(id: x.id, installed: x.installed, name: x.title, help: describe(x), used: used, inUse: !uses.isEmpty) {
            MetricCell(text: speed.map { S("speech.metric.speed.value", decimal($0.value)) }, measured: speed?.measured == true,
                       width: Col.speed, dash: dash)
            // macOS Speech: built in, nothing to download and no model of ours in memory — never "0 MB"
            MetricCell(text: memory.flatMap { $0.value > 0 ? modelSize($0.value) : nil }, measured: memory?.measured == true,
                       width: Col.memory, dash: x.sizeMB > 0 ? dash : S("speech.compare.builtin"))
            MetricCell(text: x.sizeMB > 0 ? modelSize(x.sizeMB) : S("speech.compare.builtin"), measured: false, width: Col.size,
                       dash: "", seal: false)
        } action: {
            if m.download(x.id) != nil {
                stopButton(x.id)
            } else if m.benching.contains(x.id) {
                BrandSpinnerView(size: 12)
            } else if !x.installed {
                // a model not on this Mac shows its Download at rest: the one way to tell it from one that is
                Button(S("speech.download.button")) { m.startDownload(x) }.controlSize(.small)
            } else if hover == x.id {
                HStack(spacing: 6) {
                    if uses.count < everyJob { useButton { m.useEverywhere(x) } }
                    Menu { asrActions(x, inUse: !uses.isEmpty) } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel(S("speech.lib.actions", x.title))
                }
            }
        } menu: {
            if x.installed && uses.count < everyJob { Button(S("speech.lib.use")) { m.useEverywhere(x) }; Divider() }
            if x.installed { asrActions(x, inUse: !uses.isEmpty) }
            else if m.download(x.id) == nil { Button(S("speech.download.button")) { m.startDownload(x) } }
        }
    }

    @ViewBuilder func asrActions(_ x: ASRModel, inUse: Bool) -> some View {
        Button(S("speech.bench.button")) { Task { await m.runBench(x) } }.help(S("speech.bench.help"))
        if let p = x.path {
            Button(T("action.reveal_in_finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
        }
        if m.canRemove(x) && !inUse {
            Divider()
            Button(S("speech.remove.menu"), role: .destructive) { confirmRemove = x }
        }
    }

    /// The row's tooltip: what the model is good at, and the languages it doesn't understand.
    func describe(_ x: ASRModel) -> String {
        let miss = m.missing(x)
        return sentences([x.qualityNoteKey.map { S($0) } ?? "",
                          miss.isEmpty ? "" : S("speech.coverage.missing", Loc.list(miss.map(languageName)))])
    }

    // MARK: polish rows

    func polishRow(_ x: PolishModel) -> some View {
        let inUse = d.polish?.selected == x.id
        var used = Used()
        if let p = m.download(x.id) { used.text = p.text }
        else if m.failed(x.id) != nil { used = Used(text: S(ModelDownloads.shared.failed[x.id] == "disk_full" ? "speech.download.no_space" : "speech.download.failed.short"), err: true) }
        else if inUse { used.jobs = [Job.polish] }
        else { used.text = tag(id: x.id, recommended: d.polish?.recommended == x.id); used.tag = true }
        return row(id: x.id, installed: x.installed, name: x.name, help: "", used: used, inUse: inUse) {
            MetricCell(text: x.ramMB.map(modelSize), measured: false, width: Col.memory, dash: S("speech.lib.dash"), seal: false)
            MetricCell(text: modelSize(x.sizeMB), measured: false, width: Col.size, dash: "", seal: false)
        } action: {
            if m.download(x.id) != nil {
                stopButton(x.id)
            } else if !x.installed {
                Button(S("speech.download.button")) { d.download(x) }.controlSize(.small)
            } else if hover == x.id && !inUse {
                useButton { d.choose(x) }
            }
        } menu: {
            if x.installed && !inUse { Button(S("speech.lib.use_polish")) { d.choose(x) } }
            else if !x.installed && m.download(x.id) == nil { Button(S("speech.download.button")) { d.download(x) } }
        }
    }

    // MARK: one row

    /// recordings, live captions, voice notes and dictation
    var everyJob: Int { ASRPurpose.allCases.count + 1 }

    /// Use: an installed model takes over its tab's jobs (every recognition job / dictation polish).
    func useButton(_ action: @escaping () -> Void) -> some View {
        Button(S("speech.lib.use"), action: action).controlSize(.small).help(tab == .asr ? S("speech.lib.use.help") : S("speech.lib.use_polish"))
    }

    func stopButton(_ id: String) -> some View {
        HStack(spacing: 6) {
            if let p = m.download(id) {
                ProgressView(value: min(p.done, p.total), total: max(p.total, 1)).controlSize(.small).frame(width: 56)
            }
            Button { dl.stop(id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless).help(S("speech.download.stop")).accessibilityLabel(S("speech.download.stop"))
        }
    }

    func row<Metrics: View, Action: View, Items: View>(id: String, installed: Bool, name: String, help: String,
                                                         used: Used, inUse: Bool,
                                                         @ViewBuilder metrics: () -> Metrics, @ViewBuilder action: () -> Action,
                                                         @ViewBuilder menu: () -> Items) -> some View {
        SettingsLine(padding: 5) {
            HStack(spacing: Col.gap) {
                // no install mark of its own: a model not on this Mac shows Download at rest, one in use says so in About
                // (a leading ✓ read as "measured", the seal's meaning)
                // a long name ("Whisper large-v3-turbo (4-bit)") wraps rather than losing its end; the tooltip names it too
                Text(name).font(.system(size: SettingsMetrics.titleSize)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(help.isEmpty ? name : name + "\n" + help)
                Group {
                    if used.jobs.isEmpty {
                        // two lines rather than a cut ("Recommended · A little better at Eng…")
                        Text(used.text).font(.system(size: SettingsMetrics.detailSize)).monospacedDigit()
                            .foregroundStyle(used.err ? AnyShapeStyle(Color.brandErr) : AnyShapeStyle(.secondary))
                            .lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                            .help(used.text)
                    } else {
                        // in words, not icons (v1.0.6: nobody could read the icon row): "In use: dictation, voice notes"
                        let names = Loc.list(used.jobs.enumerated().map { i, j in i == 0 ? j.title : j.title.lowercased(with: Loc.locale) })
                        // the check in brand ink, the words in neutral ink (brand ink is a link's colour)
                        (Text(Image(systemName: "checkmark")).foregroundColor(Color.brandInk)
                            + Text(" " + S("speech.lib.in_use", names)).foregroundColor(.primary))
                            .font(.system(size: SettingsMetrics.detailSize))
                            .lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                            .help(S("speech.lib.in_use", names))
                    }
                }
                .frame(width: Col.used, alignment: .leading)
                metrics()
                HStack(spacing: 0) { Spacer(minLength: 0); action() }.frame(width: Col.action, height: 22)
            }
            .frame(minHeight: 22)
            .contentShape(Rectangle())
            .onHover { h in if h { hover = id } else if hover == id { hover = nil } }
            .contextMenu { menu() }
            .accessibilityElement(children: .contain)
        }
    }
}

/// A number in the library's table: right-aligned tabular digits, the seal in its own slot after it when measured
/// here; "—" with a tooltip that says why there is no number.
private struct MetricCell: View {
    var text: String?
    var measured: Bool
    var width: CGFloat
    var dash: String
    var seal = true
    var body: some View {
        HStack(spacing: 2) {
            Text(text ?? "—").font(.system(size: SettingsMetrics.detailSize)).monospacedDigit()
                .foregroundStyle(text == nil ? .secondary : .primary).lineLimit(1)
            if seal {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 9)).foregroundStyle(Color.brandOk)
                    .frame(width: 9).opacity(measured ? 1 : 0)
                    .accessibilityHidden(!measured).accessibilityLabel(S("speech.metric.measured"))
            }
        }
        .frame(width: width, alignment: .trailing)
        .help(text == nil ? dash : measured ? S("speech.metric.measured") : "")
    }
}

/// A language you speak: its name in itself, × to remove it (not the last one). Chips and the Add menu share one
/// height, so they sit on one baseline.
private struct LanguageChip: View {
    static let height: CGFloat = 22
    var title: String
    var help: String
    var removable: Bool
    var remove: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 12))
            if removable {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(hover ? .primary : .secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(S("speech.languages.remove", title))
            }
        }
        .padding(.leading, 9).padding(.trailing, removable ? 6 : 9)
        .frame(height: LanguageChip.height)
        .background(Capsule().fill(Color.secondary.opacity(hover ? 0.18 : 0.11)))
        .onHover { hover = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// Left-to-right wrapping layout for the language chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += line + spacing; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

