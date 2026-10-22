// Status notifications for agent sessions (K4 reminder rules): when a session starts waiting for the user, finishes a
// turn, exits or fails, and Blurt isn't the app in front, one quiet system notification that says which project and
// which items ("Needs your input · bug-agent" / "BA-12 · Login button does nothing"). Never a sound, never a window
// opened on its own; clicking it shows that session's terminal. Same kind within 10 s → one notification. Switch:
// config notify.agent (default on).
import AppKit
import UserNotifications
import BlurtCore

@MainActor
final class SessionNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SessionNotifier()

    private var last: [String: AgentSessionStatus] = [:]      // job → status we last saw
    private var recent: [String: (at: Date, id: String, lines: [String])] = [:]   // kind → the last 10 s, merged
    private var token: UUID?

    /// System notifications only for the real app: test builds (non-default BLURT_HOME) report them on stdout instead.
    var deliver: Bool { Notify.allowed }

    func start() {
        guard token == nil else { return }
        for j in JobStore.shared.jobs where j.type == .agent { if let a = j.agent { last[j.id] = j.isActive ? a.status : .exited } }
        token = JobStore.shared.addObserver { [weak self] changed in MainActor.assumeIsolated { self?.changed(changed) } }
        let c = UNUserNotificationCenter.current()
        if deliver, c.delegate == nil { c.delegate = self }
    }

    private func changed(_ jobs: [Job]) {
        for j in jobs where j.type == .agent {
            guard let a = j.agent else { continue }
            let now: AgentSessionStatus = j.isActive ? a.status : (j.state == .failed ? .error : (a.status == .error ? .error : .exited))
            let before = last[j.id]
            last[j.id] = now
            guard let b = before, b != now else { continue }      // first sight: baseline only
            guard [.waitingInput, .turnDone, .exited, .error].contains(now) else { continue }
            if now == .exited && b == .turnDone && j.state == .cancelled { continue }   // the user ended it
            post(j, a, now)
        }
    }

    func post(_ j: Job, _ a: AgentInfo, _ status: AgentSessionStatus) {
        guard (Config.shared["notify.agent"] as? Bool) ?? true else { return }
        let project = ProjectStore.shared.project(id: j.project ?? "")?.name ?? a.cwd.lastPathComponent
        let labels = HandoffLabels.labels(a.handoff)
        let head = labels.first.map { "\($0.id) · \($0.title)" } ?? (a.windowName ?? "")
        let more = labels.count > 1 ? " " + TL("notify.more", labels.count - 1) : ""
        var title = TL("notify.title.\(status.rawValue)", project)
        var body = head + more
        if status == .waitingInput, let m = a.statusMessage, !m.isEmpty { body += "\n" + m }
        if status == .error, let e = a.exit { body += "\n" + TL("notify.exit", Int(e)) }
        let foreground = NSApp.isActive
        emit(["event": "session_notify", "job": j.id, "status": status.rawValue, "title": title, "body": body,
              "delivered": deliver && !foreground, "foreground": foreground])
        guard deliver, !foreground else { return }
        // the same kind within 10 s: one notification listing them all ("2 sessions need your input")
        let kind = status.rawValue
        var id = "session-\(kind)-\(Int(Date().timeIntervalSince1970 * 1000))"
        var lines = ["\(project) · \(head)"]
        if let r = recent[kind], Date().timeIntervalSince(r.at) < 10 {
            id = r.id
            lines = r.lines + lines
            title = Loc.plural("notify.many.\(kind)", table: "Terminal", count: lines.count)
            body = lines.joined(separator: "\n")
        }
        recent[kind] = (Date(), id, lines)
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert]) { ok, _ in
            guard ok else { return }
            let n = UNMutableNotificationContent()
            n.title = title
            n.body = body
            n.threadIdentifier = "session-\(j.id)"
            n.userInfo = ["job": j.id]
            n.sound = nil
            c.add(UNNotificationRequest(identifier: id, content: n, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let job = response.notification.request.content.userInfo["job"] as? String
        let uid = response.notification.request.content.userInfo["uid"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let job = job { TerminalModule.reveal(job: job) }
                else if let uid = uid { AppEnvironment.mainWindow?.reveal(uid: uid) }
            }
            done()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([])        // in front: the session list already shows it
    }
}
