// A dictation transcribed and polished while it is being said (docs/design/dictation.md §Streaming).
//
// Before, everything waited for the key to come up: the whole recording went to the speech model, then the whole text
// to polish — 2–3 s after a 30 s dictation, more after a minute. Now the audio is cut at the pauses as it comes in
// (BlurtCore's DictationSegmenter: ≥ 0.5 s of quiet, pieces of ≥ 3 s, at most 20 s), and each piece is
//   1. transcribed as soon as it is complete (the warm speech server; the text so far goes along as context, so a name
//      is spelled the same way all through — transcribe.py keeps only its last 80 characters and decodes a piece
//      that echoes it once more without it), on one serial queue;
//   2. polished right after, on another (the polished text so far goes along as the turn before, so polish sees what
//      came before without being allowed to change it).
// At key-up only the last piece is left: its transcription and polish are all the user waits for.
//
// Live text (docs/design/dictation.md §Live text): the words shown while talking (LiveTranscript) are the finished
// pieces' transcripts and, about once a second, the open piece's audio so far decoded by the same warm server as an
// *interim* request (on its own queue; BlurtCore's DictationLiveDecode decides when). Interim text shows quieter
// until its piece's final transcript replaces it; nothing typed or filed comes from it. A final piece always goes
// first: no interim is sent while a final one is queued or under way, and the server stops an interim decode as soon
// as another request waits (transcribe.py serve). Off on the light / minimal tiers (record.dictation.live_partial).
//
// A cut is a pause, not a sentence end (each piece used to come back as a whole utterance: a full stop at every
// breath). So a piece's own ending isn't final: its trailing 。/，is taken off before polish, and polish works over a
// sliding window — the last, unfinished clause of the window before (`carry`) is polished again together with the
// new piece, with no mark between them however long the pause (DictationStitch.windowInput: the model decides from
// the words whether the sentence ended), and only the text up to the window's last sentence end or comma is
// committed (DictationStitch.commitSplit). Without
// polish the transcripts are joined with the seam rule (DictationStitch.joinPieces). At key-up the last window is the
// carried clause + the last piece. Structured then runs one structuring pass over the joined text (`finish(structure:)`).
// Nothing here reads the words for meaning: no correction markers, no stop words (docs/design/dictation.md §Rules vs
// model).
//
// Safety: a piece the speech model failed on → the whole recording is transcribed (and polished) in one go, the old
// way; when that fails too, the result says why (`asrError`: no model, too slow, failed) — never an empty "nothing
// heard" — and the app keeps the audio for Retry (`retry`). A hard cut (no pause for 20 s) overlaps the pieces by 0.8 s and DictationStitch drops the doubled words. Each
// piece's polish has the content-loss guard; the joined result is checked once more against the joined transcript
// (polish.py's `guard`), and falls back to the transcript when it fails. Nothing here touches the microphone or
// another app; it only gets samples.
import AppKit
import AVFoundation
import BlurtCore

final class DictationStream {
    struct Options {
        var vocab: [[String: Any]] = []
        var polish = true
        var polishTimeout = 3.0
        /// how long a model may take to come up (server start + load) before it counts against nothing
        var loadBudget = 12.0
        var language = "auto"
        /// cut while talking (record.dictation.streaming); off = one piece at key-up, the old path
        var streaming = true
        /// the category's variant of light for polish.py ("chat": the request asks the model to keep the tone words)
        var variant: String?
        /// Structured's one pass over the whole take (polish.py structure_timeout_ms)
        var structureTimeout = 10.0
        /// decode the piece still being said for the live text (Dictation.livePartial)
        var interim = false
    }

    /// One piece of the recording and what became of it.
    final class Piece {
        let index: Int
        let start: Int, end: Int
        /// it began at a hard cut (overlapping the piece before)
        let hard: Bool
        var asr: [String: Any]?
        /// the transcript (what polish gets), the overlap with the piece before removed
        var raw = ""
        /// what the speech model itself wrote (the history's "heard")
        var asrText = ""
        var polish: [String: Any]?
        /// what this piece contributes to the final text ("" when it was polished together with the next one)
        var text = ""
        var asrFailed = false
        /// the speech model's error code when it failed (model_missing, timeout, …)
        var asrCode: String?
        /// enqueued at key-up: the dictation ends here, so its ending is final
        let last: Bool
        /// polish's own output for what this piece committed (the history's "polished")
        var polishedPart = ""
        var asrSpan: (Double, Double) = (0, 0)
        var polishSpan: (Double, Double) = (0, 0)
        var loadMS = 0
        /// the polish window's input (the carried clause + this piece): the Dictation Lab shows it
        var polishInput = ""
        /// its transcript is in (the live text shows it as committed)
        var asrDone = false
        /// when its last sample arrived (the live text's lag is measured from it)
        var arrived: CFTimeInterval = 0
        init(index: Int, start: Int, end: Int, hard: Bool, last: Bool = false) {
            self.index = index; self.start = start; self.end = end; self.hard = hard; self.last = last
        }
    }

