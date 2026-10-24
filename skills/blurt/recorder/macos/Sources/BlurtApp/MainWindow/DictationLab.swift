// The Dictation Lab (测试台; docs/design/dictation.md §Lab): the Dictation page's second tab. The user dictates (the
// microphone they pick, the Record button or the dictation key while the lab is in front; or an audio file played in
// as the microphone), sees what every stage made of it — each piece's transcript, the stitched transcript, polish,
// the fit at the cursor, the custom words, the guard, the milliseconds —, writes what they meant, marks the errors,
// and saves it as a case: $BLURT_HOME/dictation/lab/cases/<id>/ {audio.wav, case.json} (BlurtCore LabStore).
// Saved cases are re-run through other configurations (Compare) or all at once (Run All Cases) by
// scripts/dictation_lab.py, which uses the app's own warm servers. A correction teaches the custom words
// (dictation_vocab.learn when it exists, else the app's own learner), with Undo. Nothing leaves this Mac.
//
// The take itself is the real pipeline: NoteVoice → DictationStream (cut at pauses, ASR + polish per piece, the
// stitch guard) → DictationFit against the lab's own "text around the cursor" fields. Nothing is pasted anywhere,
// nothing goes to the history. Test builds never open the microphone: the "mic" is a wav (the `dictation wav` hook,
// BLURT_TEST_MIC_WAV) or an imported file.
import AppKit
import AVFoundation
import BlurtCore
import UniformTypeIdentifiers

/// What Dictation hands the key to while the lab is in front.
@MainActor protocol DictationLabSink: AnyObject {
    var wantsKey: Bool { get }
    func keyStart()
    func keyStop()
    func keyCancel()
}

/// One lab take: the microphone (or a file played in as one) → the stream → the result, without typing anything.
final class LabTake {
    let id: String
    let wav: URL
    private var voice: NoteVoice?
    private var stream: DictationStream?
    private(set) var options = DictationStream.Options()
    var onLevel: ((Float) -> Void)?
    var heardSpeech = false
    var elapsed: Double { voice?.elapsed ?? 0 }

    init(id: String, dir: URL) {
        self.id = id
        wav = dir.appendingPathComponent("\(id).wav")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// inject: a file played in real time as the microphone (an imported file, or a test wav); device: the picked
    /// input (nil = the default); context: the lab's text around the cursor.
    func start(inject: String?, builtIn: Bool, device: AudioDeviceID?, context: DictationContext?, ready: @escaping (Bool) -> Void) {
        let v = NoteVoice(url: wav)
        v.inject = inject
        v.builtInMic = builtIn
        v.device = device
        v.silenceToEnd = .infinity
        v.noSpeechTimeout = .infinity
        v.maxLength = 300
        v.onLevel = { [weak self] l in self?.onLevel?(l) }
        v.onSpeech = { [weak self] in self?.heardSpeech = true }
        var opt = DictationStream.Options()
        opt.language = Config.shared["asr.language"] as? String ?? "auto"
        opt.streaming = Dictation.streaming
        opt.polishTimeout = Dictation.polishTimeout
        opt.loadBudget = Dictation.loadBudget
        opt.vocab = DictationVocabulary.shared.payload()
        opt.polish = Dictation.polishOn && Dictation.shared.polishModel != nil
        options = opt
        let s = DictationStream(id: "lab-\(id)", dir: wav.deletingLastPathComponent(), wholeWav: wav, options: opt)
        s.setContext(opt.polish ? context : nil)
        v.onSamples = { [weak s] x in s?.append(x) }
        voice = v
        stream = s
        v.start(ready)
    }

    func finish(_ done: @escaping (DictationStream.Result?) -> Void) {
        guard let v = voice, let s = stream else { return done(nil) }
        let keyUp = CACurrentMediaTime()
        v.stop(keep: true)
        voice = nil
        stream = nil
        s.finish(keyUp: keyUp) { r in done(r) }
    }

    func cancel() {
        voice?.stop(keep: false)
        stream?.cancel()
        voice = nil
        stream = nil
        try? FileManager.default.removeItem(at: wav)
    }
}

@MainActor
final class DictationLabModel: ObservableObject, DictationLabSink {
    enum Phase: String { case idle, starting, recording, processing }
    /// What the detail column shows: the take being made / a saved case, or the regression run.
    enum Pane: Equatable { case take, script, regression }

    struct Rerun: Identifiable {
        let id = UUID()
        let label: String
        let spec: String
        var outputs: [String: Any] = [:]
        var error: String?
        var text: String { outputs["text"] as? String ?? "" }
        var ms: Int { (outputs["timings"] as? [String: Any])?["total_ms"] as? Int ?? 0 }
    }

    struct Option: Identifiable, Hashable {
        let spec: String
        let label: String
        var id: String { spec }
    }

