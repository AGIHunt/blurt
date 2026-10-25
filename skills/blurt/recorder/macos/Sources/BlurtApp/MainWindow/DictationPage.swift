// Dictation (听写): a page of the main window — the sidebar's Dictation place, ⌥⌘D, the menu-bar menu's "Dictation
// History…", the command palette and Settings → Dictation all open it. Tabs: History | Words (DictationWords.swift: the
// custom words, managed here only) | Lab (when on). History: the middle column lists every dictation, newest
// first, grouped by day, with today's numbers on top and the toolbar's search field searching it; the detail column
// shows one dictation: what was typed and what was heard (one at a time or side by side), copy each, turn it into an
// item, delete it, and where and how it was typed — the style that actually ran, what polish did, and the models by
// name (DictationModels), not their ids. The lists draw their selection as the brand wash (ListWash / RowWash).
//
// Keys (the list focused): ↑↓ (⇧/⌘-click for more), ⌫ deletes (⌘Z puts it back), ⌘C copies, ⌘F searches.
//
// Reads DictationHistory (history.jsonl) directly, plus what newer dictation engines add to an entry (the terms they
// applied, the context they used) straight from its line, so older and newer histories both read. "Turn into item"
// goes through dictation.py (items.py add). `DictationHistoryWindow` keeps the name the rest of the app (and the test
// hooks) call: it opens this page.
import AppKit
import Combine
import SwiftUI
import BlurtCore

/// What a newer dictation engine may add to an entry; read defensively (any of a few shapes, or nothing).
struct DictationExtras: Equatable {
    var terms: [String] = []
    var context: String?

    init(_ o: [String: Any]) {
        let t = o["terms_applied"] ?? o["terms"] ?? o["vocabulary"]
        if let a = t as? [Any] {
            terms = a.compactMap { v in
                if let s = v as? String { return s }
                guard let d = v as? [String: Any] else { return nil }
                let to = (d["to"] ?? d["term"] ?? d["text"] ?? d["word"]) as? String
                if let from = (d["from"] ?? d["heard"]) as? String, let to = to, from != to { return "\(from) → \(to)" }
                return to
            }
        }
        let c = o["context_used"] ?? o["context"]
        if let s = c as? String, !s.isEmpty { context = s }
        else if let d = c as? [String: Any] {
            let parts = ["app", "kind", "source", "summary", "title", "field"].compactMap { d[$0] as? String }.filter { !$0.isEmpty }
            context = parts.isEmpty ? (d.isEmpty ? nil : d.keys.sorted().joined(separator: ", ")) : parts.joined(separator: " · ")
        } else if let a = c as? [String], !a.isEmpty { context = a.joined(separator: ", ") }
        else if (c as? Bool) == true { context = T("main.dictation.info.context.yes") }
    }

    var isEmpty: Bool { terms.isEmpty && context == nil }

    /// id → extras, for the entries that have any.
    static func load(_ url: URL) -> [String: DictationExtras] {
        guard let d = try? Data(contentsOf: url) else { return [:] }
        var out: [String: DictationExtras] = [:]
        for line in d.split(separator: 0x0A) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], o["op"] == nil,
                  let id = o["id"] as? String else { continue }
            let x = DictationExtras(o)
            out[id] = x.isEmpty ? nil : x
        }
        return out
    }
}

/// Today's numbers for the page's header: dictations, words (a CJK character counts as one), and roughly the minutes
/// it saved over typing the same text.
struct DictationStats: Equatable {
    var count = 0, words = 0
    var spoken: Double = 0
    /// typing at ~40 English words or ~50 Chinese characters a minute, minus the time spent talking
    var savedMinutes: Int {
        Int(max(0, Double(latin) / 40 + Double(cjk) / 50 - spoken / 60).rounded(.down))
    }
    private var latin = 0, cjk = 0

    init(_ entries: [DictationEntry]) {
        for e in entries {
            count += 1
            spoken += e.duration
            let (c, w) = DictationStats.units(e.text)
            cjk += c; latin += w
        }
        words = cjk + latin
    }

    static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: return true
        default: return false
        }
    }

    /// (CJK characters, other words)
    static func units(_ s: String) -> (Int, Int) {
        var cjk = 0, words = 0, inWord = false
        for u in s.unicodeScalars {
            if isCJK(u) { cjk += 1; inWord = false; continue }
            let letter = CharacterSet.alphanumerics.contains(u) || u == "'" || u == "’"
            if letter, !inWord { words += 1 }
            inWord = letter
        }
        return (cjk, words)
    }
}

@MainActor
final class DictationHistoryModel: ObservableObject {
    /// What the detail shows of a dictation that polish changed.
    enum Mode: String, CaseIterable { case polished, raw, compare }
    /// The page's tabs: the history, the custom words (DictationWords.swift), and the Dictation Lab (DictationLab.swift).
    enum Tab: String { case history, words, lab }

    @Published var tab: Tab = .history
    /// "Add to Lab" on an entry (the page sets it: the lab takes it in and shows it)
    var addToLab: ((DictationEntry) -> Void)?
    @Published var entries: [DictationEntry] = []
    @Published var extras: [String: DictationExtras] = [:]
    @Published var query = ""
    @Published var mode: Mode = .polished
    @Published var working: Set<String> = []
    @Published var error: String?
    /// The selected rows (↑↓, ⇧/⌘-click): ⌘C copies them, ⌫ deletes them.
    @Published var selection: Set<String> = []
    /// The id (or "detail-raw" / "detail-polished") whose copy button just worked: a check for a moment.
    @Published var copied: String?
    /// Dictation's state, for the header and the empty state: off in Settings, or on but its key can't be heard.
    @Published var enabled = true
    @Published var needsSetup = false

    func reload() {
        let h = DictationHistory.shared
        entries = h.load()
        extras = DictationExtras.load(h.url)
        let ids = Set(entries.map(\.id))
        if !selection.isSubset(of: ids) { selection = selection.intersection(ids) }
        refreshAccess()
    }

    func refreshAccess() {
        if enabled != Dictation.enabled { enabled = Dictation.enabled }
        let n = Dictation.enabled && Dictation.shared.needsSetup
        if needsSetup != n { needsSetup = n }
    }

    var filtered: [DictationEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { e in
            [e.finalText, e.text, e.raw, e.polished ?? "", e.app ?? ""].contains { $0.lowercased().contains(q) }
                || (extras[e.id]?.terms.contains { $0.lowercased().contains(q) } ?? false)
        }
    }

