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
    /// the phone's word on the picture: pieces missing, frames decoded, a frame lost (RemoteVideoFeedback)
    public var onVideoFeedback: ((Data) -> Void)?
    /// `failure`: the handshake's reason, when that is what ended it
    public var onClose: ((_ failure: RemoteHandshakeError?) -> Void)?

    // the phone's UDP path
    private var udp: NWConnection?
    private var udpSession: UInt32 = 0
    private var udpOK = false
    private var flow: NWConnection?
    private var macID: String?
    private var pendingHandshake: MacHandshake.Answer?
    /// Mac: the paired key the handshake used, and what the phone committed to
    public private(set) var pairedKey: Data?
    private var commitment: Data?
    /// phone: the nonce to reveal in the first message
    public var nonce: Data? { if case let .phone(h) = role { h.nonce } else { nil } }
    /// phone: the session's six digits (RemoteCrypto.check), once the handshake is done
    public var check: String? { nonce.flatMap { n in sealer?.check(n) } }
    /// Mac: the six digits, if `nonce` is the one the phone committed to (nil otherwise)
    public func check(revealing nonce: Data) -> String? {
        guard let c = commitment, RemoteCrypto.same(RemoteCrypto.commitment(nonce), c) else { return nil }
        return sealer?.check(nonce)
    }

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
    /// the connection came up (for a relay: the WebSocket upgrade was accepted)
    public private(set) var wasReady = false

    /// Where the other end is, as the connection sees it (an IP address, or nil before it knows).
    public var remoteHost: String? {
        guard case let .hostPort(h, _) = connection.currentPath?.remoteEndpoint ?? connection.endpoint else { return nil }
        switch h {
        case let .ipv4(a): return "\(a)".split(separator: "%").first.map(String.init)
        case let .ipv6(a): return "\(a)".split(separator: "%").first.map(String.init)
        case let .name(n, _): return n
        @unknown default: return nil
        }
    }

    /// The port at the other end (the host's TCP port, which it keeps across launches), once known.
    public var remotePort: UInt16? {
        guard case let .hostPort(_, p) = connection.currentPath?.remoteEndpoint ?? connection.endpoint else { return nil }
        return p.rawValue
    }

    /// The interface the connection runs over ("en0", "utun4", "feth1234"): an overlay network has its own.
    public var interfaceName: String? {
        guard let p = connection.currentPath else { return nil }
        return p.availableInterfaces.first { p.usesInterfaceType($0.type) }?.name
    }
    /// a direct path answered, or stopped answering (phone)
    public var onDirect: ((Bool) -> Void)?

    public func start() {
        connection.stateUpdateHandler = { [weak self] s in self?.stateChanged(s) }
        connection.start(queue: queue)
        if standby { return }
        armHandshakeTimeout()
    }

    /// Six seconds to finish the handshake. A waiting relay connection has no limit until a phone says hello on it; from then the same.
    private func armHandshakeTimeout() {
        handshakeTimeout?.cancel()
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
            wasReady = true
            receive()
            if case let .phone(h) = role { sendRaw(RemoteFrameReader.framed(h.hello())) }
            if standby { keepAlive() }
        case let .failed(e):
            if !oldStreamGone { failure = e }
            oldStreamEnded()
        case .cancelled:
            oldStreamEnded()
        case let .waiting(e) where isRelay:
            failure = e
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

    /// what the connection failed with, when it did: a relay that refused the upgrade (busy, over quota) says so here (RemoteRelay.refused)
    public private(set) var failure: NWError?
    /// the WebSocket (or TCP) is gone and the session goes on: both ways have moved onto the direct path
    private var oldStreamGone = false

    /// The old stream ended. Once both ends have moved onto the direct path that's nothing: the session carries on over UDP.
    private func oldStreamEnded() {
        guard !closed else { return }
        guard inMoved, outMoved else { return shut(nil) }
        guard !oldStreamGone else { return }
        oldStreamGone = true
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

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
            if done || err != nil { return self.oldStreamEnded() }
            self.receive()
        }
    }

    private func receiveMessages() {
        connection.receiveMessage { [weak self] data, ctx, _, err in
            guard let self else { return }
            if let m = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata, m.opcode == .close {
                if case let .privateCode(c) = m.closeCode { self.relayClose = c }
                return self.oldStreamEnded()
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
            if err != nil { return self.oldStreamEnded() }
            self.receiveMessages()
        }
    }

    private func frame(_ f: Data) {
        guard let sealer else { return handshake(f) }
        if inMoved { return }       // the other end's last frame here was `streamMoved`: nothing after it counts
        guard let plain = try? sealer.open(f) else { return shut(nil) }
        if !opened {
            opened = true
            handshakeTimeout?.cancel()
            reader.limit = RemoteFrameReader.maxFrame     // only now: an id alone doesn't buy anyone a megabyte
            onOpen?(macID)
        }
        if isRelay, Self.isStreamMoved(plain) {
            inMoved = true
            readStream()
            movedChanged()
            return
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
            pairedKey = a.key
            commitment = a.commitment
            if standby { armHandshakeTimeout() }
        }
    }

    /// A frame or packet, opened: first byte says what it is. `datagram`: it came as a packet, not in a stream.
    public func deliver(_ plain: Data, datagram: Bool = false) {
        guard let k = plain.first.flatMap(RemoteFrameKind.init) else { return }
        let body = plain.dropFirst()
        if datagram { lastDatagram = CACurrentMediaTime() }
        switch k {
        case .control: onControl?(Data(body))
        case .audio: onAudio?(Data(body))
        case .pointer: if let p = RemotePointerPacket(Data(body)) { onPointer?(p) }
        case .video: onVideo?(Data(body))
        case .probe: onProbe?(Data(body))
        case .cursor: onCursor?(Data(body))
        case .videoFeedback: onVideoFeedback?(Data(body))
        case .stream, .streamAck: if datagram, isRelay { streamPacket(k, Data(body)) }
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
        if canMove, !outMoved {
            // the go-between before the move: no picture or sound over it at all, and the big messages wait for the direct path (in order,
            // so whatever follows one waits too). If the move never comes, the session ends and they go with it
            switch kind {
            case .control:
                if !held.isEmpty || body.count > Self.holdOver {
                    held.append(body)
                    done?()
                    return
                }
            case .pointer: break
            default:
                done?()
                return
            }
        }
        guard let f = try? sealer.seal(Data([kind.rawValue]) + body) else { return }
        if outMoved {
            writeStream(RemoteFrameReader.framed(f))
            done?()
        } else {
            sendRaw(RemoteFrameReader.framed(f), done: done)
        }
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

    /// Over UDP once it works, else in the TCP stream. `inOrder`: in the stream regardless, behind the messages sent before it, as a
    /// scroll must be when the pointer was just placed where it's to happen.
    public func sendPointer(_ p: RemotePointerPacket, inOrder: Bool = false) {
        queue.async {
            guard let sealer = self.sealer, !self.closed else { return }
            if !inOrder, self.udpOK, let udp = self.udp, let d = try? sealer.sealPacket(Data([RemoteFrameKind.pointer.rawValue]) + p.encoded(), session: self.udpSession) {
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
            guard self.isRelay, kind != .probe, !self.outMoved else { return }
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
                self.deliver(plain, datagram: true)
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
        tryMove()
    }

    /// A small packet now and every 2 s, echoed by the Mac: the Mac answers on the path it heard last, which must be this one and not
    /// a knock from an address that's been dropped; firewalls forget a quiet path; and no echo for 6 s means it's gone.
    private func holdDirect() {
        guard !closed, let c = udp, udpOK else { return }
        if CACurrentMediaTime() - directHeard > 6 {
            if moved { return shut(nil) }      // the stream is on this path: no way back to the old one
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

    /// Over the relay, a path counts once something has come back on it (`chose`), not when the Mac heard a knock. On the go-between
    /// (`enableMove`) the other end's word that a datagram got through is half of what moving the stream needs; the path is the other half.
    public func udpConfirmed() {
        queue.async {
            guard !self.isRelay else {
                self.wantMove = true
                return self.tryMove()
            }
            self.udpOK = true
            self.setPath(true)
        }
    }

    // MARK: the stream, moved onto the direct path (docs/design/remote-go-between.md)

    /// control messages bigger than this wait for the direct path on the go-between
    static let holdOver = 2048
    /// both ends listed `move` and this is the go-between: the stream moves once the direct path is open
    private var canMove = false
    /// the other end's word that a datagram got through (phone: `udpOK`; host: it saw one)
    private var wantMove = false
    /// this end has written `streamMoved` and writes to the UDP stream since; the other end's `streamMoved` has been read
    private var outMoved = false
    private var inMoved = false
    private var streamOut: RemoteStreamSender?
    private let streamIn = RemoteStreamReceiver()
    private var streamReader: RemoteFrameReader = {
        var r = RemoteFrameReader()
        r.limit = RemoteFrameReader.maxFrame
        return r
    }()
    /// control messages that wait for the move (`holdOver`)
    private var held: [Data] = []
    private var lastDatagram = 0.0
    private var timerToken = 0
    private var timerDue: Double?
    private var watching = false
    /// both ways have moved (once; on the channel's queue)
    public var onMoved: (() -> Void)?

    /// Both ends are on the stream over UDP. Safe from any queue.
    public var moved: Bool {
        pathLock.lock()
        defer { pathLock.unlock() }
        return movedBoth
    }
    private var movedBoth = false

    /// The go-between, and both ends listed `move`: from now on nothing big goes over the WebSocket, and the stream moves onto the direct
    /// path once `udpConfirmed` and a path agree. The host calls `udpConfirmed` itself, once it has seen a datagram and said `udpOK`.
    public func enableMove() {
        queue.async {
            self.canMove = true
            self.tryMove()
        }
    }

    /// what datagrams go out on: the phone's chosen direct path, or the flow the host last heard the phone on
    private var datagramPath: NWConnection? { (udpOK ? udp : nil) ?? (flowFresh ? flow : nil) }

    private func tryMove() {
        guard canMove, wantMove, !outMoved, !closed, let sealer, datagramPath != nil else { return }
        // the last frame on the old stream
        guard let body = try? JSONEncoder().encode(Self.movedMessage), let f = try? sealer.seal(Data([RemoteFrameKind.control.rawValue]) + body) else { return }
        sendRaw(RemoteFrameReader.framed(f))
        outMoved = true
        streamOut = RemoteStreamSender()
        lastDatagram = CACurrentMediaTime()
        let waiting = held
        held = []
        for m in waiting { sendSealed(.control, m) }
        movedChanged()
    }

    private struct MovedMessage: Encodable { struct Empty: Encodable {}; var streamMoved = Empty() }
    private static let movedMessage = MovedMessage()

    /// `{"streamMoved":{}}` in a control frame, however the other end spaced it
    static func isStreamMoved(_ plain: Data) -> Bool {
        guard plain.first == RemoteFrameKind.control.rawValue, plain.count < 64,
              let o = try? JSONSerialization.jsonObject(with: plain.dropFirst()) as? [String: Any] else { return false }
        return o.count == 1 && o["streamMoved"] != nil
    }

    private func movedChanged() {
        if outMoved || inMoved, !watching {
            watching = true
            lastDatagram = max(lastDatagram, CACurrentMediaTime())
            watchDatagrams()
        }
        guard outMoved, inMoved, !moved else { return }
        pathLock.lock()
        movedBoth = true
        pathLock.unlock()
        onMoved?()
    }

    /// After the move the session lives on datagrams: none for 6 s and it's over (the phone starts again from the beginning).
    private func watchDatagrams() {
        guard !closed else { return }
        if CACurrentMediaTime() - lastDatagram > 6 { return shut(nil) }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.watchDatagrams() }
    }

    private func writeStream(_ bytes: Data) {
        guard let s = streamOut else { return }
        s.write(bytes, now: CACurrentMediaTime()).forEach(sendStream)
        armTimer()
    }

    private func sendStream(_ p: RemoteStreamPacket) {
        guard let sealer, let path = datagramPath,
              let d = try? sealer.sealPacket(Data([p.kind.rawValue]) + p.encoded(), session: udpSession) else { return }
        path.send(content: d, completion: .idempotent)
    }

    /// A kind-7 or kind-8 datagram (over the relay only: nobody else moves).
    private func streamPacket(_ k: RemoteFrameKind, _ body: Data) {
        guard let p = RemoteStreamPacket(kind: k, body: body) else { return }
        let now = CACurrentMediaTime()
        switch p {
        case let .data(offset, bytes):
            let (d, ack) = streamIn.receive(offset: offset, bytes: bytes, now: now)
            if let ack { sendStream(.ack(next: ack)) }
            if !d.isEmpty {
                streamReader.feed(d)
                // bytes that came before the other end's `streamMoved` was read wait for it
                if inMoved { readStream() }
            }
        case let .ack(next):
            streamOut?.ack(next, now: now).forEach(sendStream)
        }
        armTimer()
    }

    /// The other end's frames from the UDP stream, in order, with the same implicit counters as before the move.
    private func readStream() {
        guard let sealer else { return }
        do {
            while let f = try streamReader.next() {
                guard let plain = try? sealer.open(f) else { return shut(nil) }
                deliver(plain)
                if closed { return }
            }
        } catch { shut(nil) }
    }

    /// One timer for the stream: the sender's timeout and the receiver's held-back ack, whichever is first.
    private func armTimer() {
        guard !closed, let due = [streamOut?.deadline, streamIn.deadline].compactMap({ $0 }).min() else { return }
        if let t = timerDue, t <= due { return }
        timerDue = due
        timerToken += 1
        let token = timerToken
        queue.asyncAfter(deadline: .now() + max(0, due - CACurrentMediaTime())) { [weak self] in
            guard let self, token == self.timerToken, !self.closed else { return }
            self.timerDue = nil
            let now = CACurrentMediaTime()
            if let a = self.streamIn.tick(now: now) { self.sendStream(.ack(next: a)) }
            self.streamOut?.tick(now: now).forEach(self.sendStream)
            self.armTimer()
        }
    }

    // MARK: the Mac's UDP path

    /// A packet the listener matched to this session (on the channel's queue).
    public func packet(_ p: Data) -> Bool {
        guard let plain = sealer?.openPacket(p) else { return false }
        deliver(plain, datagram: true)
        return true
    }

    public func close(_ failure: RemoteHandshakeError? = nil) {
        queue.async { self.shut(failure) }
    }

    /// A relay connection's close with an app close code the relay reads (RemoteRelay.asleep: the computer is going to sleep), then shut.
    public func close(code: UInt16) {
        queue.async {
            guard self.isRelay, !self.closed else { return self.shut(nil) }
            let m = NWProtocolWebSocket.Metadata(opcode: .close)
            m.closeCode = .privateCode(code)
            let ctx = NWConnection.ContentContext(identifier: "close", metadata: [m])
            self.connection.send(content: nil, contentContext: ctx, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.queue.async { self?.shut(nil) }
            })
            // a sleeping Mac doesn't wait long for it
            self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.shut(nil) }
        }
    }

    private func shut(_ failure: RemoteHandshakeError?) {
        guard !closed else { return }
        closed = true
        timerToken += 1
        held = []
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
