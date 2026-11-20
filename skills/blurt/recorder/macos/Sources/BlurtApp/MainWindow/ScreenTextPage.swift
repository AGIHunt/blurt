// Text & Translation (取字与翻译): a full page of the main window, 2026-11-16 — what ⌥C read and ⌥T translated
// (BlurtCore ScreenTextHistory), as the Dictation page keeps what was dictated. Before, the capability had no place in
// the window: what it gave was on the clipboard and then gone.
//
//   the head     the page's name; a row with the search (over the text and, for a translation, its original) and, at
//                its right end, Copy Text ⌥C and Translate ⌥T as the Cards page has Voice Note ⌥V and Snap ⌥A; under
//                it how long the history keeps things (Settings… changes it). All on the title's edge, as on Cards.
//   the list     newest first under their days: the read or translate glyph, "Translate Text from Screen · Safari",
//                the text in up to three lines, a translation's original under it in one quiet line, the time — under
//                the pointer Copy instead
//
// Selection as everywhere on the Mac: a click, ⌘-click adds or removes one, ⇧-click a range; ↑ ↓ move, ⇧↑ ⇧↓ extend,
// ⌘A all. A double-click copies the row, ⌘C the selection (a blank line between texts), ⌫ deletes it — with Undo in the
// island and ⌘Z, as the Dictation page's delete (it was gone at once).
// A translation Blurt quit before it came back is kept as the text read, "Translation interrupted", with Translate Again.
// Test commands (`screentextpage …`): state | select <id,…> | key <name> | copy | delete | undo | translate_again <id> |
// query <text>.
import AppKit
import Combine
import SwiftUI
import BlurtCore

final class ScreenTextPage: FullPage {
    lazy var viewController: NSViewController = MainActor.assumeIsolated {
        NSHostingController(rootView: ScreenTextPageView(m: ScreenTextPageModel.shared))
    }

    func didShow() { MainActor.assumeIsolated { ScreenTextPageModel.shared.reload() } }

    /// "Translate Text from Screen · Safari": what made it and where it went (an interrupted translation says so).
    static func source(_ e: ScreenTextEntry) -> String {
        let what = Loc.t(e.translated || e.wasInterrupted ? "capture.menu.translate" : "capture.menu.text", table: "Capture")
        var parts = [what]
        if let app = AppNames.display(name: e.app, bundle: e.bundle) { parts.append(app) }
        if e.wasInterrupted { parts.append(T("home.screen_text.interrupted")) }
        return parts.joined(separator: " · ")
    }

    /// What VoiceOver reads for a row: what made it, then the whole text (the row shows three lines of it).
    static func spoken(_ e: ScreenTextEntry) -> String {
        var s = source(e) + ": " + e.text
        if e.translated, let o = e.source { s += ". " + T("home.screen_text.original") + ": " + o }
        return s
    }
}

@MainActor
final class ScreenTextPageModel: ObservableObject {
    static let shared = ScreenTextPageModel()

    @Published private(set) var entries: [ScreenTextEntry] = []
    @Published var query = "" { didSet { if query != oldValue { refilter() } } }
    @Published private(set) var shown: [ScreenTextEntry] = []
    @Published private(set) var days: [(day: Date, rows: [ScreenTextEntry])] = []
    @Published private(set) var selection: Set<String> = []
    @Published var pointed: String?
    @Published private(set) var copied: String?
    @Published private(set) var keepDays = ScreenTextCopy.historyDays
    /// the row ⇧ extends from
    private var anchor: String?
    /// the row the keyboard is on (the last one clicked or moved to)
    private(set) var cursor: String?

    private init() {
        NotificationCenter.default.addObserver(forName: .blurtScreenTextChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        keepDays = ScreenTextCopy.historyDays
        entries = ScreenTextHistory.shared.load()
        refilter()
    }

    private func refilter() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        shown = q.isEmpty ? entries : entries.filter { e in
            e.text.lowercased().contains(q) || (e.source?.lowercased().contains(q) ?? false) || (e.app?.lowercased().contains(q) ?? false)
        }
        let cal = Calendar.current
        var out: [(day: Date, rows: [ScreenTextEntry])] = []
        for e in shown {
            let d = cal.startOfDay(for: e.time)
            if let i = out.indices.last, out[i].day == d { out[i].rows.append(e) } else { out.append((d, [e])) }
        }
        days = out
        let ids = Set(shown.map(\.id))
        selection = selection.intersection(ids)
        if let c = cursor, !ids.contains(c) { cursor = nil }
    }

