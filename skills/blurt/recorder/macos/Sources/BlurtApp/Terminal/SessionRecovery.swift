// The ways back from a session that ended without doing the work — the same two actions wherever it shows (the
// pane's ended card, the item's banner, the job detail):
//   Restart Session  `sessions.py restart`: the same items, agent and model in a fresh session (its old window,
//                    worktree and branch go); the new session opens.
//   Take Back        the items still with it go back to To Do (items.py state --action take_back, the user's move).
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

    static func takeBack(_ jobID: String, failed: @escaping (String) -> Void) {
        guard let j = JobStore.shared.job(jobID) else { return }
        let uids = itemsWithIt(j)
        guard !uids.isEmpty else { NSSound.beep(); return }
        guard busy.begin(jobID) else { return }
        Scripts.state(uids, action: "take_back") { r in
            busy.end(jobID)
            switch r {
            case .success: emit(["event": "session_take_back", "job": jobID, "items": uids])
            case .failure(let f): failed(f.localized)
            }
        }
    }
}
