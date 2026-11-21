// A Mac viewer and a host end to end (docs/design/remote-desktop-viewer.md): the viewer's link pairs with a host it found nearby (six digits,
// the owner's yes, a new key), opens a session, gets real H.264 frames and decodes them, sends keys and its clipboard and hears the host's;
// then the same through a relay with the public connection service's budget, moving the stream onto the direct path.
//
// The host is cut down to what RemoteServer does for this, in this process: no input is posted and nothing is captured. The relay is a small
// one in this process with the budget of `BUDGET=1 node tools/remote-relay/server.js`; with BLURT_TEST_RELAY=ws://127.0.0.1:<port> the test
// runs through that server instead.
import Network
import XCTest
@testable import BlurtRemoteKit

final class RemoteViewerSessionTests: XCTestCase {
    /// Real frames: tests the iPhone app's decoder runs (apps/ios/BlurtRemoteTests/Fixtures/testsrc.h264, 320 × 180, a keyframe every 6).
    static func pictures() throws -> [(payload: Data, key: Bool)] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../../../../apps/ios/BlurtRemoteTests/Fixtures/testsrc.h264").standardizedFileURL
        let b = [UInt8](try Data(contentsOf: file))
        var starts: [(at: Int, code: Int)] = []
        var i = 0
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 { starts.append((i + 3, i > 0 && b[i - 1] == 0 ? 4 : 3)); i += 3 } else { i += 1 }
        }
        let nals = starts.enumerated().map { n, s in Data(b[s.at..<(n + 1 < starts.count ? starts[n + 1].at - starts[n + 1].code : b.count)]) }
        // a picture's slices together (first_mb_in_slice == 0 starts one), parameter sets with the keyframe
        var pics: [(sets: [Data], nals: [Data], key: Bool)] = [], sets: [Data] = []
        for n in nals {
            let type = Int(n[0] & 0x1F)
            if type == 7 || type == 8 { sets.append(n); continue }
            guard type == 1 || type == 5 else { continue }
            if n[1] & 0x80 != 0 || pics.isEmpty {
                pics.append((type == 5 ? sets : [], [n], type == 5))
                if type == 5 { sets = [] }
            } else {
                pics[pics.count - 1].nals.append(n)
            }
        }
        let out: [(Data, Bool)] = pics.map { p in
            var pic = Data()
            for n in p.nals { withUnsafeBytes(of: UInt32(n.count).bigEndian) { pic.append(contentsOf: $0) }; pic.append(n) }
            return (RemoteVideoPayload.pack(crop: .whole, parameterSets: p.sets, picture: pic), p.key)
        }
        return out
    }

    /// The host's side as RemoteServer runs it for a viewer, without posting input or capturing anything.
    final class Host {
        let tcp: NWListener
        let udp: NWListener
        let q = DispatchQueue(label: "test.host")
        private(set) var channel: RemoteChannel?
        private let lock = NSLock()
        private var _log: [String] = []
        var log: [String] { lock.withLock { _log } }
        private(set) var window: RemotePixelSize?
        var pairedID: String?
        var pairedKey: Data?
        var digits: String?
        private var captured = false
        private var saw = false
        private var sending = false
        private var relay = false
        /// the public connection service's case where the direct path never opens: the session, then `noDirect`, then the end
        var noDirect = false
        /// what the owner does with the pairing question: yes, no after a moment, or nothing until the host gives up asking (a bare close
        /// either way, as RemoteServer's `answerPairing(false)`)
        enum Answer { case yes, no, none(closeAfter: Double) }
        var answer = Answer.yes
        /// connections are taken and dropped at once until then (a host not up yet)
        var deafUntil: Date?
        /// the host removes this viewer this long after its session began (its owner's Remove)
        var removeAfter: Double?
        let pictures: [(payload: Data, key: Bool)]

        init(pictures: [(payload: Data, key: Bool)]) throws {
            tcp = try NWListener(using: .tcp, on: .any)
            udp = try NWListener(using: .udp, on: .any)
            self.pictures = pictures
        }

        func note(_ s: String) { lock.withLock { _log.append(s) } }

        func start() -> (tcp: UInt16, udp: UInt16) {
            let ready = DispatchSemaphore(value: 0)
            udp.newConnectionHandler = { [weak self] c in
                guard let self else { return }
                c.start(queue: self.q)
                self.receive(c)
            }
            udp.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            udp.start(queue: q)
            tcp.newConnectionHandler = { [weak self] c in
                guard let self else { return }
                if let d = self.deafUntil, Date() < d { c.start(queue: self.q); return c.cancel() }
                self.wire(c, relay: false)
            }
            tcp.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            tcp.start(queue: q)
            _ = ready.wait(timeout: .now() + 3)
            _ = ready.wait(timeout: .now() + 3)
            return (tcp.port!.rawValue, udp.port!.rawValue)
        }

        /// The owner's relay, or the go-between: one waiting connection in the paired key's room.
        func standby(relay address: String) {
            guard let key = pairedKey, let c = RemoteRelay.connection(address: address, room: RemoteRelay.room(key: key), role: "mac") else { return }
            wire(c, relay: true)
        }

        private func lookup(_ id: String) -> Data? {
            if id == pairedID { return pairedKey }
            // nearby pairing: only on the network listener, never over a relay
            return !relay && RemoteNearby.isNearby(id) ? RemoteNearby.key : nil
        }

        private func wire(_ c: NWConnection, relay: Bool) {
            self.relay = relay
            let ch = RemoteChannel(connection: c, role: .mac(lookup: { [weak self] in self?.lookup($0) }), relay: relay, standby: relay, queue: q)
            channel = ch
            var id: String?
            ch.onOpen = { id = $0 }
            ch.onControl = { [weak self, weak ch] d in
                guard let self, let ch, let m = try? JSONDecoder().decode(ToMac.self, from: d) else { return }
                self.handle(m, ch, id: id ?? "")
            }
            ch.onProbe = { [weak ch] d in ch?.sendDatagram(.probe, d) }
            ch.onVideoFeedback = { _ in }
            ch.start()
        }

        private var newKey: Data?

        private func handle(_ m: ToMac, _ ch: RemoteChannel, id: String) {
            switch m {
            case let .hello(device, _, nonce, features):
                note("hello \(device) \((features ?? []).joined(separator: ","))")
                if (features ?? []).contains(RemoteFeature.move), relay { ch.enableMove() }
                if id != pairedID {
                    // a new one: the six digits for the owner, who says yes here; then a key of its own
                    guard RemoteNearby.isNearby(id), let n = nonce, let check = ch.check(revealing: n) else { return ch.close() }
                    digits = check
                    ch.send(ToPhone.pairingWaits)
                    switch answer {
                    case .yes:
                        let k = RemoteCrypto.newKey()
                        newKey = k
                        q.asyncAfter(deadline: .now() + 0.3) { ch.send(ToPhone.newKey(k)) }
                        pairedID = id
                    case .no: q.asyncAfter(deadline: .now() + 0.3) { ch.close() }
                    case let .none(after): q.asyncAfter(deadline: .now() + after) { ch.close() }
                    }
                    return
                }
                session(ch)
            case .keyStored:
                pairedKey = newKey
                note("keyStored")
                session(ch)
            case let .screen(r):
                window = r?.window
                note("screen \(r?.window.map { "\($0.width)x\($0.height)" } ?? "none")")
                guard r != nil else { sending = false; return }
                ch.send(ToPhone.screenView(width: 320, height: 180, codec: RemoteVideoCodec.h264, display: "1", features: nil))
                sending = true
                frames(ch, from: 0)
            case let .key(c, down):
                note("key \(c.key) \(down.map { $0 ? "down" : "up" } ?? "tap")")
            case let .mods(mm):
                note("mods \(mm.rawValue)")
            case let .keysCaptured(on):
                captured = on
                note("captured \(on)")
                // the host's clipboard changes while captured: the viewer hears it
                if on { q.asyncAfter(deadline: .now() + 0.1) { ch.send(ToPhone.clipboard("from the host")) } }
            case let .clipboard(t):
                note("clipboard \(t.utf8.count)")
            case let .pointerTo(x, y, seq):
                note("pointer \(x),\(y) \(seq ?? 0)")
            case let .ping(t):
                ch.send(ToPhone.pong(t))
            default: break
            }
        }

        private func session(_ ch: RemoteChannel) {
            if noDirect {
                ch.send(ToPhone.session(RemoteSessionInfo(macName: "Test Host", udpPort: 9, udpSession: 7, canControl: true, version: "test",
                                                          relay: "ws://relay", platform: "mac", features: [RemoteFeature.move, RemoteFeature.viewer])))
                note("session")
                q.asyncAfter(deadline: .now() + 0.5) {
                    self.note("noDirect")
                    ch.send(ToPhone.noDirect)
                    self.q.asyncAfter(deadline: .now() + 0.3) { ch.close() }
                }
                return
            }
            ch.send(ToPhone.session(RemoteSessionInfo(macName: "Test Host", udpPort: udp.port!.rawValue, udpSession: 7, canControl: true, version: "test",
                                                      candidates: [RemoteCandidate(host: "127.0.0.1", port: udp.port!.rawValue)],
                                                      relay: relay ? "ws://relay" : nil, platform: "windows",
                                                      features: [RemoteFeature.move, RemoteFeature.viewer])))
            ch.send(ToPhone.displays([RemoteDisplay(id: "1", name: "One", x: 0, y: 0, width: 320, height: 180, main: true),
                                      RemoteDisplay(id: "2", name: "Two", x: 320, y: 0, width: 320, height: 180, main: false)]))
            if let r = removeAfter {
                q.asyncAfter(deadline: .now() + r) {
                    // forgotten here, then told: what comes next with the old key is refused
                    self.pairedID = nil
                    self.pairedKey = nil
                    ch.send(ToPhone.removed)
                    self.q.asyncAfter(deadline: .now() + 0.2) { ch.close() }
                }
            }
        }

        /// The fixture's frames, over and over, as datagrams once the viewer's path is known (or in the stream on the same network until then).
        private var frameID: UInt32 = 0
        private func frames(_ ch: RemoteChannel, from i: Int) {
            guard sending else { return }
            let p = pictures[i % pictures.count]
            frameID &+= 1
            for piece in RemoteVideoPacket.split(p.payload, frame: frameID, keyframe: p.key, captured: CACurrentMediaTime()) {
                ch.sendDatagram(.video, piece.encoded())
            }
            q.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in self?.frames(ch, from: i + 1) }
        }

        private func receive(_ c: NWConnection) {
            c.receiveMessage { [weak self] data, _, _, err in
                guard let self, err == nil, let data, let ch = self.channel else { return }
                self.q.async {
                    guard ch.packet(data) else { return }
                    ch.useFlow(c)
                    if !self.saw {
                        self.saw = true
                        ch.send(ToPhone.udpOK)
                        if ch.isRelay {
                            ch.sendDatagram(.probe, Data(count: 8))
                            ch.udpConfirmed()
                        }
                    }
                }
                self.receive(c)
            }
        }

        func stop() {
            sending = false
            channel?.close()
            tcp.cancel()
            udp.cancel()
        }
    }

    /// The viewer: a link, the picture it decodes, and what the host said.
    final class Viewer {
        let link: RemoteViewerLink
        let screen: RemoteViewerScreen
        private let lock = NSLock()
        private var _states: [RemoteViewerLink.State] = []
        private var _heard: [String] = []
        var states: [RemoteViewerLink.State] { lock.withLock { _states } }
        var heard: [String] { lock.withLock { _heard } }
        var stored: Data?
        let callbacks = DispatchQueue(label: "test.viewer")

        init(_ link: RemoteViewerLink) {
            self.link = link
            screen = RemoteViewerScreen(link: link)
            link.onVideo = { [weak screen] in screen?.packet($0) }
            link.onState = { [weak self] s in
                guard let self else { return }
                self.lock.withLock { self._states.append(s) }
                if s == .connected {
                    let window = RemotePixelSize(width: 1600, height: 900)
                    self.screen.start(RemoteScreenPlan(.auto, local: true, window: window).request(display: nil, features: RemoteViewerScreen.features, window: window))
                }
            }
            link.onMessage = { [weak self] m in
                guard let self else { return }
                switch m {
                case let .screenView(_, _, codec, _, features): self.screen.view(codec: codec, features: features)
                case let .clipboard(t): self.lock.withLock { self._heard.append("clipboard \(t)") }
                case let .displays(list): self.lock.withLock { self._heard.append("displays \(list.count)") }
                case let .session(i): self.lock.withLock { self._heard.append("session \(i.platform ?? "") \((i.features ?? []).joined(separator: ","))") }
                default: break
                }
            }
            link.onNewKey = { [weak self] _, k in self?.stored = k }
        }
    }

    private func until(_ seconds: Double, _ ok: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !ok(), Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        return ok()
    }

    /// The same network: found nearby, paired with six digits and a yes, then the picture, keys and the clipboard both ways.
    func testPairNearbyThenPictureKeysAndClipboard() throws {
        let host = try Host(pictures: try Self.pictures())
        let ports = host.start()
        let computer = RemoteComputer(id: "test-host", deviceID: RemoteNearby.newID(), name: "", port: 0, addresses: [])
        let link = RemoteViewerLink(computer: computer, key: RemoteNearby.key, deviceName: "Test Mac", pairing: true,
                                    endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: ports.tcp)!), callbacks: DispatchQueue(label: "cb"))
        let v = Viewer(link)
        link.start()
        defer { link.stop(); host.stop() }

        // the six digits on both ends are the same
        XCTAssertTrue(until(5) { v.states.contains { if case .waiting = $0 { true } else { false } } }, "\(v.states)")
        guard case let .waiting(check)? = v.states.first(where: { if case .waiting = $0 { true } else { false } }) else { return XCTFail() }
        XCTAssertEqual(check.count, 6)
        XCTAssertEqual(check, host.digits)
        XCTAssertTrue(until(5) { v.states.last == .connected }, "\(v.states)")
        XCTAssertNotNil(v.stored)
        XCTAssertEqual(v.stored, host.pairedKey)
        XCTAssertEqual(link.computer.platform, "windows")
        XCTAssertEqual(link.computer.port, ports.tcp, "the port it was found at, kept to connect again")
        XCTAssertTrue(link.hostTakesViewer)
        XCTAssertTrue(host.log.contains("hello Test Mac move,viewer"))
        XCTAssertTrue(host.log.contains("keyStored"))

        // the picture: asked for at the window's size, real frames decoded
        XCTAssertTrue(until(8) { v.screen.decoded >= 12 }, "decoded \(v.screen.decoded) bytes \(v.screen.bytes) \(host.log)")
        XCTAssertEqual(host.window, RemotePixelSize(width: 1600, height: 900))
        XCTAssertTrue(v.heard.contains("displays 2"))
        XCTAssertTrue(v.heard.contains("session windows move,viewer"))

        // keys as a keyboard sends them, the pointer, then the clipboard while captured
        link.send(.keysCaptured(true))
        link.send(.clipboard("from the viewer"))
        link.send(.mods(RemoteViewerKeys.map(.command, from: .mac, to: .windows, mapping: true)))
        link.send(.key(RemoteChord([], "C"), down: true))
        link.send(.key(RemoteChord([], "C"), down: false))
        link.send(.key(RemoteChord([], "F13"), down: nil))
        link.send(.mods([]))
        let seq = link.pointerTo(x: 0.5, y: 0.25)
        XCTAssertEqual(seq, 1)
        XCTAssertTrue(until(5) { host.log.contains("pointer 0.5,0.25 1") && v.heard.contains("clipboard from the host") }, "\(host.log) \(v.heard)")
        let keys = host.log.filter { $0.hasPrefix("key ") || $0.hasPrefix("mods") || $0.hasPrefix("captured") || $0.hasPrefix("clipboard") }
        XCTAssertEqual(keys, ["captured true", "clipboard 15", "mods 8", "key C down", "key C up", "key F13 tap", "mods 0"])
        link.send(.keysCaptured(false))
        XCTAssertTrue(until(3) { host.log.contains("captured false") })
    }

    private final class Relay {
        let listener: NWListener
        let q = DispatchQueue(label: "relay")
        private var peers: [NWConnection] = []
        private let lock = NSLock()
        private var _carried = 0
        var carried: Int { lock.withLock { _carried } }
        private var spent: [ObjectIdentifier: (total: Int, recent: [(Double, Int)])] = [:]
        private(set) var overBudget = false
        private var _joins = 0
        var joins: Int { lock.withLock { _joins } }

        init() throws {
            let params = NWParameters.tcp
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            listener = try NWListener(using: params, on: .any)
            listener.newConnectionHandler = { [weak self] c in
                guard let self else { return }
                self.lock.withLock { self._joins += 1 }
                self.peers.append(c)
                c.start(queue: self.q)
                self.receive(c)
            }
        }

        func start() -> UInt16 {
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.start(queue: q)
            _ = ready.wait(timeout: .now() + 3)
            return listener.port!.rawValue
        }

        private func receive(_ c: NWConnection) {
            c.receiveMessage { [weak self] data, ctx, _, err in
                guard let self, err == nil else { return }
                if let m = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata, m.opcode == .close {
                    // one leaving: the other hears it, as from the real relay (4001: the host is gone)
                    for o in self.peers where o !== c {
                        let cm = NWProtocolWebSocket.Metadata(opcode: .close)
                        cm.closeCode = .privateCode(4001)
                        o.send(content: nil, contentContext: NWConnection.ContentContext(identifier: "close", metadata: [cm]), isComplete: true,
                               completion: .contentProcessed { _ in o.cancel() })
                    }
                    return
                }
                if let data, !data.isEmpty {
                    let now = CACurrentMediaTime()
                    var s = self.spent[ObjectIdentifier(c)] ?? (0, [])
                    s.total += data.count
                    s.recent = s.recent.filter { now - $0.0 < 5 } + [(now, data.count)]
                    self.spent[ObjectIdentifier(c)] = s
                    if data.count > 16 * 1024 || s.total > 96 * 1024 || s.recent.reduce(0, { $0 + $1.1 }) > 24 * 1024 { self.overBudget = true }
                    self.lock.withLock { self._carried += data.count }
                    for o in self.peers where o !== c {
                        let ctx = NWConnection.ContentContext(identifier: "b", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
                        o.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent)
                    }
                }
                self.receive(c)
            }
        }

        func stop() {
            listener.cancel()
            peers.forEach { $0.cancel() }
        }
    }

    /// Away: through a relay with the public connection service's budget. The stream moves onto the direct path, the picture comes as
    /// datagrams, and a clipboard far over a message's budget goes after the move.
    func testThroughTheBudgetRelay() throws {
        var relay: Relay?
        let address: String
        if let a = ProcessInfo.processInfo.environment["BLURT_TEST_RELAY"], !a.isEmpty { address = a } else {
            let r = try Relay()
            relay = r
            address = "ws://127.0.0.1:\(r.start())"
        }
        let host = try Host(pictures: try Self.pictures())
        _ = host.start()
        let key = RemoteCrypto.newKey()
        host.pairedID = "viewer-1"
        host.pairedKey = key
        host.standby(relay: address)
        Thread.sleep(forTimeInterval: 0.3)       // the host waits in the room first, as it always does
        let computer = RemoteComputer(id: "test-host", deviceID: "viewer-1", name: "Test Host", port: 0, addresses: [], relayAddress: address)
        let link = RemoteViewerLink(computer: computer, key: key, deviceName: "Test Mac", relayOnly: address, callbacks: DispatchQueue(label: "cb"))
        link.moveOnRelay = true
        let v = Viewer(link)
        link.start()
        defer { link.stop(); host.stop(); relay?.stop() }

        XCTAssertTrue(until(8) { v.states.last == .connected }, "\(v.states)")
        XCTAssertTrue(until(10) { link.route == .goBetween }, "route \(String(describing: link.route))")
        XCTAssertTrue(until(10) { v.screen.decoded >= 12 }, "decoded \(v.screen.decoded)")
        let big = String(repeating: "字", count: 21_000)       // 63 KB: four times what one message on the go-between may be
        link.send(.keysCaptured(true))
        link.send(.clipboard(big))
        link.send(.key(RemoteChord([], "KeypadEnter"), down: nil))
        XCTAssertTrue(until(8) { host.log.contains("key KeypadEnter tap") && v.heard.contains("clipboard from the host") }, "\(host.log)")
        XCTAssertTrue(host.log.contains("clipboard \(big.utf8.count)"))
        if let relay {
            XCTAssertFalse(relay.overBudget)
            XCTAssertLessThan(relay.carried, 16 * 1024, "the relay carried only the meeting: \(relay.carried) bytes")
        }
    }

    /// Through the public connection service on a network where the direct path never opens: the host says `noDirect` and ends the
    /// session. The window must say so and stay saying it, never "connecting", and the service isn't asked again inside its 30 s wait.
    func testNoDirectPathIsSaidAndStays() throws {
        let relay = try Relay()
        let address = "ws://127.0.0.1:\(relay.start())"
        let host = try Host(pictures: try Self.pictures())
        _ = host.start()
        host.noDirect = true
        let key = RemoteCrypto.newKey()
        host.pairedID = "viewer-1"
        host.pairedKey = key
        host.standby(relay: address)
        Thread.sleep(forTimeInterval: 0.3)
        let computer = RemoteComputer(id: "test-host", deviceID: "viewer-1", name: "Test Host", port: 0, addresses: [], relayAddress: address)
        let link = RemoteViewerLink(computer: computer, key: key, deviceName: "Test Mac", relayOnly: address, callbacks: DispatchQueue(label: "cb"))
        link.moveOnRelay = true
        let v = Viewer(link)
        link.start()
        defer { link.stop(); host.stop(); relay.stop() }

        // while it meets there, the way being tried is the public connection service
        XCTAssertTrue(until(3) { host.log.contains("session") })
        XCTAssertEqual(link.trying, .goBetween)
        XCTAssertTrue(until(5) { v.states.last == .away(.noDirect) }, "\(v.states)")
        // never usable before the move, so never "connected"; and it stays said
        Thread.sleep(forTimeInterval: 4)
        XCTAssertFalse(v.states.contains(.connected), "\(v.states)")
        XCTAssertEqual(v.states.last, .away(.noDirect), "\(v.states)")
        XCTAssertEqual(link.away, .noDirect)
        XCTAssertEqual(relay.joins, 2, "the host's and the viewer's: the service isn't asked again inside its wait")
        // Try Again clears it and asks now
        link.tryAgain()
        XCTAssertTrue(until(3) { relay.joins >= 3 }, "joins \(relay.joins)")
    }

    /// The public connection service refuses the upgrade (HTTP 429: over today's limit): the window says so, and waits.
    func testBusyIsSaid() throws {
        let refuser = try NWListener(using: .tcp, on: .any)
        let q = DispatchQueue(label: "refuser")
        let lock = NSLock()
        var tries = 0
        refuser.newConnectionHandler = { c in
            lock.withLock { tries += 1 }
            c.start(queue: q)
            c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                let r = "HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                c.send(content: Data(r.utf8), isComplete: true, completion: .contentProcessed { _ in c.cancel() })
            }
        }
        let ready = DispatchSemaphore(value: 0)
        refuser.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        refuser.start(queue: q)
        _ = ready.wait(timeout: .now() + 3)
        defer { refuser.cancel() }
        let address = "ws://127.0.0.1:\(refuser.port!.rawValue)"
        let computer = RemoteComputer(id: "test-host", deviceID: "viewer-1", name: "Test Host", port: 0, addresses: [], relayAddress: address)
        let link = RemoteViewerLink(computer: computer, key: RemoteCrypto.newKey(), deviceName: "Test Mac", relayOnly: address, callbacks: DispatchQueue(label: "cb"))
        link.moveOnRelay = true
        let v = Viewer(link)
        link.start()
        defer { link.stop() }
        XCTAssertTrue(until(8) { v.states.last == .away(.busy) }, "\(v.states) failure")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(v.states.last, .away(.busy))
        XCTAssertEqual(lock.withLock { tries }, 1, "asked once: the next time is 30 s away")
    }
}
