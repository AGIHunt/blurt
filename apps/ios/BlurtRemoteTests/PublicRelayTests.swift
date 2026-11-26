// Blurt's public relay on the phone (Net/Link.swift; docs/design/remote-go-between.md §The public relay): what the hello lists, where
// `publicRelay` may send it and for how long, how the voice goes there, and the picture's ceiling.
import BlurtRemoteKit
import XCTest
@testable import BlurtRemote

final class PublicRelayTests: XCTestCase {
    private let room = "guZRlWLF0yQX0I21ZnxtHFAtfVV5pDTmSepPGKS3c8w"
    private let ticket = "1764000060.vSDxp8K1xSfY.Zd8TTbFbCLl3pNcSNSWE0A"

    func testTheHelloListsThePublicRelayAndOpusWhenThisPhoneCanMakeIt() {
        let f = Link.features
        XCTAssertTrue(f.contains(RemoteFeature.publicRelay))
        XCTAssertEqual(f.contains(RemoteFeature.opus), RemoteOpus.available)
        XCTAssertTrue(RemoteOpus.available, "iOS 17 has Apple's Opus encoder")
        for k in [RemoteFeature.move, RemoteFeature.files, RemoteFeature.resume] { XCTAssertTrue(f.contains(k), k) }
    }

    func testOnlyBlurtsRelayAndOnlyWss() {
        XCTAssertEqual(Link.publicURL(address: "wss://relay.blurt.work", room: room, ticket: ticket, testing: nil)?.absoluteString,
                       "wss://relay.blurt.work/v1/\(room)/phone?t=\(ticket)")
        XCTAssertNil(Link.publicURL(address: "wss://relay.example.com", room: room, ticket: ticket, testing: nil), "anyone else's")
        XCTAssertNil(Link.publicURL(address: "ws://relay.blurt.work", room: room, ticket: ticket, testing: nil))
        XCTAssertNil(Link.publicURL(address: "wss://meet.blurt.work", room: room, ticket: ticket, testing: nil), "the go-between isn't it")
        // a debug build's local copy, as given
        XCTAssertEqual(Link.publicURL(address: "ws://127.0.0.1:8790", room: room, ticket: ticket, testing: "ws://127.0.0.1:8790")?.absoluteString,
                       "ws://127.0.0.1:8790/v1/\(room)/phone?t=\(ticket)")
        XCTAssertNil(Link.publicURL(address: "ws://127.0.0.1:9999", room: room, ticket: ticket, testing: "ws://127.0.0.1:8790"))
    }

    func testTheRoomAndTicketGoIntoTheURLAsTheyAreOrNotAtAll() {
        let a = "wss://relay.blurt.work"
        XCTAssertNil(Link.publicURL(address: a, room: "../../x", ticket: ticket, testing: nil))
        XCTAssertNil(Link.publicURL(address: a, room: room, ticket: "x&mac=1", testing: nil))
        XCTAssertNil(Link.publicURL(address: a, room: room + "/mac", ticket: ticket, testing: nil))
        XCTAssertNil(Link.publicURL(address: a, room: "short", ticket: ticket, testing: nil))
        XCTAssertNil(Link.publicURL(address: a, room: room, ticket: "", testing: nil))
    }

    func testTheWordHoldsTenSeconds() {
        let at = Date()
        XCTAssertTrue(Link.offerFresh(at, now: at))
        XCTAssertTrue(Link.offerFresh(at, now: at.addingTimeInterval(10)))
        XCTAssertFalse(Link.offerFresh(at, now: at.addingTimeInterval(10.1)))
        XCTAssertFalse(Link.offerFresh(at, now: at.addingTimeInterval(-1)))
        XCTAssertEqual(RemotePublicRelay.giveUp, 5, "the phone's wait for `session` there")
    }

    func testTheWireSendsThePhoneThere() throws {
        let d = Data(#"{"publicRelay":{"address":"wss://relay.blurt.work","room":"\#(room)","ticket":"\#(ticket)"}}"#.utf8)
        guard case let .publicRelay(address, r, t) = try JSONDecoder().decode(ToPhone.self, from: d) else { return XCTFail() }
        XCTAssertNotNil(Link.publicURL(address: address, room: r, ticket: t, testing: nil))
        guard case let .screenFailed(why) = try JSONDecoder().decode(ToPhone.self, from: Data(#"{"screenFailed":{"_0":"busy"}}"#.utf8)) else { return XCTFail() }
        XCTAssertEqual(why, RemotePublicRelay.busy)
    }

    // MARK: voice

    func testVoiceIsPCMOffThePublicRelayOpusOnItOrNothing() {
        let opus: Set<String> = [RemoteFeature.files, RemoteFeature.opus], old: Set<String> = [RemoteFeature.files]
        XCTAssertEqual(Link.voice(publicRelay: false, phoneOpus: true, hostFeatures: opus), .pcm)
        XCTAssertEqual(Link.voice(publicRelay: false, phoneOpus: false, hostFeatures: old), .pcm)
        XCTAssertEqual(Link.voice(publicRelay: true, phoneOpus: true, hostFeatures: opus), .opus)
        // PCM never goes there
        XCTAssertEqual(Link.voice(publicRelay: true, phoneOpus: true, hostFeatures: old), .off(hostOutdated: true))
        XCTAssertEqual(Link.voice(publicRelay: true, phoneOpus: false, hostFeatures: opus), .off(hostOutdated: false))
    }

    func testOpusPacketsAreTwentyMillisecondsAndSmall() throws {
        let e = try XCTUnwrap(RemoteOpusEncoder())
        // 100 ms of a tone, as MicStream hands it over: five packets
        var pcm = Data()
        for i in 0..<1600 {
            var s = Int16(sin(Double(i) * 2 * .pi * 440 / 16000) * 8000).littleEndian
            pcm.append(Data(bytes: &s, count: 2))
        }
        let packets = e.encode(pcm)
        XCTAssertEqual(packets.count, 5)
        let bytes = packets.reduce(0) { $0 + $1.count }
        XCTAssertLessThan(bytes, 3200 / 2, "far under the 3200 bytes of PCM")
    }

    // MARK: the picture

    func testThePictureOnThePublicRelayIsDataSaversWhateverWasChosen() {
        let native = CGSize(width: 1320, height: 2868)
        for q in ScreenQuality.allCases {
            let p = ScreenPlan(q, route: .relay, cellular: false, lowData: false, native: native, panel: 120, publicRelay: true)
            XCTAssertLessThanOrEqual(p.width, RemotePublicRelay.maxWidth, "\(q)")
            XCTAssertLessThanOrEqual(p.bitrate, RemotePublicRelay.maxBitrate, "\(q)")
            XCTAssertLessThanOrEqual(p.fps, RemotePublicRelay.maxFPS, "\(q)")
        }
        XCTAssertGreaterThan(ScreenPlan(.sharp, route: .relay, cellular: false, lowData: false, native: native).bitrate, RemotePublicRelay.maxBitrate,
                             "elsewhere the choice stands")
    }
}
