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

struct PairedMac: Codable, Identifiable, Hashable {
    var id: String          // the Mac's own id, which outlives its name and address
    var deviceID: String
    var name: String
    var port: UInt16
    var addresses: [String]
    /// the relay the Mac's owner set up, as last heard
    var relayAddress: String?
    /// what the user calls it here, when two Macs have much the same name
    var nickname: String?
    /// what the computer said it is ("mac", "windows", "linux"), as last heard; nil before it said, as a Mac paired before 1.0.15
    var platform: String?

    var title: String { nickname?.isEmpty == false ? nickname! : name }
    var host: RemoteHost { platform.flatMap(RemoteHost.init(rawValue:)) ?? .mac }
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
    @Published private(set) var current: PairedMac? { didSet { hostChanged() } }
    /// what the computer in hand is: its keys, their names and what the app says follow it. A Mac until it says otherwise
    @Published private(set) var host = RemoteHost.mac
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
    /// paired Macs on this network right now, while Settings looks
    @Published private(set) var nearby: Set<String> = []
    /// on mobile data; Low Data Mode is on
    @Published private(set) var cellular = false
    @Published private(set) var lowData = false
    private let path = NWPathMonitor()
    private var nearbyBrowser: NWBrowser?
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
        #if DEBUG
        if let h = Self.testHost { pretend(h) }
        #endif
        hostChanged()
        path.pathUpdateHandler = { [weak self] p in
            // a phone's hotspot is Wi-Fi the user is paying for
            let mobile = p.isExpensive, low = p.isConstrained
            DispatchQueue.main.async {
                guard let self, mobile != self.cellular || low != self.lowData else { return }
                self.cellular = mobile
                self.lowData = low
                ScreenStream.shared.planChanged()
            }
        }
        path.start(queue: queue)
    }

    private func hostChanged() {
        let h = current?.host ?? .mac
        RemoteHost.shown = h
        if host != h { host = h }
    }

    /// Debug builds: BLURT_REMOTE_TEST_HOST=windows|linux|mac shows that computer as connected, with no connection and nothing saved, among
    /// three of mixed kinds; for looking at each one's keys in the simulator.
    private static let testHost: RemoteHost? = {
        #if DEBUG
        ProcessInfo.processInfo.environment["BLURT_REMOTE_TEST_HOST"].flatMap(RemoteHost.init(rawValue:))
        #else
        nil
        #endif
    }()

    private func pretend(_ h: RemoteHost) {
        let all = [PairedMac(id: "test-windows", deviceID: "test-1", name: "Studio PC", port: 0, addresses: [], platform: "windows"),
                   PairedMac(id: "test-mac", deviceID: "test-2", name: "MacBook Pro", port: 0, addresses: [], relayAddress: "wss://relay.example.com"),
                   PairedMac(id: "test-linux", deviceID: "test-3", name: "ubuntu-desk", port: 0, addresses: [], platform: "linux")]
        macs = all.filter { $0.host == h } + all.filter { $0.host != h }
        current = macs.first
        state = .connected
    }

    private func saveMacs() {
        guard Self.testHost == nil else { return }
        if let d = try? JSONEncoder().encode(macs) { UserDefaults.standard.set(d, forKey: Self.macsKey) }
        UserDefaults.standard.set(current?.id, forKey: "currentMac")
    }

    // MARK: pairing

    /// A link from outside (the system Camera, or anything that can open a URL): a web page could send one too, and this
    /// phone's keys and microphone would go to whoever made it. So it asks; only the app's own scanner goes straight through.
    @Published var offered: RemotePairing?
    /// the Mac is asking its owner about the code this phone used
    @Published private(set) var waitingForMac = false
    /// the four digits the Mac shows with its question: a yes there is for this iPhone only if they match
    private(set) var pairCheck: String?
    /// a pairing that didn't take, for the pad to say
    @Published private(set) var pairFailed: String?
    /// A code isn't a pairing until the Mac has answered it: the Macs already paired stay as they are until then.
    private var joining: (mac: PairedMac, back: PairedMac?, since: Date)?
    /// paired again: the entry this one took over from, for the Mac to drop
    private var replacing: String?
    private var joinOpens = 0

    func openExternal(_ url: URL) { offered = RemotePairing(url: url) }

    /// The in-app scanner, or the user said yes.
    @discardableResult func open(_ url: URL, confirmed: Bool = false) -> Bool {
        guard let p = RemotePairing(url: url) else { return false }
        // a code for a Mac already here replaces it: asked first, as a link from outside is, since a code can claim any Mac's id
        if !confirmed, macs.contains(where: { $0.id == p.macID }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.offered = p }     // once the scanner has gone
            return true
        }
        pair(p)
        return true
    }

    func pair(_ p: RemotePairing) {
        guard joining?.mac.deviceID != p.deviceID, !macs.contains(where: { $0.deviceID == p.deviceID }) else { return }     // the same code, read twice
        Keychain.store(p.key, account: p.deviceID)
        let m = PairedMac(id: p.macID, deviceID: p.deviceID, name: p.macName, port: p.port, addresses: p.addresses, relayAddress: p.relay,
                          nickname: macs.first { $0.id == p.macID }?.nickname, platform: macs.first { $0.id == p.macID }?.platform)
        if let j = joining { Keychain.remove(account: j.mac.deviceID) }
        joining = (m, joining != nil ? joining!.back : current, Date())
        joinOpens = 0
        pairFailed = nil
        switchTo(m)
    }

    /// The code never got an answer, or a refusal: back where things were, and say why.
    private func joinFailed() {
        guard let j = joining else { return }
        let asked = waitingForMac
        joining = nil
        waitingForMac = false
        Keychain.remove(account: j.mac.deviceID)
        pairFailed = asked ? String(localized: "\(j.mac.name) didn’t allow this iPhone.")
            : j.mac.relayAddress == nil ? String(localized: "Couldn’t reach \(j.mac.name). Put this iPhone on the same network, or set a relay on that computer first.")
            : String(localized: "Couldn’t reach \(j.mac.name). Scan a fresh code on that computer.")
        let t = pairFailed
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in if self?.pairFailed == t { self?.pairFailed = nil } }
        leave()
        current = macs.first { $0.id == j.back?.id } ?? macs.first
        state = current == nil ? .unpaired : .connecting
        disconnect()
        connect()
    }

    func choose(_ m: PairedMac) {
        guard m.id != current?.id else { return }
        abandonJoin()
        switchTo(m)
    }

    private func abandonJoin() {
        if let j = joining { Keychain.remove(account: j.mac.deviceID) }
        joining = nil
        waitingForMac = false
    }

    private func switchTo(_ m: PairedMac?) {
        leave()
        current = m
        if joining == nil { saveMacs() }
        state = m == nil ? .unpaired : Self.testHost != nil ? .connected : .connecting
        disconnect()
        connect()
    }

    /// Nothing of this Mac goes with the phone to the next: not a held key, a take, its picture or what went wrong with it.
    private func leave() {
        if dictation != .idle { send(.blurt(.dictationCancel)) }
        Sticky.shared.clear()
        send(.mods([]))
        send(.releaseAll)
        ScreenStream.shared.stop()
        dictation = .idle
        live = ""
        liveFinal = ""
        front = nil
        screenError = nil
        refused = false
        firstAttempt = nil
        lastRelayTry = .distantPast
    }

    func rename(_ m: PairedMac, to name: String) {
        guard let n = macs.firstIndex(where: { $0.id == m.id }) else { return }
        macs[n].nickname = name.trimmingCharacters(in: .whitespaces)
        if current?.id == m.id { current = macs[n] }
        saveMacs()
    }

    /// While Settings is open: which of the paired Macs are here. Asks nothing of them.
    func watchNearby(_ on: Bool) {
        nearbyBrowser?.cancel()
        nearbyBrowser = nil
        guard on else { nearby = []; return }
        let params = NWParameters()
        params.includePeerToPeer = RemoteChannel.peerToPeer
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: RemotePairing.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let ids = Set(results.compactMap { r -> String? in if case let .bonjour(t) = r.metadata { t["id"] } else { nil } })
            DispatchQueue.main.async { self?.nearby = ids }
        }
        b.start(queue: queue)
        nearbyBrowser = b
    }

    func forget(_ m: PairedMac) {
        if current?.id == m.id, state == .connected { send(.unpair) }
        Keychain.remove(account: m.deviceID)
        macs.removeAll { $0.id == m.id }
        if current?.id == m.id {
            abandonJoin()
            switchTo(macs.first)
        }
        saveMacs()
    }

    // MARK: app life

    func foreground() {
        active = true
        joining?.since = Date()      // scanning with the Camera app, say
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
        if waitingForMac { joinFailed() }      // nobody's there to see it, and the code is spent
        Sticky.shared.clear()
        UIApplication.shared.isIdleTimerDisabled = false
        send(.releaseAll)
        disconnect()
        // another phone has the Mac: coming back doesn't take it from them, a touch does
        if current != nil, state != .replaced { state = .connecting }
    }

    // MARK: connecting

    private func connect() {
        guard active, Self.testHost == nil, let mac = current, channel == nil, attempts.allSatisfy(\.isRelay) else { return }
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
            if let j = self.joining, !self.waitingForMac, self.refused || Date().timeIntervalSince(j.since) > 15 { return self.joinFailed() }
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
        ch.onControl = { [weak self, weak ch] d in
            guard let m = try? JSONDecoder().decode(ToPhone.self, from: d) else { return }
            DispatchQueue.main.async {
                // a word from a Mac no longer in hand says nothing about the one that is
                guard let self, let ch, self.channel === ch else { return }
                self.heard(m)
            }
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
        // a code that keeps getting sessions which never come to a question is being tried for digits: give up on it
        if joining != nil {
            joinOpens += 1
            if joinOpens > 3 { ch.close(); return joinFailed() }
        }
        ch.send(ToMac.hello(device: UIDevice.current.name, micOnPhone: MicStream.shared.usable, nonce: ch.nonce))
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
        if waitingForMac { return joinFailed() }       // the Mac said no, or the way to it went
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
            // its name, and what it is: a computer being paired isn't in the list yet, but its keys show already
            if var c = current, c.name != i.macName || c.platform != i.platform {
                c.name = i.macName
                c.platform = i.platform
                current = c
                if let n = macs.firstIndex(where: { $0.id == c.id && $0.deviceID == c.deviceID }) {
                    macs[n] = c
                    saveMacs()
                }
            }
            displayAspect = CGFloat(i.displayAspect)
            lastInfo = i
            noteRelay(i.relay)
            if let r = replacing {
                replacing = nil
                send(.replaces(deviceID: r))
            }
            // one relay serves all of them: a Mac with none takes the one the others use
            if i.relay == nil, let a = macs.compactMap(\.relayAddress).first { send(.offerRelay(a)) }
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
        case let .listen(on):
            // a voice note started from here is heard through this phone, as the talk key is
            if on {
                // couldn't have the microphone (a call has it): the Mac hears this note with its own. The setting stays as
                // it was, so the next note tries the phone again
                if !MicStream.shared.usable || !MicStream.shared.start(for: .note) {
                    send(.setMicOnPhone(false))
                    send(.setMicOnPhone(MicStream.shared.usable))
                    send(.hud(String(localized: "iPhone microphone unavailable")))
                }
            } else {
                MicStream.shared.stop(for: .note)
            }
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
        case let .screenView(w, h, codec):
            ScreenStream.shared.source(CGSize(width: w, height: h), codec: codec)
        case let .cursorShape(png, hx, hy, w, h):
            ScreenStream.shared.shape(png, hot: CGPoint(x: hx, y: hy), size: CGSize(width: w, height: h))
        case let .relay(a): noteRelay(a)
        case .pairingWaits:
            pairCheck = channel?.check
            waitingForMac = true
            let d = joining?.mac.deviceID
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                if let self, self.waitingForMac, self.joining?.mac.deviceID == d { self.joinFailed() }
            }
        case let .newKey(k):
            guard let c = current else { return }
            Keychain.store(k, account: c.deviceID)
            if joining != nil {
                joining = nil
                waitingForMac = false
                if let old = macs.first(where: { $0.id == c.id }), old.deviceID != c.deviceID {
                    Keychain.remove(account: old.deviceID)
                    replacing = old.deviceID
                }
                macs.removeAll { $0.id == c.id }
                macs.insert(c, at: 0)
                saveMacs()
            }
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
    /// `inOrder`: behind what was sent before it, as a scroll right after the pointer was placed must be
    func pointer(_ p: RemotePointerPacket, inOrder: Bool = false) {
        // over the relay every message counts: 30 a second is plenty, and it's already no place for a fine stroke
        guard route == .relay else { return channel?.sendPointer(p, inOrder: inOrder) ?? () }
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
