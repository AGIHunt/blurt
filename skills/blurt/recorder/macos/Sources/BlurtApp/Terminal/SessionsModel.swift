// The agent sessions the app shows: every `agent` job (K4/K5) from JobStore, live — hooks and the tmux monitor append
// to the job's events, JobStore folds them, this model re-groups by project. Item labels ("BA-12 · Login button does
// nothing") come from the session's hand-off sheet (K6), so nothing here depends on the index.
import AppKit
import SwiftUI
import BlurtCore

struct SessionItemLabel: Hashable {
    let id: String          // BA-12
    let title: String
}

/// One mark per state, the same in the list, the header and the ended card (system.md §3.3, the island's rule): the
/// spinner while the agent works; the attention "!" whenever it is the user's move — a question, a finished turn
/// waiting for the next prompt, changes ready to review; the ok check only once it is merged or a pull request is
/// open; the error "×" when it failed; a hollow ring when it is over with nothing to do; an outward arrow when it goes on
/// in the agent's desktop app.
enum SessionMark: Equatable { case working, waiting, done, failed, idle, elsewhere }

struct AgentSessionRow: Identifiable {
    let job: Job
    let agent: AgentInfo
    let projectID: String
    let projectName: String
    let items: [SessionItemLabel]
    /// Ready to review, but its worktree's folder is gone (deleted outside Blurt): nothing left to review.
    var folderGone = false

    var id: String { job.id }
    /// Once the user decided (merged, restarted, discarded…), a failure is past news: the quiet mark of an ended one.
    var status: AgentSessionStatus {
        if agent.finishAction != nil { return .exited }
        return job.isActive ? agent.status : (agent.status == .error || job.state == .failed ? .error : .exited)
    }
    var alive: Bool { job.isActive }
    /// Going on in the agent's desktop app: nothing runs here, so no spinner and not in the "running" count.
    var inDesktop: Bool { job.inDesktop }
    /// "BA-12, BA-13" — the tmux window's name, else the item ids
    var label: String {
        if let n = agent.windowName, !n.isEmpty { return n.replacingOccurrences(of: ",", with: ", ") }
        if !items.isEmpty { return items.map(\.id).joined(separator: ", ") }
        return job.title ?? ""
    }
    /// The first item's title (else the job's title), the line under the label.
    var subtitle: String {
        guard let first = items.first else { return job.title ?? "" }
        return items.count > 1 ? TL("session.items.more", first.title, items.count - 1) : first.title
    }
    var agentName: String { AgentNames.name(agent.agent) }
    /// When it started — the moment the item list shows for the same hand-off.
    var since: Date { job.started ?? job.created }
    var outcome: SessionOutcome { SessionOutcome.of(job) }
    /// Ended with changes on its branch that haven't been merged, turned into a PR or discarded yet.
    var awaitsFinish: Bool { outcome == .review }
    var isAppRunner: Bool { agent.runner == "app" }
    /// Its window is still there to read (Show Output): not once merged, discarded or restarted (the window went).
    var hasOutput: Bool {
        (agent.tmuxWindow != nil || isAppRunner) && !["merge", "discard", "restart", "take_back"].contains(agent.finishAction ?? "")
    }
    /// What the list and the header say about it: its live status, else how it ended ("Ready to review" only when
    /// there is something to review).
    var stateText: String { folderGone ? TL("row.folder_gone") : Self.stateText(job) }

    var mark: SessionMark {
        if inDesktop && alive { return .elsewhere }
        switch outcome {
        case .live(let st):
            if agent.stalled { return .waiting }
            switch st {
            case .running: return .working
            case .waitingInput, .turnDone: return .waiting
            case .error: return .failed
            case .exited: return .idle
            }
        case .review: return .waiting
        case .failed: return .failed
        case .finished(let f): return f == "merge" || f == "pr" ? .done : .idle
        case .noChanges, .ended: return .idle
        }
    }
    /// It's the user's move (the attention mark) or it failed: never dimmed.
    var needsYou: Bool { mark == .waiting || mark == .failed }

    /// The words' ink: attention ink when it waits on you, the error ink when it failed, else secondary (never under
    /// the readable floor, §2.4).
    var stateColor: Color {
        switch mark {
        case .waiting: return .brandAttnInk
        case .failed: return .brandErr
        default: return .secondary
        }
    }

    /// The one wording of a session's state, wherever it shows (the list, the pane header, the ended card's row, the
    /// job detail's line): its live status — "No response" once the watchdog gave up on it — else how it ended.
    static func stateText(_ job: Job) -> String {
        guard let agent = job.agent else { return "" }
        switch SessionOutcome.of(job) {
        case .live where agent.isDesktop:
            return TL(agent.desktopNeedsMarking ? "row.desktop.no_mcp" : "row.desktop", DesktopApp.name(agent.agent))
        case .live(let st): return agent.stalled ? TL("row.no_response") : st.title
        case .review: return TL("row.ready_to_review")
        case .failed(let atStart): return atStart ? TL("row.failed_start") : TL("row.failed")
        case .noChanges: return TL("row.no_changes")
        case .ended: return AgentSessionStatus.exited.title
        case .finished(let f):
            // "pr" without a pull request url = only pushed (no gh, or a host it doesn't know)
            return TL(f == "pr" && agent.finishResult?["pr"] as? String == nil ? "finish.state.pushed" : "finish.state.\(f)")
        }
    }
}

