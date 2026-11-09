import BlurtRemoteKit
import XCTest

final class RemoteVideoRepairTests: XCTestCase {
    private func frame(_ id: UInt32, size: Int = 3000, key: Bool = false, refresh: Bool = false, ack: Bool = false) -> [RemoteVideoPacket] {
        let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(id)) })
        return RemoteVideoPacket.split(data, frame: id, keyframe: key, refresh: refresh, ackRequested: ack, captured: Double(id), payload: 1000)
    }

    private func frames(_ out: [RemoteVideoReceiver.Output]) -> [UInt32] {
        out.compactMap { if case let .frame(f) = $0 { f.id } else { nil } }
    }

    private func feedback(_ out: [RemoteVideoReceiver.Output]) -> [RemoteVideoFeedback] {
        out.compactMap { if case let .feedback(f) = $0 { f } else { nil } }
    }

    func testFeedbackRoundTrips() {
        let all: [RemoteVideoFeedback] = [
            .nack([.init(frame: 7, pieces: [0, 3, 9]), .init(frame: 8, pieces: [])]),
            .ack(newest: 1234, earlier: 0b1011),
            .lost(after: 99),
        ]
        for f in all { XCTAssertEqual(RemoteVideoFeedback(f.encoded()), f) }
        XCTAssertNil(RemoteVideoFeedback(Data([9, 1, 2])))
        XCTAssertNil(RemoteVideoFeedback(Data([1, 0, 0])))
        // many frames: split so every datagram fits
        let big = RemoteVideoFeedback.nacks((0..<300).map { .init(frame: UInt32($0), pieces: [1, 2, 3]) })
        XCTAssertGreaterThan(big.count, 1)
        XCTAssertTrue(big.allSatisfy { $0.encoded().count <= RemoteVideoFeedback.maxSize })
    }

    func testFlagsByteKeepsTheOldMeaning() {
        let p = RemoteVideoPacket(frame: 1, index: 0, count: 1, keyframe: true, captured: 0, payload: Data([1]))
        XCTAssertEqual(p.encoded()[8], 1)       // what an old phone reads as a keyframe
        let r = RemoteVideoPacket(frame: 1, index: 0, count: 1, keyframe: false, refresh: true, ackRequested: true, captured: 0, payload: Data([1]))
        let back = RemoteVideoPacket(r.encoded())!
        XCTAssertEqual(back.refresh, true)
        XCTAssertEqual(back.ackRequested, true)
        XCTAssertEqual(back.keyframe, false)
    }

    func testParityRebuildsAnyOnePiece() {
        let pieces = frame(3, size: 9_500, key: true)        // ten pieces, the last short
        let parity = RemoteVideoFEC.parity(for: pieces, group: 5)
        XCTAssertEqual(parity.count, 2)
        XCTAssertTrue(parity.allSatisfy(\.isParity))
        // an old assembler never takes a parity piece for a piece
        var old = RemoteVideoAssembler()
        for p in parity { XCTAssertNil(old.add(RemoteVideoPacket(p.encoded())!)) }
        for lost in [[0], [4], [9], [3, 4]] {
            var r = RemoteVideoReceiver(nack: false, ltr: false)
            var out: [RemoteVideoReceiver.Output] = []
            for p in (pieces + parity) where !lost.contains(Int(p.index)) { out += r.add(RemoteVideoPacket(p.encoded())!, now: 0) }
            guard case let .frame(f)? = out.first else { return XCTFail("piece \(lost) not rebuilt") }
            XCTAssertEqual(f.data, pieces.reduce(Data()) { $0 + $1.payload })
            XCTAssertEqual(r.repaired, lost.count, "a burst of two lands in two groups")
        }
    }

    func testFramesWaitForAPieceSentAgain() {
        var r = RemoteVideoReceiver(nack: true, ltr: false)
        r.rtt = 0.004
        XCTAssertEqual(frames(frame(1, key: true).flatMap { r.add($0, now: 0) }), [1])
        let f2 = frame(2), f3 = frame(3)
        var out = f2.filter { $0.index != 1 }.flatMap { r.add($0, now: 0.016) }
        out += f3.flatMap { r.add($0, now: 0.032) }
        XCTAssertEqual(frames(out), [], "3 waits for 2")
        let asked = feedback(r.tick(now: 0.033))
        XCTAssertEqual(asked, [.nack([.init(frame: 2, pieces: [1])])])
        XCTAssertEqual(feedback(r.tick(now: 0.034)), [], "not again within a round trip")
        XCTAssertEqual(frames(r.add(f2[1], now: 0.037)), [2, 3])
        XCTAssertEqual(r.dropped, 0)
    }

    func testAWholeFrameMissingIsAskedFor() {
        var r = RemoteVideoReceiver(nack: true, ltr: false)
        _ = frame(1, key: true).flatMap { r.add($0, now: 0) }
        _ = frame(3).flatMap { r.add($0, now: 0.03) }
        XCTAssertEqual(feedback(r.tick(now: 0.031)), [.nack([.init(frame: 2, pieces: [])])])
        XCTAssertEqual(frames(frame(2).flatMap { r.add($0, now: 0.035) }), [2, 3])
    }

    func testTheEndOfAFrameIsAskedForOnceQuiet() {
        var r = RemoteVideoReceiver(nack: true, ltr: false)
        _ = frame(1, key: true).flatMap { r.add($0, now: 0) }
        let f2 = frame(2)
        _ = f2.dropLast().flatMap { r.add($0, now: 0.016) }
        XCTAssertEqual(feedback(r.tick(now: 0.02)), [], "its last piece may still be coming")
        XCTAssertEqual(feedback(r.tick(now: 0.05)), [.nack([.init(frame: 2, pieces: [2])])])
    }

    func testGivenUpThenARefreshEndsTheWait() {
        var r = RemoteVideoReceiver(nack: true, ltr: true)
        r.rtt = 0.004
        let k = frame(1, key: true, ack: true)
        var out = k.flatMap { r.add($0, now: 0) }
        guard case let .frame(f1) = out[0] else { return XCTFail() }
        // decoded and acknowledged
        XCTAssertEqual(feedback(r.decoded(f1, now: 0.01)), [.ack(newest: 1, earlier: 0)])
        out = frame(2).filter { $0.index != 0 }.flatMap { r.add($0, now: 0.016) }
        out += frame(3).flatMap { r.add($0, now: 0.032) }
        XCTAssertEqual(frames(out), [])
        // frames keep coming (the path works), the piece doesn't
        var t = 0.033, n: UInt32 = 4
        var lost = false
        while t < 0.3, !lost {
            if Int(t * 1000) % 16 == 0 { _ = frame(n).flatMap { r.add($0, now: t) }; n += 1 }
            lost = feedback(r.tick(now: t)).contains(.lost(after: 1))
            t += 0.001
        }
        XCTAssertTrue(lost, "gave up within its patience")
        XCTAssertLessThan(t, 0.09)
        XCTAssertTrue(r.broken)
        // ordinary frames don't help now; the refresh does
        XCTAssertEqual(frames(frame(n).flatMap { r.add($0, now: t + 0.01) }), [])
        XCTAssertEqual(frames(frame(n + 1, refresh: true).flatMap { r.add($0, now: t + 0.02) }), [n + 1])
        XCTAssertFalse(r.broken)
        XCTAssertEqual(frames(frame(n + 2).flatMap { r.add($0, now: t + 0.03) }), [n + 2])
    }

    func testAStallIsWaitedOutNotGivenUp() {
        var r = RemoteVideoReceiver(nack: true, ltr: true)
        r.rtt = 0.004
        _ = frame(1, key: true).flatMap { r.add($0, now: 0) }
        let f2 = frame(2)
        _ = f2.prefix(1).flatMap { r.add($0, now: 0.016) }
        // nothing at all for 120 ms: the rest of frame 2 was held up, not lost
        var asked = 0
        for t in stride(from: 0.02, to: 0.136, by: 0.004) {
            let out = r.tick(now: t)
            XCTAssertFalse(out.contains(.keyframe))
            XCTAssertFalse(feedback(out).contains(.lost(after: 1)), "gave up during a stall at \(t)")
            asked += feedback(out).count
        }
        XCTAssertLessThanOrEqual(asked, 1, "the end of the frame asked for once, not again into the stall")
        XCTAssertEqual(frames(f2.dropFirst().flatMap { r.add($0, now: 0.137) }), [2])
        XCTAssertFalse(r.broken)
    }

    func testAHitchOnThePhoneGivesNothingUp() {
        // the phone stops for 60 ms (a busy CPU, the app descheduled) while the piece asked for is on its way: the tick that comes after
        // reads nothing yet, so it mustn't give the frame up; the piece, read next, completes it
        var r = RemoteVideoReceiver(nack: true, ltr: true)
        r.rtt = 0.002
        _ = frame(1, key: true).flatMap { r.add($0, now: 0) }
        let f2 = frame(2)
        _ = f2.filter { $0.index != 1 }.flatMap { r.add($0, now: 0.016) }
        _ = frame(3).flatMap { r.add($0, now: 0.032) }
        XCTAssertEqual(feedback(r.tick(now: 0.033)), [.nack([.init(frame: 2, pieces: [1])])])
        // back after 60 ms: the first piece read (heard just now, so it doesn't look like a stall), then the timers, then the rest
        _ = frame(4).flatMap { r.add($0, now: 0.094) }
        let out = r.tick(now: 0.094)
        XCTAssertFalse(feedback(out).contains { if case .lost = $0 { true } else { false } }, "gave up after a hitch: \(out)")
        XCTAssertFalse(r.broken)
        XCTAssertEqual(frames(r.add(f2[1], now: 0.095)), [2, 3, 4])
        XCTAssertEqual(r.dropped, 0)
        // a piece that really is gone is still given up on, the hitch not counted
        _ = frame(5).filter { $0.index != 0 }.flatMap { r.add($0, now: 0.096) }
        var t = 0.098, n: UInt32 = 6
        var lost: Double?
        while t < 0.4, lost == nil {
            if t >= 0.096 + 0.016 * Double(n - 5) { _ = frame(n).flatMap { r.add($0, now: t) }; n += 1 }
            if feedback(r.tick(now: t)).contains(.lost(after: 4)) { lost = t }
            t += 0.002
        }
        guard let lost else { return XCTFail("a lost piece is still given up") }
        XCTAssertLessThan(lost, 0.097 + r.patience + 0.05)
    }

    func testAPhoneThatStaysBusyStillGivesUp() {
        // every tick 20 ms after the last (a slow phone's busy main queue): each one looks like a hitch, but a piece that never comes is
        // still given up within a second of real time, so the picture doesn't freeze with nothing asked
        var r = RemoteVideoReceiver(nack: true, ltr: true)
        r.rtt = 0.002
        _ = frame(1, key: true).flatMap { r.add($0, now: 0) }
        _ = frame(2).filter { $0.index != 1 }.flatMap { r.add($0, now: 0.016) }
        var t = 0.02, n: UInt32 = 3
        var lost: Double?
        while t < 2, lost == nil {
            _ = frame(n).flatMap { r.add($0, now: t) }; n += 1
            if feedback(r.tick(now: t)).contains(.lost(after: 1)) { lost = t }
            t += 0.02
        }
        guard let lost else { return XCTFail("given up though every tick was late") }
        XCTAssertLessThanOrEqual(lost, 0.02 + 1.0 + 0.02 + 1e-9)
    }

    func testAfterAStallThePieceAskedForGetsItsRetry() {
        // the end of frame 2 is lost, asked for, and then nothing comes for 80 ms (Wi-Fi's stall, or the sender stopped): when the next
        // frame's first piece arrives the frame has been late longer than the patience, but only in the stall
        var r = RemoteVideoReceiver(nack: true, ltr: true)
        r.rtt = 0.002
        _ = frame(1, key: true).flatMap { r.add($0, now: 0) }
        let f2 = frame(2)
        _ = f2.prefix(1).flatMap { r.add($0, now: 0.016) }
        var t = 0.02
        var asked: [RemoteVideoFeedback] = []
        while t < 0.13 { asked += feedback(r.tick(now: t)); t += 0.004 }
        XCTAssertEqual(asked, [.nack([.init(frame: 2, pieces: [1, 2])])], "asked once, then the stall")
        _ = frame(3).prefix(1).flatMap { r.add($0, now: 0.13) }
        let out = r.tick(now: 0.13)
        XCTAssertFalse(feedback(out).contains { if case .lost = $0 { true } else { false } }, "gave up as the stall ended: \(out)")
        XCTAssertEqual(feedback(out), [.nack([.init(frame: 2, pieces: [1, 2])])], "asked again at once")
        XCTAssertEqual(frames(f2.dropFirst().flatMap { r.add($0, now: 0.134) }), [2])
        XCTAssertEqual(r.dropped, 0)
    }

    func testWithoutLTRALossAsksForAKeyframe() {
        var r = RemoteVideoReceiver(nack: true, ltr: false)
        _ = frame(1, key: true).flatMap { r.add($0, now: 0) }
        _ = frame(3).flatMap { r.add($0, now: 0.02) }
        var t = 0.02, asked = false
        while t < 0.4, !asked { asked = r.tick(now: t).contains(.keyframe); t += 0.005 }
        XCTAssertTrue(asked)
        XCTAssertEqual(frames(frame(9, key: true).flatMap { r.add($0, now: t) }), [9])
        XCTAssertEqual(r.dropped, 7)
    }

    func testAfterTheDecoderFailsOnlyAKeyframeWill() {
        var r = RemoteVideoReceiver(nack: true, ltr: true)
        _ = frame(1, key: true).flatMap { r.add($0, now: 0) }
        r.decoderFailed(now: 0.01)
        XCTAssertEqual(r.tick(now: 0.02), [.keyframe])
        XCTAssertEqual(frames(frame(2, refresh: true).flatMap { r.add($0, now: 0.03) }), [])
        XCTAssertEqual(frames(frame(3, key: true).flatMap { r.add($0, now: 0.04) }), [3])
    }

    func testNoAskingAtTheStartWhileTheFirstKeyframeArrives() {
        var r = RemoteVideoReceiver(nack: true, ltr: true, now: 0)
        _ = frame(1, key: true).prefix(1).flatMap { r.add($0, now: 0.001) }
        XCTAssertFalse(r.tick(now: 0.01).contains(.keyframe))
        XCTAssertTrue(r.tick(now: 0.5).contains(.keyframe))
    }

    func testHistoryKeepsASecond() {
        var h = RemoteVideoHistory(maxAge: 1, maxBytes: 10_000)
        h.add(1, [Data([1]), Data([2])], now: 0)
        h.add(2, [Data([3])], now: 0.5)
        XCTAssertEqual(h.pieces(1, [1]), [Data([2])])
        XCTAssertEqual(h.pieces(1, []).count, 2)
        h.add(3, [Data([4])], now: 1.2)
        XCTAssertEqual(h.pieces(1, [0]), [])
        XCTAssertEqual(h.pieces(2, [0]), [Data([3])])
    }
}
