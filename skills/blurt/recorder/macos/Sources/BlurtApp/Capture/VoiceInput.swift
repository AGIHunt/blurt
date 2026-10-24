// Voice input (K7, ⌥⇧V): talk, and it becomes a capture — no screen recording, just the words.
//
// v0.8.6 — the report: any breath or thinking pause ended the voice note (1.5 s of silence did), fine for a short
// note, bad for a long one. Now you end it:
//  • press once: listening starts; press ⌥⇧V again (or the island's Done) to finish; Esc cancels. A pause no longer
//    ends it — unless Settings → General → "End a voice note when I pause" (record.voice.end_on_pause, off) is on:
//    then 1.5 s of silence after you spoke does, as before (record.voice.silence_ms). 10 minutes at most
//    (record.voice.max_seconds, 600; the right ear shows the time, the island the time left in the last minute);
//    nothing heard within 20 s (8 s with end_on_pause) = nothing filed.
//  • hold longer than 0.35 s: push-to-talk — it ends when you let go.
//  • record.voice.mode: auto (both, default) | toggle | hold.
//  • the snap's spoken note (⌥⇧A, NoteBubble) keeps its silence end: it is a sentence about one picture.
//  • the words while you talk (record.live_text, on — "Show text while I talk"): VoiceNoteStream cuts the audio at
//    pauses as it comes in (BlurtCore's DictationSegmenter, as dictation does) and each piece goes to the warm speech
//    server as soon as it is complete (`note`, the voice-note model, the text so far as context); the text so far
//    shows in LiveTranscript under the island. At stop only the last piece is left, so the card has its words about
//    as soon as it is caught. A piece that failed → the whole wav through `transcribe.py note`, the old way. (The
//    pieces run whether or not the panel shows: the words are ready at stop either way. record.voice.stream false =
//    the old path only.)
//  • the wav goes to shots/<NNN>.wav of the current store's open shots batch (`said` = the words; K9).
//    Pressing starts `transcribe.py serve --preload` (once; it exits by itself when idle), so the model is warm by the
//    time the first piece is complete.
//    With a current project it goes straight into the island; in auto mode it hangs from the island on a thread.
//  • while recording it does nothing (the recording already has the mic) and says so.
// Tests: BLURT_TEST_MIC_WAV (or BLURT_NOTE_WAV) is fed through the same path instead of the microphone;
// BLURT_TEST_NO_SERVERS=1 starts no warm server (the pieces go through the CLI: no local port is opened).

import AppKit
import BlurtCore
import Carbon.HIToolbox

final class VoiceInput {
    static let shared = VoiceInput()
    static let holdThreshold: CFTimeInterval = 0.35

    private(set) var active = false
    private(set) var holding = false
    private(set) var levels: [Float] = []
    /// the words so far (the pieces transcribed while talking)
    private(set) var liveText: String?
    private var voice: NoteVoice?
    private var stream: VoiceNoteStream?
    private var batch: ShotBatch?
    private var n = 0
    private var pressedAt: CFTimeInterval?
    private var startedAt = Date()
    private var heardSpeech = false
    /// this take's live transcript (LiveTranscript's session)
    private var liveSession = 0

    var elapsed: Double { active ? voice?.elapsed ?? Date().timeIntervalSince(startedAt) : 0 }

    private var settings: [String: Any] { recordConfig()["voice"] as? [String: Any] ?? [:] }
    private var mode: String { settings["mode"] as? String ?? "auto" }
    private var silence: Double { (settings["silence_ms"] as? Double ?? 1500) / 1000 }
    /// "End a voice note when I pause" (off): a pause of `silence` ends it, as before v0.8.6
    static var endOnPause: Bool { (recordConfig()["voice"] as? [String: Any])?["end_on_pause"] as? Bool ?? false }
    static func setEndOnPause(_ on: Bool) { Config.shared.set("record.voice.end_on_pause", on ? true : nil) }
    /// the longest voice note (seconds)
    var maxSeconds: Double { max(30, (settings["max_seconds"] as? Double) ?? 600) }
    /// transcribe while talking (off: the whole wav after stop, the old path)
    private var streams: Bool { settings["stream"] as? Bool ?? true }
    /// what the island says it will take to finish: the key, else the Done button
    var endsOnPause: Bool { VoiceInput.endOnPause && !holding }