    /// (day, rows) newest day first.
    var days: [(day: Date, rows: [DictationEntry])] {
        let cal = Calendar.current
        var out: [(Date, [DictationEntry])] = []
        for e in filtered {
            let d = cal.startOfDay(for: e.time)
            if let i = out.indices.last, out[i].0 == d { out[i].1.append(e) } else { out.append((d, [e])) }
        }
        return out
    }

    var today: DictationStats { DictationStats(entries.filter { Calendar.current.isDateInToday($0.time) }) }

    var selected: [DictationEntry] { filtered.filter { selection.contains($0.id) } }
    /// The one dictation the detail shows (nil: none or several selected).
    var current: DictationEntry? { selection.count == 1 ? entries.first { $0.id == selection.first } : nil }

    /// Polish changed it (so there are two texts to tell apart).
    static func differs(_ e: DictationEntry) -> Bool { e.polished != nil && e.text != e.raw }

    func select(_ id: String?) { selection = id.map { [$0] } ?? [] }

    /// The first row, when nothing is selected yet.
    func selectFirstIfNone() {
        if selection.isEmpty, let f = filtered.first { selection = [f.id] }
    }

    func copy(_ s: String, from id: String? = nil) {
        DictationInsert.copy(s)             // the general clipboard (a test build's own pasteboard)
        emit(["event": "dictation_history", "action": "copy"])
        copied = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in if self?.copied == id { self?.copied = nil } }
    }

    /// The text the list and ⌘C go by: what was heard while the detail shows the original, else what was typed.
    func shownText(_ e: DictationEntry) -> String { mode == .raw ? e.raw : e.finalText }

    /// The selection's text, newest first, one per paragraph.
    func copySelection() {
        let es = selected
        guard !es.isEmpty else { return }
        copy(es.map(shownText).joined(separator: "\n\n"), from: es.count == 1 ? es[0].id : nil)
    }

    /// ⌘Z puts them back (the text and the item link; a recording kept with them is gone). The row after the last
    /// deleted one is selected, as in Mail.
    func delete(_ es: [DictationEntry], undo: UndoManager? = nil) {
        guard !es.isEmpty else { return }
        let undo = DictationHistoryWindow.shared.undoManager ?? undo     // the main window's: what ⌘Z in its Edit menu reaches
        let gone = Set(es.map(\.id))
        let list = filtered
        let next = list.firstIndex { gone.contains($0.id) }.flatMap { i in
            list[i...].first { !gone.contains($0.id) } ?? list[..<i].last { !gone.contains($0.id) }
        }
        DictationHistory.shared.delete(es.map(\.id))
        reload()
        selection = next.map { [$0.id] } ?? []
        undo?.registerUndo(withTarget: self) { m in
            for e in es.reversed() {
                var back = e
                back.audio = nil
                DictationHistory.shared.append(back)
                if let i = e.item, let u = e.itemUID { DictationHistory.shared.markItem(e.id, item: i, uid: u) }
            }
            m.reload()
            m.selection = gone
            // registered while undoing: ⇧⌘Z deletes them again
            undo?.registerUndo(withTarget: m) { m2 in m2.delete(m2.entries.filter { gone.contains($0.id) }, undo: undo) }
            undo?.setActionName(T("dictation.history.delete"))
        }
        undo?.setActionName(T("dictation.history.delete"))
        for e in es { emit(["event": "dictation_history", "action": "delete", "id": e.id]) }
    }

    /// dictation.py item ID --project <the current project, else Unassigned>
    func makeItem(_ e: DictationEntry) {
        let project = ProjectStore.shared.currentID ?? "inbox"
        working.insert(e.id)
        Scripts.call("dictation.py", ["item", e.id, "--project", project, "--lang", Loc.isChinese ? "zh" : "en"], timeout: 60) { [weak self] r in
            guard let self = self else { return }
            self.working.remove(e.id)
            switch r {
            case .success(let o):
                let it = o["item"] as? [String: Any] ?? [:]
                self.error = nil
                self.reload()
                emit(["event": "dictation_history", "action": "item", "id": e.id, "item": it["id"] as? String ?? ""])
                if let uid = it["uid"] as? String {
                    island.toast(T("dictation.history.item_made", it["id"] as? String ?? ""), actionTitle: T("dictation.history.show")) {
                        AppEnvironment.mainWindow?.reveal(uid: uid)
                    }
                }
            case .failure(let f):
                self.error = f.localized
                emit(["event": "dictation_history", "action": "item", "id": e.id, "error": f.code])
            }
        }
    }

    // MARK: correcting a dictation (docs/design/dictation.md §Learning from corrections)

    /// The dictation whose text is being edited, and the text so far.
    @Published var editing: String?
    @Published var draft = ""
    /// After a save, shown under the text for a while: the words it found — `offered` (new: suggestions until the
    /// note's Add), `known` (already on the list) — and, once added, `added` (the note's Undo takes them back).
    struct SavedNote: Equatable {
        var id: String
        var offered: [String] = []
        var known: [String] = []
        var added: [String] = []
    }
    @Published var savedNote: SavedNote?

    func beginEdit(_ e: DictationEntry) {
        draft = e.finalText
        editing = e.id
        savedNote = nil
    }

    func cancelEdit() { editing = nil }

    /// Saves the user's corrected text (history `correct`) and offers the words they fixed: a new word is a suggestion
    /// the note adds with one click (DictationVocabulary.learnCorrection; never a fragment with punctuation in it).
    /// ⌘Z (the window's undo) puts the text back and takes the words this correction made away. Returns the words.
    @discardableResult
    func saveCorrection(_ e: DictationEntry, _ text: String) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = nil
        guard !t.isEmpty, t != e.finalText else { return [] }
        let before = e.finalText, previous = e.corrected
        DictationHistory.shared.correct(e.id, text: t)
        let results = DictationVocabulary.shared.learnCorrection(typed: before, corrected: t)
        var note = SavedNote(id: e.id)
        for r in results {
            switch r.result {
            case .suggested(let w)?, .learned(let w)?: if !note.offered.contains(w) { note.offered.append(w) }
            case .known(let w)?: if !note.known.contains(w) { note.known.append(w) }
            case nil: break
            }
        }
        reload()
        savedNote = note
        let made = note.offered
        let undo = DictationHistoryWindow.shared.undoManager
        undo?.registerUndo(withTarget: self) { m in
            DictationHistory.shared.correct(e.id, text: previous)
            for w in made { DictationVocabulary.shared.forget(w) }
            m.savedNote = nil
            m.reload()
            emit(["event": "dictation_history", "action": "correct_undo", "id": e.id, "forgot": made])
        }
        undo?.setActionName(T("main.dictation.correct.undo_name"))
        emit(["event": "dictation_history", "action": "correct", "id": e.id, "learned": note.offered + note.known,
              "offered": note.offered, "known": note.known,
              "fixes": results.map { ["heard": $0.fix.heard, "fixed": $0.fix.fixed, "kind": $0.fix.kind.rawValue,
                                      "result": $0.result.map { "\($0)" } ?? "ignored"] }])
        holdNote(e.id, seconds: note.offered.isEmpty ? 6 : 12)
        return note.offered + note.known
    }

    /// The note's Add: the words found are in use from now on.
    func addOffered() {
        guard var n = savedNote, !n.offered.isEmpty else { return }
        for w in n.offered { DictationVocabulary.shared.accept(w) }
        n.added = n.offered
        n.offered = []
        savedNote = n
        emit(["event": "dictation_history", "action": "correct_add", "id": n.id, "added": n.added])
        holdNote(n.id, seconds: 6)
    }

    /// The note's Undo after Add: the words go again.
    func undoAdded() {
        guard var n = savedNote, !n.added.isEmpty else { return }
        for w in n.added { DictationVocabulary.shared.forget(w) }
        emit(["event": "dictation_history", "action": "correct_add_undo", "id": n.id, "forgot": n.added])
        n.added = []
        savedNote = n
        holdNote(n.id, seconds: 3)
    }

    private var noteToken = 0
    private func holdNote(_ id: String, seconds: Double) {
        noteToken += 1
        let tok = noteToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.noteToken == tok, self?.savedNote?.id == id { self?.savedNote = nil }
        }
    }

    /// A dictation whose speech recognition failed (its audio kept): again, the text copied when it is in.
    func retry(_ e: DictationEntry) {
        emit(["event": "dictation_history", "action": "retry", "id": e.id])
        Dictation.shared.retry(e.id, via: "history")
    }

    /// It failed and can be tried again (its audio is still there).
    static func canRetry(_ e: DictationEntry) -> Bool {
        e.text.isEmpty && (e.reason ?? "").hasPrefix("asr_failed") && e.audio.map {
            FileManager.default.fileExists(atPath: DictationHistory.shared.resolve($0).path)
        } ?? false
    }

    /// What the list shows for a dictation that wasn't recognised.
    static func failedText(_ e: DictationEntry) -> String {
        e.reason == "asr_failed:model_missing" ? T("dictation.history.failed.no_model") : T("dictation.history.failed")
    }

    func openSettings() { AppEnvironment.settings?.show(pane: "dictation") }
    func turnOn() { Dictation.shared.openSetup(from: "page") }

    // MARK: words for the views

    static func reasonText(_ r: String?) -> String {
        let k = "dictation.history.reason.\(r ?? "error")"
        return T(k) == k ? T("dictation.history.reason.error") : T(k)
    }

    static func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return T("dictation.history.today") }
        if cal.isDateInYesterday(d) { return T("dictation.history.yesterday") }
        let f = DateFormatter()
        f.locale = Loc.locale
        f.setLocalizedDateFormatFromTemplate(cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "MMMMdEEEE" : "yMMMMd")
        return f.string(from: d)
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Loc.locale
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f.string(from: d)
    }

    static func duration(_ s: Double) -> String {
        s < 60 ? T("dictation.history.seconds", Int(s.rounded())) : Loc.duration(s)
    }

    // MARK: app icons (the app a dictation went into)

    private static var icons: [String: NSImage] = [:]
    static func icon(_ bundle: String?) -> NSImage? {
        guard let b = bundle, !b.isEmpty else { return nil }
        if let i = icons[b] { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        icons[b] = i
        return i
    }
}

