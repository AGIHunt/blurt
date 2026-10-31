// BlurtCore/Sessions/SessionOutcome.swift, the job fold's reported error, closed steps and ProcessGroup (dogfood v0.9):
// a session that failed at start says so and offers Restart, "Ready to review" only with changes, the ended banner
// is neutral with Open Session first, failed organising stays listed until retried or dismissed, and an organiser
// started in its own process group stops with everything it started — and a later launch stops a recorded group
// only while it is still that run's.
import Foundation
import XCTest
@testable import BlurtCore

final class SessionOutcomeTests: XCTestCase {
    func agentJob(state: String = "done", status: String = "exited", worktree: Bool = true, changes: [String: Int]? = nil,
                  started: Bool = true, finish: String? = nil, ended: String? = nil) -> Job {
        var a: [String: Any] = ["id": "codex", "status": status, "cwd": "/tmp", "started": started]
        if worktree { a["worktree"] = ["path": "/tmp/wt", "branch": "blurt/hs-1", "base": "main"] }
        if let c = changes { a["changes"] = c }
        if let f = finish { a["finish"] = ["action": f, "result": [:]] }
        var o: [String: Any] = ["id": "j-1", "type": "agent", "state": state, "created": "2026-10-25T10:00:00+08:00", "agent": a]
        if let e = ended { o["ended"] = e }
        return JobFold.job(o)!
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
        // an agent without hooks is "up" once its window opens; dying 4 s later is still not getting going
        XCTAssertEqual(SessionOutcome.of(agentJob(state: "failed", status: "error", changes: ["ahead": 0, "dirty": 0],
                                                  ended: "2026-10-25T10:00:04+08:00")), .failed(atStart: true))
        XCTAssertEqual(SessionOutcome.of(agentJob(worktree: false)), .ended)
        XCTAssertEqual(SessionOutcome.of(agentJob(changes: ["ahead": 3, "dirty": 0], finish: "merge")), .finished("merge"))
        // quit at its folder-trust question: it never started (dogfood W41), even with exit 0 and an empty worktree
        var trust = agentJob(changes: ["ahead": 0, "dirty": 0], started: false).raw
        trust["agent"] = (trust["agent"] as! [String: Any]).merging(["stopped_at": "trust"]) { $1 }
        let stopped = JobFold.job(trust)!
        XCTAssertTrue(stopped.stoppedAtTrust)
        XCTAssertEqual(SessionOutcome.of(stopped), .failed(atStart: true))
        // a startup question's hint is only read while it is live and waiting
        var waiting = agentJob(state: "running", status: "waiting_input").raw
        waiting["agent"] = (waiting["agent"] as! [String: Any]).merging(["waiting_hint": "hooks"]) { $1 }
        XCTAssertEqual(JobFold.job(waiting)!.waitingHint, "hooks")
        XCTAssertNil(agentJob().waitingHint)
        XCTAssertTrue(SessionOutcome.failed(atStart: true).canRestart)
        XCTAssertFalse(SessionOutcome.review.canRestart)
    }

    func testBannerPlan() {
        typealias P = SessionBannerPlan
        XCTAssertEqual(P.plan(.live(.running), outcome: nil), P(tone: .brand, actions: ["session"]))
        XCTAssertEqual(P.plan(.live(.waitingInput), outcome: nil), P(tone: .attn, actions: ["session"]))
        // ended without reporting back: neutral, Open Session first, never Mark Done as the primary; two buttons
        // inline at most, the rest in the ⋯ menu
        XCTAssertEqual(P.plan(.ended(.exited), outcome: .noChanges),
                       P(tone: .neutral, actions: ["session", "restart"], more: ["done", "take_back"]))
        XCTAssertEqual(P.plan(.ended(.exited), outcome: .finished("keep")),
                       P(tone: .neutral, actions: ["session", "done"], more: ["take_back"]))
        XCTAssertEqual(P.plan(.ended(.error), outcome: .failed(atStart: true)),
                       P(tone: .neutral, actions: ["restart", "take_back"], more: ["session"]))
        XCTAssertEqual(P.plan(.ended(.exited), outcome: .review), P(tone: .neutral, actions: ["review", "take_back"], more: ["done"]))
        XCTAssertEqual(P.plan(.gone, outcome: nil), P(tone: .neutral, actions: ["take_back", "done"]))
        // the watchdog gave up on it: it needs you, and it can start again
        XCTAssertEqual(P.plan(.live(.waitingInput), outcome: .live(.waitingInput), stalled: true),
                       P(tone: .attn, actions: ["session", "restart"], more: ["take_back"]))
        for w in [WorkSession.live(.running), .ended(.exited), .ended(.error), .gone] {
            for o in [SessionOutcome.review, .noChanges, .failed(atStart: true), .ended, .finished("keep")] {
                XCTAssertLessThanOrEqual(P.plan(w, outcome: o).actions.count, P.maxInline)
            }
        }
    }

