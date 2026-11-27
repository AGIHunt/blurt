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
            // a phone that can move its stream onto the direct path (docs/design/remote-go-between.md)
            ("hello_move", .hello(device: "Pixel 9", micOnPhone: true, nonce: bytes(9), features: ["move"])),
            ("stream_moved", .streamMoved),
            ("set_mic_on_phone", .setMicOnPhone(false)),
            ("release_all", .releaseAll),
            ("key_stored", .keyStored),
            ("screen", .screen(RemoteScreenRequest(target: "display", crop: crop, width: 1600, height: 1000, bitrate: 4_000_000, fps: 30, codecs: ["h264"]))),
            ("screen_old_phone", .screen(RemoteScreenRequest(target: "display", width: 1280, height: 800, bitrate: 1_000_000, fps: 15, codecs: nil))),
            ("screen_off", .screen(nil)),
            ("screen_pinned_display", .screen(RemoteScreenRequest(target: "display", width: 1600, height: 900, bitrate: 4_000_000, fps: 30, codecs: ["h264"], display: "69733382"))),
            ("screen_repairs", .screen(RemoteScreenRequest(target: "display", width: 2622, height: 1206, bitrate: 12_000_000, fps: 120, codecs: ["hevc", "h264"],
                                                           features: ["nack", "ltr", "fec"]))),
            ("show_display", .showDisplay("69733382")),
            ("show_display_follow", .showDisplay(nil)),
            ("screen_crop", .screenCrop(crop)),
            ("pointer_to", .pointerTo(x: 0.5, y: 0.75)),
            ("pointer_to_seq", .pointerTo(x: 0.5, y: 0.75, seq: 7)),
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
            // a computer driving another (docs/design/remote-desktop-viewer.md)
            ("hello_viewer", .hello(device: "MacBook Pro", micOnPhone: false, nonce: bytes(9), features: ["move", "viewer"])),
            // another window of a viewer that has a session: the host keeps the first beside it
            ("hello_viewer_window", .hello(device: "MacBook Pro", micOnPhone: false, nonce: bytes(9), features: ["move", "viewer", "window"])),
            ("screen_viewer", .screen(RemoteScreenRequest(target: "display", width: 2560, height: 1600, bitrate: 12_000_000, fps: 60, codecs: ["hevc", "h264"],
                                                          display: "69733382", features: ["nack", "ltr", "fec"], window: RemotePixelSize(width: 2400, height: 1350)))),
            ("clipboard", .clipboard("复制 copied\n")),
            ("keys_captured", .keysCaptured(true)),
            ("keys_released", .keysCaptured(false)),
            ("privacy_on", .privacyScreen(true)),
            ("file_begin", .fileBegin(id: "f1", name: "notes.txt", size: 5)),
            ("file_chunk", .fileChunk(id: "f1", data: Data("hello".utf8))),
            ("file_end", .fileEnd(id: "f1")),
            // clipboard and files both ways (docs/design/remote-files.md)
            ("file_begin_batch", .fileBegin(id: "f2", name: "照片 1.heic", size: 2_400_000, index: 1, count: 3, total: 7_000_000)),
            ("file_begin_clip", .fileBegin(id: "f3", name: "Image.png", size: 52_000, clip: true)),
            ("get_clipboard", .getClipboard),
            ("file_progress_back", .fileProgress(id: "h1", bytes: 1_048_576)),
            ("file_saved_back", .fileSaved(id: "h1", name: "report 2.pdf")),
            ("file_failed_back", .fileFailed(id: "h1", why: "stopped")),
            ("key_f13_down", .key(RemoteChord([], "F13"), down: true)),
            ("key_keypad_enter", .key(RemoteChord([], "KeypadEnter"), down: nil)),
        ]
    }

    private func toPhone() -> [(String, ToPhone)] {
        [
            ("session", .session(RemoteSessionInfo(macName: "Studio PC", udpPort: 50123, udpSession: 7, canControl: true, version: "1.0.15",
                                                   candidates: [RemoteCandidate(host: "192.168.1.20", port: 50123)], displayAspect: 1.5,
                                                   relay: "wss://relay.example.com", platform: "windows"))),
            ("session_go_between", .session(RemoteSessionInfo(macName: "Studio PC", udpPort: 50123, udpSession: 7, canControl: true, version: "1.0.27",
                                                              candidates: [RemoteCandidate(host: "192.168.1.20", port: 50123), RemoteCandidate(host: "100.101.102.103", port: 50123),
                                                                           RemoteCandidate(host: "fd7a:115c:a1e0::1", port: 50123)],
                                                              displayAspect: 1.5, relay: "wss://meet.blurt.work", platform: "windows", features: ["move"]))),
            ("stream_moved", .streamMoved),
            ("no_direct", .noDirect),
            ("public_relay", .publicRelay(address: "wss://relay.blurt.work", room: "guZRlWLF0yQX0I21ZnxtHFAtfVV5pDTmSepPGKS3c8w",
                                          ticket: "1764000060.vSDxp8K1xSfY.Zd8TTbFbCLl3pNcSNSWE0A")),
            ("screen_failed_busy", .screenFailed(RemotePublicRelay.busy)),
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
            ("screen_view_repairs", .screenView(width: 1512, height: 982, codec: "hevc", display: "1", features: ["nack", "ltr"])),
            ("legends", .legends(RemoteLegends(source: "German", keys: ["Y": .init(base: "z", shift: "Z"), "Q": .init(base: "q", shift: "Q", altGr: "@"),
                                                                          "-": .init(base: "ß", shift: "?", altGr: "\\")]))),
            ("displays", .displays([RemoteDisplay(id: "1", name: "Built-in Retina Display", x: 0, y: 0, width: 1512, height: 982, main: true),
                                    RemoteDisplay(id: "69733382", name: "DELL U2723QE", x: 1512, y: -458, width: 2560, height: 1440, main: false)])),
            ("cursor_shape", .cursorShape(png: Data([0x89, 0x50]), hotX: 1, hotY: 2, width: 16, height: 24)),
            ("session_viewer", .session(RemoteSessionInfo(macName: "Studio", udpPort: 50123, udpSession: 7, canControl: true, version: "1.0.27",
                                                          candidates: [RemoteCandidate(host: "192.168.1.20", port: 50123)], displayAspect: 1.6,
                                                          platform: "mac", features: ["move", "viewer"]))),
            ("clipboard", .clipboard("host text")),
            ("screen_locked", .screenLocked(true)),
            ("ended", .ended),
            ("file_progress", .fileProgress(id: "f1", bytes: 5)),
            ("file_saved", .fileSaved(id: "f1", name: "notes.txt")),
            ("file_failed", .fileFailed(id: "f1", why: "space")),
            ("file_begin_back", .fileBegin(id: "h1", name: "report.pdf", size: 5, index: 2, count: 2, total: 9)),
            ("file_begin_back_clip", .fileBegin(id: "h2", name: "Text.txt", size: 70_000, clip: true)),
            ("file_chunk_back", .fileChunk(id: "h1", data: Data("hello".utf8))),
            ("file_end_back", .fileEnd(id: "h1")),
            ("clipboard_none", .clipboardNone(why: "empty")),
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
            // numbered (1.0.17+): four more bytes, which a host before that reads past
            ("move_seq", .move(dx: 1.5, dy: -2.25, seq: 258)),
        ]
        out["pointer"] = pointers.map { ["name": $0.0, "hex": hex($0.1.encoded())] }

        let crop = RemoteCrop(x: 0.25, y: 0.125, w: 0.5, h: 0.5)
        let payload = RemoteVideoPayload.pack(crop: crop, parameterSets: [Data([0x40, 0x01]), Data([0x42, 0x01, 0x02])], picture: Data([0, 0, 0, 1, 0x26, 0x01]))
        let pieces = RemoteVideoPacket.split(payload, frame: 42, keyframe: true, captured: 1234.5, payload: 16)
        out["video"] = [
            "payload": ["crop": try json(crop), "parameterSets": ["4001", "420102"], "picture": "000000012601", "hex": hex(payload)],
            "packets": ["frame": 42, "keyframe": true, "captured": 1234.5, "pieceSize": 16, "hex": pieces.map { hex($0.encoded()) }],
        ]
        // the repairs (docs/design/remote-realtime.md): flags beyond the keyframe bit, parity pieces, the phone's feedback
        let small = Data((0..<40).map { UInt8($0) })
        let refresh = RemoteVideoPacket.split(small, frame: 43, keyframe: false, refresh: true, ackRequested: true, captured: 1234.75, payload: 16)
        let feedback: [(String, RemoteVideoFeedback)] = [("nack", .nack([.init(frame: 43, pieces: [1, 2]), .init(frame: 44, pieces: [])])),
                                                          ("ack", .ack(newest: 43, earlier: 5)), ("lost", .lost(after: 42))]
        out["videoRepair"] = [
            "refresh": ["frame": 43, "keyframe": false, "refresh": true, "ackRequested": true, "captured": 1234.75, "pieceSize": 16,
                        "data": hex(small), "hex": refresh.map { hex($0.encoded()) }],
            "parity": ["group": 2, "hex": RemoteVideoFEC.parity(for: refresh, group: 2).map { hex($0.encoded()) }],
            "feedback": feedback.map { ["name": $0.0, "hex": hex($0.1.encoded())] },
        ]
        var cursor = Data()
        for v: Float in [0.5, 0.25] { withUnsafeBytes(of: v.bitPattern.littleEndian) { cursor.append(contentsOf: $0) } }
        out["cursor"] = ["x": 0.5, "y": 0.25, "hex": hex(cursor)]
        // to a phone that numbers its pointer instructions: the newest one this place includes
        out["cursorSeq"] = ["x": 0.5, "y": 0.25, "seq": 258, "hex": hex(RemoteCursor(x: 0.5, y: 0.25, seq: 258).encoded())]

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
        // The move (docs/design/remote-go-between.md): `streamMoved` is the phone's last frame on the old stream (channel 0, counter 2 after
        // the two frames above); its next frame, sealed with counter 3 as it would have been on the old stream, is the UDP stream's first
        // bytes, at offset 0, in a kind-7 datagram sealed on channel 1 (counter 3 after the two packets above). The host acks with kind 8.
        let movedPlain = Data([RemoteFrameKind.control.rawValue]) + (try sorted.encode(ToMac.streamMoved))
        let moved = try phone.seal(movedPlain)
        let afterPlain = Data([RemoteFrameKind.control.rawValue]) + (try sorted.encode(ToMac.key(RemoteChord(.command, "C"), down: nil)))
        let after = RemoteFrameReader.framed(try phone.seal(afterPlain))
        let streamBody = RemoteStreamPacket.data(offset: 0, bytes: after).encoded()
        let streamPacket = try phone.sealPacket(Data([RemoteFrameKind.stream.rawValue]) + streamBody, session: 7)
        let ackBody = RemoteStreamPacket.ack(next: UInt64(after.count)).encoded()
        let ackPacket = try mac.sealPacket(Data([RemoteFrameKind.streamAck.rawValue]) + ackBody, session: 7)
        out["stream"] = [
            "about": "kind 7: u64 BE offset ∥ at most 1100 bytes of the sender's stream (length-prefixed channel-0 frames, counters continuing). Sealed with handshake's keys.",
            "streamMoved": ["counter": 2, "plain": hex(movedPlain), "sealed": hex(moved), "framed": hex(RemoteFrameReader.framed(moved))],
            "frame": ["counter": 3, "plain": hex(afterPlain), "framed": hex(after)],
            "packet": ["offset": 0, "body": hex(streamBody), "plain": hex(Data([RemoteFrameKind.stream.rawValue]) + streamBody),
                       "session": 7, "udpCounter": 3, "sealed": hex(streamPacket)],
            "examples": [["offset": 0, "bytes": "", "body": hex(RemoteStreamPacket.data(offset: 0, bytes: Data()).encoded())],
                         ["offset": 1100, "bytes": "0102", "body": hex(RemoteStreamPacket.data(offset: 1100, bytes: Data([1, 2])).encoded())],
                         ["offset": 0x0102030405060708, "bytes": "ff", "body": hex(RemoteStreamPacket.data(offset: 0x0102030405060708, bytes: Data([0xff])).encoded())]],
        ]
        out["streamAck"] = [
            "about": "kind 8: u64 BE next expected offset, cumulative. Host to phone, sealed on channel 1 (the host's first packet: counter 1).",
            "packet": ["next": after.count, "body": hex(ackBody), "plain": hex(Data([RemoteFrameKind.streamAck.rawValue]) + ackBody),
                       "session": 7, "udpCounter": 1, "sealed": hex(ackPacket)],
            "examples": [["next": 0, "body": hex(RemoteStreamPacket.ack(next: 0).encoded())],
                         ["next": 262144, "body": hex(RemoteStreamPacket.ack(next: 262144).encoded())]],
        ]
        out["goBetween"] = ["address": RemoteRelay.goBetween, "overBudgetClose": Int(RemoteRelay.overBudget), "feature": RemoteFeature.move,
                            "chunk": RemoteStream.chunk, "window": RemoteStream.window]
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
        // a computer driving another (docs/design/remote-desktop-viewer.md): its feature name, the clipboard's limit, every key name a host
        // must know (a phone's deck and a full keyboard's) with the Mac's key code for it, the modifier swap, and nearby pairing's id and key
        out["viewer"] = [
            "feature": RemoteFeature.viewer, "windowFeature": RemoteFeature.window, "clipboardMaxBytes": RemoteClipboard.maxBytes,
            "keys": RemoteKey.all.map { ["name": $0.name, "macCode": Int($0.code)] },
            "modifierMap": [["viewer": "mac", "host": "windows", "pressed": Int(RemoteModifiers([.command]).rawValue),
                             "sent": Int(RemoteViewerKeys.map([.command], from: .mac, to: .windows, mapping: true).rawValue)],
                            ["viewer": "mac", "host": "linux", "pressed": Int(RemoteModifiers([.control, .shift]).rawValue),
                             "sent": Int(RemoteViewerKeys.map([.control, .shift], from: .mac, to: .linux, mapping: true).rawValue)],
                            ["viewer": "windows", "host": "mac", "pressed": Int(RemoteModifiers([.control, .option]).rawValue),
                             "sent": Int(RemoteViewerKeys.map([.control, .option], from: .windows, to: .mac, mapping: true).rawValue)],
                            ["viewer": "linux", "host": "windows", "pressed": Int(RemoteModifiers([.control]).rawValue),
                             "sent": Int(RemoteViewerKeys.map([.control], from: .linux, to: .windows, mapping: true).rawValue)]],
            "nearby": ["idPrefix": RemoteNearby.idPrefix, "key": hex(RemoteNearby.key), "seed": "blurt-remote-nearby-1"],
        ]
        // clipboard and files (docs/design/remote-files.md): feature names and every limit an implementation must share
        out["files"] = [
            "features": ["files": RemoteFeature.files, "resume": RemoteFeature.resume, "clipboard": RemoteFeature.clipboard],
            "chunk": RemoteFiles.chunk, "window": RemoteFiles.window, "progressEvery": RemoteFiles.progressEvery, "oldProgressEvery": RemoteFiles.oldProgressEvery,
            "minWindow": RemoteFiles.minWindow, "windowMilliseconds": Int(RemoteFiles.windowSeconds * 1000),
            "windowFor": [[0, 0], [100_000, RemoteFiles.window(rate: 100_000, resumes: true)], [1_500_000, RemoteFiles.window(rate: 1_500_000, resumes: true)],
                          [50_000_000, RemoteFiles.window(rate: 50_000_000, resumes: true)]].map { ["rate": $0[0], "window": $0[0] == 0 ? RemoteFiles.minWindow : $0[1]] },
            "maxSize": RemoteFiles.maxSize,
            "maxCount": RemoteFiles.maxCount, "maxClipImage": RemoteFiles.maxClipImage, "keepPartsSeconds": Int(RemoteFiles.keepParts),
            "resumeWaitSeconds": Int(RemoteFiles.resumeWait), "askOnCellular": RemoteFiles.askOnCellular,
            "clean": [["in": "../secret/.bashrc", "out": "bashrc"], ["in": "a:b.txt", "out": "a-b.txt"], ["in": "C:\\Users\\me\\报告.pdf", "out": "报告.pdf"],
                      ["in": "   ", "out": "file"], ["in": "tab\there.txt", "out": "tabhere.txt"]].map { c in
                          ["in": c["in"]!, "out": RemoteFiles.clean(c["in"]!)]
                      },
        ]
        // while joining, newKey only after pairingWaits and this side's yes to the same digits (security review F1)
        // Blurt's public relay (docs/design/remote-go-between.md §The public relay): features, addresses, limits, the text messages to the
        // relay and the go-between (never sealed, never passed on), and the opus frame kind
        out["publicRelay"] = [
            "features": ["publicRelay": RemoteFeature.publicRelay, "opus": RemoteFeature.opus], "addresses": RemotePublicRelay.addresses,
            "opusKind": Int(RemoteFrameKind.opus.rawValue), "giveUpSeconds": RemotePublicRelay.giveUp, "ticketWaitSeconds": RemotePublicRelay.ticketWait,
            "picture": ["maxWidth": RemotePublicRelay.maxWidth, "maxBitrate": RemotePublicRelay.maxBitrate, "maxFPS": RemotePublicRelay.maxFPS],
            "renewSeconds": RemotePublicRelay.renewEvery, "askAgainSeconds": RemotePublicRelay.askAgain, "untouchedSeconds": RemotePublicRelay.untouched,
            "filesPerDay": RemotePublicRelay.filesPerDay, "askOver": RemotePublicRelay.askOver, "nobodyCame": Int(RemotePublicRelay.nobodyCame),
            "busy": RemotePublicRelay.busy,
            "leaseAsk": RemotePublicRelay.lease(true), "leaseFree": RemotePublicRelay.lease(false),
            "leaseAnswers": [#"{"lease":{"ok":true,"ttl":75}}"#, #"{"lease":{"ok":false,"why":"full"}}"#, #"{"lease":{"ok":false,"why":"prefix"}}"#,
                             #"{"lease":{"ok":false,"why":"expired"}}"#],
            "ticketAsk": RemotePublicRelay.ticketAsk(room: "guZRlWLF0yQX0I21ZnxtHFAtfVV5pDTmSepPGKS3c8w"),
            "ticketAnswer": #"{"ticket":{"relay":"wss://relay.blurt.work","room":"guZRlWLF0yQX0I21ZnxtHFAtfVV5pDTmSepPGKS3c8w","mac":"1764000060.vSDxp8K1xSfY.WAcrp_CCMxTDXy-t3YDNzQ","phone":"1764000060.vSDxp8K1xSfY.Zd8TTbFbCLl3pNcSNSWE0A"}}"#,
            "ticketRefused": [#"{"ticket":{"error":"off"}}"#, #"{"ticket":{"error":"alone"}}"#, #"{"ticket":{"error":"limit"}}"#, #"{"ticket":{"error":"bad"}}"#],
        ]
        out["joinGate"] = [
            "about": "While joining, the joining side stores newKey only after pairingWaits and its own user's yes to the same digits (same), in either order of yes and key. A key before pairingWaits is dropped, not held; reconnect starts over. stores: the index of the event at which the key is stored, or null.",
            "cases": RemoteJoinGate.cases.map { c -> [String: Any] in
                ["events": c.map(\.rawValue), "stores": RemoteJoinGate.run(c).map { $0 as Any } ?? NSNull()]
            },
        ]
        let pairing = RemotePairing(macID: "host-id-1", deviceID: "device-id-1", key: paired, macName: "Studio PC", port: 50123,
                                    addresses: ["192.168.1.20", "fe80::1"], relay: "wss://relay.example.com")
        out["pairingURL"] = pairing.url.absoluteString
        let l = pairing.url.absoluteString
        let near = RemotePairing(macID: "host-id-1", deviceID: "device-id-2", key: paired, macName: "Studio PC", port: 50123,
                                 addresses: ["192.168.1.20"]).url.absoluteString
        let texts: [String] = [
            l, "  \(l)\n", "Pair with my PC: \(l) (works for 10 minutes)", "配对链接：\(l)。", "\(l).", "(\(l))", "<\(l)>", "[Pair](\(l))",
            "Blurtremote" + l.dropFirst("blurtremote".count), "\(near).", "\(near)\nsent from my phone",
            String(l.prefix(80)), "https://blurt.work/pair", "blurtremote://pair?v=1&mac=host-id-1", "", "copy the link from Add Device",
        ]
        out["pairingText"] = [
            "about": "Pasted text that holds a pairing link: the link alone, or inside a message (words, brackets, a full stop, a capitalised scheme). link: the link it holds, written back, or null when it holds no whole one.",
            "cases": texts.map { t -> [String: Any] in ["text": t, "link": RemotePairing(text: t).map { $0.url.absoluteString as Any } ?? NSNull()] },
        ]
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
        guard case let .screenView(_, _, codec, display, _) = try JSONDecoder().decode(ToPhone.self, from: v) else { return XCTFail() }
        XCTAssertNil(codec)
        XCTAssertNil(display)
        // an old phone's hello and an old host's session have no features
        let h = Data(#"{"hello":{"device":"iPhone","micOnPhone":true}}"#.utf8)
        guard case let .hello(_, _, _, features) = try JSONDecoder().decode(ToMac.self, from: h) else { return XCTFail() }
        XCTAssertNil(features)
        XCTAssertNil(i.features)
        // the move's frames open in order on the other end: the stream continues the old one's counters
        XCTAssertEqual(try JSONDecoder().decode(ToPhone.self, from: Data(#"{"noDirect":{}}"#.utf8)).isNoDirect, true)
    }

    /// What types a character is never shown on the computer's screen: a password goes by one key after another.
    func testWhatTypesACharacter() {
        for c in [RemoteChord([], "A"), RemoteChord(.shift, "1"), RemoteChord(.option, "E"), RemoteChord([.shift, .option], "/"), RemoteChord([], "Space"), RemoteChord([], "Keypad5")] {
            XCTAssertTrue(c.types, c.label)
        }
        for c in [RemoteChord(.command, "C"), RemoteChord(.control, "C"), RemoteChord([], "Return"), RemoteChord([], "F5"), RemoteChord(.shift, "Tab"), RemoteChord(.shift, "")] {
            XCTAssertFalse(c.types, c.label)
        }
    }
}

private extension ToPhone {
    var isNoDirect: Bool { if case .noDirect = self { true } else { false } }
}
