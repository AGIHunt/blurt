// The go-between end to end (docs/design/remote-go-between.md): a phone and a host meet over a WebSocket relay that keeps the go-between's
// budget, open the direct UDP path, move their streams onto it, and go on with keys, a big message each way and the relay gone, while the
// relay carries only the first few KiB.
//
// The relay is a small one in this process with the same limits as `BUDGET=1 node tools/remote-relay/server.js`; with
// BLURT_TEST_RELAY=ws://127.0.0.1:<port> (that server, or wrangler dev of src/meet.js) the test runs through it instead.
import Network
import XCTest
@testable import BlurtRemoteKit

final class RemoteMoveTests: XCTestCase {
    /// One room, the first connection the host's, the second the phone's, with the go-between's limits per connection: 16 KiB a message,
    /// 96 KiB in all, 24 KiB in any 5 s; past one, both get 4003.
    private final class Relay {
        let listener: NWListener
        let q = DispatchQueue(label: "relay")
        private(set) var peers: [NWConnection] = []
        private var spent: [ObjectIdentifier: (total: Int, recent: [(Double, Int)])] = [:]
        private let lock = NSLock()
        private var _carried = 0
        private var _overBudget = false
        var carried: Int { lock.lock(); defer { lock.unlock() }; return _carried }
        var overBudget: Bool { lock.lock(); defer { lock.unlock() }; return _overBudget }

        init() throws {
            let params = NWParameters.tcp
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            listener = try NWListener(using: params, on: .any)
            listener.newConnectionHandler = { [weak self] c in self?.joined(c) }
        }

        func start() -> UInt16 {
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.start(queue: q)
            _ = ready.wait(timeout: .now() + 3)
            return listener.port!.rawValue
        }

        private func joined(_ c: NWConnection) {
            peers.append(c)
            c.start(queue: q)
            receive(c)
        }

        private func receive(_ c: NWConnection) {
            c.receiveMessage { [weak self] data, ctx, _, err in
                guard let self, err == nil else { return }
                if let m = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata, m.opcode == .close {
                    // one leaving: the other hears it, as from the real relay
                    return self.peers.filter { $0 !== c }.forEach { self.close($0, 4000) }
                }
                if let data, !data.isEmpty {
                    guard self.spend(c, data.count) else {
                        self.lock.lock(); self._overBudget = true; self.lock.unlock()
                        return self.peers.forEach { self.close($0, 4003) }
                    }
                    self.lock.lock(); self._carried += data.count; self.lock.unlock()
                    for o in self.peers where o !== c {
                        let ctx = NWConnection.ContentContext(identifier: "b", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
                        o.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent)
                    }
                }
                self.receive(c)
            }
        }

        private func spend(_ c: NWConnection, _ n: Int) -> Bool {
            let now = CACurrentMediaTime()
            var s = spent[ObjectIdentifier(c)] ?? (0, [])
            s.total += n
            s.recent = s.recent.filter { now - $0.0 < 5 } + [(now, n)]
            spent[ObjectIdentifier(c)] = s
            return n <= 16 * 1024 && s.total <= 96 * 1024 && s.recent.reduce(0) { $0 + $1.1 } <= 24 * 1024
        }

        func close(_ c: NWConnection, _ code: UInt16) {
            let m = NWProtocolWebSocket.Metadata(opcode: .close)
            m.closeCode = .privateCode(code)
            let ctx = NWConnection.ContentContext(identifier: "close", metadata: [m])
            c.send(content: nil, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
        }

        /// the relay goes away: both WebSockets drop
        func stop() {
            listener.cancel()
            peers.forEach { $0.cancel() }
        }
    }

    /// The host's side of a session as RemoteServer runs it, cut down to what moving needs: the phone's packets on a UDP listener, `udpOK`
    /// when the first one opens, then the move.
    private final class Host {
        let udp: NWListener
        let q = DispatchQueue(label: "host")
        var channel: RemoteChannel!
        private var saw = false
        private let lock = NSLock()
        private var _keys: [String] = []
        private var _big: [Int] = []
        var keys: [String] { lock.lock(); defer { lock.unlock() }; return _keys }
        var big: [Int] { lock.lock(); defer { lock.unlock() }; return _big }
        var onHello: (() -> Void)?