    func testStalledIsTheWatchdogs() {
        var o: [String: Any] = ["id": "j-s", "type": "agent", "state": "running", "created": "2026-10-25T10:00:00+08:00",
                                "agent": ["id": "codex", "status": "waiting_input", "status_source": "watchdog", "cwd": "/tmp"]]
        XCTAssertTrue(JobFold.job(o)!.agent!.stalled)
        o["agent"] = ["id": "codex", "status": "waiting_input", "status_source": "tty", "cwd": "/tmp"]
        XCTAssertFalse(JobFold.job(o)!.agent!.stalled)
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

    /// Stop in the job's detail: an event marks the run cancelled; the killed agent's exit (a failure) or items it
    /// wrote anyway (done) don't undo that, and its steps close.
    func testAStoppedRunStaysStopped() {
        var job: [String: Any] = ["id": "j-3", "type": "process", "state": "running", "error": NSNull(),
                                  "steps": [["id": "prepare", "state": "done"], ["id": "transcribe", "state": "running"]]]
        JobFold.apply(["event": "stop", "state": "cancelled", "source": "user"], to: &job)
        XCTAssertEqual(JobFold.job(job)?.state, .cancelled)
        var failed = job
        JobFold.finishing(&failed, state: .failed, error: JobError(code: "unknown", message: "exit 143"), at: "t")
        XCTAssertEqual(JobFold.job(failed)?.state, .cancelled)
        XCTAssertNil(JobFold.job(failed)?.error)
        XCTAssertEqual((failed["steps"] as? [[String: Any]])?.map { $0["state"] as? String }, ["done", "failed"])
        XCTAssertEqual(failed["ended"] as? String, "t")
        var done = job
        JobFold.finishing(&done, state: .done, error: nil, at: "t")
        XCTAssertEqual(JobFold.job(done)?.state, .cancelled)
        // a run nobody stopped ends as its owner says
        var plain: [String: Any] = ["id": "j-4", "type": "process", "state": "running"]
        JobFold.finishing(&plain, state: .failed, error: JobError(code: "quota", message: "429"), at: "t")
        XCTAssertEqual(JobFold.job(plain)?.state, .failed)
        XCTAssertEqual(JobFold.job(plain)?.error?.code, "quota")
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

    /// A group a previous run recorded is stopped only while it is still that run's: a reused number is left alone.
    func testProcessGroupIsOursOnlyWhileItIsTheSameGroup() throws {
        let exited = expectation(description: "exit")
        let p = try ProcessGroup.spawn("/bin/sh", ["-c", "sleep 30 & wait"], env: ["PATH": "/usr/bin:/bin", "BLURT_JOB": "j-pg"],
                                       cwd: URL(fileURLWithPath: "/"), output: nil) { _ in exited.fulfill() }
        usleep(150_000)
        XCTAssertNotNil(p.started)
        XCTAssertEqual(ProcessGroup.startTime(p.pgid), p.started)
        XCTAssertTrue(ProcessGroup.members(p.pgid).contains(p.pgid))
        XCTAssertTrue(ProcessGroup.isOurs(p.pgid, started: p.started))
        XCTAssertFalse(ProcessGroup.isOurs(p.pgid, started: nil))                 // an older job: can't tell, leave it
        XCTAssertFalse(ProcessGroup.isOurs(p.pgid, started: p.started! - 5_000_000))   // same number, another group
        XCTAssertFalse(ProcessGroup.isOurs(getpgrp(), started: ProcessGroup.startTime(getpgrp())))   // never the app's own
        ProcessGroup.stop(p.pgid, grace: 1)
        wait(for: [exited], timeout: 5)
        XCTAssertFalse(ProcessGroup.isOurs(p.pgid, started: p.started))                   // gone
    }

    /// The leader (zsh) gone, the agent it started still running: that is still the run's group.
    func testProcessGroupWithoutItsLeaderIsStillOurs() throws {
        let exited = expectation(description: "exit")
        let p = try ProcessGroup.spawn("/bin/sh", ["-c", "sleep 30 >/dev/null 2>&1 & exit 0"], env: ["PATH": "/usr/bin:/bin"],
                                       cwd: URL(fileURLWithPath: "/"), output: nil) { _ in exited.fulfill() }
        wait(for: [exited], timeout: 5)
        for _ in 0..<50 where ProcessGroup.startTime(p.pgid) != nil { usleep(20_000) }
        XCTAssertNil(ProcessGroup.startTime(p.pgid))
        XCTAssertTrue(ProcessGroup.alive(p.pgid))
        XCTAssertTrue(ProcessGroup.isOurs(p.pgid, started: p.started))
        XCTAssertFalse(ProcessGroup.isOurs(p.pgid, started: UInt64(Date().timeIntervalSince1970 * 1_000_000) + 60_000_000))
        ProcessGroup.stop(p.pgid, grace: 1)
        XCTAssertFalse(ProcessGroup.alive(p.pgid))
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
