// Settings → 远程控制 / Remote Control. First one row for the devices: nothing paired says so, with Add Device… (the main
// window's page with the code up); paired says how many and who is connected now, with Show Devices. The devices themselves
// — paired phones and computers, Add Device…'s code, the computers this Mac controls — are on the main window's page
// (MainWindow/PhonePageViews.swift, docs/design/remote-desktop-viewer.md §One page for the devices). Then two sections:
//   On this Mac      staying awake, saying when it sleeps, the keys shown here, the screen: one line each, the long version
//                    in the title's tooltip.
//   Other networks   how a device on another network gets here (docs/design/remote-go-between.md): the public connection
//                    service (a switch) and the own relay (its address), each with its state as the line under it; with an
//                    own relay set, the public service only stands in while that is down. The footnote copies the setup
//                    instructions for the user's coding agent.
//
// The connection and the relay's answer are PhoneModel's (MainWindow/PhonePage.swift), the one model this pane shares
// with the page; RemoteModel keeps what only this pane edits (the options, the relay's field).
import AppKit
import BlurtCore
import BlurtRemoteKit
import SwiftUI

@MainActor
final class RemoteModel: ObservableObject {
    @Published var hud = RemoteHUD.enabled
    @Published var stayAwake = RemoteStayAwake.enabled
    @Published var sayAsleep = RemoteServer.sayAsleep
    @Published var relayText = Config.shared["record.remote.relay_url"] as? String ?? ""
    @Published var relayState = RelayState.idle
    private var committed = Config.shared["record.remote.relay_url"] as? String ?? ""
    enum RelayState { case idle, checking, ok, failed, invalid, fromPhone }
    @Published var screen = RemoteServer.screenAllowed
    @Published var goBetween = RemoteServer.goBetweenOn
    /// a relay of the owner's own is set (committed), so the go-between isn't used
    var ownRelay: Bool { RemoteRelay.address(committed) != nil }

    func setGoBetween(_ on: Bool) {
        goBetween = on
        Config.shared.set("record.remote.go_between", on ? nil : false)
        RemoteServer.shared.relayChanged()
    }

    private var adoption: NSObjectProtocol?

    /// The pane came on show: the connection's path and the relay's answer, for Other networks.
    func start() {
        PhoneModel.shared.watch("settings")
        guard adoption == nil else { return }
        adoption = NotificationCenter.default.addObserver(forName: RemoteServer.relayAdopted, object: nil, queue: .main) { [weak self] n in
            guard let a = n.object as? String else { return }
            MainActor.assumeIsolated { self?.adopted(a) }
        }
    }

    /// The pane left.
    func stop() {
        PhoneModel.shared.unwatch("settings")
        if let a = adoption { NotificationCenter.default.removeObserver(a) }
        adoption = nil
    }

    /// A phone filled it in. Say so, and try it as if it had been typed.
    private func adopted(_ a: String) {
        relayText = a
        committed = a
        check(a, good: .fromPhone)
    }

    /// Asks the relay at this address, once, for this pane's line and the Phone page's alike.
    private func check(_ a: String, good: RelayState) {
        relayState = .checking
        PhoneModel.shared.relayAsking(a)
        RemoteRelay.check(address: a, queue: .main) { [weak self] ok in
            MainActor.assumeIsolated {
                PhoneModel.shared.relayAnswered(a, ok)
                guard let self, self.relayText == a else { return }
                self.relayState = ok ? good : .failed
            }
        }
    }

    func setScreen(_ on: Bool) {
        screen = on
        Config.shared.set("record.remote.screen", on ? nil : false)
        RemoteServer.shared.screenSettingChanged()
    }

    /// Pressing Return or leaving the field: what's there is what's used, and it's tried straight away.
    func commitRelay() {
        let typed = relayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed != committed else { return }      // Return, and then leaving the field
        committed = typed
        if typed.isEmpty {
            relayText = ""
            relayState = .idle
            Config.shared.set("record.remote.relay_url", "")    // cleared, not unset: a phone mustn't put one back
            return RemoteServer.shared.relayChanged()
        }
        guard let a = RemoteRelay.address(typed) else { relayState = .invalid; return }
        relayText = a
        committed = a
        Config.shared.set("record.remote.relay_url", a)
        RemoteServer.shared.relayChanged()
        check(a, good: .ok)
    }

    /// Whatever was said about the last address doesn't hold for this one.
    func relayEdited() {
        if relayText != committed { relayState = .idle }
    }

