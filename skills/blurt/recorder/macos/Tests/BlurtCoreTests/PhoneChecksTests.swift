// BlurtCore/PhoneChecks.swift: the Phone page's headline, which lines about this Mac show, and what to try when a
// phone won't connect.
import XCTest
@testable import BlurtCore

final class PhoneChecksTests: XCTestCase {
    func testHeadline() {
        XCTAssertEqual(PhoneChecks.headline(PhoneFacts()), .nonePaired)
        XCTAssertEqual(PhoneChecks.headline(PhoneFacts(paired: 2, listening: true)), .notConnected)
        XCTAssertEqual(PhoneChecks.headline(PhoneFacts(paired: 1, connected: "iPhone", listening: true)), .connected(name: "iPhone", viaRelay: false))
        XCTAssertEqual(PhoneChecks.headline(PhoneFacts(paired: 1, connected: "Pixel", viaRelay: true, listening: true, relay: .ok)),
                       .connected(name: "Pixel", viaRelay: true))
        // a phone in the middle of pairing is connected before it is in the list
        XCTAssertEqual(PhoneChecks.headline(PhoneFacts(paired: 0, connected: "", pairing: true)), .connected(name: "", viaRelay: false))
    }

    func testAllWellIsNoLines() {
        XCTAssertEqual(PhoneChecks.problems(PhoneFacts()), [])
        XCTAssertEqual(PhoneChecks.problems(PhoneFacts(paired: 1, connected: "iPhone", listening: true, relay: .ok)), [])
        // a relay still being asked is not a problem yet
        XCTAssertEqual(PhoneChecks.problems(PhoneFacts(paired: 1, listening: true, relay: .checking)), [])
    }

    func testAccessibilityIsSaidBeforePairing() {
        XCTAssertEqual(PhoneChecks.problems(PhoneFacts(canControl: false)), [.accessibility])
        // …but nothing needs attention until a phone is paired
        XCTAssertFalse(PhoneChecks.needsAttention(PhoneFacts(canControl: false)))
        XCTAssertTrue(PhoneChecks.needsAttention(PhoneFacts(paired: 1, canControl: false, listening: true)))
    }

    func testScreenRecordingOnlyWhenTheScreenIsShared() {
        XCTAssertEqual(PhoneChecks.problems(PhoneFacts(screenWanted: true, screenAllowed: false)), [.screenRecording])
        XCTAssertEqual(PhoneChecks.problems(PhoneFacts(screenWanted: false, screenAllowed: false)), [])
        // the pointer and the keys still work: not the tile's business
        XCTAssertFalse(PhoneChecks.needsAttention(PhoneFacts(paired: 1, screenAllowed: false, listening: true)))
    }

    func testThePortOnlyOnceItShouldBeOpenAndTheSystemSaidWhy() {
        // nothing paired, no code: the port is closed on purpose
        XCTAssertEqual(PhoneChecks.problems(PhoneFacts(listening: false, listenFailure: "EADDRINUSE")), [])
        // starting: closed for a moment, no reason given
        XCTAssertEqual(PhoneChecks.problems(PhoneFacts(paired: 1, listening: false)), [])
        XCTAssertEqual(PhoneChecks.problems(PhoneFacts(paired: 1, listening: false, listenFailure: "EADDRINUSE")), [.notListening("EADDRINUSE")])
        XCTAssertEqual(PhoneChecks.problems(PhoneFacts(listening: false, listenFailure: "denied", pairing: true)), [.notListening("denied")])
        XCTAssertTrue(PhoneChecks.needsAttention(PhoneFacts(paired: 1, listening: false, listenFailure: "EADDRINUSE")))
        // open again: the old reason is history
        XCTAssertEqual(PhoneChecks.problems(PhoneFacts(paired: 1, listening: true, listenFailure: "EADDRINUSE")), [])
    }

    func testOrderMostInTheWayFirst() {
        let f = PhoneFacts(paired: 1, canControl: false, screenAllowed: false, listening: false, listenFailure: "x", relay: .failed)
        XCTAssertEqual(PhoneChecks.problems(f), [.accessibility, .notListening("x"), .screenRecording, .relayUnreachable])
    }

    func testTipsOnlyWhileAPhoneShouldBeConnecting() {
        XCTAssertEqual(PhoneChecks.tips(PhoneFacts()), [])
        XCTAssertEqual(PhoneChecks.tips(PhoneFacts(paired: 1, connected: "iPhone", listening: true)), [])
        XCTAssertEqual(PhoneChecks.tips(PhoneFacts(paired: 1, listening: true)), [.sameNetwork, .appOpenMacAwake, .vpnFirewall, .awayNeedsRelay])
        // a code waiting to be scanned counts
        XCTAssertEqual(PhoneChecks.tips(PhoneFacts(listening: true, pairing: true)).count, 4)
    }

    func testTheAwayLineFollowsTheRelay() {
        XCTAssertEqual(PhoneChecks.tips(PhoneFacts(paired: 1, relay: .ok)).last, .awayUsesRelay)
        XCTAssertEqual(PhoneChecks.tips(PhoneFacts(paired: 1, relay: .checking)).last, .awayUsesRelay)
        // a relay that doesn't answer is a problem line with its own fix: not said twice
        let down = PhoneFacts(paired: 1, listening: true, relay: .failed)
        XCTAssertEqual(PhoneChecks.problems(down), [.relayUnreachable])
        XCTAssertEqual(PhoneChecks.tips(down), [.sameNetwork, .appOpenMacAwake, .vpnFirewall])
    }
}
