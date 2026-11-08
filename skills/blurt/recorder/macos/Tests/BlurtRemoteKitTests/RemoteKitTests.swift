import Network
import XCTest
@testable import BlurtRemoteKit

final class RemoteKitTests: XCTestCase {
    private func paired() throws -> (RemoteSealer, RemoteSealer) {
        let key = RemoteCrypto.newKey()
        let phone = PhoneHandshake(id: "dev", paired: key)
        let a = MacHandshake.answer(phone.hello()) { $0 == "dev" ? key : nil }
        return (try phone.finish(a.reply), try XCTUnwrap(a.sealer))
    }

    func testHandshakeAndFrames() throws {
        let (p, m) = try paired()
        let f = try p.seal(Data("hello".utf8))
        XCTAssertEqual(try m.open(f), Data("hello".utf8))
        let g = try m.seal(Data("back".utf8))
        XCTAssertEqual(try p.open(g), Data("back".utf8))
    }

    func testBothEndsShowTheSameDigitsAndOnlyThisSessionDoes() throws {
        let key = RemoteCrypto.newKey()
        let phone = PhoneHandshake(id: "dev", paired: key)
        let a = MacHandshake.answer(phone.hello()) { $0 == "dev" ? key : nil }
        let p = try phone.finish(a.reply), m = try XCTUnwrap(a.sealer)
        XCTAssertEqual(p.check(phone.nonce), m.check(phone.nonce))
        XCTAssertEqual(p.check(phone.nonce).count, 6)
        XCTAssertEqual(a.key, key, "the Mac knows which key it used")
        // someone else holding the same code: their own session, other digits (almost always)
        var differ = 0
        for _ in 0..<20 {
            let other = PhoneHandshake(id: "dev", paired: key)
            let b = MacHandshake.answer(other.hello()) { $0 == "dev" ? key : nil }
            if try other.finish(b.reply).check(other.nonce) != p.check(phone.nonce) { differ += 1 }
        }
        XCTAssertGreaterThanOrEqual(differ, 19)
    }

    func testSameKeyComparison() {
        let k = RemoteCrypto.newKey()
        XCTAssertTrue(RemoteCrypto.same(k, k))
        XCTAssertFalse(RemoteCrypto.same(k, RemoteCrypto.newKey()))
        XCTAssertFalse(RemoteCrypto.same(k, k.prefix(16)))
    }

    func testRefusesUnknownDevice() {
        let phone = PhoneHandshake(id: "dev", paired: RemoteCrypto.newKey())
        let a = MacHandshake.answer(phone.hello()) { _ in nil }
        XCTAssertNil(a.sealer)
        XCTAssertThrowsError(try phone.finish(a.reply)) { XCTAssertEqual($0 as? RemoteHandshakeError, RemoteHandshakeError(.notPaired)) }
    }

    func testAMacWithoutTheKeyCannotPretend() {
        let phone = PhoneHandshake(id: "dev", paired: RemoteCrypto.newKey())
        let a = MacHandshake.answer(phone.hello()) { _ in RemoteCrypto.newKey() }
        XCTAssertThrowsError(try phone.finish(a.reply)) { XCTAssertEqual($0 as? RemoteHandshakeError, RemoteHandshakeError(.badProof)) }
    }

    func testAPhoneWithoutTheKeyCannotSeal() throws {
        let phone = PhoneHandshake(id: "dev", paired: RemoteCrypto.newKey())
        let macKey = RemoteCrypto.newKey()
        let a = MacHandshake.answer(phone.hello()) { _ in macKey }
        // the phone can't finish, so forge a frame under an unrelated key
        let forged = PhoneHandshake(id: "x", paired: macKey)
        let b = MacHandshake.answer(forged.hello()) { _ in macKey }
        let other = try forged.finish(b.reply)
        XCTAssertThrowsError(try XCTUnwrap(a.sealer).open(try other.seal(Data("k".utf8))))
    }

