// While a device controls this Mac, a small bar at the top of the main display says which, with Disconnect (docs/design/remote-1.1.md §3):
// whoever sits at this Mac always knows, and can end it in one click. Above everything but the lock screen, on every Space, never
// taking focus. It shows in the picture too, so the person controlling sees what the person here sees.
import AppKit
import BlurtCore

enum RemoteBanner {
    private static var panel: NSPanel?
    private static var label: NSTextField?
    private static var row: NSStackView?
    private static var shownFor: String?
    private static var pretended: String?

    static func start() {
        NotificationCenter.default.addObserver(forName: RemoteServer.statusChanged, object: nil, queue: .main) { _ in update() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            if panel?.isVisible == true { place() }
        }
        update()
    }

    /// From what the main thread was told (`shown`), on every status change: a bar that should show and doesn't (ordered out by
    /// something else, or never ordered in) comes back on the next one, not only when the name changes.
    private static func update() {
        let who = pretended ?? RemoteServer.shared.shown.connected
        guard who != shownFor || (who != nil && panel?.isVisible != true) else { return }
        shownFor = who
        guard let who else {
            panel?.orderOut(nil)
            return
        }
        let (_, t) = make()
        t.stringValue = T("remote.banner.controlling", PhoneStatus.name(who))
        place()
        panel?.orderFrontRegardless()
    }

    /// Test commands only: the bar as if this device controlled the Mac. Nothing does. Says where the bar and the island's middles are.
    static func pretend(_ who: String?) {
        pretended = who
        update()
        guard let p = panel, let s = NSScreen.screens.first else { return }
        emit(["event": "remote_bar", "window": p.windowNumber, "visible": p.isVisible, "bar_mid": Double(p.frame.midX),
              "island_mid": island.shapeMidX(on: s).map { Double($0) } ?? NSNull(), "screen_mid": Double(s.frame.midX)])
    }

    private static func make() -> (NSPanel, NSTextField) {
        if let panel, let label { return (panel, label) }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 30), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.appearance = NSAppearance(named: .darkAqua)
        bg.maskImage = .roundedMask(15)
        let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil) ?? NSImage())
        dot.symbolConfiguration = .init(pointSize: 8, weight: .regular)
        dot.contentTintColor = .systemOrange
        let t = NSTextField(labelWithString: "")
        t.font = .systemFont(ofSize: 13, weight: .medium)
        t.textColor = .white
        t.lineBreakMode = .byTruncatingMiddle
        let b = NSButton(title: T("remote.banner.disconnect"), target: Handler.shared, action: #selector(Handler.disconnect))
        b.bezelStyle = .push
        b.controlSize = .small
        b.font = .systemFont(ofSize: 12, weight: .semibold)
        b.appearance = NSAppearance(named: .darkAqua)
        let row = NSStackView(views: [dot, t, b])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        p.contentView = bg
        panel = p
        label = t
        Self.row = row
        return (p, t)
    }

    /// Top of the main display, just under the menu bar and centred under the island's shape, which is off the screen's middle while only
    /// one of its ears shows (28 pt with the cards' count). Centred on the screen, the two read as one of them being off. No island on this
    /// display: the screen's middle, not the middle of what a Dock at the side leaves.
    private static func place() {
        guard let p = panel, let row, let s = NSScreen.screens.first else { return }
        let f = s.visibleFrame
        let w = min(ceil((row.fittingSize.width + 18) / 2) * 2, f.width - 40)       // even: centred on a whole point
        let x = IslandLayout.hangX(under: island.shapeMidX(on: s) ?? s.frame.midX, width: w, in: s.frame, scale: s.backingScaleFactor)
        let at = NSRect(x: x, y: f.maxY - 30 - 6, width: w, height: 30)
        if p.frame != at { p.setFrame(at, display: true) }
    }

    /// The island's shape moved (an ear came or went, it opened): the bar goes with it.
    static func islandMoved() {
        if panel?.isVisible == true { place() }
    }

    private final class Handler: NSObject {
        static let shared = Handler()
        @objc func disconnect() { RemoteServer.shared.endByOwner() }
    }
}
