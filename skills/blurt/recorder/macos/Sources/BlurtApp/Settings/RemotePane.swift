// Settings → Phone: pair a phone with the QR code, see what's connected, remove a phone, and the options (keys on screen,
// the screen, the relay). Away from home says first how the phone gets here now, or why it can't (docs/design/remote-go-between.md):
// the owner's relay (recommended), else Blurt's go-between unless it's switched off, and an overlay network's address in any case. The code shows while "Add Phone" is open and there's nothing to switch on: with no paired phone
// Blurt doesn't listen at all (Remote/RemoteServer.swift).
//
// The phones, the connection and the pairing code are PhoneModel's (MainWindow/PhonePage.swift), the one model this pane
// shares with the main window's Phone page — where the connection's state and what to try when it won't connect live;
// RemoteModel keeps what only this pane edits (the options, the relay's field).
import AppKit
import BlurtCore
import BlurtRemoteKit
import SwiftUI

@MainActor
final class RemoteModel: ObservableObject {
    @Published var hud = RemoteHUD.enabled
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

    /// The pane came on show. The QR code waits for Add Phone…: showing it listens on the network and advertises this Mac.
    func start() {
        PhoneModel.shared.watch("settings")
        guard adoption == nil else { return }
        adoption = NotificationCenter.default.addObserver(forName: RemoteServer.relayAdopted, object: nil, queue: .main) { [weak self] n in
            guard let a = n.object as? String else { return }
            MainActor.assumeIsolated { self?.adopted(a) }
        }
    }

    /// The pane left: a code on show goes with it.
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

    /// Where the phone apps come from (iPhone and iPad, Android): their build steps, until they are in the stores.
    static let appPage = URL(string: "https://github.com/AGIHunt/blurt#what-it-does")!

    /// For the user's own coding agent: Blurt doesn't run a relay, and setting one up is a job for someone at a terminal.
    static let relayPrompt = """
    Set up a relay I own for Blurt on my phone, then give me its address to paste into Blurt.

    Blurt on the phone turns a phone (iPhone, iPad or Android) into a trackpad and keyboard for a computer. When the two aren't on the same network they connect through a small WebSocket relay. It passes sealed bytes it can't read and stores nothing.

    The code and the full steps are here; read README.md first:
    https://github.com/AGIHunt/blurt/tree/main/tools/remote-relay

    Ask me which of these I have, then do that one:
    A. A domain on Cloudflare: deploy the Worker on a subdomain such as relay.example.com. The free plan is enough for one person.
    B. A server with a public IP: run server.js as a service (Node 12 or later, one dependency). With a domain, serve it over HTTPS on port 443 with a publicly trusted certificate. Without one, open a port and use ws://.

    Either way, give it a secret path as README.md says: a random RELAY_SECRET (openssl rand -hex 16), so strangers who find the host can't use it. Don't put the secret in a DNS name.

    If I'm in mainland China, prefer a server there: the round trip is far shorter. A domain served from a mainland server needs an ICP filing.

    Don't change anything else on the server or the domain, and ask before opening a port or spending money. Keep credentials out of anything you print.

    When it's up, run `node test.mjs <address>` from that folder and check it passes. Then tell me the one address with its secret, like wss://relay.example.com/<secret>, and that it goes in Blurt → Settings → Phone → Relay Address. Reply in the language I'm writing in.
    """

    func setHUD(_ on: Bool) {
        hud = on
        Config.shared.set("record.remote.hud", on ? nil : false)
    }
}

struct RemotePane: View {
    @StateObject private var m = RemoteModel()
    @ObservedObject private var phone = PhoneModel.shared
    @FocusState private var relayFocused: Bool
    @State private var removing: RemoteServer.Device?
    @ObservedObject private var viewer = ViewerStore.shared
    @State private var addingComputer = false

    private var relayLine: String {
        switch m.relayState {
        case .idle: T("settings.remote.relay.address.detail")
        case .checking: T("settings.remote.relay.checking")
        case .ok: T("settings.remote.relay.ok")
        case .fromPhone: T("settings.remote.relay.from_phone")
        case .failed: T("settings.remote.relay.failed")
        case .invalid: T("settings.remote.relay.invalid")
        }
    }

    private func allowAccessibility() { PermissionGuide.shared.start(.all, only: [.accessibility], source: .phone) }

    /// Away from home, first: the way the connected phone came, or the way a phone would come from another network ("Not set" when there
    /// is none), and when that way isn't working, the problem and what to do about it.
    private var away: (tone: Tone, value: String, problem: String?) {
        let st = phone.status
        func path(_ k: String) -> String { T("settings.remote.path.\(k)") }
        if st.connectedID != nil, let p = st.path {
            let name = switch p {
            case .local: path("local")
            case .tailscale: path("tailscale")
            case .overlay: path("overlay")
            case .direct, .goBetween: path("direct")
            case .relay: path("relay")
            case .meeting: path("go_between")
            }
            return p == .meeting ? (.off, T("settings.remote.away.connecting", name), nil) : (.good, T("settings.remote.away.connected", name), nil)
        }
        if m.ownRelay {
            return phone.relay == .failed ? (.warn, path("relay"), T("settings.remote.away.relay_down")) : (.good, path("relay"), nil)
        }
        guard m.goBetween else { return (.off, path("none"), nil) }
        switch st.away {
        case .busy?: return (.warn, path("go_between"), T("settings.remote.away.busy"))
        case .noDirect?: return (.warn, path("go_between"), T("settings.remote.away.no_direct"))
        case nil: return (.good, path("go_between"), nil)
        }
    }

