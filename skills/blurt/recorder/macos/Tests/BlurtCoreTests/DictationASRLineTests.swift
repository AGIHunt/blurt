import XCTest
@testable import BlurtCore

/// 2026-10-31, the founder: a cloud key with two "ç" after it failed every take as "Couldn't recognize that · Retry"
/// (Retry failed the same way), and a model switch left takes waiting for minutes.
final class DictationASRLineTests: XCTestCase {
    func testCloudKeyFailureSaysSoAndOffersSettingsNotRetry() {
        let l = DictationASRFailure(code: "auth").line
        XCTAssertEqual(l, .cloudKey)
        XCTAssertFalse(l.retryHelps)
        XCTAssertEqual(l.key, "dictation.toast.asr_cloud_key")
    }

    func testNetworkAndQuotaSayWhatAndKeepRetry() {
        XCTAssertEqual(DictationASRFailure(code: "network").line, .cloudOffline)
        XCTAssertEqual(DictationASRFailure(code: "quota").line, .cloudQuota)
        XCTAssertTrue(DictationASRFailure(code: "network").line.retryHelps)
        XCTAssertTrue(DictationASRFailure(code: "quota").line.retryHelps)
    }

    func testEverythingElseKeepsTheOldLines() {
        XCTAssertEqual(DictationASRFailure(code: "error").line, .failed)
        XCTAssertEqual(DictationASRFailure(code: nil).line, .failed)
        XCTAssertEqual(DictationASRFailure(code: "timeout").line, .slow)
        XCTAssertEqual(DictationASRFailure.failed("bad_response").line.key, "dictation.toast.asr_failed")
        XCTAssertEqual(DictationASRFailure.timedOut.line.key, "dictation.toast.asr_slow")
    }

    func testDefiniteAnswersSkipTheCLIRerun() {
        for c in ["model_missing", "auth", "privacy"] { XCTAssertTrue(DictationASRFailure.definite(c), c) }
        for c in ["error", "network", "quota", "restarting", "interrupted", ""] { XCTAssertFalse(DictationASRFailure.definite(c), c) }
        XCTAssertFalse(DictationASRFailure.definite(nil))
    }

    func testEveryLineIsInBothLanguages() throws {
        let res = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BlurtApp/Resources")
        for lang in ["en", "zh-Hans"] {
            let d = try XCTUnwrap(NSDictionary(contentsOf: res.appendingPathComponent("\(lang).lproj/Dictation.strings")))
            let lines: [DictationASRFailure.Line] = [.failed, .slow, .cloudKey, .cloudOffline, .cloudQuota]
            for l in lines { XCTAssertNotNil(d[l.key], "\(lang) \(l.key)") }
            XCTAssertNotNil(d["dictation.toast.asr_cloud_key.action"])
            let s = try XCTUnwrap(NSDictionary(contentsOf: res.appendingPathComponent("\(lang).lproj/Speech.strings")))
            for code in ["auth", "network", "quota", "privacy", "no_key", "bad_key", "anything"] {
                XCTAssertNotNil(s[CloudSpeechCheck.sentence(code)], "\(lang) \(code)")
            }
            XCTAssertNotNil(s["speech.cloud.check.ok_silent"])
        }
    }

    func testATakeNeverWaitsForever() {
        XCTAssertEqual(DictationTakeDeadline.seconds(audioSeconds: 3), 46.5)
        XCTAssertEqual(DictationTakeDeadline.seconds(audioSeconds: 60), 75)
        XCTAssertEqual(DictationTakeDeadline.seconds(audioSeconds: 300), DictationTakeDeadline.cap)
        // a cold Whisper load (~30 s) still fits a short take
        XCTAssertGreaterThan(DictationTakeDeadline.seconds(audioSeconds: 1), 35)
    }

    func testKeyCharacters() {
        XCTAssertEqual(CloudSpeechCheck.clean("  sk-abc123\n"), "sk-abc123")
        XCTAssertEqual(CloudSpeechCheck.clean(""), "")
        XCTAssertEqual(CloudSpeechCheck.clean("   "), "")
        // the founder's: a key, then two ç as ⌥C types them (decomposed) — and the composed form
        XCTAssertNil(CloudSpeechCheck.clean("sk-abc123c\u{0327}c\u{0327}"))
        XCTAssertNil(CloudSpeechCheck.clean("sk-abc123çç"))
        XCTAssertNil(CloudSpeechCheck.clean("sk-abc 123"))
        XCTAssertNil(CloudSpeechCheck.clean("sk-abc\u{200B}123"))     // a zero-width space from a web page
    }

    func testCheckAnswers() {
        XCTAssertEqual(CloudSpeechCheck.result(["ok": true, "ms": 812, "heard": true]), .ok(ms: 812, heard: true))
        XCTAssertEqual(CloudSpeechCheck.result(["ok": true, "ms": 500, "heard": false]), .ok(ms: 500, heard: false))
        XCTAssertEqual(CloudSpeechCheck.result(["ok": false, "code": "auth"]), .failed("speech.cloud.check.auth"))
        XCTAssertEqual(CloudSpeechCheck.result(["ok": false, "code": "timeout"]), .failed("speech.cloud.check.network"))
        XCTAssertEqual(CloudSpeechCheck.result(nil), .failed("speech.cloud.check.other"))
    }
}
