// The 远程控制 / Remote Control page's views (PhonePage.swift has the model; docs/design/remote-desktop-viewer.md
// §One page for the devices). Top to bottom: a new device waiting for a yes; this Mac's state — one quiet line while all
// is well, or one notice per thing that stands in a device's way, each with its fix (system.md §3.4: a state that
// concerns the whole page is said once, above the first section); the devices that can control this Mac (every paired
// phone and computer, then Add Device…, whose code takes its place while open, and under it where the phone app comes
// from); the computers this Mac controls (ViewerStore's, the Computers window's rows, then Add Computer…); and at the
// foot, closed until asked for, what to try while a phone should be connecting and isn't. What shows is PhoneChecks'
// decision (BlurtCore); the options (keys on screen, the screen, the relay) stay in Settings → 远程控制, one button
// away. No device is listed anywhere else in Settings.
//
// The grid: the page's title, the headings and the rows' marks on the column's left edge; a row's text 28 pt in (an
// 18 pt mark slot and 10), Settings' row metrics; every row's one button at the trailing edge, and a list's Add… under
// it on the same edge. PhonePairingCode and PhoneAsk are one look for the code wherever it is shown.
import AppKit
import CoreImage
import SwiftUI
import BlurtCore
import BlurtRemoteKit

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
            // this Mac next: what a device that can't connect runs into is the first thing read
            mac(f, problems)
            PhoneSection(T("phone.paired"), first: m.status.asking == nil && !showsMac(f, problems)) {
                controllers
                app
            }
            PhoneSection(T("phone.section.computers")) { computers }
            if !log.isEmpty { PhoneSection(T("phone.log")) { connections } }
            // what to try, closed at the page's foot (Settings' Advanced): one line until it's wanted
            if !tips.isEmpty {
                PhoneSection(T("phone.tips"), disclosure: $m.tipsOpen) {
                    ForEach(Array(tips.enumerated()), id: \.offset) { i, t in tip(i + 1, t) }
                }
            }
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
        return PhoneDeviceRow(device: d, detail: on ? PhoneText.connected(m.status.path) : PhoneText.lastUsed(d), tone: on ? .good : .off) {
            removing = d
        }
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
        // the name this Mac calls it now, if it's still paired and was renamed
        let d = m.devices.first { $0.id == e.deviceID }
        return PhoneRow(symbol: e.paired ? "link" : "clock", title: PhoneStatus.name(RemoteAlias.shown(e.name, alias: d?.alias)),
                        detail: PhoneText.logLine(e)) { EmptyView() }
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

    /// Said plainly, in one footnote under the devices' list, next to Add Device… (a fact needed once, before the first
    /// pairing, not a section of its own): it isn't in the stores, and these are the build steps.
    private var app: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(T("phone.app.where")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PhoneLink(T("phone.app.ios"), url: PhoneLinks.ios).fixedSize()
            PhoneLink(T("phone.app.android"), url: PhoneLinks.android).fixedSize()
        }
        .padding(.leading, SettingsMetrics.iconSlot + SettingsMetrics.iconGap)
        .padding(.bottom, 2)
    }

    // MARK: this Mac

    /// Something shows for this Mac: a problem, or the all-well line once there is a device it is about.
    private func showsMac(_ f: PhoneFacts, _ problems: [PhoneChecks.Problem]) -> Bool { !problems.isEmpty || !m.devices.isEmpty }

    /// All well: one quiet line under the title (none before anything is paired: there is nothing yet that could control
    /// this Mac). Otherwise one notice per thing in a device's way, most in the way first, each with its fix.
    @ViewBuilder private func mac(_ f: PhoneFacts, _ problems: [PhoneChecks.Problem]) -> some View {
        if problems.isEmpty {
            if !m.devices.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.iconGap) {
                    StatusDot(tone: .good).frame(width: SettingsMetrics.iconSlot)
                        // a disc has no baseline: its centre on the words' middle
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    (Text(T("phone.mac.ok")).foregroundColor(.primary) + Text("   " + works(f)).foregroundColor(.secondary))
                        .font(.system(size: SettingsMetrics.detailSize + 0.5)).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .padding(.bottom, 4)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(problems.enumerated()), id: \.offset) { _, p in notice(p) }
            }
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder private func notice(_ p: PhoneChecks.Problem) -> some View {
        switch p {
        case .accessibility:
            PhoneNotice(title: T("phone.mac.accessibility"), detail: T("phone.mac.accessibility.detail")) {
                Button(T("settings.kit.allow")) { PermissionGuide.shared.start(.all, only: [.accessibility], source: .phone) }
            }
        case let .notListening(why):
            // what to do, in words; macOS's own error only on hover (and in the log)
            PhoneNotice(tone: .bad, title: T("phone.mac.deaf"), detail: PhoneText.listenFailure(why), help: why == RemoteServer.portInUse ? "" : why) {
                Button(T("phone.mac.deaf.retry")) { m.listenAgain() }
            }
        case .screenRecording:
            PhoneNotice(title: T("phone.mac.screen"), detail: T("phone.mac.screen.detail")) {
                Button(T("settings.kit.allow")) { PermissionGuide.shared.start(.all, only: [.screen], source: .phone) }
            }
        case .relayUnreachable:
            // what still works, with the public connection service as the fallback or without it; the address on hover
            PhoneNotice(title: T("phone.mac.relay"), detail: T(RemoteServer.goBetweenOn ? "phone.mac.relay.detail.fallback" : "phone.mac.relay.detail"),
                        help: RemoteServer.relayAddress ?? "") {
                HStack(spacing: 8) {
                    Button(T("phone.mac.relay.again")) { m.checkRelay() }
                    Button(T("phone.relay_settings")) { PhoneLinks.relaySettings() }
                }
            }
        case .goBetweenBusy:
            PhoneNotice(title: T("phone.away.busy"), detail: T("phone.away.busy.detail")) {
                Button(T("phone.relay_settings")) { PhoneLinks.relaySettings() }
            }
        case .noDirect:
            PhoneNotice(title: T("phone.away.no_direct"), detail: T("phone.away.no_direct.detail")) {
                Button(T("phone.relay_settings")) { PhoneLinks.relaySettings() }
            }
        }
    }

    /// All well, and what that covers: "Pointer and keys · Screen · From other networks through your relay". While a
    /// device is connected its row says the way it came, so the way in from elsewhere isn't said beside it.
    private func works(_ f: PhoneFacts) -> String {
        var parts = [T("phone.mac.ok.keys")]
        if f.screenWanted { parts.append(T("phone.mac.ok.screen")) }
        if f.connected == nil {
            switch f.relay {
            case .ok: parts.append(T("phone.mac.ok.relay"))
            case .checking: parts.append(T("phone.mac.ok.relay_checking"))
            case .goBetween: parts.append(T("phone.mac.ok.go_between"))
            case .none, .failed: break
            }
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
        f.unitsStyle = .full
        return T("phone.last_used", spaced(f.localizedString(for: t, relativeTo: Date())))
    }

    /// 「2 小时前」, not the formatter's「2小时前」: a space between a number and Chinese, as the rest of the copy has it.
    static func spaced(_ s: String) -> String {
        func han(_ c: Character) -> Bool { c.unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } ?? false }
        func digit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
        var out = "", prev: Character?
        for c in s {
            if let p = prev, digit(p) && han(c) || han(p) && digit(c) { out.append(" ") }
            out.append(c)
            prev = c
        }
        return out
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

/// The pairing code: the QR on its white plate with when it renews under it, what to do beside it, what went wrong opening the
/// port, Copy Link for a computer on another network, and a quiet ✕ in the corner (Esc). The card is as wide as what it holds.
struct PhonePairingCode: View {
    var link: URL?
    /// when this code gives way to the next: "1:40 left", ticking once a second while the card shows
    var renews: Date?
    var failure: String?
    var cancel: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(spacing: 8) {
                QRImage(link: link).frame(width: 148, height: 148)
                    .accessibilityLabel(T("settings.remote.scan"))
                if let renews, link != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { t in
                        Text(T("phone.add.left", Self.left(renews, t.date)))
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .accessibilityHidden(true)      // a number that changes every second is noise to VoiceOver
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(T("phone.add.title")).font(.system(size: SettingsMetrics.headerSize, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(T("settings.remote.scan.detail")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let f = failure {
                    Text(PhoneText.listenFailure(f)).help(f == RemoteServer.portInUse ? "" : f).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandAttnInk).fixedSize(horizontal: false, vertical: true)
                }
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
                    .help(T("phone.pair.copy.tip"))
                    .padding(.top, 8)
                }
            }
            .frame(width: 280, alignment: .leading)
            .padding(.trailing, 16)         // the ✕'s corner
        }
        .phoneCard(hug: true)
        .overlay(alignment: .topTrailing) {
            Button(action: cancel) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(T("settings.remote.cancel"))
            .accessibilityLabel(T("settings.remote.cancel"))
            .padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    /// The page's one quiet card (the code, a question): a soft fill and hairline edge, a step stronger in dark mode where
    /// 3.5 % barely leaves the page. `hug`: as wide as what it holds, on the column's leading edge (no empty half).
    func phoneCard(hug: Bool = false) -> some View { modifier(PhoneCard(hug: hug)) }
}

private struct PhoneCard: ViewModifier {
    var hug: Bool
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous)
        return content.padding(16)
            .frame(maxWidth: hug ? nil : .infinity, alignment: .leading)
            .background(shape.fill(Color.primary.opacity(scheme == .dark ? 0.06 : 0.035)))
            .overlay(shape.strokeBorder(Color.primary.opacity(scheme == .dark ? 0.12 : 0.08), lineWidth: 0.5))
    }
}

/// A device that scanned the code waits for a yes: one stack in the same order as the Windows / Linux sheet — the question,
/// the six digits large with what to compare them with, the anti-scam line (remote-1.1.md §3) right above the buttons, then
/// Don't Allow and Allow side by side, neither one highlighted. No default button: Return must not say yes.
struct PhoneAsk: View {
    var who: String
    var check: String
    var answer: (Bool) -> Void

    private static let slot: CGFloat = 24, gap: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Self.gap) {
                Image(systemName: "lock.shield").font(.system(size: 18)).foregroundStyle(.secondary)
                    .frame(width: Self.slot).accessibilityHidden(true)
                Text(T("settings.remote.ask.title", PhoneStatus.name(who))).font(.system(size: SettingsMetrics.headerSize, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 4) {
                // grouped in threes, as the other device shows them, in the UI face's tabular digits
                Text(verbatim: Self.grouped(check)).font(.system(size: 28, weight: .semibold).monospacedDigit()).tracking(1.5)
                Text(T("settings.remote.ask.detail", PhoneStatus.name(who))).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // one element across the column: the digits one by one in their groups ("4 8 2, 7 1 3"), never as one number, then what to do
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: Self.spoken(check) + ". " + T("settings.remote.ask.detail", PhoneStatus.name(who))))
            .padding(.leading, Self.slot + Self.gap).padding(.top, 10)
            // anti-scam: said on every pairing, where the owner is looking, right above the yes
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Color.brandAttnInk)
                    .accessibilityHidden(true)
                Text(T("settings.remote.ask.caution")).font(.system(size: SettingsMetrics.titleSize))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, Self.slot + Self.gap).padding(.top, 14)
            HStack(spacing: 8) {
                Spacer()
                Button(T("settings.remote.ask.no")) { answer(false) }.buttonStyle(SettingsOutlinedButtonStyle())
                Button(T("settings.remote.ask.yes")) { answer(true) }.buttonStyle(SettingsOutlinedButtonStyle())
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .phoneCard(hug: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func grouped(_ c: String) -> String {
        guard c.count == 6 else { return c }
        return "\(c.prefix(3)) \(c.suffix(3))"
    }

    static func spoken(_ c: String) -> String {
        grouped(c).split(separator: " ").map { $0.map(String.init).joined(separator: " ") }.joined(separator: ", ")
    }
}

extension View {
    /// "Remove iPhone?" — it has to scan a new code to come back.
    func phoneRemoveAlert(_ removing: Binding<RemoteServer.Device?>) -> some View {
        let d = removing.wrappedValue
        return alert(T("settings.remote.remove.title", d.map { PhoneStatus.name($0.shown) } ?? ""),
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
/// rows with hairlines between them — never under the heading. `disclosure`: the heading opens and closes it, and its
/// rows show only while open (Settings' Advanced).
struct PhoneSection<Content: View, Accessory: View>: View {
    var title: String
    /// the page's first section, straight under the title: no gap of its own
    var first = false
    var disclosure: Binding<Bool>?
    var content: Content
    var accessory: Accessory

    init(_ title: String, first: Bool = false, disclosure: Binding<Bool>? = nil, @ViewBuilder content: () -> Content,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.first = first
        self.disclosure = disclosure
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let d = disclosure {
                    Button {
                        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.15)) {
                            d.wrappedValue.toggle()
                        }
                    } label: {
                        // "› If It Won't Connect", as Settings' Advanced heading: on the headings' edge
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                .rotationEffect(.degrees(d.wrappedValue ? 90 : 0))
                            Text(title).font(.system(size: SettingsMetrics.headerSize, weight: .semibold))
                        }
                        .foregroundStyle(.primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title)
                    .accessibilityValue(d.wrappedValue ? "1" : "0")
                    .accessibilityAddTraits(.isHeader)
                } else {
                    Text(title).font(.system(size: SettingsMetrics.headerSize, weight: .semibold)).accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 8)
            }
            .frame(minHeight: 16)
            // over the heading's line, never making it taller: every heading starts at one height
            .overlay(alignment: .trailing) { accessory }
            .padding(.bottom, 4)
            if disclosure?.wrappedValue ?? true {
                VStack(alignment: .leading, spacing: 0) { content }
                    // the first row's hairline lies on the top edge, where the clip takes it away
                    .padding(.top, -1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
            }
        }
        .padding(.top, first ? 0 : SettingsMetrics.groupGap)
    }
}

extension PhoneSection where Accessory == EmptyView {
    init(_ title: String, first: Bool = false, disclosure: Binding<Bool>? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, first: first, disclosure: disclosure, content: content) { EmptyView() }
    }
}

