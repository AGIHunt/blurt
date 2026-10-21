// What the main window shows: the sidebar scope, the filters, the search text — and the matching rows, read straight
// from index.db (IndexReader, read-only). Reloads are synchronous on the main thread: on 20k items a filter change is
// ~10 ms and a search ~5–10 ms (Tests/BlurtCoreTests), so there is nothing to gain from going async and a lot of
// flicker to lose. Rows are fetched a page at a time: the table only ever asks for what is on screen.
import AppKit
import BlurtCore

enum Smart: String, CaseIterable {
    case openIssues, ideas, fixing, fixed
}

enum Scope: Hashable {
    case inbox, all, sessions
    case smart(Smart)
    case workspace(String)
    case session(String)

    var key: String {
        switch self {
        case .inbox: return "inbox"
        case .all: return "all"
        case .sessions: return "sessions"
        case .smart(let s): return "smart:" + s.rawValue
        case .workspace(let w): return "ws:" + w
        case .session(let s): return "session:" + s
        }
    }

    init?(key: String) {
        switch key {
        case "inbox": self = .inbox
        case "all": self = .all
        case "sessions": self = .sessions
        default:
            if key.hasPrefix("smart:"), let s = Smart(rawValue: String(key.dropFirst(6))) { self = .smart(s) }
            else if key.hasPrefix("ws:") { self = .workspace(String(key.dropFirst(3))) }
            else if key.hasPrefix("session:") { self = .session(String(key.dropFirst(8))) }
            else { return nil }
        }
    }

    /// Inbox and All Sessions list sessions; everything else lists items.
    var listsSessions: Bool { self == .inbox || self == .sessions }
}

/// The state of the index itself, for the first-run / empty states.
enum IndexState: Equatable {
    case ready, missing, scanning, noScripts, failed(String)
}

final class MainModel {
    private(set) var reader: IndexReader?
    private(set) var indexState: IndexState = .missing

    var scope: Scope = .all
    var kinds: Set<String> = []                 // empty = every kind
    var status: String?                         // nil = all but deleted | draft | confirmed | deleted
    var fix: String?                            // nil = any | none | fixing | fixed | wontfix | reopened
    var text = ""
    var sort = "updated"
    var ascending = false

    private(set) var uids: [String] = []
    private(set) var sessions: [SessionRow] = []
    private(set) var counts = IndexCounts()
    private(set) var workspaces: [WorkspaceRow] = []
    private(set) var recentSessions: [SessionRow] = []
    private(set) var lastReloadMS = 0.0

    private var pages: [Int: [ItemRow]] = [:]
    private let pageSize = 100
    private var version = 0
    private var poll: Timer?

    /// Called after every reload (rows may have changed) / when the sidebar's data changed.
    var onReload: (() -> Void)?
    var onSidebar: (() -> Void)?
    var onIndexState: (() -> Void)?

