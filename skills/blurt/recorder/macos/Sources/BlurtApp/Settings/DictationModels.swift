// The models dictation runs on, in one place (docs/design/dictation.md §Recognition model, §Polish): the speech models
// it can use (`transcribe.py dictation-models`) and the polish models (`polish.py models`), their downloads (only when
// the user asks, through the app's one download manager, App/ModelDownloads.swift: a model the assistant is already
// fetching shows its bar here, "Queued" while it waits, never a second Download), whether dictation has a recogniser
// to run on (`dictationReady`: the dictation key waits on it), the choice, the recommended pair with its total size, and
// their names (the Dictation page's history shows names, not ids). Settings → Speech lists and picks them
// (`DictationModelsSection`, the "speech.dictation" group); Settings → Dictation shows them as one row: the names in
// use with a link there (show(pane: "speech/dictation")), or what is missing with one Download for all of it
// (`missingJobs`), or the download's progress.
// One verb per state: Download (not on this Mac) / Use (on this Mac) / the selected one is marked. Sizes come from
// the catalogues' size_mb, formatted by `modelSize`.
// Strings: Resources/*.lproj/Speech.strings ("speech.dictation.*").
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
    enum CodingKeys: String, CodingKey { case id, name, family, installed, recommended, sizeMB = "size_mb" }
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
    enum CodingKeys: String, CodingKey { case id, name, installed, files, recommended, vocab, sizeMB = "size_mb" }
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
    enum CodingKeys: String, CodingKey {
        case configured, recommended, selected, models, ready, missing
        case selectedInstalled = "selected_installed", configuredInstalled = "configured_installed"
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
        return d
    }
}

struct PolishState: Decodable {
    var supported: Bool
    var tier: String
    var recommended: String
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

// MARK: - Settings → Speech: the dictation models

/// The recommended pair with its total size, then the speech models and the polish models: the selected, recommended
/// and downloaded ones, the rest folded under "Other models".
struct DictationModelsSection: View {
    @ObservedObject var m = DictationModels.shared

