// The iPhone remote, Mac side (docs/design/remote.md): Blurt listens on the local network for paired phones and turns what
// they send into pointer moves, keys and dictation.
//
//  • listens only once a phone is paired (or a QR code is showing). No paired phone, no open port.
//  • pairing (Settings → Phone): a QR code with a fresh key, good for one connection within two minutes, renewed while the
//    page shows it. Used over the relay, where a photo of it would otherwise do from anywhere, someone at the Mac has to allow it. The connection that uses it spends it, is sent a new key over the sealed session, and becomes a paired
//    device once the phone says it has kept that key. So a photo of the code, or a screen recording, is worth nothing later.
//  • found through Bonjour (`_blurt-remote._tcp`, including peer-to-peer Wi-Fi, so two devices with no shared network still
//    find each other); the TXT record has this Mac's id, which outlives its name and address. The port stays the same
//    across launches so a phone's last-known address keeps working.
//  • one phone drives at a time: a new session replaces the old one.
//  • nothing but the handshake is listened to before a session has greeted; at most `maxHandshakes` at a time.
//  • a session that goes quiet with anything held is let go of (`RemoteInput.releaseAll`, within `silence`): the phone
//    left the Wi-Fi, locked, or crashed, and its ⌘ or its dictation key must not stay down.
import AppKit
import ApplicationServices
import BlurtCore
import BlurtRemoteKit
import Network

final class RemoteServer {
    static let shared = RemoteServer()

