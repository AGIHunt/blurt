// What the main window shows: the sidebar place, the filters, the search text — and the matching rows, read straight
// from index.db (IndexReader v3, read-only) — plus the projects (projects.json, K2) and the running jobs (K4).
// Reloads are synchronous on the main thread: on 20k items a filter change is ~10 ms and a search ~5–10 ms
// (Tests/BlurtCoreTests), so there is nothing to gain from going async and a lot of flicker to lose. Rows are fetched
// a page at a time: the table only ever asks for what is on screen.
//
// Places (K2 / K3):
//   Inbox        what needs you: new items and items an agent says are finished (new + to_verify)
//   In Progress  handed off, in progress, to verify — with the running jobs above the list
//   Unassigned   items not filed under a project yet (the inbox store)
//   All Items    everything, as a full table
//   Dictation    not items: what was dictated into other apps (DictationPage.swift replaces both columns)
//   <project>    one opened folder
//   <session>    one capture batch (a recording, a snap batch), reached from a job or a link
//
// Filters (kinds, State) are per place (BlurtCore/PlaceFilters.swift); the search text is the window's.
import AppKit
import BlurtCore

enum Scope: Hashable {
    case inbox, inProgress, unassigned, all
    /// the Dictation page (DictationPage.swift): no item rows
    case dictation
    case project(String)
    case session(String)

    var key: String {
        switch self {
        case .inbox: return "inbox"
        case .inProgress: return "progress"
        case .unassigned: return "unassigned"
        case .all: return "all"
        case .dictation: return "dictation"
        case .project(let p): return "project:" + p
        case .session(let s): return "session:" + s
        }
    }

    init?(key: String) {
        switch key {
        case "inbox": self = .inbox
        case "progress": self = .inProgress
        case "unassigned": self = .unassigned
        case "all": self = .all
        case "dictation": self = .dictation
        default:
            if key.hasPrefix("project:") { self = .project(String(key.dropFirst(8))) }
            else if key.hasPrefix("session:") { self = .session(String(key.dropFirst(8))) }
            else { return nil }
        }
    }

    /// The full table (every column, a header) — elsewhere the list is a dense one-line list.
    var isTable: Bool { self == .all }
    /// Whether the running jobs show above the list.
    var showsJobs: Bool {
        switch self { case .inbox, .inProgress, .project, .unassigned: return true; default: return false }
    }
    /// The project new captures and moves default to here (nil = none in particular).
    var projectID: String? {
        switch self { case .project(let p): return p; case .unassigned: return "inbox"; default: return nil }
    }
}

/// The state of the index itself, for the first-run / empty states.
enum IndexState: Equatable {
    case ready, missing, scanning, noScripts, outdated, failed(String)
}

/// One project in the sidebar: the registry's entry and the index's counts.
struct ProjectEntry: Equatable {
    let id: String, name: String, key: String, path: URL
    let registered: Bool, exists: Bool, pinned: Bool
    var open = 0, inbox = 0
}

final class MainModel {
    private(set) var reader: IndexReader?
    private(set) var indexState: IndexState = .missing

    /// The place on show. Each place keeps its own kinds and State filter (PlaceFilters): going somewhere puts that
    /// place's back, and the one left keeps what it had.
    var scope: Scope = .inbox {
        didSet {
            guard scope != oldValue else { return }
            filters.set(currentFilter, for: oldValue.key)
            applyFilters()
        }
    }
    var kinds: Set<String> = []                 // empty = every kind
    var state: String?                          // nil = all but discarded | "inbox" (needs you) | one of Lifecycle.states
    /// The other places' filters (the one on show lives in kinds / state).
    var filters = PlaceFilters()
    var text = ""
    var sort = "updated"
    var ascending = false

    private(set) var uids: [String] = []
    private(set) var counts = IndexCounts()
    private(set) var projects: [ProjectEntry] = []
    private(set) var jobs: [Job] = []            // active ones for this place (and failures waiting), newest first
    private(set) var lastReloadMS = 0.0

    private var pages: [Int: [ItemRow]] = [:]
    private let pageSize = 100
    private var version = 0
    private var poll: Timer?

    /// Called after every reload (rows may have changed) / when the sidebar's data changed / the jobs changed.
    var onReload: (() -> Void)?
    var onSidebar: (() -> Void)?
    var onIndexState: (() -> Void)?
    var onJobs: (() -> Void)?