    struct Result {
        var raw: String           // the transcript polish got, joined
        var asrText: String       // what the speech model wrote, joined
        var text: String          // what gets typed
        var polished: String?     // polish's own output, joined (nil: no polish)
        var fellBack: Bool
        var reason: String?
        var model: String?
        var asrModel: String?
        var language: String?
        var biased: Bool
        var terms: [String]
        var contextUsed: Bool
        var repaired: [String]
        var segments: Int
        var timing: [String: Int]
        /// each piece as the Dictation Lab shows it: index, start / end (s), hard, pause_after, asr_text, raw, asr_ms,
        /// polish_in, text (what it committed), polished, polish_ms, fell_back, reason, repaired
        var pieces: [[String: Any]] = []
        /// Structured: the structuring pass's text (nil: not asked, or it refused — then `text` is typed)
        var structured: String?
        /// why the structuring pass refused (nil: it didn't, or wasn't asked)
        var structureReason: String?
        /// the speech model couldn't recognise the take (nil: it did — an empty text is then silence)
        var asrError: DictationASRFailure?
        /// each piece's language tag and how sure the model was (transcribe.py's `tag`; the history keeps them)
        var tags: [[String: Any]] = []
        var empty: Bool { raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    let id: String
    let dir: URL
    private(set) var opt: Options
    /// the text around the cursor: read at the start, while the first piece may already be under way
    private var context: DictationContext?
    func setContext(_ c: DictationContext?) { lock.locked { context = c } }
    /// the whole recording's wav (NoteVoice writes it): the safety path transcribes it in one go
    let wholeWav: URL
    /// stage changes after key-up (transcribing → polishing), on the main queue
    var onStage: ((String) -> Void)?
    /// the words shown while talking (LiveTranscript), on the main queue: the finished pieces' transcripts joined
    /// (`committed`) and the interim text of the pieces still to come (`pending`); nothing else reads them
    var onLive: ((_ committed: String, _ pending: String) -> Void)?

    private var segmenter = DictationSegmenter(sampleRate: NoteVoice.rate)
    private var audio: [Float] = []             // main thread
    private var pieceStart = 0
    private var pieceHard = false
    private var pieces: [Piece] = []           // appended on main, read on the queues after their block was queued
    private let lock = NSLock()
    private let asrQ = DispatchQueue(label: "blurt.dictation.asr", qos: .userInitiated)
    private let polishQ = DispatchQueue(label: "blurt.dictation.polish", qos: .userInitiated)
    private var cancelled = false
    /// Esc while polishing (skipPolish): no more polish windows; the result is handed over once (`delivered`), through
    /// `finished` (finish's `done`) — lock
    private var skipped = false, delivered = false
    private var finished: ((Result) -> Void)?
    private var keyUp: CFTimeInterval = 0
    /// the pause after each piece (DictationSegmenter.pauses, copied on the main thread as it learns them)
    private var pauses: [Double?] = []
    /// polishQ only: the last window's unfinished clause (the typed text and polish's own output) and the
    /// punctuation it ended in — polished again with the next piece
    private var carry = "", carryPolished = "", carryEnd = ""
    // the live text (main thread): when to decode the open piece, and what the interim requests said per piece
    private var live = DictationLiveDecode(sampleRate: NoteVoice.rate)
    private var interims: [Int: (text: String, arrived: CFTimeInterval)] = [:]
    private let liveQ = DispatchQueue(label: "blurt.dictation.live", qos: .userInitiated)
    private var liveOffLogged = false
    private var firstAudio: CFTimeInterval = 0
    /// interim requests sent / shown this take (dictation_text's timing)
    private var interimSent = 0, interimShown = 0

    init(id: String, dir: URL, wholeWav: URL, options: Options) {
        self.id = id; self.dir = dir; self.wholeWav = wholeWav; self.opt = options
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !options.interim || !options.streaming { live = DictationLiveDecode(sampleRate: NoteVoice.rate, off: .setting) }
    }

    // MARK: while talking (main thread)

    func append(_ x: [Float]) {
        guard !cancelled else { return }
        if audio.isEmpty { firstAudio = CACurrentMediaTime() }
        audio += x
        guard opt.streaming else { return }
        let cuts = segmenter.feed(x)
        let known = segmenter.pauses
        if known != lock.locked({ pauses }) { lock.locked { pauses = known } }
        for cut in cuts {
            enqueue(start: pieceStart, end: cut.end, hard: pieceHard)
            pieceStart = cut.nextStart
            pieceHard = cut.hard
        }
        interimIfDue()
    }

    var segments: Int { lock.lock(); defer { lock.unlock() }; return pieces.count }

    /// Esc while it is still polishing ("Still polishing… Esc types it as spoken"): what was heard goes in as it is, as
    /// soon as the transcripts are in — the polish under way (or a model still loading) is not waited for, and its
    /// answer, when it comes, is dropped. The take falls back the way a refused polish does (reason "skipped").
    func skipPolish() {
        lock.locked { skipped = true }
        asrQ.async {
            guard !self.cancelled, let r = self.spokenResult() else { return }
            emit(["event": "dictation_polish_skipped", "id": self.id])
            self.deliver(r)
        }
    }

    /// Hands the take's result over once: the polished one, or the one Esc asked for, whichever is first.
    private func deliver(_ r: Result) {
        let done: ((Result) -> Void)? = lock.locked {
            if delivered { return nil }
            delivered = true
            return finished
        }
        guard let d = done else { return }
        DispatchQueue.main.async { d(r) }
    }

    /// The transcripts joined as a refused polish types them (a comma where a boundary was heard); nil when a piece
    /// failed to transcribe (the safety path then decides, as without Esc).
    private func spokenResult() -> Result? {
        let ps = lock.locked { pieces }
        guard !ps.isEmpty, !ps.contains(where: \.asrFailed) else { return nil }
        let gaps = lock.locked { pauses }
        let raw = DictationStitch.joinPieces(ps.map(\.raw), pauses: gaps)
        let heard = DictationStitch.joinPieces(ps.map(\.asrText), pauses: gaps)
        let text = DictationStitch.joinPiecesForFallback(ps.map(\.raw), pauses: gaps)
        var terms: [String] = []
        for p in ps { for t in p.asr?["terms"] as? [String] ?? [] where !terms.contains(t) { terms.append(t) } }
        let first = ps.first { $0.asr != nil }?.asr ?? [:]
        var r = Result(raw: raw, asrText: heard, text: text.isEmpty ? raw : text, polished: nil, fellBack: true,
                       reason: "skipped", model: nil, asrModel: first["model"] as? String, language: first["language"] as? String,
                       biased: first["biased"] as? Bool ?? false, terms: terms, contextUsed: false, repaired: [],
                       segments: ps.count, timing: timing(ps), pieces: ps.map { describe($0, gaps) })
        r.timing["total_ms"] = Int((CACurrentMediaTime() - keyUp) * 1000)
        r.tags = ps.compactMap { $0.asr?["tag"] as? [String: Any] }
        return r
    }

    func cancel() {
        cancelled = true
        live.stop()
        let ps = lock.locked { pieces }
        for p in ps { try? FileManager.default.removeItem(at: wav(p.index)) }
        try? FileManager.default.removeItem(at: liveWav)
    }

    private func wav(_ i: Int) -> URL { dir.appendingPathComponent("\(id)-p\(i).wav") }

    private func enqueue(start: Int, end: Int, hard: Bool, last: Bool = false) {
        guard end > start else { return }
        live.finalQueued()          // before the request goes out: no interim is sent from here until it is in
        let p = lock.locked { () -> Piece in
            let p = Piece(index: pieces.count, start: start, end: end, hard: hard, last: last)
            p.arrived = CACurrentMediaTime() - Double(max(0, audio.count - end)) / NoteVoice.rate
            pieces.append(p)
            return p
        }
        let samples = Array(audio[max(0, start)..<min(end, audio.count)])
        emit(["event": "dictation_piece", "id": id, "index": p.index, "start": Double(start) / NoteVoice.rate,
              "end": Double(end) / NoteVoice.rate, "hard": hard])
        asrQ.async { self.transcribe(p, samples) }      // the queues keep the stream alive until its work is done
    }

    // MARK: the work (queues)

    private func previous(_ p: Piece) -> Piece? {
        lock.locked { p.index > 0 && p.index - 1 < pieces.count ? pieces[p.index - 1] : nil }
    }

    private func transcribe(_ p: Piece, _ samples: [Float]) {
        guard !cancelled else { return }
        let url = wav(p.index)
        DictationStream.writeWav(samples, to: url)
        // the text so far, as context: the speech model keeps names consistent across pieces
        let (before, gaps) = lock.locked { (Array(pieces.prefix(p.index).map(\.raw)), pauses) }
        let prior = String(DictationStitch.joinPieces(before, pauses: gaps).suffix(200))
        let t0 = CACurrentMediaTime()
        let answer = Dictation.transcribe(url, vocab: opt.vocab, language: opt.language, prior: prior, budget: 30,
                                          hint: lock.locked { context }?.hint ?? "", app: lock.locked { context }?.app ?? "",
                                          audioSeconds: Double(samples.count) / NoteVoice.rate)
        p.asrSpan = (t0, CACurrentMediaTime())
        p.loadMS += answer["load_ms"] as? Int ?? 0
        try? FileManager.default.removeItem(at: url)
        let ok = answer["ok"] as? Bool == true
        let r: [String: Any]? = ok ? answer : nil
        p.asr = r
        if !ok { p.asrFailed = true; p.asrCode = answer["code"] as? String ?? "error" }
        var text = (r?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var heard = (r?["asr_text"] as? String ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hard, let prev = previous(p) {
            text = DictationStitch.dropOverlap(previous: prev.raw, next: text)
            heard = DictationStitch.dropOverlap(previous: prev.asrText, next: heard)
        }
        lock.locked {
            p.raw = text
            p.asrText = heard
            p.asrDone = true
        }
        // the live text: this piece's transcript replaces its interim text (and interim requests may go again)
        DispatchQueue.main.async { self.finalLanded(p.index) }
        emit(["event": "dictation_piece_text", "id": id, "index": p.index, "ms": Int((p.asrSpan.1 - p.asrSpan.0) * 1000),
              "server_ms": r?["ms"] ?? NSNull(), "chars": text.count, "ok": ok, "code": p.asrCode ?? NSNull()])
        polishQ.async { self.polish(p) }
    }

    /// The pause after piece `i` (nil: not known, or no such piece).
    private func pause(after i: Int) -> Double? {
        lock.locked { i >= 0 && i < pauses.count ? pauses[i] : nil }
    }

    /// One polish window: the carried, unfinished clause + this piece (its own ending taken off unless it is the
    /// last). What the window says up to its last sentence end or comma is committed; the rest is carried to the next
    /// window. No pause puts a mark between them (DictationStitch.windowInput): whether the sentence ended at the pause
    /// is the model's call from the words on both sides (no stop-word list makes it, and no pause length does).
    private func polish(_ p: Piece) {
        guard !cancelled, !lock.locked({ skipped }) else { return }
        // without polish the transcripts are joined with the seam rule at the end (assemble)
        guard opt.polish, !p.raw.isEmpty else { return }
        let core = p.last ? p.raw : DictationStitch.splitTrailing(p.raw).core
        let carried = carry
        carry = ""; carryPolished = ""; carryEnd = ""
        let input = DictationStitch.windowInput(carry: carried, piece: core)
        var ctx = lock.locked { context }?.payload ?? [:]
        let so = DictationStitch.join(lock.locked { pieces.prefix(p.index).map(\.text) })
        // the dictation's own text so far goes as its own key: polish.py shows it as the turn before this one, so the
        // model continues it instead of repeating it (appended to "before", it was repeated in 8 of 15 list windows)
        if !so.isEmpty { ctx["dictated"] = so }
        p.polishInput = input
        let t0 = CACurrentMediaTime()
        let r = Dictation.polish(input, timeout: opt.polishTimeout, loadBudget: opt.loadBudget, vocab: opt.vocab,
                                 context: ctx.isEmpty ? nil : ctx, variant: opt.variant)
        p.polishSpan = (t0, CACurrentMediaTime())
        p.loadMS += r?["load_ms"] as? Int ?? 0
        p.polish = r
        var out = (r?["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? input
        if r?["fell_back"] as? Bool == true {
            // only this window falls back, and its seam (the pause before this piece) still gets its punctuation
            if !carried.isEmpty, out.hasPrefix(carried), let prev = previous(p) {
                out = DictationStitch.fallbackSeam(carried, String(out.dropFirst(carried.count)), pause: pause(after: p.index - 1),
                                                   heardEnd: DictationStitch.splitTrailing(prev.raw).end)
            }
        } else if DictationStitch.midSentence(so) {
            // the model capitalised a window that continues a sentence: polish.py already asked its model whether the
            // capital is a name's (`case`); this keeps a lower-case transcript's case when it was not asked
            out = DictationStitch.keepCase(input: input, output: out)
        }
        let model = (r?["polished"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? out
        if p.last {
            p.text = out
            p.polishedPart = model
        } else {
            let s = DictationStitch.commitSplit(out), sm = DictationStitch.commitSplit(model)
            p.text = s.commit
            p.polishedPart = sm.commit
            carry = s.carry; carryEnd = s.end; carryPolished = sm.carry
        }
        emit(["event": "dictation_window", "id": id, "index": p.index, "in_units": DictationStitch.units(input).count,
              "committed": DictationStitch.units(p.text).count, "carry": DictationStitch.units(carry).count,
              "ms": Int((p.polishSpan.1 - p.polishSpan.0) * 1000)])
    }

    // MARK: live text (main thread; the interim requests on liveQ)

    private var liveWav: URL { dir.appendingPathComponent("\(id)-live.wav") }

    /// As audio arrives: the open piece's audio so far to the warm server when DictationLiveDecode says so.
    private func interimIfDue() {
        guard onLive != nil else { return }
        let index = lock.locked { pieces.count }
        guard let t = live.next(now: CACurrentMediaTime(), piece: index, pieceStart: pieceStart, audioEnd: audio.count,
                                hasSpeech: segmenter.pieceHasSpeech) else { return logLiveOff() }
        let samples = Array(audio[t.start..<t.end])
        let issued = CACurrentMediaTime()
        // the text so far as context, as a final piece gets it (names spelled the same way)
        let (done, gaps, hint, app) = lock.locked { (pieces.prefix { $0.asrDone }.map(\.raw), pauses, context?.hint ?? "", context?.app ?? "") }
        let prior = String(DictationStitch.joinPieces(done, pauses: gaps).suffix(200))
        let url = liveWav, vocab = opt.vocab, language = opt.language
        interimSent += 1
        liveQ.async { [weak self] in
            guard let self = self, !self.cancelled else { return }
            DictationStream.writeWav(samples, to: url)
            let t0 = CACurrentMediaTime()
            let r = Dictation.transcribeInterim(url, vocab: vocab, language: language, prior: prior, hint: hint, app: app)
            let secs = CACurrentMediaTime() - t0
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async { self.interimDone(t, r, seconds: secs, arrived: issued) }
        }
    }

    private func interimDone(_ t: DictationLiveDecode.Ticket, _ r: [String: Any]?, seconds: Double, arrived: CFTimeInterval) {
        let code = r?["code"] as? String
        // a model still loading isn't the decode's own time
        let load = Double(r?["load_ms"] as? Int ?? 0) / 1000
        let a: DictationLiveDecode.Answer = r?["ok"] as? Bool == true ? .text(seconds: max(0, seconds - load))
            : code == "interrupted" || code == "no_server" ? .interrupted : code == "interim_unsupported" ? .unsupported : .failed
        let show = !cancelled && live.done(t, a)
        let text = (r?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        emit(["event": "dictation_interim", "id": id, "piece": t.piece, "audio_s": Double(t.end) / NoteVoice.rate,
              "window_s": Double(t.end - t.start) / NoteVoice.rate, "ms": Int(seconds * 1000),
              "server_ms": r?["ms"] ?? NSNull(), "result": r?["ok"] as? Bool == true ? "text" : code ?? "failed",
              "shown": show && !text.isEmpty, "chars": text.count, "interval": live.interval])
        if show, !text.isEmpty {
            interims[t.piece] = (text, arrived)
            interimShown += 1
            publish("interim")
        }
        logLiveOff()
    }

    private func logLiveOff() {
        guard let why = live.off, !liveOffLogged, why != .setting else { return }
        liveOffLogged = true
        emit(["event": "dictation_interim_off", "id": id, "why": why.rawValue, "decode_s": live.smoothed ?? NSNull()])
    }

    /// A final piece's transcript is in.
    private func finalLanded(_ i: Int) {
        live.finalDone(piece: i)
        interims[i] = nil
        publish("final")
        if !live.stopped { interimIfDue() }
    }

    /// The panel's text: committed (finished pieces) and pending (interim), with how far it is behind the audio.
    private func publish(_ source: String) {
        guard let f = onLive, !cancelled else { return }
        let (ps, gaps) = lock.locked { (pieces.map { ($0.asrDone, $0.raw, $0.hard, $0.arrived) }, pauses) }
        var items: [DictationLiveDecode.Piece] = []
        var covered: CFTimeInterval = 0
        for (i, p) in ps.enumerated() {
            if p.0 {
                items.append(.final(p.1)); covered = max(covered, p.3)
            } else if let it = interims[i] {
                items.append(.interim(it.text, hard: p.2)); covered = max(covered, it.arrived)
            } else {
                items.append(.none)
            }
        }
        if let it = interims[ps.count] { items.append(.interim(it.text, hard: pieceHard)); covered = max(covered, it.arrived) }
        let (committed, pending) = DictationLiveDecode.compose(items, pauses: gaps)
        f(committed, pending)
        let now = CACurrentMediaTime()
        emit(["event": "dictation_live", "id": id, "source": source, "t": ((now - firstAudio) * 1000).rounded() / 1000,
              "lag_ms": covered > 0 ? Int((now - covered) * 1000) : NSNull(), "committed": committed.count,
              "pending": pending.count, "listening": !live.stopped])
    }

    // MARK: key-up

    /// The last piece, then everything joined; `structure` (Structured / Auto at key-up): the joined text then goes
    /// through the polish model's structuring pass once. `done` runs on the main queue.
    func finish(keyUp: CFTimeInterval, structure: Bool = false, _ done: @escaping (Result) -> Void) {
        self.keyUp = keyUp
        lock.locked { finished = done; delivered = false }
        live.stop()             // no more interim requests: an answer under way still shows until its piece is in
        lock.locked { finalCounts = (interimSent, interimShown) }
        let n = lock.locked { pieces.count }
        let tail = audio.count - pieceStart
        if n == 0 || (tail > Int(0.3 * NoteVoice.rate) && (segmenter.pieceSpeech >= 3 || !opt.streaming)) {
            enqueue(start: pieceStart, end: audio.count, hard: pieceHard, last: true)
        }
        onStage?("asr")
        // both queues are serial: this runs after every piece's transcription, and what it queues after every polish
        // (strong captures: the controller has let go of the stream by now; the queues hold it until it is done)
        asrQ.async {
            if self.opt.polish || structure { DispatchQueue.main.async { self.onStage?("polish") } }
            self.polishQ.async {
                guard !self.cancelled, !self.lock.locked({ self.delivered }) else { return }
                var r = self.assemble()
                if structure, !r.empty, !self.lock.locked({ self.skipped }) { self.structure(&r) }
                self.deliver(r)
            }
        }
    }

    /// Structured: the stitched text through polish.py's `structure` (it resolves self-corrections and lays out what
    /// was enumerated, or leaves a paragraph; its guard keeps the content). A refusal keeps Light's text.
    private func structure(_ r: inout Result) {
        let t0 = CACurrentMediaTime()
        let s = Dictation.structure(r.text, timeout: opt.structureTimeout, loadBudget: opt.loadBudget, vocab: opt.vocab)
        let ms = Int((CACurrentMediaTime() - t0) * 1000)
        r.timing["structure_ms"] = ms
        r.timing["total_ms"] = Int((CACurrentMediaTime() - keyUp) * 1000)
        r.structureReason = s?["fell_back"] as? Bool == true ? (s?["reason"] as? String ?? "error") : nil
        if let t = s?["text"] as? String, !t.isEmpty, s?["fell_back"] as? Bool != true {
            r.structured = t
        }
        emit(["event": "dictation_structure", "id": id, "ms": ms, "list": s?["list"] as? Bool ?? false,
              "fell_back": s?["fell_back"] as? Bool ?? (s == nil), "reason": s?["reason"] ?? NSNull()])
    }
    private func assemble() -> Result {
        let ps = lock.locked { pieces }
        // the safety path: a piece the speech model failed on → the whole recording, the old way
        if let failed = ps.first(where: \.asrFailed) {
            emit(["event": "dictation_stream_fallback", "id": id, "why": "asr_failed", "code": failed.asrCode ?? NSNull()])
            // no model: the whole recording would only fail the same way
            if failed.asrCode == "model_missing" { return failure(.noModel, segments: ps.count) }
            return whole(ps.count)
        }
        let gaps = lock.locked { pauses }
        let raw = DictationStitch.joinPieces(ps.map(\.raw), pauses: gaps)
        let heard = DictationStitch.joinPieces(ps.map(\.asrText), pauses: gaps)
        // polish's windows, then the clause still carried (the dictation ended in it: its ending stays)
        var text = opt.polish ? DictationStitch.join(ps.map(\.text) + [carry + carryEnd]) : raw
        let pol = ps.compactMap(\.polish)
        var fellBack = pol.contains { $0["fell_back"] as? Bool == true }
        var reason = pol.first { $0["fell_back"] as? Bool == true }?["reason"] as? String
        let polished: String? = pol.isEmpty ? nil
            : DictationStitch.join(ps.map(\.polishedPart) + [carryPolished + carryEnd])
        // the joined result once more against the joined transcript: pieces that each passed can still add up wrong
        // a refusal types the transcript with a comma where a boundary was heard (`fallback_text`)
        let fallback = DictationStitch.joinPiecesForFallback(ps.map(\.raw), pauses: gaps)
        if opt.polish, ps.count > 1, !pol.isEmpty, text != raw,
           let g = WarmServer.call("polish-serve", ["cmd": "guard", "raw": raw, "output": text, "vocab": opt.vocab,
                                                    "context": lock.locked { context }?.payload ?? NSNull(),
                                                    "fallback": fallback], timeout: 2),
           g["pass"] as? Bool == false {
            emit(["event": "dictation_stream_fallback", "id": id, "why": "stitch_guard", "reason": g["reason"] ?? NSNull()])
            text = (g["fallback_text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            fellBack = true
            reason = "stitch_" + (g["reason"] as? String ?? "guard")
        }
        var terms: [String] = []
        for p in ps {
            for t in (p.asr?["terms"] as? [String] ?? []) + (p.polish?["terms"] as? [String] ?? []) where !terms.contains(t) { terms.append(t) }
        }
        let first = ps.first { $0.asr != nil }?.asr ?? [:]
        let repaired = ps.flatMap { ($0.polish?["repaired"] as? [String]) ?? [] }
        var r = Result(raw: raw, asrText: heard, text: text.isEmpty ? raw : text, polished: polished, fellBack: fellBack,
                       reason: reason, model: pol.first { $0["model"] is String }?["model"] as? String,
                       asrModel: first["model"] as? String, language: first["language"] as? String,
                       biased: first["biased"] as? Bool ?? false, terms: terms,
                       contextUsed: pol.contains { $0["context"] as? Bool == true }, repaired: repaired,
                       segments: ps.count, timing: timing(ps), pieces: ps.map { describe($0, gaps) })
        r.tags = ps.compactMap { $0.asr?["tag"] as? [String: Any] }
        return r
    }

    /// One piece for the Dictation Lab (what each stage made of it, and how long it took).
    private func describe(_ p: Piece, _ gaps: [Double?]) -> [String: Any] {
        let ms = { (s: (Double, Double)) in Int(max(0, s.1 - s.0) * 1000) }
        var o: [String: Any] = ["index": p.index, "start": (Double(p.start) / NoteVoice.rate * 100).rounded() / 100,
                                "end": (Double(p.end) / NoteVoice.rate * 100).rounded() / 100, "hard": p.hard,
                                "asr_text": p.asrText, "raw": p.raw, "asr_ms": ms(p.asrSpan), "text": p.text,
                                "polish_in": p.polishInput, "polished": p.polishedPart, "polish_ms": ms(p.polishSpan),
                                "fell_back": p.polish?["fell_back"] as? Bool ?? false, "reason": p.polish?["reason"] ?? NSNull(),
                                "repaired": p.polish?["repaired"] as? [String] ?? [], "load_ms": p.loadMS,
                                "tag": p.asr?["tag"] ?? NSNull(), "case": p.polish?["case"] ?? NSNull()]
        let g: Double? = p.index < gaps.count ? gaps[p.index] : nil
        o["pause_after"] = g.map { ($0 * 100).rounded() / 100 as Any } ?? NSNull()
        return o
    }

    /// A take the speech model couldn't recognise: no text, and why.
    private func failure(_ f: DictationASRFailure, segments n: Int) -> Result {
        var r = Result(raw: "", asrText: "", text: "", polished: nil, fellBack: false, reason: nil, model: nil, asrModel: nil,
                       language: nil, biased: false, terms: [], contextUsed: false, repaired: [], segments: n,
                       timing: ["total_ms": Int((CACurrentMediaTime() - keyUp) * 1000), "segments": n])
        r.asrError = f
        return r
    }

    /// Retry (the island's, the history's): the whole recording again, after a failure — the same passes as at key-up.
    /// `done` on the main queue.
    func retry(structure: Bool, _ done: @escaping (Result) -> Void) {
        cancelled = false
        keyUp = CACurrentMediaTime()
        polishQ.async {
            var r = self.whole(max(1, self.segments))
            if structure, !r.empty, r.asrError == nil { self.structure(&r) }
            DispatchQueue.main.async { done(r) }
        }
    }

    /// The old path on the whole recording: one transcription, one polish.
    private func whole(_ n: Int) -> Result {
        let t0 = CACurrentMediaTime()
        let answer = Dictation.transcribe(wholeWav, vocab: opt.vocab, language: opt.language, prior: "", budget: 30,
                                          hint: lock.locked { context }?.hint ?? "", app: lock.locked { context }?.app ?? "",
                                          audioSeconds: DictationStream.seconds(of: wholeWav))
        guard answer["ok"] as? Bool == true else {
            emit(["event": "dictation_asr_failed", "id": id, "code": answer["code"] ?? "error"])
            return failure(DictationASRFailure(code: answer["code"] as? String), segments: n)
        }
        let r = answer
        let t1 = CACurrentMediaTime()
        let raw = (r["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pol = opt.polish && !raw.isEmpty ? Dictation.polish(raw, timeout: opt.polishTimeout, loadBudget: opt.loadBudget,
                                                               vocab: opt.vocab, context: lock.locked { context }?.payload,
                                                               variant: opt.variant) : nil
        let t2 = CACurrentMediaTime()
        let text = (pol?["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? raw
        var timing = ["asr_ms": Int((t1 - t0) * 1000), "polish_ms": Int((t2 - t1) * 1000), "segments": n,
                      "load_ms": (r["load_ms"] as? Int ?? 0) + (pol?["load_ms"] as? Int ?? 0)]
        timing["total_ms"] = Int((t2 - keyUp) * 1000)
        var out = Result(raw: raw, asrText: r["asr_text"] as? String ?? raw, text: text, polished: pol?["polished"] as? String,
                      fellBack: pol?["fell_back"] as? Bool ?? false, reason: pol?["reason"] as? String,
                      model: pol?["model"] as? String, asrModel: r["model"] as? String, language: r["language"] as? String,
                      biased: r["biased"] as? Bool ?? false, terms: (r["terms"] as? [String] ?? []) + (pol?["terms"] as? [String] ?? []),
                      contextUsed: pol?["context"] as? Bool ?? false, repaired: pol?["repaired"] as? [String] ?? [],
                      segments: n, timing: timing,
                      pieces: [["index": 0, "start": 0, "end": NSNull(), "hard": false, "whole": true,
                                "asr_text": r["asr_text"] as? String ?? raw, "raw": raw, "asr_ms": timing["asr_ms"] ?? 0,
                                "text": text, "polish_in": raw, "polished": pol?["polished"] ?? NSNull(),
                                "polish_ms": timing["polish_ms"] ?? 0, "fell_back": pol?["fell_back"] as? Bool ?? false,
                                "reason": pol?["reason"] ?? NSNull(), "repaired": pol?["repaired"] as? [String] ?? [],
                                "case": pol?["case"] ?? NSNull()]])
        if let t = r["tag"] as? [String: Any] { out.tags = [t] }
        return out
    }

    /// What the user waited for after key-up (the work before it was hidden behind the talking), and the total.
    private func timing(_ ps: [Piece]) -> [String: Int] {
        func after(_ s: (Double, Double)) -> Double { max(0, s.1 - max(s.0, keyUp)) }
        let asr = ps.reduce(0) { $0 + after($1.asrSpan) }, pol = ps.reduce(0) { $0 + after($1.polishSpan) }
        let asrAll = ps.reduce(0) { $0 + ($1.asrSpan.1 - $1.asrSpan.0) }, polAll = ps.reduce(0) { $0 + ($1.polishSpan.1 - $1.polishSpan.0) }
        return ["asr_ms": Int(asr * 1000), "polish_ms": Int(pol * 1000), "load_ms": ps.reduce(0) { $0 + $1.loadMS },
                "segments": ps.count, "asr_ms_all": Int(asrAll * 1000), "polish_ms_all": Int(polAll * 1000),
                "total_ms": Int((CACurrentMediaTime() - keyUp) * 1000), "interim_sent": interimCounts.sent,
                "interim_shown": interimCounts.shown]
    }

    /// interim requests this take (read off the main thread once the take is over: a copy taken at key-up)
    private var interimCounts: (sent: Int, shown: Int) { lock.locked { finalCounts } }
    private var finalCounts = (sent: 0, shown: 0)

    /// A wav's length (s); 0 when it can't be read.
    static func seconds(of url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url), f.fileFormat.sampleRate > 0 else { return 0 }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    static func writeWav(_ x: [Float], to url: URL) {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: NoteVoice.rate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: NoteVoice.rate, channels: 1, interleaved: false),
              let f = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false),
              let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(1, x.count))) else { return }
        b.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { src in b.floatChannelData![0].update(from: src.baseAddress!, count: x.count) }
        try? f.write(from: b)
    }
}

private extension NSLock {
    func locked<T>(_ f: () -> T) -> T { lock(); defer { unlock() }; return f() }
}
