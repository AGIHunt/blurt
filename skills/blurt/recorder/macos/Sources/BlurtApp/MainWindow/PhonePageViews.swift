// The 手机和电脑 / Phones and Computers page's views (PhonePage.swift has the model; docs/design/remote-desktop-viewer.md
// §One page for the devices). Top to bottom: a new device waiting for a yes, then three groups — the devices that can
// control this Mac (every paired phone and computer, then Add Device…, whose code takes its place while open), the
// computers this Mac controls (ViewerStore's, the Computers window's rows, then Add Computer…), and this Mac (only what
// stands in a device's way; all well is one line) — then what to try while a phone should be connecting and isn't, and
// where the phone app comes from. What shows is PhoneChecks' decision (BlurtCore); the options (keys on screen, the
// screen, the relay) stay in Settings → 手机和电脑, one button away. No device is listed anywhere else in Settings.
//
// The grid: the page's title, the headings and the rows' marks on the column's left edge; a row's text 28 pt in (an
// 18 pt mark slot and 10), Settings' row metrics; every row's one button at the trailing edge, and a list's Add… under
// it on the same edge. PhonePairingCode and PhoneAsk are one look for the code wherever it is shown.
import AppKit
import CoreImage
import SwiftUI
import BlurtCore

struct PhonePageView: View {
    @ObservedObject private var m = PhoneModel.shared
    @ObservedObject private var viewer = ViewerStore.shared
    @State private var removing: RemoteServer.Device?
    @State private var addingComputer = false
    @State private var log = RemoteConnectionLog.all()
    @State private var logOpen = false

    var body: some View {
        let f = m.facts
        let problems = PhoneChecks.problems(f), tips = PhoneChecks.tips(f)
        FullPageFrame(title: T("feature.phone")) {
            // the page's own button, on the title's line at the column's trailing edge (FullPageFrame has the title
            // and 20 pt under it; the options are Settings')
            Color.clear.frame(maxWidth: .infinity).frame(height: 0)
                .overlay(alignment: .bottomTrailing) {
                    Button(T("phone.settings")) { AppEnvironment.settings?.show(pane: "remote") }
                        .buttonStyle(SettingsOutlinedButtonStyle(compact: true))
                        .help(T("phone.settings.tip"))
                        .offset(y: -20)
                }
            // a new device waiting for a yes comes first, whatever else is on the page
            if let who = m.status.asking {
                PhoneAsk(who: who, check: m.status.askingCheck ?? "") { m.answer($0) }.padding(.bottom, 4)
            }
            PhoneSection(T("phone.paired"), first: m.status.asking == nil) { controllers }
            PhoneSection(T("settings.remote.section.computers")) { computers }
            if !log.isEmpty { PhoneSection(T("phone.log")) { connections } }
            PhoneSection(T("phone.mac")) { mac(f, problems) }
            if !tips.isEmpty {
                PhoneSection(T("phone.tips")) {
                    ForEach(Array(tips.enumerated()), id: \.offset) { i, t in tip(i + 1, t) }
                }
            }
            app
        }
        .phoneRemoveAlert($removing)
        .onReceive(NotificationCenter.default.publisher(for: RemoteConnectionLog.changed)) { _ in log = RemoteConnectionLog.all() }
        .sheet(isPresented: $addingComputer) {
            AddComputerView { addingComputer = false; viewer.cancelPairing() }
        }
        // paired: the sheet's job is done (a failure stays on it, with Try Again or Back)
        .onChange(of: viewer.pairedCount) { _ in addingComputer = false }
    }

    // MARK: devices that control this Mac

    /// Every paired phone and computer, then Add Device… — or, while it's open, the code in its place.
    @ViewBuilder private var controllers: some View {
        ForEach(m.devices) { d in device(d) }
        if m.adding {
            PhoneLine { PhonePairingCode(link: m.status.pairingLink, renews: m.status.pairingRenews, failure: m.status.failure) { m.setAdding(false) } }
        } else {
            // nothing paired: one row says so; Add Device… is the list's last line whether it's empty or not
            if m.devices.isEmpty {
                PhoneRow(title: T("phone.none"), detail: T("phone.none.detail"), quiet: true) { EmptyView() }
            }
            PhoneAddLine(title: T("settings.remote.add"), help: T("phone.add.tip")) { m.setAdding(true) }
        }
    }

