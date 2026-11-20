// The connection to the Mac (docs/design/remote.md §Connection). The one thing competing apps most often get wrong, so the
// rule is: the user never has to do anything to get back. Opening the app connects; coming back from another app or a
// lock connects, usually before the thumb lands. It tries the last address and Bonjour at the same time and takes
// whichever answers. Keys and clicks made in the moment before the session is up are dropped, never queued: a late ⌘W is
// worse than a missing one.
//
// Away from home the same session runs over the relay, tried a moment after the local ways. Over it the phone looks for a direct
// path for the pointer and video (RemoteRelay), and keeps checking for the local network, which takes over the moment it's back.
// With no relay of the owner's own the computer may offer Blurt's go-between instead: the two meet there and move the whole session
// onto the direct path, or say it can't be done on this network (docs/design/remote-go-between.md). An overlay address the computer
// listed (Tailscale, ZeroTier) is tried like a local one, and needs no server at all.
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
    /// the computer removed this phone, said in a session it had opened: its key is gone, and it has to be paired again (nil before 1.1)
    var removed: Bool?

    var title: String { nickname?.isEmpty == false ? nickname! : name }
    var host: RemoteHost { platform.flatMap(RemoteHost.init(rawValue:)) ?? .mac }
}

/// A pairing that didn't take: what went wrong, what to do next, and whether the same code can still work (Try Again). The computer never
/// says why (a refused handshake, or a bare close), so it's read from when (docs/design/remote-desktop-viewer.md, as the Mac viewer does).
struct PairFailure: Equatable {
    enum Why: Equatable {
        /// refused before anyone was asked: the code ran out or was used already
        case spent
        /// the question was asked and the computer let go: its owner said no
        case declined
        /// closed at 90 % of the computer's two-minute question or later: nobody answered
        case unanswered
        /// the app went to the background while the computer was asking: the code is spent
        case left
        /// nothing answered; still trying, and the digits take this one's place as soon as the computer asks
        case unreachable
    }

    var why: Why
    var title: String
    var help: String
    var canRetry: Bool { why == .unreachable }
}

