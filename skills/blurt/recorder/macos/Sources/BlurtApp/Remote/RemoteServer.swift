// The iPhone remote, Mac side (docs/design/remote.md): Blurt listens on the local network for paired phones and turns what
// they send into pointer moves, keys and dictation.
//
//  • listens only once a phone is paired (or a QR code is showing). No paired phone, no open port.
//  • pairing (Settings → iPhone): a QR code with a fresh key, good for one connection within two minutes, renewed while the
//    page shows it. The connection that uses it spends it, is sent a new key over the sealed session, and becomes a paired
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
        var udp = false
        var pairingLink: URL?
        var failure: String?
    }

    private static let serviceKeychain = "Blurt iPhone Remote"
    private static let silence = 2.0
    private static let pairingLife = 120.0
    private static let maxHandshakes = 16
    private static let maxSteps = 32
    private static let maxWaitMs = 3000
    private static let maxText = 64 * 1024
    /// a session this quiet is over, relay or not: the phone is gone, and the screen must not go on being captured for nobody
    private static let gone = 12.0
    private static let testing = ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1"

    let queue = DispatchQueue(label: "blurt.remote", qos: .userInteractive)
    var onStatus: ((Status) -> Void)?
    var onDevices: (([Device]) -> Void)?
    private(set) var status = Status() { didSet { if status != oldValue { let s = status; DispatchQueue.main.async { self.onStatus?(s) } } } }

    private var udpFlows: [ObjectIdentifier: NWConnection] = [:]
    private var tcp: NWListener?
    private var udp: NWListener?
    private var udpPort: UInt16 = 0
    private var session: Session?
    /// connections still in their handshake (a channel must outlive `tcpConnection`)
    private var handshaking: [ObjectIdentifier: Session] = [:]
    private var pairing: (id: String, key: Data, until: Date)?
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
        var screen: RemoteScreen?
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

    private func key(for id: String) -> Data? {
        if let p = pairing, p.id == id, p.until > Date() { return p.key }
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
        observers.append(c.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.queue.sync { self?.end(); self?.stopListening() }
        })
        // the session's watch: silence, and whether macOS lets us post events
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.watch() }
        t.resume()
        watcher = t
    }
    private var watcher: DispatchSourceTimer?
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
                self.status.pairingLink = nil
            }
        }
    }

    private func renewPairing() {
        guard showingPairing, let port = tcp?.port?.rawValue else { return }
        let id = RemoteCrypto.newID(), key = RemoteCrypto.newKey()
        pairing = (id, key, Date().addingTimeInterval(Self.pairingLife))
        status.pairingLink = RemotePairing(macID: macID, deviceID: id, key: key, macName: Host.current().localizedName ?? "Mac", port: port,
                                           addresses: Self.addresses()).url
        if Self.testing { emit(["event": "remote_pairing", "link": status.pairingLink?.absoluteString ?? ""]) }
        pairingTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.pairingLife - 5)
        t.setEventHandler { [weak self] in self?.renewPairing() }
        t.resume()
        pairingTimer = t
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
            return self.queue.sync { self.key(for: id) }
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
    /// Set up by the owner (Settings → iPhone, tools/remote-relay). No address, no relay: Blurt doesn't run one.
    static var relayAddress: String? { (Config.shared["record.remote.relay_url"] as? String).flatMap(RemoteRelay.address) }
    static var relayOn: Bool { relayAddress != nil }
    /// Settings → iPhone: a paired phone may ask for the screen
    static var screenAllowed: Bool { Config.shared["record.remote.screen"] as? Bool ?? true }

    func relayChanged() {
        queue.async {
            self.session?.channel.send(ToPhone.relay(Self.relayAddress))     // first: it may be riding on the connection this closes
            self.updateRelays()
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

    private func updateRelays() {
        let on = Self.relayOn
        let ids = Set(devices().map(\.id))
        // a changed address counts as gone: the phone has been told the new one
        for (id, s) in relays where !on || !ids.contains(id) || relayAt != Self.relayAddress {
            relays[id] = nil
            s.channel.close()
        }
        relayAt = Self.relayAddress
        guard on else { return }
        for id in ids where relays[id] == nil { connectRelay(id) }
    }

    private func connectRelay(_ id: String) {
        guard let a = Self.relayAddress, relays[id] == nil, devices().contains(where: { $0.id == id }), let k = storedKey(id),
              let c = RemoteRelay.connection(address: a, room: RemoteRelay.room(key: k), role: "mac") else { return }
        emit(["event": "remote_relay", "state": "waiting"])
        wire(c, relay: id)
    }

    private func relayEnded(_ id: String, _ s: Session) {
        guard relays[id] === s else { return }
        relays[id] = nil
        let clean = s.channel.relayClose == RemoteRelay.phoneLeft || s.greeted
        let wait = clean ? 0.5 : min((relayWait[id] ?? 1) * 2, 60)
        relayWait[id] = clean ? 1 : wait
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in self?.connectRelay(id) }
    }

    private func opened(_ s: Session, id: String?) {
        handshaking[ObjectIdentifier(s)] = nil
        // removed, or its code renewed, while the handshake ran
        guard let id, key(for: id) != nil else { return s.channel.close() }
        // the phone that had the session gives way
        if let old = session, old !== s {
            if old.id != id { old.channel.send(ToPhone.replaced) }
            closed(old)
            old.channel.queue.asyncAfter(deadline: .now() + 0.2) { old.channel.close() }
        }
        s.id = id
        session = s
        // the code is spent the moment it opens a session
        if let p = pairing, p.id == id {
            s.pairingKey = RemoteCrypto.newKey()
            pairing = nil
            if showingPairing { renewPairing() }
        }
        emit(["event": "remote_session", "state": "open", "relay": s.channel.isRelay])
    }

    private func closed(_ s: Session) {
        guard session === s else { return }
        session = nil
        s.screen?.stop()
        s.screen = nil
        keepAwake(false)
        status.connected = nil
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
        case let .hello(device, mic):
            s.name = String(device.prefix(64))
            s.micOnPhone = mic
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
            s.screen?.stop()
            s.screen = nil
            keepAwake(displayToo: false)
            guard let r else { return }
            guard Self.screenAllowed else { return s.channel.send(ToPhone.screenFailed("off")) }
            let screen = RemoteScreen(channel: s.channel)
            screen.onInfo = { [weak s] m in s?.channel.send(m) }
            screen.onStopped = { [weak self] in self?.queue.async { self?.keepAwake(displayToo: false) } }
            s.screen = screen
            keepAwake(displayToo: true)
            screen.start(r) { why in s.channel.send(ToPhone.screenFailed(why)) }
        case let .screenCrop(c):
            s.screen?.setCrop(c)
        case let .pointerTo(x, y):
            if let p = s.screen?.pointerTo(x: x, y: y) { input.queue.async { input.place(p) } }
        case let .candidates(list):
            guard s.punches < 3 else { return }
            s.punches += 1
            queue.async { self.punch(list) }
        case .requestKeyframe:
            s.screen?.keyframe()
        case let .screenStats(json):
            s.channel.queue.async { emit(["event": "remote_screen_phone", "stats": json, "uplink": s.takeGaps()]) }
        case let .screenSnapshot(name, jpeg):
            guard let dir = ProcessInfo.processInfo.environment["BLURT_SCREEN_SNAP_DIR"], !name.contains("/") else { return }
            try? jpeg.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".jpg"))
        case let .setMicOnPhone(on):
            s.micOnPhone = on
        case let .key(c, down):
            input.queue.async { if let down { input.hold(c, down: down) } else { input.press(c) } }
            if down != false, !c.key.isEmpty { RemoteHUD.show(c.label) }
        case let .mods(mods):
            input.queue.async { input.setSticky(mods) }
            RemoteHUD.sticky(mods)
        case let .run(steps):
            let waits = steps.reduce(0) { if case let .wait(ms) = $1 { $0 + max(ms, 0) } else { $0 } }
            guard steps.count <= Self.maxSteps, waits <= Self.maxWaitMs else { return }
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
        guard session === s, let id = s.id else { return }
        if let k = s.pairingKey {
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

    private func keyStored(_ s: Session) {
        guard session === s, let id = s.id, let k = s.pairingKey else { return }
        s.pairingKey = nil
        store(k, for: id)
        save(devices() + [Device(id: id, name: s.name, added: Date(), lastSeen: Date())])
        begin(s)
    }

    private func begin(_ s: Session) {
        s.greeted = true
        status.connected = s.name
        keepAwake()
        let info = { (list: [RemoteCandidate]) in
            let main = CGDisplayBounds(CGMainDisplayID())
            s.channel.send(ToPhone.session(RemoteSessionInfo(macName: Host.current().localizedName ?? "Mac", udpPort: self.udpPort, udpSession: s.number, canControl: self.canControl,
                                                             version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                                                             candidates: list, displayAspect: main.height > 0 ? Double(main.width / main.height) : 1.6, relay: Self.relayAddress)))
        }
        if s.channel.isRelay {
            // where the phone might reach this Mac without the relay
            var list = Self.addresses().map { RemoteCandidate(host: $0, port: udpPort) }
            list += RemoteAddresses.publicIPv6().map { RemoteCandidate(host: $0, port: udpPort) }
            RemoteSTUN.ask(from: udpPort, queue: queue) { found in
                if let found { list.append(found) }
                info(list)
                self.sendFront()
                DispatchQueue.main.async { self.dictationChanged(Dictation.shared.remotePhase) }
            }
            return
        }
        info([])
        sendFront()
        DispatchQueue.main.async { self.dictationChanged(Dictation.shared.remotePhase) }
    }

    private func pointer(_ p: RemotePointerPacket) {
        let input = RemoteInput.shared
        input.queue.async {
            switch p {
            case let .move(x, y): input.move(dx: CGFloat(x), dy: CGFloat(y))
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
        case .voiceNote: center.onFire?(.voice)
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
        session?.channel.send(ToPhone.front(RemoteFront(bundle: b, name: a.localizedName ?? b)))
    }

    func dictationChanged(_ p: RemoteDictationPhase) { session?.channel.send(ToPhone.dictation(p)) }
    func live(committed: String, pending: String) { session?.channel.send(ToPhone.live(committed: committed, pending: pending)) }
    func level(_ l: Float) { session?.channel.send(ToPhone.level(l)) }
    func typed(_ t: String) { session?.channel.send(ToPhone.typed(t)) }

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
