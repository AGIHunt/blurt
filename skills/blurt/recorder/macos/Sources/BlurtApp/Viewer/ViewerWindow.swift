// A window per computer (docs/design/remote-desktop-viewer.md): the host's screen, sized to the window; a toolbar with the computer's name,
// the path (and the round trip once it's slow), then a few small icons as Screen Sharing has them: Keys to Remote (a toggle that shows
// whether it's on), the display switcher (two displays or more) and a ⋯ menu that holds the rest, the picture's quality included. Several
// computers are several windows, and macOS merges them into tabs when asked. Keys go only to the window in front.
//
// Each window has its own link, so its own session: a second window on another display of the same computer is a second session, which
// the host keeps beside the first (`hello.features` "window").
import AppKit
import BlurtCore
import BlurtRemoteKit
import Network

final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuDelegate, NSPopoverDelegate {
    private static var windows: [ViewerWindowController] = []

    let computer: RemoteComputer
    let link: RemoteViewerLink
    private let screen: RemoteViewerScreen
    private let picture = ViewerPictureView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    /// the cover over a picture that stopped or never came: what's happening, how long, and the way on or out (ViewerCoverView)
    private let cover = ViewerCoverView()
    /// when the link went down (or the window began connecting): the cover's "trying for 0:12"
    private var downSince: Double?
    private var coverClock: Timer?
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
        f.onEvent = { [weak self] e in self?.showFile(e) }
        fileCard.onStop = { [weak f] in f?.stop() }
        return f
    }()

    /// the file going there (or just through): its own card over the picture, apart from the keys hint
    private let fileCard = ViewerFileCard()
    private var fileCardBottom: NSLayoutConstraint?

    private func showFile(_ e: ViewerFileSender.Event) {
        fileCard.show(e, to: window?.title ?? shownName)
        placeFileCard()
    }

    /// The card keeps above the band where a host keeps its taskbar or Dock (about 7 % of its screen's height: Windows' taskbar
    /// at 200 % on 1440 px, a Mac's Dock): 12 pt over that band, 64 pt at least.
    private func placeFileCard() {
        guard let content = window?.contentView else { return }
        let band = (content.bounds.height * 0.075).rounded()
        fileCardBottom?.constant = -max(64, band + 12)
    }

    /// The host takes files (its session lists `files`)
    private var hostTakesFiles: Bool { link.session?.features?.contains(RemoteFeature.files) == true }

    func sendFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard hostTakesFiles else { return showFile(.failed(name: urls.count == 1 ? urls[0].lastPathComponent : "", why: "other")) }
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
    /// the modifiers held here and what the host has of them: a press of ⌃ or ⌘ waits until it's clear it isn't the release
    private var heldMods = RemoteHeldModifiers()
    private var screenOn = false
    /// the path the picture was last asked for on
    private var pictureRoute: RemoteViewerLink.Route?
    private var lastPixels = RemotePixelSize(width: 0, height: 0)
    private var resizeWait: DispatchWorkItem?
    private var pasteboardSeen = 0
    private var held = Set<UInt16>()

    // toolbar: icon-only items (no text, no chevrons), so the picture stays the window's one focus and the bar keeps one width in every
    // language; each says what it does in its tooltip and, in the overflow menu, its label
    private var displayItem: NSToolbarItem?
    private var keysItem: NSToolbarItem?
    private let moreMenu = NSMenu()
    /// the display switcher while it's open (kept current as the host's displays change)
    private var displaysPopover: NSPopover?
    private var displaysMap: ViewerDisplayMap?
    private var displaysClosed = Date.distantPast

    // MARK: opening

    /// The computer's window: in front if one is open, else a new one. `adopting`: the session a pairing just opened. `display`: another
    /// window on that display (Open in New Window).
    @MainActor
    static func open(_ c: RemoteComputer, adopting: RemoteViewerLink? = nil, display: String? = nil) {
        watchActive()
        if display == nil, adopting == nil, let w = windows.first(where: { $0.computer.id == c.id }) {
            w.showWindow(nil)
            w.window?.makeKeyAndOrderFront(nil)
            if !ViewerStore.testing { NSApp.activate(ignoringOtherApps: true) }
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
        // (a test build stays behind the user's own apps: `viewer active` stands in for coming to the front)
        if !ViewerStore.testing { NSApp.activate(ignoringOtherApps: true) }
        emit(["event": "viewer_window", "state": "open", "second": second, "platform": c.platform ?? ""])
    }

    /// the window in front, or the newest (tests)
    static var front: ViewerWindowController? {
        (NSApp.keyWindow?.windowController as? ViewerWindowController) ?? windows.last
    }

    private static var watching = false

    /// Keys follow Blurt being the app in front: another app in front gives them back, and coming back to a window that's key takes them.
    @MainActor private static func watchActive() {
        guard !watching else { return }
        watching = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { activeChanged() }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { activeChanged() }
        }
    }

    /// Blurt came to the front or went behind (tests: `viewer active on|off`).
    @MainActor static func activeChanged() {
        for w in windows {
            if w.wantsKeys { w.setCaptured(true) } else if w.captured, !ViewerKeyboard.holdsKeys(w.window) { w.setCaptured(false) }
        }
    }

    static func closeAll(of id: String) { windows.filter { $0.computer.id == id }.forEach { $0.close() } }

    /// The user renamed the computer: its windows' titles (and the tooltips that name it) say the new name.
    @MainActor static func renamed(_ id: String) {
        for w in windows where w.computer.id == id {
            w.window?.title = w.shownName
            w.updateKeys()
        }
    }

    /// What this Mac calls the computer: the user's name for it, else what it said of itself last.
    private var shownName: String { MainActor.assumeIsolated { ViewerStore.shared.name(of: link.computer.id, else: link.computer.name) } }

    private init(_ c: RemoteComputer, link: RemoteViewerLink, second: Bool, display: String?) {
        computer = c
        self.link = link
        self.second = second
        pinned = display
        screen = RemoteViewerScreen(link: link)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = c.shownName
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
        // layer-backed, so the cover and its buttons draw over the picture's layer
        content.wantsLayer = true
        buildFileCard(in: content)
        buildCover(in: content)
        buildToolbar(w)
        // screenshots of a test build behind the user's apps: drawn as the key window (BLURT_TEST_KEY_LOOK), focus untouched
        MainActor.assumeIsolated { SettingsTestKeyLook.apply(to: w) }
        wire()
        if link.state == .connected { connected() } else { stateChanged(link.state) }
        link.start()
        updateControls()
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
            Notify.post(title: shownName, body: text, uid: "remote-notice-\(link.computer.id)")
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
            let name = shownName
            // the host's own sentence is for phones (English only): the viewer says it in its own words
            let key = ["off": "viewer.screen_off", "permission": "viewer.screen_permission", "one_display": "viewer.one_display"][why]
            // Try Again asks for the screen once more: a permission given, or the host's Remote Desktop dialog answered since
            showCover(.init(mark: .attention, title: T(key ?? "viewer.screen_failed", name),
                            primary: why == "off" ? nil : (T("viewer.retry"), #selector(retryScreen))))
        case let .screenLocked(locked):
            // the stream stops at a lock screen this host can't show: the last picture stays, darker, and says why
            guard screenOn else { return }
            if locked {
                picture.stale = true
                // GNOME ends screen sharing at its lock; its own Remote Login reaches the login screen
                showCover(.init(mark: .symbol("lock.fill"), title: T("viewer.locked.title", shownName),
                                detail: T(host == .linux ? "viewer.locked.linux.detail" : "viewer.locked.detail")))
            } else {
                hideCover()
                link.send(.requestKeyframe)
            }
            emit(["event": "viewer_locked", "locked": locked])
        case let .front(f):
            remoteFront = f
        case let .canControl(ok):
            remoteCanControl = ok
            // clicks and keys go nowhere until it's allowed there: said for as long as it lasts
            if ok { picture.hideHint() } else { picture.showHint(T("viewer.no_control", shownName), seconds: nil) }
        case let .session(i):
            remoteCanControl = i.canControl
            window?.title = ViewerStore.shared.name(of: link.computer.id, else: i.macName)
            updateKeys()
            if !i.canControl { picture.showHint(T("viewer.no_control", window?.title ?? i.macName), seconds: nil) }
            updateMore()
        default: break
        }
    }

    private func stateChanged(_ s: RemoteViewerLink.State) {
        let name = shownName
        emit(["event": "viewer_link", "state": "\(s)", "route": link.route.map { "\($0)" } ?? "", "trying": link.trying.map { "\($0)" } ?? "", "lost": link.lostWhy])
        // the clock the cover counts from: the moment the link went down, or the window began connecting
        if s == .connected { downSince = nil } else if downSince == nil { downSince = CACurrentMediaTime() }
        switch s {
        case .connected: connected()
        case .connecting, .waiting:
            // a drop: the last picture stays, frozen, while it comes back by itself (it never asks to pair again)
            if s == .connecting { stopPicture(keep: true) }
            let again = picture.hasPicture
            showCover(.init(mark: .working, title: T(again ? "viewer.reconnecting.to" : "viewer.connecting.to", name), timed: .trying))
        case .unreachable:
            stopPicture(keep: true)
            // it goes on trying by itself; a Mac that restarted with FileVault on waits for its disk password at the computer: nothing
            // reaches it before that
            showCover(.init(mark: .attention, title: T("viewer.unreachable", name), detail: host == .mac ? T("viewer.unreachable.mac.detail") : nil,
                            timed: .stillTrying, primary: (T("viewer.retry"), #selector(retry))))
        case .forgotten, .removed:
            // its key is no good there now: the way back is to add it again (removed in a session is certain, and the list says so
            // until then; a refused key alone only for this run, the key kept)
            stopPicture()
            ViewerStore.shared.hostRemoved(computer.id, inSession: s == .removed)
            showCover(.init(mark: .attention, title: T("viewer.forgotten", name), primary: (T("viewer.add_again"), #selector(addAgain))))
        case .pairingFailed:
            // a pairing's own end, said in the Add Computer sheet; a window only ever adopts a link that paired
            stopPicture()
            showCover(.init(mark: .attention, title: T("viewer.forgotten", name), primary: (T("viewer.add_again"), #selector(addAgain))))
        case .replaced:
            stopPicture()
            showCover(.init(mark: .symbol("desktopcomputer"), title: T("viewer.replaced", name), primary: (T("viewer.take_over"), #selector(takeOver))))
        case .ended:
            stopPicture()
            showCover(.init(mark: .symbol("desktopcomputer"), title: T("viewer.ended", name), primary: (T("viewer.reconnect"), #selector(takeOver))))
        case .away(.noDirect):
            stopPicture()
            showCover(.init(mark: .attention, title: T("viewer.no_direct"), primary: (T("viewer.retry"), #selector(retry))))
        case .away(.relayDown):
            // still trying, now through the public connection service as well
            stopPicture(keep: true)
            showCover(.init(mark: .working, title: T("viewer.relay_down", name), timed: .trying, primary: (T("viewer.retry"), #selector(retry))))
        case .away(.busy):
            // over today's limit: it waits by itself (30 s, 2 min, 10 min, hourly); asking again now changes nothing
            stopPicture()
            showCover(.init(mark: .attention, title: T("viewer.busy")))
        }
        updateControls()
        updateMore()
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
        hideCover()
        updateMore()
        startPicture()
        ViewerStore.shared.liveChanged(computer.id, route: link.route, rtt: link.rtt, open: !second)
        if let p = pinned { link.send(.showDisplay(p)) }
        // after a drop the host has taken the cover down: asked again
        if privacy { link.send(.privacyScreen(true)) }
        // a window that opens in front, captured: the mouse and keys go to the computer it shows. Only with Blurt in front: a window
        // that opens or reconnects behind another app leaves this Mac's keys and input method alone
        if wantsKeys { setCaptured(true) }
    }

    private func routeChanged(_ r: RemoteViewerLink.Route?, _ rtt: Double?) {
        updateSubtitle()
        updateMore()      // another path may cost data, or no longer (the quality menu says so)
        if link.state == .connected, !second { ViewerStore.shared.liveChanged(computer.id, route: r, rtt: rtt, open: true) }
        // away and back: the picture's ceiling changes with the path (a new round trip alone changes nothing)
        if screenOn, r != pictureRoute { askForPicture() }
        pictureRoute = r
    }

    /// The window takes the host's shape: no bars beside the picture, and every size keeps it, a drag (`contentAspectRatio`) and a size
    /// set in code alike (`snap`); the system's full screen is its own.
    private func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0, let w = window else { return }
        picture.source = size
        shaped = true
        w.contentAspectRatio = size
        // the smallest window in the host's shape: 480 pt along its long side, 270 along its short one (a 16:9 host: 480 × 270)
        let long = max(size.width, size.height), short = min(size.width, size.height)
        let k = max(480 / long, 270 / short)
        // the content's minimum only: AppKit derives the frame's
        w.contentMinSize = NSSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
        snap()
    }

    /// the host's shape is known (its first screenView): from then on every size of the window keeps it
    private var shaped = false
    private var snapping = false

    /// The title bar and toolbar's height: the frame above the content.
    private func chrome(_ w: NSWindow) -> CGFloat { w.frame.height - (w.contentView?.frame.height ?? w.contentLayoutRect.height) }

    /// The content back in the host's shape at its width (its top edge kept), as large as the screen allows. Not in full screen, and not
    /// for a window in a tab group: its tabs share one frame, and two hosts of two shapes would pull it back and forth.
    private func snap() {
        guard shaped, !snapping, let w = window, let content = w.contentView, !w.styleMask.contains(.fullScreen),
              (w.tabbedWindows?.count ?? 1) <= 1 else { return }
        let size = picture.source
        let bar = chrome(w)
        var width = content.frame.width
        var height = (width * size.height / size.width).rounded()
        if let screen = w.screen?.visibleFrame, height + bar > screen.height {
            height = screen.height - bar - 40
            width = (height * size.width / size.height).rounded()
        }
        let least = w.contentMinSize
        if width < least.width || height < least.height { width = least.width; height = least.height }
        guard abs(width - content.frame.width) > 0.5 || abs(height - content.frame.height) > 0.5 else { return }
        let f = w.frame
        snapping = true
        w.setFrame(NSRect(x: f.minX, y: f.maxY - height - bar, width: width, height: height + bar), display: true, animate: false)
        snapping = false
    }

    /// Zoom (a double-click on the title bar, ⌥ on the green button): the largest window in the host's shape on this screen.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        guard shaped else { return defaultFrame }
        let size = picture.source, bar = chrome(window)
        let k = min(defaultFrame.width / size.width, (defaultFrame.height - bar) / size.height)
        let w = (size.width * k).rounded(), h = (size.height * k).rounded()
        return NSRect(x: defaultFrame.minX, y: defaultFrame.maxY - h - bar, width: w, height: h + bar)
    }

    private func updateSubtitle() {
        guard let w = window else { return }
        // before it's up: what the cover says, in a word (the way being tried is on the cover, beside how long); a state that waits on the
        // user names no path, which would read as if it worked. Then the real path and the round trip
        guard link.state == .connected else {
            switch link.state {
            case .connecting, .waiting, .away(.relayDown): w.subtitle = T(picture.hasPicture ? "viewer.reconnecting" : "viewer.connecting")
            case .forgotten, .removed, .pairingFailed: w.subtitle = ""
            default: w.subtitle = T("viewer.not_connected")
            }
            return
        }
        // the round trip only once it's slow enough to feel (a fast one is noise under the name, as Screen Sharing shows none)
        let path = ViewerStore.path(link.route)
        w.subtitle = link.rtt.flatMap { $0 >= Self.slowRTT ? T("viewer.path_rtt", path, Int(($0 * 1000).rounded())) : nil } ?? path
    }

    /// a round trip from which the delay is felt under the pointer: said beside the path
    static let slowRTT = 0.08

    @objc private func retry() {
        if !second { ViewerStore.shared.awayChanged(computer.id, nil) }
        link.tryAgain()
    }
    @objc private func takeOver() { link.takeBack() }
    /// The way out of any cover (and the ⋯ menu's): the window closes, and with it the session and the retries.
    @objc private func disconnect() { close() }
    /// The computer removed this Mac: this window has nothing more to show; Add Computer takes its place.
    @objc private func addAgain() {
        ViewerStore.shared.requestAdd()
        close()
    }
    @objc private func retryScreen() {
        guard link.state == .connected else { return retry() }
        hideCover()
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
        // a size set in code (a drag keeps the shape by itself): back to the host's shape
        if window?.inLiveResize == false { snap() }
        placeFileCard()
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

    /// The window would take the keys now: connected, key, with Blurt in front. (A window of an app behind others can still be key.)
    var wantsKeys: Bool { link.state == .connected && ViewerKeyboard.appActive && ViewerKeyboard.isKey(window) }

    func windowDidBecomeKey(_ n: Notification) {
        if wantsKeys, !captured { setCaptured(true) }
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
        updateKeys()
        if on {
            let system = ViewerKeyboard.shared.capture(for: self)
            heldMods = RemoteHeldModifiers()
            sentMods = []
            held = []
            link.send(.keysCaptured(true))
            // what was copied here pastes there
            let pb = NSPasteboard.general
            if shareClipboard, link.hostTakesViewer, pb.changeCount != pasteboardSeen, let t = pb.string(forType: .string), RemoteClipboard.fits(t) {
                link.send(.clipboard(t))
            }
            pasteboardSeen = pb.changeCount
            showReleaseHint(system: system)
        } else {
            // "press ⌃⌘" is no longer true
            picture.endHint(kind: "release")
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

    /// The keys just came here: the hint pill at the top of the picture, 3 s (6 s with the note on system shortcuts, which takes longer to
    /// read): "Keyboard and mouse go to Office PC | [⌃][⌘] Release". The display switcher closes first: one floating thing at a time.
    private func showReleaseHint(system: Bool) {
        displaysPopover?.close()
        picture.showHint(releaseHint(system: system), seconds: system ? 3 : 6)
    }

    /// `system`: the capture has system shortcuts (Input Monitoring); without it a note says they stay on this Mac.
    private func releaseHint(system: Bool) -> ViewerPictureView.Hint {
        ViewerPictureView.Hint(text: T("viewer.release.lead", window?.title ?? shownName), keys: ["⌃", "⌘"],
                               keysWord: T("viewer.release.word"), note: system ? nil : T("viewer.release.app_only.note"), kind: "release")
    }

    @objc private func toggleKeys() { setCaptured(!captured) }

    /// A key, a click or a scroll is about to go: a ⌃ or ⌘ held back (it might have been the release) goes first.
    func beforeInput() { heldMods.other().forEach(sendMods) }

    private func sendMods(_ m: RemoteModifiers) {
        let mapped = RemoteViewerKeys.map(m, from: .mac, to: host, mapping: mapping)
        guard mapped != sentMods else { return }
        sentMods = mapped
        link.send(.mods(mapped))
    }

    /// A key from the capture (ViewerKeyboard), on the main thread.
    func key(_ e: ViewerKeyboard.Event) {
        let mods = RemoteModifiers(e.flags)
        if e.modifiersOnly {
            switch heldMods.modifiers(mods) {
            case .release:
                setCaptured(false)
                return
            case let .send(list): list.forEach(sendMods)
            case .none: break
            }
            // Caps Lock toggles: a press each way
            if e.code == 57 { link.send(.key(RemoteChord([], "CapsLock"), down: nil)) }
            return
        }
        beforeInput()
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

    // MARK: the file card

    private func buildFileCard(in content: NSView) {
        fileCard.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(fileCard)
        let bottom = fileCard.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -64)
        let wide = fileCard.widthAnchor.constraint(equalToConstant: ViewerFileCard.width)
        wide.priority = .defaultHigh
        NSLayoutConstraint.activate([bottom, wide,
                                     fileCard.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                                     fileCard.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12)])
        fileCardBottom = bottom
    }

    // MARK: the cover

    /// The cover's place: on the picture's optical centre (45 % down), above the host's taskbar or dock, the width of a sentence.
    private func buildCover(in content: NSView) {
        cover.translatesAutoresizingMaskIntoConstraints = false
        cover.isHidden = true
        cover.quiet.target = self
        cover.quiet.action = #selector(disconnect)
        cover.primary.target = self
        content.addSubview(cover)
        let upper = NSLayoutGuide()
        content.addLayoutGuide(upper)
        let wide = cover.widthAnchor.constraint(equalToConstant: ViewerCoverView.width)
        wide.priority = .defaultHigh
        let centre = cover.centerYAnchor.constraint(equalTo: upper.bottomAnchor)
        centre.priority = .defaultHigh
        NSLayoutConstraint.activate([upper.topAnchor.constraint(equalTo: content.topAnchor),
                                     upper.heightAnchor.constraint(equalTo: content.heightAnchor, multiplier: 0.45),
                                     cover.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                                     centre,
                                     cover.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 12),
                                     cover.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -12),
                                     wide,
                                     cover.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -32)])
    }

    private func showCover(_ c: ViewerCoverView.Cover) {
        cover.show(c, elapsed: elapsed, route: ViewerStore.trying(link.trying))
        coverClock?.invalidate()
        coverClock = nil
        guard c.timed != nil else { return }
        // the count goes on by itself, so a retry that's alive never looks like one that hung
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cover.tick(elapsed: self.elapsed, route: ViewerStore.trying(self.link.trying))
            }
        }
        RunLoop.main.add(t, forMode: .common)
        coverClock = t
    }

    private var elapsed: Double { downSince.map { CACurrentMediaTime() - $0 } ?? 0 }

    private func hideCover() {
        coverClock?.invalidate()
        coverClock = nil
        cover.hide()
    }

    /// What can act only through a live link (the display switcher, Keys to Remote) is dimmed while there's none; ⋯ stays, with Try
    /// Again and Disconnect in it.
    private func updateControls() {
        let up = link.state == .connected
        for item in [displayItem, keysItem].compactMap({ $0 }) { item.isEnabled = up }
    }

    // MARK: the toolbar

    private enum Item {
        static let displays = NSToolbarItem.Identifier("viewer.displays")
        static let keys = NSToolbarItem.Identifier("viewer.keys")
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
        moreMenu.delegate = self
        moreMenu.autoenablesItems = false
        updateMore()
    }

    /// Keys to Remote on its own (it tints while on, and a tinted item leaves its group: kept apart, the bar's shape stays the same),
    /// then the display switcher (only while the host has two displays or more, updateDisplays) and ⋯ together; a space after them,
    /// so the bar ends as far in from the right edge as the window's buttons start from the left
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Item.keys, .space] + (displays.count > 1 ? [Item.displays] : []) + [Item.more, .space]
    }

    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .space, Item.displays, Item.keys, Item.more]
    }

    private static func symbol(_ name: String, _ label: String) -> NSImage? {
        // one line weight for all three: monochrome (display.2's hierarchical fill read heavier than the keyboard and ⋯ beside it)
        NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(.preferringMonochrome())
    }

    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Item.displays:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = T("viewer.display.label")
            item.paletteLabel = item.label
            item.image = Self.symbol("display.2", item.label)
            item.toolTip = T("viewer.display.tip")
            item.isBordered = true
            item.target = self
            item.action = #selector(showDisplays(_:))
            // enabled by the link's state (updateControls), not by the responder chain
            item.autovalidates = false
            item.isEnabled = link.state == .connected
            displayItem = item
            return item
        case Item.keys:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = T("viewer.keys")
            item.paletteLabel = item.label
            item.isBordered = true
            item.target = self
            item.action = #selector(toggleKeys)
            item.autovalidates = false
            item.isEnabled = link.state == .connected
            keysItem = item
            updateKeys()
            return item
        case Item.more:
            // the ⋯ alone, as Finder's and Mail's: the ellipsis already says there's a menu
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = T("viewer.more")
            item.paletteLabel = item.label
            item.image = Self.symbol("ellipsis.circle", item.label)
            item.toolTip = T("viewer.more")
            item.showsIndicator = false
            item.menu = moreMenu
            return item
        default: return nil
        }
    }

    /// Keys to Remote: the keyboard outlined while this Mac keeps its keys; filled, in brand ink on the brand tint, while they go to the
    /// computer (system.md §2: the tint behind the ink), so whether it's on shows at rest. Its tooltip names the computer and the way back.
    private func updateKeys() {
        guard let item = keysItem else { return }
        let title = window?.title ?? ""
        let name = title.isEmpty ? shownName : title
        if captured {
            item.image = Self.symbol("keyboard.fill", item.label)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [BrandColor.ink]))
            item.toolTip = T("viewer.keys.on", name)
        } else {
            item.image = Self.symbol("keyboard", item.label)
            item.toolTip = T("viewer.keys.off", name)
        }
        #if compiler(>=6.2)   // the macOS 26 SDK (Xcode 26); CI's Xcode 16 builds without the tint
        if #available(macOS 26.0, *) {
            item.backgroundTintColor = BrandColor.tint
            item.style = captured ? .prominent : .plain
        }
        #endif
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === moreMenu { fillMore() }
    }

    @objc private func chooseQuality(_ i: NSMenuItem) {
        guard let q = (i.representedObject as? String).flatMap(RemoteScreenQuality.init(rawValue:)) else { return }
        quality = q
        updateMore()
        askForPicture()
    }

    @objc private func allowShortcuts() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    private func updateMore() { fillMore() }

    private func menuItem(_ key: String, _ action: Selector?, on: Bool? = nil, tip: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: T(key), action: action, keyEquivalent: "")
        i.target = self
        if let on { i.state = on ? .on : .off }
        i.toolTip = tip.map { T($0) }
        return i
    }

    /// The ⋯ menu: what's set once and seldom touched (the picture's quality, ⌘ as Ctrl, the clipboard, the cover on the host's screen),
    /// then what's done now and then (files, Ctrl+Alt+Del), then what's missing here.
    private func fillMore() {
        let m = moreMenu
        m.removeAllItems()
        // the picture's quality: Auto picks for the path, the others hold
        let q = NSMenuItem(title: T("viewer.quality"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for each in RemoteScreenQuality.allCases {
            let i = menuItem("viewer.quality.\(each.rawValue)", #selector(chooseQuality(_:)), on: each == quality,
                             tip: each == .auto ? "viewer.quality.auto.tip" : nil)
            i.representedObject = each.rawValue
            sub.addItem(i)
        }
        // on a phone's hotspot or cellular: the picture costs data, and Data Saver is the choice that spends little
        if NWPathLowData.costsData {
            sub.addItem(.separator())
            let note = NSMenuItem(title: T("viewer.quality.costs_data"), action: nil, keyEquivalent: "")
            note.isEnabled = false
            sub.addItem(note)
        }
        q.submenu = sub
        m.addItem(q)
        m.addItem(.separator())
        // ⌘ as Ctrl only means something on Windows and Linux
        if host != .mac { m.addItem(menuItem("viewer.map_modifiers", #selector(toggleMapping), on: mapping, tip: "viewer.map_modifiers.tip")) }
        m.addItem(menuItem("viewer.clipboard", #selector(toggleClipboard), on: shareClipboard))
        // only where the host can (its session lists `privacy`)
        if link.session?.features?.contains(RemoteFeature.privacy) == true {
            m.addItem(menuItem("viewer.privacy", #selector(togglePrivacy), on: privacy, tip: "viewer.privacy.tip"))
        }
        var actions: [NSMenuItem] = []
        if hostTakesFiles { actions.append(menuItem("viewer.send_files", #selector(chooseFiles))) }
        // a Windows host: its lock and login screens want Ctrl+Alt+Del (sent by the system service where it's on)
        if host == .windows { actions.append(menuItem("viewer.ctrl_alt_del", #selector(sendSecureAttention))) }
        if !actions.isEmpty {
            m.addItem(.separator())
            actions.forEach(m.addItem)
        }
        // without Input Monitoring ⌘Tab and the like stay on this Mac: the way to change that, where it's missing
        if !ViewerKeyboard.systemShortcuts {
            m.addItem(.separator())
            m.addItem(menuItem("viewer.allow_shortcuts", #selector(allowShortcuts)))
        }
        // the link's own: Try Again while it's down and can be asked again, and Disconnect always (the cover's way out, here too)
        m.addItem(.separator())
        switch link.state {
        case .connecting, .unreachable, .away(.noDirect), .away(.relayDown):
            let again = NSMenuItem(title: T("viewer.retry"), action: #selector(retry), keyEquivalent: "")
            again.target = self
            m.addItem(again)
        default: break
        }
        let bye = NSMenuItem(title: T("viewer.disconnect"), action: #selector(disconnect), keyEquivalent: "")
        bye.target = self
        m.addItem(bye)
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
        // shown only when the host has more than one display: the item joins the bar before ⋯, or leaves it
        if let t = window?.toolbar {
            let at = t.items.firstIndex { $0.itemIdentifier == Item.displays }
            if displays.count > 1, at == nil, let k = t.items.firstIndex(where: { $0.itemIdentifier == Item.more }) {
                t.insertItem(withItemIdentifier: Item.displays, at: k)
            } else if displays.count < 2, let i = at {
                t.removeItem(at: i)
                displayItem = nil
            }
        }
        if let m = displaysMap?.model {
            m.displays = displays
            m.shown = shownDisplay
            m.following = pinned == nil
        }
        if displays.count < 2 { displaysPopover?.close() }
    }

    @objc private func showDisplays(_ sender: Any?) {
        // a second click on the item closes it (or the click outside closed it a moment before the item acts)
        if let open = displaysPopover, open.isShown {
            open.close()
            displaysGone(open)
            return
        }
        if Date().timeIntervalSince(displaysClosed) < 0.25 { return }
        let p = NSPopover()
        p.behavior = .transient
        p.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        p.delegate = self
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
            if let p {
                p.close()
                self.displaysGone(p)
            }
        }
        p.contentViewController = v
        // one floating thing over the picture at a time: a short hint makes way (what lasts, no control there, stays)
        picture.endHint()
        displaysPopover = p
        displaysMap = v
        // under the item, its arrow on it
        if #available(macOS 14.0, *), let item = displayItem, item.toolbar != nil {
            p.show(relativeTo: item)
        } else if let c = window?.contentView {
            // macOS 13: under the bar's trailing end, where the item is
            p.show(relativeTo: NSRect(x: c.bounds.maxX - 120, y: c.bounds.maxY - 1, width: 1, height: 1), of: c, preferredEdge: .minY)
        }
        emit(["event": "viewer_displays", "state": "open", "shown": shownDisplay ?? "", "following": pinned == nil])
    }

    func popoverDidClose(_ n: Notification) {
        if let p = n.object as? NSPopover { displaysGone(p) }
    }

    /// The switcher closed: by a choice in it, a click outside or the item again (a close of our own isn't always told to the delegate)
    private func displaysGone(_ p: NSPopover) {
        guard p === displaysPopover else { return }
        displaysPopover = nil
        displaysMap = nil
        displaysClosed = Date()
        emit(["event": "viewer_displays", "state": "closed"])
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
        hideCover()
        displays = list
        shownDisplay = shown
        fit(size)
        picture.show(still: still)
        updateDisplays()
        let path = ViewerStore.path(route)
        window?.subtitle = T("viewer.path_rtt", path, Int((rtt * 1000).rounded()))
        captured = true
        updateKeys()
        displaysPopover?.close()
        picture.showHint(releaseHint(system: true), seconds: 30)
    }

    /// `viewer displays [pin ID|follow] [hover ID|follow]`: the switcher, pinned to a display or following first, the pointer over a
    /// display's tile and row (or the Follow row)
    func testOpenDisplays(_ args: [String] = []) {
        var hover: String?
        var i = 0
        while i < args.count {
            let v = i + 1 < args.count ? args[i + 1] : ""
            switch args[i] {
            case "pin":
                pinned = v
                shownDisplay = v
                link.send(.showDisplay(v))
                i += 1
            case "follow":
                pinned = nil
                link.send(.showDisplay(nil))
            case "hover":
                hover = v
                i += 1
            default: break
            }
            i += 1
        }
        let wait = displaysPopover == nil ? 0 : 0.5
        if let open = displaysPopover {
            open.close()
            displaysGone(open)
        }
        updateDisplays()
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.displaysClosed = .distantPast
            self.showDisplays(nil)
            self.displaysMap?.model.hover = hover
        }
    }

    /// the picture's hint, as the window shows it (`viewer hint KEY`: release, release.app_only, no_control); held up until the
    /// next one, so a screenshot can't miss it. The display switcher closes, as it does when the keys come here. And the file card:
    /// file (a long file name being sent, 3.2 of 8.4 MB there), file.start (before the host's first count), file.many (the second of
    /// three), file.saved, file.failed (not enough space there), file.off.
    func testHint(_ key: String) {
        displaysPopover?.close()
        let name = "Quarterly results for the board, final version (2).pdf", size = 8_400_000
        // the file card on its own (a release hint held up for an earlier shot goes)
        if key.hasPrefix("file") { picture.hideHint() }
        switch key {
        case "release", "release.app_only": picture.showHint(releaseHint(system: key == "release"), seconds: 600)
        case "no_control": picture.showHint(T("viewer.no_control", shownName), seconds: nil)
        case "file": showFile(.sending(name: name, size: size, done: 3_200_000, index: 1, count: 1))
        case "file.start": showFile(.sending(name: name, size: size, done: nil, index: 1, count: 1))
        case "file.many": showFile(.sending(name: name, size: size, done: 5_100_000, index: 2, count: 3))
        case "file.saved": showFile(.saved(name: name, index: 1, count: 1))
        case "file.failed": showFile(.failed(name: name, why: "space"))
        case "file.off": fileCard.hide()
        default: emit(["event": "viewer_hint", "unknown": key])
        }
    }

    var testHintState: [String: Any] { picture.testHint.merging(["file": fileCard.testState]) { a, _ in a } }

    /// the bar's items and the ⋯ menu as they stand (`viewer state`): a check item is "[x] title", a submenu ["title >", its items]
    var testToolbar: [String: Any] {
        fillMore()
        func line(_ i: NSMenuItem) -> Any {
            if i.isSeparatorItem { return "—" }
            let t = (i.state == .on ? "[x] " : "") + i.title
            return i.submenu.map { [t + " >", $0.items.map(line)] as [Any] } ?? t
        }
        return ["items": window?.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [], "keysTip": keysItem?.toolTip ?? "",
                "displayTip": displayItem?.toolTip ?? "", "more": moreMenu.items.map(line)]
    }

    /// what the cover says and offers, and which toolbar controls are live (`viewer state`)
    var testOverlay: [String: Any] {
        var st = cover.testState
        st["controls"] = ["display": displayItem?.isEnabled ?? false, "keys": keysItem?.isEnabled ?? false, "more": true]
        return st
    }
    #endif
}

/// The cover over the picture: one card for every state the link or the picture can be in, so it never changes shape or place between
/// them, only its mark, words and buttons. The toast grid (system.md §3.2 "Toasts (all)"), as a sheet is laid out on a Mac: a leading
/// slot (the brand spinner while it's trying, the amber ⚠ when it needs the user, else the state's own glyph), the title, a detail line in
/// secondary ink (where it's trying and for how long), and the buttons on their own row ending at the right edge: Disconnect (esc), the
/// way out, always; the state's one action (↩) after it, the primary. A sheet's own surface (light or dark with the window), nearly opaque: the frozen picture behind is already blurred, and
/// the words have to read at a glance.
final class ViewerCoverView: NSView {
    enum Mark: Equatable { case working, attention, symbol(String) }
    /// the detail's clock: "Same network · trying for 0:12" while it tries, "Still trying · 0:42" once it said it can't reach
    enum Timed { case trying, stillTrying }
    struct Cover {
        var mark: Mark
        var title: String
        var detail: String? = nil
        var timed: Timed? = nil
        var primary: (String, Selector)? = nil
    }

    static let width: CGFloat = 400
    private static let inset = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 16)
    private static let slot: CGFloat = 22
    private static let gap: CGFloat = 12

    private let card = NSView()
    private let spinner = BrandSpinner(size: 18)
    private let glyph = NSImageView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let text = NSStackView()
    private let buttons = NSStackView()
    /// Disconnect: closes the window, and with it the session and its retries
    let quiet = ViewerQuietButton()
    let primary = BrandButton(title: "", target: nil, action: nil)
    private var current: Cover?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 120))
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.32
        layer?.shadowRadius = 22
        layer?.shadowOffset = CGSize(width: 0, height: -8)

        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0.5
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.symbolConfiguration = .init(pointSize: 17, weight: .medium)
        for v in [spinner, glyph] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(v)
        }
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 4
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 4
        detailLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.detachesHiddenViews = true
        text.addArrangedSubview(titleLabel)
        text.addArrangedSubview(detailLabel)
        text.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(text)

        quiet.keyHint = "esc"
        quiet.title = T("viewer.disconnect")
        primary.keyHint = "↩"
        primary.radius = 7
        primary.hPad = 14
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.detachesHiddenViews = true
        buttons.addArrangedSubview(quiet)
        buttons.addArrangedSubview(primary)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(buttons)

        let textLeft = Self.inset.left + Self.slot + Self.gap
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor), card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 18), spinner.heightAnchor.constraint(equalToConstant: 18),
            spinner.centerXAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.inset.left + Self.slot / 2),
            spinner.centerYAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor, constant: -5),
            glyph.widthAnchor.constraint(equalToConstant: Self.slot), glyph.heightAnchor.constraint(equalToConstant: Self.slot),
            glyph.centerXAnchor.constraint(equalTo: spinner.centerXAnchor), glyph.centerYAnchor.constraint(equalTo: spinner.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: textLeft),
            text.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.inset.left),
            text.topAnchor.constraint(equalTo: card.topAnchor, constant: Self.inset.top),
            buttons.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.inset.right),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: textLeft),
            buttons.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Self.inset.bottom),
            quiet.heightAnchor.constraint(equalToConstant: 28), primary.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ c: Cover, elapsed: Double, route: String) {
        current = c
        titleLabel.stringValue = c.title
        switch c.mark {
        case .working:
            glyph.isHidden = true
            spinner.startAnimation()
        case .attention:
            spinner.stopAnimation()
            glyph.isHidden = false
            glyph.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            glyph.contentTintColor = BrandColor.attn
        case let .symbol(name):
            spinner.stopAnimation()
            glyph.isHidden = false
            glyph.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            glyph.contentTintColor = .secondaryLabelColor
        }
        quiet.title = T("viewer.disconnect")
        quiet.keyEquivalent = "\u{1b}"
        if let (t, a) = c.primary {
            primary.isHidden = false
            primary.title = t
            primary.action = a
            primary.keyEquivalent = "\r"
        } else {
            primary.isHidden = true
            primary.keyEquivalent = ""
        }
        tick(elapsed: elapsed, route: route)
        isHidden = false
        needsLayout = true
    }

    /// the detail again, its clock a second on
    func tick(elapsed: Double, route: String) {
        guard let c = current else { return }
        let clock = Self.clock(elapsed)
        var lines = [String]()
        if let d = c.detail { lines.append(d) }
        switch c.timed {
        case .trying?: lines.append(T("viewer.cover.trying", route, clock))
        case .stillTrying?: lines.append(T("viewer.cover.still_trying", clock))
        case nil: break
        }
        detailLabel.stringValue = lines.joined(separator: "\n")
        detailLabel.isHidden = lines.isEmpty
    }

    func hide() {
        current = nil
        isHidden = true
        spinner.stopAnimation()
        // a hidden cover's keys go nowhere: Esc and Return are the remote's again
        quiet.keyEquivalent = ""
        primary.keyEquivalent = ""
    }

    /// 0:07, 2:41, 1:02:09
    static func clock(_ t: Double) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    override func layout() {
        // the words wrap at the card's width (it narrows with a small window)
        let room = max(120, bounds.width - Self.inset.left - Self.slot - Self.gap - Self.inset.left)
        for l in [titleLabel, detailLabel] where l.preferredMaxLayoutWidth != room {
            l.preferredMaxLayoutWidth = room
            l.invalidateIntrinsicContentSize()
        }
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 14, cornerHeight: 14, transform: nil)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // light: the sheet's near-white; dark: the raised surface (#2A2A2A); both 96 % so the edge sits softly on the picture
            card.layer?.backgroundColor = (isDarkAppearance ? NSColor(srgbRed: 0x2A / 255.0, green: 0x2A / 255.0, blue: 0x2A / 255.0, alpha: 0.96)
                                                            : NSColor(white: 0.985, alpha: 0.96)).cgColor
            card.layer?.borderColor = (isDarkAppearance ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.12)).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    /// the picture under the cover takes no clicks while it shows
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }

    #if DEBUG || BLURT_TEST_HOOKS
    var testState: [String: Any] {
        ["shown": !isHidden, "text": titleLabel.stringValue, "detail": detailLabel.isHidden ? "" : detailLabel.stringValue,
         "mark": current.map { "\($0.mark)" } ?? "", "button": primary.isHidden ? "" : primary.title, "quiet": quiet.title,
         "frame": NSStringFromRect(frame), "buttons": NSStringFromRect(buttons.frame)]
    }
    #endif
}

/// The cover's quiet button (system.md §3.2 "quiet pill"): a film of the label colour, a medium title and its key after it, lighter.
/// Drawn by its own layer (a standard bezel over the picture's layer was attached and laid out but never drawn).
final class ViewerQuietButton: NSButton {
    var keyHint: String? { didSet { updateTitle() } }
    private var hovering = false { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        focusRingType = .default
        updateTitle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var title: String { didSet { updateTitle(); invalidateIntrinsicContentSize() } }
    override var isHighlighted: Bool { didSet { needsLayout = true } }

    private func updateTitle() {
        let base = keyHint.map { k in title.hasSuffix("  " + k) ? String(title.dropLast(k.count + 2)) : title } ?? title
        let t = NSMutableAttributedString(string: base, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor])
        if let k = keyHint {
            t.append(NSAttributedString(string: "  " + k, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .regular),
                                                                     .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        attributedTitle = t
    }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(attributedTitle.size().width + 28), height: 28) }

    override func layout() {
        super.layout()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let a: CGFloat = isHighlighted ? 0.16 : hovering ? 0.12 : 0.08
            layer?.backgroundColor = (isDarkAppearance ? NSColor(white: 1, alpha: a + 0.04) : NSColor(white: 0, alpha: a)).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateTitle(); needsLayout = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
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
