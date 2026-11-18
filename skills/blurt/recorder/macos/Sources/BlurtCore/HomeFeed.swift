// Home's "Recent" (MainWindow/HomePage.swift): one timeline of what the user made with the capabilities that are on —
// dictations, cards (hanging and used), text read or translated from the screen (⌥C / ⌥T), recordings with their state
// (Recordings) and items — newest first, grouped by day, cut at a number of rows. The page
// gathers the three lists; what is shown of them is decided here, so it can be tested without the app.
//
//   merge   the three lists as one, newest first, at most `limit` rows. Kinds whose capability is off are left out
//           (their rows are not "recent": the capability is gone from the app). The result also says which kinds had
//           anything at all — each gets a "Show all …" link under the timeline — and which had rows cut.
//   days    the rows under their days (the day's first moment, in the user's calendar), the order kept.
//   stops   the keyboard's walk over the page (the capability rows and their switches, the lines under them, the
//           timeline, the links): where ↑ ↓ and Tab go from a stop.
import Foundation

public enum HomeFeed {
    public enum Kind: String, CaseIterable, Sendable {
        case dictation, card, screenText = "screen_text", recording, item

        /// The capability a kind of row belongs to: with it off, none of its rows show.
        public var capability: Capability {
            switch self {
            case .dictation: return .dictation
            case .card: return .cards
            case .screenText: return .screenText
            case .recording, .item: return .recording
            }
        }
    }

    /// One row of the timeline. `key` is the thing's own id (a dictation's id, a card's "<batch>#<n>", an item's uid);
    /// `id` is unique across kinds. `source` is the quiet line over the text (the app dictated into, "Snap", an item's
    /// id and project); `text` what was made (the dictation, the card's note, the item's title — "" when there is none).
    public struct Entry: Equatable, Identifiable, Sendable {
        public var kind: Kind
        public var key: String
        public var time: Date
        public var source: String
        public var text: String

        public var id: String { kind.rawValue + ":" + key }

        public init(kind: Kind, key: String, time: Date, source: String = "", text: String = "") {
            self.kind = kind; self.key = key; self.time = time; self.source = source; self.text = text
        }
    }

    public struct Feed: Equatable, Sendable {
        /// newest first, at most the limit
        public var entries: [Entry] = []
        /// the kinds that had rows to show (before the cut), in the capabilities' order: each has a "Show all" link
        public var kinds: [Kind] = []
        /// the kinds some of whose rows were cut
        public var cut: Set<Kind> = []

        public init() {}
        public var isEmpty: Bool { entries.isEmpty }
    }

    public static let limit = 40

    /// The timeline: every list's rows of the kinds whose capability is on, newest first (rows of one moment: in the
    /// capabilities' order, then by key — the order never depends on the lists' own), cut at `limit`.
    public static func merge(dictations: [Entry], cards: [Entry], screenTexts: [Entry] = [], recordings: [Entry] = [], items: [Entry],
                             limit: Int = HomeFeed.limit, off: Set<Capability> = []) -> Feed {
        let order: [Kind: Int] = [.dictation: 0, .card: 1, .screenText: 2, .recording: 3, .item: 4]
        var seen = Set<String>()
        let all = (dictations + cards + screenTexts + recordings + items)
            .filter { !off.contains($0.kind.capability) }
            .filter { seen.insert($0.id).inserted }          // a card listed as hanging and as used: once
            .sorted { a, b in
                if a.time != b.time { return a.time > b.time }
                if a.kind != b.kind { return (order[a.kind] ?? 0) < (order[b.kind] ?? 0) }
                return a.key < b.key
            }
        var f = Feed()
        f.entries = Array(all.prefix(max(0, limit)))
        f.kinds = Kind.allCases.filter { k in all.contains { $0.kind == k } }
        let shown = Dictionary(grouping: f.entries, by: \.kind).mapValues(\.count)
        f.cut = Set(f.kinds.filter { k in (shown[k] ?? 0) < all.filter { $0.kind == k }.count })
        return f
    }

    public struct Day: Equatable, Identifiable, Sendable {
        /// the day's first moment
        public var day: Date
        public var rows: [Entry]
        public var id: Date { day }
    }

    /// The rows under their days, in the order given (newest first in, newest day first out).
    public static func days(_ entries: [Entry], calendar: Calendar = .current) -> [Day] {
        var out: [Day] = []
        for e in entries {
            let d = calendar.startOfDay(for: e.time)
            if let last = out.indices.last, out[last].day == d { out[last].rows.append(e) } else { out.append(Day(day: d, rows: [e])) }
        }
        return out
    }

    // MARK: the keyboard's walk

    /// Somewhere the keyboard can be on the page.
    public enum Stop: Hashable, Sendable {
        /// a capability's row (its place) — only while the capability is on
        case row(Capability)
        /// its switch
        case toggle(Capability)
        /// the one button in a capability's row that fixes what stands in its way ("Turn On Dictation…", "Change…")
        case fix(Capability)
        /// a link of the page ("Open Inbox", "Show all dictation"), by its id
        case link(String)
        /// a row of the timeline (Entry.id)
        case entry(String)

