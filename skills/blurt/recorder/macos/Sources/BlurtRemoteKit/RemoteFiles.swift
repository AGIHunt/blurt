// Files and the clipboard's content between any two ends (docs/design/remote-files.md, remote-protocol.md §Clipboard and files): the
// same engine on the Mac host, the Mac viewer and the iPhone. A sender goes one file at a time, a chunk at a time, never more than
// `window` past what the receiver says it has written; a receiver writes a part, keeps it an hour if the session drops, and goes on from
// there when the same file begins again. Nothing here knows which way the wire's enums point: callers map RemoteFileOut and
// RemoteFileAnswer onto ToMac / ToPhone.
import Foundation

public enum RemoteFiles {
    public static let chunk = 192 * 1024
    public static let window = 4 << 20
    public static let progressEvery = 1 << 20
    public static let maxSize = 4 << 30
    public static let maxCount = 1000
    /// an image the phone pastes
    public static let maxClipImage = 20 << 20
    /// a dropped file's part waits this long for the same file to begin again
    public static let keepParts: TimeInterval = 3600
    /// a sender that sees `resume` waits this long for the receiver to say where to start
    public static let resumeWait: TimeInterval = 10
    /// the receiver keeps this much free beyond the file
    public static let spare: Int64 = 256 << 20
    /// a phone on mobile data asks before more than this goes either way
    public static let askOnCellular = 100_000_000

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"]
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "hevc", "avi", "3gp"]

    public static func isImage(_ name: String) -> Bool { imageExtensions.contains((name as NSString).pathExtension.lowercased()) }
    public static func isMedia(_ name: String) -> Bool {
        let e = (name as NSString).pathExtension.lowercased()
        return imageExtensions.contains(e) || videoExtensions.contains(e)
    }

    /// A name to write under: no folders, no `:`, no hidden or empty names, at most 200 characters.
    public static func clean(_ name: String) -> String {
        var n = (name.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        n = String(n.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(Character.init))
        while n.hasPrefix(".") { n.removeFirst() }
        return n.isEmpty ? "file" : String(n.prefix(200))
    }

    /// `u`, or the first of "name 2.ext", "name 3.ext" … not taken.
    public static func unique(_ u: URL) -> URL {
        guard FileManager.default.fileExists(atPath: u.path) else { return u }
        let base = u.deletingPathExtension().lastPathComponent, ext = u.pathExtension, dir = u.deletingLastPathComponent()
        for i in 2...100_000 {
            let c = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            if !FileManager.default.fileExists(atPath: c.path) { return c }
        }
        return u
    }

    /// Folders become zip files (in a temporary folder), files stay: what a sender sends for what the user picked. Synchronous; run it off
    /// the main thread. A folder that can't be zipped is left out.
    public static func prepare(_ urls: [URL]) -> [URL] {
        urls.compactMap { u in
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) else { return nil }
            return dir.boolValue ? zip(u) : u
        }
    }

    /// Of what `prepare` gave, the zips it made (to delete once sent).
    public static func made(_ urls: [URL]) -> Set<URL> { Set(urls.filter { $0.deletingLastPathComponent().lastPathComponent.hasPrefix("blurt-zip-") }) }

    /// The system's own zip of a folder (what Files and Finder make for sharing one), named after the folder.
    public static func zip(_ folder: URL) -> URL? {
        var out: URL?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &err) { z in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-zip-" + UUID().uuidString)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(folder.lastPathComponent + ".zip")
            if (try? FileManager.default.copyItem(at: z, to: dest)) != nil { out = dest }
        }
        return out
    }

    /// Seconds left from what moved lately: nil until 2 s of progress.
    static func left(_ samples: [(t: TimeInterval, bytes: Int)], size: Int) -> Double? {
        guard let first = samples.first, let last = samples.last, last.t - first.t >= 2, last.bytes > first.bytes else { return nil }
        let rate = Double(last.bytes - first.bytes) / (last.t - first.t)
        return Double(max(0, size - last.bytes)) / rate
    }
}

/// A file's begin, either way: ToMac.fileBegin / ToPhone.fileBegin.
public struct RemoteFileInfo: Equatable, Sendable {
    public var id: String
    public var name: String
    public var size: Int
    public var clip: Bool
    public var index: Int?
    public var count: Int?
    public var total: Int?
    public init(id: String, name: String, size: Int, clip: Bool = false, index: Int? = nil, count: Int? = nil, total: Int? = nil) {
        self.id = id; self.name = name; self.size = size; self.clip = clip; self.index = index; self.count = count; self.total = total
    }
}

