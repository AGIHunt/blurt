// The setup assistant's models step (Onboarding.swift, docs/design/desktop-app.md §2.2): one "Download recommended
// models" for this Mac — dictation's recogniser, the polish model and the voice-note model (BlurtCore ModelBundle) —
// with the total size and one progress bar (Stop ends it). The downloads themselves are the app's one download manager
// (App/ModelDownloads.swift): they run one after another, carry on when the assistant closes (a line says so; the
// menu-bar menu and Settings → Speech show the progress), and pick up again after a quit or a crash. When the set
// didn't come down, SenseVoice Small alone is offered. A list that couldn't be read (`listRead` false) is the same
// state as speech tools that didn't install (BlurtCore SpeechSetup .blocked): one sentence and one Try Again on the
// step — never a set with a model quietly left out, never two errors. Read again each time the assistant opens.
//   reads      `transcribe.py dictation-models`, `polish.py models`, `transcribe.py models` (SpeechModel)
//   downloads  ModelDownloads, nothing pinned: dictation and polish stay automatic (the recommended model runs once it
//              is installed); voice notes are re-picked with `transcribe.py auto --apply`.
//   dictation  `dictationReady`: the recogniser is in — the Try-it step works from then on, even while the polish and
//              voice-note models are still coming.
//   start now  `startNow` (docs/design/first-minute-speech.md): macOS 26's own recogniser speaks the user's language,
//              so dictation works with nothing downloaded — the step says so, offers the one cloud key, and the set
//              becomes the optional local upgrade (Download is no longer the footer's primary). `system` is where
//              macOS's language files stand (asked for here, in the background: AppleSpeech.prepare).
import AppKit
import BlurtCore
import Combine

@MainActor
final class ModelSetup: ObservableObject {
    static let shared = ModelSetup()

    @Published private(set) var parts: [ModelBundle.Part] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    /// the last read could read every list (false: the speech tools couldn't run — SpeechSetup .blocked)
    @Published private(set) var listRead = true
    /// the user asked for the small model alone
    private var only = false
    /// the user settled for the small model (it came down): the step is done, the full set stays on offer
    var settled: Bool { only && !downloading && SpeechModel.shared.model(ModelBundle.fallbackID)?.installed == true }
    /// the assistant is showing (else the download manager's toasts say how the models went)
    var shown = false
    /// macOS's language files for its recogniser (nil: not asked yet)
    @Published private(set) var system: AppleSpeech.Assets?
    /// Dictation works with nothing downloaded: macOS's recogniser, in a language the user speaks.
    var startNow: Bool { AppleSpeech.available && AppleSpeech.locale() != nil && system != .unsupported }
    /// …and its files are here: the Try-it step works now.
    var systemReady: Bool { startNow && system == .installed }
    private var sub: AnyCancellable?