        public var capability: Capability? {
            switch self {
            case .row(let c), .toggle(let c), .fix(let c): return c
            default: return nil
            }
        }
    }

    /// The page's stops, top to bottom, as the page lays them out: per capability its row (when on) and its switch,
    /// then the lines under the box, the timeline, the links that close it.
    public struct Walk: Equatable, Sendable {
        public var on: [Capability]
        /// the rows that show a fix now (only rows that are on do)
        public var fixes: [Capability]
        public var waiting: [String]
        public var entries: [String]
        public var closing: [String]

        public init(on: [Capability], fixes: [Capability] = [], waiting: [String] = [], entries: [String] = [], closing: [String] = []) {
            self.on = on; self.fixes = fixes.filter(on.contains); self.waiting = waiting; self.entries = entries; self.closing = closing
        }

        /// One stop per line, for ↑ and ↓: a capability's row (its switch when it is off), the lines, the timeline's
        /// rows, the links.
        public var lines: [Stop] {
            Capability.allCases.map { on.contains($0) ? Stop.row($0) : .toggle($0) }
                + waiting.map(Stop.link) + entries.map(Stop.entry) + closing.map(Stop.link)
        }

        /// Tab's stops: every row, its fix and its switch, the lines, the timeline as one stop (`current`, or its first
        /// row), the links.
        public func tabs(current: Stop?) -> [Stop] {
            var out: [Stop] = []
            for c in Capability.allCases {
                if on.contains(c) { out.append(.row(c)) }
                if fixes.contains(c) { out.append(.fix(c)) }
                out.append(.toggle(c))
            }
            out += waiting.map(Stop.link)
            if case .entry(let id)? = current, entries.contains(id) { out.append(.entry(id)) }
            else if let f = entries.first { out.append(.entry(f)) }
            out += closing.map(Stop.link)
            return out
        }

        public func contains(_ s: Stop) -> Bool {
            switch s {
            case .row(let c): return on.contains(c)
            case .toggle: return true
            case .fix(let c): return fixes.contains(c)
            case .link(let id): return waiting.contains(id) || closing.contains(id)
            case .entry(let id): return entries.contains(id)
            }
        }

        /// ↓ / ↑ from `from` (nil: nothing chosen yet — the first line, or the last going up). On a switch the walk
        /// stays in the switches' column through the box; it never wraps.
        public func vertical(from: Stop?, down: Bool) -> Stop? {
            let ls = lines
            guard !ls.isEmpty else { return nil }
            guard var from, contains(from) else { return down ? ls.first : ls.last }
            if case .fix(let c) = from { from = .row(c) }            // a fix is on its row's line
            if case .toggle(let c) = from, let i = Capability.allCases.firstIndex(of: c) {
                let j = i + (down ? 1 : -1)
                if Capability.allCases.indices.contains(j) { return .toggle(Capability.allCases[j]) }
                return down ? (ls.count > Capability.allCases.count ? ls[Capability.allCases.count] : from) : from
            }
            guard let i = ls.firstIndex(of: from) else { return from }
            let j = i + (down ? 1 : -1)
            return ls.indices.contains(j) ? ls[j] : from
        }

        /// ← / →: along a capability's line — its row, its fix when it shows one, its switch (an off row has only the
        /// switch).
        public func horizontal(from: Stop?, right: Bool) -> Stop? {
            guard let from, let c = from.capability else { return from }
            let line: [Stop] = (on.contains(c) ? [.row(c)] : []) + (fixes.contains(c) ? [.fix(c)] : []) + [.toggle(c)]
            guard let i = line.firstIndex(of: from) else { return from }
            let j = i + (right ? 1 : -1)
            return line.indices.contains(j) ? line[j] : from
        }

        /// Tab / ⇧Tab, round and round.
        public func tab(from: Stop?, forward: Bool) -> Stop? {
            let ts = tabs(current: from)
            guard !ts.isEmpty else { return nil }
            guard let from, let i = ts.firstIndex(of: from) else { return forward ? ts.first : ts.last }
            return ts[(i + (forward ? 1 : ts.count - 1)) % ts.count]
        }

        /// Where the keyboard is after the page changed under it: the same stop while it is still there; a row whose
        /// capability went off: its switch; a timeline row that left: the first one; otherwise nothing.
        public func keep(_ s: Stop?) -> Stop? {
            guard let s else { return nil }
            if contains(s) { return s }
            switch s {
            case .row(let c): return .toggle(c)
            case .fix(let c): return on.contains(c) ? .row(c) : .toggle(c)      // fixed (or off) under the keyboard
            case .entry: return entries.first.map(Stop.entry)
            default: return nil
            }
        }
    }
}