    /// "12 saved · deleted after 30 days" — or kept until deleted, or not kept.
    var summary: String {
        switch keepDays {
        case 0: return T("home.screen_text.summary.off")
        case ..<0: return T("home.screen_text.summary.forever", entries.count)
        default: return T("home.screen_text.summary", entries.count, T("dictation.history.days", keepDays))
        }
    }

    // MARK: selection

    func click(_ id: String) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if mods.contains(.shift), let a = anchor ?? cursor {
            selection = range(a, id)
        } else {
            selection = [id]
            anchor = id
        }
        cursor = id
    }

    private func range(_ a: String, _ b: String) -> Set<String> {
        let ids = shown.map(\.id)
        guard let i = ids.firstIndex(of: a), let j = ids.firstIndex(of: b) else { return [b] }
        return Set(ids[min(i, j)...max(i, j)])
    }

    func move(down: Bool, extend: Bool) {
        let ids = shown.map(\.id)
        guard !ids.isEmpty else { return }
        let from = cursor.flatMap(ids.firstIndex(of:))
        let to = from.map { min(max(0, $0 + (down ? 1 : -1)), ids.count - 1) } ?? (down ? 0 : ids.count - 1)
        let id = ids[to]
        if extend, let a = anchor ?? cursor { selection = range(a, id) } else { selection = [id]; anchor = id }
        cursor = id
    }

    func selectAll() { selection = Set(shown.map(\.id)); anchor = shown.first?.id; cursor = cursor ?? shown.first?.id }

    func select(_ ids: [String]) { selection = Set(ids); anchor = ids.first; cursor = ids.last }

    /// The selected rows in the list's order.
    var selected: [ScreenTextEntry] { shown.filter { selection.contains($0.id) } }

    // MARK: actions

    /// One row's text (a translation's translation) on the clipboard; the row's button shows the check for a moment.
    func copy(_ id: String, original: Bool = false) {
        guard let e = entries.first(where: { $0.id == id }) else { return }
        DictationInsert.copy(original ? (e.source ?? e.text) : e.text)
        flash(id)
        emit(["event": "screen_text_page", "action": original ? "copy_original" : "copy", "id": id])
    }

    /// ⌘C: the selection, its texts one after another with a blank line between.
    func copySelection() {
        let s = selected
        guard !s.isEmpty else { return }
        if s.count == 1 { return copy(s[0].id) }
        DictationInsert.copy(s.map(\.text).joined(separator: "\n\n"))
        emit(["event": "screen_text_page", "action": "copy", "count": s.count])
    }

    /// The main window's: what ⌘Z in its Edit menu reaches.
    private var undo: UndoManager? { MainWindowController.shared.window?.undoManager }

    /// ⌘Z — or the island's "Deleted · Undo" — puts them back (as the Dictation page's delete does).
    func delete(_ ids: [String]) {
        let gone = entries.filter { ids.contains($0.id) }
        guard !gone.isEmpty else { return }
        ScreenTextHistory.shared.delete(gone.map(\.id))
        selection.subtract(ids)
        emit(["event": "screen_text_page", "action": "delete", "count": gone.count])
        reload()
        let undo = self.undo
        island.toast(gone.count == 1 ? T("home.screen_text.deleted.one") : T("home.screen_text.deleted.many", gone.count),
                     key: "screen_text_deleted", seconds: 5, actionTitle: T("dictation.toast.undo")) { [weak undo] in
            if let u = undo, u.canUndo { u.undo() }
        }
        undo?.registerUndo(withTarget: self) { m in
            MainActor.assumeIsolated { m.restore(gone) }
        }
        undo?.setActionName(T("home.screen_text.delete"))
    }

    private func restore(_ es: [ScreenTextEntry]) {
        ScreenTextHistory.shared.restore(es)
        reload()
        selection = Set(es.map(\.id))
        emit(["event": "screen_text_page", "action": "undo_delete", "count": es.count])
        // registered while undoing: ⇧⌘Z deletes them again
        undo?.registerUndo(withTarget: self) { m in MainActor.assumeIsolated { m.delete(es.map(\.id)) } }
        undo?.setActionName(T("home.screen_text.delete"))
    }

    /// An interrupted translation's Translate Again: the text as read, translated as a fresh ⌥T's (onto the clipboard);
    /// its row goes once the new one is in.
    func translateAgain(_ id: String) {
        guard let e = entries.first(where: { $0.id == id }) else { return }
        emit(["event": "screen_text_page", "action": "translate_again", "id": id])
        ScreenTextHistory.shared.delete([id])
        reload()
        ScreenTextCopy.shared.translateAgain(e.text)
    }

    func copyText() { ScreenTextCopy.shared.hotkey(via: "text_page") }
    func translateText() { ScreenTextCopy.shared.hotkey(via: "text_page", translate: true) }

    func deleteSelection() { delete(selected.map(\.id)) }

    private func flash(_ id: String) {
        copied = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated { if self?.copied == id { self?.copied = nil } }
        }
    }

    func openSettings() { AppEnvironment.settings?.show(pane: "screentext/screentext.history_keep") }

    // MARK: tests

    func testCommand(_ arg: String) {
        let p = arg.split(separator: " ", maxSplits: 1).map(String.init)
        switch p.first ?? "state" {
        case "select": select((p.count > 1 ? p[1] : "").split(separator: ",").map(String.init))
        case "key":
            switch p.count > 1 ? p[1] : "" {
            case "down": move(down: true, extend: false)
            case "up": move(down: false, extend: false)
            case "shift-down": move(down: true, extend: true)
            case "shift-up": move(down: false, extend: true)
            case "all": selectAll()
            default: break
            }
        case "copy": copySelection()
        case "delete": deleteSelection()
        case "undo": if undo?.canUndo == true { undo?.undo() }
        case "translate_again": if p.count > 1 { translateAgain(p[1]) }
        case "query": query = p.count > 1 ? p[1] : ""
        case "reload": reload()
        default: break
        }
        emit(["event": "screen_text_page_state", "count": entries.count, "shown": shown.map(\.id), "selected": selected.map(\.id),
              "cursor": cursor ?? NSNull(), "summary": summary, "days": days.count])
    }
}

