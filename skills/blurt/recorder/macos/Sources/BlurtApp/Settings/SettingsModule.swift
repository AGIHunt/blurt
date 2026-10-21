// WP6 (mac-settings-system) owns Settings/, Onboarding/, System/. Called once at launch by the menu-bar app (before
// the menu exists): registers Settings, "fix with an agent" and blurt:// handling with the shell (AppEnvironment),
// the Services provider ("Add to Blurt"), Spotlight indexing, the fix watcher (→ the chicken pecks the bug), the
// live-audio retention sweep, and the setup assistant on first launch.
import AppKit
import BlurtCore

enum SettingsModule {
    static func install() {
        // K10: config `lang` (Settings → General: auto | en | zh-Hans) decides, unless --lang was given; the strings not
        // moved to the tables yet (L(zh, en)) follow the same choice
        if !CommandLine.arguments.contains("--lang") { opts.lang = Loc.isChinese ? "zh" : "en"; BlurtLocale.lang = opts.lang }

        AppEnvironment.settings = SettingsController.shared
        AppEnvironment.openURL = { URLRouter.handle($0) }
        AppEnvironment.fixWithAgent = { uids in
            DispatchQueue.main.async { MainActor.assumeIsolated { FixRunner.shared.start(uids) } }
        }
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

        SelfTests.install()
        if Onboarding.needed && ProcessInfo.processInfo.environment["BLURT_NO_ONBOARDING"] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { Onboarding.shared.show() }
        }
    }
}