        init() throws {
            udp = try NWListener(using: .udp, on: .any)
        }

        func start(relay: String, key: Data) -> UInt16 {
            let ready = DispatchSemaphore(value: 0)
            udp.newConnectionHandler = { [weak self] c in
                guard let self else { return }
                c.start(queue: self.q)
                self.receive(c)
            }
            udp.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            udp.start(queue: q)
            _ = ready.wait(timeout: .now() + 3)
            let c = RemoteRelay.connection(address: relay, room: RemoteRelay.room(key: key), role: "mac")!
            channel = RemoteChannel(connection: c, role: .mac(lookup: { $0 == "dev" ? key : nil }), relay: true, standby: true)
            channel.onControl = { [weak self] d in
                guard let self, let m = try? JSONDecoder().decode(ToMac.self, from: d) else { return }
                switch m {
                case let .hello(_, _, _, features):
                    XCTAssertEqual(features, ["move"])
                    self.channel.enableMove()
                    self.channel.send(ToPhone.session(RemoteSessionInfo(macName: "Test", udpPort: self.udp.port!.rawValue, udpSession: 7, canControl: true,
                                                                        version: "test", relay: RemoteRelay.goBetween, features: ["move"])))
                    // too big for the go-between before the move: it waits for the direct path
                    self.channel.send(ToPhone.cursorShape(png: Data(count: 40_000), hotX: 0, hotY: 0, width: 16, height: 16))
                    self.onHello?()
                case let .key(c, _):
                    self.lock.lock(); self._keys.append(c.key); self.lock.unlock()
                case let .text(t):
                    self.lock.lock(); self._big.append(t.utf8.count); self.lock.unlock()
                case let .ping(t): self.channel.send(ToPhone.pong(t))
                default: break
                }
            }
            channel.onProbe = { [weak self] d in self?.channel.sendDatagram(.probe, d) }
            channel.start()
            return udp.port!.rawValue
        }

        private func receive(_ c: NWConnection) {
            c.receiveMessage { [weak self] data, _, _, err in
                guard let self, err == nil, let data else { return }
                self.channel.queue.async {
                    guard self.channel.packet(data) else { return }
                    self.channel.useFlow(c)
                    if !self.saw {
                        self.saw = true
                        self.channel.send(ToPhone.udpOK)
                        self.channel.sendDatagram(.probe, Data(count: 8))
                        self.channel.udpConfirmed()
                    }
                }
                self.receive(c)
            }
        }
    }

    private func address() throws -> (String, Relay?) {
        if let a = ProcessInfo.processInfo.environment["BLURT_TEST_RELAY"], !a.isEmpty { return (a, nil) }
        let r = try Relay()
        return ("ws://127.0.0.1:\(r.start())", r)
    }

