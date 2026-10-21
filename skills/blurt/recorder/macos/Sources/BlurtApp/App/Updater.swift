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
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var available: Bool { controller != nil }
    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    @objc func checkForUpdates(_ sender: Any?) {
        activateApp()
        controller?.checkForUpdates(sender)
    }
    #else
    func start() {}
    var available: Bool { false }
    var canCheck: Bool { false }
    @objc func checkForUpdates(_ sender: Any?) {}
    #endif
}

#if canImport(Sparkle)
extension Updater: SPUStandardUserDriverDelegate {
    // A menu-bar app (LSUIElement) has no Dock icon to badge: Sparkle shows its update window when it finds one
    // in the background, and we bring ourselves forward for it.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate { activateApp() }
    }
}
#endif
