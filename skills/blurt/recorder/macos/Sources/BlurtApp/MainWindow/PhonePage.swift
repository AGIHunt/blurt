// 手机和电脑 / Phones and Computers (docs/design/capabilities.md, remote-desktop-viewer.md §One page for the devices): a
// full page of the main window with every device — what controls this Mac, what this Mac controls — and the phone's
// state for everything outside Settings: the page (PhonePageViews.swift), the menu-bar menu's row and Home's tile
// (PhoneStatus).
//
//  • PhoneModel.shared is the one model of the paired devices for the page AND Settings → 手机和电脑 (which shows
//    only the options and Away from home): both follow RemoteServer's notifications through it. The pairing code
//    (`setAdding`) is the page's; it ends when the page is hidden or the window closes.
//  • The page never opens the port by itself: only Add Device does (RemoteServer.showPairing), and RemoteServer
//    listens on its own only while a device is paired and the capability is on.
//  • What the page says is decided in BlurtCore (PhoneChecks): this file gathers the facts.
import AppKit
import SwiftUI
import BlurtCore
import BlurtRemoteKit

final class PhonePage: FullPage {
    lazy var viewController: NSViewController = NSHostingController(rootView: PhonePageView())
    private var closing: NSObjectProtocol?

    func didShow() {
        MainActor.assumeIsolated {
            PhoneModel.shared.watch("page")
            // the computers this Mac controls: which ones are on this network now (可连接)
            ViewerStore.shared.watch("page")
        }
        // the window closed with the page on show is the page left too (the controller only tells a page it hid when
        // another place takes over): a code must not stay up, with the port open, behind a closed window
        guard closing == nil, let w = viewController.view.window else { return }
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.didHide()
        }
    }

    func didHide() {
        MainActor.assumeIsolated {
            PhoneModel.shared.unwatch("page")
            ViewerStore.shared.unwatch("page")
        }
    }

    deinit { if let c = closing { NotificationCenter.default.removeObserver(c) } }
}

/// The phone in one line, for the places outside the Phone page that say it (the menu-bar menu, Home's tile). Read on
/// the main thread, straight from RemoteServer: nothing here starts anything.
enum PhoneStatus {
    #if DEBUG || BLURT_TEST_HOOKS
    /// tests (`phonepage ax on|off|clear`): what Accessibility would say (RemoteServer's own answer is always yes in
    /// a test build, so its input can be logged)
    static var testCanControl: Bool?
    #endif

    /// macOS lets Blurt move the pointer and press keys for a phone.
    static var canControl: Bool {
        #if DEBUG || BLURT_TEST_HOOKS
        if let t = testCanControl { return t }
        #endif
        return RemoteServer.shared.canControl
    }

    /// The facts that need no asking around (the relay's answer is the page's: PhoneModel).
    static var facts: PhoneFacts {
        let s = RemoteServer.shared, st = s.shown
        return PhoneFacts(paired: s.devices().count, connected: st.connected, viaRelay: st.viaRelay, canControl: canControl,
                          screenWanted: RemoteServer.screenAllowed, screenAllowed: SystemAccess.granted(.screen),
                          listening: st.listening, listenFailure: st.failure, pairing: st.pairingLink != nil,
                          relay: RemoteServer.relayOn ? .checking : PhoneModel.noRelay, away: PhoneModel.away(st.away))
    }

    /// A phone's name as it gave it; one that gave none is "Phone".
    static func name(_ n: String) -> String { n.isEmpty ? T("phone.unnamed") : n }

    /// The menu-bar menu's row: "Phone: iPhone Connected" · "Phone: Not Connected" (paired, none here now) ·
    /// "Phone: Needs Accessibility" (paired, and it could do nothing here) · "Add a Phone…" (none paired)
    static var menuTitle: String {
        // a device waits for a yes: said here too, as the page says it
        if let who = RemoteServer.shared.shown.asking { return T("phone.menu.asking", name(who)) }
        let f = facts
        switch PhoneChecks.headline(f) {
        case .nonePaired: return T("phone.menu.add")
        case let .connected(n, _): return needsAttention ? T("phone.menu.needs_access", T("feature.phone")) : T("phone.menu.connected", T("feature.phone"), name(n))
        case .notConnected: return needsAttention ? T("phone.menu.needs_access", T("feature.phone")) : T("phone.menu.paired", T("feature.phone"))
        }
    }

