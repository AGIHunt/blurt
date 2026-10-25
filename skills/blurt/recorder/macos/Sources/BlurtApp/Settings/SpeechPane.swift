// Settings → Speech (K9; SettingsKit rows, titles and descriptions from SettingsCatalog), built around one question:
// which model does each job, and is the recommended set on this Mac? (docs/design/system.md §3.4)
//
//   subtitle   the Mac under the page's title ("Apple M5 Max · 128 GB memory · 40-core GPU"): what the choice is for
//   Models     at most one recommendation, only while something recommended is missing (`transcribe.py models` for
//              recordings / live captions / voice notes, `dictation-models` + `polish.py models` for dictation): what
//              it is for and its size, the page's one primary Download and a "…" menu for one model at a time; while
//              anything downloads it becomes that download's bar and Stop. Then Choose automatically (asr.auto, and
//              dictation's two models unpinned: DictationModels.setAuto) and one row per job — Recordings, Live
//              captions, Voice notes, Dictation, Dictation polish —, each with its model on the right: the name and
//              "Auto" while automatic, a native pop-up of the models on this Mac (and Get More Models…) otherwise. A
//              job whose model isn't on this Mac says "· downloading" or "None yet", never names it as if in use.
//              Last, All models: Manage Models… opens the library.
//   Languages  the languages you speak (chips) and the recognition language (detect, or always one).
//   Advanced   folded (a search or a link unfolds it): processor threads, transcriptions at a time and GPU memory as
//              pop-ups, lighter models on battery, the download mirror, one row per cloud service with whether its key
//              is found (never stored or shown; the variables' names and the export line in an info popover).
//   library    a sheet (ModelLibrary): one 32 pt row per model that runs here, recognition or polish — what it is
//              used for, accuracy for your languages, speed, memory, size as a table; numbers measured on this Mac
//              (`transcribe.py bench`) carry the seal; Download on hover, Measure / Show in Finder / Move to Trash in
//              the row's "…" menu (and its context menu). Move to Trash asks by the model's name and size.
// Every download goes through the app's one download manager (App/ModelDownloads.swift).
// Test hooks (BLURT_TEST_COMMANDS): `settings speech/speech.models` opens the library, `settings speech/speech.threads`
// unfolds Advanced; BLURT_TEST_SPEECH_HOVER=ID shows a library row as hovered, BLURT_TEST_SPEECH_TAB=polish its tab.
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
    func failed(_ id: String) -> String? { ModelDownloads.shared.failed[id] == nil ? nil : S("speech.download.failed") }

    func model(_ id: String?) -> ASRModel? { id.flatMap { i in models.first { $0.id == i } } }
    func selected(_ p: ASRPurpose) -> ASRModel? { model(state?.selected[p.rawValue] ?? nil) }
    func recommended(_ p: ASRPurpose) -> ASRModel? { model(state?.recommended[p.rawValue]) }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await SkillCLI.shared.run("transcribe.py", ["models"], timeout: 180)
            guard r.ok, let s = r.decode(ASRState.self) else { error = S("speech.error.read"); return }
            // a finished download: the suggestion folds away and the jobs show their new model
            let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || state == nil
            withAnimation(calm ? nil : .easeInOut(duration: 0.25)) {
                state = s
                models = s.models.filter { $0.role == "asr" }  // not the VAD every local model uses
            }
            error = nil
        } catch { self.error = S("speech.error.read") }
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

    func setLanguages(_ l: [String]) {
        Config.shared.set("asr.languages", l.isEmpty ? nil : l)
        if language != "auto", !l.contains(language) { setLanguage("auto") }
        Task { await reapply() }
    }

    func setLanguage(_ l: String) { language = l; Config.shared.set("asr.language", l == "auto" ? nil : l) }
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
private func endonym(_ code: String) -> String {
    let l = Locale(identifier: code)
    let n = l.localizedString(forLanguageCode: code) ?? code
    return n.prefix(1).uppercased(with: l) + n.dropFirst()
}

