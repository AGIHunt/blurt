// The joining side's rule for `newKey` (RemoteJoinGate): someone holding a photo of the code can answer as the computer, so the key is
// taken only after the computer asked and this side's user said the digits are the same.
import XCTest
@testable import BlurtRemoteKit

final class RemoteJoinGateTests: XCTestCase {
    private let key = Data(repeating: 9, count: 32)

    func testAKeyWithoutTheQuestionIsDropped() {
        var g = RemoteJoinGate()
        XCTAssertNil(g.newKey(key))
        g.pairingWaits()
        XCTAssertNil(g.confirm(), "the early key was dropped, not held")
    }

    func testTheComputersYesWaitsForThisSide() {
        var g = RemoteJoinGate()
        g.pairingWaits()
        XCTAssertTrue(g.canConfirm)
        XCTAssertNil(g.newKey(key))
        XCTAssertTrue(g.keyWaiting)
        XCTAssertEqual(g.confirm(), key)
        XCTAssertFalse(g.keyWaiting)
    }

    func testThisSidesYesFirst() {
        var g = RemoteJoinGate()
        g.pairingWaits()
        XCTAssertNil(g.confirm())
        XCTAssertFalse(g.canConfirm)
        XCTAssertEqual(g.newKey(key), key)
    }

    func testAYesBeforeTheDigitsCountsForNothing() {
        var g = RemoteJoinGate()
        XCTAssertNil(g.confirm())
        g.pairingWaits()
        XCTAssertNil(g.newKey(key))
    }

    func testANewConnectionAsksAgain() {
        var g = RemoteJoinGate()
        g.pairingWaits()
        _ = g.confirm()
        g.reset()
        XCTAssertNil(g.newKey(key))
    }

    func testTheCasesOnlyStoreAfterQuestionAndYes() {
        for c in RemoteJoinGate.cases {
            guard let at = RemoteJoinGate.run(c) else { continue }
            let before = c[...at]
            let lastReconnect = before.lastIndex(of: .reconnect) ?? -1
            let since = c[(lastReconnect + 1)...at]
            XCTAssertTrue(since.contains(.pairingWaits) && since.contains(.same) && since.contains(.newKey), "\(c)")
        }
    }
}