/// One state that concerns the whole page (Settings' SettingsNotice, on this page's column): the 16 pt disc in the
/// marks' slot, what is wrong over what it means and what still works, and its fix at the trailing edge. The tone only
/// as a faint wash and a hairline; the text in the ordinary inks.
struct PhoneNotice<Action: View>: View {
    var tone: Tone = .warn
    var title: String
    var detail: String
    /// what the words leave out (macOS's own error, the relay's address): on hover
    var help: String = ""
    @ViewBuilder var action: Action

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous)
        HStack(alignment: .center, spacing: 14) {
            HStack(alignment: .center, spacing: SettingsMetrics.iconGap) {
                StatusDot(tone: tone, diameter: 16).frame(width: SettingsMetrics.iconSlot)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: SettingsMetrics.titleSize, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(T("phone.ax.needs_you"))
                .help(help)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action.buttonStyle(SettingsOutlinedButtonStyle(compact: true))
        }
        // the disc in the column's mark slot, as every row's mark: the wash reaches out around it
        .padding(.vertical, 10).padding(.horizontal, SettingsMetrics.boxInset)
        .background(shape.fill(tint.opacity(0.08)))
        .overlay(shape.strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
        .padding(.horizontal, -SettingsMetrics.boxInset)
    }

    private var tint: Color { tone == .bad ? .brandErr : .brandAttn }
}