    func testTamperedAndReorderedFramesFail() throws {
        let (p, m) = try paired()
        var f = try p.seal(Data("one".utf8))
        f[0] ^= 1
        XCTAssertThrowsError(try m.open(f))
        let (p2, m2) = try paired()
        let a = try p2.seal(Data("a".utf8)), b = try p2.seal(Data("b".utf8))
        XCTAssertThrowsError(try m2.open(b))
        XCTAssertEqual(try m2.open(a), Data("a".utf8))
    }

    func testPacketsDropReplaysAndVeryLateOnes() throws {
        let (p, m) = try paired()
        let a = try p.sealPacket(Data("1".utf8), session: 7), b = try p.sealPacket(Data("2".utf8), session: 7)
        XCTAssertEqual(RemoteSealer.sessionOfPacket(a), 7)
        XCTAssertEqual(m.openPacket(b), Data("2".utf8))
        XCTAssertEqual(m.openPacket(a), Data("1".utf8), "a little out of order is fine")
        XCTAssertNil(m.openPacket(a), "replay")
        XCTAssertNil(m.openPacket(b), "replay")
        let late = try p.sealPacket(Data("3".utf8), session: 7)
        var last = Data()
        for _ in 0..<70 { last = try p.sealPacket(Data("x".utf8), session: 7) }
        XCTAssertNotNil(m.openPacket(last))
        XCTAssertNil(m.openPacket(late), "too old")
    }

    func testFrameReaderSplitsAndJoins() throws {
        var r = RemoteFrameReader()
        let w = RemoteFrameReader.framed(Data("abc".utf8)) + RemoteFrameReader.framed(Data("de".utf8))
        r.feed(w.prefix(5))
        XCTAssertNil(try r.next())
        r.feed(w.dropFirst(5))
        XCTAssertEqual(try r.next(), Data("abc".utf8))
        XCTAssertEqual(try r.next(), Data("de".utf8))
        XCTAssertNil(try r.next())
    }

    func testFrameLimits() {
        for head in [[0xFF, 0xFF, 0xFF, 0xFF], [0, 0, 0, 0], [0, 0, 0x04, 0x01]] as [[UInt8]] {
            var r = RemoteFrameReader()
            r.feed(Data(head))
            XCTAssertThrowsError(try r.next(), "\(head)")
        }
        var open = RemoteFrameReader()
        open.limit = RemoteFrameReader.maxFrame
        open.feed(Data([0, 0, 0x04, 0x01]))
        XCTAssertNil(try open.next(), "after the handshake, a longer frame is fine")
    }

    func testPointerPackets() {
        for p: RemotePointerPacket in [.move(dx: 1.5, dy: -2), .scroll(dx: 0, dy: 12.25, phase: .changed), .scrollFling(vx: 300, vy: -9), .scrollStop] {
            XCTAssertEqual(RemotePointerPacket(p.encoded()), p)
        }
        XCTAssertNil(RemotePointerPacket(Data()))
        XCTAssertNil(RemotePointerPacket(Data([0, 1])))
        XCTAssertNil(RemotePointerPacket(Data([0, 0, 0, 0xC0, 0x7F, 0, 0, 0, 0])), "NaN is not a move")
        XCTAssertNil(RemotePointerPacket(RemotePointerPacket.move(dx: 1e30, dy: 0).encoded()), "nor is a number that overflows Int32")
    }

    func testPairingLink() throws {
        let p = RemotePairing(macID: "m", deviceID: "d", key: RemoteCrypto.newKey(), macName: "John’s MacBook Pro", port: 51234, addresses: ["192.168.1.5", "fe80::1%en0"])
        XCTAssertEqual(RemotePairing(url: p.url), p)
        XCTAssertNil(RemotePairing(url: URL(string: "blurtremote://pair?v=1&mac=m")!))
        XCTAssertNil(RemotePairing(url: URL(string: "https://example.com/pair")!))
    }

