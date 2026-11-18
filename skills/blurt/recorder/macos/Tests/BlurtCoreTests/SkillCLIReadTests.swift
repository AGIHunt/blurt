import XCTest
@testable import BlurtCore

/// SkillCLI.read: the model lists are read offline first (no PyPI on the way), and online only when that fails.
final class SkillCLIReadTests: XCTestCase {
    private func script(_ body: String) throws -> String {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-read-\(UUID().uuidString).py")
        try body.write(to: u, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u.path
    }

    func testAReadRunsOfflineFirst() async throws {
        guard SkillCLI.shared.uvPath != nil else { throw XCTSkip("uv isn't installed here") }
        let s = try script("import json, os\nprint(json.dumps({'offline': os.environ.get('UV_OFFLINE')}))\n")
        let r = try await SkillCLI.shared.read(s, [], timeout: 60)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.json?["offline"] as? String, "1")
    }

    func testAReadThatFailsOfflineRunsAgainOnline() async throws {
        guard SkillCLI.shared.uvPath != nil else { throw XCTSkip("uv isn't installed here") }
        // what an empty package cache does to the offline try: it exits non-zero, and the online run answers
        let s = try script("import json, os, sys\nif os.environ.get('UV_OFFLINE'): sys.exit(2)\nprint(json.dumps({'offline': None, 'ok': True}))\n")
        let r = try await SkillCLI.shared.read(s, [], timeout: 60)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.json?["ok"] as? Bool, true)
    }

    func testAStuckOfflineTryDoesNotUseUpTheRead() async throws {
        guard SkillCLI.shared.uvPath != nil else { throw XCTSkip("uv isn't installed here") }
        let was = SkillCLI.offlineReadTimeout
        SkillCLI.offlineReadTimeout = 1.5
        defer { SkillCLI.offlineReadTimeout = was }
        let s = try script("import json, os, time\nif os.environ.get('UV_OFFLINE'): time.sleep(30)\nprint(json.dumps({'ok': True}))\n")
        let t0 = Date()
        let r = try await SkillCLI.shared.read(s, [], timeout: 60)
        XCTAssertTrue(r.ok)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 15)
    }
}
