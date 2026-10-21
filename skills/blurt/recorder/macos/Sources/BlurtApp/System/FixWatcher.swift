// Watches every item store (each project's .blurt/ and the inbox — K1) for item files whose work.state becomes
// "to_verify" (K3) — whoever wrote it: an agent in a Blurt session (mark_fixed / items.py work), the session monitor
// when the agent exited, a worktree merge, an agent outside Blurt with the MCP. Then the chicken pecks the item and
// a notification says so (FixRunner.announceFixed). A file seen for the first time is only a baseline.
import AppKit
import CoreServices
import BlurtCore

final class FixWatcher {
    static let shared = FixWatcher()

    private var stream: FSEventStreamRef?
    private var roots: [String] = []
    private var states: [String: String] = [:]                // item file path → work.state
    private var rootTimer: Timer?
    var onChange: ((URL) -> Void)?                             // a store's items changed
    var onFixed: ((_ uid: String, _ item: [String: Any], _ file: URL) -> Void)?

    /// Every store: registered projects and the inbox.
    static func stores() -> [URL] {
        let ps = ProjectStore.shared
        var seen = Set<String>()
        return (ps.projects.map(\.store) + [ps.inbox.store]).map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }

    /// Where recordings live, for the storage panes: each store's sessions/ plus the v0.6 locations still on disk.
    static func sessionRoots() -> [URL] {
        var ws = [defaultWorkspace] + knownWorkspaces() + [currentWorkspace()]
        if let extra = Config.shared["record.workspaces"] as? [String] { ws += extra.map { URL(fileURLWithPath: $0) } }
        var seen = Set<String>()
        return (stores().map { $0.appendingPathComponent("sessions") } + ws.map { sessionsRoot(for: $0) })
            .map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }

    func start() {
        restartIfNeeded()
        rootTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.restartIfNeeded() }
    }

    private func restartIfNeeded() {
        let want = FixWatcher.stores().map { $0.appendingPathComponent("items").path }
            .filter { FileManager.default.fileExists(atPath: $0) }.sorted()
        guard want != roots else { return }
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil }
        roots = want
        for r in want {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: r)) ?? [] where f.hasSuffix(".md") {
                let p = "\(r)/\(f)"
                if states[p] == nil { states[p] = Self.frontMatter(URL(fileURLWithPath: p)).flatMap(Self.workState) ?? "todo" }
            }
        }
        guard !want.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, n, paths, _, _ in
            guard let info = info else { return }
            let me = Unmanaged<FixWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.changed(Array(arr.prefix(n)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, want as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    private func changed(_ paths: [String]) {
        // items.py writes atomically (temp file + rename in items/): look at the .md files the events name
        var stores = Set<String>()
        for p in Set(paths) where p.hasSuffix(".md") {
            check(URL(fileURLWithPath: p))
            stores.insert(URL(fileURLWithPath: p).deletingLastPathComponent().deletingLastPathComponent().path)
        }
        for s in stores { onChange?(URL(fileURLWithPath: s)) }
    }

    /// Compare one item file with what we knew.
    func check(_ file: URL) {
        let p = file.path
        guard FileManager.default.fileExists(atPath: p), let fm = Self.frontMatter(file) else { states[p] = nil; return }
        let now = Self.workState(fm) ?? "todo"
        let before = states[p]
        states[p] = now
        guard let b = before, b != "to_verify", now == "to_verify", let uid = fm["uid"] as? String else { return }
        onFixed?(uid, fm, file)
    }

    static func workState(_ fm: [String: Any]) -> String? { (fm["work"] as? [String: Any])?["state"] as? String }

    /// The K1 front-matter: one `key: value` per line between the `---` fences; values that look like JSON are JSON.
    static func frontMatter(_ url: URL) -> [String: Any]? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let head = String(decoding: (try? h.read(upToCount: 64 * 1024)) ?? Data(), as: UTF8.self)
        var lines = head.split(separator: "\n", omittingEmptySubsequences: false).makeIterator()
        guard lines.next()?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var out: [String: Any] = [:]
        while let line = lines.next() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { return out }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = String(line[..<colon])
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let first = raw.first, "{[\"".contains(first) || ["true", "false", "null"].contains(raw) || Double(raw) != nil,
               let v = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]) {
                out[key] = v
            } else {
                out[key] = raw
            }
        }
        return nil
    }
}