/// A paired phone, tablet or computer: its mark, name and state, and its ⋯ (Rename…, Remove…) only while the pointer is over the
/// row, its slot kept at rest (Settings' RowMenu); the same items in the context menu. A double-click on the name renames it too.
struct PhoneDeviceRow: View {
    var device: RemoteServer.Device
    var detail: String
    var tone: Tone
    var remove: () -> Void
    @State private var hovering = false

    @State private var renaming = false

    var body: some View {
        let name = PhoneStatus.name(device.shown)
        PhoneRow(symbol: PhoneText.symbol(device), title: name, detail: detail, detailTone: tone,
                 rename: PhoneRow.Rename(id: device.id, own: PhoneStatus.name(device.name), editing: $renaming) {
                     RemoteServer.shared.rename(device.id, to: $0)
                 }) {
            RowMenu(label: T("viewer.more"), visible: hovering) { items(name) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { items(name) }
    }

    /// The ⋯ and the context menu: Rename…, then Remove….
    @ViewBuilder private func items(_ name: String) -> some View {
        Button(T("phone.rename")) { renaming = true }
            .accessibilityLabel(T("phone.rename.named", name))
        Divider()
        Button(T("phone.remove"), action: remove)
            .accessibilityLabel(T("phone.remove.named", name))
    }
}

/// A paired device's or computer's name in its row, renamed in place (remote-1.1.md §6: what this Mac calls it, nothing sent, its id the
/// same). A double-click on the name (`doubleClick`) or Rename… in the row's ⋯ turns the words into a field where they stand, the text
/// selected; Return keeps it, Esc puts it back, an empty field brings the device's own name back, and leaving the field keeps what's
/// typed (Finder's rename). Renamed, the name's tooltip says its own name.
struct RenamableName: View {
    /// the record's id and where the row is ("page", "list"): for the tests' `rename` command
    var id = ""
    var place = "page"
    var shown: String
    var own: String
    var size: CGFloat
    /// the Computers window opens a computer on a double-click anywhere on its row: Rename… is its way in there
    var doubleClick = true
    @Binding var editing: Bool
    var commit: (String) -> Void
    @State private var text = ""
    @State private var cancelled = false
    @FocusState private var focused: Bool

    var body: some View {
        Group { if editing { field } else { label } }
            .modifier(RenameTestHook(id: id, place: place, editing: $editing, text: $text, finish: finish, cancel: cancel))
    }

    private func cancel() {
        cancelled = true
        editing = false
    }

    private var label: some View {
        Text(shown).font(.system(size: size)).lineLimit(1).truncationMode(.middle)
            .modifier(Tooltip(text: shown == own ? nil : T("phone.rename.own", own)))
            .modifier(DoubleClick(on: doubleClick) { editing = true })
    }

    private var field: some View {
        TextField(T("phone.rename"), text: $text, prompt: Text(own))
            .textFieldStyle(.plain)
            .font(.system(size: size))
            .focused($focused)
            .onSubmit(finish)
            .onExitCommand(perform: cancel)
            // clicked away (another field, another row's rename): kept, as Finder keeps it
            .onChange(of: focused) { f in if !f, editing, !cancelled { finish() } }
            // the words stay where they were: the box reaches out around them
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2))
            .padding(.horizontal, -3).padding(.vertical, -1)
            .frame(maxWidth: 280, alignment: .leading)
            .accessibilityLabel(T("phone.rename"))
            .onAppear {
                // the tests' `rename … type` may have filled it in already
                if text.isEmpty { text = shown }
                cancelled = false
                DispatchQueue.main.async { focused = true }
            }
            .onDisappear { text = "" }
    }

