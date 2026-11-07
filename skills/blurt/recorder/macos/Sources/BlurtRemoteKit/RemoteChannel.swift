// A session over the wire: the same code on the phone and on the Mac. TCP carries the handshake, control messages and
// audio; UDP carries the pointer once a packet has made it across (docs/design/remote.md §Transport). Everything runs on
// the channel's own queue; callbacks arrive there too.
import Foundation
import Network
import QuartzCore

public final class RemoteChannel {
    /// Peer-to-peer Wi-Fi: finds a Mac with no shared network, at a cost in steadiness being measured (docs/design/remote.md).
    public static var peerToPeer = ProcessInfo.processInfo.environment["BLURT_P2P"] != "0"

    public enum Role { case phone(PhoneHandshake), mac(lookup: (String) -> Data?) }

    public let queue: DispatchQueue
    /// over the WebSocket relay
    public let isRelay: Bool
    /// a relay connection the Mac holds open, waiting for its phone: no time limit on the handshake
    private let standby: Bool
    private let connection: NWConnection
    private let role: Role
    private var reader = RemoteFrameReader()
    private var sealer: RemoteSealer?
    private var closed = false
    private var handshakeTimeout: DispatchWorkItem?

    /// The session is up (phone: the Mac proved itself; Mac: the phone's first sealed frame arrived, with the device id).
    public var onOpen: ((_ deviceID: String?) -> Void)?
    public var onControl: ((Data) -> Void)?
    public var onAudio: ((Data) -> Void)?
    public var onPointer: ((RemotePointerPacket) -> Void)?
    public var onVideo: ((Data) -> Void)?
    public var onProbe: ((Data) -> Void)?
    public var onCursor: ((Data) -> Void)?
    /// `failure`: the handshake's reason, when that is what ended it
    public var onClose: ((_ failure: RemoteHandshakeError?) -> Void)?

    // the phone's UDP path
    private var udp: NWConnection?
    private var udpSession: UInt32 = 0
    private var udpOK = false
    private var flow: NWConnection?
    private var macID: String?
    private var pendingHandshake: MacHandshake.Answer?

    public init(connection: NWConnection, role: Role, relay: Bool = false, standby: Bool = false,
                queue: DispatchQueue = DispatchQueue(label: "blurt.remote.channel", qos: .userInteractive)) {
        self.connection = connection
        self.role = role
        self.queue = queue
        self.isRelay = relay
        self.standby = standby
    }

    /// the relay's close code, when that ended it
    public private(set) var relayClose: UInt16?
    /// a direct path answered, or stopped answering (phone)
    public var onDirect: ((Bool) -> Void)?

    public func start() {
        connection.stateUpdateHandler = { [weak self] s in self?.stateChanged(s) }
        connection.start(queue: queue)
        if standby { return }
        let t = DispatchWorkItem { [weak self] in
            guard let self, self.sealer == nil || self.macID != nil && !self.opened else { return }
            self.shut(nil)
        }
        handshakeTimeout = t
        queue.asyncAfter(deadline: .now() + 6, execute: t)
    }

    private var opened = false

    private func stateChanged(_ s: NWConnection.State) {
        switch s {
        case .ready:
            receive()
            if case let .phone(h) = role { sendRaw(RemoteFrameReader.framed(h.hello())) }
            if standby { keepAlive() }
        case .failed, .cancelled:
            shut(nil)
        case .waiting where isRelay:
            shut(nil)      // no network, or the relay refused: the caller tries again later
        default: break
        }
    }