    func testTheStreamMovesToUDPAndKeysStillArrive() throws {
        let (relayAddress, relay) = try address()
        let key = RemoteCrypto.newKey()
        let host = try Host()
        let udpPort = host.start(relay: relayAddress, key: key)
        Thread.sleep(forTimeInterval: 0.3)       // the host waits in the room first, as it always does

        let phoneConn = RemoteRelay.connection(address: relayAddress, room: RemoteRelay.room(key: key), role: "phone")!
        let phone = RemoteChannel(connection: phoneConn, role: .phone(PhoneHandshake(id: "dev", paired: key)), relay: true)
        phone.enableMove()      // the phone knows it's on the go-between from the address it dialled
        let sessionUp = expectation(description: "session")
        let movedBoth = expectation(description: "moved")
        movedBoth.assertForOverFulfill = false
        let cursor = expectation(description: "the big message held for the move arrives after it")
        var pongs = 0
        let pongLock = NSLock()
        phone.onOpen = { _ in phone.send(ToMac.hello(device: "Test", micOnPhone: false, nonce: phone.nonce, features: ["move"])) }
        phone.onControl = { d in
            guard let m = try? JSONDecoder().decode(ToPhone.self, from: d) else { return }
            switch m {
            case let .session(i):
                XCTAssertEqual(i.features, ["move"])
                phone.tryDirect([RemoteCandidate(host: "127.0.0.1", port: udpPort)], session: i.udpSession, localPort: 0)
                sessionUp.fulfill()
            case .udpOK: phone.udpConfirmed()
            case let .cursorShape(png, _, _, _, _):
                XCTAssertEqual(png.count, 40_000)
                XCTAssertLessThan(relay?.carried ?? 0, 40_000, "held until the move: it came over UDP")
                cursor.fulfill()
            case .pong:
                pongLock.lock(); pongs += 1; pongLock.unlock()
            default: break
            }
        }
        phone.onMoved = { movedBoth.fulfill() }
        phone.onProbe = { _ in }
        phone.start()
        wait(for: [sessionUp, movedBoth, cursor], timeout: 10)
        let moving = Date().addingTimeInterval(3)
        while !host.channel.moved, Date() < moving { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(host.channel.moved)
        let beforeKeys = relay?.carried ?? 0

        // keys, in order, and a message far bigger than the go-between would ever carry, both ways
        for i in 0..<200 { phone.send(ToMac.key(RemoteChord([], "K\(i)"), down: nil)) }
        phone.send(ToMac.text(String(repeating: "字", count: 100_000)))     // 300 KB: more than the window, queued and sent as acks come
        phone.send(ToMac.key(RemoteChord([], "last"), down: nil))
        let deadline = Date().addingTimeInterval(10)
        while host.keys.count < 201, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(host.keys, (0..<200).map { "K\($0)" } + ["last"])
        XCTAssertEqual(host.big, [300_000])
        if let relay {
            XCTAssertFalse(relay.overBudget)
            XCTAssertEqual(relay.carried, beforeKeys, "nothing more went over the go-between after the move")
            XCTAssertLessThan(relay.carried, 8 * 1024, "the go-between carried only the meeting")
        }

        // the go-between goes away: the session carries on over UDP
        relay?.stop()
        Thread.sleep(forTimeInterval: 0.5)
        phone.send(ToMac.key(RemoteChord([], "after"), down: nil))
        phone.send(ToMac.ping(1))
        let after = Date().addingTimeInterval(5)
        while host.keys.last != "after", Date() < after { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(host.keys.last, "after")
        while Date() < after, (pongLock.withLock { pongs }) == 0 { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertGreaterThan(pongLock.withLock { pongs }, 0)
        phone.close()
        host.channel.close()
        host.udp.cancel()
    }

    /// Without the move the same traffic blows the go-between's budget: the reason the stream moves at all.
    func testWithoutTheMoveTheBudgetEndsIt() throws {
        let (relayAddress, relay) = try address()
        let key = RemoteCrypto.newKey()
        let c = RemoteRelay.connection(address: relayAddress, room: RemoteRelay.room(key: key), role: "mac")!
        let mac = RemoteChannel(connection: c, role: .mac(lookup: { $0 == "dev" ? key : nil }), relay: true, standby: true)
        let closed = expectation(description: "closed")
        mac.onClose = { _ in closed.fulfill() }
        mac.start()
        Thread.sleep(forTimeInterval: 0.3)
        let pc = RemoteRelay.connection(address: relayAddress, room: RemoteRelay.room(key: key), role: "phone")!
        let phone = RemoteChannel(connection: pc, role: .phone(PhoneHandshake(id: "dev", paired: key)), relay: true)
        let phoneClosed = expectation(description: "phone closed")
        phone.onClose = { _ in phoneClosed.fulfill() }
        phone.onOpen = { _ in
            phone.send(ToMac.hello(device: "Test", micOnPhone: false, nonce: phone.nonce))
            for _ in 0..<40 { phone.send(ToMac.text(String(repeating: "a", count: 4000))) }
        }
        phone.start()
        wait(for: [closed, phoneClosed], timeout: 10)
        XCTAssertEqual(phone.relayClose, RemoteRelay.overBudget)
        if let relay { XCTAssertTrue(relay.overBudget) }
        relay?.stop()
    }
}
