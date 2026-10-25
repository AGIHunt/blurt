// The setup assistant's models step (Onboarding.swift, docs/design/desktop-app.md §2.2): one "Download recommended
// models" for this Mac — dictation's recogniser, the polish model and the voice-note model (BlurtCore ModelBundle) —
// with the total size and one progress bar (Stop ends it). The downloads themselves are the app's one download manager
// (App/ModelDownloads.swift): they run one after another, carry on when the assistant closes (a line says so; the
// menu-bar menu and Settings → Speech show the progress), and pick up again after a quit or a crash. When the set
// didn't come down, SenseVoice Small alone is offered. A list that couldn't be read shows "Couldn't read the models"
// and Try Again — never a set with a model quietly left out. Read again each time the assistant opens.
//   reads      `transcribe.py dictation-models`, `polish.py models`, `transcribe.py models` (SpeechModel)
//   downloads  ModelDownloads, nothing pinned: dictation and polish stay automatic (the recommended model runs once it
//              is installed); voice notes are re-picked with `transcribe.py auto --apply`.
//   dictation  `dictationReady`: the recogniser is in — the Try-it step works from then on, even while the polish and
//              voice-note models are still coming.
import AppKit
import BlurtCore
import Combine

@MainActor
final class ModelSetup: ObservableObject {
    static let shared = ModelSetup()

    @Published private(set) var parts: [ModelBundle.Part] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    /// the user asked for the small model alone
    private var only = false
    /// the user settled for the small model (it came down): the step is done, the full set stays on offer
    var settled: Bool { only && !downloading && SpeechModel.shared.model(ModelBundle.fallbackID)?.installed == true }
    /// the assistant is showing (else the download manager's toasts say how the models went)
    var shown = false
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
        loaded = true
        emit(["event": "onboarding_models", "read": ["dictation": asr != nil, "polish": polish != nil, "note": note != nil],
              "parts": parts.map { ["id": $0.id, "kind": $0.kind.rawValue, "size_mb": $0.sizeMB,
                                                                   "installed": $0.installed] },
              "total_mb": totalMB])
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
        guard downloading else { return }
        let left = modelSize(dl.queue.remainingMB)
        var t = Island.Toast(text: T("app.models.background", left), actionTitle: T("app.models.show")) { ModelDownloads.showProgress() }
        t.seconds = 6
        island.toast(t)
    }
}
