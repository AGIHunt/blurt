// Voice note (K7, ⌥⇧V): talk, and it becomes a capture — no screen recording, just the words. (Not dictation: that
// types at the cursor. This one files a card.)
//
// v0.8.6 — the report: any breath or thinking pause ended the voice note (1.5 s of silence did), fine for a short
// note, bad for a long one. Now you end it:
//  • press once: listening starts; press ⌥⇧V again (or the island's Done) to finish. A pause no longer
//    ends it — unless Settings → General → "End a voice note when I pause" (record.voice.end_on_pause, off) is on:
//    then 1.5 s of silence after you spoke does, as before (record.voice.silence_ms). 10 minutes at most
//    (record.voice.max_seconds, 600; the right ear shows the time, the island the time left in the last minute);
//    nothing heard within 20 s (8 s with end_on_pause) = nothing filed.
//  • hold longer than 0.35 s: push-to-talk — it ends when you let go.
//  • record.voice.mode: auto (both, default) | toggle | hold.
//  • the snap's spoken note (⌥⇧A, NoteBubble) keeps its silence end: it is a sentence about one picture.
//  • the words while you talk (record.live_text, on — "Show text while I talk"): VoiceNoteStream cuts the audio at
//    pauses as it comes in (BlurtCore's DictationSegmenter, as dictation does) and each piece goes to the warm speech
//    server as soon as it is complete (`note`, the voice-note model, the text so far as context); about once a second
//    the piece still being said is decoded as an interim request (v0.9, as dictation's live text: quieter until its
//    piece is final) on every tier — the note model is quick (`liveWords`); the text so far shows in LiveTranscript under the island. At stop only the last piece is left, so the card has its words about
//    as soon as it is caught. A piece that failed → the whole wav through `transcribe.py note`, the old way. (The
//    pieces run whether or not the panel shows: the words are ready at stop either way. record.voice.stream false =
//    the old path only.)
//  • the wav goes to shots/<NNN>.wav of the current store's open shots batch (`said` = the words; K9).
//    Pressing starts `transcribe.py serve --preload` (once; it exits by itself when idle), so the model is warm by the
//    time the first piece is complete.
//    With a current project it goes straight into the island; in auto mode it hangs from the island on a thread.
//  • while recording it does nothing (the recording already has the mic) and says so.
//  • Esc cancels — only in its first 10 s (escSeconds): plain Esc is a hotkey for every app while Blurt holds it, and
//    a vibe coder presses Esc in Claude Code or vim all the time, so it is given back as soon as a mistaken start is
//    no longer likely (the island stops saying "Esc to cancel"); after that, the key again or Done ends it. A cancel
//    keeps the audio for 5 s: "Voice note discarded · Undo" files it after all (v0.8.6 deleted it at once). Meanwhile
//    the wav waits as NNN.discarded.wav (BlurtCore VoiceDiscard): a quit or a crash then never brings it back.
//  • what is kept (BlurtCore VoiceKeep, v0.9): a note the user ends (the key, Done, letting go, quitting) is kept when
//    it lasted 1.5 s and held a sound above the room, even if the room hid the speech from the endpointer — the speech
//    model decides; no words → a card that says "No words recognized" with Retry (with a project too: it is filed
//    there once Retry has words, never as an empty item). A fan or a hum alone is "Didn't hear anything". Nothing
//    heard for the whole wait: "Didn't hear anything — check the microphone" (Sound Settings). The microphone gone
//    mid-note (a headset out, the input switched: NoteVoice's watchdog) ends it with what was said.
//  • Blurt quitting finishes it (finishForQuit); a snap's bubble opened meanwhile has Esc (yieldEsc).
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
    /// Esc cancels (its hotkey is held): the first `escSeconds` of a voice note only
    private(set) var escCancels = false
    private var escTimer: Timer?
    static let escSeconds: Double = 10
    /// how long "Voice note discarded · Undo" can bring a cancelled note back (its audio is kept until then)
    static let undoSeconds: Double = 5

    var elapsed: Double { active ? voice?.elapsed ?? Date().timeIntervalSince(startedAt) : 0 }

    private var settings: [String: Any] { recordConfig()["voice"] as? [String: Any] ?? [:] }
    private var mode: String { settings["mode"] as? String ?? "auto" }
    private var silence: Double { (settings["silence_ms"] as? Double ?? 1500) / 1000 }
    /// "End a voice note when I pause" (off): a pause of `silence` ends it, as before v0.8.6
    /// The live words of a note — ⌥⇧V's panel and a snap's note field — on every tier: the note model is quick
    /// (SenseVoice answers an interim request whole in ~0.1 s; a slow model says so and DictationLiveDecode asks again
    /// later, then stops for that take). Dictation's tier gate is about its larger model on the GPU, so it isn't
    /// applied here; only the user's own switches turn them off: record.live_text ("Show text while I talk") and an
    /// explicit record.dictation.live_partial = false.
    static var liveWords: Bool { (Dictation.settings["live_partial"] as? Bool ?? true) && LiveTranscript.enabled }

    static var endOnPause: Bool { (recordConfig()["voice"] as? [String: Any])?["end_on_pause"] as? Bool ?? false }
    static func setEndOnPause(_ on: Bool) { Config.shared.set("record.voice.end_on_pause", on ? true : nil) }
    /// the longest voice note (seconds)
    var maxSeconds: Double { max(30, (settings["max_seconds"] as? Double) ?? 600) }
    /// transcribe while talking (off: the whole wav after stop, the old path)
    var streams: Bool { settings["stream"] as? Bool ?? true }
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

    /// Esc (its hotkey, held for the first `escSeconds`): the note is discarded, with Undo.
    func cancel() { if active { finish(keep: false, via: "esc") } }

    /// Esc back to the other apps (its time is up, or the note ended).
    private func releaseEsc() {
        escTimer?.invalidate()
        escTimer = nil
        guard escCancels else { return }
        escCancels = false
        unregisterHotkey(.voiceEsc)
    }

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
            self.finish(keep: e != .noSpeech, ended: true, via: e == .micLost ? "mic_lost" : "\(e)")
        }
        let live = LiveTranscript.shared.begin(.voice)
        liveSession = live
        let st = streams ? VoiceNoteStream(id: "\(ShotBatch.name(k))-\(Int(Date().timeIntervalSince1970))",
                                           interim: VoiceInput.liveWords) : nil
        st?.onLive = { [weak self] committed, pending in
            if let self = self, self.stream === st { self.liveText = committed + pending }
            LiveTranscript.shared.update(committed, pending: pending, session: live)
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
        if !NoteBubble.shared.isOpen { registerHotkey(.voiceEsc, key: kVK_Escape, mods: 0) }
        escCancels = true
        escTimer?.invalidate()
        escTimer = Timer.scheduledTimer(withTimeInterval: VoiceInput.escSeconds, repeats: false) { [weak self] _ in
            guard let self = self, self.voice === v else { return }
            self.releaseEsc()
            emit(["event": "voice_esc_released", "n": k])
        }
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
        // dictation's preload never downloads a model (no model: the server waits unloaded; Dictation says so)
        server = WarmSpawn.start("transcribe.py", ["serve", "--preload"] + (dictation ? ["--purpose", "dictation", "--no-download"] : []),
                                 server: "asr-serve")
    }

    /// Dictation gave up on a server that stopped answering: the one Blurt started goes (SIGKILL: a stopped process
    /// doesn't take SIGTERM), so the next key-down starts a fresh one. A server someone else started is left alone.
    static func endUnresponsiveServer() {
        guard let s = server, s.isRunning else { return }
        // the server itself is `uv run`'s child (or grandchild): it goes first, while it can still be told from a
        // stranger's by its ancestry (killing only `uv` left it orphaned and running)
        if let d = try? Data(contentsOf: WarmServer.infoURL("asr-serve")),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let pid = (o["pid"] as? NSNumber)?.int32Value,
           descends(pid, from: s.processIdentifier) {
            kill(pid, SIGKILL)
        }
        kill(s.processIdentifier, SIGKILL)
        server = nil
        emit(["event": "asr_server_ended", "why": "unresponsive"])
    }

    /// `pid`'s parent, grandparent … (up to 4) include `ancestor`.
    private static func descends(_ pid: pid_t, from ancestor: pid_t) -> Bool {
        var p = pid
        for _ in 0..<4 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return false }
            p = pid_t(info.pbi_ppid)
            if p == ancestor { return true }
            if p <= 1 { return false }
        }
        return false
    }

    /// Voice-note pieces waiting on the speech server now (dictation doesn't end a server a note is using).
    private static let notesLock = NSLock()
    private static var notesInFlight = 0
    static var notesWaiting: Int { notesLock.lock(); defer { notesLock.unlock() }; return notesInFlight }

    /// Our server process runs but hasn't written its address yet (dictation's pieces wait for it, not for a CLI).
    static var serverStarting: Bool { server?.isRunning == true && !WarmServer.running("asr-serve") }

    /// One piece of a voice note → its words: the warm server (`note`, the voice-note model), else the CLI (which
    /// asks the server itself, or loads the model). Blocking: off the main thread.
    static func transcribePiece(_ wav: URL, prior: String) -> [String: Any]? {
        notesLock.lock(); notesInFlight += 1; notesLock.unlock()
        defer { notesLock.lock(); notesInFlight -= 1; notesLock.unlock() }
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

    /// Tests (test commands only): the microphone stops delivering mid-note.
    func testStall() { voice?.testStall() }

    /// Blurt is quitting (App.applicationShouldTerminate): the note is finished and filed as if the key ended it — its
    /// wav is closed (a header that says how long it is) and its shots.jsonl line written.
    func finishForQuit() { if active { finish(keep: true, via: "quit") } }

    /// The snap's note bubble opened while this listens (a snap taken during a voice note): plain Esc is the bubble's
    /// until it closes, then the voice note's again for what is left of `escSeconds`.
    func yieldEsc(_ yield: Bool) {
        guard active, escCancels else { return }
        if yield { unregisterHotkey(.voiceEsc) } else { registerHotkey(.voiceEsc, key: kVK_Escape, mods: 0) }
    }

    private func finish(keep: Bool, ended: Bool = false, via: String) {
        guard active, let v = voice, let b = batch else { return }
        let dur = v.elapsed
        // BlurtCore VoiceKeep: a note the user ended is kept when it lasted and wasn't digital silence, even if the room
        // hid the speech from the endpointer — the speech model decides (no words → kept as audio, "Retry")
        let how: VoiceKeep.Ended = via == "esc" ? .cancel : via == "no_mic" ? .noMic : via == "noSpeech" ? .noSpeech
            : via == "mic_lost" ? .micLost : via == "silence" ? .silence : via == "maxed" ? .maxed : .user
        let decision = VoiceKeep.decide(how, heardSpeech: heardSpeech, seconds: dur, soundSeconds: v.soundSeconds)
        var kept = false, undoable = false, toast = VoiceKeep.Toast.none
        switch decision {
        case .keep(let t): kept = true; toast = t
        case .undoable: undoable = true             // Esc after something was said: kept a moment longer, for Undo
        case .drop(let t): toast = t
        }
        if !ended { v.stop(keep: kept || undoable) } else if !kept { v.stop(keep: false) }
        let st = stream
        voice = nil
        stream = nil
        batch = nil
        active = false
        holding = false
        releaseEsc()
        emit(["event": "voice_end", "kept": kept, "duration": (dur * 100).rounded() / 100, "via": via,
              "pieces": st?.count ?? 0, "heard_speech": heardSpeech, "peak_db": Double((v.peakDB * 10).rounded() / 10),
              "sound": (v.soundSeconds * 100).rounded() / 100,
              "wall": Date().timeIntervalSince1970])
        VoiceInput.say(toast)
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
        } else if undoable {
            LiveTranscript.shared.end(session: live)
            st?.onText = nil
            discarded(batch: b, n: n, duration: dur, project: project.isInbox ? nil : project.id, stream: st, wav: v.url)
        } else {
            st?.cancel()
            LiveTranscript.shared.end(session: live)
        }
    }

    /// What the island says when a voice note ends without being kept as it was (BlurtCore VoiceKeep.Toast).
    static func say(_ t: VoiceKeep.Toast) {
        switch t {
        case .none: return
        case .nothing: island.toast(Loc.t("capture.voice.nothing", table: "Capture"), actionTitle: nil, action: nil)
        case .micLost: island.toast(Loc.t("capture.voice.mic_lost", table: "Capture"), actionTitle: nil, action: nil)
        case .micGone: island.toast(Loc.t("capture.voice.mic_gone", table: "Capture"), actionTitle: nil, action: nil)
        case .checkMic:
            // nothing at all for the whole wait: a muted or wrong microphone, most likely
            var toast = Island.Toast(text: Loc.t("capture.voice.check_mic", table: "Capture"),
                                     actionTitle: Loc.t("capture.voice.sound_settings", table: "Capture")) {
                if let u = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input") { NSWorkspace.shared.open(u) }
            }
            toast.seconds = 6
            island.toast(toast)
        }
    }

    /// The voice-note model on the piece still being said (the live text): the warm server only, never a CLI — an
    /// interim answer that has to load a model isn't worth it. Blocking: off the main thread.
    static func transcribeInterim(_ wav: URL, prior: String) -> [String: Any]? {
        guard WarmServer.running("asr-serve") else { return ["ok": false, "code": "no_server"] }
        var req: [String: Any] = ["cmd": "note", "wav": wav.path, "language": "auto", "interim": true]
        if !prior.isEmpty { req["prior"] = prior }
        return WarmServer.call("asr-serve", req, timeout: 15)
    }

    /// A cancelled voice note: "Voice note discarded · Undo" for `undoSeconds` — Undo files it as if it had been
    /// finished (Snapper.voiceFinished); else its audio goes.
    private func discarded(batch b: ShotBatch, n: Int, duration: Double, project: String?, stream st: VoiceNoteStream?, wav: URL) {
        var settled = false
        // waiting for its Undo under another name: a quit or a crash now never brings it back as a note
        let parked = VoiceDiscard.parked(wav)
        let moved = (try? FileManager.default.moveItem(at: wav, to: parked)) != nil
        emit(["event": "voice_discarded", "n": n, "undo_seconds": VoiceInput.undoSeconds, "parked": moved])
        var t = Island.Toast(text: Loc.t("capture.voice.discarded", table: "Capture"), actionTitle: Loc.t("capture.undo", table: "Capture")) {
            guard !settled else { return }
            settled = true
            if moved { try? FileManager.default.moveItem(at: parked, to: wav) }
            emit(["event": "voice_undo", "n": n])
            snapper.voiceFinished(batch: b, n: n, duration: duration, project: project, stream: st)
        }
        t.seconds = VoiceInput.undoSeconds
        island.toast(t)
        DispatchQueue.main.asyncAfter(deadline: .now() + VoiceInput.undoSeconds + 0.5) {
            guard !settled else { return }
            settled = true
            st?.cancel()
            try? FileManager.default.removeItem(at: moved ? parked : wav)
            emit(["event": "voice_discard_done", "n": n])
        }
    }
}