    init() {
        // the manager's progress is this step's progress
        sub = ModelDownloads.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.managerChanged() } }
        }
    }

    private var dl: ModelDownloads { ModelDownloads.shared }
    private var ids: Set<String> { Set(parts.map(\.id)) }

    var pending: [ModelBundle.Part] { ModelBundle.pending(parts.map { p in var p = p; p.installed = p.installed || finished.contains(p.id); return p }) }
    var totalMB: Double { ModelBundle.totalMB(parts) }
    /// What a stopped or cut-short download left on disk for the models still to come (MB, by id): the next download
    /// continues it, so the step says what is left, not the whole size again. Read with the list (ModelCatalog.keptBytes).
    @Published private(set) var kept: [String: Double] = [:]
    /// Already on disk of what is still to come, never more than a model's size (a model whose files are in but that
    /// still misses its detector counts as nearly whole).
    var keptMB: Double {
        downloading ? 0 : pending.reduce(0) { $0 + min(kept[$1.id] ?? 0, $1.sizeMB) }
    }
    /// What Download still has to fetch.
    var leftMB: Double { max(totalMB - keptMB, 0) }
    /// Some of it is on disk from before: "Resume (5.2 GB left)", "707 MB of 5.9 GB downloaded".
    var resumable: Bool { keptMB >= 1 && leftMB >= 1 }
    /// this step's models that are in the manager's batch, in order
    var running: [ModelBundle.Part] { dl.queue.jobs.filter { ids.contains($0.id) }.map(\.part) }
    var finished: Set<String> { Set(dl.queue.finished).intersection(ids) }
    var current: String? { dl.current.flatMap { ids.contains($0) ? $0 : nil } }
    var line: (done: Double, total: Double)? { current == nil ? nil : dl.line }
    /// one of this step's models is downloading or waiting its turn
    var downloading: Bool { dl.queue.pending.contains { ids.contains($0.id) } }
    var failed: Bool { parts.contains { dl.failed[$0.id] != nil } }
    var ready: Bool { loaded && !parts.isEmpty && pending.isEmpty }
    var progress: (done: Double, total: Double) { ModelBundle.progress(running, finished: finished, current: current, line: line) }
    /// SenseVoice Small, when it is still missing
    var fallback: ModelBundle.Part? {
        SpeechModel.shared.model(ModelBundle.fallbackID).flatMap { $0.installed ? nil : part($0, .note) }
    }

    /// The recogniser dictation runs on is in (installed, or came down in this batch): Try it works now.
    var dictationReady: Bool {
        // macOS's recogniser, unless the app's own answer says dictation can't run yet (it picked a model still missing a file)
        if systemReady, DictationModels.shared.dictationReady != false { return true }
        guard let d = parts.first(where: { $0.kind == .dictation }) else { return DictationModels.shared.dictationReady == true }
        return d.installed || finished.contains(d.id) || DictationModels.shared.dictationReady == true
    }
    /// The recogniser is the one coming down now (or waiting): its own bar on the Try-it step.
    var dictationProgress: (done: Double, total: Double)? {
        guard let d = parts.first(where: { $0.kind == .dictation }), !dictationReady, dl.queue.contains(d.id) else { return nil }
        return dl.progress(d.id) ?? (0, d.sizeMB)
    }
    /// What is still coming besides the recogniser (MB), once the recogniser is in.
    var restMB: Double { dl.queue.pending.filter { ids.contains($0.id) && $0.kind != .dictation }.reduce(0) { $0 + $1.sizeMB } }

    private func managerChanged() { objectWillChange.send() }

    // MARK: what this Mac gets

    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        prepareSystem()
        async let d = try? SkillCLI.shared.run("transcribe.py", ["dictation-models"], timeout: 180)
        async let p = try? SkillCLI.shared.run("polish.py", ["models"], timeout: 120)
        await SpeechModel.shared.load()
        let asr = (await d)?.decode(DictationASRState.self)
        let polish = (await p)?.decode(PolishState.self)
        let speech = SpeechModel.shared
        let dictation = asr.flatMap { s in s.models.first { $0.id == s.recommended } }.map {
            ModelBundle.Part(id: $0.id, kind: .dictation, name: $0.name ?? $0.id, sizeMB: $0.sizeMB, installed: $0.installed)
        }
        let pm = polish.flatMap { s in s.models.first { $0.id == s.recommended } }.map {
            ModelBundle.Part(id: $0.id, kind: .polish, name: $0.name, sizeMB: $0.sizeMB, installed: $0.installed)
        }
        let note = speech.recommended(.note).map { part($0, .note) }
        // a list that couldn't be read: no set ("Couldn't read the models" + Try Again), never a set without that model
        let plan = ModelBundle.plan(dictation: dictation, polish: pm, polishRuns: polish?.supported, note: note)
        // while the set downloads, keep the rows it started with (a read mid-download changes nothing that matters)
        if !(downloading && plan == nil) { parts = plan ?? [] }
        listRead = plan != nil || downloading
        loaded = true
        let ids = pending.map(\.id), models = BlurtPaths.home.appendingPathComponent("models"), hub = Self.hfCache
        kept = await Task.detached(priority: .utility) {
            Dictionary(ids.map { ($0, Double(ModelCatalog.keptBytes($0, models: models, hfCache: hub)) / 1_048_576) }) { a, _ in a }
        }.value
        emit(["event": "onboarding_models", "read": ["dictation": asr != nil, "polish": polish != nil, "note": note != nil],
              "parts": parts.map { ["id": $0.id, "kind": $0.kind.rawValue, "size_mb": $0.sizeMB,
                                                                   "installed": $0.installed] },
              "total_mb": totalMB])
    }

    /// Hugging Face's cache, as the scripts find it (polish.py hf_cache).
    nonisolated static var hfCache: URL {
        let env = ProcessInfo.processInfo.environment
        if let c = env["HF_HUB_CACHE"], !c.isEmpty { return URL(fileURLWithPath: c) }
        let home = env["HF_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface")
        return home.appendingPathComponent("hub")
    }

    /// macOS's language files asked for (nothing to fetch when they are here); dictation re-reads its model then.
    func prepareSystem() {
        guard AppleSpeech.available, system != .installed else { return }
        AppleSpeech.prepare(via: "onboarding") { [weak self] a in
            self?.system = a
            Dictation.shared.refreshSpeechModels()
        }
    }

    /// The languages macOS's recogniser can listen for that this user speaks (Settings' list), the one it listens for
    /// now first; English always offered.
    var systemLanguages: [String] {
        let now = AppleSpeech.code(AppleSpeech.locale())
        let all = [now].compactMap { $0 } + SpeechModel.shared.languages + ["en"]
        return Array(NSOrderedSet(array: all.filter { AppleSpeech.locales[$0] != nil })) as? [String] ?? []
    }

    /// The language dictation listens for, picked on this step: "Automatic" stays unpinned (Settings → Speech →
    /// Recognition language), another one is pinned there; macOS's files for it are asked for now.
    func chooseLanguage(_ code: String) {
        SpeechModel.shared.setLanguage(code == AppleSpeech.code(AppleSpeech.automatic) ? "auto" : code)
        emit(["event": "onboarding_language", "language": code])
        system = nil
        AppleSpeech.prepare(via: "onboarding") { [weak self] a in
            self?.system = a
            Dictation.shared.refreshSpeechModels()
        }
    }

    private func part(_ m: ASRModel, _ kind: ModelBundle.Kind) -> ModelBundle.Part {
        ModelBundle.Part(id: m.id, kind: kind, name: m.title, sizeMB: m.sizeMB, installed: m.installed)
    }

    // MARK: download

    /// The recommended set (or `only` these), through the download manager.
    func start(only: [ModelBundle.Part]? = nil) {
        let todo = only ?? pending
        guard !todo.isEmpty else { return }
        self.only = only != nil
        emit(["event": "onboarding_models", "op": "start", "models": todo.map(\.id), "total_mb": todo.reduce(0) { $0 + $1.sizeMB }])
        dl.download(todo.map { ModelDownloadQueue.Job(id: $0.id, kind: $0.kind, name: $0.name, sizeMB: $0.sizeMB) }, via: "onboarding")
    }

    /// The progress bar's Stop: the downloads end (what came down is kept), the set stays on offer.
    func cancel() {
        guard downloading else { return }
        emit(["event": "onboarding_models", "op": "stop", "model": current ?? NSNull()])
        dl.stop()
    }

    /// The assistant closed while the set downloads: one line says it carries on, and where to see it.
    func closedWhileDownloading() {
        guard downloading, !App.terminating else { return }      // a quit stops the downloads: nothing carries on
        let left = modelSize(dl.remainingMB)       // what came down of the running model isn't counted again
        var t = Island.Toast(text: T("app.models.background", left), actionTitle: T("app.models.show")) { ModelDownloads.showProgress() }
        t.seconds = 6
        island.toast(t)
    }
}
