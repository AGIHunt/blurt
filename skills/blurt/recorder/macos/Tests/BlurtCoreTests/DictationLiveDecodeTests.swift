import XCTest
@testable import BlurtCore

/// The words shown while talking (docs/design/dictation.md §Live text): when the open piece is decoded, that an
/// interim decode never delays a final piece, and that stale interim answers are dropped.
final class DictationLiveDecodeTests: XCTestCase {
    let sr = 16000.0
    func s(_ seconds: Double) -> Int { Int(seconds * sr) }

    func testOneAtATimeAndNeverWhileAFinalIsPending() {
        var d = DictationLiveDecode(sampleRate: sr)
        let t = d.next(now: 1.0, piece: 0, pieceStart: 0, audioEnd: s(1.0), hasSpeech: true)
        XCTAssertNotNil(t)
        // in flight: nothing more, however long it takes
        XCTAssertNil(d.next(now: 5.0, piece: 0, pieceStart: 0, audioEnd: s(5.0), hasSpeech: true))
        XCTAssertTrue(d.done(t!, .text(seconds: 0.3)))
        // a final piece queued (the cut) → no interim until it is transcribed
        d.finalQueued()
        XCTAssertNil(d.next(now: 6.0, piece: 1, pieceStart: s(5.0), audioEnd: s(6.0), hasSpeech: true))
        XCTAssertNil(d.next(now: 9.0, piece: 1, pieceStart: s(5.0), audioEnd: s(9.0), hasSpeech: true))
        d.finalDone(piece: 0)
        XCTAssertNotNil(d.next(now: 9.0, piece: 1, pieceStart: s(5.0), audioEnd: s(9.0), hasSpeech: true))
    }

    func testTwoFinalsQueuedBothHaveToLand() {
        var d = DictationLiveDecode(sampleRate: sr)
        d.finalQueued(); d.finalQueued()
        d.finalDone(piece: 0)
        XCTAssertNil(d.next(now: 10, piece: 2, pieceStart: s(8), audioEnd: s(10), hasSpeech: true))
        d.finalDone(piece: 1)
        XCTAssertNotNil(d.next(now: 10, piece: 2, pieceStart: s(8), audioEnd: s(10), hasSpeech: true))
    }

    func testWaitsForAudioSpeechAndTheInterval() {
        var d = DictationLiveDecode(sampleRate: sr)
        XCTAssertNil(d.next(now: 0.4, piece: 0, pieceStart: 0, audioEnd: s(0.4), hasSpeech: true))      // too little
        XCTAssertNil(d.next(now: 2.0, piece: 0, pieceStart: 0, audioEnd: s(2.0), hasSpeech: false))     // no speech
        let t = d.next(now: 2.0, piece: 0, pieceStart: 0, audioEnd: s(2.0), hasSpeech: true)!
        _ = d.done(t, .text(seconds: 0.2))
        XCTAssertEqual(d.interval, 0.8)                     // 2 × 0.2 s, at least 0.8 s
        XCTAssertNil(d.next(now: 2.5, piece: 0, pieceStart: 0, audioEnd: s(2.5), hasSpeech: true))
        XCTAssertNotNil(d.next(now: 2.85, piece: 0, pieceStart: 0, audioEnd: s(2.85), hasSpeech: true))
    }

    func testNothingNewNoRequest() {
        var d = DictationLiveDecode(sampleRate: sr)
        let t = d.next(now: 2.0, piece: 0, pieceStart: 0, audioEnd: s(2.0), hasSpeech: true)!
        _ = d.done(t, .text(seconds: 0.1))
        // the clock moved on but the audio didn't (a stalled mic): nothing to decode again
        XCTAssertNil(d.next(now: 4.0, piece: 0, pieceStart: 0, audioEnd: s(2.1), hasSpeech: true))
        XCTAssertNotNil(d.next(now: 4.0, piece: 0, pieceStart: 0, audioEnd: s(2.4), hasSpeech: true))
    }

