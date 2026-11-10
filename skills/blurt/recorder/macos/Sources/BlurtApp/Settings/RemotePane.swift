// Settings → Phone: pair a phone with the QR code, see what's connected, remove a phone. The code shows while "Add Phone"
// is open and there's nothing to switch on: with no paired phone Blurt doesn't listen at all (Remote/RemoteServer.swift).
import AppKit
import ApplicationServices
import BlurtCore
import BlurtRemoteKit
import CoreImage
import SwiftUI

@MainActor
final class RemoteModel: ObservableObject {
    @Published var status = RemoteServer.Status()
    @Published var devices: [RemoteServer.Device] = []
    @Published var adding = false
    @Published var hud = RemoteHUD.enabled
    @Published var relayText = Config.shared["record.remote.relay_url"] as? String ?? ""
    @Published var relayState = RelayState.idle
    private var committed = Config.shared["record.remote.relay_url"] as? String ?? ""
    enum RelayState { case idle, checking, ok, failed, invalid, fromPhone }
    @Published var screen = RemoteServer.screenAllowed

    private var pollAccess: Timer?
    @Published var canControl = AXIsProcessTrusted()

    func start() {
        let s = RemoteServer.shared
        s.onStatus = { [weak self] st in MainActor.assumeIsolated { self?.statusChanged(st) } }
        s.onDevices = { [weak self] d in MainActor.assumeIsolated { self?.devicesChanged(d) } }
        s.onRelayAdopted = { [weak self] a in MainActor.assumeIsolated { self?.adopted(a) } }
        status = s.status
        devices = s.devices()
        // the QR code waits for Add Phone…: showing it listens on the network and advertises this Mac
        pollAccess = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.canControl = RemoteServer.shared.canControl }
        }
    }

    func stop() {
        setAdding(false)
        pollAccess?.invalidate()
        pollAccess = nil
    }

    private func statusChanged(_ st: RemoteServer.Status) { status = st }

    private func devicesChanged(_ d: [RemoteServer.Device]) {
        // a phone just paired from the code on screen: the code's job is done
        if adding, d.count > devices.count { setAdding(false) }
        devices = d
    }

    /// A phone filled it in. Say so, and try it as if it had been typed.
    private func adopted(_ a: String) {
        relayText = a
        committed = a
        relayState = .checking
        RemoteRelay.check(address: a, queue: .main) { [weak self] ok in
            MainActor.assumeIsolated {
                guard let self, self.relayText == a else { return }
                self.relayState = ok ? .fromPhone : .failed
            }
        }
    }

    func setAdding(_ on: Bool) {
        adding = on
        RemoteServer.shared.showPairing(on)
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
        relayState = .checking
        Config.shared.set("record.remote.relay_url", a)
        RemoteServer.shared.relayChanged()
        RemoteRelay.check(address: a, queue: .main) { [weak self] ok in
            MainActor.assumeIsolated {
                guard let self, self.relayText == a else { return }
                self.relayState = ok ? .ok : .failed
            }
        }
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

    /// Where to get the phone apps (iPhone and iPad, Android): their build steps until they are in the stores.
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
    @FocusState private var relayFocused: Bool
    @State private var removing: RemoteServer.Device?

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

    var body: some View {
        SettingsPage(.remote) {
            if !m.canControl, !m.devices.isEmpty {
                SettingsNotice(title: T("settings.remote.needs_access"), detail: T("settings.remote.needs_access.detail")) {
                    Button(T("settings.kit.allow")) { PermissionGuide.shared.start(.all, only: [.accessibility], source: .general) }
                }
                .padding(.top, SettingsMetrics.groupGap)
            }
            SettingsGroup("remote.phones") { phones }
            SettingsGroup("remote.options") {
                SettingToggle("remote.hud", isOn: Binding(get: { m.hud }, set: { m.setHUD($0) }))
                SettingToggle("remote.screen", isOn: Binding(get: { m.screen }, set: { m.setScreen($0) }))
            }
            SettingsGroup("remote.relay") {
                SettingRow("remote.relay.address", detail: relayLine) {
                    TextField("wss://relay.example.com", text: $m.relayText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 230)
                        .focused($relayFocused)
                        .onSubmit { m.commitRelay() }
                        .onChange(of: m.relayText) { _ in m.relayEdited() }
                        .onChange(of: relayFocused) { on in if !on { m.commitRelay() } }
                }
                SettingRow("remote.relay.help") {
                    Button(m.copied ? T("settings.remote.relay.copied") : T("settings.remote.relay.copy")) { m.copyRelayPrompt() }
                }
            }
        }
        .onAppear { m.start() }
        .onDisappear { m.stop() }
        .alert(T("settings.remote.remove.title", removing?.name ?? ""), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(T("settings.remote.cancel"), role: .cancel) {}
            Button(T("settings.remote.remove"), role: .destructive) { if let d = removing { RemoteServer.shared.remove(d.id) } }
        } message: { Text(T("settings.remote.remove.detail")) }
    }

    private func lastUsed(_ d: RemoteServer.Device) -> String {
        guard let t = d.lastSeen else { return T("settings.remote.not_connected") }
        return T("settings.remote.last_used", RelativeDateTimeFormatter().localizedString(for: t, relativeTo: Date()))
    }

    @ViewBuilder var phones: some View {
        ForEach(m.devices) { d in
            let on = m.status.connectedID == d.id
            SettingRow("remote.device.\(d.id)", title: d.name, detail: on ? T("settings.remote.connected") : lastUsed(d)) {
                Button(T("settings.remote.remove")) { removing = d }
            }
        }
        if let who = m.status.asking {
            let n = m.status.askingNumber
            // the four digits, large: the yes is for the phone showing the same ones. No default button: Return mustn't say yes
            SettingRow("remote.device.\(who)", title: T("settings.remote.ask.title", who),
                       detail: T("settings.remote.ask.detail", m.status.askingCheck ?? "")) {
                HStack {
                    Text(m.status.askingCheck ?? "").font(.system(size: 20, weight: .semibold, design: .monospaced)).padding(.trailing, 8)
                    Button(T("settings.remote.ask.no")) { RemoteServer.shared.answerPairing(false, number: n) }
                    Button(T("settings.remote.ask.yes")) { RemoteServer.shared.answerPairing(true, number: n) }
                }
            }
        }
        if m.adding {
            SettingsLine(flashID: "remote.add", hosts: [], padding: SettingsMetrics.rowPadding, height: nil) {
                HStack(alignment: .center, spacing: 20) {
                    QRImage(link: m.status.pairingLink).frame(width: 168, height: 168)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(T("settings.remote.scan")).font(.system(size: SettingsMetrics.titleSize, weight: .medium))
                        Text(T("settings.remote.scan.detail")).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let f = m.status.failure { Text(f).font(.system(size: 11)).foregroundStyle(Color.brandAttnInk) }
                        Button(T("settings.remote.cancel")) { m.setAdding(false) }
                    }
                    Spacer(minLength: 0)
                }
            }
        } else {
            SettingRow("remote.add") {
                HStack(spacing: 12) {
                    // not on the App Store yet: the page says how to build it with Xcode
                    Link(T("settings.remote.get_app"), destination: RemoteModel.appPage).font(.system(size: 12))
                    Button(T("settings.remote.add")) { m.setAdding(true) }
                }
            }
        }
    }
}

/// The pairing link as a QR code: sharp pixels, dark on a white plate, whichever the appearance.
private struct QRImage: View {
    let link: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.white)
            if let i = link.flatMap(Self.image) {
                Image(nsImage: i).interpolation(.none).resizable().padding(10)
            } else {
                BrandSpinnerView()
            }
        }
    }

    static func image(_ url: URL) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let o = f.outputImage, let cg = CIContext().createCGImage(o, from: o.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: o.extent.width, height: o.extent.height))
    }
}
