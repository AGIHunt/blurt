// WP5 (mac-main-window) owns MainWindow/ and WebHost/. Called once at launch by the menu-bar app:
// set AppEnvironment.mainWindow here (the menu then shows "Open Blurt").
//
// At launch: an incremental `index.py scan` in the background when an index exists (a missing index is offered as a
// first-run scan in the window instead), and the window comes back if it was open when the app quit — only for
// background launches (login item, `--background`), never on top of a plain launch that starts a recording.
// BLURT_OPEN_MAIN=1 opens it right away (tests, screenshots).
import AppKit
import BlurtCore

enum MainWindowModule {
    static func install() {
        AppEnvironment.mainWindow = MainWindowHost()
        if Scripts.has("index.py"), FileManager.default.fileExists(atPath: BlurtPaths.indexDB.path) {
            Scripts.indexScan { _ in }
        }
        let env = ProcessInfo.processInfo.environment
        let reopen = CommandLine.arguments.contains("--background") && MainWindowController.loadState()?.open == true
        if env["BLURT_OPEN_MAIN"] != nil || reopen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { AppEnvironment.mainWindow?.show() }
        }
    }
}

/// Creates the window on first use: nothing of the main window costs memory until it's opened.
final class MainWindowHost: MainWindowHosting {
    func show() { MainWindowController.shared.show() }
    func reveal(uid: String) { MainWindowController.shared.reveal(uid: uid) }
    func reveal(session: URL) { MainWindowController.shared.reveal(session: session) }
}
