// BlurtCore/Lifecycle.swift against tests/fixtures/lifecycle.json — the one K3 table Python, the web and Swift share.
import Foundation
import XCTest
@testable import BlurtCore

final class LifecycleTests: XCTestCase {
    static var fixture: [String: Any] = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { u.deleteLastPathComponent() }      // Tests/BlurtCoreTests/<file> → repo root
        let d = try! Data(contentsOf: u.appendingPathComponent("tests/fixtures/lifecycle.json"))
        return try! JSONSerialization.jsonObject(with: d) as! [String: Any]
    }()

    func testStatesAndGroups() {
        let f = Self.fixture
        XCTAssertEqual(Lifecycle.states, f["states"] as? [String])
        let g = f["groups"] as! [String: [String]]
        XCTAssertEqual(Lifecycle.inbox, Set(g["inbox"]!))
        XCTAssertEqual(Lifecycle.open, Set(g["open"]!))
        XCTAssertEqual(Lifecycle.active, Set(g["active"]!))
        XCTAssertEqual(Lifecycle.closed, Set(g["closed"]!))
    }

    func testActions() {
        let acts = Self.fixture["actions"] as! [[String: Any]]
        XCTAssertEqual(Lifecycle.actions, acts.map { $0["action"] as! String })
        for a in acts {
            let name = a["action"] as! String
            let t = Lifecycle.transitions[name]!
            XCTAssertEqual(t.from, a["from"] as? [String], name)
            XCTAssertEqual(t.to, a["to"] as? String, name)
            XCTAssertEqual(t.key, a["key"] as? String, name)
            for s in Lifecycle.states {
                XCTAssertEqual(Lifecycle.canDo(name, s), t.from.contains(s), "\(name) from \(s)")
            }
        }
    }

    func testMenus() {
        let menus = Self.fixture["menus"] as! [String: [String]]
        for s in Lifecycle.states {
            XCTAssertEqual(Lifecycle.menu(for: s, canHandOff: true), menus[s], s)
            XCTAssertEqual(Lifecycle.menu(for: s, canHandOff: false), menus[s]!.filter { $0 != "hand_off" }, s)
            // every item of a menu is valid from its state, and R is never ambiguous
            XCTAssertTrue(menus[s]!.allSatisfy { Lifecycle.canDo($0, s) }, s)
            XCTAssertLessThanOrEqual(Lifecycle.backActions.filter { Lifecycle.canDo($0, s) }.count, 1, s)
        }
    }

    func testTargetsAndKeys() {
        XCTAssertEqual(Lifecycle.target(of: "keep", state: "new"), "todo")
        XCTAssertNil(Lifecycle.target(of: "keep", state: "todo"))
        XCTAssertEqual(Lifecycle.target(of: "restore", state: "discarded", restoreTo: "done"), "done")
        XCTAssertEqual(Lifecycle.target(of: "restore", state: "discarded", restoreTo: nil), "new")
        XCTAssertEqual(Lifecycle.target(of: "restore", state: "discarded", restoreTo: "discarded"), "new")
        XCTAssertEqual(Lifecycle.backAction("to_verify"), "send_back")
        XCTAssertEqual(Lifecycle.backAction("in_progress"), "take_back")
        XCTAssertEqual(Lifecycle.backAction("wontfix"), "reopen")
        XCTAssertEqual(Lifecycle.backAction("discarded"), "restore")
        XCTAssertNil(Lifecycle.backAction("new"))
        XCTAssertEqual(Lifecycle.action(forKey: "a", state: "new"), "keep")
        XCTAssertNil(Lifecycle.action(forKey: "a", state: "todo"))
        XCTAssertEqual(Lifecycle.action(forKey: "R", state: "done"), "reopen")
        XCTAssertEqual(Lifecycle.action(forKey: "delete", state: "done"), "discard")
        XCTAssertNil(Lifecycle.action(forKey: "x", state: "discarded"))
        XCTAssertEqual(Lifecycle.action(forKey: "cmd+enter", state: "todo"), "hand_off")
        XCTAssertEqual(Lifecycle.keyLabel("hand_off"), "⌘↩")
        XCTAssertEqual(Lifecycle.keyLabel("wontfix"), "W")
    }

    func testMigration() {
        for c in Self.fixture["migrate"] as! [[String: Any]] {
            let m = Lifecycle.migrate(c["in"] as! [String: Any])
            XCTAssertEqual(m.state, c["state"] as? String, "\(c["in"]!)")
            XCTAssertEqual(m.restoreTo, c["restore_to"] as? String, "\(c["in"]!)")
        }
    }

    func testLegacyQueryWords() {
        XCTAssertEqual(Lifecycle.states(fromStatus: "draft"), ["new"])
        XCTAssertEqual(Lifecycle.states(fromStatus: "deleted"), ["discarded"])
        XCTAssertEqual(Set(Lifecycle.states(fromStatus: "confirmed")), Set(Lifecycle.live).subtracting(["new"]))
        XCTAssertEqual(Lifecycle.states(fromWork: "todo"), ["new", "todo"])
        XCTAssertEqual(Lifecycle.states(fromWork: "to_verify"), ["to_verify"])
    }

    /// A list key that does nothing says why (the dogfood's bare beep on D for a discarded item).
    func testRefusalSaysWhy() {
        XCTAssertEqual(Lifecycle.refusal(forKey: "d", states: ["discarded"]), .discarded)
        XCTAssertNil(Lifecycle.refusal(forKey: "d", states: ["new"]))             // BA-56: D marks a new one done too
        XCTAssertEqual(Lifecycle.refusal(forKey: "a", states: ["todo"]), .state("todo"))
        XCTAssertEqual(Lifecycle.refusal(forKey: "a", states: ["done", "wontfix"]), .state(nil))
        XCTAssertNil(Lifecycle.refusal(forKey: "d", states: ["new", "todo"]))      // D marks the to-do one done
        XCTAssertNil(Lifecycle.refusal(forKey: "r", states: ["discarded"]))       // R restores
        XCTAssertNil(Lifecycle.refusal(forKey: "d", states: []))
    }
}
