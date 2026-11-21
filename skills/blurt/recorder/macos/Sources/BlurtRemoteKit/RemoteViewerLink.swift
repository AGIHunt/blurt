// A computer driving another (docs/design/remote-desktop-viewer.md): the viewer's connection to one host. To the host it is one more paired
// device, like a phone: the same handshake (RemoteChannel, role phone), the same paths in the same order (the same network and its overlay
// addresses, the owner's relay or the public connection service, then the direct path and the move onto it), the same messages. What's
// a phone's own (the deck, the touch gestures, the microphone) isn't here; the window, the picture and the keyboard are BlurtApp's (Viewer/).
//
// One link per window: a second window on another display of the same computer is a second link, so a second session.
import Foundation
import Network
import QuartzCore

/// A computer this one can drive, as last heard of. Saved by the app, its key apart (the Keychain).
public struct RemoteComputer: Codable, Hashable, Identifiable, Sendable {
    /// the host's own id, which outlives its name and addresses (TXT `id`, the pairing link's `mac`)
    public var id: String
    /// this viewer's id on that host
    public var deviceID: String
    public var name: String
    public var port: UInt16
    public var addresses: [String]
    /// the owner's relay, or the public connection service, as the host last said
    public var relayAddress: String?
    /// "mac", "windows", "linux"; nil until the host says
    public var platform: String?
    public var lastSeen: Date?
    /// the host removed this viewer, said in a session it had opened: its key is gone, and it has to be added again (nil before 1.1)
    public var removed: Bool?
    /// the name the user gave it on this Mac (remote-1.1.md §6): shown before `name`, never sent, and kept when the host's hello or
    /// DNS-SD says its own name again; nil: its own name
    public var alias: String?
    public init(id: String, deviceID: String, name: String, port: UInt16, addresses: [String], relayAddress: String? = nil, platform: String? = nil, lastSeen: Date? = nil) {
        self.id = id; self.deviceID = deviceID; self.name = name; self.port = port; self.addresses = addresses; self.relayAddress = relayAddress
        self.platform = platform; self.lastSeen = lastSeen
    }
    public var host: RemoteHost { platform.flatMap(RemoteHost.init(rawValue:)) ?? .mac }
    /// what this Mac calls it: the user's name for it, else its own
    public var shownName: String { RemoteAlias.shown(name, alias: alias) }

    /// The same computer as just heard from (its hello, a pairing, DNS-SD), over the record kept: its own name, addresses and relay are
    /// the new ones; the user's name for it stays.
    public func heard(_ fresh: RemoteComputer) -> RemoteComputer {
        var c = fresh
        c.alias = alias
        return c
    }

    /// From a pairing link (the host's 添加设备 / Add Device), with the key in it.
    public init(pairing p: RemotePairing) {
        self.init(id: p.macID, deviceID: p.deviceID, name: p.macName, port: p.port, addresses: p.addresses, relayAddress: p.relay)
    }
}

public final class RemoteViewerLink {
    public enum State: Equatable, Sendable {
        case connecting
        /// nothing answered for a while
        case unreachable
        /// pairing: the host shows these six digits and waits for its owner's yes
        case waiting(check: String)
        case connected
        /// the host refused this viewer's key with no session (it may have removed it; anyone on the network can send a refusal, so the
        /// key is kept)
        case forgotten
        /// the host removed this viewer, said in a session it had opened
        case removed
        /// a pairing that ended without a key: nothing more until the user starts another
        case pairingFailed(PairingFailure)
        /// another device took the host
        case replaced
        /// the person at the computer ended the session: nothing more until the user reconnects
        case ended
        /// away, through the public connection service, it didn't work: no direct path on this network, or the service is over today's
        /// limit. Stays until the backoff (30 s, 2 min, 10 min, hourly) lets the service be asked again and that works, a network change,
        /// or Try Again (no direct path only)
        case away(Away)
    }

