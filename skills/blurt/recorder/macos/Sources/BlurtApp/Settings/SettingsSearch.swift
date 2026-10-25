// Where the Settings window is and the search across all of it.
//   SettingsNavigator   the pane showing, the query and its hits (SettingsCatalog.search: titles, descriptions and
//                       keywords, English and Chinese), the hit chosen with ↑ / ↓ or the pointer.
//   SettingsFlash       the row to scroll to — a hit opened, a link (show(pane: "speech/dictation")), a test hook — and
//                       the row flashing there in the brand tint; a row folded away (Dictation's By kind of app) is
//                       unfolded by its pane first. Apart from the navigator so that the rows of every kept page, which
//                       watch it, don't redraw with each key typed in the search.
//   SettingsSearchResults  the page while searching: the hits grouped by pane, the matched words in semibold, each
//                       with its section; click or ↩ opens it in its pane. One row is highlighted: the pointer moves the
//                       keyboard's choice, as in Raycast.
import AppKit
import SwiftUI
import BlurtCore

@MainActor
final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()

    @Published var pane: SettingsPane = .general
    @Published var query = "" { didSet { if query != oldValue { refresh() } } }
    /// The hits in the order the results page shows them (grouped by pane, best pane first).
    @Published private(set) var hits: [SettingsHit] = []
    @Published var selected = 0
    /// bumped when ↑ / ↓ moved the choice: the results scroll to it (the pointer's choice is already in view)
    @Published private(set) var keyMoves = 0

    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private init() {
        // the dictation key and the like in the results' titles ("Double-tap Fn to send")
        SettingsCatalog.arguments = { key in
            MainActor.assumeIsolated {
                let hw = SpeechModel.shared.state?.hardware
                switch key {
                case "dictation.settings.double_tap": return [Dictation.keyShort(Dictation.key)]
                case "speech.limits.threads.detail": return hw.map { [Loc.number($0.perfCores + $0.effCores)] }
                case "speech.limits.memory.detail":
                    guard let h = hw, let f = SpeechModel.shared.state?.limits.maxMemoryFraction else { return nil }
                    return [ByteCountFormatter.string(fromByteCount: Int64(h.ramGB * f * 1_073_741_824), countStyle: .memory)]
                default: return nil
                }
            }
        }
    }

    private func refresh() {
        let found = SettingsCatalog.search(query)
        var order: [String] = []
        for h in found where !order.contains(h.entry.pane) { order.append(h.entry.pane) }
        hits = order.flatMap { p in found.filter { $0.entry.pane == p } }
        selected = 0
        if searching { emit(["event": "settings_search", "query": query, "hits": hits.prefix(8).map(\.entry.id)]) }
    }

    func count(_ p: SettingsPane) -> Int { hits.filter { $0.entry.pane == p.rawValue }.count }

    /// Show a pane (the sidebar, a link): the search ends.
    func go(_ p: SettingsPane) {
        if !query.isEmpty { query = "" }
        if pane != p { pane = p }
    }

    /// Bring a row or section into view in its pane.
    func reveal(_ id: String) {
        let req = SettingsFlash.Request(id: id)
        guard let p = SettingsPane(rawValue: req.pane) else { return }
        go(p)
        SettingsFlash.shared.request = req
        emit(["event": "settings_reveal", "id": id])
    }

    func open(_ h: SettingsHit) { reveal(h.entry.id) }

    func moveSelection(_ by: Int) {
        guard !hits.isEmpty else { return }
        selected = min(max(0, selected + by), hits.count - 1)
        keyMoves += 1
        pointer = NSEvent.mouseLocation
    }

    /// Where the pointer was when the choice last changed. A row that comes under a pointer standing still (the
    /// results scrolled to the keyboard's choice) doesn't take the choice; one the pointer moves onto does.
    private var pointer: NSPoint?
    func point(at i: Int) {
        let p = NSEvent.mouseLocation
        guard p != pointer, hits.indices.contains(i) else { return }
        pointer = p
        selected = i
    }

    func openSelected() {
        guard hits.indices.contains(selected) else { return }
        open(hits[selected])
    }

}

