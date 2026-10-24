// At most one island message per launch. Several things want a word as Blurt starts — a config.json that doesn't
// parse, the welcome (the very first launch), a shortcut that won't work, dictation without its permission, the
// carried-over project question, a skill that doesn't match the app, jobs the last run left unfinished, a better
// speech model — and they used to arrive in the same second, each replacing the last before it could be read.
// Each one is posted here with its rank (LaunchRank, lowest first: a model suggestion, an unfinished job, the project
// question, dictation's permission, a skill that doesn't match, a shortcut, the welcome, settings that can't be
// saved). For the first 3 s they are held; then the highest goes up and the rest are dropped (each comes back on a
// later launch, or lives in the menu and Settings anyway — dictation's row in the menu, the job in the main window,
// the model in Settings → Speech). Until 90 s after launch, a launch message that arrives once one has been shown is
// dropped too. Outside that window post() is just the island's toast; ordinary toasts (what the user just did) never
// come through here. The rule itself is BlurtCore's LaunchQueue.
import AppKit
import BlurtCore

enum LaunchRank: Int, Comparable {
    case model = 1, job, project, permission, skill, shortcuts, welcome, config
    static func < (a: LaunchRank, b: LaunchRank) -> Bool { a.rawValue < b.rawValue }
}

/// BlurtCore's LaunchQueue (the rule, unit-tested) with the island to show on and the event log.
final class LaunchMessages {
    static let shared = LaunchMessages()

    private struct Held { let rank: LaunchRank; let toast: Island.Toast; let shown: (() -> Void)? }
    private lazy var queue = LaunchQueue<Held>(show: { h in island.toast(h.toast); h.shown?() }, dropped: { h, _ in
        emit(["event": "launch_toast_dropped", "rank": h.rank.rawValue, "text": h.toast.text])
    })

    /// At launch, before anything posts (App.startResident).
    func start() {
        queue.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + queue.hold) { [weak self] in self?.queue.flush() }
    }

    /// `shown`: called when the message really goes up (not when it is dropped).
    func post(_ rank: LaunchRank, _ t: Island.Toast, shown: (() -> Void)? = nil) {
        if queue.post(rank.rawValue, Held(rank: rank, toast: t, shown: shown)) == .held {
            emit(["event": "launch_toast_held", "rank": rank.rawValue, "text": t.text])
        }
    }
}
