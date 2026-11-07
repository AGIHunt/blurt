// The connection to the Mac (docs/design/remote.md §Connection). The one thing competing apps most often get wrong, so the
// rule is: the user never has to do anything to get back. Opening the app connects; coming back from another app or a
// lock connects, usually before the thumb lands. It tries the last address and Bonjour at the same time and takes
// whichever answers. Keys and clicks made in the moment before the session is up are dropped, never queued: a late ⌘W is
// worse than a missing one.
//
// Away from home the same session runs over the relay, tried a moment after the local ways. Over it the phone looks for a direct
// path for the pointer and video (RemoteRelay), and keeps checking for the local network, which takes over the moment it's back.
import BlurtRemoteKit
import Combine
import Foundation
import Network
import UIKit

struct PairedMac: Codable, Identifiable, Equatable {
    var id: String          // the Mac's own id, which outlives its name and address
    var deviceID: String
    var name: String
    var port: UInt16
    var addresses: [String]
    /// the relay the Mac's owner set up, as last heard
    var relayAddress: String?
}

final class Link: ObservableObject {
    static let shared = Link()

    enum State: Equatable {
        case unpaired
        case connecting
        /// nothing answers after a while, with what we think is wrong
        case unreachable
        case connected
        /// the Mac has forgotten this phone
        case forgotten
        /// another phone is driving; this one waits to be touched, or the two would keep throwing each other off
        case replaced
    }

    @Published private(set) var state = State.unpaired
    @Published private(set) var macs: [PairedMac] = []
    @Published private(set) var current: PairedMac?
    @Published private(set) var canControl = true
    @Published private(set) var front: RemoteFront?
    @Published private(set) var dictation = RemoteDictationPhase.idle
    @Published private(set) var live = ""
    @Published private(set) var liveFinal = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var rtt: Double?
    enum Route { case local, relay, direct }
    @Published private(set) var route = Route.local
    @Published private(set) var displayAspect: CGFloat = 1.6
    @Published var screenError: String?

    private var channel: RemoteChannel?
    private var attempts: [RemoteChannel] = []
    private var browser: NWBrowser?
    private var retry: DispatchWorkItem?
    private var pinger: Timer?
    private var lastPong = Date()
    private var firstAttempt: Date?
    private var active = false
    private var generation = 0
    private var refused = false
    private var testRan = false
    private var lastRelayTry = Date.distantPast
    private var lastLocalTry = Date.distantPast
    /// a test run: only this way in
    private static let relayOnly = ProcessInfo.processInfo.environment["BLURT_RELAY_ONLY"].flatMap { $0.isEmpty ? nil : $0 }
    private var pingCount = 0
    private var pendingMove: (Float, Float)?
    private var pendingScroll: (Float, Float)?
    private var flusher: Timer?
    let queue = DispatchQueue(label: "blurt.remote.link", qos: .userInteractive)

