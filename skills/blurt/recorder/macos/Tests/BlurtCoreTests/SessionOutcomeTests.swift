// BlurtCore/Sessions/SessionOutcome.swift, the job fold's reported error, closed steps and ProcessGroup (dogfood v0.9):
// a session that failed at start says so and offers Restart, "Ready to review" only with changes, the ended banner
// is neutral with Open Session first, failed organising stays listed until retried or dismissed, and an organiser
// started in its own process group stops with everything it started.
import Foundation
import XCTest
@testable import BlurtCore

final class SessionOutcomeTests: XCTestCase {
    func agentJob(state: String = "done", status: String = "exited", worktree: Bool = true, changes: [String: Int]? = nil,
                  started: Bool = true, finish: String? = nil) -> Job {
        var a: [String: Any] = ["id": "codex", "status": status, "cwd": "/tmp", "started": started]
        if worktree { a["worktree"] = ["path": "/tmp/wt", "branch": "blurt/hs-1", "base": "main"] }
        if let c = changes { a["changes"] = c }
        if let f = finish { a["finish"] = ["action": f, "result": [:]] }
        return JobFold.job(["id": "j-1", "type": "agent", "state": state, "created": "2026-10-25T10:00:00+08:00", "agent": a])!
    }

    func testOutcome() {
        XCTAssertEqual(SessionOutcome.of(agentJob(state: "running", status: "turn_done")), .live(.turnDone))
        XCTAssertEqual(SessionOutcome.of(agentJob(changes: ["ahead": 1, "dirty": 0])), .review)
        XCTAssertEqual(SessionOutcome.of(agentJob(changes: ["ahead": 0, "dirty": 2])), .review)    // Blurt commits it
        XCTAssertEqual(SessionOutcome.of(agentJob()), .review)                                     // not known: offer it
        XCTAssertEqual(SessionOutcome.of(agentJob(changes: ["ahead": 0, "dirty": 0])), .noChanges)
        XCTAssertEqual(SessionOutcome.of(agentJob(state: "failed", status: "error", changes: ["ahead": 0, "dirty": 0], started: false)),
                       .failed(atStart: true))
        XCTAssertEqual(SessionOutcome.of(agentJob(state: "failed", status: "error", changes: ["ahead": 0, "dirty": 0])),
                       .failed(atStart: false))
        XCTAssertEqual(SessionOutcome.of(agentJob(worktree: false)), .ended)
        XCTAssertEqual(SessionOutcome.of(agentJob(changes: ["ahead": 3, "dirty": 0], finish: "merge")), .finished("merge"))
        XCTAssertTrue(SessionOutcome.failed(atStart: true).canRestart)
        XCTAssertFalse(SessionOutcome.review.canRestart)
    }

    func testBannerPlan() {
        typealias P = SessionBannerPlan
        XCTAssertEqual(P.plan(.live(.running), outcome: nil), P(tone: .brand, actions: ["session"]))
        XCTAssertEqual(P.plan(.live(.waitingInput), outcome: nil), P(tone: .attn, actions: ["session"]))
        // ended without reporting back: neutral, Open Session first, never Mark Done as the primary
        XCTAssertEqual(P.plan(.ended(.exited), outcome: .noChanges), P(tone: .neutral, actions: ["session", "restart", "done", "take_back"]))
        XCTAssertEqual(P.plan(.ended(.exited), outcome: .finished("keep")), P(tone: .neutral, actions: ["session", "done", "take_back"]))
        XCTAssertEqual(P.plan(.ended(.error), outcome: .failed(atStart: true)), P(tone: .neutral, actions: ["restart", "take_back", "session"]))
        XCTAssertEqual(P.plan(.ended(.exited), outcome: .review), P(tone: .neutral, actions: ["review", "take_back", "done"]))
        XCTAssertEqual(P.plan(.gone, outcome: nil), P(tone: .neutral, actions: ["take_back", "done"]))
    }

