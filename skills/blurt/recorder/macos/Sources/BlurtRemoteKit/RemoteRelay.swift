// Reaching the Mac from anywhere (docs/design/remote.md §Away from home). Blurt runs no relay: its owner sets one up, on their own
// Cloudflare account or server (tools/remote-relay), and gives the Mac its address; the phone hears it inside the sealed session.
// A WebSocket relay always works, but every byte goes round by it. So once a session is up over the relay, both ends
// also try for a direct path: they trade addresses inside the sealed session (public IPv6, and what a STUN server sees of their
// IPv4), send each other packets to open their firewalls, and the pointer and video move to the first path that answers.
// The relay stays for control. It only ever sees sealed bytes.
import CryptoKit
import Foundation
import Network

public enum RemoteRelay {
    public static let macGone: UInt16 = 4001
    public static let phoneLeft: UInt16 = 4000
    public static let replaced: UInt16 = 4002
    /// the go-between's budget for one connection is spent: it can't carry this session (docs/design/remote-go-between.md)
    public static let overBudget: UInt16 = 4003

    /// Blurt's go-between: phone and computer meet there, then move onto the direct path. Used only when the owner has no relay of their
    /// own and hasn't turned it off, and only with a phone that can move (`RemoteFeature.move`).
    public static let goBetween = "wss://meet.blurt.work"

    /// This address is Blurt's go-between, not someone's own relay.
    public static func isGoBetween(_ address: String?) -> Bool {
        guard let a = address.flatMap(self.address), let h = URLComponents(string: a)?.host else { return false }
        return h.lowercased() == "meet.blurt.work"
    }

    /// The go-between turned the connection away: the upgrade was refused (HTTP 429 when the day's quota or the rate limit is spent; any
    /// other answer that isn't a WebSocket counts the same). The TCP and TLS parts worked, so it isn't this network. Network.framework
    /// reports a refused upgrade as a connection abort.
    public static func refused(_ e: NWError?) -> Bool {
        if case .posix(.ECONNABORTED)? = e { return true }
        return false
    }

    /// How long to leave the go-between alone after it turned us away `times` times in a row: 30 s, 2 min, 10 min, then hourly. Never a
    /// loop of retries against a quota that resets at 00:00 UTC.
    public static func busyWait(_ times: Int) -> Double {
        switch times {
        case ..<2: 30
        case 2: 120
        case 3: 600
        default: 3600
        }
    }

    /// A computer's close code when it's going to sleep: the relay keeps the time for `peek` ("asleep since")
    public static let asleep: UInt16 = 4010

    /// Derived from the paired key: unguessable, and it says nothing about the pair.
    public static func room(key: Data) -> String {
        RemoteCrypto.base64url(Data(HMAC<SHA256>.authenticationCode(for: Data("blurt-relay-room".utf8), using: SymmetricKey(data: key))))
    }

    /// What someone typed, as the address to use: `relay.example.com` means wss://. nil if it can't be one. `ws://` is allowed: what
    /// passes through is sealed either way, and a bare server with an open port needs no domain or certificate.
    public static func address(_ typed: String) -> String? {
        var t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.contains("://") { t = "wss://" + t }
        while t.hasSuffix("/") { t.removeLast() }
        guard let u = URLComponents(string: t), u.scheme == "wss" || u.scheme == "ws", let h = u.host, !h.isEmpty, u.query == nil, u.fragment == nil else { return nil }
        return t
    }

    public static func connection(address: String, room: String, role: String) -> NWConnection? {
        guard let a = self.address(address), let url = URL(string: "\(a)/v1/\(room)/\(role)") else { return nil }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 8
        let params = url.scheme == "wss" ? NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp) : NWParameters(tls: nil, tcp: tcp)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 1 << 21
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        return NWConnection(to: .url(url), using: params)
    }
}

/// What a relay says of a room's computer without joining it (`GET …/peek`): waiting there now, else since when it's asleep (it said so
/// before sleeping) or last seen. Only a paired device can ask: the room comes from the pair's key.
public struct RemotePresence: Equatable, Sendable {
    public var host: Bool
    public var asleep: Date?
    public var seen: Date?
    public init(host: Bool, asleep: Date? = nil, seen: Date? = nil) { self.host = host; self.asleep = asleep; self.seen = seen }
}