    var rowCount: Int { scope.listsSessions ? sessions.count : uids.count }
    var filtered: Bool { !kinds.isEmpty || status != nil || fix != nil || !text.trimmingCharacters(in: .whitespaces).isEmpty }

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
        } catch {
            reader = nil
            indexState = Scripts.has("index.py") ? .missing : .noScripts
        }
        onIndexState?()
    }

    /// Full scan (first run, menu "Rescan"); the model reloads when index.py is done.
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
                if self.indexState == .missing { self.indexState = .ready }   // scanned, just nothing recorded yet
                self.onIndexState?()
                self.reloadAll()
            case .failure(let e):
                self.indexState = before == .ready ? .ready : .failed("\(e)")
                self.onIndexState?()
            }
        }
    }

    /// index.py committed something (an agent's items.py write, our own user-ops, the watcher's update).
    private func tick() {
        guard let r = reader else {
            if FileManager.default.fileExists(atPath: BlurtPaths.indexDB.path), indexState != .scanning {
                open()
                if reader != nil { reloadAll() }
            }
            return
        }
        let v = r.dataVersion
        if v != version {
            version = v
            if indexState == .missing { indexState = .ready; onIndexState?() }
            reloadAll()
        }
    }

    // MARK: queries

    var query: ItemQuery {
        var q = ItemQuery(text: text, kinds: kinds.sorted(), statuses: status.map { [$0] } ?? [],
                          fixStates: fix.map { [$0] } ?? [], sort: sort, limit: 0)
        q.ascending = ascending
        switch scope {
        case .smart(.openIssues):
            q.kinds = ["issue"]
            if fix == nil { q.fixStates = ["none", "fixing", "reopened"] }
        case .smart(.ideas): q.kinds = ["idea"]
        case .smart(.fixing): q.fixStates = ["fixing"]
        case .smart(.fixed): q.fixStates = ["fixed"]
        case .workspace(let w): q.workspace = w
        case .session(let s): q.session = s; if sort == "updated" && !ascending { q.sort = "t_start" }
        default: break
        }
        return q
    }

    func reloadAll() {
        reloadSidebar()
        reload()
    }

    func reloadSidebar() {
        guard let r = reader else { counts = IndexCounts(); workspaces = []; recentSessions = []; onSidebar?(); return }
        counts = (try? r.counts()) ?? IndexCounts()
        workspaces = (try? r.workspaces()) ?? []
        recentSessions = (try? r.sessions(SessionQuery(limit: 12))) ?? []
        onSidebar?()
    }

    func reload() {
        let t0 = DispatchTime.now().uptimeNanoseconds
        pages.removeAll()
        if let r = reader {
            if scope.listsSessions {
                uids = []
                var s = (try? r.sessions(SessionQuery(state: scope == .inbox ? "inbox" : nil, limit: 0))) ?? []
                let t = text.trimmingCharacters(in: .whitespaces).lowercased()
                if !t.isEmpty {
                    s = s.filter { ($0.title ?? "").lowercased().contains(t) || $0.dir.lowercased().contains(t) || ($0.workspaceName ?? "").lowercased().contains(t) }
                }
                sessions = s
            } else {
                sessions = []
                uids = (try? r.uids(query)) ?? []
            }
        } else {
            uids = []; sessions = []
        }
        lastReloadMS = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        onReload?()
        if ProcessInfo.processInfo.environment["BLURT_PERF"] != nil {    // query, then query + table reload + detail
            let total = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            NSLog("blurt main window: reload %@ “%@” → %d rows: query %.1f ms, on screen %.1f ms", scope.key, text, rowCount, lastReloadMS, total)
        }
    }

    func item(at row: Int) -> ItemRow? {
        guard !scope.listsSessions, row >= 0, row < uids.count, let r = reader else { return nil }
        let p = row / pageSize
        if pages[p] == nil {
            let slice = Array(uids[(p * pageSize)..<min((p + 1) * pageSize, uids.count)])
            let rows = (try? r.items(uids: slice, terms: query.terms)) ?? []
            // a uid can vanish between the two queries (index.py committed): keep the row count stable until the reload
            let byUID = Dictionary(rows.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
            pages[p] = slice.map { byUID[$0] ?? ItemRow(uid: $0, sessionID: "", sessionDir: "", itemID: "", kind: "note", title: "…", status: "draft") }
        }
        return pages[p]?[row % pageSize]
    }

    func session(at row: Int) -> SessionRow? {
        guard scope.listsSessions, row >= 0, row < sessions.count else { return nil }
        return sessions[row]
    }

    func row(of uid: String) -> Int? { uids.firstIndex(of: uid) }
    func row(ofSession id: String) -> Int? { sessions.firstIndex { $0.id == id } }

    func workspace(id: String) -> WorkspaceRow? { workspaces.first { $0.id == id } }
    func workspace(ofSession sessionID: String) -> WorkspaceRow? {
        sessionID.split(separator: ":").first.flatMap { workspace(id: String($0)) }
    }
    func sessionRow(id: String) -> SessionRow? {
        recentSessions.first { $0.id == id } ?? sessions.first { $0.id == id } ?? (try? reader?.session(id: id)) ?? nil
    }
    func itemRow(uid: String) -> ItemRow? { (try? reader?.item(uid: uid)) ?? nil }

    /// Title for the window / the list header.
    var scopeTitle: String {
        switch scope {
        case .inbox: return L("收件箱", "Inbox")
        case .all: return L("全部条目", "All Items")
        case .sessions: return L("全部会话", "All Sessions")
        case .smart(.openIssues): return L("待修问题", "Open Issues")
        case .smart(.ideas): return L("想法", "Ideas")
        case .smart(.fixing): return L("Agent 修复中", "Agent Fixing")
        case .smart(.fixed): return L("已修复", "Fixed")
        case .workspace(let w): return workspace(id: w)?.name ?? L("项目", "Project")
        case .session(let s): return sessionRow(id: s).map { MainModel.title(of: $0) } ?? L("会话", "Session")
        }
    }

    static func title(of s: SessionRow) -> String {
        if let t = s.title, !t.isEmpty { return t }
        if let c = s.created { return (s.mode == "shots" ? L("截图 ", "Snaps ") : L("录屏 ", "Recording ")) + shortDate(c) }
        return URL(fileURLWithPath: s.dir).lastPathComponent
    }

    /// Dates in the app's language (--lang / the system's), like every other string here.
    static let locale = Locale(identifier: L("zh_CN", "en_US"))
    static let dayFmt: DateFormatter = { let f = DateFormatter(); f.locale = locale; f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true; return f }()
    static func shortDate(_ t: Double) -> String { dayFmt.string(from: Date(timeIntervalSince1970: t)) }

    static let relFmt: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.locale = locale; f.unitsStyle = .short; return f }()
    static func relative(_ t: Double) -> String {
        let d = Date(timeIntervalSince1970: t)
        if abs(d.timeIntervalSinceNow) < 60 { return L("刚刚", "just now") }
        return relFmt.localizedString(for: d, relativeTo: Date())
    }
}