    @Published var cases: [LabCase] = []
    @Published var pane: Pane = .take
    /// the case in the workbench: a new take (not saved yet) or a copy of a saved one
    @Published var draft = LabCase(id: LabStore.newID(), source: "take")
    @Published var isNew = true
    @Published var dirty = false
    @Published var phase: Phase = .idle
    @Published var levels: [Float] = []
    @Published var elapsed: Double = 0
    @Published var notice: String?
    @Published var error: String?
    /// the text around the cursor for the take (polish's context, and what the result is fitted into)
    @Published var before = "" { didSet { if before != oldValue { contextChanged() } } }
    @Published var after = "" { didSet { if after != oldValue { contextChanged() } } }
    @Published var includeContext = false { didSet { if includeContext != oldValue { contextChanged() } } }
    @Published var mics: [String] = []
    /// "" = the system's default input, else a device name
    @Published var mic = ""
    @Published var options: [Option] = []
    @Published var chosen: Set<String> = []
    @Published var reruns: [Rerun] = []
    @Published var rerunning = false
    @Published var learned: [LabVocab.Change] = []
    @Published var learnedVia: String?
    // regression
    @Published var runSpec = "current"
    @Published var running = false
    @Published var runResult: [String: Any]?
    @Published var keepNext = 0
    private var take: LabTake?
    private var pendingAudio: URL?
    private var timer: Timer?
    private var stopAfter: DispatchWorkItem?
    /// the lab page is showing (Dictation hands it the key then)
    var visible = false

    static var tmpDir: URL { BlurtPaths.home.appendingPathComponent("dictation/lab/tmp") }

    init() {
        mic = Config.shared["record.dictation.lab_mic"] as? String ?? ""
        keepNext = Dictation.labKeepNext
    }

    // MARK: cases

    func reload() {
        cases = LabStore.shared.list()
        keepNext = Dictation.labKeepNext
        if visible { MainWindowController.shared.updateTitle() }
        refreshMics()
        if options.isEmpty { loadOptions() }
        if packs.isEmpty { loadPacks() }
    }

    var selectedID: String? { isNew ? nil : draft.id }

    /// A new take: a free one, or (reading a script) one of the current prompt — its text is the reference.
    func newTake(script: Bool = false) {
        guard phase == .idle else { return }
        draft = LabCase(id: LabStore.newID(), source: "take")
        isNew = true
        dirty = false
        pendingAudio = nil
        reruns = []
        learned = []
        learnedVia = nil
        error = nil
        notice = nil
        if script, let p = currentPack, let q = currentPrompt {
            draft.json["source"] = "script"
            draft.reference = q.expected
            draft.json["prompt"] = ["pack": p.id, "id": q.id, "read": q.read, "tags": q.tags] as [String: Any]
            pane = .script
        } else {
            pane = .take
        }
    }

    func open(_ id: String, keepPane: Bool = false) {
        guard phase == .idle, let c = LabStore.shared.load(id) else { return }
        draft = c
        isNew = false
        dirty = false
        pendingAudio = nil
        reruns = (LabStore.shared.runs(id).suffix(6)).map { r in
            var x = Rerun(label: r["label"] as? String ?? r["key"] as? String ?? "", spec: r["key"] as? String ?? "")
            x.outputs = r["outputs"] as? [String: Any] ?? [:]
            return x
        }
        learned = (c.json["learned"] as? [[String: Any]] ?? []).compactMap(LabVocab.Change.init(json:))
        learnedVia = nil
        let ctx = c.context
        before = ctx["before"] ?? ""
        after = ctx["after"] ?? ""
        includeContext = c.contextIncluded
        error = nil
        notice = nil
        if !keepPane { pane = .take }
    }

    func edit(_ change: (inout LabCase) -> Void) {
        change(&draft)
        dirty = true
    }

    private func contextChanged() {
        guard !isNew || draft.take != nil else { return }
        dirty = true
    }

    /// Moves the case's folder to the Trash (the user can still get it back from there).
    func delete(_ id: String) {
        let f = LabStore.shared.folder(id)
        if (try? FileManager.default.trashItem(at: f, resultingItemURL: nil)) == nil { LabStore.shared.delete(id) }
        emit(["event": "dictation_lab", "action": "delete", "id": id])
        notice = T("dictation.lab.deleted")
        if draft.id == id { newTake(script: pane == .script) }
        reload()
    }

    // MARK: the microphone

    func refreshMics() {
        mics = AudioDevices.inputs().map(\.name)
    }

    func setMic(_ name: String) {
        mic = name
        Config.shared.set("record.dictation.lab_mic", name.isEmpty ? nil : name)
    }

    private var micDevice: AudioDeviceID? {
        guard !mic.isEmpty else { return nil }
        return AudioDevices.inputs().first { $0.name == mic }?.id
    }

    // MARK: recording (the Record button, the dictation key, an imported file)

    var wantsKey: Bool {
        guard visible, pane != .regression, phase == .idle || phase == .recording || phase == .starting else { return false }
        if DictationInsert.testMode { return true }
        return NSApp.isActive && MainWindowController.shared.window?.isKeyWindow == true
    }
    func keyStart() { if phase == .idle { record(file: nil, via: "key") } }
    func keyStop() { if phase == .recording { stop(via: "key") } }
    func keyCancel() { cancel() }

