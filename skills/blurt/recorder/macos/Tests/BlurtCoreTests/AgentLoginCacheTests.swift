// Dogfood (work): the Hand Off panel opened on a signed-out Claude Code and switched to Codex seconds later, because only
// a 10 s sweep knew who was signed in. Agents.LoginCache keeps the last sign-in check per agent (merged as single-agent
// probes come back), and sessions.py's outdated refusal carries the version, the minimum and the update command.
import Foundation
import XCTest
@testable import BlurtCore

final class AgentLoginCacheTests: XCTestCase {
    func detect(_ rows: [(String, String, String)]) throws -> AgentDetect {
        let agents = rows.map { id, state, fix in
            ["id": id, "name": id, "installed": state != "not_installed", "login": state == "logged_out" ? "logged_out" : "ok",
             "state": state, "why": "", "fix": fix, "headless": true] as [String: Any]
        }
        let d = try JSONSerialization.data(withJSONObject: ["order": rows.map(\.0), "pick": NSNull(), "agents": agents])
        return try JSONDecoder().decode(AgentDetect.self, from: d)
    }

    func testMergesProbesPerAgent() throws {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var c = Agents.LoginCache(at: t0, states: [:], fix: [:])
        c = c.merging(try detect([("claude", "logged_out", "run `claude` and /login"), ("codex", "ready", "")]), at: t0)
        XCTAssertTrue(c.loggedOut("claude"))
        XCTAssertFalse(c.loggedOut("codex"))
        XCTAssertEqual(c.fix["claude"], "run `claude` and /login")
        XCTAssertNil(c.fix["codex"])
        XCTAssertFalse(c.knows("grok"))
        // a later probe of one agent changes that one only
        let t1 = t0.addingTimeInterval(60)
        c = c.merging(try detect([("claude", "ready", "")]), at: t1)
        XCTAssertFalse(c.loggedOut("claude"))
        XCTAssertNil(c.fix["claude"])
        XCTAssertEqual(c.states["codex"], "ready")
        XCTAssertEqual(c.at, t1)
    }

    func testOutdatedRefusalCarriesVersions() {
        let e = SessionsError(json: ["ok": false, "code": "outdated", "error": "Codex 0.157.0 is too old", "agent": "codex",
                                     "version": "0.157.0", "need": "0.164.0", "fix": "npm i -g @openai/codex"], fallback: "failed")
        XCTAssertEqual(e.code, "outdated")
        XCTAssertEqual(e.version, "0.157.0")
        XCTAssertEqual(e.need, "0.164.0")
        XCTAssertEqual(e.fix, "npm i -g @openai/codex")
    }
}
