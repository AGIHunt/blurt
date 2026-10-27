import XCTest
@testable import BlurtCore

/// A release app's own skill, copied to ~/.blurt/skill (BundledSkill): the app from the website needs no other install.
final class BundledSkillTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-skill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func skill(_ name: String, stamp: String?, marker: String) throws -> URL {
        let d = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: d.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try "CONTRACT = 1\n".write(to: d.appendingPathComponent("scripts/_common.py"), atomically: true, encoding: .utf8)
        try marker.write(to: d.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        if let s = stamp { try s.write(to: d.appendingPathComponent(".version"), atomically: true, encoding: .utf8) }
        return d
    }

    private func marker(_ d: URL) -> String? { try? String(contentsOf: d.appendingPathComponent("SKILL.md"), encoding: .utf8) }

    func testCopiedWhenMissingThenLeftAlone() throws {
        let src = try skill("bundle", stamp: "1.0.1 (726)", marker: "new")
        let dest = tmp.appendingPathComponent("home/skill")
        XCTAssertTrue(try BundledSkill.sync(from: src, to: dest))
        XCTAssertEqual(marker(dest), "new")
        // a cache the scripts wrote stays while the stamp matches
        try "x".write(to: dest.appendingPathComponent("scripts/cache"), atomically: true, encoding: .utf8)
        XCTAssertFalse(try BundledSkill.sync(from: src, to: dest))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("scripts/cache").path))
    }

    func testAnUpdateReplacesTheOldCopyWhole() throws {
        let dest = try skill("home/skill", stamp: "1.0.0 (725)", marker: "old")
        try "stale".write(to: dest.appendingPathComponent("scripts/gone.py"), atomically: true, encoding: .utf8)
        let src = try skill("bundle", stamp: "1.0.1 (726)", marker: "new")
        XCTAssertTrue(try BundledSkill.sync(from: src, to: dest))
        XCTAssertEqual(marker(dest), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("scripts/gone.py").path))
        // nothing left next to it
        let left = try FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path)
        XCTAssertEqual(left, ["skill"])
    }

    func testACopyWithoutItsScriptsIsRedone() throws {
        let dest = tmp.appendingPathComponent("home/skill")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try "1.0.1 (726)".write(to: dest.appendingPathComponent(".version"), atomically: true, encoding: .utf8)
        let src = try skill("bundle", stamp: "1.0.1 (726)", marker: "new")
        XCTAssertTrue(try BundledSkill.sync(from: src, to: dest))
        XCTAssertEqual(marker(dest), "new")
    }

    func testABundleWithoutAStampIsAlwaysCopied() throws {
        let src = try skill("bundle", stamp: nil, marker: "new")
        let dest = tmp.appendingPathComponent("home/skill")
        XCTAssertTrue(try BundledSkill.sync(from: src, to: dest))
        XCTAssertTrue(try BundledSkill.sync(from: src, to: dest))
    }

    func testOnlyABundleWithScriptsCounts() throws {
        // the test runner's own bundle has no skill
        XCTAssertNil(BundledSkill.source(in: Bundle(for: Self.self)))
    }
}
