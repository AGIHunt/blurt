// dogfood-2 (work): the hand-off is checked before its panel opens (HandOffCheck), an organising failure is put on
// the step it belongs to (OrganizeSteps), a job's reason for people is kept apart from its raw message (JobError),
// and sessions.py's refusals carry what the app needs to say them in words (SessionsError).
import Foundation
import XCTest
@testable import BlurtCore

final class WorkDogfoodTests: XCTestCase {
    typealias I = HandOffCheck.Item

    func testHandOffIsCheckedBeforeThePanelOpens() {
        let none: (String) -> Bool = { _ in false }
        // W30: everything discarded — a reason (with Restore), never a bare beep
        XCTAssertEqual(HandOffCheck.block([I(itemID: "HS-1", state: "discarded", projectID: "p")], isLive: none), .discarded)
        // to verify / done / won't do: reopen first
        XCTAssertEqual(HandOffCheck.block([I(itemID: "HS-1", state: "done", projectID: "p")], isLive: none), .finished(state: "done"))
        XCTAssertEqual(HandOffCheck.block([I(itemID: "HS-1", state: "to_verify", projectID: "p")], isLive: none), .finished(state: "to_verify"))
        // W33: in progress with a session still going → that session (never the panel with a raw bad_transition)
        let live = [I(itemID: "HS-2", state: "in_progress", projectID: "p", job: "j-1")]
        XCTAssertEqual(HandOffCheck.block(live, isLive: { $0 == "j-1" }), .withSession(itemID: "HS-2", job: "j-1"))
        // …and with a session that is over: it may go again (sessions.py takes it back first)
        XCTAssertNil(HandOffCheck.block(live, isLive: none))
        XCTAssertNil(HandOffCheck.block([I(itemID: "HS-3", state: "handed_off", projectID: "p", job: "j-9")], isLive: none))
        // a file that can't be read comes first; projects as before
        XCTAssertEqual(HandOffCheck.block([I(itemID: "A-4", state: "new", projectID: "p", unreadable: true)], isLive: none), .unreadable)
        XCTAssertEqual(HandOffCheck.block([I(itemID: "A-1", state: "new", projectID: "a"), I(itemID: "B-1", state: "todo", projectID: "b")],
                                          isLive: none), .mixedProjects)
        XCTAssertEqual(HandOffCheck.block([I(itemID: "IN-1", state: "new", projectID: "inbox")], isLive: none), .needsProject)
        XCTAssertNil(HandOffCheck.block([I(itemID: "A-1", state: "new", projectID: "a"), I(itemID: "A-2", state: "discarded", projectID: "b")],
                                        isLive: none))      // discarded ones are left out, not counted against the rest
        XCTAssertNil(HandOffCheck.block([], isLive: none))
    }

    func testAnOrganisingFailureIsPutOnItsOwnStep() {
        // W25: login, quota, network and model failures are the agent's, not transcription's
        for c in ["auth", "quota", "network", "model"] {
            let s = OrganizeSteps.onFailure(failureClass: c, transcribed: false)
            XCTAssertEqual(s.map(\.step), ["transcribe", "prepare"], c)
            XCTAssertEqual(s.map(\.state), [.pending, .failed], c)
        }
        let after = OrganizeSteps.onFailure(failureClass: "auth", transcribed: true)
        XCTAssertEqual(after.map(\.step), ["transcribe", "write"])
        XCTAssertEqual(after.map(\.state), [.done, .failed])
        XCTAssertEqual(OrganizeSteps.onFailure(failureClass: nil, transcribed: false).map(\.step), ["transcribe"])
    }

    func testAJobKeepsItsReasonForPeopleApartFromItsRawMessage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-workdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let o: [String: Any] = ["id": "j-1", "type": "process", "state": "failed", "created": "2026-10-25T10:00:00+08:00",
                                "error": ["code": "auth", "message": "exit 1: Traceback…", "hint_key": NSNull(),
                                          "reason": "Claude Code 登录失效了：在终端运行 claude，然后输入 /login"],
                                "organizer": ["agent": "codex", "instead_of": ["Claude Code 没登录"]]]
        let j = try XCTUnwrap(JobFold.job(o))
        XCTAssertEqual(j.error?.reason, "Claude Code 登录失效了：在终端运行 claude，然后输入 /login")
        XCTAssertEqual(j.error?.message, "exit 1: Traceback…")
        XCTAssertEqual(j.organizer?.agent, "codex")
        XCTAssertEqual(j.organizer?.insteadOf, ["Claude Code 没登录"])
        // the first agent did it: nothing to say
        XCTAssertNil(try XCTUnwrap(JobFold.job(["id": "j-2", "type": "process", "state": "done", "created": "2026-10-25T10:00:00+08:00",
                                                      "organizer": ["agent": "claude", "instead_of": []]])).organizer)
    }

    func testSessionsRefusalsCarryWhatTheAppSays() {
        let e = SessionsError(json: ["ok": false, "code": "auth", "error": "Claude Code isn't logged in — run claude",
                                     "agent": "claude", "fix": "在终端运行 claude，然后输入 /login"], fallback: "failed")
        XCTAssertEqual(e.code, "auth")
        XCTAssertEqual(e.agent, "claude")
        XCTAssertEqual(e.fix, "在终端运行 claude，然后输入 /login")
        let busy = SessionsError(json: ["ok": false, "code": "already_dispatched", "job": "j-1", "id": "HS-2"], fallback: "failed")
        XCTAssertEqual(busy.job, "j-1")
        XCTAssertEqual(busy.itemID, "HS-2")
        XCTAssertEqual(SessionsError(json: [:], fallback: "missing_dependency").code, "missing_dependency")
        XCTAssertNil(SessionsError(json: ["fix": "", "id": ""], fallback: "x").fix)
    }
}
