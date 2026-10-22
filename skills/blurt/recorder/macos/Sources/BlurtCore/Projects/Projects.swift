// K2: a project is a folder on this Mac, opened like in VS Code / Claude Code. The registry is
// $BLURT_HOME/projects.json — written only by projects.py (it locks and replaces the file atomically); we read the
// file directly, watch it, and send every change through the CLI (`projects.py add / use / set / remove`).
// Items with no project live in the inbox store, $BLURT_WORKSPACE/inbox ("Unassigned").
import Foundation

public enum SessionKind: String { case video, shots, voice }

public struct ProjectModule: Equatable {
    public let name: String
    public let paths: [String]
    public let description: String
    public init(name: String, paths: [String], description: String) { self.name = name; self.paths = paths; self.description = description }
}

public struct Project: Equatable, Hashable, Identifiable {
    public let id, name, key, slug, description: String
    public let path, store: URL
    public let isInbox, isGitRepo, worktree: Bool
    public let defaultAgent: String?
    public let modules: [ProjectModule]
    public let lastUsed: Date?
    public let pinned: Bool

    public static func == (a: Project, b: Project) -> Bool {
        a.id == b.id && a.name == b.name && a.key == b.key && a.slug == b.slug && a.description == b.description && a.path == b.path
            && a.worktree == b.worktree && a.defaultAgent == b.defaultAgent && a.modules == b.modules && a.lastUsed == b.lastUsed
            && a.pinned == b.pinned
    }
    public func hash(into h: inout Hasher) { h.combine(id) }

    /// Whether the folder is still there (a moved or deleted folder stays registered until the user removes it).
    public var exists: Bool { FileManager.default.fileExists(atPath: path.path) }
}

public enum ProjectError: Error, CustomStringConvertible {
    /// projects.py answered {"ok": false, "code": …}; `code` is for the UI to localise (K10), `message` for logs.
    case cli(code: String, message: String)
    public var description: String {
        switch self { case .cli(let c, let m): return "\(c): \(m)" }
    }
    public var code: String { switch self { case .cli(let c, _): return c } }
}

public final class ProjectStore {
    public static let shared = ProjectStore()

    /// Registered projects, pinned and most recently used first. Not the inbox.
    public private(set) var projects: [Project] = []
    /// nil = auto (AI sorts captures into projects)
    public private(set) var currentID: String?
    /// Who set the current project: "user", or "migrate" (carried over from v0.6 — the app asks once).
    public private(set) var currentBy: String?
    /// The confidence at or above which the AI moves an item (projects.json route_threshold).
    public private(set) var routeThreshold = 0.75
    /// Main thread; projects.json changed (another process, or our own CLI call).
    public var onChange: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var lastStamp: Date?

    public var registryURL: URL { BlurtPaths.home.appendingPathComponent("projects.json") }
    public var inboxStore: URL { BlurtPaths.workspace.appendingPathComponent("inbox") }

    public init() { reload() }

    public var inbox: Project {
        Project(id: "inbox", name: Loc.t("project.inbox"), key: "IN", slug: "inbox", description: "", path: inboxStore,
                store: inboxStore, isInbox: true, isGitRepo: false, worktree: false, defaultAgent: nil, modules: [],
                lastUsed: nil, pinned: false)
    }

    public var current: Project? { currentID.flatMap(project(id:)) }

    /// A registered project, or the inbox for "inbox".
    public func project(id: String) -> Project? {
        id == "inbox" ? inbox : projects.first { $0.id == id }
    }

    /// The deepest registered project that contains `path` (a session dir, an item file, a code file).
    public func project(containing path: URL) -> Project? {
        let p = path.resolvingSymlinksInPath().standardizedFileURL.path
        if p == inboxStore.standardizedFileURL.path || p.hasPrefix(inboxStore.standardizedFileURL.path + "/") { return inbox }
        return projects.filter { p == $0.path.path || p.hasPrefix($0.path.path + "/") }.max { $0.path.path.count < $1.path.path.count }
    }

    // MARK: reading projects.json