    struct Device: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var added: Date
        var lastSeen: Date?
    }

    /// Published to the Settings page, always on the main thread.
    struct Status: Equatable {
        var listening = false
        var connected: String?
        var connectedID: String?
        /// a phone used the code over the relay, and waits for a yes
        var asking: String?
        /// the four digits the phone that's asking shows too, and which session it is
        var askingCheck: String?
        var askingNumber: UInt32?
        var udp = false
        var pairingLink: URL?
        var failure: String?
    }

    private static let serviceKeychain = "Blurt iPhone Remote"
    private static let silence = 2.0
    private static let pairingLife = 120.0
    private static let pairingGrace = 20.0
    private static let maxHandshakes = 16
    private static let maxSteps = 32
    private static let maxWaitMs = 3000
    private static let maxText = 64 * 1024
    /// a session this quiet is over, relay or not: the phone is gone, and the screen must not go on being captured for nobody
    private static let gone = 12.0
    /// test hooks (a code at once, keys in a file, an automatic yes): debug builds only, so no other program can borrow a release
    /// build's Screen Recording and microphone through them
    #if DEBUG || BLURT_TEST_HOOKS
    private static let testing = ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1"
    #else
    private static let testing = false
    #endif

    let queue = DispatchQueue(label: "blurt.remote", qos: .userInteractive)
    var onStatus: ((Status) -> Void)?
    var onDevices: (([Device]) -> Void)?
    private(set) var status = Status() { didSet { if status != oldValue { let s = status; DispatchQueue.main.async { self.onStatus?(s) } } } }

    private var udpFlows: [ObjectIdentifier: NWConnection] = [:]
    private var tcp: NWListener?
    private var udp: NWListener?
    private var udpPort: UInt16 = 0
    private var session: Session? {
        didSet {
            sessionLock.lock(); mirrored = session; sessionLock.unlock()
            watching = session != nil
        }
    }
    /// `session` for the main thread (dictation's levels and words, the front app, Blurt's commands): it changes on `queue`
    private var current: Session? { sessionLock.lock(); defer { sessionLock.unlock() }; return mirrored }
    /// the connected phone's name, as it gave it ("iPad")
    var phoneName: String? { current.map { $0.name.isEmpty ? nil : $0.name } ?? nil }
    private let sessionLock = NSLock()
    private var mirrored: Session?
    /// connections still in their handshake (a channel must outlive `tcpConnection`)
    private var handshaking: [ObjectIdentifier: Session] = [:]
    private var pairing: (id: String, key: Data, until: Date)?
    /// the code before this one: someone may have scanned it just as it was replaced
    private var oldCode: (id: String, key: Data, until: Date)?
    private var asking: Session?
    private var codeTries: [String: Int] = [:]
    private static let codeTries = 8
    private var pairingTimer: DispatchSourceTimer?
    private var showingPairing = false
    private var observers: [NSObjectProtocol] = []
    /// test builds never touch the login Keychain: a file in their own BLURT_HOME
    private var testKeysFile: URL { folder.appendingPathComponent("test-keys.json") }
    private var testKeys: [String: Data] {
        get { (try? Data(contentsOf: testKeysFile)).flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) } ?? [:] }
        set {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? JSONEncoder().encode(newValue).write(to: testKeysFile)
        }
    }

    private final class Session {
        let channel: RemoteChannel
        var id: String?
        var name = ""
        var micOnPhone = true
        var lastHeard = CACurrentMediaTime()
        var keyDown = false
        var udpSeen = false
        /// said hello, and if it came with a code, kept its new key: until then nothing it sends is acted on
        var greeted = false
        /// the code this session spent; the new key waits here for `.keyStored`
        var pairingKey: Data?
        /// `newKey` has gone: `keyStored` means nothing before that
        var keySent = false
        /// a new phone the owner said yes to on this Mac, this session: it may also set the relay, and drop the entry it replaces
        var approved = false
        /// revealed in the hello: with the handshake it makes the six digits
        var nonce: Data?
        /// when the question was asked: unanswered for two minutes, it's a no
        var askedAt = 0.0
        var screen: RemoteScreen?
        /// the display the phone chose to see; nil follows the pointer (docs/design/remote.md §Several displays)
        var pinned: CGDirectDisplayID?
        var heldReleased = false
        var punches = 0
        // gaps between the phone's 10 ms probes as they arrive: the pointer's own path, one way
        var lastProbe = 0.0
        var probeGaps: [Double] = []
        func probeArrived() {
            let now = CACurrentMediaTime()
            if lastProbe > 0 { probeGaps.append((now - lastProbe) * 1000) }
            lastProbe = now
        }
        func takeGaps() -> [String: Any] {
            let g = probeGaps.sorted()
            probeGaps = []
            guard !g.isEmpty else { return [:] }
            func p(_ x: Double) -> Double { (g[min(g.count - 1, Int(Double(g.count) * x))] * 10).rounded() / 10 }
            return ["gap_p50": p(0.5), "gap_p95": p(0.95), "gap_p99": p(0.99), "gap_p999": p(0.999), "gap_max": p(1), "n": g.count]
        }
        let number = UInt32.random(in: 1 ... .max)
        init(_ c: RemoteChannel) { channel = c }
    }

    // MARK: identity and devices

    private var folder: URL { BlurtPaths.home.appendingPathComponent("remote") }
    private var devicesFile: URL { folder.appendingPathComponent("devices.json") }

    var macID: String {
        if let s = Config.shared["record.remote.mac_id"] as? String, !s.isEmpty { return s }
        let s = RemoteCrypto.newID()
        Config.shared.set("record.remote.mac_id", s)
        return s
    }

    private var savedPort: UInt16 { (Config.shared["record.remote.port"] as? Int).flatMap { UInt16(exactly: $0) } ?? 0 }

    /// read once, kept: a stranger's hello must not cost a disk read
    private var deviceCache: [Device]?
    private let cacheLock = NSLock()
    func devices() -> [Device] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let deviceCache { return deviceCache }
        let list = (try? Data(contentsOf: devicesFile)).flatMap { try? JSONDecoder().decode([Device].self, from: $0) } ?? []
        deviceCache = list
        return list
    }

    private func save(_ list: [Device]) {
        cacheLock.lock()
        deviceCache = list
        cacheLock.unlock()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let d = try? JSONEncoder().encode(list) {
            try? d.write(to: devicesFile, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: devicesFile.path)
        }
        DispatchQueue.main.async { self.onDevices?(list) }
    }

    private func keychainQuery(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.serviceKeychain, kSecAttrAccount as String: id]
    }

    private func storedKey(_ id: String) -> Data? {
        if Self.testing { return testKeys[id] }
        var q = keychainQuery(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    private func store(_ key: Data, for id: String) {
        if Self.testing { testKeys[id] = key; return }
        var q = keychainQuery(id)
        q[kSecValueData as String] = key
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecAttrLabel as String] = Self.serviceKeychain
        SecItemAdd(q as CFDictionary, nil)
    }

    func remove(_ id: String) {
        queue.async {
            if Self.testing { self.testKeys[id] = nil } else { SecItemDelete(self.keychainQuery(id) as CFDictionary) }
            self.save(self.devices().filter { $0.id != id })
            guard self.session?.id == id else { return self.updateListening() }
            // the phone hears it first, or it would only see the connection go and keep trying
            self.session?.channel.send(ToPhone.removed)
            self.queue.asyncAfter(deadline: .now() + 0.3) {
                self.end()
                self.updateListening()
                self.relays[id]?.channel.close()
            }
        }
    }

    private func code(_ id: String) -> (id: String, key: Data, until: Date)? {
        [pairing, oldCode].compactMap { $0 }.first { $0.id == id && $0.until > Date() }
    }

    private func key(for id: String) -> Data? {
        if let c = code(id) { return c.key }
        return devices().contains { $0.id == id } ? storedKey(id) : nil
    }

    // MARK: start

    /// At launch: listen if a phone is paired.
    func install() {
        queue.async { self.updateListening() }
        // tests: a code at once, and every input event on stdout instead of on the screen
        if Self.testing, ProcessInfo.processInfo.environment["BLURT_TEST_REMOTE"] == "1" {
            RemoteInput.shared.testLog = { emit(["event": "remote_input", "line": $0]) }
            showPairing(true)
        }
        let c = NotificationCenter.default, w = NSWorkspace.shared.notificationCenter
        observers.append(w.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sendFront()
        })
        // whatever was open has died in the sleep, and a timer may be well into a long wait: back on the relay now
        observers.append(w.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.queue.async {
                guard let self else { return }
                let open = self.relays.filter { $0.value !== self.session }
                open.keys.forEach { self.relays[$0] = nil }
                open.values.forEach { $0.channel.close() }
                self.relayWait = [:]
                self.updateRelays()
            }
        })
        // the phone draws the arrangement and switches between them: it hears of every change
        RemoteDisplayList.watch { [weak self] in self?.queue.async { self?.displaysChanged() } }
        observers.append(c.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.queue.sync { self?.end(); self?.stopListening() }
        })
        // the session's watch: silence, and whether macOS lets us post events. It runs only while a phone is connected
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 0.5, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.watch() }
        queue.async {
            self.watcher = t
            if self.session != nil { t.resume(); self.watcherRunning = true }
        }
    }
    private var watcher: DispatchSourceTimer?
    private var watcherRunning = false
    /// on `queue`: the watch runs while there's a session, and nobody else's Mac wakes twice a second for it
    private var watching: Bool {
        get { watcherRunning }
        set {
            guard let w = watcher, newValue != watcherRunning else { return }
            watcherRunning = newValue
            // a phone starts out assuming it may control the Mac: the first tick tells it otherwise
            if newValue { lastControl = true; w.resume() } else { w.suspend() }
        }
    }
    private var lastControl = true

    private func updateListening() {
        let want = showingPairing || !devices().isEmpty
        if want, tcp == nil { startListening() } else if !want, tcp != nil { stopListening() }
        updateRelays()
    }

    private func startListening() {
        do {
            let udpParams = NWParameters.udp
            udpParams.includePeerToPeer = RemoteChannel.peerToPeer
            udpParams.allowLocalEndpointReuse = true
            // the picture and the pointer's place: the Mac's own Wi-Fi sends them in the video access category, ahead of a download
            // (docs/design/remote-realtime.md §Marking). Voice is for small packets; a frame's burst in it would lose aggregation. macOS
            // writes no DSCP for it unless the network is QoS-capable (measured: TOS 0), so the access point's side is unchanged
            udpParams.serviceClass = .interactiveVideo
            let u = try NWListener(using: udpParams, on: .any)
            u.newConnectionHandler = { [weak self] c in self?.udpConnection(c) }
            u.stateUpdateHandler = { [weak self] s in
                guard let self else { return }
                if case .ready = s, let p = u.port?.rawValue { self.udpPort = p }
            }
            u.start(queue: queue)
            udp = u

            let params = NWParameters.tcp
            params.includePeerToPeer = RemoteChannel.peerToPeer
            if let o = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options { o.noDelay = true }
            params.serviceClass = .interactiveVideo
            let port = NWEndpoint.Port(rawValue: savedPort) ?? .any
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: port)
            var txt = NWTXTRecord()
            txt["id"] = macID
            l.service = NWListener.Service(type: RemotePairing.serviceType, txtRecord: txt)
            l.newConnectionHandler = { [weak self] c in self?.tcpConnection(c) }
            l.stateUpdateHandler = { [weak self] s in self?.listenerState(s, l) }
            l.start(queue: queue)
            tcp = l
        } catch {
            emit(["event": "remote_listen_failed", "why": "\(error)"])
            status.failure = "\(error)"
        }
    }

    private func listenerState(_ s: NWListener.State, _ l: NWListener) {
        switch s {
        case .ready:
            if let p = l.port?.rawValue, p != savedPort { Config.shared.set("record.remote.port", Int(p)) }
            status.listening = true
            status.failure = nil
            emit(["event": "remote_listening", "port": Int(l.port?.rawValue ?? 0)])
            if showingPairing { renewPairing() }
        case let .failed(e):
            emit(["event": "remote_listen_failed", "why": "\(e)"])
            status.listening = false
            status.failure = "\(e)"
            // the saved port went to someone else: any free one
            if case .posix(.EADDRINUSE) = e {
                Config.shared.set("record.remote.port", nil)
            }
            stopListening()
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.updateListening() }
        default: break
        }
    }

    private func stopListening() {
        tcp?.cancel(); tcp = nil
        udp?.cancel(); udp = nil
        dropFlows()
        status.listening = false
    }

    // MARK: pairing

    /// The Settings page is showing the QR code.
    func showPairing(_ on: Bool) {
        queue.async {
            self.showingPairing = on
            self.updateListening()
            if on, self.tcp?.state == .ready { self.renewPairing() }
            if !on {
                self.pairingTimer?.cancel(); self.pairingTimer = nil
                self.pairing = nil
                self.oldCode = nil
                self.status.pairingLink = nil
                self.updateRelays()
            }
        }
    }

    private func renewPairing() {
        guard showingPairing, let port = tcp?.port?.rawValue else { return }
        let id = RemoteCrypto.newID(), key = RemoteCrypto.newKey()
        oldCode = pairing
        pairing = (id, key, Date().addingTimeInterval(Self.pairingLife))
        status.pairingLink = RemotePairing(macID: macID, deviceID: id, key: key, macName: Host.current().localizedName ?? "Mac", port: port,
                                           addresses: Self.addresses(), relay: Self.relayAddress).url
        updateRelays()
        if Self.testing { emit(["event": "remote_pairing", "link": status.pairingLink?.absoluteString ?? ""]) }
        pairingTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.pairingLife - Self.pairingGrace)
        t.setEventHandler { [weak self] in self?.renewPairing() }
        t.resume()
        pairingTimer = t
        // the code before this one has run out by then
        queue.asyncAfter(deadline: .now() + Self.pairingGrace + 1) { [weak self] in
            guard let self, let o = self.oldCode, o.until <= Date() else { return }
            self.oldCode = nil
            self.updateRelays()
        }
    }

    /// This Mac's LAN addresses (IPv4), Wi-Fi and Ethernet first.
    static func addresses() -> [String] {
        var out: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let a = i.ifa_addr, a.pointee.sa_family == UInt8(AF_INET), i.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  i.ifa_flags & UInt32(IFF_UP) != 0, String(cString: i.ifa_name).hasPrefix("en") || String(cString: i.ifa_name).hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { out.append(String(cString: host)) }
        }
        return out
    }

    // MARK: connections

    private func tcpConnection(_ c: NWConnection) {
        guard handshaking.count < Self.maxHandshakes else { return c.cancel() }
        wire(c, relay: nil)
    }

    private func wire(_ c: NWConnection, relay deviceID: String?) {
        let ch = RemoteChannel(connection: c, role: .mac(lookup: { [weak self] id in
            guard let self else { return nil }
            return self.queue.sync {
                // a code answers a few handshakes, no more: enough for a phone trying several ways at once, too few to try for digits
                if self.code(id) != nil {
                    self.codeTries[id, default: 0] += 1
                    if self.codeTries[id, default: 0] > Self.codeTries { return nil }
                }
                return self.key(for: id)
            }
        }), relay: deviceID != nil, standby: deviceID != nil, queue: DispatchQueue(label: "blurt.remote.session", qos: .userInteractive))
        let s = Session(ch)
        ch.onOpen = { [weak self, weak s] id in
            guard let self, let s else { return }
            self.queue.async { self.opened(s, id: id) }
        }
        ch.onControl = { [weak self, weak s] d in
            guard let self, let s, let m = try? JSONDecoder().decode(ToMac.self, from: d) else { return }
            s.lastHeard = CACurrentMediaTime()
            self.handle(m, s)
        }
        ch.onAudio = { [weak s] d in if s?.greeted == true { RemoteMicFeed.shared.receive(d) } }
        ch.onProbe = { [weak ch, weak s] d in
            ch?.sendDatagram(.probe, d)
            s?.probeArrived()
        }
        // pieces missing, frames decoded, a frame lost: the picture repairs itself (docs/design/remote-realtime.md)
        ch.onVideoFeedback = { [weak s] d in if s?.greeted == true { s?.screen?.feedback(d) } }
        ch.onPointer = { [weak self, weak s] p in
            guard let s, s.greeted else { return }
            s.lastHeard = CACurrentMediaTime()
            self?.pointer(p)
        }
        ch.onClose = { [weak self, weak s] _ in
            guard let self, let s else { return }
            self.queue.async {
                self.handshaking[ObjectIdentifier(s)] = nil
                self.closed(s)
                if let deviceID { self.relayEnded(deviceID, s) }
            }
        }
        if let deviceID { relays[deviceID] = s } else { handshaking[ObjectIdentifier(s)] = s }
        ch.start()
    }

    // MARK: the relay

    /// One waiting connection per paired phone, while a relay address is set. A phone leaving ends the connection (that's how
    /// the next one starts a clean session): one comes back at once. A failure waits longer each time.
    private var relays: [String: Session] = [:]
    private var relayWait: [String: Double] = [:]
    private var relayAt: String?
    /// the code that let a phone in over the relay: its connection carries that session until it ends
    private var spentCode: String?
    /// Set up by the owner (Settings → Phone, tools/remote-relay). No address, no relay: Blurt doesn't run one.
    /// Never set here, as against cleared by the owner: only then may a phone offer the one it knows.
    static var relayUnset: Bool { Config.shared["record.remote.relay_url"] == nil }
    static var relayAddress: String? { (Config.shared["record.remote.relay_url"] as? String).flatMap(RemoteRelay.address) }
    static var relayOn: Bool { relayAddress != nil }
    /// Settings → Phone: a paired phone may ask for the screen
    static var screenAllowed: Bool { Config.shared["record.remote.screen"] as? Bool ?? true }

    func relayChanged() {
        queue.async {
            self.session?.channel.send(ToPhone.relay(Self.relayAddress))     // first: it may be riding on the connection this closes
            self.updateRelays()
            if self.showingPairing, self.tcp?.state == .ready { self.renewPairing() }   // the code carries the address
        }
    }

    func screenSettingChanged() {
        queue.async {
            guard !Self.screenAllowed, let s = self.session, s.screen != nil else { return }
            s.screen?.stop()
            s.screen = nil
            self.keepAwake(displayToo: false)
            s.channel.send(ToPhone.screenFailed("off"))
        }
    }

    /// Blurt's settings page follows, if it's open.
    var onRelayAdopted: ((String) -> Void)?

    /// A paired phone may already do everything on this Mac; its relay is the owner's own.
    private func adoptRelay(_ typed: String) {
        guard Self.relayUnset, let a = RemoteRelay.address(typed) else { return }
        Config.shared.set("record.remote.relay_url", a)
        emit(["event": "remote_relay", "state": "adopted"])
        relayChanged()
        DispatchQueue.main.async { self.onRelayAdopted?(a) }
    }

    private func updateRelays() {
        let on = Self.relayOn
        // a code showing counts: a phone on another network can pair through the relay too
        let ids = Set(devices().map(\.id)).union([pairing, oldCode].compactMap { $0?.id })
        // a changed address counts as gone: the phone has been told the new one
        for (id, s) in relays where !on || !(ids.contains(id) || (id == spentCode && (s === session || s === asking))) || relayAt != Self.relayAddress {
            relays[id] = nil
            s.channel.close()
        }
        relayAt = Self.relayAddress
        guard on else { return }
        for id in ids where relays[id] == nil { connectRelay(id) }
    }

    private func connectRelay(_ id: String) {
        guard let a = Self.relayAddress, relays[id] == nil, let k = code(id)?.key ?? (devices().contains { $0.id == id } ? storedKey(id) : nil),
              let c = RemoteRelay.connection(address: a, room: RemoteRelay.room(key: k), role: "mac") else { return }
        emit(["event": "remote_relay", "state": "waiting"])
        wire(c, relay: id)
    }

    private func relayEnded(_ id: String, _ s: Session) {
        guard relays[id] === s else { return }
        relays[id] = nil
        let clean = s.channel.relayClose == RemoteRelay.phoneLeft || s.greeted
        // a failure waits longer each time, but not so long that a bad hello now and then keeps the phone off the relay
        let wait = clean ? 0.5 : min((relayWait[id] ?? 1) * 2, 8)
        relayWait[id] = clean ? 1 : wait
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in self?.connectRelay(id) }
    }

    private func opened(_ s: Session, id: String?) {
        handshaking[ObjectIdentifier(s)] = nil
        // the key the handshake used must still be this id's key: removed, its code spent or renewed, or the phone paired again since,
        // and a handshake begun with it, perhaps hours ago on a waiting relay connection, opens nothing
        guard let id, let now = key(for: id), let used = s.channel.pairedKey, RemoteCrypto.same(now, used) else {
            emit(["event": "remote_session", "state": "refused", "why": "stale_key"])
            return s.channel.close()
        }
        s.id = id
        // the code is spent the moment it opens a session
        if code(id) != nil {
            // one new phone at a time: a second one using a code while the first waits is turned away, so a yes can't go to it
            if let a = asking, a !== s {
                emit(["event": "remote_pairing_refused", "why": "busy"])
                return s.channel.close()
            }
            s.pairingKey = RemoteCrypto.newKey()
            let current = pairing?.id == id
            if current { pairing = nil } else { oldCode = nil }
            spentCode = id
            // whoever holds a picture of the code, on any network: nothing until someone here says yes, comparing the four digits
            asking = s
            // nothing else may come in on this code: the relay connection waiting in its room goes
            if let r = relays[id], r !== s { relays[id] = nil; r.channel.close() }
            if current, showingPairing { renewPairing() }
            return
        }
        takeOver(s)
    }

    private func takeOver(_ s: Session) {
        // the phone that had the session gives way
        if let old = session, old !== s {
            if old.id != s.id { old.channel.send(ToPhone.replaced) }
            closed(old)
            old.channel.queue.asyncAfter(deadline: .now() + 0.2) { old.channel.close() }
        }
        session = s
        RemoteInput.shared.forgetPhone()      // another phone, or this one started again: its numbers start over
        emit(["event": "remote_session", "state": "open", "relay": s.channel.isRelay])
    }

    private func closed(_ s: Session) {
        if asking === s {
            asking = nil
            status.asking = nil
            status.askingCheck = nil
            status.askingNumber = nil
        }
        guard session === s else { return }
        session = nil
        s.screen?.stop()
        s.screen = nil
        keepAwake(false)
        status.connected = nil
        status.connectedID = nil
        status.udp = false
        dropFlows()
        letGo(s)
        DispatchQueue.main.async { RemoteMicFeed.shared.sessionEnded() }
        emit(["event": "remote_session", "state": "closed"])
    }

    private func end() {
        if let s = session { s.channel.close(); closed(s) }
    }

    private func letGo(_ s: Session) {
        RemoteInput.shared.queue.async { RemoteInput.shared.releaseAll() }
        if s.keyDown {
            s.keyDown = false
            DispatchQueue.main.async { Dictation.shared.remoteKey(down: false) }
        }
    }

    private func watch() {
        let ok = canControl
        if ok != lastControl {
            lastControl = ok
            session?.channel.send(ToPhone.canControl(ok))
        }
        if let s = session {
            let quiet = CACurrentMediaTime() - s.lastHeard
            if quiet > Self.gone {
                emit(["event": "remote_session", "state": "gone"])
                s.channel.close()
                closed(s)
            } else if quiet > Self.silence, !s.heldReleased {
                emit(["event": "remote_session", "state": "silent"])
                s.heldReleased = true
                letGo(s)
            } else if quiet <= Self.silence {
                s.heldReleased = false
            }
        }
    }

    var canControl: Bool { Self.testing || AXIsProcessTrusted() }

    private func handle(_ m: ToMac, _ s: Session) {
        let input = RemoteInput.shared
        switch m {
        case let .hello(device, mic, nonce):
            s.name = String(device.prefix(64))
            s.micOnPhone = mic
            s.nonce = nonce
            queue.async { self.greet(s) }
            return
        case .keyStored:
            queue.async { self.keyStored(s) }
            return
        case let .ping(t):
            s.channel.send(ToPhone.pong(t))
            if !s.channel.isRelay { s.channel.send(ToPhone.clock(phone: t, mac: CACurrentMediaTime())) }
            return
        default: break
        }
        guard s.greeted else { return }
        switch m {
        case .hello, .keyStored, .ping: break
        case let .screen(r):
            // on the server's queue, where `closed` runs: a capture can't start for a session that has just ended
            queue.async {
                guard self.session === s else { return }
                s.screen?.stop()
                s.screen = nil
                self.keepAwake(displayToo: false)
                guard let r else { return }
                guard Self.screenAllowed else { return s.channel.send(ToPhone.screenFailed("off")) }
                // the phone says what it last chose, so a picture turned on again shows what it showed
                var asked = r
                s.pinned = RemoteDisplayList.id(asked.display)
                asked.display = s.pinned.map { String($0) }
                let screen = RemoteScreen(channel: s.channel)
                screen.onInfo = { [weak s] m in s?.channel.send(m) }
                screen.onStopped = { [weak self] in self?.queue.async { self?.keepAwake(displayToo: false) } }
                s.screen = screen
                self.keepAwake(displayToo: true)
                screen.start(asked) { why in s.channel.send(ToPhone.screenFailed(why)) }
            }
        case let .screenCrop(c):
            s.screen?.setCrop(c)
        case let .screenReport(r):
            s.screen?.report(r)
        case let .screenPace(idle):
            s.screen?.pace(idle: idle)
        case .unpair:
            if let id = s.id { remove(id) }
        case let .replaces(id):
            // only a phone the owner just said yes to may drop its own older entry
            guard s.approved, id != s.id, devices().contains(where: { $0.id == id }) else { return }
            remove(id)
        case let .offerRelay(a):
            // and only it may set the relay: another paired phone, or a Mac's, can't point this one somewhere else
            guard s.approved else { return }
            queue.async { self.adoptRelay(a) }
        case let .showDisplay(id):
            queue.async { self.showDisplay(id, s) }
        case let .pointerTo(x, y, seq):
            // its number counts even with no picture to place it on: the phone waits for it
            let p = s.screen?.pointerTo(x: x, y: y)
            input.queue.async {
                if let p { input.place(p) }
                input.made(seq)
            }
        case let .candidates(list):
            guard s.punches < 3 else { return }
            s.punches += 1
            queue.async { self.punch(list) }
        case .requestKeyframe:
            s.screen?.keyframe()
        case let .screenStats(json):
            s.channel.queue.async { emit(["event": "remote_screen_phone", "stats": json, "uplink": s.takeGaps()]) }
        case let .screenSnapshot(name, jpeg):
            guard Self.testing, let dir = ProcessInfo.processInfo.environment["BLURT_SCREEN_SNAP_DIR"], !name.contains("/"), !name.hasPrefix(".") else { return }
            try? jpeg.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".jpg"))
        case let .setMicOnPhone(on):
            s.micOnPhone = on
            // a note waiting on the phone's microphone that the phone can't have: heard through this Mac's instead
            if !on { DispatchQueue.main.async { VoiceInput.shared.phoneMicUnavailable() } }
        case let .key(c, down):
            input.queue.async { if let down { input.hold(c, down: down) } else { input.press(c) } }
            // a modifier pressed on its own shows too: it may have switched the input method
            if down != false, !c.key.isEmpty || (down == nil && !c.mods.isEmpty) { RemoteHUD.show(c.label) }
        case let .mods(mods):
            input.queue.async { input.setSticky(mods) }
            RemoteHUD.sticky(mods)
        case let .run(steps):
            guard steps.count <= Self.maxSteps else { return }
            let waits = steps.reduce(0) { if case let .wait(ms) = $1 { $0 + min(max(ms, 0), Self.maxWaitMs + 1) } else { $0 } }   // no overflow
            guard waits <= Self.maxWaitMs else { return }
            input.queue.async { input.run(steps) }
            let keys = steps.compactMap { if case let .key(c) = $0 { c.label } else { nil } }
            if !keys.isEmpty { RemoteHUD.show(keys.joined(separator: " ")) }
        case let .text(t):
            guard t.utf8.count <= Self.maxText else { return }
            input.queue.async { RemoteText.type(t, input: input) }
        case let .button(b, down):
            input.queue.async { input.button(b, down: down) }
        case .dragBegin:
            input.queue.async { input.dragBegin() }
        case let .dictationKey(down):
            s.keyDown = down
            let mic = s.micOnPhone
            if down { RemoteMicFeed.shared.clear() }    // the end of the last take isn't the start of this one
            DispatchQueue.main.async {
                RemoteMicFeed.shared.pressed = mic
                Dictation.shared.remoteKey(down: down)
            }
        case let .blurt(c):
            DispatchQueue.main.async { self.blurt(c) }
        case let .system(move):
            system(move)
        case let .activate(bundle):
            DispatchQueue.main.async {
                if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                    NSWorkspace.shared.openApplication(at: u, configuration: .init())
                }
            }
        case let .hud(t):
            RemoteHUD.show(t)
        case .releaseAll:
            letGo(s)
        }
    }

    /// Packets out to where the phone may be, from the port it's knocking on: they open this side's firewall. They carry nothing.
    private func punch(_ list: [RemoteCandidate]) {
        guard udpPort != 0, let local = NWEndpoint.Port(rawValue: udpPort) else { return }
        for k in list.prefix(8) {
            guard let p = NWEndpoint.Port(rawValue: k.port) else { continue }
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(host: k.host.contains(":") ? "::" : "0.0.0.0", port: local)
            let c = NWConnection(host: NWEndpoint.Host(k.host), port: p, using: params)
            c.stateUpdateHandler = { s in
                guard case .ready = s else { return }
                for i in 0..<8 {
                    self.queue.asyncAfter(deadline: .now() + Double(i) * 0.25) { c.send(content: Data([0]), completion: .idempotent) }
                }
            }
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { c.cancel() }
        }
    }

    /// The Mac stays awake while a phone is connected, and its display while it's being watched: no one is at it to nudge the mouse.
    private var awake: NSObjectProtocol?
    private func keepAwake(_ on: Bool = true, displayToo: Bool = false) {
        if let a = awake { ProcessInfo.processInfo.endActivity(a); awake = nil }
        guard on else { return }
        awake = ProcessInfo.processInfo.beginActivity(options: displayToo ? [.idleSystemSleepDisabled, .idleDisplaySleepDisabled] : .idleSystemSleepDisabled,
                                                      reason: "iPhone remote")
    }

    private func greet(_ s: Session) {
        if asking === s {
            // no digits that match what the handshake committed to, no question
            guard let n = s.nonce, let check = s.channel.check(revealing: n) else {
                asking = nil
                s.channel.close()
                return closed(s)
            }
            status.asking = s.name
            status.askingCheck = check
            status.askingNumber = s.number
            // nobody answers: after two minutes it's a no, so a question left open can't keep everyone else waiting
            queue.asyncAfter(deadline: .now() + Self.pairingLife) { [weak self, weak s] in
                guard let self, let s, self.asking === s else { return }
                self.answerPairing(false, number: s.number)
            }
            emit(["event": "remote_pairing_asks"])
            s.channel.send(ToPhone.pairingWaits)
            if Self.testing, let a = ProcessInfo.processInfo.environment["BLURT_TEST_PAIR_ANSWER"] {
                queue.asyncAfter(deadline: .now() + 3) { self.answerPairing(a == "yes") }
            }
            return
        }
        guard session === s, let id = s.id else { return }
        if let k = s.pairingKey {
            s.keySent = true
            s.channel.send(ToPhone.newKey(k))   // `keyStored` finishes it
            return
        }
        var list = devices()
        if let i = list.firstIndex(where: { $0.id == id }) {
            list[i].lastSeen = Date()
            list[i].name = s.name
            save(list)
        }
        begin(s)
    }

    /// Settings: yes or no to the phone that used the code over the relay.
    /// `number`: the session the question was about, so a yes given to one can't go to another
    func answerPairing(_ yes: Bool, number: UInt32? = nil) {
        queue.async {
            guard let s = self.asking, number == nil || number == s.number else { return }
            self.asking = nil
            self.status.asking = nil
            self.status.askingCheck = nil
            self.status.askingNumber = nil
            if yes {
                s.approved = true
                self.takeOver(s)
                self.greet(s)
            } else {
                s.channel.close()
                self.closed(s)
            }
        }
    }

    private func keyStored(_ s: Session) {
        guard session === s, s.keySent, let id = s.id, let k = s.pairingKey else { return }
        s.pairingKey = nil
        store(k, for: id)
        save(devices() + [Device(id: id, name: s.name, added: Date(), lastSeen: Date())])
        begin(s)
        // a relay connection still in the code's room goes; the next waits in the new key's
        if let r = relays[id], r !== s { relays[id] = nil; r.channel.close() }
        updateRelays()
    }

    private func begin(_ s: Session) {
        s.greeted = true
        status.connected = s.name
        status.connectedID = s.id
        keepAwake()
        let info = { (list: [RemoteCandidate]) in
            let main = CGDisplayBounds(CGMainDisplayID())
            s.channel.send(ToPhone.session(RemoteSessionInfo(macName: Host.current().localizedName ?? "Mac", udpPort: self.udpPort, udpSession: s.number, canControl: self.canControl,
                                                             version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                                                             candidates: list, displayAspect: main.height > 0 ? Double(main.width / main.height) : 1.6, relay: Self.relayAddress, platform: RemoteHost.mac.rawValue)))
        }
        if s.channel.isRelay {
            // where the phone might reach this Mac without the relay
            var list = Self.addresses().map { RemoteCandidate(host: $0, port: udpPort) }
            list += RemoteAddresses.publicIPv6().map { RemoteCandidate(host: $0, port: udpPort) }
            RemoteSTUN.ask(from: udpPort, queue: queue) { found in
                if let found { list.append(found) }
                info(list)
                s.channel.send(ToPhone.displays(RemoteDisplayList.all()))
                self.sendFront()
                DispatchQueue.main.async { self.dictationChanged(Dictation.shared.remotePhase) }
            }
            return
        }
        info([])
        s.channel.send(ToPhone.displays(RemoteDisplayList.all()))
        sendFront()
        DispatchQueue.main.async { self.dictationChanged(Dictation.shared.remotePhase) }
    }

    /// The phone chose a display: shown from now on, with the pointer in its middle, where the eyes go next; nil follows the pointer again.
    private func showDisplay(_ asked: String?, _ s: Session) {
        guard session === s else { return }
        if asked != nil, RemoteDisplayList.id(asked) == nil { return }      // gone since the phone heard of it
        let id = RemoteDisplayList.id(asked)
        s.pinned = id
        s.screen?.show(id)
        emit(["event": "remote_display", "state": id == nil ? "follow" : "pinned", "display": Int(id ?? 0)])
        guard let id else { return }
        let b = CGDisplayBounds(id)
        let input = RemoteInput.shared
        input.queue.async { input.place(CGPoint(x: b.midX, y: b.midY)) }
        RemoteHUD.show(RemoteDisplayList.name(id), on: id)
    }

    /// Plugged in, unplugged, rearranged: the phone redraws its map, and a display that went is no longer chosen.
    private func displaysChanged() {
        guard let s = session, s.greeted else { return }
        let list = RemoteDisplayList.all()
        emit(["event": "remote_displays", "count": list.count])
        s.channel.send(ToPhone.displays(list))
        if let p = s.pinned, !list.contains(where: { $0.id == String(p) }) { s.pinned = nil }
        s.screen?.displaysChanged()
    }

    private func pointer(_ p: RemotePointerPacket) {
        let input = RemoteInput.shared
        input.queue.async {
            switch p {
            case let .move(x, y, seq): input.move(dx: CGFloat(x), dy: CGFloat(y)); input.made(seq)
            case let .scroll(x, y, phase): input.scroll(dx: CGFloat(x), dy: CGFloat(y), phase: phase)
            case let .scrollFling(x, y): input.fling(vx: CGFloat(x), vy: CGFloat(y))
            case .scrollStop: input.stopCoast()
            }
        }
    }

    private func blurt(_ c: RemoteBlurtCommand) {
        let center = HotkeyCenter.shared
        switch c {
        case .snap: center.onFire?(.snap)
        case .record: center.onFire?(.toggleRecord)
        case .voiceNote:
            // a note to start, from a phone that uses its own microphone: heard through it, as dictation is
            let input = VoiceInput.shared
            // only when nothing else is listening: dictation may be using the phone's microphone right now
            var asked = false
            let session = current
            if !input.active, Dictation.shared.phase != .listening, session?.micOnPhone == true, let s = session {
                RemoteMicFeed.shared.clear()
                RemoteMicFeed.shared.onListen = { [weak s] on in s?.channel.send(ToPhone.listen(on)) }
                s.channel.send(ToPhone.listen(true))
                input.phoneFeed = RemoteMicFeed.shared
                asked = true
            }
            // a tap on the phone: start, or stop the one going, whatever the voice key's mode (no key-up comes to end a held one)
            if input.active { input.toggle() } else { center.onFire?(.voice) }
            // asked for the phone's microphone and the note didn't start after all: it can let it go
            if asked, input.phoneFeed != nil || !input.active {
                input.phoneFeed = nil
                session?.channel.send(ToPhone.listen(false))
            }
        case .copyText: center.onFire?(.text)
        case .translate: center.onFire?(.translateText)
        case .cards: center.onFire?(.cards)
        case .dictationCancel: Dictation.shared.cancel()
        case .dictationStructured: Dictation.shared.remoteToggleStyle()
        case .dictationTranslate: Dictation.shared.remoteToggleTranslate()
        case .dictationSend: Dictation.shared.remoteSend()
        }
    }

    private func system(_ m: RemoteSystemMove) {
        let input = RemoteInput.shared
        let chord: RemoteChord? = switch m {
        case .missionControl: RemoteChord(.control, "Up")
        case .appExpose: RemoteChord(.control, "Down")
        case .spaceLeft: RemoteChord(.control, "Left")
        case .spaceRight: RemoteChord(.control, "Right")
        case .zoomIn: RemoteChord(.command, "=")
        case .zoomOut: RemoteChord(.command, "-")
        case .findCursor: nil
        }
        if let chord {
            input.queue.async { input.press(chord) }
            RemoteHUD.show(chord.label)
        } else {
            RemoteHUD.findCursor()
        }
    }

    // MARK: what the phone is told

    private func sendFront() {
        guard let a = NSWorkspace.shared.frontmostApplication, let b = a.bundleIdentifier else { return }
        current?.channel.send(ToPhone.front(RemoteFront(bundle: b, name: a.localizedName ?? b)))
    }

    func dictationChanged(_ p: RemoteDictationPhase) { current?.channel.send(ToPhone.dictation(p)) }
    func live(committed: String, pending: String) { current?.channel.send(ToPhone.live(committed: committed, pending: pending)) }
    func level(_ l: Float) { current?.channel.send(ToPhone.level(l)) }
    func typed(_ t: String) { current?.channel.send(ToPhone.typed(t)) }

    // MARK: UDP

    /// One flow per source address, made by the listener: only the session's is kept. A packet that isn't for the session
    /// ends its flow on the spot, so a stranger's spoofed ports cost nothing that lasts.
    private func udpConnection(_ c: NWConnection) {
        guard udpFlows.count < 8 else { return c.cancel() }
        udpFlows[ObjectIdentifier(c)] = c
        c.stateUpdateHandler = { [weak self] s in
            switch s {
            case .failed, .cancelled: self?.udpFlows[ObjectIdentifier(c)] = nil
            default: break
            }
        }
        c.start(queue: queue)
        receive(c)
    }

    private func dropFlows() {
        let f = udpFlows.values
        udpFlows = [:]
        f.forEach { $0.cancel() }
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, err in
            guard let self else { return }
            guard err == nil, let data, let s = self.session, s.greeted, RemoteSealer.sessionOfPacket(data) == s.number else { return c.cancel() }
            s.channel.queue.async {
                guard s.channel.packet(data) else { return }
                s.channel.useFlow(c)
                s.lastHeard = CACurrentMediaTime()
                if !s.udpSeen {
                    s.udpSeen = true
                    emit(["event": "remote_udp", "state": "ok", "relay": s.channel.isRelay])
                    s.channel.send(ToPhone.udpOK)
                    if s.channel.isRelay { s.channel.sendDatagram(.probe, Data(count: 8)) }    // the way back works too: the phone switches
                    self.queue.async { self.status.udp = true }
                }
            }
            self.receive(c)
        }
    }
}

