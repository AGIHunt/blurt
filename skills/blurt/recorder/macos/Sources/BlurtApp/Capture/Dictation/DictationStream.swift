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
// A cut is a pause, not a sentence end (each piece used to come back as a whole utterance: a full stop at every
// breath). So a piece's own ending isn't final: its trailing 。/，is taken off before polish, and polish works over a
// sliding window — the last, unfinished clause of the window before (`carry`) is polished again together with the
// new piece (after a long pause, ≥ 1.2 s, with the mark it ended in: the model decides whether the sentence ended),
// and only the text up to the window's last sentence end or comma is committed (DictationStitch.commitSplit). Without
// polish the transcripts are joined with the seam rule (DictationStitch.joinPieces). At key-up the last window is the
// carried clause + the last piece. Structured then runs one structuring pass over the joined text (`finish(structure:)`).
// Nothing here reads the words for meaning: no correction markers, no stop words (docs/design/dictation.md §Rules vs
// model).
//
// Safety: a piece the speech model failed on → the whole recording is transcribed (and polished) in one go, the old
// way. A hard cut (no pause for 20 s) overlaps the pieces by 0.8 s and DictationStitch drops the doubled words. Each
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
    }

    /// One piece of the recording and what became of it.
    final class Piece {
        let index: Int
        let start: Int, end: Int
        /// it began at a hard cut (overlapping the piece before)
        let hard: Bool
        var asr: [String: Any]?
        /// the text after the sounds-like pass (what polish gets), the overlap with the piece before removed
        var raw = ""
        /// what the speech model itself wrote (the history's "heard")
        var asrText = ""
        var polish: [String: Any]?
        /// what this piece contributes to the final text ("" when it was polished together with the next one)
        var text = ""
        var asrFailed = false
        /// enqueued at key-up: the dictation ends here, so its ending is final
        let last: Bool
        /// polish's own output for what this piece committed (the history's "polished")
        var polishedPart = ""
        var asrSpan: (Double, Double) = (0, 0)
        var polishSpan: (Double, Double) = (0, 0)
        var loadMS = 0
        /// the polish window's input (the carried clause + this piece): the Dictation Lab shows it
        var polishInput = ""
        init(index: Int, start: Int, end: Int, hard: Bool, last: Bool = false) {
            self.index = index; self.start = start; self.end = end; self.hard = hard; self.last = last
        }
    }

    struct Result {
        var raw: String           // the transcript (sounds-like pass applied), joined
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
    /// what has been heard so far (the pieces' transcripts, joined), on the main queue after each piece — the words
    /// shown while talking (LiveTranscript); nothing else reads it
    var onHeard: ((String) -> Void)?

    private var segmenter = DictationSegmenter(sampleRate: NoteVoice.rate)
    private var audio: [Float] = []             // main thread
    private var pieceStart = 0
    private var pieceHard = false
    private var pieces: [Piece] = []           // appended on main, read on the queues after their block was queued
    private let lock = NSLock()
    private let asrQ = DispatchQueue(label: "blurt.dictation.asr", qos: .userInitiated)
    private let polishQ = DispatchQueue(label: "blurt.dictation.polish", qos: .userInitiated)
    private var cancelled = false
    private var keyUp: CFTimeInterval = 0
    /// the pause after each piece (DictationSegmenter.pauses, copied on the main thread as it learns them)
    private var pauses: [Double?] = []
    /// polishQ only: the last window's unfinished clause (the typed text and polish's own output) and the
    /// punctuation it ended in — polished again with the next piece
    private var carry = "", carryPolished = "", carryEnd = ""

    init(id: String, dir: URL, wholeWav: URL, options: Options) {
        self.id = id; self.dir = dir; self.wholeWav = wholeWav; self.opt = options
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: while talking (main thread)

    func append(_ x: [Float]) {
        guard !cancelled else { return }
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
    }

    var segments: Int { lock.lock(); defer { lock.unlock() }; return pieces.count }

    func cancel() {
        cancelled = true
        let ps = lock.locked { pieces }
        for p in ps { try? FileManager.default.removeItem(at: wav(p.index)) }
    }

    private func wav(_ i: Int) -> URL { dir.appendingPathComponent("\(id)-p\(i).wav") }

    private func enqueue(start: Int, end: Int, hard: Bool, last: Bool = false) {
        guard end > start else { return }
        let p = lock.locked { () -> Piece in
            let p = Piece(index: pieces.count, start: start, end: end, hard: hard, last: last)
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
        let r = Dictation.transcribe(url, vocab: opt.vocab, language: opt.language, prior: prior, budget: 30,
                                     hint: lock.locked { context }?.hint ?? "")
        p.asrSpan = (t0, CACurrentMediaTime())
        p.loadMS += r?["load_ms"] as? Int ?? 0
        try? FileManager.default.removeItem(at: url)
        p.asr = r
        if r == nil { p.asrFailed = true }
        var text = (r?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var heard = (r?["asr_text"] as? String ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hard, let prev = previous(p) {
            text = DictationStitch.dropOverlap(previous: prev.raw, next: text)
            heard = DictationStitch.dropOverlap(previous: prev.asrText, next: heard)
        }
        p.raw = text
        p.asrText = heard
        if let f = onHeard {
            // the live transcript (LiveTranscript): what was heard so far, joined as the transcript is
            let (all, gaps) = lock.locked { (pieces.prefix(p.index + 1).map(\.raw), pauses) }
            let so = DictationStitch.joinPieces(all, pauses: gaps)
            DispatchQueue.main.async { f(so) }
        }
        emit(["event": "dictation_piece_text", "id": id, "index": p.index, "ms": Int((p.asrSpan.1 - p.asrSpan.0) * 1000),
              "chars": text.count, "ok": r != nil])
        polishQ.async { self.polish(p) }
    }

    /// The pause after piece `i` (nil: not known, or no such piece).
    private func pause(after i: Int) -> Double? {
        lock.locked { i >= 0 && i < pauses.count ? pauses[i] : nil }
    }

    /// One polish window: the carried, unfinished clause + this piece (its own ending taken off unless it is the
    /// last). What the window says up to its last sentence end or comma is committed; the rest is carried to the next
    /// window. After a long pause the carried clause keeps the mark it ended in: the pause may have ended a sentence,
    /// and the model decides with both sides in view (no stop-word list does).
    private func polish(_ p: Piece) {
        guard !cancelled else { return }
        // without polish the transcripts are joined with the seam rule at the end (assemble)
        guard opt.polish, !p.raw.isEmpty else { return }
        let core = p.last ? p.raw : DictationStitch.splitTrailing(p.raw).core
        var carried = carry
        if !carry.isEmpty, let g = pause(after: p.index - 1), g >= DictationStitch.longPause {
            carried += DictationStitch.mark(carryEnd, after: carry)
        }
        carry = ""; carryPolished = ""; carryEnd = ""
        let input = DictationStitch.join(carried, core)
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
            // the model capitalised a window that continues a sentence
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

    // MARK: key-up

    /// The last piece, then everything joined; `structure` (Structured / Auto at key-up): the joined text then goes
    /// through the polish model's structuring pass once. `done` runs on the main queue.
    func finish(keyUp: CFTimeInterval, structure: Bool = false, _ done: @escaping (Result) -> Void) {
        self.keyUp = keyUp
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
                guard !self.cancelled else { return }
                var r = self.assemble()
                if structure, !r.empty { self.structure(&r) }
                DispatchQueue.main.async { done(r) }
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
        if ps.contains(where: \.asrFailed) {
            emit(["event": "dictation_stream_fallback", "id": id, "why": "asr_failed"])
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
        return Result(raw: raw, asrText: heard, text: text.isEmpty ? raw : text, polished: polished, fellBack: fellBack,
                      reason: reason, model: pol.first { $0["model"] is String }?["model"] as? String,
                      asrModel: first["model"] as? String, language: first["language"] as? String,
                      biased: first["biased"] as? Bool ?? false, terms: terms,
                      contextUsed: pol.contains { $0["context"] as? Bool == true }, repaired: repaired,
                      segments: ps.count, timing: timing(ps), pieces: ps.map { describe($0, gaps) })
    }

    /// One piece for the Dictation Lab (what each stage made of it, and how long it took).
    private func describe(_ p: Piece, _ gaps: [Double?]) -> [String: Any] {
        let ms = { (s: (Double, Double)) in Int(max(0, s.1 - s.0) * 1000) }
        var o: [String: Any] = ["index": p.index, "start": (Double(p.start) / NoteVoice.rate * 100).rounded() / 100,
                                "end": (Double(p.end) / NoteVoice.rate * 100).rounded() / 100, "hard": p.hard,
                                "asr_text": p.asrText, "raw": p.raw, "asr_ms": ms(p.asrSpan), "text": p.text,
                                "polish_in": p.polishInput, "polished": p.polishedPart, "polish_ms": ms(p.polishSpan),
                                "fell_back": p.polish?["fell_back"] as? Bool ?? false, "reason": p.polish?["reason"] ?? NSNull(),
                                "repaired": p.polish?["repaired"] as? [String] ?? [], "load_ms": p.loadMS]
        let g: Double? = p.index < gaps.count ? gaps[p.index] : nil
        o["pause_after"] = g.map { ($0 * 100).rounded() / 100 as Any } ?? NSNull()
        return o
    }

    /// The old path on the whole recording: one transcription, one polish.
    private func whole(_ n: Int) -> Result {
        let t0 = CACurrentMediaTime()
        let r = Dictation.transcribe(wholeWav, vocab: opt.vocab, language: opt.language, prior: "", budget: 30,
                                     hint: lock.locked { context }?.hint ?? "") ?? [:]
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
        return Result(raw: raw, asrText: r["asr_text"] as? String ?? raw, text: text, polished: pol?["polished"] as? String,
                      fellBack: pol?["fell_back"] as? Bool ?? false, reason: pol?["reason"] as? String,
                      model: pol?["model"] as? String, asrModel: r["model"] as? String, language: r["language"] as? String,
                      biased: r["biased"] as? Bool ?? false, terms: (r["terms"] as? [String] ?? []) + (pol?["terms"] as? [String] ?? []),
                      contextUsed: pol?["context"] as? Bool ?? false, repaired: pol?["repaired"] as? [String] ?? [],
                      segments: n, timing: timing,
                      pieces: [["index": 0, "start": 0, "end": NSNull(), "hard": false, "whole": true,
                                "asr_text": r["asr_text"] as? String ?? raw, "raw": raw, "asr_ms": timing["asr_ms"] ?? 0,
                                "text": text, "polish_in": raw, "polished": pol?["polished"] ?? NSNull(),
                                "polish_ms": timing["polish_ms"] ?? 0, "fell_back": pol?["fell_back"] as? Bool ?? false,
                                "reason": pol?["reason"] ?? NSNull(), "repaired": pol?["repaired"] as? [String] ?? []]])
    }

    /// What the user waited for after key-up (the work before it was hidden behind the talking), and the total.
    private func timing(_ ps: [Piece]) -> [String: Int] {
        func after(_ s: (Double, Double)) -> Double { max(0, s.1 - max(s.0, keyUp)) }
        let asr = ps.reduce(0) { $0 + after($1.asrSpan) }, pol = ps.reduce(0) { $0 + after($1.polishSpan) }
        let asrAll = ps.reduce(0) { $0 + ($1.asrSpan.1 - $1.asrSpan.0) }, polAll = ps.reduce(0) { $0 + ($1.polishSpan.1 - $1.polishSpan.0) }
        return ["asr_ms": Int(asr * 1000), "polish_ms": Int(pol * 1000), "load_ms": ps.reduce(0) { $0 + $1.loadMS },
                "segments": ps.count, "asr_ms_all": Int(asrAll * 1000), "polish_ms_all": Int(polAll * 1000),
                "total_ms": Int((CACurrentMediaTime() - keyUp) * 1000)]
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