/// A voice note transcribed while it is being said: the audio is cut at pauses (DictationSegmenter, as dictation
/// does: ≥ 0.5 s of quiet, pieces of ≥ 3 s, at most 20 s) and each piece goes to the speech model as soon as it is
/// complete, on one serial queue, the text so far as context. `finish` sends the rest and answers with the whole
/// text (DictationStitch.joinPieces) — nil when a piece failed (the caller transcribes the whole wav then).
/// Live text (`interim`, v0.9 — the same as dictation's, docs/design/dictation.md §Live text): about once a second the
/// piece still being said is decoded by the warm server as an *interim* request (BlurtCore DictationLiveDecode decides
/// when; a final piece always goes first) and `onLive` gets the finished pieces' text and, after it, the interim
/// text. The ⌥⇧V panel and the snap's note bubble show it; nothing filed comes from an interim answer.
final class VoiceNoteStream {
    let id: String
    /// the finished pieces' text so far, on the main queue, after each piece
    var onText: ((String) -> Void)?
    /// the live text (main queue): the finished pieces' text, then the interim text of the piece still being said
    var onLive: ((_ committed: String, _ pending: String) -> Void)?
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
    private let liveQ = DispatchQueue(label: "blurt.voice.live", qos: .userInitiated)
    private let lock = NSLock()
    private var texts: [String] = []        // q
    private var pauses: [Double?] = []      // under lock
    private var failed = false              // q
    private var cancelled = false           // under lock
    private let dir: URL
    // the live text (main thread)
    private var live: DictationLiveDecode
    private var finals: [Int: String] = [:]
    private var hards: [Int: Bool] = [:]
    private var interims: [Int: String] = [:]