    private func finish() {
        guard editing else { return }
        editing = false
        commit(text)
    }

    private struct DoubleClick: ViewModifier {
        var on: Bool
        var action: () -> Void
        func body(content: Content) -> some View {
            if on { content.onTapGesture(count: 2, perform: action) } else { content }
        }
    }
}

/// Tests (`phonepage rename …`, `viewer rename …`): the field started, typed into, and ended by Return or Esc, through the field's own
/// handlers, as a double-click and the keys would. Nothing in a release build.
private struct RenameTestHook: ViewModifier {
    var id: String
    var place: String
    @Binding var editing: Bool
    @Binding var text: String
    var finish: () -> Void
    var cancel: () -> Void

    func body(content: Content) -> some View {
        #if DEBUG || BLURT_TEST_HOOKS
        content.onReceive(NotificationCenter.default.publisher(for: .remoteRenameTest)) { n in
            guard let u = n.userInfo, u["id"] as? String == id, u["place"] as? String == place else { return }
            switch u["do"] as? String {
            case "start": editing = true
            case "type": text = u["text"] as? String ?? ""
            case "return": finish()
            case "esc": cancel()
            default: break
            }
            DispatchQueue.main.async { emit(["event": "rename_field", "id": id, "place": place, "editing": editing, "text": text]) }
        }
        #else
        content
        #endif
    }
}