    func testTheWindowIsCapped() {
        var d = DictationLiveDecode(sampleRate: sr)
        let t = d.next(now: 31, piece: 0, pieceStart: 0, audioEnd: s(30), hasSpeech: true)!
        XCTAssertEqual(t.end - t.start, s(20))
        XCTAssertEqual(t.end, s(30))
    }

    func testAdaptiveToTheDecodeTime() {
        var d = DictationLiveDecode(sampleRate: sr)
        var now = 1.0
        for _ in 0..<6 {
            let t = d.next(now: now, piece: 0, pieceStart: 0, audioEnd: s(now), hasSpeech: true)!
            _ = d.done(t, .text(seconds: 0.55))
            now += 2
        }
        XCTAssertEqual(d.interval, 1.1, accuracy: 0.01)       // 2 × 0.55 s
        XCTAssertNil(d.off)
        // a long window of mixed speech: decodes of 0.9 s → every 1.8 s, still on
        for _ in 0..<6 {
            let t = d.next(now: now, piece: 0, pieceStart: 0, audioEnd: s(now), hasSpeech: true)!
            _ = d.done(t, .text(seconds: 0.9))
            now += 2.5
        }
        XCTAssertNil(d.off)
        XCTAssertEqual(d.interval, 1.8, accuracy: 0.05)
        // a slow machine: decodes of 2.5 s → off for the take
        for _ in 0..<6 {
            guard let t = d.next(now: now, piece: 0, pieceStart: 0, audioEnd: s(now), hasSpeech: true) else { break }
            _ = d.done(t, .text(seconds: 2.5))
            now += 3
        }
        XCTAssertEqual(d.off, .slow)
        XCTAssertEqual(d.interval, 2.2)
        XCTAssertNil(d.next(now: now + 5, piece: 0, pieceStart: 0, audioEnd: s(now + 5), hasSpeech: true))
    }

    func testOneColdDecodeDoesNotTurnItOff() {
        // the first interim of a session waits for the model to warm up (~0.9 s for 1.5 s of audio); the next are fast
        var d = DictationLiveDecode(sampleRate: sr)
        var now = 1.5
        for secs in [1.4, 0.3, 0.3, 0.35] {
            let t = d.next(now: now, piece: 0, pieceStart: 0, audioEnd: s(now), hasSpeech: true)!
            XCTAssertTrue(d.done(t, .text(seconds: secs)))
            now += 2.3
        }
        XCTAssertNil(d.off)
    }

    func testTiersAndUnsupportedAndFailures() {
        XCTAssertFalse(DictationLiveDecode.tierAllows(ramGB: 8))
        XCTAssertFalse(DictationLiveDecode.tierAllows(ramGB: 14.9))
        XCTAssertTrue(DictationLiveDecode.tierAllows(ramGB: 16))
        var off = DictationLiveDecode(sampleRate: sr, off: .tier)
        XCTAssertNil(off.next(now: 5, piece: 0, pieceStart: 0, audioEnd: s(5), hasSpeech: true))

        var u = DictationLiveDecode(sampleRate: sr)
        let t = u.next(now: 2, piece: 0, pieceStart: 0, audioEnd: s(2), hasSpeech: true)!
        XCTAssertFalse(u.done(t, .unsupported))
        XCTAssertEqual(u.off, .unsupported)

        var f = DictationLiveDecode(sampleRate: sr)
        let a = f.next(now: 2, piece: 0, pieceStart: 0, audioEnd: s(2), hasSpeech: true)!
        XCTAssertFalse(f.done(a, .failed))
        XCTAssertNil(f.off)                                  // one failure: try again
        let b = f.next(now: 4, piece: 0, pieceStart: 0, audioEnd: s(4), hasSpeech: true)!
        XCTAssertFalse(f.done(b, .failed))
        XCTAssertNil(f.off)
        let c = f.next(now: 6, piece: 0, pieceStart: 0, audioEnd: s(6), hasSpeech: true)!
        XCTAssertFalse(f.done(c, .failed))
        XCTAssertEqual(f.off, .failed)        // three in a row: the server went away
    }

