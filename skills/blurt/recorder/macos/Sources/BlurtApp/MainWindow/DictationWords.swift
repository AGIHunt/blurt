// The Dictation page's Words tab (词库; docs/design/dictation.md §Custom words): the one place the custom words are
// managed. The list column: one field that finds as you type and adds on Return (pasting "a, b, c" adds three; a word
// already there is said under it), what the words are for in one line under it, then the words learned once and
// waiting for the user (待确认: Add, or × to ignore), the user's own words as chips that wrap (added, learned), their
// projects' names and keys under their own heading (so nobody wonders whether they added them), and the built-in words
// folded under the same kind of heading with a disclosure chevron. The chips take the keyboard: Tab enters them, ← →
// move, ⌫ removes, Return or a double-click edits the spelling; the × shows on the chosen chip and on hover, over the
// chip's corner (nothing reflows). Remove, Add and Ignore say so on the island with Undo (⌘Z too). The detail column:
// the chosen word — where it came from, how often dictation used it, what it was heard as — with its actions; a word
// waiting for review is chosen first, so the column opens on the one thing that needs the user.
// The words are hints to the models, never replacements (BlurtCore/DictationVocabulary.swift).
// Settings → Dictation shows a one-line summary with "Manage…", which opens this tab.
import AppKit
import SwiftUI
import BlurtCore

@MainActor
final class DictationWordsModel: ObservableObject {
    /// the user's own words: added, or learned from their corrections
    @Published var mine: [VocabTerm] = []
    /// their projects' names and keys (seeded by the app): their own section, so the user knows where they came from
    @Published var projects: [VocabTerm] = []
    @Published var builtIn: [VocabTerm] = []
    @Published var suggestions: [VocabTerm] = []
    /// the one field: what it finds as it is typed, and what Return adds
    @Published var newWord = ""
    @Published var showBuiltIn = false
    /// the chosen word (its id = the term)
    @Published var selected: String?

    /// One order in every language: by name, the way the words are spelled (not the reader's locale's collation, so
    /// "口喷鸡" doesn't move between first and last when the app's language changes).
    static func byName(_ a: VocabTerm, _ b: VocabTerm) -> Bool {
        a.term.compare(b.term, options: [.caseInsensitive, .numeric], range: nil, locale: Locale(identifier: "en_US_POSIX")) == .orderedAscending
    }

    func reload() {
        let all = DictationVocabulary.shared.load()
        let g = DictationVocabulary.groups(all)
        let m = g.own.sorted(by: Self.byName), p = g.projects.sorted(by: Self.byName), b = g.builtIn.sorted(by: Self.byName)
        let s = all.filter { $0.state == .suggested }
        if m != mine { mine = m }
        if p != projects { projects = p }
        if b != builtIn { builtIn = b }
        if s != suggestions { suggestions = s }
        if let t = selected, !(m + p + b + s).contains(where: { $0.term == t }) { selected = nil }
    }

    /// A word waiting for review is what the detail opens on (nothing chosen yet).
    func selectFirstIfNone() {
        if selected == nil, let s = suggestions.first { selected = s.term }
    }

    /// What the field finds: its text while it is one word (a list being pasted finds nothing).
    var query: String {
        let q = newWord.trimmingCharacters(in: .whitespaces)
        return entries.count > 1 ? "" : q
    }

    var filtering: Bool { !query.isEmpty }

    func matching(_ ts: [VocabTerm]) -> [VocabTerm] {
        guard filtering else { return ts }
        return ts.filter { $0.term.localizedCaseInsensitiveContains(query) }
    }

    /// While finding: nothing in any group matches.
    var noMatch: Bool {
        filtering && [suggestions, mine, projects, builtIn].allSatisfy { matching($0).isEmpty }
    }

    var current: VocabTerm? { selected.flatMap { t in (mine + projects + builtIn + suggestions).first { $0.term == t } } }

    /// the chip whose spelling is being edited, and the text so far
    @Published var renaming: String?
    @Published var renameText = ""

    /// What the field would add: one word per comma (or 、 ; a line).
    var entries: [String] { DictationVocabulary.entries(newWord) }
    /// The words in the field that are already on the list (said under the field, not added twice).
    var duplicates: [String] { entries.filter { t in (mine + projects + builtIn).contains { $0.term.caseInsensitiveCompare(t) == .orderedSame } } }
    /// What Return would add.
    var addable: [String] { entries.filter { !duplicates.contains($0) } }

