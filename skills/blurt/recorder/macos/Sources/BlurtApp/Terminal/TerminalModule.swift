// P3 (mac-terminal) owns Terminal/. Called once at launch by AppEnvironment.installModules():
//   AppEnvironment.terminal  → TerminalHost: panes for the main window (makePane) and the dispatch panel (newSession)
//   AppEnvironment.dispatch  → the dispatch panel for item uids
// and starts what follows the sessions while the app runs: JobStore (FSEvents on $BLURT_HOME/jobs) and the status
// notifications. tmux sessions outlive the app; nothing here stops them on quit (app-runner sessions do end).
import AppKit
import BlurtCore

enum TerminalModule {
    static func install() {
        AppEnvironment.terminal = MainActor.assumeIsolated { TerminalHost.shared }
        AppEnvironment.dispatch = { uids in
            DispatchQueue.main.async { MainActor.assumeIsolated { DispatchPanel.show(items: uids) } }
        }
        JobStore.shared.start()
        MainActor.assumeIsolated {
            SessionsModel.shared.start()
            SessionNotifier.shared.start()
            TerminalSelfTests.install()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppRunner.shared.terminateAll() }
        }
        if ProcessInfo.processInfo.environment["BLURT_OPEN_SESSIONS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { SessionsWindowController.shared.show(job: nil) } }
        }
    }

    /// Show this session's terminal: the main window when it hosts panes, else the Sessions window.
    @MainActor
    static func reveal(job: String) {
        if let m = AppEnvironment.mainWindow { m.reveal(job: job) } else { SessionsWindowController.shared.show(job: job) }
    }
}

@MainActor
final class TerminalHost: @preconcurrency TerminalHosting {
    static let shared = TerminalHost()
    private var panes = 0

    func makePane() -> TerminalPaneHosting {
        panes += 1
        return SessionsPaneController(paneID: panes == 1 ? "main" : "pane-\(panes)")
    }

    func newSession(project: String?, items: [String]) { DispatchPanel.show(items: items, project: project) }
}

/// The Sessions window: a pane of its own, for when the main window isn't showing one (and "Open in New Window").
@MainActor
final class SessionsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SessionsWindowController(paneID: "window")
    private static var extra: [SessionsWindowController] = []
    let pane: SessionsPaneController

    init(paneID: String) {
        pane = SessionsPaneController(paneID: paneID)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 660),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: true)
        w.title = TL("window.title")
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.minSize = NSSize(width: 680, height: 380)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed         // "Open in New Window" means a window: two terminals side by side
        let tb = NSToolbar(identifier: "BlurtSessions")      // empty: a 52 pt unified title bar the header lines up with
        w.toolbar = tb
        w.toolbarStyle = .unified
        if let appearance = ProcessInfo.processInfo.environment["BLURT_APPEARANCE"] {
            w.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        super.init(window: w)
        w.delegate = self
        w.contentViewController = pane
        w.setContentSize(NSSize(width: 1080, height: 660))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `newWindow`: a second window for this job, next to the first (two terminals on two windows of a project).
    func show(job: String?, newWindow: Bool = false) {
        if newWindow, window?.isVisible == true {
            let c = SessionsWindowController(paneID: "window-\(Self.extra.count + 2)")
            Self.extra.append(c)
            c.show(job: job)
            if let f = window?.frame { c.window?.setFrameTopLeftPoint(NSPoint(x: f.minX + 32, y: f.maxY - 32)) }
            return
        }
        if window?.isVisible != true { window?.center() }
        NSApp.setActivationPolicy(.regular)
        activateApp()
        window?.makeKeyAndOrderFront(nil)
        pane.attach(job: job)
    }

    func windowWillClose(_ notification: Notification) {
        pane.surface.detach()           // ends only this window's tmux client
        Self.extra.removeAll { $0 === self }
        let others = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.canBecomeMain }
        if !others { DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) } }
    }
}
