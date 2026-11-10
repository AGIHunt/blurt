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

    // MARK: the pointer's numbers, and a still picture made sharp (1.0.17)

    func testANumberedMoveIsReadByAHostThatKnowsNoNumbers() throws {
        let numbered = RemotePointerPacket.move(dx: 1.5, dy: -2.25, seq: 258).encoded()
        XCTAssertEqual(numbered.count, 13)
        XCTAssertEqual(RemotePointerPacket(numbered), .move(dx: 1.5, dy: -2.25, seq: 258))
        // what a host before 1.0.17 reads: the first nine bytes
        XCTAssertEqual(RemotePointerPacket(numbered.prefix(9)), .move(dx: 1.5, dy: -2.25))
        XCTAssertEqual(RemotePointerPacket.move(dx: 1.5, dy: -2.25).encoded(), numbered.prefix(9))
        let to = try JSONEncoder().encode(ToMac.pointerTo(x: 0.5, y: 0.75))
        XCTAssertFalse(String(decoding: to, as: UTF8.self).contains("seq"))
        guard case let .pointerTo(_, _, none) = try JSONDecoder().decode(ToMac.self, from: to) else { return XCTFail() }
        XCTAssertNil(none)
        let toN = try JSONEncoder().encode(ToMac.pointerTo(x: 0.5, y: 0.75, seq: 7))
        guard case let .pointerTo(x, y, seq) = try JSONDecoder().decode(ToMac.self, from: toN) else { return XCTFail() }
        XCTAssertEqual([x, y], [0.5, 0.75])
        XCTAssertEqual(seq, 7)
    }

    func testTheCursorSaysHowFarTheHostHasGot() {
        let plain = RemoteCursor(x: 0.5, y: 0.25).encoded()
        XCTAssertEqual(plain.count, 8)
        XCTAssertEqual(RemoteCursor(plain), RemoteCursor(x: 0.5, y: 0.25))
        let numbered = RemoteCursor(x: 0.5, y: 0.25, seq: 258).encoded()
        XCTAssertEqual(numbered.count, 12)
        XCTAssertEqual(RemoteCursor(numbered)?.seq, 258)
        XCTAssertNil(RemoteCursor(numbered.prefix(10)))
        XCTAssertTrue(RemoteCursor.covers(5, 5))
        XCTAssertTrue(RemoteCursor.covers(6, 5))
        XCTAssertFalse(RemoteCursor.covers(4, 5))
        XCTAssertTrue(RemoteCursor.covers(2, .max - 1), "counting round")
        XCTAssertFalse(RemoteCursor.covers(.max - 1, 2))
    }

    func testAStillPictureIsSharpenedInStepsThatFitTheRate() {
        var s = RemoteSharpen()
        var now = 0.0, caps: [Int] = [], total = 0
        // a screen of text at 2 Mbps: a step costs more the further it goes (the sizes measured, roughly)
        while !s.done, caps.count < 50 {
            guard let cap = s.next(now: now) else { now += 0.05; continue }
            caps.append(cap)
            XCTAssertNil(s.next(now: now + 0.1), "one at a time")
            let bytes = cap > 34 ? 45_000 : cap > 28 ? 90_000 : 130_000
            total += bytes
            s.sent(cap: cap, bytes: bytes, bitrate: 2_000_000, now: now)
            XCTAssertNil(s.next(now: now + Double(bytes) * 8 / 2_000_000 - 0.01), "not before the last one is through")
        }
        XCTAssertEqual(caps.first, 40)
        XCTAssertEqual(caps.last, RemoteSharpen.sharp, "it ends sharp, however many steps that takes")
        XCTAssertEqual(caps, caps.sorted(by: >), "only ever finer")
        XCTAssertLessThan(caps.count, 12)
        XCTAssertLessThanOrEqual(Double(total) * 8 / 2_000_000, now + 1, "never more than the rate")
        XCTAssertNil(s.next(now: now + 100))
    }

    func testSharpeningTakesBiggerStepsWhenTheyAreCheapAndSmallerWhenTheyAreNot() {
        var cheap = RemoteSharpen(), dear = RemoteSharpen()
        var a: [Int] = [], b: [Int] = [], now = 0.0
        for _ in 0..<30 {
            if let c = cheap.next(now: now) { a.append(c); cheap.sent(cap: c, bytes: 5_000, bitrate: 12_000_000, now: now) }
            if let c = dear.next(now: now) { b.append(c); dear.sent(cap: c, bytes: 80_000, bitrate: 700_000, now: now) }
            now += 1
        }
        XCTAssertEqual(a, [40, 34, 26, 22])
        XCTAssertEqual(b.prefix(4), [40, 38, 37, 36])
        XCTAssertEqual(b.last, 22)
    }

    func testADroppedResendGoesAgainAndAMovingPictureStartsOver() {
        var s = RemoteSharpen()
        XCTAssertEqual(s.next(now: 0), 40)
        XCTAssertNil(s.next(now: 0.1))
        XCTAssertEqual(s.next(now: 0.21), 40, "nothing came back: the same step again")
        s.sent(cap: 40, bytes: 1_000, bitrate: 2_000_000, now: 0.22)
        XCTAssertEqual(s.next(now: 0.4), 34)
        s.again()
        s.sent(cap: 34, bytes: 1_000, bitrate: 2_000_000, now: 0.41)      // a resend of the picture before: says nothing about this one
        XCTAssertEqual(s.next(now: 0.5), 40)
        // an encoder that takes no ceiling: eight plain resends, as before
        var plain = RemoteSharpen()
        var n = 0
        for i in 0..<20 where plain.next(now: Double(i), capped: false) != nil { n += 1 }
        XCTAssertEqual(n, 8)
        XCTAssertTrue(plain.done)
    }

    func testABlinkingCaretDoesntStartTheStepsOver() {
        var s = RemoteSharpen()
        let cap = s.next(now: 0)!
        s.sent(cap: cap, bytes: 20_000, bitrate: 2_000_000, now: 0)
        XCTAssertFalse(s.moved(bytes: 600, bitrate: 2_000_000, fps: 30), "a caret, a spinner: a few hundred bytes")
        XCTAssertEqual(s.next(now: 1), 34, "on from where it was")
        XCTAssertTrue(s.moved(bytes: 9_000, bitrate: 2_000_000, fps: 30), "a scroll's frame: the picture really changed")
        XCTAssertEqual(s.next(now: 2), 40, "from the top")
        // a picture that is sharp stays so under a caret: nothing more is sent for it
        var done = RemoteSharpen()
        var now = 0.0
        while !done.done { if let c = done.next(now: now) { done.sent(cap: c, bytes: 1_000, bitrate: 2_000_000, now: now) }; now += 1 }
        XCTAssertFalse(done.moved(bytes: 1_200, bitrate: 2_000_000, fps: 30))
        XCTAssertNil(done.next(now: now + 10))
        // the share is the rate's: at 12 Mbps and 60 frames, 12.5 KB; never under 3 KB
        var a = RemoteSharpen()
        XCTAssertFalse(a.moved(bytes: 12_000, bitrate: 12_000_000, fps: 60))
        XCTAssertTrue(a.moved(bytes: 13_000, bitrate: 12_000_000, fps: 60))
        XCTAssertFalse(a.moved(bytes: 2_900, bitrate: 300_000, fps: 10))
        XCTAssertTrue(a.moved(bytes: 3_000, bitrate: 300_000, fps: 10))
    }

    // MARK: a rate that fell finds its way back while the screen is still

    func testAStillPicturesResendsFindTheRoomAboveARateThatFell() {
        var r = RemoteRate(bitrate: 8_000_000, fps: 30, away: true)
        XCTAssertEqual(r.bitrate, 4_000_000)
        XCTAssertEqual(r.probe, 6_000_000, "away it starts at half: the first still picture asks for more")
        // the resends went at 5.8 Mbps, all of it arrived, and nothing queued: the network carries that
        XCTAssertTrue(r.update(frames: 6, lost: 0, busy: 0, rtt: 0.05, sent: 2_900_000, delivered: 2_800_000, probed: 5_800_000))
        XCTAssertEqual(r.bitrate, 5_220_000, "nine tenths of how fast they went")
        // resends that went no faster than the rate say nothing new
        var slow = RemoteRate(bitrate: 8_000_000, fps: 30, away: true)
        XCTAssertFalse(slow.update(frames: 6, lost: 0, busy: 0, rtt: 0.05, sent: 2_000_000, delivered: 2_000_000, probed: 4_200_000))
        // nor does a report without them: three calm reports and a used rate, as before
        XCTAssertFalse(slow.update(frames: 6, lost: 0, busy: 0, rtt: 0.05, sent: 3_900_000, delivered: 3_900_000))
        // and what didn't all arrive proves nothing
        var short = RemoteRate(bitrate: 8_000_000, fps: 30, away: true)
        XCTAssertFalse(short.update(frames: 6, lost: 0, busy: 0, rtt: 0.05, sent: 2_900_000, delivered: 2_000_000, probed: 5_800_000))
        // never past the phone's ceiling
        var near = RemoteRate(bitrate: 5_000_000, fps: 30, away: true)
        _ = near.update(frames: 6, lost: 0, busy: 0, rtt: 0.05, sent: 3_000_000, delivered: 3_000_000, probed: 3_750_000)
        _ = near.update(frames: 6, lost: 0, busy: 0, rtt: 0.05, sent: 3_000_000, delivered: 3_000_000, probed: 5_000_000)
        _ = near.update(frames: 6, lost: 0, busy: 0, rtt: 0.05, sent: 3_000_000, delivered: 3_000_000, probed: 9_000_000)
        XCTAssertEqual(near.bitrate, 5_000_000)
        XCTAssertEqual(near.probe, 5_000_000, "at the ceiling there is nothing to ask")
    }

    func testAQuestionTheNetworkAnswersNoToCostsNothingAndIsntAskedAgainSoon() {
        var r = RemoteRate(bitrate: 8_000_000, fps: 30, away: true)
        _ = r.update(frames: 6, lost: 0, busy: 0, rtt: 0.05, sent: 0, delivered: 0)     // the best round trip known
        // the resends went at 6 Mbps and queued: the network has no more than it had
        XCTAssertFalse(r.update(frames: 6, lost: 0, busy: 0, rtt: 0.4, sent: 3_000_000, delivered: 2_100_000, probed: 5_800_000), "no cut for asking")
        XCTAssertEqual(r.bitrate, 4_000_000)
        XCTAssertEqual(r.probe, 4_000_000, "and the next still picture goes at the rate")
        // trouble without a question is still trouble
        var plain = RemoteRate(bitrate: 8_000_000, fps: 30, away: true)
        _ = plain.update(frames: 6, lost: 0, busy: 0, rtt: 0.05, sent: 0, delivered: 0)
        XCTAssertTrue(plain.update(frames: 6, lost: 0, busy: 0, rtt: 0.4, sent: 4_000_000, delivered: 4_000_000))
        XCTAssertLessThan(plain.bitrate, 4_000_000)
        // after a while it may ask again
        for _ in 0..<31 { _ = r.update(frames: 0, lost: 0, busy: 0, rtt: 0.05, sent: 0, delivered: 0) }
        XCTAssertEqual(r.probe, 6_000_000)
    }

    func testResendsSayHowFastTheyReallyWent() {
        var p = RemoteProbe()
        XCTAssertNil(p.take(), "nothing went")
        p.sent(bytes: 50_000, wait: 0.1)
        XCTAssertNil(p.take(), "a tenth of a second says nothing")
        // four resends of 75 KB at 6 Mbps: 0.1 s each
        for _ in 0..<4 { p.sent(bytes: 75_000, wait: 0.1) }
        XCTAssertEqual(p.take(), 6_000_000)
        XCTAssertNil(p.take(), "taken")
        // small ones wait their tenth of a second each: slower than the pace, and it says so
        for _ in 0..<4 { p.sent(bytes: 20_000, wait: 0.1) }
        XCTAssertEqual(p.take(), 1_600_000)
        // the ladder hands it what it needs
        var s = RemoteSharpen()
        let cap = s.next(now: 0)!
        XCTAssertEqual(s.sent(cap: cap, bytes: 150_000, bitrate: 4_000_000, pace: 6_000_000, now: 0), 0.2, accuracy: 0.0001)
        XCTAssertEqual(s.sent(cap: 51, bytes: 150_000, bitrate: 4_000_000, pace: 6_000_000, now: 0), 0, "not this picture's")
    }

    func testOverAnHourOfReadingTheRateSettlesJustUnderWhatTheNetworkCarries() {
        // a network that carries 3 Mbps, a phone that may have 8: a dip to the floor, then only still pictures, one every 20 s, each
        // sharpened by two seconds of resends that really go at nine tenths of their pace. Before, the rate stayed where it fell
        // until something scrolled.
        let carries = 3_000_000
        var r = RemoteRate(bitrate: 8_000_000, fps: 30, away: true)
        _ = r.update(frames: 6, lost: 0, busy: 0, rtt: 0.05, sent: 0, delivered: 0)
        for _ in 0..<12 { _ = r.update(frames: 6, lost: 0, busy: 5, rtt: 0.05, sent: r.bitrate, delivered: 400_000) }
        let fell = r.bitrate
        XCTAssertLessThan(fell, 600_000)
        var lowest = fell, stills = 0, back = 0
        for _ in 0..<180 {
            stills += 1
            for _ in 0..<2 {       // the resends, a report a second
                let pace = r.probe, went = pace * 9 / 10
                let arrives = min(went, carries)
                _ = r.update(frames: 5, lost: 0, busy: 0, rtt: went > carries ? 0.5 : 0.05, sent: went, delivered: arrives, probed: pace > r.bitrate ? went : nil)
                lowest = min(lowest, r.bitrate)
            }
            for _ in 0..<4 { _ = r.update(frames: 0, lost: 0, busy: 0, rtt: 0.05, sent: 0, delivered: 0) }      // still: a report every 5 s
            if back == 0, r.bitrate > carries * 7 / 10 { back = stills }
        }
        XCTAssertEqual(lowest, fell, "asking never costs")
        XCTAssertGreaterThan(r.bitrate, carries * 7 / 10)
        // (the old rule may still step a quarter past it on a rate that's in use; real motion at that rate brings it down, as ever)
        XCTAssertLessThanOrEqual(r.bitrate, carries * 11 / 10)
        XCTAssertLessThan(back, 30, "and it is back within some minutes of reading, not never")
    }
}