    // MARK: the hotkey: down / up

    func pressed() {
        if (NSApp.delegate as? App)?.rec != nil {
            island.toast(Loc.t("capture.voice.recording_busy", table: "Capture"), actionTitle: nil, action: nil)
            return
        }
        pressedAt = CACurrentMediaTime()
        if active {
            if mode != "hold" { finish(keep: true, via: "key") }
            return
        }
        start()
    }

    func released() {
        guard let t = pressedAt else { return }
        pressedAt = nil
        guard active else { return }
        let held = CACurrentMediaTime() - t >= VoiceInput.holdThreshold
        if mode == "hold" || (mode == "auto" && held) {
            if holding || mode == "hold" { finish(keep: true, via: "release") }
        }
    }

    /// The island's mic button, and its Done.
    func toggle() { active ? finish(keep: true, via: "button") : start() }

    func cancel() { if active { finish(keep: false, via: "esc") } }

    // MARK: listening

    private func start() {
        guard !active else { return }
        // one listener at a time: dictation has the microphone (and Esc) until it is done
        if Dictation.shared.phase == .listening {
            island.toast(Loc.t("capture.voice.dictation_busy", table: "Capture"), actionTitle: nil, action: nil)
            return
        }
        if NoteBubble.shared.isOpen { NoteBubble.shared.commit() }
        let b = snapper.openBatch(for: snapper.target)
        let k = b.reserve()
        let url = b.dir.appendingPathComponent("shots/\(ShotBatch.name(k)).wav")
        let v = NoteVoice(url: url)
        v.inject = ProcessInfo.processInfo.environment["BLURT_TEST_MIC_WAV"] ?? ProcessInfo.processInfo.environment["BLURT_NOTE_WAV"]
        let pauseEnds = VoiceInput.endOnPause
        v.silenceToEnd = pauseEnds ? silence : .infinity
        v.noSpeechTimeout = pauseEnds ? 8 : 20
        v.maxLength = maxSeconds
        v.onLevel = { [weak self] l in
            guard let self = self else { return }
            self.levels.append(l)
            if self.levels.count > 120 { self.levels.removeFirst(self.levels.count - 120) }
        }
        v.onSpeech = { [weak self] in self?.heardSpeech = true }
        v.onEnd = { [weak self] e in
            guard let self = self, self.voice === v else { return }
            if e == .maxed { island.toast(Loc.t("capture.voice.maxed", table: "Capture", Island.clock(self.maxSeconds)), actionTitle: nil, action: nil) }
            self.finish(keep: e != .noSpeech, ended: true, via: "\(e)")
        }
        let live = LiveTranscript.shared.begin(.voice)
        liveSession = live
        let st = streams ? VoiceNoteStream(id: "\(ShotBatch.name(k))-\(Int(Date().timeIntervalSince1970))") : nil
        st?.onText = { [weak self] t in
            if let self = self, self.stream === st { self.liveText = t }
            LiveTranscript.shared.update(t, session: live)
        }
        if let s = st { v.onSamples = { [weak s] x in s?.append(x) } }
        voice = v
        stream = st
        batch = b
        n = k
        levels = []
        liveText = nil
        heardSpeech = false
        holding = false
        startedAt = Date()
        active = true
        Self.warmSpeechModel()
        registerHotkey(.voiceEsc, key: kVK_Escape, mods: 0)
        emit(["event": "voice_start", "n": k, "session": b.dir.path, "end_on_pause": pauseEnds, "max_seconds": maxSeconds,
              "stream": st != nil, "live_text": LiveTranscript.enabled, "wall": Date().timeIntervalSince1970])
        island.voiceChanged()
        v.start { [weak self] ok in
            guard let self = self, self.voice === v else { return }
            if !ok {
                self.finish(keep: false, via: "no_mic")
                NoteVoice.toastUnavailable()
            }
        }
        // held past the threshold: push-to-talk — only letting go ends it
        DispatchQueue.main.asyncAfter(deadline: .now() + VoiceInput.holdThreshold) { [weak self] in
            guard let self = self, self.voice === v, self.pressedAt != nil, self.mode != "toggle" else { return }
            self.holding = true
            v.silenceToEnd = .infinity
            v.noSpeechTimeout = .infinity
            emit(["event": "voice_hold"])
            island.voiceChanged()
        }
    }

