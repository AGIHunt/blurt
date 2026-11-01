// Dictation history (docs/design/dictation.md): $BLURT_HOME/dictation/history.jsonl, append-only. One line per
// dictation; edits are lines too, applied in order when it is read:
//   {"id","t","app","bundle","duration","raw","polished","text","model","fell_back","reason","insert","audio",
//    "terms_applied" [custom words the dictation wrote], "context_used" (text around the cursor went to polish),
//    "context" (that text — only with record.dictation.keep_audio, on unless turned off),
//    "asr_ms","polish_ms","load_ms","total_ms" (key-up → paste),"segments" (pieces streamed), "fitted" (how it was fitted at the cursor), "repaired" (spans polish
//    dropped that the guard put back), …}
//   {"op":"delete","ids":[…],"t"}   {"op":"item","id","item","uid","t"}   {"op":"clear","t"}
//   {"op":"correct","id","text","t"}  the user's corrected text (the Dictation page's "Save correction"); "corrected"
//                                      on a rewritten line; "text": null takes it back (⌘Z)
//   {"op":"style","id","action","from","to","replaced","text","before","t"}  reformat-last, its undo, or a list the
//                                      user took apart (action reformat | undo | revert); "reformats" on a rewritten
//                                      line. Replaced in the field: "text" becomes the entry's text (what is there
//                                      now), the first version is kept as `typedFirst`.
// Since the styles work: "style", "style_source", "style_router" (DictationStyleRecord: the router's inputs and decision).
// Since v0.9: "asr_tags" — per piece, the speech model's language tag and how sure it was (DictationLanguageTag: the
// tag, p_en / p_<lang> read without the Words, p_en_words with them, the margin to the threshold, redone), so a take
// typed in the wrong language shows in the history and the Dictation Lab.
// Since v1.0.2: "pieces" — with the audio only (keep_audio): each streamed piece's cut, pause, transcript and polish
// window (DictationPieceRecord), so `dictation_lab.py from-history` / `review` replay the take as it ran.
// Retention (record.dictation.retention_days, default 30) rewrites the file without what is older or deleted, and
// removes their audio (dictation/audio/<id>.wav, kept only with record.dictation.keep_audio), and any recording there
// no entry points at that is over an hour old (a take dropped, cancelled, or cut short by a quit or a crash). It runs
// at launch. dictation.py reads the same file (list, turn into an item).
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
    /// a streamed take some of whose polish windows fell back (not all: then `fellBack`): how many, of how many
    /// (`reason` is the first one's); nil: none did, or an older entry
    public var fellBackParts: DictationParts?
    /// "pasted" | "copied" | "none"
    public var insert: String
    public var audio: String?
    public var asrModel: String?
    public var language: String?
    /// set once it was turned into an item: its id ("BA-12") and uid
    public var item: String?
    public var itemUID: String?
    /// the words this dictation wrote (the biased speech model or polish); nil in older entries
    public var termsApplied: [String]?
    /// whether the text around the cursor went to polish; nil in older entries
    public var contextUsed: Bool?
    /// that text itself — kept only when record.dictation.keep_audio is on (the default), as long as the entry
    /// (record.dictation.retention_days, 30)
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
    /// translated (docs/design/dictation-translate.md): by what, into what, and what was said (nil: not translated)
    public var translate: DictationTranslateRecord?
    /// what was typed first, when reformat-last replaced it in the field since (`text` is then the current version)
    public var typedFirst: String?
    /// the speech model's language tag per piece (nil: an older entry, or a model without one)
    public var asrTags: [DictationLanguageTag]?
    /// each streamed piece — where it was cut, the pause after it, what was heard, what its polish window got and
    /// committed — kept with the audio only (record.dictation.keep_audio), so the Lab can replay the take as it ran
    public var pieces: [DictationPieceRecord]?
    /// the windows the pieces were heard again in (docs/design/dictation.md §Hearing again), kept like `pieces`
    public var windows: [DictationWindowRecord]?
    /// only my voice (docs/design/voiceprint.md): the spans of the take another speaker said, left out of the text —
    /// in seconds of the kept audio, which is the take as recorded (nil: nothing left out, or the switch off)
    public var voiceDropped: [[Double]]?

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

    public static let timingKeys = ["asr_ms", "polish_ms", "structure_ms", "translate_ms", "load_ms", "total_ms", "segments", "windows", "rehear_ms_all"]

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
        if let p = fellBackParts { o["fell_back_parts"] = [p.n, p.of] }
        if let t = asrTags, !t.isEmpty { o["asr_tags"] = t.map(\.json) }
        if let p = pieces, !p.isEmpty { o["pieces"] = p.map(\.json) }
        if let w = windows, !w.isEmpty { o["windows"] = w.map(\.json) }
        if let v = voiceDropped, !v.isEmpty { o["voice_dropped"] = v }
        style?.write(into: &o)
        if let t = translate { o["translate"] = t.json }
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
        if let p = o["fell_back_parts"] as? [Int], p.count == 2 { fellBackParts = DictationParts(n: p[0], of: p[1]) }
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
        asrTags = (o["asr_tags"] as? [[String: Any]])?.compactMap(DictationLanguageTag.init(json:))
        pieces = (o["pieces"] as? [[String: Any]])?.compactMap(DictationPieceRecord.init(json:))
        windows = (o["windows"] as? [[String: Any]])?.compactMap(DictationWindowRecord.init(json:))
        voiceDropped = o["voice_dropped"] as? [[Double]]
        style = DictationStyleRecord(json: o)
        translate = (o["translate"] as? [String: Any]).flatMap(DictationTranslateRecord.init(json:))
    }
}

