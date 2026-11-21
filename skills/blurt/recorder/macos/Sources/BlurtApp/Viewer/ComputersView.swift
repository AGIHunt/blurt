// 电脑 / Computers (docs/design/remote-desktop-viewer.md): the computers this Mac can drive, from the menu bar, and the same rows on the
// main window's Remote Control page. Each row: the computer's system as its glyph, its name, its state (已连接 · <path>, 可连接 · <path>,
// 需要自建中转, 离线 · <when>) and at most one button (打开窗口, 连接, 重试 or 重新添加…), with ⋯ on hover (重命名…, 移除…).
// 添加电脑 / Add Computer: one found on this network, or a pairing link pasted from another network.
import AppKit
import BlurtRemoteKit
import SwiftUI

/// The Computers window's grid (System Settings' grouped list): the card's inset, the glyph slot, the text column after it.
enum ComputersMetrics {
    static let inset: CGFloat = 16          // the card from the window's edges
    static let rowInset: CGFloat = 12       // a row's content from the card's edges
    static let iconSlot: CGFloat = 24
    static let iconGap: CGFloat = 10
    /// the text column, where the hairlines between rows start
    static var textColumn: CGFloat { rowInset + iconSlot + iconGap }
    static let rowPadding: CGFloat = 9
    /// rows shown before the card scrolls
    static let visibleRows = 7
    static let rowHeight: CGFloat = 51
    static let radius: CGFloat = 10
}

/// One computer's row: in the Computers window, and on the Remote Control page in that page's grid (`.page`: the mark in the
/// 18 pt slot, Settings' type sizes). The same trailing column in both: the row's one button in a slot as wide as the widest
/// row button, then ⋯ on hover (its items are the context menu's too).
struct ComputerRow: View {
    enum Style { case list, page }
    var computer: RemoteComputer
    @ObservedObject var store = ViewerStore.shared
    var style = Style.list
    /// Add Again… (a computer that removed this Mac): the page opens its own sheet; the list window, the Computers window's
    var addAgain: (() -> Void)?
    @State private var removing = false
    @State private var hovering = false
    /// its name is a field (RenamableName)
    @State private var renaming = false

    var body: some View {
        let row = store.row(computer)
        Group {
            switch style {
            case .list: list(row)
            case .page: page(row)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            guard !renaming else { return }
            computer.removed == true ? add() : store.open(computer)
        }
        .contextMenu { menuItems(row) }
        .alert(T("settings.remote.remove.title", computer.shownName), isPresented: $removing) {
            Button(T("viewer.remove"), role: .destructive) { store.remove(computer) }
            Button(T("settings.remote.cancel"), role: .cancel) {}
        } message: {
            Text(T("viewer.remove.detail"))
        }
    }

    @ViewBuilder private func list(_ row: ViewerStore.Row) -> some View {
        HStack(spacing: ComputersMetrics.iconGap) {
            Image(systemName: ViewerStore.symbol(computer))
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: ComputersMetrics.iconSlot)
                .help(ViewerStore.system(computer))
                .accessibilityHidden(true)
            text(row, title: 13, detail: SettingsMetrics.detailSize)
            trailing(row)
        }
    }

