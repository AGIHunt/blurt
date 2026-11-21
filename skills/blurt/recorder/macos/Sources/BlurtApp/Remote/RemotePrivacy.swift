// 隐私屏 / Black out remote screen (docs/design/remote-1.1.md §3): while the person controlling asks for it, every display of this Mac
// is covered by a sentence saying it's in use remotely, never plain black, so nobody walking by wonders what happened. The cover lets
// clicks through (the remote's clicks reach the windows under it) and is left out of the picture (RemoteScreen excludes its windows),
// so the person controlling sees the real desktop. Off when they turn it off or the session ends.
import AppKit
import BlurtCore

enum RemotePrivacy {
    private static var covers: [NSWindow] = []
    /// the covers' window numbers, for RemoteScreen's filter (read on other queues)
    private(set) static var windowIDs: Set<CGWindowID> = []
    private static let lock = NSLock()
    static var onChange: (() -> Void)?

    static var ids: Set<CGWindowID> { lock.lock(); defer { lock.unlock() }; return windowIDs }

    static func set(_ on: Bool, who: String) {
        DispatchQueue.main.async {
            covers.forEach { $0.orderOut(nil) }
            covers = on ? NSScreen.screens.map { cover($0, who: who) } : []
            lock.lock()
            windowIDs = Set(covers.map { CGWindowID($0.windowNumber) })
            lock.unlock()
            emit(["event": "remote_privacy", "on": on])
            onChange?()
        }
    }

    private static func cover(_ s: NSScreen, who: String) -> NSWindow {
        let w = NSWindow(contentRect: s.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .screenSaver
        w.backgroundColor = .black
        w.isOpaque = true
        w.ignoresMouseEvents = true
        w.sharingType = .none
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let t = NSTextField(wrappingLabelWithString: T("remote.privacy.cover", PhoneStatus.name(who)))
        t.font = .systemFont(ofSize: 28, weight: .medium)
        t.textColor = NSColor(white: 0.85, alpha: 1)
        t.alignment = .center
        t.translatesAutoresizingMaskIntoConstraints = false
        let v = NSView()
        v.addSubview(t)
        NSLayoutConstraint.activate([
            t.centerXAnchor.constraint(equalTo: v.centerXAnchor), t.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            t.widthAnchor.constraint(lessThanOrEqualTo: v.widthAnchor, multiplier: 0.7),
        ])
        w.contentView = v
        w.setFrame(s.frame, display: true)
        w.orderFrontRegardless()
        return w
    }
}
