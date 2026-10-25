// ~/.blurt/config.json, shared with record.py (and every other script). Other processes write it too, so every read
// checks the file (modification time, size, inode — one stat) and parses it again only when it changed.
// Keys may be dotted paths: Config.shared["record.hotkeys"], Config.shared.set("record.countdown", 3).
//
// Writes are read-modify-write under $BLURT_HOME/.config.lock — an flock, the same lock _common.update_global_config
// takes, so the app and the scripts never lose each other's changes — and atomic (pretty, sorted keys, like
// _common.save_json; 0600). A config.json that exists but doesn't parse (a hand edit gone wrong) is never overwritten:
// it is copied once to config.json.bad-<time> (not again on later launches while it stays the same), the write is
// refused, and `onUnreadable` says so (the app: one line in the island, at launch already: checkReadable). Reads of
// such a file give {} (every setting at its default) until it is fixed; `readable` tells that apart from an empty file
// (the app then doesn't take a missing app.onboarded for a first run). What counts as readable is the scripts' rule
// too (_common.parse_config_text): JSON, with a comma right before `}` or `]` forgiven (ConfigText) — the slip a hand
// edit makes most — so a file the app reads, the scripts read, and the other way round.
import Foundation

/// config.json's text the way the app and the scripts both read it.
public enum ConfigText {
    /// A comma right before `}` or `]` (outside strings) left out — the same walk as _common.drop_trailing_commas —
    /// until none is left (",, }" too): JSONSerialization forgives one trailing comma and Python's json none, so with
    /// none left both read exactly the same files.
    public static func dropTrailingCommas(_ text: String) -> String {
        var cur = text
        while true {
            let next = dropOnce(cur)
            if next == cur { return cur }
            cur = next
        }
    }

    private static func dropOnce(_ text: String) -> String {
        let s = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0, inString = false
        while i < s.count {
            let c = s[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < s.count { out.append(s[i + 1]); i += 1 } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
                out.append(c)
            } else if c == "," {
                var j = i + 1
                while j < s.count, [" ", "\t", "\r", "\n"].contains(s[j]) { j += 1 }
                if j >= s.count || (s[j] != "}" && s[j] != "]") { out.append(c) }
            } else {
                out.append(c)
            }
            i += 1
        }
        return String(out)
    }

    /// The file's bytes → its settings; nil when it doesn't parse (even with trailing commas left out) or isn't an
    /// object.
    public static func parse(_ data: Data) -> [String: Any]? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }      // a BOM (Notepad, PowerShell), as the scripts allow
        guard let d = dropTrailingCommas(text).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}

public final class Config {
    public static let shared = Config()

    private let fixedURL: URL?
    private let lock = NSLock()          // writers in this process
    private let cacheLock = NSLock()
    private var cache: (sig: FileSig, value: [String: Any], ok: Bool)?
    private var backedUp: FileSig?

    /// The file exists but doesn't parse; a write was refused (called with the backup's URL, once per bad version).
    public var onUnreadable: ((URL) -> Void)?

    /// nil = BlurtPaths.config at the time of each access (so a changed BLURT_HOME is honoured, as in the scripts)
    public init(url: URL? = nil) { fixedURL = url }

    public var url: URL { fixedURL ?? BlurtPaths.config }

    /// What identifies one version of the file without reading it.
    struct FileSig: Equatable {
        var path: String, inode: UInt64, size: Int64, mtime: Int64
        init?(_ u: URL) {
            var st = stat()
            guard stat(u.path, &st) == 0 else { return nil }
            path = u.path
            inode = UInt64(st.st_ino)
            size = Int64(st.st_size)
            mtime = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        }
    }

    /// The whole file ({} when missing or unreadable).
    public var all: [String: Any] { read().value }

    /// The file parses (or isn't there). False: every setting reads as its default until it is fixed.
    public var readable: Bool { read().ok }

    /// At launch: a file that doesn't parse is copied aside (once per version) and `onUnreadable` says so — before a
    /// write is refused, so the user hears it right away, with what it means. Returns `readable`.
    @discardableResult
    public func checkReadable() -> Bool {
        if read().ok { return true }
        lock.lock(); defer { lock.unlock() }
        refuse()
        return false
    }

    /// The parsed file, and whether it parsed (a missing file counts as fine: there is nothing to lose).
    private func read() -> (value: [String: Any], ok: Bool) {
        let u = url
        guard let sig = FileSig(u) else { return ([:], true) }
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let c = cache, c.sig == sig { return (c.value, c.ok) }
        let parsed = (try? Data(contentsOf: u)).flatMap(ConfigText.parse)
        cache = (sig, parsed ?? [:], parsed != nil)
        return (parsed ?? [:], parsed != nil)
    }

    public subscript(key: String) -> Any? {
        get {
            var cur: Any? = all
            for part in key.split(separator: ".") { cur = (cur as? [String: Any])?[String(part)] }
            return cur
        }
        set { set(key, newValue) }
    }

    /// nil removes the key (and any section left empty by that). Returns false when nothing was written (the file
    /// doesn't parse, or it couldn't be written).
    @discardableResult
    public func set(_ key: String, _ value: Any?) -> Bool {
        let parts = key.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = Config.lockFile(dir.appendingPathComponent(".config.lock"))
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        let (cur, ok) = read()
        guard ok else { refuse(); return false }
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
        guard let d = try? JSONSerialization.data(withJSONObject: put(cur, 0), options: [.prettyPrinted, .sortedKeys]) else { return false }
        return FilePrivacy.writePrivate(d, to: url)
    }

    /// The cross-process lock (flock, like _common.file_lock): waits up to 2 s, then goes ahead — a stuck script must
    /// not cost the user a setting. -1 = no lock taken.
    static func lockFile(_ u: URL) -> Int32 {
        let fd = open(u.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return -1 }
        let deadline = Date().addingTimeInterval(2)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() > deadline { close(fd); return -1 }
            usleep(10_000)
        }
        return fd
    }

    /// The file doesn't parse: keep a copy of it (once per version — also across launches: a config.json.bad-* with
    /// the same bytes is that copy) and leave it alone.
    private func refuse() {
        guard let sig = FileSig(url), sig != backedUp else { return }
        backedUp = sig
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let bytes = try? Data(contentsOf: url)
        let same = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(url.lastPathComponent + ".bad-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first { bytes != nil && (try? Data(contentsOf: $0)) == bytes }
        if let bak = same { onUnreadable?(bak); return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let bak = dir.appendingPathComponent("\(url.lastPathComponent).bad-\(f.string(from: Date()))")
        try? fm.copyItem(at: url, to: bak)
        onUnreadable?(bak)
    }

    /// config["record"] as a dictionary ([:] when absent)
    public var record: [String: Any] { all["record"] as? [String: Any] ?? [:] }
}