    private func device(_ d: RemoteServer.Device) -> some View {
        let on = m.status.connectedID == d.id
        return PhoneRow(symbol: PhoneText.symbol(d), title: PhoneStatus.name(d.name),
                        detail: on ? PhoneText.connected(m.status.path) : PhoneText.lastUsed(d), detailTone: on ? .good : .off) {
            // the same trailing column as the computers' rows: Remove is a rare action, in the ⋯ menu
            RowMenu(label: T("viewer.more"), visible: true) {
                Button(T("phone.remove")) { removing = d }
                    .accessibilityLabel(T("phone.remove.named", PhoneStatus.name(d.name)))
            }
        }
        .contextMenu { Button(T("phone.remove")) { removing = d } }
    }

    // MARK: who was in this Mac

    /// The latest three sessions and pairings, newest first (RemoteConnectionLog); Show All opens the rest in a box that scrolls on its
    /// own, so a long log never pushes the page down.
    @ViewBuilder private var connections: some View {
        ForEach(log.suffix(3).reversed()) { e in logRow(e) }
        if log.count > 3 {
            if logOpen {
                ScrollView {
                    VStack(spacing: 0) { ForEach(log.dropLast(3).reversed()) { e in logRow(e) } }
                }
                .frame(maxHeight: 260)
            }
            PhoneLine {
                Button(T(logOpen ? "phone.log.less" : "phone.log.all", log.count)) { logOpen.toggle() }
                    .buttonStyle(.plain).foregroundStyle(Color.brandInk).font(.system(size: SettingsMetrics.titleSize))
            }
        }
    }

    private func logRow(_ e: RemoteConnection) -> some View {
        PhoneRow(symbol: e.paired ? "link" : "clock", title: PhoneStatus.name(e.name), detail: PhoneText.logLine(e)) { EmptyView() }
    }

    // MARK: computers this Mac controls