// MARK: - the page (two columns of the main window)

/// The page's two view controllers, swapped into the main window's middle and detail columns while the Dictation
/// place is selected.
@MainActor
final class DictationPage {
    let model = DictationHistoryModel()
    let lab = DictationLabModel()
    let words = DictationWordsModel()
    lazy var list: NSViewController = DictationPage.host(DictationPageList(m: model, lab: lab, words: words))
    lazy var detail: NSViewController = DictationPage.host(DictationPageDetail(m: model, lab: lab, words: words))
    private var accessTimer: Timer?
    private var tabWatch: AnyCancellable?
    private(set) var visible = false

    init() {
        Dictation.shared.lab = lab
        model.addToLab = { [weak self] e in self?.addToLab(e) }
        tabWatch = model.$tab.sink { [weak self] t in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    self.lab.visible = self.visible && t == .lab
                    if t == .lab { self.lab.reload() }
                    if t == .words { self.words.reload() }
                    MainWindowController.shared.updateTitle()
                    emit(["event": "dictation_page", "tab": t.rawValue])
                }
            }
        }
    }

    /// The Lab tab (the Go menu's "Dictation Lab", the palette, the test hooks).
    func showLab() {
        guard DictationLabModel.enabled else { model.tab = .history; return }
        model.tab = .lab
    }

    /// "Add to Lab" on a history entry: a case made from it (with its audio when it was kept), shown in the lab.
    func addToLab(_ e: DictationEntry) {
        lab.add(fromHistory: e.id) { [weak self] in self?.model.tab = .lab }
    }

    private static func host<V: View>(_ v: V) -> NSViewController {
        let h = NSHostingController(rootView: v)
        h.sizingOptions = []          // the split view sizes the columns, not the content
        return h
    }

    /// The Words tab (Settings → Dictation's "Manage…").
    func showWords() { model.tab = .words }

    func didShow() {
        visible = true
        lab.visible = model.tab == .lab
        model.reload()
        model.selectFirstIfNone()
        words.reload()
        DictationModels.shared.loadIfNeeded()          // the models' names in the detail
        // granting Input Monitoring needs no restart: the header and the empty state follow it; a word learned
        // meanwhile shows up in the Words tab
        accessTimer?.invalidate()
        accessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.refreshAccess()
                if self?.model.tab == .words { self?.words.reload() }
            }
        }
    }

    func didHide() {
        visible = false
        lab.visible = false
        accessTimer?.invalidate()
        accessTimer = nil
    }

    /// The list's table (SwiftUI's List is one underneath): first responder for ↑↓ ⌫ ⌘C.
    var table: NSTableView? { DictationPage.firstTable(list.view) }

    static func firstTable(_ v: NSView) -> NSTableView? {
        if let t = v as? NSTableView { return t }
        for s in v.subviews { if let t = firstTable(s) { return t } }
        return nil
    }
}

