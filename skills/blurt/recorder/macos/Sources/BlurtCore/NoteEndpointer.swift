// When a voice note (the snap's note bubble, ⌥⇧V, dictation) has been said: speech start, and the pause that ends it.
//
// v0.8 — the old detector took the quietest of the first three 100 ms buffers as the room's noise floor and froze it
// once speech began. A Mac's mic opens quieter than the room (the user's own recording: −52 dBFS for 0.2 s, then the
// room at −44…−40), so "quiet" meant below −46 dBFS for good: the room never was, the note never ended — and the
// room's ups and downs alone could count as speech (a kept wav with nothing in it, a mic mark with no words). Now:
//  • 20 ms frames. The noise floor is the 10th percentile of the last 3 s of frames, the mic's first 0.25 s (it wakes
//    up quieter than the room) and digital silence left out. It follows the room all the time, also while the user
//    talks (the gaps between words are the room), rising at most 2 dB/s while they do.
//  • a frame is loud above floor + 10 dB (and above −62 dBFS). Speech starts at 8 loud frames out of 12 (a held
//    sound, not a click or a key press), judged over the last second against the floor as it is now — so a word said
//    the moment the mic opens, before the room was known, still counts.
//  • "still talking" while 4 of the last 6 frames are loud; 1.8 s without that ends the note. A key press or a mouse
//    click in the pause doesn't restart the count.
//  • `speechSeconds`: how much of it was talking — a note abandoned for typing after a cough is dropped, not kept.
//  • `activity(grace:)`: the snap's bubble is being drawn on — the pause or the no-speech end waits for the pen
//    (v0.9: a circle drawn as the note ended was lost). `peakDB`: the loudest frame, so a take that is digital silence
//    can be told from speech the room hid. `soundSeconds`: how long a sound was held above the room (3 of 5 frames
//    6 dB over the floor) — speech too quiet for the endpointer in a café still holds some, a fan or a hum none
//    (VoiceKeep: a note the user ended is kept on it).
// Pure (samples in, events out) so tests feed it synthetic rooms and voices (NoteEndpointerTests).

import Foundation

public struct NoteEndpointer {
    public enum End: Equatable { case silence, noSpeech, maxed }
    public enum Event: Equatable { case speechStarted, ended(End) }

    public static let frameSeconds = 0.02
    public let sampleRate: Double
    public var silenceToEnd = 1.8
    public var noSpeechTimeout = 8.0
    public var maxLength = 60.0
    /// the mic's first moments: not the room
    public var warmup = 0.25
    /// loud: this far above the floor (dB)
    public var onDelta: Float = 10
    /// … and above this, whatever the floor (a dead-quiet room doesn't make every rustle speech)
    public var minLoudDB: Float = -62
    public var floorWindow = 3.0

    public private(set) var heard: Double = 0
    public private(set) var speaking = false
    public private(set) var speechSeconds: Double = 0
    public private(set) var floorDB: Float = -90
    public private(set) var ended: End?
    /// the last frame's level (dBFS), for tests and logs
    public private(set) var lastDB: Float = -120
    /// the loudest frame after the mic's warm-up (dBFS): digital silence (a muted or dead input) stays near −120
    public private(set) var peakDB: Float = -120
    /// how long a sound was held above the room (seconds): `soundDelta` over the floor in 3 of the last 5 frames
    public private(set) var soundSeconds: Double = 0
    public var soundDelta: Float = 6

    static let startWindow = 12, startLoud = 8, lookback = 50, talkWindow = 6, talkLoud = 4

    private let frameLength: Int
    private var carry: [Float] = []
    private var history: [Float] = []         // frame levels for the floor (ring)
    private var historyAt = 0
    private var recent: [Float] = []          // the last second's frame levels
    private var quietFor: Double = 0
    private var soundRecent: [Bool] = []      // the last 5 frames: above floor + soundDelta

    public init(sampleRate: Double = 16000) {
        self.sampleRate = sampleRate
        frameLength = max(1, Int((sampleRate * NoteEndpointer.frameSeconds).rounded()))
    }

    /// Feeds samples (mono, −1…1); returns what happened in them (at most one start and one end).
    public mutating func feed(_ samples: [Float]) -> [Event] {
        guard ended == nil else { return [] }
        var out: [Event] = []
        var i = 0
        if !carry.isEmpty {
            let need = frameLength - carry.count
            if samples.count < need { carry += samples; return [] }
            carry += samples[0..<need]
            out += frame(carry)
            carry.removeAll(keepingCapacity: true)
            i = need
        }
        while i + frameLength <= samples.count, ended == nil {
            out += frame(samples[i..<(i + frameLength)])
            i += frameLength
        }
        if ended == nil, i < samples.count { carry += samples[i...] }
        return out
    }