    func add() {
        let ts = addable
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
    /// After Add or Ignore, the next word waiting for review is chosen (the review goes on), else the added word.
    func accept(_ t: VocabTerm) {
        let next = suggestions.first { $0.term != t.term }?.term
        change(t, op: "accept", toast: "dictation.words.accepted") { DictationVocabulary.shared.accept(t.term) }
        selected = next ?? t.term
    }
    func reject(_ t: VocabTerm) {
        let next = suggestions.first { $0.term != t.term }?.term
        change(t, op: "reject", toast: "dictation.words.ignored") { DictationVocabulary.shared.reject(t.term) }
        selected = next
    }

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
        guard n != old, let t = (mine + projects + builtIn).first(where: { $0.term == old }) else { return }
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
        emit(["event": "dictation_words", "mine": mine.map(\.term), "projects": projects.map(\.term), "built_in": builtIn.count, "suggestions": suggestions.map(\.term),
              "show_built_in": showBuiltIn, "filter": query, "selected": selected ?? NSNull(), "duplicates": duplicates,
              "renaming": renaming ?? NSNull()])
    }
}

// MARK: - the list column

struct DictationWordsList: View {
    @ObservedObject var w: DictationWordsModel

    var body: some View {
        VStack(spacing: 0) {
            field
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if w.noMatch {
                        Text(T("dictation.words.no_match", w.query)).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        if !w.matching(w.suggestions).isEmpty { review }
                        mine
                        projects
                        builtIn
                    }
                }
                .padding(.leading, DictationPageHeader.inset).padding(.trailing, 16).padding(.top, 14).padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 320, minHeight: 300)
        .onAppear { w.reload(); w.selectFirstIfNone() }
    }

    /// The one field: it finds as it is typed (the groups below narrow down) and Return adds what isn't there yet;
    /// the line under it says which of the two Return will do, or what the words are for while it is empty.
    var field: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "plus.magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("", text: $w.newWord, prompt: Text(T("dictation.words.add.placeholder")))
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .onSubmit { w.add() }
                    .onExitCommand { w.newWord = "" }
                    .accessibilityLabel(T("dictation.words.add.placeholder"))
                if !w.newWord.isEmpty {
                    Button { w.newWord = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.borderless).accessibilityLabel(T("dictation.history.clear_search"))
                }
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            hint
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, DictationPageHeader.inset).padding(.trailing, 16).padding(.bottom, 4)
    }

    @ViewBuilder var hint: some View {
        let sep = T("dictation.vocab.list_sep")
        if w.newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(T("dictation.words.about"))
        } else if !w.duplicates.isEmpty && w.addable.isEmpty {
            Text(T("dictation.words.duplicate", w.duplicates.joined(separator: sep)))
        } else if w.addable.count > 1 {
            Text(T("dictation.words.add.hint.many", w.addable.joined(separator: sep)))
        } else if let a = w.addable.first {
            Text(T("dictation.words.add.hint", a))
        }
    }

    /// Learned once from a fix and waiting for the user: a quiet card, each word with its one action (Add, in brand
    /// ink) and an × to ignore it; the chosen one is open in the detail with the reason it was learned.
    var review: some View {
        VStack(alignment: .leading, spacing: 8) {
            WordsHeading(title: T("dictation.words.suggested"), count: w.suggestions.count)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(w.matching(w.suggestions)) { t in
                    ReviewRow(w: w, t: t)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        }
    }

    @ViewBuilder var mine: some View {
        let shown = w.matching(w.mine)
        if !w.filtering || !shown.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                WordsHeading(title: T("dictation.words.mine"), count: w.mine.count)
                if w.mine.isEmpty {
                    Text(T("dictation.words.mine.empty")).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ChipGroup(w: w, ts: shown)
                }
            }
        }
    }

    /// The projects' names and keys: their own heading (where they come from is its tooltip), so nobody wonders
    /// whether they added them (v0.9 dogfood: "Atlas Web, AW, BA" under "Your words").
    @ViewBuilder var projects: some View {
        let shown = w.matching(w.projects)
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                WordsHeading(title: T("dictation.words.projects"), count: w.projects.count)
                    .help(T("dictation.words.projects.detail"))
                ChipGroup(w: w, ts: shown)
            }
        }
    }

    /// The built-in words, folded under the same heading with a chevron (open while the field finds some).
    @ViewBuilder var builtIn: some View {
        let shown = w.matching(w.builtIn)
        if !w.builtIn.isEmpty, !w.filtering || !shown.isEmpty {
            let open = w.filtering || w.showBuiltIn
            VStack(alignment: .leading, spacing: 8) {
                Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { w.showBuiltIn.toggle() } } label: {
                    HStack(spacing: 5) {
                        WordsHeading(title: T("dictation.words.builtin"), count: w.builtIn.count)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(w.filtering)
                .accessibilityLabel(T(open ? "dictation.words.hide.ax" : "dictation.words.show.ax"))
                if open { ChipGroup(w: w, ts: shown) }
            }
        }
    }
}

