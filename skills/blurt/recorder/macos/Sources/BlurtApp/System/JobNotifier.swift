// K4's notification rules, for the jobs the app sees change (JobStore), and the menu-bar badge.
//   • Never opens the review, the main window or a browser by itself.
//   • Organising finished: the badge goes up; one quiet line in the island (2.4 s, no focus) — "Recording organised ·
//     5 to review", click = that batch in the main window. A system notification only when the app isn't frontmost,
//     the job ran 20 s or more and notify.done is on (default); never a sound.
//   • Nothing at all while recording (the counts still update).
//   • Agent sessions are Terminal/SessionNotifier's (P3): nothing here for type agent, so nothing arrives twice.
//   • Failures: a line with the reason, a notification when not frontmost.
//   • The same kind of notification within 10 s collapses into one.
import AppKit
import BlurtCore
import UserNotifications

extension Notification.Name {
    /// JobStore changed; userInfo["jobs"] = the changed [Job].
    static let blurtJobsChanged = Notification.Name("dev.blurt.jobs-changed")
}

final class JobNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = JobNotifier()
    private var seen: [String: String] = [:]          // job id → "state/agent status" last time
    private var lastPost: [String: Date] = [:]        // kind → when
    private var pending: [String: (count: Int, job: Job)] = [:]

    func start() {
        for j in JobStore.shared.jobs { seen[j.id] = Self.signature(j) }    // what was already true at launch is old news
        // the one listener of JobStore; everyone else (the main window) follows the notification
        JobStore.shared.onChange = { [weak self] changed in
            self?.changed(changed)
            NotificationCenter.default.post(name: .blurtJobsChanged, object: nil, userInfo: ["jobs": changed])
        }
        if Self.systemNotificationsAllowed { UNUserNotificationCenter.current().delegate = self }
        MenuBadge.shared.refresh()
    }

    static func signature(_ j: Job) -> String { "\(j.state.rawValue)/\(j.agent?.status.rawValue ?? "")" }

    func changed(_ jobs: [Job]) {
        MenuBadge.shared.refresh()
        for j in jobs {
            let sig = Self.signature(j)
            let before = seen[j.id]
            seen[j.id] = sig
            guard before != sig else { continue }
            if before == nil && !j.isActive { continue }       // an old job we only now noticed
            event(j, before: before)
        }
    }

    var recording: Bool { appDelegate?.rec != nil }
    var frontmost: Bool { NSApp.isActive }
    func setting(_ key: String) -> Bool { Config.shared["notify.\(key)"] as? Bool ?? true }

    private func event(_ j: Job, before: String?) {
        guard !recording, j.type != .agent else { return }
        let ran = (j.ended ?? Date()).timeIntervalSince(j.started ?? j.created)
        switch (j.type, j.state) {
        case (.process, .done), (.route, .done):
            // a capture filed from its note (no agent) already said "Filed to …" in the island
            if let u = j.usage, u.agent == nil { MenuGlyph.shared.hop(); return }
            let n = j.items.isEmpty ? nil : j.items.count
            let what = j.session.map { isShotsSession($0) ? T("notify.done.snaps") : T("notify.done.recording") } ?? T("notify.done.generic")
            let text = n.map { "\(what) · \(TP("app.menu.new", $0))" } ?? what
            quiet(text, action: T("notify.open"), art: .happy) { j.session.map { AppEnvironment.mainWindow?.reveal(session: $0) } ?? AppEnvironment.mainWindow?.showInbox() }
            MenuGlyph.shared.hop()
            if !frontmost, ran >= 20, setting("done") { post("done", title: text, body: JobLook.title(j), job: j) }
        case (_, .failed):
            let why = j.error.map { $0.hintKey.map { T($0) } ?? $0.message } ?? ""
            quiet(T("notify.failed", JobLook.title(j)), action: T("notify.show"),
                  launch: j.error?.hintKey == "main.job.hint.interrupted" ? .job : nil) { AppEnvironment.mainWindow?.reveal(job: j.id) }
            if !frontmost { post("failed", title: T("notify.failed", JobLook.title(j)), body: why, job: j) }
        default: break
        }
    }

    /// The island's quiet line; before the island exists, the same small non-activating toast the app always had.
    /// `launch`: a launch message too (one at launch: LaunchMessages) — a job the last run left unfinished.
    private func quiet(_ text: String, action: String, art: MascotClip? = nil, launch: LaunchRank? = nil, _ run: @escaping () -> Void) {
        if AppEnvironment.island != nil, let clip = art {
            // done: the chick hops beside the line (the mascot, Icons/Mascot.swift)
            let chick = MascotView(clip: clip, size: 50)
            chick.show(clip, frame: 0)
            var t = Island.Toast(text: text, actionTitle: action, action: run)
            t.art = chick
            t.seconds = max(2.4, (MascotLibrary.shared.clip(clip)?.duration ?? 1.5) + 0.8)
            Island.shared.toast(t)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { chick.play(clip) }
        } else if let r = launch, AppEnvironment.island != nil {
            LaunchMessages.shared.post(r, Island.Toast(text: text, actionTitle: action, action: run))
        } else if let island = AppEnvironment.island {
            island.toast(text, actionTitle: action, action: run)
        } else {
            appDelegate?.toast(text, seconds: 2.4)
        }
    }

    static var systemNotificationsAllowed: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
            && ProcessInfo.processInfo.environment["BLURT_NO_NOTIFICATIONS"] == nil
    }

    /// A system notification (no sound). Same kind within 10 s → one notification that says how many.
    private func post(_ kind: String, title: String, body: String, job: Job) {
        let now = Date()
        if let last = lastPost[kind], now.timeIntervalSince(last) < 10 {
            let p = pending[kind]
            pending[kind] = ((p?.count ?? 1) + 1, job)
            return
        }
        lastPost[kind] = now
        deliver(kind, title: title, body: body, job: job)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, let p = self.pending.removeValue(forKey: kind) else { return }
            self.deliver(kind, title: TP("notify.more", p.count), body: JobLook.title(p.job), job: p.job)
        }
    }

    private func deliver(_ kind: String, title: String, body: String, job: Job) {
        emit(["event": "notification", "kind": kind, "title": title, "job": job.id])
        guard Self.systemNotificationsAllowed else { return }
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert]) { ok, _ in
            guard ok else { return }
            let n = UNMutableNotificationContent()
            n.title = title
            n.body = body
            n.userInfo = ["job": job.id]
            n.threadIdentifier = kind
            if kind == "done" { n.attachments = MascotLibrary.shared.attachment(.happy) }
            c.add(UNNotificationRequest(identifier: "\(kind)-\(job.id)", content: n, trigger: nil))
        }
    }

    // a click on a notification (ours, SessionNotifier's or FixRunner's): the job or the item in the main window
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let id = info["job"] as? String {
            DispatchQueue.main.async { AppEnvironment.mainWindow?.reveal(job: id) }
        } else if let uid = info["uid"] as? String {          // FixRunner's "to verify" notifications
            DispatchQueue.main.async { AppEnvironment.mainWindow?.reveal(uid: uid) }
        }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([])        // frontmost: the app shows it itself
    }
}