/// What a sender puts on the wire.
public enum RemoteFileOut: Equatable, Sendable {
    case begin(RemoteFileInfo)
    case chunk(id: String, data: Data)
    case end(id: String)
}

/// What a receiver answers.
public enum RemoteFileAnswer: Equatable, Sendable {
    case progress(id: String, bytes: Int)
    case saved(id: String, name: String)
    case failed(id: String, why: String)
}

public extension ToMac {
    init(_ o: RemoteFileOut) {
        switch o {
        case let .begin(i): self = .fileBegin(id: i.id, name: i.name, size: i.size, clip: i.clip ? true : nil, index: i.index, count: i.count, total: i.total)
        case let .chunk(id, d): self = .fileChunk(id: id, data: d)
        case let .end(id): self = .fileEnd(id: id)
        }
    }
    init(_ a: RemoteFileAnswer) {
        switch a {
        case let .progress(id, b): self = .fileProgress(id: id, bytes: b)
        case let .saved(id, n): self = .fileSaved(id: id, name: n)
        case let .failed(id, w): self = .fileFailed(id: id, why: w)
        }
    }
    /// A file going to the host, as the engine sees it (nil for anything else).
    var fileOut: RemoteFileOut? {
        switch self {
        case let .fileBegin(id, name, size, clip, index, count, total):
            return .begin(RemoteFileInfo(id: id, name: name, size: size, clip: clip ?? false, index: index, count: count, total: total))
        case let .fileChunk(id, d): return .chunk(id: id, data: d)
        case let .fileEnd(id): return .end(id: id)
        default: return nil
        }
    }
    /// The phone's or viewer's answer to a file from the host.
    var fileAnswer: RemoteFileAnswer? {
        switch self {
        case let .fileProgress(id, b): return .progress(id: id, bytes: b)
        case let .fileSaved(id, n): return .saved(id: id, name: n)
        case let .fileFailed(id, w): return .failed(id: id, why: w)
        default: return nil
        }
    }
}

public extension ToPhone {
    init(_ o: RemoteFileOut) {
        switch o {
        case let .begin(i): self = .fileBegin(id: i.id, name: i.name, size: i.size, clip: i.clip ? true : nil, index: i.index, count: i.count, total: i.total)
        case let .chunk(id, d): self = .fileChunk(id: id, data: d)
        case let .end(id): self = .fileEnd(id: id)
        }
    }
    init(_ a: RemoteFileAnswer) {
        switch a {
        case let .progress(id, b): self = .fileProgress(id: id, bytes: b)
        case let .saved(id, n): self = .fileSaved(id: id, name: n)
        case let .failed(id, w): self = .fileFailed(id: id, why: w)
        }
    }
    var fileOut: RemoteFileOut? {
        switch self {
        case let .fileBegin(id, name, size, clip, index, count, total):
            return .begin(RemoteFileInfo(id: id, name: name, size: size, clip: clip ?? false, index: index, count: count, total: total))
        case let .fileChunk(id, d): return .chunk(id: id, data: d)
        case let .fileEnd(id): return .end(id: id)
        default: return nil
        }
    }
    var fileAnswer: RemoteFileAnswer? {
        switch self {
        case let .fileProgress(id, b): return .progress(id: id, bytes: b)
        case let .fileSaved(id, n): return .saved(id: id, name: n)
        case let .fileFailed(id, w): return .failed(id: id, why: w)
        default: return nil
        }
    }
}