/// ⌥C's or ⌥T's glyph, in a row's 18 pt slot (here and in Home's timeline).
struct ScreenTextMark: View {
    let translated: Bool
    var body: some View {
        Image(systemName: translated ? "character.bubble" : "text.viewfinder")
            .font(.system(size: 13)).foregroundStyle(.secondary)
            .frame(height: 16)
            .accessibilityHidden(true)
    }
}

struct ScreenTextPageView: View {
    @ObservedObject var m: ScreenTextPageModel

    var body: some View {
        FullPageFrame(title: T("feature.screen_text")) {
            VStack(alignment: .leading, spacing: 0) {
                head
                if m.entries.isEmpty {
                    empty
                } else if m.shown.isEmpty {
                    Text(T("home.screen_text.none_found")).font(.system(size: 13)).foregroundStyle(.secondary)
                        .padding(.top, 24)
                } else {
                    list
                        // the rows' hover wash reaches out past the column, their glyphs stay on the title's edge
                        // (as the Cards page's tiles)
                        .padding(.horizontal, -HomeMetrics.inset)
                }
            }
            .focusable()
            .focusEffectDisabledIfAvailable()
            .onCopyCommand { m.copySelection(); return [] }
            .onDeleteCommand { m.deleteSelection() }
            .onCommand(#selector(NSText.selectAll(_:))) { m.selectAll() }
            .onMoveCommand { d in
                if d == .down || d == .up { m.move(down: d == .down, extend: NSEvent.modifierFlags.contains(.shift)) }
            }
        }
        .onAppear { m.reload() }
    }

    /// The Cards page's row: the search, and at its right end the two keys as buttons; then how long things are kept,
    /// with Settings….
    private var head: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if !m.entries.isEmpty {
                    ScreenTextSearchField(text: $m.query).frame(minWidth: 120, maxWidth: 280)
                }
                Spacer(minLength: 4)
                Button { m.copyText() } label: {
                    CardsKeyedLabel(title: Look.menuCase(T("home.screen_text.action.copy")), key: hk(.text))
                }
                .buttonStyle(SettingsOutlinedButtonStyle()).help(Loc.t("capture.menu.text", table: "Capture"))
                Button { m.translateText() } label: {
                    CardsKeyedLabel(title: Look.menuCase(T("home.screen_text.action.translate")), key: hk(.translateText))
                }
                .buttonStyle(SettingsOutlinedButtonStyle()).help(Loc.t("capture.menu.translate", table: "Capture"))
            }
            HStack(spacing: 6) {
                Text(m.summary).foregroundStyle(.secondary)
                Button(T("home.screen_text.settings")) { m.openSettings() }.buttonStyle(HomeLinkStyle())
            }
            .font(.system(size: SettingsMetrics.detailSize))
        }
    }

    private var empty: some View {
        Text(m.keepDays == 0 ? T("home.screen_text.empty.off") : T("home.screen_text.empty", hk(.text), hk(.translateText)))
            .font(.system(size: 13)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 28)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(m.days.enumerated()), id: \.element.day) { n, day in
                Text(DictationHistoryModel.dayTitle(day.day)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.leading, HomeMetrics.inset)
                    .padding(.top, n == 0 ? 18 : 18).padding(.bottom, 4)
                ForEach(day.rows) { e in ScreenTextRow(m: m, e: e) }
            }
            if m.selection.count > 1 {
                Text(T("home.screen_text.selected", m.selection.count)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .padding(.leading, HomeMetrics.inset + HomeMetrics.slot + HomeMetrics.gap).padding(.top, 12)
            }
        }
    }
}