/// One of our icons in SwiftUI: the SF Symbol for generic ones (as the rest of the app), our vector for brand ones.
private func glyph(_ i: BlurtIcon, _ size: CGFloat = 12) -> Image {
    Image(nsImage: i.isBrand ? i.image(size: size + 2) : i.symbolImage(pointSize: size)).renderingMode(.template)
}

/// A small quiet button that reads as a link (the header's "Dictation Settings…").
private struct LinkButton: View {
    let title: String
    var tint: Color = .brandInk
    let action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).foregroundStyle(tint) }
            .buttonStyle(.plain)
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }
}

// MARK: - the two tabs

/// History | Words (| Lab, when it is on), above the list column; each tab has both columns.
struct DictationTabBar: View {
    @ObservedObject var m: DictationHistoryModel
    var body: some View {
        Picker("", selection: $m.tab) {
            Text(T("dictation.lab.tab.history")).tag(DictationHistoryModel.Tab.history)
            Text(T("dictation.words.tab")).tag(DictationHistoryModel.Tab.words)
            if DictationLabModel.enabled { Text(T("dictation.lab.tab.lab")).tag(DictationHistoryModel.Tab.lab) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .accessibilityLabel(T("dictation.lab.tab.label"))
        .frame(maxWidth: .infinity)
        .padding(.top, 8).padding(.bottom, 6)
        .onAppear { if m.tab == .lab && !DictationLabModel.enabled { m.tab = .history } }
    }
}

struct DictationPageList: View {
    @ObservedObject var m: DictationHistoryModel
    @ObservedObject var lab: DictationLabModel
    @ObservedObject var words: DictationWordsModel
    var body: some View {
        VStack(spacing: 0) {
            DictationTabBar(m: m)
            Divider()
            switch m.tab {
            case .lab: LabListView(lab: lab)
            case .words: DictationWordsList(w: words)
            case .history: DictationListView(m: m)
            }
        }
    }
}

struct DictationPageDetail: View {
    @ObservedObject var m: DictationHistoryModel
    @ObservedObject var lab: DictationLabModel
    @ObservedObject var words: DictationWordsModel
    var body: some View {
        switch m.tab {
        case .lab: LabDetailView(lab: lab)
        case .words: DictationWordsDetail(w: words)
        case .history: DictationDetailView(m: m)
        }
    }
}

/// A SwiftUI List's selection drawn the way every Blurt list draws it (system.md §3.3: a rounded `brand.tint` wash,
/// text stays ink; neutral when the window isn't key), not the filled accent: put `.background(ListWash())` on the
/// List (its table stops drawing the highlight) and `.listRowBackground(RowWash(on: selected))` on each row.
struct ListWash: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Finder() }
    func updateNSView(_ v: NSView, context: Context) { (v as? Finder)?.apply() }

    final class Finder: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }
        /// the nearest table around this view: the List it is the background of
        func apply() {
            var v = superview
            while let s = v {
                if let t = DictationPage.firstTable(s) {
                    if t.selectionHighlightStyle != .none { t.selectionHighlightStyle = .none }
                    return
                }
                v = s.superview
            }
        }
    }
}

struct RowWash: View {
    var on: Bool
    @Environment(\.controlActiveState) private var active
    var body: some View {
        if on {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active == .key ? Color.brandTint : Color.primary.opacity(0.06))
                .padding(.horizontal, 6).padding(.vertical, 1)
        } else {
            Color.clear
        }
    }
}

// MARK: - the list

struct DictationListView: View {
    @ObservedObject var m: DictationHistoryModel
    @Environment(\.undoManager) private var undo

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let e = m.error {
                Text(e).font(.caption).foregroundStyle(Color.brandErr).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                Divider()
            }
            if m.entries.isEmpty {
                DictationEmptyView(m: m)
            } else if m.filtered.isEmpty {
                EmptyStateContent(title: T("dictation.history.no_match"))
            } else {
                list
            }
        }
        .frame(minWidth: 320, minHeight: 300)
        .onAppear { m.reload() }
    }

    /// Today's numbers, quietly, and the way to Settings → Dictation (or the warning when dictation can't work).
    var header: some View {
        let s = m.today
        // the empty state says all of it itself; here only the way to Settings
        let quiet = m.entries.isEmpty
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            if quiet {
                EmptyView()
            } else if s.count == 0 {
                Text(T("main.dictation.today.none")).foregroundStyle(.secondary)
            } else {
                Text(T("main.dictation.today")).foregroundStyle(.secondary)
                stat(TP("main.dictation.stat.count", s.count))
                stat(TP("main.dictation.stat.words", s.words))
                if s.savedMinutes >= 1 {
                    stat(T("main.dictation.stat.saved", s.savedMinutes)).help(T("main.dictation.stat.saved.tip"))
                }
            }
            Spacer(minLength: 8)
            if !quiet && (!m.enabled || m.needsSetup) {
                // dictation can't work right now: say so where the settings link was
                HStack(spacing: 5) {
                    Circle().fill(Color.brandAttn).frame(width: 6, height: 6)
                    if m.enabled {
                        LinkButton(title: T("dictation.menu.turn_on"), tint: .brandAttnInk) { m.turnOn() }
                    } else {
                        Text(T("main.dictation.off")).foregroundStyle(.secondary)
                        LinkButton(title: T("main.dictation.settings")) { m.openSettings() }
                    }
                }
                .help(m.enabled ? T("dictation.menu.turn_on.tip", Dictation.keyInline) : T("main.dictation.off.detail"))
            } else {
                LinkButton(title: T("main.dictation.settings")) { m.openSettings() }
            }
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .accessibilityElement(children: .contain)
    }

    /// One of today's numbers: the number itself semibold, the words around it quieter. Neutral: a count is not brand.
    func stat(_ s: String) -> some View {
        let (before, number, after) = Self.splitNumber(s)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            if !before.isEmpty { Text(before).foregroundStyle(.primary.opacity(0.85)) }
            if !number.isEmpty { Text(number).fontWeight(.semibold).monospacedDigit() }
            if !after.isEmpty { Text(after).foregroundStyle(.primary.opacity(0.85)) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(s)
    }

    /// "12 dictations" → ("", "12", " dictations"); "约省 5 分钟" → ("约省 ", "5", " 分钟"); no digits → ("", "", s).
    static func splitNumber(_ s: String) -> (String, String, String) {
        guard let r = s.range(of: "[0-9][0-9,.\u{00A0}\u{202F}]*[0-9]|[0-9]", options: .regularExpression) else { return ("", "", s) }
        return (String(s[..<r.lowerBound]), String(s[r]), String(s[r.upperBound...]))
    }

    var list: some View {
        List(selection: $m.selection) {
            ForEach(m.days, id: \.day) { group in
                Section(header: Text(DictationHistoryModel.dayTitle(group.day))) {
                    ForEach(group.rows) { e in
                        DictationRow(m: m, e: e).tag(e.id).listRowBackground(RowWash(on: m.selection.contains(e.id)))
                    }
                }
            }
        }
        .listStyle(.inset)
        .background(ListWash())
        .onDeleteCommand { m.delete(m.selected, undo: undo) }        // ⌫
        .modifier(EditKeys { if let e = m.current { m.beginEdit(e) } })  // E or Return: correct the selected one
        .onCopyCommand {                                             // ⌘C
            m.copySelection()
            return []
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let es = m.entries.filter { ids.contains($0.id) }
            if !es.isEmpty {
                Button(T("dictation.history.copy")) { m.copy(es.map(\.finalText).joined(separator: "\n\n")) }
                if es.count == 1, let e = es.first {
                    Button(T("dictation.history.copy_raw")) { m.copy(e.raw) }
                    Divider()
                    Button(e.item == nil ? T("dictation.history.make_item") : T("dictation.history.item_exists", e.item ?? "")) { m.makeItem(e) }
                        .disabled(e.item != nil || m.working.contains(e.id))
                    if DictationLabModel.enabled { Button(T("dictation.lab.add")) { m.addToLab?(e) } }
                }
                Divider()
                Button(T("dictation.history.delete"), role: .destructive) { m.delete(es, undo: undo) }
            }
        }
    }
}