/// One transfer as a list or a card shows it, either way.
public struct RemoteTransfer: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// not begun: behind another file, or until the session is up (and its stream has moved)
        case waiting
        case going
        /// the session dropped: it goes on from `done` when it's back
        case paused
        case done
        /// "space", "too_big", "write", "locked", "read", "stopped", "other"
        case failed(String)
    }
    public var id: String
    public var name: String
    public var size: Int
    /// written at the other end (sending) or here (receiving)
    public var done: Int
    public var incoming: Bool
    public var clip: Bool
    public var state: State
    public var index: Int?
    public var count: Int?
    /// receiving: where it was saved; sending: the file read
    public var url: URL?
    public var secondsLeft: Double?
    public var at: Date
    public init(id: String, name: String, size: Int, done: Int = 0, incoming: Bool, clip: Bool = false, state: State = .waiting,
                index: Int? = nil, count: Int? = nil, url: URL? = nil, secondsLeft: Double? = nil, at: Date = Date()) {
        self.id = id; self.name = name; self.size = size; self.done = done; self.incoming = incoming; self.clip = clip; self.state = state
        self.index = index; self.count = count; self.url = url; self.secondsLeft = secondsLeft; self.at = at
    }
    public var fraction: Double { size > 0 ? min(1, Double(done) / Double(size)) : (state == .done ? 1 : 0) }
    public var isOver: Bool { if case .failed = state { return true }; return state == .done }
}

// MARK: - sending

/// Sends files one at a time, in the order asked. `send` puts a message on the wire and says false when there's no session to put it on.
/// `ready` says whether files may go now (a session is up and, on the public connection service, its stream has moved). Call
/// `heard` with the receiver's answers and `connection(up:)` when the session drops or is back.
public final class RemoteFileSender: @unchecked Sendable {
    private struct Item {
        var t: RemoteTransfer
        let source: URL
        /// a temporary file (a zip, a pasted image) to delete once over
        let temporary: Bool
        /// the batch's bytes, said with each of its begins
        var total: Int? = nil
        var acked: Int?
        var heardSince = false
        var samples: [(t: TimeInterval, bytes: Int)] = []
        var pausedAt: Date?
    }
    private let lock = NSLock()
    private var items: [Item] = []
    private let send: (RemoteFileOut) -> Bool
    private let ready: () -> Bool
    /// the receiver answers every begin with where to start
    public var peerResumes: () -> Bool
    public var onChange: ((RemoteTransfer) -> Void)?
    private let worker = DispatchQueue(label: "blurt.remote.files.out")
    private var running = false
    private var up = true
    /// test hook: no sleeping while waiting
    var pollInterval: TimeInterval = 0.02

    public init(send: @escaping (RemoteFileOut) -> Bool, ready: @escaping () -> Bool, peerResumes: @escaping () -> Bool) {
        self.send = send; self.ready = ready; self.peerResumes = peerResumes
    }

    public var transfers: [RemoteTransfer] { lock.withLock { items.map(\.t) } }

    /// Queue files. `clip`: the clipboard's content (one file). Folders must already be zipped (RemoteFiles.prepare). `temporary`: delete
    /// each once it's over; `made`: only these (the zips RemoteFiles.prepare made). Returns the transfers made, in order.
    @discardableResult
    public func add(_ urls: [URL], clip: Bool = false, temporary: Bool = false, made: Set<URL> = []) -> [RemoteTransfer] {
        let sizes = urls.map { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1 }
        let total = sizes.reduce(0) { $0 + max(0, $1) }
        let many = urls.count > 1
        let new: [Item] = zip(urls, sizes).enumerated().map { i, p in
            Item(t: RemoteTransfer(id: Self.newID(), name: p.0.lastPathComponent, size: max(0, p.1), incoming: false, clip: clip,
                                   index: many ? i + 1 : nil, count: many ? urls.count : nil, url: p.0), source: p.0, temporary: temporary || made.contains(p.0),
                 total: many ? total : nil)
        }
        lock.withLock { items.append(contentsOf: new) }
        new.forEach { onChange?($0.t) }
        kick()
        return new.map(\.t)
    }

    /// × on one transfer, or on all of them (nil).
    public func stop(_ id: String? = nil) {
        var changed: [RemoteTransfer] = []
        var ends: [String] = []
        lock.withLock {
            for i in items.indices where (id == nil || items[i].t.id == id) && !items[i].t.isOver {
                if items[i].t.state == .going || items[i].t.state == .paused { ends.append(items[i].t.id) }
                items[i].t.state = .failed("stopped")
                items[i].t.secondsLeft = nil
                changed.append(items[i].t)
            }
        }
        // the receiver deletes what it had: a short end
        ends.forEach { _ = send(.end(id: $0)) }
        changed.forEach { onChange?($0) }
        cleanUp()
    }

    /// Done and failed ones leave the list.
    public func clear() {
        lock.withLock { items.removeAll { $0.t.isOver } }
    }

