import XCTest
@testable import BlurtCore

/// Where a streamed dictation is cut (docs/design/dictation.md §Streaming): in pauses, never inside speech, not too
/// short, and with an overlap when there was no pause for too long.
final class DictationSegmenterTests: XCTestCase {
    let sr = 16000.0

    /// "speech": a 200 Hz tone with a syllable-like envelope at −20 dBFS; "quiet": a room at −60 dBFS.
    func speech(_ s: Double) -> [Float] {
        (0..<Int(s * sr)).map { i in
            let t = Double(i) / sr
            let env = 0.6 + 0.4 * sin(2 * .pi * 4 * t)          // 4 syllables a second, never silent
            return Float(0.1 * env * sin(2 * .pi * 200 * t))
        }
    }
    func quiet(_ s: Double) -> [Float] {
        var g = SystemRandomNumberGenerator()
        return (0..<Int(s * sr)).map { _ in Float.random(in: -0.001...0.001, using: &g) }
    }

    func run(_ parts: [[Float]], chunk: Int = 1600, _ configure: (inout DictationSegmenter) -> Void = { _ in }) -> ([DictationSegmenter.Cut], DictationSegmenter) {
        var s = DictationSegmenter(sampleRate: sr)
        configure(&s)
        let x = parts.flatMap { $0 }
        var cuts: [DictationSegmenter.Cut] = []
        var i = 0
        while i < x.count { cuts += s.feed(Array(x[i..<min(x.count, i + chunk)])); i += chunk }
        return (cuts, s)
    }

    func testCutsInTheMiddleOfAPause() {
        // 0.3 s room, 4 s talk, 0.8 s pause, 3 s talk
        let (cuts, s) = run([quiet(0.3), speech(4), quiet(0.8), speech(3)])
        XCTAssertEqual(cuts.count, 1)
        let c = cuts[0]
        XCTAssertFalse(c.hard)
        XCTAssertEqual(c.end, c.nextStart)
        // inside the pause (4.3 s … 5.1 s), after its first half second
        let at = Double(c.end) / sr
        XCTAssertGreaterThan(at, 4.3 + 0.2)
        XCTAssertLessThan(at, 5.1)
        XCTAssertTrue(s.pieceHasSpeech)             // the last piece (the 3 s) is still open
    }

    func testShortPausesAndShortPiecesDontCut() {
        // pauses of 0.3 s never cut; a 0.8 s pause after only 2 s of talk doesn't either (pieces ≥ 3 s)
        XCTAssertEqual(run([speech(2), quiet(0.3), speech(2), quiet(0.3), speech(2)]).0.count, 0)
        XCTAssertEqual(run([speech(2), quiet(0.8), speech(2)]).0.count, 0)
    }

    func testEveryPauseAfterEnoughTalkCuts() {
        let parts = [speech(3.5), quiet(0.7), speech(3.5), quiet(0.7), speech(3.5), quiet(0.7), speech(1)]
        let (cuts, _) = run(parts)
        XCTAssertEqual(cuts.count, 3)
        XCTAssertTrue(cuts.allSatisfy { !$0.hard })
        // the pieces cover everything, in order, without a gap
        XCTAssertEqual(zip(cuts, cuts.dropFirst()).filter { $0.0.nextStart > $0.1.end }.count, 0)
    }

    func testSilenceAloneIsNeverAPiece() {
        // a long silence after a cut doesn't cut again (no speech in it)
        let (cuts, s) = run([speech(3.5), quiet(5)])
        XCTAssertEqual(cuts.count, 1)
        XCTAssertFalse(s.pieceHasSpeech)
    }

    func testNoPauseForTooLongIsAHardCutWithOverlap() {
        let (cuts, _) = run([speech(25)]) { $0.maxSegment = 10 }
        XCTAssertGreaterThanOrEqual(cuts.count, 2)
        var start = 0
        for c in cuts {
            XCTAssertTrue(c.hard)
            XCTAssertEqual(c.end - c.nextStart, Int(0.8 * sr))     // the next piece hears the last 0.8 s again
            let len = Double(c.end - start) / sr
            XCTAssertLessThanOrEqual(len, 10.05)                    // within the last 2 s before the limit
            XCTAssertGreaterThanOrEqual(len, 7.9)
            start = c.nextStart
        }
    }

    func testALongPieceCutsAtItsQuietestMomentWithoutOverlapWhenItIsQuiet() {
        // 9 s of talk with a 0.3 s breath at 8 s, no 0.5 s pause: cut in the breath, a soft cut
        let (cuts, _) = run([speech(8), quiet(0.3), speech(3)]) { $0.maxSegment = 9 }
        XCTAssertEqual(cuts.count, 1)
        XCTAssertFalse(cuts[0].hard)
        let at = Double(cuts[0].end) / sr
        XCTAssertGreaterThan(at, 8.0)
        XCTAssertLessThan(at, 8.3)
    }

    func testDigitalSilenceIsQuiet() {
        // a test file's gaps are exact zeros: still pauses (not ignored)
        let zeros = [Float](repeating: 0, count: Int(0.8 * sr))
        XCTAssertEqual(run([speech(4), zeros, speech(3)]).0.count, 1)
    }
}