/// The number next to the menu-bar icon: what needs you (K3's inbox = new + to verify) + agent sessions waiting for
/// an answer. Read from index.db (only when its data_version moves) and the job store.
final class MenuBadge {
    static let shared = MenuBadge()
    private(set) var new = 0, verify = 0, waiting = 0
    private var reader: IndexReader?
    private var version = -1
    private var timer: Timer?

    var count: Int { testCount ?? new + verify + waiting }
    /// Tests only (the `menuglyph` self-test): a stand-in count, to render the status button with a number.
    var testCount: Int?
    /// An agent is waiting for an answer: the number takes the attention colour.
    var urgent: Bool { waiting > 0 }
    var tooltip: String {
        var parts: [String] = []
        if new > 0 { parts.append(TP("app.menu.new", new)) }
        if verify > 0 { parts.append(TP("app.menu.to_verify", verify)) }
        if waiting > 0 { parts.append(TP("app.badge.waiting", waiting)) }
        return parts.isEmpty ? T("app.name") : parts.joined(separator: " · ")
    }

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        if reader == nil { reader = try? IndexReader(url: BlurtPaths.indexDB) }
        if let r = reader {
            let v = r.dataVersion
            if v != version, let c = try? r.counts() {
                version = v
                new = c.new
                verify = c.toVerify
            }
        }
        waiting = JobStore.shared.active.filter { $0.agent?.status == .waitingInput }.count
    }
}
