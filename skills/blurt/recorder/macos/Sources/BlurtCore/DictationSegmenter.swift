// Where to cut a dictation while the user is still talking (docs/design/dictation.md §Streaming), so each piece is
// transcribed and polished as soon as it is complete and only the last one is left when the key comes up.
//
//  • 20 ms frames; the room's level is the 10th percentile of the last 3 s (the mic's first 0.25 s left out; digital
//    silence counts as −90 dBFS), rising at most 2 dB/s while someone talks, as in NoteEndpointer; a frame is speech
//    above floor + 10 dB (and above −62 dBFS).
//  • a cut goes in the middle of a pause of `pause` (0.5 s) once the piece is at least `minSegment` (3 s) long and has
//    speech in it — between words, never inside one (Chinese has no spaces to find a word boundary in the text).
//  • a piece that reaches `maxSegment` (20 s) without such a pause is cut anyway, at the quietest 100 ms of its last
//    2 s. When even that was loud (no real gap), the cut is `hard`: the next piece starts `overlap` (0.8 s) earlier, so
//    a word under the cut is heard whole at least once, and DictationStitch drops the words both pieces heard.
// Pure (samples in, cuts out): DictationSegmenterTests feed it synthetic speech and pauses.
import Foundation

public struct DictationSegmenter {
    public struct Cut: Equatable {
        /// the piece ends here (sample index, exclusive)
        public let end: Int
        /// the next piece starts here: `end`, or `overlap` earlier for a hard cut
        public let nextStart: Int
        /// cut without a pause: the pieces overlap and the text needs DictationStitch.dropOverlap
        public let hard: Bool
    }

    public static let frameSeconds = 0.02
    public let sampleRate: Double
    public var pause = 0.5
    public var minSegment = 3.0
    public var maxSegment = 20.0
    public var overlap = 0.8
    public var onDelta: Float = 10
    public var minLoudDB: Float = -62
    public var warmup = 0.25

    /// where the current piece starts (sample index)
    public private(set) var pieceStart = 0
    /// speech frames in the current piece
    public private(set) var pieceSpeech = 0
    public private(set) var samples = 0
    public private(set) var floorDB: Float = -90
    /// The pause at each cut: from the last speech frame before it to the first one after it (seconds), filled in once
    /// speech resumes; index k = the pause after piece k. nil while not known yet; 0 for a hard cut. DictationStitch
    /// keeps a sentence end at a seam only after a long one.
    public private(set) var pauses: [Double?] = []

    private let frameLength: Int
    private var carry: [Float] = []
    private var levels: [Float] = []          // every frame's level (dBFS): the quietest-point search looks back 2 s
    private var history: [Float] = []         // ring for the floor
    private var historyAt = 0
    private var quietRun = 0                  // frames since the last speech frame
    private var recentLoud: [Bool] = []       // the last 12 frames
    private var talking = false               // 6 of them loud
    private var lastLoudFrame = -1
    private var pauseOpen: Int?               // the cut whose pause ends at the next speech frame

    public init(sampleRate: Double = 16000) {
        self.sampleRate = sampleRate
        frameLength = max(1, Int((sampleRate * DictationSegmenter.frameSeconds).rounded()))
    }

    private var frames: Int { levels.count }
    private func seconds(_ frames: Int) -> Double { Double(frames) * DictationSegmenter.frameSeconds }
    private func sampleAt(frame f: Int) -> Int { f * frameLength }

    /// Feeds mono samples (−1…1); returns the cuts they completed (usually none, at most a few).
    public mutating func feed(_ x: [Float]) -> [Cut] {
        var out: [Cut] = []
        var i = 0
        if !carry.isEmpty {
            let need = frameLength - carry.count
            if x.count < need { carry += x; samples += x.count; return [] }
            carry += x[0..<need]
            if let c = frame(carry) { out.append(c) }
            carry.removeAll(keepingCapacity: true)
            i = need
        }
        while i + frameLength <= x.count {
            if let c = frame(x[i..<(i + frameLength)]) { out.append(c) }
            i += frameLength
        }
        if i < x.count { carry += x[i...] }
        samples += x.count
        return out
    }

