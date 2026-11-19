// The go-between's small rules (docs/design/remote-go-between.md): which address is it, how long to leave it alone after a refusal,
// which addresses are overlay networks', and the wire's new parts as older peers read them.
import Network
import XCTest
@testable import BlurtRemoteKit

final class RemoteGoBetweenTests: XCTestCase {
    func testTheGoBetweenIsKnownByItsHost() {
        XCTAssertTrue(RemoteRelay.isGoBetween("wss://meet.blurt.work"))
        XCTAssertTrue(RemoteRelay.isGoBetween("meet.blurt.work/"))
        XCTAssertTrue(RemoteRelay.isGoBetween("wss://MEET.blurt.work"))
        XCTAssertFalse(RemoteRelay.isGoBetween("wss://relay.example.com"))
        XCTAssertFalse(RemoteRelay.isGoBetween("wss://meet.blurt.work.example.com"))
        XCTAssertFalse(RemoteRelay.isGoBetween(nil))
        XCTAssertEqual(RemoteRelay.address(RemoteRelay.goBetween), RemoteRelay.goBetween)
    }

    func testARefusalIsLeftAloneLongerEachTimeNeverInALoop() {
        XCTAssertEqual((1...6).map(RemoteRelay.busyWait), [30, 120, 600, 3600, 3600, 3600])
        // a refused upgrade is a connection abort; a closed port or no network isn't the go-between saying no
        XCTAssertTrue(RemoteRelay.refused(.posix(.ECONNABORTED)))
        XCTAssertFalse(RemoteRelay.refused(.posix(.ECONNREFUSED)))
        XCTAssertFalse(RemoteRelay.refused(.posix(.ENETUNREACH)))
        XCTAssertFalse(RemoteRelay.refused(nil))
    }

    func testOverlayAddresses() {
        for a in ["100.64.0.1", "100.101.102.103", "100.127.255.254", "fd7a:115c:a1e0::1", "fd7a:115c:a1e0:ab12::5%utun4"] {
            XCTAssertTrue(RemoteOverlay.isTailscale(a), a)
        }
        for a in ["100.63.255.255", "100.128.0.1", "192.168.1.20", "fd7a:115c:a1e1::1", "2001:db8::1", "not an address"] {
            XCTAssertFalse(RemoteOverlay.isTailscale(a), a)
        }
        XCTAssertTrue(RemoteOverlay.isOverlayInterface("zt7nnig26"))
        XCTAssertTrue(RemoteOverlay.isOverlayInterface("feth2093"))
        XCTAssertTrue(RemoteOverlay.isOverlayInterface("tailscale0"))
        XCTAssertFalse(RemoteOverlay.isOverlayInterface("en0"))
        XCTAssertFalse(RemoteOverlay.isOverlayInterface("utun3"))
        // kept by the phone to try at the host's port: private and overlay ones, never a public or link-local one
        for a in ["10.0.0.2", "172.20.1.1", "192.168.1.20", "100.100.1.1", "fd7a:115c:a1e0::1", "fd12::1"] {
            XCTAssertTrue(RemoteOverlay.worthTrying(a), a)
        }
        for a in ["203.0.113.5", "172.32.0.1", "2001:db8::1", "fe80::1", "8.8.8.8"] {
            XCTAssertFalse(RemoteOverlay.worthTrying(a), a)
        }
    }

    func testOlderPeersAndNewerOnes() throws {
        // a host that knows nothing of `move` drops the new cases; the new phone's hello still reads as a hello to it
        let hello = try JSONEncoder().encode(ToMac.hello(device: "iPhone", micOnPhone: true, features: ["move", "something-later"]))
        guard case let .hello(_, _, _, f) = try JSONDecoder().decode(ToMac.self, from: hello) else { return XCTFail() }
        XCTAssertEqual(f, ["move", "something-later"])
        XCTAssertNil(try? JSONDecoder().decode(ToPhone.self, from: Data(#"{"somethingLater":{}}"#.utf8)))
        XCTAssertTrue(RemoteChannel.isStreamMoved(Data([0]) + Data(#"{"streamMoved":{}}"#.utf8)))
        XCTAssertTrue(RemoteChannel.isStreamMoved(Data([0]) + Data(#"{ "streamMoved" : { } }"#.utf8)))
        XCTAssertFalse(RemoteChannel.isStreamMoved(Data([0]) + Data(#"{"udpOK":{}}"#.utf8)))
        XCTAssertFalse(RemoteChannel.isStreamMoved(Data([1]) + Data(#"{"streamMoved":{}}"#.utf8)))
        XCTAssertEqual(RemoteFrameKind(rawValue: 7), .stream)
        XCTAssertEqual(RemoteFrameKind(rawValue: 8), .streamAck)
    }
}
