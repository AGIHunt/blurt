// What the share extension hands the app (docs/design/remote-files.md §What the user does): Share → Blurt names the computer last
// controlled, and that tap is the act. The extension copies the items into the App Group's outbox with that computer's id; the app sends
// them the next time it's open and connected to that computer. Anything not sent within an hour is dropped. Built into the app and the
// extension both, with nothing of BlurtRemoteKit, so the extension stays small.
import Foundation

struct Outbox {
    static let keep: TimeInterval = 3600
    static let most = 50

    /// One share: its files sit beside this, in the same folder. Written last, so a folder without it is still being filled.
    struct Entry: Codable, Equatable {
        var computer: String
        var name: String
        var at: Date
        var files: [String]
    }

    /// The computer the extension sends to: the last one controlled, as the app named it then.
    struct Target: Codable, Equatable {
        var id: String
        var name: String
    }

    let root: URL

    /// Info.plist's `BlurtAppGroup` (from the build setting: dev.blurt.remote's group in debug, work.blurt.remote's in release)
    static var group: String? {
        (Bundle.main.object(forInfoDictionaryKey: "BlurtAppGroup") as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
    }

    static var shared: Outbox? {
        guard let g = group, let c = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g) else { return nil }
        return Outbox(root: c.appendingPathComponent("Outbox", isDirectory: true))
    }

    private static var defaults: UserDefaults? { group.flatMap(UserDefaults.init(suiteName:)) }
    private static let targetKey = "share.target"

    static var target: Target? {
        get { defaults?.data(forKey: targetKey).flatMap { try? JSONDecoder().decode(Target.self, from: $0) } }
        set {
            guard let d = defaults else { return }
            if let t = newValue, let data = try? JSONEncoder().encode(t) { d.set(data, forKey: targetKey) } else { d.removeObject(forKey: targetKey) }
        }
    }

    private static let entryName = "entry.json"

    /// A new share's folder, to copy files into, then `seal`.
    func open() -> URL? {
        let u = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)) != nil ? u : nil
    }

    /// Copies one file into an open share under a name not taken there. Returns the name it got.
    @discardableResult
    func add(_ file: URL, as name: String? = nil, to folder: URL) -> String? {
        var n = (name ?? file.lastPathComponent).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while n.hasPrefix(".") { n.removeFirst() }
        if n.isEmpty || n == Self.entryName { n = "file" + (file.pathExtension.isEmpty ? "" : "." + file.pathExtension) }
        var dest = folder.appendingPathComponent(n)
        let base = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
        var i = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            i += 1
        }
        guard (try? FileManager.default.copyItem(at: file, to: dest)) != nil else { return nil }
        return dest.lastPathComponent
    }

    /// The share is complete: the app may take it.
    func seal(_ folder: URL, for t: Target, files: [String], now: Date = Date()) {
        let e = Entry(computer: t.id, name: t.name, at: now, files: files)
        guard !files.isEmpty, let d = try? JSONEncoder().encode(e) else { return discard(folder) }
        try? d.write(to: folder.appendingPathComponent(Self.entryName), options: .atomic)
    }

    func discard(_ folder: URL) { try? FileManager.default.removeItem(at: folder) }

    /// What waits, oldest first, and its folder. Shares older than an hour, and folders left half-filled as long, are deleted on the way.
    func waiting(now: Date = Date()) -> [(entry: Entry, folder: URL)] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [(Entry, URL)] = []
        for d in dirs {
            let made = (try? d.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now
            guard let data = try? Data(contentsOf: d.appendingPathComponent(Self.entryName)),
                  let e = try? JSONDecoder().decode(Entry.self, from: data) else {
                if now.timeIntervalSince(made) > Self.keep { discard(d) }
                continue
            }
            if now.timeIntervalSince(e.at) > Self.keep { discard(d); continue }
            out.append((e, d))
        }
        return out.sorted { $0.0.at < $1.0.at }
    }

    /// The shares for `computer`, moved into `dir` (the app's own, out of the extension's reach): one list of files for each, in order.
    func take(for computer: String, into dir: URL, now: Date = Date()) -> [[URL]] {
        var out: [[URL]] = []
        for (e, folder) in waiting(now: now) where e.computer == computer {
            let to = dir.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
            try? FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
            let files = e.files.compactMap { n -> URL? in
                let src = folder.appendingPathComponent(n), dest = to.appendingPathComponent(n)
                return (try? FileManager.default.moveItem(at: src, to: dest)) != nil ? dest : nil
            }
            discard(folder)
            if !files.isEmpty { out.append(files) }
        }
        return out
    }

    /// × on one file that waits; its share goes when nothing is left in it.
    func remove(_ file: String, in folder: URL) {
        let u = folder.appendingPathComponent(Self.entryName)
        guard let data = try? Data(contentsOf: u), var e = try? JSONDecoder().decode(Entry.self, from: data) else { return }
        e.files.removeAll { $0 == file }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        if e.files.isEmpty { return discard(folder) }
        if let d = try? JSONEncoder().encode(e) { try? d.write(to: u, options: .atomic) }
    }
}
