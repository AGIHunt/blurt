// The session's cryptography (docs/design/remote.md §Security). A key press on the phone becomes a key press on the Mac,
// so nothing on the network may read or forge one.
//
//  Pairing: the Mac shows a QR code holding a fresh 256-bit key and a device id; the phone keeps both in its Keychain,
//  the Mac in its own. The code is good for one phone and two minutes.
//  Session: each side makes a throwaway X25519 key. HKDF over the Diffie-Hellman secret, salted with the paired key and
//  bound to the transcript, gives one key each way: a stolen paired key can't read past traffic, and without the
//  paired key nobody finishes the handshake.
//    phone → Mac   hello  {v, id, eph}                       in the clear; `id` picks the paired key
//    Mac → phone   hello  {v, eph, proof}                    proof = HMAC(paired key, "mac" ∥ transcript)
//    phone → Mac   first sealed frame                        only the paired key could have sealed it
//  Frames: ChaCha20-Poly1305. The nonce is a counter, per direction and per channel (TCP in order, so implicit; UDP sent
//  with the packet, anything not newer than the last one taken is dropped).
import CryptoKit
import Foundation

public enum RemoteCrypto {
    public static let version = 1

    public static func newKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    public static func newID() -> String { base64url(SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }) }

    public static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    public static func base64url(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    static func transcript(id: String, phoneEph: Data, macEph: Data) -> Data {
        var h = SHA256()
        h.update(data: Data("blurt-remote-\(version)".utf8))
        h.update(data: Data(id.utf8))
        h.update(data: phoneEph)
        h.update(data: macEph)
        return Data(h.finalize())
    }

    static func proof(paired: Data, transcript: Data) -> Data {
        var m = Data("mac".utf8)
        m.append(transcript)
        return Data(HMAC<SHA256>.authenticationCode(for: m, using: SymmetricKey(data: paired)))
    }

    static func sessionKeys(secret: SharedSecret, paired: Data, transcript: Data) -> (toMac: SymmetricKey, toPhone: SymmetricKey) {
        let k = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: paired, sharedInfo: transcript, outputByteCount: 64)
        return k.withUnsafeBytes { b in
            (SymmetricKey(data: Data(b.prefix(32))), SymmetricKey(data: Data(b.suffix(32))))
        }
    }
}

public struct RemoteHandshakeError: Error, Equatable {
    public enum Kind: Equatable { case notPaired, badProof, badMessage, version }
    public let kind: Kind
    public init(_ k: Kind) { kind = k }
}

struct PhoneHello: Codable { var v: Int; var id: String; var eph: Data }
struct MacHello: Codable { var v: Int; var eph: Data?; var proof: Data?; var error: String? }

/// The phone's end of the handshake.
public struct PhoneHandshake {
    public let id: String
    let paired: Data
    let eph = Curve25519.KeyAgreement.PrivateKey()

    public init(id: String, paired: Data) { self.id = id; self.paired = paired }

    public func hello() -> Data {
        (try? JSONEncoder().encode(PhoneHello(v: RemoteCrypto.version, id: id, eph: eph.publicKey.rawRepresentation))) ?? Data()
    }

    public func finish(_ reply: Data) throws -> RemoteSealer {
        guard let m = try? JSONDecoder().decode(MacHello.self, from: reply) else { throw RemoteHandshakeError(.badMessage) }
        if m.error == "not_paired" { throw RemoteHandshakeError(.notPaired) }
        guard m.v == RemoteCrypto.version else { throw RemoteHandshakeError(.version) }
        guard let e = m.eph, let proof = m.proof, let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: e),
              let secret = try? eph.sharedSecretFromKeyAgreement(with: pub) else { throw RemoteHandshakeError(.badMessage) }
        let t = RemoteCrypto.transcript(id: id, phoneEph: eph.publicKey.rawRepresentation, macEph: e)
        guard HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data("mac".utf8) + t, using: SymmetricKey(data: paired)) else {
            throw RemoteHandshakeError(.badProof)
        }
        let k = RemoteCrypto.sessionKeys(secret: secret, paired: paired, transcript: t)
        return RemoteSealer(send: k.toMac, receive: k.toPhone)
    }
}

/// The Mac's end: `lookup` says which paired key an id has (nil: not one of ours).
public enum MacHandshake {
    public struct Answer {
        public let reply: Data
        public let sealer: RemoteSealer?
        public let id: String?
    }

    public static func answer(_ hello: Data, lookup: (String) -> Data?) -> Answer {
        func refuse(_ e: String) -> Answer {
            Answer(reply: (try? JSONEncoder().encode(MacHello(v: RemoteCrypto.version, eph: nil, proof: nil, error: e))) ?? Data(), sealer: nil, id: nil)
        }
        guard let h = try? JSONDecoder().decode(PhoneHello.self, from: hello) else { return refuse("bad_message") }
        guard h.v == RemoteCrypto.version else { return refuse("version") }
        guard let paired = lookup(h.id) else { return refuse("not_paired") }
        guard let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: h.eph) else { return refuse("bad_message") }
        let eph = Curve25519.KeyAgreement.PrivateKey()
        guard let secret = try? eph.sharedSecretFromKeyAgreement(with: pub) else { return refuse("bad_message") }
        let macEph = eph.publicKey.rawRepresentation
        let t = RemoteCrypto.transcript(id: h.id, phoneEph: h.eph, macEph: macEph)
        let k = RemoteCrypto.sessionKeys(secret: secret, paired: paired, transcript: t)
        let m = MacHello(v: RemoteCrypto.version, eph: macEph, proof: RemoteCrypto.proof(paired: paired, transcript: t), error: nil)
        return Answer(reply: (try? JSONEncoder().encode(m)) ?? Data(), sealer: RemoteSealer(send: k.toPhone, receive: k.toMac), id: h.id)
    }
}