    /// Home's tile: "iPhone connected" · "Not connected" · nil while no phone is paired.
    static var line: String? {
        switch PhoneChecks.headline(facts) {
        case .nonePaired: return nil
        case let .connected(n, _): return T("phone.line.connected", name(n))
        case .notConnected: return T("phone.line.not_connected")
        }
    }

    /// A phone is paired and this Mac can't be controlled (no Accessibility, or the port could not be opened).
    static var needsAttention: Bool { PhoneChecks.needsAttention(facts) }
}

/// The phone, for the Phone page and Settings → Phone: what RemoteServer says, what macOS allows, whether the relay
/// answers, and the pairing code both of them show.
@MainActor
final class PhoneModel: ObservableObject {
    static let shared = PhoneModel()

    @Published private(set) var status = RemoteServer.shared.shown
    @Published private(set) var devices = RemoteServer.shared.devices()
    /// Add a Phone is open: the code is on show (and the port is open for it)
    @Published private(set) var adding = false
    @Published private(set) var canControl = PhoneStatus.canControl
    @Published private(set) var screenWanted = RemoteServer.screenAllowed
    @Published private(set) var screenAllowed = SystemAccess.granted(.screen)
    @Published private(set) var relay: PhoneFacts.Relay = RemoteServer.relayOn ? .checking : PhoneModel.noRelay
    /// the page's "If It Won't Connect" is open (closed until asked for; kept while the app runs)
    @Published var tipsOpen = false
    /// with no relay of the owner's own: the public connection service, unless it's switched off
    nonisolated static var noRelay: PhoneFacts.Relay { RemoteServer.meetAddress != nil ? .goBetween : .none }
    #if DEBUG || BLURT_TEST_HOOKS
    /// tests (`phonepage relay …`): the relay's answer, without asking anything
    var testRelay: PhoneFacts.Relay? {
        didSet {
            asked = nil
            if let t = testRelay { relay = t } else { checkRelay() }
        }
    }
    #endif

    var facts: PhoneFacts {
        PhoneFacts(paired: devices.count, connected: status.connected, viaRelay: status.viaRelay, canControl: canControl,
                   screenWanted: screenWanted, screenAllowed: screenAllowed, listening: status.listening, listenFailure: status.failure,
                   pairing: adding, relay: relay, away: Self.away(status.away))
    }

    /// What this Mac's own tries found away from home, in BlurtCore's terms (Settings → Remote Control reads the same field).
    nonisolated static func away(_ a: RemoteServer.AwayProblem?) -> PhoneFacts.Away? {
        switch a {
        case .busy?: .busy
        case .noDirect?: .noDirect
        case .relayDown?: .relayDown
        case nil: nil
        }
    }