    /// A paused or failed transfer goes again (the transfers list's Continue): from where the receiver has it, if it kept it.
    public func again(_ id: String) {
        let t: RemoteTransfer? = lock.withLock {
            guard let i = items.firstIndex(where: { $0.t.id == id }) else { return nil }
            if case .failed("stopped") = items[i].t.state { return nil }
            guard items[i].t.state != .done, FileManager.default.fileExists(atPath: items[i].source.path) else { return nil }
            items[i].t.state = .waiting
            items[i].pausedAt = nil
            return items[i].t
        }
        if let t { onChange?(t); kick() }
    }

    public func heard(_ a: RemoteFileAnswer) {
        var t: RemoteTransfer?
        lock.withLock {
            switch a {
            case let .progress(id, bytes):
                guard let i = items.firstIndex(where: { $0.t.id == id }), !items[i].t.isOver else { return }
                items[i].acked = bytes
                items[i].heardSince = true
                items[i].t.done = min(bytes, items[i].t.size)
                let now = ProcessInfo.processInfo.systemUptime
                items[i].samples.append((now, bytes))
                items[i].samples.removeAll { now - $0.t > 5 }
                items[i].t.secondsLeft = RemoteFiles.left(items[i].samples, size: items[i].t.size)
                t = items[i].t
            case let .saved(id, _):
                guard let i = items.firstIndex(where: { $0.t.id == id }), !items[i].t.isOver else { return }
                items[i].t.state = .done
                items[i].t.done = items[i].t.size
                items[i].t.secondsLeft = nil
                t = items[i].t
            case let .failed(id, why):
                guard let i = items.firstIndex(where: { $0.t.id == id }), !items[i].t.isOver else { return }
                items[i].t.state = .failed(why)
                items[i].t.secondsLeft = nil
                t = items[i].t
            }
        }
        if let t { onChange?(t) }
        if t?.isOver == true { cleanUp() }
    }

    /// The session dropped (false) or is back (true). Dropped: the file going pauses where the receiver had it.
    public func connection(up: Bool) {
        var changed: [RemoteTransfer] = []
        lock.withLock {
            self.up = up
            guard !up else { return }
            for i in items.indices where items[i].t.state == .going {
                items[i].t.state = .paused
                items[i].t.secondsLeft = nil
                items[i].pausedAt = Date()
                items[i].samples = []
                changed.append(items[i].t)
            }
        }
        changed.forEach { onChange?($0) }
        if up {
            // paused ones go on by themselves, as long as they paused less than an hour ago
            var back: [RemoteTransfer] = []
            lock.withLock {
                for i in items.indices where items[i].t.state == .paused {
                    if let p = items[i].pausedAt, Date().timeIntervalSince(p) > RemoteFiles.keepParts {
                        items[i].t.state = .failed("other")
                    } else {
                        items[i].t.state = .waiting
                    }
                    back.append(items[i].t)
                }
            }
            back.forEach { onChange?($0) }
            kick()
        }
    }

    private func kick() {
        let start: Bool = lock.withLock {
            guard !running else { return false }
            running = true
            return true
        }
        guard start else { return }
        worker.async { self.run() }
    }

    private func next() -> Int? {
        lock.withLock {
            guard up else { return nil }
            return items.firstIndex { $0.t.state == .waiting }
        }
    }

    private func run() {
        defer {
            lock.withLock { running = false }
            // something queued while the loop was ending
            if lock.withLock({ up && items.contains { $0.t.state == .waiting } }) && ready() { kick() }
            else if lock.withLock({ up && items.contains { $0.t.state == .waiting } }) { worker.asyncAfter(deadline: .now() + 0.25) { self.kick() } }
        }
        while let i = next() {
            // the session must be up (and its stream moved) before a byte goes
            var waited = 0.0
            while !ready() {
                if !lock.withLock({ up }) { return }
                Thread.sleep(forTimeInterval: 0.1)
                waited += 0.1
                if waited > 600 { break }
            }
            guard ready() else { return }
            one(i)
        }
    }

