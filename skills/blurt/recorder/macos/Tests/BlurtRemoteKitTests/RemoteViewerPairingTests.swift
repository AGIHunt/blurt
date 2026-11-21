// How a viewer's pairing ends when it doesn't end paired, and how a paired computer says it let this viewer go: each case has its own
// state, so the Add Computer sheet and the window can say what happened and what to do next (a spent link is not "didn't allow").
// The host is RemoteViewerSessionTests.Host, in this process.
import Network
import XCTest
@testable import BlurtRemoteKit

final class RemoteViewerPairingTests: XCTestCase {
    private typealias Host = RemoteViewerSessionTests.Host
    private typealias Viewer = RemoteViewerSessionTests.Viewer

    private func until(_ seconds: Double, _ ok: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !ok(), Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        return ok()
    }

    private func nearby(_ port: UInt16) -> RemoteViewerLink {
        let c = RemoteComputer(id: "test-host", deviceID: RemoteNearby.newID(), name: "Test Host", port: 0, addresses: [])
        return RemoteViewerLink(computer: c, key: RemoteNearby.key, deviceName: "Test Mac", pairing: true,
                                endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), callbacks: DispatchQueue(label: "cb"))
    }

    private static func waited(_ s: RemoteViewerLink.State) -> Bool { if case .waiting = s { true } else { false } }

    /// A pasted link whose code the host no longer knows (ran out, or used already): refused before anyone was asked.
    func testASpentLinkIsNotARefusal() throws {
        let host = try Host(pictures: [])
        let ports = host.start()
        defer { host.stop() }
        let p = RemotePairing(macID: "no-such-mac-\(UUID().uuidString)", deviceID: RemoteCrypto.newID(), key: RemoteCrypto.newKey(), macName: "Studio Mac",
                              port: ports.tcp, addresses: ["127.0.0.1"])
        let link = RemoteViewerLink(computer: RemoteComputer(pairing: p), key: p.key, deviceName: "Test Mac", pairing: true, callbacks: DispatchQueue(label: "cb"))
        let v = Viewer(link)
        link.start()
        defer { link.stop() }
        XCTAssertTrue(until(8) { v.states.last == .pairingFailed(.spent) }, "\(v.states)")
        XCTAssertFalse(v.states.contains(.forgotten), "\(v.states)")
        XCTAssertFalse(v.states.contains(where: Self.waited))
    }

    /// The owner said no: the question was asked (six digits), then the host let go.
    func testTheOwnerSaysNo() throws {
        let host = try Host(pictures: [])
        host.answer = .no
        let ports = host.start()
        defer { host.stop() }
        let link = nearby(ports.tcp)
        let v = Viewer(link)
        link.start()
        defer { link.stop() }
        XCTAssertTrue(until(6) { v.states.last == .pairingFailed(.declined) }, "\(v.states)")
        XCTAssertTrue(v.states.contains(where: Self.waited))
    }

    /// Nobody answered: the host gives up asking after its two minutes (here the link's own wait is cut to a second).
    func testNobodyAnswers() throws {
        let host = try Host(pictures: [])
        host.answer = .none(closeAfter: 1.2)
        let ports = host.start()
        defer { host.stop() }
        let link = nearby(ports.tcp)
        link.questionLife = 1
        let v = Viewer(link)
        link.start()
        defer { link.stop() }
        XCTAssertTrue(until(6) { v.states.last == .pairingFailed(.unanswered) }, "\(v.states)")
    }

    /// Can't reach it at first; once the host is up it asks, and the link says so (the sheet shows the digits in place of "Can't reach").
    func testUnreachableThenAsked() throws {
        let host = try Host(pictures: [])
        host.deafUntil = Date().addingTimeInterval(10)
        host.answer = .none(closeAfter: 30)
        let ports = host.start()
        defer { host.stop() }
        let link = nearby(ports.tcp)
        let v = Viewer(link)
        link.start()
        defer { link.stop() }
        XCTAssertTrue(until(14) { v.states.contains(.unreachable) }, "\(v.states)")
        XCTAssertTrue(until(10) { v.states.last.map(Self.waited) == true }, "\(v.states)")
    }

    /// The host removed this viewer in a session it had opened: `removed`, not the unauthenticated `forgotten` a refusal gives.
    func testRemovedBySessionIsNotForgotten() throws {
        // the viewer asks for the picture once connected: the host has frames to send
        let host = try Host(pictures: try RemoteViewerSessionTests.pictures())
        let ports = host.start()
        defer { host.stop() }
        let id = RemoteCrypto.newID(), key = RemoteCrypto.newKey()
        host.pairedID = id
        host.pairedKey = key
        host.removeAfter = 0.5
        let c = RemoteComputer(id: "test-host", deviceID: id, name: "Test Host", port: ports.tcp, addresses: ["127.0.0.1"])
        let link = RemoteViewerLink(computer: c, key: key, deviceName: "Test Mac", callbacks: DispatchQueue(label: "cb"))
        let v = Viewer(link)
        link.start()
        defer { link.stop() }
        XCTAssertTrue(until(6) { v.states.contains(.connected) }, "\(v.states)")
        XCTAssertTrue(until(6) { v.states.last == .removed }, "\(v.states)")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(v.states.last, .removed, "it stays said: nothing tries again with a key the host dropped")
    }

    /// A saved computer that refuses the key without a session (anyone on the network can send that): `forgotten`, the key kept.
    func testARefusedKeyIsForgotten() throws {
        let host = try Host(pictures: [])
        let ports = host.start()
        defer { host.stop() }
        let c = RemoteComputer(id: "test-host", deviceID: RemoteCrypto.newID(), name: "Test Host", port: ports.tcp, addresses: ["127.0.0.1"])
        let link = RemoteViewerLink(computer: c, key: RemoteCrypto.newKey(), deviceName: "Test Mac", callbacks: DispatchQueue(label: "cb"))
        let v = Viewer(link)
        link.start()
        defer { link.stop() }
        XCTAssertTrue(until(8) { v.states.last == .forgotten }, "\(v.states)")
    }

    func testTheListSaysARemovedComputerIsRemoved() {
        var c = RemoteComputer(id: "a", deviceID: "d", name: "Mini", port: 1, addresses: [], relayAddress: "wss://relay.example.com")
        XCTAssertEqual(RemoteViewerRow.of(c, connected: false, route: nil, nearby: true, failed: nil), .available(.local))
        c.removed = true
        XCTAssertEqual(RemoteViewerRow.of(c, connected: false, route: nil, nearby: true, failed: nil), .removed,
                       "found on this network, but its key is gone: Add Again, not Connect")
        XCTAssertEqual(RemoteViewerRow.of(c, connected: false, route: nil, nearby: false, failed: .relayDown), .removed)
        c.removed = nil
        XCTAssertEqual(RemoteViewerRow.of(c, connected: false, route: nil, nearby: true, failed: nil, refused: true), .removed,
                       "refused this run (unauthenticated): said the same, the key kept")
        XCTAssertEqual(RemoteViewerRow.of(c, connected: true, route: .local, nearby: true, failed: nil, refused: true), .connected(.local))
        // records from before 1.1 have no `removed`
        let old = #"{"id":"x","deviceID":"d","name":"Old","port":1,"addresses":[]}"#
        XCTAssertNil(try JSONDecoder().decode(RemoteComputer.self, from: Data(old.utf8)).removed)
    }
}