    var count: Int { queued }

    init(id: String, interim: Bool = false) {
        self.id = id
        live = DictationLiveDecode(sampleRate: NoteVoice.rate, off: interim ? nil : .setting)
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
        interimIfDue()
    }

    private func enqueue(start: Int, end: Int, hard: Bool) {
        guard end > start else { return }
        let samples = Array(audio[max(0, start - base)..<max(0, min(end - base, audio.count))])
        let i = queued
        queued += 1
        hards[i] = hard
        live.finalQueued()          // no interim goes out until this piece's text is in
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
        DispatchQueue.main.async {
            if !joined.isEmpty { self.onText?(joined) }
            self.finalLanded(i, text)
        }
    }

    // MARK: live text (main thread; the interim requests on liveQ)

    /// As audio arrives: the open piece's audio so far to the warm server when DictationLiveDecode says so.
    private func interimIfDue() {
        guard onLive != nil, !isCancelled else { return }
        guard let t = live.next(now: CACurrentMediaTime(), piece: queued, pieceStart: pieceStart, audioEnd: total,
                                hasSpeech: segmenter.pieceHasSpeech) else { return }
        let lo = max(0, t.start - base), hi = max(lo, min(audio.count, t.end - base))
        let samples = Array(audio[lo..<hi])
        let prior = String(DictationStitch.joinPieces((0..<queued).compactMap { finals[$0] }, pauses: segmenter.pauses).suffix(200))
        let url = dir.appendingPathComponent("\(id)-live.wav")
        liveQ.async { [weak self] in
            guard let self = self, !self.isCancelled else { return }
            DictationStream.writeWav(samples, to: url)
            let t0 = CACurrentMediaTime()
            let r = VoiceInput.transcribeInterim(url, prior: prior)
            let secs = CACurrentMediaTime() - t0
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async { self.interimDone(t, r, seconds: secs) }
        }
    }