    func testPointerCurve() {
        let c = RemotePointerCurve()
        XCTAssertEqual(c.gain(speed: 10), c.slowGain)
        XCTAssertEqual(c.gain(speed: 5000), c.fastGain)
        XCTAssertLessThan(c.gain(speed: 200), c.gain(speed: 500))
        var s = RemoteSubpixel()
        var total = 0
        for _ in 0..<10 { total += s.whole(0.3, 0).0 }
        XCTAssertEqual(total, 3)
    }

    func testVideoPacketsRoundTrip() {
        let d = Data((0..<3000).map { UInt8($0 % 251) })
        let parts = RemoteVideoPacket.split(d, frame: 7, keyframe: true, captured: 12.5)
        XCTAssertEqual(parts.count, 3)
        XCTAssertLessThanOrEqual(parts[0].encoded().count, 1200)
        XCTAssertEqual(RemoteVideoPacket(parts[1].encoded()), parts[1])
        var a = RemoteVideoAssembler()
        var got: RemoteVideoAssembler.Frame?
        for p in parts.reversed() { got = a.add(p) ?? got }     // any order within a frame
        XCTAssertEqual(got?.data, d)
        XCTAssertEqual(got?.captured, 12.5)
    }

    func testALostPieceWaitsForTheNextKeyframe() {
        var a = RemoteVideoAssembler()
        let one = Data([1]), two = Data(repeating: 2, count: 2000), three = Data([3])
        XCTAssertNil(a.add(RemoteVideoPacket.split(one, frame: 1, keyframe: false, captured: 0)[0]), "nothing before the first keyframe")
        XCTAssertTrue(a.waitingForKey)
        XCTAssertEqual(a.add(RemoteVideoPacket.split(one, frame: 2, keyframe: true, captured: 0)[0])?.id, 2)
        XCTAssertFalse(a.waitingForKey)
        _ = a.add(RemoteVideoPacket.split(two, frame: 3, keyframe: false, captured: 0)[0])      // its second piece never comes
        XCTAssertNil(a.add(RemoteVideoPacket.split(three, frame: 4, keyframe: false, captured: 0)[0]))
        XCTAssertTrue(a.waitingForKey)
        XCTAssertEqual(a.dropped, 1, "one frame, however many ways it shows")
        XCTAssertNil(a.add(RemoteVideoPacket.split(three, frame: 5, keyframe: false, captured: 0)[0]))
        XCTAssertEqual(a.add(RemoteVideoPacket.split(three, frame: 6, keyframe: true, captured: 0)[0])?.id, 6)
        XCTAssertNil(a.add(RemoteVideoPacket.split(three, frame: 4, keyframe: false, captured: 0)[0]), "late")
    }

    func testPayloadPacking() {
        let c = RemoteCrop(x: 0.25, y: 0.5, w: 0.5, h: 0.25)
        let p = RemoteVideoPayload.pack(crop: c, parameterSets: [Data([1, 2]), Data([3])], picture: Data([9, 9]))
        let u = RemoteVideoPayload.unpack(p)
        XCTAssertEqual(u?.crop, c)
        XCTAssertEqual(u?.parameterSets, [Data([1, 2]), Data([3])])
        XCTAssertEqual(u?.picture, Data([9, 9]))
        XCTAssertNil(RemoteVideoPayload.unpack(Data([1, 0, 9])))
        XCTAssertNil(RemoteVideoPayload.unpack(Data(repeating: 0, count: 16) + Data([1, 0, 9])), "a set longer than what's left")
    }

    func testACropIsAlwaysInsideTheSource() {
        XCTAssertEqual(RemoteCrop(x: .nan, y: 0, w: 1, h: 1).valid, .whole)
        XCTAssertEqual(RemoteCrop(x: 0.9, y: -1, w: 0.5, h: 3).valid, RemoteCrop(x: 0.5, y: 0, w: 0.5, h: 1))
        XCTAssertEqual(RemoteCrop(x: 0, y: 0, w: 0, h: 0).valid.w, 0.1)
        XCTAssertEqual(RemoteCrop.centered(zoom: 2), RemoteCrop(x: 0.25, y: 0.25, w: 0.5, h: 0.5))
    }

