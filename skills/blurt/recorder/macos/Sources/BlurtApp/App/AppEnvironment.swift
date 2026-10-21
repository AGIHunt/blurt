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

extension MainWindowHosting {     // G0 (v0.7 contract): P4 implements these in MainWindowController
    func reveal(job: String) { show() }
    func reveal(project: String) { show() }
    func showInbox() { show() }
}

protocol TerminalPaneHosting: AnyObject { var viewController: NSViewController { get }; func attach(job: String?) }
protocol TerminalHosting: AnyObject { func makePane() -> TerminalPaneHosting; func newSession(project: String?, items: [String]) }
/// The notch island (K7, P5): ⌥⇧O's project switcher, and one quiet line inside the island (K4's notification rules).
protocol IslandHosting: AnyObject {
    func showSwitcher()
    func toast(_ text: String, actionTitle: String?, action: (() -> Void)?)
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
    /// G0 (v0.7 contract) seams: set by TerminalModule (P3), IslandModule (P5), AgentHub (P4).
    static var terminal: TerminalHosting?
    static var island: IslandHosting?
    static var dispatch: (([String]) -> Void)?
    /// Process captures of a session (K7): nil captures = all of them; nil project = route each item (K2).
    static var process: ((_ session: URL, _ captures: [Int]?, _ project: String?) -> Void)?

    static func installModules() {
        MainWindowModule.install()
        SettingsModule.install()
        IslandModule.install()
    }
}
