// What the menu-bar app does in the background at launch (v0.7 contract), silently, in this order:
//   projects.py migrate      v0.6 record.workspace(s) → projects.json (K2; idempotent)
//   items.py migrate --all   v1/v2 sessions (items.json, no batch.json) → Markdown stores (K1; idempotent)
//   jobs.py gc               jobs that ended 14+ days ago, beyond the last 300 (K4)
// and keeps one `sessions.py monitor` running while it lives (K5: tmux windows → session status; it takes its own lock,
// so a second copy just exits). Any of them missing (an older skill) is skipped.
import AppKit
import BlurtCore

enum Housekeeping {
    private static var monitor: Process?

    static func atLaunch() {
        guard ProcessInfo.processInfo.environment["BLURT_NO_HOUSEKEEPING"] == nil else { return }
        Task.detached(priority: .utility) {
            let r = ScriptRunner.shared
            for (script, args) in [("projects.py", ["migrate"]), ("items.py", ["migrate", "--all"]), ("jobs.py", ["gc"])] {
                guard (try? r.scriptURL(script)) != nil else { continue }
                do { _ = try await r.run(script, args, timeout: 600) } catch { NSLog("blurt: \(script) \(args.joined(separator: " ")): \(error)") }
            }
            await MainActor.run {
                ProjectStore.shared.reload()
                Scripts.indexUpdate([ProjectStore.shared.inbox.store])
                startMonitor()
            }
        }
    }

    static func startMonitor() {
        guard monitor == nil, (try? ScriptRunner.shared.scriptURL("sessions.py")) != nil else { return }
        monitor = try? ScriptRunner.shared.spawn("sessions.py", ["monitor"]) { _ in }
    }

    static func atQuit() {
        if let m = monitor, m.isRunning { m.terminate() }
        monitor = nil
    }
}
