// How an agent session stands, in the words every surface uses (the session list, the pane's ended card, the item's
// banner): still going, failed (at start or later), ended with changes to review, ended with nothing to review, or
// finished by the user (merged, PR, discarded, kept, restarted). And what the item's banner offers for each.
import Foundation

public enum SessionOutcome: Equatable {
    /// running, waiting for you or between turns
    case live(AgentSessionStatus)
    /// the user decided: merge | pr | discard | keep | restart
    case finished(String)
    /// ended, and its worktree has something to merge, turn into a PR or discard (a failed agent may have left work)
    case review
    /// it couldn't work: a non-zero exit, or a screen it can't get past (not logged in). atStart = it never got going
    case failed(atStart: Bool)
    /// ended in a worktree that has nothing on it
    case noChanges
    /// ended in the project folder (nothing for Blurt to merge)
    case ended

    /// A session that fails within this long of starting "couldn't start".
    public static let startupWindow: TimeInterval = 20

    public static func of(_ j: Job) -> SessionOutcome {
        guard let a = j.agent else { return .ended }
        if let f = a.finishAction { return .finished(f) }
        if j.isActive, a.status != .exited, a.status != .error { return .live(a.status) }
        // it quit at its own folder-trust question (sessions.py agent.stopped_at): it never started — start it again
        // or take the items back, never "ended without reporting back"
        if j.stoppedAtTrust, !a.hasChanges { return .failed(atStart: true) }
        if a.hasChanges { return .review }
        if a.status == .error || j.state == .failed {
            // it never got going: no hook or screen said it was up, or it died within its first moments (an agent
            // without hooks counts as up as soon as its window opens)
            let lived = (j.ended ?? Date()).timeIntervalSince(j.started ?? j.created)
            return .failed(atStart: !a.started || lived < startupWindow)
        }
        return a.worktree != nil ? .noChanges : .ended
    }

    /// Ended, and the same items can simply be started again (nothing of it to keep).
    public var canRestart: Bool {
        switch self {
        case .failed, .noChanges, .ended: return true
        default: return false
        }
    }
}

/// The item banner of an item handed to a session: its tone, its inline buttons (action ids the banner sends; the
/// first one the primary — two at most, so the line keeps its words at a detail's width) and the rest in its ⋯ menu.
/// `brand` while the agent works for you (system.md §1.1), `attn` when it needs you, `neutral` once the session is
/// over and the user decides.
public struct SessionBannerPlan: Equatable {
    public enum Tone: Equatable { case brand, attn, neutral }
    public let tone: Tone
    public let actions: [String]
    /// What the ⋯ menu beside the buttons offers.
    public let more: [String]

    public static let maxInline = 2

    public init(tone: Tone, actions: [String], more: [String] = []) { self.tone = tone; self.actions = actions; self.more = more }

    /// `work`: the item's session (WorkSession.of); `outcome`: its job's (nil when the job is gone); `stalled`: the
    /// watchdog says it isn't responding (AgentInfo.stalled); `desktop`: it runs in the agent's desktop app
    /// (AgentInfo.isDesktop), where nothing here is live — Go to Claude, and its worktree's changes when it has one.
    /// `reports` false: the desktop app has no blurt MCP, so nothing will ever move the item — marking it done is the
    /// user's, right there next to Go to Claude.
    public static func plan(_ work: WorkSession, outcome: SessionOutcome?, stalled: Bool = false, desktop: Bool = false,
                            worktree: Bool = false, reports: Bool = true) -> SessionBannerPlan {
        switch work {
        case .live where desktop:
            return SessionBannerPlan(tone: reports ? .brand : .neutral, actions: reports ? ["desktop"] : ["desktop", "done"],
                                     more: ["session"] + (worktree ? ["review"] : []) + ["take_back"])
        case .live(let st):
            // no response for a minute: look at it, or start it again
            if stalled { return SessionBannerPlan(tone: .attn, actions: ["session", "restart"], more: ["take_back"]) }
            return SessionBannerPlan(tone: st == .waitingInput ? .attn : .brand, actions: ["session"])
        case .gone:
            return SessionBannerPlan(tone: .neutral, actions: ["take_back", "done"])
        case .ended:
            switch outcome {
            case .failed?:
                // it couldn't start or crashed with nothing done: start it again, or take the items back
                return SessionBannerPlan(tone: .neutral, actions: ["restart", "take_back"], more: ["session"])
            case .review?:
                return SessionBannerPlan(tone: .neutral, actions: ["review", "take_back"], more: ["done"])
            default:
                // it ended without saying the items are done: see what it did first, then decide
                return outcome?.canRestart == true
                    ? SessionBannerPlan(tone: .neutral, actions: ["session", "restart"], more: ["done", "take_back"])
                    : SessionBannerPlan(tone: .neutral, actions: ["session", "done"], more: ["take_back"])
            }
        }
    }
}

/// The jobs section's failures (K4): organising or routing that failed in the last week stays listed — a recording
/// whose organising failed has no items to reach it from — until it is dismissed, retried (a newer job for the same
/// recording) or old.
public enum JobFailures {
    public static let keep: TimeInterval = 7 * 24 * 3600

    public static func waiting(_ jobs: [Job], now: Date = Date()) -> [Job] {
        jobs.filter { j in
            guard j.state == .failed, j.type == .process || j.type == .route, !j.dismissed,
                  now.timeIntervalSince(j.ended ?? j.created) < keep else { return false }
            // a later run for the same recording (or the same items) replaced it
            return !jobs.contains { o in
                o.id != j.id && o.type == j.type && o.created > j.created
                    && (j.session.map { o.session?.path == $0.path } ?? (!j.items.isEmpty && Set(o.items) == Set(j.items)))
            }
        }
    }
}

extension Job {
    /// The agent quit at its folder-trust question, before any of its hooks spoke (sessions.py agent.stopped_at).
    public var stoppedAtTrust: Bool { (raw["agent"] as? [String: Any])?["stopped_at"] as? String == "trust" }
    /// The startup question its terminal shows now, while its hooks haven't spoken: "trust" (the folder) or "hooks"
    /// (Codex's hook review) — sessions.py agent.waiting_hint. nil for any other question.
    public var waitingHint: String? {
        guard isActive, agent?.status == .waitingInput else { return nil }
        return (raw["agent"] as? [String: Any])?["waiting_hint"] as? String
    }
}