    /// How a pairing ended without a key. The host never says which (a bare close, or a refused handshake), so it's read from when:
    public enum PairingFailure: String, Sendable {
        /// refused before anyone was asked: a link's code ran out or was used already; nearby, the host isn't taking a new computer now
        /// (it's asking about another, or was just told no)
        case spent
        /// the question was asked and the host let go: its owner said no
        case declined
        /// the question was asked and nobody answered: the host gives up after its two minutes
        case unanswered
    }

    /// How the session came, in the agreed terms (copy.md): 同一网络 · 直连 · Tailscale · 虚拟局域网 · 自建中转 · 公共连接服务
    public enum Route: String, Sendable {
        case local, tailscale, overlay, direct, relay, goBetween
    }

    /// Why away from home didn't work through the public connection service.
    /// `relayDown`: the computer's own relay doesn't answer; the public connection service is tried too meanwhile (2026-11-20, the office)
    public enum Away: String, Sendable { case busy, noDirect, relayDown }

    public private(set) var computer: RemoteComputer
    private var key: Data
    private let deviceName: String
    /// a pairing under way (a code or nearby): until the new key is kept, nothing is saved
    public private(set) var pairing: Bool
    /// tried first: the host as found on the network (nearby pairing)
    private let endpoint: NWEndpoint?
    /// test runs: only this relay, no local attempts
    private let relayOnly: String?
    public let queue = DispatchQueue(label: "blurt.viewer.link", qos: .userInteractive)
    private let callbacks: DispatchQueue

    public var onState: ((State) -> Void)?
    /// every message from the host, after the link has taken what it needs from it (callbacks queue)
    public var onMessage: ((ToPhone) -> Void)?
    /// video pieces and cursor places, on the channel's queue
    public var onVideo: ((Data) -> Void)?
    public var onCursor: ((Data) -> Void)?
    /// the computer's details changed (its name, what it is, its addresses, its relay): the app saves them (callbacks queue)
    public var onComputer: ((RemoteComputer) -> Void)?
    /// pairing: the host's new key for this viewer, to keep before the link says it's kept (link's queue, synchronously)
    public var onNewKey: ((RemoteComputer, Data) -> Void)?
    /// the route or the round trip changed (callbacks queue)
    public var onRoute: ((Route?, Double?) -> Void)?

    public private(set) var state = State.connecting
    public private(set) var route: Route?
    public private(set) var rtt: Double?
    public private(set) var away: Away?
    /// the way being tried while not connected: the public connection service or the owner's relay when there is one, else the same network
    public private(set) var trying: Route?
    /// Why the last session ended here (for the log): "closed", "no pong", "no direct".
    public private(set) var lostWhy = ""
    public private(set) var session: RemoteSessionInfo?
    /// the host takes a viewer's extras (clipboard, window size)
    public var hostTakesViewer: Bool { session?.features?.contains(RemoteFeature.viewer) == true }

    private var channel: RemoteChannel?
    private var attempts: [RemoteChannel] = []
    /// when each attempt began: one still unanswered long after is stale, and no longer holds the next round back
    private var attemptBegan: [ObjectIdentifier: Double] = [:]
    private var browser: NWBrowser?
    private var active = false
    private var generation = 0
    private var firstAttempt: Double?
    private var refused = false
    private var lastRelayTry = -100.0
    private var lastLocalTry = -100.0
    private var lastPong = 0.0
    private var pingCount = 0
    private var pinger: DispatchSourceTimer?
    private var meetRefusals = 0, noDirectTimes = 0
    private var meetQuietUntil = 0.0
    /// the computer's own relay failed this many times in a row without connecting: from `relayDownAfter`, the public connection service
    /// is tried as well (the host waits there too by then) and the window says why
    private var ownRelayFails = 0
    static let relayDownAfter = 2
    private var lastMeetTry = -100.0
    private var pointerSeq: UInt32 = 0
    /// the session came through the public connection service and waits for the move: not usable before it (no picture goes there)
    private var awaitingMove = false
    private let paths = NWPathMonitor()
    private var pathSeen = false
    /// tests: a relay on this machine with the public connection service's budget (`BUDGET=1 node tools/remote-relay/server.js`) is met as the
    /// service is, moving the stream onto the direct path
    var moveOnRelay = false
    /// a second window on the same computer (another display): the host keeps the first window's session beside this one
    public var extraWindow = false
    /// how long a host asks its owner about a new device before it takes the silence as a no (RemoteServer's and blurt-remote's
    /// `pairingLife`): a close that late is "nobody answered", not "no"
    var questionLife = 120.0
    private var waitingSince: Double?

