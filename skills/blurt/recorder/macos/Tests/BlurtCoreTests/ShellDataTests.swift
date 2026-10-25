// The app shell's data rules: Config (cached reads, refusing to overwrite an unreadable file, the lock shared with
// _common.update_global_config), FilePrivacy (0700 / 0600), SkillContract (the app ↔ skill handshake),
// VideoRetention (which videos Settings → Storage may delete), ModelUsage (which models it may offer for the Trash) and
// LaunchQueue (one message at launch).
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
        // the next launch (a new Config) finds the same file still broken: it is told again, but no second copy
        let next = Config(url: u)
        var toldNext: [URL] = []
        next.onUnreadable = { toldNext.append($0) }
        XCTAssertFalse(next.set("app.welcomed", true))
        XCTAssertEqual(toldNext.map(\.lastPathComponent), told.map(\.lastPathComponent))
        let copies = try! FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("config.json.bad-") }
        XCTAssertEqual(copies.count, 1)
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

    /// A recording with snaps taken while recording, its video deleted: meta.json still says recording, other keys kept.
    func testStampKeepsARecordingARecording() throws {
        let s = session("snapped", organized: true, age: 100)
        try #"{"video": "recording.mp4", "duration": 42.5, "author": "A"}"#.write(to: s.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: s.appendingPathComponent("shots.jsonl").path, contents: Data("{\"n\": 1}\n".utf8))
        XCTAssertFalse(VideoRetention.isRecording(s))
        XCTAssertTrue(VideoRetention.stamp(s))
        XCTAssertTrue(VideoRetention.isRecording(s))
        try FileManager.default.removeItem(at: s.appendingPathComponent("recording.mp4"))
        XCTAssertTrue(VideoRetention.stamp(s, removed: Date(timeIntervalSince1970: 0)))
        let m = try JSONSerialization.jsonObject(with: Data(contentsOf: s.appendingPathComponent("meta.json"))) as! [String: Any]
        XCTAssertEqual(m["mode"] as? String, "video")
        XCTAssertEqual(m["video_removed"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual(m["duration"] as? Double, 42.5)
        XCTAssertEqual(m["author"] as? String, "A")
        XCTAssertTrue(VideoRetention.isRecording(s))
        // Undo in Settings → Storage put the video back: the session no longer says it was removed, still a recording
        XCTAssertTrue(VideoRetention.unstampRemoved(s))
        let back = try JSONSerialization.jsonObject(with: Data(contentsOf: s.appendingPathComponent("meta.json"))) as! [String: Any]
        XCTAssertNil(back["video_removed"])
        XCTAssertEqual(back["duration"] as? Double, 42.5)
        XCTAssertTrue(VideoRetention.isRecording(s))
    }

    // MARK: ModelUsage

    func asrModels() -> [String: Any] {
        ["models": [
            ["id": "qwen3-asr-1.7b-mlx", "name": "Qwen3-ASR 1.7B", "installed": true, "path": "/h/models/asr/qwen17", "purposes": [String]()],
            ["id": "sensevoice", "name": "SenseVoice", "installed": true, "path": "/h/models/asr/sv", "purposes": ["batch", "live", "note"]],
            ["id": "turbo", "name": "Turbo", "installed": true, "path": "/h/models/asr/turbo", "purposes": [String]()],
            ["id": "hf", "name": "HF", "installed": true, "path": "/c/hub/models--org--name/snapshots/abc", "purposes": [String]()],
            ["id": "silero-vad", "name": "Silero VAD", "role": "vad", "installed": true, "path": "/h/models/silero_vad.onnx", "purposes": [String]()],
            ["id": "gone", "installed": false, "path": "/h/models/asr/gone", "purposes": [String]()],
        ]]
    }

    /// The model Fn dictation runs is in use even when no recording, live-caption or voice-note pick names it.
    func testDictationModelIsInUse() {
        let u = ModelUsage.merge(asr: asrModels(), dictation: ["selected": "qwen3-asr-1.7b-mlx"],
                                 polish: ["selected": "p1", "models": [["id": "p1", "name": "P1", "installed": true, "path": "/h/models/polish/p1"],
                                                                       ["id": "p2", "name": "P2", "installed": true, "path": "/h/models/polish/p2"]]])
        XCTAssertEqual(u["/h/models/asr/qwen17"], .init(name: "Qwen3-ASR 1.7B", kind: .asr, inUse: true, removable: false))
        XCTAssertEqual(u["/h/models/asr/sv"]?.inUse, true)
        XCTAssertEqual(u["/h/models/asr/turbo"], .init(name: "Turbo", kind: .asr, inUse: false, removable: true))
        XCTAssertEqual(u["/h/models/silero_vad.onnx"]?.kind, .vad)
        XCTAssertEqual(u["/h/models/silero_vad.onnx"]?.removable, false)
        XCTAssertEqual(u["/c/hub/models--org--name"]?.name, "HF")
        XCTAssertNil(u["/h/models/asr/gone"])
        XCTAssertEqual(u["/h/models/polish/p1"]?.inUse, true)
        XCTAssertEqual(u["/h/models/polish/p2"]?.removable, true)
    }

    /// Without dictation's answer no speech model is offered for the Trash: the one it runs can't be told apart.
    func testNoDictationAnswerRemovesNothing() {
        let u = ModelUsage.merge(asr: asrModels(), dictation: nil, polish: nil)
        XCTAssertEqual(u["/h/models/asr/turbo"]?.inUse, false)
        XCTAssertFalse(u.values.contains { $0.removable })
    }
}

// MARK: LaunchQueue

final class LaunchQueueTests: XCTestCase {
    var shown: [String] = []
    var dropped: [String] = []
    lazy var q = LaunchQueue<String>(hold: 3, window: 90, show: { self.shown.append($0) }, dropped: { m, _ in self.dropped.append(m) })
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testHoldShowsOnlyTheHighest() {
        q.start(now: t0)
        XCTAssertEqual(q.post(1, "model", now: t0), .held)
        XCTAssertEqual(q.post(7, "welcome", now: t0 + 1), .held)
        XCTAssertEqual(q.post(4, "permission", now: t0 + 2), .held)
        XCTAssertEqual(q.post(7, "welcome again", now: t0 + 2), .held)
        XCTAssertTrue(shown.isEmpty)
        q.flush()
        XCTAssertEqual(shown, ["welcome"], "the highest; between equals the first posted")
        XCTAssertEqual(Set(dropped), ["model", "permission", "welcome again"])
    }

    func testOneShownThenDropsUntilTheWindowEnds() {
        q.start(now: t0)
        q.flush()                                       // nothing held: nothing shown yet
        XCTAssertEqual(q.post(2, "job", now: t0 + 10), .shown)
        XCTAssertEqual(q.post(8, "config", now: t0 + 20), .dropped)
        XCTAssertEqual(q.post(1, "later", now: t0 + 91), .shown, "after the window it is an ordinary toast")
        XCTAssertEqual(shown, ["job", "later"])
        XCTAssertEqual(dropped, ["config"])
    }
}