    func testInterruptedIsDroppedButNotAFailure() {
        var d = DictationLiveDecode(sampleRate: sr)
        for i in 0..<4 {
            let t = d.next(now: Double(2 + 2 * i), piece: 0, pieceStart: 0, audioEnd: s(Double(2 + 2 * i)), hasSpeech: true)!
            XCTAssertFalse(d.done(t, .interrupted))
        }
        XCTAssertNil(d.off)
        XCTAssertNil(d.inFlight)
    }

    func testStaleAnswersAreDropped() {
        var d = DictationLiveDecode(sampleRate: sr)
        // the piece was cut and its final transcript landed while its interim was in flight
        let t = d.next(now: 4, piece: 0, pieceStart: 0, audioEnd: s(4), hasSpeech: true)!
        d.finalQueued()
        d.finalDone(piece: 0)
        XCTAssertFalse(d.done(t, .text(seconds: 0.3)))
        // an older answer coming in after a newer one for the same piece
        let a = d.next(now: 6, piece: 1, pieceStart: s(4.5), audioEnd: s(6), hasSpeech: true)!
        XCTAssertFalse(d.done(a, .failed))
        let b = d.next(now: 8, piece: 1, pieceStart: s(4.5), audioEnd: s(8), hasSpeech: true)!
        XCTAssertTrue(d.done(b, .text(seconds: 0.3)))
        XCTAssertFalse(d.done(a, .text(seconds: 0.3)))
        // the piece was cut, its final not in yet: its interim still shows (provisional until the final lands)
        let c = d.next(now: 10, piece: 1, pieceStart: s(4.5), audioEnd: s(10), hasSpeech: true)!
        d.finalQueued()
        XCTAssertTrue(d.done(c, .text(seconds: 0.3)))
    }

    func testStopSendsNothingMoreButLetsTheLastAnswerShow() {
        var d = DictationLiveDecode(sampleRate: sr)
        let t = d.next(now: 3, piece: 0, pieceStart: 0, audioEnd: s(3), hasSpeech: true)!
        d.stop()
        d.finalQueued()                                       // the last piece, at key-up
        XCTAssertTrue(d.done(t, .text(seconds: 0.3)))
        XCTAssertNil(d.next(now: 9, piece: 1, pieceStart: s(3), audioEnd: s(9), hasSpeech: true))
        d.finalDone(piece: 0)
        XCTAssertNil(d.next(now: 9, piece: 1, pieceStart: s(3), audioEnd: s(9), hasSpeech: true))
    }

