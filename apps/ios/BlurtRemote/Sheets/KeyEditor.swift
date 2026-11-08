// Editing the keys: the list as it is, with the dock on top. Hold a key and drag it: the others make way as it passes, so what will
// happen shows before it's let go. Tap one to change what it shows or what it does, the minus to remove it, the plus to add one. No file
// to write, no helper to run on the Mac. A key is an action from the list, a shortcut made here, or text to type.
import BlurtRemoteKit
import SwiftUI
import UniformTypeIdentifiers

struct KeyEditor: View {
    @State var deck: Deck
    let onChange: (Deck) -> Void
    @State private var editing: KeySlot.ID?
    @State private var adding: AddTo?
    @State private var renaming: Int?
    @State private var name = ""
    @State private var dragging: KeySlot.ID?
    @State private var bumps = 0

    private struct AddTo: Identifiable { let section: Int; var id: Int { section } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Hold and drag a key to move it. Tap one to change it.").font(.footnote).foregroundStyle(.secondary)
                heading("Always Here")
                Text("With the keys put away in landscape, esc, return and space stay, or the keys in their places.").font(.footnote).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 5) {
                    ForEach(deck.dock) { tile($0, removable: false) }
                    Image(systemName: "mic.fill").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.06)))
                }
                ForEach(deck.sections.indices, id: \.self) { n in
                    HStack {
                        heading(deck.sections[n].name)
                        Spacer()
                        Menu {
                            Button("Rename") { name = deck.sections[n].name; renaming = n }
                            Button("Add Section") { addSection(after: n) }.disabled(deck.sections.count >= Deck.maxSections)
                            Button("Delete Section", role: .destructive) { update { $0.sections.remove(at: n) } }.disabled(deck.sections.count <= 1)
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 28) }
                        .accessibilityLabel("More")
                    }
                    LazyVGrid(columns: columns, spacing: 5) {
                        ForEach(deck.sections[n].slots) { tile($0, removable: true) }
                        Button { adding = AddTo(section: n) } label: {
                            Image(systemName: "plus").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 44)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(white: 0.2)))
                        }
                        .accessibilityLabel("Add Key")
                        .onDrop(of: [.text], delegate: EndOfSection(dragging: $dragging, enter: { moveToEnd(section: n) }, done: finished))
                    }
                }
            }
            .padding(16)
            .animation(.snappy(duration: 0.22), value: deck)
        }
        // let go anywhere else: it stays where it had got to
        .onDrop(of: [.text], isTargeted: nil) { _ in finished(); return true }
        .sensoryFeedback(.selection, trigger: bumps)
        .navigationTitle("Edit Keys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Restore Default Keys", role: .destructive) { update { $0 = .standard } }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("More")
            }
        }
        .sheet(item: Binding(get: { editing.map(Editing.init) }, set: { editing = $0?.id })) { e in
            NavigationStack {
                KeyFaceEditor(slot: slot(e.id) ?? KeySlot(.text("", enter: false)), removable: isInList(e.id)) { new in
                    update { $0.replace(e.id, with: new) }
                } onRemove: {
                    update { $0.remove(e.id) }
                    editing = nil
                }
            }
        }
        .sheet(item: $adding) { a in
            NavigationStack {
                KeyPicker { s in
                    update { $0.sections[a.section].slots.append(s) }
                    adding = nil
                }
            }
        }
        .alert("Section Name", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("OK") { if let n = renaming { update { $0.sections[n].name = name } } }
        }
        .onDisappear { onChange(deck) }
    }

    private struct Editing: Identifiable { let id: KeySlot.ID }

    private func slot(_ id: KeySlot.ID) -> KeySlot? { deck.dock.first { $0.id == id } ?? deck.sections.lazy.flatMap(\.slots).first { $0.id == id } }
    private func isInList(_ id: KeySlot.ID) -> Bool { !deck.dock.contains { $0.id == id } }

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 5), count: Deck.columns) }

    private func heading(_ t: String) -> some View {
        Text(LocalizedStringKey(t)).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
    }

    private func tile(_ s: KeySlot, removable: Bool) -> some View {
        face(s, removable: removable)
            .opacity(dragging == s.id ? 0.25 : 1)
            .scaleEffect(dragging == s.id ? 0.92 : 1)
            .onTapGesture { editing = s.id }
            .draggable(s.id.uuidString) {
                face(s, removable: false).frame(width: 50, height: 46).onAppear { dragging = s.id }
            }
            .onDrop(of: [.text], delegate: OverKey(target: s.id, dragging: $dragging, enter: { from in move(from, to: s.id) }, done: finished))
    }

    private func face(_ s: KeySlot, removable: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 2) {
                KeyFaceView(face: s.face)
                if let c = s.detail { Text(c).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7) }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.13)))
            if removable {
                Button { update { $0.remove(s.id) } } label: {
                    Image(systemName: "minus.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, Color(white: 0.3))
                }
                .accessibilityLabel("Remove")
                .font(.system(size: 10))
                .offset(x: 3, y: -3)
            }
        }
    }

    /// As it passes over a key the others make way. Into or out of the dock it's a swap: the dock always has its keys.
    private func move(_ from: KeySlot.ID, to: KeySlot.ID) {
        guard from != to else { return }
        deck.move(from, onto: to)
        bumps += 1
    }

    private func moveToEnd(section m: Int) {
        guard let from = dragging, deck.sections.indices.contains(m), isInList(from) else { return }
        guard deck.sections[m].slots.last?.id != from, let s = slot(from) else { return }
        deck.remove(from)
        deck.sections[m].slots.append(s)
        bumps += 1
    }

    private func finished() {
        dragging = nil
        onChange(deck)
    }

    private func update(_ f: (inout Deck) -> Void) {
        f(&deck)
        onChange(deck)
    }

    private func addSection(after n: Int) {
        update { $0.sections.insert(KeySection(String(localized: "New Section"), []), at: n + 1) }
        name = String(localized: "New Section")
        renaming = n + 1
    }
}

