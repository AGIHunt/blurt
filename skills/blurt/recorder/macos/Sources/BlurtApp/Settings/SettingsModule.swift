// WP6 (mac-settings-system) owns Settings/, Onboarding/, System/. Called once at launch by the menu-bar app (before
// the menu exists): registers Settings and blurt:// handling with the shell (AppEnvironment),
// the Services provider ("Add to Blurt"), Spotlight indexing, the fix watcher (→ Peep's done line), the
// live-audio retention sweep, and the setup assistant on first launch.
import AppKit
import BlurtCore

enum SettingsModule {
    static func install() {
        AppEnvironment.settings = SettingsController.shared
        AppEnvironment.openURL = { URLRouter.handle($0) }
        ServiceProvider.shared.register()

        FixWatcher.shared.onFixed = { uid, item, session in
            FixRunner.shared.announceFixed(uid: uid, item: item, session: session)
        }
        FixWatcher.shared.onChange = { _ in
            Spotlight.shared.refreshSoon()
            Retention.sweep()
        }
        FixWatcher.shared.start()
        Retention.sweep()

        // Spotlight: from index.db; build the index first when there is none yet (index.py scan, C3)
        Task.detached(priority: .utility) {
            if !IndexLookup.available, ScriptRunner.shared.uvAvailable {
                _ = try? await SkillCLI.shared.run("index.py", ["scan"], timeout: 300)
            }
            await MainActor.run { Spotlight.shared.refresh() }
        }

        // the cloud services (record.cloud; the one-time move from cloud polish happens on this first read) and their
        // model lists, read again when a day old
        CloudStore.refreshStale()

        SelfTests.install()
        if Onboarding.needed && ProcessInfo.processInfo.environment["BLURT_NO_ONBOARDING"] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { Onboarding.shared.show(step: Onboarding.resumeStep) }
        }
    }
}
