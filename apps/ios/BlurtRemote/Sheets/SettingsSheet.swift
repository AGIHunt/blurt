import BlurtRemoteKit
import GameController
import SwiftUI

struct SettingsSheet: View {
    let onDeck: (Deck) -> Void
    @ObservedObject private var p = Prefs.shared
    @ObservedObject private var l = Link.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = false
    @State private var details: PairedMac?
    @ObservedObject private var use = ScreenStream.shared.use

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(l.macs) { m in macRow(m) }
                    Button("Add Computer") { pairing = true }
                } header: { Text("Computers") } footer: {
                    if l.macs.count > 1 { Text("Tap a computer to switch to it. On the main screen, hold the settings button to switch without coming here.") }
                }
                Section {
                    Picker("Quality", selection: $p.quality) {
                        ForEach(ScreenQuality.allCases) { q in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(q.name)
                                Text(q.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                            .tag(q)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    if use.running {
                        LabeledContent("Now", value: "\(rate(use.kbps)) · \(use.fps) fps")
                        LabeledContent("Used Since Opening", value: size(use.total))
                    }
                } header: { Text(l.host == .mac ? "Mac Screen" : "Computer Screen") } footer: {
                    Text("A still screen uses no data. On a poor network the picture steps down by itself, and text sharpens as soon as it stops moving.")
                }
                Section {
                    Toggle("Touch Mode", isOn: $p.tapWhereTouched)
                } footer: {
                    Text(l.host == .mac ? "On the Mac’s screen, taps, scrolls and drags act where your fingers are. Off: at the pointer, as on a trackpad."
                        : "On the computer’s screen, taps, scrolls and drags act where your fingers are. Off: at the pointer, as on a trackpad.")
                }
                Section("Keys") {
                    NavigationLink("Edit Keys") { KeyEditor(deck: Deck.load(for: l.host), onChange: onDeck) }
                }
                if l.host != .mac, GCKeyboard.coalesced != nil {
                    Section {
                        Picker("⌘ on This Keyboard", selection: $p.hardwareCommand) {
                            Text(l.host.name(.control)).tag(CommandKeyRole.control)
                            Text(l.host.name(.command)).tag(CommandKeyRole.system)
                        }
                    } footer: { Text("Ctrl: ⌘C copies and ⌘V pastes, as on a Mac. Control is Ctrl too, Option is Alt.") }
                }
                Section("Trackpad") {
                    VStack(alignment: .leading) {
                        Text("Pointer Speed")
                        Slider(value: $p.pointerSpeed, in: 0.4...2.2)
                    }
                    VStack(alignment: .leading) {
                        Text("Scroll Speed")
                        Slider(value: $p.scrollSpeed, in: 0.2...2.2)
                    }
                    Toggle("Reverse Scrolling", isOn: $p.reverseScroll)
                    Toggle("Haptics", isOn: $p.haptics)
                }
                Section {
                    Toggle("Use iPhone Microphone", isOn: $p.micOnPhone)
                        .onChange(of: p.micOnPhone) { _, _ in Link.shared.send(.setMicOnPhone(MicStream.shared.usable)) }
                } header: { Text("Dictation") } footer: {
                    Text(l.host == .mac ? "Off: Blurt listens through your Mac’s microphone." : "Off: Blurt listens through your computer’s microphone.")
                }
                Section {
                    Toggle("Left-Handed", isOn: $p.lefty)
                } footer: { Text("Moves the talk key and the arrow key to the other side in portrait. In landscape, turn the phone round.") }
                Section("Gestures") {
                    row("Tap", "Click")
                    row("Tap, then drag", "Drag")
                    row("Touch and hold, then lift", "Right click")
                    row("Touch and hold, then drag", "Drag, select an area")
                    row("Tap, in Touch Mode", "Click right there")
                    row("One finger along the edge", "Scroll")
                    row("Two fingers", "Scroll at the pointer, tap to right click")
                    row("Two fingers, in Touch Mode", "Scroll under your fingers")
                    row("Pinch", "Zoom")
                    row("Pinch, with the screen showing", "Zoom the picture")
                    row("One finger, zoomed in, in Touch Mode", "Move the picture")
                    row("Pointer, zoomed in", "The picture follows it")
                    row("\(Words.cycleKeys(l.host)): hold and slide", "Step through, both ways")
                    row("Arrow key: tap an edge", "That arrow, hold to repeat")
                    row("Arrow key: drag", "Arrows, faster further out")
                    row("\(Words.modifiers(l.host)): tap", "Held for the next key, tap twice to lock")
                    row("\(Words.modifiers(l.host)): hold", "Pressed alone, e.g. \(l.host.name(.shift)) to switch input language")
                    row("Three fingers left, right", "Change desktop")
                    row("Three fingers up, down", "All windows, app windows")
                    row("Talk: tap", "Start, stop")
                    row("Talk: hold", "Talk while held")
                    row("Talk: double tap", "Send")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $pairing) { PairSheet() }
            .navigationDestination(item: $details) { m in MacDetail(mac: m) }
            .onAppear { l.watchNearby(true) }
            .onDisappear { l.watchNearby(false) }
        }
    }

    private func macRow(_ m: PairedMac) -> some View {
        HStack(spacing: 12) {
            Button {
                guard m.id != l.current?.id else { return }
                l.choose(m)
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(.tint).opacity(m.id == l.current?.id ? 1 : 0)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.title).foregroundStyle(.primary)
                        // with computers of more than one kind, each says which it is
                        Text(kinds ? "\(m.host.kindName) · \(String(localized: state(of: m)))" : String(localized: state(of: m))).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { details = m } label: { Image(systemName: "info.circle") }
                .buttonStyle(.plain).foregroundStyle(.tint)
                .accessibilityLabel(Text("Details"))
        }
    }

    private var kinds: Bool { Set(l.macs.map(\.host)).count > 1 }

    private func state(of m: PairedMac) -> String.LocalizationValue {
        if m.id == l.current?.id {
            switch l.state {
            case .connected: return l.route == .local ? "Connected" : l.route == .direct ? "Connected, direct" : "Connected through your relay"
            case .connecting: return "Connecting…"
            case .unreachable: return "Can’t reach it"
            case .forgotten: return "Needs pairing again"
            case .replaced: return "Another phone is using it"
            case .unpaired: return "Not connected"
            }
        }
        return l.nearby.contains(m.id) ? "On this network" : m.relayAddress != nil ? "Uses your relay" : "Not on this network"
    }

    private func rate(_ kbps: Int) -> String {
        kbps >= 1000 ? String(format: "%.1f Mbps", Double(kbps) / 1000) : "\(kbps) kbps"
    }

    private func size(_ b: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }

    private func row(_ a: LocalizedStringKey, _ b: LocalizedStringKey) -> some View {
        HStack {
            Text(a)
            Spacer()
            Text(b).foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}

/// One computer: what to call it, how it's reached, and how to drop it.
private struct MacDetail: View {
    let mac: PairedMac
    @ObservedObject private var l = Link.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var removing = false

    init(mac: PairedMac) {
        self.mac = mac
        _name = State(initialValue: mac.title)
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField(mac.name, text: $name)
                    .submitLabel(.done)
                    .onSubmit { l.rename(mac, to: name == mac.name ? "" : name) }
            }
            Section {
                LabeledContent("Relay", value: mac.relayAddress ?? String(localized: "None"))
            } footer: {
                if mac.host == .mac {
                    Text(mac.relayAddress == nil ? "Without a relay this Mac is reachable on its own network. Set one in Blurt’s Settings on the Mac." : "Set in Blurt’s Settings on the Mac. All your Macs can share one.")
                } else {
                    Text(mac.relayAddress == nil ? "Without a relay this computer is reachable on its own network. Set one in Blurt’s Settings on the computer." : "Set in Blurt’s Settings on the computer. All your computers can share one.")
                }
            }
            Section {
                Button(mac.host == .mac ? "Remove This Mac" : "Remove This Computer", role: .destructive) { removing = true }
            }
        }
        .navigationTitle(mac.title)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { l.rename(mac, to: name == mac.name ? "" : name) }
        .confirmationDialog("Remove \(mac.title)?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                l.forget(mac)
                dismiss()
            }
        } message: { Text("To use it again, scan its code again.") }
    }
}
