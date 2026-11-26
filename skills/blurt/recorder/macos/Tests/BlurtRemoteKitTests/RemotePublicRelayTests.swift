// Blurt's public relay (docs/design/remote-go-between.md §The public relay): the parts on their own (tickets, leases, the picture's ceiling,
// the files budget), then a viewer and the in-process host of RemoteViewerSessionTests end to end through the real servers on this
// machine: `tools/remote-relay/server.js` as the go-between (BUDGET=1, TICKET_SECRET, PUBLIC_RELAY) and `public.js` as the relay. The
// tests start both on free ports and stop exactly the processes they started; without node they're skipped. Nothing is captured and no
// input is posted: the host is the tests' own.
import CryptoKit
import Network
import XCTest
@testable import BlurtRemoteKit

final class RemotePublicRelayTests: XCTestCase {
    // MARK: the parts

    private static var vectors: [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../../../../tests/remote-vectors/vectors.json").standardizedFileURL
        let o = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any]
        return o?["publicRelay"] as? [String: Any] ?? [:]
    }

    func testTheWireFromTheVectors() throws {
        let v = Self.vectors
        XCTAssertEqual(v["leaseAsk"] as? String, RemotePublicRelay.lease(true))
        XCTAssertEqual(v["leaseFree"] as? String, RemotePublicRelay.lease(false))
        let answers = try XCTUnwrap(v["leaseAnswers"] as? [String]).map(RemotePublicRelay.leaseAnswer)
        XCTAssertEqual(answers, [.granted(ttl: 75), .refused("full"), .refused("prefix"), .refused("expired")])
        guard case let .ticket(t)? = RemotePublicRelay.ticketAnswer(try XCTUnwrap(v["ticketAnswer"] as? String)) else { return XCTFail() }
        XCTAssertEqual(t.relay, "wss://relay.blurt.work")
        XCTAssertEqual(t.room.count, 43)
        XCTAssertTrue(RemotePublicRelay.allowed(t.relay))
        XCTAssertFalse(RemotePublicRelay.allowed("wss://relay.example.com"))
        XCTAssertTrue(RemotePublicRelay.allowed("ws://127.0.0.1:1", testing: "ws://127.0.0.1:1"))
        let refused = try XCTUnwrap(v["ticketRefused"] as? [String]).map(RemotePublicRelay.ticketAnswer)
        XCTAssertEqual(refused, [.refused("off"), .refused("alone"), .refused("limit"), .refused("bad")])
        XCTAssertNil(RemotePublicRelay.ticketAnswer(#"{"lease":true}"#))
        XCTAssertNil(RemotePublicRelay.leaseAnswer(#"{"ticket":{"error":"off"}}"#))
        // a room for one session, and the path with its ticket
        XCTAssertEqual(RemotePublicRelay.newRoom().count, 43)
        let c = try XCTUnwrap(RemotePublicRelay.connection(address: t.relay, room: t.room, role: "phone", ticket: t.phone))
        guard case let .url(u) = c.endpoint else { return XCTFail() }
        XCTAssertEqual(u.absoluteString, "wss://relay.blurt.work/v1/\(t.room)/phone?t=\(t.phone)")
        XCTAssertNil(RemotePublicRelay.connection(address: t.relay, room: t.room, role: "phone", ticket: "a&b=c"))
    }

    func testThePictureIsDataSaversAtMost() {
        let asked = RemoteScreenPlan(.sharp, local: true, window: RemotePixelSize(width: 2880, height: 1800))
            .request(display: nil, features: nil, window: RemotePixelSize(width: 2880, height: 1800))
        let r = RemotePublicRelay.clamp(asked)
        XCTAssertEqual(r.width, 1280)
        XCTAssertEqual(r.height, 800)
        XCTAssertEqual(r.box.width, 1280)
        XCTAssertEqual(r.box.height, 800)
        XCTAssertEqual(r.bitrate, 1_000_000)
        XCTAssertEqual(r.fps, 15)
        // Data Saver's own plan passes as it is
        let saver = RemoteScreenPlan(.saver, local: false, window: RemotePixelSize(width: 1600, height: 1000))
            .request(display: nil, features: nil, window: RemotePixelSize(width: 1600, height: 1000))
        XCTAssertEqual(RemotePublicRelay.clamp(saver), saver)
    }

    func testFilesBudget() {
        let now = Date(timeIntervalSince1970: 1_764_000_000)
        var f = RemotePublicFiles()
        XCTAssertEqual(f.decide(5_000_000, device: "a", now: now), .send)
        XCTAssertEqual(f.decide(35_000_000, device: "a", now: now), .ask)
        f.spend(35_000_000, device: "a", now: now)
        XCTAssertEqual(f.left("a", now: now), 15_000_000)
        XCTAssertEqual(f.decide(16_000_000, device: "a", now: now), .over)
        XCTAssertEqual(f.decide(15_000_000, device: "a", now: now), .send)
        XCTAssertEqual(f.decide(35_000_000, device: "b", now: now), .ask, "per device")
        XCTAssertEqual(f.decide(51_000_000, device: "b", now: now), .over)
        // the next UTC day starts over
        let tomorrow = now.addingTimeInterval(86400)
        XCTAssertEqual(f.decide(35_000_000, device: "a", now: tomorrow), .ask)
        f.spend(1, device: "a", now: tomorrow)
        XCTAssertEqual(f.sent, ["a": 1])
    }

    /// The lease as the host keeps it: asked when the picture is wanted, said busy once and asked again, granted, renewed, given back; and
    /// the picture stops after the device has been quiet too long.
    func testLease() {
        let q = DispatchQueue(label: "lease")
        let lock = NSLock()
        var sent: [String] = [], events: [RemotePictureLease.Event] = []
        let l = RemotePictureLease(queue: q) { t in lock.withLock { sent.append(t) } }
        l.askAgain = 0.3
        l.renewEvery = 0.4
        l.untouched = 2
        l.onEvent = { e in lock.withLock { events.append(e) } }
        let ask = RemotePublicRelay.lease(true), free = RemotePublicRelay.lease(false)
        func wait(_ s: Double) { Thread.sleep(forTimeInterval: s); q.sync {} }

        l.want(true)
        wait(0.05)
        XCTAssertEqual(lock.withLock { sent }, [ask])
        l.heard(#"{"lease":{"ok":false,"why":"full"}}"#)
        wait(0.05)
        XCTAssertEqual(lock.withLock { events }, [.refused("full")])
        wait(0.35)
        XCTAssertEqual(lock.withLock { sent }, [ask, ask], "asked again by itself")
        l.heard(#"{"lease":{"ok":false,"why":"full"}}"#)
        wait(0.05)
        XCTAssertEqual(lock.withLock { events }, [.refused("full")], "busy is said once")
        wait(0.3)
        l.heard(#"{"lease":{"ok":true,"ttl":75}}"#)
        wait(0.05)
        XCTAssertEqual(lock.withLock { events }, [.refused("full"), .granted])
        // renewed while it runs (and the device keeps touching)
        l.touched()
        wait(0.9)
        l.touched()
        XCTAssertGreaterThanOrEqual(lock.withLock { sent }.filter { $0 == ask }.count, 4)
        // off: given back at once
        l.want(false)
        wait(0.05)
        XCTAssertEqual(lock.withLock { sent }.last, free)
        // wanted again, then nothing from the device for `untouched`: stopped, given back
        lock.withLock { sent = []; events = [] }
        l.want(true)
        wait(0.05)
        l.heard(#"{"lease":{"ok":true,"ttl":75}}"#)
        wait(2.4)
        XCTAssertEqual(lock.withLock { events }, [.granted, .untouched])
        XCTAssertEqual(lock.withLock { sent }.first, ask)
        XCTAssertEqual(lock.withLock { sent }.last, free)
        // the session's end gives back what's held, and nothing is asked after it
        l.want(true)
        wait(0.05)
        l.heard(#"{"lease":{"ok":true,"ttl":75}}"#)
        l.end()
        wait(0.6)
        XCTAssertEqual(lock.withLock { sent }.last, free)
        let n = lock.withLock { sent.count }
        l.want(true)
        wait(0.4)
        XCTAssertEqual(lock.withLock { sent.count }, n)
    }

    // MARK: end to end, through server.js and public.js

    /// node and the relay's dependencies, or the test is skipped
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("../../../..").standardizedFileURL
    private static var relayDir: URL { root.appendingPathComponent("tools/remote-relay") }
    private static var node: String? {
        ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The go-between and the public relay, as this machine's own processes on free ports.
    final class Servers {
        let secret = RemoteCrypto.base64url(RemoteCrypto.newKey())
        let meet: UInt16, relay: UInt16
        private var procs: [Process] = []
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-public-relay-test-" + UUID().uuidString)
        var goBetween: String { "ws://127.0.0.1:\(meet)" }
        var publicRelay: String { "ws://127.0.0.1:\(relay)" }

        /// `relayFor`: what the go-between names in its tickets (a dead port, for a relay that isn't there)
        init(leases: Int, relayFor: String? = nil, startRelay: Bool = true) throws {
            guard let node = RemotePublicRelayTests.node, FileManager.default.fileExists(atPath: RemotePublicRelayTests.relayDir.appendingPathComponent("node_modules/ws").path)
            else { throw XCTSkip("node or tools/remote-relay/node_modules missing") }
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            meet = Self.freePort()
            relay = Self.freePort()
            if startRelay {
                try run(node, "public.js", ["TICKET_SECRETS": secret, "PORT": "\(relay)", "HOST": "127.0.0.1", "LEASES": "\(leases)", "COUNT_MS": "600000"])
            }
            try run(node, "server.js", ["BUDGET": "1", "TICKET_SECRET": secret, "PUBLIC_RELAY": relayFor ?? publicRelay, "PORT": "\(meet)", "HOST": "127.0.0.1"])
            guard Self.answers(meet), !startRelay || Self.answers(relay) else { stop(); throw XCTSkip("the servers didn't start: \(logs.path)") }
        }

        private func run(_ node: String, _ script: String, _ env: [String: String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: node)
            p.arguments = [script]
            p.currentDirectoryURL = RemotePublicRelayTests.relayDir
            p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
            let log = logs.appendingPathComponent(script + ".log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let h = try FileHandle(forWritingTo: log)
            p.standardOutput = h
            p.standardError = h
            try p.run()
            procs.append(p)
        }

        /// exactly the processes started here
        func stop() {
            for p in procs where p.isRunning { p.terminate() }
            for p in procs { p.waitUntilExit() }
            procs = []
        }

        static func freePort() -> UInt16 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var a = sockaddr_in()
            a.sin_family = sa_family_t(AF_INET)
            a.sin_addr.s_addr = inet_addr("127.0.0.1")
            a.sin_port = 0
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) } }
            _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
            return UInt16(bigEndian: a.sin_port)
        }

        /// `GET /` answers (both servers say what they are)
        static func answers(_ port: UInt16) -> Bool {
            let end = Date().addingTimeInterval(8)
            while Date() < end {
                let done = DispatchSemaphore(value: 0)
                var ok = false
                URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)/")!) { _, r, _ in
                    ok = (r as? HTTPURLResponse)?.statusCode == 200
                    done.signal()
                }.resume()
                _ = done.wait(timeout: .now() + 2)
                if ok { return true }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return false
        }

        /// A ticket as the go-between mints it (src/ticket.js), for a room of the test's own
        func ticket(room: String, role: String) -> String {
            let exp = String(Int(Date().timeIntervalSince1970) + 60)
            let tag = RemoteCrypto.base64url(Data((0..<9).map { _ in UInt8.random(in: 0...255) }))
            let mac = HMAC<SHA256>.authenticationCode(for: Data("blurt-ticket-1|\(room)|\(role)|\(exp)|\(tag)".utf8), using: SymmetricKey(data: Data(secret.utf8)))
            return "\(exp).\(tag).\(RemoteCrypto.base64url(Data(Data(mac).prefix(16))))"
        }
    }

    /// Another pair in the relay holding the one picture lease (LEASES=1) until it gives it back.
    final class Occupant {
        let q = DispatchQueue(label: "occupant")
        let mac: RemoteChannel
        let phone: NWConnection
        private let lock = NSLock()
        private var _held = false
        var held: Bool { lock.withLock { _held } }

        init(_ servers: Servers) throws {
            let room = RemotePublicRelay.newRoom()
            let m = try XCTUnwrap(RemotePublicRelay.connection(address: servers.publicRelay, room: room, role: "mac", ticket: servers.ticket(room: room, role: "mac")))
            mac = RemoteChannel(connection: m, role: .mac(lookup: { _ in nil }), relay: true, standby: true, queue: q)
            phone = try XCTUnwrap(RemotePublicRelay.connection(address: servers.publicRelay, room: room, role: "phone", ticket: servers.ticket(room: room, role: "phone")))
            mac.onText = { [weak self] t in
                guard let self, let a = RemotePublicRelay.leaseAnswer(t) else { return }
                self.lock.withLock { self._held = a == .granted(ttl: 75) }
            }
        }

        func hold() {
            mac.start()
            Thread.sleep(forTimeInterval: 0.3)
            phone.start(queue: q)
            Thread.sleep(forTimeInterval: 0.3)
            mac.sendText(RemotePublicRelay.lease(true))
        }

        func giveBack() {
            mac.sendText(RemotePublicRelay.lease(false))
            lock.withLock { _held = false }
        }

        func stop() {
            mac.close()
            phone.cancel()
        }
    }

    private func until(_ seconds: Double, _ ok: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !ok(), Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        return ok()
    }

    private func pair(_ servers: Servers, publicTest: String?) throws -> (RemoteViewerSessionTests.Host, RemoteViewerLink, RemoteViewerSessionTests.Viewer) {
        let host = try RemoteViewerSessionTests.Host(pictures: try RemoteViewerSessionTests.pictures())
        _ = host.start()
        host.goPublic = true
        host.publicTest = publicTest
        let key = RemoteCrypto.newKey()
        host.pairedID = "viewer-1"
        host.pairedKey = key
        host.standby(relay: servers.goBetween)
        Thread.sleep(forTimeInterval: 0.3)       // the host waits in the room first, as it always does
        let computer = RemoteComputer(id: "test-host", deviceID: "viewer-1", name: "Test Host", port: 0, addresses: [], relayAddress: servers.goBetween)
        let link = RemoteViewerLink(computer: computer, key: key, deviceName: "Test Mac", relayOnly: servers.goBetween, callbacks: DispatchQueue(label: "cb"))
        link.moveOnRelay = true
        link.publicRelayTest = publicTest
        return (host, link, RemoteViewerSessionTests.Viewer(link))
    }

    /// No direct path at the go-between: the session goes on at the public relay. Keys pass; the picture waits for a lease while the only
    /// one (LEASES=1) is someone else's, the viewer hears "busy", and the picture comes by itself once that one is given back.
    func testLandsOnThePublicRelayKeysPassAndThePictureWaitsForALease() throws {
        let servers = try Servers(leases: 1)
        defer { servers.stop() }
        let occupant = try Occupant(servers)
        occupant.hold()
        defer { occupant.stop() }
        XCTAssertTrue(until(3) { occupant.held }, "the other pair holds the lease")

        let (host, link, v) = try pair(servers, publicTest: servers.publicRelay)
        link.start()
        defer { link.stop(); host.stop() }

        XCTAssertTrue(until(15) { v.states.last == .connected }, "\(v.states) \(host.log)")
        XCTAssertEqual(link.route, .publicRelay)
        XCTAssertTrue(host.log.contains("ticket ok"), "\(host.log)")
        XCTAssertTrue(host.log.contains("room open true"), "\(host.log)")
        XCTAssertTrue(host.log.contains("session public"), "\(host.log)")
        XCTAssertTrue(host.log.contains { $0.hasPrefix("hello Test Mac") && $0.contains(RemoteFeature.publicRelay) }, "\(host.log)")
        XCTAssertFalse(v.states.contains(.away(.noDirect)), "never said no direct: \(v.states)")

        // keys, while the picture waits
        link.send(.key(RemoteChord([], "A"), down: nil))
        XCTAssertTrue(until(5) { host.log.contains("key A tap") }, "\(host.log)")
        // the picture: clamped to Data Saver's, then busy (the one lease is taken)
        XCTAssertTrue(until(5) { host.log.contains("asked 1280x720 1000000 15 window 1600x900") }, "\(host.log)")
        XCTAssertTrue(until(5) { v.heard.contains("screenFailed busy") }, "\(v.heard) \(host.log)")
        XCTAssertEqual(v.screen.decoded, 0)
        // given back there: granted here at the next ask, and the picture comes
        occupant.giveBack()
        XCTAssertTrue(until(5) { host.log.contains("lease granted") }, "\(host.log)")
        XCTAssertTrue(until(10) { v.screen.decoded >= 12 }, "decoded \(v.screen.decoded) \(host.log)")
        XCTAssertEqual(link.route, .publicRelay)
        // and keys still pass
        link.send(.key(RemoteChord([], "B"), down: nil))
        XCTAssertTrue(until(5) { host.log.contains("key B tap") }, "\(host.log)")
    }

    /// The relay the go-between names isn't there: the host can't open its room within 5 s, so the viewer hears `noDirect` alone and
    /// shows the no-direct line, and nothing tries again inside the wait.
    func testDeadPublicRelayIsNoDirect() throws {
        let dead = "ws://127.0.0.1:\(Servers.freePort())"
        let servers = try Servers(leases: 10, relayFor: dead, startRelay: false)
        defer { servers.stop() }
        let (host, link, v) = try pair(servers, publicTest: dead)
        link.start()
        defer { link.stop(); host.stop() }

        XCTAssertTrue(until(15) { v.states.last == .away(.noDirect) }, "\(v.states) \(host.log)")
        XCTAssertTrue(host.log.contains("room open false"), "\(host.log)")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(v.states.last, .away(.noDirect))
        XCTAssertFalse(v.states.contains(.connected))
        XCTAssertEqual(host.log.filter { $0.hasPrefix("session") }.count, 1, "no second try: \(host.log)")
    }

    /// The host sent the viewer to a relay that never answers (it takes the connection and says nothing): the viewer gives up after 5 s
    /// with the no-direct line, and doesn't loop.
    func testViewerGivesUpOnTheRoomInFiveSeconds() throws {
        let servers = try Servers(leases: 10)
        defer { servers.stop() }
        // a black hole: the TCP connection is taken, the upgrade never answered
        let hole = try NWListener(using: .tcp, on: .any)
        let hq = DispatchQueue(label: "hole")
        var held: [NWConnection] = []
        hole.newConnectionHandler = { c in held.append(c); c.start(queue: hq) }
        let ready = DispatchSemaphore(value: 0)
        hole.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        hole.start(queue: hq)
        _ = ready.wait(timeout: .now() + 3)
        defer { hole.cancel(); hq.sync { held.forEach { $0.cancel() } } }
        let lie = "ws://127.0.0.1:\(hole.port!.rawValue)"

        let (host, link, v) = try pair(servers, publicTest: lie)
        host.publicTest = servers.publicRelay
        host.publicLie = lie
        link.start()
        defer { link.stop(); host.stop() }

        XCTAssertTrue(until(12) { host.log.contains("noDirect") }, "\(host.log)")
        let said = Date()
        XCTAssertTrue(until(7) { v.states.last == .away(.noDirect) }, "\(v.states)")
        let took = Date().timeIntervalSince(said)
        XCTAssertGreaterThan(took, 4.5, "it waited for the room")
        XCTAssertLessThan(took, 6.0, "and gave up after 5 s")
        XCTAssertTrue(link.lostWhy.contains("public relay"), link.lostWhy)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(v.states.last, .away(.noDirect))
        XCTAssertEqual(host.log.filter { $0.hasPrefix("session") }.count, 1, "no loop: \(host.log)")
    }
}
