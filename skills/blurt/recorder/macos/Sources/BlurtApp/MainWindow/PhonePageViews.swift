// The Phone page's views (PhonePage.swift has the model). Top to bottom: the one headline (who is connected, and
// how), a new phone waiting for a yes, this Mac (only what stands in a phone's way; all well is one line), the paired
// phones with Add a Phone, where the phone app comes from, and what to try while a phone should be connecting and
// isn't. What shows is PhoneChecks' decision (BlurtCore); the options (keys on screen, the screen, the relay) stay in
// Settings → Phone, one button away.
//
// The grid: the page's title, the cards' edges, the headings and the rows' marks on the column's left edge; a row's
// text 28 pt in (an 18 pt mark slot and 10), Settings' row metrics. PhonePairingCode, PhoneAsk and PhoneRemoveAlert
// are Settings → Phone's too (RemotePane.swift): one look for the code wherever it is shown.
import AppKit
import CoreImage
import SwiftUI
import BlurtCore

struct PhonePageView: View {
    @ObservedObject private var m = PhoneModel.shared
    @State private var removing: RemoteServer.Device?

    var body: some View {
        let f = m.facts
        let head = PhoneChecks.headline(f), problems = PhoneChecks.problems(f), tips = PhoneChecks.tips(f)
        FullPageFrame(title: T("phone.title")) {
            // the page's own button, on the title's line at the column's trailing edge (FullPageFrame has the title
            // and 20 pt under it; the options are Settings')
            Color.clear.frame(maxWidth: .infinity).frame(height: 0)
                .overlay(alignment: .bottomTrailing) {
                    Button(T("phone.settings")) { AppEnvironment.settings?.show(pane: "remote") }
                        .buttonStyle(SettingsOutlinedButtonStyle())
                        .help(T("phone.settings.tip"))
                        .offset(y: -20)
                }
            PhoneHeadline(head: head, adding: m.adding, link: m.status.pairingLink, failure: m.status.failure,
                          add: { m.setAdding(true) }, cancel: { m.setAdding(false) })
            if let who = m.status.asking {
                PhoneAsk(who: who, check: m.status.askingCheck ?? "") { m.answer($0) }.padding(.top, 10)
            }
            // nothing paired yet: the phone needs the app before anything else on this page matters
            if head == .nonePaired { app }
            PhoneSection(T("phone.mac")) { mac(f, problems) }
            if !m.devices.isEmpty {
                PhoneSection(T("phone.paired")) {
                    if m.adding {
                        PhoneLine { PhonePairingCode(link: m.status.pairingLink, failure: m.status.failure) { m.setAdding(false) } }
                    }
                    ForEach(m.devices) { d in device(d) }
                } accessory: {
                    if !m.adding {
                        Button(T("phone.add")) { m.setAdding(true) }
                            .buttonStyle(SettingsOutlinedButtonStyle(compact: true))
                            .help(T("phone.add.tip"))
                    }
                }
            }
            if head != .nonePaired { app }
            if !tips.isEmpty {
                PhoneSection(T("phone.tips")) {
                    ForEach(Array(tips.enumerated()), id: \.offset) { i, t in tip(i + 1, t) }
                }
            }
        }
        .phoneRemoveAlert($removing)
    }

    // MARK: the phone app

    /// Said plainly, in one line: it isn't in the stores, and these are the build steps.
    private var app: some View {
        PhoneSection(T("phone.app")) {
            PhoneRow(symbol: "hammer", title: T("phone.app.where")) {
                HStack(spacing: 14) {
                    PhoneLink(T("phone.app.ios"), url: PhoneLinks.ios)
                    PhoneLink(T("phone.app.android"), url: PhoneLinks.android)
                }
            }
        }
    }

    // MARK: this Mac