    var rowCount: Int { uids.count }
    var filtered: Bool { !kinds.isEmpty || shownState != nil || !text.trimmingCharacters(in: .whitespaces).isEmpty }
    /// The State filter as this place applies it: none where there is no State control to show it.
    var shownState: String? { PlaceFilters.showsState(scope.key) ? state : nil }
    var currentFilter: PlaceFilter { PlaceFilter(kinds: Array(kinds), state: state) }
    /// Every place's filters, the one on show included (saved with the window state).
    var allFilters: PlaceFilters {
        var f = filters
        f.set(currentFilter, for: scope.key)
        return f
    }
    /// The place's own filters on show (after `scope` or `filters` were set from outside).
    func applyFilters() {
        let f = filters.filter(for: scope.key)
        kinds = Set(f.kinds)
        state = f.state
    }
    /// No items anywhere yet, discarded ones included (a first run): no filters to offer, no detail to point at.
    var isEmptyWorld: Bool { indexState == .ready && counts.all == 0 && counts.discarded == 0 }

    init() {
        open()
        poll = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in self?.tick() }
    }

    deinit { poll?.invalidate() }

    // MARK: index lifecycle

    func open() {
        do {
            let r = try IndexReader(url: BlurtPaths.indexDB)
            reader = r
            version = r.dataVersion
            indexState = r.lastFullScan() == nil && (try? r.count(ItemQuery())) == 0 ? .missing : .ready
        } catch IndexError.schema {
            reader = nil
            indexState = .outdated          // a v1 index: index.py rebuilds it on its next scan
        } catch {
            reader = nil
            indexState = Scripts.has("index.py") ? .missing : .noScripts
        }
        onIndexState?()
    }

    /// Full scan (first run, an outdated index, menu "Rescan"); the model reloads when index.py is done.
    func scan() {
        guard Scripts.has("index.py") else { indexState = .noScripts; onIndexState?(); return }
        let before = indexState
        indexState = .scanning
        onIndexState?()
        Scripts.indexScan { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success:
                self.reader = nil
                self.open()
                if self.indexState == .missing { self.indexState = .ready }   // scanned, just nothing captured yet
                self.onIndexState?()
                self.reloadAll()
            case .failure(let e):
                self.indexState = before == .ready ? .ready : .failed("\(e)")
                self.onIndexState?()
            }
        }
    }

    /// index.py committed something (an agent's items.py write, our own ops, the watcher's update).
    private func tick() {
        guard let r = reader else {
            if FileManager.default.fileExists(atPath: BlurtPaths.indexDB.path), indexState != .scanning {
                open()
                if reader != nil { reloadAll(); onIndexState?() }
            }
            return
        }
        let v = r.dataVersion
        if v != version {
            version = v
            let wasMissing = indexState == .missing
            if wasMissing { indexState = .ready }
            reloadAll()
            if wasMissing { onIndexState?() }
        }
    }

    // MARK: queries

    var query: ItemQuery {
        let state = shownState
        var q = ItemQuery(text: text, kinds: kinds.sorted(), states: state.flatMap { $0 == "inbox" ? nil : [$0] } ?? [],
                          inbox: state == "inbox", sort: sort, limit: 0)
        q.ascending = ascending
        switch scope {
        case .inbox: q.inbox = true
        case .inProgress: if state == nil { q.states = Lifecycle.states.filter(Lifecycle.active.contains) }
        case .unassigned: q.project = "inbox"
        case .project(let p): q.project = p
        case .session(let s): q.session = s; if sort == "updated" && !ascending { q.sort = "t_start" }
        case .all, .dictation: break
        }
        return q
    }

    func reloadAll() {
        reloadSidebar()
        reload()
    }

    func reloadSidebar() {
        let byID = Dictionary(((try? reader?.projects()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        counts = (try? reader?.counts()) ?? IndexCounts()
        var list = ProjectStore.shared.ordered.map { p -> ProjectEntry in
            var e = ProjectEntry(id: p.id, name: p.name, key: p.key, path: p.path, registered: true, exists: p.exists, pinned: p.pinned)
            e.open = byID[p.id]?.openItems ?? 0
            e.inbox = byID[p.id]?.inbox ?? 0
            return e
        }
        // folders the index found that aren't opened as projects (v0.6 workspaces): listed, dimmed, with their items
        let known = Set(list.map(\.id))
        for r in byID.values.sorted(by: { $0.name < $1.name }) where !r.isInbox && !known.contains(r.id) && (r.openItems > 0 || r.inbox > 0) {
            var e = ProjectEntry(id: r.id, name: r.name, key: r.key, path: URL(fileURLWithPath: r.path), registered: false,
                                 exists: FileManager.default.fileExists(atPath: r.path), pinned: false)
            e.open = r.openItems
            e.inbox = r.inbox
            list.append(e)
        }
        projects = list
        onSidebar?()
    }

    /// The running jobs, and organising that failed and still waits for a Retry or Dismiss (JobFailures): a recording
    /// whose organising failed has no items to be found by, so its job stays in its place until then.
    func reloadJobs() {
        let all = JobStore.shared.active + JobFailures.waiting(JobStore.shared.jobs)
        switch scope {
        case .project(let p): jobs = all.filter { $0.project == p }
        case .unassigned: jobs = all.filter { $0.project == "inbox" || $0.project == nil }
        default: jobs = scope.showsJobs ? all : []
        }
        onJobs?()
    }

    func reload() {
        let t0 = DispatchTime.now().uptimeNanoseconds
        pages.removeAll()
        overrides.removeAll()
        uids = scope == .dictation ? [] : (try? reader?.uids(query)) ?? []
        rowByUID = nil
        lastReloadMS = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        reloadJobs()
        onReload?()
        if ProcessInfo.processInfo.environment["BLURT_PERF"] != nil {    // query, then query + table reload + detail
            let total = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            NSLog("blurt main window: reload %@ “%@” → %d rows: query %.1f ms, on screen %.1f ms", scope.key, text, rowCount, lastReloadMS, total)
        }
    }

    /// A state change shown at once, before items.py and the index have it (the next reload from index.db agrees, or
    /// puts the truth back if the write failed): the rows take their new state, and those this place no longer lists
    /// (a key pressed in the Inbox, a discard) leave it.
    func optimistic(states: [String: String]) {
        guard !states.isEmpty else { return }
        let allowed = query.allowedStates.map(Set.init)
        overrides.merge(states) { _, n in n }
        let leaving = Set(states.filter { _, s in allowed.map { !$0.contains(s) } ?? (s == "discarded") }.keys)
        if !leaving.isEmpty {
            uids.removeAll(where: leaving.contains)
            rowByUID = nil
        }
        pages.removeAll()           // refetched for what's on screen, with the overrides
        onReload?()
    }
    /// States shown before the index has them (optimistic); a reload from the index drops them.
    private var overrides: [String: String] = [:]

    func item(at row: Int) -> ItemRow? {
        guard row >= 0, row < uids.count, let r = reader else { return nil }
        let p = row / pageSize
        if pages[p] == nil {
            let slice = Array(uids[(p * pageSize)..<min((p + 1) * pageSize, uids.count)])
            let rows = (try? r.items(uids: slice, terms: query.terms)) ?? []
            // a uid can vanish between the two queries (index.py committed): keep the row count stable until the reload
            let byUID = Dictionary(rows.map { r -> (String, ItemRow) in
                var r = r
                if let s = overrides[r.uid] { r.state = s }
                return (r.uid, r)
            }, uniquingKeysWith: { a, _ in a })
            pages[p] = slice.map { byUID[$0] ?? ItemRow(uid: $0, itemID: "", kind: "note", title: "…") }
        }
        return pages[p]?[row % pageSize]
    }

    /// uid → row, built on first use after a reload: keeping a big selection (⌘A on 20k rows) across a reload looks
    /// up every selected uid, which was quadratic with firstIndex.
    private var rowByUID: [String: Int]?
    func row(of uid: String) -> Int? {
        if rowByUID == nil { rowByUID = Dictionary(uids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a }) }
        return rowByUID?[uid]
    }

    func project(id: String) -> ProjectEntry? { projects.first { $0.id == id } }
    func sessionRow(id: String) -> SessionRow? { (try? reader?.session(id: id)) ?? nil }
    func itemRow(uid: String) -> ItemRow? { (try? reader?.item(uid: uid)) ?? nil }
    func items(uids: [String]) -> [ItemRow] { (try? reader?.items(uids: uids)) ?? [] }

    /// Title for the window.
    var scopeTitle: String {
        switch scope {
        case .inbox: return T("main.place.inbox")
        case .inProgress: return T("main.place.progress")
        case .unassigned: return T("project.inbox")
        case .all: return T("main.place.all")
        case .dictation: return T("dictation.history.sidebar")
        case .project(let p): return project(id: p)?.name ?? ProjectStore.shared.project(id: p)?.name ?? T("main.place.project")
        case .session(let s): return sessionRow(id: s).map(MainModel.title(of:)) ?? T("main.place.session")
        }
    }

    static func title(of s: SessionRow) -> String {
        if let t = s.title, !t.isEmpty { return t }
        let when = s.created.map { Loc.dateTime(Date(timeIntervalSince1970: $0)) } ?? URL(fileURLWithPath: s.dir).lastPathComponent
        switch s.mode {
        case "shots": return T("main.session.snaps", when)
        case "voice": return T("main.session.voice", when)
        default: return T("main.session.recording", when)
        }
    }

    static func relative(_ t: Double) -> String { Loc.relative(Date(timeIntervalSince1970: t)) }
    static func shortDate(_ t: Double) -> String { Loc.dateTime(Date(timeIntervalSince1970: t)) }
}
