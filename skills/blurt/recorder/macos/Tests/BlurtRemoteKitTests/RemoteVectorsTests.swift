// The wire format, written down as examples every other implementation checks itself against (docs/design/remote-protocol.md):
// the Rust host for Windows and Linux, the Android app. tests/remote-vectors/vectors.json is made here and committed; this test fails
// when the Swift side drifts from it. To write it again after a deliberate change:
//   BLURT_WRITE_VECTORS=1 swift test --filter RemoteVectorsTests
import CryptoKit
import XCTest
@testable import BlurtRemoteKit

final class RemoteVectorsTests: XCTestCase {
    private static let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()   // macos/
        .appendingPathComponent("../../../../tests/remote-vectors/vectors.json").standardizedFileURL

    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    private func bytes(_ seed: UInt8, _ n: Int = 32) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: Int(seed) &+ $0 &* 7) }) }

    private func json<T: Encodable>(_ v: T) throws -> Any {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try JSONSerialization.jsonObject(with: e.encode(v), options: [.fragmentsAllowed])
    }

    private func toMac() -> [(String, ToMac)] {
        let crop = RemoteCrop(x: 0.25, y: 0.125, w: 0.5, h: 0.5)
        return [
            ("key_tap", .key(RemoteChord(.command, "C"), down: nil)),
            ("key_down", .key(RemoteChord([.command, .shift], "Tab"), down: true)),
            ("key_up_modifier_alone", .key(RemoteChord(.shift, ""), down: false)),
            ("mods", .mods([.command, .option])),
            ("run", .run([.key(RemoteChord([], "Escape")), .wait(80), .key(RemoteChord([], "Escape")), .text("/compact")])),
            ("text", .text("你好 hello\n")),
            ("button_down", .button(.left, down: true)),
            ("button_up_right", .button(.right, down: false)),
            ("drag_begin", .dragBegin),
            ("dictation_key", .dictationKey(down: true)),
            ("blurt", .blurt(.voiceNote)),
            ("system", .system(.missionControl)),
            ("activate", .activate(bundle: "com.apple.Terminal")),
            ("hud", .hud("常用")),
            ("hello", .hello(device: "Pixel 9", micOnPhone: true, nonce: bytes(9))),
            ("hello_no_nonce", .hello(device: "iPhone", micOnPhone: false)),
            ("set_mic_on_phone", .setMicOnPhone(false)),
            ("release_all", .releaseAll),
            ("key_stored", .keyStored),
            ("screen", .screen(RemoteScreenRequest(target: "display", crop: crop, width: 1600, height: 1000, bitrate: 4_000_000, fps: 30, codecs: ["h264"]))),
            ("screen_old_phone", .screen(RemoteScreenRequest(target: "display", width: 1280, height: 800, bitrate: 1_000_000, fps: 15, codecs: nil))),
            ("screen_off", .screen(nil)),
            ("screen_pinned_display", .screen(RemoteScreenRequest(target: "display", width: 1600, height: 900, bitrate: 4_000_000, fps: 30, codecs: ["h264"], display: "69733382"))),
            ("show_display", .showDisplay("69733382")),
            ("show_display_follow", .showDisplay(nil)),
            ("screen_crop", .screenCrop(crop)),
            ("pointer_to", .pointerTo(x: 0.5, y: 0.75)),
            ("candidates", .candidates([RemoteCandidate(host: "203.0.113.5", port: 50123), RemoteCandidate(host: "2001:db8::1", port: 50123)])),
            ("request_keyframe", .requestKeyframe),
            ("screen_report", .screenReport(RemoteScreenReport(frames: 30, lost: 1, rtt: 0.25, received: 123_456))),
            ("screen_report_no_rtt", .screenReport(RemoteScreenReport(frames: 0, lost: 0, rtt: nil, received: 0))),
            ("screen_pace", .screenPace(idle: true)),
            ("unpair", .unpair),
            ("replaces", .replaces(deviceID: "old-device-id")),
            ("offer_relay", .offerRelay("wss://relay.example.com")),
            ("screen_stats", .screenStats("fps=30")),
            ("screen_snapshot", .screenSnapshot(name: "a", jpeg: Data([0xff, 0xd8, 0xff]))),
            ("ping", .ping(12.5)),
        ]
    }

    private func toPhone() -> [(String, ToPhone)] {
        [
            ("session", .session(RemoteSessionInfo(macName: "Studio PC", udpPort: 50123, udpSession: 7, canControl: true, version: "1.0.15",
                                                   candidates: [RemoteCandidate(host: "192.168.1.20", port: 50123)], displayAspect: 1.5,
                                                   relay: "wss://relay.example.com", platform: "windows"))),
            ("session_old_mac", .session(RemoteSessionInfo(macName: "Mac", udpPort: 1, udpSession: 2, canControl: false, version: "1.0.13", platform: nil))),
            ("can_control", .canControl(true)),
            ("front", .front(RemoteFront(bundle: "WindowsTerminal.exe", name: "Terminal"))),
            ("dictation", .dictation(.listening)),
            ("live", .live(committed: "你好", pending: " wor")),
            ("level", .level(0.5)),
            ("typed", .typed("hello")),
            ("notice", .notice("Copied")),
            ("pong", .pong(12.5)),
            ("udp_ok", .udpOK),
            ("removed", .removed),
            ("relay", .relay("wss://relay.example.com")),
            ("relay_none", .relay(nil)),
            ("replaced", .replaced),
            ("pairing_waits", .pairingWaits),
            ("listen", .listen(true)),
            ("new_key", .newKey(bytes(3))),
            ("clock", .clock(phone: 100.5, mac: 2000.25)),
            ("screen_failed", .screenFailed("Screen Recording is off")),
            ("screen_view", .screenView(width: 1920, height: 1080, codec: "h264")),
            ("screen_view_old_mac", .screenView(width: 1512, height: 982)),
            ("screen_view_display", .screenView(width: 2560, height: 1440, codec: "hevc", display: "69733382")),
            ("displays", .displays([RemoteDisplay(id: "1", name: "Built-in Retina Display", x: 0, y: 0, width: 1512, height: 982, main: true),
                                    RemoteDisplay(id: "69733382", name: "DELL U2723QE", x: 1512, y: -458, width: 2560, height: 1440, main: false)])),
            ("cursor_shape", .cursorShape(png: Data([0x89, 0x50]), hotX: 1, hotY: 2, width: 16, height: 24)),
        ]
    }

    private func build() throws -> [String: Any] {
        var out: [String: Any] = [
            "about": "Written by RemoteVectorsTests.swift (skills/blurt/recorder/macos). Spec: docs/design/remote-protocol.md. Byte fields are lowercase hex; JSON is compared as parsed values, not text.",
            "version": RemoteCrypto.version,
        ]
        out["toMac"] = try toMac().map { ["name": $0.0, "json": try json($0.1)] }
        out["toPhone"] = try toPhone().map { ["name": $0.0, "json": try json($0.1)] }

        let pointers: [(String, RemotePointerPacket)] = [
            ("move", .move(dx: 1.5, dy: -2.25)), ("scroll", .scroll(dx: 0, dy: 10, phase: .changed)),
            ("scroll_began", .scroll(dx: -3, dy: 0.5, phase: .began)), ("fling", .scrollFling(vx: 100, vy: -50)), ("stop", .scrollStop),
        ]
        out["pointer"] = pointers.map { ["name": $0.0, "hex": hex($0.1.encoded())] }

        let crop = RemoteCrop(x: 0.25, y: 0.125, w: 0.5, h: 0.5)
        let payload = RemoteVideoPayload.pack(crop: crop, parameterSets: [Data([0x40, 0x01]), Data([0x42, 0x01, 0x02])], picture: Data([0, 0, 0, 1, 0x26, 0x01]))
        let pieces = RemoteVideoPacket.split(payload, frame: 42, keyframe: true, captured: 1234.5, payload: 16)
        out["video"] = [
            "payload": ["crop": try json(crop), "parameterSets": ["4001", "420102"], "picture": "000000012601", "hex": hex(payload)],
            "packets": ["frame": 42, "keyframe": true, "captured": 1234.5, "pieceSize": 16, "hex": pieces.map { hex($0.encoded()) }],
        ]
        var cursor = Data()
        for v: Float in [0.5, 0.25] { withUnsafeBytes(of: v.bitPattern.littleEndian) { cursor.append(contentsOf: $0) } }
        out["cursor"] = ["x": 0.5, "y": 0.25, "hex": hex(cursor)]

        // The handshake with fixed keys, and the first frames each way.
        let paired = bytes(1), phonePriv = bytes(2), macPriv = bytes(5), nonce = bytes(9), id = "device-id-1"
        let pe = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: phonePriv)
        let me = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: macPriv)
        let phoneEph = pe.publicKey.rawRepresentation, macEph = me.publicKey.rawRepresentation
        let t = RemoteCrypto.transcript(id: id, phoneEph: phoneEph, macEph: macEph)
        let secret = try pe.sharedSecretFromKeyAgreement(with: me.publicKey)
        let keys = RemoteCrypto.sessionKeys(secret: secret, paired: paired, transcript: t)
        let phone = RemoteSealer(send: keys.toMac, receive: keys.toPhone, transcript: t)
        let mac = RemoteSealer(send: keys.toPhone, receive: keys.toMac, transcript: t)
        // bytes that get sealed must be the same on every run: sorted keys (another implementation seals the `plain` given here, it
        // doesn't re-encode the JSON itself)
        let sorted = JSONEncoder()
        sorted.outputFormatting = [.sortedKeys]
        let hello = try sorted.encode(PhoneHello(v: 1, id: id, eph: phoneEph, c: RemoteCrypto.commitment(nonce)))
        let reply = try sorted.encode(MacHello(v: 1, eph: macEph, proof: RemoteCrypto.proof(paired: paired, transcript: t), error: nil))
        let first = Data([RemoteFrameKind.control.rawValue]) + (try sorted.encode(ToMac.hello(device: "Pixel", micOnPhone: true, nonce: nonce)))
        let f0 = try phone.seal(first), f1 = try phone.seal(Data([RemoteFrameKind.audio.rawValue, 1, 0, 2, 0]))
        let backPlain = Data([RemoteFrameKind.control.rawValue]) + (try sorted.encode(ToPhone.udpOK))
        let back0 = try mac.seal(backPlain)
        let udp1 = try phone.sealPacket(Data([RemoteFrameKind.pointer.rawValue]) + RemotePointerPacket.scrollStop.encoded(), session: 7)
        let udp2 = try phone.sealPacket(Data([RemoteFrameKind.pointer.rawValue]) + RemotePointerPacket.move(dx: 1, dy: 1).encoded(), session: 7)
        let sharedRaw = secret.withUnsafeBytes { Data($0) }
        out["handshake"] = [
            "paired": hex(paired), "phoneEphPrivate": hex(phonePriv), "macEphPrivate": hex(macPriv), "phoneEph": hex(phoneEph), "macEph": hex(macEph),
            "id": id, "nonce": hex(nonce), "commitment": hex(RemoteCrypto.commitment(nonce)),
            "phoneHello": try JSONSerialization.jsonObject(with: hello), "macHello": try JSONSerialization.jsonObject(with: reply),
            "macHelloRefused": try JSONSerialization.jsonObject(with: JSONEncoder().encode(MacHello(v: 1, eph: nil, proof: nil, error: "not_paired"))),
            "sharedSecret": hex(sharedRaw), "transcript": hex(t), "proof": hex(RemoteCrypto.proof(paired: paired, transcript: t)),
            "keyToMac": keys.toMac.withUnsafeBytes { hex(Data($0)) }, "keyToPhone": keys.toPhone.withUnsafeBytes { hex(Data($0)) },
            "check": phone.check(nonce),
            "tcpPhoneToMac": [["plain": hex(first), "sealed": hex(f0), "framed": hex(RemoteFrameReader.framed(f0))],
                              ["plain": "0101000200", "sealed": hex(f1)]],
            "tcpMacToPhone": [["plain": hex(backPlain), "sealed": hex(back0)]],
            "udpPhoneToMac": [["session": 7, "counter": 1, "plain": "0203", "sealed": hex(udp1)],
                              ["session": 7, "counter": 2, "plain": hex(Data([2]) + RemotePointerPacket.move(dx: 1, dy: 1).encoded()), "sealed": hex(udp2)]],
        ]
        out["relayRoom"] = ["paired": hex(paired), "room": RemoteRelay.room(key: paired)]
        let pairing = RemotePairing(macID: "host-id-1", deviceID: "device-id-1", key: paired, macName: "Studio PC", port: 50123,
                                    addresses: ["192.168.1.20", "fe80::1"], relay: "wss://relay.example.com")
        out["pairingURL"] = pairing.url.absoluteString
        return out
    }

    func testVectorsMatchTheCommittedFile() throws {
        let built = try build()
        let data = try JSONSerialization.data(withJSONObject: built, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if ProcessInfo.processInfo.environment["BLURT_WRITE_VECTORS"] == "1" {
            try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (data + Data("\n".utf8)).write(to: Self.file)
            return
        }
        let committed = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.file)) as? NSDictionary
        XCTAssertEqual(committed, built as NSDictionary, "the wire format changed: write the vectors again on purpose (see the top of this file)")
    }

    /// Every message in the file decodes back into the same message: the JSON shapes are ones the Swift side reads.
    func testVectorsDecode() throws {
        for (name, m) in toMac() {
            let back = try JSONDecoder().decode(ToMac.self, from: JSONEncoder().encode(m))
            XCTAssertEqual(try json(back) as? NSObject, try json(m) as? NSObject, name)
        }
        // an old phone's request and an old Mac's session have no codecs / platform
        let old = Data(#"{"screen":{"_0":{"target":"display","crop":{"x":0,"y":0,"w":1,"h":1},"width":1,"height":1,"bitrate":1,"fps":1}}}"#.utf8)
        guard case let .screen(r) = try JSONDecoder().decode(ToMac.self, from: old) else { return XCTFail() }
        XCTAssertNil(r?.codecs)
        let s = Data(#"{"session":{"_0":{"macName":"M","udpPort":1,"udpSession":1,"canControl":true,"version":"1","candidates":[],"displayAspect":1.6}}}"#.utf8)
        guard case let .session(i) = try JSONDecoder().decode(ToPhone.self, from: s) else { return XCTFail() }
        XCTAssertEqual(i.host, .mac)
        let v = Data(#"{"screenView":{"width":1,"height":2}}"#.utf8)
        guard case let .screenView(_, _, codec, display) = try JSONDecoder().decode(ToPhone.self, from: v) else { return XCTFail() }
        XCTAssertNil(codec)
        XCTAssertNil(display)
    }
}
