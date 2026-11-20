// 电脑 / Computers (docs/design/remote-desktop-viewer.md): the computers this Mac can drive, from the menu bar, and the same rows on the
// main window's 手机和电脑 page (本机可控制的电脑). Each row: the computer's name, its system, its state (已连接 · <path>, 可连接 · <path>, 离线 · <when>) and one button (打开窗口,
// 连接 or 移除). 添加电脑 / Add Computer: one found on this network, or a pairing link pasted from another network.
import AppKit
import BlurtRemoteKit
import SwiftUI

/// One computer's row: in the Computers window, and on the 手机和电脑 page in that page's grid (`.page`: the mark in the
/// 18 pt slot, Settings' type sizes, Connect / Open Window with Remove in the ⋯ menu beside it).
struct ComputerRow: View {
    enum Style { case list, page }
    var computer: RemoteComputer
    @ObservedObject var store = ViewerStore.shared
    var style = Style.list
    /// Add Again… (a computer that removed this Mac): the page opens its own sheet; the list window, the Computers window's
    var addAgain: (() -> Void)?
    @State private var removing = false

    var body: some View {
        let row = store.row(computer)
        Group {
            switch style {
            case .list: list(row)
            case .page: page(row)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { computer.removed == true ? add() : store.open(computer) }
        .contextMenu {
            if computer.removed == true { Button(T("viewer.add_again")) { add() } } else { Button(T("viewer.connect")) { store.open(computer) } }
            Button(T("phone.remove")) { removing = true }
        }
        .alert(T("settings.remote.remove.title", computer.name), isPresented: $removing) {
            Button(T("viewer.remove"), role: .destructive) { store.remove(computer) }
            Button(T("settings.remote.cancel"), role: .cancel) {}
        } message: {
            Text(T("viewer.remove.detail"))
        }
    }

    @ViewBuilder private func list(_ row: ViewerStore.Row) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ViewerStore.symbol(computer))
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(computer.name).font(.system(size: 13)).lineLimit(1)
                HStack(spacing: 5) {
                    StatusDot(tone: tone(row))
                    Text(ViewerStore.line(row)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            // the page's buttons, so the same rows look the same in both places
            actions(row).buttonStyle(SettingsOutlinedButtonStyle(compact: true))
        }
    }

    @ViewBuilder private func page(_ row: ViewerStore.Row) -> some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(alignment: .center, spacing: SettingsMetrics.iconGap) {
                Image(systemName: ViewerStore.symbol(computer)).font(.system(size: 14)).foregroundStyle(.secondary)
                    .frame(width: SettingsMetrics.iconSlot, height: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(computer.name).font(.system(size: SettingsMetrics.titleSize)).lineLimit(1)
                    HStack(alignment: .center, spacing: 5) {
                        StatusDot(tone: tone(row))
                        Text(ViewerStore.line(row)).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions(row).buttonStyle(SettingsOutlinedButtonStyle(compact: true))
        }
    }

    /// The row's one button and its ⋯ (here and in the window alike): Open Window while connected, Connect while it can
    /// be reached; offline (a guess from when it was last seen) shows no button — Connect is still there, in the ⋯ with
    /// Remove…, for when the public connection service or the relay reaches it anyway.
    @ViewBuilder private func actions(_ row: ViewerStore.Row) -> some View {
        HStack(spacing: 6) {
            switch row {
            case .connected: Button(T("viewer.open")) { store.open(computer) }
            case .available, .noDirect, .relayDown: Button(T("viewer.connect")) { store.open(computer) }
            case .offline, .asleep: EmptyView()
            // its key is gone (or refused): it has to be added again; Connect stays in the ⋯ while the key is here
            case .removed: Button(T("viewer.add_again")) { add() }
            }
            RowMenu(label: T("viewer.more"), visible: true) {
                if row.isOffline || row == .removed && computer.removed != true { Button(T("viewer.connect")) { store.open(computer) } }
                Button(T("phone.remove")) { removing = true }
            }
        }
    }

    private func add() { if let addAgain { addAgain() } else { store.requestAdd() } }

    private func tone(_ r: ViewerStore.Row) -> Tone {
        switch r {
        case .connected: .good
        case .available: .ready
        case .noDirect, .relayDown, .removed: .warn
        case .offline, .asleep: .off
        }
    }
}

/// The Add Computer sheet: nearby computers to pair with, a pairing link, and the six digits while the other computer asks its owner.
struct AddComputerView: View {
    @ObservedObject var store = ViewerStore.shared
    var done: () -> Void
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(T("viewer.add.title")).font(.system(size: 15, weight: .semibold))
            if let p = store.pairing {
                pairing(p)
            } else {
                Text(T("viewer.add.nearby")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    if store.unpaired.isEmpty {
                        HStack(spacing: 8) {
                            BrandSpinnerView(size: 14)
                            Text(T("viewer.add.looking")).font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(12)
                    }
                    ForEach(store.unpaired) { n in
                        HStack(spacing: 10) {
                            Image(systemName: "desktopcomputer").foregroundStyle(.secondary).frame(width: 24)
                            Text(n.name).font(.system(size: 13)).lineLimit(1)
                            Spacer()
                            Button(T("viewer.connect")) { store.pair(n) }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        if n.id != store.unpaired.last?.id { Divider().padding(.leading, 46) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                Text(T("viewer.add.nearby.detail")).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(T("viewer.add.link")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.top, 4)
                HStack(spacing: 8) {
                    TextField("blurtremote://pair?…", text: $store.linkText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(useLink)
                        .onChange(of: store.linkText) { _ in invalid = false }
                    Button(T("viewer.connect"), action: useLink).disabled(store.linkText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(invalid ? T("viewer.add.invalid") : T("viewer.add.link.detail")).font(.system(size: 11.5))
                    .foregroundStyle(invalid ? Color.brandAttnInk : .secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(T("settings.remote.cancel")) { done() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { store.watch("add") }
        .onDisappear { store.unwatch("add") }
    }

    private func useLink() {
        if !store.pair(link: store.linkText) { invalid = true }
    }

    @ViewBuilder private func pairing(_ p: ViewerStore.Pairing) -> some View {
        if let f = p.failed {
            // what went wrong, then what to do; never a dead end: Try Again where the same link can still work, else Back to the
            // link field (the link still in it) for a new one
            VStack(alignment: .leading, spacing: 4) {
                Text(f).font(.system(size: 13)).foregroundStyle(Color.brandAttnInk).fixedSize(horizontal: false, vertical: true)
                if let h = p.help {
                    Text(h).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                if p.canRetry { Button(T("viewer.add.back")) { store.backFromPairing() } }
                Spacer()
                Button(T("settings.remote.cancel")) { done() }.keyboardShortcut(.cancelAction)
                if p.canRetry {
                    Button(T("viewer.retry")) { store.retryPairing() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(T("viewer.add.back")) { store.backFromPairing() }.keyboardShortcut(.defaultAction)
                }
            }
        } else if let c = p.check, !c.isEmpty {
            Text(T("viewer.add.check", p.name)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Text(c.map(String.init).joined(separator: " "))
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .accessibilityLabel(c)
            HStack {
                Spacer()
                Button(T("settings.remote.cancel")) { done() }.keyboardShortcut(.cancelAction)
            }
        } else {
            HStack(spacing: 8) {
                BrandSpinnerView(size: 14)
                Text(T("viewer.add.connecting", p.name)).font(.system(size: 13))
            }
            HStack {
                Spacer()
                Button(T("settings.remote.cancel")) { done() }.keyboardShortcut(.cancelAction)
            }
        }
    }
}

/// The list, in its own window from the menu bar.
struct ComputersView: View {
    @ObservedObject var store = ViewerStore.shared
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            if store.computers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "desktopcomputer").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text(T("viewer.empty")).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.computers) { c in
                            ComputerRow(computer: c).padding(.horizontal, 16).padding(.vertical, 10)
                            if c.id != store.computers.last?.id { Divider().padding(.leading, 58) }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button(T("viewer.add")) { adding = true }.buttonStyle(SettingsOutlinedButtonStyle(compact: true))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)     // the rows' trailing edge
        }
        .frame(minWidth: 420, minHeight: 280)
        .sheet(isPresented: Binding(get: { adding || store.pairing != nil }, set: { if !$0 { adding = false; store.cancelPairing() } })) {
            AddComputerView { adding = false; store.cancelPairing() }
        }
        // a pairing begun from elsewhere (a test, a link) holds the sheet open as one begun here does, so Back keeps it
        .onChange(of: store.pairing == nil) { none in if !none { adding = true } }
        // paired: its window opens, the sheet's job is done
        .onChange(of: store.pairedCount) { _ in adding = false }
        .onAppear { store.watch("list") }
        .onDisappear { store.unwatch("list") }
        .onReceive(NotificationCenter.default.publisher(for: .viewerAdd)) { _ in adding = true }
    }
}

final class ComputersWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ComputersWindowController()

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = T("viewer.title")
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: ComputersView())
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