    private func interimDone(_ t: DictationLiveDecode.Ticket, _ r: [String: Any]?, seconds: Double) {
        let code = r?["code"] as? String
        let load = Double(r?["load_ms"] as? Int ?? 0) / 1000
        let a: DictationLiveDecode.Answer = r?["ok"] as? Bool == true ? .text(seconds: max(0, seconds - load))
            : code == "interrupted" || code == "no_server" ? .interrupted : code == "interim_unsupported" ? .unsupported : .failed
        let show = !isCancelled && live.done(t, a)
        let text = (r?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        emit(["event": "voice_interim", "id": id, "piece": t.piece, "ms": Int(seconds * 1000),
              "result": r?["ok"] as? Bool == true ? "text" : code ?? "failed", "shown": show && !text.isEmpty, "chars": text.count])
        if show, !text.isEmpty {
            interims[t.piece] = text
            publish()
        }
    }

    /// A final piece's transcript is in: it replaces its interim text (and interim requests may go again).
    private func finalLanded(_ i: Int, _ text: String) {
        finals[i] = text
        interims[i] = nil
        live.finalDone(piece: i)
        publish()
        if !live.stopped { interimIfDue() }
    }

    private func publish() {
        guard let f = onLive, !isCancelled else { return }
        var items: [DictationLiveDecode.Piece] = []
        for i in 0..<queued {
            if let t = finals[i] { items.append(.final(t)) }
            else if let t = interims[i] { items.append(.interim(t, hard: hards[i] ?? false)) }
            else { items.append(.none) }
        }
        if let t = interims[queued] { items.append(.interim(t, hard: pieceHard)) }
        let (committed, pending) = DictationLiveDecode.compose(items, pauses: segmenter.pauses)
        if !(committed + pending).isEmpty { f(committed, pending) }
    }

    // MARK: stop

    /// The rest of the audio as the last piece, then the whole text (main queue). nil: a piece failed.
    func finish(_ done: @escaping (String?) -> Void) {
        live.stop()             // no more interim requests: one under way still shows until its piece is in
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
                self.onText = nil           // (its closures hold the stream)
                self.onLive = nil
                done(text)
            }
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        live.stop()
        onText = nil
        onLive = nil
        onFinished = nil
        audio = []
    }
}