    public init(computer: RemoteComputer, key: Data, deviceName: String, pairing: Bool = false, endpoint: NWEndpoint? = nil, relayOnly: String? = nil,
                callbacks: DispatchQueue = .main) {
        self.computer = computer
        self.key = key
        self.deviceName = deviceName
        self.pairing = pairing
        self.endpoint = endpoint
        self.relayOnly = relayOnly
        self.callbacks = callbacks
    }

    // MARK: life

    public func start() {
        queue.async {
            guard !self.active else { return }
            self.active = true
            self.firstAttempt = nil
            self.watchNetwork()
            self.connect()
        }
    }

    /// Another network: what didn't connect directly on the last one may here.
    private func watchNetwork() {
        paths.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            guard self.pathSeen else { self.pathSeen = true; return }
            guard self.active, self.away == .noDirect else { return }
            self.clearNoDirect()
            if self.channel == nil {
                self.firstAttempt = nil
                self.set(.connecting)
                self.cancelAttempts(keepRelay: true)
                self.connect()
            }
        }
        paths.start(queue: queue)
    }

    private func clearNoDirect() {
        away = nil
        meetQuietUntil = 0
        noDirectTimes = 0
    }

    /// What the end of a connection to the public connection service says: refused (busy, over the day's limit or its rate), no direct path
    /// (the host said so, or the service's budget ran out before the move), or nothing about away at all.
    public static func away(refused: Bool, closeCode: UInt16?, moved: Bool, heardNoDirect: Bool) -> Away? {
        if refused { return .busy }
        if heardNoDirect { return .noDirect }
        if closeCode == RemoteRelay.overBudget, !moved { return .noDirect }
        return nil
    }

    /// The window closed: let go of everything held, then the connection.
    public func stop() {
        queue.async {
            guard self.active else { return }
            self.active = false
            self.paths.cancel()
            self.channel?.send(ToMac.releaseAll)
            let c = self.channel
            self.queue.asyncAfter(deadline: .now() + 0.2) { c?.close() }
            self.channel = nil
            self.pinger?.cancel()
            self.pinger = nil
            self.cancelAttempts()
        }
    }

    /// Retry: the same attempts, from now.
    public func tryAgain() {
        queue.async {
            guard self.active, self.channel == nil else { return }
            if self.away == .noDirect { self.clearNoDirect() }
            self.firstAttempt = nil
            self.set(.connecting)
            self.cancelAttempts()
            self.connect()
        }
    }

    /// Another device took the host: take it back.
    public func takeBack() {
        queue.async {
            guard self.active, self.state == .replaced || self.state == .ended else { return }
            self.set(.connecting)
            self.connect()
        }
    }

    private func set(_ s: State) {
        guard s != state else { return }
        state = s
        callbacks.async { self.onState?(s) }
    }

    private func setTrying(_ r: Route?) {
        guard r != trying else { return }
        trying = r
        let (route, t) = (self.route, rtt)
        callbacks.async { self.onRoute?(route, t) }
    }

    private func setRoute(_ r: Route?) {
        route = r
        let t = rtt
        callbacks.async { self.onRoute?(r, t) }
    }

    // MARK: sending

    public func send(_ m: ToMac) { queue.async { self.channel?.send(m) } }
    public func sendDatagram(_ k: RemoteFrameKind, _ d: Data) { queue.async { self.channel?.sendDatagram(k, d) } }
    public func sendPointer(_ p: RemotePointerPacket, inOrder: Bool = false) { queue.async { self.channel?.sendPointer(p, inOrder: inOrder) } }
    /// The host's pointer to this place on the display shown (0…1), numbered so the host's word on where it is says which this includes.
    @discardableResult public func pointerTo(x: Float, y: Float) -> UInt32 {
        let seq = queue.sync { () -> UInt32 in
            pointerSeq &+= 1
            return pointerSeq
        }
        send(.pointerTo(x: x, y: y, seq: seq))
        return seq
    }
    /// over the relay, every message counts against someone's plan: the app sends fewer
    public var overRelay: Bool { queue.sync { route == .relay } }
    public var sentSeq: UInt32 { queue.sync { pointerSeq } }

    // MARK: connecting

    private func connect() {
        // replaced or ended there: nothing until the user asks (takeBack), whatever retry was already scheduled
        guard active, channel == nil, state != .replaced, state != .ended else { return }
        // attempts other than the relay's still under way (the direct path looked for while on the relay): they may move the session, so
        // they're left to finish, but this looks again in 3 s either way. It used to return here for good, and after a drop the window sat
        // on "Reconnecting…" until it was closed (2026-11-20, a host restarted)
        guard attempts.allSatisfy(\.isRelay) else {
            let g = generation
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.channel == nil, self.active, g == self.generation else { return }
                // only attempts long unanswered are dropped: a direct path just being tried may still carry the session over
                let now = CACurrentMediaTime()
                let stale = self.attempts.filter { !$0.isRelay && !$0.wasReady && now - (self.attemptBegan[ObjectIdentifier($0)] ?? now) > 10 }
                self.attempts.removeAll { x in stale.contains { $0 === x } }
                stale.forEach { $0.close() }
                self.connect()
            }
            return
        }
        generation += 1
        let now = CACurrentMediaTime()
        if firstAttempt == nil { firstAttempt = now }
        if state == .connected { set(.connecting) }
        let away = endpoint == nil ? (relayOnly ?? computer.relayAddress) : nil
        setTrying(away.map { RemoteRelay.isGoBetween($0) || moveOnRelay ? .goBetween : .relay } ?? .local)
        tryLocal()
        // the relay a moment later, so on the same network it's never the one that wins; the public connection service only while it isn't
        // waiting out a refusal. Nearby pairing is the same network's alone
        if endpoint == nil, let address = relayOnly ?? computer.relayAddress, now - lastRelayTry > 4,
           !(RemoteRelay.isGoBetween(address) || moveOnRelay) || now >= meetQuietUntil {
            let g = generation
            queue.asyncAfter(deadline: .now() + (relayOnly != nil ? 0 : 1.2)) { [weak self] in
                guard let self, self.channel == nil, self.active, g == self.generation,
                      let c = RemoteRelay.connection(address: address, room: RemoteRelay.room(key: self.key), role: "phone") else { return }
                self.lastRelayTry = CACurrentMediaTime()
                self.attempt(c, relay: true, goBetween: RemoteRelay.isGoBetween(address) || self.moveOnRelay)
            }
        }
        // the computer's own relay is down: its host waits at the public connection service meanwhile, so that's tried as well
        if endpoint == nil, relayOnly == nil, let own = computer.relayAddress, !RemoteRelay.isGoBetween(own),
           ownRelayFails >= Self.relayDownAfter, now >= meetQuietUntil, now - lastMeetTry > 4 {
            let g = generation
            queue.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.channel == nil, self.active, g == self.generation,
                      let c = RemoteRelay.connection(address: RemoteRelay.goBetween, room: RemoteRelay.room(key: self.key), role: "phone") else { return }
                self.lastMeetTry = CACurrentMediaTime()
                self.attempt(c, relay: true, goBetween: true)
            }
        }
        let g = generation
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.channel == nil, self.active, g == self.generation else { return }
            // a refusal alone proves nothing, anyone on the network can send one: only if no other way in worked
            if self.refused { self.set(self.pairing ? .pairingFailed(.spent) : .forgotten); return }
            if let a = self.away { self.set(.away(a)) } else if let f = self.firstAttempt, CACurrentMediaTime() - f > 8 { self.set(.unreachable) }
            self.cancelAttempts(keepRelay: CACurrentMediaTime() - self.lastRelayTry < 9)
            self.connect()
        }
    }

    /// The host as found nearby, the addresses it last listed (overlay ones with a shorter wait), and DNS-SD by its id.
    private func tryLocal() {
        guard relayOnly == nil else { return }
        lastLocalTry = CACurrentMediaTime()
        if let endpoint { attempt(endpoint) }
        if let port = NWEndpoint.Port(rawValue: computer.port), computer.port != 0 {
            for a in computer.addresses {
                attempt(.hostPort(host: NWEndpoint.Host(a), port: port), timeout: RemoteOverlay.isTailscale(a) ? 1.5 : 3)
            }
        }
        browse()
    }

    private func browse() {
        browser?.cancel()
        let params = NWParameters()
        params.includePeerToPeer = RemoteChannel.peerToPeer
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: RemotePairing.serviceType, domain: nil), using: params)
        var tried = Set<NWEndpoint>()
        let id = computer.id
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for r in results {
                guard case let .bonjour(txt) = r.metadata, txt["id"] == id, !tried.contains(r.endpoint) else { continue }
                tried.insert(r.endpoint)
                self.attempt(r.endpoint)
            }
        }
        b.start(queue: queue)
        browser = b
    }

    private func attempt(_ endpoint: NWEndpoint, timeout: Double = 3) {
        guard channel == nil || channel?.isRelay == true || route == .overlay || route == .tailscale else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = RemoteChannel.peerToPeer
        params.serviceClass = .interactiveVideo
        if let o = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            o.noDelay = true
            o.connectionTimeout = Int(timeout.rounded(.up))
        }
        let ch = attempt(NWConnection(to: endpoint, using: params), relay: false)
        if timeout < 3 {
            queue.asyncAfter(deadline: .now() + timeout) { [weak self, weak ch] in
                guard let self, let ch, self.attempts.contains(where: { $0 === ch }), !ch.wasReady else { return }
                self.attempts.removeAll { $0 === ch }
                ch.close()
            }
        }
    }

    @discardableResult
    private func attempt(_ c: NWConnection, relay: Bool, goBetween: Bool = false) -> RemoteChannel {
        let ch = RemoteChannel(connection: c, role: .phone(PhoneHandshake(id: computer.deviceID, paired: key)), relay: relay, queue: queue)
        attemptBegan = attemptBegan.filter { id, _ in attempts.contains { ObjectIdentifier($0) == id } }
        attemptBegan[ObjectIdentifier(ch)] = CACurrentMediaTime()
        if goBetween { ch.enableMove() }
        ch.onOpen = { [weak self, weak ch] _ in
            guard let self, let ch else { return }
            self.opened(ch, goBetween: goBetween)
        }
        ch.onMoved = { [weak self] in
            guard let self else { return }
            self.noDirectTimes = 0
            self.meetRefusals = 0
            self.away = nil
            self.setRoute(.goBetween)
            if self.awaitingMove {
                self.awaitingMove = false
                self.set(.connected)
            }
        }
        ch.onControl = { [weak self, weak ch] d in
            guard let self, let ch, self.channel === ch, let m = try? JSONDecoder().decode(ToPhone.self, from: d) else { return }
            self.heard(m)
        }
        ch.onVideo = { [weak self] d in self?.onVideo?(d) }
        ch.onCursor = { [weak self] d in self?.onCursor?(d) }
        ch.onProbe = { _ in }
        ch.onDirect = { [weak self, weak ch] found in
            guard let self, let ch, self.channel === ch, self.route != .goBetween else { return }
            self.setRoute(found ? .direct : .relay)
            if !found, let i = self.session {
                self.queue.asyncAfter(deadline: .now() + 15) { if self.route == .relay { self.lookForDirect(i) } }
            }
        }
        ch.onClose = { [weak self, weak ch] failure in
            guard let self else { return }
            self.attempts.removeAll { $0 === ch }
            if failure?.kind == .notPaired { self.refused = true }
            if relay, !goBetween, let ch { self.ownRelayAnswered(ch.wasReady) }
            if goBetween, let ch { self.goBetweenEnded(ch) }
            guard let ch, self.channel === ch else { return }
            self.lostWhy = "closed (\(failure.map { "\($0.kind)" } ?? "no failure"), moved \(ch.moved))"
            self.lost()
        }
        attempts.append(ch)
        ch.start()
        return ch
    }

    private func opened(_ ch: RemoteChannel, goBetween: Bool) {
        let overlay = ch.isRelay ? nil : Self.overlay(ch)
        if let old = channel {
            // the same network takes over from the relay or an overlay network; an overlay network from the relay
            let oldOverlay = route == .overlay || route == .tailscale
            guard old.isRelay && !ch.isRelay || oldOverlay && !ch.isRelay && overlay == nil else { return ch.close() }
            channel = nil
            old.close()
        }
        attempts.removeAll { $0 === ch }
        cancelAttempts()
        channel = ch
        if away == .relayDown { away = nil }
        setRoute(ch.isRelay ? (goBetween ? nil : .relay) : overlay == .tailscale ? .tailscale : overlay != nil ? .overlay : .local)
        if goBetween { setTrying(.goBetween) }
        awaitingMove = goBetween
        firstAttempt = nil
        refused = false
        lastPong = CACurrentMediaTime()
        ch.send(ToMac.hello(device: deviceName, micOnPhone: false, nonce: ch.nonce, features: [RemoteFeature.move, RemoteFeature.viewer] + (extraWindow ? [RemoteFeature.window] : [])))
        pinger?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.ping() }
        t.resume()
        pinger = t
    }

    private func cancelAttempts(keepRelay: Bool = false) {
        browser?.cancel()
        browser = nil
        let a = attempts.filter { !(keepRelay && $0.isRelay) }
        attempts.removeAll { x in a.contains { $0 === x } }
        a.forEach { $0.close() }
    }

    private static func overlay(_ ch: RemoteChannel) -> RemoteOverlay? {
        if let h = ch.remoteHost, RemoteOverlay.isTailscale(h) { return .tailscale }
        if let i = ch.interfaceName, i.hasPrefix("utun") || i.hasPrefix("ipsec") || RemoteOverlay.isOverlayInterface(i) { return .other }
        return nil
    }

    private func ownRelayAnswered(_ ok: Bool) {
        if ok {
            ownRelayFails = 0
            if away == .relayDown { away = nil }
        } else {
            ownRelayFails += 1
            if ownRelayFails >= Self.relayDownAfter, away == nil { away = .relayDown }
        }
    }

    private func goBetweenEnded(_ ch: RemoteChannel) {
        let refused = RemoteRelay.refused(ch.failure)
        if refused {
            meetRefusals += 1
            meetQuietUntil = CACurrentMediaTime() + RemoteRelay.busyWait(meetRefusals)
        } else if ch.wasReady {
            meetRefusals = 0
            if away == .busy { away = nil }
        }
        // a busy refusal says nothing while another way already carries the session
        guard let a = Self.away(refused: refused, closeCode: ch.relayClose, moved: ch.moved, heardNoDirect: false),
              channel == nil || channel === ch || a == .noDirect else { return }
        if a == .noDirect { noDirect() } else {
            away = .busy
            if channel == nil || channel === ch { set(.away(.busy)) }
        }
    }

    /// The host said the direct path didn't open, or the service couldn't carry the session: this network won't do it. Shown now, and
    /// the service is left alone for 30 s, 2 min, 10 min, then hourly (or until the network changes, or Try Again).
    private func noDirect() {
        let first = away != .noDirect
        away = .noDirect
        if first {
            noDirectTimes += 1
            meetQuietUntil = max(meetQuietUntil, CACurrentMediaTime() + RemoteRelay.busyWait(noDirectTimes))
        }
        set(.away(.noDirect))
    }

    private func ping() {
        guard let ch = channel else { return }
        let relay = ch.isRelay, moved = ch.moved
        if CACurrentMediaTime() - lastPong > (relay ? 8 : 2.5) { lostWhy = "no pong (relay \(relay), moved \(moved))"; return lost() }
        pingCount += 1
        if !relay || moved || pingCount % 4 == 0 { ch.send(ToMac.ping(CACurrentMediaTime())) }
        // away: the same network, or a nearer way than an overlay network's, is looked for now and then
        if relay || route == .overlay || route == .tailscale, attempts.isEmpty, CACurrentMediaTime() - lastLocalTry > 10, endpoint == nil {
            tryLocal()
        }
    }

    private func lost() {
        pinger?.cancel()
        pinger = nil
        let c = channel
        channel = nil
        c?.close()
        session = nil
        setRoute(nil)
        guard active, !stays else { return }
        // a pairing that lost its way before its key was kept can't go on: the host has spent the code. A close near the end of the
        // host's question is its own no to the silence
        if pairing, case .waiting = state {
            let waited = waitingSince.map { CACurrentMediaTime() - $0 } ?? 0
            set(.pairingFailed(waited >= questionLife * 0.9 ? .unanswered : .declined))
            return
        }
        awaitingMove = false
        // a reason away didn't work stays said; the next round goes on in the background, the service only once its wait is over
        if let a = away { set(.away(a)) } else { set(.connecting) }
        connect()
    }

    /// a state that stays until the user does something (or, replaced and ended, takes the host back)
    private var stays: Bool {
        switch state {
        case .forgotten, .removed, .replaced, .ended, .pairingFailed: true
        default: false
        }
    }

    // MARK: what the host says

    private func heard(_ m: ToPhone) {
        switch m {
        case let .session(i):
            session = i
            pointerSeq = 0
            if computer.name != i.macName || computer.platform != i.platform {
                computer.name = i.macName
                computer.platform = i.platform
            }
            noteAddresses(i.candidates)
            // found nearby: the port it listens on, which it keeps across launches
            if let ch = channel, !ch.isRelay, let p = ch.remotePort, Self.overlay(ch) == nil { computer.port = p }
            computer.relayAddress = i.relay.flatMap(RemoteRelay.address) ?? (RemoteRelay.isGoBetween(computer.relayAddress) ? nil : computer.relayAddress)
            computer.lastSeen = Date()
            if channel?.isRelay == true, route == nil { setRoute(channel?.moved == true ? .goBetween : nil) }
            if channel?.isRelay == true, ProcessInfo.processInfo.environment["BLURT_NO_DIRECT"] != "1" {
                lookForDirect(i)
            } else {
                channel?.openUDP(port: i.udpPort, session: i.udpSession)
            }
            if !pairing { let c = computer; callbacks.async { self.onComputer?(c) } }
            // through the public connection service the session is usable only once it has moved onto the direct path (onMoved)
            if awaitingMove, channel?.moved != true {} else {
                awaitingMove = false
                away = nil
                set(.connected)
            }
        case let .pong(t):
            lastPong = CACurrentMediaTime()
            rtt = CACurrentMediaTime() - t
            let r = route, rt = rtt
            callbacks.async { self.onRoute?(r, rt) }
        case .udpOK:
            channel?.udpConfirmed()
        case .pairingWaits:
            waitingSince = CACurrentMediaTime()
            set(.waiting(check: channel?.check ?? ""))
        case let .newKey(k):
            guard k.count == 32 else { return }
            key = k
            onNewKey?(computer, k)
            pairing = false
            channel?.send(ToMac.keyStored)
            let c = computer
            callbacks.async { self.onComputer?(c) }
        case .removed:
            set(.removed)
            active = false
            channel?.close()
        case .replaced:
            set(.replaced)
            let c = channel
            channel = nil
            c?.close()
        case .ended:
            set(.ended)
            let c = channel
            channel = nil
            c?.close()
        case .noDirect:
            // the host ends this session now: said at once, and the session is let go of here too (the service is asked again only after
            // its wait; the same network keeps being looked for)
            noDirect()
            lost()
            return
        case let .relay(a):
            let address = a.flatMap(RemoteRelay.address)
            if computer.relayAddress != address {
                computer.relayAddress = address
                if !pairing { let c = computer; callbacks.async { self.onComputer?(c) } }
            }
        default: break
        }
        callbacks.async { self.onMessage?(m) }
    }

    /// The host's own addresses, as it listed them this session: private and overlay ones are kept to try next time.
    private func noteAddresses(_ list: [RemoteCandidate]) {
        let keep = list.map(\.host).filter(RemoteOverlay.worthTrying)
        guard !keep.isEmpty else { return }
        var seen = Set<String>()
        computer.addresses = Array((keep + computer.addresses).filter { seen.insert($0).inserted }.prefix(8))
    }

    /// Over the relay: trade addresses with the host and knock, from one fixed local port.
    private func lookForDirect(_ i: RemoteSessionInfo) {
        let port = UInt16.random(in: 50000...60000)
        RemoteSTUN.ask(from: port, queue: queue) { [weak self] found in
            guard let self, let ch = self.channel else { return }
            var mine = RemoteAddresses.publicIPv6().map { RemoteCandidate(host: $0, port: port) }
            if let found { mine.append(found) }
            ch.send(ToMac.candidates(mine))
            ch.tryDirect(i.candidates, session: i.udpSession, localPort: port)
        }
    }
}