    private var watchers: Set<String> = []
    private var codeOwner: String?
    private var poll: Timer?
    /// the address the relay's state is about ("" for none); nil: not asked yet
    private var asked: String?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let c = NotificationCenter.default, s = RemoteServer.shared
        observers.append(c.addObserver(forName: RemoteServer.statusChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusChanged(s.shown) }
        })
        observers.append(c.addObserver(forName: RemoteServer.devicesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.devicesChanged(s.devices()) }
        })
    }

    private func statusChanged(_ st: RemoteServer.Status) { if status != st { status = st } }

    private func devicesChanged(_ d: [RemoteServer.Device]) {
        // a phone just paired from the code on screen: the code's job is done
        if adding, codeOwner != "test", d.count > devices.count { setAdding(false) }
        if devices != d { devices = d }
    }

    // MARK: who is looking

    /// A surface that shows the phone came on show ("page", "settings"): what macOS allows is read again every second
    /// while anyone looks (a switch flipped in System Settings shows here at once), and the relay is asked once.
    func watch(_ who: String) {
        let first = watchers.isEmpty
        watchers.insert(who)
        status = RemoteServer.shared.shown
        devices = RemoteServer.shared.devices()
        refresh()
        // back on show with a relay that didn't answer last time: it may have been fixed since
        guard first else { if relay == .failed { checkRelay() }; return }
        asked = nil
        checkRelay()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// It left. A code goes with the surface that put it up: nobody is at it to answer.
    func unwatch(_ who: String) {
        guard watchers.remove(who) != nil else { return }
        if adding, codeOwner == who || watchers.isEmpty { setAdding(false) }
        guard watchers.isEmpty else { return }
        poll?.invalidate()
        poll = nil
    }

    fileprivate func refresh() {
        let can = PhoneStatus.canControl, wanted = RemoteServer.screenAllowed, allowed = SystemAccess.granted(.screen)
        if can != canControl { canControl = can }
        if wanted != screenWanted { screenWanted = wanted }
        if allowed != screenAllowed { screenAllowed = allowed }
        // the address changed (typed in Settings, filled in by a phone): what was said about the last one doesn't hold
        if asked != nil, asked != (RemoteServer.relayAddress ?? "") || RemoteServer.relayAddress == nil && relay != Self.noRelay { checkRelay() }
    }

    // MARK: pairing

    /// Add a Phone… / Cancel: the code shows (RemoteServer opens the port for it) or goes. `who` put it up ("page",
    /// "settings"): both show it, and it goes when that one leaves.
    func setAdding(_ on: Bool, by who: String = "page") {
        guard on != adding else { return }
        guard !on || Capability.phone.isOn else { return }
        adding = on
        codeOwner = on ? who : nil
        RemoteServer.shared.showPairing(on)
        emit(["event": "phone_pairing", "on": on])
    }

    #if DEBUG || BLURT_TEST_HOOKS
    /// tests (`phonepage fake … code`): the code's place on show without RemoteServer making one
    func testCode(_ on: Bool) {
        if adding, codeOwner != "test" { setAdding(false) }
        adding = on
        codeOwner = on ? "test" : nil
    }
    #endif

    func answer(_ yes: Bool) { RemoteServer.shared.answerPairing(yes, number: status.askingNumber) }

    /// The port could not be opened: once more.
    func listenAgain() { RemoteServer.shared.capabilityChanged() }

    // MARK: the relay

    /// Does the owner's relay answer? Asked when someone starts looking, when the address changes, and on Check Again.
    func checkRelay() {
        #if DEBUG || BLURT_TEST_HOOKS
        if testRelay != nil { return }
        #endif
        guard let a = RemoteServer.relayAddress else {
            asked = ""
            if relay != Self.noRelay { relay = Self.noRelay }
            return
        }
        asked = a
        relay = .checking
        RemoteRelay.check(address: a, queue: .main) { [weak self] ok in
            MainActor.assumeIsolated { self?.relayAnswered(a, ok) }
        }
    }

    /// Settings just asked this address itself (its field was committed): no second question.
    func relayAsking(_ a: String) {
        asked = a
        relay = .checking
    }

    func relayAnswered(_ a: String, _ ok: Bool) {
        guard asked == a, RemoteServer.relayAddress == a else { return }
        relay = ok ? .ok : .failed
    }
}

// MARK: - tests

