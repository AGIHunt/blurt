// Dictation history (听写历史): every dictation, newest first, grouped by day, searchable. A row shows what was
// typed (the polished text) with a switch to the original words, and copy / copy original / turn into item / delete.
// Reached from the menu-bar menu, the main window's sidebar (Dictation), Settings → Dictation and ⌥⌘D in the main
// window. Reads DictationHistory (history.jsonl) directly; "Turn into item" goes through dictation.py (items.py add).
import AppKit
import SwiftUI
import BlurtCore

@MainActor
final class DictationHistoryModel: ObservableObject {
    @Published var entries: [DictationEntry] = []
    @Published var query = ""
    @Published var showRaw: Set<String> = []
    @Published var working: Set<String> = []
    @Published var error: String?

    func reload() { entries = DictationHistory.shared.load() }

    var filtered: [DictationEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { e in [e.text, e.raw, e.polished ?? "", e.app ?? ""].contains { $0.lowercased().contains(q) } }
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

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        emit(["event": "dictation_history", "action": "copy"])
    }

    func delete(_ e: DictationEntry) {
        DictationHistory.shared.delete([e.id])
        reload()
        emit(["event": "dictation_history", "action": "delete", "id": e.id])
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
}

final class DictationHistoryWindow: NSObject, NSWindowDelegate {
    static let shared = DictationHistoryWindow()
    private var window: NSWindow?
    private var model: DictationHistoryModel?

    @MainActor
    func show() {
        if window == nil {
            let m = DictationHistoryModel()
            let host = NSHostingController(rootView: DictationHistoryView(m: m))
            let w = NSWindow(contentViewController: host)
            w.title = T("dictation.history.title")
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 720, height: 640))
            w.minSize = NSSize(width: 520, height: 360)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("BlurtDictationHistory")
            if let a = ProcessInfo.processInfo.environment["BLURT_APPEARANCE"] { w.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua) }
            window = w
            model = m
        }
        model?.reload()
        activateApp()
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        emit(["event": "dictation_history", "action": "show", "window": window?.windowNumber ?? -1, "entries": model?.entries.count ?? 0])
    }

    func reloadIfOpen() {
        guard window?.isVisible == true else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.model?.reload() } }
    }

    var windowNumber: Int? { window?.isVisible == true ? window?.windowNumber : nil }

    @MainActor func setQuery(_ q: String) { model?.query = q }
    @MainActor func toggleRaw(_ id: String?) {
        guard let m = model else { return }
        let target = id ?? m.entries.first?.id
        if let t = target { if m.showRaw.contains(t) { m.showRaw.remove(t) } else { m.showRaw.insert(t) } }
    }
    @MainActor func makeItem(_ id: String?) {
        guard let m = model, let e = m.entries.first(where: { $0.id == id }) ?? m.entries.first else { return }
        m.makeItem(e)
    }
}

/// One of our icons in SwiftUI: the SF Symbol for generic ones (as the rest of the app), our vector for brand ones.
private func glyph(_ i: BlurtIcon, _ size: CGFloat = 12) -> Image {
    Image(nsImage: i.isBrand ? i.image(size: size + 2) : i.symbolImage(pointSize: size)).renderingMode(.template)
}

struct DictationHistoryView: View {
    @ObservedObject var m: DictationHistoryModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                glyph(.search).foregroundStyle(.secondary)
                TextField(T("dictation.history.search"), text: $m.query).textFieldStyle(.plain)
                if !m.query.isEmpty {
                    Button { m.query = "" } label: { glyph(.x, 10) }.buttonStyle(.borderless).help(T("dictation.history.clear_search"))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.45)))
            .padding(12)
            if let e = m.error { Text(e).font(.caption).foregroundStyle(.orange).padding(.bottom, 6) }
            Divider()
            if m.filtered.isEmpty {
                VStack(spacing: 8) {
                    glyph(.keyboard, 28).foregroundStyle(.tertiary)
                    Text(m.entries.isEmpty ? T("dictation.history.empty.title") : T("dictation.history.no_match")).font(.headline)
                    if m.entries.isEmpty {
                        Text(T("dictation.history.empty.body", Dictation.keyName)).font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: 380)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(m.days, id: \.day) { group in
                        Section(header: Text(dayTitle(group.day))) {
                            ForEach(group.rows) { e in row(e) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { m.reload() }
    }

    func row(_ e: DictationEntry) -> some View {
        let raw = m.showRaw.contains(e.id)
        let differs = e.polished != nil && e.text != e.raw
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(raw ? e.raw : e.text)
                    .font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(raw ? .secondary : .primary)
                HStack(spacing: 6) {
                    Text(e.time, style: .time).monospacedDigit()
                    if let a = e.app { Text("·"); Text(a) }
                    Text("·")
                    Text(T("dictation.history.seconds", Int(e.duration.rounded())))
                    if raw { badge(T("dictation.history.badge.original"), .secondary) }
                    else if e.fellBack { badge(T("dictation.history.badge.fell_back"), .orange).help(reasonText(e.reason)) }
                    else if differs { badge(T("dictation.history.badge.polished"), .accentColor) }
                    if e.insert == "copied" { badge(T("dictation.history.badge.copied"), .secondary) }
                    if let it = e.item { badge(it, .green) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                if differs || e.fellBack {
                    Button { if raw { m.showRaw.remove(e.id) } else { m.showRaw.insert(e.id) } } label: { glyph(.eye) }
                        .help(raw ? T("dictation.history.show_polished") : T("dictation.history.show_raw"))
                        .accessibilityLabel(raw ? T("dictation.history.show_polished") : T("dictation.history.show_raw"))
                }
                Button { m.copy(raw ? e.raw : e.text) } label: { glyph(.copy) }
                    .help(T("dictation.history.copy")).accessibilityLabel(T("dictation.history.copy"))
                Menu {
                    Button(T("dictation.history.copy")) { m.copy(e.text) }
                    Button(T("dictation.history.copy_raw")) { m.copy(e.raw) }
                    Divider()
                    Button(e.item == nil ? T("dictation.history.make_item") : T("dictation.history.item_exists", e.item ?? "")) { m.makeItem(e) }
                        .disabled(e.item != nil || m.working.contains(e.id))
                    Divider()
                    Button(T("dictation.history.delete"), role: .destructive) { m.delete(e) }
                } label: { glyph(.more) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(T("dictation.history.more")).accessibilityLabel(T("dictation.history.more"))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(T("dictation.history.copy")) { m.copy(e.text) }
            Button(T("dictation.history.copy_raw")) { m.copy(e.raw) }
            Button(T("dictation.history.make_item")) { m.makeItem(e) }.disabled(e.item != nil)
            Divider()
            Button(T("dictation.history.delete"), role: .destructive) { m.delete(e) }
        }
    }

    func badge(_ s: String, _ c: Color) -> some View {
        Text(s).font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(c.opacity(0.14))).foregroundStyle(c)
    }

    func reasonText(_ r: String?) -> String {
        let k = "dictation.history.reason.\(r ?? "error")"
        return T(k) == k ? T("dictation.history.reason.error") : T(k)
    }

    func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return T("dictation.history.today") }
        if cal.isDateInYesterday(d) { return T("dictation.history.yesterday") }
        let f = DateFormatter()
        f.locale = Loc.locale
        f.setLocalizedDateFormatFromTemplate(cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "MMMMdEEEE" : "yMMMMd")
        return f.string(from: d)
    }
}