    func copyRelayPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.relayPrompt, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.copied = false }
    }
    @Published var copied = false

    /// For the user's own coding agent: Blurt doesn't run a relay, and setting one up is a job for someone at a terminal.
    static let relayPrompt = """
    Set up a relay I own for Blurt's Remote Control, then give me its address to paste into Blurt.

    Blurt lets my phones and computers show and control my computers. When two of them can't connect directly (other networks, a strict firewall) they go through a small WebSocket relay. It passes sealed bytes it can't read and stores nothing.

    The code and the full steps are here; read README.md first:
    https://github.com/AGIHunt/blurt/tree/main/tools/remote-relay

    Ask me which of these I have, then do that one:
    A. A domain on Cloudflare: deploy the Worker on a subdomain such as relay.example.com. The free plan is enough for one person.
    B. A server with a public IP: run server.js as a service (Node 12 or later, one dependency). With a domain, serve it over HTTPS on port 443 with a publicly trusted certificate. Without one, open a port and use ws://.

    Either way, give it a secret path as README.md says: a random RELAY_SECRET (openssl rand -hex 16), so strangers who find the host can't use it. Don't put the secret in a DNS name.

    Where it runs decides how quick it feels: every move goes there and back. Don't assume where I am: ask where I and the computers I'll control usually are, and measure from this computer (a few timed HTTPS requests) to Cloudflare and to any server I have before choosing. Check the hosting rules where the server is (some countries require registering a website served from there) and tell me before relying on it.

    Don't change anything else on the server or the domain, and ask before opening a port or spending money. Keep credentials out of anything you print.

    When it's up, run `node test.mjs <address>` from that folder and check it passes. Then tell me the one address with its secret, like wss://relay.example.com/<secret>, and that it goes in Blurt → Settings → Remote Control → Other networks → Own relay. Reply in the language I'm writing in.
    """

    func setSayAsleep(_ on: Bool) {
        sayAsleep = on
        Config.shared.set("record.remote.say_asleep", on ? nil : false)
    }

    func setStayAwake(_ on: Bool) {
        stayAwake = on
        Config.shared.set("record.remote.stay_awake", on ? nil : false)
        RemoteStayAwake.shared.settingChanged()
    }

    func setHUD(_ on: Bool) {
        hud = on
        Config.shared.set("record.remote.hud", on ? nil : false)
    }
}

struct RemotePane: View {
    @StateObject private var m = RemoteModel()
    @ObservedObject private var phone = PhoneModel.shared
    @FocusState private var relayFocused: Bool

    var body: some View {
        SettingsPage(.remote) {
            devices
            groups
        }
        .onAppear { m.start() }
        .onDisappear { m.stop() }
    }

    // MARK: the devices

    /// The page's first row: what is paired and who is connected now, with the way to the main window's page (the
    /// devices themselves are there). Nothing paired: it says so, with Add Device…, which opens that page with the code up.
    @ViewBuilder private var devices: some View {
        let list = phone.devices
        let st = phone.status
        let canOpen = AppEnvironment.mainWindow != nil
        let now: String = {
            guard let n = st.connected else { return T("phone.line.not_connected") }
            let who = T("phone.line.connected", PhoneStatus.name(n))
            guard let p = st.path else { return who }
            return p == .meeting ? T("settings.remote.away.connecting", PhoneText.path(p)) : "\(who) · \(PhoneText.path(p))"
        }()
        SettingsGroup(footer: nil) {
            SettingRow("remote.devices", title: list.isEmpty ? T("phone.none") : TP("settings.remote.devices", list.count),
                       detail: list.isEmpty ? T("phone.none.detail") : now,
                       icon: st.connected == nil ? "iphone" : "iphone.radiowaves.left.and.right") {
                if !canOpen {
                    EmptyView()
                } else if list.isEmpty {
                    Button(T("settings.remote.add")) { openPage(adding: true) }.help(T("phone.add.tip"))
                } else {
                    InkLink(T("phone.pane.show")) { openPage(adding: false) }.font(.system(size: SettingsMetrics.titleSize))
                }
            }
        }
    }

    private func openPage(adding: Bool) {
        MainWindowController.shared.show()
        MainWindowController.shared.go(.phone)
        // the page's own code, as its Add Device… makes it (it goes when the page is left)
        if adding { DispatchQueue.main.async { PhoneModel.shared.setAdding(true, by: "page") } }
    }

    // MARK: the sections

