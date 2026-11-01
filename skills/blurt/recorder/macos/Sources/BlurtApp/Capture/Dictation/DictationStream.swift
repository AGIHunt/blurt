// A dictation transcribed and polished while it is being said (docs/design/dictation.md §Streaming).
//
// Before, everything waited for the key to come up: the whole recording went to the speech model, then the whole text
// to polish — 2–3 s after a 30 s dictation, more after a minute. Now the audio is cut at the pauses as it comes in
// (BlurtCore's DictationSegmenter: ≥ 0.5 s of quiet, pieces of ≥ 3 s, at most 20 s), and each piece is
//   1. transcribed as soon as it is complete (the warm speech server; the text so far goes along as context, so a name
//      is spelled the same way all through — transcribe.py keeps only its last 80 characters and decodes a piece
//      that echoes it once more without it; with "Use the text around the cursor" on, the field's last 300 characters
//      before the cursor go too, which a model that takes them hears ahead of it: §Field context), on one serial queue;
//   2. polished right after, on another (the polished text so far goes along as the turn before, so polish sees what
//      came before without being allowed to change it).
// At key-up only the last piece is left: its transcription and polish are all the user waits for.
//
// Hearing again (docs/design/dictation.md §Hearing again): a piece is 3–8 s of a sentence, and the speech model hears
// it without the rest (德宝 for 豆包, 巨幅 for GIF). So the pieces are heard once more in windows of the speech model's
// length (ModelCatalog.rehearWindow: Qwen3-ASR 1.7B 30 s, 0.6B 20 s, others 10 s)
// (DictationStitch.rehearGroups: a window closes at a pause cut, never at a hard one — windows don't share audio), with
// the windows' text so far as context, while the user still talks; polish then works window by window. The pieces'
// own transcripts are the live text. At key-up the open window (the pieces since the last one, the last piece in it
// heard only there) is what is left. A window of one piece keeps that piece's transcript; one the model fails on keeps
// its pieces' (`dictation_rehear` logs both).
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
// Second transcript (docs/design/dictation.md §Second transcript): with cloud polish, macOS's own recogniser hears
// each window's audio too (each piece's when the take isn't heard again), on its own queue beside the speech model,
// and polish gets its text as "Also heard" — evidence about the sounds where the two differ (dictation-eval-2026-10-31
// §4.2: cloud polish of the 1.7B's text 2.50 → 3.16 % without it, → 2.20 % with it). Polish then runs once, over the
// whole take at key-up (`polishAtKeyUp`), as the eval measured it: window by window the same polish made 2.57–2.92 %
// on the same takes (worse than none), at key-up 2.20–2.28 %; it costs ~0.3 s more after key-up on a minute-long take
// (one cloud request either way). Polish waits for the last second transcript at most `secondWait`; without one
// (macOS 13–15, a language it doesn't speak) polish runs window by window as before.
//
// A cloud recogniser (`wholeAtKeyUp`, §Cloud recognition): the pieces are heard by macOS's recogniser only — the live
// text, and the second transcript — and at key-up the whole take goes to the cloud service once, with the words and
// the field's text (dictation-eval §4.1: short pieces with the field's text made it type that text back, 26.6 % errors
// against 2.0 % for the whole take). Without macOS's recogniser the take isn't cut at all (Dictation: streaming off):
// one request at key-up, as before for a short take.
//
// A cloud recogniser that hears the take as it is said (`streamCloud`: Volcengine Seed-ASR 2.0, dictation-eval
// §6.3 B′): the microphone's samples go to it all along through the warm speech server (BlurtCore WarmServerStream,
// transcribe.py `serve` cmd "stream"; one session per take), and at key-up only its final text is waited for — ~0.5 s
// however long the take, where a whole take sent at key-up grows with it (Flash: 0.5 → 1.5 s). The request goes out
// once the field's text is read (or after 1.5 s of audio without it); until the server is up the samples wait. A stream
// that couldn't be used (no server, the connection broke) → the whole take at key-up, as above; one the service refused
// (key, quota: "quota exceeded for types: concurrency") → the failure line, the recording kept for Retry, which sends
// the kept recording whole through the same service.
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
        /// the user's cloud model for polish (DictationCloud.payload: base URL, model, key), and the last dictations in
        /// the same app it is told about (DictationCloud.recent); nil / empty: the local model, as before
        var cloud: [String: Any]?
        var recent: [String] = []
        /// hear the pieces again in windows (record.dictation.rehear; §Hearing again), of this many seconds
        /// (record.dictation.rehear_window_s)
        var rehear = true
        var rehearWindow = DictationStitch.rehearWindow
        /// cloud polish gets macOS's transcript of the same audio (§Second transcript)
        var second = false
        /// a cloud recogniser: the pieces go to macOS's recogniser (live text), the whole take to the service at key-up
        var wholeAtKeyUp = false
        /// …one that hears the take while it is said (Volcengine): the samples stream to it, its text comes at key-up
        var streamCloud = false
        /// the field's text is being read (Dictation.contextOn): the stream's request waits for it (setContext)
        var contextComing = false
        /// only my voice (Dictation.onlyMyVoice, docs/design/voiceprint.md): each piece is judged once — by the speech
        /// server as it recognises it, or by `vp_gate` when macOS's recogniser hears it — and what was dropped from a
        /// piece is silenced in everything else that hears that audio (its window, the second transcript)
        var voiceGate = false
        /// polish once over the whole take at key-up instead of window by window (cloud polish with the second
        /// transcript: `second`)
        var polishAtKeyUp: Bool { second }
    }

    /// The longest polish waits for a window's second transcript (macOS's recogniser: ~0.2 s for a 10 s window).
    static let secondWait = 2.0

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
        /// a window (hearing again): the pieces it covers; nil for a piece
        var members: Range<Int>?
        /// the last piece, heard only as part of its window (no transcript of its own: nobody watches the live text then)
        var covered = false
        /// a window: what its pieces' transcripts said, joined (the history keeps both)
        var piecesText = ""
        /// only my voice: everything in this piece was someone else (dropped before recognition) — lock
        var allOther = false
        /// macOS's transcript of the same audio (§Second transcript; nil: not asked or nothing came) — lock
        var second: String?
        var secondAsked = false
        let secondDone = DispatchGroup()
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
        /// some of a streamed take's polish windows fell back, not all (`fellBack` is then false)
        var fellBackParts: DictationParts?
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
        /// cloud polish failed and the local model (or nothing) polished instead: polish.py's code (auth, rate_limited,
        /// network …) — a key refused is said once a day (Dictation.afterPaste), not left to fall back unseen
        var polishCloudError: String?
        /// each piece's language tag and how sure the model was (transcribe.py's `tag`; the history keeps them)
        var tags: [[String: Any]] = []
        /// the windows the pieces were heard again in (§Hearing again): pieces, start / end, what the pieces said and
        /// what the window said, asr_ms, ok
        var windows: [[String: Any]] = []
        /// only my voice: the spans of the take (s) another speaker said, left out
        var voiceDropped: [[Double]] = []
        /// Translated (docs/design/dictation-translate.md): the text in its style, in the other language — typed in
        /// place of it (nil: not asked, already in the target, or refused: then the text as said is typed)
        var translated: String?
        /// what the translation did, for the history (nil: the take wasn't translated)
        var translation: DictationTranslateRecord?
        var empty: Bool { raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// A take to translate at key-up (Dictation.translateJob): Settings' target, the style it is typed in (the
    /// translation is of that text), the cloud model (nil: the local one), how it was turned on.
    struct TranslateJob {
        var setting: DictationTranslateTarget
        /// what Auto means on this Mac (TranslateTargets.pair, read on the main thread at key-up)
        var auto: TranslateAutoPair
        var style: DictationStyle
        var cloud: [String: Any]?
        var engine: DictationTranslateRoute.Engine
        var source: String
        var toggles: Int
    }

    let id: String
    let dir: URL
    private(set) var opt: Options
    /// the text around the cursor: read at the start, while the first piece may already be under way
    private var context: DictationContext?
    func setContext(_ c: DictationContext?) {
        lock.locked { context = c }
        if let cs = cloudStream {
            var f: [String: Any] = [:]
            if let app = c?.app, !app.isEmpty { f["app"] = app }
            if let h = c?.hint, !h.isEmpty { f["hint"] = h }
            if let b = c?.asrBefore, !b.isEmpty { f["before"] = b }
            cs.update(f)
            cs.release()
        }
    }
    /// the take's audio, streamed to a recogniser that hears it as it comes (`streamCloud`)
    private let cloudStream: WarmServerStream?
    private var cloudReleased = false       // main thread
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
    /// the windows heard again (§Hearing again), like `pieces`; and the open window (main thread): its first sample
    /// and first piece
    private var windows: [Piece] = []
    private var windowStart = 0, windowFirst = 0
    private let lock = NSLock()
    private let asrQ = DispatchQueue(label: "blurt.dictation.asr", qos: .userInitiated)
    private let polishQ = DispatchQueue(label: "blurt.dictation.polish", qos: .userInitiated)
    /// macOS's recogniser for the second transcript, beside the speech model's queue
    private let secondQ = DispatchQueue(label: "blurt.dictation.second", qos: .userInitiated)
    /// a cloud recogniser's whole take at key-up (`wholeAtKeyUp`): its answer and when it was asked — lock
    private var cloudAnswer: [String: Any]?
    private var cloudAsked: CFTimeInterval = 0
    private let cloudDone = DispatchGroup()
    private var cancelled = false
    /// Esc while polishing (skipPolish): no more polish windows; the result is handed over once (`delivered`), through
    /// `finished` (finish's `done`) — lock
    private var skipped = false, delivered = false
    /// the whole recording is being heard again (a piece failed: `whole`) — lock; the take's deadline counts it
    private var hearingWhole = false
    private var finished: ((Result) -> Void)?
    private var keyUp: CFTimeInterval = 0
    /// Auto's structuring pass (only a list changes what is typed): finish(onlyForLists:)
    private var onlyForLists = false
    /// the pause after each piece (DictationSegmenter.pauses, copied on the main thread as it learns them)
    private var pauses: [Double?] = []
    /// only my voice: the take's samples another speaker said (each piece's verdict, in the take's samples) — lock
    private var muted: [Range<Int>] = []
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
        cloudStream = options.streamCloud
            ? WarmServerStream(server: "asr-serve", header: ["model_id": VolcengineSpeech.modelID, "language": options.language,
                                                           "vocab": options.vocab, "purpose": "dictation"],
                               hold: options.contextComing)
            : nil
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !options.interim || !options.streaming { live = DictationLiveDecode(sampleRate: NoteVoice.rate, off: .setting) }
    }

    // MARK: while talking (main thread)

    func append(_ x: [Float]) {
        guard !cancelled else { return }
        if audio.isEmpty { firstAudio = CACurrentMediaTime() }
        audio += x
        if let cs = cloudStream {
            cs.append(x)
            // the field's text didn't come: the request goes without it rather than wait longer
            if !cloudReleased, audio.count >= Int(1.5 * NoteVoice.rate) { cloudReleased = true; cs.release() }
        }
        guard opt.streaming else { return }
        let cuts = segmenter.feed(x)
        let known = segmenter.pauses
        if known != lock.locked({ pauses }) { lock.locked { pauses = known } }
        for cut in cuts {
            enqueue(start: pieceStart, end: cut.end, hard: pieceHard)
            pieceStart = cut.nextStart
            pieceHard = cut.hard
            if opt.rehear, DictationStitch.closesWindow(start: windowStart, end: cut.end, hardCut: cut.hard, sampleRate: NoteVoice.rate,
                                                        window: opt.rehearWindow) {
                closeWindow(end: cut.end)
            }
        }
        interimIfDue()
    }

    var segments: Int { lock.lock(); defer { lock.unlock() }; return pieces.count }

    /// Esc while it is still polishing ("Still polishing… Esc types it as spoken"): what was heard goes in as it is, as
    /// soon as the transcripts are in — the polish under way (or a model still loading) is not waited for, and its
    /// answer, when it comes, is dropped. The take falls back the way a refused polish does (reason "skipped").
    func skipPolish() {
        lock.locked { skipped = true }
        // the whole take in the cloud: what it heard goes in unpolished (whole() looks at `skipped`); the pieces were
        // only macOS's live text
        if opt.wholeAtKeyUp { return }
        asrQ.async {
            guard !self.cancelled, let r = self.spokenResult() else { return }
            emit(["event": "dictation_polish_skipped", "id": self.id])
            self.deliver(r)
        }
    }

    /// Hands the take's result over once: the polished one, or the one Esc asked for, whichever is first.
    private func deliver(_ r: Result) {
        var r = r
        let done: ((Result) -> Void)? = lock.locked {
            if delivered { return nil }
            delivered = true
            // the history keeps what was left out (merged, in seconds of the take as recorded)
            var spans: [[Double]] = []
            for m in muted.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                let s = Double(m.lowerBound) / NoteVoice.rate, e = Double(m.upperBound) / NoteVoice.rate
                if let last = spans.last, s <= last[1] + 0.05 { spans[spans.count - 1][1] = max(last[1], e) }
                else { spans.append([s, e]) }
            }
            r.voiceDropped = spans.map { $0.map { ($0 * 100).rounded() / 100 } }
            return finished
        }
        guard let d = done else { return }
        DispatchQueue.main.async { d(r) }
    }

    /// The transcripts joined as a refused polish types them (a comma where a boundary was heard); nil when a piece
    /// failed to transcribe (the safety path then decides, as without Esc).
    private func spokenResult() -> Result? {
        let (ps, us, ws, gaps, pgaps) = lock.locked { (pieces, units, windows, unitGaps, pauses) }
        guard !us.isEmpty, !us.contains(where: \.asrFailed) else { return nil }
        let raw = DictationStitch.joinPieces(us.map(\.raw), pauses: gaps)
        let heard = DictationStitch.joinPieces(us.map(\.asrText), pauses: gaps)
        let text = DictationStitch.joinPiecesForFallback(us.map(\.raw), pauses: gaps)
        var terms: [String] = []
        for p in us { for t in p.asr?["terms"] as? [String] ?? [] where !terms.contains(t) { terms.append(t) } }
        let first = us.first { $0.asr != nil }?.asr ?? [:]
        var r = Result(raw: raw, asrText: heard, text: text.isEmpty ? raw : text, polished: nil, fellBack: true,
                       reason: "skipped", model: nil, asrModel: first["model"] as? String, language: first["language"] as? String,
                       biased: first["biased"] as? Bool ?? false, terms: terms, contextUsed: false, repaired: [],
                       segments: ps.count, timing: timing(ps, windows: ws), pieces: ps.map { describe($0, pgaps) })
        r.timing["total_ms"] = Int((CACurrentMediaTime() - keyUp) * 1000)
        r.tags = us.compactMap { $0.asr?["tag"] as? [String: Any] }
        r.windows = ws.map(describeWindow)
        return r
    }

    func cancel() {
        cancelled = true
        cloudStream?.cancel()
        live.stop()
        let ps = lock.locked { pieces }
        for p in ps { try? FileManager.default.removeItem(at: wav(p.index)) }
        for w in lock.locked({ windows }) { try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id)-w\(w.index).wav")) }
        try? FileManager.default.removeItem(at: liveWav)
    }

    private func wav(_ i: Int) -> URL { dir.appendingPathComponent("\(id)-p\(i).wav") }

    private func enqueue(start: Int, end: Int, hard: Bool, last: Bool = false, covered: Bool = false) {
        guard end > start else { return }
        if !covered { live.finalQueued() }   // before the request goes out: no interim is sent from here until it is in
        let p = lock.locked { () -> Piece in
            let p = Piece(index: pieces.count, start: start, end: end, hard: hard, last: last)
            p.arrived = CACurrentMediaTime() - Double(max(0, audio.count - end)) / NoteVoice.rate
            p.covered = covered
            p.asrDone = covered
            pieces.append(p)
            return p
        }
        emit(["event": "dictation_piece", "id": id, "index": p.index, "start": Double(start) / NoteVoice.rate,
              "end": Double(end) / NoteVoice.rate, "hard": hard, "covered": covered])
        guard !covered else { return }
        let samples = Array(audio[max(0, start)..<min(end, audio.count)])
        // only my voice: the second transcript waits for the piece's verdict (transcribe), so it never hears what is dropped
        if opt.second, !opt.rehear, !opt.wholeAtKeyUp, !opt.voiceGate { hearSecond(p, samples) }
        asrQ.async { self.transcribe(p, samples) }      // the queues keep the stream alive until its work is done
    }

    /// The open window ends here (main thread): the pieces since the last window, heard again on the speech queue
    /// after their own transcripts.
    private func closeWindow(end: Int, last: Bool = false) {
        let (w, members) = lock.locked { () -> (Piece?, [Piece]) in
            guard windowFirst < pieces.count, end > windowStart else { return (nil, []) }
            let w = Piece(index: windows.count, start: windowStart, end: end, hard: false, last: last)
            w.members = windowFirst..<pieces.count
            windows.append(w)
            return (w, Array(pieces[windowFirst..<pieces.count]))
        }
        windowFirst = lock.locked { pieces.count }
        windowStart = end
        guard let w else { return }
        // one piece that was heard already: the same audio, nothing to hear again
        let again = members.count > 1 || members.contains(where: \.covered)
        let audioW = Array(audio[max(0, w.start)..<min(end, audio.count)])
        let samples = again ? audioW : []
        if opt.second, !opt.voiceGate { hearSecond(w, audioW) }
        // only my voice: the window's second transcript waits for its verdicts (rehear)
        asrQ.async { self.rehear(w, members, samples, second: self.opt.second && self.opt.voiceGate ? audioW : nil) }
    }

    /// macOS's recogniser on a unit's audio, on its own queue (§Second transcript): its text is the unit's `second`.
    private func hearSecond(_ u: Piece, _ samples: [Float]) {
        guard !samples.isEmpty else { return }
        u.secondAsked = true
        u.secondDone.enter()
        let url = dir.appendingPathComponent("\(id)-\(u.members == nil ? "p" : "w")\(u.index)-second.wav")
        secondQ.async {
            defer { u.secondDone.leave() }
            guard !self.cancelled else { return }
            DictationStream.writeWav(samples, to: url)
            let t0 = CACurrentMediaTime()
            let r = AppleSpeech.transcribe(url, language: self.opt.language, vocab: self.opt.vocab, purpose: "dictation_second")
            try? FileManager.default.removeItem(at: url)
            let text = (r["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.lock.locked { u.second = r["ok"] as? Bool == true && !text.isEmpty ? text : nil }
            emit(["event": "dictation_second", "id": self.id, "unit": u.members == nil ? "piece" : "window", "index": u.index,
                  "ok": r["ok"] as? Bool ?? false, "code": r["code"] ?? NSNull(), "chars": text.count,
                  "ms": Int((CACurrentMediaTime() - t0) * 1000)])
        }
    }

    /// A unit's second transcript once it is in (waiting until `until`: at most `secondWait` for all of a take's);
    /// nil without one.
    private func secondOf(_ u: Piece, until: DispatchTime) -> String? {
        guard opt.second, u.secondAsked else { return nil }
        if u.secondDone.wait(timeout: until) == .timedOut {
            emit(["event": "dictation_second", "id": id, "index": u.index, "ok": false, "code": "late"])
            return nil
        }
        return lock.locked { u.second }
    }

    // MARK: the work (queues)

    /// The unit before this one (a piece, or a window when the take is heard again).
    private func previous(_ p: Piece) -> Piece? {
        lock.locked { () -> Piece? in
            let us = p.members == nil ? pieces : windows
            return p.index > 0 && p.index - 1 < us.count ? us[p.index - 1] : nil
        }
    }

    private func transcribe(_ p: Piece, _ samples: [Float]) {
        guard !cancelled else { return }
        let url = wav(p.index)
        var samples = samples
        DictationStream.writeWav(samples, to: url)
        // only my voice, for a piece macOS's recogniser hears (it can't judge voices): the speech server judges it
        // first and macOS's recogniser hears it without what was dropped; a piece that is all someone else isn't heard
        var verdict: [String: Any]?
        if opt.voiceGate, opt.wholeAtKeyUp || AppleSpeech.forDictation, let sp = Dictation.voiceVerdict(url) {
            verdict = sp
            judged(p, sp)
            samples = masked(samples, from: p.start)
            if sp["dropped"] as? Int ?? 0 > 0 { DictationStream.writeWav(samples, to: url) }
        }
        // the text so far, as context: the speech model keeps names consistent across pieces
        let (before, gaps) = lock.locked { (Array(pieces.prefix(p.index).map(\.raw)), pauses) }
        let prior = String(DictationStitch.joinPieces(before, pauses: gaps).suffix(200))
        let t0 = CACurrentMediaTime()
        // a cloud recogniser hears the whole take at key-up: the pieces are macOS's live text only (never billed,
        // never a reason for the safety path)
        let answer: [String: Any] = verdict?["match"] as? Bool == false
            ? ["ok": true, "text": "", "speaker": verdict ?? [:]]
            : opt.wholeAtKeyUp
            ? AppleSpeech.transcribe(url, language: opt.language, vocab: opt.vocab, purpose: "dictation_live")
            : Dictation.transcribe(url, vocab: opt.vocab, language: opt.language, prior: prior, budget: 30,
                                   hint: lock.locked { context }?.hint ?? "", app: lock.locked { context }?.app ?? "",
                                   before: lock.locked { context }?.asrBefore ?? "",
                                   audioSeconds: Double(samples.count) / NoteVoice.rate)
        if opt.voiceGate, verdict == nil, let sp = answer["speaker"] as? [String: Any] {
            judged(p, sp)
            samples = masked(samples, from: p.start)
        }
        if opt.second, opt.voiceGate, !opt.rehear, !opt.wholeAtKeyUp { hearSecond(p, samples) }
        p.asrSpan = (t0, CACurrentMediaTime())
        p.loadMS += answer["load_ms"] as? Int ?? 0
        try? FileManager.default.removeItem(at: url)
        let ok = answer["ok"] as? Bool == true
        let r: [String: Any]? = ok ? answer : nil
        p.asr = r
        if !ok, !opt.wholeAtKeyUp { p.asrFailed = true; p.asrCode = answer["code"] as? String ?? "error" }
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
        if !opt.rehear, !opt.wholeAtKeyUp { polishQ.async { self.polish(p) } }
    }

    /// A window heard again (speech queue, after its pieces): its audio in one request, with the windows' text so far
    /// as context — a piece's prior is the same, only shorter. Then polished as one unit.
    /// `second`: the window's audio for macOS's second transcript, asked once the verdicts are in (only my voice).
    private func rehear(_ w: Piece, _ members: [Piece], _ samples: [Float], second: [Float]? = nil) {
        guard !cancelled else { return }
        let gaps = lock.locked { pauses }
        let mine = members.map { $0.index < gaps.count ? gaps[$0.index] : nil }
        let said = DictationStitch.joinPieces(members.map(\.raw), pauses: mine)
        let saidHeard = DictationStitch.joinPieces(members.map(\.asrText), pauses: mine)
        w.piecesText = said
        let failed = members.contains(where: \.asrFailed)
        // only my voice: the members' verdicts are in by now (this same queue judged them) — the window is heard
        // without what they dropped and they aren't judged again; the last piece, heard only here (`covered`), is
        // judged with the window. Pieces that were all someone else leave nothing to hear.
        var judgedAll = !members.contains(where: \.covered)
        if opt.voiceGate, !judgedAll, !samples.isEmpty {
            // the last piece alone, not the whole window again (a 20 s window judged at key-up cost ~0.3 s; its
            // other pieces were judged while they were said); no server to ask: the window is judged as it is heard
            judgedAll = true
            for m in members where m.covered {
                let a = max(0, m.start - w.start), b = min(samples.count, m.end - w.start)
                guard b > a else { continue }
                let url = dir.appendingPathComponent("\(id)-p\(m.index)-voice.wav")
                DictationStream.writeWav(Array(samples[a..<b]), to: url)
                if let sp = Dictation.voiceVerdict(url) { judged(m, sp) } else { judgedAll = false }
                try? FileManager.default.removeItem(at: url)
            }
        }
        let allOther = opt.voiceGate && members.allSatisfy { m in lock.locked { m.allOther } }
        let samples = opt.voiceGate && !samples.isEmpty ? masked(samples, from: w.start) : samples
        if samples.isEmpty || failed || allOther {
            if let s = second { hearSecond(w, masked(s, from: w.start)) }
            // nothing to hear again (one piece), or a piece the model failed on: assemble's safety path decides
            lock.locked { w.raw = said; w.asrText = saidHeard; w.asr = members.first?.asr; w.asrDone = true }
            if failed { w.asrFailed = true; w.asrCode = members.first(where: \.asrFailed)?.asrCode }
            polishQ.async { self.polish(w) }
            return
        }
        let url = dir.appendingPathComponent("\(id)-w\(w.index).wav")
        DictationStream.writeWav(samples, to: url)
        let (before, wgaps) = lock.locked { (Array(windows.prefix(w.index).map(\.raw)), windowGaps()) }
        let prior = String(DictationStitch.joinPieces(before, pauses: wgaps).suffix(200))
        let t0 = CACurrentMediaTime()
        let answer = Dictation.transcribe(url, vocab: opt.vocab, language: opt.language, prior: prior, budget: 30,
                                          hint: lock.locked { context }?.hint ?? "", app: lock.locked { context }?.app ?? "",
                                          before: lock.locked { context }?.asrBefore ?? "",
                                          audioSeconds: Double(samples.count) / NoteVoice.rate,
                                          voiceprint: opt.voiceGate && judgedAll ? false : nil)
        w.asrSpan = (t0, CACurrentMediaTime())
        if opt.voiceGate, !judgedAll, let sp = answer["speaker"] as? [String: Any] { judged(w, sp) }
        if let s = second { hearSecond(w, masked(s, from: w.start)) }
        w.loadMS += answer["load_ms"] as? Int ?? 0
        try? FileManager.default.removeItem(at: url)
        let text = (answer["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // only my voice: a window that was all someone else answers blank, and that is its text — not a failure
        let noneMine = (answer["speaker"] as? [String: Any])?["match"] as? Bool == false
        let ok = answer["ok"] as? Bool == true && (!text.isEmpty || noneMine)
        lock.locked {
            if ok {
                w.raw = text
                w.asrText = (answer["asr_text"] as? String ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
                w.asr = answer
            } else {
                // the pieces' own transcripts: never worse than before
                w.raw = said; w.asrText = saidHeard; w.asr = members.first?.asr
                if members.contains(where: \.covered) { w.asrFailed = true; w.asrCode = answer["code"] as? String ?? "error" }
            }
            w.asrDone = true
        }
        emit(["event": "dictation_rehear", "id": id, "window": w.index, "pieces": members.count,
              "audio_s": (Double(samples.count) / NoteVoice.rate * 100).rounded() / 100,
              "ms": Int((w.asrSpan.1 - w.asrSpan.0) * 1000), "ok": ok, "code": ok ? NSNull() : answer["code"] ?? "empty",
              "changed": ok && text != said])
        polishQ.async { self.polish(w) }
    }

    /// Only my voice: a piece's verdict (`speaker`: match, dropped, similarity, drop [[s, e]] in the piece's seconds)
    /// becomes the take's muted samples.
    private func judged(_ p: Piece, _ sp: [String: Any]) {
        let drop = (sp["drop"] as? [[Double]] ?? []).compactMap { s -> Range<Int>? in
            guard s.count == 2 else { return nil }
            let a = p.start + Int(s[0] * NoteVoice.rate), b = p.start + Int(s[1] * NoteVoice.rate)
            return b > a ? a..<b : nil
        }
        lock.locked {
            muted += drop
            p.allOther = sp["match"] as? Bool == false
        }
        emit(["event": "dictation_voice", "id": id, "index": p.index, "match": sp["match"] ?? NSNull(),
              "dropped": sp["dropped"] ?? 0, "similarity": sp["similarity"] ?? NSNull()])
    }

    /// These samples (from `start` in the take) with another speaker's silenced.
    private func masked(_ x: [Float], from start: Int) -> [Float] {
        let ranges = lock.locked { muted }
        guard !ranges.isEmpty else { return x }
        var y = x
        for r in ranges {
            let a = max(0, r.lowerBound - start), b = min(y.count, r.upperBound - start)
            if a < b { for i in a..<b { y[i] = 0 } }
        }
        return y
    }

    /// The pause after each window (its last piece's) — lock held.
    private func windowGaps() -> [Double?] {
        windows.map { w in w.members.flatMap { $0.last }.flatMap { $0 < pauses.count ? pauses[$0] : nil } }
    }

    /// What polish works through, in order: the windows when the take is heard again, else the pieces — lock held.
    private var units: [Piece] { opt.rehear ? windows : pieces }
    private var unitGaps: [Double?] { opt.rehear ? windowGaps() : pauses }

    /// The pause after unit `i` (nil: not known, or no such unit).
    private func pause(after i: Int) -> Double? {
        lock.locked { () -> Double? in
            let g = unitGaps
            return i >= 0 && i < g.count ? g[i] : nil
        }
    }

    /// One polish window: the carried, unfinished clause + this piece (its own ending taken off unless it is the
    /// last). What the window says up to its last sentence end or comma is committed; the rest is carried to the next
    /// window. No pause puts a mark between them (DictationStitch.windowInput): whether the sentence ended at the pause
    /// is the model's call from the words on both sides (no stop-word list makes it, and no pause length does).
    private func polish(_ p: Piece) {
        guard !cancelled, !lock.locked({ skipped }) else { return }
        // without polish the transcripts are joined with the seam rule at the end (assemble); polished once at key-up
        // (cloud polish with the second transcript): assemble too
        guard opt.polish, !opt.polishAtKeyUp, !p.raw.isEmpty else { return }
        let core = p.last ? p.raw : DictationStitch.splitTrailing(p.raw).core
        let carried = carry
        carry = ""; carryPolished = ""; carryEnd = ""
        let input = DictationStitch.windowInput(carry: carried, piece: core)
        var ctx = lock.locked { context }?.payload ?? [:]
        let so = DictationStitch.join(lock.locked { units.prefix(p.index).map(\.text) })
        // the dictation's own text so far goes as its own key: polish.py shows it as the turn before this one, so the
        // model continues it instead of repeating it (appended to "before", it was repeated in 8 of 15 list windows)
        if !so.isEmpty { ctx["dictated"] = so }
        if opt.cloud != nil, !opt.recent.isEmpty { ctx["recent"] = opt.recent }
        p.polishInput = input
        let t0 = CACurrentMediaTime()
        let r = Dictation.polish(input, timeout: opt.polishTimeout, loadBudget: opt.loadBudget, vocab: opt.vocab,
                                 context: ctx.isEmpty ? nil : ctx, variant: opt.variant, cloud: opt.cloud)
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
        let (done, gaps, hint, app, field) = lock.locked {
            (pieces.prefix { $0.asrDone }.map(\.raw), pauses, context?.hint ?? "", context?.app ?? "", context?.asrBefore ?? "")
        }
        let prior = String(DictationStitch.joinPieces(done, pauses: gaps).suffix(200))
        let url = liveWav, vocab = opt.vocab, language = opt.language
        interimSent += 1
        liveQ.async { [weak self] in
            guard let self = self, !self.cancelled else { return }
            DictationStream.writeWav(samples, to: url)
            let t0 = CACurrentMediaTime()
            let r = Dictation.transcribeInterim(url, vocab: vocab, language: language, prior: prior, hint: hint, app: app,
                                                before: field)
            let secs = CACurrentMediaTime() - t0
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async { self.interimDone(t, r, seconds: secs, arrived: issued) }
        }
    }

    private func interimDone(_ t: DictationLiveDecode.Ticket, _ r: [String: Any]?, seconds: Double, arrived: CFTimeInterval) {
        let code = r?["code"] as? String
        // a model still loading isn't the decode's own time
        let load = Double(r?["load_ms"] as? Int ?? 0) / 1000
        // a model that can't give live text (Whisper): macOS's recogniser gives it from the next request on, when ready
        let unsupported = code == "interim_unsupported" && !Dictation.shared.noLiveText()
        let a: DictationLiveDecode.Answer = r?["ok"] as? Bool == true ? .text(seconds: max(0, seconds - load))
            : code == "interrupted" || code == "no_server" || code == "interim_unsupported" && !unsupported ? .interrupted
            : unsupported ? .unsupported : .failed
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
    func finish(keyUp: CFTimeInterval, structure: Bool = false, onlyForLists: Bool = false, translate: TranslateJob? = nil,
                _ done: @escaping (Result) -> Void) {
        self.keyUp = keyUp
        self.onlyForLists = onlyForLists
        lock.locked { finished = done; delivered = false }
        live.stop()             // no more interim requests: an answer under way still shows until its piece is in
        lock.locked { finalCounts = (interimSent, interimShown) }
        let n = lock.locked { pieces.count }
        let tail = audio.count - pieceStart
        // the open window's pieces before the last one: under 2 s of them is not worth hearing again at key-up (where
        // every decode is waited for) — they close as their own window, and the last piece is heard on its own
        if opt.rehear, windowFirst < n, pieceStart - windowStart < Int(2 * NoteVoice.rate), !pieceHard {
            closeWindow(end: pieceStart)
        }
        // (a streamed cloud take without macOS's recogniser has no live text to finish: nothing is cut)
        if !(opt.streamCloud && !opt.streaming),
           n == 0 || (tail > Int(0.3 * NoteVoice.rate) && (segmenter.pieceSpeech >= 3 || !opt.streaming)) {
            // heard again with the open window's other pieces: its own transcript would only be thrown away
            enqueue(start: pieceStart, end: audio.count, hard: pieceHard, last: true,
                    covered: opt.rehear && windowFirst < lock.locked { pieces.count })
        }
        if opt.rehear { closeWindow(end: lock.locked { pieces.last?.end } ?? audio.count, last: true) }
        if opt.wholeAtKeyUp { askCloud() }
        onStage?("asr")
        // never open-ended (DictationTakeDeadline): words not in by then → "the speech model didn't answer", the
        // recording kept for Retry; what still comes later is dropped (`delivered`), the pieces not yet started skip
        let deadline = DictationTakeDeadline.seconds(audioSeconds: Double(audio.count) / NoteVoice.rate)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline) { [weak self] in
            guard let self, !self.cancelled, !self.lock.locked({ self.delivered }) else { return }
            let (n, waiting) = self.lock.locked {
                (self.pieces.count, self.hearingWhole || (self.pieces + self.windows).contains { !$0.asrDone })
            }
            guard waiting else { return }       // the words are in: polish has its own time limits
            emit(["event": "dictation_take_deadline", "id": self.id, "after_s": deadline, "segments": n])
            self.cancelled = true
            self.deliver(self.failure(.timedOut, segments: n))
        }
        // both queues are serial: this runs after every piece's transcription, and what it queues after every polish
        // (strong captures: the controller has let go of the stream by now; the queues hold it until it is done)
        asrQ.async {
            if self.opt.polish || structure || translate != nil { DispatchQueue.main.async { self.onStage?("polish") } }
            self.polishQ.async {
                guard !self.cancelled, !self.lock.locked({ self.delivered }) else { return }
                var r = self.opt.wholeAtKeyUp ? self.cloudWhole() : self.assemble()
                if structure, !r.empty, !self.lock.locked({ self.skipped }) { self.structure(&r) }
                if let j = translate, !r.empty, !self.lock.locked({ self.skipped }) { self.translate(&r, j) }
                self.deliver(r)
            }
        }
    }

    /// A cloud recogniser at key-up (`wholeAtKeyUp`): the whole take in one request (the service cuts a long one at
    /// its pauses: transcribe.py DashScope.max_chunk), with the words and the field's text, while macOS's recogniser
    /// finishes the last piece. The take's deadline counts it (`hearingWhole`).
    private func askCloud() {
        let samples = audio
        let url = dir.appendingPathComponent("\(id)-take.wav")
        let ctx = lock.locked { context }
        lock.locked { hearingWhole = true; cloudAsked = CACurrentMediaTime() }
        cloudDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.cloudDone.leave() }
            // streamed while it was said: only the final text is left (the server's wait is bounded too). An
            // answer that the model can't take a stream ("usage": the choice changed mid-take) or no answer at all →
            // the whole take, as for any cloud recogniser
            var streamed = false
            var a: [String: Any]
            // the server waits 10 s for the final text, more for audio that reached it late (transcribe.py final_wait)
            let wait = 15 + 0.4 * Double(samples.count) / NoteVoice.rate
            if let cs = self.cloudStream, let r = cs.finish(timeout: wait), r["code"] as? String != "usage" {
                a = r
                streamed = true
            } else {
                DictationStream.writeWav(samples, to: url)
                a = Dictation.transcribe(url, vocab: self.opt.vocab, language: self.opt.language, prior: "", budget: 30,
                                         hint: ctx?.hint ?? "", app: ctx?.app ?? "", before: ctx?.asrBefore ?? "",
                                         audioSeconds: Double(samples.count) / NoteVoice.rate)
                try? FileManager.default.removeItem(at: url)
            }
            self.lock.locked { self.cloudAnswer = a; self.hearingWhole = false }
            emit(["event": "dictation_cloud_take", "id": self.id, "ok": a["ok"] as? Bool ?? false, "code": a["code"] ?? NSNull(),
                  "audio_s": (Double(samples.count) / NoteVoice.rate * 100).rounded() / 100,
                  "ms": Int((CACurrentMediaTime() - self.lock.locked { self.cloudAsked }) * 1000),
                  "echo": (a["tag"] as? [String: Any])?["echo"] ?? false, "streamed": streamed,
                  "stream_tried": self.cloudStream != nil])
        }
    }

    /// The cloud's whole take, polished once with macOS's pieces (the live text) joined as the second transcript.
    private func cloudWhole() -> Result {
        cloudDone.wait()
        let (ps, gaps, answer, asked) = lock.locked {
            (pieces, pauses, cloudAnswer ?? ["ok": false, "code": "error"], cloudAsked)
        }
        let heard = DictationStitch.joinPieces(ps.map(\.raw), pauses: gaps)
        var r = whole(ps.count, second: heard.isEmpty ? nil : heard, heard: (answer, asked))
        // the history keeps the cuts (what macOS heard of each piece): the Lab replays the take from them
        if r.asrError == nil, !ps.isEmpty {
            r.pieces = ps.map { var d = describe($0, gaps); d["heard_by"] = AppleSpeech.modelID; return d }
        }
        return r
    }

    /// Structured: the stitched text through polish.py's `structure` (it resolves self-corrections and lays out what
    /// was enumerated, or leaves a paragraph; its guard keeps the content). A refusal keeps Light's text.
    private func structure(_ r: inout Result) {
        let t0 = CACurrentMediaTime()
        // Auto asks the pass only whether there is a list: in the cloud it gets the polish's own limit, and when the
        // cloud is slower than that Light's text is typed (a 4.6 s wait for a one-sentence take, v1.0.4) — no second
        // wait for the local model
        let s = onlyForLists && opt.cloud != nil
            ? Dictation.structure(r.text, timeout: DictationCloud.requestBudget(chars: r.text.count), loadBudget: opt.loadBudget,
                                  vocab: opt.vocab, cloud: opt.cloud, localFallback: false)
            : Dictation.structure(r.text, timeout: opt.structureTimeout, loadBudget: opt.loadBudget, vocab: opt.vocab, cloud: opt.cloud)
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
    /// Translate: the text in its style (Structured's when it picked it) through polish.py's `translate`, into the other
    /// language of the one the speech model heard — or Settings' fixed target; nothing is sent when the take is
    /// already in it. A refusal or a failure keeps the text as said (`translation.fellBack`: the island says so).
    private func translate(_ r: inout Result, _ j: TranslateJob) {
        let t0 = CACurrentMediaTime()
        let said = j.style.pick(light: r.text, structured: r.structured).text
        guard let target = DictationTranslateRoute.target(j.setting, spoken: r.language, auto: j.auto) else {
            r.translation = DictationTranslateRecord(source: j.source, toggles: j.toggles, target: nil, engine: j.engine.rawValue)
            emit(["event": "dictation_translate", "action": "skipped", "id": id, "language": r.language ?? NSNull()])
            return
        }
        let a = Dictation.translate(said, target: target, vocab: opt.vocab, cloud: j.cloud, loadBudget: opt.loadBudget)
        let ms = Int((CACurrentMediaTime() - t0) * 1000)
        let out = (a?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fellBack = a?["ok"] as? Bool != true || a?["fell_back"] as? Bool == true || out.isEmpty
        let reason = a == nil ? "unavailable" : a?["ok"] as? Bool != true ? (a?["code"] as? String ?? "error")
            : out.isEmpty ? "empty" : a?["reason"] as? String
        let engine = a?["cloud"] as? Bool == true ? "cloud" : a?["model"] != nil ? "local" : j.engine.rawValue
        r.translation = DictationTranslateRecord(source: j.source, toggles: j.toggles, target: target, engine: engine, sourceText: said,
                                                 fellBack: fellBack, reason: fellBack ? reason : nil,
                                                 cloudError: a?["cloud_error"] as? String, ms: ms)
        if !fellBack { r.translated = out }
        r.timing["translate_ms"] = ms
        r.timing["total_ms"] = Int((CACurrentMediaTime() - keyUp) * 1000)
        emit(["event": "dictation_translate", "action": "done", "id": id, "ms": ms, "target": target, "engine": engine,
              "fell_back": fellBack, "reason": (fellBack ? reason : nil) ?? NSNull(), "cloud_error": a?["cloud_error"] ?? NSNull()])
    }

    private func assemble() -> Result {
        let (ps, us, ws, gaps, pgaps) = lock.locked { (pieces, units, windows, unitGaps, pauses) }
        // the safety path: a piece the speech model failed on → the whole recording, the old way
        if let failed = us.first(where: \.asrFailed) {
            emit(["event": "dictation_stream_fallback", "id": id, "why": "asr_failed", "code": failed.asrCode ?? NSNull()])
            // no model: the whole recording would only fail the same way
            if failed.asrCode == "model_missing" { return failure(.noModel, segments: ps.count) }
            let secs = us.compactMap { u in lock.locked { u.second } }
            return whole(ps.count, second: secs.count == us.count ? DictationStitch.joinPieces(secs, pauses: gaps) : nil)
        }
        let raw = DictationStitch.joinPieces(us.map(\.raw), pauses: gaps)
        let heard = DictationStitch.joinPieces(us.map(\.asrText), pauses: gaps)
        if opt.polish, opt.polishAtKeyUp, let last = us.last, !raw.isEmpty, !lock.locked({ skipped }) {
            polishTake(raw, into: last, units: us, gaps: gaps)
        }
        // polish's windows, then the clause still carried (the dictation ended in it: its ending stays); or the one
        // polish at key-up
        var text = !opt.polish ? raw : opt.polishAtKeyUp ? (us.last.map(\.text).flatMap { $0.isEmpty ? nil : $0 } ?? raw)
            : DictationStitch.join(us.map(\.text) + [carry + carryEnd])
        let pol = us.compactMap(\.polish)
        // not polished only when every window fell back; some of them: how many (DictationWindowFallback)
        let fb = DictationWindowFallback.of(pol.map { $0["fell_back"] as? Bool == true })
        var fellBack = fb.all
        var parts = fb.parts
        var reason = pol.first { $0["fell_back"] as? Bool == true }?["reason"] as? String
        let polished: String? = pol.isEmpty ? nil : opt.polishAtKeyUp ? us.last?.polishedPart
            : DictationStitch.join(us.map(\.polishedPart) + [carryPolished + carryEnd])
        // the joined result once more against the joined transcript: pieces that each passed can still add up wrong
        // a refusal types the transcript with a comma where a boundary was heard (`fallback_text`)
        let fallback = DictationStitch.joinPiecesForFallback(us.map(\.raw), pauses: gaps)
        if opt.polish, !opt.polishAtKeyUp, us.count > 1, !pol.isEmpty, text != raw,
           let g = WarmServer.call("polish-serve", ["cmd": "guard", "raw": raw, "output": text, "vocab": opt.vocab,
                                                    "context": lock.locked { context }?.payload ?? NSNull(),
                                                    "fallback": fallback,
                                                    // windows the cloud model polished: its allowance (§Cloud polish)
                                                    "cloud": pol.contains { $0["cloud"] as? Bool == true }], timeout: 2),
           g["pass"] as? Bool == false {
            emit(["event": "dictation_stream_fallback", "id": id, "why": "stitch_guard", "reason": g["reason"] ?? NSNull()])
            text = (g["fallback_text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            fellBack = true
            parts = nil
            reason = "stitch_" + (g["reason"] as? String ?? "guard")
        }
        var terms: [String] = []
        for p in us {
            for t in (p.asr?["terms"] as? [String] ?? []) + (p.polish?["terms"] as? [String] ?? []) where !terms.contains(t) { terms.append(t) }
        }
        let first = us.first { $0.asr != nil }?.asr ?? [:]
        let repaired = us.flatMap { ($0.polish?["repaired"] as? [String]) ?? [] }
        var r = Result(raw: raw, asrText: heard, text: text.isEmpty ? raw : text, polished: polished, fellBack: fellBack,
                       reason: reason, model: pol.first { $0["model"] is String }?["model"] as? String,
                       asrModel: first["model"] as? String, language: first["language"] as? String,
                       biased: first["biased"] as? Bool ?? false, terms: terms,
                       contextUsed: pol.contains { $0["context"] as? Bool == true }, repaired: repaired,
                       segments: ps.count, timing: timing(ps, windows: ws), pieces: ps.map { describe($0, pgaps) })
        r.tags = us.compactMap { $0.asr?["tag"] as? [String: Any] }
        r.windows = ws.map(describeWindow)
        r.fellBackParts = parts
        r.polishCloudError = pol.lazy.compactMap { $0["cloud_error"] as? String }.first
        return r
    }

    /// The whole take's transcript polished once at key-up (`polishAtKeyUp`), with every unit's second transcript
    /// joined as "Also heard": what it gives is the last unit's text (the history's `polish_in` / `text` show it there).
    private func polishTake(_ raw: String, into last: Piece, units us: [Piece], gaps: [Double?]) {
        var ctx = lock.locked { context }?.payload ?? [:]
        if opt.cloud != nil, !opt.recent.isEmpty { ctx["recent"] = opt.recent }
        let until = DispatchTime.now() + DictationStream.secondWait
        let secs = us.map { secondOf($0, until: until) ?? "" }
        let second = DictationStitch.joinPieces(secs, pauses: gaps)
        if !second.isEmpty { ctx["second"] = second }
        last.polishInput = raw
        let t0 = CACurrentMediaTime()
        let r = Dictation.polish(raw, timeout: opt.polishTimeout, loadBudget: opt.loadBudget, vocab: opt.vocab,
                                 context: ctx.isEmpty ? nil : ctx, variant: opt.variant, cloud: opt.cloud)
        last.polishSpan = (t0, CACurrentMediaTime())
        last.loadMS += r?["load_ms"] as? Int ?? 0
        last.polish = r
        let out = (r?["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? raw
        last.text = out
        last.polishedPart = (r?["polished"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? out
        emit(["event": "dictation_polish_take", "id": id, "units": us.count, "in_units": DictationStitch.units(raw).count,
              "second_units": DictationStitch.units(second).count, "seconds": secs.filter { !$0.isEmpty }.count,
              "ms": Int((last.polishSpan.1 - last.polishSpan.0) * 1000), "fell_back": r?["fell_back"] as? Bool ?? (r == nil),
              "reason": r?["reason"] ?? NSNull(), "cloud": r?["cloud"] as? Bool ?? false])
    }

    /// One window for the history and the Dictation Lab: its pieces, what they said and what it said.
    private func describeWindow(_ w: Piece) -> [String: Any] {
        let ms = Int(max(0, w.asrSpan.1 - w.asrSpan.0) * 1000)
        return ["index": w.index, "pieces": w.members.map { Array($0) } ?? [],
                "start": (Double(w.start) / NoteVoice.rate * 100).rounded() / 100,
                "end": (Double(w.end) / NoteVoice.rate * 100).rounded() / 100,
                "pieces_text": w.piecesText, "raw": w.raw, "asr_ms": ms, "heard_again": ms > 0,
                "polish_in": w.polishInput, "text": w.text, "polish_ms": Int(max(0, w.polishSpan.1 - w.polishSpan.0) * 1000),
                "fell_back": w.polish?["fell_back"] as? Bool ?? false, "reason": w.polish?["reason"] ?? NSNull(),
                "second": lock.locked { w.second } ?? NSNull()]
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
                                "tag": p.asr?["tag"] ?? NSNull(), "case": p.polish?["case"] ?? NSNull(), "covered": p.covered]
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
    func retry(structure: Bool, translate: TranslateJob? = nil, _ done: @escaping (Result) -> Void) {
        cancelled = false
        keyUp = CACurrentMediaTime()
        polishQ.async {
            var r = self.whole(max(1, self.segments))
            if structure, !r.empty, r.asrError == nil { self.structure(&r) }
            if let j = translate, !r.empty, r.asrError == nil { self.translate(&r, j) }
            DispatchQueue.main.async { done(r) }
        }
    }

    /// The old path on the whole recording: one transcription, one polish. `heard`: the transcription already made
    /// (a cloud recogniser's take at key-up) and when it was asked; `second`: macOS's transcript of the take, for
    /// cloud polish (§Second transcript).
    private func whole(_ n: Int, second: String? = nil, heard: (answer: [String: Any], t0: CFTimeInterval)? = nil) -> Result {
        let t0: CFTimeInterval
        let answer: [String: Any]
        if let h = heard {
            (answer, t0) = (h.answer, h.t0)
        } else {
            t0 = CACurrentMediaTime()
            lock.locked { hearingWhole = true }
            answer = Dictation.transcribe(wholeWav, vocab: opt.vocab, language: opt.language, prior: "", budget: 30,
                                          hint: lock.locked { context }?.hint ?? "", app: lock.locked { context }?.app ?? "",
                                          before: lock.locked { context }?.asrBefore ?? "",
                                          audioSeconds: DictationStream.seconds(of: wholeWav))
            lock.locked { hearingWhole = false }
        }
        guard answer["ok"] as? Bool == true else {
            emit(["event": "dictation_asr_failed", "id": id, "code": answer["code"] ?? "error"])
            return failure(DictationASRFailure(code: answer["code"] as? String), segments: n)
        }
        let r = answer
        let t1 = CACurrentMediaTime()
        let raw = (r["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var wctx = lock.locked { context }?.payload
        if opt.cloud != nil, !opt.recent.isEmpty { wctx = (wctx ?? [:]).merging(["recent": opt.recent]) { a, _ in a } }
        if opt.second, let sec = second, !sec.isEmpty { wctx = (wctx ?? [:]).merging(["second": sec]) { a, _ in a } }
        // Esc while it is still polishing (skipPolish, a cloud recogniser's take): what was heard, unpolished
        let skip = lock.locked { skipped }
        let pol = opt.polish && !raw.isEmpty && !skip ? Dictation.polish(raw, timeout: opt.polishTimeout, loadBudget: opt.loadBudget,
                                                                        vocab: opt.vocab, context: wctx, variant: opt.variant,
                                                                        cloud: opt.cloud) : nil
        let t2 = CACurrentMediaTime()
        let text = (pol?["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? raw
        var timing = ["asr_ms": Int((t1 - t0) * 1000), "polish_ms": Int((t2 - t1) * 1000), "segments": n,
                      "load_ms": (r["load_ms"] as? Int ?? 0) + (pol?["load_ms"] as? Int ?? 0)]
        timing["total_ms"] = Int((t2 - keyUp) * 1000)
        var out = Result(raw: raw, asrText: r["asr_text"] as? String ?? raw, text: text, polished: pol?["polished"] as? String,
                      fellBack: pol?["fell_back"] as? Bool ?? (skip && opt.polish && !raw.isEmpty),
                      reason: pol?["reason"] as? String ?? (skip && opt.polish && !raw.isEmpty ? "skipped" : nil),
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
        out.polishCloudError = pol?["cloud_error"] as? String
        return out
    }

    /// What the user waited for after key-up (the work before it was hidden behind the talking), and the total.
    private func timing(_ pieces: [Piece], windows: [Piece] = []) -> [String: Int] {
        func after(_ s: (Double, Double)) -> Double { max(0, s.1 - max(s.0, keyUp)) }
        let ps = pieces + windows
        let asr = ps.reduce(0) { $0 + after($1.asrSpan) }, pol = ps.reduce(0) { $0 + after($1.polishSpan) }
        let asrAll = ps.reduce(0) { $0 + ($1.asrSpan.1 - $1.asrSpan.0) }, polAll = ps.reduce(0) { $0 + ($1.polishSpan.1 - $1.polishSpan.0) }
        let again = windows.reduce(0) { $0 + ($1.asrSpan.1 - $1.asrSpan.0) }
        return ["asr_ms": Int(asr * 1000), "polish_ms": Int(pol * 1000), "load_ms": ps.reduce(0) { $0 + $1.loadMS },
                "segments": pieces.count, "windows": windows.count, "rehear_ms_all": Int(again * 1000),
                "asr_ms_all": Int(asrAll * 1000), "polish_ms_all": Int(polAll * 1000),
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