extension PhonePage {
    /// `phonepage …` (SnapApp's test channel; test builds only — a release build ignores it):
    ///   fake none|paired|connected|relay|asking|deaf [code]   devices and a connection as if real (RemoteServer.testFake):
    ///                           nothing paired · an iPhone, an iPad and a computer that controls this Mac (its hello
    ///                           said "viewer"), none here · the iPhone connected on the local network ·
    ///                           … through the relay · a new phone waiting for a yes · the port could not be opened (`deaf other`: an error with no words of its own);
    ///                           also tailscale|meeting|gobetween (connected that way) and busy|nodirect (paired, and why the
    ///                           go-between didn't work) · relaydown (paired, and this Mac's own tries to reach its
    ///                           relay keep failing): the page's notice, as Settings → Remote Control → Status says it;
    ///                           `code`: with a pairing code on show that is no code (a picture of it gives nothing
    ///                           away: no key, no address, no name) and nothing listening for it
    ///   ax on|off|clear         what Accessibility says · relay none|checking|ok|failed|clear   the relay's answer
    ///   tips open|closed        the page's "If It Won't Connect"
    ///   add · cancel            = Add a Phone… / Cancel · key return|esc   the key, as the window's key equivalent
    ///   rename page|list ID start|type TEXT|return|esc   a row's name field (a device's id, or a computer's), as a double-click,
    ///                           typing and the keys would
    ///   state                   what the page shows ("phone_page" event)
    static func testCommand(_ arg: String) {
        #if DEBUG || BLURT_TEST_HOOKS
        MainActor.assumeIsolated {
            let a = arg.split(separator: " ").map(String.init), v = a.count > 1 ? a[1] : ""
            let m = PhoneModel.shared
            switch a.first ?? "state" {
            case "fake":
                let now = Date()
                let two = [RemoteServer.Device(id: "test-iphone", name: "iPhone", added: now.addingTimeInterval(-40 * 86400), lastSeen: now.addingTimeInterval(-2 * 3600)),
                           RemoteServer.Device(id: "test-ipad", name: "iPad", added: now.addingTimeInterval(-12 * 86400), lastSeen: now.addingTimeInterval(-3 * 86400)),
                           RemoteServer.Device(id: "test-mbp", name: "MacBook Pro", added: now.addingTimeInterval(-5 * 86400),
                                               lastSeen: now.addingTimeInterval(-26 * 3600), kind: "computer")]
                var st = RemoteServer.Status()
                st.listening = v != "none" && v != "deaf"
                switch v {
                case "connected", "relay", "tailscale", "meeting", "gobetween":
                    st.connected = "iPhone"
                    st.connectedID = "test-iphone"
                    st.viaRelay = ["relay", "meeting", "gobetween"].contains(v)
                    st.udp = v != "meeting"
                    let paths: [String: RemoteServer.Path] = ["connected": .local, "relay": .relay, "tailscale": .tailscale, "meeting": .meeting,
                                                              "gobetween": .goBetween]
                    st.path = paths[v]
                case "busy": st.away = .busy
                case "nodirect": st.away = .noDirect
                case "relaydown": st.away = .relayDown
                case "asking":
                    st.asking = "Pixel 9"
                    st.askingCheck = "482713"
                    st.askingNumber = 1
                // `deaf other`: an error the page has no words of its own for
                case "deaf": st.failure = a.count > 2 && a[2] == "other" ? "POSIXErrorCode(rawValue: 13): Permission denied" : RemoteServer.portInUse
                default: break
                }
                let code = a.count > 2 && a[2] == "code"
                // a code that renews in 1:40, as one just put up
                if code { st.pairingRenews = Date().addingTimeInterval(100) }
                if code { st.pairingLink = URL(string: "https://example.com/blurt-pairing-code-for-screenshots-only#not-a-key-0000000000000000000000000000000000000000000") }
                m.testCode(code)
                RemoteServer.shared.testFake(devices: v == "none" ? [] : two, status: st)
            case "ax": PhoneStatus.testCanControl = v == "clear" ? nil : v == "on"
            case "relay":
                m.testRelay = ["none": .none, "checking": .checking, "ok": .ok, "failed": .failed][v]
            case "tips": m.tipsOpen = v == "open"
            case "add": m.setAdding(true)
            case "key":
                // Return / Esc as the main window gets them first (key equivalents: the page's default and cancel buttons)
                guard let w = MainWindowController.shared.window else { break }
                let esc = v == "esc", chars = esc ? "\u{1b}" : "\r"
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                            isARepeat: false, keyCode: esc ? 53 : 36) {
                    emit(["event": "phone_key", "key": v, "handled": w.performKeyEquivalent(with: e)])
                }
            case "cancel": m.setAdding(false)
            case "rename": RenameTests.post(a)
            default: break
            }
            // the fake goes through RemoteServer's queue and back: say what shows once it has landed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated {
                    m.refresh()
                    let f = m.facts
                    emit(["event": "phone_page", "headline": "\(PhoneChecks.headline(f))", "problems": PhoneChecks.problems(f).map { "\($0)" },
                          "tips": PhoneChecks.tips(f).map { "\($0)" }, "adding": m.adding, "listening": RemoteServer.shared.shown.listening,
                          "link": RemoteServer.shared.shown.pairingLink != nil, "menu": PhoneStatus.menuTitle,
                          "line": PhoneStatus.line ?? NSNull(), "attention": PhoneStatus.needsAttention,
                          "devices": m.devices.map { [$0.name, $0.alias ?? ""] }, "connected": m.status.connected ?? NSNull()])
                }
            }
        }
        #endif
    }
}
