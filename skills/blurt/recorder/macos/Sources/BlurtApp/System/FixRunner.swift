// "Hand to an agent" used to open a panel that ran the agent in the background (`-p`). That is gone: Hand Off copies
// an instruction for the user's own agent (MainWindowController.handOff). What stays here:
//   FixRunner.announceFixed(…)     → an item reached "to verify": a notification that says only what the agent
//                                    claimed, and Peep says so when it claimed something
//   enum Notify                    → system notifications (unchanged)
import AppKit
import UserNotifications
import BlurtCore

final class FixRunner {
    static let shared = FixRunner()

    // MARK: the "to verify" moment

    /// An item reached "to verify" (K3). `item` is the item's front-matter. Only what the agent claimed is said for
    /// it: "fixed" / "won't fix" (and Peep peeps); anything else is neutral.
    func announceFixed(uid: String, item: [String: Any], session: URL) {
        let title = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? item["id"] as? String ?? T("main.item.untitled")
        let work = item["work"] as? [String: Any] ?? [:]
        let detail = Self.verifyDetail(work)
        emit(["event": "to_verify", "uid": uid, "title": title, "detail": detail])
        if ["fixed", "wontfix"].contains(work["claim"] as? String ?? "") { PeckCard.shared.play(title: title, detail: detail, uid: uid) }
        Notify.post(title: AL("verify.notification", title), body: detail, uid: uid)
    }

    /// "Claude Code says it's fixed · <note>"; "Codex handed it back"; or just the note.
    static func verifyDetail(_ work: [String: Any]) -> String {
        let agent = (work["agent"] as? String).flatMap { $0 == "human" ? nil : AgentNames.name($0) }
        let note = work["note"] as? String ?? ""
        let by: String?
        switch work["claim"] as? String {
        case "fixed": by = agent.map { AL("verify.by", $0) }
        case "wontfix": by = agent.map { AL("verify.by.wontfix", $0) }
        default: by = work["by"] as? String == "agent" ? agent.map { AL("verify.by.none", $0) } : nil
        }
        return [by, note.isEmpty ? nil : note].compactMap { $0 }.joined(separator: " · ")
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
            n.attachments = MascotLibrary.shared.attachment(.done)
            c.add(UNNotificationRequest(identifier: "fixed-\(uid)-\(Int(Date().timeIntervalSince1970))", content: n, trigger: nil))
        }
    }
}