final class Link: ObservableObject {
    static let shared = Link()
    /// how long a computer asks its owner about a new device before it takes the silence as a no (RemoteServer's and blurt-remote's
    /// pairing life): a close that late is "nobody answered", not "no"
    static let questionLife: TimeInterval = 120

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
        /// the person at the computer ended the session; this one waits to be touched
        case ended
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
    enum Route { case local, relay, direct, overlay }
    @Published private(set) var route = Route.local
    /// on an overlay network: Tailscale's own addresses, or another's (ZeroTier and the like)
    @Published private(set) var overlayIsTailscale = false
    /// the session came in through Blurt's go-between (RemoteRelay.goBetween)
    @Published private(set) var viaGoBetween = false
    /// why away from home didn't work with the go-between, for the pad's card
    @Published private(set) var away: LinkStatus.Away?
    /// the computer's own words for this user (a new device paired there): the pad shows it once
    @Published var notice: String?
    /// the go-between turned this phone away so many times in a row (busy), or met the computer with no direct path (noDirect), and isn't
    /// asked again before `meetQuietUntil`
    private var meetRefusals = 0
    private var noDirectTimes = 0
    private var meetQuietUntil = Date.distantPast
    @Published private(set) var displayAspect: CGFloat = 1.6
    /// the computer's displays, as it arranges them; a switcher shows only with two or more (docs/design/remote.md §Several displays)
    @Published private(set) var displays: [RemoteDisplay] = []
    /// the one the picture shows now
    @Published private(set) var shownDisplay: String?
    /// the one chosen to be shown; nil follows the pointer from display to display
    @Published private(set) var pinnedDisplay: String?
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
    /// the computer's own relay failed this many times in a row without opening: from 2, the public connection service is tried too
    /// (its host waits there meanwhile), and the pad says why
    private var relayFails = 0
    private var lastMeetTry = Date.distantPast
    private var lastLocalTry = Date.distantPast
    /// a test run: only this way in
    private static let relayOnly = ProcessInfo.processInfo.environment["BLURT_RELAY_ONLY"].flatMap { $0.isEmpty ? nil : $0 }
    private var pingCount = 0
    private var pendingMove: (Float, Float)?
    /// this phone's pointer instructions so far, moves and placements alike: the computer says how far it has got with each word on
    /// where its pointer is (RemoteCursor), so the pointer drawn here never jumps back to a place from before the last moves
    private(set) var pointerSeq: UInt32 = 0
    func nextPointerSeq() -> UInt32 {
        pointerSeq &+= 1
        return pointerSeq
    }
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
        // a test run: the code as the in-app scanner reads it, with no one there to answer the question a link from outside asks
        if let u = ProcessInfo.processInfo.environment["BLURT_REMOTE_PAIR"].flatMap(URL.init(string:)) {
            DispatchQueue.main.async { self.open(u, confirmed: true) }
        }
        if !Pretend.displays.isEmpty { pretend(displays: Pretend.displays, shown: Pretend.displays.first?.id) }
        // the pad's card when the public connection service couldn't carry the session, with no computer: =nodirect | =busy
        if let a = ProcessInfo.processInfo.environment["BLURT_REMOTE_TEST_AWAY"] {
            macs = [PairedMac(id: "test-mac", deviceID: "test-2", name: "MacBook Pro", port: 0, addresses: [], relayAddress: RemoteRelay.goBetween)]
            current = macs.first
            away = a == "busy" ? .busy : .noDirect
            state = .unreachable
            testAway = true
        }
        #endif
        hostChanged()
        path.pathUpdateHandler = { [weak self] p in
            // a phone's hotspot is Wi-Fi the user is paying for
            let mobile = p.isExpensive, low = p.isConstrained
            let network = p.availableInterfaces.map(\.name).joined(separator: ",")
            DispatchQueue.main.async {
                guard let self else { return }
                // another network may open the direct path where this one didn't
                if network != self.network {
                    let first = self.network.isEmpty
                    self.network = network
                    if !first, self.away == .noDirect { self.away = nil; self.noDirectTimes = 0; self.meetQuietUntil = .distantPast }
                }
                guard mobile != self.cellular || low != self.lowData else { return }
                self.cellular = mobile
                self.lowData = low
                ScreenStream.shared.planChanged()
            }
        }
        path.start(queue: queue)
    }

    private var network = ""

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

    #if DEBUG
    /// Layout work and render tests: displays with no computer
    func pretend(displays d: [RemoteDisplay], shown: String?, pinned: String? = nil) {
        displays = d
        shownDisplay = shown
        pinnedDisplay = pinned
    }
    #endif

    private func saveMacs() {
        guard Self.testHost == nil, !testAway else { return }
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
    @Published private(set) var pairFailed: PairFailure?
    /// when the computer began asking about the code in hand
    private var askedAt: Date?
    /// the last pairing link typed into the sheet (an iPhone without a camera): the sheet shows it again after a failure
    var lastLink = ""
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

    /// Why a pairing that ended without a key ended, from when: refused before the question (spent), closed while it was up (a no), or
    /// closed near the end of the computer's two minutes (nobody answered).
    static func ending(asked: Date?, now: Date = Date()) -> PairFailure.Why {
        guard let asked else { return .spent }
        return now.timeIntervalSince(asked) >= questionLife * 0.9 ? .unanswered : .declined
    }

    static func failure(_ why: PairFailure.Why, name: String, hasRelay: Bool) -> PairFailure {
        let scan = String(localized: "On \(name), open Add Device and scan the code it shows now.")
        return switch why {
        case .spent: PairFailure(why: why, title: String(localized: "This code has expired or was already used."), help: scan)
        case .declined: PairFailure(why: why, title: String(localized: "\(name) didn’t allow this iPhone."), help: scan)
        case .unanswered: PairFailure(why: why, title: String(localized: "No one answered on \(name) in time."), help: scan)
        case .left: PairFailure(why: why, title: String(localized: "Pairing stopped when Blurt left the screen."), help: scan)
        case .unreachable:
            PairFailure(why: why, title: String(localized: "Can’t reach \(name)."),
                        help: hasRelay ? String(localized: "Make sure \(name) is on and Blurt is open there.")
                            : String(localized: "Put this iPhone and the computer on the same network. To connect from anywhere, set a relay in Blurt’s Settings → Remote Control on the computer first."))
        }
    }

    /// The code in hand can't be reached yet: said, and it goes on trying; if the computer turns up and asks, its digits take this one's
    /// place, so they can be compared.
    private func joinUnreachable() {
        guard let j = joining, pairFailed == nil else { return }
        pairFailed = Self.failure(.unreachable, name: j.mac.name, hasRelay: j.mac.relayAddress != nil)
    }

    /// The code never got an answer, or a refusal: back where things were, and say why, with Scan Code for a new one. Said for a while
    /// over the computer gone back to (it may be in use), or until the next pairing begins.
    private func joinFailed(_ why: PairFailure.Why) {
        guard let j = joining else { return }
        joining = nil
        waitingForMac = false
        askedAt = nil
        Keychain.remove(account: j.mac.deviceID)
        let f = Self.failure(why, name: j.mac.name, hasRelay: j.mac.relayAddress != nil)
        pairFailed = f
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in if self?.pairFailed == f { self?.pairFailed = nil } }
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
        askedAt = nil
        pairFailed = nil
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
        displays = []
        shownDisplay = nil
        pinnedDisplay = nil
        refused = false
        firstAttempt = nil
        lastRelayTry = .distantPast
        away = nil
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

    /// The computer removed this phone in a session: its key is deleted and the record kept, marked removed, so the pad and the list say
    /// so and offer a new code. Pairing again replaces the record by the computer's id.
    private func removedHere(_ m: PairedMac) {
        Keychain.remove(account: m.deviceID)
        if let n = macs.firstIndex(where: { $0.id == m.id && $0.deviceID == m.deviceID }) {
            macs[n].removed = true
            if current?.id == m.id { current = macs[n] }
            saveMacs()
        }
        state = .forgotten
        disconnect()
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
        if state != .connected, state != .replaced, state != .ended { connect() }
    }

    /// The user reached for this phone while another had the Mac: take it back.
    func touched() {
        guard state == .replaced || state == .ended else { return }
        state = .connecting
        connect()
    }

    /// The pad's Retry, when nothing has answered for a while: the same attempts, started over now, and the pad says "connecting" again
    /// while they run. It was already trying every 3 s; this is for the moment the user has just woken the computer or started Blurt.
    func tryAgain() {
        guard active, current != nil, state == .unreachable || pairFailed?.canRetry == true else { return }
        firstAttempt = nil
        // a code that couldn't be reached: the same code once more; what went wrong is gone until it goes wrong again
        if joining != nil, pairFailed?.canRetry == true {
            pairFailed = nil
            joining?.since = Date()
        }
        // a network that wouldn't connect directly may now (the user moved, or switched Wi-Fi off); busy stays busy until it's waited out
        if away == .noDirect { meetQuietUntil = .distantPast; noDirectTimes = 0 }
        state = .connecting
        cancelAttempts()
        connect()
    }

    /// Control Center or a notification over the app: let go of what's held, keep the connection.
    func leaving() { send(.releaseAll) }

    func background() {
        active = false
        if waitingForMac { joinFailed(.left) }      // nobody's there to see it, and the code is spent
        Sticky.shared.clear()
        UIApplication.shared.isIdleTimerDisabled = false
        send(.releaseAll)
        disconnect()
        // another phone has the Mac: coming back doesn't take it from them, a touch does
        if current != nil, state != .replaced, state != .ended { state = .connecting }
    }

    // MARK: connecting

    /// debug builds: BLURT_REMOTE_TEST_AWAY shows that card and connects nowhere
    private var testAway = false

    private func connect() {
        guard active, Self.testHost == nil, !testAway, let mac = current, channel == nil, attempts.allSatisfy(\.isRelay) else { return }
        // replaced or ended there: nothing until the user touches this phone, whatever retry was already queued
        guard state != .replaced, state != .ended else { return }
        guard let key = Keychain.read(account: mac.deviceID) else { state = .forgotten; return }
        generation += 1
        if firstAttempt == nil { firstAttempt = Date() }
        if state == .connected || state == .unpaired { state = .connecting }
        tryLocal(mac, key)
        // the relay a moment later, so at home it's never the one that wins; and not every round. The go-between only while it isn't
        // waiting out a refusal: a quota spent for the day doesn't come back for being asked again
        if let address = Self.relayOnly ?? mac.relayAddress, Date().timeIntervalSince(lastRelayTry) > 4,
           !RemoteRelay.isGoBetween(address) || Date() >= meetQuietUntil {
            let g0 = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + (Self.relayOnly != nil ? 0 : 1.2)) { [weak self] in
                guard let self, self.channel == nil, self.active, g0 == self.generation,
                      let c = RemoteRelay.connection(address: address, room: RemoteRelay.room(key: key), role: "phone") else { return }
                self.lastRelayTry = Date()
                self.attempt(c, relay: true, mac: mac, key: key, goBetween: RemoteRelay.isGoBetween(address))
            }
        }
        if Self.relayOnly == nil, let own = mac.relayAddress, !RemoteRelay.isGoBetween(own), relayFails >= 2,
           Date().timeIntervalSince(lastMeetTry) > 4, Date() >= meetQuietUntil {
            let g0 = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.channel == nil, self.active, g0 == self.generation,
                      let c = RemoteRelay.connection(address: RemoteRelay.goBetween, room: RemoteRelay.room(key: key), role: "phone") else { return }
                self.lastMeetTry = Date()
                self.attempt(c, relay: true, mac: mac, key: key, goBetween: true)
            }
        }
        // keep trying while the app is open; say so after a while
        let g = generation
        let r = DispatchWorkItem { [weak self] in
            guard let self, self.channel == nil, self.active, g == self.generation else { return }
            // a code refused before anyone was asked has run out or was used; one that can't be reached is said, and tried on
            if let j = self.joining, !self.waitingForMac {
                if self.refused { return self.joinFailed(.spent) }
                if Date().timeIntervalSince(j.since) > 15 { self.joinUnreachable() }
            }
            // a refusal alone proves nothing, anyone on the network can send one: only if no other way in worked
            if self.refused { self.state = .forgotten } else if let f = self.firstAttempt, Date().timeIntervalSince(f) > 8 || self.away != nil { self.state = .unreachable }
            // a relay attempt gets longer than a local one: it has further to go
            self.cancelAttempts(keepRelay: Date().timeIntervalSince(self.lastRelayTry) < 9)
            self.connect()
        }
        retry = r
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: r)
    }

    /// The addresses it was last told (the code's, then the computer's own list each session), overlay networks' among them, and Bonjour.
    /// An overlay address is a TCP connection like a local one, so it's tried the same way, with a shorter wait: away from that network
    /// (or with another VPN on, as iOS allows one at a time) it never answers.
    private func tryLocal(_ mac: PairedMac, _ key: Data) {
        guard Self.relayOnly == nil else { return }
        lastLocalTry = Date()
        for a in mac.addresses {
            guard let port = NWEndpoint.Port(rawValue: mac.port) else { continue }
            attempt(.hostPort(host: NWEndpoint.Host(a), port: port), mac: mac, key: key, timeout: RemoteOverlay.isTailscale(a) ? 1.5 : 3)
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

    private func attempt(_ endpoint: NWEndpoint, mac: PairedMac, key: Data, timeout: Double = 3) {
        guard channel == nil || channel?.isRelay == true || route == .overlay else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = RemoteChannel.peerToPeer
        params.serviceClass = .interactiveVideo
        if let o = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            o.noDelay = true
            o.connectionTimeout = Int(timeout.rounded(.up))
        }
        let ch = attempt(NWConnection(to: endpoint, using: params), relay: false, mac: mac, key: key)
        // TCP's own timeout is in whole seconds: a shorter wait (an overlay address) is kept here
        if timeout < 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self, weak ch] in
                guard let self, let ch, self.attempts.contains(where: { $0 === ch }), !ch.wasReady else { return }
                self.attempts.removeAll { $0 === ch }
                ch.close()
            }
        }
    }

    @discardableResult
    private func attempt(_ c: NWConnection, relay: Bool, mac: PairedMac, key: Data, goBetween: Bool = false) -> RemoteChannel {
        let ch = RemoteChannel(connection: c, role: .phone(PhoneHandshake(id: mac.deviceID, paired: key)), relay: relay)
        // on the go-between, nothing big goes over it from the start, and the stream moves once the direct path opens
        if goBetween { ch.enableMove() }
        ch.onOpen = { [weak self, weak ch] _ in
            guard let ch else { return }
            DispatchQueue.main.async { self?.opened(ch, mac: mac, goBetween: goBetween) }
        }
        ch.onMoved = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                // the whole session is on the direct path now: the go-between worked on this network
                self.noDirectTimes = 0
                self.meetRefusals = 0
                self.away = nil
            }
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
        ch.onDirect = { [weak self, weak ch] found in
            DispatchQueue.main.async {
                guard let self, let ch, self.channel === ch else { return }
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
                if relay, !goBetween, let ch {
                    if ch.wasReady {
                        self.relayFails = 0
                        if self.away == .relayDown { self.away = nil }
                    } else {
                        self.relayFails += 1
                        if self.relayFails >= 2, self.away == nil { self.away = .relayDown }
                    }
                }
                if goBetween, let ch { self.goBetweenEnded(ch) }
                guard let ch, self.channel === ch else { return }
                self.lost()
            }
        }
        attempts.append(ch)
        ch.start()
        return ch
    }

    private func opened(_ ch: RemoteChannel, mac: PairedMac, goBetween: Bool) {
        let overlay = ch.isRelay ? nil : Self.overlay(ch)
        if let old = channel {
            // back on the local network: it takes over from the relay, or from an overlay network; an overlay one from the relay
            guard old.isRelay && !ch.isRelay || route == .overlay && !ch.isRelay && overlay == nil else { return ch.close() }
            channel = nil
            old.close()
            pinger?.invalidate()
            pinger = nil
        }
        attempts.removeAll { $0 === ch }
        cancelAttempts()
        channel = ch
        if away == .relayDown { away = nil }
        route = ch.isRelay ? .relay : overlay != nil ? .overlay : .local
        overlayIsTailscale = overlay == .tailscale
        viaGoBetween = goBetween
        firstAttempt = nil
        refused = false
        lastPong = Date()
        // a code that keeps getting sessions which never come to a question is being tried for digits: give up on it
        if joining != nil {
            joinOpens += 1
            if joinOpens > 3 { ch.close(); return joinFailed(.spent) }
        }
        ch.send(ToMac.hello(device: UIDevice.current.name, micOnPhone: MicStream.shared.usable, nonce: ch.nonce, features: [RemoteFeature.move]))
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

    /// An overlay network's address, or a connection over a tunnel interface (ZeroTier's addresses are in no fixed range): nil for the
    /// same network.
    private static func overlay(_ ch: RemoteChannel) -> RemoteOverlay? {
        if let h = ch.remoteHost, RemoteOverlay.isTailscale(h) { return .tailscale }
        if let i = ch.interfaceName, i.hasPrefix("utun") || i.hasPrefix("ipsec") || RemoteOverlay.isOverlayInterface(i) { return .other }
        return nil
    }

    /// A go-between connection ended: say why when it's the reason away doesn't work, and leave the go-between alone for a while after a
    /// refusal (30 s, 2 min, 10 min, then hourly) instead of asking again every round. The same wait after a network that wouldn't
    /// connect directly, until the network changes or Retry.
    private func goBetweenEnded(_ ch: RemoteChannel) {
        if RemoteRelay.refused(ch.failure) {
            meetRefusals += 1
            meetQuietUntil = Date().addingTimeInterval(RemoteRelay.busyWait(meetRefusals))
            if channel == nil { away = .busy }
            return
        }
        if ch.wasReady { meetRefusals = 0; if away == .busy { away = nil } }
        if ch.relayClose == RemoteRelay.overBudget, !ch.moved { noDirect() }
    }

    /// The computer said the direct path didn't open, or the go-between couldn't carry the session: this network won't do it. Said on the
    /// pad, and the go-between is left alone for 30 s (or until the network changes, or Retry).
    private func noDirect() {
        away = .noDirect
        noDirectTimes += 1
        meetQuietUntil = max(meetQuietUntil, Date().addingTimeInterval(RemoteRelay.busyWait(noDirectTimes)))
    }

    private func ping() {
        let relay = channel?.isRelay == true, moved = channel?.moved == true
        // the stream moved onto UDP: as long a wait as the relay's (a lost ping waits for its resend), but nothing there counts against a plan
        if Date().timeIntervalSince(lastPong) > (relay ? 8 : 2.5) { return lost() }
        pingCount += 1
        // over the relay, one in four: every message counts against the free plan
        if !relay || moved || pingCount % 4 == 0 { send(.ping(CACurrentMediaTime())) }
        // away, the same network (or a nearer way than an overlay network's) is looked for now and then
        if relay || route == .overlay, attempts.isEmpty, Date().timeIntervalSince(lastLocalTry) > 10, let mac = current, let key = Keychain.read(account: mac.deviceID) {
            tryLocal(mac, key)
        }
    }

    private func lost() {
        pinger?.invalidate()
        pinger = nil
        let c = channel
        channel = nil
        c?.close()
        viaGoBetween = false
        MicStream.shared.stop()
        ScreenStream.shared.connectionLost()
        dictation = .idle
        // the computer let go while it was asking: its owner said no, or nobody answered in its two minutes
        if waitingForMac { return joinFailed(Self.ending(asked: askedAt)) }
        guard current != nil, state != .forgotten, state != .replaced, state != .ended else { return }
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
            pointerSeq = 0      // a new session: the computer has forgotten the last one's numbers too
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
            noteAddresses(i.candidates)
            if viaGoBetween { away = nil }
            if let r = replacing {
                replacing = nil
                send(.replaces(deviceID: r))
            }
            // one relay serves all of them: a Mac with none takes the one the others use
            if i.relay == nil, let a = macs.compactMap(\.relayAddress).first(where: { !RemoteRelay.isGoBetween($0) }) { send(.offerRelay(a)) }
            if talkHeld { send(.dictationKey(down: true)) }
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
        case .typed: break
        case let .notice(t): notice = t
        case let .pong(t):
            lastPong = Date()
            rtt = CACurrentMediaTime() - t
            Self.rttLock.lock(); Self.rttShared = rtt ?? 0.01; Self.rttLock.unlock()
        case .udpOK:
            channel?.udpConfirmed()
            #if DEBUG
            DisplayTest.run()
            #endif
            if let t = ProcessInfo.processInfo.environment["BLURT_SCREEN_TEST"], !testRan {
                testRan = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ScreenTest.run(target: t) }
            }
        case let .clock(phone, mac): ScreenStream.shared.clock(phone: phone, mac: mac)
        case let .screenFailed(why):
            ScreenStream.shared.stop()
            screenError = why
        case let .screenView(w, h, codec, display, features):
            shownDisplay = display
            ScreenStream.shared.source(CGSize(width: w, height: h), codec: codec, display: display, features: features)
        case let .displays(list):
            displays = list
            if let p = pinnedDisplay, !list.contains(where: { $0.id == p }) { pinnedDisplay = nil }     // unplugged: the computer follows again
        case let .cursorShape(png, hx, hy, w, h):
            ScreenStream.shared.shape(png, hot: CGPoint(x: hx, y: hy), size: CGSize(width: w, height: h))
        case let .relay(a): noteRelay(a)
        case .pairingWaits:
            pairCheck = channel?.check
            waitingForMac = true
            askedAt = Date()
            // the computer asks now, whatever was said before (it may have turned up after "Can't reach"): the digits take its place
            pairFailed = nil
            let d = joining?.mac.deviceID
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.questionLife) { [weak self] in
                if let self, self.waitingForMac, self.joining?.mac.deviceID == d { self.joinFailed(.unanswered) }
            }
        case let .newKey(k):
            guard let c = current else { return }
            Keychain.store(k, account: c.deviceID)
            if joining != nil {
                joining = nil
                waitingForMac = false
                askedAt = nil
                pairFailed = nil
                lastLink = ""
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
            // said in a session it had opened, so it's so: the key goes, and the list says Removed until it's paired again. A refused
            // key with no session (anyone on the network can send one) only says so, the key kept (`refused` → `.forgotten`)
            if let c = current { removedHere(c) }
        case .replaced:
            state = .replaced
            disconnect()
        case .ended:
            state = .ended
            disconnect()
        case .fileProgress, .fileSaved, .fileFailed: break   // a phone sends no files
        case .noDirect:
            noDirect()
        case .streamMoved: break      // the channel reads it itself
        case .clipboard: break        // to a computer driving another (remote-desktop-viewer.md); a phone never asks for it
        case .screenLocked: break     // the picture stops at a lock screen; the phone keeps its last frame
        }
    }

    private var lastInfo: RemoteSessionInfo?

    /// The computer's own addresses, as it listed them this session: the private and overlay ones are kept to try next time, newest first.
    private func noteAddresses(_ list: [RemoteCandidate]) {
        let keep = list.map(\.host).filter(RemoteOverlay.worthTrying)
        guard !keep.isEmpty, var c = current, let n = macs.firstIndex(where: { $0.id == c.id && $0.deviceID == c.deviceID }) else { return }
        var seen = Set<String>()
        let next = Array((keep + c.addresses).filter { seen.insert($0).inserted }.prefix(8))
        guard next != c.addresses else { return }
        c.addresses = next
        macs[n] = c
        current = c
        saveMacs()
    }

    private func noteRelay(_ typed: String?) {
        let address = typed.flatMap(RemoteRelay.address)
        guard var c = current, c.relayAddress != address, let n = macs.firstIndex(where: { $0.id == c.id }) else { return }
        c.relayAddress = address
        macs[n] = c
        current = c
        saveMacs()
    }

    /// Show this display from now on, with the pointer in its middle; nil follows the pointer again.
    func showDisplay(_ id: String?) {
        pinnedDisplay = id
        if id != nil { ScreenStream.shared.displayAsked() }
        send(.showDisplay(id))
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

    /// The talk key held while the session isn't up (this phone taking the computer back, or just coming back to the app): it
    /// starts dictation once the session opens, if it's still held. A press already let go of stays dropped, like any key.
    private var talkHeld = false
    func dictationKey(down: Bool) {
        talkHeld = down
        guard state == .connected else { return }
        send(.dictationKey(down: down))
    }
    /// `inOrder`: behind what was sent before it, as a scroll right after the pointer was placed must be
    func pointer(_ p: RemotePointerPacket, inOrder: Bool = false) {
        var p = p
        if case let .move(x, y, _) = p { p = .move(dx: x, dy: y, seq: nextPointerSeq()) }
        // over the relay every message counts: 30 a second is plenty, and it's already no place for a fine stroke
        guard route == .relay else { return channel?.sendPointer(p, inOrder: inOrder) ?? () }
        switch p {
        case let .move(x, y, _):
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
        if let m = pendingMove { channel?.sendPointer(.move(dx: m.0, dy: m.1, seq: pointerSeq)) }
        if let s = pendingScroll { channel?.sendPointer(.scroll(dx: s.0, dy: s.1, phase: .changed)) }
        pendingMove = nil
        pendingScroll = nil
    }

    func audio(_ d: Data) { channel?.sendAudio(d) }
    func datagram(_ k: RemoteFrameKind, _ d: Data) { channel?.sendDatagram(k, d) }
    /// the last round trip, from any thread (the picture's receiver waits a few of these for a piece sent again)
    static var rttNow: Double { rttLock.lock(); defer { rttLock.unlock() }; return rttShared }
    static let rttLock = NSLock()
    nonisolated(unsafe) static var rttShared = 0.01
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
