// A dictation transcribed and polished while it is being said (docs/design/dictation.md §Streaming).
//
// Before, everything waited for the key to come up: the whole recording went to the speech model, then the whole text
// to polish — 2–3 s after a 30 s dictation, more after a minute. Now the audio is cut at the pauses as it comes in
// (BlurtCore's DictationSegmenter: ≥ 0.5 s of quiet, pieces of ≥ 3 s, at most 20 s), and each piece is
//   1. transcribed as soon as it is complete (the warm speech server; the text so far goes along as context, so a name
//      is spelled the same way all through), on one serial queue;
//   2. polished right after, on another (the polished text so far goes along as the text before the cursor, so polish
//      sees what came before without being allowed to change it). A piece that opens with a self-correction ("不对…")
//      is polished together with the one before it.
// At key-up only the last piece is left: its transcription and polish are all the user waits for.
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
        var asrSpan: (Double, Double) = (0, 0)
        var polishSpan: (Double, Double) = (0, 0)
        var loadMS = 0
        init(index: Int, start: Int, end: Int, hard: Bool) { self.index = index; self.start = start; self.end = end; self.hard = hard }
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

    init(id: String, dir: URL, wholeWav: URL, options: Options) {
        self.id = id; self.dir = dir; self.wholeWav = wholeWav; self.opt = options
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: while talking (main thread)

    func append(_ x: [Float]) {
        guard !cancelled else { return }
        audio += x
        guard opt.streaming else { return }
        for cut in segmenter.feed(x) {
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

    private func enqueue(start: Int, end: Int, hard: Bool) {
        guard end > start else { return }
        let p = lock.locked { () -> Piece in
            let p = Piece(index: pieces.count, start: start, end: end, hard: hard)
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
        let before = lock.locked { pieces.prefix(p.index).map(\.raw) }
        let prior = String(DictationStitch.join(before).suffix(200))
        let t0 = CACurrentMediaTime()
        let r = Dictation.transcribe(url, vocab: opt.vocab, language: opt.language, prior: prior, budget: 30)
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
        emit(["event": "dictation_piece_text", "id": id, "index": p.index, "ms": Int((p.asrSpan.1 - p.asrSpan.0) * 1000),
              "chars": text.count, "ok": r != nil])
        polishQ.async { self.polish(p) }
    }

    private func polish(_ p: Piece) {
        guard !cancelled else { return }
        guard opt.polish, !p.raw.isEmpty else { p.text = p.raw; return }
        // a piece that opens with "不对…" / "no wait…": polished with the one before, so the corrected-away words go
        var input = p.raw
        var merged: Piece?
        if let prev = previous(p), DictationStitch.startsWithCorrection(p.raw), !prev.raw.isEmpty {
            input = DictationStitch.join(prev.raw, p.raw)
            merged = prev
        }
        let upTo = merged?.index ?? p.index
        let done = lock.locked { pieces.prefix(upTo).map(\.text) }
        var ctx = lock.locked { context }?.payload ?? [:]
        let so = DictationStitch.join(done)
        if !so.isEmpty { ctx["before"] = DictationStitch.join(ctx["before"] as? String ?? "", so) }
        let t0 = CACurrentMediaTime()
        let r = Dictation.polish(input, timeout: opt.polishTimeout, loadBudget: opt.loadBudget, vocab: opt.vocab,
                                 context: ctx.isEmpty ? nil : ctx)
        p.polishSpan = (t0, CACurrentMediaTime())
        p.loadMS += r?["load_ms"] as? Int ?? 0
        p.polish = r
        let out = (r?["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? input
        if let m = merged { m.text = ""; p.text = out } else { p.text = out }
    }

    // MARK: key-up

    /// The last piece, then everything joined. `done` runs on the main queue.
    func finish(keyUp: CFTimeInterval, _ done: @escaping (Result) -> Void) {
        self.keyUp = keyUp
        let n = lock.locked { pieces.count }
        let tail = audio.count - pieceStart
        if n == 0 || (tail > Int(0.3 * NoteVoice.rate) && (segmenter.pieceSpeech >= 3 || !opt.streaming)) {
            enqueue(start: pieceStart, end: audio.count, hard: pieceHard)
        }
        onStage?("asr")
        // both queues are serial: this runs after every piece's transcription, and what it queues after every polish
        // (strong captures: the controller has let go of the stream by now; the queues hold it until it is done)
        asrQ.async {
            if self.opt.polish { DispatchQueue.main.async { self.onStage?("polish") } }
            self.polishQ.async {
                guard !self.cancelled else { return }
                let r = self.assemble()
                DispatchQueue.main.async { done(r) }
            }
        }
    }

    private func assemble() -> Result {
        let ps = lock.locked { pieces }
        // the safety path: a piece the speech model failed on → the whole recording, the old way
        if ps.contains(where: \.asrFailed) {
            emit(["event": "dictation_stream_fallback", "id": id, "why": "asr_failed"])
            return whole(ps.count)
        }
        let raw = DictationStitch.join(ps.map(\.raw))
        let heard = DictationStitch.join(ps.map(\.asrText))
        var text = DictationStitch.join(ps.map(\.text))
        let pol = ps.compactMap(\.polish)
        var fellBack = pol.contains { $0["fell_back"] as? Bool == true }
        var reason = pol.first { $0["fell_back"] as? Bool == true }?["reason"] as? String
        let polished: String? = pol.isEmpty ? nil : DictationStitch.join(ps.map { p in
            p.text.isEmpty ? "" : ((p.polish?["polished"] as? String) ?? p.raw)
        })
        // the joined result once more against the joined transcript: pieces that each passed can still add up wrong
        if opt.polish, ps.count > 1, !pol.isEmpty, text != raw,
           let g = WarmServer.call("polish-serve", ["cmd": "guard", "raw": raw, "output": text, "vocab": opt.vocab,
                                                    "context": lock.locked { context }?.payload ?? NSNull()], timeout: 2),
           g["pass"] as? Bool == false {
            emit(["event": "dictation_stream_fallback", "id": id, "why": "stitch_guard", "reason": g["reason"] ?? NSNull()])
            text = raw
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
                      segments: ps.count, timing: timing(ps))
    }

    /// The old path on the whole recording: one transcription, one polish.
    private func whole(_ n: Int) -> Result {
        let t0 = CACurrentMediaTime()
        let r = Dictation.transcribe(wholeWav, vocab: opt.vocab, language: opt.language, prior: "", budget: 30) ?? [:]
        let t1 = CACurrentMediaTime()
        let raw = (r["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pol = opt.polish && !raw.isEmpty ? Dictation.polish(raw, timeout: opt.polishTimeout, loadBudget: opt.loadBudget,
                                                               vocab: opt.vocab, context: lock.locked { context }?.payload) : nil
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
                      segments: n, timing: timing)
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
