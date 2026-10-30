// Dictation (听写): a page of the main window — the sidebar's Dictation place, ⌥⌘D, the menu-bar menu's "Dictation
// History…", the command palette and Settings → Dictation all open it. The list column starts with one header band
// (DictationPageHeader): the views History | Words (DictationWords.swift: the custom words, managed here only) | Lab
// (when on) as a neutral segmented control on the column's leading edge, and the view's own few commands on the right
// (the Lab's; History's Send Feedback…, DictationFeedback.swift). History: every dictation, newest first, grouped by day (today's numbers on the Today heading) — what
// stands in dictation's way (no speech model…) as one banner above it, with the view's one primary; the detail column
// shows one dictation: where and when, the text (polished, original, or the changes polish made marked in one text),
// Copy and Correct on hover, Turn into Item, the rest in "⋯" (and the row's right-click), and how it was typed behind
// "Details" — the style that actually ran, what polish did, and the models by name (DictationModels), not their ids.
// The lists draw their selection as the brand wash (ListWash / RowWash).
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
            // an older entry's raw context dict ({"before","after","selection"}): never its keys — just that it was used
            context = parts.isEmpty ? (d.isEmpty ? nil : T("main.dictation.info.context.yes")) : parts.joined(separator: " · ")
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
    /// History → Send Feedback… (DictationFeedback.swift)
    @Published var feedbackOpen = false
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
            [e.finalText, e.text, e.raw, e.polished ?? "", AppNames.display(name: e.app, bundle: e.bundle) ?? ""].contains { $0.lowercased().contains(q) }
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

    /// What ⌘C copies of one dictation: what the detail shows of it (the Polished | As Spoken switch is the detail's
    /// own — the list always reads what was typed).
    func shownText(_ e: DictationEntry) -> String { mode == .raw && DictationHistoryModel.differs(e) ? e.raw : e.finalText }

    /// The selection's text, newest first, one per paragraph: one dictation as the detail shows it, several as typed.
    func copySelection() {
        let es = selected
        guard !es.isEmpty else { return }
        copy(es.count == 1 ? shownText(es[0]) : es.map(\.finalText).joined(separator: "\n\n"), from: es.count == 1 ? es[0].id : nil)
    }

    /// The page's one count, in the window's subtitle: "9 dictations", "3 of 9 dictations" while searching.
    var subtitle: String {
        guard !entries.isEmpty else { return "" }
        let all = TP("main.dictation.count", entries.count)
        return query.trimmingCharacters(in: .whitespaces).isEmpty ? all : T("main.dictation.count_of", filtered.count, all)
    }

    /// The search's words, for marking them in the rows (several words: each).
    var queryTerms: [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
    }

    /// How a dictation went in, when it didn't simply go in polished at the cursor: one fact for the row's chip and
    /// the same fact, with its reason, for the detail — one wording in both places.
    struct Exception: Equatable {
        var chip: String
        var line: String
    }

    static func exception(_ e: DictationEntry) -> Exception? {
        let copied = e.insert == "copied", raw = e.fellBack
        let why = reasonText(e.reason)
        switch (copied, raw) {
        case (true, true): return Exception(chip: T("main.dictation.chip.copied_raw"), line: T("main.dictation.status.copied_raw", why))
        case (true, false): return Exception(chip: T("main.dictation.chip.copied"), line: T("main.dictation.status.copied"))
        case (false, true): return Exception(chip: T("dictation.history.badge.fell_back"), line: T("main.dictation.status.raw", why))
        default: return nil
        }
    }

    /// Some of a long take's parts weren't polished (not all: the take isn't "not polished"): said under the text only.
    static func partsLine(_ e: DictationEntry) -> String? {
        guard !e.fellBack, let p = e.fellBackParts else { return nil }
        return T("main.dictation.status.parts", p.n, p.of, reasonText(e.reason))
    }

    /// ⌘Z — or the island's "Deleted · Undo" — puts them back: the text, the item link and a recording kept with them
    /// (it waits in audio/.deleted/ for a couple of minutes: DictationHistory.delete). The row after the last deleted
    /// one is selected, as in Mail.
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
        // the recordings go for good once Undo is unlikely
        let files = es.compactMap { $0.audio.map { DictationHistory.shared.resolve($0).lastPathComponent } }
        if !files.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + DictationHistoryModel.audioUndoSeconds) {
                DictationHistory.shared.purgeDeleted(files)
            }
        }
        // said where the user looks while dictating too, with the way back (an Undo only in the Edit menu went unseen)
        island.toast(es.count == 1 ? T("dictation.history.deleted.one") : T("dictation.history.deleted.many", es.count),
                     key: DictationToastKeys.historyDeleted, seconds: 5, actionTitle: T("dictation.toast.undo")) { [weak undo] in
            if let u = undo, u.canUndo { u.undo() }
        }
        undo?.registerUndo(withTarget: self) { m in
            for e in es.reversed() {
                var back = e
                if !DictationHistory.shared.restoreAudio(e) { back.audio = nil }
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
        switch e.reason {
        case "asr_failed:model_missing": return T("dictation.history.failed.no_model")
        case DictationHistory.interruptedReason: return T("dictation.history.failed.interrupted")
        default: return T("dictation.history.failed")
        }
    }

    func openSettings() { AppEnvironment.settings?.show(pane: "dictation") }
    func turnOn() { Dictation.shared.openSetup(from: "page") }
    /// How long a deleted dictation's recording waits for Undo.
    static let audioUndoSeconds = 120.0

    /// The one step in the way of a dictation, for the empty state and the header (DictationPageStatus): the speech
    /// model counts as much as the key's permission.
    @MainActor static func pageStatus(enabled: Bool, needsSetup: Bool) -> DictationPageStatus {
        let models = DictationModels.shared, dl = ModelDownloads.shared
        let download = models.dictationJob.flatMap { j in dl.queue.contains(j.id) ? dl.progress(j.id) ?? (0, j.sizeMB) : nil }
        return .of(enabled: enabled, needsSetup: needsSetup, modelReady: models.dictationReady, download: download)
    }

    // MARK: words for the views

    /// Why polish didn't run or wasn't kept, as a clause ("polish took too long"): the detail and the Lab put it in
    /// their sentence.
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
        Island.clock(s.rounded())          // one form wherever a take's length shows: the island's 0:05, 1:20
    }

    // MARK: app icons (the app a dictation went into)

    private static var icons: [String: NSImage?] = [:]
    /// The app's icon; Blurt's own for its own windows (any of its builds); nil for an app not on this Mac — the
    /// view draws a neutral tile with its initial then (DictationAppIcon), never the system's blank document, and
    /// never a gap: the list's names keep one left edge (v0.9 dogfood: rows without an icon jumped 28 pt left).
    static func icon(_ bundle: String?) -> NSImage? {
        guard let b = bundle, !b.isEmpty else { return nil }
        if let i = icons[b] { return i }
        let i: NSImage?
        if b == Bundle.main.bundleIdentifier || b.hasPrefix(DictationInsert.productionBundleID) {
            i = NSApp.applicationIconImage
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
            i = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            i = nil
        }
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
                    if t == .words { self.words.reload(); self.words.selectFirstIfNone() }
                    if self.visible { self.searchFollows(t) }
                    MainWindowController.shared.updateTitle()
                    self.syncDetailColumn()
                    emit(["event": "dictation_page", "tab": t.rawValue])
                }
            }
        }
        // the subtitle and the detail column follow what the tab shows: the search, the words, the cases
        countWatch = Publishers.Merge4(model.$query.map { _ in () }, model.$entries.map { _ in () },
                                       words.$mine.map { _ in () }, lab.$cases.map { _ in () })
            .merge(with: words.$projects.map { _ in () }, words.$builtIn.map { _ in () })
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self = self, self.visible else { return }
                        MainWindowController.shared.updateTitle()
                        self.syncDetailColumn()
                    }
                }
            }
    }
    private var countWatch: AnyCancellable?

    /// The window's subtitle while the page shows: one live count in one form, following the tab and the search —
    /// "9 dictations", "3 of 9 dictations", "26 words", "1 case". Headings never carry counts.
    var subtitle: String {
        switch model.tab {
        case .history: return model.subtitle
        case .words:
            let n = words.mine.count + words.projects.count + words.builtIn.count
            return n > 0 ? TP("main.dictation.words_count", n) : ""
        case .lab: return TP("main.dictation.cases_count", lab.cases.count)
        }
    }

    /// A search that found nothing (or no dictation at all) leaves no dictation to show: the detail column folds away,
    /// so the empty state stands alone in the middle of the window instead of beside a blank pane; it comes back with
    /// the first match.
    func syncDetailColumn() {
        let c = MainWindowController.shared
        guard c.split.splitViewItems.count > 2 else { return }
        let item = c.split.splitViewItems[2]
        let fold = visible && model.tab == .history && model.filtered.isEmpty
        guard item.isCollapsed != fold else { return }
        if fold {
            detailWidth = item.viewController.view.frame.width
            item.isCollapsed = true
        } else {
            item.isCollapsed = false
            // back at the width it had: unfolding alone hands it a sliver
            if let w = detailWidth, w > 0 {
                let sv = c.split.splitView
                sv.layoutSubtreeIfNeeded()
                sv.setPosition(sv.bounds.width - w - sv.dividerThickness, ofDividerAt: 1)
            }
        }
    }
    private var detailWidth: CGFloat?

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

    /// The toolbar's search field searches the history only: on Words (whose own field finds as it is typed) and the
    /// Lab it leaves the toolbar, so no field on the page searches something that isn't showing; back on History (or
    /// on leaving the page) the toolbar is the page's again (MainWindowController.syncToolbar puts it back).
    private func searchFollows(_ t: DictationHistoryModel.Tab) {
        let c = MainWindowController.shared
        guard let tb = c.window?.toolbar else { return }
        if t == .history || !visible {
            c.syncToolbar(dictation: visible)
            if visible, let f = c.searchItem?.searchField {
                f.placeholderString = T("dictation.history.search")
                if f.stringValue != model.query { f.stringValue = model.query }
            }
        } else if let i = tb.items.firstIndex(where: { $0.itemIdentifier == MainWindowController.searchID }) {
            tb.removeItem(at: i)
        }
    }

    func didShow() {
        visible = true
        searchFollows(model.tab)
        lab.visible = model.tab == .lab
        model.reload()
        model.selectFirstIfNone()
        words.reload()
        syncDetailColumn()
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
        syncDetailColumn()               // the items' detail is never folded away
        searchFollows(.history)          // the items' pages search with it
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

// MARK: - the views (the list column's header band)

/// The list column's one header band: History | Words (| Lab, when it is on) on the column's leading edge — the rows'
/// edge — as a native segmented control with a neutral selected segment (a view is where you are, not an action: never
/// a brand fill, system.md §3.3), and on the right the view's own few commands (the Lab's). Nothing else sits above the
/// list: today's numbers are on the Today heading, what stops dictation is the banner.
struct DictationPageHeader: View {
    @ObservedObject var m: DictationHistoryModel
    @ObservedObject var lab: DictationLabModel

    static let height: CGFloat = 44
    /// the rows' leading edge (List .inset), so the segments, the headings and the text share one line
    static let inset: CGFloat = 16

    var tabs: [(value: DictationHistoryModel.Tab, title: String)] {
        [(.history, T("dictation.lab.tab.history")), (.words, T("dictation.words.tab"))]
            + (DictationLabModel.enabled ? [(.lab, T("dictation.lab.tab.lab"))] : [])
    }

    var body: some View {
        HStack(spacing: 8) {
            NeutralSegments(items: tabs, selection: $m.tab, label: T("dictation.lab.tab.label"))
                .fixedSize()
            Spacer(minLength: 8)
            if m.tab == .lab { LabCommandBar(lab: lab) }
            if m.tab == .history && !m.entries.isEmpty {
                // the history's one command: send chosen dictations to the developers (DictationFeedback.swift)
                ViewThatFits(in: .horizontal) {
                    feedbackButton(titled: true)
                    feedbackButton(titled: false)
                }
            }
        }
        .padding(.leading, DictationPageHeader.inset).padding(.trailing, 10)
        .frame(height: DictationPageHeader.height)
        .onAppear { if m.tab == .lab && !DictationLabModel.enabled { m.tab = .history } }
        .sheet(isPresented: $m.feedbackOpen) {
            DictationFeedbackSheet(f: DictationFeedbackModel(entries: m.entries, selected: m.selection)) { m.feedbackOpen = false }
        }
    }

    func feedbackButton(titled: Bool) -> some View {
        LabBarButton(icon: .send, title: titled ? T("dictation.feedback.button") : nil, help: T("dictation.feedback.button.tip"), on: false) {
            m.feedbackOpen = true
            emit(["event": "dictation_feedback", "action": "open", "selected": m.selection.count])
        }
        .fixedSize()
        .accessibilityLabel(T("dictation.feedback.button"))
    }
}

/// The system's segmented control with a neutral selected segment (raised white in light mode, a lighter grey in dark),
/// not the accent fill: a view switch is not a primary action, and the list's mint wash stays the one coloured
/// selection on the page (system.md §1, §3.3). Text on it stays the label colour, never white on mint. Every segment
/// is as wide as the widest, so the control is the same shape in both languages.
struct NeutralSegments<V: Hashable>: NSViewRepresentable {
    let items: [(value: V, title: String)]
    @Binding var selection: V
    var small = false
    var label: String
    /// a segment that can't be picked now (the detail's views while a correction is being edited)
    var enabled = true

    final class Coordinator: NSObject {
        var pick: ((Int) -> Void)?
        @objc func changed(_ c: NSSegmentedControl) { pick?(c.selectedSegment) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    static var selectedFill: NSColor {
        NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.42, alpha: 1) : NSColor.white
        }
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let c = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: context.coordinator,
                                   action: #selector(Coordinator.changed(_:)))
        c.controlSize = small ? .small : .regular
        c.font = .systemFont(ofSize: NSFont.systemFontSize(for: c.controlSize))
        c.selectedSegmentBezelColor = Self.selectedFill
        c.setContentHuggingPriority(.required, for: .horizontal)
        c.setContentCompressionResistancePriority(.required, for: .horizontal)
        return c
    }

    func updateNSView(_ c: NSSegmentedControl, context: Context) {
        let items = self.items, sel = $selection
        context.coordinator.pick = { i in if items.indices.contains(i) { sel.wrappedValue = items[i].value } }
        let titles = items.map(\.title)
        if c.segmentCount != titles.count || titles.indices.contains(where: { c.label(forSegment: $0) != titles[$0] }) {
            c.segmentCount = titles.count
            let font = c.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            let widest = titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            let w = ceil(max(widest + (small ? 18 : 24), small ? 56 : 72))
            for (i, t) in titles.enumerated() { c.setLabel(t, forSegment: i); c.setWidth(w, forSegment: i) }
            c.invalidateIntrinsicContentSize()
        }
        c.selectedSegment = items.firstIndex { $0.value == selection } ?? -1
        if c.isEnabled != enabled { c.isEnabled = enabled }
        c.setAccessibilityLabel(label)
    }

    @available(macOS 13.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

struct DictationPageList: View {
    @ObservedObject var m: DictationHistoryModel
    @ObservedObject var lab: DictationLabModel
    @ObservedObject var words: DictationWordsModel
    var body: some View {
        VStack(spacing: 0) {
            DictationPageHeader(m: m, lab: lab)
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
    /// the AI is working on this row (Turn into Item): the static 1 pt `brand.working` hairline just inside the same
    /// rounded shape (system.md §3.3 "Job running"), selected or not — the work stays in sight when the selection moves
    var working = false
    @Environment(\.controlActiveState) private var active
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        ZStack {
            if on { shape.fill(active == .key ? Color.brandTint : Color.primary.opacity(0.06)) }
            if working { shape.strokeBorder(Color.brandWorking, lineWidth: BrandColor.workingWidth).transition(.opacity) }
        }
        .padding(.horizontal, 6).padding(.vertical, 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: working)
    }
}

// MARK: - small pieces

/// The app a dictation went into: its icon, or — for an app not on this Mac — a neutral tile with its initial (never
/// the blank document the system hands out for an unknown app: it read as a missing image).
struct DictationAppIcon: View {
    let bundle: String?
    let name: String
    var size: CGFloat = 16

    var body: some View {
        if let i = DictationHistoryModel.icon(bundle) {
            Image(nsImage: i).resizable().interpolation(.high).frame(width: size, height: size).accessibilityHidden(true)
        } else {
            let r = size * 0.24
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(Color.primary.opacity(0.09))
                .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .overlay(Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.56, weight: .semibold, design: .rounded)).foregroundStyle(.secondary))
                .frame(width: size, height: size)
                .padding(size * 0.06)          // an app icon's own margin, so tiles and icons look one size
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

/// The one chip of the page (a row's exception, the item a dictation became, the words it used): neutral, never a
/// status colour — "not polished" or "only copied" is a fact, not something that needs you.
struct DictationChip: View {
    let text: String
    var tip: String?
    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .help(tip ?? "")
            .accessibilityLabel(tip ?? text)
    }
}

/// One of our icons in a small borderless button (the detail's hover tools, the Side by Side toggle).
private struct IconButton: View {
    let symbol: String
    let tip: String
    var on = false
    var tint: Color?
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .regular))
                .foregroundStyle(tint ?? (on || hover ? Color.primary : Color.secondary))
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(on ? 0.1 : hover ? 0.06 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(tip)
        .accessibilityLabel(tip)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - the list

struct DictationListView: View {
    @ObservedObject var m: DictationHistoryModel
    @Environment(\.undoManager) private var undo

    var body: some View {
        VStack(spacing: 0) {
            if !m.entries.isEmpty { DictationStatusBanner(m: m) }      // the empty state says it itself
            if let e = m.error {
                Text(e).font(.system(size: 12)).foregroundStyle(Color.brandErr).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 6)
            }
            if m.entries.isEmpty {
                DictationEmptyView(m: m)
            } else if m.filtered.isEmpty {
                DictationNoResultsView(query: m.query) {
                    MainWindowController.shared.setDictationQuery("")
                    MainWindowController.shared.focusList()
                    emit(["event": "dictation_history", "action": "clear_search"])
                }
            } else {
                list
            }
        }
        .frame(minWidth: 320, minHeight: 300)
        .onAppear { m.reload() }
    }

    /// Today's numbers, on the Today heading's tooltip (the page's one count is the window's subtitle; headings carry
    /// none): dictations, words, and roughly the minutes it saved over typing.
    func todayTip(_ day: Date) -> String? {
        guard Calendar.current.isDateInToday(day) else { return nil }
        let s = m.today
        var parts = [TP("main.dictation.stat.count", s.count), TP("main.dictation.stat.words", s.words)]
        if s.savedMinutes >= 1 { parts.append(T("main.dictation.stat.saved", s.savedMinutes)) }
        return parts.joined(separator: " · ") + (s.savedMinutes >= 1 ? "\n" + T("main.dictation.stat.saved.tip") : "")
    }

    /// Days as quiet headings (no rule under them, no counts), rows without separators: the spacing groups them, as in
    /// "Recently Dragged Out"; the selection is the brand wash.
    var list: some View {
        List(selection: $m.selection) {
            ForEach(Array(m.days.enumerated()), id: \.element.day) { n, group in
                // the day as a plain, untagged (so never selectable) row: a section header would bring the table's
                // own rule under it, a second line over every group
                DayHeading(title: DictationHistoryModel.dayTitle(group.day), first: n == 0, tip: todayTip(group.day))
                ForEach(group.rows) { e in
                    DictationRow(m: m, e: e).tag(e.id)
                        .listRowBackground(RowWash(on: m.selection.contains(e.id), working: m.working.contains(e.id)))
                        .listRowSeparator(.hidden)
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
            if es.count == 1, let e = es.first {
                DictationEntryMenu(m: m, e: e, withItem: true)
            } else if !es.isEmpty {
                Button(T("main.dictation.copy_all")) { m.copy(es.map(\.finalText).joined(separator: "\n\n")) }
                Divider()
                Button(T("dictation.history.delete"), role: .destructive) { m.delete(es, undo: undo) }
            }
        }
    }
}

/// A day over its dictations: secondary semibold, no rule, no count; 18 pt above it between days (4 above the first).
/// Today's numbers are its tooltip.
private struct DayHeading: View {
    let title: String
    let first: Bool
    var tip: String? = nil
    var body: some View {
        let t = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .help(tip ?? "")
            Spacer(minLength: 8)
        }
        .padding(.top, first ? 4 : 18).padding(.bottom, 2)
        .listRowSeparator(.hidden)
        if #available(macOS 14.0, *) { t.selectionDisabled() } else { t }
    }
}

/// A search that found nothing: the shared empty state (the app's mark, system.md §3.5 "no results"), the query said
/// back (cut in the middle when long), where search looks, and one plain way out — never brand, never ↩. The detail
/// column folds away meanwhile (DictationPage.syncDetailColumn), so this stands alone in the window.
struct DictationNoResultsView: View {
    let query: String
    let clear: () -> Void

    var body: some View {
        EmptyStateContent(title: T("dictation.history.no_match", Self.shortQuery(query)), message: T("dictation.history.no_match.hint")) {
            Button(T("dictation.history.clear_search"), action: clear).controlSize(.regular)
        }
        .padding(.bottom, DictationPageHeader.height)      // the window's middle, not the column's under the header
        .accessibilityElement(children: .contain)
    }

    /// The query as typed, trimmed; past 16 characters, its start and end around an ellipsis (the title stays one line).
    static func shortQuery(_ q: String) -> String {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > 16 else { return t }
        return String(t.prefix(8)) + "…" + String(t.suffix(7))
    }
}

/// What stands between the user and a dictation, above the list, read before anything else: no speech model (the
/// warn dot, what it means, Download as the view's one primary), the model coming down, the key not heard yet, or
/// dictation off. Nothing while it is ready.
struct DictationStatusBanner: View {
    @ObservedObject var m: DictationHistoryModel
    /// it follows the models and their download
    @ObservedObject var models = DictationModels.shared
    @ObservedObject var downloads = ModelDownloads.shared

    var body: some View {
        let status = DictationHistoryModel.pageStatus(enabled: m.enabled, needsSetup: m.needsSetup)
        if status != .ready {
            HStack(alignment: .center, spacing: 10) {
                mark(status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(status)).font(.system(size: 12.5, weight: .semibold))
                    if let d = detail(status) {
                        Text(d).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if case let .downloading(done, total) = status {
                        ProgressView(value: min(done, total), total: max(total, 1)).controlSize(.small).frame(maxWidth: 220)
                            .tint(Color.brandInk)
                            .padding(.top, 3)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                action(status)
            }
            // the card on the rows' wash edge, its text on the rows' text edge
            .padding(.horizontal, DictationPageHeader.inset - 6).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            .padding(.horizontal, 6).padding(.top, 2).padding(.bottom, 4)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder func mark(_ s: DictationPageStatus) -> some View {
        switch s {
        case .off: StatusDot(tone: .off)
        case .downloading: BrandSpinnerView()
        default: StatusDot(tone: .warn)
        }
    }

    func title(_ s: DictationPageStatus) -> String {
        switch s {
        case .off: return T("main.dictation.off")
        case .needsPermission: return T("main.dictation.banner.permission")
        case .noModel: return T("main.dictation.banner.no_model")
        case .downloading: return T("main.dictation.banner.downloading")
        case .ready: return ""
        }
    }

    func detail(_ s: DictationPageStatus) -> String? {
        switch s {
        case .off: return T("main.dictation.off.detail")
        case .needsPermission: return T("dictation.menu.turn_on.tip", Dictation.keyInline)
        case .noModel:
            return models.dictationJob.map { T("main.dictation.banner.no_model.detail", modelSize($0.sizeMB)) }
                ?? T("main.dictation.banner.no_model.detail_plain")
        case let .downloading(done, total): return T("main.dictation.banner.downloading.detail", modelSize(done), modelSize(total))
        case .ready: return nil
        }
    }

    @ViewBuilder func action(_ s: DictationPageStatus) -> some View {
        switch s {
        case .off:
            Button(T("main.dictation.settings")) { m.openSettings() }
        case .needsPermission:
            Button(T("dictation.menu.turn_on")) { m.turnOn() }.buttonStyle(.brand)
        case .noModel:
            if models.dictationJob != nil {
                Button(T("main.dictation.banner.download")) { Dictation.getSpeechModel(from: "page") }.buttonStyle(.brand)
            } else {
                Button(T("dictation.toast.no_model.settings")) { SpeechPane.showDictationModels() }
            }
        case .downloading:
            Button(T("dictation.toast.model_downloading.action")) { ModelDownloads.showProgress() }
        case .ready:
            EmptyView()
        }
    }
}

/// A row: the app it went into, one quiet chip when it didn't simply go in polished (the same words as the detail's
/// line: "Copied · as spoken"), the item it became as a link on the trailing side, and its time — always there, also
/// while the AI writes an item from it (the row's working hairline says that; the spinner is the detail's button's).
/// Then the text as typed, one paragraph, two lines at most, the search's words in semibold.
struct DictationRow: View {
    @ObservedObject var m: DictationHistoryModel
    let e: DictationEntry

    var body: some View {
        let app = AppNames.display(name: e.app, bundle: e.bundle) ?? T("main.dictation.unknown_app")
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                DictationAppIcon(bundle: e.bundle, name: app, size: 16)
                Text(DictationRow.marked(app, m.queryTerms)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1)
                if let x = DictationHistoryModel.exception(e) { DictationChip(text: x.chip, tip: x.line) }
                Spacer(minLength: 8)
                if let it = e.item, !it.isEmpty { ItemLink(key: it, uid: e.itemUID) }
                Text(DictationHistoryModel.time(e.time)).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize()
            }
            if e.text.isEmpty, (e.reason ?? "").hasPrefix("asr_failed") {
                Text(DictationHistoryModel.failedText(e)).font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(DictationRow.marked(DictationEntry.preview(e.finalText), m.queryTerms))
                    .font(.system(size: 13)).lineLimit(2).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityValue(m.working.contains(e.id) ? T("dictation.history.making_item") : "")
    }

    /// The text with every occurrence of the search's words in semibold (Settings' search does the same; never brand).
    static func marked(_ s: String, _ terms: [String]) -> AttributedString {
        var out = AttributedString(s)
        guard !terms.isEmpty else { return out }
        let ns = s as NSString
        for t in terms {
            var r = NSRange(location: 0, length: ns.length)
            while true {
                let f = ns.range(of: t, options: [.caseInsensitive, .diacriticInsensitive], range: r)
                guard f.location != NSNotFound, f.length > 0 else { break }
                if let rr = Range(f, in: s), let a = Range(rr, in: out) {
                    out[a].inlinePresentationIntent = .stronglyEmphasized
                    out[a].foregroundColor = Color.primary
                }
                let next = f.location + f.length
                r = NSRange(location: next, length: ns.length - next)
            }
        }
        return out
    }
}

/// The item a dictation became, on the row's trailing side: its key as a link (it opens the item), never a status chip.
private struct ItemLink: View {
    let key: String
    let uid: String?
    @State private var hover = false
    var body: some View {
        Button { if let u = uid { AppEnvironment.mainWindow?.reveal(uid: u) } } label: {
            HStack(spacing: 2) {
                Text(key).font(.system(size: 11, weight: .medium, design: .monospaced))
                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(hover ? Color.primary : Color.secondary)
            .underline(hover, color: Color.brandInk)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(T("main.dictation.show_item", key))
        .accessibilityLabel(T("main.dictation.show_item", key))
    }
}

/// Everything that can be done with one dictation: the detail's "⋯" and the row's right-click (with Turn into Item,
/// which the detail shows as its button).
struct DictationEntryMenu: View {
    @ObservedObject var m: DictationHistoryModel
    let e: DictationEntry
    var withItem = false
    @Environment(\.undoManager) private var undo

    var body: some View {
        let failed = e.text.isEmpty && (e.reason ?? "").hasPrefix("asr_failed")
        Button(T("dictation.history.copy")) { m.copy(e.finalText, from: "detail-text") }.disabled(failed)
        if DictationHistoryModel.differs(e) { Button(T("dictation.history.copy_raw")) { m.copy(e.raw, from: "detail-raw") } }
        if !failed { Button(T("main.dictation.correct")) { m.select(e.id); m.beginEdit(e) } }
        Divider()
        if withItem {
            if let it = e.item, let uid = e.itemUID {
                Button(T("main.dictation.show_item", it)) { AppEnvironment.mainWindow?.reveal(uid: uid) }
            } else {
                Button(T("dictation.history.make_item")) { m.makeItem(e) }.disabled(failed || m.working.contains(e.id))
            }
        }
        if DictationLabModel.enabled { Button(T("dictation.lab.add")) { m.addToLab?(e) } }
        if let a = e.audio, FileManager.default.fileExists(atPath: DictationHistory.shared.resolve(a).path) {
            Button(T("main.dictation.reveal_audio")) {
                NSWorkspace.shared.activateFileViewerSelecting([DictationHistory.shared.resolve(a)])
            }
        }
        Button(T("main.dictation.settings")) { m.openSettings() }
        Divider()
        Button(T("dictation.history.delete"), role: .destructive) { m.delete([e], undo: undo) }
    }
}

/// Nothing dictated yet: how to, and what stands in the way if anything does — the one blocking step
/// (DictationPageStatus: off, the key's permission, the speech model), with its button.
struct DictationEmptyView: View {
    @ObservedObject var m: DictationHistoryModel
    @ObservedObject var models = DictationModels.shared
    @ObservedObject var downloads = ModelDownloads.shared

    var body: some View {
        EmptyStateContent(title: T("dictation.history.empty.title"), message: T("dictation.history.empty.body", Dictation.keyInline)) {
            status
        }
        .onAppear { models.loadIfNeeded() }
    }

    @ViewBuilder var status: some View {
        switch DictationHistoryModel.pageStatus(enabled: m.enabled, needsSetup: m.needsSetup) {
        case .off:
            VStack(spacing: 8) {
                pill(T("main.dictation.off"), .off)
                Button(T("main.dictation.settings")) { m.openSettings() }.controlSize(.regular)
            }
        case .needsPermission:
            VStack(spacing: 8) {
                pill(T("dictation.menu.turn_on.tip", Dictation.keyInline), .warn)
                // the one thing standing in the way: this view's primary
                Button(T("dictation.menu.turn_on")) { m.turnOn() }.buttonStyle(.brand).keyboardShortcut(.defaultAction)
            }
        case .noModel:
            VStack(spacing: 8) {
                if let j = models.dictationJob {
                    pill(T("dictation.toast.no_model"), .warn)
                    Button(T("dictation.toast.no_model.action_size", modelSize(j.sizeMB))) { Dictation.getSpeechModel(from: "page") }
                        .buttonStyle(.brand).keyboardShortcut(.defaultAction)
                } else {
                    // what is missing can't be fetched from here: the models' page
                    pill(T("dictation.toast.no_model_plain"), .warn)
                    Button(T("dictation.toast.no_model.settings")) { SpeechPane.showDictationModels() }.controlSize(.regular)
                }
            }
        case .downloading(let done, let total):
            VStack(spacing: 8) {
                pill(T("dictation.toast.model_downloading", modelSize(done), modelSize(total)), nil)
                ProgressView(value: min(done, total), total: max(total, 1)).frame(width: 220).tint(Color.brandInk)
                Button(T("dictation.toast.model_downloading.action")) { ModelDownloads.showProgress() }.controlSize(.regular)
            }
        case .ready:
            pill(T("main.dictation.ready"), .good)
        }
    }

    /// A status line in a pill, led by its status dot (each tone its own shape: warn "!", good ✓, off a ring).
    func pill(_ s: String, _ tone: Tone?) -> some View {
        HStack(spacing: 6) {
            if let t = tone { StatusDot(tone: t) }
            Text(s).font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
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
    /// its height: the text plus one line (it measures itself as the text and the width change)
    @Binding var height: CGFloat

    /// the reading block's size and spacing, so the text doesn't move when the editor opens in its place
    static let font = NSFont.systemFont(ofSize: DictationTextBlock.size)
    static let lineSpacing: CGFloat = 4
    static let maxHeight: CGFloat = 320
    static var attributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineSpacing
        return [.font: font, .paragraphStyle: p, .foregroundColor: NSColor.labelColor]
    }
    /// one line of text as the view lays it out
    static var lineHeight: CGFloat { NSLayoutManager().defaultLineHeight(for: font) + lineSpacing }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let tv = scroll.documentView as! NSTextView   // swiftlint:disable:this force_cast
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.defaultParagraphStyle = CorrectionEditor.attributes[.paragraphStyle] as? NSParagraphStyle
        tv.typingAttributes = CorrectionEditor.attributes
        tv.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: CorrectionEditor.attributes))
        tv.delegate = context.coordinator
        // the width follows the pane: the lines (and so the height) follow the width
        tv.postsFrameChangedNotifications = true
        context.coordinator.watch(tv)
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            context.coordinator.measure(tv)
            emit(["event": "dictation_history", "action": "editor_focus", "focused": tv.window?.firstResponder === tv])
        }
        return scroll
    }

    func updateNSView(_ v: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = v.documentView as? NSTextView, tv.string != text else { return }
        tv.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: CorrectionEditor.attributes))
        context.coordinator.measure(tv)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CorrectionEditor
        private var observer: NSObjectProtocol?
        init(_ p: CorrectionEditor) { parent = p }
        deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

        func watch(_ tv: NSTextView) {
            observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: tv, queue: .main) {
                [weak self, weak tv] _ in
                guard let tv = tv else { return }
                MainActor.assumeIsolated { self?.measure(tv) }
            }
        }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            MainActor.assumeIsolated { measure(tv) }
        }

        @MainActor func measure(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let line = CorrectionEditor.lineHeight
            let h = min(CorrectionEditor.maxHeight, ceil(max(lm.usedRect(for: tc).height, line) + line))
            guard abs(parent.height - h) > 0.5 else { return }
            let binding = parent.$height
            DispatchQueue.main.async { binding.wrappedValue = h }
        }
    }
}

// MARK: - what changed

/// What polish (and a correction) changed between what was heard and what was typed, for the Changes view: one text,
/// in runs kept / removed / added. Words are the unit (a CJK character is one, so is a punctuation mark or a run of
/// spaces); the edits are slid onto word edges where they can be (as diff-match-patch's lossless cleanup), so
/// "嗯 那个 我们周三 不对 周四" → "我们周四" strikes 嗯 那个 and 周三 不对 whole, not 三 不对 周; a change of case only
/// ("pr" → "PR") shows the new spelling as added, not both.
enum DictationChanges {
    /// `recased`: only while aligning — a word whose case changed, kept in its place (it is shown as added).
    enum Op: Equatable { case same, removed, added, recased }
    struct Run: Equatable {
        var op: Op
        var text: String
    }

    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = "", kind = 0          // 1 a word, 2 spaces
        func flush() { if !cur.isEmpty { out.append(cur) }; cur = ""; kind = 0 }
        for ch in s {
            if ch.isWhitespace {
                if kind != 2 { flush(); kind = 2 }
                cur.append(ch)
            } else if let u = ch.unicodeScalars.first, DictationStats.isCJK(u) {
                flush(); out.append(String(ch))
            } else if ch.isLetter || ch.isNumber || ch == "'" || ch == "’" || ch == "_" {
                if kind != 1 { flush(); kind = 1 }
                cur.append(ch)
            } else {
                flush(); out.append(String(ch))
            }
        }
        flush()
        return out
    }

    /// heard → typed, as runs (adjacent runs never share an op; within a change, what went comes before what came).
    static func runs(heard: String, typed: String) -> [Run] {
        let a = tokens(heard), b = tokens(typed)
        // aligned ignoring case, so "hi anna" → "Hi Anna" lines up word for word; a word whose case changed is shown
        // in its new spelling as added
        let ka = a.map { $0.lowercased() }, kb = b.map { $0.lowercased() }
        var ops: [(Op, [String])] = []
        func push(_ op: Op, _ t: String) {
            if let l = ops.last, l.0 == op { ops[ops.count - 1].1.append(t) } else { ops.append((op, [t])) }
        }
        let n = a.count, m = b.count
        if n * m > 2_000_000 {          // too long to align here: all of it went, all of it came
            ops = [(Op.removed, a), (Op.added, b)].filter { !$0.1.isEmpty }
        } else {
            var l = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
            if n > 0 && m > 0 {
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        l[i][j] = ka[i] == kb[j] ? l[i + 1][j + 1] + 1 : max(l[i + 1][j], l[i][j + 1])
                    }
                }
            }
            var i = 0, j = 0
            while i < n || j < m {
                if i < n, j < m, ka[i] == kb[j] { push(a[i] == b[j] ? .same : .recased, b[j]); i += 1; j += 1 }
                else if j >= m || (i < n && l[i + 1][j] >= l[i][j + 1]) { push(.removed, a[i]); i += 1 }
                else { push(.added, b[j]); j += 1 }
            }
        }
        ops = slide(normalise(ops))
        var out: [Run] = []
        var k = 0
        while k < ops.count {
            let (op, ts) = ops[k]
            // "pr" → "PR": the new spelling, once
            if op == .removed, k + 1 < ops.count, ops[k + 1].0 == .added,
               ts.joined().lowercased() == ops[k + 1].1.joined().lowercased() {
                out.append(Run(op: .added, text: ops[k + 1].1.joined()))
                k += 2
                continue
            }
            out.append(Run(op: op == .recased ? .added : op, text: ts.joined()))
            k += 1
        }
        // the case fold can leave two added runs side by side
        var merged: [Run] = []
        for r in out {
            if let l = merged.last, l.op == r.op { merged[merged.count - 1].text += r.text } else { merged.append(r) }
        }
        return merged
    }

    /// Between two kept runs: one removed run, then one added run.
    static func normalise(_ ops: [(Op, [String])]) -> [(Op, [String])] {
        var out: [(Op, [String])] = []
        var del: [String] = [], ins: [String] = []
        func close() {
            if !del.isEmpty { out.append((.removed, del)) }
            if !ins.isEmpty { out.append((.added, ins)) }
            del = []; ins = []
        }
        for (op, ts) in ops {
            switch op {
            case .removed: del += ts
            case .added: ins += ts
            case .same, .recased:
                close()
                if let l = out.last, l.0 == op { out[out.count - 1].1 += ts } else { out.append((op, ts)) }
            }
        }
        close()
        return out
    }

    /// A lone removal or addition between two kept runs slides to where its edges are word edges (spaces best, then
    /// punctuation); the text either way is the same.
    static func slide(_ input: [(Op, [String])]) -> [(Op, [String])] {
        var ops = input
        var k = 1
        while k + 1 < ops.count {
            guard ops[k - 1].0 == .same, ops[k + 1].0 == .same, ops[k].0 != .same else { k += 1; continue }
            var a = ops[k - 1].1, b = ops[k].1, c = ops[k + 1].1
            while let x = a.last, let y = b.last, x == y { a.removeLast(); b.removeLast(); b.insert(x, at: 0); c.insert(y, at: 0) }
            var best = (a, b, c), bestScore = score(a.last, b.first) + score(b.last, c.first)
            while let x = b.first, let y = c.first, x == y {
                a.append(x); b.removeFirst(); b.append(c.removeFirst())
                let s = score(a.last, b.first) + score(b.last, c.first)
                if s >= bestScore { best = (a, b, c); bestScore = s }
            }
            ops[k - 1].1 = best.0; ops[k].1 = best.1; ops[k + 1].1 = best.2
            if ops[k - 1].1.isEmpty { ops.remove(at: k - 1); continue }
            if ops[k + 1].1.isEmpty { ops.remove(at: k + 1) }
            k += 1
        }
        return ops
    }

    /// How good an edge between two words is for a change to start or end on.
    static func score(_ left: String?, _ right: String?) -> Int {
        guard let l = left, let r = right else { return 3 }          // the text's own edge
        if l.allSatisfy(\.isWhitespace) || r.allSatisfy(\.isWhitespace) { return 2 }
        if isMark(l) || isMark(r) { return 1 }
        return 0
    }

    static func isMark(_ t: String) -> Bool {
        guard t.count == 1, let c = t.first else { return false }
        return !(c.isLetter || c.isNumber || c.isWhitespace)
    }

    /// The runs as one text: removed words struck through in `err`, added ones underlined in `attn` (a line, not a
    /// fill: a fill on one full-width "，" read as a rendering glitch, and went muddy in dark mode); spaces at a
    /// change's edges stay plain, a change that is only spaces is left out, and one that is only punctuation reads as
    /// the typed text (a comma polish put in is not news).
    static func attributed(_ runs: [Run]) -> AttributedString {
        var out = AttributedString()
        var last: Character?
        func plain(_ s: String) {
            guard !s.isEmpty else { return }
            out += AttributedString(s)
            last = s.last
        }
        for r in runs {
            let core = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.op == .same || core.isEmpty || isPunctuation(core) {
                if r.op != .removed { plain(r.text) }
                continue
            }
            let lead = String(r.text.prefix { $0.isWhitespace })
            let trail = String(r.text.reversed().prefix { $0.isWhitespace }.reversed())
            if let l = last, !l.isWhitespace { plain(lead) }
            out += mark(core, removed: r.op == .removed)
            last = core.last
            plain(trail)
        }
        return out
    }

    /// One changed word as the Changes view, the correction's line and the Lab draw it.
    static func mark(_ s: String, removed: Bool) -> AttributedString {
        var a = AttributedString(s)
        if removed {
            a.strikethroughStyle = Text.LineStyle(pattern: .solid, color: Color.brandErr)
            a.foregroundColor = Color.brandErr
        } else {
            a.underlineStyle = Text.LineStyle(pattern: .solid, color: Color.brandAttn)      // a diff is not brand
        }
        return a
    }

    /// Only punctuation and symbols (，。！? "…").
    static func isPunctuation(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { !($0.isLetter || $0.isNumber) }
    }
}