/// What the list of computers says of one (docs/design/remote-desktop-viewer.md): 已连接 · <path>, 可连接 · <path>, 无法直连, 离线 · <when>.
public enum RemoteViewerRow: Equatable, Sendable {
    case connected(RemoteViewerLink.Route?)
    /// a way to it exists now: the same network (found by DNS-SD), Tailscale, the owner's relay or the public connection service
    case available(RemoteViewerLink.Route)
    /// the public connection service is its only way and the last try found no direct path
    case noDirect
    /// its own relay doesn't answer (the public connection service is tried meanwhile)
    case relayDown
    /// its relay says it went to sleep then (it said so before sleeping)
    case asleep(Date)
    case offline(Date?)
    /// it removed this viewer (or refused its key this run): Add Again, not Connect
    case removed

    /// `connected`: a window has a session with it. `failed`: why its last try through the public connection service didn't work.
    /// `presence`: what its relay said lately (`peek`); a computer not waiting there is asleep or offline, not "available".
    /// `refused`: it refused this viewer's key this run, with no session (not saved: anyone on the network can send that)
    public static func of(_ c: RemoteComputer, connected: Bool, route: RemoteViewerLink.Route?, nearby: Bool,
                          failed: RemoteViewerLink.Away?, presence: RemotePresence? = nil, refused: Bool = false) -> RemoteViewerRow {
        if connected { return .connected(route) }
        if c.removed == true || refused { return .removed }
        if nearby { return .available(.local) }
        if let p = presence, !p.host, failed != .relayDown {
            if let a = p.asleep { return .asleep(a) }
            return .offline(p.seen ?? c.lastSeen)
        }
        if let r = c.relayAddress {
            if !RemoteRelay.isGoBetween(r) { return failed == .relayDown ? .relayDown : .available(.relay) }
            if failed == .noDirect { return .noDirect }
            return .available(.goBetween)
        }
        if c.addresses.contains(where: RemoteOverlay.isTailscale) { return .available(.tailscale) }
        return .offline(c.lastSeen)
    }
}
