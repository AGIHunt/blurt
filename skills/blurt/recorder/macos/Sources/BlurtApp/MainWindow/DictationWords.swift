// The Dictation page's Words tab (词库; docs/design/dictation.md §Custom words): the one place the custom words are
// managed. The list column: an add field (pasting "a, b, c" adds three; a word already there is flagged under it), a
// filter once there are more than 20 words, the words learned once and waiting for the user (Add / Ignore), the
// user's own words as chips that wrap (added, learned, their projects'), and the built-in words folded into one line
// ("Built-in words: 19 · Show"). The chips take the keyboard: Tab enters them, ← → move, ⌫ removes, Return or a
// double-click edits the spelling; the × shows on the chosen chip and on hover. Remove, Add and Ignore say so on the
// island with Undo (⌘Z too). The detail column: the chosen word — where it came from, how often dictation used it,
// what it was heard as — or what the words are for.
// The words are hints to the models, never replacements (BlurtCore/DictationVocabulary.swift).
// Settings → Dictation shows a one-line summary with "Manage…", which opens this tab.
import AppKit
import SwiftUI
import BlurtCore

@MainActor
final class DictationWordsModel: ObservableObject {
    /// a filter field shows once there are more words than this
    static let filterFrom = 20

    @Published var mine: [VocabTerm] = []
    @Published var builtIn: [VocabTerm] = []
    @Published var suggestions: [VocabTerm] = []
    @Published var newWord = ""
    @Published var filter = ""
    @Published var showBuiltIn = false
    /// the chosen word (its id = the term)
    @Published var selected: String?

    func reload() {
        let all = DictationVocabulary.shared.load()
        let byName: (VocabTerm, VocabTerm) -> Bool = { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
        let m = all.filter { $0.state == .active && $0.source != .builtIn }.sorted(by: byName)
        let b = all.filter { $0.state == .active && $0.source == .builtIn }.sorted(by: byName)
        let s = all.filter { $0.state == .suggested }
        if m != mine { mine = m }
        if b != builtIn { builtIn = b }
        if s != suggestions { suggestions = s }
        if let t = selected, !(m + b + s).contains(where: { $0.term == t }) { selected = nil }
    }

    var showsFilter: Bool { mine.count + builtIn.count > DictationWordsModel.filterFrom }

    func matching(_ ts: [VocabTerm]) -> [VocabTerm] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return ts }
        return ts.filter { $0.term.localizedCaseInsensitiveContains(q) }
    }

    var current: VocabTerm? { selected.flatMap { t in (mine + builtIn + suggestions).first { $0.term == t } } }

    /// the chip whose spelling is being edited, and the text so far
    @Published var renaming: String?
    @Published var renameText = ""

    /// What the add field would add: one word per comma (or 、 ; a line).
    var entries: [String] { DictationVocabulary.entries(newWord) }
    /// The words in the add field that are already on the list (said under the field, not added twice).
    var duplicates: [String] { entries.filter { t in (mine + builtIn).contains { $0.term.caseInsensitiveCompare(t) == .orderedSame } } }

    func add() {
        let ts = entries.filter { !duplicates.contains($0) }
        guard !ts.isEmpty else { return }
        for t in ts { DictationVocabulary.shared.add(t) }
        newWord = ""
        reload()
        selected = ts.last
        emit(["event": "dictation_vocab", "op": "add", "term": ts.count == 1 ? ts[0] : ts.joined(separator: ", "), "terms": ts])
    }

    /// A change to one word, with Undo: the island's line (its button) and ⌘Z both put the word back as it was.
    private func change(_ t: VocabTerm, op: String, toast key: String, _ apply: () -> Void) {
        let before = DictationVocabulary.shared.load().first { $0.term == t.term } ?? t
        apply()
        reload()
        emit(["event": "dictation_vocab", "op": op, "term": t.term])
        let undo = { [weak self] in
            DictationVocabulary.shared.restore(before)
            self?.reload()
            self?.selected = before.term
            emit(["event": "dictation_vocab", "op": "undo_\(op)", "term": before.term])
        }
        let um = DictationHistoryWindow.shared.undoManager
        um?.registerUndo(withTarget: self) { _ in undo() }
        um?.setActionName(T(key, t.term))
        var toast = Island.Toast(text: T(key, t.term), actionTitle: T("dictation.toast.undo"), action: {
            undo()
            _ = um.map { $0.removeAllActions(withTarget: self) }
        })
        toast.overOpen = true
        toast.key = "dictation.words"
        toast.seconds = 4
        island.toast(toast)
    }

    func remove(_ t: VocabTerm) {
        change(t, op: "remove", toast: "dictation.words.removed") {
            DictationVocabulary.shared.remove(t.term)
            if selected == t.term { selected = nil }
        }
    }
    func accept(_ t: VocabTerm) { change(t, op: "accept", toast: "dictation.words.accepted") { DictationVocabulary.shared.accept(t.term) } }
    func reject(_ t: VocabTerm) { change(t, op: "reject", toast: "dictation.words.ignored") { DictationVocabulary.shared.reject(t.term) } }

    // the chips by keyboard: ← → move, ⌫ removes, Return / a double-click edits

    func move(_ by: Int, in ts: [VocabTerm]) {
        guard !ts.isEmpty else { return }
        let i = ts.firstIndex { $0.term == selected }.map { max(0, min(ts.count - 1, $0 + by)) } ?? (by < 0 ? ts.count - 1 : 0)
        selected = ts[i].term
    }

    /// ⌫ on the chosen chip: it goes, and the next one is chosen.
    func removeSelected(in ts: [VocabTerm]) {
        guard let i = ts.firstIndex(where: { $0.term == selected }) else { return }
        let next = ts.indices.contains(i + 1) ? ts[i + 1].term : i > 0 ? ts[i - 1].term : nil
        remove(ts[i])
        selected = next
    }

    func beginRename(_ t: VocabTerm) {
        selected = t.term
        renameText = t.term
        renaming = t.term
    }

    func commitRename() {
        guard let old = renaming else { return }
        renaming = nil
        let n = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard n != old, let t = (mine + builtIn).first(where: { $0.term == old }) else { return }
        guard DictationVocabulary.shared.rename(old, to: n) else { return NSSound.beep() }
        let um = DictationHistoryWindow.shared.undoManager
        um?.registerUndo(withTarget: self) { m in
            DictationVocabulary.shared.restore(t)
            DictationVocabulary.shared.remove(n)
            m.reload()
            m.selected = old
        }
        um?.setActionName(T("dictation.words.rename"))
        reload()
        selected = n
        emit(["event": "dictation_vocab", "op": "rename", "term": old, "to": n])
    }

    func cancelRename() { renaming = nil }

    /// tests: what the tab shows
    func report() {
        emit(["event": "dictation_words", "mine": mine.map(\.term), "built_in": builtIn.count, "suggestions": suggestions.map(\.term),
              "show_built_in": showBuiltIn, "filter": filter, "selected": selected ?? NSNull(), "duplicates": duplicates,
              "renaming": renaming ?? NSNull()])
    }
}

