// "Hand to an agent" used to open a panel that ran the agent in the background (`-p`). That is gone (v0.7, K5): items
// go to an interactive agent session in tmux through the dispatch panel (Terminal/DispatchPanel.swift). What stays here:
//   FixRunner.start(uids)          → the dispatch panel (for callers that still use the old name)
//   FixRunner.announceFixed(…)     → an item reached "to verify": the chicken pecks it, and a notification
//   enum Notify                    → system notifications (unchanged)
import AppKit
import UserNotifications
import BlurtCore

final class FixRunner {
    static let shared = FixRunner()

    var windowNumber: Int? { MainActor.assumeIsolated { DispatchPanel.windowNumber } }

    /// `autostart` is ignored: a session is always started by the user from the panel.
    @MainActor
    func start(_ uids: [String], autostart: (agent: String, background: Bool)? = nil) {
        guard !uids.isEmpty else { return }
        DispatchPanel.show(items: uids)
    }

    // MARK: the "to verify" moment

    /// An agent says it is done with an item (work.state → to_verify, K3). `item` is the item's front-matter.
    func announceFixed(uid: String, item: [String: Any], session: URL) {
        let title = item["title"] as? String ?? uid
        let work = item["work"] as? [String: Any] ?? [:]
        let agent = (work["agent"] as? String).map { AgentNames.name($0) }
        let note = work["note"] as? String ?? ""
        let claim = work["claim"] as? String
        let by = agent.map { claim == "wontfix" ? TL("verify.by.wontfix", $0) : TL("verify.by", $0) }
        let detail = [by, note.isEmpty ? nil : note].compactMap { $0 }.joined(separator: " · ")
        PeckCard.shared.play(title: title, detail: detail, uid: uid)
        Notify.post(title: TL("verify.notification", title), body: detail, uid: uid)
    }
}

/// System notifications — only once the user allowed them; never asked for in tests (non-default BLURT_HOME), where the
/// bundle id is shared with the real app.
enum Notify {
    static var allowed: Bool { ProcessInfo.processInfo.environment["BLURT_HOME"] == nil && Bundle.main.bundleIdentifier != nil }

    static func post(title: String, body: String, uid: String) {
        guard allowed else { return }
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let n = UNMutableNotificationContent()
            n.title = title
            n.body = body
            n.userInfo = ["uid": uid]
            c.add(UNNotificationRequest(identifier: "fixed-\(uid)-\(Int(Date().timeIntervalSince1970))", content: n, trigger: nil))
        }
    }
}