    private func one(_ index: Int) {
        guard let (id, info, source) = lock.withLock({ () -> (String, RemoteFileInfo, URL)? in
            guard index < items.count, items[index].t.state == .waiting else { return nil }
            items[index].t.state = .going
            items[index].acked = nil
            items[index].heardSince = false
            items[index].samples = []
            let t = items[index].t
            return (t.id, RemoteFileInfo(id: t.id, name: t.name, size: t.size, clip: t.clip, index: t.index, count: t.count, total: items[index].total), items[index].source)
        }) else { return }
        publish(id)
        guard info.size <= RemoteFiles.maxSize else { return finish(id, .failed("too_big"), wire: false) }
        guard let h = try? FileHandle(forReadingFrom: source) else { return finish(id, .failed("read"), wire: false) }
        defer { try? h.close() }
        guard send(.begin(info)) else { return pause(id) }
        var sent = 0
        if peerResumes() {
            // where the receiver has it: 0 for a new file
            var waited = 0.0
            while lock.withLock({ item(id).map { $0.heardSince == false && $0.t.state == .going } ?? false }) {
                Thread.sleep(forTimeInterval: pollInterval)
                waited += pollInterval
                if waited > RemoteFiles.resumeWait { return finish(id, .failed("other"), wire: true) }
            }
            guard let it = lock.withLock({ item(id) }), it.t.state == .going else { return }
            sent = min(max(0, it.acked ?? 0), info.size)
            if sent > 0 { try? h.seek(toOffset: UInt64(sent)) }
        } else {
            lock.withLock { if let i = items.firstIndex(where: { $0.t.id == id }) { items[i].acked = 0 } }
        }
        while true {
            var waited = 0.0
            while let it = lock.withLock({ item(id) }), it.t.state == .going, sent - (it.acked ?? 0) > RemoteFiles.window {
                Thread.sleep(forTimeInterval: pollInterval)
                waited += pollInterval
                // a minute without the receiver moving
                if waited > 60 { return finish(id, .failed("other"), wire: true) }
            }
            guard let it = lock.withLock({ item(id) }) else { return }
            switch it.t.state {
            case .going: break
            case .paused: return
            default: return   // stopped here (the short end went in stop) or refused there
            }
            // nil at the end of the file; a throw is a file that can't be read
            let d: Data
            do { d = try h.read(upToCount: RemoteFiles.chunk) ?? Data() } catch { return finish(id, .failed("read"), wire: true) }
            if d.isEmpty { break }
            guard send(.chunk(id: id, data: d)) else { return pause(id) }
            sent += d.count
        }
        guard send(.end(id: id)) else { return pause(id) }
        // then the receiver's saved or failed; a drop before it pauses it, and the begin again finds it whole
        while let it = lock.withLock({ item(id) }), it.t.state == .going {
            Thread.sleep(forTimeInterval: pollInterval)
            if !lock.withLock({ up }) { break }
        }
    }

    private func item(_ id: String) -> Item? { items.first { $0.t.id == id } }

    private func publish(_ id: String) {
        if let t = lock.withLock({ item(id)?.t }) { onChange?(t) }
    }

    private func pause(_ id: String) {
        var t: RemoteTransfer?
        lock.withLock {
            guard let i = items.firstIndex(where: { $0.t.id == id }), items[i].t.state == .going else { return }
            items[i].t.state = .paused
            items[i].pausedAt = Date()
            items[i].t.secondsLeft = nil
            t = items[i].t
        }
        if let t { onChange?(t) }
    }

    /// Over here: `wire` sends a short end so the receiver deletes its part.
    private func finish(_ id: String, _ s: RemoteTransfer.State, wire: Bool) {
        var t: RemoteTransfer?
        lock.withLock {
            guard let i = items.firstIndex(where: { $0.t.id == id }) else { return }
            items[i].t.state = s
            items[i].t.secondsLeft = nil
            t = items[i].t
        }
        if wire { _ = send(.end(id: id)) }
        if let t { onChange?(t) }
        cleanUp()
    }