    public func reload() {
        let raw = (try? Data(contentsOf: registryURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let list = (raw["projects"] as? [[String: Any]] ?? []).compactMap(Self.parse)
        projects = list.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return (a.lastUsed ?? .distantPast) > (b.lastUsed ?? .distantPast)
        }
        let cur = raw["current"] as? String
        currentID = cur == nil || cur == "auto" || !list.contains(where: { $0.id == cur }) ? nil : cur
        currentBy = raw["current_by"] as? String
        routeThreshold = (raw["route_threshold"] as? NSNumber)?.doubleValue ?? 0.75
        lastStamp = modified
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain = ISO8601DateFormatter()
    public static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    static func parse(_ o: [String: Any]) -> Project? {
        guard let id = o["id"] as? String, let path = o["path"] as? String else { return nil }
        let url = URL(fileURLWithPath: path)
        let name = (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
        let modules = (o["modules"] as? [[String: Any]] ?? []).map {
            ProjectModule(name: $0["name"] as? String ?? "", paths: $0["paths"] as? [String] ?? [], description: $0["description"] as? String ?? "")
        }
        return Project(id: id, name: name, key: o["key"] as? String ?? "P", slug: o["slug"] as? String ?? id,
                       description: o["description"] as? String ?? "", path: url, store: url.appendingPathComponent(".blurt"),
                       isInbox: false, isGitRepo: gitRoot(of: url) != nil, worktree: o["worktree"] as? Bool ?? true,
                       defaultAgent: o["default_agent"] as? String, modules: modules,
                       lastUsed: date(o["last_used"]) ?? date(o["opened"]), pinned: o["pinned"] as? Bool ?? false)
    }

    /// The folder (or an ancestor) that holds .git — a directory, or the file a worktree has.
    public static func gitRoot(of url: URL) -> URL? {
        var u = url.standardizedFileURL
        while u.path != "/" {
            if FileManager.default.fileExists(atPath: u.appendingPathComponent(".git").path) { return u }
            u.deleteLastPathComponent()
        }
        return nil
    }

    private var modified: Date? {
        (try? FileManager.default.attributesOfItem(atPath: registryURL.path))?[.modificationDate] as? Date
    }

    // MARK: watching

    /// Watches projects.json (and $BLURT_HOME, for the atomic replace that swaps the file's inode). Idempotent.
    public func watch() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: BlurtPaths.home, withIntermediateDirectories: true)
        let dfd = Darwin.open(BlurtPaths.home.path, O_EVTONLY)
        if dfd >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dfd, eventMask: [.write, .rename, .link], queue: .main)
            s.setEventHandler { [weak self] in self?.changed() }
            s.setCancelHandler { Darwin.close(dfd) }
            s.resume()
            dirSource = s
        }
        watchFile()
    }

    private func watchFile() {
        source?.cancel()
        source = nil
        let fd = Darwin.open(registryURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: .main)
        s.setEventHandler { [weak self] in self?.changed() }
        s.setCancelHandler { Darwin.close(fd) }
        s.resume()
        source = s
    }

    private func changed() {
        let m = modified
        if m == lastStamp, source != nil { return }
        watchFile()
        let before = (projects, currentID)
        reload()
        if before.0 != projects || before.1 != currentID { onChange?() }
    }

    // MARK: changes (projects.py)

    @discardableResult
    private func cli(_ args: [String]) async throws -> [String: Any] {
        let o: [String: Any]
        do {
            o = try await ScriptRunner.shared.json("projects.py", args, timeout: 30)
        } catch ScriptError.failed(_, let out, let err) {
            let line = String(decoding: out, as: UTF8.self).split(separator: "\n").last(where: { $0.hasPrefix("{") }).map(String.init) ?? "{}"
            let j = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
            throw ProjectError.cli(code: j["code"] as? String ?? "failed", message: j["error"] as? String ?? err)
        } catch ScriptError.scriptMissing(let p) {
            throw ProjectError.cli(code: "no_scripts", message: p)
        } catch ScriptError.uvMissing {
            throw ProjectError.cli(code: "no_uv", message: "uv not found")
        }
        guard o["ok"] as? Bool == true else {
            throw ProjectError.cli(code: o["code"] as? String ?? "failed", message: o["error"] as? String ?? "projects.py \(args.first ?? "")")
        }
        await MainActor.run { self.changed() }
        return o
    }

    /// nil = auto
    public func use(_ id: String?) async throws { try await cli(["use", id ?? "auto"]) }

    /// Opens (registers) a folder: creates its store and its .git/info/exclude line. An already registered folder just
    /// comes back (and becomes the most recently used).
    public func open(folder: URL) async throws -> Project {
        let o = try await cli(["add", folder.standardizedFileURL.path])
        let row = o["project"] as? [String: Any] ?? [:]
        if let id = row["id"] as? String, let p = await MainActor.run(body: { self.project(id: id) }) { return p }
        if let p = Self.parse(row) { return p }
        throw ProjectError.cli(code: "failed", message: "projects.py add returned no project")
    }

    public func update(_ id: String, _ patch: [String: Any]) async throws {
        let d = try JSONSerialization.data(withJSONObject: patch, options: [.sortedKeys])
        try await cli(["set", id, "--json", String(decoding: d, as: UTF8.self)])
    }

    /// Unregisters it. The folder and its .blurt are never touched.
    public func remove(_ id: String) async throws { try await cli(["remove", id]) }

    // MARK: where captures go

    /// <current project's store, or the inbox's>/sessions/<yyyyMMdd-HHmmss>[-shots|-voice], created.
    public func newSessionDir(_ kind: SessionKind) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = kind == .video ? "" : "-" + kind.rawValue
        let store = current?.store ?? inbox.store
        let dir = store.appendingPathComponent("sessions").appendingPathComponent(f.string(from: Date()) + suffix)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
