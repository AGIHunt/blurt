// Blurt's public relay, the parts both ends share (docs/design/remote-go-between.md §The public relay): the host's ask for tickets on the
// go-between, its wait for the relay to open, the picture's lease, the picture's ceiling on this path and the files budget. The host
// (BlurtApp's RemoteServer) and the tests' in-process host use the same code; the viewer's side is RemoteViewerLink.
import Foundation
import Network

extension RemotePublicRelay {
    /// a phone takes `ToPhone.publicRelay` only this soon before `noDirect`
    public static let offerLife: Double = 10

    /// A room for one session: 32 random bytes, base64url (43 characters). Never used again.
    public static func newRoom() -> String { RemoteCrypto.base64url(RemoteCrypto.newKey()) }

    /// The go-between's answer to `ticketAsk`: where to go, the room, and a ticket for each end.
    public struct Ticket: Equatable, Sendable {
        public var relay: String
        public var room: String
        public var mac: String
        public var phone: String
        public init(relay: String, room: String, mac: String, phone: String) { self.relay = relay; self.room = room; self.mac = mac; self.phone = phone }
    }

    public enum TicketAnswer: Equatable, Sendable {
        case ticket(Ticket)
        /// "off", "alone", "limit", "bad"
        case refused(String)
    }

    /// `{"ticket":{…}}` from the go-between; nil for anything else.
    public static func ticketAnswer(_ text: String) -> TicketAnswer? {
        guard text.utf8.count <= 1024, let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let t = o["ticket"] as? [String: Any] else { return nil }
        if let e = t["error"] as? String { return .refused(e) }
        guard let relay = t["relay"] as? String, let room = t["room"] as? String, let mac = t["mac"] as? String, let phone = t["phone"] as? String
        else { return nil }
        return .ticket(Ticket(relay: relay, room: room, mac: mac, phone: phone))
    }

    public enum LeaseAnswer: Equatable, Sendable {
        case granted(ttl: Int)
        /// "full", "prefix", "alone"; "expired" when the relay took it back
        case refused(String)
    }

    /// `{"lease":{…}}` from the relay; nil for anything else.
    public static func leaseAnswer(_ text: String) -> LeaseAnswer? {
        guard text.utf8.count <= 256, let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let l = o["lease"] as? [String: Any], let ok = l["ok"] as? Bool else { return nil }
        if ok { return .granted(ttl: l["ttl"] as? Int ?? 75) }
        return .refused(l["why"] as? String ?? "full")
    }

    /// A ticket has digits, base64url and two dots, nothing that needs escaping in a query.
    static func plausible(_ t: String) -> Bool {
        !t.isEmpty && t.count <= 64 && t.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }
    }

    /// `<address>/v1/<room>/<role>?t=<ticket>`
    public static func connection(address: String, room: String, role: String, ticket: String) -> NWConnection? {
        guard plausible(ticket), plausible(room) else { return nil }
        return RemoteRelay.connection(address: address, room: room, role: role, query: "t=" + ticket)
    }

    /// The picture on this path: Data Saver's at most (1280 wide, 1 Mbps, 15 fps), whatever the device asked. A viewer's window stays as
    /// it is: the picture is fitted into the smaller of the two (`box`).
    public static func clamp(_ asked: RemoteScreenRequest) -> RemoteScreenRequest {
        var r = asked
        if r.width > maxWidth {
            r.height = max(64, Int((Double(r.height) * Double(maxWidth) / Double(r.width)).rounded()) / 2 * 2)
            r.width = maxWidth
        }
        r.bitrate = min(r.bitrate, maxBitrate)
        r.fps = min(r.fps, maxFPS)
        return r
    }

    /// The host, 8 s into a session on the go-between with no direct path: asks the go-between for tickets on this session's connection (a
    /// text message, answered there and never passed on) and waits `wait` seconds. `done` (on the channel's queue, once): the tickets, if
    /// the answer came, named this room and an allowed relay (`testing`: a test build's own, BLURT_PUBLIC_RELAY); else nil and why.
    public static func askTickets(on ch: RemoteChannel, testing: String?, wait: Double = ticketWait,
                                  done: @escaping (Ticket?, String) -> Void) {
        let room = newRoom()
        ch.queue.async {
            var finished = false
            func finish(_ t: Ticket?, _ why: String) {
                guard !finished else { return }
                finished = true
                ch.onText = nil
                done(t, why)
            }
            ch.onText = { text in
                switch ticketAnswer(text) {
                case let .ticket(t)?:
                    guard t.room == room else { return finish(nil, "room") }
                    guard allowed(t.relay, testing: testing) else { return finish(nil, "relay") }
                    finish(t, "ok")
                case let .refused(why)?: finish(nil, why)
                case nil: break
                }
            }
            ch.sendText(ticketAsk(room: room))
            ch.queue.asyncAfter(deadline: .now() + wait) { finish(nil, "timeout") }
        }
    }

    /// The relay connection `ch` (made, its callbacks set, started) is up within `within` seconds: `done(true)` once the WebSocket is
    /// open, `done(false)` if it closed first or the time ran out. On the channel's queue, once. `onClose` must be set before this.
    public static func whenOpen(_ ch: RemoteChannel, within: Double = giveUp, done: @escaping (Bool) -> Void) {
        ch.queue.async {
            var finished = false
            func finish(_ ok: Bool) {
                guard !finished else { return }
                finished = true
                ch.onReady = nil
                done(ok)
            }
            if ch.wasReady { return finish(true) }
            ch.onReady = { finish(true) }
            let closed = ch.onClose
            ch.onClose = { f in
                finish(false)
                closed?(f)
            }
            ch.queue.asyncAfter(deadline: .now() + within) { finish(ch.wasReady) }
        }
    }
}

