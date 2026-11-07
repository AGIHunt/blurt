import SwiftUI

struct SettingsSheet: View {
    let onDeck: (Deck) -> Void
    @ObservedObject private var p = Prefs.shared
    @ObservedObject private var l = Link.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = false
    @State private var editing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Keys") {
                    NavigationLink("Edit Keys") { KeyEditor(deck: Deck.load(), onChange: onDeck) }
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
                    Toggle("Tap Clicks Where You Touch", isOn: $p.tapWhereTouched)
                } header: { Text("Mac Screen") } footer: { Text("Off: taps click where the pointer is, as on a trackpad.") }
                Section {
                    Toggle("Use iPhone Microphone", isOn: $p.micOnPhone)
                        .onChange(of: p.micOnPhone) { _, on in Link.shared.send(.setMicOnPhone(on)) }
                } header: { Text("Dictation") } footer: { Text("Off: Blurt listens through your Mac’s microphone.") }
                Section {
                    Toggle("Left-Handed", isOn: $p.lefty)
                } footer: { Text("Moves the talk key to the other corner, and the keys to the right in landscape.") }
                Section("Macs") {
                    ForEach(l.macs) { m in
                        Button { l.choose(m); dismiss() } label: {
                            HStack {
                                Text(m.name).foregroundStyle(.primary)
                                Spacer()
                                if m.id == l.current?.id, l.state == .connected { Text("Connected").foregroundStyle(.secondary) }
                            }
                        }
                        .swipeActions { Button("Remove", role: .destructive) { l.forget(m) } }
                    }
                    Button("Add Mac") { pairing = true }
                }
                Section("Gestures") {
                    row("Tap", "Click")
                    row("Tap, then drag", "Drag")
                    row("Touch and hold, then lift", "Right click")
                    row("Touch and hold, then drag", "Drag, select an area")
                    row("Tap, with the screen showing", "Click right there")
                    row("One finger along the edge", "Scroll")
                    row("Two fingers", "Scroll, tap to right click")
                    row("Pinch", "Zoom")
                    row("Pinch, with the screen showing", "Zoom the picture")
                    row("Two fingers, zoomed in", "Move the picture")
                    row("Arrow key: tap an edge", "That arrow, hold to repeat")
                    row("Arrow key: drag", "Arrows, faster further out")
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
        }
    }

    private func row(_ a: LocalizedStringKey, _ b: LocalizedStringKey) -> some View {
        HStack {
            Text(a)
            Spacer()
            Text(b).foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}