    private static let macsKey = "macs.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: Self.macsKey), let m = try? JSONDecoder().decode([PairedMac].self, from: d) { macs = m }
        current = macs.first { $0.id == UserDefaults.standard.string(forKey: "currentMac") } ?? macs.first
        state = current == nil ? .unpaired : .connecting
    }

    private func saveMacs() {
        if let d = try? JSONEncoder().encode(macs) { UserDefaults.standard.set(d, forKey: Self.macsKey) }
        UserDefaults.standard.set(current?.id, forKey: "currentMac")
    }

    // MARK: pairing

    /// A link from outside (the system Camera, or anything that can open a URL): a web page could send one too, and this
    /// phone's keys and microphone would go to whoever made it. So it asks; only the app's own scanner goes straight through.
    @Published var offered: RemotePairing?

    func openExternal(_ url: URL) { offered = RemotePairing(url: url) }

    /// The in-app scanner, or the user said yes.
    @discardableResult func open(_ url: URL) -> Bool {
        guard let p = RemotePairing(url: url) else { return false }
        pair(p)
        return true
    }

    func pair(_ p: RemotePairing) {
        Keychain.store(p.key, account: p.deviceID)
        let m = PairedMac(id: p.macID, deviceID: p.deviceID, name: p.macName, port: p.port, addresses: p.addresses)
        macs.removeAll { $0.id == p.macID }
        macs.insert(m, at: 0)
        current = m
        saveMacs()
        refused = false
        disconnect()
        connect()
    }

    func choose(_ m: PairedMac) {
        current = m
        saveMacs()
        disconnect()
        connect()
    }

    func forget(_ m: PairedMac) {
        Keychain.remove(account: m.deviceID)
        macs.removeAll { $0.id == m.id }
        if current?.id == m.id {
            current = macs.first
            disconnect()
            state = current == nil ? .unpaired : .connecting
            connect()
        }
        saveMacs()
    }

    // MARK: app life

    func foreground() {
        active = true
        UIApplication.shared.isIdleTimerDisabled = true
        if state != .connected, state != .replaced { connect() }
    }

    /// The user reached for this phone while another had the Mac: take it back.
    func touched() {
        guard state == .replaced else { return }
        connect()
    }

    /// Control Center or a notification over the app: let go of what's held, keep the connection.
    func leaving() { send(.releaseAll) }

    func background() {
        active = false
        Sticky.shared.clear()
        UIApplication.shared.isIdleTimerDisabled = false
        send(.releaseAll)
        disconnect()
        if current != nil { state = .connecting }
    }

    // MARK: connecting

    private func connect() {
        guard active, let mac = current, channel == nil, attempts.allSatisfy(\.isRelay) else { return }
        guard let key = Keychain.read(account: mac.deviceID) else { state = .forgotten; return }
        generation += 1
        if firstAttempt == nil { firstAttempt = Date() }
        if state == .connected || state == .unpaired || state == .replaced { state = .connecting }
        tryLocal(mac, key)
        // the relay a moment later, so at home it's never the one that wins; and not every round
        if let address = Self.relayOnly ?? mac.relayAddress, Date().timeIntervalSince(lastRelayTry) > 4 {
            let g0 = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + (Self.relayOnly != nil ? 0 : 1.2)) { [weak self] in
                guard let self, self.channel == nil, self.active, g0 == self.generation,
                      let c = RemoteRelay.connection(address: address, room: RemoteRelay.room(key: key), role: "phone") else { return }
                self.lastRelayTry = Date()
                self.attempt(c, relay: true, mac: mac, key: key)
            }
        }
        // keep trying while the app is open; say so after a while
        let g = generation
        let r = DispatchWorkItem { [weak self] in
            guard let self, self.channel == nil, self.active, g == self.generation else { return }
            // a refusal alone proves nothing, anyone on the network can send one: only if no other way in worked
            if self.refused { self.state = .forgotten } else if let f = self.firstAttempt, Date().timeIntervalSince(f) > 8 { self.state = .unreachable }
            // a relay attempt gets longer than a local one: it has further to go
            self.cancelAttempts(keepRelay: Date().timeIntervalSince(self.lastRelayTry) < 9)
            self.connect()
        }
        retry = r
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: r)
    }

    private func tryLocal(_ mac: PairedMac, _ key: Data) {
        guard Self.relayOnly == nil else { return }
        lastLocalTry = Date()
        for a in mac.addresses {
            guard let port = NWEndpoint.Port(rawValue: mac.port) else { continue }
            attempt(.hostPort(host: NWEndpoint.Host(a), port: port), mac: mac, key: key)
        }
        browse(mac: mac, key: key)
    }

    private func browse(mac: PairedMac, key: Data) {
        browser?.cancel()
        let params = NWParameters()
        params.includePeerToPeer = RemoteChannel.peerToPeer
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: RemotePairing.serviceType, domain: nil), using: params)
        var tried = Set<NWEndpoint>()
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for r in results {
                guard case let .bonjour(txt) = r.metadata, txt["id"] == mac.id, !tried.contains(r.endpoint) else { continue }
                tried.insert(r.endpoint)
                DispatchQueue.main.async { self.attempt(r.endpoint, mac: mac, key: key) }
            }
        }
        b.start(queue: queue)
        browser = b
    }

    private func attempt(_ endpoint: NWEndpoint, mac: PairedMac, key: Data) {
        guard channel == nil || channel?.isRelay == true else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = RemoteChannel.peerToPeer
        params.serviceClass = .interactiveVideo
        if let o = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            o.noDelay = true
            o.connectionTimeout = 3
        }
        attempt(NWConnection(to: endpoint, using: params), relay: false, mac: mac, key: key)
    }

    private func attempt(_ c: NWConnection, relay: Bool, mac: PairedMac, key: Data) {
        let ch = RemoteChannel(connection: c, role: .phone(PhoneHandshake(id: mac.deviceID, paired: key)), relay: relay)
        ch.onOpen = { [weak self, weak ch] _ in
            guard let ch else { return }
            DispatchQueue.main.async { self?.opened(ch, mac: mac) }
        }
        ch.onControl = { [weak self] d in
            guard let m = try? JSONDecoder().decode(ToPhone.self, from: d) else { return }
            DispatchQueue.main.async { self?.heard(m) }
        }
        ch.onVideo = { ScreenStream.shared.packet($0) }
        ch.onProbe = { ScreenStream.shared.probeBack($0) }
        ch.onCursor = { ScreenStream.shared.cursor($0) }
        ch.onDirect = { [weak self] found in
            DispatchQueue.main.async {
                guard let self else { return }
                self.route = found ? .direct : .relay
                ScreenStream.shared.routeChanged()
                // a path that went quiet may come back, or another may open
                if !found, let i = self.lastInfo {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { if self.route == .relay { self.lookForDirect(i) } }
                }
            }
        }
        ch.onClose = { [weak self, weak ch] failure in
            DispatchQueue.main.async {
                guard let self else { return }
                self.attempts.removeAll { $0 === ch }
                if failure?.kind == .notPaired { self.refused = true }
                guard let ch, self.channel === ch else { return }
                self.lost()
            }
        }
        attempts.append(ch)
        ch.start()
    }

    private func opened(_ ch: RemoteChannel, mac: PairedMac) {
        if let old = channel {
            // back on the local network: it takes over from the relay
            guard old.isRelay, !ch.isRelay else { return ch.close() }
            channel = nil
            old.close()
            pinger?.invalidate()
            pinger = nil
        }
        attempts.removeAll { $0 === ch }
        cancelAttempts()
        channel = ch
        route = ch.isRelay ? .relay : .local
        firstAttempt = nil
        refused = false
        lastPong = Date()
        ch.send(ToMac.hello(device: UIDevice.current.name, micOnPhone: Prefs.shared.micOnPhone))
        pinger = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.ping() }
    }

    private func cancelAttempts(keepRelay: Bool = false) {
        retry?.cancel()
        browser?.cancel()
        browser = nil
        let a = attempts.filter { !(keepRelay && $0.isRelay) }
        attempts.removeAll { x in a.contains { $0 === x } }
        a.forEach { $0.close() }
    }

    private func ping() {
        let relay = channel?.isRelay == true
        if Date().timeIntervalSince(lastPong) > (relay ? 8 : 2.5) { return lost() }
        pingCount += 1
        // over the relay, one in four: every message counts against the free plan
        if !relay || pingCount % 4 == 0 { send(.ping(CACurrentMediaTime())) }
        if relay, attempts.isEmpty, Date().timeIntervalSince(lastLocalTry) > 10, let mac = current, let key = Keychain.read(account: mac.deviceID) {
            tryLocal(mac, key)
        }
    }

    private func lost() {
        pinger?.invalidate()
        pinger = nil
        let c = channel
        channel = nil
        c?.close()
        MicStream.shared.stop()
        ScreenStream.shared.connectionLost()
        dictation = .idle
        guard current != nil, state != .forgotten, state != .replaced else { return }
        state = .connecting
        connect()
    }

    private func disconnect() {
        pinger?.invalidate()
        pinger = nil
        cancelAttempts()
        let c = channel
        channel = nil
        c?.close()
        MicStream.shared.stop()
    }

    private func heard(_ m: ToPhone) {
        switch m {
        case let .session(i):
            canControl = i.canControl
            state = .connected
            if let c = current, c.name != i.macName, let n = macs.firstIndex(of: c) {
                macs[n].name = i.macName
                current = macs[n]
                saveMacs()
            }
            displayAspect = CGFloat(i.displayAspect)
            lastInfo = i
            noteRelay(i.relay)
            ScreenStream.shared.resume()
            if channel?.isRelay == true {
                if ProcessInfo.processInfo.environment["BLURT_NO_DIRECT"] != "1" { lookForDirect(i) }
            } else {
                channel?.openUDP(port: i.udpPort, session: i.udpSession)
            }
            // the Mac let go of everything when the last session ended
            send(.mods(Sticky.shared.held))
        case let .canControl(ok): canControl = ok
        case let .front(f): front = f
        case let .dictation(p):
            dictation = p
            if p != .listening { level = 0 }
            if p == .idle { live = ""; liveFinal = "" }
            MicStream.shared.macPhase(p)
        case let .live(c, p): liveFinal = c; live = p
        case let .level(l): level = l
        case .typed, .notice: break
        case let .pong(t):
            lastPong = Date()
            rtt = CACurrentMediaTime() - t
        case .udpOK:
            channel?.udpConfirmed()
            if let t = ProcessInfo.processInfo.environment["BLURT_SCREEN_TEST"], !testRan {
                testRan = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ScreenTest.run(target: t) }
            }
        case let .clock(phone, mac): ScreenStream.shared.clock(phone: phone, mac: mac)
        case let .screenFailed(why):
            ScreenStream.shared.stop()
            screenError = why
        case let .screenView(w, h):
            ScreenStream.shared.source(CGSize(width: w, height: h))
        case let .cursorShape(png, hx, hy, w, h):
            ScreenStream.shared.shape(png, hot: CGPoint(x: hx, y: hy), size: CGSize(width: w, height: h))
        case let .relay(a): noteRelay(a)
        case let .newKey(k):
            guard let c = current else { return }
            Keychain.store(k, account: c.deviceID)
            send(.keyStored)
        case .removed:
            if let c = current { forget(c) }
        case .replaced:
            state = .replaced
            disconnect()
        }
    }

    private var lastInfo: RemoteSessionInfo?

    private func noteRelay(_ typed: String?) {
        let address = typed.flatMap(RemoteRelay.address)
        guard var c = current, c.relayAddress != address, let n = macs.firstIndex(where: { $0.id == c.id }) else { return }
        c.relayAddress = address
        macs[n] = c
        current = c
        saveMacs()
    }

    func setAspect(_ a: CGFloat) { if abs(a - displayAspect) > 0.001 { displayAspect = a } }

    /// Trade addresses with the Mac and knock. From one fixed local port, so what STUN saw is what the Mac's packets will meet.
    private func lookForDirect(_ i: RemoteSessionInfo) {
        let port = UInt16.random(in: 50000...60000)
        RemoteSTUN.ask(from: port, queue: queue) { [weak self] found in
            guard let self else { return }
            var mine = RemoteAddresses.publicIPv6().map { RemoteCandidate(host: $0, port: port) }
            if let found { mine.append(found) }
            self.send(.candidates(mine))
            self.channel?.tryDirect(i.candidates, session: i.udpSession, localPort: port)
        }
    }

    // MARK: sending

    func send(_ m: ToMac) { channel?.send(m) }
    func pointer(_ p: RemotePointerPacket) {
        // over the relay every message counts: 30 a second is plenty, and it's already no place for a fine stroke
        guard route == .relay else { return channel?.sendPointer(p) ?? () }
        switch p {
        case let .move(x, y):
            pendingMove = ((pendingMove?.0 ?? 0) + x, (pendingMove?.1 ?? 0) + y)
        case let .scroll(x, y, .changed):
            pendingScroll = ((pendingScroll?.0 ?? 0) + x, (pendingScroll?.1 ?? 0) + y)
        default:
            flush()
            return channel?.sendPointer(p) ?? ()
        }
        if flusher == nil {
            flusher = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: false) { [weak self] _ in self?.flush() }
        }
    }

    private func flush() {
        flusher?.invalidate()
        flusher = nil
        if let m = pendingMove { channel?.sendPointer(.move(dx: m.0, dy: m.1)) }
        if let s = pendingScroll { channel?.sendPointer(.scroll(dx: s.0, dy: s.1, phase: .changed)) }
        pendingMove = nil
        pendingScroll = nil
    }

    func audio(_ d: Data) { channel?.sendAudio(d) }
    func datagram(_ k: RemoteFrameKind, _ d: Data) { channel?.sendDatagram(k, d) }
    var ready: Bool { channel != nil && state == .connected }
}

enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.blurt.remote", kSecAttrAccount as String: account]
    }

    static func store(_ key: Data, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = key
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func read(account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func remove(account: String) { SecItemDelete(query(account) as CFDictionary) }
}
