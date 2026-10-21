// Auto-update with Sparkle 2 (release builds only: BLURT_SPARKLE=1, see Package.swift). Feed: Info.plist SUFeedURL
// (the GitHub release's appcast.xml, written by scripts/release-mac.sh); updates are EdDSA-signed and the key in
// SUPublicEDKey verifies them, on top of the Developer ID signature. Without a key (a local build) the updater stays
// off, so a build that can't verify updates never offers one.
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
        return false        // install when the app quits, as Sparkle does by default
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        emit(["event": "update_error", "error": (error as NSError).localizedDescription])
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    // A menu-bar app (LSUIElement) has no Dock icon to badge: Sparkle shows its update window when it finds one
    // in the background, and we bring ourselves forward for it.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate { activateApp() }
    }
}
#endif