/// Languages offered in the picker: the ones the bundled models have been measured on first, then the rest of what
/// the multilingual models understand.
private let offeredLanguages = ["en", "zh", "yue", "ja", "ko", "es", "fr", "de", "it", "pt", "ru", "ar", "hi", "vi", "th",
                                "id", "ms", "tr", "nl", "pl", "sv", "da", "fi", "cs", "el", "hu", "ro", "uk", "fa", "fil"]

/// The pop-ups' last item: opens the library instead of choosing.
private let moreModels = "__more"

// MARK: - Pane

struct SpeechPane: View {
    @ObservedObject var m = SpeechModel.shared
    @ObservedObject var d = DictationModels.shared
    @ObservedObject private var dl = ModelDownloads.shared
    @State private var library = false
    @State private var advanced = false

    /// Settings → Speech at dictation's row, just under the recommendation and its download bar (Settings →
    /// Dictation's "Change…" / "Download…", the dictation key's "no model yet").
    @MainActor static func showDictationModels() {
        AppEnvironment.settings?.show(pane: "speech/dictation")
    }

    var body: some View {
        SettingsPage(.speech, subtitle: machineLine) {
            useSection
            languagesSection
            advancedSection
        }
        .task { await m.load() }
        .task { await d.load() }
        .sheet(isPresented: $library) { ModelLibrary { library = false } }
        // a search or a link landing on the library or on a row folded under Advanced: open / unfold it first
        .onReceive(SettingsFlash.shared.$request) { r in
            guard let id = r?.id else { return }
            if id == "speech.models" { library = true }
            if id == "speech.more" || SettingsCatalog.entry(id)?.fold == "speech.more" { advanced = true }
        }
    }

    // MARK: the Mac

    /// "Apple M5 Max · 128 GB memory · 40-core GPU" under the page's title ("Checking this Mac…" while it is read).
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

    @ViewBuilder var useSection: some View {
        SettingsGroup("speech.use", content: {
            if let e = m.error {
                SettingsLine {
                    HStack(spacing: SettingsMetrics.iconGap) {
                        SettingsIcon("exclamationmark.triangle")
                        Text(e).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandErr)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            recommendation
            SettingToggle("speech.auto", isOn: Binding(get: { m.auto }, set: { on in d.setAuto(on); m.setAuto(on) }),
                          icon: "laptopcomputer")
            ForEach(ASRPurpose.allCases) { p in purposeRow(p) }
            dictationRow
            polishRow
            libraryRow
        }, accessory: {
            if (m.loading && m.state != nil) { BrandSpinnerView(size: 10) }
        })
    }

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
            for p in ASRPurpose.allCases {
                guard let r = m.recommended(p), !r.installed, r.local, r.runsHere ?? true else { continue }
                add(.init(id: r.id, kind: .note, name: r.title, sizeMB: r.sizeMB), p.title)
            }
        }
        let dictation = S("speech.purpose.dictation")
        if let a = d.recommendedASR, !a.installed, a.files != true {
            add(.init(id: a.id, kind: .dictation, name: a.name ?? d.asrName(a.id), sizeMB: a.sizeMB), dictation)
        } else if d.dictationReady == false, let j = d.dictationJob {
            add(j, dictation)              // only the VAD (or the configured model) is missing: what the key needs
        }
        if let p = d.recommendedPolish, !p.installed {
            add(.init(id: p.id, kind: .polish, name: p.name, sizeMB: p.sizeMB), dictation)
        }
        return out
    }

    /// "SenseVoice Small for voice notes · Qwen3-ASR 1.7B (MLX) and Gemma 4 E2B for dictation · 6.1 GB"
    func pickLine(_ ps: [Pick]) -> String {
        var groups: [(uses: String, names: [String])] = []
        for p in ps {
            let uses = Loc.list(p.uses.map { $0.lowercased(with: Loc.locale) })
            // a model's name never breaks over two lines: the line wraps between the parts
            let name = p.job.name.replacingOccurrences(of: " ", with: "\u{00A0}")
            if let i = groups.firstIndex(where: { $0.uses == uses }) { groups[i].names.append(name) }
            else { groups.append((uses, [name])) }
        }
        return (groups.map { S("speech.rec.item", Loc.list($0.names), $0.uses) }
                + [modelSize(ps.reduce(0) { $0 + $1.job.sizeMB }).replacingOccurrences(of: " ", with: "\u{00A0}")])
            .joined(separator: " · ")
    }

