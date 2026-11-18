// dogfood-2 (work): an organising failure is put on the step it belongs to (OrganizeSteps), a job's reason for people
// is kept apart from its raw message (JobError), and scan findings are said once.
import Foundation
import XCTest
@testable import BlurtCore

final class WorkDogfoodTests: XCTestCase {
    func testAnOrganisingFailureIsPutOnItsOwnStep() {
        // W25: login, quota, network and model failures are the agent's, not transcription's
        for c in ["auth", "quota", "network", "model"] {
            let s = OrganizeSteps.onFailure(failureClass: c, transcribed: false)
            XCTAssertEqual(s.map(\.step), ["transcribe", "prepare"], c)
            XCTAssertEqual(s.map(\.state), [.pending, .failed], c)
        }
        // review: a login / network failure on a recording already transcribed (Retry, a fallback) is still the
        // agent's, never "writing items failed"
        let after = OrganizeSteps.onFailure(failureClass: "auth", transcribed: true)
        XCTAssertEqual(after.map(\.step), ["transcribe", "prepare"])
        XCTAssertEqual(after.map(\.state), [.done, .failed])
        let written = OrganizeSteps.onFailure(failureClass: "agent_exit", transcribed: true)
        XCTAssertEqual(written.map(\.step), ["transcribe", "write"])
        XCTAssertEqual(written.map(\.state), [.done, .failed])
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

    func testScanFindingsAreSaidOncePerRunAndSkippedFilesToo() {
        var told = ScanFindings.Told()
        let report: [String: Any] = [
            "unreadable": [["uid": "U1", "id": "AW-6", "path": "/r/.blurt/items/AW-6.md"]],
            "skipped": [["path": "/r/.blurt/items/AW-7.md", "error": "IntegrityError: UNIQUE constraint failed"]],
        ]
        let first = ScanFindings.fresh(in: report, told: &told)
        XCTAssertEqual(first.unreadable, [ScanFindings.File(path: "/r/.blurt/items/AW-6.md", uid: "U1", id: "AW-6")])
        XCTAssertEqual(first.skipped.map(\.path), ["/r/.blurt/items/AW-7.md"])   // review: skipped files are told too
        XCTAssertTrue(ScanFindings.fresh(in: report, told: &told).isEmpty)          // the next scan: nothing new to say
        var more = report
        more["skipped"] = [["path": "/r/.blurt/items/AW-7.md"], ["path": "/r/.blurt/items/AW-8.md"]]
        XCTAssertEqual(ScanFindings.fresh(in: more, told: &told).skipped.map(\.path), ["/r/.blurt/items/AW-8.md"])
    }
}