extension RemoteRelay {
    /// The room's computer, as the relay at `address` knows it; nil when it can't say (an older relay, or no answer in 5 s).
    public static func peek(address: String, room: String, done: @escaping @Sendable (RemotePresence?) -> Void) {
        guard let a = self.address(address), var u = URLComponents(string: "\(a)/v1/\(room)/peek") else { return done(nil) }
        u.scheme = u.scheme == "wss" ? "https" : "http"
        guard let url = u.url else { return done(nil) }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        r.httpMethod = "GET"
        URLSession.shared.dataTask(with: r) { d, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let d, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let host = o["host"] as? Bool else { return done(nil) }
            let date = { (k: String) in (o[k] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
            done(RemotePresence(host: host, asleep: date("asleep"), seen: date("seen")))
        }.resume()
    }
}

extension RemoteRelay {
    /// Does anything answer as a relay at this address? For Settings: a throwaway room, gone as soon as it's opened.
    public static func check(address: String, queue: DispatchQueue, done: @escaping (Bool) -> Void) {
        let room = RemoteCrypto.base64url(RemoteCrypto.newKey())
        guard let c = connection(address: address, room: room, role: "mac") else { return done(false) }
        var finished = false
        func finish(_ ok: Bool) {
            guard !finished else { return }
            finished = true
            c.cancel()
            done(ok)
        }
        c.stateUpdateHandler = { s in
            switch s {
            case .ready: finish(true)
            case .failed, .waiting: finish(false)
            default: break
            }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) { finish(false) }
    }
}

/// Overlay networks (Tailscale, ZeroTier and the like): an address on one reaches the computer from anywhere, with no server in between.
public enum RemoteOverlay: String, Sendable {
    case tailscale, other

    /// Tailscale's ranges: IPv4 100.64.0.0/10 (shared address space, which Tailscale uses for its nodes), IPv6 fd7a:115c:a1e0::/48.
    public static func isTailscale(_ address: String) -> Bool {
        let a = address.split(separator: "%").first.map(String.init) ?? address
        if a.contains(":") {
            var v6 = in6_addr()
            guard inet_pton(AF_INET6, a, &v6) == 1 else { return false }
            let b = withUnsafeBytes(of: v6) { Array($0) }
            return b[0] == 0xfd && b[1] == 0x7a && b[2] == 0x11 && b[3] == 0x5c && b[4] == 0xa1 && b[5] == 0xe0
        }
        var v4 = in_addr()
        guard inet_pton(AF_INET, a, &v4) == 1 else { return false }
        let b = withUnsafeBytes(of: v4) { Array($0) }
        return b[0] == 100 && b[1] & 0xc0 == 64
    }

    /// An interface that only carries an overlay network: ZeroTier's (`zt…` on Linux and Windows, `feth…` on a Mac). Tailscale's are
    /// `utun…` / `tailscale…`, shared with every other VPN, so its addresses are told by their range instead.
    public static func isOverlayInterface(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix("zt") || n.hasPrefix("feth") || n.hasPrefix("tailscale") || n.contains("zerotier")
    }

    /// An address a phone may keep and try at the host's TCP port when away: private, shared (CGNAT / Tailscale) or unique-local, never a
    /// public one (the direct path's business) or a link-local one.
    public static func worthTrying(_ address: String) -> Bool {
        if isTailscale(address) { return true }
        if address.contains(":") {
            let l = address.lowercased()
            return l.hasPrefix("fd") || l.hasPrefix("fc")
        }
        var v4 = in_addr()
        guard inet_pton(AF_INET, address, &v4) == 1 else { return false }
        let b = withUnsafeBytes(of: v4) { Array($0) }
        return b[0] == 10 || (b[0] == 172 && b[1] & 0xf0 == 16) || (b[0] == 192 && b[1] == 168)
    }
}

public struct RemoteCandidate: Codable, Hashable, Sendable {
    public var host: String
    public var port: UInt16
    public init(host: String, port: UInt16) { self.host = host; self.port = port }
}

/// This machine's public IPv6 addresses: reachable as they are, where a firewall lets a reply through.
public enum RemoteAddresses {
    public static func publicIPv6() -> [String] {
        var out: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let a = i.ifa_addr, a.pointee.sa_family == UInt8(AF_INET6), i.ifa_flags & UInt32(IFF_LOOPBACK) == 0, i.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let s = String(cString: host)
            if let c = s.first, c == "2" || c == "3", !s.contains("%") { out.append(s) }
        }
        return out
    }
}

/// What the outside world sees of a local UDP port.
public final class RemoteSTUN {
    private var c: NWConnection?
    private var done: ((RemoteCandidate?) -> Void)?
    private let queue: DispatchQueue
    private let txn = (0..<12).map { _ in UInt8.random(in: 0...255) }
    private static let cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]