/// Seals and opens a session's frames. Not thread-safe: each side uses it from its connection's queue.
public final class RemoteSealer {
    let sendKey: SymmetricKey
    let receiveKey: SymmetricKey
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    private var sentUDP: UInt64 = 0
    private var receivedUDP: UInt64 = 0
    private var seenUDP: UInt64 = 0

    init(send: SymmetricKey, receive: SymmetricKey) { sendKey = send; receiveKey = receive }

    private static func nonce(_ channel: UInt32, _ n: UInt64) -> ChaChaPoly.Nonce {
        var d = Data(capacity: 12)
        withUnsafeBytes(of: channel.bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: n.bigEndian) { d.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: d)   // 12 bytes, always
    }

    /// TCP: the frame is ciphertext ∥ tag; the nonce is how many came before.
    public func seal(_ plain: Data) throws -> Data {
        defer { sent += 1 }
        let b = try ChaChaPoly.seal(plain, using: sendKey, nonce: Self.nonce(0, sent))
        var f = Data(capacity: plain.count + 16)
        f.append(b.ciphertext)
        f.append(b.tag)
        return f
    }

    public func open(_ frame: Data) throws -> Data {
        guard frame.count >= 16 else { throw CryptoKitError.incorrectParameterSize }
        let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(0, received), ciphertext: frame.dropLast(16), tag: frame.suffix(16))
        let d = try ChaChaPoly.open(box, using: receiveKey)
        received += 1
        return d
    }

    /// UDP: session (4) ∥ counter (8) ∥ ciphertext ∥ tag. The session id isn't secret, it finds the session on the Mac.
    public func sealPacket(_ plain: Data, session: UInt32) throws -> Data {
        sentUDP += 1
        let b = try ChaChaPoly.seal(plain, using: sendKey, nonce: Self.nonce(1, sentUDP))
        var d = Data(capacity: 12 + plain.count + 16)
        withUnsafeBytes(of: session.bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: sentUDP.bigEndian) { d.append(contentsOf: $0) }
        return d + b.ciphertext + b.tag
    }

    public static func sessionOfPacket(_ p: Data) -> UInt32? {
        guard p.count >= 28 else { return nil }
        return p.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    /// nil: forged, damaged, or a replay. Wi-Fi reorders a little, and a video frame's pieces can come in any order, so anything
    /// in the last 64 counts that hasn't been seen is taken; older is dropped.
    public func openPacket(_ p: Data) -> Data? {
        guard p.count >= 28 else { return nil }
        let n = p.dropFirst(4).prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard n > 0 else { return nil }
        if n <= receivedUDP {
            let back = receivedUDP - n
            guard back < 64, seenUDP & (1 << back) == 0 else { return nil }
        }
        let body = p.dropFirst(12)
        guard let box = try? ChaChaPoly.SealedBox(nonce: Self.nonce(1, n), ciphertext: body.dropLast(16), tag: body.suffix(16)),
              let d = try? ChaChaPoly.open(box, using: receiveKey) else { return nil }
        if n > receivedUDP {
            let up = n - receivedUDP
            seenUDP = up >= 64 ? 0 : seenUDP << up
            receivedUDP = n
            seenUDP |= 1
        } else {
            seenUDP |= 1 << (receivedUDP - n)
        }
        return d
    }
}

/// Length-prefixed frames over a byte stream: 4 bytes big-endian, then the frame. Until the handshake is done a frame can
/// only be a hello, so `limit` stays small: nobody unauthenticated gets to make the Mac hold a megabyte.
public struct RemoteFrameReader {
    public static let maxFrame = 1 << 20
    public static let maxHello = 1024
    public var limit = RemoteFrameReader.maxHello
    private var buffer = Data()
    private var head = 0
    public init() {}

    public static func framed(_ d: Data) -> Data {
        var o = Data(capacity: 4 + d.count)
        withUnsafeBytes(of: UInt32(d.count).bigEndian) { o.append(contentsOf: $0) }
        o.append(d)
        return o
    }

    /// Next whole frame, or nil when more bytes are needed. Throws for a frame that can't be ours.
    public mutating func next() throws -> Data? {
        guard buffer.count - head >= 4 else { return nil }
        let start = buffer.startIndex + head
        let n = buffer[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
        guard n > 0, n <= limit else { throw RemoteFrameError.badLength }
        guard buffer.count - head >= 4 + n else { return nil }
        let f = Data(buffer[start + 4..<start + 4 + n])
        head += 4 + n
        if head == buffer.count { buffer = Data(); head = 0 }
        return f
    }

    public mutating func feed(_ d: Data) {
        if head > 0 { buffer = Data(buffer.dropFirst(head)); head = 0 }
        buffer.append(d)
    }
}

public enum RemoteFrameError: Error { case badLength }