/// One streamed piece of a kept take (DictationStream.Result.pieces, the keys the Dictation Lab's segments use).
public struct DictationPieceRecord: Hashable {
    public var start: Double
    public var end: Double
    public var pauseAfter: Double?
    public var heard: String
    public var raw: String
    /// the polish window's input and what it committed (nil: polish off)
    public var polishIn: String?
    public var committed: String?
    public var polished: String?
    public var fellBack: Bool
    public var reason: String?
    /// it began at a hard cut (overlapping the piece before: no pause to cut at for 20 s)
    public var hard = false
    /// heard only as part of its window (the last piece, when the take is heard again): no transcript of its own
    public var covered = false

    public init?(json o: [String: Any]) {
        guard let s = (o["start"] as? NSNumber)?.doubleValue, let e = (o["end"] as? NSNumber)?.doubleValue else { return nil }
        start = s; end = e
        hard = o["hard"] as? Bool ?? false
        covered = o["covered"] as? Bool ?? false
        pauseAfter = (o["pause_after"] as? NSNumber)?.doubleValue
        raw = o["raw"] as? String ?? ""
        heard = o["asr_text"] as? String ?? raw
        polishIn = o["polish_in"] as? String
        committed = o["text"] as? String
        polished = o["polished"] as? String
        fellBack = o["fell_back"] as? Bool ?? false
        reason = o["reason"] as? String
    }

    public var json: [String: Any] {
        let r = { (x: Double) in (x * 100).rounded() / 100 }
        var o: [String: Any] = ["start": r(start), "end": r(end), "asr_text": heard, "raw": raw, "fell_back": fellBack]
        if let p = pauseAfter { o["pause_after"] = r(p) }
        if let p = polishIn { o["polish_in"] = p }
        if let c = committed { o["text"] = c }
        if let p = polished { o["polished"] = p }
        if let w = reason { o["reason"] = w }
        if hard { o["hard"] = true }
        if covered { o["covered"] = true }
        return o
    }
}

/// One window of a kept take heard again (DictationStream.Result.windows): which pieces, what they had said and what
/// the window said.
public struct DictationWindowRecord: Hashable {
    public var start: Double
    public var end: Double
    public var pieces: [Int]
    public var piecesText: String
    public var raw: String
    /// how long hearing it again took (0: one piece, not heard again)
    public var asrMS: Int

    public init?(json o: [String: Any]) {
        guard let s = (o["start"] as? NSNumber)?.doubleValue, let e = (o["end"] as? NSNumber)?.doubleValue else { return nil }
        start = s; end = e
        pieces = o["pieces"] as? [Int] ?? []
        piecesText = o["pieces_text"] as? String ?? ""
        raw = o["raw"] as? String ?? ""
        asrMS = o["asr_ms"] as? Int ?? 0
    }

    public var json: [String: Any] {
        let r = { (x: Double) in (x * 100).rounded() / 100 }
        return ["start": r(start), "end": r(end), "pieces": pieces, "pieces_text": piecesText, "raw": raw, "asr_ms": asrMS]
    }
}

/// What a row of the Dictation page says beside the app's name (system.md §3.5a): nothing for the usual take —
/// polished and typed in — else the one exception that matters most, in one neutral chip: the item it became (a link
/// to it), that it was only copied (no text field had the focus: it still has to be pasted), or that it went in
/// without polish.
public enum DictationRowMark: Equatable {
    case item(String)
    case copiedOnly
    case notPolished
}

