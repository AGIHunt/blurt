// Hand-offs to the agent's desktop app (BlurtCore: DesktopLink, HandoffTarget, DesktopContinue, the banner plan):
// only claude:// links are ever opened from a sessions.py answer, the choice is remembered per agent and falls back
// to the terminal when the app is missing, the item banner says Go to Claude with nothing live, Continue in Claude
// Desktop shows only where its check said yes, and a job's agent fields (title, conversation id, where it came from)
// are read from the job file.
import Foundation
import XCTest
@testable import BlurtCore

final class DesktopHandoffTests: XCTestCase {
    func job(runner: String = "desktop", state: String = "running", status: String = "running", worktree: Bool = true,
             extra: [String: Any] = [:]) -> Job {
        var a: [String: Any] = ["id": "claude", "runner": runner, "status": status, "status_source": "desktop", "cwd": "/tmp"]
        if worktree { a["worktree"] = ["path": "/tmp/wt", "branch": "blurt/aw-12", "base": "main"] }
        a.merge(extra) { _, n in n }
        return JobFold.job(["id": "j-1", "type": "agent", "state": state, "created": "2026-10-25T10:00:00+08:00", "agent": a])!
    }

    func testOnlyTheDesktopSchemeIsOpened() {
        let s = "claude://code/new?folder=%2FUsers%2Fme%2Fapp%20wt&q=AW-12%20%C2%B7%20Fix%0A%0ARead%20%26%20do"
        let u = DesktopLink.url(s)
        XCTAssertNotNil(u)
        let p = DesktopLink.parts(u!)
        XCTAssertEqual(p.folder, "/Users/me/app wt")
        XCTAssertEqual(p.prompt, "AW-12 · Fix\n\nRead & do")
        for bad in ["https://claude.ai/code/new?q=x", "file:///etc/passwd", "javascript:alert(1)", "", "not a url", "claude-cli://open?q=x"] {
            XCTAssertNil(DesktopLink.url(bad), bad)
        }
        XCTAssertNil(DesktopLink.url(nil))
        let rows: [[String: Any]] = [["id": "j-1", "url": s], ["id": "j-2", "url": "https://evil.example/x"], ["id": "j-3"]]
        XCTAssertEqual(AgentSessions.links(rows).map(\.job), ["j-1"])
    }

    func testTargetIsRememberedPerAgent() {
        XCTAssertEqual(HandoffTarget.resolve(nil, agent: "claude", available: true), .terminal)        // the default
        let saved = HandoffTarget.store(nil, agent: "claude", target: .desktop)
        XCTAssertEqual(saved["claude"] as? String, "desktop")
        XCTAssertEqual(HandoffTarget.resolve(saved, agent: "claude", available: true), .desktop)
        XCTAssertEqual(HandoffTarget.resolve(saved, agent: "codex", available: true), .terminal)      // per agent
        XCTAssertEqual(HandoffTarget.resolve(saved, agent: "claude", available: false), .terminal)    // app gone
        XCTAssertEqual(HandoffTarget.resolve(["claude": "moon"], agent: "claude", available: true), .terminal)
        let back = HandoffTarget.store(saved, agent: "claude", target: .terminal)
        XCTAssertNil(back["claude"])                                                                  // stored as nothing
        let two = HandoffTarget.store(["codex": "desktop"], agent: "claude", target: .desktop)
        XCTAssertEqual(two.count, 2)
    }

    func testJobFields() {
        let j = job(extra: ["title": "AW-12 · Fix (Blurt hand-off)", "agent_session_id": "s-1", "continued": ["from": "tmux"]])
        XCTAssertTrue(j.agent!.isDesktop)
        XCTAssertEqual(j.agent!.title, "AW-12 · Fix (Blurt hand-off)")
        XCTAssertEqual(j.agent!.agentSessionID, "s-1")
        XCTAssertEqual(j.agent!.continuedFrom, "tmux")
        XCTAssertFalse(job(runner: "tmux").agent!.isDesktop)
        XCTAssertNil(job(runner: "tmux").agent!.continuedFrom)
        // no blurt MCP for the desktop app: the card says to mark the items by hand; unknown says nothing
        XCTAssertTrue(job(extra: ["desktop": ["mcp": false]]).agent!.desktopNeedsMarking)
        XCTAssertFalse(job(extra: ["desktop": ["mcp": true]]).agent!.desktopNeedsMarking)
        XCTAssertFalse(job().agent!.desktopNeedsMarking)
        XCTAssertNil(job().agent!.desktopMCP)
        XCTAssertFalse(job(runner: "tmux", extra: ["desktop": ["mcp": false]]).agent!.desktopNeedsMarking)
    }

