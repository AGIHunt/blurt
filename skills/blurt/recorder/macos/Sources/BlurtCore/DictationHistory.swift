// Dictation history (docs/design/dictation.md): $BLURT_HOME/dictation/history.jsonl, append-only. One line per
// dictation; edits are lines too, applied in order when it is read:
//   {"id","t","app","bundle","duration","raw","polished","text","model","fell_back","reason","insert","audio",…}
//   {"op":"delete","ids":[…],"t"}   {"op":"item","id","item","uid","t"}   {"op":"clear","t"}
// Retention (record.dictation.retention_days, default 30) rewrites the file without what is older or deleted, and
// removes their audio (dictation/audio/<id>.wav, kept only with record.dictation.keep_audio). dictation.py reads the
// same file (list, turn into an item).
import Foundation

public struct DictationEntry: Identifiable, Hashable {
    public var id: String
    public var time: Date
    public var app: String?
    public var bundle: String?
    public var duration: Double
    public var raw: String
    public var polished: String?
    /// what was typed (or copied): the polished text, or the raw one when polish was off or fell back
    public var text: String
    public var model: String?
    public var fellBack: Bool
    public var reason: String?
    /// "pasted" | "copied" | "none"
    public var insert: String
    public var audio: String?
    public var asrModel: String?
    public var language: String?
    /// set once it was turned into an item: its id ("BA-12") and uid
    public var item: String?
    public var itemUID: String?

    public init(id: String, time: Date, app: String?, bundle: String?, duration: Double, raw: String, polished: String?,
                text: String, model: String?, fellBack: Bool, reason: String?, insert: String, audio: String? = nil,
                asrModel: String? = nil, language: String? = nil) {
        self.id = id; self.time = time; self.app = app; self.bundle = bundle; self.duration = duration; self.raw = raw
        self.polished = polished; self.text = text; self.model = model; self.fellBack = fellBack; self.reason = reason
        self.insert = insert; self.audio = audio; self.asrModel = asrModel; self.language = language
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    public var json: [String: Any] {
        var o: [String: Any] = ["id": id, "t": DictationEntry.iso.string(from: time), "duration": (duration * 100).rounded() / 100,
                                "raw": raw, "text": text, "fell_back": fellBack, "insert": insert]
        o["app"] = app ?? NSNull()
        o["bundle"] = bundle ?? NSNull()
        o["polished"] = polished ?? NSNull()
        o["model"] = model ?? NSNull()
        o["reason"] = reason ?? NSNull()
        o["audio"] = audio ?? NSNull()
        if let a = asrModel { o["asr_model"] = a }
        if let l = language { o["language"] = l }
        return o
    }

    init?(json o: [String: Any]) {
        guard let id = o["id"] as? String, let raw = o["raw"] as? String else { return nil }
        self.id = id
        time = (o["t"] as? String).flatMap { DictationEntry.iso.date(from: $0) } ?? Date(timeIntervalSince1970: 0)
        app = o["app"] as? String
        bundle = o["bundle"] as? String
        duration = o["duration"] as? Double ?? 0
        self.raw = raw
        polished = o["polished"] as? String
        text = o["text"] as? String ?? polished ?? raw
        model = o["model"] as? String
        fellBack = o["fell_back"] as? Bool ?? false
        reason = o["reason"] as? String
        insert = o["insert"] as? String ?? "none"
        audio = o["audio"] as? String
        asrModel = o["asr_model"] as? String
        language = o["language"] as? String
    }
}

public final class DictationHistory {
    public static var dir: URL { BlurtPaths.home.appendingPathComponent("dictation") }
    public static let shared = DictationHistory()

    private let fixedURL: URL?
    private let lock = NSLock()
    public init(url: URL? = nil) { fixedURL = url }

    public var url: URL { fixedURL ?? DictationHistory.dir.appendingPathComponent("history.jsonl") }
    public var audioDir: URL { url.deletingLastPathComponent().appendingPathComponent("audio") }

    /// "d-20261023-020301-4f2a": sortable, unique enough for one person's dictations.
    public static func newID(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "d-" + f.string(from: d) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
    }

    // MARK: writing (one line each, O_APPEND)

    public func append(_ e: DictationEntry) { appendLine(e.json) }

    public func delete(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let gone = load().filter { ids.contains($0.id) }
        appendLine(["op": "delete", "ids": ids, "t": DictationEntry.iso.string(from: Date())])
        for e in gone { if let a = e.audio { try? FileManager.default.removeItem(at: resolve(a)) } }
    }

    public func markItem(_ id: String, item: String, uid: String) {
        appendLine(["op": "item", "id": id, "item": item, "uid": uid, "t": DictationEntry.iso.string(from: Date())])
    }

    /// Everything goes: the file is emptied and the audio removed.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: audioDir)
        try? Data().write(to: url, options: .atomic)
    }

    private func appendLine(_ o: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        guard var d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
        d.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        _ = d.withUnsafeBytes { write(fd, $0.baseAddress, d.count) }
        close(fd)
    }

    public func resolve(_ rel: String) -> URL {
        rel.hasPrefix("/") ? URL(fileURLWithPath: rel) : url.deletingLastPathComponent().appendingPathComponent(rel)
    }

    // MARK: reading

    /// The entries, newest first, with the edits applied.
    public func load() -> [DictationEntry] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        var order: [String] = []
        var byID: [String: DictationEntry] = [:]
        for line in d.split(separator: 0x0A) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            switch o["op"] as? String {
            case "delete": for i in o["ids"] as? [String] ?? [] { byID[i] = nil }
            case "clear": byID = [:]; order = []
            case "item":
                if let i = o["id"] as? String, var e = byID[i] { e.item = o["item"] as? String; e.itemUID = o["uid"] as? String; byID[i] = e }
            default:
                if let e = DictationEntry(json: o) {
                    if byID[e.id] == nil { order.append(e.id) }
                    byID[e.id] = e
                }
            }
        }
        return order.compactMap { byID[$0] }.sorted { $0.time > $1.time }
    }

    /// Rewrites the file without entries older than `days` (and without the edit lines), removing their audio.
    /// Returns how many entries went.
    @discardableResult
    public func prune(days: Int, now: Date = Date()) -> Int {
        let all = load()
        let cutoff = now.addingTimeInterval(-Double(max(0, days)) * 86400)
        let keep = all.filter { $0.time >= cutoff }
        let drop = all.filter { $0.time < cutoff }
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        // nothing to forget and no edit lines to fold: leave the file alone
        let lines = (try? Data(contentsOf: url))?.split(separator: 0x0A).count ?? 0
        if drop.isEmpty && lines == all.count { return 0 }
        for e in drop { if let a = e.audio { try? FileManager.default.removeItem(at: resolve(a)) } }
        var out = Data()
        for e in keep.reversed() {
            if let d = try? JSONSerialization.data(withJSONObject: e.json, options: [.sortedKeys]) { out.append(d); out.append(0x0A) }
            if let i = e.item, let u = e.itemUID,
               let d = try? JSONSerialization.data(withJSONObject: ["op": "item", "id": e.id, "item": i, "uid": u], options: [.sortedKeys]) {
                out.append(d); out.append(0x0A)
            }
        }
        lock.lock(); defer { lock.unlock() }
        try? out.write(to: url, options: .atomic)
        return drop.count
    }
}