    private static var server: Process?

    /// K9's voice-note server: answers "already" when one runs (this app's or another), else stays up on its own
    /// (unloads the model after 5 idle minutes, exits after 30).
    /// dictation: its own model (record.dictation.asr_model / the recommended one) — a running server is asked to
    /// load it, a new one preloads it.
    static func warmSpeechModel(dictation: Bool = false) {
        if dictation && WarmServer.running("asr-serve") {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = WarmServer.call("asr-serve", ["cmd": "load", "purpose": "dictation"], timeout: 30)
            }
            return
        }
        if let s = server, s.isRunning { return }
        server = WarmSpawn.start("transcribe.py", ["serve", "--preload"] + (dictation ? ["--purpose", "dictation"] : []), server: "asr-serve")
    }

    /// Our server process runs but hasn't written its address yet (dictation's pieces wait for it, not for a CLI).
    static var serverStarting: Bool { server?.isRunning == true && !WarmServer.running("asr-serve") }

    /// One piece of a voice note → its words: the warm server (`note`, the voice-note model), else the CLI (which
    /// asks the server itself, or loads the model). Blocking: off the main thread.
    static func transcribePiece(_ wav: URL, prior: String) -> [String: Any]? {
        var req: [String: Any] = ["cmd": "note", "wav": wav.path, "language": "auto"]
        if !prior.isEmpty { req["prior"] = String(prior.suffix(200)) }
        let until = Date().addingTimeInterval(15)
        while !WarmServer.running("asr-serve") && Date() < until && serverStarting { usleep(50_000) }
        if let r = WarmServer.call("asr-serve", req, timeout: 60), r["ok"] as? Bool == true { return r }
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any]?
        Task.detached {
            out = try? await ScriptRunner.shared.json("transcribe.py", ["note", wav.path, "--language", "auto"], timeout: 120)
            sem.signal()
        }
        sem.wait()
        return out.flatMap { ($0["ok"] as? Bool ?? true) ? $0 : nil }
    }

    private func finish(keep: Bool, ended: Bool = false, via: String) {
        guard active, let v = voice, let b = batch else { return }
        let dur = v.elapsed
        let kept = keep && heardSpeech
        if !ended { v.stop(keep: kept) } else if !kept { v.stop(keep: false) }
        let st = stream
        voice = nil
        stream = nil
        batch = nil
        active = false
        holding = false
        unregisterHotkey(.voiceEsc)
        emit(["event": "voice_end", "kept": kept, "duration": (dur * 100).rounded() / 100, "via": via,
              "pieces": st?.count ?? 0, "wall": Date().timeIntervalSince1970])
        let project = snapper.target
        island.voiceChanged()
        let live = liveSession
        if kept {
            // the words stay a moment once the last piece is in (the card has them by then)
            st?.onFinished = { t in
                if let t = t, !t.isEmpty { LiveTranscript.shared.update(t, session: live) }
                LiveTranscript.shared.end(session: live, after: 1.2)
            }
            if st == nil { LiveTranscript.shared.end(session: live, after: 0.4) }
            snapper.voiceFinished(batch: b, n: n, duration: dur, project: project.isInbox ? nil : project.id, stream: st)
        } else {
            st?.cancel()
            LiveTranscript.shared.end(session: live)
            if keep { island.toast(Loc.t("capture.voice.nothing", table: "Capture"), actionTitle: nil, action: nil) }
        }
    }
}

