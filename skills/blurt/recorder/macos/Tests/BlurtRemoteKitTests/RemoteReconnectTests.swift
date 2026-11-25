import BlurtRemoteKit
import Foundation
import XCTest

final class RemoteReconnectTests: XCTestCase {
    /// Six tries in the first ten seconds and no more than one every five after: well inside the go-between's 40 in 10 s.
    func testTheRelayIsAskedSoonThenLessOften() {
        var at = 0.0, n = 0
        while at < 10 { n += 1; at += RemoteReconnect.relayAgain(n) }
        XCTAssertLessThanOrEqual(n, 6)
        XCTAssertLessThan(RemoteReconnect.relayAgain(1), 0.5)
        XCTAssertEqual(RemoteReconnect.relayAgain(50), 5)
        for i in 1..<10 { XCTAssertLessThanOrEqual(RemoteReconnect.relayAgain(i), RemoteReconnect.relayAgain(i + 1)) }
    }

    func testAtHomeTheRelayNeverLeads() {
        XCTAssertEqual(RemoteReconnect.relayDelay(lastAway: true), 0)
        XCTAssertGreaterThan(RemoteReconnect.relayDelay(lastAway: false), 1)
    }

    /// A busy go-between: coming back to the app asks far less often than Retry.
    func testBusyIsAskedAgainSoonerWhenTheUserSaysSo() {
        XCTAssertGreaterThan(RemoteReconnect.busyFloor(asked: false), RemoteReconnect.busyFloor(asked: true))
        XCTAssertGreaterThan(RemoteReconnect.busyFloor(asked: true), 10)
    }

    /// Three displays, one small: grown to be a target, and never over a neighbour or out of the map.
    func testThreeDisplaysNeverOverlapInTheMap() {
        let d = [RemoteDisplay(id: "1", name: "1", x: 0, y: 0, width: 1920, height: 1080, main: true),
                 RemoteDisplay(id: "2", name: "2", x: 1920, y: -180, width: 2560, height: 1440, main: false),
                 RemoteDisplay(id: "3", name: "3", x: -1280, y: 140, width: 1280, height: 800, main: false)]
        for (w, h) in [(330.0, 150.0), (200, 90), (700, 300)] {
            let m = RemoteDisplayMap.layout(d, in: CGSize(width: w, height: h), gap: 8, smallest: 34)
            let r = Array(m.values)
            XCTAssertEqual(r.count, 3)
            for i in 0..<3 {
                for j in (i + 1)..<3 { XCTAssertFalse(r[i].insetBy(dx: 0.5, dy: 0.5).intersects(r[j]), "\(w) \(r)") }
                XCTAssertGreaterThanOrEqual(r[i].minX, -0.5)
                XCTAssertLessThanOrEqual(r[i].maxX, w + 0.5)
            }
        }
    }
}
