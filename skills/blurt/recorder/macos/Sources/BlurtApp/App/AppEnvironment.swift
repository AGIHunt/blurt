// Seams between the app shell (WP4) and the parts other work packages add, so nobody edits someone else's files:
//   MainWindow/ + WebHost/ (WP5) set `mainWindow` in MainWindowModule.install();
//   Settings/, Onboarding/, System/ (WP6) set `settings`, `fixWithAgent`, `openURL` in SettingsModule.install().
// The shell calls both install()s once at launch (menu-bar app only) and shows the matching menu items only when the
// hook is set.
import AppKit

protocol MainWindowHosting: AnyObject {
    func show()
    func reveal(uid: String)
    func reveal(session: URL)
}

protocol SettingsHosting: AnyObject {
    /// nil = the last pane / the first one
    func show(pane: String?)
}

enum AppEnvironment {
    static var mainWindow: MainWindowHosting?
    static var settings: SettingsHosting?
    /// "Let the agent fix" for item uids (WP6); the main window greys the action out while nil.
    static var fixWithAgent: (([String]) -> Void)?
    /// blurt:// and blurt-app:// URLs handed to the app by macOS (WP6: blurt://item/<uid>, session/<path>, record, snap).
    /// Return false to let the shell try its own handling (record / snap).
    static var openURL: ((URL) -> Bool)?

    static func installModules() {
        MainWindowModule.install()
        SettingsModule.install()
    }
}
