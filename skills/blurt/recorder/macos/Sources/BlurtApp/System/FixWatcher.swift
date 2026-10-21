// Watches every workspace's sessions for items.json changes (FSEvents, file-level) and notices when an item's
// fix.state becomes "fixed" — whoever wrote it: an agent the app started (MCP mark_fixed or items.py fix), an
// interactive session in a terminal, or a teammate's sync. Then: the chicken pecks the bug (Peck.swift), a notification,
// and Spotlight is refreshed. A file seen for the first time is only a baseline (no pecking for old fixes).
import AppKit
import CoreServices
import BlurtCore

final class FixWatcher {
    static let shared = FixWatcher()

    private var stream: FSEventStreamRef?
    private var roots: [String] = []
    private var states: [String: [String: String]] = [:]      // items.json path → uid → fix.state ("" = none)
    private var rootTimer: Timer?
    var onChange: ((URL) -> Void)?                             // a session's items.json changed (debounced by caller)
    var onFixed: ((_ uid: String, _ item: [String: Any], _ session: URL) -> Void)?

    static func sessionRoots() -> [URL] {
        var ws = [defaultWorkspace] + knownWorkspaces() + [currentWorkspace()]
        if let extra = Config.shared["record.workspaces"] as? [String] { ws += extra.map { URL(fileURLWithPath: $0) } }
        var seen = Set<String>()
        return ws.map { sessionsRoot(for: $0).standardizedFileURL }.filter { seen.insert($0.path).inserted }
    }

    func start() {
        restartIfNeeded()
        rootTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.restartIfNeeded() }
    }

    private func restartIfNeeded() {
        let want = FixWatcher.sessionRoots().map(\.path).filter { FileManager.default.fileExists(atPath: $0) }.sorted()
        guard want != roots else { return }
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil }
        roots = want
        // baseline: every items.json under the roots
        for r in want {
            for d in (try? FileManager.default.contentsOfDirectory(atPath: r)) ?? [] {
                let f = "\(r)/\(d)/items.json"
                if states[f] == nil, FileManager.default.fileExists(atPath: f) { states[f] = fixStates(f) }
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
        // items.py writes atomically (tmp file + rename): look at the session's items.json, whatever the event path
        var files = Set<String>()
        for p in paths {
            let u = URL(fileURLWithPath: p)
            let dir = u.lastPathComponent == "items.json" || u.lastPathComponent.hasPrefix("items.json") || u.lastPathComponent.hasPrefix(".items")
                ? u.deletingLastPathComponent() : nil
            if let d = dir { files.insert(d.appendingPathComponent("items.json").path) }
        }
        for f in files { check(f) }
    }

    /// Compare one items.json with what we knew (also called directly by FixRunner when its run ends).
    func check(_ f: String) {
        guard FileManager.default.fileExists(atPath: f) else { states[f] = nil; return }
        let session = URL(fileURLWithPath: f).deletingLastPathComponent()
        onChange?(session)
        let known = states[f]
        let now = fixStates(f)
        states[f] = now
        guard let before = known else { return }        // first sight: baseline only
        let items = readItems(session)
        for (uid, st) in now where st == "fixed" && before[uid] != "fixed" {
            let item = items.first { ($0["uid"] as? String) == uid } ?? [:]
            onFixed?(uid, item, session)
        }
    }

    private func fixStates(_ f: String) -> [String: String] {
        var out: [String: String] = [:]
        for it in readItems(URL(fileURLWithPath: f).deletingLastPathComponent()) {
            guard let uid = it["uid"] as? String else { continue }
            out[uid] = (it["fix"] as? [String: Any])?["state"] as? String ?? ""
        }
        return out
    }
}
