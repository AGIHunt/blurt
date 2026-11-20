// What ⌥C and ⌥T read (2026-11-16, the founder: "I want to see what I took before", as dictation keeps its history):
// one line per result in ~/.blurt/screen-text/history.jsonl — when, read or translated, the text that went on the
// clipboard, the original for a translation, the app in front, what became of it (pasted / copied). Newest first on
// the main window's Screen Text page and in Home's timeline. Kept for record.screen_text.history_days: 7, 30 (the
// default), -1 forever, 0 not at all (Settings → Screen Text). No picture is kept, only text.
import Foundation

public struct ScreenTextEntry: Equatable, Identifiable, Sendable {
    public var id: String
    public var time: Date
    /// ⌥T's: `text` is the translation, `source` what was on the screen
    public var translated: Bool
    public var text: String
    public var source: String?
    /// the language asked for ("zh", "en", "auto:zh|en"); translations only
    public var target: String?
    public var app: String?
    public var bundle: String?
    /// pasted | unconfirmed | copied (ScreenTextPaste.Outcome's raw values); `interrupted`: a translation Blurt quit
    /// before it came back — `text` is what was read, `target` what it was to go into
    public var outcome: String?
    public static let interrupted = "interrupted"
    public var wasInterrupted: Bool { outcome == ScreenTextEntry.interrupted }

    public init(id: String = ScreenTextHistory.newID(), time: Date = Date(), translated: Bool, text: String, source: String? = nil,
                target: String? = nil, app: String? = nil, bundle: String? = nil, outcome: String? = nil) {
        self.id = id; self.time = time; self.translated = translated; self.text = text; self.source = source
        self.target = target; self.app = app; self.bundle = bundle; self.outcome = outcome
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public var json: [String: Any] {
        var o: [String: Any] = ["id": id, "t": ScreenTextEntry.iso.string(from: time), "translated": translated, "text": text]
        if let s = source { o["source"] = s }
        if let s = target { o["target"] = s }
        if let s = app { o["app"] = s }
        if let s = bundle { o["bundle"] = s }
        if let s = outcome { o["outcome"] = s }
        return o
    }

    public init?(json o: [String: Any]) {
        guard let id = o["id"] as? String, let t = (o["t"] as? String).flatMap(ScreenTextEntry.iso.date(from:)),
              let text = o["text"] as? String else { return nil }
        self.id = id; time = t; self.text = text
        translated = o["translated"] as? Bool ?? false
        source = o["source"] as? String
        target = o["target"] as? String
        app = o["app"] as? String
        bundle = o["bundle"] as? String
        outcome = o["outcome"] as? String
    }

    /// One line for a list: the text's first lines joined, at most `max` characters.
    public static func preview(_ s: String, max: Int = 160) -> String {
        let one = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " ")
        return one.count > max ? String(one.prefix(max)) + "…" : one
    }
}

public final class ScreenTextHistory {
    public static var dir: URL { BlurtPaths.home.appendingPathComponent("screen-text") }
    public static let shared = ScreenTextHistory()

    /// The choices Settings offers, in its order: days, -1 forever, 0 not kept.
    public static let choices = [7, 30, -1, 0]
    public static let defaultDays = 30

    private let fixedURL: URL?
    private let lock = NSLock()
    public init(url: URL? = nil) { fixedURL = url }

    public var url: URL { fixedURL ?? ScreenTextHistory.dir.appendingPathComponent("history.jsonl") }

    /// "s-20261116-101530-4f2a"
    public static func newID(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "s-" + f.string(from: d) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
    }

    /// `days` 0: nothing is written.
    public func append(_ e: ScreenTextEntry, days: Int) {
        guard days != 0 else { return }
        appendLine(e.json)
    }

    public func delete(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        appendLine(["op": "delete", "ids": ids])
    }

    /// Undo of a delete: the entries as they were (written again after the delete line, so load() has them back — also
    /// after a prune dropped the line and them).
    public func restore(_ es: [ScreenTextEntry]) {
        for e in es.sorted(by: { $0.time < $1.time }) { appendLine(e.json) }
    }

    /// A better reading replaced the text on the clipboard (⌥C's second pass): the entry says what is there now.
    public func update(_ id: String, text: String) {
        appendLine(["op": "text", "id": id, "text": text])
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    private func appendLine(_ o: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        guard var d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
        d.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: d)
    }

    /// Newest first, deletions applied.
    public func load() -> [ScreenTextEntry] {
        lock.lock(); defer { lock.unlock() }
        return loadUnlocked()
    }

    private func loadUnlocked() -> [ScreenTextEntry] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        var out: [ScreenTextEntry] = []
        for line in d.split(separator: 0x0A) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if o["op"] as? String == "delete" {
                let gone = Set(o["ids"] as? [String] ?? [])
                out.removeAll { gone.contains($0.id) }
            } else if o["op"] as? String == "text" {
                if let id = o["id"] as? String, let t = o["text"] as? String, let i = out.firstIndex(where: { $0.id == id }) { out[i].text = t }
            } else if let e = ScreenTextEntry(json: o) {
                out.removeAll { $0.id == e.id }       // written again (a delete undone): once
                out.append(e)
            }
        }
        return out.sorted { $0.time > $1.time }
    }

    /// How many entries a retention of `days` would delete now (Settings asks before it does: "Delete N entries?").
    public func wouldPrune(days: Int, now: Date = Date()) -> Int {
        guard days >= 0 else { return 0 }
        let all = load()
        return days == 0 ? all.count : all.filter { $0.time < now.addingTimeInterval(-Double(days) * 86400) }.count
    }

    /// Rewrites the file without entries older than `days` (0: none kept, -1: all kept) and without delete lines.
    /// Returns how many went.
    @discardableResult
    public func prune(days: Int, now: Date = Date()) -> Int {
        // read and rewritten under the lock: a line appended meanwhile (an ⌥C saved while the retention changed) was
        // lost when the rewrite replaced the file with the earlier read
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let all = loadUnlocked()
        let keep = days < 0 ? all : days == 0 ? [] : all.filter { $0.time >= now.addingTimeInterval(-Double(days) * 86400) }
        let lines = (try? Data(contentsOf: url))?.split(separator: 0x0A).count ?? 0
        if keep.count == all.count && lines == all.count { return 0 }
        var out = Data()
        for e in keep.reversed() {
            if let d = try? JSONSerialization.data(withJSONObject: e.json, options: [.sortedKeys]) { out.append(d); out.append(0x0A) }
        }
        if keep.isEmpty { try? FileManager.default.removeItem(at: url) } else {
            try? out.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)     // what was on the screen is private
        }
        return all.count - keep.count
    }
}
