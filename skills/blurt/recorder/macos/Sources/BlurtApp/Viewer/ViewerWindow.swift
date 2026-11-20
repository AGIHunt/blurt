// A window per computer (docs/design/remote-desktop-viewer.md): the host's screen, sized to the window; a toolbar with the computer's name,
// the path and round trip, the display switcher (two displays or more), Keys to Remote, the picture's quality and a ⋯ menu. Several
// computers are several windows, and macOS merges them into tabs when asked. Keys go only to the window in front.
//
// Each window has its own link, so its own session: a second window on another display of the same computer is a second session, which
// the host keeps beside the first (`hello.features` "window").
import AppKit
import BlurtCore
import BlurtRemoteKit
import Network

final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuDelegate {
    private static var windows: [ViewerWindowController] = []

    let computer: RemoteComputer
    let link: RemoteViewerLink
    private let screen: RemoteViewerScreen
    private let picture = ViewerPictureView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    private let overlay = NSStackView()
    private let overlayText = NSTextField(wrappingLabelWithString: "")
    private let overlayButton = NSButton(title: "", target: nil, action: nil)
    /// another window of a computer already open: the host keeps it beside the first
    private let second: Bool

    private(set) var captured = false
    private var host: RemoteHost { link.computer.host }
    private var displays: [RemoteDisplay] = []
    private var shownDisplay: String?
    /// the display this window keeps to; nil follows the host's pointer
    private var pinned: String?
    private var quality: RemoteScreenQuality {
        get { RemoteScreenQuality(rawValue: Config.shared["record.viewer.quality"] as? String ?? "") ?? .auto }
        set { Config.shared.set("record.viewer.quality", newValue == .auto ? nil : newValue.rawValue) }
    }
    /// ⌘ as Ctrl and ⌃ as the Windows / Super key on Windows and Linux (the ⋯ menu)
    private var mapping: Bool {
        get { Config.shared["record.viewer.map_modifiers"] as? Bool ?? true }
        set { Config.shared.set("record.viewer.map_modifiers", newValue ? nil : false) }
    }
    /// the app in front on the remote (its `front`): a terminal there takes dictation without a closing full stop
    private var remoteFront: RemoteFront?
    private var remoteCanControl = true
    /// keys sent as a terminal's copy / paste: their release isn't sent again
    private var terminalKeys: Set<UInt16> = []

    /// Dictation with this window in front types on the remote (remote-1.1.md §4): the window in front, connected, allowed to control.
    static func dictationTarget() -> ViewerWindowController? {
        guard NSApp.isActive, let k = NSApp.keyWindow else { return nil }
        return windows.first { $0.window === k && $0.link.state == .connected && $0.remoteCanControl }
    }

    /// Sends a take to the remote; the host types it (and refuses it at its lock screen or in a password field).
    func typeOnRemote(_ text: String) {
        var t = text
        if let f = remoteFront, RemoteTerminals.isTerminal(f.bundle) {
            while let last = t.last, "。.".contains(last) { t.removeLast() }
        }
        guard !t.isEmpty else { return }
        link.send(.text(t))
        emit(["event": "dictation_insert", "result": "remote", "chars": t.count])
    }

    private lazy var files: ViewerFileSender = {
        let f = ViewerFileSender(link: link)
        f.onState = { [weak self] state, what in
            guard let self else { return }
            switch state {
            case "sending": self.picture.showHint(T("viewer.file.sending", what), seconds: nil)
            case "saved": self.picture.showHint(T("viewer.file.saved", what), seconds: 5)
            default:
                let k = ["space", "too_big", "locked"].contains(what) ? what : "other"
                self.picture.showHint(T("viewer.file.failed.\(k)"), seconds: 5)
            }
        }
        return f
    }()

    /// The host takes files (its session lists `files`)
    private var hostTakesFiles: Bool { link.session?.features?.contains(RemoteFeature.files) == true }

    func sendFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard hostTakesFiles else { return picture.showHint(T("viewer.file.failed.other"), seconds: 3) }
        files.send(urls)
    }

    @objc private func sendSecureAttention() { link.send(.system(.secureAttention)) }

    @objc private func chooseFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        guard let w = window else { return }
        p.beginSheetModal(for: w) { [weak self] r in
            if r == .OK { self?.sendFiles(p.urls) }
        }
    }

    /// 隐私屏 asked of the host this session (off at every new session: the host drops it when a session ends)
    private var privacy = false

    private var shareClipboard: Bool {
        get { Config.shared["record.viewer.clipboard"] as? Bool ?? true }
        set { Config.shared.set("record.viewer.clipboard", newValue ? nil : false) }
    }
    private var sentMods: RemoteModifiers = []
    private var release = RemoteReleaseChord()
    private var screenOn = false
    /// the path the picture was last asked for on
    private var pictureRoute: RemoteViewerLink.Route?
    private var lastPixels = RemotePixelSize(width: 0, height: 0)
    private var resizeWait: DispatchWorkItem?
    private var pasteboardSeen = 0
    private var held = Set<UInt16>()

    // toolbar
    private let displayButton = NSButton(title: "", target: nil, action: nil)
    private let keysButton = NSButton(title: "", target: nil, action: nil)
    private let qualityButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let moreButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var displayItem: NSToolbarItem?

    // MARK: opening

    /// The computer's window: in front if one is open, else a new one. `adopting`: the session a pairing just opened. `display`: another
    /// window on that display (Open in New Window).
    @MainActor
    static func open(_ c: RemoteComputer, adopting: RemoteViewerLink? = nil, display: String? = nil) {
        if display == nil, adopting == nil, let w = windows.first(where: { $0.computer.id == c.id }) {
            w.showWindow(nil)
            w.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let second = windows.contains { $0.computer.id == c.id }
        let link: RemoteViewerLink
        if let adopting { link = adopting } else {
            guard let key = ViewerStore.shared.key(c) else { return }
            link = RemoteViewerLink(computer: c, key: key, deviceName: Host.current().localizedName ?? "Mac")
        }
        let w = ViewerWindowController(c, link: link, second: second, display: display)
        windows.append(w)
        w.showWindow(nil)
        w.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        emit(["event": "viewer_window", "state": "open", "second": second, "platform": c.platform ?? ""])
    }

    /// the window in front, or the newest (tests)
    static var front: ViewerWindowController? {
        (NSApp.keyWindow?.windowController as? ViewerWindowController) ?? windows.last
    }

    static func closeAll(of id: String) { windows.filter { $0.computer.id == id }.forEach { $0.close() } }

    private init(_ c: RemoteComputer, link: RemoteViewerLink, second: Bool, display: String?) {
        computer = c
        self.link = link
        self.second = second
        pinned = display
        screen = RemoteViewerScreen(link: link)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = c.name
        w.tabbingIdentifier = "blurt.viewer"
        w.tabbingMode = .automatic
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.minSize = NSSize(width: 480, height: 320)
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("BlurtViewer.\(c.id)")
        if !w.setFrameUsingName("BlurtViewer.\(c.id)") { w.center() }
        super.init(window: w)
        w.delegate = self
        picture.controller = self
        let content = NSView()
        content.addSubview(picture)
        picture.autoresizingMask = [.width, .height]
        picture.frame = content.bounds
        w.contentView = content
        picture.acceptFiles()
        buildOverlay(in: content)
        buildToolbar(w)
        wire()
        if link.state == .connected { connected() } else { stateChanged(link.state) }
        link.start()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: the link

    private func wire() {
        if second { link.extraWindow = true }
        link.onState = { [weak self] s in MainActor.assumeIsolated { self?.stateChanged(s) } }
        link.onRoute = { [weak self] r, rtt in MainActor.assumeIsolated { self?.routeChanged(r, rtt) } }
        link.onComputer = { c in MainActor.assumeIsolated { ViewerStore.shared.save(c) } }
        link.onVideo = { [weak screen] d in screen?.packet(d) }
        link.onCursor = { [weak self] d in
            guard let c = RemoteCursor(d) else { return }
            DispatchQueue.main.async { self?.picture.cursor(c) }
        }
        screen.onFrame = { [weak self] image, _ in DispatchQueue.main.async { self?.picture.show(image) } }
        link.onMessage = { [weak self] m in MainActor.assumeIsolated { self?.heard(m) } }
    }

    private func heard(_ m: ToPhone) {
        switch m {
        case .fileProgress, .fileSaved, .fileFailed:
            files.heard(m)
        case let .notice(text):
            // the host's own words (a new device paired there): a notification, so it's seen even with this window behind
            Notify.post(title: link.computer.name, body: text, uid: "remote-notice-\(link.computer.id)")
        case let .screenView(w, h, codec, display, features):
            screen.view(codec: codec, features: features)
            fit(CGSize(width: w, height: h))
            shownDisplay = display
            updateDisplays()
        case let .displays(list):
            displays = list
            if let p = pinned, !list.contains(where: { $0.id == p }) { pinned = nil }
            updateDisplays()
        case let .cursorShape(png, hx, hy, w, h):
            picture.shape(png: png, hot: CGPoint(x: hx, y: hy), size: CGSize(width: w, height: h))
        case let .clipboard(t):
            guard captured, shareClipboard, RemoteClipboard.fits(t) else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(t, forType: .string)
            pasteboardSeen = pb.changeCount
        case let .screenFailed(why):
            screenOn = false
            let name = link.computer.name
            // the host's own sentence is for phones (English only): the viewer says it in its own words
            let key = ["off": "viewer.screen_off", "permission": "viewer.screen_permission", "one_display": "viewer.one_display"][why]
            // Try Again asks for the screen once more: a permission given, or the host's Remote Desktop dialog answered since
            showOverlay(T(key ?? "viewer.screen_failed", name), button: why == "off" ? nil : (T("viewer.retry"), #selector(retryScreen)))
        case let .screenLocked(locked):
            // the stream stops at a lock screen this host can't show: the last picture stays, darker, and says why
            guard screenOn else { return }
            if locked {
                picture.stale = true
                // GNOME ends screen sharing at its lock; its own Remote Login reaches the login screen
                showOverlay(T(host == .linux ? "viewer.locked.linux" : "viewer.locked", link.computer.name), button: nil)
            } else {
                hideOverlay()
                link.send(.requestKeyframe)
            }
            emit(["event": "viewer_locked", "locked": locked])
        case let .front(f):
            remoteFront = f
        case let .canControl(ok):
            remoteCanControl = ok
            // clicks and keys go nowhere until it's allowed there: said for as long as it lasts
            if ok { picture.hideHint() } else { picture.showHint(T("viewer.no_control", link.computer.name), seconds: nil) }
        case let .session(i):
            remoteCanControl = i.canControl
            window?.title = i.macName
            if !i.canControl { picture.showHint(T("viewer.no_control", i.macName), seconds: nil) }
            updateMore()
        default: break
        }
    }

    private func stateChanged(_ s: RemoteViewerLink.State) {
        let name = link.computer.name
        emit(["event": "viewer_link", "state": "\(s)", "route": link.route.map { "\($0)" } ?? "", "trying": link.trying.map { "\($0)" } ?? "", "lost": link.lostWhy])
        switch s {
        case .connected: connected()
        case .connecting:
            // a drop: the last picture stays, darker, while it comes back by itself (it never asks to pair again)
            stopPicture(keep: true)
            showOverlay(T(picture.hasPicture ? "viewer.reconnecting" : "viewer.connecting"), button: nil)
        case .unreachable:
            stopPicture(keep: true)
            // a Mac that restarted with FileVault on waits for its disk password at the computer: nothing reaches it before that
            showOverlay(T(host == .mac ? "viewer.unreachable.mac" : "viewer.unreachable", name), button: (T("viewer.retry"), #selector(retry)))
        case .waiting: showOverlay(T("viewer.connecting"), button: nil)
        case .forgotten:
            stopPicture()
            showOverlay(T("viewer.forgotten", name), button: nil)
        case .replaced:
            stopPicture()
            showOverlay(T("viewer.replaced", name), button: (T("viewer.take_over"), #selector(takeOver)))
        case .ended:
            stopPicture()
            showOverlay(T("viewer.ended", name), button: (T("viewer.reconnect"), #selector(takeOver)))
        case .away(.noDirect):
            stopPicture()
            showOverlay(T("viewer.no_direct"), button: (T("viewer.retry"), #selector(retry)))
        case .away(.relayDown):
            // still trying, now through the public connection service as well
            stopPicture(keep: true)
            showOverlay(T("viewer.relay_down", name), button: (T("viewer.retry"), #selector(retry)))
        case .away(.busy):
            // over today's limit: it waits by itself (30 s, 2 min, 10 min, hourly); asking again now changes nothing
            stopPicture()
            showOverlay(T("viewer.busy"), button: nil)
        }
        if !second {
            switch s {
            case let .away(a): ViewerStore.shared.awayChanged(computer.id, a)
            case .connected: ViewerStore.shared.awayChanged(computer.id, nil)
            default: break
            }
        }
        ViewerStore.shared.liveChanged(computer.id, route: link.route, rtt: link.rtt, open: s == .connected && !second)
        updateSubtitle()
    }

    private func connected() {
        hideOverlay()
        updateMore()
        startPicture()
        ViewerStore.shared.liveChanged(computer.id, route: link.route, rtt: link.rtt, open: !second)
        if let p = pinned { link.send(.showDisplay(p)) }
        // after a drop the host has taken the cover down: asked again
        if privacy { link.send(.privacyScreen(true)) }
        // a window that opens in front, captured: the mouse and keys go to the computer it shows
        if window?.isKeyWindow == true { setCaptured(true) }
    }

    private func routeChanged(_ r: RemoteViewerLink.Route?, _ rtt: Double?) {
        updateSubtitle()
        updateQuality()      // another path may cost data, or no longer
        if link.state == .connected, !second { ViewerStore.shared.liveChanged(computer.id, route: r, rtt: rtt, open: true) }
        // away and back: the picture's ceiling changes with the path (a new round trip alone changes nothing)
        if screenOn, r != pictureRoute { askForPicture() }
        pictureRoute = r
    }

    /// The window takes the host's shape: no bars beside the picture, and resizing keeps it (full screen is the system's own).
    private func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let changed = picture.source != size
        picture.source = size
        guard changed, let w = window, !w.styleMask.contains(.fullScreen) else { return }
        w.contentAspectRatio = size
        let content = w.contentRect(forFrameRect: w.frame)
        var target = NSRect(x: content.minX, y: content.maxY, width: content.width, height: (content.width * size.height / size.width).rounded())
        if let screen = w.screen?.visibleFrame, target.height > screen.height - 40 {
            target.size.height = screen.height - 80
            target.size.width = (target.height * size.width / size.height).rounded()
        }
        target.origin.y = content.maxY - target.height
        w.setFrame(w.frameRect(forContentRect: target), display: true, animate: false)
    }

    private func updateSubtitle() {
        guard let w = window else { return }
        // before it's up: the way being tried (公共连接服务 until the move); then the real path and the round trip
        guard link.state == .connected else { w.subtitle = ViewerStore.trying(link.trying); return }
        let path = ViewerStore.path(link.route)
        w.subtitle = link.rtt.map { T("viewer.path_rtt", path, max(1, Int(($0 * 1000).rounded()))) } ?? path
    }

    @objc private func retry() {
        if !second { ViewerStore.shared.awayChanged(computer.id, nil) }
        link.tryAgain()
    }
    @objc private func takeOver() { link.takeBack() }
    @objc private func retryScreen() {
        guard link.state == .connected else { return retry() }
        hideOverlay()
        startPicture()
    }

    // MARK: the picture

    private var local: Bool { link.route == .local }

    private func plan() -> RemoteScreenRequest {
        let px = picture.pixels
        lastPixels = px
        let constrained = NWPathLowData.on
        let panel = window?.screen?.maximumFramesPerSecond ?? 60
        return RemoteScreenPlan(quality, local: local, lowData: constrained, window: px, panel: panel)
            .request(display: pinned, features: RemoteViewerScreen.features, window: px)
    }

    private func startPicture() {
        screenOn = true
        pictureRoute = link.route
        screen.start(plan())
        emit(["event": "viewer_screen", "state": "on", "width": lastPixels.width, "height": lastPixels.height, "quality": quality.rawValue])
    }

    /// Another size, quality or path: the host starts its stream again at the new size.
    private func askForPicture() {
        guard screenOn else { return }
        screen.change(plan())
    }

    /// `keep`: the last frame stays, darker (a drop, a lock), instead of a black window.
    private func stopPicture(keep: Bool = false) {
        guard screenOn else { if !keep { picture.clear() }; return }
        screenOn = false
        screen.stop(tell: link.state == .connected)
        if keep { picture.stale = true } else { picture.clear() }
        setCaptured(false)
    }

    func windowDidResize(_ n: Notification) {
        // resizing asks for a new size, once the window has settled
        resizeWait?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.screenOn, self.picture.pixels != self.lastPixels else { return }
            self.askForPicture()
        }
        resizeWait = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    func windowDidChangeBackingProperties(_ n: Notification) { windowDidResize(n) }

    // MARK: keys

    func windowDidBecomeKey(_ n: Notification) {
        if link.state == .connected, !captured { setCaptured(true) }
    }

    /// Keys go only to the window in front: another window or app in front gives them back.
    func windowDidResignKey(_ n: Notification) {
        // a helper panel (an input method's, the accent picker) taking the key status for a moment isn't leaving the window: checked once
        // the new key window is known
        DispatchQueue.main.async { [weak self] in
            guard let self, !ViewerKeyboard.holdsKeys(self.window) else { return }
            self.setCaptured(false)
        }
    }

    func setCaptured(_ on: Bool) {
        guard on != captured, !on || link.state == .connected else { return }
        captured = on
        picture.captured = on
        keysButton.state = on ? .on : .off
        if on {
            let system = ViewerKeyboard.shared.capture(for: self)
            release = RemoteReleaseChord()
            sentMods = []
            held = []
            link.send(.keysCaptured(true))
            // what was copied here pastes there
            let pb = NSPasteboard.general
            if shareClipboard, link.hostTakesViewer, pb.changeCount != pasteboardSeen, let t = pb.string(forType: .string), RemoteClipboard.fits(t) {
                link.send(.clipboard(t))
            }
            pasteboardSeen = pb.changeCount
            picture.showHint(system ? T("viewer.release") : T("viewer.release.app_only"))
        } else {
            ViewerKeyboard.shared.release(self)
            // nothing stays held on the host
            if !sentMods.isEmpty { link.send(.mods([])) }
            for code in held { if let n = RemoteViewerKeys.name(macKeyCode: code) { link.send(.key(RemoteChord([], n), down: false)) } }
            held = []
            sentMods = []
            link.send(.keysCaptured(false))
            link.send(.releaseAll)
        }
    }

    @objc private func toggleKeys() { setCaptured(!captured) }

    /// A key from the capture (ViewerKeyboard), on the main thread.
    func key(_ e: ViewerKeyboard.Event) {
        let mods = RemoteModifiers(e.flags)
        if e.modifiersOnly {
            if release.modifiers(mods) {
                setCaptured(false)
                return
            }
            let mapped = RemoteViewerKeys.map(mods.subtracting(.function), from: .mac, to: host, mapping: mapping)
            if mapped != sentMods {
                sentMods = mapped
                link.send(.mods(mapped))
            }
            // Caps Lock toggles: a press each way
            if e.code == 57 { link.send(.key(RemoteChord([], "CapsLock"), down: nil)) }
            return
        }
        release.key()
        guard let name = RemoteViewerKeys.name(macKeyCode: e.code) else { return }
        // ⌘C / ⌘V into a terminal on Windows or Linux: copy and paste there (Ctrl+Shift+C / V), not an interrupt (remote-1.1.md §5)
        if e.down, host != .mac, mapping, name == "C" || name == "V", mods.subtracting(.function) == [.command],
           let f = remoteFront, RemoteTerminals.isTerminal(f.bundle) {
            link.send(.mods([.control, .shift]))
            link.send(.key(RemoteChord([], name), down: nil))
            link.send(.mods(sentMods))
            terminalKeys.insert(e.code)
            return
        }
        if !e.down, terminalKeys.remove(e.code) != nil { return }
        if e.down { held.insert(e.code) } else { held.remove(e.code) }
        // a key held down repeats as a key down again: the host presses it again (a posted key doesn't repeat by itself)
        link.send(.key(RemoteChord([], name), down: e.down))
    }

    // MARK: the overlay

    private func buildOverlay(in content: NSView) {
        overlay.orientation = .vertical
        overlay.alignment = .centerX
        overlay.spacing = 12
        overlayText.font = .systemFont(ofSize: 15, weight: .medium)
        overlayText.textColor = .white
        overlayText.alignment = .center
        overlayText.preferredMaxLayoutWidth = 420
        // drawn by its own layer: a standard bezel over the picture's layer didn't show (measured: attached, framed, not drawn)
        overlay.wantsLayer = true
        overlayButton.isBordered = false
        overlayButton.wantsLayer = true
        overlayButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        overlayButton.layer?.cornerRadius = 7
        overlayButton.translatesAutoresizingMaskIntoConstraints = false
        overlayButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        overlayButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        overlayButton.target = self
        overlay.addArrangedSubview(overlayText)
        overlay.addArrangedSubview(overlayButton)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(overlay)
        NSLayoutConstraint.activate([overlay.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                                     overlay.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                                     overlay.widthAnchor.constraint(lessThanOrEqualToConstant: 440)])
    }

    private func showOverlay(_ text: String, button: (String, Selector)?) {
        overlay.isHidden = false
        overlayText.stringValue = text
        overlayButton.isHidden = button == nil
        if let (t, a) = button {
            overlayButton.attributedTitle = NSAttributedString(string: "  \(t)  ", attributes: [.foregroundColor: NSColor.white,
                                                                                                .font: NSFont.systemFont(ofSize: 13, weight: .medium)])
            overlayButton.action = a
        }
    }

    private func hideOverlay() { overlay.isHidden = true }

    // MARK: the toolbar

    private enum Item {
        static let displays = NSToolbarItem.Identifier("viewer.displays")
        static let keys = NSToolbarItem.Identifier("viewer.keys")
        static let quality = NSToolbarItem.Identifier("viewer.quality")
        static let more = NSToolbarItem.Identifier("viewer.more")
    }

    private func buildToolbar(_ w: NSWindow) {
        let t = NSToolbar(identifier: "blurt.viewer")
        t.delegate = self
        t.displayMode = .iconOnly
        t.allowsUserCustomization = false
        w.toolbar = t
        w.toolbarStyle = .unified
        w.titleVisibility = .visible

        displayButton.bezelStyle = .texturedRounded
        displayButton.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: nil)
        displayButton.imagePosition = .imageLeading
        displayButton.target = self
        displayButton.action = #selector(showDisplays(_:))

        keysButton.setButtonType(.pushOnPushOff)
        keysButton.bezelStyle = .texturedRounded
        keysButton.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: T("viewer.keys"))
        keysButton.title = T("viewer.keys")
        keysButton.imagePosition = .imageLeading
        keysButton.target = self
        keysButton.action = #selector(toggleKeys)
        keysButton.toolTip = T("viewer.release")

        qualityButton.bezelStyle = .texturedRounded
        qualityButton.menu?.delegate = self
        moreButton.bezelStyle = .texturedRounded
        moreButton.menu?.delegate = self
        updateQuality()
        updateMore()
    }

    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Item.displays, Item.keys, Item.quality, Item.more]
    }

    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(t) }

    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Item.displays:
            item.view = displayButton
            item.label = T("viewer.display.label")
            displayButton.isHidden = displays.count < 2
            displayItem = item
        case Item.keys:
            item.view = keysButton
            item.label = T("viewer.keys")
        case Item.quality:
            item.view = qualityButton
            item.label = T("viewer.quality")
        case Item.more:
            item.view = moreButton
            item.label = T("viewer.more")
        default: return nil
        }
        return item
    }

    private func updateQuality() {
        let m = qualityButton.menu ?? NSMenu()
        m.removeAllItems()
        let head = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        head.image = NSImage(systemSymbolName: "dial.medium", accessibilityDescription: T("viewer.quality"))
        head.title = T("viewer.quality.\(quality.rawValue)")
        m.addItem(head)
        for q in RemoteScreenQuality.allCases {
            let i = NSMenuItem(title: T("viewer.quality.\(q.rawValue)"), action: #selector(chooseQuality(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = q.rawValue
            i.state = q == quality ? .on : .off
            m.addItem(i)
        }
        // on a phone's hotspot or cellular: the picture costs data, and Data Saver is the choice that spends little
        if NWPathLowData.costsData {
            m.addItem(.separator())
            let note = NSMenuItem(title: T("viewer.quality.costs_data"), action: nil, keyEquivalent: "")
            note.isEnabled = false
            m.addItem(note)
        }
        qualityButton.menu = m
        qualityButton.toolTip = T("viewer.quality")
    }

    @objc private func chooseQuality(_ i: NSMenuItem) {
        guard let q = (i.representedObject as? String).flatMap(RemoteScreenQuality.init(rawValue:)) else { return }
        quality = q
        updateQuality()
        askForPicture()
    }

    @objc private func allowShortcuts() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    private func updateMore() {
        let m = moreButton.menu ?? NSMenu()
        m.removeAllItems()
        let head = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        head.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: T("viewer.more"))
        m.addItem(head)
        let map = NSMenuItem(title: T("viewer.map_modifiers"), action: host == .mac ? nil : #selector(toggleMapping), keyEquivalent: "")
        map.target = self
        map.state = mapping && host != .mac ? .on : .off
        map.toolTip = T("viewer.map_modifiers.tip")
        m.addItem(map)
        let clip = NSMenuItem(title: T("viewer.clipboard"), action: #selector(toggleClipboard), keyEquivalent: "")
        clip.target = self
        clip.state = shareClipboard ? .on : .off
        m.addItem(clip)
        // a Windows host: its lock and login screens want Ctrl+Alt+Del (sent by the system service where it's on)
        if host == .windows {
            let sas = NSMenuItem(title: T("viewer.ctrl_alt_del"), action: #selector(sendSecureAttention), keyEquivalent: "")
            sas.target = self
            m.addItem(sas)
        }
        if hostTakesFiles {
            let f = NSMenuItem(title: T("viewer.send_files"), action: #selector(chooseFiles), keyEquivalent: "")
            f.target = self
            m.addItem(f)
        }
        // only where the host can (its session lists `privacy`)
        if link.session?.features?.contains(RemoteFeature.privacy) == true {
            let p = NSMenuItem(title: T("viewer.privacy"), action: #selector(togglePrivacy), keyEquivalent: "")
            p.target = self
            p.state = privacy ? .on : .off
            p.toolTip = T("viewer.privacy.tip")
            m.addItem(p)
        }
        // without Input Monitoring ⌘Tab and the like stay on this Mac: the way to change that, where it's missing
        if !ViewerKeyboard.systemShortcuts {
            m.addItem(.separator())
            let allow = NSMenuItem(title: T("viewer.allow_shortcuts"), action: #selector(allowShortcuts), keyEquivalent: "")
            allow.target = self
            m.addItem(allow)
        }
        moreButton.menu = m
        moreButton.toolTip = T("viewer.more")
    }

    @objc private func toggleMapping() {
        mapping.toggle()
        updateMore()
        // what's held now is held as the new mapping says
        if captured { sentMods = []; link.send(.mods([])) }
    }

    @objc private func togglePrivacy() {
        privacy.toggle()
        link.send(.privacyScreen(privacy))
        updateMore()
    }

    @objc private func toggleClipboard() {
        shareClipboard.toggle()
        updateMore()
    }

    // MARK: displays

    private func updateDisplays() {
        // shown only when the host has more than one display (NSToolbarItem.isHidden is macOS 15's: the view goes instead)
        displayButton.isHidden = displays.count < 2
        if #available(macOS 15.0, *) { displayItem?.isHidden = displays.count < 2 }
        let n = displays.firstIndex { $0.id == shownDisplay }.map { $0 + 1 } ?? 1
        displayButton.title = T("viewer.display", n, displays.count)
    }

    @objc private func showDisplays(_ sender: NSButton) {
        let p = NSPopover()
        p.behavior = .transient
        let v = ViewerDisplayMap(displays: displays, shown: shownDisplay, following: pinned == nil) { [weak self, weak p] action in
            guard let self else { return }
            switch action {
            case let .show(id):
                self.pinned = id
                self.link.send(.showDisplay(id))
            case .follow:
                self.pinned = nil
                self.link.send(.showDisplay(nil))
            case let .newWindow(id):
                ViewerWindowController.open(self.computer, display: id)
            }
            p?.close()
        }
        p.contentViewController = v
        p.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    // MARK: closing

    func windowWillClose(_ n: Notification) {
        setCaptured(false)
        screen.stop(tell: true)
        link.stop()
        if !second { ViewerStore.shared.liveChanged(computer.id, route: nil, rtt: nil, open: false) }
        Self.windows.removeAll { $0 === self }
        emit(["event": "viewer_window", "state": "closed"])
    }

    // MARK: tests

    #if DEBUG || BLURT_TEST_HOOKS
    /// `viewer demo`: the window as it looks connected, with a still picture and these displays (screenshots; no session behind it).
    func testShow(still: CGImage, size: CGSize, displays list: [RemoteDisplay], shown: String?, route: RemoteViewerLink.Route, rtt: Double) {
        hideOverlay()
        displays = list
        shownDisplay = shown
        fit(size)
        picture.show(still: still)
        updateDisplays()
        let path = ViewerStore.path(route)
        window?.subtitle = T("viewer.path_rtt", path, Int((rtt * 1000).rounded()))
        captured = true
        keysButton.state = .on
        picture.showHint(T("viewer.release"), seconds: 30)
    }

    func testOpenDisplays() { showDisplays(displayButton) }

    /// what the overlay says and offers (`viewer state`)
    var testOverlay: [String: Any] {
        ["shown": !overlay.isHidden, "text": overlayText.stringValue, "button": overlayButton.isHidden ? "" : overlayButton.title,
         "buttonFrame": NSStringFromRect(overlayButton.frame), "attached": overlayButton.superview != nil,
         "buttonInWindow": NSStringFromRect(overlayButton.convert(overlayButton.bounds, to: nil)), "stack": NSStringFromRect(overlay.frame)]
    }
    #endif
}

/// Low Data Mode, as macOS reports it for the path in use. Auto doesn't follow it (RemoteScreenPlan); the quality menu says the picture
/// costs data on such a path (a phone's hotspot, cellular).
enum NWPathLowData {
    private static let monitor: NWPathMonitorBox = NWPathMonitorBox()
    static var on: Bool { monitor.constrained }
    static var costsData: Bool { monitor.constrained || monitor.expensive }
}

final class NWPathMonitorBox {
    private let m = NWPathMonitor()
    private(set) var constrained = false
    private(set) var expensive = false
    init() {
        m.pathUpdateHandler = { [weak self] p in self?.constrained = p.isConstrained; self?.expensive = p.isExpensive }
        m.start(queue: DispatchQueue(label: "blurt.viewer.path"))
    }
}