extension RemoteRelay {
    /// `connection(address:room:role:)` with a query on the path (the public relay's ticket).
    public static func connection(address: String, room: String, role: String, query: String) -> NWConnection? {
        guard let a = self.address(address), let url = URL(string: "\(a)/v1/\(room)/\(role)?\(query)") else { return nil }
        return connection(url: url)
    }
}

/// The host's picture lease on the public relay (docs/design/remote-go-between.md §The picture: leases). The relay can't see the picture, so
/// the host asks before it starts it, renews while it runs, and gives it back when it stops. Every call may come from any queue; the
/// callbacks come on `queue`.
public final class RemotePictureLease {
    public enum Event: Equatable, Sendable {
        /// granted: the picture may start (or go on)
        case granted
        /// none free (or taken back): no picture now; asked again every `askAgain` while it's wanted
        case refused(String)
        /// no touch, key or voice for `untouched`: the picture stops and the lease is given back
        case untouched
    }

    public var onEvent: ((Event) -> Void)?
    /// seconds; the tests make them short
    public var askAgain = RemotePublicRelay.askAgain
    public var renewEvery = RemotePublicRelay.renewEvery
    public var untouched = RemotePublicRelay.untouched

    private let queue: DispatchQueue
    private let send: (String) -> Void
    private var wanted = false
    /// the lease is held now (on `queue`)
    public private(set) var held = false
    private var asking = false
    private var refusedSaid = false
    private var ended = false
    private var token = 0
    private let lock = NSLock()
    private var lastTouch = 0.0

    /// `send`: a text message to the relay on the host's connection
    public init(queue: DispatchQueue, send: @escaping (String) -> Void) {
        self.queue = queue
        self.send = send
    }

    /// The device touched, typed or spoke: the picture isn't for nobody.
    public func touched() {
        lock.withLock { lastTouch = CFAbsoluteTimeGetCurrent() }
    }

    /// The picture is wanted (the device asked for it) or not (it turned it off, or the app went to the background).
    public func want(_ on: Bool) {
        queue.async { [self] in
            guard !ended else { return }
            if on {
                touched()
                let was = wanted
                wanted = true
                refusedSaid = false
                if held {
                    onEvent?(.granted)
                } else if !asking || !was {
                    ask()
                }
                schedule()
            } else {
                wanted = false
                token += 1
                giveBack()
            }
        }
    }