    private func cleanUp() {
        let gone: [URL] = lock.withLock {
            items.filter { $0.temporary && $0.t.isOver }.map(\.source)
        }
        gone.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    public static func newID() -> String { RemoteCrypto.newID() }
}

// MARK: - receiving

/// Writes files as they arrive. Parts live in `parts` (this end's own folder); a finished file moves to `folder()` under a name not taken.
/// One receiver serves every device a host knows (parts are keyed by device), or one link on a phone or viewer.
public final class RemoteFileReceiver: @unchecked Sendable {
    private struct Part {
        let device: String
        let id: String
        let name: String
        let size: Int
        let clip: Bool
        let url: URL
        var handle: FileHandle?
        var written: Int
        var told: Int
        var index: Int?
        var count: Int?
        var keptSince: Date?
        var samples: [(t: TimeInterval, bytes: Int)] = []
    }
    private let lock = NSLock()
    private var parts: [String: Part] = [:]
    private let partsFolder: URL
    private let folder: () -> URL
    /// answers this end supports resume with
    public let resumes: Bool
    /// the screen is locked: nothing is taken
    public var locked: () -> Bool = { false }
    /// a finished file, moved to its place: quarantine it, notify (not for clip ones)
    public var onSaved: ((URL, _ device: String) -> Void)?
    /// a `clip` file arrived: put it on the clipboard. The file is deleted after this returns
    public var onClip: ((URL, _ name: String, _ device: String) -> Void)?
    public var onChange: ((RemoteTransfer, _ device: String) -> Void)?
    /// test hook
    var now: () -> Date = Date.init

