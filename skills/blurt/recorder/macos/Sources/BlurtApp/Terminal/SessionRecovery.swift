// The ways back from a session that ended without doing the work — the same two actions wherever it shows (the
// pane's ended card, the item's banner, the job detail):
//   Restart Session  `sessions.py restart`: the same items, agent and model in a fresh session (its old window,
//                    worktree and branch go); the new session opens.
//   Take Back        the items still with it go back to To Do (`sessions.py take-back`, the user's move); a session
//                    that is over and left no change goes with it (window, worktree, branch), one with changes keeps
//                    its worktree and says so (Review Changes).
// Either one is in flight for a job until it returns (Busy): its buttons are off meanwhile, and a second press is
// ignored — sessions.py restart also refuses a job already restarted (code finished), so nothing can reach the new
// session's worktree.
import AppKit
import BlurtCore
import Combine

@MainActor
enum SessionRecovery {
    /// The jobs a Restart or Take Back is running for.
    final class Busy: ObservableObject {
        @Published private(set) var jobs: Set<String> = []
        func contains(_ j: String) -> Bool { jobs.contains(j) }
        /// false when it already runs
        func begin(_ j: String) -> Bool { jobs.insert(j).inserted }
        func end(_ j: String) { jobs.remove(j) }
    }
    static let busy = Busy()

    /// → the new session's job id (nil when it runs elsewhere), or the sessions.py error.
    static func restart(_ job: String, done: @escaping (Result<String?, Error>) -> Void) {
        guard busy.begin(job) else { return }
        Task { @MainActor in
            defer { busy.end(job) }
            do {
                let r = try await AgentSessions.shared.restart(job: job)
                for l in r.launch { AppRunner.shared.launch(l) }
                for l in r.links { DesktopApp.open(l.url, job: l.job) }     // a desktop session starts there again
                emit(["event": "session_restart", "job": job, "jobs": r.jobs])
                JobStore.shared.rescan()
                done(.success(r.jobs.first))
            } catch {
                done(.failure(error))
            }
        }
    }

    /// The session's items that are still handed off to it or in progress.
    static func itemsWithIt(_ job: Job) -> [String] {
        job.items.filter { uid in
            guard let it = IndexLookup.item(uid: uid) else { return true }     // not indexed yet: items.py decides
            return ["handed_off", "in_progress"].contains(it.state)
        }
    }

    /// After items were taken back some other way (R, the state menu, the item's banner: items.py): their sessions
    /// that are over clean up the same way (`sessions.py clean-up`: a no-change worktree, its branch and the dead
    /// window go) — but only once none of the session's items is still with it. Taking back one item of three never
    /// moves the other two or removes the worktree they are still with.
    static func cleanUp(jobs: [String]) {
        let ended = Set(jobs).filter { JobStore.shared.job($0).map { $0.type == .agent && !$0.isActive && $0.agent?.finishAction == nil } ?? false }
        guard !ended.isEmpty else { return }
        Task { @MainActor in
            var kept = false
            for j in ended.sorted() {
                do { kept = try await AgentSessions.shared.cleanUp(job: j) || kept }
                catch { NSLog("blurt take back: clean-up of %@ failed: %@", j, "\(error)") }
            }
            emit(["event": "session_cleanup", "jobs": ended.sorted(), "changes_kept": kept])
            JobStore.shared.rescan()
            if kept { appDelegate?.toast(TL("take_back.changes_kept")) }
        }
    }

    static func takeBack(_ jobID: String, failed: @escaping (String) -> Void) {
        guard let j = JobStore.shared.job(jobID) else { return }
        let uids = itemsWithIt(j)
        guard !uids.isEmpty else { NSSound.beep(); return }
        guard busy.begin(jobID) else { return }
        Task { @MainActor in
            defer { busy.end(jobID) }
            do {
                let kept = try await AgentSessions.shared.takeBack(job: jobID)
                emit(["event": "session_take_back", "job": jobID, "items": uids, "changes_kept": kept])
                Scripts.indexUpdate(uids.compactMap { IndexLookup.item(uid: $0).map { URL(fileURLWithPath: $0.path) } })
                JobStore.shared.rescan()
                if kept { appDelegate?.toast(TL("take_back.changes_kept")) }
            } catch {
                failed(sessionsErrorText(error))
            }
        }
    }
}