    /// The user is still working on the note without talking (drawing on the picture): ending it needs at least
    /// `grace` more seconds of quiet, and the no-speech end moves out as far.
    public mutating func activity(grace: Double) {
        guard ended == nil else { return }
        quietFor = min(quietFor, silenceToEnd - grace)
        noSpeechTimeout = max(noSpeechTimeout, heard + grace)
    }

    /// One frame's level in dBFS.
    public static func level<C: Collection>(_ frame: C) -> Float where C.Element == Float {
        guard !frame.isEmpty else { return -120 }
        var sum: Float = 0
        for x in frame { sum += x * x }
        return 20 * log10(max((sum / Float(frame.count)).squareRoot(), 1e-6))
    }

    private mutating func frame<C: Collection>(_ f: C) -> [Event] where C.Element == Float {
        let db = NoteEndpointer.level(f)
        lastDB = db
        heard += NoteEndpointer.frameSeconds
        if heard > warmup + 1e-9 { peakDB = max(peakDB, db) }
        var out = step(db)
        if ended == nil, heard >= maxLength - 1e-9 { ended = .maxed; out.append(.ended(.maxed)) }
        return out
    }

    private func loud(_ db: Float) -> Bool { db > max(floorDB + onDelta, minLoudDB) }

    private mutating func step(_ db: Float) -> [Event] {
        let dt = NoteEndpointer.frameSeconds
        var out: [Event] = []
        recent.append(db)
        if recent.count > NoteEndpointer.lookback { recent.removeFirst(recent.count - NoteEndpointer.lookback) }
        // the room: not the mic waking up, not digital silence (a muted or waking mic)
        if heard > warmup + 1e-9, db > -100 {
            let cap = max(1, Int(floorWindow / dt))
            if history.count < cap { history.append(db) } else { history[historyAt] = db; historyAt = (historyAt + 1) % cap }
            let sorted = history.sorted()
            let p10 = sorted[min(sorted.count - 1, sorted.count / 10)]
            floorDB = speaking ? min(p10, floorDB + Float(2 * dt)) : p10
        }
        if heard > warmup + 1e-9, history.count >= 12 {
            soundRecent.append(db > max(floorDB + soundDelta, minLoudDB))
            if soundRecent.count > 5 { soundRecent.removeFirst() }
            if soundRecent.last == true, soundRecent.filter({ $0 }).count >= 3 { soundSeconds += dt }
        }
        if !speaking {
            // judged once a quarter second of the room is known, over the last second, against today's floor
            if history.count >= 12, let (loudCount, trailingQuiet) = started() {
                speaking = true
                speechSeconds = Double(loudCount) * dt
                quietFor = Double(trailingQuiet) * dt
                out.append(.speechStarted)
            } else if heard >= noSpeechTimeout - 1e-9 {
                ended = .noSpeech
                out.append(.ended(.noSpeech))
                return out
            }
        } else {
            let talking = recent.suffix(NoteEndpointer.talkWindow).filter(loud).count >= NoteEndpointer.talkLoud
            if talking { quietFor = 0; speechSeconds += dt } else { quietFor += dt }
        }
        if speaking, quietFor >= silenceToEnd - 1e-9 {
            ended = .silence
            out.append(.ended(.silence))
        }
        return out
    }

    /// A held sound somewhere in the last second: (loud frames from its start on, quiet frames since its last one).
    private func started() -> (Int, Int)? {
        let flags = recent.map(loud)
        let w = NoteEndpointer.startWindow
        guard flags.count >= w else { return nil }
        // frames from here on came after the mic's warm-up: a held sound must reach into them (a pop as the mic opens,
        // however loud, isn't speech; a word said as it opens goes on past it)
        let awake = max(0, flags.count - Int(((heard - warmup) / NoteEndpointer.frameSeconds).rounded()))
        var first: Int?
        for start in 0...(flags.count - w) {
            let win = flags[start..<(start + w)]
            if win.filter({ $0 }).count >= NoteEndpointer.startLoud,
               flags[max(start, awake)..<(start + w)].filter({ $0 }).count >= 3 { first = start; break }
        }
        guard let s = first else { return nil }
        let loudFrom = flags[s...].filter { $0 }.count
        let lastLoud = flags.lastIndex(of: true) ?? flags.count - 1
        return (loudFrom, flags.count - 1 - lastLoud)
    }
}