struct AgentSessionGroup: Identifiable {
    let id: String          // project id
    let name: String
    let rows: [AgentSessionRow]
}

/// agents.json display names ("claude" → "Claude Code").
enum AgentNames {
    private static var cache: [String: String]?
    static func name(_ id: String) -> String {
        if cache == nil {
            var m: [String: String] = [:]
            var urls = [BlurtPaths.scripts.appendingPathComponent("agents.json")]
            if let u = Bundle.main.url(forResource: "agents", withExtension: "json") { urls.append(u) }
            for u in urls {
                guard let d = try? Data(contentsOf: u), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                for a in o["agents"] as? [[String: Any]] ?? [] {
                    if let i = a["id"] as? String, let n = a["name"] as? String { m[i] = n }
                }
                break
            }
            cache = m
        }
        let custom = ((Config.shared["record.agent_defs"] as? [String: Any])?[id] as? [String: Any])?["name"] as? String
        return custom ?? cache?[id] ?? (id == "human" ? TL("agent.you") : id.capitalized)
    }
}

/// $BLURT_HOME/handoff/<H-id>.md → its "## 1. BA-12 · Title" headings.
enum HandoffLabels {
    private static var cache: [String: [SessionItemLabel]] = [:]
    static func labels(_ handoff: String?) -> [SessionItemLabel] {
        guard let h = handoff, !h.isEmpty else { return [] }
        if let c = cache[h] { return c }
        let url = BlurtPaths.home.appendingPathComponent("handoff/\(h).md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [SessionItemLabel] = []
        let re = try! NSRegularExpression(pattern: #"^##\s+\d+\.\s+(\S+)\s+·\s+(.+?)\s*$"#)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix("## ") {
            let s = String(line)
            guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s) else { continue }
            out.append(SessionItemLabel(id: String(s[a]), title: String(s[b])))
        }
        if !out.isEmpty { cache[h] = out }
        return out
    }
}

@MainActor
final class SessionsModel: ObservableObject {
    static let shared = SessionsModel()

    @Published private(set) var groups: [AgentSessionGroup] = []
    @Published private(set) var rows: [AgentSessionRow] = []
    private var token: UUID?

    /// Ended sessions stay listed this long (worktrees waiting for merge / PR / discard stay until finished).
    static let keepEnded: TimeInterval = 24 * 3600

    func start() {
        guard token == nil else { return }
        JobStore.shared.start()
        token = JobStore.shared.addObserver { [weak self] _ in MainActor.assumeIsolated { self?.rebuild() } }
        rebuild()
    }

    func row(_ job: String) -> AgentSessionRow? { rows.first { $0.id == job } }

    var alive: [AgentSessionRow] { rows.filter(\.alive) }

    /// The session to show when a pane opens with no choice: the one that needs the user, else the newest live one.
    var preferred: AgentSessionRow? {
        alive.min { ($0.status.urgency, -$0.since.timeIntervalSince1970) < ($1.status.urgency, -$1.since.timeIntervalSince1970) }
            ?? rows.first
    }

    func rebuild() {
        let now = Date()
        let store = ProjectStore.shared
        var out: [AgentSessionRow] = []
        for j in JobStore.shared.jobs where j.type == .agent {
            guard let a = j.agent else { continue }
            let keep = j.isActive || (a.worktree != nil && a.finishAction == nil)
                || now.timeIntervalSince(j.ended ?? j.updated ?? j.created) < Self.keepEnded
            guard keep else { continue }
            let pid = j.project ?? "inbox"
            let name = store.project(id: pid)?.name ?? (pid == "inbox" ? store.inbox.name
                : pid == AgentSetup.project ? M("models.agent.session") : a.cwd.lastPathComponent)
            guard !PaneMemory.removed().contains(j.id) else { continue }       // Remove Session (its folder was gone)
            var row = AgentSessionRow(job: j, agent: a, projectID: pid, projectName: name, items: HandoffLabels.labels(a.handoff))
            if row.outcome == .review, let wt = a.worktree { row.folderGone = !FileManager.default.fileExists(atPath: wt.path) }
            out.append(row)
        }
        // live first (the one that needs you on top), then ended newest first
        out.sort { l, r in
            if l.alive != r.alive { return l.alive }
            if l.alive, l.status.urgency != r.status.urgency { return l.status.urgency < r.status.urgency }
            return l.job.created > r.job.created
        }
        rows = out
        var order: [String] = []
        var by: [String: [AgentSessionRow]] = [:]
        for r in out {
            if by[r.projectID] == nil { order.append(r.projectID) }
            by[r.projectID, default: []].append(r)
        }
        groups = order.map { AgentSessionGroup(id: $0, name: by[$0]!.first!.projectName, rows: by[$0]!) }
    }
}
