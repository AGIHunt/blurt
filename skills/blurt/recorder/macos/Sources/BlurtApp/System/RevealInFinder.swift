import AppKit

/// Files selected in the Finder, with the Finder in front.
///
/// The island, the hanging cards and the countdown are non-activating panels, so Blurt is usually not the active app
/// when they ask for the Finder. From an inactive app `activateFileViewerSelecting` selects the files but leaves the
/// Finder behind the app in front whenever the Finder already has that folder's window open (measured 2026-11-27 on
/// macOS 27 from an accessory process: the first reveal came to the front, the second stayed behind), and
/// `NSRunningApplication.activate` is refused (cooperative activation). Asking LaunchServices to open the Finder with
/// `activates` brings it forward every time. Before this, "Show in Finder" after a recording looked like it did nothing.
enum RevealInFinder {
    static let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

    static func show(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        guard !NSApp.isActive else { return }      // the Finder comes forward by itself from the active app
        let c = NSWorkspace.OpenConfiguration()
        c.activates = true
        NSWorkspace.shared.openApplication(at: finder, configuration: c) { _, _ in }
    }
}
