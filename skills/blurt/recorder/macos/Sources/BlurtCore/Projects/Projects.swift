// K2 projects (G0 stub, owner P4): the registry $BLURT_HOME/projects.json (written by projects.py only — this reads it
// and watches it), the inbox store, the current project. Writes go through projects.py; while that script isn't
// there yet (before P1 merges) the stub writes `current` itself so the capture side can be exercised.
import Foundation

public enum SessionKind: String { case video, shots, voice }

public struct ProjectModule: Equatable {
    public let name: String
    public let paths: [String]
    public let description: String
}

public struct Project: Equatable, Hashable, Identifiable {
    public let id, name, key, slug, description: String
    public let path, store: URL
    public let isInbox, isGitRepo, worktree: Bool
    public let defaultAgent: String?
    public let modules: [ProjectModule]
    public let lastUsed: Date?

    public static func == (a: Project, b: Project) -> Bool {
        a.id == b.id && a.name == b.name && a.key == b.key && a.path == b.path && a.lastUsed == b.lastUsed
    }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

public final class ProjectStore {
    public static let shared = ProjectStore()

    /// registered projects, pinned and most recently used first; never the inbox
    public private(set) var projects: [Project] = []
    public private(set) var currentID: String?               // nil = auto
    public var onChange: (() -> Void)?

    private var mtime: Date?
    private var timer: Timer?

    public init() {
        reload()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.reloadIfChanged() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static var registryURL: URL { BlurtPaths.home.appendingPathComponent("projects.json") }

    public var inbox: Project {
        let p = BlurtPaths.workspace.appendingPathComponent("inbox")
        return Project(id: "inbox", name: Loc.t("project.inbox"), key: "IN", slug: "inbox", description: "", path: p, store: p,
                       isInbox: true, isGitRepo: false, worktree: false, defaultAgent: nil, modules: [], lastUsed: nil)
    }

    public var current: Project? { currentID.flatMap(project(id:)) }

    public func project(id: String) -> Project? { id == "inbox" ? inbox : projects.first { $0.id == id } }

    public func use(_ id: String?) async throws {
        let arg = id ?? "auto"
        if (try? ScriptRunner.shared.scriptURL("projects.py")) != nil {
            _ = try await ScriptRunner.shared.json("projects.py", ["use", arg])
        } else {
            var o = Self.readRegistry()
            o["current"] = arg
            Self.writeRegistry(o)
        }
        await MainActor.run { reload() }
    }

    public func open(folder: URL) async throws -> Project {
        let r = try await ScriptRunner.shared.json("projects.py", ["add", folder.path])
        await MainActor.run { reload() }
        let id = (r["project"] as? [String: Any])?["id"] as? String
        guard let p = id.flatMap(project(id:)) ?? projects.first(where: { $0.path.standardizedFileURL == folder.standardizedFileURL })
        else { throw ScriptError.failed(status: 1, stdout: Data(), stderr: "projects.py add returned no project") }
        return p
    }

    public func update(_ id: String, _ patch: [String: Any]) async throws {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: patch), as: UTF8.self)
        _ = try await ScriptRunner.shared.json("projects.py", ["set", id, "--json", json])
        await MainActor.run { reload() }
    }

    /// <current project's store, or the inbox when auto>/sessions/<ts>[-shots|-voice] (created)
    public func newSessionDir(_ kind: SessionKind) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = kind == .video ? "" : "-\(kind.rawValue)"
        let dir = (current ?? inbox).store.appendingPathComponent("sessions/\(f.string(from: Date()))\(suffix)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func reload() {
        let o = Self.readRegistry()
        mtime = (try? FileManager.default.attributesOfItem(atPath: Self.registryURL.path))?[.modificationDate] as? Date
        let iso = ISO8601DateFormatter()
        var list: [(Project, Bool)] = []
        for e in o["projects"] as? [[String: Any]] ?? [] {
            guard let id = e["id"] as? String, let path = e["path"] as? String else { continue }
            let url = URL(fileURLWithPath: path)
            let mods = (e["modules"] as? [[String: Any]] ?? []).map {
                ProjectModule(name: $0["name"] as? String ?? "", paths: $0["paths"] as? [String] ?? [], description: $0["description"] as? String ?? "")
            }
            let p = Project(id: id, name: e["name"] as? String ?? url.lastPathComponent, key: e["key"] as? String ?? "P",
                            slug: e["slug"] as? String ?? id, description: e["description"] as? String ?? "", path: url,
                            store: url.appendingPathComponent(".blurt"), isInbox: false,
                            isGitRepo: FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path),
                            worktree: e["worktree"] as? Bool ?? true, defaultAgent: e["default_agent"] as? String, modules: mods,
                            lastUsed: (e["last_used"] as? String).flatMap(iso.date(from:)))
            list.append((p, e["pinned"] as? Bool ?? false))
        }
        list.sort { a, b in
            if a.1 != b.1 { return a.1 }
            return (a.0.lastUsed ?? .distantPast) > (b.0.lastUsed ?? .distantPast)
        }
        let next = list.map(\.0)
        let cur = (o["current"] as? String).flatMap { $0 == "auto" ? nil : $0 }
        let changed = next != projects || cur != currentID
        projects = next
        currentID = cur.flatMap { c in next.contains { $0.id == c } ? c : nil }
        if changed { onChange?() }
    }

    private func reloadIfChanged() {
        let m = (try? FileManager.default.attributesOfItem(atPath: Self.registryURL.path))?[.modificationDate] as? Date
        if m != mtime { reload() }
    }

    static func readRegistry() -> [String: Any] {
        guard let d = try? Data(contentsOf: registryURL), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return ["schema": 1, "current": "auto", "projects": []]
        }
        return o
    }

    static func writeRegistry(_ o: [String: Any]) {
        try? FileManager.default.createDirectory(at: registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: registryURL, options: .atomic)
        }
    }
}