    func testReportedErrorIsFolded() {
        var job: [String: Any] = ["id": "j-2", "type": "process", "state": "running", "error": NSNull()]
        JobFold.apply(["event": "finish", "state": "failed", "detail": ["error": ["code": "quota", "message": "429"]]], to: &job)
        XCTAssertEqual(JobFold.job(job)?.error?.code, "quota")
        // the owner's own reason stays
        JobFold.apply(["event": "finish", "state": "failed", "detail": ["error": ["code": "network", "message": "x"]]], to: &job)
        XCTAssertEqual(JobFold.job(job)?.error?.message, "429")
    }

    func testCloseSteps() {
        let out = JobFold.closeSteps([["id": "prepare", "state": "done"], ["id": "transcribe", "state": "running"],
                                      ["id": "write", "state": "pending"]], at: "t")
        XCTAssertEqual(out.map { $0["state"] as? String }, ["done", "failed", "skipped"])
        XCTAssertEqual(out[1]["ended"] as? String, "t")
    }

    func testFailuresStayUntilRetriedOrDismissed() {
        func job(_ id: String, _ state: String, created: String, session: String? = "/s/a", dismissed: Bool = false) -> Job {
            var o: [String: Any] = ["id": id, "type": "process", "state": state, "created": created, "ended": created,
                                    "dismissed": dismissed]
            if let s = session { o["session"] = s }
            return JobFold.job(o)!
        }
        let now = JobFold.date("2026-10-25T12:00:00+08:00")!
        let old = job("j-old", "failed", created: "2026-10-10T10:00:00+08:00", session: "/s/old")
        let failed = job("j-a", "failed", created: "2026-10-25T10:00:00+08:00")
        let gone = job("j-d", "failed", created: "2026-10-25T10:00:00+08:00", session: "/s/d", dismissed: true)
        let other = job("j-b", "failed", created: "2026-10-25T10:00:00+08:00", session: "/s/b")
        XCTAssertEqual(JobFailures.waiting([failed, gone, old, other], now: now).map(\.id), ["j-a", "j-b"])
        let retry = job("j-a2", "running", created: "2026-10-25T11:00:00+08:00")
        XCTAssertEqual(JobFailures.waiting([retry, failed, other], now: now).map(\.id), ["j-b"])   // the retry replaced it
    }

    func testProcessGroupStopsEverythingItStarted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exited = expectation(description: "exit")
        var status: Int32 = -1
        // the leader starts a grandchild, as zsh starts the agent
        let p = try ProcessGroup.spawn("/bin/sh", ["-c", "sleep 30 & echo $! > child; wait"], env: ["PATH": "/usr/bin:/bin"],
                                       cwd: dir, output: nil) { status = $0; exited.fulfill() }
        let childFile = dir.appendingPathComponent("child")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: childFile.path) { usleep(20_000) }
        usleep(50_000)
        let child = pid_t(try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        XCTAssertEqual(getpgid(child), p.pgid)
        XCTAssertTrue(ProcessGroup.alive(p.pgid))
        ProcessGroup.stop(p.pgid, grace: 1)
        wait(for: [exited], timeout: 5)
        XCTAssertEqual(status, 128 + SIGTERM)
        XCTAssertFalse(ProcessGroup.alive(p.pgid))
        XCTAssertNotEqual(kill(child, 0), 0)
    }

    func testProcessGroupExitStatus() throws {
        let exited = expectation(description: "exit")
        var status: Int32 = -1
        _ = try ProcessGroup.spawn("/bin/sh", ["-c", "exit 3"], env: [:], cwd: URL(fileURLWithPath: "/"), output: nil) {
            status = $0; exited.fulfill()
        }
        wait(for: [exited], timeout: 5)
        XCTAssertEqual(status, 3)
        XCTAssertThrowsError(try ProcessGroup.spawn("/nonexistent/tool", [], env: [:], cwd: URL(fileURLWithPath: "/"), output: nil) { _ in })
    }
}
