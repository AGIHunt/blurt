// BlurtCore/Agents/UnattendedRun.swift: an unattended run's arguments (scripts pinned, one --add-dir per folder, the
// prompt never searched for placeholders) and what its sandbox may write — never Blurt's home or the shared uv cache.
import Foundation
import XCTest
@testable import BlurtCore

final class UnattendedRunTests: XCTestCase {
    /// skills/blurt/scripts/agents.json, from this file's place in the repo
    var registry: [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../scripts/agents.json")
        let o = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return o?["agents"] as? [[String: Any]] ?? []
    }

    func testArgs() {
        let run = ["-p", "{prompt}", "--allowedTools", "Bash(uv run {scripts}/items.py:*)", "{writable}"]
        let args = UnattendedRun.args(run, prompt: "look at {scripts} and {writable}", scripts: "/s/scripts", writable: ["/a", "/b"])
        XCTAssertEqual(args, ["-p", "look at {scripts} and {writable}", "--allowedTools", "Bash(uv run /s/scripts/items.py:*)",
                              "--add-dir", "/a", "--add-dir", "/b"])
    }

    func testShellCommandsArePinnedToTheSkillScripts() {
        for id in ["claude", "gemini"] {
            let run = registry.first { $0["id"] as? String == id }?["run"] as? [String] ?? []
            let shell = run.filter { $0.hasPrefix("Bash(") || $0.hasPrefix("run_shell_command(") }
            XCTAssertFalse(shell.isEmpty, id)
            for rule in shell {  // `uv run <scripts>/<name>.py …`, never a bare `uv run` prefix
                XCTAssertTrue(rule.contains("uv run {scripts}/") && rule.contains(".py"), "\(id): \(rule)")
            }
            XCTAssertFalse(run.contains("Write") || run.contains("Edit") || run.contains("--yolo"), id)  // edits: cwd only
        }
        let codex = registry.first { $0["id"] as? String == "codex" }?["run"] as? [String] ?? []
        XCTAssertTrue(codex.contains("workspace-write") && codex.contains("{writable}"))
        XCTAssertFalse(codex.contains { $0.contains("danger") || $0.contains("bypass") })
    }

    func testWritableDirs() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("unattended-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let home = tmp.appendingPathComponent("home"), inbox = tmp.appendingPathComponent("ws/inbox")
        let store = tmp.appendingPathComponent("proj/.blurt"), moved = tmp.appendingPathComponent("gone/.blurt")
        for d in [home, inbox, store] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let dirs = UnattendedRun.writableDirs(inbox: inbox, projectStores: [store, moved, store], home: home)
        XCTAssertEqual(dirs, [inbox.path, store.path, UnattendedRun.uvCache(home: home).path])
        XCTAssertFalse(dirs.contains(home.path))  // config.json, the jobs' hook settings, index.db
        XCTAssertTrue(UnattendedRun.uvCache(home: home).path.hasPrefix(home.path + "/sandbox/"))

        let env = UnattendedRun.sandboxEnv(home: home)
        XCTAssertEqual(env["UV_CACHE_DIR"], UnattendedRun.uvCache(home: home).path)
        XCTAssertEqual(env["BLURT_NO_INDEX"], "1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: UnattendedRun.uvCache(home: home).path))  // its parent isn't writable to the run
    }
}
