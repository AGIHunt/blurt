// At most one island message per launch. Several things want a word as Blurt starts — a config.json that doesn't
// parse, the welcome (the very first launch), a shortcut that won't work, dictation without its permission, the
// carried-over project question, a skill that doesn't match the app, jobs the last run left unfinished, a better
// speech model — and they used to arrive in the same second, each replacing the last before it could be read.
// Each one is posted here with its rank (LaunchRank, lowest first: a model suggestion, an unfinished job, the skill,
// the project question, dictation's permission, a shortcut, the welcome, settings that can't be saved). For the first
// 3 s they are held; then the highest goes up and the rest are dropped (each comes back on a later launch, or lives in the menu and Settings anyway — dictation's row in the menu,
// the job in the main window, the model in Settings → Speech). Until 90 s after launch, a launch message that arrives
// once one has been shown is dropped too. Outside that window post() is just the island's toast; ordinary toasts
// (what the user just did) never come through here.
import AppKit
import BlurtCore

enum LaunchRank: Int, Comparable {
    case model = 1, job, skill, project, permission, shortcuts, welcome, config
    static func < (a: LaunchRank, b: LaunchRank) -> Bool { a.rawValue < b.rawValue }
}

final class LaunchMessages {
    static let shared = LaunchMessages()
    static let holdSeconds = 3.0
    static let windowSeconds = 90.0

    private var held: [(rank: LaunchRank, toast: Island.Toast, shown: (() -> Void)?)] = []
    private var collecting = false
    private var oneShown = false
    private var started: Date?

    /// At launch, before anything posts (App.startResident).
    func start() {
        started = Date()
        collecting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdSeconds) { [weak self] in self?.flush() }
    }

    private var inWindow: Bool { started.map { Date().timeIntervalSince($0) < Self.windowSeconds } ?? false }

    /// `shown`: called when the message really goes up (not when it is dropped).
    func post(_ rank: LaunchRank, _ t: Island.Toast, shown: (() -> Void)? = nil) {
        if collecting {
            held.append((rank, t, shown))
            emit(["event": "launch_toast_held", "rank": rank.rawValue, "text": t.text])
            return
        }
        if inWindow {
            if oneShown { emit(["event": "launch_toast_dropped", "rank": rank.rawValue, "text": t.text]); return }
            oneShown = true
        }
        island.toast(t)
        shown?()
    }

    private func flush() {
        collecting = false
        // the highest rank; between equals, the first posted
        guard let best = held.indices.max(by: { held[$0].rank < held[$1].rank || (held[$0].rank == held[$1].rank && $0 > $1) }) else { return }
        for (i, h) in held.enumerated() where i != best {
            emit(["event": "launch_toast_dropped", "rank": h.rank.rawValue, "text": h.toast.text])
        }
        let t = held[best]
        held = []
        oneShown = true
        island.toast(t.toast)
        t.shown?()
    }
}