/// A voice note transcribed while it is being said: the audio is cut at pauses (DictationSegmenter, as dictation
/// does: ≥ 0.5 s of quiet, pieces of ≥ 3 s, at most 20 s) and each piece goes to the speech model as soon as it is
/// complete, on one serial queue, the text so far as context. `finish` sends the rest and answers with the whole
/// text (DictationStitch.joinPieces) — nil when a piece failed (the caller transcribes the whole wav then).
final class VoiceNoteStream {
    let id: String
    /// the text so far, on the main queue, after each piece
    var onText: ((String) -> Void)?
    /// the whole text (nil: a piece failed), on the main queue, just before `finish`'s own answer
    var onFinished: ((String?) -> Void)?
    private var segmenter = DictationSegmenter(sampleRate: NoteVoice.rate)
    private var audio: [Float] = []         // main thread; audio[0] is sample `base` of the take
    private var base = 0
    private var total = 0
    private var pieceStart = 0
    private var pieceHard = false
    private var queued = 0
    private let q = DispatchQueue(label: "blurt.voice.pieces", qos: .userInitiated)
    private let lock = NSLock()
    private var texts: [String] = []        // q
    private var pauses: [Double?] = []      // under lock
    private var failed = false              // q
    private var cancelled = false           // under lock
    private let dir: URL

    var count: Int { queued }

    init(id: String) {
        self.id = id
        dir = BlurtPaths.home.appendingPathComponent("tmp/voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: while talking (main thread)

    func append(_ x: [Float]) {
        audio += x
        total += x.count
        let cuts = segmenter.feed(x)
        let known = segmenter.pauses
        lock.lock(); pauses = known; lock.unlock()
        for cut in cuts {
            enqueue(start: pieceStart, end: cut.end, hard: pieceHard)
            pieceStart = cut.nextStart
            pieceHard = cut.hard
            // what no piece will need again (a hard cut's next piece starts 0.8 s back, never before this)
            let drop = pieceStart - base
            if drop > 0 { audio.removeFirst(min(drop, audio.count)); base = pieceStart }
        }
    }

    private func enqueue(start: Int, end: Int, hard: Bool) {
        guard end > start else { return }
        let samples = Array(audio[max(0, start - base)..<max(0, min(end - base, audio.count))])
        let i = queued
        queued += 1
        emit(["event": "voice_piece", "id": id, "index": i, "start": Double(start) / NoteVoice.rate, "end": Double(end) / NoteVoice.rate,
              "hard": hard])
        q.async { self.transcribe(i, samples, hard: hard) }
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    // MARK: the work (q)

    private func transcribe(_ i: Int, _ samples: [Float], hard: Bool) {
        guard !isCancelled else { return }
        let url = dir.appendingPathComponent("\(id)-p\(i).wav")
        DictationStream.writeWav(samples, to: url)
        let gaps = { () -> [Double?] in self.lock.lock(); defer { self.lock.unlock() }; return self.pauses }
        let prior = DictationStitch.joinPieces(texts, pauses: gaps())
        let t0 = CACurrentMediaTime()
        let r = VoiceInput.transcribePiece(url, prior: prior)
        try? FileManager.default.removeItem(at: url)
        if r == nil { failed = true }
        var text = (r?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if hard, let prev = texts.last { text = DictationStitch.dropOverlap(previous: prev, next: text) }
        texts.append(text)
        let joined = DictationStitch.joinPieces(texts, pauses: gaps())
        emit(["event": "voice_piece_text", "id": id, "index": i, "ok": r != nil, "chars": text.count,
              "ms": Int((CACurrentMediaTime() - t0) * 1000), "audio_s": (Double(samples.count) / NoteVoice.rate * 100).rounded() / 100])
        guard !isCancelled else { return }
        DispatchQueue.main.async { if !joined.isEmpty { self.onText?(joined) } }
    }

    // MARK: stop

    /// The rest of the audio as the last piece, then the whole text (main queue). nil: a piece failed.
    func finish(_ done: @escaping (String?) -> Void) {
        let tail = total - pieceStart
        if queued == 0 || (tail > Int(0.3 * NoteVoice.rate) && segmenter.pieceHasSpeech) {
            enqueue(start: pieceStart, end: total, hard: pieceHard)
        }
        audio = []
        q.async {
            let lock = self.lock
            lock.lock(); let gaps = self.pauses; lock.unlock()
            let text = self.failed ? nil : DictationStitch.joinPieces(self.texts, pauses: gaps)
            DispatchQueue.main.async {
                self.onFinished?(text)
                self.onFinished = nil
                self.onText = nil           // (its closure holds the stream)
                done(text)
            }
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        onText = nil
        onFinished = nil
        audio = []
    }
}
