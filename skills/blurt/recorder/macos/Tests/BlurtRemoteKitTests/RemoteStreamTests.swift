// The stream over UDP (RemoteStream.swift; docs/design/remote-go-between.md, "Rules for the stream over UDP"), with a clock that only moves
// when a test says so: loss, reordering, duplicates, a full window, the timeout and its backoff, and three acks in a row.
import XCTest
@testable import BlurtRemoteKit

final class RemoteStreamTests: XCTestCase {
    /// the same "random" every run
    private struct Seeded: RandomNumberGenerator {
        var x: UInt64
        init(_ s: UInt64) { x = s }
        mutating func next() -> UInt64 {
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return x ^ (x >> 29)
        }
    }

    private func bytes(_ n: Int, seed: Int = 0) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed) }) }

    private func chunks(_ p: [RemoteStreamPacket]) -> [(UInt64, Data)] {
        p.compactMap { if case let .data(o, b) = $0 { (o, b) } else { nil } }
    }

    /// Carries packets between a sender and a receiver, losing or holding back the ones a test names.
    private final class Pipe {
        let s: RemoteStreamSender
        let r = RemoteStreamReceiver()
        var now = 0.0
        var got = Data()
        var acks: [UInt64] = []
        init(rtt: Double? = 0.05) { s = RemoteStreamSender(rtt: rtt) }

        func deliver(_ p: [RemoteStreamPacket], drop: (UInt64) -> Bool = { _ in false }) {
            for case let .data(o, b) in p where !drop(o) {
                let (d, a) = r.receive(offset: o, bytes: b, now: now)
                got.append(d)
                if let a { acks.append(a) }
            }
        }

        /// the acks so far reach the sender; what that sends goes through too
        func returnAcks(drop: (UInt64) -> Bool = { _ in false }) {
            let a = acks
            acks = []
            for n in a { deliver(s.ack(n, now: now), drop: drop) }
        }

        func tick(drop: (UInt64) -> Bool = { _ in false }) {
            if let a = r.tick(now: now) { acks.append(a) }
            deliver(s.tick(now: now), drop: drop)
        }
    }

    func testPacketsEncodeAsTheSpecSays() {
        let d = RemoteStreamPacket.data(offset: 0x0102030405060708, bytes: Data([0xaa, 0xbb]))
        XCTAssertEqual(d.encoded(), Data([1, 2, 3, 4, 5, 6, 7, 8, 0xaa, 0xbb]))
        XCTAssertEqual(RemoteStreamPacket(kind: .stream, body: d.encoded()), d)
        let a = RemoteStreamPacket.ack(next: 1100)
        XCTAssertEqual(a.encoded(), Data([0, 0, 0, 0, 0, 0, 0x04, 0x4c]))
        XCTAssertEqual(RemoteStreamPacket(kind: .streamAck, body: a.encoded()), a)
        // too short, too long, or an ack with bytes after it: not ours
        XCTAssertNil(RemoteStreamPacket(kind: .stream, body: Data(count: 7)))
        XCTAssertNil(RemoteStreamPacket(kind: .stream, body: Data(count: 8 + RemoteStream.chunk + 1)))
        XCTAssertNotNil(RemoteStreamPacket(kind: .stream, body: Data(count: 8 + RemoteStream.chunk)))
        XCTAssertNil(RemoteStreamPacket(kind: .streamAck, body: Data(count: 9)))
        XCTAssertNil(RemoteStreamPacket(kind: .video, body: Data(count: 8)))
    }

    func testBytesGoInChunksAndArriveInOrder() {
        let p = Pipe()
        let data = bytes(5000)
        let out = p.s.write(data, now: 0)
        XCTAssertEqual(chunks(out).map(\.0), [0, 1100, 2200, 3300, 4400])
        XCTAssertEqual(chunks(out).map(\.1.count), [1100, 1100, 1100, 1100, 600])
        p.deliver(out)
        XCTAssertEqual(p.got, data)
        // the first packet is acked at once, the rest within 20 ms
        XCTAssertEqual(p.acks, [1100])
        p.now = 0.02
        p.tick()
        XCTAssertEqual(p.acks, [1100, 5000])
        p.returnAcks()
        XCTAssertEqual(p.s.acked, 5000)
        XCTAssertEqual(p.s.inFlight, 0)
        XCTAssertNil(p.s.deadline)
    }

    func testReorderedAndDuplicatedPacketsStillReadInOrder() {
        let p = Pipe()
        let data = bytes(4400, seed: 3)
        var out = p.s.write(data, now: 0)
        out = [out[2], out[0], out[3], out[0], out[1], out[2], out[1]]     // late, early and twice
        p.deliver(out)
        XCTAssertEqual(p.got, data)
        XCTAssertEqual(p.r.next, 4400)
        XCTAssertEqual(p.r.held, 0)
    }

    func testAChunkThatOverlapsWhatsThereIsFine() {
        let r = RemoteStreamReceiver()
        let data = bytes(3000, seed: 5)
        var got = Data()
        got.append(r.receive(offset: 1000, bytes: data[1000..<2000], now: 0).data)
        got.append(r.receive(offset: 500, bytes: data[500..<1500], now: 0).data)
        XCTAssertTrue(got.isEmpty)
        got.append(r.receive(offset: 0, bytes: data[0..<800], now: 0).data)
        XCTAssertEqual(got, data[0..<2000])
        got.append(r.receive(offset: 1900, bytes: data[1900..<3000], now: 0).data)
        XCTAssertEqual(got, data)
    }

    func testALostChunkGoesAgainAfterTheTimeoutFromTheAckedOffset() {
        let p = Pipe(rtt: 0.05)
        let data = bytes(3300, seed: 9)
        p.deliver(p.s.write(data, now: 0), drop: { $0 == 1100 })
        XCTAssertEqual(p.got, data[0..<1100])
        p.now = 0.02
        p.tick()
        p.returnAcks()
        XCTAssertEqual(p.s.acked, 1100)
        // RTO = max(200 ms, 2 × 50 ms): nothing before it, from the last progress
        XCTAssertEqual(p.s.rto, 0.2, accuracy: 1e-9)
        p.now = 0.2
        XCTAssertTrue(p.s.tick(now: p.now).isEmpty)
        p.now = 0.221
        let again = p.s.tick(now: p.now)
        XCTAssertEqual(chunks(again).map(\.0), [1100, 2200], "from the acked offset, what's in flight")
        p.deliver(again)
        XCTAssertEqual(p.got, data)
        p.returnAcks()
        XCTAssertEqual(p.s.acked, 3300)
    }

    func testTheTimeoutDoublesUpToTwoSecondsAndSendsAtMostEightChunks() {
        let s = RemoteStreamSender(rtt: 0.05)
        _ = s.write(bytes(20 * 1100), now: 0)
        var t = 0.0
        var waits: [Double] = []
        for _ in 0..<7 {
            let d = s.deadline!
            waits.append(((d - t) * 1000).rounded() / 1000)
            t = d
            let out = s.tick(now: t)
            XCTAssertEqual(out.count, RemoteStream.resendBurst)
            XCTAssertEqual(chunks(out).first?.0, 0)
        }
        XCTAssertEqual(waits, [0.2, 0.4, 0.8, 1.6, 2, 2, 2])
        // progress puts it back to max(200 ms, 2 × RTT)
        _ = s.ack(1100, now: t + 0.1)
        XCTAssertEqual(s.deadline! - (t + 0.1), s.rto, accuracy: 1e-9)
        XCTAssertLessThan(s.rto, 0.5)
    }

    func testTheTimeoutFollowsTheRoundTrip() {
        let s = RemoteStreamSender()
        _ = s.write(bytes(1100), now: 0)
        _ = s.ack(1100, now: 0.5)
        XCTAssertEqual(s.srtt!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.rto, 1.0, accuracy: 1e-9)
        _ = s.write(bytes(1100), now: 1)
        _ = s.ack(2200, now: 1.1)
        XCTAssertEqual(s.srtt!, 0.5 * 7 / 8 + 0.1 / 8, accuracy: 1e-9)
    }

    func testThreeAcksInARowWithTheSameNextSendOneChunkAtOnce() {
        let p = Pipe(rtt: 0.05)
        let data = bytes(6 * 1100, seed: 1)
        let out = p.s.write(data, now: 0)
        // the second chunk is lost; the rest arrive 25 ms apart, so each is acked
        for (i, c) in out.enumerated() where i != 1 {
            p.now = Double(i) * 0.025
            p.deliver([c])
        }
        XCTAssertEqual(p.acks, [1100, 1100, 1100, 1100, 1100])
        let s = p.s
        XCTAssertTrue(s.ack(1100, now: p.now).isEmpty)
        XCTAssertTrue(s.ack(1100, now: p.now).isEmpty)
        let fast = s.ack(1100, now: p.now)
        XCTAssertEqual(chunks(fast).map(\.0), [1100], "one chunk, long before the timeout")
        XCTAssertLessThan(p.now, s.deadline!)
        p.acks = []
        p.deliver(fast)
        XCTAssertEqual(p.got, data)
        XCTAssertEqual(p.acks, [6600], "it filled the gap: acked at once")
    }

    func testAFullWindowQueuesTheRestUntilAcksMakeRoom() {
        let s = RemoteStreamSender(rtt: 0.05)
        let data = bytes(RemoteStream.window + 5000, seed: 2)
        let out = s.write(data, now: 0)
        XCTAssertEqual(chunks(out).reduce(0) { $0 + $1.1.count }, RemoteStream.window)
        XCTAssertEqual(s.inFlight, RemoteStream.window)
        XCTAssertEqual(s.queued, 5000)
        XCTAssertTrue(s.write(bytes(10), now: 0).isEmpty, "nothing more goes while the window is full")
        let more = s.ack(4400, now: 0.1)
        XCTAssertEqual(chunks(more).reduce(0) { $0 + $1.1.count }, 4400)
        XCTAssertEqual(chunks(more).first?.0, UInt64(RemoteStream.window))
        XCTAssertEqual(s.inFlight, RemoteStream.window)
        XCTAssertEqual(s.queued, 610)
    }

    func testTheReceiverKeepsNothingPastItsWindow() {
        let r = RemoteStreamReceiver()
        let w = UInt64(RemoteStream.window)
        _ = r.receive(offset: w + 10, bytes: bytes(100), now: 0)
        XCTAssertEqual(r.held, 0)
        _ = r.receive(offset: w - 50, bytes: bytes(100), now: 0)
        XCTAssertEqual(r.held, 50, "the part inside the window only")
        // an ack for more than was sent is ignored
        let s = RemoteStreamSender()
        _ = s.write(bytes(10), now: 0)
        _ = s.ack(11, now: 0)
        XCTAssertEqual(s.acked, 0)
    }

    func testAcksComeAtMostEveryTwentyMillisecondsAndNoneIsForgotten() {
        let r = RemoteStreamReceiver()
        XCTAssertEqual(r.receive(offset: 0, bytes: bytes(10), now: 0).ack, 10)
        XCTAssertNil(r.receive(offset: 10, bytes: bytes(10), now: 0.005).ack)
        XCTAssertNil(r.receive(offset: 20, bytes: bytes(10), now: 0.01).ack)
        XCTAssertEqual(r.deadline!, 0.02, accuracy: 1e-9)
        XCTAssertNil(r.tick(now: 0.019))
        XCTAssertEqual(r.tick(now: 0.02), 30)
        XCTAssertNil(r.deadline)
        // a duplicate is acked too (the ack that said so may have been lost), within the same limit
        XCTAssertEqual(r.receive(offset: 0, bytes: bytes(10), now: 0.05).ack, 30)
    }

    func testABigStreamThroughALossyReorderingPipeArrivesWhole() {
        // 2 MB through a pipe that loses one packet in ten and swaps neighbours, acks lost too: it all arrives, in order
        var rng = Seeded(7)
        let p = Pipe(rtt: 0.05)
        let data = bytes(2_000_000, seed: 7)
        var inbox: [RemoteStreamPacket] = p.s.write(data, now: 0)
        var steps = 0
        while p.s.acked < data.count, steps < 200_000 {
            steps += 1
            p.now += 0.005
            if inbox.count > 1, Bool.random(using: &rng) { inbox.swapAt(0, 1) }
            if let first = inbox.first {
                inbox.removeFirst()
                if Int.random(in: 0..<10, using: &rng) != 0 { p.deliver([first]) }
            }
            if let a = p.r.tick(now: p.now) { p.acks.append(a) }
            for n in p.acks where Int.random(in: 0..<10, using: &rng) != 0 { inbox += p.s.ack(n, now: p.now) }
            p.acks = []
            inbox += p.s.tick(now: p.now)
        }
        XCTAssertEqual(p.s.acked, UInt64(data.count))
        XCTAssertEqual(p.got.count, data.count)
        XCTAssertEqual(p.got, data)
    }
}
