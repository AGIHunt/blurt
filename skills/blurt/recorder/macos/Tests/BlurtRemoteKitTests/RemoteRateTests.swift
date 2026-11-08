// The picture's rate follows the network (docs/design/remote.md §Screen).
@testable import BlurtRemoteKit
import XCTest

final class RemoteRateTests: XCTestCase {
    func testAtHomeItStartsAtTheTop() {
        let r = RemoteRate(bitrate: 12_000_000, fps: 60)
        XCTAssertEqual(r.bitrate, 12_000_000)
        XCTAssertEqual(r.fps, 60)
    }

    func testAwayItStartsAtHalfAndClimbsWhenThePictureUsesIt() {
        var r = RemoteRate(bitrate: 4_000_000, fps: 30, away: true)
        XCTAssertEqual(r.bitrate, 2_000_000)
        for _ in 0..<30 { _ = r.update(frames: 30, lost: 0, busy: 0, rtt: 0.05, sent: r.bitrate) }
        XCTAssertEqual(r.bitrate, 4_000_000)
    }

    func testAStillScreenProvesNothing() {
        var r = RemoteRate(bitrate: 4_000_000, fps: 30, away: true)
        for _ in 0..<30 { XCTAssertFalse(r.update(frames: 0, lost: 0, busy: 0, rtt: 0.05, sent: 0)) }
        XCTAssertEqual(r.bitrate, 2_000_000)
    }

    func testAThinPipeBringsItDownToWhatGetsThrough() {
        var r = RemoteRate(bitrate: 4_000_000, fps: 30)
        for _ in 0..<12 { _ = r.update(frames: 8, lost: 0, busy: 5, backedUp: true, rtt: 0.05, sent: r.bitrate, delivered: 480_000) }
        XCTAssertLessThanOrEqual(r.bitrate, 480_000)
        XCTAssertGreaterThanOrEqual(r.bitrate, r.floor)
        XCTAssertLessThan(r.fps, 20, "fewer frames, each of them sharper")
    }

    func testOneLateFrameIsNoReasonToGiveUp() {
        var r = RemoteRate(bitrate: 4_000_000, fps: 30)
        XCTAssertFalse(r.update(frames: 30, lost: 1, busy: 1, rtt: 0.05, sent: 3_000_000))
    }

    func testRealLossAndAGrowingRoundTripBothCount() {
        var a = RemoteRate(bitrate: 4_000_000, fps: 30)
        XCTAssertTrue(a.update(frames: 20, lost: 3, busy: 0, rtt: 0.05, sent: 3_000_000))
        var b = RemoteRate(bitrate: 4_000_000, fps: 30)
        _ = b.update(frames: 30, lost: 0, busy: 0, rtt: 0.05, sent: 3_000_000)
        XCTAssertTrue(b.update(frames: 30, lost: 0, busy: 0, rtt: 0.6, sent: 3_000_000))
    }

    func testItDoesntClimbStraightBackIntoTrouble() {
        var r = RemoteRate(bitrate: 4_000_000, fps: 30)
        _ = r.update(frames: 8, lost: 0, busy: 5, backedUp: true, rtt: 0.05, sent: 1_000_000, delivered: 1_000_000)
        XCTAssertEqual(r.bitrate, 2_000_000)
        for _ in 0..<20 { _ = r.update(frames: 30, lost: 0, busy: 0, rtt: 0.05, sent: r.bitrate) }
        XCTAssertLessThanOrEqual(r.bitrate, 3_600_000)
        for _ in 0..<40 { _ = r.update(frames: 30, lost: 0, busy: 0, rtt: 0.05, sent: r.bitrate) }
        XCTAssertEqual(r.bitrate, 4_000_000, "and tries again in a while")
    }

    func testNeverBelowTheFloor() {
        var r = RemoteRate(bitrate: 1_000_000, fps: 15)
        for _ in 0..<40 { _ = r.update(frames: 1, lost: 1, busy: 9, rtt: nil, sent: 0, delivered: 1000) }
        XCTAssertEqual(r.bitrate, 200_000)
        XCTAssertEqual(r.fps, 10)
    }
}

final class RemotePairingRelayTests: XCTestCase {
    func testARelayGoesInTheCodeAndAStrangeOneStaysOut() {
        let p = RemotePairing(macID: "m", deviceID: "d", key: Data(repeating: 7, count: 32), macName: "Mac", port: 1, addresses: [], relay: "wss://relay.example.com")
        XCTAssertEqual(RemotePairing(url: p.url)?.relay, "wss://relay.example.com")
        var bad = p
        bad.relay = "https://relay.example.com"
        XCTAssertNil(RemotePairing(url: bad.url)?.relay)
        var none = p
        none.relay = nil
        XCTAssertEqual(RemotePairing(url: none.url)?.relay, nil)
    }
}