    /// A text message from the relay; true if it was about the lease.
    @discardableResult
    public func heard(_ text: String) -> Bool {
        guard let a = RemotePublicRelay.leaseAnswer(text) else { return false }
        queue.async { [self] in
            guard !ended else { return }
            asking = false
            switch a {
            case .granted:
                let was = held
                held = true
                if !wanted {
                    giveBack()
                } else if !was {
                    refusedSaid = false
                    onEvent?(.granted)
                }
            case let .refused(why):
                let was = held
                held = false
                guard wanted else { return }
                // taken back while it ran: the picture stops and the next ask goes behind anyone refused lately (the relay sees to that)
                if !refusedSaid || was {
                    refusedSaid = true
                    onEvent?(.refused(why))
                }
                let t = token
                queue.asyncAfter(deadline: .now() + askAgain) { [weak self] in
                    guard let self, t == self.token, self.wanted, !self.held, !self.asking, !self.ended else { return }
                    self.ask()
                }
            }
        }
        return true
    }

    /// The session's end: the lease goes back, and nothing more is asked.
    public func end() {
        queue.async { [self] in
            guard !ended else { return }
            wanted = false
            giveBack()
            ended = true
            token += 1
        }
    }

    private func ask() {
        asking = true
        send(RemotePublicRelay.lease(true))
    }

    private func giveBack() {
        guard held || asking else { return }
        held = false
        asking = false
        send(RemotePublicRelay.lease(false))
    }

    /// While wanted: renew every `renewEvery` while held, and stop the picture after `untouched` with nothing from the device.
    private func schedule() {
        token += 1
        let t = token
        func tick() {
            let step = min(renewEvery, max(0.05, untouched / 10))
            queue.asyncAfter(deadline: .now() + step) { [weak self] in
                guard let self, t == self.token, self.wanted, !self.ended else { return }
                let quiet = CFAbsoluteTimeGetCurrent() - self.lock.withLock { self.lastTouch }
                if quiet >= self.untouched {
                    self.wanted = false
                    self.token += 1
                    self.giveBack()
                    self.onEvent?(.untouched)
                    return
                }
                self.sinceRenew += step
                if self.sinceRenew >= self.renewEvery - 0.001 {
                    self.sinceRenew = 0
                    if self.held, !self.asking { self.send(RemotePublicRelay.lease(true)) }
                }
                tick()
            }
        }
        sinceRenew = 0
        tick()
    }
    private var sinceRenew = 0.0
}

/// Files over the public relay, counted by the sender: at most `RemotePublicRelay.filesPerDay` per device per UTC day, and a send over
/// `askOver` is asked about first. Kept by the app (it's Codable) so a restart doesn't reset the day.
public struct RemotePublicFiles: Codable, Equatable, Sendable {
    public enum Decision: Equatable, Sendable { case send, ask, over }

    /// the UTC day (days since 1970) the counts are for
    public var day: Int
    /// a device's id → bytes sent today
    public var sent: [String: Int]

    public init(day: Int = 0, sent: [String: Int] = [:]) { self.day = day; self.sent = sent }

    public static func day(_ now: Date) -> Int { Int(floor(now.timeIntervalSince1970 / 86400)) }

    /// what's left today for this device
    public func left(_ device: String, now: Date = Date()) -> Int {
        RemotePublicRelay.filesPerDay - (Self.day(now) == day ? sent[device] ?? 0 : 0)
    }

    public func decide(_ size: Int, device: String, now: Date = Date()) -> Decision {
        if size > left(device, now: now) { return .over }
        return size > RemotePublicRelay.askOver ? .ask : .send
    }

    public mutating func spend(_ size: Int, device: String, now: Date = Date()) {
        let d = Self.day(now)
        if d != day { day = d; sent = [:] }
        sent[device, default: 0] += size
    }

    /// What a send of these files counts for: their sizes, a folder's whole contents.
    public static func size(of urls: [URL]) -> Int {
        var total = 0
        for u in urls {
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if v?.isDirectory == true {
                let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
                while let f = e?.nextObject() as? URL {
                    if let r = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), r.isRegularFile == true { total += r.fileSize ?? 0 }
                }
            } else {
                total += v?.fileSize ?? 0
            }
        }
        return total
    }
}