/// A row: the app it went into, small marks, the time; then the text, two lines at most.
struct DictationRow: View {
    @ObservedObject var m: DictationHistoryModel
    let e: DictationEntry

    var body: some View {
        let x = m.extras[e.id]
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let i = DictationHistoryModel.icon(e.bundle) {
                    Image(nsImage: i).resizable().interpolation(.high).frame(width: 14, height: 14)
                }
                Text(e.app ?? T("main.dictation.unknown_app")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1)
                marks(x)
                Spacer(minLength: 6)
                Text(DictationHistoryModel.time(e.time)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
            }
            if e.text.isEmpty, (e.reason ?? "").hasPrefix("asr_failed") {
                Text(DictationHistoryModel.failedText(e)).font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(m.shownText(e).trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 13)).lineLimit(2).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// polished · typed as spoken · terms applied · copied (not pasted) · its item
    @ViewBuilder func marks(_ x: DictationExtras?) -> some View {
        HStack(spacing: 4) {
            if e.fellBack {
                mark(.undo, .brandAttn, DictationHistoryModel.reasonText(e.reason))
            } else if DictationHistoryModel.differs(e) {
                mark(.wand, .secondary, T("dictation.history.badge.polished"))
            }
            if let t = x?.terms, !t.isEmpty { mark(.tag, .secondary, T("main.dictation.mark.terms", t.joined(separator: ", "))) }
            if e.insert == "copied" { mark(.copy, .secondary, T("main.dictation.info.copied")) }
            if let it = e.item {
                Text(it).font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(Color.brandOk)
                    .help(T("dictation.history.item_exists", it))
            }
        }
    }

    func mark(_ i: BlurtIcon, _ c: Color, _ tip: String) -> some View {
        glyph(i, 10).foregroundStyle(c).opacity(c == .secondary ? 0.8 : 1).help(tip).accessibilityLabel(tip)
    }
}

/// Nothing dictated yet: how to, and what stands in the way if anything does.
struct DictationEmptyView: View {
    @ObservedObject var m: DictationHistoryModel

    var body: some View {
        EmptyStateContent(title: T("dictation.history.empty.title"), message: T("dictation.history.empty.body", Dictation.keyInline)) {
            status
        }
    }

    @ViewBuilder var status: some View {
        if !m.enabled {
            VStack(spacing: 8) {
                pill(T("main.dictation.off"), .secondary)
                Button(T("main.dictation.settings")) { m.openSettings() }.controlSize(.regular)
            }
        } else if m.needsSetup {
            VStack(spacing: 8) {
                pill(T("dictation.menu.turn_on.tip", Dictation.keyInline), .brandAttn)
                // the one thing standing in the way: this view's primary
                Button(T("dictation.menu.turn_on")) { m.turnOn() }.buttonStyle(.brand).keyboardShortcut(.defaultAction)
            }
        } else {
            pill(T("main.dictation.ready"), .brandOk, check: true)
        }
    }

    /// A status line in a pill: a dot (attention), or a check (ready: ok is always a check shape).
    func pill(_ s: String, _ c: Color, check: Bool = false) -> some View {
        HStack(spacing: 6) {
            if check { glyph(.check, 10).foregroundStyle(c) } else { Circle().fill(c).frame(width: 6, height: 6) }
            Text(s).font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35)))
        .frame(maxWidth: 340)
    }
}

/// E or Return on the list: start correcting the selected dictation (macOS 14's key presses; on 13, the Correct
/// button).
struct EditKeys: ViewModifier {
    let edit: () -> Void
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .onKeyPress(.return) { edit(); return .handled }
                .onKeyPress(characters: CharacterSet(charactersIn: "eE"), phases: .down) { p in
                    guard p.modifiers.isEmpty else { return .ignored }
                    edit()
                    return .handled
                }
        } else {
            content
        }
    }
}

