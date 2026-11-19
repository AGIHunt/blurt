// The computers this Mac can drive (docs/design/remote-desktop-viewer.md): who they are, their keys, which are on this network now, which
// have a window open, and adding one. The list window (ComputersView), Settings → 手机和电脑 and the windows (ViewerWindow) all read it.
//
//  • paired computers: BLURT_HOME/remote/computers.json; each one's key in the login Keychain ("Blurt Remote Viewer", by this Mac's device
//    id there). Test builds keep keys in a file in their own BLURT_HOME, never the Keychain.
//  • nearby: DNS-SD `_blurt-remote._tcp` while the list or the Add Computer sheet shows, never otherwise. This Mac's own host isn't listed.
//  • adding: a computer found nearby (the host asks its owner, both show six digits) or a pasted `blurtremote://pair?…` link.
import AppKit
import BlurtCore
import BlurtRemoteKit
import Network

@MainActor
final class ViewerStore: ObservableObject {
    static let shared = ViewerStore()

    struct Nearby: Identifiable, Equatable {
        var id: String          // the host's id (TXT)
        var name: String
        var endpoint: NWEndpoint
    }

    /// What the list says of a computer (RemoteViewerRow): 已连接 · <path>, 可连接 · <path>, 无法直连, 离线 · <when>.
    typealias Row = RemoteViewerRow

    /// A pairing under way, for the Add Computer sheet.
    struct Pairing: Equatable {
        var name: String
        var check: String?
        var failed: String?
    }

    @Published private(set) var computers: [RemoteComputer] = []
    @Published private(set) var nearby: [Nearby] = []
    /// open windows: the computer's id → the path and round trip of its first window
    @Published private(set) var live: [String: (route: RemoteViewerLink.Route?, rtt: Double?)] = [:] {
        didSet { objectWillChange.send() }
    }
    @Published private(set) var pairing: Pairing?
    /// a computer's last try through the public connection service didn't work (its window says why): until it connects, Try Again, or
    /// another network
    @Published private(set) var failed: [String: RemoteViewerLink.Away] = [:]
    private let network = NWPathMonitor()
    private var pairingLink: RemoteViewerLink?
    private var browser: NWBrowser?
    private var watchers: Set<String> = []

    #if DEBUG || BLURT_TEST_HOOKS
    nonisolated static let testing = ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1"
    #else
    nonisolated static let testing = false
    #endif