    @ViewBuilder private func mac(_ f: PhoneFacts, _ problems: [PhoneChecks.Problem]) -> some View {
        if problems.isEmpty {
            PhoneRow(tone: .good, title: T("phone.mac.ok"), detail: works(f)) { EmptyView() }
        }
        ForEach(Array(problems.enumerated()), id: \.offset) { _, p in
            switch p {
            case .accessibility:
                PhoneRow(tone: .warn, title: T("phone.mac.accessibility"), detail: T("phone.mac.accessibility.detail")) {
                    Button(T("settings.kit.allow")) { PermissionGuide.shared.start(.all, only: [.accessibility], source: .phone) }
                }
            case let .notListening(why):
                PhoneRow(tone: .bad, title: T("phone.mac.deaf"), detail: T("phone.mac.deaf.detail", why)) {
                    Button(T("phone.mac.deaf.retry")) { m.listenAgain() }
                }
            case .screenRecording:
                PhoneRow(tone: .warn, title: T("phone.mac.screen"), detail: T("phone.mac.screen.detail")) {
                    Button(T("settings.kit.allow")) { PermissionGuide.shared.start(.all, only: [.screen], source: .phone) }
                }
            case .relayUnreachable:
                PhoneRow(tone: .warn, title: T("phone.mac.relay"), detail: T("phone.mac.relay.detail")) {
                    HStack(spacing: 8) {
                        Button(T("phone.mac.relay.again")) { m.checkRelay() }
                        Button(T("phone.relay_settings")) { PhoneLinks.relaySettings() }
                    }
                }
            }
        }
    }

    /// All well, and what that covers: "Pointer and keys · Screen · Away from home through your relay".
    private func works(_ f: PhoneFacts) -> String {
        var parts = [T("phone.mac.ok.keys")]
        if f.screenWanted { parts.append(T("phone.mac.ok.screen")) }
        switch f.relay {
        case .ok: parts.append(T("phone.mac.ok.relay"))
        case .checking: parts.append(T("phone.mac.ok.relay_checking"))
        case .goBetween: parts.append(T("phone.mac.ok.go_between"))
        case .none, .failed: break
        }
        return parts.joined(separator: " · ")
    }

    // MARK: phones

    private func device(_ d: RemoteServer.Device) -> some View {
        let on = m.status.connectedID == d.id
        return PhoneRow(symbol: "iphone", title: PhoneStatus.name(d.name), detail: on ? T("settings.remote.connected") : PhoneText.lastUsed(d),
                        detailTone: on ? .good : nil) {
            Button(T("phone.remove")) { removing = d }
                .buttonStyle(SettingsOutlinedButtonStyle(compact: true))
                .help(T("settings.remote.remove.detail"))
                .accessibilityLabel(T("phone.remove.named", PhoneStatus.name(d.name)))
        }
        .contextMenu { Button(T("phone.remove")) { removing = d } }
    }

    // MARK: when it won't connect

    private func tip(_ n: Int, _ t: PhoneChecks.Tip) -> some View {
        let text: String = switch t {
        case .sameNetwork: T("phone.tips.network")
        case .appOpenMacAwake: T("phone.tips.open")
        case .vpnFirewall: PhoneText.vpnTip
        case .awayNeedsRelay: T("phone.tips.away.none")
        case .awayUsesRelay: T("phone.tips.away.ok")
        case .awayGoBetween: T("phone.tips.away.go_between")
        }
        return PhoneLine {
            HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.iconGap) {
                Text("\(n)").font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.tertiary)
                    .frame(width: SettingsMetrics.iconSlot)
                    .accessibilityHidden(true)
                Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if t == .awayNeedsRelay {
                    InkLink(T("phone.relay_settings")) { PhoneLinks.relaySettings() }.font(.system(size: 12))
                }
            }
        }
    }
}

enum PhoneLinks {
    /// The build steps, until the apps are in the stores.
    static let ios = URL(string: "https://github.com/AGIHunt/blurt/blob/main/apps/ios/README.md#build-it-yourself")!
    static let android = URL(string: "https://github.com/AGIHunt/blurt/blob/main/apps/android/README.md#build-it-yourself")!

    /// Settings → Phone, at the relay's address.
    static func relaySettings() { AppEnvironment.settings?.show(pane: "remote/remote.relay.address") }
}

enum PhoneText {
    /// macOS 15 asks before an app may use the local network (Privacy & Security → Local Network); earlier ones have
    /// no such list to point at.
    static var vpnTip: String {
        if #available(macOS 15, *) { return T("phone.tips.vpn.local") }
        return T("phone.tips.vpn")
    }