/// The correction's text view: the caret is in it, at the end, as soon as it opens (no click first); Esc cancels and
/// ⌘Return saves (the buttons' shortcuts), ⌘Z inside undoes typing.
struct CorrectionEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let tv = scroll.documentView as! NSTextView   // swiftlint:disable:this force_cast
        tv.font = .systemFont(ofSize: 14)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.string = text
        tv.delegate = context.coordinator
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            emit(["event": "dictation_history", "action": "editor_focus", "focused": tv.window?.firstResponder === tv])
        }
        return scroll
    }

    func updateNSView(_ v: NSScrollView, context: Context) {
        guard let tv = v.documentView as? NSTextView, tv.string != text else { return }
        tv.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: CorrectionEditor
        init(_ p: CorrectionEditor) { parent = p }
        func textDidChange(_ n: Notification) {
            if let tv = n.object as? NSTextView { parent.text = tv.string }
        }
    }
}

// MARK: - the detail

struct DictationDetailView: View {
    @ObservedObject var m: DictationHistoryModel
    /// the models' names (the history keeps their ids)
    @ObservedObject var models = DictationModels.shared
    @Environment(\.undoManager) private var undo

    var body: some View {
        Group {
            if let e = m.current {
                one(e)
            } else if m.selection.count > 1 {
                several(m.selected)
            } else if m.entries.isEmpty {
                Color.clear         // the list column's empty state says it once, with the app's mark
            } else {
                placeholder(T("main.dictation.none"), T("main.dictation.none.detail"))
            }
        }
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
    }