    public init(parts: URL, folder: @escaping () -> URL, resumes: Bool = true) {
        self.partsFolder = parts
        self.folder = folder
        self.resumes = resumes
        try? FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        // parts from an earlier run: their sessions can't come back
        if let old = try? FileManager.default.contentsOfDirectory(at: parts, includingPropertiesForKeys: nil) {
            old.filter { $0.pathExtension == "part" }.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    private func key(_ device: String, _ id: String) -> String { device + "\u{1F}" + id }

    /// One message about a file from `device`; `answer` goes back on the same session.
    public func heard(_ m: RemoteFileOut, from device: String, answer: (RemoteFileAnswer) -> Void) {
        switch m {
        case let .begin(i): begin(i, device, answer)
        case let .chunk(id, d): chunk(id, d, device, answer)
        case let .end(id): end(id, device, answer)
        }
    }

    private func begin(_ i: RemoteFileInfo, _ device: String, _ answer: (RemoteFileAnswer) -> Void) {
        expire()
        let k = key(device, i.id)
        // the same file again after a drop: go on from what's written
        if resumes, var p = lock.withLock({ parts[k] }), p.name == RemoteFiles.clean(i.name), p.size == i.size {
            if p.handle == nil {
                guard let h = try? FileHandle(forWritingTo: p.url) else { lock.withLock { _ = parts.removeValue(forKey: k) }; return begin(i, device, answer) }
                let at = (try? h.seekToEnd()).map(Int.init) ?? 0
                p.handle = h
                p.written = at
                p.told = at
            }
            p.keptSince = nil
            lock.withLock { parts[k] = p }
            answer(.progress(id: i.id, bytes: p.written))
            change(p, device, .going)
            return
        }
        // another file from this device begins: one that wasn't finished is kept (resume) or goes
        suspend(device: device, except: i.id)
        if locked() { return answer(.failed(id: i.id, why: "locked")) }
        let cap = i.clip ? max(RemoteFiles.maxClipImage, 64 << 20) : RemoteFiles.maxSize
        guard i.size >= 0, i.size <= cap else { return answer(.failed(id: i.id, why: "too_big")) }
        if !i.clip {
            let dest = folder()
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let free = Self.free(at: dest)
            guard Int64(i.size) < free - RemoteFiles.spare else { return answer(.failed(id: i.id, why: "space")) }
        }
        let url = partsFolder.appendingPathComponent(UUID().uuidString + ".part")
        guard FileManager.default.createFile(atPath: url.path, contents: nil), let h = try? FileHandle(forWritingTo: url) else {
            return answer(.failed(id: i.id, why: "write"))
        }
        let p = Part(device: device, id: i.id, name: RemoteFiles.clean(i.name), size: i.size, clip: i.clip, url: url, handle: h, written: 0, told: 0,
                     index: i.index, count: i.count)
        lock.withLock { parts[k] = p }
        if resumes { answer(.progress(id: i.id, bytes: 0)) }
        change(p, device, .going)
    }

    private func chunk(_ id: String, _ d: Data, _ device: String, _ answer: (RemoteFileAnswer) -> Void) {
        let k = key(device, id)
        guard var p = lock.withLock({ parts[k] }), let h = p.handle else { return }
        guard p.written + d.count <= p.size, (try? h.write(contentsOf: d)) != nil else {
            drop(k)
            answer(.failed(id: id, why: "write"))
            return change(p, device, .failed("write"))
        }
        p.written += d.count
        let tell = p.written - p.told >= RemoteFiles.progressEvery
        if tell {
            p.told = p.written
            let now = ProcessInfo.processInfo.systemUptime
            p.samples.append((now, p.written))
            p.samples.removeAll { now - $0.t > 5 }
        }
        lock.withLock { parts[k] = p }
        if tell {
            answer(.progress(id: id, bytes: p.written))
            change(p, device, .going)
        }
    }

    private func end(_ id: String, _ device: String, _ answer: (RemoteFileAnswer) -> Void) {
        let k = key(device, id)
        guard let p = lock.withLock({ parts.removeValue(forKey: k) }) else { return }
        try? p.handle?.close()
        // short: the sender stopped it
        guard p.written == p.size else {
            try? FileManager.default.removeItem(at: p.url)
            answer(.failed(id: id, why: "stopped"))
            return change(p, device, .failed("stopped"))
        }
        if p.clip {
            onClip?(p.url, p.name, device)
            try? FileManager.default.removeItem(at: p.url)
            answer(.saved(id: id, name: p.name))
            return change(p, device, .done)
        }
        let dir = folder()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = RemoteFiles.unique(dir.appendingPathComponent(p.name))
        do {
            try FileManager.default.moveItem(at: p.url, to: dest)
        } catch {
            // another volume: copy, then delete
            do { try FileManager.default.copyItem(at: p.url, to: dest); try? FileManager.default.removeItem(at: p.url) } catch {
                try? FileManager.default.removeItem(at: p.url)
                answer(.failed(id: id, why: "write"))
                return change(p, device, .failed("write"))
            }
        }
        onSaved?(dest, device)
        answer(.saved(id: id, name: dest.lastPathComponent))
        change(p, device, .done, url: dest)
    }

    /// × here: the file stops and its part goes; the sender hears `stopped`.
    public func stop(_ id: String, from device: String, answer: (RemoteFileAnswer) -> Void) {
        let k = key(device, id)
        guard let p = lock.withLock({ parts[k] }) else { return }
        drop(k)
        answer(.failed(id: id, why: "stopped"))
        change(p, device, .failed("stopped"))
    }

    /// The session with `device` ended: parts wait an hour for it (or go, without resume).
    public func suspend(device: String, except: String? = nil) {
        var paused: [Part] = []
        lock.withLock {
            for (k, p) in parts where p.device == device && p.id != except && p.keptSince == nil {
                try? p.handle?.close()
                if resumes && !p.clip {
                    parts[k]?.handle = nil
                    parts[k]?.keptSince = now()
                    paused.append(p)
                } else {
                    try? FileManager.default.removeItem(at: p.url)
                    parts.removeValue(forKey: k)
                }
            }
        }
        paused.forEach { change($0, device, .paused) }
    }

    /// Parts kept longer than an hour go.
    public func expire() {
        lock.withLock {
            for (k, p) in parts {
                if let t = p.keptSince, now().timeIntervalSince(t) > RemoteFiles.keepParts {
                    try? FileManager.default.removeItem(at: p.url)
                    parts.removeValue(forKey: k)
                }
            }
        }
    }

    /// What's being received or kept, for a list.
    public var current: [RemoteTransfer] {
        lock.withLock { parts.values.map { transfer($0, $0.keptSince == nil ? .going : .paused) } }
    }

    private func drop(_ k: String) {
        guard let p = lock.withLock({ parts.removeValue(forKey: k) }) else { return }
        try? p.handle?.close()
        try? FileManager.default.removeItem(at: p.url)
    }

    private func transfer(_ p: Part, _ s: RemoteTransfer.State, url: URL? = nil) -> RemoteTransfer {
        RemoteTransfer(id: p.id, name: url?.lastPathComponent ?? p.name, size: p.size, done: s == .done ? p.size : p.written, incoming: true,
                       clip: p.clip, state: s, index: p.index, count: p.count, url: url,
                       secondsLeft: s == .going ? RemoteFiles.left(p.samples, size: p.size) : nil)
    }

    private func change(_ p: Part, _ device: String, _ s: RemoteTransfer.State, url: URL? = nil) {
        onChange?(transfer(p, s, url: url), device)
    }

    static func free(at u: URL) -> Int64 {
        #if os(macOS) || os(iOS)
        if let v = (try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage, v > 0 {
            return v
        }
        #endif
        return (try? u.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init) ?? Int64.max
    }
}