    private init() {
        computers = load()
        var first = true
        network.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if first { first = false; return }
                    self?.failed = [:]
                }
            }
        }
        network.start(queue: .main)
    }

    /// A window's link said why away didn't work, or that it works again.
    func awayChanged(_ id: String, _ a: RemoteViewerLink.Away?) {
        if failed[id] != a { failed[id] = a }
    }

    // MARK: saved

    private var folder: URL { BlurtPaths.home.appendingPathComponent("remote") }
    private var file: URL { folder.appendingPathComponent("computers.json") }

    private func load() -> [RemoteComputer] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([RemoteComputer].self, from: $0) } ?? []
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let d = try? JSONEncoder().encode(computers) {
            try? d.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    /// A computer heard from: its name, system, addresses and relay as it said them this session.
    func save(_ c: RemoteComputer) {
        if let i = computers.firstIndex(where: { $0.id == c.id }) {
            // paired again (a new device id): the old key goes
            if computers[i].deviceID != c.deviceID { ViewerKeys.remove(computers[i].deviceID) }
            computers[i] = c
        } else {
            computers.append(c)
        }
        persist()
    }

    func remove(_ c: RemoteComputer) {
        ViewerWindowController.closeAll(of: c.id)
        ViewerKeys.remove(c.deviceID)
        computers.removeAll { $0.id == c.id }
        persist()
        emit(["event": "viewer_computer", "state": "removed"])
    }

    func key(_ c: RemoteComputer) -> Data? { ViewerKeys.read(c.deviceID) }

    // MARK: the list's words

    /// The path, in the agreed terms (copy.md).
    static func path(_ r: RemoteViewerLink.Route?) -> String {
        switch r {
        case .local?: T("settings.remote.path.local")
        case .tailscale?: T("settings.remote.path.tailscale")
        case .overlay?: T("settings.remote.path.overlay")
        case .direct?, .goBetween?: T("settings.remote.path.direct")
        case .relay?: T("settings.remote.path.relay")
        case nil: T("settings.remote.path.go_between")
        }
    }

    /// The way a computer that isn't open would be reached: the same network if it's here, else its relay or an overlay address.
    func row(_ c: RemoteComputer) -> Row {
        let l = live[c.id]
        return RemoteViewerRow.of(c, connected: l != nil, route: l?.route, nearby: nearby.contains { $0.id == c.id }, failed: failed[c.id])
    }

    /// The way being tried, before it's up: the public connection service until the move, the owner's relay, the same network.
    static func trying(_ r: RemoteViewerLink.Route?) -> String {
        switch r {
        case .goBetween?, nil: T("settings.remote.path.go_between")
        case .relay?: T("settings.remote.path.relay")
        default: path(r)
        }
    }

    static func line(_ r: Row) -> String {
        switch r {
        case let .connected(p): T("viewer.state.connected", path(p))
        case let .available(p): T("viewer.state.available", trying(p))
        case .noDirect: T("viewer.state.no_direct")
        case let .offline(d?): T("viewer.state.offline", Self.when(d))
        case .offline(nil): T("viewer.state.offline.never")
        }
    }

    static func when(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Loc.locale
        f.unitsStyle = .full
        return Date().timeIntervalSince(d) < 60 ? T("viewer.state.just_now") : f.localizedString(for: d, relativeTo: Date())
    }

    static func symbol(_ c: RemoteComputer) -> String {
        switch c.host {
        case .mac: "desktopcomputer"
        case .windows: "display"      // not "pc": its screen has a face that reads as Windows' crash screen
        case .linux: "server.rack"
        }
    }

    // MARK: open windows

    func liveChanged(_ id: String, route: RemoteViewerLink.Route?, rtt: Double?, open: Bool) {
        if open { live[id] = (route, rtt) } else { live[id] = nil }
    }

    func open(_ c: RemoteComputer) { ViewerWindowController.open(c) }

    // MARK: nearby

    /// The list or the Add Computer sheet came on show ("list", "settings", "add"): look for computers on this network while any does.
    func watch(_ who: String) {
        watchers.insert(who)
        guard browser == nil else { return }
        #if DEBUG || BLURT_TEST_HOOKS
        if fakeNearby { return }       // the screenshots' made-up network: nothing real is listed
        #endif
        let params = NWParameters()
        params.includePeerToPeer = RemoteChannel.peerToPeer
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: RemotePairing.serviceType, domain: nil), using: params)
        let own = RemoteServer.shared.macID
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { r -> Nearby? in
                guard case let .bonjour(txt) = r.metadata, let id = txt["id"], id != own, case let .service(name, _, _, _) = r.endpoint else { return nil }
                return Nearby(id: id, name: name, endpoint: r.endpoint)
            }
            var seen = Set<String>()
            let list = found.filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.nearby != list { self?.nearby = list } } }
        }
        b.start(queue: .main)
        browser = b
    }

    func unwatch(_ who: String) {
        watchers.remove(who)
        guard watchers.isEmpty else { return }
        browser?.cancel()
        browser = nil
        #if DEBUG || BLURT_TEST_HOOKS
        if fakeNearby { return }
        #endif
        nearby = []
    }

    // MARK: adding

    /// Nearby computers not paired yet, for the Add Computer sheet.
    var unpaired: [Nearby] { nearby.filter { n in !computers.contains { $0.id == n.id } } }

    /// Pair with one found on this network: the host shows six digits and asks its owner; this sheet shows the same six.
    func pair(_ n: Nearby) {
        let c = RemoteComputer(id: n.id, deviceID: RemoteNearby.newID(), name: n.name, port: 0, addresses: [])
        startPairing(c, key: RemoteNearby.key, endpoint: n.endpoint)
    }

    /// A pasted pairing link (the host's 添加设备 / Add Device). False when it isn't one.
    @discardableResult func pair(link text: String) -> Bool {
        guard let u = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let p = RemotePairing(url: u) else { return false }
        startPairing(RemoteComputer(pairing: p), key: p.key, endpoint: nil)
        return true
    }

    private func startPairing(_ c: RemoteComputer, key: Data, endpoint: NWEndpoint?) {
        cancelPairing()
        pairing = Pairing(name: c.name)
        let link = RemoteViewerLink(computer: c, key: key, deviceName: Host.current().localizedName ?? "Mac", pairing: true, endpoint: endpoint)
        link.onNewKey = { c, k in ViewerKeys.store(k, c.deviceID) }
        link.onState = { [weak self, weak link] s in
            MainActor.assumeIsolated {
                guard let self, let link, self.pairingLink === link else { return }
                switch s {
                case let .waiting(check): self.pairing?.check = check
                case .connected:
                    // paired: the computer is saved, and its window opens on this very session
                    self.save(link.computer)
                    self.pairingLink = nil
                    self.pairing = nil
                    emit(["event": "viewer_pairing", "state": "paired", "platform": link.computer.platform ?? ""])
                    ViewerWindowController.open(link.computer, adopting: link)
                case .forgotten:
                    self.pairing?.failed = T("viewer.add.refused", link.computer.name)
                    link.stop()
                    self.pairingLink = nil
                case .unreachable:
                    self.pairing?.failed = T("viewer.add.unreachable", link.computer.name)
                case let .away(a) where !link.pairing:
                    // paired over the public connection service, and then it couldn't connect directly: the computer is kept, and its
                    // window says why and offers Try Again
                    self.save(link.computer)
                    self.failed[link.computer.id] = a
                    self.pairingLink = nil
                    self.pairing = nil
                    emit(["event": "viewer_pairing", "state": "paired", "away": a.rawValue])
                    ViewerWindowController.open(link.computer, adopting: link)
                case let .away(a):
                    self.pairing?.failed = a == .busy ? T("viewer.busy") : T("viewer.no_direct")
                default: break
                }
            }
        }
        link.onMessage = { [weak self, weak link] m in
            MainActor.assumeIsolated {
                guard let self, let link, self.pairingLink === link, case let .session(i) = m else { return }
                self.pairing?.name = i.macName
            }
        }
        pairingLink = link
        link.start()
        emit(["event": "viewer_pairing", "state": "started", "nearby": endpoint != nil])
    }

    func cancelPairing() {
        if let l = pairingLink, l.pairing { ViewerKeys.remove(l.computer.deviceID) }
        pairingLink?.stop()
        pairingLink = nil
        pairing = nil
    }

    #if DEBUG || BLURT_TEST_HOOKS
    /// tests (`viewer fake …`): computers, nearby ones and open windows as if real, for a look at every state. Nothing saved.
    private(set) var fakeNearby = false
    func testFake(computers list: [RemoteComputer], nearby n: [Nearby], live l: [String: (RemoteViewerLink.Route?, Double?)], pairing p: Pairing?,
                  failed f: [String: RemoteViewerLink.Away] = [:]) {
        computers = list
        failed = f
        fakeNearby = true
        browser?.cancel()
        browser = nil
        nearby = n
        live = l.mapValues { (route: $0.0, rtt: $0.1) }
        pairing = p
    }
    #endif
}

/// The keys this Mac was given by the computers it drives.
enum ViewerKeys {
    private static let service = "Blurt Remote Viewer"
    private static var testFile: URL { BlurtPaths.home.appendingPathComponent("remote/viewer-test-keys.json") }
    private static var testKeys: [String: Data] {
        get { (try? Data(contentsOf: testFile)).flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) } ?? [:] }
        set {
            try? FileManager.default.createDirectory(at: testFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(newValue).write(to: testFile)
        }
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func store(_ key: Data, _ account: String) {
        if ViewerStore.testing { testKeys[account] = key; return }
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = key
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecAttrLabel as String] = service
        SecItemAdd(q as CFDictionary, nil)
    }

    static func read(_ account: String) -> Data? {
        if ViewerStore.testing { return testKeys[account] }
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func remove(_ account: String) {
        if ViewerStore.testing { testKeys[account] = nil; return }
        SecItemDelete(query(account) as CFDictionary)
    }
}
