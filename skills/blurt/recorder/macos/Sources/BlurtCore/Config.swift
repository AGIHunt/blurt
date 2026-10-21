// ~/.blurt/config.json, shared with record.py (and every other script): read fresh on each access — other processes
// write it too — and written back whole (pretty, sorted keys, like _common.save_json).
// Keys may be dotted paths: Config.shared["record.hotkeys"], Config.shared.set("record.countdown", 3).
import Foundation

public final class Config {
    public static let shared = Config()

    private let fixedURL: URL?
    private let lock = NSLock()

    /// nil = BlurtPaths.config at the time of each access (so a changed BLURT_HOME is honoured, as in the scripts)
    public init(url: URL? = nil) { fixedURL = url }

    public var url: URL { fixedURL ?? BlurtPaths.config }

    /// The whole file ({} when missing or unreadable).
    public var all: [String: Any] {
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    public subscript(key: String) -> Any? {
        get {
            var cur: Any? = all
            for part in key.split(separator: ".") { cur = (cur as? [String: Any])?[String(part)] }
            return cur
        }
        set { set(key, newValue) }
    }

    /// nil removes the key (and any section left empty by that).
    public func set(_ key: String, _ value: Any?) {
        lock.lock(); defer { lock.unlock() }
        let parts = key.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return }
        func put(_ dict: [String: Any], _ i: Int) -> [String: Any] {
            var d = dict
            if i == parts.count - 1 {
                d[parts[i]] = value
            } else {
                let child = put(d[parts[i]] as? [String: Any] ?? [:], i + 1)
                d[parts[i]] = child.isEmpty && value == nil ? nil : child
            }
            return d
        }
        let out = put(all, 0)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: url, options: .atomic)
        }
    }

    /// config["record"] as a dictionary ([:] when absent)
    public var record: [String: Any] { all["record"] as? [String: Any] ?? [:] }
}
