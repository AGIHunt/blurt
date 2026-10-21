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
    func reveal(job: String)
    func reveal(project: String)
    func showInbox()
}

// G0 stub defaults (v0.7 contract): until the main window embeds the terminal (P4), a job opens in P3's own
// Sessions window.
extension MainWindowHosting {
    func reveal(job: String) { SessionsWindowController.shared.show(job: job) }
    func reveal(project: String) { show() }
    func showInbox() { show() }
}

/// One embedded terminal (P3): the main window puts `viewController` where it wants it; `attach` shows that agent
/// session (nil = the session list / the most recent one).
protocol TerminalPaneHosting: AnyObject {
    var viewController: NSViewController { get }
    func attach(job: String?)
}

protocol TerminalHosting: AnyObject {
    func makePane() -> TerminalPaneHosting
    /// The dispatch panel for a new session in `project` (nil = the current project) with `items` preselected.
    func newSession(project: String?, items: [String])
}

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
    /// Embedded terminals and agent sessions (P3's TerminalModule.install()).
    static var terminal: TerminalHosting?
    /// The island at the top of the screen (P5's IslandModule.install()).
    static var island: IslandHosting?
    /// Hand items to an agent session: opens P3's dispatch panel (agent, mode, worktree, the concurrent-edit reminder).
    /// Replaces fixWithAgent.
    static var dispatch: (([String]) -> Void)?
    /// P4's AgentHub: create a process job and organise these captures.
    static var process: ((_ session: URL, _ captures: [Int]?, _ project: String?) -> Void)?

    static func installModules() {
        MainWindowModule.install()
        SettingsModule.install()
        TerminalModule.install()
    }
}
