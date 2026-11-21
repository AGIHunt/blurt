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
        /// what went wrong, and what to do about it (a second line, or nil)
        var failed: String?
        var help: String?
        /// the same link, or the computer found nearby, can still work: Try Again (else Back, for a new link)
        var canRetry = false
    }

    @Published private(set) var computers: [RemoteComputer] = []
    @Published private(set) var nearby: [Nearby] = []
    /// open windows: the computer's id → the path and round trip of its first window
    @Published private(set) var live: [String: (route: RemoteViewerLink.Route?, rtt: Double?)] = [:] {
        didSet { objectWillChange.send() }
    }
    @Published private(set) var pairing: Pairing?
    /// the Add Computer sheet's link field: kept here, so Back after a failure finds the link still in it
    @Published var linkText = ""
    /// a pairing ended paired (its window opened): the sheet's job is done
    @Published private(set) var pairedCount = 0
    /// computers that refused this Mac's key this run, with no session (`.forgotten`): said in the list, the key kept (anyone on the
    /// network can send a refusal); cleared when one connects
    @Published private(set) var refused: Set<String> = []
    /// a computer's last try through the public connection service didn't work (its window says why): until it connects, Try Again, or
    /// another network
    @Published private(set) var failed: [String: RemoteViewerLink.Away] = [:]
    private let network = NWPathMonitor()
    private var pairingLink: RemoteViewerLink?
    /// how the pairing under way began: Try Again starts it again the same way
    private var pairingStart: (computer: RemoteComputer, key: Data, endpoint: NWEndpoint?)?
    private var browser: NWBrowser?
    private var watchers: Set<String> = []
    /// what each computer's relay said lately (`peek`), while a list of computers is on screen: asleep since, last seen
    @Published private(set) var presence: [String: RemotePresence] = [:]
    private var peekTimer: Timer?

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

    /// A computer heard from: its name, system, addresses and relay as it said them this session. The name the user gave it stays.
    func save(_ c: RemoteComputer) {
        var c = c
        if let i = computers.firstIndex(where: { $0.id == c.id }) {
            c = computers[i].heard(c)
            // a window's late word on a computer that removed this Mac doesn't bring it back; pairing again (a new device id) does
            if computers[i].removed == true, computers[i].deviceID == c.deviceID { c.removed = true }
            // paired again (a new device id): the old key goes
            if computers[i].deviceID != c.deviceID { ViewerKeys.remove(computers[i].deviceID) }
            computers[i] = c
        } else {
            computers.append(c)
        }
        persist()
    }

    /// Rename (a double-click on its name, or Rename… in its ⋯): what this Mac calls it, nothing sent, its id the same. An empty field,
    /// or its own name, brings its own name back.
    func rename(_ c: RemoteComputer, to text: String) {
        guard let i = computers.firstIndex(where: { $0.id == c.id }) else { return }
        let alias = RemoteAlias.typed(text, own: computers[i].name)
        guard computers[i].alias != alias else { return }
        computers[i].alias = alias
        #if DEBUG || BLURT_TEST_HOOKS
        if !fakeNearby { persist() }
        #else
        persist()
        #endif
        ViewerWindowController.renamed(c.id)
        emit(["event": "viewer_computer", "state": "renamed", "alias": alias != nil])
    }

    /// What this Mac calls the computer of that id: the user's name for it, else `own` (what the host said of itself just now).
    func name(of id: String, else own: String) -> String {
        computers.first { $0.id == id }?.alias.flatMap { $0.isEmpty ? nil : $0 } ?? own
    }

    func remove(_ c: RemoteComputer) {
        ViewerWindowController.closeAll(of: c.id)
        ViewerKeys.remove(c.deviceID)
        computers.removeAll { $0.id == c.id }
        persist()
        emit(["event": "viewer_computer", "state": "removed"])
    }

    func key(_ c: RemoteComputer) -> Data? { ViewerKeys.read(c.deviceID) }

    /// A window's link heard that the computer let this Mac go. `inSession`: said in a session it had opened, so it's so: the key goes and
    /// the list says Removed until it's added again. Otherwise (a refused key, which anyone on the network can send) only this run's
    /// list says so, and the key stays.
    func hostRemoved(_ id: String, inSession: Bool) {
        guard let i = computers.firstIndex(where: { $0.id == id }) else { return }
        if inSession {
            guard computers[i].removed != true else { return }
            computers[i].removed = true
            ViewerKeys.remove(computers[i].deviceID)
            persist()
        } else {
            refused.insert(id)
        }
        emit(["event": "viewer_computer", "state": inSession ? "removed_by_host" : "refused"])
    }

    /// Add Computer, from a row or a window that says the computer removed this Mac: the Computers window and its sheet.
    func requestAdd() {
        ComputersWindowController.shared.show()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .viewerAdd, object: nil) }
    }

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
        return RemoteViewerRow.of(c, connected: l != nil, route: l?.route, nearby: nearby.contains { $0.id == c.id }, failed: failed[c.id],
                                  presence: presence[c.id], refused: refused.contains(c.id))
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
        case .relayDown: T("viewer.state.relay_down")
        case let .asleep(d): T("viewer.state.asleep", Self.clock(d))
        case let .offline(d?): T("viewer.state.offline", Self.when(d))
        case .offline(nil): T("viewer.state.offline.never")
        case .removed: T("viewer.state.removed")
        }
    }

    /// "10:42", or "Yesterday 10:42" / "11月18日 10:42" further back
    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Loc.locale
        f.timeStyle = .short
        f.dateStyle = Calendar.current.isDateInToday(d) ? .none : .short
        f.doesRelativeDateFormatting = true
        return f.string(from: d)
    }

    static func when(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Loc.locale
        f.unitsStyle = .full
        return Date().timeIntervalSince(d) < 60 ? T("viewer.state.just_now") : f.localizedString(for: d, relativeTo: Date())
    }

    /// The row's glyph: the Mac's monitor with its chin, a plain monitor for Windows (not "pc": its screen has a face that
    /// reads as Windows' crash screen), a terminal for Linux (not a server rack: most are desktops and laptops).
    static func symbol(_ c: RemoteComputer) -> String {
        switch c.host {
        case .mac: "desktopcomputer"
        case .windows: "display"
        case .linux: "terminal.fill"
        }
    }

    /// The system's name, for the glyph's tooltip and VoiceOver.
    static func system(_ c: RemoteComputer) -> String {
        switch c.host {
        case .mac: "macOS"
        case .windows: "Windows"
        case .linux: "Linux"
        }
    }

    /// What VoiceOver says of a row, as one element: its name, its system, its state.
    static func spoken(_ c: RemoteComputer, _ r: Row) -> String {
        "\(c.shownName), \(system(c)), \(line(r))"
    }

    /// The longer word on a state that needs the user (the state line's tooltip): why, and what to do.
    static func explain(_ c: RemoteComputer, _ r: Row) -> String? {
        r == .noDirect ? T("viewer.no_direct.help", c.shownName) : nil
    }

    // MARK: open windows

    func liveChanged(_ id: String, route: RemoteViewerLink.Route?, rtt: Double?, open: Bool) {
        if open { live[id] = (route, rtt); refused.remove(id) } else { live[id] = nil }
    }

    /// Its window; a computer that removed this Mac has no key to open one with: Add Computer instead.
    func open(_ c: RemoteComputer) {
        if c.removed == true { return requestAdd() }
        ViewerWindowController.open(c)
    }

    // MARK: nearby

    /// The list or the Add Computer sheet came on show ("list", "settings", "add"): look for computers on this network while any does.
    func watch(_ who: String) {
        watchers.insert(who)
        if peekTimer == nil {
            peekAll()
            // once a minute while a list shows: a few small requests, nothing while nobody's looking
            peekTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { ViewerStore.shared.peekAll() } }
        }
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

    /// Asks each closed computer's relay whether it's there (a window that's open knows already).
    func peekAll() {
        for c in computers where live[c.id] == nil {
            guard let a = c.relayAddress, let key = key(c) else { continue }
            let id = c.id
            RemoteRelay.peek(address: a, room: RemoteRelay.room(key: key)) { p in
                DispatchQueue.main.async { MainActor.assumeIsolated { ViewerStore.shared.presence[id] = p } }
            }
        }
    }

    func unwatch(_ who: String) {
        watchers.remove(who)
        guard watchers.isEmpty else { return }
        peekTimer?.invalidate()
        peekTimer = nil
        browser?.cancel()
        browser = nil
        #if DEBUG || BLURT_TEST_HOOKS
        if fakeNearby { return }
        #endif
        nearby = []
    }

    // MARK: adding

    /// Nearby computers not paired yet, for the Add Computer sheet (one that removed this Mac counts: it's added again).
    var unpaired: [Nearby] {
        nearby.filter { n in !computers.contains { $0.id == n.id && $0.removed != true && !refused.contains($0.id) } }
    }

    /// Pair with one found on this network: the host shows six digits and asks its owner; this sheet shows the same six.
    func pair(_ n: Nearby) {
        let c = RemoteComputer(id: n.id, deviceID: RemoteNearby.newID(), name: n.name, port: 0, addresses: [])
        startPairing(c, key: RemoteNearby.key, endpoint: n.endpoint)
    }

    /// A pasted pairing link (the host's 添加设备 / Add Device). False when it isn't one.
    @discardableResult func pair(link text: String) -> Bool {
        guard let u = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let p = RemotePairing(url: u) else { return false }
        // kept for Back: the field shows the link that was used
        linkText = text
        startPairing(RemoteComputer(pairing: p), key: p.key, endpoint: nil)
        return true
    }

    private func startPairing(_ c: RemoteComputer, key: Data, endpoint: NWEndpoint?) {
        cancelPairing(keepLink: true)
        // added again: the name the user gave it before
        pairing = Pairing(name: name(of: c.id, else: c.name))
        pairingStart = (c, key, endpoint)
        let link = RemoteViewerLink(computer: c, key: key, deviceName: Host.current().localizedName ?? "Mac", pairing: true, endpoint: endpoint)
        link.onNewKey = { c, k in ViewerKeys.store(k, c.deviceID) }
        let byLink = endpoint == nil
        link.onState = { [weak self, weak link] s in
            MainActor.assumeIsolated {
                guard let self, let link, self.pairingLink === link else { return }
                let name = self.name(of: link.computer.id, else: link.computer.name)
                @MainActor func fail(_ text: String, _ help: String?, retry: Bool) {
                    self.pairing?.check = nil
                    self.pairing?.failed = text
                    self.pairing?.help = help
                    self.pairing?.canRetry = retry
                }
                switch s {
                case .connecting:
                    // Try Again: what went wrong is gone until it goes wrong again
                    self.pairing?.failed = nil
                    self.pairing?.help = nil
                case let .waiting(check):
                    // the other computer asks its owner now, whatever was said before (it may have woken after "Can't reach"): the
                    // digits take the place of the failure, so they can be compared
                    self.pairing?.check = check
                    self.pairing?.failed = nil
                    self.pairing?.help = nil
                case .connected:
                    // paired: the computer is saved, and its window opens on this very session
                    self.save(link.computer)
                    self.pairingLink = nil
                    self.pairingStart = nil
                    self.pairing = nil
                    self.linkText = ""
                    self.pairedCount += 1
                    emit(["event": "viewer_pairing", "state": "paired", "platform": link.computer.platform ?? ""])
                    ViewerWindowController.open(link.computer, adopting: link)
                case let .pairingFailed(why):
                    // a link's code is spent by now whatever happened (Back, for a new one); nearby, asking again is a new question
                    switch why {
                    case .spent where byLink: fail(T("viewer.add.expired"), T("viewer.add.new_link", name), retry: false)
                    case .spent: fail(T("viewer.add.not_now", name), nil, retry: true)
                    case .declined: fail(T("viewer.add.refused", name), byLink ? T("viewer.add.new_link", name) : nil, retry: !byLink)
                    case .unanswered: fail(T("viewer.add.unanswered", name), byLink ? T("viewer.add.new_link", name) : nil, retry: !byLink)
                    }
                    link.stop()
                    self.pairingLink = nil
                    emit(["event": "viewer_pairing", "state": "failed", "why": why.rawValue, "link": byLink])
                case .forgotten, .removed:
                    // not from a pairing link (its refusals are pairingFailed); said all the same
                    fail(T("viewer.add.refused", name), byLink ? T("viewer.add.new_link", name) : nil, retry: !byLink)
                    link.stop()
                    self.pairingLink = nil
                case .unreachable:
                    // it goes on trying meanwhile: if the other computer turns up and asks, its digits replace this
                    fail(T("viewer.add.unreachable", name), T(byLink ? "viewer.add.unreachable.help.link" : "viewer.add.unreachable.help", name),
                         retry: true)
                    emit(["event": "viewer_pairing", "state": "failed", "why": "unreachable", "link": byLink])
                case let .away(a) where !link.pairing:
                    // paired over the public connection service, and then it couldn't connect directly: the computer is kept, and its
                    // window says why and offers Try Again
                    self.save(link.computer)
                    self.failed[link.computer.id] = a
                    self.pairingLink = nil
                    self.pairingStart = nil
                    self.pairing = nil
                    self.linkText = ""
                    self.pairedCount += 1
                    emit(["event": "viewer_pairing", "state": "paired", "away": a.rawValue])
                    ViewerWindowController.open(link.computer, adopting: link)
                case let .away(a):
                    fail(T(a == .busy ? "viewer.busy" : a == .relayDown ? "viewer.relay_down.short" : "viewer.no_direct"), nil, retry: a != .busy)
                default: break
                }
            }
        }
        link.onMessage = { [weak self, weak link] m in
            MainActor.assumeIsolated {
                guard let self, let link, self.pairingLink === link, case let .session(i) = m else { return }
                self.pairing?.name = self.name(of: link.computer.id, else: i.macName)
            }
        }
        pairingLink = link
        link.start()
        emit(["event": "viewer_pairing", "state": "started", "nearby": endpoint != nil])
    }

    /// The failed sheet's Try Again: the same link (or the computer found nearby) once more. A link still trying asks again from now;
    /// one that ended starts over.
    func retryPairing() {
        if let l = pairingLink {
            pairing?.failed = nil
            pairing?.help = nil
            l.tryAgain()
        } else if let s = pairingStart {
            startPairing(s.computer, key: s.key, endpoint: s.endpoint)
        }
    }

    /// The failed sheet's Back: the sheet's first page, the pasted link still in its field.
    func backFromPairing() {
        cancelPairing(keepLink: true)
    }

    /// Cancel (the sheet closes, and the link with it), Back, or another pairing starting.
    func cancelPairing(keepLink: Bool = false) {
        if !keepLink { linkText = "" }
        if let l = pairingLink, l.pairing { ViewerKeys.remove(l.computer.deviceID) }
        pairingLink?.stop()
        pairingLink = nil
        pairingStart = nil
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
