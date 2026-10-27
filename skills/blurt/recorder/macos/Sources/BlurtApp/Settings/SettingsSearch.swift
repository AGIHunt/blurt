// Where the Settings window is and the search across all of it.
//   SettingsNavigator   the pane showing, the query and its results (SettingsCatalog.results: titles, descriptions and
//                       keywords, English and Chinese, grouped by pane), the stop chosen with ↑ / ↓ or the pointer.
//   SettingsFlash       the row to scroll to — a hit opened, a link (show(pane: "speech/dictation")), a test hook — and
//                       the row flashing there in the brand tint; a row folded away (Dictation's By kind of app) is
//                       unfolded by its pane first. Apart from the navigator so that the rows of every kept page, which
//                       watch it, don't redraw with each key typed in the search.
//   SettingsSearchResults  the page while searching, on the panes' own grid and in their own components: the query is
//                       the window's title; a quiet lead with the count (and ↑↓ / ↩ on its right), then one group per
//                       pane in the sidebar's counts — the pane's heading (its symbol, name, count) over one rounded box
//                       of one-line rows. A row is its title with the matched words in semibold, why it matched when
//                       the title doesn't say (a sentence of its description, a keyword — always in the UI's language)
//                       and, on its right, one thing: a shortcut's keycaps, or the section it is in. A pane found by
//                       its name ("short") leads with "Open Shortcuts settings", then its first rows and "Show 9 more".
//                       Restore defaults is an action: only found by its own words, in brand ink. One stop is tinted
//                       (brand tint when the window is key); the pointer moving onto a row makes it the keyboard's
//                       choice, as in Raycast. Click or ↩ opens it in its pane. With no hits the page keeps its frame
//                       and says so in one quiet block where the count goes: a hint, a few common searches and a plain
//                       Clear Search — a miss is a result, not a friendly empty state (system.md §3.5).
import AppKit
import SwiftUI
import BlurtCore

