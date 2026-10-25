// The models dictation runs on, in one place (docs/design/dictation.md §Recognition model, §Polish): the speech models
// it can use (`transcribe.py dictation-models`) and the polish models (`polish.py models`), their downloads (only when
// the user asks, through the app's one download manager, App/ModelDownloads.swift: a model the assistant is already
// fetching shows its bar here, "Queued" while it waits, never a second Download), whether dictation has a recogniser
// to run on (`dictationReady`: the dictation key waits on it), the choice, the recommended pair with its total size, and
// their names (the Dictation page's history shows names, not ids). Settings → Speech lists and picks them
// (`DictationModelsSection`, the "speech.dictation" group); Settings → Dictation shows the current choice with a link
// there (show(pane: "speech/dictation")).
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

    /// Dictation has a recogniser to run on: the selected model is installed. nil = not read yet, or the selected one
    /// isn't one of dictation's rows (the Fn key then doesn't wait on this).
    var dictationReady: Bool? { selectedASR.map(\.installed) }
    /// The recogniser dictation would download: the selected one when its files are in and only the VAD is missing
    /// (0.6 MB, not the model again), else the recommended one.
    var dictationJob: ModelDownloadQueue.Job? {
        if let s = selectedASR, s.files == true, !s.installed {
            return ModelDownloadQueue.Job(id: s.id, kind: .dictation, name: s.name ?? s.id, sizeMB: DictationModels.vadMB)
        }
        return recommendedASR.map { ModelDownloadQueue.Job(id: $0.id, kind: .dictation, name: $0.name ?? $0.id, sizeMB: $0.sizeMB) }
    }
    /// silero_vad.onnx
    static let vadMB = 0.6

    func load() async {
        loaded = true
        async let a = SkillCLI.shared.run("transcribe.py", ["dictation-models"], timeout: 120)
        async let p = SkillCLI.shared.run("polish.py", ["models"], timeout: 60)
        asr = (try? await a)?.decode(DictationASRState.self)
        polish = (try? await p)?.decode(PolishState.self)
    }

    /// Once per run (the history's names); Settings reloads whenever it opens.
    func loadIfNeeded() { if !loaded { Task { await load() } } }

    // MARK: names

    func asrName(_ id: String) -> String { asr?.models.first { $0.id == id }?.name ?? id }
    func polishName(_ id: String) -> String { polish?.models.first { $0.id == id }?.name ?? id }
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
    /// "polish_settings" event with every row's state (whichever pane is showing)
    func testCommand(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
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
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(S("speech.dictation.loading")).foregroundStyle(.secondary) }
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

    func asrRow(_ x: DictationASRModel, selected: Bool) -> some View {
        DictationModelRow(name: x.name ?? x.id, sizeMB: x.sizeMB, recommended: x.recommended, installed: x.installed,
                          selected: selected, detail: x.vocab == "none" ? S("speech.dictation.no_words") : nil,
                          progress: m.progress(x.id), queued: m.queued(x.id), unpacking: m.unpacking(x.id), failed: m.failed(x.id),
                          use: { m.chooseASR(x) }, download: { m.installASR(x) }, cancel: { m.cancel(x.id) })
    }

    func polishRow(_ x: PolishModel, selected: Bool) -> some View {
        DictationModelRow(name: x.name, sizeMB: x.sizeMB, recommended: x.recommended, installed: x.installed,
                          selected: selected, detail: nil, progress: m.progress(x.id), queued: m.queued(x.id), unpacking: m.unpacking(x.id), failed: m.failed(x.id),
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
                ProgressView(value: min(d.done, d.total), total: max(d.total, 1)).frame(width: 90)
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