/// The phone's microphone as the source of a dictation: what NoteVoice takes in place of the Mac's mic. Samples may arrive
/// before the take has started (the phone sends from the key-down); they wait here, the last second of them.
final class RemoteMicFeed {
    static let shared = RemoteMicFeed()
    /// the press came from a phone that wants its own mic used
    var pressed = false
    /// tells the phone to send its microphone, or to stop (a voice note started from it)
    var onListen: ((Bool) -> Void)?
    private var waiting: [[Float]] = []
    private var sink: (([Float]) -> Void)?
    private let lock = NSLock()

    var onGone: (() -> Void)?

    func receive(_ pcm: Data) {
        let n = pcm.count / 2
        var x = [Float](repeating: 0, count: n)
        pcm.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            for i in 0..<n { x[i] = Float(Int16(littleEndian: b.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768 }
        }
        lock.lock()
        let s = sink
        if s == nil {
            waiting.append(x)
            while waiting.reduce(0, { $0 + $1.count }) > 16000 { waiting.removeFirst() }
        }
        lock.unlock()
        if let s { DispatchQueue.main.async { s(x) } }
    }

    func attach(_ s: @escaping ([Float]) -> Void) {
        lock.lock()
        let held = waiting
        waiting = []
        sink = s
        lock.unlock()
        for x in held { s(x) }
    }

    func detach() {
        lock.lock()
        sink = nil
        waiting = []
        lock.unlock()
    }

    func clear() {
        lock.lock()
        waiting = []
        lock.unlock()
    }

    func sessionEnded() {
        pressed = false
        onGone?()
    }
}
