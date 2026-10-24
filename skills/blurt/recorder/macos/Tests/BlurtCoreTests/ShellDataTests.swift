// The app shell's data rules: Config (cached reads, refusing to overwrite an unreadable file, the lock shared with
// _common.update_global_config), FilePrivacy (0700 / 0600), SkillContract (the app ↔ skill handshake) and
// VideoRetention (which videos Settings → Storage may delete).
import Foundation
import XCTest
@testable import BlurtCore

final class ShellDataTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-shell-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func mode(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions]) as? Int) ?? -1 }

    // MARK: Config

    func testSetKeepsOtherKeysAndWritesPrivately() {
        let u = dir.appendingPathComponent("config.json")
        try! #"{"skill_dir": "/x", "record": {"countdown": 5}}"#.write(to: u, atomically: true, encoding: .utf8)
        let c = Config(url: u)
        XCTAssertTrue(c.set("record.system_audio", true))
        XCTAssertEqual(c["skill_dir"] as? String, "/x")
        XCTAssertEqual(c["record.countdown"] as? Int, 5)
        XCTAssertEqual(c["record.system_audio"] as? Bool, true)
        XCTAssertEqual(mode(u), 0o600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".config.lock").path))
    }

    func testReadsFollowOtherWriters() {
        let u = dir.appendingPathComponent("config.json")
        let c = Config(url: u)
        XCTAssertNil(c["lang"])
        try! #"{"lang": "en"}"#.write(to: u, atomically: true, encoding: .utf8)      // another process (a new inode)
        XCTAssertEqual(c["lang"] as? String, "en")
        try! #"{"lang": "zh-Hans"}"#.write(to: u, atomically: true, encoding: .utf8)
        XCTAssertEqual(c["lang"] as? String, "zh-Hans")
    }

    func testUnreadableFileIsNeverOverwritten() {
        let u = dir.appendingPathComponent("config.json")
        let broken = "{\"record\": {\"hotkeys\": {\"snap\": \"opt+shift+A\"}},, }"
        try! broken.write(to: u, atomically: true, encoding: .utf8)
        let c = Config(url: u)
        var told: [URL] = []
        c.onUnreadable = { told.append($0) }
        XCTAssertTrue(c.all.isEmpty)
        XCTAssertFalse(c.set("record.last_snap_region", [1, 2, 3, 4]))
        XCTAssertFalse(c.set("app.settings_pane", "general"))
        XCTAssertEqual(try String(contentsOf: u, encoding: .utf8), broken, "the user's file stays as it was")
        XCTAssertEqual(told.count, 1, "one backup, one notice per bad version")
        XCTAssertEqual(try String(contentsOf: told[0], encoding: .utf8), broken)
        XCTAssertTrue(told[0].lastPathComponent.hasPrefix("config.json.bad-"))
        // fixed by hand: writes work again
        try! #"{"lang": "en"}"#.write(to: u, atomically: true, encoding: .utf8)
        XCTAssertTrue(c.set("app.settings_pane", "general"))
        XCTAssertEqual(c["lang"] as? String, "en")
    }

    func testWriteWaitsForTheScriptsLock() {
        let u = dir.appendingPathComponent("config.json")
        let lock = dir.appendingPathComponent(".config.lock")
        let fd = Config.lockFile(lock)            // stands in for update_global_config holding it
        XCTAssertGreaterThanOrEqual(fd, 0)
        let done = expectation(description: "written")
        let c = Config(url: u)
        let t0 = Date()
        DispatchQueue.global().async { c.set("lang", "en"); done.fulfill() }
        usleep(300_000)
        XCTAssertNil(c["lang"], "not written while the lock is held")
        flock(fd, LOCK_UN); close(fd)
        wait(for: [done], timeout: 3)
        XCTAssertEqual(c["lang"] as? String, "en")
        XCTAssertGreaterThan(Date().timeIntervalSince(t0), 0.25)
    }

    // MARK: FilePrivacy

    func testLockDown() {
        let home = dir.appendingPathComponent("home"), ws = dir.appendingPathComponent("ws")
        for d in [home, home.appendingPathComponent("dictation"), home.appendingPathComponent("run"), ws] {
            try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        let hist = home.appendingPathComponent("dictation/history.jsonl"), tok = home.appendingPathComponent("run/asr-serve.json")
        for f in [hist, tok] { FileManager.default.createFile(atPath: f.path, contents: Data("{}".utf8), attributes: [.posixPermissions: 0o644]) }
        let changed = FilePrivacy.lockDown(home: home, workspace: ws)
        XCTAssertEqual(mode(home), 0o700)
        XCTAssertEqual(mode(home.appendingPathComponent("dictation")), 0o700)
        XCTAssertEqual(mode(home.appendingPathComponent("run")), 0o700)
        XCTAssertEqual(mode(ws), 0o700)
        XCTAssertEqual(mode(hist), 0o600)
        XCTAssertEqual(mode(tok), 0o600)
        XCTAssertEqual(changed.count, 6)
        XCTAssertEqual(FilePrivacy.lockDown(home: home, workspace: ws), [], "nothing to do the second time")
    }

    func testWritePrivate() {
        let u = dir.appendingPathComponent("sub/secret.json")
        XCTAssertTrue(FilePrivacy.writePrivate(Data("{\"token\": \"t\"}".utf8), to: u))
        XCTAssertEqual(mode(u), 0o600)
        XCTAssertEqual(try String(contentsOf: u, encoding: .utf8), "{\"token\": \"t\"}")
        let left = try! FileManager.default.contentsOfDirectory(atPath: u.deletingLastPathComponent().path)
        XCTAssertEqual(left, ["secret.json"], "no temp file left behind")
    }

    // MARK: SkillContract

    func testContractParse() {
        XCTAssertEqual(SkillContract.parse("import os\nCONTRACT = 3  # comment\nX = 1\n"), 3)
        XCTAssertEqual(SkillContract.parse("CONTRACT=2\n"), 2)
        XCTAssertEqual(SkillContract.parse("# CONTRACT = 9\nCONTRACT_X = 4\n"), 0, "only the constant itself counts")
        XCTAssertEqual(SkillContract.parse(""), 0)
    }

    func testContractCheck() {
        XCTAssertNil(SkillContract.check(skill: nil, app: 2), "no skill: nothing to compare")
        XCTAssertNil(SkillContract.check(skill: 2, app: 2))
        XCTAssertEqual(SkillContract.check(skill: 0, app: 2), .skillOlder(skill: 0))
        XCTAssertEqual(SkillContract.check(skill: 3, app: 2), .appOlder(skill: 3))
    }

    func testTheShippedSkillMatchesTheApp() {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { u.deleteLastPathComponent() }      // Tests/BlurtCoreTests/<file> → recorder/macos
        let scripts = u.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts")
        XCTAssertEqual(SkillContract.skillVersion(scripts: scripts), SkillContract.expected,
                       "bump SkillContract.expected together with _common.CONTRACT")
    }

    // MARK: VideoRetention

    func session(_ name: String, organized: Bool, age days: Double, processing: Bool = false) -> URL {
        let s = dir.appendingPathComponent("recordings/\(name)")
        try! FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        let video = s.appendingPathComponent("recording.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data(count: 1000))
        FileManager.default.createFile(atPath: s.appendingPathComponent("recording.scan.npz").path, contents: Data(count: 24))
        if organized {
            FileManager.default.createFile(atPath: s.appendingPathComponent("transcript.json").path, contents: Data("{}".utf8))
            FileManager.default.createFile(atPath: s.appendingPathComponent("batch.json").path,
                                           contents: Data("{\"processing\": \(processing)}".utf8))
        }
        try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -days * 86400)], ofItemAtPath: video.path)
        return s
    }

    func testVideoCandidates() {
        let old = session("old", organized: true, age: 100)
        _ = session("recent", organized: true, age: 3)
        _ = session("raw", organized: false, age: 200)               // never organized: the video is all there is
        _ = session("busy", organized: true, age: 200, processing: true)
        let root = dir.appendingPathComponent("recordings")
        let c = VideoRetention.candidates(roots: [root], olderThan: 30)
        XCTAssertEqual(c.map { $0.session.lastPathComponent }, ["old"])
        XCTAssertEqual(c.first?.bytes, 1024)
        XCTAssertEqual(c.first?.files.map(\.lastPathComponent), ["recording.mp4", "recording.scan.npz"])
        XCTAssertEqual(Set(VideoRetention.candidates(roots: [root], olderThan: nil).map { $0.session.lastPathComponent }), ["old", "recent"])
        XCTAssertEqual(VideoRetention.candidates(roots: [root], olderThan: nil, excluding: [old.standardizedFileURL.path]).count, 1)
    }
}