/// The page's search field: the Cards page's (a system search field, as tall as the buttons at the row's other end;
/// Esc and its × clear it) — it was a filled box of its own.
private struct ScreenTextSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = T("home.screen_text.search")
        f.sendsSearchStringImmediately = true
        f.sendsWholeSearchString = false
        f.controlSize = .large
        f.font = .systemFont(ofSize: 13)
        f.setAccessibilityLabel(T("home.screen_text.search"))
        f.delegate = context.coordinator
        f.target = context.coordinator
        f.action = #selector(Coordinator.sent(_:))
        return f
    }

    func updateNSView(_ f: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
    }

    @available(macOS 13.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: max(nsView.intrinsicContentSize.height, OutlinedPopUpButton.height))
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ScreenTextSearchField
        init(_ p: ScreenTextSearchField) { parent = p }
        @objc func sent(_ f: NSSearchField) { parent.text = f.stringValue }
        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSSearchField { parent.text = f.stringValue }
        }
    }
}

/// One reading: Home's row grammar (the glyph, a quiet line saying what and where, the text, the time — Copy under
/// the pointer), plus a translation's original in one quiet line.
private struct ScreenTextRow: View {
    @ObservedObject var m: ScreenTextPageModel
    let e: ScreenTextEntry

    var body: some View {
        let selected = m.selection.contains(e.id), pointed = m.pointed == e.id, copied = m.copied == e.id
        HStack(alignment: .top, spacing: HomeMetrics.gap) {
            ScreenTextMark(translated: e.translated || e.wasInterrupted).frame(width: HomeMetrics.slot)
            VStack(alignment: .leading, spacing: 2) {
                Text(ScreenTextPage.source(e)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    .frame(minHeight: 16)
                Text(e.text).font(.system(size: 13)).lineLimit(3).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                if e.translated, let s = e.source {
                    Text(T("home.screen_text.original") + "  " + ScreenTextEntry.preview(s)).font(.system(size: 12))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 12)
            ZStack(alignment: .topTrailing) {
                Text(DictationHistoryModel.time(e.time)).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize().frame(minHeight: 16)
                    .opacity(pointed || copied ? 0 : 1)
                if pointed || copied {
                    Button { m.copy(e.id) } label: {
                        ZStack {
                            Text(T("dictation.history.copy")).opacity(copied ? 0 : 1)
                            if copied { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.brandOk) }
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).fixedSize().offset(y: -3)
                    .accessibilityLabel(copied ? T("main.dictation.copied") : T("dictation.history.copy"))
                }
            }
            .frame(width: HomeMetrics.timeWidth, alignment: .topTrailing)
        }
        .padding(.horizontal, HomeMetrics.inset).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? Color.brandTint : Color.primary.opacity(pointed ? 0.035 : 0)))
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { m.copy(e.id) })
        .simultaneousGesture(TapGesture().onEnded { m.click(e.id) })
        .onHover { inside in
            if inside { m.pointed = e.id } else if m.pointed == e.id { m.pointed = nil }
        }
        .contextMenu {
            Button(T("dictation.history.copy")) { m.copy(e.id) }
            if e.translated { Button(T("home.screen_text.copy_original")) { m.copy(e.id, original: true) } }
            if e.wasInterrupted { Button(T("home.screen_text.translate_again")) { m.translateAgain(e.id) } }
            Divider()
            Button(T("home.screen_text.delete"), role: .destructive) {
                m.delete(m.selection.contains(e.id) && m.selection.count > 1 ? m.selected.map(\.id) : [e.id])
            }
        }
        // the whole text, not the three-line preview combine read (VoiceOver heard a cut-off row)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ScreenTextPage.spoken(e))
        .accessibilityValue(DictationHistoryModel.time(e.time))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { m.copy(e.id) }
        .accessibilityAction(named: T("dictation.history.copy")) { m.copy(e.id) }
    }
}

private extension View {
    @ViewBuilder func focusEffectDisabledIfAvailable() -> some View {
        if #available(macOS 14.0, *) { self.focusEffectDisabled() } else { self }
    }
}