private struct OverKey: DropDelegate {
    let target: KeySlot.ID
    @Binding var dragging: KeySlot.ID?
    let enter: (KeySlot.ID) -> Void
    let done: () -> Void

    func dropEntered(info: DropInfo) { if let d = dragging, d != target { enter(d) } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { done(); return true }
}

private struct EndOfSection: DropDelegate {
    @Binding var dragging: KeySlot.ID?
    let enter: () -> Void
    let done: () -> Void

    func dropEntered(info: DropInfo) { enter() }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { done(); return true }
}

extension Deck {
    mutating func replace(_ id: KeySlot.ID, with s: KeySlot) {
        if let i = dock.firstIndex(where: { $0.id == id }) { dock[i] = s; return }
        for n in sections.indices { if let i = sections[n].slots.firstIndex(where: { $0.id == id }) { sections[n].slots[i] = s; return } }
    }

    mutating func remove(_ id: KeySlot.ID) {
        for n in sections.indices { sections[n].slots.removeAll { $0.id == id } }
    }

    private func place(_ id: KeySlot.ID) -> (section: Int?, index: Int)? {
        if let i = dock.firstIndex(where: { $0.id == id }) { return (nil, i) }
        for n in sections.indices { if let i = sections[n].slots.firstIndex(where: { $0.id == id }) { return (n, i) } }
        return nil
    }

    /// Takes `to`'s place, the rest making room; with the dock in it, the two change places.
    mutating func move(_ from: KeySlot.ID, onto to: KeySlot.ID) {
        guard let a = place(from), let b = place(to) else { return }
        switch (a.section, b.section) {
        case (nil, nil): dock.swapAt(a.index, b.index)
        case let (nil, n?): swap(&dock[a.index], &sections[n].slots[b.index])
        case let (n?, nil): swap(&sections[n].slots[a.index], &dock[b.index])
        case let (n?, m?):
            let s = sections[n].slots.remove(at: a.index)
            sections[m].slots.insert(s, at: min(b.index, sections[m].slots.count))
        }
    }
}

/// What a key shows, and what it does. An icon says the most in the room there is; any text or emoji will do, and the longer it is the
/// smaller it reads.
struct KeyFaceEditor: View {
    @State var slot: KeySlot
    let removable: Bool
    let onChange: (KeySlot) -> Void
    let onRemove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var small: String

    init(slot: KeySlot, removable: Bool, onChange: @escaping (KeySlot) -> Void, onRemove: @escaping () -> Void) {
        _slot = State(initialValue: slot)
        _text = State(initialValue: slot.glyph.flatMap { $0.hasPrefix("sf:") || $0.hasPrefix("mark:") ? nil : $0 } ?? "")
        _small = State(initialValue: slot.caption ?? "")
        self.removable = removable
        self.onChange = onChange
        self.onRemove = onRemove
    }

    private func save() { onChange(slot) }

