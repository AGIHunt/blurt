// The Dictation page's Words tab (词库; docs/design/dictation.md §Custom words): the one place the custom words are
// managed. The list column: one field that finds as you type and adds on Return (pasting "a, b, c" adds three; a word
// already there is said under it), what the words are for in one line under it, then the words learned once and
// waiting for the user (待确认) as plain rows whose Add and × show on the chosen row and on hover — the only place that
// decision is made — the words the user added as chips that wrap, their projects' words one chip per project (the name,
// and the key the way the sidebar sets it), and the built-in words folded under the same kind of heading with a
// disclosure chevron. The chips take the keyboard: Tab enters them, ← → move, ⌫ removes, Return or a double-click
// edits the spelling; the × shows on the chosen chip and on hover, over the chip's corner (nothing reflows). Remove, Add
// and Ignore say so on the island with Undo (⌘Z too). The detail column only tells: the chosen word, where it came
// from, how often dictation used it, what it was heard as (Edit Spelling and Remove in its ⋯); a word waiting for
// review is chosen first, so the column opens on the one thing that needs the user.
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
        offerUndo(T(key, t.term), undo)
    }

    /// ⌘Z and the island's one keyed line ("dictation.words": a newer change's Undo takes its place) both run `undo`.
    private func offerUndo(_ text: String, _ undo: @escaping () -> Void) {
        let um = DictationHistoryWindow.shared.undoManager
        um?.registerUndo(withTarget: self) { _ in undo() }
        um?.setActionName(text)
        var toast = Island.Toast(text: text, actionTitle: T("dictation.toast.undo"), action: {
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

    /// A project's words (its chip's ×): all of them go, with one Undo that brings them all back.
    func remove(_ ts: [VocabTerm]) {
        guard ts.count > 1 else { if let t = ts.first { remove(t) }; return }
        let all = DictationVocabulary.shared.load()
        let before = ts.map { t in all.first { $0.term == t.term } ?? t }
        for t in ts { DictationVocabulary.shared.remove(t.term) }
        if let s = selected, ts.contains(where: { $0.term == s }) { selected = nil }
        reload()
        let names = ts.map(\.term).joined(separator: T("dictation.vocab.list_sep"))
        emit(["event": "dictation_vocab", "op": "remove", "term": names, "terms": ts.map(\.term)])
        let undo = { [weak self] in
            for b in before { DictationVocabulary.shared.restore(b) }
            self?.reload()
            self?.selected = before.first?.term
            emit(["event": "dictation_vocab", "op": "undo_remove", "term": names])
        }
        offerUndo(T("dictation.words.removed", names), undo)
    }

    /// The projects' words, one group per project (its name and its key, as the project made them), so a key like
    /// "BA" reads as billing-api's and not as a stray word; words of a project that is gone stand alone.
    struct ProjectWords: Identifiable, Equatable {
        var id: String
        var name: String
        var key: String
        var terms: [VocabTerm]
        var nameIsWord: Bool { terms.contains { $0.term == name } }
        var keyWord: VocabTerm? { key.isEmpty ? nil : terms.first { $0.term == key } }
    }

    var projectGroups: [ProjectWords] {
        var left = projects
        var out: [ProjectWords] = []
        for p in ProjectStore.shared.projects where !p.isInbox {
            let ws = left.filter { $0.term == p.name || $0.term == p.key }
            guard !ws.isEmpty else { continue }
            left.removeAll { t in ws.contains(t) }
            out.append(ProjectWords(id: p.id, name: p.name, key: p.key, terms: ws.sorted { a, _ in a.term == p.name }))
        }
        out += left.map { ProjectWords(id: "word:" + $0.term, name: $0.term, key: "", terms: [$0]) }
        return out.sorted { a, b in
            a.name.compare(b.name, options: [.caseInsensitive, .numeric], range: nil, locale: Locale(identifier: "en_US_POSIX")) == .orderedAscending
        }
    }

    /// The project a word came from (the detail says it).
    func project(of t: VocabTerm) -> String? {
        projectGroups.first { g in !g.id.hasPrefix("word:") && g.terms.contains(t) }?.name
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
            // a field a step off the pane in both modes (the text background was a near-black well in dark mode)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
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

    /// Learned once from a fix and waiting for the user: plain rows on the list's edge (no card), each with Add and ×
    /// on the chosen row and on hover; the chosen one is open in the detail with where it came from.
    var review: some View {
        VStack(alignment: .leading, spacing: 4) {
            WordsHeading(title: T("dictation.words.suggested"), count: w.suggestions.count)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(w.matching(w.suggestions)) { t in
                    ReviewRow(w: w, t: t)
                }
            }
            .padding(.horizontal, -10)          // the rows' text on the headings' edge, their wash past it
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
        let groups = w.projectGroups.filter { g in !w.filtering || !w.matching(g.terms).isEmpty }
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                WordsHeading(title: T("dictation.words.projects"), count: w.projects.count)
                    .help(T("dictation.words.projects.detail"))
                ProjectChips(w: w, groups: groups)
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

/// A word waiting for review: the word and where it came from; Add (brand ink, ⌘↩ while chosen) and × to ignore show
/// on the chosen row and on hover, at the same place (nothing moves). Chosen: the list's tint, nothing else.
private struct ReviewRow: View {
    @ObservedObject var w: DictationWordsModel
    let t: VocabTerm
    @State private var hover = false
    @Environment(\.controlActiveState) private var active

    var body: some View {
        let chosen = w.selected == t.term
        let tools = chosen || hover
        HStack(spacing: 8) {
            Text(t.term).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text(T("dictation.words.source.suggested")).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Group {
                    if chosen {
                        Button(T("dictation.vocab.accept")) { w.accept(t) }.keyboardShortcut(.return, modifiers: .command)
                    } else {
                        Button(T("dictation.vocab.accept")) { w.accept(t) }
                    }
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.brandInk)
                .help(T("dictation.words.accept.tip"))
                .accessibilityLabel(T("dictation.words.accept.ax", t.term))
                Button { w.reject(t) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(T("dictation.vocab.ignore"))
                .accessibilityLabel(T("dictation.words.ignore.ax", t.term))
            }
            .opacity(tools ? 1 : 0)
            .allowsHitTesting(tools)
            .accessibilityHidden(!tools)
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(chosen ? (active == .key ? Color.brandTint : Color.primary.opacity(0.06)) : Color.primary.opacity(hover ? 0.04 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { w.selected = t.term }
        .contextMenu {
            Button(T("dictation.words.accept")) { w.accept(t) }
            Button(T("dictation.vocab.ignore")) { w.reject(t) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: T("dictation.words.accept")) { w.accept(t) }
        .accessibilityAction(named: T("dictation.vocab.ignore")) { w.reject(t) }
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

/// The projects' words, one chip per project, as one keyboard stop like the other chips (← → move, ⌫ removes the
/// project's words). Each chip: the project's name, then its key set the way the sidebar sets it (small, monospaced);
/// a part that isn't a word dictation is told about (a long name) is in secondary, so "IOS" reads as the key of
/// "口喷鸡 iOS 客户端", not as a misspelt iOS. The context menu edits or removes one word of it.
struct ProjectChips: View {
    @ObservedObject var w: DictationWordsModel
    let groups: [DictationWordsModel.ProjectWords]
    @FocusState private var focused: Bool

    var body: some View {
        WordsFlow(spacing: 6) {
            ForEach(groups) { g in
                if let r = w.renaming, g.terms.contains(where: { $0.term == r }) {
                    RenameField(w: w)
                } else {
                    ProjectWordsChip(w: w, g: g)
                }
            }
        }
        .focusable()
        .focused($focused)
        .onChange(of: focused) { f in if f, chosen == nil { pick(0) } }
        .onMoveCommand { d in
            switch d {
            case .left, .up: pick((chosen ?? groups.count) - 1)
            case .right, .down: pick((chosen ?? -1) + 1)
            default: break
            }
        }
        .onDeleteCommand {
            guard let i = chosen else { return }
            let next = groups.indices.contains(i + 1) ? groups[i + 1].terms.first?.term : i > 0 ? groups[i - 1].terms.first?.term : nil
            w.remove(groups[i].terms)
            w.selected = next
        }
    }

    var chosen: Int? { groups.firstIndex { g in g.terms.contains { $0.term == w.selected } } }
    func pick(_ i: Int) {
        guard !groups.isEmpty else { return }
        w.selected = groups[max(0, min(groups.count - 1, i))].terms.first?.term
    }
}

private struct ProjectWordsChip: View {
    @ObservedObject var w: DictationWordsModel
    let g: DictationWordsModel.ProjectWords
    @State private var hover = false

    var body: some View {
        let selected = g.terms.contains { $0.term == w.selected }
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(g.name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(g.nameIsWord ? Color.primary : Color.secondary)
                .frame(maxWidth: 170, alignment: .leading).fixedSize(horizontal: g.name.count < 18, vertical: false)
            if let k = g.keyWord {
                Text(k.term).font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(g.nameIsWord ? Color.secondary : Color.primary)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(Capsule().fill(selected ? Color.brandTint : Color.primary.opacity(hover ? 0.10 : 0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(selected ? 0 : 0.05), lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            if hover || selected {
                Button { w.remove(g.terms) } label: {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(.regularMaterial))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .help(T("dictation.vocab.remove"))
                .accessibilityLabel(T("dictation.words.remove", g.terms.map(\.term).joined(separator: T("dictation.vocab.list_sep"))))
                .transition(.opacity)
            }
        }
        .contentShape(Capsule())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { if let t = g.terms.first { w.beginRename(t) } }
        .onTapGesture { w.selected = selected ? nil : g.terms.first?.term }
        .contextMenu {
            ForEach(g.terms) { t in Button(T("dictation.words.rename.one", t.term)) { w.beginRename(t) } }
            Divider()
            ForEach(g.terms) { t in Button(T("dictation.words.remove", t.term)) { w.remove(t) } }
        }
        .help(T("dictation.words.project.tip", g.name, g.terms.map(\.term).joined(separator: T("dictation.vocab.list_sep"))))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(g.terms.map(\.term).joined(separator: T("dictation.vocab.list_sep")))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default) { w.selected = g.terms.first?.term }
        .accessibilityAction(named: T("dictation.vocab.remove")) { w.remove(g.terms) }
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

/// The chosen word, told, not acted on: one header band level with the list's views (the word, where it came from,
/// and for a word in use a ⋯ with Edit Spelling and Remove), then the facts in one label column under a hairline, as the
/// history's. A word waiting for review is decided in the list (its row's Add and ×) — the one place for it; here, why
/// it was suggested and when. Nothing chosen: a quiet placeholder.
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

    func source(_ t: VocabTerm) -> String {
        if t.state == .suggested { return T("dictation.words.source.review") }
        if t.source == .project, let p = w.project(of: t) { return T("dictation.words.source.project_named", p) }
        return T("dictation.words.source.\(t.source.rawValue)")
    }

    func word(_ t: VocabTerm) -> some View {
        let review = t.state == .suggested
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.term).font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Text(source(t)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    if !review {
                        Menu {
                            Button(T("dictation.words.rename")) { w.beginRename(t) }
                            Divider()
                            Button(T("dictation.vocab.remove")) { w.remove(t) }
                        } label: {
                            Image(nsImage: BlurtIcon.more.symbolImage(pointSize: 13)).renderingMode(.template)
                                .accessibilityLabel(T("dictation.history.more"))
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .foregroundStyle(.secondary)
                        .help(T("dictation.history.more"))
                        .accessibilityLabel(T("dictation.history.more"))
                    }
                }
                .frame(height: DictationPageHeader.height, alignment: .leading)
                .padding(.bottom, 14)
                if review {
                    Text(T("dictation.words.review.detail")).font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 18)
                }
                Divider().padding(.bottom, 12)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 7) {
                    if !review { row(T("dictation.words.info.used"), T("dictation.words.info.used.value", t.hits)) }
                    if !t.soundsLike.isEmpty {
                        row(T("dictation.words.info.heard"), t.soundsLike.joined(separator: T("dictation.vocab.list_sep")))
                    }
                    if review, t.seen > 1 { row(T("dictation.words.info.seen"), T("dictation.words.info.seen.value", t.seen)) }
                    if t.added.timeIntervalSince1970 > 0 {
                        // a word waiting for review hasn't been added: when it was found
                        row(T(review ? "dictation.words.info.found" : "dictation.words.info.added"), Loc.dateTime(t.added))
                    }
                }
                .font(.system(size: 12))
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
