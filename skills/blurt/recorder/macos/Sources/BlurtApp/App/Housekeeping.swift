// What the menu-bar app does in the background at launch (v0.7 contract), silently, in this order:
//   projects.py migrate      v0.6 record.workspace(s) → projects.json (K2; idempotent)
//   items.py migrate --all   v1/v2 sessions (items.json, no batch.json) → Markdown stores (K1; idempotent)
//   jobs.py gc               jobs that ended 14+ days ago, beyond the last 300 (K4)
//   transcribe.py auto --apply   speech models for this Mac (K9); after a hardware change that wants a download, one
//                            quiet line in the island offers Settings → Speech (once: --apply records the hardware)
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
            await speechModels()
        }
    }

    /// K9: pick the speech models for this machine. Skipped until onboarding is done (it downloads the first model);
    /// the hardware is recorded only then, so the first real launch afterwards may suggest a better model.
    static func speechModels() async {
        guard !Onboarding.needed, (try? ScriptRunner.shared.scriptURL("transcribe.py")) != nil else { return }
        guard let r = try? await ScriptRunner.shared.json("transcribe.py", ["auto", "--apply"], timeout: 120),
              r["ok"] as? Bool == true, r["hardware_changed"] as? Bool == true,
              let need = r["needs_download"] as? [[String: Any]], !need.isEmpty else { return }
        let mb = need.compactMap { ($0["size_mb"] as? NSNumber)?.doubleValue }.reduce(0, +)
        let size = ByteCountFormatter.string(fromByteCount: Int64(mb * 1_000_000), countStyle: .file)
        await MainActor.run {
            emit(["event": "asr_suggest", "models": need.compactMap { $0["model"] as? String }, "size_mb": mb])
            AppEnvironment.island?.toast(T("main.speech.better_model", size), actionTitle: T("main.speech.better_model.action")) {
                AppEnvironment.settings?.show(pane: SettingsPane.speech.rawValue)
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
