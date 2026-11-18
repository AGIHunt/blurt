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

    public static func ask(from localPort: UInt16, server: String = "stun.cloudflare.com", port: UInt16 = 3478, queue: DispatchQueue, done: @escaping (RemoteCandidate?) -> Void) {
        let s = RemoteSTUN(queue: queue)
        s.done = done
        s.start(localPort, server, port)
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