    @ViewBuilder var recommendation: some View {
        if dl.active {
            // whatever is downloading (from here, the library, the assistant, the dictation key): one bar, one Stop
            let p = dl.progress
            let now = dl.queue.pending.first { $0.id == dl.current } ?? dl.queue.next
            SettingsLine(flashID: "speech.download") {
                HStack(alignment: .center, spacing: 14) {
                    HStack(alignment: .center, spacing: SettingsMetrics.iconGap) {
                        SettingsIcon("arrow.down.circle")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(S("speech.rec.downloading", now?.name ?? "")).font(.system(size: SettingsMetrics.titleSize)).lineLimit(1)
                            Text(dl.current.map(dl.isUnpacking) == true ? S("speech.download.unpacking")
                                 : p.done == 0 ? S("speech.download.preparing")
                                 : S("speech.download.progress", modelSize(p.done), modelSize(p.total)))
                                .font(.system(size: SettingsMetrics.detailSize)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ProgressView(value: min(p.done, p.total), total: max(p.total, 1)).frame(width: 120)
                        .accessibilityLabel(S("speech.rec.downloading", now?.name ?? ""))
                    Button(S("speech.download.stop")) { dl.stop() }
                }
            }
        } else {
            let ps = picks
            if !ps.isEmpty {
                let failed = ps.contains { dl.failed[$0.job.id] != nil }
                SettingsLine(flashID: "speech.download") {
                    HStack(alignment: .center, spacing: 14) {
                        HStack(alignment: .center, spacing: SettingsMetrics.iconGap) {
                            SettingsIcon("arrow.down.circle")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(S("speech.rec.title")).font(.system(size: SettingsMetrics.titleSize))
                                // every model named whole, on as many lines as the width needs (never cut)
                                Text(pickLine(ps)).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if failed {
                                    Text(S("speech.download.failed")).font(.system(size: SettingsMetrics.detailSize))
                                        .foregroundStyle(Color.brandErr).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 2) {
                            // the page's one primary (system.md §9)
                            Button(failed ? S("speech.rec.retry") : S("speech.download.button")) { get(ps) }
                                .buttonStyle(.brand)
                            if ps.count > 1 {
                                Menu {
                                    ForEach(ps, id: \.job.id) { p in
                                        Button(S("speech.rec.one", p.job.name, modelSize(p.job.sizeMB))) { get([p]) }
                                    }
                                } label: { Image(systemName: "ellipsis") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                .frame(width: 26)
                                .help(S("speech.rec.choose")).accessibilityLabel(S("speech.rec.choose"))
                            }
                        }
                    }
                }
            }
        }
    }

    /// One request for the download manager: nothing is pinned (an automatic choice stays automatic and takes each
    /// model once it is in).
    func get(_ ps: [Pick]) { dl.download(ps.map(\.job), via: "settings") }

    // the jobs

    func purposeRow(_ p: ASRPurpose) -> some View {
        SettingRow("speech.\(p.rawValue)", icon: p.symbol) {
            if m.state == nil {
                BrandSpinnerView(size: 12)
            } else if m.auto {
                AutoValue(text: purposeValue(p))
            } else {
                ModelPopUp(label: p.title, current: m.selected(p)?.id,
                           choices: choices(p).map { ($0.id, $0.title) }, more: { library = true }) { id in
                    if let x = m.model(id) { m.choose(x, for: p) }
                }
            }
        }
    }

    /// What a purpose runs on: the model's name once it is on this Mac; "· downloading" while it comes down, "none
    /// yet" before — never a model that isn't there as if it were in use.
    func purposeValue(_ p: ASRPurpose) -> String {
        guard let x = m.selected(p) else { return S("speech.purpose.none_yet") }
        if x.installed || !x.local { return x.title }
        return dl.queue.contains(x.id) ? S("speech.purpose.downloading", x.title) : S("speech.purpose.none_yet")
    }

    /// Installed models that run here (cloud ones when a key is set and local-only is off).
    func choices(_ p: ASRPurpose) -> [ASRModel] {
        var out = m.models.filter { $0.installed && ($0.runsHere ?? true) && ($0.local || !m.localOnly) }
        if let cur = m.selected(p), !out.contains(cur) { out.insert(cur, at: 0) }
        return out
    }

    @ViewBuilder var dictationRow: some View {
        SettingRow("speech.dictation", icon: "character.cursor.ibeam") {
            if let a = d.asr {
                if m.auto && d.asrAuto {
                    AutoValue(text: dictationValue(a))
                } else {
                    // a model whose own files are in can be chosen (its setup then fetches only the VAD)
                    let here = a.models.filter { $0.installed || $0.files == true || $0.id == a.selected }
                    ModelPopUp(label: S("speech.purpose.dictation"), current: a.selected,
                               choices: here.map { ($0.id, $0.name ?? d.asrName($0.id)) }, more: { library = true }) { id in
                        if let x = a.models.first(where: { $0.id == id }) { d.chooseASR(x) }
                    }
                }
            } else {
                BrandSpinnerView(size: 12)
            }
        }
    }

    func dictationValue(_ a: DictationASRState) -> String {
        if a.selectedInstalled ?? d.selectedASR?.installed ?? false { return d.asrName(a.selected) }
        if let j = d.dictationJob, dl.queue.contains(j.id) { return S("speech.purpose.downloading", j.name) }
        return S("speech.purpose.none_yet")
    }

    @ViewBuilder var polishRow: some View {
        SettingRow("speech.polish", icon: "wand.and.stars") {
            if let p = d.polish {
                if !p.supported {
                    Text(S("speech.purpose.polish.unsupported")).foregroundStyle(.secondary)
                } else if m.auto && d.polishAuto {
                    AutoValue(text: polishValue(p))
                } else {
                    let here = p.models.filter { $0.installed }
                    ModelPopUp(label: S("speech.purpose.polish"), current: p.selected,
                               choices: here.map { ($0.id, $0.name) }, more: { library = true }) { id in
                        if let x = p.models.first(where: { $0.id == id }) { d.choose(x) }
                    }
                }
            } else {
                BrandSpinnerView(size: 12)
            }
        }
    }

    func polishValue(_ p: PolishState) -> String {
        if let s = p.selected { return d.polishName(s) }
        if let r = d.recommendedPolish, dl.queue.contains(r.id) { return S("speech.purpose.downloading", r.name) }
        return S("speech.purpose.none_yet")
    }

    /// All models: what is on this Mac, and the library.
    var libraryRow: some View {
        let mbHere = m.models.filter { $0.local && $0.installed }.reduce(0) { $0 + $1.sizeMB }
            + (d.polish?.models.filter(\.installed).reduce(0) { $0 + $1.sizeMB } ?? 0)
        return SettingsLine(flashID: "speech.library") {
            HStack(alignment: .center, spacing: 14) {
                HStack(alignment: .center, spacing: SettingsMetrics.iconGap) {
                    SettingsIcon("square.stack.3d.up")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(S("speech.section.models")).font(.system(size: SettingsMetrics.titleSize))
                        Text(mbHere > 0 ? S("speech.manage.detail", modelSize(mbHere)) : S("speech.manage.detail.none"))
                            .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(S("speech.manage.button")) { library = true }
            }
        }
    }

    // MARK: Languages

    @ViewBuilder var languagesSection: some View {
        SettingsGroup("speech.languages",
                      footer: S(m.state?.languagesSet == true ? "speech.languages.footer" : "speech.languages.footer.system")) {
            SettingsLine {
                HStack(alignment: .top, spacing: SettingsMetrics.iconGap) {
                    SettingsIcon("globe").frame(height: LanguageChip.height)
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
            SettingRow("speech.language", icon: "ear") {
                let langs = m.languages + (m.language != "auto" && !m.languages.contains(m.language) ? [m.language] : [])
                ChoicePopup(label: S("speech.advanced.language"),
                            choices: [("auto", S("speech.advanced.language.auto"))] + langs.map { ($0, endonym($0)) },
                            selection: Binding(get: { m.language }, set: { m.setLanguage($0) }), dividers: [1])
            }
        }
    }

    // MARK: Advanced (folded)

    @ViewBuilder var advancedSection: some View {
        SettingsGroup("speech.advanced", title: "") {
            SettingRow("speech.more", icon: "slider.horizontal.3") {
                Button {
                    withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.18)) { advanced.toggle() }
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(advanced ? 90 : 0))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(S("speech.more.title"))
                .accessibilityValue(advanced ? "expanded" : "collapsed")
            }
            .contentShape(Rectangle())
            .onTapGesture { advanced.toggle() }
            if advanced {
                resourceRows
                SettingToggle("speech.mirror", isOn: Binding(get: { m.mirror }, set: { m.setMirror($0) }), icon: "network")
                let cloud = m.models.filter { !$0.local }
                ForEach(Array(cloud.enumerated()), id: \.element.id) { i, x in cloudRow(x, first: i == 0) }
            }
        }
    }

    @ViewBuilder var resourceRows: some View {
        if let s = m.state {
            let cores = max(1, s.hardware.perfCores + s.hardware.effCores)
            SettingRow("speech.threads", detail: S("speech.limits.threads.detail", decimal(Double(cores))), icon: "cpu") {
                ChoicePopup(label: S("speech.limits.threads"), choices: (1...cores).map { ($0, decimal(Double($0))) },
                            selection: Binding(get: { min(max(1, s.limits.threads), cores) }, set: { m.setLimit("threads", $0) }))
            }
            SettingRow("speech.concurrent", icon: "square.stack") {
                ChoicePopup(label: S("speech.limits.concurrent"), choices: (1...4).map { ($0, decimal(Double($0))) },
                            selection: Binding(get: { min(max(1, s.limits.maxConcurrent), 4) }, set: { m.setLimit("max_concurrent", $0) }))
            }
            if s.hardware.gpu.kind == "apple" {
                // the share of memory as what it means: "Up to 32 GB" (10–50 %, in 5 % steps)
                SettingRow("speech.memory", icon: "memorychip") {
                    ChoicePopup(label: S("speech.limits.memory"),
                                choices: Array(stride(from: 10, through: 50, by: 5)).map { pct in
                                    (pct, S("speech.limits.memory.value", mb(s.hardware.ramGB * 1024 * Double(pct) / 100)))
                                },
                                selection: Binding(get: { Int((s.limits.maxMemoryFraction * 20).rounded()) * 5 },
                                                   set: { m.setLimit("max_memory_fraction", Double($0) / 100) }))
                }
            }
            SettingToggle("speech.battery", isOn: Binding(get: { m.onBattery == "lighter" }, set: { m.setOnBattery($0) }),
                          icon: "battery.50")
        }
    }

    /// One cloud service: whether its key is found, and how to set one (the variables' names) in a popover.
    @ViewBuilder func cloudRow(_ x: ASRModel, first: Bool) -> some View {
        let title = x.backend == "openai" ? S("speech.cloud.name.openai") : x.title
        let detail = m.localOnly ? S("speech.cloud.off") : S("speech.note.cloud")
        // the first row is the catalogue's (search lands on it); the others are the same row for another service
        if first {
            SettingRow("speech.cloud", title: title, detail: detail, icon: "cloud") { CloudKey(model: x) }
        } else {
            SettingRow("speech.cloud.\(x.id)", title: title, detail: detail, icon: "cloud") { CloudKey(model: x) }
        }
    }
}

// MARK: - Pieces

/// A job's model while it is chosen automatically: its name, and a quiet "Auto" that says why it can't be picked here.
private struct AutoValue: View {
    var text: String
    var body: some View {
        HStack(spacing: 6) {
            Text(text).foregroundStyle(.secondary).lineLimit(1)
            Text(S("speech.auto.tag")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1.5)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
        .accessibilityElement(children: .combine)
    }
}

/// A job's model when the user picks it: a native pop-up of the models on this Mac, then Get More Models… (the library).
private struct ModelPopUp: View {
    var label: String
    var current: String?
    var choices: [(id: String, name: String)]
    var more: () -> Void
    var pick: (String) -> Void
    var body: some View {
        Picker(label, selection: Binding(get: { current ?? "" }, set: { id in
            if id == moreModels { DispatchQueue.main.async(execute: more) } else if id != current && !id.isEmpty { pick(id) }
        })) {
            if current == nil || !choices.contains(where: { $0.id == current }) {
                Text(S("speech.purpose.none_yet")).tag(current ?? "")
            }
            ForEach(choices, id: \.id) { Text($0.name).tag($0.id) }
            Divider()
            Text(S("speech.purpose.more")).tag(moreModels)
        }
        .labelsHidden().fixedSize()
    }
}

/// "✓ Key found" (ok + check) or "Not set", and an info button whose popover names the variables and the export line.
private struct CloudKey: View {
    var model: ASRModel
    @State private var info = false
    var body: some View {
        HStack(spacing: 6) {
            if model.installed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.brandOk).accessibilityHidden(true)
                Text(S("speech.cloud.set")).foregroundStyle(.secondary)
            } else {
                Text(S("speech.cloud.not_set")).foregroundStyle(.secondary)
            }
            Button { info.toggle() } label: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .help(S("speech.cloud.info")).accessibilityLabel(S("speech.cloud.info"))
                .popover(isPresented: $info, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(S("speech.cloud.keys")).font(.system(size: SettingsMetrics.detailSize))
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(model.keys ?? [], id: \.self) { CommandText(text: "export \($0)=…") }
                    }
                    .padding(14).frame(width: 340, alignment: .leading)
                }
        }
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
    enum Tab: Hashable { case asr, polish }

    /// fixed columns, so numbers line up from row to row (right-aligned, tabular digits)
    enum Col {
        static let used: CGFloat = 120, accuracy: CGFloat = 62, speed: CGFloat = 46, memory: CGFloat = 62, size: CGFloat = 62
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
            // a dozen rows at most: the sheet grows to fit them instead of scrolling
            SettingsGroup("speech.models", title: "") {
                header
                if tab == .asr { ForEach(asrModels) { asrRow($0) } } else { ForEach(polishModels) { polishRow($0) } }
            }
            .padding(.top, -12)
            HStack(alignment: .center) {
                if tab == .asr && m.models.contains(where: { $0.local && !($0.runsHere ?? true) }) {
                    Text(S("speech.models.elsewhere")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(S("speech.lib.done"), action: close).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 18)
        .frame(width: 760)
        .fixedSize(horizontal: false, vertical: true)
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
        var t = Text(tab == .polish ? S("speech.purpose.polish.detail") : S("speech.lib.note", Loc.list(m.languages.map(languageName))))
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
    }
    struct Job: Hashable {
        var symbol: String
        var title: String
        static var dictation: Job { Job(symbol: "character.cursor.ibeam", title: S("speech.purpose.dictation")) }
        static var polish: Job { Job(symbol: "wand.and.stars", title: S("speech.purpose.polish")) }
    }

    var header: some View {
        HStack(spacing: Col.gap) {
            Color.clear.frame(width: SettingsMetrics.iconSlot)
            headerCell(S("speech.lib.col.model"), width: nil, trailing: false)
            headerCell(S("speech.lib.col.used"), width: Col.used, trailing: false)
            if tab == .asr {
                headerCell(S("speech.metric.accuracy"), width: Col.accuracy, seal: true, help: S("speech.metric.accuracy.help"))
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
        let err = m.errorRate(x), speed = m.speed(x), memory = m.memory(x)
        let dash = x.installed ? S("speech.lib.dash.installed") : S("speech.lib.dash")
        var used = Used()
        if let p = m.download(x.id) { used.text = p.text }
        else if m.failed(x.id) != nil { used = Used(text: S("speech.download.failed.short"), err: true) }
        else if m.benching.contains(x.id) { used.text = S("speech.bench.running") }
        else if m.bench[x.id]?.error != nil { used = Used(text: S("speech.bench.failed"), err: true) }
        else if !uses.isEmpty { used.jobs = uses }
        else if !x.installed, !picked.isEmpty {
            used.text = S("speech.model.picked_not_in", Loc.list(picked.map { $0.title.lowercased(with: Loc.locale) }))
        } else if !m.missing(x).isEmpty { used.text = S("speech.lib.missing", Loc.list(m.missing(x).map(languageName))) }
        return row(id: x.id, installed: x.installed, name: x.title, help: describe(x), used: used, inUse: !uses.isEmpty) {
            MetricCell(text: err.map { percent(max(0, 1 - $0.value)) }, measured: err?.measured == true, width: Col.accuracy, dash: dash)
            MetricCell(text: speed.map { S("speech.metric.speed.value", decimal($0.value)) }, measured: speed?.measured == true,
                       width: Col.speed, dash: dash)
            MetricCell(text: memory.map { modelSize($0.value) }, measured: memory?.measured == true, width: Col.memory, dash: dash)
            MetricCell(text: modelSize(x.sizeMB), measured: false, width: Col.size, dash: "", seal: false)
        } action: {
            if m.download(x.id) != nil {
                stopButton(x.id)
            } else if m.benching.contains(x.id) {
                BrandSpinnerView(size: 12)
            } else if !x.installed {
                if hover == x.id || m.failed(x.id) != nil { Button(S("speech.download.button")) { m.startDownload(x) } }
            } else if hover == x.id {
                Menu { asrActions(x, inUse: !uses.isEmpty) } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(S("speech.lib.actions", x.title))
            }
        } menu: {
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
        else if m.failed(x.id) != nil { used = Used(text: S("speech.download.failed.short"), err: true) }
        else if inUse { used.jobs = [Job.polish] }
        return row(id: x.id, installed: x.installed, name: x.name, help: "", used: used, inUse: inUse) {
            MetricCell(text: x.ramMB.map(modelSize), measured: false, width: Col.memory, dash: S("speech.lib.dash"), seal: false)
            MetricCell(text: modelSize(x.sizeMB), measured: false, width: Col.size, dash: "", seal: false)
        } action: {
            if m.download(x.id) != nil {
                stopButton(x.id)
            } else if !x.installed {
                if hover == x.id || m.failed(x.id) != nil { Button(S("speech.download.button")) { d.download(x) } }
            } else if hover == x.id && !inUse {
                Menu { Button(S("speech.lib.use_polish")) { d.choose(x) } } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(S("speech.lib.actions", x.name))
            }
        } menu: {
            if x.installed && !inUse { Button(S("speech.lib.use_polish")) { d.choose(x) } }
            else if !x.installed && m.download(x.id) == nil { Button(S("speech.download.button")) { d.download(x) } }
        }
    }

    // MARK: one row

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
                // the one install mark: a quiet check for a model on this Mac (what it does is in Used for)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .opacity(installed ? 1 : 0).frame(width: SettingsMetrics.iconSlot)
                    .accessibilityHidden(true)
                Text(name).font(.system(size: SettingsMetrics.titleSize)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(help)
                Group {
                    if used.jobs.isEmpty {
                        Text(used.text).font(.system(size: SettingsMetrics.detailSize)).monospacedDigit()
                            .foregroundStyle(used.err ? AnyShapeStyle(Color.brandErr) : AnyShapeStyle(.secondary))
                            .lineLimit(1).truncationMode(.tail)
                            .help(used.text)
                    } else {
                        let names = Loc.list(used.jobs.map(\.title))
                        HStack(spacing: 8) {
                            ForEach(used.jobs, id: \.self) { j in
                                Image(systemName: j.symbol).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 16)
                            }
                        }
                        .help(names)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(S("speech.lib.col.used") + " " + names)
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