    var body: some View {
        // "nothing is downloaded until you click Download" is only true while nothing is
        SettingsGroup("speech.dictation", footer: m.downloading ? nil : S("speech.dictation.footer")) {
            if m.asr == nil && m.polish == nil {
                SettingsLine {
                    HStack(spacing: 8) { BrandSpinnerView(); Text(S("speech.dictation.loading")).foregroundStyle(.secondary) }
                }
            } else {
                recommended
                if let a = m.asr {
                    subheading(S("speech.dictation.asr"))
                    let (main, more) = split(a.models) { $0.id == a.selected || $0.recommended || $0.installed || ModelDownloads.shared.queue.contains($0.id) }
                    ForEach(main) { x in modelLine { asrRow(x, selected: a.selected == x.id) } }
                    if !more.isEmpty {
                        modelLine {
                            DisclosureGroup(S("speech.dictation.more", more.count)) {
                                ForEach(more) { asrRow($0, selected: a.selected == $0.id) }
                            }
                        }
                    }
                }
                if let p = m.polish {
                    subheading(S("speech.dictation.polish"))
                    if !p.supported {
                        SettingsLine { Text(S("speech.dictation.polish.unsupported")).foregroundStyle(.secondary) }
                    } else {
                        let sorted = p.models.sorted { ($0.recommended ? 0 : 1, $0.sizeMB) < ($1.recommended ? 0 : 1, $1.sizeMB) }
                        let (main, more) = split(sorted) { $0.id == p.selected || $0.recommended || $0.installed || ModelDownloads.shared.queue.contains($0.id) }
                        ForEach(main) { x in modelLine { polishRow(x, selected: p.selected == x.id) } }
                        if !more.isEmpty {
                            modelLine {
                                DisclosureGroup(S("speech.dictation.more", more.count)) {
                                    ForEach(more) { polishRow($0, selected: p.selected == $0.id) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .task { await m.load() }
    }

    /// A model's line: tighter than a setting's, the choice card brings its own padding.
    private func modelLine<C: View>(@ViewBuilder _ c: () -> C) -> some View { SettingsLine(padding: 6) { c() } }

    private func split<T>(_ xs: [T], _ keep: (T) -> Bool) -> ([T], [T]) { (xs.filter(keep), xs.filter { !keep($0) }) }

    /// Recognition / Polish: a small label inside the group, over the models it names.
    private func subheading(_ s: String) -> some View {
        Text(s).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 14).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    /// "Recommended: Qwen3-ASR 1.7B + Gemma 4 E2B · 5.7 GB" with one Download for what's missing.
    @ViewBuilder var recommended: some View {
        let names = [m.recommendedASR?.name, m.recommendedPolish?.name].compactMap { $0 }
        if !names.isEmpty {
            let mb = m.recommendedMB
            SettingsLine {
            HStack(alignment: .center, spacing: 14) {
                StatusDot(tone: mb.missing == 0 ? .good : .off).frame(width: SettingsMetrics.leadingWidth)
                VStack(alignment: .leading, spacing: 2) {
                    Text(S("speech.dictation.recommended", names.joined(separator: " + ")))
                    Text(mb.missing == 0 ? S("speech.dictation.recommended.ready", modelSize(mb.total))
                                         : S("speech.dictation.recommended.size", modelSize(mb.total)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if mb.missing > 0 && !m.downloading {
                    Button(S("speech.dictation.download", modelSize(mb.missing))) { m.downloadRecommended() }
                }
            }
            .accessibilityElement(children: .combine)
            }
        }
    }

    /// The radio is filled only for a model on this Mac: with nothing in yet, none is — the recommended one says it is
    /// used once it's downloaded.
    func asrRow(_ x: DictationASRModel, selected: Bool) -> some View {
        let noneIn = m.asr.map { a in !a.models.contains { $0.id == a.selected && $0.installed } } ?? false
        let notes = [x.vocab == "none" ? S("speech.dictation.no_words") : nil,
                     noneIn && x.recommended && !x.installed ? S("speech.dictation.used_once_in") : nil].compactMap { $0 }
        return DictationModelRow(name: x.name ?? m.asrName(x.id), sizeMB: x.sizeMB, recommended: x.recommended, installed: x.installed,
                          selected: selected && x.installed, detail: notes.isEmpty ? nil : notes.joined(separator: " · "),
                          progress: m.progress(x.id), queued: m.queued(x.id), unpacking: m.unpacking(x.id), failed: m.failed(x.id),
                          use: { m.chooseASR(x) }, download: { m.installASR(x) }, cancel: { m.cancel(x.id) })
    }

    func polishRow(_ x: PolishModel, selected: Bool) -> some View {
        let noneIn = m.polish.map { p in !p.models.contains { $0.id == p.selected && $0.installed } } ?? false
        return DictationModelRow(name: x.name, sizeMB: x.sizeMB, recommended: x.recommended, installed: x.installed,
                          selected: selected && x.installed, detail: noneIn && x.recommended && !x.installed ? S("speech.dictation.used_once_in") : nil,
                          progress: m.progress(x.id), queued: m.queued(x.id), unpacking: m.unpacking(x.id), failed: m.failed(x.id),
                          use: { m.choose(x) }, download: { m.install(x) }, cancel: { m.cancel(x.id) })
    }
}

/// One model: a radio mark, its name (Recommended), its size; Download / Use, or the download's progress.
struct DictationModelRow: View {
    var name: String
    var sizeMB: Double
    var recommended: Bool
    var installed: Bool
    var selected: Bool
    var detail: String?
    var progress: (done: Double, total: Double)?
    /// waiting its turn in the download manager's queue
    var queued = false
    var unpacking = false
    var failed: Bool
    var use: () -> Void
    var download: () -> Void
    var cancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.brandInk : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(name)
                    if recommended { Badge(S("speech.dictation.recommended.badge")) }
                }
                Group {
                    if progress != nil && unpacking {
                        Text(S("speech.download.unpacking"))
                    } else if let d = progress {
                        Text(S("speech.dictation.progress", modelSize(d.done), modelSize(max(d.total, sizeMB)))).monospacedDigit()
                    } else if queued {
                        Text([modelSize(sizeMB), S("speech.download.queued")].joined(separator: " · "))
                    } else {
                        Text(([modelSize(sizeMB)] + (detail.map { [$0] } ?? [])).joined(separator: " · "))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let d = progress {
                ProgressView(value: min(d.done, d.total), total: max(d.total, 1)).tint(Color.brandInk).frame(width: 90)
                if let c = cancel { Button(S("speech.download.stop"), action: c).controlSize(.small) }
            } else if queued {
                if let c = cancel { Button(S("speech.download.stop"), action: c).controlSize(.small) }
            } else if installed {
                if !selected { Button(S("speech.dictation.use"), action: use).controlSize(.small) }
            } else {
                if failed { Text(S("speech.dictation.failed")).font(.caption).foregroundStyle(Color.brandErr) }
                Button(S("speech.download.button"), action: download).controlSize(.small)
            }
        }
        .choiceCard(selected)
        .contentShape(Rectangle())
        .onTapGesture { if installed && !selected { use() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