extension Notification.Name {
    /// tests: a row's name field (RenameTestHook)
    static let remoteRenameTest = Notification.Name("blurt.remote.rename_test")
}

enum RenameTests {
    /// `rename page|list ID start|type TEXT…|return|esc`
    static func post(_ a: [String]) {
        guard a.count >= 4 else { return }
        NotificationCenter.default.post(name: .remoteRenameTest, object: nil,
                                        userInfo: ["place": a[1], "id": a[2], "do": a[3], "text": a.dropFirst(4).joined(separator: " ")])
    }
}

/// VoiceOver's Rename action on a row whose name can be renamed.
struct RenameAction: ViewModifier {
    var rename: (() -> Void)?
    func body(content: Content) -> some View {
        if let rename { content.accessibilityAction(named: T("phone.rename.action"), rename) } else { content }
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
    /// the title is a paired device's name, renamed in place (RenamableName)
    var rename: Rename?
    @ViewBuilder var control: Control

    struct Rename {
        var id: String
        /// the device's own name: an empty field brings it back
        var own: String
        var editing: Binding<Bool>
        var commit: (String) -> Void
    }

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
                        if let r = rename {
                            RenamableName(id: r.id, shown: title, own: r.own, size: SettingsMetrics.titleSize, editing: r.editing, commit: r.commit)
                        } else {
                            Text(title).font(.system(size: SettingsMetrics.titleSize)).fixedSize(horizontal: false, vertical: true)
                                .foregroundStyle(quiet ? .secondary : .primary)
                        }
                        if let d = detail, !d.isEmpty {
                            HStack(alignment: .center, spacing: 5) {
                                if let t = detailTone { StatusDot(tone: t) }
                                Text(d).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    // while renamed, the field is its own element
                    .accessibilityElement(children: rename?.editing.wrappedValue == true ? .contain : .combine)
                    .accessibilityValue(spoken)
                    .modifier(RenameAction(rename: rename.map { r in { r.editing.wrappedValue = true } }))
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