    /// A 60 s take on a simulated warm server (serial, as transcribe.py serve is): cuts at random pauses, a final
    /// request for each, interim requests as the scheduler asks. The server stops an interim decode at its next step
    /// (20 ms) when another request is waiting. No final piece ever waits more than one step, and no interim request
    /// is ever sent while a final is pending.
    func testAnInterimDecodeNeverDelaysAFinalOne() {
        var rng = SeededRandom(seed: 7)
        let step = 0.02, tick = 0.05
        for _ in 0..<20 {
            var d = DictationLiveDecode(sampleRate: sr)
            // the server: what it is working on, until when
            enum Job { case final(piece: Int, queued: Double), interim(DictationLiveDecode.Ticket) }
            var busy: (job: Job, until: Double)?
            var waiting: [(Int, Double)] = []          // final requests at the server's door
            var finalStarted: [Double] = []            // how long each final waited (s)
            var answers: [(DictationLiveDecode.Ticket, DictationLiveDecode.Answer, Double)] = []
            var piece = 0, pieceStart = 0
            var nextCut = 3 + rng.next() * 9
            var t = 0.0
            while t < 60 {
                t += tick
                let audioEnd = s(t)
                // the server's progress
                if let b = busy {
                    switch b.job {
                    case let .interim(tk) where !waiting.isEmpty:
                        // stopped at its next step
                        let stopAt = min(b.until, t - tick + step)
                        answers.append((tk, .interrupted, stopAt))
                        busy = nil
                    case let .interim(tk) where b.until <= t:
                        answers.append((tk, .text(seconds: 0.35), b.until)); busy = nil
                    case let .final(p, _) where b.until <= t:
                        d.finalDone(piece: p); busy = nil
                    default: break
                    }
                }
                for (tk, a, _) in answers { _ = d.done(tk, a) }
                answers.removeAll()
                if busy == nil, !waiting.isEmpty {
                    let (p, q) = waiting.removeFirst()
                    finalStarted.append(t - q)
                    busy = (.final(piece: p, queued: q), t + 0.25)
                }
                // a cut: the piece goes to the server as a final request
                if t >= nextCut {
                    d.finalQueued()
                    waiting.append((piece, t))
                    piece += 1
                    pieceStart = audioEnd
                    nextCut = t + 3 + rng.next() * 17
                    if case .interim? = busy?.job {} else if busy == nil {
                        let (p, q) = waiting.removeFirst()
                        finalStarted.append(t - q)
                        busy = (.final(piece: p, queued: q), t + 0.25)
                    }
                }
                if let tk = d.next(now: t, piece: piece, pieceStart: pieceStart, audioEnd: audioEnd, hasSpeech: true) {
                    XCTAssertEqual(d.finalsPending, 0)
                    XCTAssertTrue(waiting.isEmpty)
                    XCTAssertNil(busy, "an interim is only sent to an idle server")
                    let secs = 0.1 + 0.02 * Double(tk.end - tk.start) / sr
                    busy = (.interim(tk), t + secs)
                }
            }
            XCTAssertFalse(finalStarted.isEmpty)
            // a final waits at most for the interim's next step (plus this simulation's tick)
            XCTAssertLessThanOrEqual(finalStarted.max() ?? 0, tick + step + 1e-9)
        }
    }

    // MARK: what the panel shows

    func testComposeCommittedThenPending() {
        let (c, p) = DictationLiveDecode.compose([.final("我们先看一下这个问题。"), .interim("然后再决定怎么改", hard: false)],
                                                 pauses: [0.6])
        // a breath between them: the seam takes the full stop off (as the transcript is joined)
        XCTAssertEqual(c, "我们先看一下这个问题")
        XCTAssertEqual(p, "然后再决定怎么改")
        let (c2, p2) = DictationLiveDecode.compose([.final("Fix the login page."), .interim("then ship it", hard: false)],
                                                   pauses: [1.5])
        XCTAssertEqual(c2 + p2, "Fix the login page. then ship it")
        XCTAssertEqual(c2, "Fix the login page.")
    }

    func testComposeDropsTheHardCutOverlap() {
        let (c, p) = DictationLiveDecode.compose([.final("先把登录页面的按钮改好"), .interim("按钮改好然后发布", hard: true)],
                                                 pauses: [0])
        XCTAssertEqual(c, "先把登录页面的按钮改好")
        XCTAssertEqual(p, "然后发布")
    }

    func testComposeWithAPieceStillComing() {
        // piece 1 cut (its final not in, no interim for it), piece 2 open
        let (c, p) = DictationLiveDecode.compose([.final("第一段。"), .none, .interim("第三段", hard: false)], pauses: [0.5, 0.5])
        XCTAssertEqual(c, "第一段")
        XCTAssertEqual(p, "第三段")
        // everything final: nothing pending
        let (c2, p2) = DictationLiveDecode.compose([.final("one"), .final("two")], pauses: [0.6])
        XCTAssertEqual([c2, p2], ["one two", ""])
        // nothing final yet
        let (c3, p3) = DictationLiveDecode.compose([.interim("hello there", hard: false)], pauses: [])
        XCTAssertEqual([c3, p3], ["", "hello there"])
    }
}

/// A small deterministic generator (the simulation is the same every run).
struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
}