    func testRelayAddresses() {
        XCTAssertEqual(RemoteRelay.address("relay.example.com"), "wss://relay.example.com")
        XCTAssertEqual(RemoteRelay.address(" wss://relay.example.com/ \n"), "wss://relay.example.com")
        XCTAssertEqual(RemoteRelay.address("ws://1.2.3.4:8787"), "ws://1.2.3.4:8787")
        XCTAssertEqual(RemoteRelay.address("wss://example.com/relay"), "wss://example.com/relay", "a relay behind a path")
        for bad in ["", "   ", "https://example.com", "ftp://x", "wss://", "wss://a.b?x=1"] { XCTAssertNil(RemoteRelay.address(bad), bad) }
        XCTAssertNotNil(RemoteRelay.connection(address: "ws://1.2.3.4:8787", room: "r", role: "mac"))
    }

    func testSessionInfoCarriesTheRelay() throws {
        let i = RemoteSessionInfo(macName: "m", udpPort: 1, udpSession: 2, canControl: true, version: "1", relay: "wss://r.example.com")
        let d = try JSONDecoder().decode(RemoteSessionInfo.self, from: JSONEncoder().encode(i))
        XCTAssertEqual(d.relay, "wss://r.example.com")
    }

    func testRelayRoomComesFromTheKey() {
        let k = RemoteCrypto.newKey()
        XCTAssertEqual(RemoteRelay.room(key: k), RemoteRelay.room(key: k))
        XCTAssertNotEqual(RemoteRelay.room(key: k), RemoteRelay.room(key: RemoteCrypto.newKey()))
        XCTAssertEqual(RemoteRelay.room(key: k).count, 43, "the relay accepts exactly this shape")
    }

    func testMessagesRoundTrip() throws {
        let m = ToMac.run([.key(RemoteChord(.command, "V")), .wait(40), .text("好")])
        let d = try JSONEncoder().encode(m)
        guard case let .run(steps) = try JSONDecoder().decode(ToMac.self, from: d) else { return XCTFail() }
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(RemoteChord([.command, .shift], "Tab").label, "⇧⌘⇥")
    }

    /// Both ends over loopback: a real listener, the handshake, control, audio, the pointer in the TCP stream.
    func testSessionOverLoopback() throws {
        let key = RemoteCrypto.newKey()
        let listener = try NWListener(using: .tcp, on: .any)
        let q = DispatchQueue(label: "t")
        let ready = expectation(description: "listening")
        var mac: RemoteChannel?
        let got = expectation(description: "control")
        let audio = expectation(description: "audio")
        let pointer = expectation(description: "pointer")
        let back = expectation(description: "back")
        listener.newConnectionHandler = { c in
            let ch = RemoteChannel(connection: c, role: .mac(lookup: { $0 == "dev" ? key : nil }))
            ch.onControl = { d in
                if case .text("hi")? = try? JSONDecoder().decode(ToMac.self, from: d) { got.fulfill(); ch.send(ToPhone.udpOK) }
            }
            ch.onAudio = { if $0 == Data([1, 2]) { audio.fulfill() } }
            ch.onPointer = { if $0 == .move(dx: 1, dy: 2) { pointer.fulfill() } }
            mac = ch
            ch.start()
        }
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: q)
        wait(for: [ready], timeout: 3)
        let c = NWConnection(host: "127.0.0.1", port: listener.port!, using: .tcp)
        let phone = RemoteChannel(connection: c, role: .phone(PhoneHandshake(id: "dev", paired: key)))
        phone.onOpen = { _ in
            phone.send(ToMac.text("hi"))
            phone.sendAudio(Data([1, 2]))
            phone.sendPointer(.move(dx: 1, dy: 2))
        }
        phone.onControl = { d in
            if case .udpOK? = try? JSONDecoder().decode(ToPhone.self, from: d) { back.fulfill() }
        }
        phone.start()
        wait(for: [got, audio, pointer, back], timeout: 5)
        phone.close(); mac?.close(); listener.cancel()
    }
}
