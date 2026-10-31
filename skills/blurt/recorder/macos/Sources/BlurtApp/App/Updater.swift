// Auto-update with Sparkle 2 (release builds only: BLURT_SPARKLE=1, see Package.swift). Feed: Info.plist SUFeedURL
// (the GitHub release's appcast.xml, written by scripts/release-mac.sh); updates are EdDSA-signed and the key in
// SUPublicEDKey verifies them, on top of the Developer ID signature. Without a key (a local build) the updater stays
// off, so a build that can't verify updates never offers one.
// Checks are on from the first launch (Info.plist SUEnableAutomaticChecks: no "check automatically?" question), once a
// day. A menu-bar app is always "in the background" to Sparkle, so a scheduled check that finds an update leaves the
// reminder to us (gentle reminders): the island says which version is there, with Update…, and the menu-bar menu's
// row reads "Update to X…" until the update window has been seen. An update that downloaded on its own (the user
// ticked Sparkle's "automatically download and install") says so too, with Restart Now — never a silent swap.
import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

final class Updater: NSObject {
    static let shared = Updater()

    /// Base64 of a 32-byte Ed25519 public key
    static var publicKeyIsValid: Bool {
        guard let k = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, let d = Data(base64Encoded: k) else { return false }
        return d.count == 32
    }

    /// The version a background check found that the user hasn't looked at yet (the menu row names it); nil: none.
    private(set) var pending: String?
    static let toastKey = "update"

    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?

    /// The menu-bar app calls this once at launch.
    func start() {
        guard controller == nil, Updater.publicKeyIsValid else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    var available: Bool { controller != nil }
    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    @objc func checkForUpdates(_ sender: Any?) {
        activateApp()
        controller?.checkForUpdates(sender)
    }

    /// Fetch and evaluate the feed without any UI (tests): the result arrives as an "update_probe" event on stdout.
    func probe() { controller?.updater.checkForUpdateInformation() }

    /// Background check that downloads (and EdDSA-verifies) an update silently; it installs when the app quits (tests).
    func silentUpdate() {
        controller?.updater.automaticallyChecksForUpdates = true
        controller?.updater.automaticallyDownloadsUpdates = true
        controller?.updater.checkForUpdatesInBackground()
    }
    #else
    func start() {}
    var available: Bool { false }
    var canCheck: Bool { false }
    @objc func checkForUpdates(_ sender: Any?) {}
    func probe() {}
    func silentUpdate() {}
    #endif
}

#if canImport(Sparkle)
extension Updater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        emit(["event": "update_probe", "found": true, "version": item.versionString, "short": item.displayVersionString])
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        emit(["event": "update_probe", "found": false, "reason": (error as NSError).localizedDescription])
    }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        emit(["event": "update_ready", "version": item.versionString])
        // downloaded on its own: said, with Restart Now; otherwise it installs when Blurt quits
        var t = Island.Toast(text: T("app.update.ready", item.displayVersionString), actionTitle: T("app.update.ready.action"),
                             action: { immediateInstallationBlock() })
        t.key = Updater.toastKey
        t.seconds = 15
        island.toast(t)
        return true
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        emit(["event": "update_error", "error": (error as NSError).localizedDescription])
    }
}

extension Updater: NSMenuItemValidation {
    /// The main menu's Check for Updates… (About and Help) greys out while a check is already running.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(checkForUpdates(_:)) ? canCheck : true
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    // A menu-bar app (LSUIElement) has no Dock icon to badge: Sparkle shows its update window when it finds one
    // in the background, and we bring ourselves forward for it.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate { return activateApp() }
        // a scheduled check found it while we are "in the background": our own reminder
        pending = update.displayVersionString
        emit(["event": "update_reminder", "version": update.displayVersionString, "user_initiated": state.userInitiated])
        var t = Island.Toast(text: T("app.update.found", update.displayVersionString), actionTitle: T("app.update.found.action"),
                             action: { [weak self] in self?.checkForUpdates(nil) })
        t.key = Updater.toastKey
        t.seconds = 15
        island.toast(t)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { pending = nil }
    func standardUserDriverWillFinishUpdateSession() { pending = nil }
}
#endif