    /// Whether the current (unfinished) piece has speech in it — the last piece at key-up, or a piece to skip.
    public var pieceHasSpeech: Bool { pieceSpeech >= DictationSegmenter.speechFramesMin }
    /// a piece needs this much speech (0.2 s) to be worth a request
    public static let speechFramesMin = 10

    private func loud(_ db: Float) -> Bool { db > max(floorDB + onDelta, minLoudDB) }

    private mutating func frame<C: Collection>(_ f: C) -> Cut? where C.Element == Float {
        let db = NoteEndpointer.level(f)
        levels.append(db)
        if seconds(frames) > warmup + 1e-9 {
            // digital silence (a gap in a test file, a muted mic) counts as a very quiet room, not as nothing: a floor
            // made of speech alone would call the dips between syllables pauses
            let v = max(db, -90)
            let cap = max(1, Int(3.0 / DictationSegmenter.frameSeconds))
            if history.count < cap { history.append(v) } else { history[historyAt] = v; historyAt = (historyAt + 1) % cap }
            let sorted = history.sorted()
            let p10 = sorted[min(sorted.count - 1, sorted.count / 10)]
            // while someone talks the floor rises at most 2 dB/s (3 s of continuous speech would otherwise become
            // "the room", and the dips between syllables pauses); it follows the room freely otherwise
            floorDB = talking ? min(p10, floorDB + Float(2 * DictationSegmenter.frameSeconds)) : p10
        }
        let isLoud = loud(db)
        recentLoud.append(isLoud)
        if recentLoud.count > 12 { recentLoud.removeFirst() }
        talking = recentLoud.filter { $0 }.count >= 6
        if isLoud {
            pieceSpeech += 1
            quietRun = 0
            if let k = pauseOpen {
                pauses[k] = seconds(frames - 1 - lastLoudFrame - 1)
                pauseOpen = nil
            }
            lastLoudFrame = frames - 1
        } else { quietRun += 1 }
        let pieceFrames = frames - pieceStart / frameLength
        let pauseFrames = Int((pause / DictationSegmenter.frameSeconds).rounded())
        // a pause long enough, in a piece long enough that has speech: cut in the middle of the pause
        if quietRun == pauseFrames, seconds(pieceFrames) >= minSegment, pieceHasSpeech {
            let mid = frames - pauseFrames / 2
            return cut(at: sampleAt(frame: mid), hard: false)
        }
        // too long without one: the quietest 100 ms of the last 2 s
        if seconds(pieceFrames) >= maxSegment {
            let back = Int(2.0 / DictationSegmenter.frameSeconds), w = 5
            let lo = max(pieceStart / frameLength + 1, frames - back), hi = frames - w
            var best = hi, bestDB = Float.greatestFiniteMagnitude
            if lo <= hi {
                for s in lo...hi {
                    let m = levels[s..<(s + w)].reduce(0, +) / Float(w)
                    if m < bestDB { bestDB = m; best = s }
                }
            }
            let at = best + w / 2
            // hard unless that moment is as quiet as the room: then the pieces overlap and the stitch drops doubled words
            return cut(at: sampleAt(frame: at), hard: bestDB > floorDB + 6)
        }
        return nil
    }

    private mutating func cut(at end: Int, hard: Bool) -> Cut {
        let next = hard ? max(pieceStart, end - Int(overlap * sampleRate)) : end
        let c = Cut(end: end, nextStart: next, hard: hard)
        if hard { pauses.append(0); pauseOpen = nil } else { pauses.append(nil); pauseOpen = pauses.count - 1 }
        // speech frames after the cut belong to the next piece
        let firstNextFrame = next / frameLength
        pieceSpeech = levels[min(firstNextFrame, levels.count)...].filter(loud).count
        pieceStart = next
        return c
    }
}
