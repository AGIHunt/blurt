// FSEvents on the session containers (~/Blurt/recordings, <repo>/.blurt/sessions…) → the session dirs that changed,
// debounced (300 ms, §3). The app then runs `index.py update <dirs>`; index.py is the only writer of index.db.
//
// Only changes that matter to the index count: items.json, meta.json, shots.jsonl, recording.mp4, and a session dir
// appearing or disappearing. Frames being written, live/ captions, logs and lock files don't wake anybody up.
import CoreServices
import Foundation

public final class IndexWatcher {
    /// Session containers: each direct child directory is one session.
    public let roots: [URL]
    public var onChange: (([URL]) -> Void)?
    public var debounce: TimeInterval = 0.3

    private var stream: FSEventStreamRef?
    private var pending = Set<String>()
    private var timer: DispatchWorkItem?
    private let queue = DispatchQueue(label: "dev.blurt.index-watcher")
    private let rootPaths: [String]

    static let relevant: Set<String> = ["items.json", "meta.json", "shots.jsonl", "recording.mp4"]

    public init(roots: [URL]) {
        self.roots = roots
        rootPaths = roots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
    }

    deinit { stop() }

    /// Starts watching (the roots that exist). Callbacks arrive on the main queue.
    public func start() {
        guard stream == nil else { return }
        let paths = rootPaths.filter { FileManager.default.fileExists(atPath: $0) }
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

    /// The session dir a changed path belongs to, if the change is one the index cares about.
    public func sessionDir(for path: String) -> String? {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        for root in rootPaths where p.hasPrefix(root + "/") {
            let rest = p.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: true)
            guard let first = rest.first, !first.hasPrefix(".") else { return nil }
            if rest.count == 1 { return root + "/" + first }                       // the session dir itself
            if rest.count == 2, Self.relevant.contains(String(rest[1])) { return root + "/" + first }
            return nil
        }
        return nil
    }

    private func received(_ paths: [String]) {
        let dirs = paths.compactMap(sessionDir(for:))
        guard !dirs.isEmpty else { return }
        pending.formUnion(dirs)
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
