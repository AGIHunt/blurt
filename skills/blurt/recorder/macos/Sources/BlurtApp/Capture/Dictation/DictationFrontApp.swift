// The app a take belongs to (its History row, its style, what is remembered for it): the app in front — unless that is
// a background agent macOS brings forward for a moment (UserNotificationCenter's alert, loginwindow, Spotlight's
// panel): not an app people know by that name, nor one to remember a style for (dogfood 1.1.0: History rows read
// "UserNotificationCenter" with a blank icon, and Structured was remembered for it). Then the last ordinary app the
// user was in, or none. Blurt itself counts as in front (its own fields take dictation).
import AppKit

enum DictationFrontApp {
    private static var lastRegular: NSRunningApplication?
    private static var observer: NSObjectProtocol?

    /// Starts following which ordinary app was in front last (once; on the main thread).
    static func watch() {
        guard observer == nil else { return }
        if let f = NSWorkspace.shared.frontmostApplication, f.activationPolicy == .regular { lastRegular = f }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                     object: nil, queue: .main) { n in
            guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  a.activationPolicy == .regular else { return }
            lastRegular = a
        }
    }

    /// The take's app now: the one in front when it is an ordinary app (or Blurt), else the one that owns the menu bar
    /// (an alert in front doesn't take it), else the last ordinary one still running, else nil ("Unknown app").
    static var current: NSRunningApplication? {
        watch()
        let f = NSWorkspace.shared.frontmostApplication
        if let f = f, f.activationPolicy == .regular || f.processIdentifier == ProcessInfo.processInfo.processIdentifier { return f }
        if let m = NSWorkspace.shared.menuBarOwningApplication, m.activationPolicy == .regular { return m }
        if let l = lastRegular, !l.isTerminated { return l }
        return nil
    }
}