// MARK: - the detail

/// One dictation: one header band level with the list's views (the app, when and how long; the text's views on the
/// right), the text itself at reading size — no card around it, so it wraps at the pane's width — with Copy and Correct
/// on hover, one primary (Turn into Item, the AI writing it shown inside the same button) and a "⋯" for the rest, and
/// the facts behind a closed "Details". Correcting the text happens in place and owns the pane while it lasts.
struct DictationDetailView: View {
    @ObservedObject var m: DictationHistoryModel
    /// the models' names (the history keeps their ids), and whether a missing model takes the view's one primary
    @ObservedObject var models = DictationModels.shared
    @ObservedObject var downloads = ModelDownloads.shared
    @Environment(\.undoManager) private var undo
    /// the correction editor's height: its text plus one line (CorrectionEditor measures it)
    @State private var editorHeight: CGFloat = 2 * CorrectionEditor.lineHeight
    /// the editor's focus ring shows while the window is key, as the system's own
    @Environment(\.controlActiveState) private var active

    static let inset: CGFloat = 28

    var body: some View {
        Group {
            if let e = m.current {
                one(e)
            } else if m.selection.count > 1 {
                several(m.selected)
            } else if m.entries.isEmpty || m.filtered.isEmpty {
                // the list column's empty state (or a search that found nothing) says it once
                Color.clear
            } else {
                placeholder
            }
        }
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Nothing selected: what to do, and the list's keys on a line of their own (they never wrap into the sentence).
    var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.alignleft").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                .accessibilityHidden(true).padding(.bottom, 4)
            Text(T("main.dictation.none")).font(.system(size: 15, weight: .semibold))
            Text(T("main.dictation.none.detail")).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 300).fixedSize(horizontal: false, vertical: true)
            Text(T("main.dictation.none.keys")).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1).padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Several selected: the items' SelectionView grammar (system.md) — top-aligned at the detail's inset, the count,
    /// one primary (Copy All), the rest in ⋯ (Delete; ⌫ still works), then the takes on a quiet card.
    func several(_ es: [DictationEntry]) -> some View {
        let shown = es.prefix(8)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(TP("main.dictation.multi", es.count)).font(.system(size: 17, weight: .semibold))
                HStack(spacing: 10) {
                    Button(T("main.dictation.copy_all")) { m.copySelection() }.buttonStyle(.brand)
                    Menu {
                        Button(T("dictation.history.delete"), role: .destructive) { m.delete(es, undo: undo) }
                    } label: {
                        glyph(.more, 13).accessibilityLabel(T("dictation.history.more"))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(.secondary)
                    .help(T("dictation.history.more"))
                    .accessibilityLabel(T("dictation.history.more"))
                    Spacer(minLength: 0)
                }
                .controlSize(.regular)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(shown)) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(DictationHistoryModel.time(e.time)).font(.system(size: 11.5)).monospacedDigit()
                                .foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                            Text(DictationEntry.preview(e.finalText)).font(.system(size: 13)).lineLimit(1)
                        }
                    }
                    if es.count > shown.count {
                        Text(T("main.dictation.multi.more", es.count - shown.count)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
            }
            .padding(.horizontal, DictationDetailView.inset).padding(.top, 24).padding(.bottom, 28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func isFailed(_ e: DictationEntry) -> Bool { e.text.isEmpty && (e.reason ?? "").hasPrefix("asr_failed") }

    func one(_ e: DictationEntry) -> some View {
        let differs = DictationHistoryModel.differs(e)
        let editing = m.editing == e.id
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(e, differs: differs, editing: editing)
                    .frame(height: DictationPageHeader.height)
                    .padding(.bottom, 14)
                if DictationDetailView.isFailed(e) {
                    failed(e)
                } else {
                    texts(e, differs: differs)
                }
                if let line = DictationHistoryModel.exception(e)?.line ?? DictationHistoryModel.partsLine(e), !editing {
                    // how it went in, in the row chip's words with the reason: a fact, in secondary (never attention)
                    Text(line).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
                if !editing {
                    actions(e).padding(.top, 22)
                    info(e).padding(.top, 26)
                }
            }
            .padding(.horizontal, DictationDetailView.inset).padding(.bottom, 28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The app and when (the one place they are said), and the text's views — off while a correction is open.
    func header(_ e: DictationEntry, differs: Bool, editing: Bool) -> some View {
        let app = AppNames.display(name: e.app, bundle: e.bundle) ?? T("main.dictation.unknown_app")
        let time = DictationHistoryModel.time(e.time), length = DictationHistoryModel.duration(e.duration)
        let fixed = e.corrected != nil ? " · " + T("main.dictation.corrected") : ""
        // narrower and narrower: the day goes first (the list's section says it), then the length; the time and
        // length never end in "…" — the app's name gives way instead
        let whens = ["\(DictationHistoryModel.dayTitle(e.time)) \(time) · \(length)\(fixed)", "\(time) · \(length)\(fixed)", time]
        return HStack(alignment: .center, spacing: 8) {
            // the app as the list draws it, one size up: a label for the text below, not the pane's loudest object
            DictationAppIcon(bundle: e.bundle, name: app, size: 18)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(app).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    .frame(minWidth: 56, alignment: .leading)
                ViewThatFits(in: .horizontal) {
                    when(whens[0])
                    when(whens[1])
                    when(whens[2])
                }
                .layoutPriority(2)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            if differs, !DictationDetailView.isFailed(e) {
                NeutralSegments(items: [(DictationHistoryModel.Mode.polished, T("main.dictation.mode.polished")),
                                        (.raw, T("main.dictation.mode.raw")), (.compare, T("main.dictation.mode.compare"))],
                                selection: $m.mode, small: true, label: T("main.dictation.mode.label"), enabled: !editing)
                    .fixedSize()
            }
        }
    }

    private func when(_ s: String) -> some View {
        Text(s).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
    }

    @ViewBuilder func texts(_ e: DictationEntry, differs: Bool) -> some View {
        if m.editing == e.id {
            editor(e)
        } else if differs && m.mode == .compare {
            changes(e)
        } else if differs && m.mode == .raw {
            DictationTextBlock(m: m, text: e.raw, copyID: "detail-raw")
        } else {
            DictationTextBlock(m: m, text: e.finalText, copyID: differs ? "detail-polished" : "detail-text", edit: e)
        }
        // reformat-last replaced it in the field: the text above is what is there now; the first version under it
        if let first = e.typedFirst, first != e.text, m.mode == .polished || !differs, m.editing != e.id {
            VStack(alignment: .leading, spacing: 6) {
                caption(T("main.dictation.before_reformat"))
                DictationTextBlock(m: m, text: first, size: 14, secondary: true, copyID: "detail-first")
            }
            .padding(.top, 16)
        }
        if let n = m.savedNote, n.id == e.id { savedNote(n).padding(.top, 12) }
    }

    /// What polish changed, in one text that reads at the pane's width: the words it left out struck through, the
    /// words it added or re-spelled underlined (punctuation alone is not a change worth marking), and a one-line key
    /// in plain words under it.
    func changes(_ e: DictationEntry) -> some View {
        let runs = DictationChanges.runs(heard: e.raw, typed: e.finalText)
        return VStack(alignment: .leading, spacing: 10) {
            Text(DictationChanges.attributed(runs))
                .font(.system(size: DictationTextBlock.size)).lineSpacing(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            Text(T("main.dictation.changes.key")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(T("main.dictation.mode.compare"))
        .accessibilityValue(e.finalText)
    }

    func caption(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
    }

    /// A take the speech model couldn't recognise: what failed, and Retry while its recording is there.
    func failed(_ e: DictationEntry) -> some View {
        HStack(alignment: .center, spacing: 8) {
            StatusDot(tone: .warn)
            Text(DictationHistoryModel.failedText(e)).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if e.reason == "asr_failed:model_missing" {
                Button(T("dictation.toast.no_model.action")) { Dictation.getSpeechModel(from: "page") }     // starts it in the download manager
            }
            if DictationHistoryModel.canRetry(e) {
                Button(T("dictation.history.retry")) { m.retry(e) }.keyboardShortcut("r", modifiers: .command)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    /// After Save Correction: saved, and the words it found — new ones to add with one click (then Undo), known ones.
    @ViewBuilder func savedNote(_ n: DictationHistoryModel.SavedNote) -> some View {
        let sep = T("main.dictation.correct.sep")
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            glyph(.check, 13).foregroundStyle(Color.brandOk)
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

    /// Correcting the text in place: the editor where the text was (the same size and edge, so nothing jumps), with the
    /// system's focus ring; under it what saving will teach Blurt, Cancel (Esc) and Save (⌘↩) as the moment's one
    /// primary. The views above are off and the actions and details step aside until it is saved or cancelled.
    func editor(_ e: DictationEntry) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            CorrectionEditor(text: $m.draft, height: $editorHeight)
                .frame(height: editorHeight)
                .padding(.horizontal, 10).padding(.vertical, 8)
                // a field a step off the pane in both modes (the text background went near-black in dark mode)
                .background(shape.fill(Color.primary.opacity(0.045)))
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                // the system's focus ring (AccentColor), just outside the field, as round any focused text field
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3).padding(-3)
                            .opacity(active == .key ? 1 : 0))
                .padding(.horizontal, -10)      // the text keeps the column's edge, as the reading block's
                .accessibilityLabel(T("main.dictation.correct.title"))
            // what saving will teach, on its own line under the field (only where it fits on one)
            ViewThatFits(in: .horizontal) {
                learnLine(e)
                Color.clear.frame(width: 0, height: 0)
            }
            .padding(.top, 2)
            HStack(spacing: 10) {
                Button(T("main.dictation.correct.save")) { m.saveCorrection(e, m.draft) }
                    .buttonStyle(.brand)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(m.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(T("main.dictation.correct.save.tip"))
                Button(T("main.dictation.correct.cancel")) { m.cancelEdit() }
                    .keyboardShortcut(.cancelAction)
                    .help(T("main.dictation.correct.cancel.tip"))
                Text(T("main.dictation.correct.hint")).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.leading, 4)
                Spacer(minLength: 0)
            }
            .controlSize(.regular)
            .padding(.top, 12)
        }
    }

    /// What saving this correction will teach Blurt, as it is typed: before any change, that it learns the names
    /// fixed; after one, the words it found (what was heard struck through, the fix tinted, as in the Lab) — or that
    /// it found none (a rewrite saves the text only).
    @ViewBuilder func learnLine(_ e: DictationEntry) -> some View {
        let typed = e.finalText
        let draft = m.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = draft != typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let fixes = changed ? DictationLearn.fixes(typed: typed, edited: draft, isCommonWord: DictationLearn.isCommonWord) : []
        Group {
            if !changed {
                Text(T("main.dictation.correct.caption"))
            } else if fixes.isEmpty {
                Text(T("main.dictation.correct.caption.none"))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(T("main.dictation.correct.caption.found"))
                    ForEach(Array(fixes.prefix(3).enumerated()), id: \.offset) { _, f in
                        Text(DictationChanges.mark(f.heard, removed: true) + AttributedString(" ")
                             + DictationChanges.mark(f.fixed, removed: false))
                            .foregroundStyle(.primary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(T("main.dictation.correct.caption.found") + " "
                                    + fixes.map(\.fixed).joined(separator: T("main.dictation.correct.sep")))
            }
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .lineLimit(1).fixedSize()
    }

    /// The missing speech model's banner holds the view's one primary while it shows; otherwise Turn into Item is it.
    var bannerHasPrimary: Bool {
        switch DictationHistoryModel.pageStatus(enabled: m.enabled, needsSetup: m.needsSetup) {
        case .needsPermission: return true
        case .noModel: return models.dictationJob != nil
        default: return false
        }
    }

    /// One primary and one ⋯ menu. "Turn into Item" (⌘↩) is the pane's brand primary; while the AI writes the item
    /// the same button — the same width, nothing beside it moves — reads "Writing Item…" with the spinner, on the
    /// primary's neutral fill. Once made, it is a plain "Show Item BA-43". The rest — Correct, the copies, Add to Lab
    /// and Delete (also ⌫ and the list's context menu) — is in the ⋯ menu.
    func actions(_ e: DictationEntry) -> some View {
        let busy = m.working.contains(e.id)
        let failed = DictationDetailView.isFailed(e)
        return HStack(spacing: 10) {
            if let it = e.item, let uid = e.itemUID {
                Button(T("main.dictation.show_item", it)) { AppEnvironment.mainWindow?.reveal(uid: uid) }
            } else if !failed {
                makeItemButton(e, busy: busy)
            }
            Menu {
                DictationEntryMenu(m: m, e: e)
            } label: {
                // the glyph's own description is the English symbol name: the menu says its name in the app's language
                glyph(.more, 13).accessibilityLabel(T("dictation.history.more"))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(.secondary)
            .help(T("dictation.history.more"))
            .accessibilityLabel(T("dictation.history.more"))
            Spacer(minLength: 0)
        }
        .controlSize(.regular)
        .frame(minHeight: 24)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: busy)
    }

    /// Both titles are laid out, one of them hidden, so the control is as wide as the wider of the two and keeps that
    /// width when it turns busy. Busy, it is the primary's neutral fill (system.md §3.3: no gradient) drawn at the
    /// button's own metrics — not a disabled button, whose title SwiftUI greys down to the "unavailable" colour —
    /// with the spinner and the verb in secondary label.
    @ViewBuilder func makeItemButton(_ e: DictationEntry, busy: Bool) -> some View {
        let writing = T("dictation.history.making_item")
        let titles = ZStack {
            Text(T("dictation.history.make_item")).opacity(busy ? 0 : 1)
            HStack(spacing: 6) {
                if busy { BrandSpinnerView(size: 14, label: writing) } else { Color.clear.frame(width: 14, height: 14) }
                Text(writing)
            }
            .opacity(busy ? 1 : 0)
        }
        if busy {
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            titles
                .lineLimit(1).fixedSize()
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14).frame(minHeight: 24)
                .background(shape.fill(Color.primary.opacity(0.06)))
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .help(T("dictation.history.making_item.tip"))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(writing)
                .accessibilityAddTraits(.updatesFrequently)
        } else if bannerHasPrimary {
            Button { m.makeItem(e) } label: { titles }
                .help(T("dictation.history.make_item.tip"))
                .accessibilityLabel(T("dictation.history.make_item"))
        } else {
            Button { m.makeItem(e) } label: { titles }
                .buttonStyle(.brand)
                .keyboardShortcut(.return, modifiers: .command)
                .help(T("dictation.history.make_item.tip"))
                .accessibilityLabel(T("dictation.history.make_item"))
        }
    }

    /// The facts the header doesn't say, as a few quiet rows under a hairline (Raycast's detail metadata): always
    /// there, nothing to open — the models by name, the style that ran, the language, the words and context it used.
    /// How it went in is the line under the text, said once.
    func info(_ e: DictationEntry) -> some View {
        let x = m.extras[e.id]
        return VStack(alignment: .leading, spacing: 12) {
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 7) {
                if e.insert == "none" { row(T("main.dictation.info.result"), T("main.dictation.info.not_typed")) }
                if let a = e.asrModel { row(T("main.dictation.info.asr"), asrName(a)) }
                polishRow(e)
                if let s = e.style, let ran = DictationEntryReport.styleRan(e) {
                    // the style the text is in (what ran, not only what was asked for), and how often reformat-last
                    // changed it (dictation-styles.md); a fall-back: the style asked for, "not polished" (the reason is
                    // the line under the text)
                    let n = s.reformats.filter { $0.action == "reformat" }.count
                    let name = e.fellBack ? Dictation.styleName(DictationStyle(rawValue: s.style) ?? .light) + " · " + T("dictation.history.badge.fell_back")
                        : Dictation.styleName(ran)
                    row(T("dictation.style.section"), name + (n > 0 ? " · " + T("dictation.history.style.reformatted", n) : ""))
                }
                if let l = e.language { row(T("main.dictation.info.language"), Loc.locale.localizedString(forIdentifier: l) ?? l) }
                if let t = x?.terms, !t.isEmpty { row(T("main.dictation.info.terms"), t.joined(separator: T("main.dictation.correct.sep"))) }
                if let c = x?.context { row(T("main.dictation.info.context"), c) }
            }
            .font(.system(size: 12))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(T("main.dictation.details"))
    }

    /// A model by name; one this Mac no longer has says so (the page may be saying "no speech model" above).
    func asrName(_ id: String) -> String {
        let name = models.asrName(id)
        if let r = models.asr?.models.first(where: { $0.id == id }), !r.installed { return T("main.dictation.info.model.gone", name) }
        return name
    }

    /// What polish did, with the model's name; a model that isn't here any more, or none at all, links to the models.
    @ViewBuilder func polishRow(_ e: DictationEntry) -> some View {
        switch DictationEntryReport.polish(e, hasModel: models.polish == nil || models.selectedPolish != nil) {
        case .model(let id):
            if !id.isEmpty, let p = models.polish, !p.models.contains(where: { $0.id == id }) {
                GridRow {
                    label(T("main.dictation.info.polish"))
                    HStack(spacing: 8) {
                        Text(T("main.dictation.info.polish.gone"))
                        LinkButton(title: T("main.dictation.info.model.choose")) { SpeechPane.showDictationModels() }
                    }
                }
            } else {
                let name = id.isEmpty ? T("dictation.history.badge.polished") : models.polishName(id)
                row(T("main.dictation.info.polish"), DictationHistoryModel.differs(e) || e.corrected != nil ? name : name + " · " + T("main.dictation.same"))
            }
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

    /// The labels in one fixed column, the same in both languages, so the values line up wherever they are read.
    func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).lineLimit(1).gridColumnAlignment(.leading).frame(width: 112, alignment: .leading)
    }

    func row(_ k: String, _ v: String) -> some View {
        GridRow {
            label(k)
            Text(v).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The detail's text, at reading size, straight on the pane: Copy and Correct appear while the pointer is over it
/// (and stay a moment after a copy, its check); VoiceOver gets both as actions.
struct DictationTextBlock: View {
    /// a step over the list's 13 pt rows: the dictation in focus reads first
    static let size: CGFloat = 17
    @ObservedObject var m: DictationHistoryModel
    let text: String
    var size: CGFloat = DictationTextBlock.size
    var secondary = false
    let copyID: String
    var edit: DictationEntry?
    @State private var hover = false

    var body: some View {
        let copied = m.copied == copyID
        Text(text)
            .font(.system(size: size)).lineSpacing(size >= 15 ? 4 : 3)
            .foregroundStyle(secondary ? .secondary : .primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.035 : 0)))
            .overlay(alignment: .topTrailing) {
                if hover || copied {
                    HStack(spacing: 0) {
                        if let e = edit {
                            IconButton(symbol: "pencil", tip: T("main.dictation.correct.tip")) { m.beginEdit(e) }
                        }
                        IconButton(symbol: copied ? "checkmark" : "doc.on.doc", tip: copied ? T("main.dictation.copied") : T("dictation.history.copy"),
                                   tint: copied ? Color.brandOk : nil) { m.copy(text, from: copyID) }
                    }
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .offset(x: 4, y: -16)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, -10)      // the text keeps the column's edge; the hover wash reaches past it
            .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hover = inside } }
            .accessibilityAction(named: T("dictation.history.copy")) { m.copy(text, from: copyID) }
            .modifier(CorrectAction(m: m, edit: edit))
    }
}

private struct CorrectAction: ViewModifier {
    @ObservedObject var m: DictationHistoryModel
    let edit: DictationEntry?
    func body(content: Content) -> some View {
        if let e = edit {
            content.accessibilityAction(named: T("main.dictation.correct")) { m.beginEdit(e) }
        } else {
            content
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
    /// Tests: History → Send Feedback… (the sheet), as the header's button opens it.
    @MainActor func testFeedback() {
        show()
        page.model.tab = .history
        page.model.feedbackOpen = true
    }

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
        if k == "front" {               // only the window key, the list focused (screenshots of the active window)
            if let table = page.table { w.makeFirstResponder(table) }
            emit(["event": "dictation_history", "action": "key", "key": k, "key_window": w.isKeyWindow])
            return
        }
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