@MainActor
final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()

    /// One stop of the keyboard's walk through the results.
    enum Item: Hashable {
        /// a pane found as a whole ("short" → Shortcuts): opens it
        case pane(String)
        /// a setting: opens its pane at it
        case hit(SettingsHit)
        /// "Show 9 more" / "Show fewer" under a pane found as a whole
        case more(String)

        var key: String {
            switch self {
            case .pane(let p): return "pane:\(p)"
            case .hit(let h): return h.entry.id
            case .more(let p): return "more:\(p)"
            }
        }
    }

    /// What the results page draws, top to bottom.
    enum Line: Hashable, Identifiable {
        case group(SettingsResultGroup)
        /// a section's caption inside a group: (catalogue section id, its title)
        case section(String, String)
        /// `items[i]` (its key), and its section's title when that goes on the row's right rather than above it (the
        /// only hit of its section)
        case item(Int, String, section: String?)

        var id: String {
            switch self {
            case .group(let g): return "g:\(g.pane)"
            case .section(let s, _): return "s:\(s)"
            case .item(_, let key, _): return "i:\(key)"
            }
        }
    }

    /// Rows a pane found as a whole shows before "Show N more".
    static let preview = 5

    @Published var pane: SettingsPane = .general
    @Published var query = "" { didSet { if query != oldValue { refresh() } } }
    @Published private(set) var groups: [SettingsResultGroup] = []
    /// Every setting found, in the page's order (the sidebar's counts; tests).
    @Published private(set) var hits: [SettingsHit] = []
    /// The keyboard's stops, in the page's order, and the page's lines.
    @Published private(set) var items: [Item] = []
    @Published private(set) var lines: [Line] = []
    /// panes found as a whole whose rows are all shown
    @Published private(set) var expanded: Set<String> = []
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
        groups = SettingsCatalog.results(query)
        hits = groups.flatMap(\.hits)
        expanded = []
        layout()
        selected = 0
        if searching {
            emit(["event": "settings_search", "query": query, "hits": hits.prefix(8).map(\.entry.id),
                  "items": items.prefix(10).map(\.key)])
        }
    }

    /// The stops and lines for the groups as they are (folded or not).
    private func layout() {
        var items: [Item] = [], lines: [Line] = []
        func add(_ i: Item, section: String? = nil) { lines.append(.item(items.count, i.key, section: section)); items.append(i) }
        for g in groups {
            lines.append(.group(g))
            if g.paneHit { add(.pane(g.pane)) }
            let folds = g.paneHit && g.hits.count > Self.preview + 1
            let shown = folds && !expanded.contains(g.pane) ? Array(g.hits.prefix(Self.preview)) : g.hits
            // the hits by section (they come in runs): a run's caption above it — or, for the only hit of its section
            // among a few found by their own words, the section on the row's right; none over a section's own
            // entry, nor for a section named like its pane
            var runs: [[SettingsHit]] = []
            for h in shown {
                if let r = runs.last, r[0].entry.section == h.entry.section { runs[runs.count - 1].append(h) } else { runs.append([h]) }
            }
            // one grouping scheme: the section is each row's right-hand qualifier (no captions between rows)
            for r in runs {
                let first = r[0].entry
                let title = first.kind == .section ? nil : first.section.flatMap(SettingsCatalog.section).flatMap { SettingsCatalog.text($0.title) }
                let named = title.flatMap { $0 == SettingsPane(rawValue: g.pane)?.title ? nil : $0 }
                for h in r { add(.hit(h), section: named) }
            }
            if folds { add(.more(g.pane)) }
        }
        self.items = items
        self.lines = lines
    }

    func count(_ p: SettingsPane) -> Int { hits.filter { $0.entry.pane == p.rawValue }.count }

    /// The sidebar's count for a pane: nil when not searching, and when nothing matches anywhere — dimming every pane
    /// would only say the whole sidebar is off, so the panes stay at rest and the page says there is no match.
    func sidebarCount(_ p: SettingsPane) -> Int? { searching && !hits.isEmpty ? count(p) : nil }

    /// The no-match page's Clear Search (Esc in the field does the same): the search ends, the last pane comes back
    /// and the field takes the focus again, ready for another word.
    func clearSearch() {
        query = ""
        (NSApp.windows.first { $0 is SettingsWindow } as? SettingsWindow)?.mFind()
        emit(["event": "settings_search_clear"])
    }

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

    /// Open a stop: a pane, a setting in its pane, or fold / unfold a pane's rows. true when the search ended.
    @discardableResult
    func open(_ item: Item) -> Bool {
        switch item {
        case .pane(let p):
            guard let sp = SettingsPane(rawValue: p) else { return false }
            emit(["event": "settings_open_pane", "pane": p])
            go(sp)
            return true
        case .hit(let h):
            reveal(h.entry.id)
            return true
        case .more(let p):
            toggle(p)
            return false
        }
    }

    /// Show all of a pane's rows, or only its first ones again. Unfolding keeps the choice where it was (the first row
    /// that came in); folding puts it back on "Show N more".
    func toggle(_ p: String) {
        let opening = !expanded.contains(p)
        if opening { expanded.insert(p) } else { expanded.remove(p) }
        layout()
        if !opening, let i = items.firstIndex(of: .more(p)) { selected = i }
        selected = min(selected, max(0, items.count - 1))
        keyMoves += 1
        emit(["event": "settings_search_more", "pane": p, "open": opening, "items": items.count])
    }

    func moveSelection(_ by: Int) {
        guard !items.isEmpty else { return }
        selected = min(max(0, selected + by), items.count - 1)
        keyMoves += 1
        pointer = NSEvent.mouseLocation
    }

    /// Where the pointer was when the choice last changed. A row that comes under a pointer standing still (the
    /// results scrolled to the keyboard's choice) doesn't take the choice; one the pointer moves onto does.
    private var pointer: NSPoint?
    func point(at i: Int) {
        let p = NSEvent.mouseLocation
        guard p != pointer, items.indices.contains(i) else { return }
        pointer = p
        selected = i
    }

    /// ↩ in the search field. true when the search ended (a pane opened): the sidebar takes the keys back.
    @discardableResult
    func openSelected() -> Bool {
        guard items.indices.contains(selected) else { return false }
        return open(items[selected])
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

private enum ResultsMetrics {
    static let rowHeight: CGFloat = 22
}

struct SettingsSearchResults: View {
    @ObservedObject var nav = SettingsNavigator.shared
    /// the pen's hold key, shown on its row
    @ObservedObject private var keys = HotkeySettings.shared

    /// The page's lines as boxes: each pane's heading, then its rows (indices into nav.lines).
    var blocks: [(group: SettingsResultGroup, lines: [Int])] {
        var out: [(group: SettingsResultGroup, lines: [Int])] = []
        for (k, l) in nav.lines.enumerated() {
            switch l {
            case .group(let g): out.append((g, []))
            case .item: if !out.isEmpty { out[out.count - 1].lines.append(k) }
            case .section: break
            }
        }
        return out
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // one frame for hits and no hits, on the panes' grid: the same column, insets and boxes
                VStack(alignment: .leading, spacing: 0) {
                    if nav.items.isEmpty {
                        NoMatch(query: query)
                            .padding(.horizontal, SettingsMetrics.boxInset).padding(.top, SettingsMetrics.groupGap)
                    } else {
                        header
                        ForEach(Array(blocks.enumerated()), id: \.element.group.pane) { _, b in
                            groupHeading(b.group)
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(b.lines.enumerated()), id: \.element) { j, k in
                                    lineView(nav.lines[k], hairline: j > 0)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous))
                            .background(RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous).fill(SettingsMetrics.boxFill))
                            .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.boxRadius, style: .continuous)
                                .strokeBorder(SettingsMetrics.boxStroke, lineWidth: 0.5).allowsHitTesting(false))
                        }
                    }
                }
                .padding(.horizontal, SettingsMetrics.gutter).padding(.top, SettingsMetrics.pageTop).padding(.bottom, 40)
                .frame(maxWidth: SettingsMetrics.pageWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            // the bottom edge as the top: rows go under a short fade instead of being cut by the window
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [SettingsMetrics.ground.opacity(0), SettingsMetrics.ground], startPoint: .top, endPoint: .bottom)
                    .frame(height: SettingsMetrics.bottomFade)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onChange(of: nav.keyMoves) { _ in proxy.scrollTo(nav.selected) }
        }
        .settingsPageGround()
    }

    var query: String { nav.query.trimmingCharacters(in: .whitespaces) }
    var terms: [String] { nav.query.split(whereSeparator: { $0.isWhitespace }).map(String.init) }

    /// "16 results" (the query is the window's title), and how to walk them — the page's lead, where every page's
    /// first line is.
    var header: some View {
        HStack(alignment: .center, spacing: 12) {
            let n = nav.hits.count
            Text(n == 1 ? T("settings.search.count_only.one") : T("settings.search.count_only", n))
                .font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(n == 1 ? T("settings.search.count.one", query) : T("settings.search.count", n, query))
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                KeyCaps(["↑", "↓"], size: 11)
                Text(T("settings.search.hint.choose"))
                KeyCaps(["↩"], size: 11).padding(.leading, 6)
                Text(T("settings.search.hint.open"))
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityHidden(true)
        }
        .padding(.horizontal, SettingsMetrics.boxInset)
        .padding(.top, SettingsMetrics.groupGap)
    }

    @ViewBuilder
    func lineView(_ line: SettingsNavigator.Line, hairline: Bool) -> some View {
        if case .item(let i, _, let section) = line, nav.items.indices.contains(i) {
            row(nav.items[i], i, section: section, hairline: hairline && nav.selected != i && nav.selected != i - 1)
        }
    }

    /// A pane's heading, as a section's on its page: its symbol and name, how many of its settings were found on the
    /// right (as in the sidebar).
    func groupHeading(_ g: SettingsResultGroup) -> some View {
        let p = SettingsPane(rawValue: g.pane)
        return HStack(spacing: 6) {
            Image(systemName: p?.symbol ?? "gearshape").font(.system(size: 11, weight: .semibold)).frame(width: 14)
                .accessibilityHidden(true)
            Text(p?.title ?? g.pane).font(.system(size: SettingsMetrics.headerSize, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Text(Loc.number(g.hits.count)).font(.system(size: SettingsMetrics.detailSize).monospacedDigit())
                .accessibilityHidden(true)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, SettingsMetrics.boxInset)
        .padding(.top, SettingsMetrics.groupGap).padding(.bottom, 5)
    }

    @ViewBuilder
    func row(_ item: SettingsNavigator.Item, _ i: Int, section: String?, hairline: Bool) -> some View {
        let on = nav.selected == i
        let hover = { nav.point(at: i) }
        let open = { _ = nav.open(item) }
        switch item {
        case .pane(let p):
            let name = SettingsPane(rawValue: p)?.title ?? p
            ResultRow(title: T("settings.search.open_pane", name), reason: SettingsCatalog.reason(pane: p, query: nav.query),
                      terms: terms, selected: on, hairline: hairline, axLabel: T("settings.search.open_pane", name),
                      hover: hover, open: open) {
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
                .id(i)
        case .hit(let h):
            let e = h.entry
            let title = SettingsCatalog.title(e)
            let action = SettingsCatalog.actions.contains(e.id)
            // a pane found as a whole: its rows are there because of it, not because of their own words
            let byPane = nav.groups.first { $0.pane == e.pane }?.paneHit == true
            ResultRow(title: title, reason: byPane ? nil : SettingsCatalog.reason(e, query: nav.query), terms: terms,
                      selected: on, hairline: hairline, ink: action, help: SettingsCatalog.detail(e),
                      axLabel: T("settings.search.result.ax", title, SettingsPane(rawValue: e.pane)?.title ?? ""),
                      axValue: Self.keys(e)?.joined(), hover: hover, open: open) {
                accessory(e, section: section)
            }
            .id(i)
        case .more(let p):
            let g = nav.groups.first { $0.pane == p }
            let opened = nav.expanded.contains(p)
            let label = opened ? T("settings.search.fewer") : T("settings.search.more", max(0, (g?.hits.count ?? 0) - SettingsNavigator.preview))
            ResultRow(title: label, reason: nil, terms: [], selected: on, hairline: hairline, ink: true, axLabel: label,
                      hover: hover, open: open) {
                Image(systemName: opened ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.brandInk).accessibilityHidden(true)
            }
            .id(i)
        }
    }

    /// On a row's right, one thing: a shortcut's keys as keycaps ("None" / "Off" without one); Restore defaults' glyph;
    /// else the section it is in.
    @ViewBuilder
    func accessory(_ e: SettingsEntry, section: String?) -> some View {
        if let k = Self.keys(e) {
            if k.isEmpty {
                let off = ["shortcuts.dictation", "shortcuts.dictation_key", "dictation.key", "shortcuts.draw_key"].contains(e.id)
                Text(Loc.t(off ? "capture.keys.off" : "capture.keys.none", table: "Capture"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                KeyCaps(k, size: 11)
            }
        } else if SettingsCatalog.actions.contains(e.id) {
            Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.brandInk).accessibilityHidden(true)
        } else if let s = section {
            Text(s).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
    }

    /// A shortcut row's keys, one keycap each ("⌥", "⇧", "R"); [] when it has none; nil for a row that isn't a key.
    static func keys(_ e: SettingsEntry) -> [String]? {
        switch e.id {
        case "shortcuts.dictation", "shortcuts.dictation_key", "dictation.key":
            return Dictation.enabled ? [Dictation.keyName] : []
        case "shortcuts.draw_key":
            switch HotkeySettings.shared.drawKey {
            case "control": return ["⌃"]
            case "option": return ["⌥"]
            case "fn": return ["fn"]
            default: return []
            }
        default:
            guard e.id.hasPrefix("shortcuts."), let a = HotAction(rawValue: String(e.id.dropFirst("shortcuts.".count))) else { return nil }
            return Hotkeys.shared.shortcut(a).map { KeyCaps.split($0.label) } ?? []
        }
    }

    /// The words of the query, wherever they are in `s`, in semibold (case and accents don't matter).
    func marked(_ s: String, _ size: CGFloat) -> AttributedString {
        ResultRow<EmptyView>.mark(s, terms, size)
    }
}

/// No setting matches: where the first group would start, one quiet block — what was searched (cut in the middle when
/// long, one line), a hint, a few searches that always find something, and a plain Clear Search (never ↩; Esc in the
/// field does the same). No brand mark: a typo is not a welcome (system.md §3.5).
private struct NoMatch: View {
    @ObservedObject var nav = SettingsNavigator.shared
    let query: String

    /// The query as the title quotes it: a pasted sentence or a path keeps its start and end, cut in the middle.
    static func clipped(_ q: String, max: Int = 24) -> String {
        guard q.count > max else { return q }
        let head = (max - 1) / 2
        return String(q.prefix(head)) + "…" + String(q.suffix(max - 1 - head))
    }

    var body: some View {
        // laid out like a results group: the symbol in the slot a pane's symbol takes, then the text column
        HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.iconGap) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: SettingsMetrics.iconSlot)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                // the query is the window's title already
                Text(T("settings.search.none.title_short"))
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel(T("settings.search.none.title", query))
                Text(T("settings.search.none.hint")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                suggestions.padding(.top, 10)
                Button(T("settings.search.clear")) { nav.clearSearch() }
                    .controlSize(.regular)
                    .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Searches that always find something (SettingsCatalog.suggestions): a click puts the word in the field.
    var suggestions: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(T("settings.search.none.common")).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(.secondary)
            ForEach(SettingsCatalog.suggestions, id: \.key) { t in
                let word = SettingsCatalog.text(t) ?? ""
                Button { nav.query = word } label: {
                    Text(word).font(.system(size: SettingsMetrics.detailSize)).foregroundStyle(Color.brandInk)
                }
                .buttonStyle(.plain)
                .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                .accessibilityLabel(T("settings.search.none.common.ax", word))
            }
        }
    }
}

/// One stop: its title (the matched words in semibold) and, when the title doesn't say why it matched, the reason after
/// it in secondary; the accessory (keycaps) on the right, then ↩ on the chosen one. One line, the same height for all.
private struct ResultRow<Accessory: View>: View {
    let title: String
    let reason: String?
    let terms: [String]
    let selected: Bool
    let hairline: Bool
    /// an action or a disclosure: brand ink, as the app's text buttons
    var ink = false
    var help: String?
    let axLabel: String
    var axValue: String?
    let hover: () -> Void
    let open: () -> Void
    @ViewBuilder let accessory: Accessory
    @Environment(\.displayScale) private var scale

    init(title: String, reason: String?, terms: [String], selected: Bool, hairline: Bool, ink: Bool = false, help: String? = nil,
         axLabel: String, axValue: String? = nil, hover: @escaping () -> Void, open: @escaping () -> Void,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title; self.reason = reason; self.terms = terms; self.selected = selected; self.hairline = hairline
        self.ink = ink; self.help = help; self.axLabel = axLabel; self.axValue = axValue
        self.hover = hover; self.open = open; self.accessory = accessory()
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 8) {
                Text(Self.mark(title, terms, SettingsMetrics.titleSize)).font(.system(size: SettingsMetrics.titleSize))
                    .foregroundStyle(ink ? AnyShapeStyle(Color.brandInk) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let r = reason, !r.isEmpty {
                    Text(Self.mark(r, terms, SettingsMetrics.detailSize)).font(.system(size: SettingsMetrics.detailSize))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 12)
                accessory
            }
            .frame(minHeight: ResultsMetrics.rowHeight)
            .padding(.vertical, 6).padding(.horizontal, SettingsMetrics.boxInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                if hairline {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1 / max(scale, 1)).padding(.horizontal, SettingsMetrics.boxInset)
                        .allowsHitTesting(false)
                }
            }
            .background(ResultWash(on: selected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
        .onHover { if $0 && !selected { hover() } }
        .accessibilityLabel(axLabel)
        .accessibilityValue(axValue ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The words of the query, wherever they are in `s`, in semibold (case and accents don't matter).
    static func mark(_ s: String, _ terms: [String], _ size: CGFloat) -> AttributedString {
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

/// The chosen result's wash: the whole row inside its box (the box's corners clip it), brand tint while the window is
/// key, a neutral 6 % otherwise (§3.3's selection).
private struct ResultWash: View {
    var on: Bool
    @Environment(\.controlActiveState) private var active
    var body: some View {
        Rectangle().fill(on ? (active == .key || SettingsTestKeyLook.on ? Color.brandTint : Color.primary.opacity(0.06)) : Color.clear)
    }
}
