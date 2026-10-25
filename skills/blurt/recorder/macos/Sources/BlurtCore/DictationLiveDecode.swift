// When to decode the piece still being said, for the words shown while talking (docs/design/dictation.md §Live text).
//
// DictationStream transcribes a piece once a pause ends it; while the user talks without pausing nothing new would
// show for up to 20 s. So about once a second the open piece's audio so far (at most its last `window`, 20 s) goes to
// the same warm speech server as an *interim* request, and what comes back shows, quieter, after the finished pieces'
// text until the piece's own final transcript replaces it. The final pieces always come first:
//  • no interim is sent while one is in flight or a final piece is queued or being transcribed (`finalsPending`);
//  • the server stops an interim decode as soon as any other request is waiting (transcribe.py serve: `interim`),
//    so a final piece that arrives during one waits one decoding step, not the whole decode;
//  • an answer for a piece whose final text has landed, or older than one already shown, is dropped (`done`).
// Adaptive: the interval is twice the smoothed decode time, at least 0.8 s — 0.8–1.2 s while a decode takes ≤ 0.6 s
// (a few seconds of open piece on Qwen3-ASR 1.7B, M5 Max), up to 2.2 s for a long window of mixed speech; interim
// decodes slower than `slowCutoff` (1.5 s, smoothed over at least three: the first one of a session also waits for the
// model to warm up) stop for the take — text that far behind isn't worth the GPU. Dictation on the light / minimal RAM
// tiers (< 15 GB) never starts them (`tierAllows`); notes ask on every tier (their model is quick: VoiceInput.liveWords).
// A server that answers "interim_unsupported" (a slow model that can't stop halfway) is asked again after
// `refusalBackoff` — one refusal never turns live words off; `maxRefusals` in a row do, for that take only.
// Pure (clock and sizes in, decisions out): DictationLiveDecodeTests.
import Foundation

public struct DictationLiveDecode {
    /// One interim request: the open piece `piece`, samples `start..<end` of the take.
    public struct Ticket: Equatable {
        public let seq: Int
        public let piece: Int
        public let start: Int
        public let end: Int
    }

    /// What an interim request came back with.
    public enum Answer: Equatable {
        /// the text; `seconds`: how long the server took
        case text(seconds: Double)
        /// the server stopped it for a request that was waiting (a final piece)
        case interrupted
        /// the server's model is slow and can't be interrupted: asked again later (`refusalBackoff`)
        case unsupported
        /// no server, a timeout, an error
        case failed
    }

    /// Why interim decodes stopped (nil: they run).
    public enum Off: String {
        case tier, setting, slow, unsupported, failed
    }

    public let sampleRate: Double
    public var minInterval = 0.8
    public var maxInterval = 2.2
    /// at most this much of the open piece (s): the segmenter cuts at 20 s anyway
    public var window = 20.0
    /// the open piece needs this much audio (s) before its first interim
    public var minAudio = 0.6
    /// …and this much new audio (s) since the last one
    public var minNew = 0.3
    /// a smoothed decode slower than this (s) stops interim decodes for the take, once `slowAfter` were measured
    public var slowCutoff = 1.5
    public var slowAfter = 3
    /// this many failures in a row stop them (a server that went away)
    public var maxFailures = 3
    /// after the server said its model can't take interim requests, wait this long (s) before asking again…
    public var refusalBackoff = 4.0
    /// …and stop for the take after this many refusals in a row
    public var maxRefusals = 3

    public private(set) var off: Off?
    public private(set) var inFlight: Ticket?
    /// final pieces queued or being transcribed
    public private(set) var finalsPending = 0
    /// the decode time, smoothed (s)
    public private(set) var smoothed: Double?
    public private(set) var stopped = false
    private var seq = 0
    private var lastSent: Double?
    private var lastIssued: Ticket?
    private var finalized = Set<Int>()
    private var shown: [Int: Int] = [:]
    private var failures = 0
    private var refusals = 0
    private var heldUntil: Double?
    private var measured = 0

    public init(sampleRate: Double, off: Off? = nil) {
        self.sampleRate = sampleRate
        self.off = off
    }

    /// Apple Silicon's tiers (transcribe.py `tier_for`): light and minimal (< 15 GB) get no interim decodes.
    public static func tierAllows(ramGB: Double) -> Bool { ramGB >= 15 }