    /// WebSocket pings on a waiting connection: one that doesn't answer is dead, and a new one is made.
    private func keepAlive() {
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, !self.closed, !self.opened else { return }
            if self.pongOwed { return self.shut(nil) }
            self.pongOwed = true
            let m = NWProtocolWebSocket.Metadata(opcode: .ping)
            m.setPongHandler(self.queue) { [weak self] _ in self?.pongOwed = false }
            let ctx = NWConnection.ContentContext(identifier: "ping", metadata: [m])
            self.connection.send(content: Data(), contentContext: ctx, isComplete: true, completion: .idempotent)
            self.keepAlive()
        }
    }
    private var pongOwed = false

    private func receive() {
        if isRelay { return receiveMessages() }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.reader.feed(data)
                do {
                    while let f = try self.reader.next() {
                        self.frame(f)
                        if self.closed { return }
                    }
                } catch { return self.shut(nil) }
            }
            if done || err != nil { return self.shut(nil) }
            self.receive()
        }
    }

    private func receiveMessages() {
        connection.receiveMessage { [weak self] data, ctx, _, err in
            guard let self else { return }
            if let m = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata, m.opcode == .close {
                if case let .privateCode(c) = m.closeCode { self.relayClose = c }
                return self.shut(nil)
            }
            if let data, !data.isEmpty {
                self.reader.feed(data)
                do {
                    while let f = try self.reader.next() {
                        self.frame(f)
                        if self.closed { return }
                    }
                } catch { return self.shut(nil) }
            }
            if err != nil { return self.shut(nil) }
            self.receiveMessages()
        }
    }

    private func frame(_ f: Data) {
        guard let sealer else { return handshake(f) }
        guard let plain = try? sealer.open(f) else { return shut(nil) }
        if !opened {
            opened = true
            handshakeTimeout?.cancel()
            onOpen?(macID)
        }
        deliver(plain)
    }

    private func handshake(_ f: Data) {
        switch role {
        case let .phone(h):
            do {
                sealer = try h.finish(f)
                reader.limit = RemoteFrameReader.maxFrame
                opened = true
                handshakeTimeout?.cancel()
                onOpen?(nil)
            } catch let e as RemoteHandshakeError { shut(e) } catch { shut(nil) }
        case let .mac(lookup):
            let a = MacHandshake.answer(f, lookup: lookup)
            guard let s = a.sealer else {
                // one answer, then the connection is over
                connection.send(content: RemoteFrameReader.framed(a.reply), contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { [weak self] _ in self?.close(nil) })
                return
            }
            sendRaw(RemoteFrameReader.framed(a.reply))
            sealer = s
            macID = a.id
            reader.limit = RemoteFrameReader.maxFrame
        }
    }

    /// A frame or packet, opened: first byte says what it is.
    public func deliver(_ plain: Data) {
        guard let k = plain.first.flatMap(RemoteFrameKind.init) else { return }
        let body = plain.dropFirst()
        switch k {
        case .control: onControl?(Data(body))
        case .audio: onAudio?(Data(body))
        case .pointer: if let p = RemotePointerPacket(Data(body)) { onPointer?(p) }
        case .video: onVideo?(Data(body))
        case .probe: onProbe?(Data(body))
        case .cursor: onCursor?(Data(body))
        }
    }

    private func sendRaw(_ d: Data, done: (() -> Void)? = nil) {
        if isRelay {
            let ctx = NWConnection.ContentContext(identifier: "b", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
            connection.send(content: d, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in done?() })
        } else {
            connection.send(content: d, completion: .contentProcessed { _ in done?() })
        }
    }

    private func sendSealed(_ kind: RemoteFrameKind, _ body: Data, done: (() -> Void)? = nil) {
        guard let sealer, !closed else { return }
        guard let f = try? sealer.seal(Data([kind.rawValue]) + body) else { return }
        sendRaw(RemoteFrameReader.framed(f), done: done)
    }

    /// Frames waiting on the way out: over a slow link the next one is dropped rather than queued.
    private var framesOut = 0

    public func send<T: Encodable>(_ m: T) {
        guard let d = try? JSONEncoder().encode(m) else { return }
        queue.async { self.sendSealed(.control, d) }
    }

    public func sendAudio(_ pcm: Data) {
        queue.async { self.sendSealed(.audio, pcm) }
    }

    /// Over UDP once it works, else in the TCP stream.
    public func sendPointer(_ p: RemotePointerPacket) {
        queue.async {
            guard let sealer = self.sealer, !self.closed else { return }
            if self.udpOK, let udp = self.udp, let d = try? sealer.sealPacket(Data([RemoteFrameKind.pointer.rawValue]) + p.encoded(), session: self.udpSession) {
                udp.send(content: d, completion: .idempotent)
            } else {
                self.sendSealed(.pointer, p.encoded())
            }
        }
    }

    // MARK: datagrams, either way

    /// A datagram path, this moment: direct, or the local network's. Safe from any queue.
    public var hasDatagrams: Bool {
        pathLock.lock()
        defer { pathLock.unlock() }
        return pathOpen
    }
    /// Over the relay: the stream isn't keeping up, so the next frame had better wait. Safe from any queue.
    public var streamBusy: Bool {
        pathLock.lock()
        defer { pathLock.unlock() }
        return busy
    }
    private func setBusy(_ on: Bool) {
        pathLock.lock()
        busy = on
        pathLock.unlock()
    }
    private var busy = false
    private let pathLock = NSLock()
    private var pathOpen = false
    private func setPath(_ on: Bool) {
        pathLock.lock()
        pathOpen = on
        pathLock.unlock()
    }
    /// when the Mac last heard the phone on its flow
    private var flowHeard = 0.0
    private var flowFresh: Bool { !isRelay || CACurrentMediaTime() - flowHeard < 7 }

    /// For what's worthless late. With no datagram path it goes in the stream, but only while the stream keeps up.
    public func sendDatagram(_ kind: RemoteFrameKind, _ body: Data) {
        queue.async {
            guard let sealer = self.sealer, !self.closed else { return }
            if !self.flowFresh, self.flow != nil {      // the phone has gone quiet on this path: back to the stream
                self.flow = nil
                self.setPath(false)
            }
            if let path = (self.udpOK ? self.udp : nil) ?? self.flow,
               let d = try? sealer.sealPacket(Data([kind.rawValue]) + body, session: self.udpSession) {
                return path.send(content: d, completion: .idempotent)
            }
            guard self.isRelay, kind != .probe else { return }
            if kind == .video {
                // the sender checks `streamBusy` before it spends an encode on a frame: dropped here, it would cost a keyframe
                guard self.framesOut < 4 else { return }
                self.framesOut += 1
                self.setBusy(self.framesOut >= 2)
                self.sendSealed(kind, body) {
                    self.queue.async {
                        self.framesOut -= 1
                        self.setBusy(self.framesOut >= 2)
                    }
                }
            } else {
                self.sendSealed(kind, body)     // the pointer's position: small, and it doesn't count against the video
            }
        }
    }

    /// The Mac: the flow the phone's packets arrive on, which is the way back to it.
    public func useFlow(_ c: NWConnection) {
        queue.async {
            self.flow = c
            self.flowHeard = CACurrentMediaTime()
            self.setPath(true)
        }
    }

    private func receiveUDP(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, err in
            guard let self, err == nil else { return }
            if let data, let plain = self.sealer?.openPacket(data) {
                if self.trying.contains(where: { $0 === c }) { self.chose(c) }
                if c === self.udp { self.directHeard = CACurrentMediaTime() }
                self.deliver(plain)
            }
            self.receiveUDP(c)
        }
    }

    // MARK: a direct path, from over the relay (phone)

    private var trying: [NWConnection] = []

    /// Knock on every address the Mac gave from one local port; the first to answer carries the pointer and video from then on.
    public func tryDirect(_ candidates: [RemoteCandidate], session: UInt32, localPort: UInt16) {
        queue.async {
            self.udpSession = session
            for k in candidates {
                guard let p = NWEndpoint.Port(rawValue: k.port) else { continue }
                let params = NWParameters.udp
                params.allowLocalEndpointReuse = true
                params.serviceClass = .interactiveVoice
                if let l = NWEndpoint.Port(rawValue: localPort), localPort != 0 {
                    params.requiredLocalEndpoint = .hostPort(host: k.host.contains(":") ? "::" : "0.0.0.0", port: l)
                }
                let c = NWConnection(host: NWEndpoint.Host(k.host), port: p, using: params)
                self.trying.append(c)
                c.stateUpdateHandler = { [weak self] s in
                    if case .ready = s {
                        self?.knock(c, attempts: 30)
                        self?.receiveUDP(c)
                    }
                }
                c.start(queue: self.queue)
            }
        }
    }

    private func knock(_ c: NWConnection, attempts: Int) {
        guard attempts > 0, !closed, !udpOK, let sealer, trying.contains(where: { $0 === c }) else { return }
        if let d = try? sealer.sealPacket(Data([RemoteFrameKind.pointer.rawValue]) + RemotePointerPacket.scrollStop.encoded(), session: udpSession) {
            c.send(content: d, completion: .idempotent)
        }
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.knock(c, attempts: attempts - 1) }
    }

    private var directHeard = 0.0

    private func chose(_ c: NWConnection) {
        udp = c
        udpOK = true
        setPath(true)
        directHeard = CACurrentMediaTime()
        trying.filter { $0 !== c }.forEach { $0.cancel() }
        trying = []
        onDirect?(true)
        holdDirect()
    }

    /// A small packet now and every 2 s, echoed by the Mac: the Mac answers on the path it heard last, which must be this one and not
    /// a knock from an address that's been dropped; firewalls forget a quiet path; and no echo for 6 s means it's gone.
    private func holdDirect() {
        guard !closed, let c = udp, udpOK else { return }
        if CACurrentMediaTime() - directHeard > 6 {
            udpOK = false
            udp = nil
            setPath(false)
            c.cancel()
            onDirect?(false)
            return
        }
        sendDatagram(.probe, Data(count: 8))
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.holdDirect() }
    }

    // MARK: the phone's UDP path

    /// The Mac said where: send it a packet; `udpConfirmed` comes when one got through.
    public func openUDP(port: UInt16, session: UInt32) {
        queue.async {
            guard case .phone = self.role, self.udp == nil,
                  let remote = self.connection.currentPath?.remoteEndpoint, case let .hostPort(host, _) = remote,
                  let p = NWEndpoint.Port(rawValue: port) else { return }
            self.udpSession = session
            let params = NWParameters.udp
            params.includePeerToPeer = Self.peerToPeer
            params.serviceClass = .interactiveVoice
            if let i = self.connection.currentPath?.availableInterfaces.first(where: { self.connection.currentPath?.usesInterfaceType($0.type) == true }) {
                params.requiredInterface = i
            }
            let c = NWConnection(host: host, port: p, using: params)
            self.udp = c
            c.stateUpdateHandler = { [weak self] s in
                if case .ready = s {
                    self?.probeUDP(attempts: 6)
                    self?.receiveUDP(c)
                }
            }
            c.start(queue: self.queue)
        }
    }

    private func probeUDP(attempts: Int) {
        guard attempts > 0, !udpOK, !closed, let sealer, let udp else { return }
        if let d = try? sealer.sealPacket(Data([RemoteFrameKind.pointer.rawValue]) + RemotePointerPacket.scrollStop.encoded(), session: udpSession) {
            udp.send(content: d, completion: .idempotent)
        }
        queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.probeUDP(attempts: attempts - 1) }
    }

    /// Over the relay, a path counts once something has come back on it (`chose`), not when the Mac heard a knock.
    public func udpConfirmed() {
        queue.async {
            guard !self.isRelay else { return }
            self.udpOK = true
            self.setPath(true)
        }
    }

    // MARK: the Mac's UDP path

    /// A packet the listener matched to this session (on the channel's queue).
    public func packet(_ p: Data) -> Bool {
        guard let plain = sealer?.openPacket(p) else { return false }
        deliver(plain)
        return true
    }

    public func close(_ failure: RemoteHandshakeError? = nil) {
        queue.async { self.shut(failure) }
    }

    private func shut(_ failure: RemoteHandshakeError?) {
        guard !closed else { return }
        closed = true
        handshakeTimeout?.cancel()
        udp?.cancel()
        udp = nil
        trying.forEach { $0.cancel() }
        trying = []
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(failure)
    }
}
