// At most one island message per launch. Several things want a word as Blurt starts — a config.json that doesn't
// parse, the welcome (the very first launch), a shortcut that won't work, dictation without its permission, the
// carried-over project question, a skill that doesn't match the app, jobs the last run left unfinished, a better
// speech model — and they used to arrive in the same second, each replacing the last before it could be read.
// Each one is posted here with its rank (LaunchRank, lowest first: a model suggestion, an unfinished job, the project
// question, dictation's permission, a shortcut, the welcome, model downloads carrying on, a skill that doesn't match
// — it breaks things, so it outranks the welcome —, settings that can't be saved). For the first 3 s they are held;
// then the highest goes up and the rest are dropped (each comes back on a later launch — the model suggestion stays
// pending until it was seen —, or lives in the menu and Settings anyway — dictation's row and the skill mismatch in
// the menu and Settings → General, the job in the main window, the model in Settings → Speech, the download in the
// menu). Until 90 s after launch, a launch message that arrives once one has been shown is
// dropped too. Outside that window post() is just the island's toast; ordinary toasts (what the user just did) never
// come through here. A message that may stop being true while held passes `stillTrue` ("the downloads carry on"): at
// the end of the hold it goes only if it still is. The rule itself is BlurtCore's LaunchQueue.
import AppKit
import BlurtCore

enum LaunchRank: Int, Comparable {
    case model = 1, job, project, permission, shortcuts, welcome, models, skill, config
    static func < (a: LaunchRank, b: LaunchRank) -> Bool { a.rawValue < b.rawValue }
}

/// BlurtCore's LaunchQueue (the rule, unit-tested) with the island to show on and the event log.
final class LaunchMessages {
    static let shared = LaunchMessages()

    private struct Held { let rank: LaunchRank; let toast: Island.Toast; let shown: (() -> Void)?; let stillTrue: (() -> Bool)? }
    private lazy var queue = LaunchQueue<Held>(show: { h in
        var t = h.toast
        t.passive = true            // a launch message never pushes aside what the user just did (ToastQueue)
        island.toast(t)
        h.shown?()
    }, dropped: { h, _ in
        emit(["event": "launch_toast_dropped", "rank": h.rank.rawValue, "text": h.toast.text])
    }, stale: { h in h.stillTrue.map { !$0() } ?? false })

    /// At launch, before anything posts (App.startResident).
    func start() {
        queue.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + queue.hold) { [weak self] in self?.queue.flush() }
    }

    /// The launch's messages are still held: a word now would only repeat what goes up in a moment.
    var holding: Bool { queue.collecting }

    /// `shown`: called when the message really goes up (not when it is dropped). `stillTrue`: asked at the end of the
    /// hold — false drops it.
    func post(_ rank: LaunchRank, _ t: Island.Toast, stillTrue: (() -> Bool)? = nil, shown: (() -> Void)? = nil) {
        if queue.post(rank.rawValue, Held(rank: rank, toast: t, shown: shown, stillTrue: stillTrue)) == .held {
            emit(["event": "launch_toast_held", "rank": rank.rawValue, "text": t.text])
        }
    }
}
