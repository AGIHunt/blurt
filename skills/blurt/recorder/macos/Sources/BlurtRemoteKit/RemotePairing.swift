// The pairing link the Mac's QR code holds. It opens the iPhone app whichever camera reads it:
//   blurtremote://pair?v=1&mac=<mac id>&id=<device id>&k=<key>&n=<name>&p=<port>&a=<address,address>
// The addresses let the phone connect at once where Bonjour is slow or blocked; `mac` finds the same Mac later, under
// whatever name or address it has by then.
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

    public init(macID: String, deviceID: String, key: Data, macName: String, port: UInt16, addresses: [String]) {
        self.macID = macID; self.deviceID = deviceID; self.key = key; self.macName = macName; self.port = port; self.addresses = addresses
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "pair"
        c.queryItems = [.init(name: "v", value: "\(RemoteCrypto.version)"), .init(name: "mac", value: macID), .init(name: "id", value: deviceID),
                        .init(name: "k", value: RemoteCrypto.base64url(key)), .init(name: "n", value: macName), .init(name: "p", value: "\(port)"),
                        .init(name: "a", value: addresses.joined(separator: ","))]
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
                  addresses: (q("a") ?? "").split(separator: ",").map(String.init))
    }
}
