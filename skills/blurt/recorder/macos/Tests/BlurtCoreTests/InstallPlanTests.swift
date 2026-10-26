// Connect's confirmation sheet reads agents.py install's changes in words: what each one is about, which group it sits
// in (what Connect adds, what needs the user, what is already in place), and the exact line only Details shows.
import XCTest
@testable import BlurtCore

final class InstallPlanTests: XCTestCase {
    let home = "/Users/me"

    func decode(_ json: String) throws -> InstallPlan {
        try JSONDecoder().decode(InstallPlan.self, from: Data(json.utf8))
    }

    func testSubjectFollowsTheShape() throws {
        let p = try decode("""
        {"applied": false, "changes": [
          {"action": "conflict", "path": "/Users/me/.claude/skills/blurt", "points_to": "/Users/me/src/blurt/skills/blurt"},
          {"action": "run", "argv": ["/Users/me/.local/bin/claude", "mcp", "add", "--scope", "user", "blurt"]},
          {"action": "symlink", "path": "/a", "target": "/b"},
          {"action": "exists", "path": "/Users/me/.agents/skills/blurt", "points_to": "/x"},
          {"action": "exists", "argv": ["claude", "mcp", "get", "blurt"]},
          {"action": "exists", "path": "/Users/me/.kimi-code/mcp.json", "key": ["mcpServers", "blurt"]},
          {"action": "json_merge", "path": "/p", "key": ["mcp", "blurt"]},
          {"action": "manual", "what": "skill", "how": ""},
          {"action": "manual", "what": "mcp", "command": ["uv", "run", "--script", "/Users/me/s/mcp_server.py"]}
        ]}
        """)
        XCTAssertEqual(p.changes.map(\.subject), [.skill, .mcp, .skill, .skill, .mcp, .mcp, .mcp, .skill, .mcp])
        XCTAssertTrue(p.changesSomething)
        XCTAssertEqual(p.changes[8].command?.last, "/Users/me/s/mcp_server.py")
    }

    func testGroups() {
        let conflict = InstallChange(action: "conflict", path: "/a", pointsTo: "/b")
        XCTAssertEqual(conflict.group(otherIsBlurt: true), .inPlace)        // another copy of Blurt keeps working
        XCTAssertEqual(conflict.group(otherIsBlurt: false), .needsYou)      // a different skill under that name
        XCTAssertEqual(InstallChange(action: "run", argv: ["x"]).group(otherIsBlurt: false), .change)
        XCTAssertEqual(InstallChange(action: "run", argv: ["x"], ok: false).group(otherIsBlurt: false), .needsYou)
        XCTAssertEqual(InstallChange(action: "exists", path: "/a").group(otherIsBlurt: false), .inPlace)
        XCTAssertEqual(InstallChange(action: "manual", what: "mcp").group(otherIsBlurt: false), .needsYou)
        XCTAssertEqual(InstallChange(action: "error", path: "/a").group(otherIsBlurt: false), .needsYou)
        XCTAssertTrue(InstallChange.Group.change < .needsYou && InstallChange.Group.needsYou < .inPlace)
        XCTAssertFalse(InstallPlan(changes: [conflict, InstallChange(action: "exists", path: "/a")], applied: false).changesSomething)
    }

    func testTechnicalLineAbbreviatesHomeAndQuotes() {
        let run = InstallChange(action: "run", argv: ["/Users/me/.local/bin/claude", "mcp", "add", "--scope", "user", "blurt", "--",
                                                      "uv", "run", "--script", "/Users/me/My Code/mcp_server.py"])
        XCTAssertEqual(run.technicalLine(home: home),
                       "~/.local/bin/claude mcp add --scope user blurt -- uv run --script '~/My Code/mcp_server.py'")
        XCTAssertEqual(InstallChange(action: "conflict", path: "/Users/me/.claude/skills/blurt", pointsTo: "/Users/me/w/skills/blurt")
                        .technicalLine(home: home), "~/.claude/skills/blurt → ~/w/skills/blurt")
        XCTAssertEqual(InstallChange(action: "json_merge", path: "/Users/me/.kimi-code/mcp.json", key: ["mcpServers", "blurt"])
                        .technicalLine(home: home), "~/.kimi-code/mcp.json: mcpServers.blurt")
        XCTAssertNil(InstallChange(action: "manual", what: "skill").technicalLine(home: home))
        XCTAssertEqual(InstallChange.tilde("/Users/me", home: home), "~")
        XCTAssertEqual(InstallChange.tilde("/Users/meme/x", home: home), "/Users/meme/x")
        XCTAssertEqual(InstallChange.tilde("/private/tmp/x", home: home + "/"), "/private/tmp/x")
    }

    func testConflictIsBlurtReadsTheOtherSkill() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("install-\(UUID().uuidString)")
        let blurt = dir.appendingPathComponent("blurt"), other = dir.appendingPathComponent("other")
        for d in [blurt, other] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: dir) }
        try "---\nname: blurt\ndescription: x\n---\n".write(to: blurt.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "---\nname: something-else\n---\n".write(to: other.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        XCTAssertTrue(InstallChange(action: "conflict", path: "/a", pointsTo: blurt.path).conflictIsBlurt)
        XCTAssertFalse(InstallChange(action: "conflict", path: "/a", pointsTo: other.path).conflictIsBlurt)
        XCTAssertFalse(InstallChange(action: "conflict", path: "/a", pointsTo: dir.appendingPathComponent("none").path).conflictIsBlurt)
        XCTAssertFalse(InstallChange(action: "exists", path: "/a", pointsTo: blurt.path).conflictIsBlurt)
        XCTAssertEqual(InstallChange(action: "conflict", pointsTo: "/Users/me/w/bug-agent/skills/blurt").otherCopy, "/Users/me/w/bug-agent")
        XCTAssertEqual(InstallChange(action: "conflict", pointsTo: "/opt/blurt").otherCopy, "/opt/blurt")
    }
}