extension DictationEntry {
    public var rowMark: DictationRowMark? {
        if let i = item, !i.isEmpty { return .item(i) }
        if insert == "copied" { return .copiedOnly }
        if fellBack { return .notPolished }
        return nil
    }

    /// The list's preview of a text: one paragraph — line breaks and runs of spaces become one space — so every row
    /// clamps the same way (two lines, then "…"), a list typed into Notes as much as a sentence.
    public static func preview(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}

/// The speech model's language tag for one piece (transcribe.py's `tag`): which language it wrote in, the
/// probabilities it gave English and the user's language without the Words (what decided) and with them, and how far
/// the decision was from the line (`margin`, in log-odds: logit(English share) − logit(threshold), > 0 English — a
/// clear English piece is about +4, the v0.9 translated sentence +0.1). Within `fragileMargin` the tag could flip with
/// a slightly different take — the Dictation Lab flags it.
public struct DictationLanguageTag: Hashable {
    public var tag: String?
    public var pEn: Double?
    /// the user's language's probability (p_zh, p_ja …) and its code
    public var pPref: Double?
    public var prefer: String?
    public var pEnWords: Double?
    public var margin: Double?
    public var redone: Bool
    public static let fragileMargin = 1.0           // log-odds (dictation_vocab.FRAGILE_MARGIN)

    public var fragile: Bool { margin.map { abs($0) < DictationLanguageTag.fragileMargin } ?? false }

    /// The pieces' closest call (the smallest margin either way): what the Lab shows for a take.
    public static func closest(_ tags: [DictationLanguageTag]) -> DictationLanguageTag? {
        tags.filter { $0.margin != nil }.min { abs($0.margin!) < abs($1.margin!) }
    }
    public static func closest(_ json: [[String: Any]]) -> DictationLanguageTag? { closest(json.compactMap(DictationLanguageTag.init(json:))) }

    public init?(json o: [String: Any]) {
        guard !o.isEmpty else { return nil }
        tag = o["tag"] as? String
        pEn = (o["p_en"] as? NSNumber)?.doubleValue
        if let (k, v) = o.first(where: { $0.key.hasPrefix("p_") && $0.key != "p_en" && $0.key != "p_en_words" }) {
            prefer = String(k.dropFirst(2))
            pPref = (v as? NSNumber)?.doubleValue
        }
        pEnWords = (o["p_en_words"] as? NSNumber)?.doubleValue
        margin = (o["margin"] as? NSNumber)?.doubleValue
        redone = o["redone"] as? Bool ?? false
    }

    public var json: [String: Any] {
        var o: [String: Any] = [:]
        if let t = tag { o["tag"] = t }
        if let p = pEn { o["p_en"] = p }
        if let k = prefer, let p = pPref { o["p_\(k)"] = p }
        if let p = pEnWords { o["p_en_words"] = p }
        if let m = margin { o["margin"] = m }
        if redone { o["redone"] = true }
        return o
    }
}

/// A streamed take's polish windows that fell back (DictationStream.assemble): the take counts as not polished only
/// when every window fell back; some of them is said as "n of m parts", never as the whole take typed as heard (the
/// dogfood's 213 s take was labelled so while most of it was polished).
public enum DictationWindowFallback {
    public static func of(_ fellBack: [Bool]) -> (all: Bool, parts: DictationParts?) {
        let n = fellBack.filter { $0 }.count
        if n == 0 { return (false, nil) }
        if n == fellBack.count { return (true, nil) }
        return (false, DictationParts(n: n, of: fellBack.count))
    }
}

/// n of m (a take's polish windows that fell back).
public struct DictationParts: Hashable {
    public var n: Int
    public var of: Int
    public init(n: Int, of: Int) { self.n = n; self.of = of }
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

    /// Deletes entries. Their kept recordings move aside (audio/.deleted/) for Undo — `restoreAudio` puts them back,
    /// `purgeDeleted` removes them for good (the page does after a couple of minutes; `prune` at launch, `clear`).
    /// Before, the audio went at once and Undo brought back a row without it: no Retry, no Add to Lab.
    public func delete(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let gone = load().filter { ids.contains($0.id) }
        appendLine(["op": "delete", "ids": ids, "t": DictationEntry.iso.string(from: Date())])
        let fm = FileManager.default
        for e in gone {
            guard let a = e.audio else { continue }
            let src = resolve(a)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.createDirectory(at: deletedDir, withIntermediateDirectories: true)
            let dst = deletedDir.appendingPathComponent(src.lastPathComponent)
            try? fm.removeItem(at: dst)
            if (try? fm.moveItem(at: src, to: dst)) == nil { try? fm.removeItem(at: src) }
        }
        NotificationCenter.default.post(name: DictationHistory.changed, object: self, userInfo: ["ids": ids])
    }