    /// Under the phones: where the connection's state is. Only while there is a main window to open.
    private var pageNote: AnyView? {
        guard AppEnvironment.mainWindow != nil else { return nil }
        return AnyView(HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(T("phone.pane.see_page"))
            InkLink(T("phone.pane.open_page")) {
                MainWindowController.shared.show()
                MainWindowController.shared.go(.phone)
            }
        })
    }

    var body: some View {
        SettingsPage(.remote) {
            if !phone.canControl, !phone.devices.isEmpty {
                SettingsNotice(title: T("settings.remote.needs_access"), detail: T("settings.remote.needs_access.detail")) {
                    Button(T("settings.kit.allow")) { allowAccessibility() }
                }
                .padding(.top, SettingsMetrics.groupGap)
            }
            SettingsGroup("remote.phones", note: pageNote) { phones }
            SettingsGroup("remote.computers") { computers }
            SettingsGroup("remote.options") {
                SettingToggle("remote.hud", isOn: Binding(get: { m.hud }, set: { m.setHUD($0) }))
                SettingToggle("remote.screen", isOn: Binding(get: { m.screen }, set: { m.setScreen($0) }))
            }
            SettingsGroup("remote.relay") {
                let a = away
                SettingRow("remote.away", title: T("settings.remote.away"), detail: a.problem, detailColor: a.problem == nil ? nil : .brandAttnInk) {
                    HStack(spacing: 6) {
                        StatusDot(tone: a.tone)
                        Text(a.value).font(.system(size: SettingsMetrics.titleSize)).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                SettingRow("remote.relay.address", title: T("settings.remote.relay.own"), detail: relayLine) {
                    TextField("wss://relay.example.com", text: $m.relayText)
                        .accessibilityLabel(T("settings.remote.relay"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 230)
                        .focused($relayFocused)
                        .onSubmit { m.commitRelay() }
                        .onChange(of: m.relayText) { _ in m.relayEdited() }
                        .onChange(of: relayFocused) { on in if !on { m.commitRelay() } }
                }
                SettingToggle("remote.go_between", isOn: Binding(get: { m.goBetween }, set: { m.setGoBetween($0) }),
                              detail: m.ownRelay ? T("settings.remote.go_between.unused") : nil)
                SettingRow("remote.relay.help") {
                    Button(m.copied ? T("settings.remote.relay.copied") : T("settings.remote.relay.copy")) { m.copyRelayPrompt() }
                }
            }
        }
        .onAppear { m.start(); viewer.watch("settings") }
        .onDisappear { m.stop(); viewer.unwatch("settings") }
        .phoneRemoveAlert($removing)
    }

    /// The computers this Mac drives: the same rows as the list from the menu bar (Viewer/ComputersView.swift).
    @ViewBuilder var computers: some View {
        ForEach(viewer.computers) { c in
            SettingsLine(flashID: "remote.computer.\(c.id)", hosts: [], padding: SettingsMetrics.rowPadding, height: nil) {
                ComputerRow(computer: c, compact: true)
            }
        }
        SettingRow("remote.computers.add") {
            Button(T("viewer.add")) { addingComputer = true }
        }
        .sheet(isPresented: Binding(get: { addingComputer || viewer.pairing != nil }, set: { if !$0 { addingComputer = false; viewer.cancelPairing() } })) {
            AddComputerView { addingComputer = false; viewer.cancelPairing() }
        }
    }

    @ViewBuilder var phones: some View {
        ForEach(phone.devices) { d in
            let on = phone.status.connectedID == d.id
            SettingRow("remote.device.\(d.id)", title: PhoneStatus.name(d.name), detail: on ? T("settings.remote.connected") : PhoneText.lastUsed(d),
                       icon: d.isComputer ? "desktopcomputer" : nil) {
                Button(T("settings.remote.remove")) { removing = d }
            }
        }
        if let who = phone.status.asking {
            SettingsLine(flashID: "remote.ask", hosts: [], padding: SettingsMetrics.rowPadding, height: nil) {
                PhoneAsk(who: who, check: phone.status.askingCheck ?? "") { phone.answer($0) }
            }
        }
        if phone.adding {
            SettingsLine(flashID: "remote.add", hosts: [], padding: SettingsMetrics.rowPadding, height: nil) {
                PhonePairingCode(link: phone.status.pairingLink, failure: phone.status.failure) { phone.setAdding(false) }
            }
        } else {
            SettingRow("remote.add") {
                HStack(spacing: 12) {
                    // not in the stores yet: the page has the build steps (the Phone page says so in words)
                    Link(T("settings.remote.get_app"), destination: RemoteModel.appPage).font(.system(size: 12))
                        .help(T("phone.pane.build.tip"))
                    Button(T("settings.remote.add")) { phone.setAdding(true, by: "settings") }
                }
            }
            // said before pairing, not after: with no phone yet the notice above isn't showing
            if !phone.canControl, phone.devices.isEmpty {
                SettingsLine(flashID: "remote.access", hosts: [], padding: SettingsMetrics.rowPadding, height: nil) {
                    HStack(alignment: .center, spacing: 6) {
                        StatusDot(tone: .warn)
                        Text(T("phone.pane.before")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(T("settings.kit.allow")) { allowAccessibility() }.buttonStyle(SettingsOutlinedButtonStyle(compact: true))
                    }
                }
            }
        }
    }
}