    /// "Last used 3 days ago"; a phone that has never been back since pairing: "Not connected".
    static func lastUsed(_ d: RemoteServer.Device) -> String {
        guard let t = d.lastSeen else { return T("settings.remote.not_connected") }
        return T("settings.remote.last_used", RelativeDateTimeFormatter().localizedString(for: t, relativeTo: Date()))
    }
}

// MARK: - the headline

/// The page's one fact, on a quiet card: the phone's mark (mint with a check once one is connected), who and how, and
/// with no phone paired the page's one primary, Add a Phone… (↩). Adding the first phone, the code takes the card.
struct PhoneHeadline: View {
    var head: PhoneChecks.Headline
    var adding: Bool
    var link: URL?
    var failure: String?
    var add: () -> Void
    var cancel: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous)
        Group {
            if head == .nonePaired, adding {
                PhonePairingCode(link: link, failure: failure, cancel: cancel)
            } else {
                HStack(alignment: .center, spacing: 14) {
                    mark
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    if head == .nonePaired {
                        Button(T("phone.add"), action: add)
                            .buttonStyle(SettingsPrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction)
                            .help(T("phone.add.tip"))
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Color.primary.opacity(0.04)))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }

    private var connected: Bool { if case .connected = head { true } else { false } }

    private var mark: some View {
        let tile = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Image(systemName: "iphone").font(.system(size: 22, weight: .regular))
            .foregroundStyle(connected ? Color.brandInk : Color.secondary)
            .frame(width: 44, height: 44)
            .background(tile.fill(connected ? Color.brandTint : Color.primary.opacity(0.06)))
            // the state's shape twin: a check once a phone is here
            .overlay(alignment: .bottomTrailing) {
                if connected {
                    StatusDot(tone: .good, diameter: 14)
                        .background(Circle().fill(Color(nsColor: .textBackgroundColor)).padding(-2))
                        .offset(x: 4, y: 4)
                }
            }
            .accessibilityHidden(true)
    }

    private var title: String {
        switch head {
        case .nonePaired: T("phone.head.none")
        case .notConnected: T("phone.head.not_connected")
        case let .connected(name, _): T("phone.head.connected", PhoneStatus.name(name))
        }
    }

    private var detail: String {
        switch head {
        case .nonePaired: T("phone.head.none.detail")
        case .notConnected: T("phone.head.not_connected.detail")
        case let .connected(_, viaRelay): viaRelay ? T("phone.head.relay") : T("phone.head.local")
        }
    }
}

// MARK: - pieces Settings → Phone shows too