    func toggleRecord() {
        switch phase {
        case .idle: record(file: nil, via: "button")
        case .recording, .starting: stop(via: "button")
        case .processing: break
        }
    }

    /// The test "microphone" in a test build (a wav), else nil = the real one.
    private var testMic: String? {
        let env = ProcessInfo.processInfo.environment
        return Dictation.shared.testWav ?? env["BLURT_TEST_MIC_WAV"] ?? env["BLURT_NOTE_WAV"]
    }

    func record(file: URL?, via: String) {
        guard phase == .idle else { return }
        var inject = file?.path
        if inject == nil, DictationInsert.testMode {
            // test builds never open the real microphone
            guard let t = testMic else { error = T("dictation.lab.error.test_mic"); return }
            inject = t
        }
        let script = pane == .script
        let forPrompt = (draft.json["prompt"] as? [String: Any])?["id"] as? String
        if !isNew || draft.take != nil || (script && forPrompt != currentPrompt?.id) { newTake(script: script) }
        if file != nil { draft.json["source"] = "import" }
        error = nil
        notice = nil
        Dictation.shared.warm()
        let t = LabTake(id: draft.id, dir: DictationLabModel.tmpDir)
        t.onLevel = { [weak self] l in
            Task { @MainActor in
                guard let self = self else { return }
                self.levels.append(l)
                if self.levels.count > 90 { self.levels.removeFirst(self.levels.count - 90) }
            }
        }
        take = t
        levels = []
        elapsed = 0
        phase = .starting
        let ctx = contextForPolish
        t.start(inject: inject, builtIn: mic.isEmpty && Dictation.useBuiltInMic, device: micDevice, context: ctx) { [weak self] ok in
            Task { @MainActor in
                guard let self = self, self.take === t else { return }
                guard ok else {
                    self.phase = .idle
                    self.take = nil
                    Dictation.shared.labReset()
                    self.error = T("dictation.lab.error.mic")
                    return
                }
                self.phase = .recording
            }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let s = self, let t = s.take { s.elapsed = t.elapsed } }
        }
        // a file (or a test wav played as the mic) ends by itself: a release 0.3 s after its last sample
        var stopAt = file.flatMap(DictationLabModel.seconds).map { $0 + 0.4 }
        if stopAt == nil, DictationInsert.testMode, let i = inject {
            stopAt = Dictation.shared.testStopAfter ?? DictationLabModel.seconds(URL(fileURLWithPath: i)).map { $0 + 0.4 }
            Dictation.shared.testStopAfter = nil
        }
        if let s = stopAt {
            let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { if self?.take === t, self?.phase == .recording { self?.stop(via: "end_of_file") } } }
            stopAfter = w
            DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
        }
        emit(["event": "dictation_lab", "action": "record", "via": via, "id": draft.id, "file": file?.lastPathComponent ?? NSNull(),
              "mic": mic.isEmpty ? "default" : mic, "test_mic": inject != nil && file == nil])
    }

    /// The length of an audio file in seconds (read-only).
    static func seconds(_ u: URL) -> Double? {
        guard let f = try? AVAudioFile(forReading: u), f.processingFormat.sampleRate > 0 else { return nil }
        return Double(f.length) / f.processingFormat.sampleRate
    }

    func stop(via: String) {
        guard let t = take, phase == .recording || phase == .starting else { return }
        stopAfter?.cancel()
        timer?.invalidate()
        Dictation.shared.labReset()
        phase = .processing
        let started = draft.created
        let duration = t.elapsed
        let opt = t.options
        t.finish { [weak self] r in
            Task { @MainActor in
                guard let self = self, self.take === t else { return }
                self.take = nil
                self.phase = .idle
                guard let r = r, !r.empty else {
                    self.error = T("dictation.lab.error.nothing")
                    try? FileManager.default.removeItem(at: t.wav)
                    emit(["event": "dictation_lab", "action": "take", "ok": false, "id": t.id])
                    return
                }
                self.pendingAudio = t.wav
                self.fill(r, duration: duration, options: opt, started: started)
            }
        }
        emit(["event": "dictation_lab", "action": "stop", "via": via, "id": t.id])
    }

    func cancel() {
        stopAfter?.cancel()
        timer?.invalidate()
        take?.cancel()
        take = nil
        phase = .idle
        Dictation.shared.labReset()
    }

    /// The text around the cursor as polish gets it (only what the user typed into the lab's two fields).
    private var contextForPolish: DictationContext? {
        guard Dictation.contextOn, !(before.isEmpty && after.isEmpty) else { return nil }
        var c = DictationContext()
        c.before = String(before.suffix(300))
        c.after = String(after.prefix(300))
        c.app = "Blurt"
        return c
    }

    /// The stream's result → the case's take: every stage, fitted into the lab's cursor fields like a real field.
    private func fill(_ r: DictationStream.Result, duration: Double, options opt: DictationStream.Options, started: Date) {
        var text = r.text
        var terms = r.terms
        let active = DictationVocabulary.shared.active().map(\.term)
        if r.biased { for t in active where text.contains(t) && !terms.contains(t) { terms.append(t) } }
        let t0 = CACurrentMediaTime()
        var fitted: [String] = []
        if Dictation.contextOn, !(before.isEmpty && after.isEmpty) {
            let names = Set(active.flatMap { $0.split(separator: " ").map(String.init) })
            let f = DictationFit.fit(text, before: String(before.suffix(500)), after: String(after.prefix(500)), names: names)
            if f.trimmed { text = f.text; fitted = f.changes }
        }
        var timing: [String: Any] = r.timing
        timing["fit_ms"] = Int((CACurrentMediaTime() - t0) * 1000)
        let take: [String: Any] = [
            "segments": r.pieces, "raw": r.raw, "asr_text": r.asrText, "polished": r.polished ?? NSNull(), "text": r.text,
            "fitted": text, "fit": fitted, "terms_applied": terms, "fell_back": r.fellBack, "reason": r.reason ?? NSNull(),
            "repaired": r.repaired, "timings": timing, "language": r.language ?? NSNull(), "asr_model": r.asrModel ?? NSNull(),
            "polish_model": r.model ?? NSNull(), "context_used": r.contextUsed, "biased": r.biased,
        ]
        draft.take = take
        draft.duration = (duration * 100).rounded() / 100
        draft.json["config"] = ["asr_model": r.asrModel ?? NSNull(), "polish": opt.polish, "polish_model": r.model ?? Dictation.shared.polishModel ?? NSNull(),
                                "vocab": !opt.vocab.isEmpty, "context": r.contextUsed, "streaming": opt.streaming,
                                "language": opt.language, "mic": mic.isEmpty ? "default" : mic,
                                "vocab_terms": active] as [String: Any]
        draft.json["app_version"] = Dictation.appVersion
        draft.refreshMetrics(vocabulary: active)
        dirty = true
        // reading a script: every take is kept as a case of its prompt (retakes pile up; "Keep only this" tidies)
        if pane == .script, draft.json["prompt"] is [String: Any] { DispatchQueue.main.async { self.save() } }
        emit(["event": "dictation_lab", "action": "take", "ok": true, "id": draft.id, "raw": r.raw, "text": text,
              "segments": r.pieces.count, "fitted": fitted, "fell_back": r.fellBack, "total_ms": r.timing["total_ms"] ?? 0])
    }

    /// An audio file played in as the microphone (real time, so the timings are what a dictation would see).
    func importAudio() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        p.allowsMultipleSelection = false
        p.message = T("dictation.lab.import.message")
        guard p.runModal() == .OK, let u = p.url else { return }
        record(file: u, via: "import")
    }

    // MARK: saving

    var canSave: Bool {
        phase == .idle && (draft.take != nil || (draft.truth != nil && pane != .script)) && (dirty || isNew)
    }

    func save() {
        guard canSave else { return }
        var c = draft
        if let a = pendingAudio, FileManager.default.fileExists(atPath: a.path) {
            LabStore.shared.adoptAudio(a, into: &c)
            try? FileManager.default.removeItem(at: a)
            pendingAudio = nil
        }
        c.setContext(includeContext ? ["before": before, "after": after] : nil)
        c.refreshMetrics(vocabulary: DictationVocabulary.shared.active().map(\.term))
        guard LabStore.shared.save(c) else { error = T("dictation.lab.error.save"); return }
        let wasNew = isNew
        draft = LabStore.shared.load(c.id) ?? c
        isNew = false
        dirty = false
        notice = T("dictation.lab.saved")
        emit(["event": "dictation_lab", "action": "save", "id": c.id, "new": wasNew, "audio": c.hasAudio,
              "errors": c.errors, "stars": c.stars ?? NSNull(), "context": c.contextIncluded, "problems": c.problems])
        reload()
        learnIfCorrected()
    }

    /// A ground truth that differs from what was heard teaches the custom words: dictation_vocab.learn (through
    /// dictation_lab.py) when it exists, else the app's own learner (the after-typing watch's). What changed is shown,
    /// with Undo.
    private func learnIfCorrected() {
        guard Dictation.learnOn, let fixed = draft.corrected, let take = draft.take else { return }
        let heard = take["raw"] as? String ?? ""
        guard !heard.isEmpty, fixed != heard, draft.json["learned_from"] as? String != fixed else { return }
        let id = draft.id
        let url = DictationVocabulary.shared.url
        let before = LabVocab.snapshot(url)
        Scripts.call("dictation_lab.py", ["learn", "--raw", heard, "--corrected", fixed], timeout: 60) { [weak self] r in
            guard let self = self else { return }
            var changes: [LabVocab.Change] = []
            var via = "dictation_vocab"
            if case .success(let o) = r, o["available"] as? Bool == true {
                changes = (o["changes"] as? [[String: Any]] ?? []).compactMap(LabVocab.Change.init(json:))
            } else {
                // not there yet (or the CLI failed): the app's own learner, on what was heard against the truth
                via = "app"
                for f in DictationLearn.fixes(typed: heard, edited: fixed, isCommonWord: DictationLearn.isCommonWord) {
                    _ = DictationVocabulary.shared.learn(heard: f.heard, fixed: f.fixed)
                }
                changes = LabVocab.changes(before: before, after: LabVocab.snapshot(url))
            }
            guard var c = LabStore.shared.load(id) else { return }
            c.json["learned_from"] = fixed
            c.json["learned"] = changes.map { ["term": $0.term, "before": $0.before ?? NSNull(), "after": $0.after ?? NSNull()] as [String: Any] }
            LabStore.shared.save(c)
            if self.draft.id == id {
                self.draft.json["learned_from"] = fixed
                self.draft.json["learned"] = c.json["learned"]
                self.learned = changes
                self.learnedVia = via
            }
            emit(["event": "dictation_lab", "action": "learn", "id": id, "via": via, "changes": changes.map(\.summary)])
        }
    }

    func undoLearned() {
        let back = LabVocab.revert(learned, in: DictationVocabulary.shared)
        emit(["event": "dictation_lab", "action": "unlearn", "id": draft.id, "terms": back])
        learned = []
        if var c = LabStore.shared.load(draft.id) {
            c.json["learned"] = [Any]()
            LabStore.shared.save(c)
            draft.json["learned"] = [Any]()
        }
        notice = T("dictation.lab.learn.undone")
    }

    // MARK: compare (dictation_lab.py rerun)

    func loadOptions() {
        Scripts.call("dictation_lab.py", ["configs"], timeout: 120) { [weak self] r in
            guard let self = self, case .success(let o) = r else { return }
            var out: [Option] = []
            let asr = (o["asr"] as? [String: Any])?["models"] as? [[String: Any]] ?? []
            let selAsr = (o["asr"] as? [String: Any])?["selected"] as? String
            for m in asr { if let id = m["id"] as? String, id != selAsr { out.append(Option(spec: "asr=\(id)", label: m["name"] as? String ?? id)) } }
            let pol = (o["polish"] as? [String: Any])?["models"] as? [[String: Any]] ?? []
            let selPol = (o["polish"] as? [String: Any])?["selected"] as? String
            for m in pol { if let id = m["id"] as? String, id != selPol { out.append(Option(spec: "polish=\(id)", label: T("dictation.lab.compare.polish_with", m["name"] as? String ?? id))) } }
            out += [Option(spec: "polish=off", label: T("dictation.lab.compare.polish_off")),
                    Option(spec: "vocab=off", label: T("dictation.lab.compare.vocab_off")),
                    Option(spec: "context=off", label: T("dictation.lab.compare.context_off")),
                    Option(spec: "mode=whole", label: T("dictation.lab.compare.whole"))]
            self.options = [Option(spec: "current", label: T("dictation.lab.compare.current"))] + out
            if self.chosen.isEmpty { self.chosen = ["current", "polish=off"] }
        }
    }

    func rerun() {
        guard !isNew, draft.hasAudio, !rerunning, !chosen.isEmpty else { return }
        let specs = options.map(\.spec).filter { chosen.contains($0) }
        rerunning = true
        error = nil
        let id = draft.id
        emit(["event": "dictation_lab", "action": "rerun", "id": id, "configs": specs])
        Scripts.call("dictation_lab.py", ["rerun", id, "--save"] + specs.flatMap { ["--config", $0] }, timeout: 900) { [weak self] r in
            guard let self = self else { return }
            self.rerunning = false
            switch r {
            case .success(let o):
                let labels = Dictionary(uniqueKeysWithValues: self.options.map { ($0.spec, $0.label) })
                let rows = (o["results"] as? [[String: Any]] ?? []).enumerated().map { i, x -> Rerun in
                    let spec = i < specs.count ? specs[i] : x["key"] as? String ?? ""
                    var row = Rerun(label: labels[spec] ?? spec, spec: spec)
                    row.outputs = x["outputs"] as? [String: Any] ?? [:]
                    row.error = x["error"] as? String
                    return row
                }
                if self.draft.id == id { self.reruns = rows }
                emit(["event": "dictation_lab", "action": "rerun_done", "id": id, "rows": rows.map { ["label": $0.label, "text": $0.text, "error": $0.error ?? NSNull()] as [String: Any] }])
            case .failure(let f):
                self.error = f.localized
                emit(["event": "dictation_lab", "action": "rerun_done", "id": id, "error": f.code])
            }
        }
    }

    // MARK: run all cases (dictation_lab.py run)

    func runAll() {
        guard !running else { return }
        running = true
        pane = .regression
        emit(["event": "dictation_lab", "action": "run_all", "config": runSpec])
        Scripts.call("dictation_lab.py", ["run", "--json", "--config", runSpec], timeout: 3600) { [weak self] r in
            guard let self = self else { return }
            self.running = false
            switch r {
            case .success(let o):
                self.runResult = o
                emit(["event": "dictation_lab", "action": "run_all_done", "overall": o["overall"] ?? NSNull()])
            case .failure(let f):
                self.error = f.localized
                emit(["event": "dictation_lab", "action": "run_all_done", "error": f.code])
            }
            self.reload()
        }
    }

    // MARK: export, history

    func export(to url: URL? = nil) {
        var target = url
        if target == nil {
            let p = NSSavePanel()
            p.allowedContentTypes = [.zip]
            p.nameFieldStringValue = "blurt-dictation-lab.zip"
            guard p.runModal() == .OK else { return }
            target = p.url
        }
        guard let out = target else { return }
        Scripts.call("dictation_lab.py", ["export", "--out", out.path], timeout: 600) { [weak self] r in
            switch r {
            case .success(let o):
                self?.notice = T("dictation.lab.exported", o["cases"] as? Int ?? 0)
                emit(["event": "dictation_lab", "action": "export", "path": out.path, "cases": o["cases"] ?? 0])
                if !DictationInsert.testMode { NSWorkspace.shared.activateFileViewerSelecting([out]) }
            case .failure(let f):
                self?.error = f.localized
            }
        }
    }

    /// A history entry as a case (its audio when it was kept, else text only), then shown in the lab.
    func add(fromHistory id: String, then: (() -> Void)? = nil) {
        Scripts.call("dictation_lab.py", ["from-history", id, "--app-version", Dictation.appVersion], timeout: 60) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let o):
                self.reload()
                if let cid = (o["case"] as? [String: Any])?["id"] as? String { self.open(cid) }
                self.notice = (o["case"] as? [String: Any])?["audio"] is String ? T("dictation.lab.added") : T("dictation.lab.added_text_only")
                emit(["event": "dictation_lab", "action": "from_history", "id": id, "case": (o["case"] as? [String: Any])?["id"] ?? NSNull(),
                      "audio": (o["case"] as? [String: Any])?["audio"] ?? NSNull(), "existed": o["existed"] ?? false])
                then?()
            case .failure(let f):
                self.error = f.localized
            }
        }
    }

    func setKeepNext(_ n: Int) {
        keepNext = max(0, n)
        Dictation.set("lab_keep_next", keepNext > 0 ? keepNext : nil)
        emit(["event": "dictation_lab", "action": "keep_next", "n": keepNext])
    }

    // MARK: reading scripts (packs: dictation_lab.py's schema; built-in lab_packs/ + $BLURT_HOME/dictation/lab/packs/)

    struct Prompt: Identifiable {
        let id: String
        let read: String
        /// what the dictation should type (fillers and the corrected-away words gone); the case's reference
        let expected: String
        let tags: [String: Any]
        var tagList: [String] {
            var out: [String] = []
            for k in ["length", "scenario", "languages"] { if let v = tags[k] as? String { out.append("\(k).\(v)") } }
            for f in tags["features"] as? [String] ?? [] { out.append("features.\(f)") }
            return out
        }
    }

    struct Pack: Identifiable {
        let id: String
        let name: String
        let source: String
        let prompts: [Prompt]
        let builtin: Bool
    }

    @Published var packs: [Pack] = []
    @Published var packID: String? { didSet { if packID != oldValue { promptIndex = firstUnread } } }
    @Published var promptIndex = 0
    @Published var generating = false

    var currentPack: Pack? { packs.first { $0.id == packID } ?? packs.first }
    var currentPrompt: Prompt? {
        guard let p = currentPack, !p.prompts.isEmpty else { return nil }
        return p.prompts[min(max(0, promptIndex), p.prompts.count - 1)]
    }

    static var builtinPacks: URL { BlurtPaths.scripts.appendingPathComponent("lab_packs") }
    static var userPacks: URL { BlurtPaths.home.appendingPathComponent("dictation/lab/packs") }

    func loadPacks() {
        var byID: [String: Pack] = [:]
        var order: [String] = []
        for (dir, builtin) in [(DictationLabModel.builtinPacks, true), (DictationLabModel.userPacks, false)] {
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for f in files {
                guard let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      o["schema"] as? Int == 1, let id = o["id"] as? String, let qs = o["prompts"] as? [[String: Any]] else { continue }
                let prompts = qs.compactMap { q -> Prompt? in
                    guard let pid = q["id"] as? String, let read = q["read"] as? String, !read.isEmpty else { return nil }
                    return Prompt(id: pid, read: read, expected: (q["expected"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? read,
                                  tags: q["tags"] as? [String: Any] ?? [:])
                }
                let name = Loc.isChinese ? (o["name_zh"] as? String ?? o["name"] as? String ?? id) : (o["name"] as? String ?? id)
                if byID[id] == nil { order.append(id) }
                byID[id] = Pack(id: id, name: name, source: o["source"] as? String ?? "", prompts: prompts, builtin: builtin && byID[id] == nil)
            }
        }
        packs = order.compactMap { byID[$0] }
        if packID == nil || !packs.contains(where: { $0.id == packID }) {
            // the user's own pack first (it was made for them), else the built-in one
            packID = packs.first { !$0.builtin }?.id ?? packs.first?.id
        }
    }

    /// The takes recorded for a prompt (newest first).
    func takes(_ q: Prompt?) -> [LabCase] {
        guard let q = q, let p = currentPack else { return [] }
        return cases.filter { c in
            let x = c.json["prompt"] as? [String: Any]
            return x?["pack"] as? String == p.id && x?["id"] as? String == q.id
        }
    }

    var progress: (done: Int, total: Int) {
        guard let p = currentPack else { return (0, 0) }
        let read = Set(cases.compactMap { c -> String? in
            let x = c.json["prompt"] as? [String: Any]
            return x?["pack"] as? String == p.id ? x?["id"] as? String : nil
        })
        return (p.prompts.filter { read.contains($0.id) }.count, p.prompts.count)
    }

    private var firstUnread: Int {
        guard let p = currentPack else { return 0 }
        return p.prompts.firstIndex { takes($0).isEmpty } ?? 0
    }

    func startScript() {
        guard phase == .idle else { return }
        if packs.isEmpty { loadPacks() }
        pane = .script
        newTake(script: true)
        emit(["event": "dictation_lab", "action": "script", "pack": currentPack?.id ?? NSNull(), "prompt": currentPrompt?.id ?? NSNull()])
    }

    func go(prompt delta: Int) {
        guard phase == .idle, let p = currentPack, !p.prompts.isEmpty else { return }
        promptIndex = min(max(0, promptIndex + delta), p.prompts.count - 1)
        newTake(script: true)
        emit(["event": "dictation_lab", "action": "prompt", "pack": p.id, "index": promptIndex, "prompt": currentPrompt?.id ?? NSNull()])
    }

    /// The next prompt nothing was recorded for yet (after this one), else simply the next.
    func nextUnread() {
        guard let p = currentPack else { return }
        let after = p.prompts.indices.dropFirst(promptIndex + 1).first { takes(p.prompts[$0]).isEmpty }
        go(prompt: (after ?? min(promptIndex + 1, p.prompts.count - 1)) - promptIndex)
    }

    /// Keeps one take of the prompt, the others go to the Trash.
    func keepOnly(_ id: String) {
        let others = takes(currentPrompt).filter { $0.id != id }
        for c in others { try? FileManager.default.trashItem(at: LabStore.shared.folder(c.id), resultingItemURL: nil) }
        emit(["event": "dictation_lab", "action": "keep_only", "id": id, "trashed": others.map(\.id)])
        reload()
        open(id, keepPane: true)
    }

    func importPack() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        p.message = T("dictation.lab.script.import.message")
        guard p.runModal() == .OK, let u = p.url else { return }
        importPack(u)
    }

    func importPack(_ u: URL) {
        Scripts.call("dictation_lab.py", ["import-pack", u.path], timeout: 60) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let o):
                self.loadPacks()
                self.packID = o["id"] as? String
                self.notice = T("dictation.lab.script.imported", o["prompts"] as? Int ?? 0)
                emit(["event": "dictation_lab", "action": "import_pack", "id": o["id"] ?? NSNull(), "prompts": o["prompts"] ?? 0])
            case .failure(let f):
                self.error = f.code == "bad_pack" ? T("dictation.lab.script.bad_pack") : f.localized
            }
        }
    }

    /// Ten more prompts in the pack's style: the configured processing agent, else the local polish model.
    func generateMore() {
        guard let p = currentPack, !generating else { return }
        generating = true
        emit(["event": "dictation_lab", "action": "generate", "pack": p.id])
        Scripts.call("dictation_lab.py", ["generate", "--pack", p.id, "--n", "10"], timeout: 900) { [weak self] r in
            guard let self = self else { return }
            self.generating = false
            switch r {
            case .success(let o):
                self.loadPacks()
                self.notice = T("dictation.lab.script.generated", o["added"] as? Int ?? 0)
                emit(["event": "dictation_lab", "action": "generated", "pack": p.id, "added": o["added"] ?? 0, "engine": o["engine"] ?? NSNull()])
            case .failure(let f):
                self.error = T("dictation.lab.script.generate_failed")
                emit(["event": "dictation_lab", "action": "generated", "pack": p.id, "error": f.code])
            }
        }
    }

    // MARK: for the views

    /// a section of the workbench to bring into view (tests, screenshots): "top", "stages", "markup", "compare"
    @Published var scrollTarget: String?

    var truth: String? { draft.truth }
    var finalText: String? { draft.finalText }
    var score: LabMetrics.Score? {
        guard let t = truth, let h = finalText else { return nil }
        return LabMetrics.score(t, h, terms: LabMetrics.expectedTerms(t, vocabulary: DictationVocabulary.shared.active().map(\.term) + draft.expectedTerms))
    }
    func score(of text: String) -> LabMetrics.Score? {
        guard let t = truth else { return nil }
        return LabMetrics.score(t, text, terms: LabMetrics.expectedTerms(t, vocabulary: DictationVocabulary.shared.active().map(\.term) + draft.expectedTerms))
    }
}