/// A group's heading: its name in the label colour, the count beside it in secondary — one form for every group.
private struct WordsHeading: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
            Text("\(count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A word waiting for review: the word, where it came from, Add (the one action, brand ink) and × to ignore.
private struct ReviewRow: View {
    @ObservedObject var w: DictationWordsModel
    let t: VocabTerm
    @State private var hover = false

    var body: some View {
        let chosen = w.selected == t.term
        HStack(spacing: 8) {
            Text(t.term).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text(T("dictation.words.source.suggested")).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button(T("dictation.vocab.accept")) { w.accept(t) }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.brandInk)
                .accessibilityLabel(T("dictation.words.accept.ax", t.term))
            Button { w.reject(t) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(T("dictation.vocab.ignore"))
            .accessibilityLabel(T("dictation.words.ignore.ax", t.term))
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(chosen ? Color.brandTint : Color.primary.opacity(hover ? 0.04 : 0)).padding(2))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { w.selected = t.term }
        .accessibilityElement(children: .contain)
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

/// A word: the brand wash when chosen (§3.3), a small × over its corner on hover and when chosen (it never changes
/// the chip's width, so a wrapped row doesn't move under the pointer), a double-click edits.
struct WordChip: View {
    let term: String
    let selected: Bool
    let select: () -> Void
    let remove: () -> Void
    var edit: () -> Void = {}
    @State private var hover = false

    var body: some View {
        Text(term).font(.system(size: 12.5)).lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(selected ? Color.brandTint : Color.primary.opacity(hover ? 0.10 : 0.06)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(selected ? 0 : 0.05), lineWidth: 0.5))
            .overlay(alignment: .topTrailing) {
                if hover || selected {
                    Button(action: remove) {
                        Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(.regularMaterial))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                    .help(T("dictation.vocab.remove"))
                    .accessibilityLabel(T("dictation.words.remove", term))
                    .transition(.opacity)
                }
            }
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

/// The chosen word: one header band level with the list's views (the word, where it came from), the facts in one
/// label column, and its actions — Add as the view's one primary for a word waiting for review (Ignore beside it),
/// Edit Spelling and Remove for a word in use. Nothing chosen: a quiet placeholder (what the words are for is said once,
/// under the field).
struct DictationWordsDetail: View {
    @ObservedObject var w: DictationWordsModel

    var body: some View {
        Group {
            if let t = w.current { word(t) } else { placeholder }
        }
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
    }

    var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "character.book.closed").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                .accessibilityHidden(true).padding(.bottom, 4)
            Text(T("dictation.words.none")).font(.system(size: 15, weight: .semibold))
            Text(T("dictation.words.none.detail")).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 280).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func word(_ t: VocabTerm) -> some View {
        let review = t.state == .suggested
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.term).font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(T("dictation.words.source.\(review ? "suggested" : t.source.rawValue)"))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(height: DictationPageHeader.height, alignment: .leading)
                .padding(.bottom, 14)
                if review {
                    Text(T("dictation.words.review.detail")).font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 16)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 7) {
                    if !review { row(T("dictation.words.info.used"), T("dictation.words.info.used.value", t.hits)) }
                    if !t.soundsLike.isEmpty {
                        row(T("dictation.words.info.heard"), t.soundsLike.joined(separator: T("dictation.vocab.list_sep")))
                    }
                    if t.added.timeIntervalSince1970 > 0 { row(T("dictation.words.info.added"), Loc.dateTime(t.added)) }
                }
                .font(.system(size: 12))
                HStack(spacing: 10) {
                    if review {
                        Button(T("dictation.words.accept")) { w.accept(t) }
                            .buttonStyle(.brand).keyboardShortcut(.return, modifiers: .command)
                        Button(T("dictation.vocab.ignore")) { w.reject(t) }
                    } else {
                        Button(T("dictation.words.rename")) { w.beginRename(t) }
                        Button(T("dictation.vocab.remove")) { w.remove(t) }
                    }
                }
                .controlSize(.regular)
                .padding(.top, 22)
            }
            .padding(.horizontal, DictationDetailView.inset).padding(.bottom, 28)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary).lineLimit(1).gridColumnAlignment(.leading).frame(width: 112, alignment: .leading)
            Text(v).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