    /// Where deleted entries' recordings wait for Undo.
    public var deletedDir: URL { audioDir.appendingPathComponent(".deleted") }

    /// Undo of a delete: the entry's recording back where it was. true when it is there (again).
    @discardableResult
    public func restoreAudio(_ e: DictationEntry) -> Bool {
        guard let a = e.audio else { return false }
        let dst = resolve(a), src = deletedDir.appendingPathComponent(dst.lastPathComponent)
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) { return true }
        return (try? fm.moveItem(at: src, to: dst)) != nil
    }

    /// The deleted recordings go for good: these (`names`: file names), or all older than `olderThan` s.
    public func purgeDeleted(_ names: [String]? = nil, olderThan: TimeInterval = 0, now: Date = Date()) {
        let fm = FileManager.default
        let all = (try? fm.contentsOfDirectory(atPath: deletedDir.path)) ?? []
        for n in names ?? all where all.contains(n) {
            let f = deletedDir.appendingPathComponent(n)
            if olderThan > 0, let m = (try? fm.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date,
               now.timeIntervalSince(m) < olderThan { continue }
            try? fm.removeItem(at: f)
        }
    }

    /// Posted after `delete` (userInfo "ids") and `clear` (no ids: everything): the app forgets what it kept of
    /// those takes (reformat-last's last paste, the after-typing watch).
    public static let changed = Notification.Name("dev.blurt.dictation.history.changed")
    /// The takes still listening or on their way (the app sets it): `clear` never deletes their audio under them.
    public static var liveIDs: () -> [String] = { [] }

    public func markItem(_ id: String, item: String, uid: String) {
        appendLine(["op": "item", "id": id, "item": item, "uid": uid, "t": DictationEntry.iso.string(from: Date())])
    }

    /// The user corrected what was typed (the Dictation page): the entry keeps both, `text` and `corrected`. nil: the
    /// correction taken back (⌘Z) — the entry is as typed again.
    public func correct(_ id: String, text: String?) {
        appendLine(["op": "correct", "id": id, "text": text ?? NSNull(), "t": DictationEntry.iso.string(from: Date())])
    }

    /// Reformat-last (or its undo, or a list taken apart in the field): folded into the entry's `reformats`.
    public func restyle(_ id: String, _ r: DictationReformatRecord) {
        var o = r.json
        o["op"] = "style"
        o["id"] = id
        appendLine(o)
    }

    /// Everything goes: the file is emptied and the audio removed — except the audio of a take still listening or on
    /// its way (`liveIDs`: its wav and pieces), which would otherwise end as "nothing heard".
    public func clear() {
        let live = DictationHistory.liveIDs()
        exclusive {
            let fm = FileManager.default
            for n in (try? fm.contentsOfDirectory(atPath: audioDir.path)) ?? [] where !live.contains(where: { n.hasPrefix($0) }) {
                try? fm.removeItem(at: audioDir.appendingPathComponent(n))
            }
            try? Data().write(to: url, options: .atomic)
        }
        NotificationCenter.default.post(name: DictationHistory.changed, object: self)
    }

    private func appendLine(_ o: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
        d.append(0x0A)
        exclusive {
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            _ = d.withUnsafeBytes { write(fd, $0.baseAddress, d.count) }
            close(fd)
        }
    }

    /// The file's one writer at a time: this process's threads (`lock`) and other processes — dictation.py appends
    /// item links — through an advisory flock on `.history.lock` beside it (not on the file itself: `prune` replaces
    /// it). An append can't land between `prune`'s read and its rewrite and be lost.
    private func exclusive<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent(".history.lock").path, O_RDWR | O_CREAT, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return body()
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
                if let i = o["id"] as? String, var e = byID[i] { e.corrected = o["text"] as? String; byID[i] = e }
            case "style":
                if let i = o["id"] as? String, var e = byID[i], let r = DictationReformatRecord(json: o) {
                    if e.style == nil { e.style = DictationStyleRecord(style: "light", source: "default", category: "other", base: "light") }
                    e.style?.reformats.append(r)
                    // replaced in the field: the entry's text is what is there now (the first version stays in
                    // `typedFirst`)
                    if r.replaced, let t = r.text {
                        if e.typedFirst == nil { e.typedFirst = e.text }
                        e.text = t
                    }
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

    /// Rewrites the file without entries older than `days` (and without the edit lines), removing their audio — and
    /// any recording in audio/ that no entry keeps (`pruneOrphanAudio`). Returns how many entries went.
    @discardableResult
    public func prune(days: Int, now: Date = Date()) -> Int {
        purgeDeleted()                  // a delete's Undo doesn't outlive the app
        recoverInterrupted(days: days, now: now)
        return exclusive {
            let all = load()
            pruneOrphanAudio(keeping: all, now: now)
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
            try? out.write(to: url, options: .atomic)
            return drop.count
        }
    }

    /// The reason of a take that Blurt quit (or crashed) on before it was typed: a failed take, with Retry.
    public static let interruptedReason = "asr_failed:interrupted"

    /// A take's own recording (dictation/audio/<id>.wav — not its pieces) with no entry: Blurt quit, crashed or was
    /// relaunched between the key-down and the paste. Within the retention it becomes an entry that says so, with its
    /// recording and Retry, instead of being deleted as an orphan a launch later. Never a take still running
    /// (`liveIDs`), nor a recording under a second long. Returns the ids recovered.
    @discardableResult
    public func recoverInterrupted(days: Int, now: Date = Date()) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: audioDir.path) else { return [] }
        let entries = load()
        let have = Set(entries.map(\.id))
        let kept = Set(entries.compactMap { $0.audio.map { resolve($0).standardizedFileURL.lastPathComponent } })
        let live = DictationHistory.liveIDs()
        let cutoff = now.addingTimeInterval(-Double(max(0, days)) * 86400)
        var out: [String] = []
        for n in names.sorted() {
            guard let id = DictationHistory.takeID(wav: n), !have.contains(id), !kept.contains(n), !live.contains(id) else { continue }
            let f = audioDir.appendingPathComponent(n)
            guard let a = try? fm.attributesOfItem(atPath: f.path), let size = (a[.size] as? NSNumber)?.doubleValue,
                  size >= 44 + DictationHistory.wavBytesPerSecond else { continue }
            let time = DictationHistory.time(of: id) ?? (a[.modificationDate] as? Date) ?? now
            guard time >= cutoff else { continue }
            append(DictationEntry(id: id, time: time, app: nil, bundle: nil, duration: (size - 44) / DictationHistory.wavBytesPerSecond,
                                  raw: "", polished: nil, text: "", model: nil, fellBack: false,
                                  reason: DictationHistory.interruptedReason, insert: "none", audio: "audio/\(n)"))
            out.append(id)
        }
        return out
    }

