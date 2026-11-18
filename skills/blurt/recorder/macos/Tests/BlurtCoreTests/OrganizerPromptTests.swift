// BlurtCore OrganizerPrompt.render: what an organising run is told, from skills/blurt/scripts/organize_prompt.json. The
// Windows/Linux app renders the same parts (agents.rs organize_prompt); tests/organize-prompt/golden.json pins what
// both make of each input, so the two can't drift.
import Foundation
import XCTest
@testable import BlurtCore

final class OrganizerPromptTests: XCTestCase {
    var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../../..").standardizedFileURL }

    var parts: [String: String] {
        OrganizerPrompt.parts(from: [repo.appendingPathComponent("skills/blurt/scripts/organize_prompt.json")]) ?? [:]
    }

    func testGoldenCases() throws {
        let d = try Data(contentsOf: repo.appendingPathComponent("tests/organize-prompt/golden.json"))
        let cases = (try JSONSerialization.jsonObject(with: d) as? [String: Any])?["cases"] as? [[String: Any]] ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 3)
        for c in cases {
            let i = c["input"] as? [String: Any] ?? [:]
            let got = OrganizerPrompt.render(parts, session: i["session"] as? String ?? "", shots: i["shots"] as? Bool ?? false,
                                             captures: i["captures"] as? [Int], skillMD: i["skill_md"] as? String ?? "",
                                             scripts: i["scripts"] as? String ?? "", code: i["code"] as? String,
                                             candidates: i["candidates"] as? String)
            XCTAssertEqual(got, c["prompt"] as? String, c["name"] as? String ?? "")
        }
    }

    /// The scripts line is UnattendedRun.scriptsHint's (AI fill-in says it too).
    func testScriptsHintIsTheSame() {
        XCTAssertEqual(parts["scripts"]?.replacingOccurrences(of: "{scripts}", with: "/s"), UnattendedRun.scriptsHint("/s"))
    }

    func testNoPartsNoPrompt() {
        XCTAssertNil(OrganizerPrompt.parts(from: [repo.appendingPathComponent("nope.json")]))
    }
}
