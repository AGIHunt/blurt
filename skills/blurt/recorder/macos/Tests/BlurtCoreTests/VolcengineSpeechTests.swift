// BlurtCore/VolcengineSpeech.swift and WarmServerStream.swift: the App ID + Access Token pair kept as one Keychain item,
// its checks, and the PCM a take streams to the speech server.
import XCTest
@testable import BlurtCore

final class VolcengineSpeechTests: XCTestCase {
    func testThePairIsOneItemAndComesBack() {
        let c = VolcengineSpeech.credential(appID: " 1234567890 ", token: "tok:en-with.colon\n")
        XCTAssertEqual(c, "1234567890:tok:en-with.colon")
        let p = VolcengineSpeech.split(c)
        XCTAssertEqual(p?.appID, "1234567890")
        XCTAssertEqual(p?.token, "tok:en-with.colon")
    }

    func testAnythingElseIsNoPair() {
        XCTAssertNil(VolcengineSpeech.split(nil))
        XCTAssertNil(VolcengineSpeech.split("sk-an-api-key"))
        XCTAssertNil(VolcengineSpeech.split("1234:"))
        XCTAssertNil(VolcengineSpeech.split("12 34:token"))
    }

    func testProblems() {
        XCTAssertNil(VolcengineSpeech.problem(appID: "1234567890", token: "abcDEF123"))
        XCTAssertEqual(VolcengineSpeech.problem(appID: "", token: "abc"), .appID)
        XCTAssertEqual(VolcengineSpeech.problem(appID: "12 34", token: "abc"), .appID)
        XCTAssertEqual(VolcengineSpeech.problem(appID: "1234", token: ""), .token(.empty))
        XCTAssertEqual(VolcengineSpeech.problem(appID: "1234", token: "ab c"), .token(.spaces))
        XCTAssertEqual(VolcengineSpeech.problem(appID: "1234", token: "abcç"), .token(.characters))
    }

    func testOfferedWhereItCanServe() {
        XCTAssertTrue(VolcengineSpeech.offered(regionCode: "CN", languages: ["en-US"]))
        XCTAssertTrue(VolcengineSpeech.offered(regionCode: "US", languages: ["en-US", "zh-Hans-CN"]))
        XCTAssertTrue(VolcengineSpeech.offered(regionCode: nil, languages: ["yue-Hant-HK"]))
        XCTAssertFalse(VolcengineSpeech.offered(regionCode: "DE", languages: ["de-DE", "en"]))
    }

    func testPCMIsSixteenBitLittleEndianClipped() {
        let d = WarmServerStream.pcm([0, 1, -1, 2, 0.5])
        XCTAssertEqual(d.count, 10)
        let v = d.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)).map { Int16(littleEndian: $0) } }
        XCTAssertEqual(v, [0, 32767, -32767, 32767, 16383])
    }

    func testAStreamWithNoServerIsNotUsed() {
        // no run file for this name: finish says "send the take whole" at once
        let s = WarmServerStream(server: "no-such-server-\(UUID().uuidString)", header: ["model_id": "volcengine-seedasr"], hold: false)
        s.append([0.1, 0.2])
        XCTAssertFalse(s.opened)
        XCTAssertNil(s.finish(timeout: 1))
    }
}