    /// 16 kHz mono 16-bit: a take's recording.
    static let wavBytesPerSecond = 32_000.0

    /// "d-20261023-020301-4f2a.wav" → its id; nil for a piece (-p1, -w2, -live) or anything else.
    static func takeID(wav n: String) -> String? {
        guard n.hasSuffix(".wav") else { return nil }
        let id = String(n.dropLast(4))
        let parts = id.split(separator: "-")
        guard parts.count == 4, parts[0] == "d", parts[1].count == 8, parts[2].count == 6, parts[3].count == 4,
              parts[1].allSatisfy(\.isNumber), parts[2].allSatisfy(\.isNumber), parts[3].allSatisfy(\.isHexDigit) else { return nil }
        return id
    }

    /// When the take with this id started (the id says it, in local time: `newID`).
    static func time(of id: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.date(from: String(id.dropFirst(2).prefix(15)))
    }

    /// A take's audio (dictation/audio/<id>.wav, and its streamed pieces <id>-pN.wav) is kept only when its entry
    /// says so (record.dictation.keep_audio, the Lab's "keep the next N"). A take that was dropped, cancelled, or cut
    /// short by a quit or a crash left its recording behind with no entry pointing at it: those go once they are
    /// older than `minAge` (no take still running is that old — dictation stops at 5 minutes). The Lab's own
    /// recordings live in dictation/lab/ and are never touched. Returns the files removed.
    @discardableResult
    public func pruneOrphanAudio(keeping entries: [DictationEntry]? = nil, minAge: TimeInterval = 3600, now: Date = Date()) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: audioDir.path) else { return [] }
        let kept = Set((entries ?? load()).compactMap { $0.audio.map { resolve($0).standardizedFileURL.path } })
        var removed: [String] = []
        for n in names where n.lowercased().hasSuffix(".wav") {
            let f = audioDir.appendingPathComponent(n)
            guard !kept.contains(f.standardizedFileURL.path),
                  let m = (try? fm.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(m) >= minAge else { continue }
            if (try? fm.removeItem(at: f)) != nil { removed.append(n) }
        }
        return removed
    }
}
