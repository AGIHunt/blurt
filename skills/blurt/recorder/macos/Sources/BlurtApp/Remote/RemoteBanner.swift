// While a device controls this Mac, a small bar at the top of the main display says which, with Disconnect (docs/design/remote-1.1.md §3):
// whoever sits at this Mac always knows, and can end it in one click. Above everything but the lock screen, on every Space, never
// taking focus. It shows in the picture too, so the person controlling sees what the person here sees.
import AppKit
import BlurtCore
import BlurtRemoteKit

enum RemoteBanner {
    private static var panel: NSPanel?
    private static var label: NSTextField?
    private static var row: NSStackView?
    private static var shownFor: String?
    private static var pretended: String?
    private static var sendButton: NSButton?
    /// a line in place of "being controlled" for a moment (the clipboard sent), or while files go
    private static var transient: String?
    private static var transientTimer: Timer?
    private static var going: String?

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
        t.stringValue = transient ?? going ?? T("remote.banner.controlling", PhoneStatus.name(who))
        sendButton?.isHidden = !(pretended != nil || RemoteServer.shared.connectedTakesFiles)
        place()
        panel?.orderFrontRegardless()
    }

    /// The bar's line, from what it says now.
    private static func relabel() {
        guard let who = shownFor, let label else { return }
        label.stringValue = transient ?? going ?? T("remote.banner.controlling", PhoneStatus.name(who))
        sendButton?.isHidden = !(pretended != nil || RemoteServer.shared.connectedTakesFiles)
        place()
    }

    /// A line for 4 s ("Clipboard sent to …"), then the bar says who's controlling again.
    static func flash(_ text: String) {
        transient = text
        transientTimer?.invalidate()
        transientTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in
            transient = nil
            relabel()
        }
        relabel()
    }

    /// A file going to the device (Send Files…, Get Copied Items): how far, while it goes.
    static func transfer(_ t: RemoteTransfer, to who: String) {
        guard !t.incoming, !t.clip else { return }
        let bytes = ByteCountFormatter()
        bytes.countStyle = .file
        switch t.state {
        case .going, .waiting:
            let d = bytes.string(fromByteCount: Int64(t.done)), size = bytes.string(fromByteCount: Int64(t.size))
            if let i = t.index, let n = t.count {
                going = T("viewer.file.to.many", i, n, who, d, size)
            } else {
                going = T("viewer.file.to", who, d, size)
            }
        case .paused:
            going = T("remote.file.paused")
        case .done, .failed:
            going = nil
            if case let .failed(why) = t.state, why != "stopped" { flash(T("viewer.file.failed.other")) }
        }
        relabel()
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
        let send = NSButton(title: T("remote.banner.send_files"), target: Handler.shared, action: #selector(Handler.sendFiles))
        send.bezelStyle = .push
        send.controlSize = .small
        send.font = .systemFont(ofSize: 12, weight: .regular)
        send.appearance = NSAppearance(named: .darkAqua)
        sendButton = send
        let row = NSStackView(views: [dot, t, send, b])
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
        // files dropped on the bar go to the device, as Send Files… does
        let drop = DropView()
        drop.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(drop, positioned: .below, relativeTo: row)
        NSLayoutConstraint.activate([
            drop.leadingAnchor.constraint(equalTo: bg.leadingAnchor), drop.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            drop.topAnchor.constraint(equalTo: bg.topAnchor), drop.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
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
        @objc func sendFiles() {
            let p = NSOpenPanel()
            p.canChooseFiles = true
            p.canChooseDirectories = true
            p.allowsMultipleSelection = true
            p.prompt = T("remote.banner.send")
            NSApp.activate(ignoringOtherApps: true)
            guard p.runModal() == .OK, !p.urls.isEmpty else { return }
            RemoteServer.shared.sendFiles(p.urls)
        }
    }

    private final class DropView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.fileURL])
        }
        required init?(coder: NSCoder) { fatalError() }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            RemoteServer.shared.connectedTakesFiles ? .copy : []
        }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard RemoteServer.shared.connectedTakesFiles,
                  let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  !urls.isEmpty else { return false }
            RemoteServer.shared.sendFiles(urls)
            return true
        }
    }
}
