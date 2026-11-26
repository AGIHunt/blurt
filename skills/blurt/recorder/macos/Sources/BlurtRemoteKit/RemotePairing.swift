// The pairing link the Mac's QR code holds. It opens the iPhone app whichever camera reads it:
//   blurtremote://pair?v=1&mac=<mac id>&id=<device id>&k=<key>&n=<name>&p=<port>&a=<address,address>&r=<relay>
// The addresses let the phone connect at once where Bonjour is slow or blocked; `mac` finds the same Mac later, under
// whatever name or address it has by then. The relay, where the Mac has one, lets a phone pair from another network.
import Foundation

public struct RemotePairing: Equatable, Sendable {
    public static let serviceType = "_blurt-remote._tcp"
    public static let scheme = "blurtremote"

    public var macID: String
    public var deviceID: String
    public var key: Data
    public var macName: String
    public var port: UInt16
    public var addresses: [String]
    public var relay: String?

    public init(macID: String, deviceID: String, key: Data, macName: String, port: UInt16, addresses: [String], relay: String? = nil) {
        self.macID = macID; self.deviceID = deviceID; self.key = key; self.macName = macName; self.port = port; self.addresses = addresses; self.relay = relay
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "pair"
        c.queryItems = [.init(name: "v", value: "\(RemoteCrypto.version)"), .init(name: "mac", value: macID), .init(name: "id", value: deviceID),
                        .init(name: "k", value: RemoteCrypto.base64url(key)), .init(name: "n", value: macName), .init(name: "p", value: "\(port)"),
                        .init(name: "a", value: addresses.joined(separator: ","))]
        if let relay { c.queryItems?.append(.init(name: "r", value: relay)) }
        return c.url!
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
        guard q("v") == "\(RemoteCrypto.version)", let mac = q("mac"), !mac.isEmpty, let id = q("id"), !id.isEmpty,
              let k = q("k").flatMap({ RemoteCrypto.base64url($0) }), k.count == 32,
              let p = q("p").flatMap(UInt16.init) else { return nil }
        self.init(macID: mac, deviceID: id, key: k, macName: q("n") ?? "Mac", port: p,
                  addresses: (q("a") ?? "").split(separator: ",").map(String.init), relay: q("r").flatMap(RemoteRelay.address))
    }
}

/// While a code is being used to join, the other end is only known to hold that code, and anyone with a photo of it or the copied link can
/// answer as the computer. So the joining side takes `newKey` only after the computer asked (`pairingWaits`, which shows the digits) and
/// this side's user said the digits are the same as the computer's: the yes and the key may come in either order. A key before the
/// question is dropped, not held. A new connection starts over, since its digits are new. Every client runs the same rule, checked against
/// `vectors.json` → `joinGate` (docs/design/remote-protocol.md, security review F1, 2026-11-26).
public struct RemoteJoinGate: Equatable, Sendable {
    public enum Event: String, CaseIterable, Sendable { case pairingWaits, same, newKey, reconnect }

    /// the computer asked: the digits are on screen
    public private(set) var asked = false
    /// this side's user said they're the same
    public private(set) var confirmed = false
    private var held: Data?

    public init() {}

    /// the digits can be confirmed now (shown, and not yet confirmed)
    public var canConfirm: Bool { asked && !confirmed }
    /// the computer said yes; this side's user hasn't yet
    public var keyWaiting: Bool { held != nil }

    public mutating func pairingWaits() { asked = true }

    /// The user says the digits are the same. The key to store now, when the computer's yes came first.
    public mutating func confirm() -> Data? {
        guard asked else { return nil }
        confirmed = true
        defer { held = nil }
        return held
    }

    /// The computer's `newKey`. The key to store now, or nil: held until the user's yes, or dropped when the computer never asked.
    public mutating func newKey(_ k: Data) -> Data? {
        guard asked else { return nil }
        if confirmed { return k }
        held = k
        return nil
    }

    /// a new connection: new digits, asked again
    public mutating func reset() { self = Self() }

    /// Runs `events` in order (the vectors' form); the index of the event at which the key is stored, or nil.
    public static func run(_ events: [Event], key: Data = Data(repeating: 7, count: 32)) -> Int? {
        var g = Self()
        for (i, e) in events.enumerated() {
            let got: Data? = switch e {
            case .pairingWaits: { g.pairingWaits(); return nil }()
            case .same: g.confirm()
            case .newKey: g.newKey(key)
            case .reconnect: { g.reset(); return nil }()
            }
            if got != nil { return i }
        }
        return nil
    }

    /// The cases every client checks (`vectors.json` → `joinGate.cases`).
    public static let cases: [[Event]] = [
        [.newKey],
        [.pairingWaits, .newKey],
        [.pairingWaits, .same, .newKey],
        [.pairingWaits, .newKey, .same],
        [.same, .pairingWaits, .newKey],
        [.newKey, .pairingWaits, .same],
        [.pairingWaits, .same, .reconnect, .newKey],
        [.pairingWaits, .newKey, .reconnect, .pairingWaits, .same],
        [.pairingWaits, .same, .reconnect, .pairingWaits, .newKey],
        [.pairingWaits, .same, .reconnect, .pairingWaits, .same, .newKey],
    ]
}
