// Dictation history (docs/design/dictation.md): $BLURT_HOME/dictation/history.jsonl, append-only. One line per
// dictation; edits are lines too, applied in order when it is read:
//   {"id","t","app","bundle","duration","raw","polished","text","model","fell_back","reason","insert","audio",
//    "terms_applied" [custom words the dictation wrote], "context_used" (text around the cursor went to polish),
//    "context" (that text — only with record.dictation.keep_audio, the debug setting),
//    "asr_ms","polish_ms","load_ms","total_ms" (key-up → paste),"segments" (pieces streamed), "fitted" (how it was fitted at the cursor), "repaired" (spans polish
//    dropped that the guard put back), …}
//   {"op":"delete","ids":[…],"t"}   {"op":"item","id","item","uid","t"}   {"op":"clear","t"}
//   {"op":"correct","id","text","t"}  the user's corrected text (the Dictation page's "Save correction"); "corrected"
//                                      on a rewritten line
//   {"op":"style","id","action","from","to","replaced","t"}  reformat-last, its undo, or a list the user took apart
//                                      (action reformat | undo | revert); "reformats" on a rewritten line
// Since the styles work: "style", "style_source", "style_router" (DictationStyleRecord: the router's inputs and decision).
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
    /// the custom words this dictation wrote (biasing, the sounds-like pass or polish); nil in older entries
    public var termsApplied: [String]?
    /// whether the text around the cursor went to polish; nil in older entries
    public var contextUsed: Bool?
    /// that text itself — kept only when record.dictation.keep_audio (debugging) is on
    public var context: String?
    /// per-stage times (ms): asr_ms, polish_ms, load_ms (model loads waited for), total_ms (key-up → paste), segments
    /// (pieces transcribed while talking); nil in older entries
    public var timing: [String: Int]?
    /// words polish dropped that the guard put back (nil: none, or an older entry)
    public var repaired: [String]?
    /// how the text was fitted into the field at the cursor (DictationFit: "head" / "tail" — words that repeated the
    /// field, "punct", "capital", "space"); nil: inserted as it came (or an older entry)
    public var fitted: [String]?
    /// the user's own correction of `text` (the Dictation page): what they meant; nil = never corrected
    public var corrected: String?
    /// the text as it stands: the correction when there is one, else what was typed
    public var finalText: String { corrected ?? text }
    /// the style the take was typed in, why, and what reformat-last did with it (nil: an older entry)
    public var style: DictationStyleRecord?

    public init(id: String, time: Date, app: String?, bundle: String?, duration: Double, raw: String, polished: String?,
                text: String, model: String?, fellBack: Bool, reason: String?, insert: String, audio: String? = nil,
                asrModel: String? = nil, language: String? = nil, termsApplied: [String]? = nil, contextUsed: Bool? = nil,
                context: String? = nil, timing: [String: Int]? = nil, repaired: [String]? = nil, fitted: [String]? = nil) {
        self.id = id; self.time = time; self.app = app; self.bundle = bundle; self.duration = duration; self.raw = raw
        self.polished = polished; self.text = text; self.model = model; self.fellBack = fellBack; self.reason = reason
        self.insert = insert; self.audio = audio; self.asrModel = asrModel; self.language = language
        self.termsApplied = termsApplied; self.contextUsed = contextUsed; self.context = context
        self.timing = timing; self.repaired = repaired; self.fitted = fitted
    }

    public static let timingKeys = ["asr_ms", "polish_ms", "load_ms", "total_ms", "segments"]

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
        if let t = termsApplied { o["terms_applied"] = t }
        if let c = contextUsed { o["context_used"] = c }
        if let c = context { o["context"] = c }
        for (k, v) in timing ?? [:] where DictationEntry.timingKeys.contains(k) { o[k] = v }
        if let r = repaired, !r.isEmpty { o["repaired"] = r }
        if let f = fitted, !f.isEmpty { o["fitted"] = f }
        if let c = corrected { o["corrected"] = c }
        style?.write(into: &o)
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
        termsApplied = o["terms_applied"] as? [String]
        contextUsed = o["context_used"] as? Bool
        context = o["context"] as? String
        var t: [String: Int] = [:]
        for k in DictationEntry.timingKeys { if let v = o[k] as? Int { t[k] = v } }
        timing = t.isEmpty ? nil : t
        repaired = o["repaired"] as? [String]
        fitted = o["fitted"] as? [String]
        corrected = o["corrected"] as? String
        style = DictationStyleRecord(json: o)
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

    /// The user corrected what was typed (the Dictation page): the entry keeps both, `text` and `corrected`.
    public func correct(_ id: String, text: String) {
        appendLine(["op": "correct", "id": id, "text": text, "t": DictationEntry.iso.string(from: Date())])
    }

    /// Reformat-last (or its undo, or a list taken apart in the field): folded into the entry's `reformats`.
    public func restyle(_ id: String, _ r: DictationReformatRecord) {
        var o = r.json
        o["op"] = "style"
        o["id"] = id
        appendLine(o)
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
            case "delete":      // an entry written again later (undo) comes back once, at its own time
                let gone = Set(o["ids"] as? [String] ?? [])
                for i in gone { byID[i] = nil }
                order.removeAll { gone.contains($0) }
            case "clear": byID = [:]; order = []
            case "correct":
                if let i = o["id"] as? String, var e = byID[i], let t = o["text"] as? String { e.corrected = t; byID[i] = e }
            case "style":
                if let i = o["id"] as? String, var e = byID[i], let r = DictationReformatRecord(json: o) {
                    if e.style == nil { e.style = DictationStyleRecord(style: "light", source: "default", category: "other", base: "light") }
                    e.style?.reformats.append(r)
                    byID[i] = e
                }
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