    /// A desktop session goes on elsewhere: no spinner, and not in the list's running count. A Continue that failed
    /// turned the job back into an ended terminal one (sessions.py), so it is neither.
    func testDesktopSessionsDontCountAsRunningHere() {
        let desk = job(), term = job(runner: "tmux"), ended = job(state: "done", status: "exited")
        XCTAssertTrue(desk.inDesktop)
        XCTAssertFalse(term.inDesktop)
        XCTAssertFalse(ended.inDesktop)
        XCTAssertEqual(Job.runningHere([desk, term, ended]), 1)
        let failedContinue = job(runner: "tmux", state: "failed", status: "error",
                                 extra: ["continued": ["from": "tmux", "failed": "exit 2"], "agent_session_id": "s-1"])
        XCTAssertFalse(failedContinue.agent!.isDesktop)
        XCTAssertFalse(failedContinue.inDesktop)
        XCTAssertFalse(DesktopContinue.offered(failedContinue.agent!, alive: failedContinue.isActive, supported: true,
                                               check: DesktopContinueCheck(available: true, reason: nil, version: "t")))
        // the check carries whether the blurt MCP is there (the confirmation's no-MCP wording); default unknown
        XCTAssertNil(DesktopContinueCheck(available: true, reason: nil, version: "t").mcp)
        XCTAssertEqual(DesktopContinueCheck(available: true, reason: nil, version: "t", mcp: false).mcp, false)
    }

    func testBannerSaysGoToClaudeWhileItRunsThere() {
        let j = job()
        let work = WorkSession.of(state: "handed_off", to: "session", job: "j-1") { _ in j }
        XCTAssertEqual(work, .live(.running))
        let plan = SessionBannerPlan.plan(work!, outcome: SessionOutcome.of(j), desktop: true, worktree: true)
        XCTAssertEqual(plan, SessionBannerPlan(tone: .brand, actions: ["desktop"], more: ["session", "review", "take_back"]))
        XCTAssertEqual(SessionBannerPlan.plan(.live(.running), outcome: nil, desktop: true, worktree: false).more, ["session", "take_back"])
        // once its items are reported the job ends: the ordinary ended plans (Review Changes… with changes)
        let ended = job(state: "done", status: "exited", extra: ["changes": ["ahead": 1, "dirty": 0]])
        let w2 = WorkSession.of(state: "in_progress", to: "session", job: "j-1") { _ in ended }!
        XCTAssertEqual(SessionBannerPlan.plan(w2, outcome: SessionOutcome.of(ended), desktop: true, worktree: true).actions,
                       ["review", "take_back"])
        // a terminal session is untouched by the flag being false
        XCTAssertEqual(SessionBannerPlan.plan(.live(.waitingInput), outcome: nil).actions, ["session"])
        // no blurt MCP there (dogfood-2 W35): nothing will report, so the banner doesn't promise progress — it is
        // quiet, and marking it done sits next to Go to Claude
        XCTAssertEqual(SessionBannerPlan.plan(.live(.running), outcome: nil, desktop: true, worktree: true, reports: false),
                       SessionBannerPlan(tone: .neutral, actions: ["desktop", "done"], more: ["session", "review", "take_back"]))
    }

    func testContinueIsOfferedOnlyWhereItWorks() {
        let ok = DesktopContinueCheck(available: true, reason: nil, version: "2.1.290 (Claude Code)")
        let old = DesktopContinueCheck(available: false, reason: "version", version: "2.1.259 (Claude Code)")
        let tmux = job(runner: "tmux", extra: ["agent_session_id": "s-1"]).agent!
        XCTAssertTrue(DesktopContinue.offered(tmux, alive: true, supported: true, check: ok))
        XCTAssertFalse(DesktopContinue.offered(tmux, alive: true, supported: true, check: old))
        XCTAssertFalse(DesktopContinue.offered(tmux, alive: true, supported: true, check: nil))       // not asked yet
        XCTAssertFalse(DesktopContinue.offered(tmux, alive: false, supported: true, check: ok))
        XCTAssertFalse(DesktopContinue.offered(tmux, alive: true, supported: false, check: ok))       // codex
        XCTAssertFalse(DesktopContinue.offered(job(runner: "tmux").agent!, alive: true, supported: true, check: ok))  // no id
        XCTAssertFalse(DesktopContinue.offered(job(extra: ["agent_session_id": "s-1"]).agent!, alive: true, supported: true, check: ok))
        XCTAssertFalse(DesktopContinue.offered(job(runner: "app", extra: ["agent_session_id": "s-1"]).agent!, alive: true,
                                               supported: true, check: ok))
    }
}
