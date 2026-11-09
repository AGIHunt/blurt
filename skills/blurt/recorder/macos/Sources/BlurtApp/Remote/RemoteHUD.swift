// What the phone just did, on the Mac's screen: the user is looking here, not at the phone (docs/design/remote.md §Feedback).
// A small dark bezel near the bottom of the screen with the pointer: the keys pressed, for 0.7 s, and the modifiers held
// (sticky ⌘) for as long as they are. Plus "find my pointer", a ring that closes in on it. It never takes the focus or a
// click. Settings → iPhone turns the bezel off (record.remote.hud).
import AppKit
import BlurtCore
import BlurtRemoteKit

enum RemoteHUD {
    private static var panel: NSPanel?
    private static var label: NSTextField?
    private static var hide: DispatchWorkItem?
    private static var sticky: RemoteModifiers = []

    static var enabled: Bool { Config.shared["record.remote.hud"] as? Bool ?? true }

    private static func make() -> (NSPanel, NSTextField) {
        if let panel, let label { return (panel, label) }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 56), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.appearance = NSAppearance(named: .darkAqua)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        let t = NSTextField(labelWithString: "")
        t.font = .monospacedSystemFont(ofSize: 24, weight: .medium)
        t.textColor = .white
        t.alignment = .center
        t.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(t)
        NSLayoutConstraint.activate([t.centerXAnchor.constraint(equalTo: bg.centerXAnchor), t.centerYAnchor.constraint(equalTo: bg.centerYAnchor)])
        p.contentView = bg
        panel = p
        label = t
        return (p, t)
    }

    private static func place(_ text: String, keep: Bool, on display: CGDirectDisplayID? = nil) {
        let (p, t) = make()
        t.stringValue = text
        let w = max(72, ceil(t.intrinsicContentSize.width) + 40)
        let m = NSEvent.mouseLocation
        let chosen = display.flatMap { id in NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id } }
        let s = chosen ?? NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = s.visibleFrame
        p.setFrame(NSRect(x: f.midX - w / 2, y: f.minY + 72, width: w, height: 56), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        hide?.cancel()
        hide = nil
        guard !keep else { return }
        let h = DispatchWorkItem {
            if !sticky.isEmpty { return place(sticky.glyphs, keep: true) }
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = 0.18
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        }
        hide = h
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: h)
    }

    /// `on`: that display's bottom, wherever the pointer is (the pointer may not have arrived yet)
    static func show(_ text: String, on display: CGDirectDisplayID? = nil) {
        guard enabled, !text.isEmpty else { return }
        DispatchQueue.main.async { place(text, keep: false, on: display) }
    }

    static func sticky(_ m: RemoteModifiers) {
        DispatchQueue.main.async {
            sticky = m
            guard enabled else { return }
            if m.isEmpty { hide?.cancel(); panel?.orderOut(nil) } else { place(m.glyphs, keep: true) }
        }
    }

    /// A mint ring that closes in on the pointer.
    static func findCursor() {
        DispatchQueue.main.async {
            let m = NSEvent.mouseLocation
            let size: CGFloat = 360
            let w = NSPanel(contentRect: NSRect(x: m.x - size / 2, y: m.y - size / 2, width: size, height: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let v = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
            v.wantsLayer = true
            let r = CAShapeLayer()
            r.frame = v.bounds
            r.path = CGPath(ellipseIn: CGRect(x: size / 2 - 24, y: size / 2 - 24, width: 48, height: 48), transform: nil)
            r.fillColor = nil
            r.strokeColor = BrandColor.Island.fill.cgColor
            r.lineWidth = 4
            v.layer?.addSublayer(r)
            w.contentView = v
            w.orderFrontRegardless()
            let a = CABasicAnimation(keyPath: "transform.scale")
            a.fromValue = 6
            a.toValue = 1
            a.duration = 0.45
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            r.add(a, forKey: "in")
            findWindow = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                if findWindow === w { w.orderOut(nil); findWindow = nil }
            }
        }
    }
    private static var findWindow: NSPanel?
}