    @ViewBuilder private var groups: some View {
        SettingsGroup("remote.options") {
            SettingToggle("remote.stay_awake", isOn: Binding(get: { m.stayAwake }, set: { m.setStayAwake($0) }),
                          detail: T(RemoteStayAwake.hasBattery ? "settings.remote.stay_awake.laptop" : "settings.remote.stay_awake.desktop"),
                          help: T(RemoteStayAwake.hasBattery ? "settings.remote.stay_awake.laptop.more" : "settings.remote.stay_awake.desktop.more"))
            SettingToggle("remote.say_asleep", isOn: Binding(get: { m.sayAsleep }, set: { m.setSayAsleep($0) }),
                          detail: T("settings.remote.say_asleep.detail"))
            SettingToggle("remote.hud", isOn: Binding(get: { m.hud }, set: { m.setHUD($0) }))
            SettingToggle("remote.screen", isOn: Binding(get: { m.screen }, set: { m.setScreen($0) }))
        }
        SettingsGroup("remote.relay", note: AnyView(relayHelp)) {
            SettingRow("remote.go_between", detailContent: AnyView(stateLine(publicState))) {
                Toggle(T("settings.remote.go_between"), isOn: Binding(get: { m.goBetween }, set: { m.setGoBetween($0) }))
                    .labelsHidden().toggleStyle(BrandSwitchStyle(label: T("settings.remote.go_between")))
            }
            SettingRow("remote.relay.address", detailContent: AnyView(stateLine(ownState))) { relayField }
        }
    }

    /// A row's state: a disc for what is in use or wrong (none for a plain fact), then one line — attention ink for a problem.
    private struct Line {
        var tone: Tone?
        var text: String
        var problem = false
    }

    /// The public connection service: in use (or why it can't be now), standing in for an own relay that is down,
    /// waiting behind one that works, or off.
    private var publicState: Line {
        let st = phone.status
        // off, or nothing paired yet to use it: what it is, with no disc (a green "in use" would claim a connection)
        guard m.goBetween, !phone.devices.isEmpty else { return Line(tone: nil, text: T("settings.remote.go_between.detail")) }
        if m.ownRelay {
            let down = phone.relay == .failed || st.away == .relayDown
            return down ? Line(tone: .good, text: T("settings.remote.go_between.standing_in"))
                        : Line(tone: nil, text: T("settings.remote.go_between.unused"))
        }
        switch st.away {
        case .busy?: return Line(tone: .warn, text: T("settings.remote.away.busy"), problem: true)
        case .noDirect?: return Line(tone: .warn, text: T("settings.remote.away.no_direct"), problem: true)
        case nil, .relayDown?: return Line(tone: .good, text: T("settings.remote.go_between.in_use"))
        }
    }

    /// The own relay: what it is for while there is none, else what the last check (this page's, or the host's own
    /// tries) said about the address.
    private var ownState: Line {
        switch m.relayState {
        case .checking: return Line(tone: nil, text: T("settings.remote.relay.checking"))
        case .failed: return Line(tone: .warn, text: T("settings.remote.relay.failed"), problem: true)
        case .invalid: return Line(tone: .warn, text: T("settings.remote.relay.invalid"), problem: true)
        case .ok: return Line(tone: .good, text: T("settings.remote.relay.ok"))
        case .fromPhone: return Line(tone: .good, text: T("settings.remote.relay.from_phone"))
        case .idle:
            guard m.ownRelay else { return Line(tone: nil, text: T("settings.remote.relay.address.detail")) }
            if phone.relay == .failed || phone.status.away == .relayDown {
                return Line(tone: .warn, text: T("settings.remote.away.relay_down"), problem: true)
            }
            if phone.relay == .checking { return Line(tone: nil, text: T("settings.remote.relay.checking")) }
            return Line(tone: .good, text: T("settings.remote.relay.in_use"))
        }
    }

    private func stateLine(_ s: Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let t = s.tone { StatusDot(tone: t, diameter: 8).alignmentGuide(.firstTextBaseline) { $0.height - 0.5 } }
            Text(s.text).font(.system(size: SettingsMetrics.detailSize))
                .foregroundStyle(s.problem ? AnyShapeStyle(Color.brandAttnInk) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// The relay's address at the page's one control width, in the pop-ups' outlined skin (not a dark well in dark mode);
    /// the whole address in the tooltip.
    private var relayField: some View {
        TextField("", text: $m.relayText, prompt: Text(verbatim: "wss://relay.example.com"))
            .accessibilityLabel(T("settings.remote.relay"))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(width: SettingsMetrics.controlWidth, height: OutlinedPopUpButton.height)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(relayFocused ? Color.brandAccent : Color(nsColor: .separatorColor), lineWidth: relayFocused ? 1.5 : 1))
            .help(m.relayText)
            .focused($relayFocused)
            .onSubmit { m.commitRelay() }
            .onChange(of: m.relayText) { _ in m.relayEdited() }
            .onChange(of: relayFocused) { on in if !on { m.commitRelay() } }
    }

    /// Under Other networks: who can set up a relay, and the instructions to hand them (a rare job: never a row of its own).
    private var relayHelp: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(T("settings.remote.relay.help.detail"))
            InkLink(m.copied ? T("settings.remote.relay.copied") : T("settings.remote.relay.copy")) { m.copyRelayPrompt() }
                .help(T("settings.remote.relay.copy.tip"))
        }
    }
}