    @ViewBuilder private func page(_ row: ViewerStore.Row) -> some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(alignment: .center, spacing: SettingsMetrics.iconGap) {
                Image(systemName: ViewerStore.symbol(computer)).font(.system(size: 14)).foregroundStyle(.secondary)
                    .frame(width: SettingsMetrics.iconSlot, height: 18)
                    .help(ViewerStore.system(computer))
                    .accessibilityHidden(true)
                text(row, title: SettingsMetrics.titleSize, detail: SettingsMetrics.detailSize)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing(row)
        }
    }

    /// The name over its state line. One element for VoiceOver with the whole text column as its frame (a combined one is only
    /// as wide as its widest line, and its joined words measured against that read as cut off), its words said once.
    private func text(_ row: ViewerStore.Row, title: CGFloat, detail: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // the page: a double-click on the name renames it (elsewhere on the row it opens); the Computers window opens it on a
            // double-click anywhere, as Finder opens what's double-clicked, and renames it from the ⋯ or the context menu
            RenamableName(id: computer.id, place: style == .page ? "page" : "list", shown: computer.shownName, own: computer.name, size: title,
                          doubleClick: style == .page, editing: $renaming) {
                store.rename(computer, to: $0)
            }
            HStack(alignment: .center, spacing: 5) {
                StatusDot(tone: tone(row))
                Text(ViewerStore.line(row)).font(.system(size: detail)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // while renamed, the field is its own element
        .accessibilityElement(children: renaming ? .contain : .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(ViewerStore.spoken(computer, row))
        .accessibilityAction(named: T("phone.rename.action")) { renaming = true }
        .modifier(Tooltip(text: ViewerStore.explain(computer, row)))
    }

    /// Open Window while connected, Connect while it can be reached, Try Again where the last try found no way through (the
    /// state line's tooltip says why), Add Again… once it removed this Mac; offline (a guess from when it was last seen) shows
    /// no button — Connect is still there, in the ⋯ with Remove…, for when the public connection service or the relay reaches
    /// it anyway.
    private func trailing(_ row: ViewerStore.Row) -> some View {
        HStack(spacing: 4) {
            ZStack(alignment: .trailing) {
                // the slot: as wide as the widest row button in this language, so every row's button has the same edges
                RowButtonLabel(title: T("viewer.open")).look.hidden().accessibilityHidden(true)
                slot(row)
            }
            RowMenu(label: T("viewer.more"), visible: hovering) { menuItems(row) }
        }
    }

    @ViewBuilder private func slot(_ row: ViewerStore.Row) -> some View {
        switch row {
        case .connected: RowButton(title: T("viewer.open")) { store.open(computer) }
        case .available, .relayDown: RowButton(title: T("viewer.connect")) { store.open(computer) }
        case .noDirect: RowButton(title: T("viewer.retry")) { store.open(computer) }
        case .offline, .asleep: EmptyView()
        // its key is gone (or refused): it has to be added again; Connect stays in the ⋯ while the key is here
        case .removed: RowButton(title: T("viewer.add_again")) { add() }
        }
    }

    /// The ⋯ and the context menu: the row's action, Rename…, then Remove….
    @ViewBuilder private func menuItems(_ row: ViewerStore.Row) -> some View {
        if computer.removed == true {
            Button(T("viewer.add_again")) { add() }
        } else {
            switch row {
            case .connected: Button(T("viewer.open")) { store.open(computer) }
            case .noDirect: Button(T("viewer.retry")) { store.open(computer) }
            default: Button(T("viewer.connect")) { store.open(computer) }
            }
        }
        Button(T("phone.rename")) { renaming = true }
        Divider()
        Button(T("phone.remove")) { removing = true }
    }

    private func add() { if let addAgain { addAgain() } else { store.requestAdd() } }

    private func tone(_ r: ViewerStore.Row) -> Tone {
        switch r {
        case .connected: .good
        case .available: .ready
        // needs you: a relay to set up on the other computer, the relay's address to check, the computer to add again
        case .noDirect, .relayDown, .removed: .warn
        case .offline, .asleep: .off
        }
    }
}

/// A row button's label, as wide as the widest row label in this language, so the buttons down a list share both edges.
private struct RowButtonLabel: View {
    var title: String
    var body: some View {
        ZStack {
            ForEach([T("viewer.open"), T("viewer.connect"), T("viewer.retry"), T("viewer.add_again")], id: \.self) { Text($0).hidden() }
            Text(title)
        }
    }
    /// the slot's width: the button drawn with this label
    var look: some View {
        Button {} label: { self }.buttonStyle(SettingsOutlinedButtonStyle(compact: true))
    }
}

private struct RowButton: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { RowButtonLabel(title: title) }
            .buttonStyle(SettingsOutlinedButtonStyle(compact: true))
            .accessibilityLabel(title)
    }
}

/// A tooltip only where there is something more to say (an empty `.help` still counts as one to VoiceOver and the layout check).
struct Tooltip: ViewModifier {
    var text: String?
    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}

