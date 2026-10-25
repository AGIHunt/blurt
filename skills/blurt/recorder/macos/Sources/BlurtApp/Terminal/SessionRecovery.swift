// The ways back from a session that ended without doing the work — the same two actions wherever it shows (the
// pane's ended card, the item's banner, the job detail):
//   Restart Session  `sessions.py restart`: the same items, agent and model in a fresh session (its old window,
//                    worktree and branch go); the new session opens.
//   Take Back        the items still with it go back to To Do (items.py state --action take_back, the user's move).
import AppKit
import BlurtCore

@MainActor
enum SessionRecovery {
    /// → the new session's job id (nil when it runs elsewhere), or the sessions.py error.
    static func restart(_ job: String, done: @escaping (Result<String?, Error>) -> Void) {
        Task { @MainActor in
            do {
                let r = try await AgentSessions.shared.restart(job: job)
                for l in r.launch { AppRunner.shared.launch(l) }
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

    static func takeBack(_ jobID: String, failed: @escaping (String) -> Void) {
        guard let j = JobStore.shared.job(jobID) else { return }
        let uids = itemsWithIt(j)
        guard !uids.isEmpty else { NSSound.beep(); return }
        Scripts.state(uids, action: "take_back") { r in
            switch r {
            case .success: emit(["event": "session_take_back", "job": jobID, "items": uids])
            case .failure(let f): failed(f.localized)
            }
        }
    }
}
