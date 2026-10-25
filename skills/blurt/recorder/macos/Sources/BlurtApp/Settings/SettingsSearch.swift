// Where the Settings window is and the search across all of it.
//   SettingsNavigator   the pane showing, the query and its results (SettingsCatalog.results: titles, descriptions and
//                       keywords, English and Chinese, grouped by pane), the stop chosen with ↑ / ↓ or the pointer.
//   SettingsFlash       the row to scroll to — a hit opened, a link (show(pane: "speech/dictation")), a test hook — and
//                       the row flashing there in the brand tint; a row folded away (Dictation's By kind of app) is
//                       unfolded by its pane first. Apart from the navigator so that the rows of every kept page, which
//                       watch it, don't redraw with each key typed in the search.
//   SettingsSearchResults  the page while searching, Raycast-like: a quiet line with the count and the query (and ↑↓ / ↩
//                       on its right), then one group per pane in the sidebar's counts — a small heading, the pane's
//                       sections as smaller captions, one-line rows over hairlines. A row is its title with the matched
//                       words in semibold, why it matched when the title doesn't say (a stretch of its description, a
//                       keyword, its other-language name) and, for a shortcut, its keys as keycaps on the right. A pane
//                       found by its name ("short") leads with "Open Shortcuts settings", then its first rows and
//                       "Show 9 more". Restore defaults is an action: only found by its own words, in brand ink. One
//                       stop is tinted (brand tint when the window is key) with ↩ at its end; the pointer moving onto
//                       a row makes it the keyboard's choice, as in Raycast. Click or ↩ opens it in its pane.
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
            for r in runs {
                let first = r[0].entry
                let title = first.kind == .section ? nil : first.section.flatMap(SettingsCatalog.section).flatMap { SettingsCatalog.text($0.title) }
                let named = title.flatMap { $0 == SettingsPane(rawValue: g.pane)?.title ? nil : $0 }
                if let t = named, g.paneHit || r.count > 1, let s = first.section { lines.append(.section(s, t)) }
                for h in r { add(.hit(h), section: !g.paneHit && r.count == 1 ? named : nil) }
            }
            if folds { add(.more(g.pane)) }
        }
        self.items = items
        self.lines = lines
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
    /// the column's widest, gutters included: the keycaps stay near the titles they belong to
    static let width: CGFloat = 560 + 2 * SettingsMetrics.gutter
    static let rowHeight: CGFloat = 22
}

struct SettingsSearchResults: View {
    @ObservedObject var nav = SettingsNavigator.shared
    /// the pen's hold key, shown on its row
    @ObservedObject private var keys = HotkeySettings.shared

