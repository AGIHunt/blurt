// BlurtCore/DictationTier.swift against tests/fixtures/dictation_tier.jsonl — the rule transcribe.py's dictation_tier
// is checked against too (docs/design/dictation.md §Defaults by Mac).
import XCTest
@testable import BlurtCore

final class DictationTierTests: XCTestCase {
    static var fixture: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("tests/fixtures/dictation_tier.jsonl")
    }

    func testTheSharedFixture() throws {
        let rows = try String(contentsOf: Self.fixture, encoding: .utf8).split(separator: "\n")
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertGreaterThanOrEqual(rows.count, 10)
        for r in rows {
            let name = r["case"] as? String ?? ""
            let want = r["want"] as! [String: Any]
            let c = DictationTier.recommended(ramGB: (r["ram_gb"] as! NSNumber).doubleValue, rtf: (r["rtf"] as? NSNumber)?.doubleValue,
                                              hasCloudKey: r["cloud"] as? Bool ?? false, slowChip: r["slow"] as? Bool ?? false,
                                              languages: r["languages"] as? [String] ?? [])
            XCTAssertEqual(c.tier.rawValue, want["tier"] as? String, name)
            XCTAssertEqual(c.recognizer, want["recognizer"] as? String, name)
            XCTAssertEqual(c.window, (want["window_s"] as? NSNumber)?.doubleValue, name)
            XCTAssertEqual(c.fieldContext, want["field_context"] as? Bool, name)
            XCTAssertEqual(c.localPolish, want["local_polish"] as? String, name)
            XCTAssertEqual(c.cloudPolish, want["cloud_polish"] as? Bool, name)
            XCTAssertEqual(c.secondTranscript, c.cloudPolish, name)
            XCTAssertEqual(c.why.rawValue, want["why"] as? String, name)
            XCTAssertEqual(c.first, "apple-speech", name)
        }
    }

    func testSlowChipsAreTheBaseM1AndM2Only() {
        XCTAssertTrue(DictationTier.slowChip("Apple M1"))
        XCTAssertTrue(DictationTier.slowChip(" Apple  M2 "))
        XCTAssertFalse(DictationTier.slowChip("Apple M1 Pro"))
        XCTAssertFalse(DictationTier.slowChip("Apple M3"))
        XCTAssertFalse(DictationTier.slowChip("Apple M5 Max"))
        XCTAssertFalse(DictationTier.slowChip(nil))
    }

    /// The windows are the catalogue's (asr_models.json rehear_window_s), as ModelCatalog reads them.
    func testWindowsMatchTheCatalogue() {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }      // Tests/BlurtCoreTests/x.swift → skills/blurt
        let scripts = u.appendingPathComponent("scripts")
        XCTAssertEqual(ModelCatalog.rehearWindow(DictationTier.large, dir: scripts), 30)
        XCTAssertEqual(ModelCatalog.rehearWindow(DictationTier.small, dir: scripts), 20)
        XCTAssertEqual(ModelCatalog.rehearWindow(DictationTier.fun, dir: scripts), DictationTier.funWindow)
    }

    /// Fun-ASR-Nano's languages are the catalogue's, and only people who speak nothing else get it.
    func testFunASRLanguages() throws {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        let d = try Data(contentsOf: u.appendingPathComponent("scripts/asr_models.json"))
        let models = (try JSONSerialization.jsonObject(with: d) as? [String: Any])?["models"] as? [[String: Any]] ?? []
        let fun = models.first { $0["id"] as? String == DictationTier.fun }
        XCTAssertEqual(Set(fun?["languages"] as? [String] ?? []), DictationTier.funLanguages)
        XCTAssertTrue(DictationTier.funSpeaks(["zh-Hans-CN", "en-US"]))
        XCTAssertTrue(DictationTier.funSpeaks(["ja"]))
        XCTAssertFalse(DictationTier.funSpeaks(["zh", "en", "de"]))
        XCTAssertFalse(DictationTier.funSpeaks(["yue"]))
        XCTAssertFalse(DictationTier.funSpeaks([]))
    }
}