@MainActor
final class SettingsFlash: ObservableObject {
    static let shared = SettingsFlash()

    /// A row or a section to bring into view in its pane, once that page is up.
    struct Request: Equatable {
        let id: String
        let token = UUID()
        var pane: String { String(id.prefix { $0 != "." }) }
    }

    @Published var request: Request?
    @Published private(set) var row: String?

    /// The landing row's wash, briefly.
    func flash(_ id: String) {
        row = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.row == id { self?.row = nil }
        }
    }
}

struct SettingsSearchResults: View {
    @ObservedObject var nav = SettingsNavigator.shared

    var body: some View {
        Group {
            if nav.hits.isEmpty {
                EmptyStateContent(title: T("settings.search.none.title", nav.query.trimmingCharacters(in: .whitespaces)),
                                  message: T("settings.search.none.hint"))
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(groups, id: \.pane) { g in
                                HStack(spacing: 7) {
                                    Image(systemName: g.pane.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                    Text(g.pane.title).font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
                                }
                                .padding(.top, SettingsMetrics.groupGap).padding(.bottom, 6)
                                ForEach(g.hits, id: \.offset) { i, h in
                                    ResultRow(hit: h, terms: terms, selected: nav.selected == i,
                                              hover: { nav.point(at: i) }) { nav.open(h) }.id(i)
                                }
                            }
                        }
                        .padding(.horizontal, SettingsMetrics.gutter).padding(.top, -8).padding(.bottom, 24)
                        .frame(maxWidth: SettingsMetrics.pageWidth, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: nav.keyMoves) { _ in proxy.scrollTo(nav.selected) }
                }
            }
        }
        .settingsPageGround()
    }

    var terms: [String] { nav.query.split(whereSeparator: { $0.isWhitespace }).map(String.init) }

    /// The hits by pane, each with its index in `nav.hits` (the keyboard's order).
    var groups: [(pane: SettingsPane, hits: [(offset: Int, element: SettingsHit)])] {
        var out: [(pane: SettingsPane, hits: [(offset: Int, element: SettingsHit)])] = []
        for (i, h) in nav.hits.enumerated() {
            guard let p = SettingsPane(rawValue: h.entry.pane) else { continue }
            if out.last?.pane == p { out[out.count - 1].hits.append((i, h)) } else { out.append((p, [(i, h)])) }
        }
        return out
    }
}

/// One hit: its title with the words that matched in semibold, its section on the right, its description under it.
private struct ResultRow: View {
    let hit: SettingsHit
    let terms: [String]
    let selected: Bool
    let hover: () -> Void
    let open: () -> Void

    var title: String { SettingsCatalog.title(hit.entry) }
    var section: String? {
        guard hit.entry.kind == .row, let s = hit.entry.section.flatMap(SettingsCatalog.section) else { return nil }
        return SettingsCatalog.text(s.title)
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(marked(title, SettingsMetrics.titleSize)).font(.system(size: SettingsMetrics.titleSize)).lineLimit(1)
                    Spacer(minLength: 8)
                    if let s = section { Text(s).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                }
                if let d = SettingsCatalog.detail(hit.entry), !d.isEmpty {
                    Text(marked(d, SettingsMetrics.detailSize)).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RowWash(on: selected).padding(.horizontal, -6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -10)
        .onHover { if $0 && !selected { hover() } }
        .accessibilityLabel(T("settings.search.result.ax", title, SettingsPane(rawValue: hit.entry.pane)?.title ?? ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The words of the query, wherever they are in `s`, in semibold (case and accents don't matter).
    func marked(_ s: String, _ size: CGFloat) -> AttributedString {
        var a = AttributedString(s)
        for t in terms where !t.isEmpty {
            var from = a.startIndex
            while from < a.endIndex, let r = a[from...].range(of: t, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) {
                a[r].font = .system(size: size, weight: .semibold)
                from = r.upperBound
            }
        }
        return a
    }
}
