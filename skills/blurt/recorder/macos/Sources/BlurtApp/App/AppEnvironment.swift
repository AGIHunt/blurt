// Seams between the app shell and the parts the other packages add, so nobody edits someone else's files
// (docs/design/next-round.md, v0.7 contract, "所有权"):
//   MainWindowModule (P4)  → mainWindow                      SettingsModule (P4) → settings, openURL
//   TerminalModule (P3)    → terminal, dispatch              IslandModule (P5)   → island
//   AgentHub (P4)          → process
// The shell calls the install()s once at launch (menu-bar app only) and shows the matching UI only when a hook is set.
import AppKit

protocol MainWindowHosting: AnyObject {
    func show()
    func reveal(uid: String)
    func reveal(session: URL)
    func reveal(job: String)
    func reveal(project: String)
    func showInbox()
}

protocol SettingsHosting: AnyObject {
    /// nil = the last pane / the first one
    func show(pane: String?)
}

/// One embedded terminal (P3, SwiftTerm): the main window puts `viewController` where it wants it.
protocol TerminalPaneHosting: AnyObject {
    var viewController: NSViewController { get }
    /// nil = detach (show nothing)
    func attach(job: String?)
}

protocol TerminalHosting: AnyObject {
    func makePane() -> TerminalPaneHosting
    /// "New session…": pick the project, agent and worktree, then start it.
    func newSession(project: String?, items: [String])
}

/// The notch island (P5): the project switcher and the quiet in-island line (K4's notification rules).
protocol IslandHosting: AnyObject {
    func showSwitcher()
    func toast(_ text: String, actionTitle: String?, action: (() -> Void)?)
}

enum AppEnvironment {
    static var mainWindow: MainWindowHosting?
    static var settings: SettingsHosting?
    static var terminal: TerminalHosting?
    static var island: IslandHosting?
    /// Hand item uids to an agent session in Blurt: P3's dispatch panel (agent, mode, worktree, the concurrent-edit
    /// reminder). nil until the terminal module is installed — the main window then dispatches with the defaults.
    static var dispatch: (([String]) -> Void)?
    /// v0.6's background "let the agent fix" (FixRunner). Replaced by `dispatch`; goes away when P3 lands.
    static var fixWithAgent: (([String]) -> Void)?
    /// Process captures: a session dir, which captures (shots.jsonl n; nil = the whole session) and the project to file
    /// them under (nil = let the AI route each item). Set by AgentHub (P4): it creates the process job (K4).
    static var process: ((_ session: URL, _ captures: [Int]?, _ project: String?) -> Void)?
    /// blurt:// and blurt-app:// URLs handed to the app by macOS (blurt://item/<uid>, session/<path>, record, snap…).
    /// Return false to let the shell try its own handling (record / snap).
    static var openURL: ((URL) -> Bool)?

    static func installModules() {
        MainWindowModule.install()
        SettingsModule.install()
        TerminalModule.install()
        IslandModule.install()
    }
}
