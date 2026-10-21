// G0 stub (P4 owns this file; docs/design/next-round.md K2). The project registry $BLURT_HOME/projects.json is
// written only by projects.py; the app reads the file and calls the CLI to change it. This stub reads the registry
// for real (so other packages can list projects before P4 lands) and shells out for the writes.
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

    public static func == (a: Project, b: Project) -> Bool {
        a.id == b.id && a.name == b.name && a.key == b.key && a.slug == b.slug && a.path == b.path && a.worktree == b.worktree
            && a.defaultAgent == b.defaultAgent && a.description == b.description && a.lastUsed == b.lastUsed
    }
    public func hash(into h: inout Hasher) { h.combine(id) }

    init(json o: [String: Any]) {
        id = o["id"] as? String ?? ""
        let p = URL(fileURLWithPath: o["path"] as? String ?? "")
        path = p
        name = o["name"] as? String ?? p.lastPathComponent
        key = o["key"] as? String ?? ""
        slug = o["slug"] as? String ?? ""
        description = o["description"] as? String ?? ""
        store = (o["store"] as? String).map { URL(fileURLWithPath: $0) } ?? p.appendingPathComponent(".blurt")
        isInbox = false
        isGitRepo = o["git"] as? Bool ?? FileManager.default.fileExists(atPath: p.appendingPathComponent(".git").path)
        worktree = o["worktree"] as? Bool ?? true
        defaultAgent = o["default_agent"] as? String
        modules = (o["modules"] as? [[String: Any]] ?? []).map {
            ProjectModule(name: $0["name"] as? String ?? "", paths: $0["paths"] as? [String] ?? [], description: $0["description"] as? String ?? "")
        }
        lastUsed = (o["last_used"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    init(inbox name: String) {
        id = "inbox"; key = "IN"; slug = "inbox"; description = ""; self.name = name
        path = BlurtPaths.workspace.appendingPathComponent("inbox"); store = path
        isInbox = true; isGitRepo = false; worktree = false; defaultAgent = nil; modules = []; lastUsed = nil
    }
}

public final class ProjectStore {
    public static let shared = ProjectStore()

    public private(set) var projects: [Project] = []
    public private(set) var currentID: String?
    public var inbox: Project { Project(inbox: Loc.t("project.inbox")) }
    public var current: Project? { currentID.flatMap { project(id: $0) } }
    public var onChange: (() -> Void)?

    private var stamp: Date?
    private var timer: Timer?

    public init() {
        reload()
        DispatchQueue.main.async { [weak self] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.reloadIfChanged() }
        }
    }

    var url: URL { BlurtPaths.home.appendingPathComponent("projects.json") }

    public func project(id: String) -> Project? { id == "inbox" ? inbox : projects.first { $0.id == id } }

    public func reload() {
        stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            projects = []; currentID = nil; return
        }
        let rows = (o["projects"] as? [[String: Any]] ?? [])
        let pinned = Set(rows.filter { $0["pinned"] as? Bool == true }.compactMap { $0["id"] as? String })
        projects = rows.map(Project.init(json:)).sorted {
            let (a, b) = (pinned.contains($0.id), pinned.contains($1.id))
            return a != b ? a : ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast)
        }
        let c = o["current"] as? String
        currentID = c == nil || c == "auto" ? nil : c
    }

    private func reloadIfChanged() {
        let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard m != stamp else { return }
        reload()
        onChange?()
    }

    private func cli(_ args: [String]) async throws -> [String: Any] {
        let o = try await ScriptRunner.shared.json("projects.py", args, timeout: 60)
        await MainActor.run { self.reload(); self.onChange?() }
        return o
    }

    public func use(_ id: String?) async throws { _ = try await cli(["use", id ?? "auto"]) }

    public func open(folder: URL) async throws -> Project {
        let o = try await cli(["add", folder.path])
        return Project(json: o["project"] as? [String: Any] ?? ["path": folder.path])
    }

    public func update(_ id: String, _ patch: [String: Any]) async throws {
        let d = try JSONSerialization.data(withJSONObject: patch)
        _ = try await cli(["set", id, "--json", String(decoding: d, as: UTF8.self)])
    }

    public func newSessionDir(_ kind: SessionKind) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = kind == .shots ? "-shots" : kind == .voice ? "-voice" : ""
        let dir = (current ?? inbox).store.appendingPathComponent("sessions/\(f.string(from: Date()))\(suffix)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