// MARK: - the list column

struct DictationWordsList: View {
    @ObservedObject var w: DictationWordsModel

    var body: some View {
        VStack(spacing: 0) {
            addRow
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !w.suggestions.isEmpty { suggestions }
                    mine
                    builtIn
                }
                .padding(.horizontal, 14).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 320, minHeight: 300)
        .onAppear { w.reload() }
    }

    var addRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("", text: $w.newWord, prompt: Text(T("dictation.words.add.placeholder")))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { w.add() }
                    .accessibilityLabel(T("dictation.words.add.placeholder"))
                Button(T("dictation.vocab.add")) { w.add() }
                    .disabled(w.entries.count == w.duplicates.count)
            }
            if !w.duplicates.isEmpty {
                Text(T("dictation.words.duplicate", w.duplicates.joined(separator: T("dictation.vocab.list_sep"))))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if w.showsFilter {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("", text: $w.filter, prompt: Text(T("dictation.words.filter")))
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .accessibilityLabel(T("dictation.words.filter"))
                    if !w.filter.isEmpty {
                        Button { w.filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.borderless).accessibilityLabel(T("dictation.history.clear_search"))
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Learned once from a fix: Add / Ignore.
    var suggestions: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading(T("dictation.words.suggested", w.suggestions.count))
            ForEach(w.suggestions) { t in
                HStack(spacing: 8) {
                    Text(t.term).lineLimit(1)
                    Spacer(minLength: 6)
                    Button(T("dictation.vocab.accept")) { w.accept(t) }.controlSize(.small)
                    Button(T("dictation.vocab.ignore")) { w.reject(t) }.controlSize(.small)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture { w.selected = t.term }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder var mine: some View {
        let shown = w.matching(w.mine)
        VStack(alignment: .leading, spacing: 8) {
            heading(T("dictation.words.mine", w.mine.count))
            if w.mine.isEmpty {
                Text(T("dictation.words.mine.empty")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if shown.isEmpty {
                Text(T("dictation.words.no_match")).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                chips(shown)
            }
        }
    }

    /// One line, folded: the built-in words show on "Show" (or while the filter matches some).
    @ViewBuilder var builtIn: some View {
        if !w.builtIn.isEmpty {
            let filtering = !w.filter.trimmingCharacters(in: .whitespaces).isEmpty
            let shown = w.matching(w.builtIn)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(T("dictation.words.builtin", w.builtIn.count)).font(.system(size: 12)).foregroundStyle(.secondary)
                    if !filtering {
                        Button(w.showBuiltIn ? T("dictation.words.hide") : T("dictation.words.show")) { w.showBuiltIn.toggle() }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.brandInk)
                            .accessibilityLabel(T(w.showBuiltIn ? "dictation.words.hide.ax" : "dictation.words.show.ax"))
                    }
                }
                if (w.showBuiltIn && !filtering) || (filtering && !shown.isEmpty) { chips(shown) }
            }
        }
    }

    func heading(_ s: String) -> some View {
        Text(s).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
    }

    func chips(_ ts: [VocabTerm]) -> some View {
        ChipGroup(w: w, ts: ts)
    }
}

/// The chips as one keyboard stop: Tab enters (the first chip is chosen), ← → move, ⌫ removes, Return edits.
struct ChipGroup: View {
    @ObservedObject var w: DictationWordsModel
    let ts: [VocabTerm]
    @FocusState private var focused: Bool

    var body: some View {
        WordsFlow(spacing: 6) {
            ForEach(ts) { t in
                if w.renaming == t.term {
                    RenameField(w: w)
                } else {
                    WordChip(term: t.term, selected: w.selected == t.term,
                             select: { w.selected = w.selected == t.term ? nil : t.term }, remove: { w.remove(t) },
                             edit: { w.beginRename(t) })
                }
            }
        }
        .padding(2)
        .focusable()
        .focused($focused)
        .onChange(of: focused) { f in if f, !ts.contains(where: { $0.term == w.selected }) { w.move(0, in: ts) } }
        .onMoveCommand { d in
            switch d {
            case .left, .up: w.move(-1, in: ts)
            case .right, .down: w.move(1, in: ts)
            default: break
            }
        }
        .onDeleteCommand { w.removeSelected(in: ts) }
        .modifier(EditKeys { if let t = ts.first(where: { $0.term == w.selected }) { w.beginRename(t) } })
    }
}

/// A chip being re-spelled: Return keeps it, Esc goes back.
struct RenameField: View {
    @ObservedObject var w: DictationWordsModel
    @FocusState private var on: Bool
    var body: some View {
        TextField("", text: $w.renameText)
            .textFieldStyle(.plain).font(.system(size: 12.5))
            .frame(minWidth: 60, maxWidth: 220).fixedSize()
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().strokeBorder(Color.brandInk.opacity(0.7), lineWidth: 1))
            .focused($on)
            .onSubmit { w.commitRename() }
            .onExitCommand { w.cancelRename() }
            .onAppear { on = true }
            .accessibilityLabel(T("dictation.words.rename"))
    }
}

/// A word: the brand wash when chosen (§3.3), × on the chosen chip and on hover to remove it, a double-click edits.
struct WordChip: View {
    let term: String
    let selected: Bool
    let select: () -> Void
    let remove: () -> Void
    var edit: () -> Void = {}
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            Text(term).font(.system(size: 12.5)).lineLimit(1)
            if hover || selected {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .help(T("dictation.vocab.remove"))
                    .accessibilityLabel(T("dictation.words.remove", term))
            }
        }
        .padding(.leading, 9).padding(.trailing, hover || selected ? 6 : 9).padding(.vertical, 3)
        .background(Capsule().fill(selected ? Color.brandTint : Color.secondary.opacity(hover ? 0.16 : 0.10)))
        .contentShape(Capsule())
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: edit)
        .onTapGesture(perform: select)
        .contextMenu {
            Button(T("dictation.words.rename"), action: edit)
            Button(T("dictation.vocab.remove"), action: remove)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(term)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
        .accessibilityAction(named: T("dictation.vocab.remove"), remove)
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// Left-to-right wrapping layout for the chips.
struct WordsFlow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += line + spacing; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

// MARK: - the detail column

struct DictationWordsDetail: View {
    @ObservedObject var w: DictationWordsModel

    var body: some View {
        Group {
            if let t = w.current { word(t) } else { about }
        }
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
    }

    var about: some View {
        VStack(spacing: 8) {
            Image(systemName: "character.book.closed").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(T("dictation.words.about.title")).font(.system(size: 15, weight: .semibold))
            Text(T("dictation.words.about")).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 320).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func word(_ t: VocabTerm) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(t.term).font(.system(size: 22, weight: .semibold)).textSelection(.enabled)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 8) {
                    row(T("dictation.words.info.source"), T("dictation.words.source.\(t.state == .suggested ? "suggested" : t.source.rawValue)"))
                    row(T("dictation.words.info.used"), T("dictation.words.info.used.value", t.hits))
                    if !t.soundsLike.isEmpty {
                        row(T("dictation.words.info.heard"), t.soundsLike.joined(separator: T("dictation.vocab.list_sep")))
                    }
                    if t.added.timeIntervalSince1970 > 0 { row(T("dictation.words.info.added"), Loc.dateTime(t.added)) }
                }
                .font(.system(size: 12))
                HStack(spacing: 8) {
                    if t.state == .suggested {
                        Button(T("dictation.vocab.accept")) { w.accept(t) }
                        Button(T("dictation.vocab.ignore")) { w.reject(t) }
                    } else {
                        Button(T("dictation.vocab.remove"), role: .destructive) { w.remove(t) }
                    }
                }
                .controlSize(.regular)
                Text(T("dictation.words.about")).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 28)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(v).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