    private init(queue: DispatchQueue) { self.queue = queue }

    /// Asked together, the first answer taken, as on Windows and Linux (crates/blurt-remote relay.rs STUN_SERVERS): Cloudflare's, and one
    /// that answers from mainland China, where Cloudflare's doesn't (2026-11-09). Wherever the user is, one of them does.
    public static let servers: [(host: String, port: UInt16)] = [("stun.cloudflare.com", 3478), ("stun.miwifi.com", 3478)]

    /// `queue` must be serial: the answers are counted on it.
    /// The first answer ends the others at once: they share the local port the direct path uses, and one left open takes its packets.
    public static func ask(from localPort: UInt16, queue: DispatchQueue, done: @escaping (RemoteCandidate?) -> Void) {
        var answered = false, left = servers.count
        var all: [RemoteSTUN] = []
        for s in servers {
            all.append(ask(from: localPort, server: s.host, port: s.port, queue: queue) { c in
                left -= 1
                guard !answered else { return }
                if let c {
                    answered = true
                    all.forEach { $0.cancel() }
                    done(c)
                } else if left == 0 {
                    answered = true
                    done(nil)
                }
            })
        }
    }

    @discardableResult
    public static func ask(from localPort: UInt16, server: String, port: UInt16, queue: DispatchQueue, done: @escaping (RemoteCandidate?) -> Void) -> RemoteSTUN {
        let s = RemoteSTUN(queue: queue)
        s.done = done
        s.start(localPort, server, port)
        return s
    }

    /// No answer wanted any more: the port is let go now.
    func cancel() {
        done = nil
        c?.cancel()
        c = nil
    }

    private func finish(_ r: RemoteCandidate?) {
        let d = done
        done = nil
        c?.cancel()
        c = nil
        d?(r)
    }

    private func start(_ localPort: UInt16, _ server: String, _ port: UInt16) {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        if localPort != 0, let p = NWEndpoint.Port(rawValue: localPort) { params.requiredLocalEndpoint = .hostPort(host: "0.0.0.0", port: p) }
        guard let p = NWEndpoint.Port(rawValue: port) else { return finish(nil) }
        let c = NWConnection(host: NWEndpoint.Host(server), port: p, using: params)
        self.c = c
        let request = Data([0, 1, 0, 0] + Self.cookie + txn)
        c.stateUpdateHandler = { [self] s in
            switch s {
            case .ready:
                c.send(content: request, completion: .idempotent)
                c.receiveMessage { [self] d, _, _, _ in finish(d.flatMap(self.parse)) }
            case .failed: finish(nil)
            default: break
            }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { [self] in finish(nil) }
    }

    func parse(_ d: Data) -> RemoteCandidate? {
        let b = [UInt8](d)
        guard b.count >= 20, b[0] == 1, b[1] == 1, Array(b[4..<8]) == Self.cookie, Array(b[8..<20]) == txn else { return nil }
        var at = 20
        while at + 4 <= b.count {
            let type = Int(b[at]) << 8 | Int(b[at + 1]), len = Int(b[at + 2]) << 8 | Int(b[at + 3])
            guard at + 4 + len <= b.count else { return nil }
            if type == 0x0020, len >= 8, b[at + 5] == 1 {       // XOR-MAPPED-ADDRESS, IPv4
                let port = (UInt16(b[at + 6]) ^ 0x21) << 8 | (UInt16(b[at + 7]) ^ 0x12)
                let ip = (0..<4).map { String(b[at + 8 + $0] ^ Self.cookie[$0]) }.joined(separator: ".")
                return RemoteCandidate(host: ip, port: port)
            }
            at += 4 + (len + 3) / 4 * 4
        }
        return nil
    }
}