// MARK: - test hooks (BLURT_TEST_COMMANDS: `dictation lab …`)

extension DictationLabModel {
    /// show | tab history|lab | new | record | stop | import PATH | set reference|corrected|note|before|after TEXT |
    /// include on|off | tag TAG | scenario KEY VALUE | stars N | good yes|no|- | mic NAME|- | save | open ID|first |
    /// delete ID | compare SPEC|SPEC | runall [SPEC] | regression | export PATH | from-history ID|first | keep N |
    /// undo-learn | scroll top|stages|markup|compare | status
    static func testCommand(_ arg: String) {
        let c = MainWindowController.shared
        let page = c.dictation
        let lab = page.lab
        let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = parts.count > 1 ? parts[1] : ""
        func kv() -> (String, String) {
            let a = rest.split(separator: " ", maxSplits: 1).map(String.init)
            return (a.first ?? "", a.count > 1 ? a[1] : "")
        }
        switch parts.first ?? "status" {
        case "show": c.showDictationLab()
        case "tab": page.model.tab = rest == "history" ? .history : .lab
        case "new": lab.newTake()
        case "record": lab.toggleRecord()
        case "stop": lab.stop(via: "test")
        case "import": lab.record(file: URL(fileURLWithPath: rest), via: "import")
        case "set":
            let (k, v) = kv()
            switch k {
            case "reference": lab.edit { $0.reference = v }
            case "corrected": lab.edit { $0.corrected = v }
            case "note": lab.edit { $0.note = v }
            case "before": lab.before = v
            case "after": lab.after = v
            default: break
            }
        case "include": lab.includeContext = rest == "on"
        case "tag":
            lab.edit { c in
                var e = c.errors
                if let i = e.firstIndex(of: rest) { e.remove(at: i) } else { e.append(rest) }
                c.errors = e
            }
        case "scenario":
            let (k, v) = kv()
            lab.edit { c in var s = c.scenario; s[k] = v; c.scenario = s }
        case "stars": lab.edit { $0.stars = Int(rest) }
        case "good": lab.edit { $0.good = rest == "yes" ? true : rest == "no" ? false : nil }
        case "mic": lab.setMic(rest == "-" ? "" : rest)
        case "save": lab.save()
        case "open": if let id = rest == "first" ? lab.cases.first?.id : rest { lab.open(id, keepPane: lab.pane == .script) }
        case "delete": lab.delete(rest)
        case "compare":
            lab.chosen = Set(rest.split(separator: "|").map(String.init))
            lab.rerun()
        case "runall":
            if !rest.isEmpty { lab.runSpec = rest }
            lab.runAll()
        case "regression": lab.pane = .regression
        case "export": lab.export(to: URL(fileURLWithPath: rest))
        case "from-history":
            let id = rest == "first" ? page.model.entries.first?.id : rest
            if let e = DictationHistory.shared.load().first(where: { $0.id == id }) { page.addToLab(e) }
        case "keep": lab.setKeepNext(Int(rest) ?? 0)
        case "undo-learn": lab.undoLearned()
        case "scroll": lab.scrollTarget = rest
        case "script": lab.startScript()
        case "pack":
            lab.loadPacks()
            if !rest.isEmpty { lab.packID = rest }
            lab.startScript()
        case "prompt":
            if rest == "next" { lab.nextUnread() } else if rest == "prev" { lab.go(prompt: -1) } else if let n = Int(rest) { lab.go(prompt: n - lab.promptIndex) }
        case "keep-only": lab.keepOnly(rest.isEmpty ? lab.draft.id : rest)
        case "import-pack": lab.importPack(URL(fileURLWithPath: rest))
        case "generate": lab.generateMore()
        default: break
        }
        emit(["event": "dictation_lab_status", "cmd": parts.first ?? "status", "tab": page.model.tab.rawValue, "phase": lab.phase.rawValue,
              "pane": "\(lab.pane)", "new": lab.isNew, "id": lab.draft.id, "cases": lab.cases.count,
              "take": lab.draft.take != nil, "dirty": lab.dirty, "error": lab.error ?? NSNull(), "notice": lab.notice ?? NSNull(),
              "learned": lab.learned.map(\.summary), "options": lab.options.map(\.spec), "wants_key": lab.wantsKey,
              "keep_next": lab.keepNext, "wer": lab.score?.wer ?? NSNull(),
              "pack": lab.currentPack?.id ?? NSNull(), "prompt": lab.currentPrompt?.id ?? NSNull(), "prompt_index": lab.promptIndex,
              "progress": [lab.progress.done, lab.progress.total], "packs": lab.packs.map(\.id)])
    }
}