    /// Twice the smoothed decode time (the GPU idle at least half the time), within minInterval…maxInterval (s).
    public var interval: Double { min(maxInterval, max(minInterval, 2 * (smoothed ?? 0))) }

    /// Called as audio arrives: a request to send now, or nil. `piece`: the open piece's index; `pieceStart` /
    /// `audioEnd`: its first sample and the take's last; `hasSpeech`: the segmenter heard speech in it.
    public mutating func next(now: Double, piece: Int, pieceStart: Int, audioEnd: Int, hasSpeech: Bool) -> Ticket? {
        guard off == nil, !stopped, inFlight == nil, finalsPending == 0, hasSpeech else { return nil }
        guard Double(audioEnd - pieceStart) >= minAudio * sampleRate else { return nil }
        if let t = lastSent, now - t < interval { return nil }
        if let h = heldUntil, now < h { return nil }
        if let l = lastIssued, l.piece == piece, Double(audioEnd - l.end) < minNew * sampleRate { return nil }
        seq += 1
        let t = Ticket(seq: seq, piece: piece, start: max(pieceStart, audioEnd - Int(window * sampleRate)), end: audioEnd)
        inFlight = t
        lastSent = now
        lastIssued = t
        return t
    }

    /// A final piece was queued (before its request goes out).
    public mutating func finalQueued() { finalsPending += 1 }

    /// A final piece's transcript landed: its interim text is done with.
    public mutating func finalDone(piece: Int) {
        finalsPending = max(0, finalsPending - 1)
        finalized.insert(piece)
        shown[piece] = nil
    }

    /// The take stopped (key-up): nothing new is sent; an answer in flight still shows until its piece is final.
    public mutating func stop() { stopped = true }

    /// An interim request's answer: true = show its text now; false = drop it (stale, interrupted, failed).
    public mutating func done(_ t: Ticket, _ a: Answer) -> Bool {
        if inFlight?.seq == t.seq { inFlight = nil }
        switch a {
        case .interrupted:
            return false
        case .unsupported:
            refusals += 1
            if refusals >= maxRefusals { off = .unsupported } else { heldUntil = (lastSent ?? 0) + refusalBackoff }
            return false
        case .failed:
            failures += 1
            if failures >= maxFailures { off = .failed }
            return false
        case let .text(s):
            failures = 0
            refusals = 0
            heldUntil = nil
            measured += 1
            smoothed = smoothed.map { 0.6 * $0 + 0.4 * s } ?? s
            if let m = smoothed, m > slowCutoff, measured >= slowAfter { off = .slow }
        }
        // stale: the piece's final text is in, or a newer answer for it already shows
        if finalized.contains(t.piece) { return false }
        if let s = shown[t.piece], s >= t.seq { return false }
        shown[t.piece] = t.seq
        return true
    }

    /// One piece as the live text knows it.
    public enum Piece: Equatable {
        /// its final transcript (the overlap with the piece before already dropped)
        case final(String)
        /// the latest interim text for it; `hard`: it began at a hard cut, overlapping the piece before
        case interim(String, hard: Bool)
        /// nothing yet
        case none
    }

    /// What the panel shows: the finished pieces' transcripts joined as the transcript is (`committed`), then the
    /// interim texts after them (`pending`, provisional). Mechanical only: an interim after a hard cut loses the words
    /// the piece before already has (DictationStitch.dropOverlap), and the seams are DictationStitch.joinPieces'.
    public static func compose(_ pieces: [Piece], pauses: [Double?]) -> (committed: String, pending: String) {
        var texts: [String] = []
        var finished = 0
        var leading = true
        for p in pieces {
            switch p {
            case let .final(t):
                texts.append(t)
                if leading { finished += 1 }
            case let .interim(t, hard):
                leading = false
                let before = texts.last { !$0.isEmpty } ?? ""
                texts.append(hard && !before.isEmpty ? DictationStitch.dropOverlap(previous: before, next: t) : t)
            case .none:
                leading = false
                texts.append("")
            }
        }
        let committed = DictationStitch.joinPieces(Array(texts.prefix(finished)), pauses: pauses)
        let full = DictationStitch.joinPieces(texts, pauses: pauses)
        // the seam after the committed text may differ once more follows (its mark): the common part is committed
        var a = committed.startIndex, b = full.startIndex
        while a < committed.endIndex, b < full.endIndex, committed[a] == full[b] {
            a = committed.index(after: a); b = full.index(after: b)
        }
        return (String(full[..<b]), String(full[b...]))
    }
}