    /// The viewer's computers, the rows of the Computers window in this page's grid, then Add Computer….
    @ViewBuilder private var computers: some View {
        ForEach(viewer.computers) { c in
            PhoneLine { ComputerRow(computer: c, style: .page, addAgain: { addingComputer = true }) }
        }
        if viewer.computers.isEmpty {
            PhoneRow(title: T("phone.computers.none"), detail: T("viewer.empty"), quiet: true) { EmptyView() }
        }
        PhoneAddLine(title: T("viewer.add")) { addingComputer = true }
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
                // what to do, in words; macOS's own error only on hover (and in the log)
                PhoneRow(tone: .bad, title: T("phone.mac.deaf"), detail: PhoneText.listenFailure(why)) {
                    Button(T("phone.mac.deaf.retry")) { m.listenAgain() }
                }
                .help(why == RemoteServer.portInUse ? "" : why)
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
    /// Why phones and computers can't connect, in words (RemoteServer.Status.failure): the port taken, or anything else macOS said.
    static func listenFailure(_ why: String) -> String {
        why == RemoteServer.portInUse ? T("phone.mac.deaf.in_use") : T("phone.mac.deaf.other")
    }

    /// macOS 15 asks before an app may use the local network (Privacy & Security → Local Network); earlier ones have
    /// no such list to point at.
    static var vpnTip: String {
        if #available(macOS 15, *) { return T("phone.tips.vpn.local") }
        return T("phone.tips.vpn")
    }

    /// "Last used 3 days ago"; a phone that has never been back since pairing: "Not connected".
    /// "Paired · Today 10:40", "Today 10:42–11:05 · Same network", "Today 10:42 · Connected now"
    static func logLine(_ e: RemoteConnection) -> String {
        let day = DateFormatter()
        day.locale = Loc.locale
        day.dateStyle = .medium
        day.timeStyle = .short
        day.doesRelativeDateFormatting = true
        let time = DateFormatter()
        time.locale = Loc.locale
        time.dateStyle = .none
        time.timeStyle = .short
        if e.paired { return T("phone.log.paired", day.string(from: e.start)) }
        let span = e.end.map { "\(day.string(from: e.start))–\(time.string(from: $0))" } ?? T("phone.log.now", day.string(from: e.start))
        guard let p = e.path.flatMap(RemoteServer.Path.init(rawValue:)) else { return span }
        return "\(span) · \(path(p))"
    }

    static func lastUsed(_ d: RemoteServer.Device) -> String {
        guard let t = d.lastSeen else { return T("settings.remote.not_connected") }
        let f = RelativeDateTimeFormatter()
        f.locale = Loc.locale
        return T("settings.remote.last_used", f.localizedString(for: t, relativeTo: Date()))
    }

    /// The connected device's line: "Connected · Same network" (the path in the agreed terms), "Connecting · Public
    /// connection service" while the direct path isn't open yet.
    static func connected(_ p: RemoteServer.Path?) -> String {
        guard let p else { return T("settings.remote.connected") }
        if p == .meeting { return T("settings.remote.away.connecting", path(p)) }
        return T("viewer.state.connected", path(p))
    }

    /// A path's name (copy.md's Connection paths). The owner's relay with the pointer and picture direct is "Direct".
    static func path(_ p: RemoteServer.Path) -> String {
        switch p {
        case .local: T("settings.remote.path.local")
        case .tailscale: T("settings.remote.path.tailscale")
        case .overlay: T("settings.remote.path.overlay")
        case .direct, .goBetween: T("settings.remote.path.direct")
        case .relay: T("settings.remote.path.relay")
        case .meeting: T("settings.remote.path.go_between")
        }
    }

    /// A paired device's mark, by what its hello said it is (RemoteServer.Device.kind): a computer, an iPad, a phone.
    static func symbol(_ d: RemoteServer.Device) -> String {
        if d.isComputer { return d.name.localizedCaseInsensitiveContains("MacBook") ? "laptopcomputer" : "desktopcomputer" }
        return d.name.localizedCaseInsensitiveContains("iPad") ? "ipad" : "iphone"
    }
}

// MARK: - pieces Settings → Phone shows too

/// The pairing code: the QR on its white plate, how to scan it, what went wrong opening the port, Cancel (Esc).
struct PhonePairingCode: View {
    var link: URL?
    /// when this code gives way to the next: "1:40 left", ticking once a second while the card shows
    var renews: Date?
    var failure: String?
    var cancel: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            QRImage(link: link).frame(width: 124, height: 124)
                .accessibilityLabel(T("settings.remote.scan"))
            VStack(alignment: .leading, spacing: 6) {
                Text(T("phone.add.title")).font(.system(size: SettingsMetrics.headerSize, weight: .semibold))
                Text(T("settings.remote.scan.detail")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let renews, link != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { t in
                        Text(T("phone.add.left", Self.left(renews, t.date)))
                            .font(.system(size: SettingsMetrics.detailSize).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .accessibilityHidden(true)      // a number that changes every second is noise to VoiceOver
                }
                if let f = failure {
                    Text(PhoneText.listenFailure(f)).help(f == RemoteServer.portInUse ? "" : f).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandAttnInk).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button(T("settings.remote.cancel"), action: cancel)
                        .buttonStyle(SettingsOutlinedButtonStyle(compact: true))
                        .keyboardShortcut(.cancelAction)
                    // for another computer away from here (Add Computer takes it pasted): the same code, as text
                    if let link {
                        Button(copied ? T("settings.remote.link_copied") : T("settings.remote.copy_link")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.absoluteString, forType: .string)
                            // the link copied outlives the code on screen (10 minutes), and says so
                            RemoteServer.shared.pairingLinkCopied()
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { copied = false }
                        }
                        .buttonStyle(SettingsOutlinedButtonStyle(compact: true))
                    }
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .phoneCard()
    }
}

extension PhonePairingCode {
    /// "1:40": minutes and seconds to `until` (the desktop app's timeLeft), never below 0:00.
    static func left(_ until: Date, _ now: Date) -> String {
        let s = max(0, Int((until.timeIntervalSince(now)).rounded(.up)))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

extension View {
    /// The page's one quiet card (the code, a question): a soft fill and hairline edge, the same in both themes.
    func phoneCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous)
        return padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Color.primary.opacity(0.035)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// A phone used the code from another network (through the relay) and waits: the six digits, large — the yes is for
/// the phone showing the same ones. No default button: Return must not say yes.
struct PhoneAsk: View {
    var who: String
    var check: String
    var answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            question
            // anti-scam: said on every pairing, where the owner is looking (remote-1.1.md §3)
            Label {
                Text(T("settings.remote.ask.caution")).font(.system(size: SettingsMetrics.detailSize, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        }
        .phoneCard()
    }

    private var question: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "lock.shield").font(.system(size: 20)).foregroundStyle(Color.brandInk)
                .frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(T("settings.remote.ask.title", PhoneStatus.name(who))).font(.system(size: SettingsMetrics.titleSize, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(T("settings.remote.ask.detail", PhoneStatus.name(who))).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityValue(check)
            // grouped in threes, as the other device shows them
            Text(Self.grouped(check)).font(.system(size: 22, weight: .semibold, design: .monospaced))
                .padding(.trailing, 14).accessibilityHidden(true)
            Button(T("settings.remote.ask.no")) { answer(false) }.buttonStyle(SettingsOutlinedButtonStyle(compact: true))
            Button(T("settings.remote.ask.yes")) { answer(true) }.buttonStyle(SettingsPrimaryButtonStyle())
        }
    }

    static func grouped(_ c: String) -> String {
        guard c.count == 6 else { return c }
        return "\(c.prefix(3)) \(c.suffix(3))"
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
    /// the page's first section, straight under the title: no gap of its own
    var first = false
    var content: Content
    var accessory: Accessory

    init(_ title: String, first: Bool = false, @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.first = first
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
        .padding(.top, first ? 0 : SettingsMetrics.groupGap)
    }
}

extension PhoneSection where Accessory == EmptyView {
    init(_ title: String, first: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(title, first: first, content: content) { EmptyView() }
    }
}

/// A list's last line: its Add…, a "+" in the marks' slot and the words in brand ink on the text column (Login Items'
/// "+", in words) — part of the list, not a button floating under it.
struct PhoneAddLine: View {
    var title: String
    var help: String?
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        PhoneLine {
            Button(action: action) {
                HStack(alignment: .center, spacing: SettingsMetrics.iconGap) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: SettingsMetrics.iconSlot)
                    Text(title).font(.system(size: SettingsMetrics.titleSize))
                }
                .foregroundStyle(Color.brandInk)
                .opacity(hovering ? 0.8 : 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help ?? "")
        }
    }
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
                    .padding(.leading, SettingsMetrics.iconSlot + SettingsMetrics.iconGap)
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
    /// a list's empty state: said quietly, so it doesn't read as a device of that name
    var quiet = false
    @ViewBuilder var control: Control

    var body: some View {
        PhoneLine {
            HStack(alignment: .center, spacing: 14) {
                HStack(alignment: .center, spacing: SettingsMetrics.iconGap) {
                    Group {
                        if let t = tone { StatusDot(tone: t, diameter: 14) }
                        else if let s = symbol {
                            Image(systemName: s).font(.system(size: 14)).foregroundStyle(.secondary).accessibilityHidden(true)
                        } else {
                            Color.clear      // no mark (an empty list's line): the words stay on the text column
                        }
                    }
                    .frame(width: SettingsMetrics.iconSlot, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: SettingsMetrics.titleSize)).fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(quiet ? .secondary : .primary)
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
                control.buttonStyle(SettingsOutlinedButtonStyle(compact: true))
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