    var body: some View {
        Form {
            Section {
                HStack { Spacer(); preview; Spacer() }
            }
            Section {
                TextField("Text or emoji", text: $text)
                    .onChange(of: text) { _, t in
                        slot.glyph = t.isEmpty ? (slot.face.hasPrefix("sf:") || slot.face.hasPrefix("mark:") ? slot.glyph : nil) : t
                        save()
                    }
                TextField("Small line", text: $small, prompt: Text(slot.caption == nil ? (slot.detail ?? "") : ""))
                    .onChange(of: small) { _, t in
                        slot.caption = t.isEmpty ? nil : t
                        save()
                    }
            } header: { Text("On the Key") } footer: { Text("The longer it is, the smaller it shows.") }
            Section("Icon") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 12) {
                    ForEach(Deck.icons, id: \.self) { n in
                        Button {
                            text = ""
                            slot.glyph = "sf:\(n)"
                            save()
                        } label: {
                            Image(systemName: n).frame(width: 34, height: 30).foregroundStyle(slot.glyph == "sf:\(n)" ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section {
                NavigationLink("Change What It Does") {
                    KeyPicker { s in
                        slot.action = s.action
                        if slot.glyph == nil, text.isEmpty { slot.glyph = s.glyph }
                        slot.hint = s.hint
                        save()
                        dismiss()
                    }
                }
                if removable { Button("Remove", role: .destructive) { onRemove() } }
            }
        }
        .navigationTitle(slot.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private var preview: some View {
        VStack(spacing: 2) {
            KeyFaceView(face: slot.face, font: .title3)
            if let c = slot.detail { Text(c).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(width: 64, height: 56)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.16)))
    }
}

/// Everything a key can be: search the list, or make one.
struct KeyPicker: View {
    let onPick: (KeySlot) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var groups: [(group: String, slots: [KeySlot])] {
        guard !query.isEmpty else { return Deck.catalogue }
        return Deck.catalogue.compactMap { g in
            let hits = g.slots.filter { $0.title.localizedCaseInsensitiveContains(query) || ($0.detail ?? "").localizedCaseInsensitiveContains(query) }
            return hits.isEmpty ? nil : (g.group, hits)
        }
    }

    var body: some View {
        List {
            Section {
                NavigationLink("New Shortcut") { ChordMaker(onPick: onPick) }
                NavigationLink("Text") { TextMaker(onPick: onPick) }
            }
            ForEach(groups, id: \.group) { g in
                Section(g.group) {
                    ForEach(g.slots) { s in
                        Button { onPick(s) } label: {
                            HStack {
                                Text(s.title).foregroundStyle(.primary)
                                Spacer()
                                if let d = s.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
                                KeyFaceView(face: s.face, font: .body).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle("Choose Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

/// A shortcut, built by tapping: modifiers, then the key.
private struct ChordMaker: View {
    let onPick: (KeySlot) -> Void
    @State private var mods: RemoteModifiers = [.command]
    @State private var key = ""
    @State private var name = ""
    @State private var cycle = false

    var body: some View {
        Form {
            Section {
                Text(RemoteChord(mods, key).label).font(.largeTitle).frame(maxWidth: .infinity, minHeight: 52)
            }
            Section("Modifiers") {
                HStack {
                    ForEach(RemoteModifiers.ordered, id: \.1) { m, g in
                        Button(g) { mods.formSymmetricDifference(m) }
                            .buttonStyle(.bordered).tint(mods.contains(m) ? .white : .gray)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            Section("Key") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 6) {
                    ForEach(RemoteKey.all, id: \.name) { k in
                        Button(k.glyph) { key = k.name }
                            .buttonStyle(.bordered).tint(key == k.name ? .white : .gray).font(.footnote).lineLimit(1).minimumScaleFactor(0.5)
                    }
                }
            }
            Section {
                TextField("Name", text: $name)
                Toggle("Hold and slide to step", isOn: $cycle)
            }
        }
        .navigationTitle("New Shortcut")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { onPick(KeySlot(.chord(RemoteChord(mods, key), cycle: cycle), caption: name.isEmpty ? nil : name)) }.disabled(key.isEmpty)
            }
        }
    }
}

private struct TextMaker: View {
    let onPick: (KeySlot) -> Void
    @State private var text = ""
    @State private var name = ""
    @State private var enter = true

    var body: some View {
        Form {
            Section("Text") { TextField("/compact", text: $text, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled() }
            Section {
                TextField("Name", text: $name)
                Toggle("Press Return After", isOn: $enter)
            }
        }
        .navigationTitle("Text")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { onPick(KeySlot(.text(text, enter: enter), caption: name.isEmpty ? nil : name)) }.disabled(text.isEmpty)
            }
        }
    }
}