    var body: some View {
        Group {
            if nav.items.isEmpty {
                EmptyStateContent(title: T("settings.search.none.title", query),
                                  message: T("settings.search.none.hint"))
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            header
                            ForEach(Array(nav.lines.enumerated()), id: \.element.id) { k, line in
                                lineView(line, at: k)
                            }
                        }
                        .padding(.horizontal, SettingsMetrics.gutter).padding(.top, 16).padding(.bottom, 40)
                        .frame(maxWidth: ResultsMetrics.width, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: nav.keyMoves) { _ in proxy.scrollTo(nav.selected) }
                }
                // the bottom edge as the top: rows go under a short fade instead of being cut by the window
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [SettingsMetrics.ground.opacity(0), SettingsMetrics.ground], startPoint: .top, endPoint: .bottom)
                        .frame(height: SettingsMetrics.topFade)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .settingsPageGround()
    }

    var query: String { nav.query.trimmingCharacters(in: .whitespaces) }
    var terms: [String] { nav.query.split(whereSeparator: { $0.isWhitespace }).map(String.init) }

    /// "17 results for “short”", and how to walk them.
    var header: some View {
        HStack(alignment: .center, spacing: 12) {
            let n = nav.hits.count
            Text(n == 1 ? T("settings.search.count.one", query) : T("settings.search.count", n, query))
                .font(.system(size: SettingsMetrics.titleSize)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                KeyCaps(keys: ["↑", "↓"])
                Text(T("settings.search.hint.choose"))
                KeyCaps(keys: ["↩"]).padding(.leading, 6)
                Text(T("settings.search.hint.open"))
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityHidden(true)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    func lineView(_ line: SettingsNavigator.Line, at k: Int) -> some View {
        switch line {
        case .group(let g):
            groupHeading(g, first: k == 0)
        case .section(_, let title):
            Text(marked(title, 11)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.top, 10).padding(.bottom, 3)
                .accessibilityAddTraits(.isHeader)
        case .item(let i, _, let section):
            if nav.items.indices.contains(i) { row(nav.items[i], i, section: section, hairline: hairline(before: k, i)) }
        }
    }

    /// A pane's heading: its symbol and name, the number of its settings found on the right (as in the sidebar).
    func groupHeading(_ g: SettingsResultGroup, first: Bool) -> some View {
        let p = SettingsPane(rawValue: g.pane)
        return HStack(spacing: 6) {
            Image(systemName: p?.symbol ?? "gearshape").font(.system(size: 11, weight: .semibold)).frame(width: 14)
                .accessibilityHidden(true)
            Text(p?.title ?? g.pane).font(.system(size: 12, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Text(Loc.number(g.hits.count)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.secondary)
        .padding(.top, first ? 20 : 26).padding(.bottom, 4)
    }

    /// A hairline over a row that follows another row — none next to the tinted one, whose wash is its edge.
    func hairline(before k: Int, _ i: Int) -> Bool {
        guard k > 0, case .item(let j, _, _) = nav.lines[k - 1] else { return false }
        return nav.selected != i && nav.selected != j
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
                      hover: hover, open: open) { EmptyView() }
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

    /// On a row's right: a shortcut's keys as keycaps ("None" / "Off" without one); Restore defaults' glyph; else the
    /// section, when no caption above says it.
    @ViewBuilder
    func accessory(_ e: SettingsEntry, section: String?) -> some View {
        if let k = Self.keys(e) {
            if k.isEmpty {
                let off = e.id == "shortcuts.dictation" || e.id == "shortcuts.draw_key"
                Text(Loc.t(off ? "capture.keys.off" : "capture.keys.none", table: "Capture"))
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                KeyCaps(keys: k)
            }
        } else if SettingsCatalog.actions.contains(e.id) {
            Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.brandInk).accessibilityHidden(true)
        } else if let s = section {
            Text(marked(s, 11)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
    }

    /// A shortcut row's keys, one keycap each ("⌥", "⇧", "R"); [] when it has none; nil for a row that isn't a key.
    static func keys(_ e: SettingsEntry) -> [String]? {
        switch e.id {
        case "shortcuts.dictation":
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
                Text("↩").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 14).opacity(selected ? 1 : 0).accessibilityHidden(true)
            }
            .frame(minHeight: ResultsMetrics.rowHeight)
            .padding(.vertical, 6).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                if hairline {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1 / max(scale, 1)).padding(.horizontal, 10)
                        .allowsHitTesting(false)
                }
            }
            .background(RowWash(on: selected).padding(.horizontal, -6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -10)
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

/// Keys as small keycaps — neutral fill, 11 pt medium — one per key ("⌥" "⇧" "R"), as on a keyboard.
struct KeyCaps: View {
    let keys: [String]
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                Text(k).font(.system(size: size, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .frame(minWidth: size + 7, minHeight: size + 7)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.07)))
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined())
    }

    /// "⌃⌥⇧R" → ["⌃", "⌥", "⇧", "R"]: each modifier its own cap, the key after them one cap ("F5", "Space").
    static func split(_ label: String) -> [String] {
        var caps: [String] = [], rest = ""
        for c in label {
            if rest.isEmpty, "⌃⌥⇧⌘".contains(c) { caps.append(String(c)) } else { rest.append(c) }
        }
        return rest.isEmpty ? caps : caps + [rest]
    }
}
