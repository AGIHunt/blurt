// FSEvents on the item stores (<project>/.blurt, ~/Blurt/inbox — K1) and on legacy session containers
// (~/Blurt/recordings) → the paths index.py should look at again, debounced (300 ms). The app then runs
// `index.py update <paths>`; index.py is the only writer of index.db.
//
// What counts: an item file (<store>/items/*.md) appearing, changing or going away, and in a session dir
// (<store>/sessions/<s>/, or <legacy root>/<s>/) the files the index reads — batch.json, items.json (the agent's
// draft, ingested by items.py), meta.json, shots.jsonl, recording.mp4 — or the dir itself. Frames being written,
// live/ captions, logs and lock files wake nobody up.
import CoreServices
import Foundation

public final class IndexWatcher {
    /// Item stores: items/ and sessions/ underneath.
    public let stores: [URL]
    /// Legacy session containers: each direct child directory is one session.
    public let legacyRoots: [URL]
    public var onChange: (([URL]) -> Void)?
    public var debounce: TimeInterval = 0.3

    private var stream: FSEventStreamRef?
    private var pending = Set<String>()
    private var timer: DispatchWorkItem?
    private let queue = DispatchQueue(label: "dev.blurt.index-watcher")
    private let storePaths: [String]
    private let legacyPaths: [String]

    static let relevant: Set<String> = ["batch.json", "items.json", "meta.json", "shots.jsonl", "recording.mp4"]

    public init(stores: [URL], legacyRoots: [URL] = []) {
        self.stores = stores
        self.legacyRoots = legacyRoots
        storePaths = stores.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        legacyPaths = legacyRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
    }

    deinit { stop() }

    /// Starts watching (the roots that exist). Callbacks arrive on the main queue.
    public func start() {
        guard stream == nil else { return }
        let paths = (storePaths + legacyPaths).filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, n, paths, _, _ in
            guard let info = info else { return }
            let me = Unmanaged<IndexWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.received(Array(arr.prefix(n)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    /// The path index.py should update for a changed path (an item file or a session dir), nil if it doesn't matter.
    public func target(for path: String) -> String? {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        for root in storePaths where p.hasPrefix(root + "/") {
            let rest = p.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: true)
            guard let top = rest.first else { return nil }
            if top == "items", rest.count == 2, rest[1].hasSuffix(".md"), !rest[1].hasPrefix(".") { return p }
            if top == "sessions", rest.count >= 2, !rest[1].hasPrefix(".") {
                let dir = root + "/sessions/" + rest[1]
                if rest.count == 2 { return dir }
                if rest.count == 3, Self.relevant.contains(String(rest[2])) { return dir }
            }
            return nil
        }
        for root in legacyPaths where p.hasPrefix(root + "/") {
            let rest = p.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: true)
            guard let first = rest.first, !first.hasPrefix(".") else { return nil }
            if rest.count == 1 { return root + "/" + first }
            if rest.count == 2, Self.relevant.contains(String(rest[1])) { return root + "/" + first }
            return nil
        }
        return nil
    }

    private func received(_ paths: [String]) {
        let hits = paths.compactMap(target(for:))
        guard !hits.isEmpty else { return }
        pending.formUnion(hits)
        timer?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, !self.pending.isEmpty else { return }
            let out = self.pending.sorted().map { URL(fileURLWithPath: $0) }
            self.pending.removeAll()
            DispatchQueue.main.async { self.onChange?(out) }
        }
        timer = w
        queue.asyncAfter(deadline: .now() + debounce, execute: w)
    }
}