/// The pairing code: the QR on its white plate, how to scan it, what went wrong opening the port, Cancel (Esc).
struct PhonePairingCode: View {
    var link: URL?
    var failure: String?
    var cancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            QRImage(link: link).frame(width: 168, height: 168)
                .accessibilityLabel(T("settings.remote.scan"))
            VStack(alignment: .leading, spacing: 8) {
                Text(T("settings.remote.scan")).font(.system(size: SettingsMetrics.titleSize, weight: .medium))
                Text(T("settings.remote.scan.detail")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let f = failure {
                    Text(f).font(.system(size: 12)).foregroundStyle(Color.brandAttnInk).fixedSize(horizontal: false, vertical: true)
                }
                Button(T("settings.remote.cancel"), action: cancel)
                    .buttonStyle(SettingsOutlinedButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .padding(.top, 2)
            }
            .frame(maxWidth: 420, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}

/// A phone used the code from another network (through the relay) and waits: the six digits, large — the yes is for
/// the phone showing the same ones. No default button: Return must not say yes.
struct PhoneAsk: View {
    var who: String
    var check: String
    var answer: (Bool) -> Void

    var body: some View {
        SettingsNotice(title: T("settings.remote.ask.title", PhoneStatus.name(who)), detail: T("settings.remote.ask.detail", check)) {
            HStack(spacing: 8) {
                Text(check).font(.system(size: 20, weight: .semibold, design: .monospaced)).padding(.trailing, 8)
                    .accessibilityHidden(true)
                Button(T("settings.remote.ask.no")) { answer(false) }
                Button(T("settings.remote.ask.yes")) { answer(true) }
            }
            .buttonStyle(SettingsOutlinedButtonStyle())
        }
    }
}

extension View {
    /// "Remove iPhone?" — it has to scan a new code to come back.
    func phoneRemoveAlert(_ removing: Binding<RemoteServer.Device?>) -> some View {
        let d = removing.wrappedValue
        return alert(T("settings.remote.remove.title", d.map { PhoneStatus.name($0.name) } ?? ""),
                     isPresented: Binding(get: { removing.wrappedValue != nil }, set: { if !$0 { removing.wrappedValue = nil } })) {
            Button(T("settings.remote.cancel"), role: .cancel) {}
            Button(T("settings.remote.remove"), role: .destructive) { if let d { RemoteServer.shared.remove(d.id) } }
        } message: { Text(T("settings.remote.remove.detail")) }
    }
}

/// The pairing link as a QR code: sharp pixels, dark on a white plate, whichever the appearance.
struct QRImage: View {
    let link: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white)
                // on a white page the plate still has an edge
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
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

// MARK: - the page's rows

/// A section: its heading (Settings' size) on the column's edge with an optional small button at its end, then its
/// rows with hairlines between them — never under the heading.
struct PhoneSection<Content: View, Accessory: View>: View {
    var title: String
    var content: Content
    var accessory: Accessory

    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: SettingsMetrics.headerSize, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
            }
            .frame(minHeight: 16)
            // over the heading's line, never making it taller: every heading starts at one height
            .overlay(alignment: .trailing) { accessory }
            .padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                // the first row's hairline lies on the top edge, where the clip takes it away
                .padding(.top, -1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
        }
        .padding(.top, SettingsMetrics.groupGap)
    }
}

extension PhoneSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) { self.init(title, content: content) { EmptyView() } }
}

/// One line of a section: the hairline above it and the row's padding (Settings' SettingsLine, on this page's edge).
struct PhoneLine<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.displayScale) private var scale

    var body: some View {
        content
            .padding(.vertical, SettingsMetrics.rowPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1 / max(scale, 1)).allowsHitTesting(false)
            }
    }
}

/// A row: its mark in the 18 pt slot (a state's disc, or a quiet symbol), a title over one secondary line, and at most
/// one thing to do at the trailing edge. The disc is hidden from VoiceOver, so the row says its state in words.
struct PhoneRow<Control: View>: View {
    var tone: Tone?
    var symbol: String?
    var title: String
    var detail: String?
    /// the secondary line is a state of its own ("Connected"): its disc before the words
    var detailTone: Tone?
    @ViewBuilder var control: Control

    var body: some View {
        PhoneLine {
            HStack(alignment: .center, spacing: 14) {
                HStack(alignment: .center, spacing: SettingsMetrics.iconGap) {
                    Group {
                        if let t = tone { StatusDot(tone: t, diameter: 14) }
                        else if let s = symbol {
                            Image(systemName: s).font(.system(size: 13)).foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                    }
                    .frame(width: SettingsMetrics.iconSlot)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: SettingsMetrics.titleSize)).fixedSize(horizontal: false, vertical: true)
                        if let d = detail, !d.isEmpty {
                            HStack(alignment: .center, spacing: 5) {
                                if let t = detailTone { StatusDot(tone: t) }
                                Text(d).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(spoken)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                control.buttonStyle(SettingsOutlinedButtonStyle())
            }
        }
    }

    private var spoken: String {
        switch tone {
        case .warn?, .bad?: T("phone.ax.needs_you")
        case .good?: T("phone.ax.ok")
        default: ""
        }
    }
}

/// A link out to a web page, in brand ink with the arrow that says it leaves the app; its tooltip is where it goes.
struct PhoneLink: View {
    var title: String
    var url: URL
    init(_ title: String, url: URL) { self.title = title; self.url = url }

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12.5)).foregroundStyle(Color.brandInk)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        .help(url.absoluteString)
        .accessibilityAddTraits(.isLink)
    }
}
