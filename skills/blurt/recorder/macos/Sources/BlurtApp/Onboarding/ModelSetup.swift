// The setup assistant's models step (Onboarding.swift, docs/design/desktop-app.md §2.2): one "Download recommended
// models" for this Mac — dictation's recogniser, the polish model and the voice-note model (BlurtCore ModelBundle) —
// with the total size and one progress bar. The downloads run one after another and carry on when the assistant
// closes (a toast says when they're in). When the set didn't come down, SenseVoice Small alone is offered.
//   reads      `transcribe.py dictation-models`, `polish.py models`, `transcribe.py models` (SpeechModel)
//   downloads  `transcribe.py setup --model-id ID` / `polish.py setup --model ID`, nothing pinned: dictation and polish
//              stay automatic (the recommended model runs once it is installed); voice notes are re-picked with
//              `transcribe.py auto --apply`.
//   mirror     the China-friendly mirrors first when Settings → Speech says so, or, unset, when the region is CN (both
//              scripts still try the other source when one fails).
// Test builds: BLURT_TEST_ASR_SETUP / BLURT_TEST_POLISH_SETUP stand in for the two setup scripts (fake downloads).
import AppKit
import BlurtCore

@MainActor
final class ModelSetup: ObservableObject {
    static let shared = ModelSetup()

    @Published private(set) var parts: [ModelBundle.Part] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    /// the downloads under way (fixed when they start), the finished ones, the current one's last "N/M MB"
    @Published private(set) var running: [ModelBundle.Part] = []
    @Published private(set) var finished: Set<String> = []
    @Published private(set) var current: String?
    @Published private(set) var line: (done: Double, total: Double)?
    @Published private(set) var failed = false
    /// the user settled for the small model (it came down): the step is done, the full set stays on offer
    @Published private(set) var settled = false
    private var only = false
    private var proc: Process?
    /// the assistant is showing (else a toast says the models are in)
    var shown = false

    var pending: [ModelBundle.Part] { ModelBundle.pending(parts) }
    var totalMB: Double { ModelBundle.totalMB(parts) }
    var downloading: Bool { current != nil }
    var ready: Bool { loaded && !parts.isEmpty && pending.isEmpty }
    var progress: (done: Double, total: Double) { ModelBundle.progress(running, finished: finished, current: current, line: line) }
    /// SenseVoice Small, when it is still missing
    var fallback: ModelBundle.Part? {
        SpeechModel.shared.model(ModelBundle.fallbackID).flatMap { $0.installed ? nil : part($0, .note) }
    }

    // MARK: what this Mac gets

    func load() async {
        guard !loading, !downloading else { return }
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
        let pm = polish.flatMap { s in s.supported ? s.models.first { $0.id == s.recommended } : nil }.map {
            ModelBundle.Part(id: $0.id, kind: .polish, name: $0.name, sizeMB: $0.sizeMB, installed: $0.installed)
        }
        let note = speech.recommended(.note).map { part($0, .note) }
        parts = ModelBundle.plan(dictation: dictation, polish: pm, note: note)
        loaded = true
        emit(["event": "onboarding_models", "parts": parts.map { ["id": $0.id, "kind": $0.kind.rawValue, "size_mb": $0.sizeMB,
                                                                   "installed": $0.installed] },
              "total_mb": totalMB])
    }

    private func part(_ m: ASRModel, _ kind: ModelBundle.Kind) -> ModelBundle.Part {
        ModelBundle.Part(id: m.id, kind: kind, name: m.title, sizeMB: m.sizeMB, installed: m.installed)
    }

    // MARK: download

    /// The recommended set (or `only` these), one after another.
    func start(only: [ModelBundle.Part]? = nil) {
        guard !downloading else { return }
        let todo = only ?? pending
        guard !todo.isEmpty else { return }
        running = todo
        finished = []
        failed = false
        self.only = only != nil
        emit(["event": "onboarding_models", "op": "start", "models": todo.map(\.id), "total_mb": todo.reduce(0) { $0 + $1.sizeMB }])
        next()
    }

    private func next() {
        guard let p = running.first(where: { !finished.contains($0.id) }) else { return done() }
        current = p.id
        line = nil
        let env = ProcessInfo.processInfo.environment
        let test = env["BLURT_TEST_COMMANDS"] == "1"
        let (script, args) = p.kind == .polish
            ? ((test ? env["BLURT_TEST_POLISH_SETUP"] : nil) ?? "polish.py", ["setup", "--model", p.id])
            : ((test ? env["BLURT_TEST_ASR_SETUP"] : nil) ?? "transcribe.py", ["setup", "--model-id", p.id])
        var extra: [String: String] = [:]
        if ModelSetup.mirror { extra["BLURT_HF_MIRROR"] = "1" }
        do {
            proc = try SkillCLI.shared.spawn(script, args, env: extra, onLine: { [weak self] l, _ in
                if let q = ModelBundle.parseProgress(l) { self?.line = q }
            }, onExit: { [weak self] st in
                guard let self = self else { return }
                self.proc = nil
                emit(["event": "onboarding_models", "op": "part", "model": p.id, "status": Int(st)])
                if st == 0 {
                    self.finished.insert(p.id)
                    self.next()
                } else {
                    self.stop(failed: st != 15)
                }
            })
        } catch { stop(failed: true) }
    }

    private func stop(failed f: Bool) {
        current = nil
        line = nil
        failed = f
        Task { await refresh() }
    }

    private func done() {
        current = nil
        line = nil
        settled = settled || only
        emit(["event": "onboarding_models", "op": "done", "models": running.map(\.id)])
        Task {
            await refresh()
            if !shown { AppEnvironment.island?.toast(T("onboarding.models.ready_toast"), actionTitle: nil, action: nil) }
        }
    }

    /// The models in use now: polish picks its model up, voice notes are re-picked for this Mac, the rows re-read.
    private func refresh() async {
        Dictation.shared.refreshPolishModel()
        await SpeechModel.shared.reapply()
        await load()
    }

    func cancel() { proc?.terminate() }

    /// The China-friendly mirrors first: Settings → Speech's choice, else (unset) a CN region.
    static var mirror: Bool {
        if let on = Config.shared["asr.hf_mirror"] as? Bool { return on }
        return Locale.current.region?.identifier == "CN"
    }
}