/// The Add Computer sheet: the computers found on this network (each with its Connect), a pairing link for another network with
/// the footer's default Connect, then one centred card while it pairs (system.md §3.3) — connecting, the six digits, or what went
/// wrong — that keeps one width, glyph and height from step to step.
struct AddComputerView: View {
    @ObservedObject var store = ViewerStore.shared
    var done: () -> Void
    @State private var invalid = false
    @FocusState private var linkFocused: Bool

    /// One width for every step, narrower than the Computers window's minimum (`ComputersView`), so the sheet always sits inside it.
    static let width: CGFloat = 400
    private static let glyph: CGFloat = 18, gap: CGFloat = 10, rowInset: CGFloat = 12
    private static var textColumn: CGFloat { rowInset + glyph + gap }

    var body: some View {
        Group {
            if let p = store.pairing { pairing(p) } else { add }
        }
        .padding(20)
        .frame(width: Self.width)
        .onAppear {
            store.watch("add")
            // the list is what most people came for: the empty field takes no focus (its ring would be the loudest thing on show)
            DispatchQueue.main.async { linkFocused = false }
        }
        .onDisappear { store.unwatch("add") }
    }

    private var box: RoundedRectangle { RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous) }

    @ViewBuilder private var add: some View {
        let list = store.unpaired
        VStack(alignment: .leading, spacing: 0) {
            Text(T("viewer.add.title")).font(.system(size: 15, weight: .semibold))
            heading(T("viewer.add.nearby")).padding(.top, 16)
            VStack(spacing: 0) {
                ForEach(list) { n in
                    HStack(spacing: Self.gap) {
                        Image(systemName: "display").font(.system(size: 14)).foregroundStyle(.secondary)
                            .frame(width: Self.glyph).accessibilityHidden(true)
                        Text(n.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button(T("viewer.connect")) { store.pair(n) }.buttonStyle(SettingsOutlinedButtonStyle(compact: true))
                    }
                    .padding(.horizontal, Self.rowInset)
                    .padding(.vertical, 7)
                    Divider().padding(.leading, Self.textColumn)
                }
                // the search goes on while the sheet is open: one quiet row says so, under the computers found
                HStack(spacing: Self.gap) {
                    BrandSpinnerView(size: 12).frame(width: Self.glyph, height: 12)
                    Text(T(list.isEmpty ? "viewer.add.looking" : "viewer.add.looking_more")).font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Self.rowInset)
                .padding(.vertical, list.isEmpty ? 14 : 9)
                .accessibilityElement(children: .combine)
            }
            .background(box.fill(Color.primary.opacity(0.035)))
            .overlay(box.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            caption(T(list.isEmpty ? "viewer.add.nearby.empty" : "viewer.add.nearby.missing"))
            heading(T("viewer.add.link")).padding(.top, 20)
            TextField(T("viewer.add.link.placeholder"), text: $store.linkText)
                .textFieldStyle(.roundedBorder)
                .focused($linkFocused)
                .onSubmit(useLink)
                .onChange(of: store.linkText) { _ in invalid = false }
                .accessibilityLabel(T("viewer.add.link"))
            caption(invalid ? T("viewer.add.invalid") : T("viewer.add.link.detail"), attention: invalid)
            HStack(spacing: 8) {
                Spacer()
                Button(T("settings.remote.cancel")) { done() }.keyboardShortcut(.cancelAction)
                // the link's Connect, the sheet's one default (a computer found nearby has its own in its row)
                Button(T("viewer.connect"), action: useLink).keyboardShortcut(.defaultAction)
                    .disabled(store.linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 20)
        }
    }

    private func heading(_ s: String) -> some View {
        Text(s).font(.system(size: 13, weight: .semibold)).padding(.bottom, 6).accessibilityAddTraits(.isHeader)
    }

    private func caption(_ s: String, attention: Bool = false) -> some View {
        Text(s).font(.system(size: 11.5)).foregroundStyle(attention ? Color.brandAttnInk : .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
    }

    private func useLink() {
        if !store.pair(link: store.linkText) { invalid = true }
    }

    /// The pairing card, centred like macOS's Bluetooth pairing request: a computer's glyph, what this step asks, then the step
    /// itself (connecting; the six digits and what to do on the other computer; or what went wrong and what to do next), and the
    /// buttons at the trailing edge. Never a dead end: Try Again where the same link or nearby computer can still work, else Back
    /// to the link field with the link still in it.
    @ViewBuilder private func pairing(_ p: ViewerStore.Pairing) -> some View {
        let check = p.failed == nil ? p.check.flatMap { $0.isEmpty ? nil : $0 } : nil
        VStack(spacing: 0) {
            Image(systemName: "display")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(height: 44)
                .accessibilityHidden(true)
            Text(p.failed != nil ? T("viewer.add.failed.title", p.name) : check != nil ? T("viewer.add.check.title", p.name) : T("viewer.add.to", p.name))
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .accessibilityAddTraits(.isHeader)
            // every step takes at least the digits' room, so the card keeps its height from step to step
            ZStack {
                Self.codeStep("000000") { Text(verbatim: " ").font(.system(size: 12)) }.hidden().accessibilityHidden(true)
                if let f = p.failed {
                    VStack(spacing: 6) {
                        Text(f).font(.system(size: 13))
                        if let h = p.help { Text(h).font(.system(size: 12)).foregroundStyle(.secondary) }
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                } else if let c = check {
                    Self.codeStep(c) {
                        HStack(alignment: .center, spacing: 6) {
                            BrandSpinnerView(size: 12, label: T("viewer.add.waiting", p.name)).frame(width: 12, height: 12)
                            Text(T("viewer.add.check", p.name)).font(.system(size: 12)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    VStack(spacing: 10) {
                        BrandSpinnerView(size: 16).frame(width: 16, height: 16)
                        Text(T("viewer.add.connecting", p.name)).font(.system(size: 13)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
            HStack(spacing: 8) {
                if p.failed != nil, p.canRetry { Button(T("viewer.add.back")) { store.backFromPairing() } }
                Spacer()
                Button(T("settings.remote.cancel")) { done() }.keyboardShortcut(.cancelAction)
                if p.failed != nil {
                    if p.canRetry {
                        Button(T("viewer.retry")) { store.retryPairing() }.keyboardShortcut(.defaultAction)
                    } else {
                        Button(T("viewer.add.back")) { store.backFromPairing() }.keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(.top, 20)
        }
        .frame(maxWidth: .infinity)
    }

    /// The six digits in a quiet well (ink 5 %, r 10), grouped 3 + 3 as Apple shows a pairing code, in the UI face's tabular digits
    /// (system.md §7: one family, never a mono face), over one status line.
    private static func codeStep<S: View>(_ c: String, @ViewBuilder status: () -> S) -> some View {
        let groups = c.count == 6 ? [String(c.prefix(3)), String(c.suffix(3))] : [c]
        return VStack(spacing: 12) {
            HStack(spacing: 20) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                    // tracking leaves room after the last digit too: the same before the first keeps the group centred
                    Text(verbatim: g).font(.system(size: 40, weight: .semibold).monospacedDigit()).tracking(2).padding(.leading, 2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            .accessibilityElement(children: .ignore)
            // read digit by digit, in its two groups ("4 8 2, 7 1 3"), never as one number
            .accessibilityLabel(Text(verbatim: groups.map { $0.map(String.init).joined(separator: " ") }.joined(separator: ", ")))
            status()
        }
    }
}

/// The list, in its own window from the menu bar: the rows in one rounded card on the window's ground (System Settings'
/// grouped list), Add Computer… as the card's last line, the window as tall as its rows (it scrolls past seven).
struct ComputersView: View {
    @ObservedObject var store = ViewerStore.shared
    @State private var adding = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    /// the Add Computer sheet's height, as last measured
    @State private var sheetHeight: CGFloat = 340

    private var sheetShown: Bool { adding || store.pairing != nil }

    private struct SheetHeight: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.computers.isEmpty { empty } else { card }
        }
        .padding(ComputersMetrics.inset)
        // wider than the Add Computer sheet (AddComputerView.width) with 30 pt on each side, so the sheet always sits inside it
        .frame(minWidth: AddComputerView.width + 60, idealWidth: 480, maxWidth: 640, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        // while Add Computer shows, the window is at least the sheet's height, so the sheet never hangs below it
        .frame(minHeight: sheetShown ? sheetHeight + 8 : nil, alignment: .top)
        .sheet(isPresented: Binding(get: { sheetShown }, set: { if !$0 { adding = false; store.cancelPairing() } })) {
            AddComputerView { adding = false; store.cancelPairing() }
                .background(GeometryReader { g in Color.clear.preference(key: SheetHeight.self, value: g.size.height) })
                .onPreferenceChange(SheetHeight.self) { h in if h > 0 { sheetHeight = h } }
        }
        // a pairing begun from elsewhere (a test, a link) holds the sheet open as one begun here does, so Back keeps it
        .onChange(of: store.pairing == nil) { none in if !none { adding = true } }
        // paired: its window opens, the sheet's job is done
        .onChange(of: store.pairedCount) { _ in adding = false }
        .onAppear { store.watch("list") }
        .onDisappear { store.unwatch("list") }
        .onReceive(NotificationCenter.default.publisher(for: .viewerAdd)) { _ in adding = true }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: ComputersMetrics.radius, style: .continuous) }
    private var cardFill: Color { scheme == .dark ? Color.white.opacity(0.05) : Color(nsColor: .controlBackgroundColor) }
    private var cardLine: Color { Color.primary.opacity(scheme == .dark ? 0.1 : 0.08) }

    @ViewBuilder private var card: some View {
        let list = store.computers
        let rows = VStack(spacing: 0) {
            ForEach(list) { c in
                ComputerRow(computer: c)
                    .padding(.horizontal, ComputersMetrics.rowInset).padding(.vertical, ComputersMetrics.rowPadding)
                    .overlay(alignment: .bottom) { hairline }
            }
            addLine
        }
        Group {
            if list.count > ComputersMetrics.visibleRows {
                ScrollView { rows }.frame(height: CGFloat(ComputersMetrics.visibleRows) * ComputersMetrics.rowHeight + 34)
            } else {
                rows
            }
        }
        .background(shape.fill(cardFill))
        .overlay(shape.strokeBorder(cardLine, lineWidth: 1))
        .clipShape(shape)
    }

    private var hairline: some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1 / max(displayScale, 1))
            .padding(.leading, ComputersMetrics.textColumn)
            .allowsHitTesting(false)
    }

    /// The card's last line (Login Items' "+", in words): a "+" in the glyphs' slot, the words on the text column, in brand ink.
    private var addLine: some View {
        Button { adding = true } label: {
            HStack(spacing: ComputersMetrics.iconGap) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: ComputersMetrics.iconSlot)
                Text(T("viewer.add")).font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.brandInk)
            .padding(.horizontal, ComputersMetrics.rowInset).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(T("viewer.add"))
    }

    /// None yet: what this window is for, and the one thing to do.
    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer").font(.system(size: 30)).foregroundStyle(.tertiary).accessibilityHidden(true)
            Text(T("viewer.empty")).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(T("viewer.add")) { adding = true }.keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24).padding(.vertical, 32)
        .frame(maxWidth: .infinity)
        .background(shape.fill(cardFill))
        .overlay(shape.strokeBorder(cardLine, lineWidth: 1))
    }
}

final class ComputersWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ComputersWindowController()

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = T("viewer.title")
        w.isReleasedWhenClosed = false
        // the card is the only edge under the title: no full-width line there
        w.titlebarSeparatorStyle = .none
        // as tall as the list: the view's height is the window's (only the width is the user's, 460–640)
        let host = NSHostingController(rootView: ComputersView())
        host.sizingOptions = [.minSize, .maxSize, .preferredContentSize]
        w.contentViewController = host
        w.setFrameAutosaveName("BlurtComputers")
        super.init(window: w)
        w.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.title = T("viewer.title")
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension ViewerStore.Row {
    var isOffline: Bool {
        switch self {
        case .offline, .asleep: true
        default: false
        }
    }
}