    func placeholder(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.right").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func several(_ es: [DictationEntry]) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            Text(TP("main.dictation.multi", es.count)).font(.system(size: 15, weight: .semibold))
            HStack(spacing: 8) {
                Button(T("main.dictation.copy_all")) { m.copySelection() }
                Button(T("dictation.history.delete"), role: .destructive) { m.delete(es, undo: undo) }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func one(_ e: DictationEntry) -> some View {
        let differs = DictationHistoryModel.differs(e)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                title(e)
                if differs {
                    Picker("", selection: $m.mode) {
                        Text(T("main.dictation.mode.polished")).tag(DictationHistoryModel.Mode.polished)
                        Text(T("main.dictation.mode.raw")).tag(DictationHistoryModel.Mode.raw)
                        Text(T("main.dictation.mode.compare")).tag(DictationHistoryModel.Mode.compare)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .accessibilityLabel(T("main.dictation.mode.label"))
                }
                if e.text.isEmpty, (e.reason ?? "").hasPrefix("asr_failed") {
                    failed(e)
                } else {
                    texts(e, differs: differs)
                }
                if e.fellBack {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        glyph(.undo, 11).foregroundStyle(Color.brandAttnInk)
                        Text(DictationHistoryModel.reasonText(e.reason)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                actions(e)
                Divider()
                info(e)
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func title(_ e: DictationEntry) -> some View {
        HStack(spacing: 12) {
            if let i = DictationHistoryModel.icon(e.bundle) {
                Image(nsImage: i).resizable().interpolation(.high).frame(width: 34, height: 34)
            } else {
                glyph(.keyboard, 20).foregroundStyle(.secondary).frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(e.app ?? T("main.dictation.unknown_app")).font(.system(size: 17, weight: .semibold))
                Text("\(DictationHistoryModel.dayTitle(e.time)) \(DictationHistoryModel.time(e.time)) · \(DictationHistoryModel.duration(e.duration))")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder func texts(_ e: DictationEntry, differs: Bool) -> some View {
        if !differs {
            card(e.finalText, label: e.corrected != nil ? T("main.dictation.corrected")
                    : e.polished == nil || e.fellBack ? T("main.dictation.heard") : T("main.dictation.typed"),
                 note: e.corrected == nil && e.polished != nil && !e.fellBack ? T("main.dictation.same") : nil,
                 copyID: "detail-text", edit: e)
        } else {
            switch m.mode {
            case .polished: card(e.finalText, label: typedLabel(e), copyID: "detail-polished", edit: e)
            case .raw: card(e.raw, label: T("main.dictation.heard"), secondary: true, copyID: "detail-raw")
            case .compare:
                // what was heard on the left, what was typed on the right, the same height
                HStack(alignment: .top, spacing: 12) {
                    card(e.raw, label: T("main.dictation.heard"), secondary: true, copyID: "detail-raw")
                    card(e.finalText, label: typedLabel(e), copyID: "detail-polished", edit: e)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        // reformat-last replaced it in the field: the text above is what is there now; the first version under it
        if let first = e.typedFirst, first != e.text, m.mode != .raw {
            card(first, label: T("main.dictation.before_reformat"), secondary: true, copyID: "detail-first")
        }
        if let n = m.savedNote, n.id == e.id { savedNote(n) }
    }

    func typedLabel(_ e: DictationEntry) -> String { e.corrected != nil ? T("main.dictation.corrected") : T("main.dictation.typed") }

    /// A take the speech model couldn't recognise: what failed, and Retry while its recording is there.
    func failed(_ e: DictationEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Color.brandAttn).frame(width: 6, height: 6)
            Text(DictationHistoryModel.failedText(e)).font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if e.reason == "asr_failed:model_missing" {
                Button(T("dictation.toast.no_model.action")) { Dictation.getSpeechModel(from: "page") }     // starts it in the download manager
            }
            if DictationHistoryModel.canRetry(e) {
                Button(T("dictation.history.retry")) { m.retry(e) }.keyboardShortcut("r", modifiers: .command)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    /// After Save Correction: saved, and the words it found — new ones to add with one click (then Undo), known ones.
    @ViewBuilder func savedNote(_ n: DictationHistoryModel.SavedNote) -> some View {
        let sep = T("main.dictation.correct.sep")
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            glyph(.check, 11).foregroundStyle(Color.brandOk)
            // the note is quiet; its one action reads as a link (brand ink), not as more of the sentence
            if !n.added.isEmpty {
                Text(T("main.dictation.correct.added", n.added.joined(separator: sep))).foregroundStyle(.secondary)
                Button(T("dictation.toast.undo")) { m.undoAdded() }.buttonStyle(.plain).foregroundStyle(Color.brandInk)
            } else if !n.offered.isEmpty {
                Text(T("main.dictation.correct.found", n.offered.joined(separator: sep))).foregroundStyle(.secondary)
                Button(T("main.dictation.correct.add")) { m.addOffered() }.buttonStyle(.plain).foregroundStyle(Color.brandInk)
            } else if !n.known.isEmpty {
                Text(T("main.dictation.correct.known", n.known.joined(separator: sep))).foregroundStyle(.secondary)
            } else {
                Text(T("main.dictation.correct.saved")).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
    }

    /// A block of text with its label and its own copy button; `edit`: the text can be corrected here ("Correct" →
    /// an editor with "Save correction", which also learns the misheard words).
    @ViewBuilder
    func card(_ text: String, label: String, note: String? = nil, secondary: Bool = false, copyID: String,
              edit: DictationEntry? = nil) -> some View {
        if let e = edit, m.editing == e.id {
            editor(e, label: label)
        } else {
            plainCard(text, label: label, note: note, secondary: secondary, copyID: copyID, edit: edit)
        }
    }

    func editor(_ e: DictationEntry, label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            CorrectionEditor(text: $m.draft)
                .frame(minHeight: 80)
                .accessibilityLabel(T("main.dictation.correct"))
            HStack(spacing: 8) {
                Text(T("main.dictation.correct.hint")).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button(T("main.dictation.correct.cancel")) { m.cancelEdit() }.keyboardShortcut(.cancelAction)
                Button(T("main.dictation.correct.save")) { m.saveCorrection(e, m.draft) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(m.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.regular)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.brandInk.opacity(0.6), lineWidth: 1))
    }

    func plainCard(_ text: String, label: String, note: String?, secondary: Bool, copyID: String, edit: DictationEntry?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                if let n = note { Text("· " + n).font(.system(size: 11)).foregroundStyle(.tertiary) }
                Spacer(minLength: 6)
                if let e = edit {
                    Button { m.beginEdit(e) } label: {
                        HStack(spacing: 4) { Image(systemName: "pencil").font(.system(size: 11)); Text(T("main.dictation.correct")) }
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(T("main.dictation.correct.tip"))
                }
                Button { m.copy(text, from: copyID) } label: {
                    HStack(spacing: 4) {
                        glyph(m.copied == copyID ? .check : .copy, 11)
                        Text(m.copied == copyID ? T("main.dictation.copied") : T("dictation.history.copy"))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(m.copied == copyID ? Color.brandOk : .secondary)
                }
                .buttonStyle(.borderless)
                .help(T("dictation.history.copy"))
            }
            Text(text)
                .font(.system(size: 14)).lineSpacing(3)
                .foregroundStyle(secondary ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)        // side by side: both as tall as the taller one
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    func actions(_ e: DictationEntry) -> some View {
        HStack(spacing: 8) {
            if let it = e.item, let uid = e.itemUID {
                Button { AppEnvironment.mainWindow?.reveal(uid: uid) } label: { Text(T("main.dictation.show_item", it)) }
            } else {
                // the AI writes the item: the button waits, the spinner beside it says so
                Button { m.makeItem(e) } label: { Text(T("dictation.history.make_item")) }
                    .disabled(m.working.contains(e.id))
                if m.working.contains(e.id) { ProgressView().controlSize(.small) }
            }
            if DictationLabModel.enabled {
                Button { m.addToLab?(e) } label: { Text(T("dictation.lab.add")) }
                    .help(e.audio != nil ? T("dictation.lab.add.tip") : T("dictation.lab.add.tip_text"))
            }
            Spacer()
            Button(role: .destructive) { m.delete([e], undo: undo) } label: {
                HStack(spacing: 4) { glyph(.trash, 11); Text(T("dictation.history.delete")) }
            }
            .help(T("main.dictation.delete.tip"))
        }
        .controlSize(.regular)
    }

    func info(_ e: DictationEntry) -> some View {
        let x = m.extras[e.id]
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 8) {
            row(T("main.dictation.info.app"), e.app ?? T("main.dictation.unknown_app"))
            row(T("main.dictation.info.when"), Loc.dateTime(e.time))
            row(T("main.dictation.info.length"), DictationHistoryModel.duration(e.duration))
            row(T("main.dictation.info.result"), e.insert == "pasted" ? T("main.dictation.info.pasted")
                : e.insert == "copied" ? T("main.dictation.info.copied") : T("main.dictation.info.not_typed"))
            polishRow(e)
            if let s = e.style, let ran = DictationEntryReport.styleRan(e) {
                // the style the text is in (what ran, not only what was asked for), and how often reformat-last
                // changed it (dictation-styles.md)
                let n = s.reformats.filter { $0.action == "reformat" }.count
                row(T("dictation.style.section"), Dictation.styleName(ran) + (n > 0 ? " · " + T("dictation.history.style.reformatted", n) : ""))
            }
            if let a = e.asrModel { row(T("main.dictation.info.asr"), models.asrName(a)) }
            if let l = e.language { row(T("main.dictation.info.language"), Loc.locale.localizedString(forIdentifier: l) ?? l) }
            if let t = x?.terms, !t.isEmpty {
                GridRow {
                    label(T("main.dictation.info.terms"))
                    FlowChips(items: t)
                }
            }
            if let c = x?.context { row(T("main.dictation.info.context"), c) }
        }
        .font(.system(size: 12))
    }

    /// What polish did, with the model's name; "no polish model" links to where it is downloaded.
    @ViewBuilder func polishRow(_ e: DictationEntry) -> some View {
        switch DictationEntryReport.polish(e, hasModel: models.polish == nil || models.selectedPolish != nil) {
        case .model(let id): row(T("main.dictation.info.polish"), id.isEmpty ? T("dictation.history.badge.polished") : models.polishName(id))
        case .fellBack(let id): row(T("main.dictation.info.polish"), T("dictation.history.badge.fell_back") + (id.map { " · " + models.polishName($0) } ?? ""))
        case .short: row(T("main.dictation.info.polish"), T("main.dictation.info.polish.short"))
        case .off: row(T("main.dictation.info.polish"), T("main.dictation.info.polish.off"))
        case .noModel:
            GridRow {
                label(T("main.dictation.info.polish"))
                HStack(spacing: 8) {
                    Text(T("main.dictation.info.polish.no_model"))
                    LinkButton(title: T("main.dictation.info.polish.get")) { SpeechPane.showDictationModels() }
                }
            }
        }
    }

    func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    func row(_ k: String, _ v: String) -> some View {
        GridRow {
            label(k)
            Text(v).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The terms a dictation applied, as small chips that wrap.
private struct FlowChips: View {
    let items: [String]
    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(items, id: \.self) { t in
                Text(t).font(.system(size: 11)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4)))
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > 0, x + z.width > w { x = 0; y += line + spacing; line = 0 }
            x += z.width + spacing; line = max(line, z.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(w, widest), height: y + line)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, line: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > b.minX, x + z.width > b.maxX { x = b.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(z))
            x += z.width + spacing; line = max(line, z.height)
        }
    }
}

// MARK: - the name the rest of the app calls

/// Opens the main window on the Dictation page (it used to be a window of its own). Dictation.swift, Settings →
/// Dictation, the menus and the test hooks call it.
final class DictationHistoryWindow: NSObject {
    static let shared = DictationHistoryWindow()

    @MainActor var page: DictationPage { MainWindowController.shared.dictation }

    @MainActor
    func show() {
        MainWindowController.shared.showDictation()
        emit(["event": "dictation_history", "action": "show", "window": MainWindowController.shared.window?.windowNumber ?? -1,
              "entries": page.model.entries.count, "page": true])
    }

    /// The page on its Words tab (Settings → Dictation's "Manage…").
    @MainActor
    func showWords() {
        show()
        page.showWords()
    }

    /// tests: `dictation history tab history|words|lab`, then what the Words tab shows ("dictation_words")
    @MainActor func testTab(_ t: String) {
        show()
        if let tab = DictationHistoryModel.Tab(rawValue: t) { page.model.tab = tab == .lab && !DictationLabModel.enabled ? .history : tab }
        page.words.reload()
        page.words.report()
    }

    /// A dictation was added, or Settings cleared the history: the page follows when it is showing.
    func reloadIfOpen() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let p = MainWindowController.shared.dictationIfLoaded
                guard let p = p, p.visible else { return }
                p.model.reload()
                p.model.selectFirstIfNone()
            }
        }
    }

    var windowNumber: Int? {
        MainActor.assumeIsolated {
            MainWindowController.shared.dictationIfLoaded?.visible == true ? MainWindowController.shared.window?.windowNumber : nil
        }
    }
    var undoManager: UndoManager? { MainActor.assumeIsolated { MainWindowController.shared.window?.undoManager } }

    // tests (BLURT_TEST_COMMANDS: `dictation history query Q | select ID,… | key K | raw [ID] | item [ID] | delete [ID]`)
    @MainActor func setQuery(_ q: String) { MainWindowController.shared.setDictationQuery(q) }
    @MainActor func testSelect(_ ids: [String]) {
        page.model.selection = Set(ids)
        emit(["event": "dictation_history", "action": "select", "selected": Array(page.model.selection)])
    }

    /// A real key event through the app's queue to the main window (key equivalents need it key): delete, cmd+c,
    /// cmd+z, cmd+f, esc, up, down. Answers with the state afterwards ("dictation_history" action "key").
    @MainActor func testKey(_ k: String) {
        guard let w = MainWindowController.shared.window else { return }
        let page = self.page
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        if k != "cmd+f", k != "esc", let table = page.table { w.makeFirstResponder(table) }
        let (code, chars, mods): (UInt16, String, NSEvent.ModifierFlags) = {
            switch k {
            case "delete": return (51, "\u{7f}", [])
            case "cmd+c": return (8, "c", .command)
            case "cmd+z": return (6, "z", .command)
            case "cmd+f": return (3, "f", .command)
            case "down": return (125, "\u{F701}", [.numericPad, .function])
            case "up": return (126, "\u{F700}", [.numericPad, .function])
            default: return (53, "\u{1b}", [])
            }
        }()
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                       isARepeat: false, keyCode: code) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            // ⌘Z / ⌘C are Edit-menu key equivalents, which only fire while the app is active — a test app launched in
            // the background isn't: send their actions up the window's responder chain, as the menu would
            if k == "cmd+z" || k == "cmd+c" {
                _ = (w.firstResponder ?? w).tryToPerform(k == "cmd+z" ? Selector(("undo:")) : #selector(NSText.copy(_:)), with: nil)
            } else if k == "cmd+f" {
                _ = MainWindowController.shared.handleKeyEquivalent(e)
            } else {
                NSApp.postEvent(e, atStart: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    emit(["event": "dictation_history", "action": "key", "key": k, "entries": page.model.entries.count,
                          "selected": Array(page.model.selection), "query": page.model.query,
                          "responder": w.firstResponder.map { "\(type(of: $0))" } ?? "none", "menu": NSApp.mainMenu?.items.count ?? 0,
                          "can_undo": w.undoManager?.canUndo ?? false, "can_redo": w.undoManager?.canRedo ?? false])
                }
            }
        }
    }

    /// Show what was heard / what was typed in the detail (and select that dictation).
    @MainActor func toggleRaw(_ id: String?) {
        let m = page.model
        if let t = id ?? m.current?.id ?? m.entries.first?.id { m.select(t) }
        m.mode = m.mode == .raw ? .polished : .raw
        emit(["event": "dictation_history", "action": "raw", "mode": m.mode.rawValue, "selected": Array(m.selection)])
    }
    @MainActor func setMode(_ mode: String) {
        if let md = DictationHistoryModel.Mode(rawValue: mode) { page.model.mode = md }
    }
    @MainActor func delete(_ id: String?) {
        let m = page.model
        guard let e = m.entries.first(where: { $0.id == id }) ?? m.entries.first else { return }
        m.delete([e])
    }
    @MainActor func makeItem(_ id: String?) {
        let m = page.model
        guard let e = m.entries.first(where: { $0.id == id }) ?? m.entries.first else { return }
        m.makeItem(e)
    }
    @MainActor func testEdit(_ id: String?) {
        let m = page.model
        guard let e = m.entries.first(where: { $0.id == id }) ?? m.entries.first else { return }
        m.select(e.id)
        m.beginEdit(e)
        emit(["event": "dictation_history", "action": "edit", "id": e.id, "draft": m.draft])
    }
    @MainActor func testNote(_ what: String) {
        let m = page.model
        if what == "undo" { m.undoAdded() } else { m.addOffered() }
        emit(["event": "dictation_history", "action": "note", "what": what, "offered": m.savedNote?.offered ?? [],
              "added": m.savedNote?.added ?? []])
    }
    @MainActor func testCorrect(_ id: String?, text: String) {
        let m = page.model
        guard let e = m.entries.first(where: { $0.id == id }) ?? m.entries.first else { return }
        m.select(e.id)
        m.saveCorrection(e, text)
    }
}
