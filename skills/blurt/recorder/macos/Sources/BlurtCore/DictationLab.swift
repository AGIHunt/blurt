// Dictation Lab (测试台; docs/design/dictation.md §Lab): a take — the audio, what every stage made of it — saved as a
// case with the user's ground truth and marks, to score, compare and run again. Pure parts, unit-tested
// (Tests/BlurtCoreTests/DictationLabTests.swift):
//
//   • LabMetrics   CER / WER / punctuation / term accuracy and the diff — the same rules as scripts/dictation_lab.py,
//                  both checked against tests/fixtures/lab_metrics.jsonl. Units: each CJK character, each Latin word
//                  or number; punctuation marks are tokens of their own for the diff, never units; case and full-width
//                  forms ignored (NFKC, lower case).
//   • LabCase      case.json (schema 1) kept as its JSON object, so keys a newer app or the CLI wrote survive a save
//   • LabStore     $BLURT_HOME/dictation/lab/cases/<id>/ {audio.wav, case.json, runs.jsonl}
//   • LabVocab     what learning from a correction changed in vocabulary.json, term by term, and putting it back (Undo)
// Everything stays on this Mac.
import Foundation

// MARK: - metrics

public enum LabMetrics {
    public struct Token: Equatable {
        public enum Kind: String { case cjk, word, punct }
        public let text: String
        public let key: String
        public let kind: Kind
        /// a space before it in the text
        public let space: Bool
    }

    public struct Chunk: Equatable {
        public enum Op: String { case equal, replace, delete, insert }
        public let op: Op
        public let ref: String
        public let hyp: String
        public init(_ op: Op, _ ref: String, _ hyp: String) { self.op = op; self.ref = ref; self.hyp = hyp }
    }

    public struct Terms: Equatable {
        public let expected: Int
        public let hit: Int
        public let missed: [String]
        public var accuracy: Double { expected == 0 ? 0 : LabMetrics.round4(Double(hit) / Double(expected)) }
    }

    public struct Score: Equatable {
        public let wer: Double
        public let cer: Double
        public let punct: Double
        public let exact: Bool
        public let refUnits: Int
        public let hypUnits: Int
        public let terms: Terms?

        public var json: [String: Any] {
            var o: [String: Any] = ["wer": wer, "cer": cer, "punct": punct, "exact": exact, "ref_units": refUnits, "hyp_units": hypUnits]
            if let t = terms {
                o["terms"] = ["expected": t.expected, "hit": t.hit, "missed": t.missed, "accuracy": t.accuracy] as [String: Any]
            } else {
                o["terms"] = NSNull()
            }
            return o
        }
    }

    static func round4(_ x: Double) -> Double { (x * 10000).rounded() / 10000 }

    public static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: return true
        default: return false
        }
    }

    static func wordy(_ u: Unicode.Scalar) -> Bool { CharacterSet.alphanumerics.contains(u) && !isCJK(u) }

    static let ends: Set<Unicode.Scalar> = Set("。.!！?？…".unicodeScalars)
    static let pauses: Set<Unicode.Scalar> = Set("，,、;；:：".unicodeScalars)

    static func punctClass(_ u: Unicode.Scalar) -> String {
        ends.contains(u) ? "<end>" : pauses.contains(u) ? "<pause>" : String(u)
    }

    public static func tokens(_ text: String) -> [Token] {
        var out: [Token] = []
        var word = "", key = "", sp = false, pendingSpace = false
        for orig in text.unicodeScalars {
            let c = String(orig).precomposedStringWithCompatibilityMapping     // the key's form; the text stays
            let c1 = c.unicodeScalars.first
            if !word.isEmpty, let f = c1, wordy(f) || f == "'" || f == "’" {
                word.unicodeScalars.append(orig)
                key += c.lowercased()
                continue
            }
            if !word.isEmpty {
                out.append(Token(text: word, key: key, kind: .word, space: sp))
                word = ""; key = ""
            }
            guard let f = c1, !CharacterSet.whitespacesAndNewlines.contains(f) else {
                if c1 != nil { pendingSpace = true }
                continue
            }
            sp = pendingSpace && !out.isEmpty
            pendingSpace = false
            if isCJK(f) {
                out.append(Token(text: String(orig), key: c, kind: .cjk, space: sp))
            } else if wordy(f) {
                word = String(orig); key = c.lowercased()
            } else {
                out.append(Token(text: String(orig), key: punctClass(f), kind: .punct, space: sp))
            }
        }
        if !word.isEmpty { out.append(Token(text: word, key: key, kind: .word, space: sp)) }
        return out
    }

    public static func units(_ text: String) -> [String] { tokens(text).filter { $0.kind != .punct }.map(\.key) }

    static func lev<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        var prev = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var cur = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, y) in b.enumerated() {
                cur[j + 1] = min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (x == y ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    enum EditOp: Equatable { case equal(Int, Int), sub(Int, Int), del(Int), ins(Int) }

    /// The minimal edit script; ties: diagonal, then delete, then insert (as the Python one).
    static func align(_ a: [String], _ b: [String]) -> [EditOp] {
        let n = a.count, m = b.count
        var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                }
            }
        }
        var ops: [EditOp] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1) {
                ops.append(a[i - 1] == b[j - 1] ? .equal(i - 1, j - 1) : .sub(i - 1, j - 1))
                i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
                ops.append(.del(i - 1)); i -= 1
            } else {
                ops.append(.ins(j - 1)); j -= 1
            }
        }
        return ops.reversed()
    }

    static func join(_ ts: [Token], first: Bool) -> String {
        var s = ""
        for (k, t) in ts.enumerated() {
            if t.space && !(first && k == 0) { s += " " }
            s += t.text
        }
        return s
    }

    /// Chunks over every token (punctuation too); joining their `hyp` (or `ref`) gives the text back.
    public static func diff(_ ref: String, _ hyp: String) -> [Chunk] {
        let rt = tokens(ref), ht = tokens(hyp)
        var chunks: [(equal: Bool, r: [Int], h: [Int])] = []
        for op in align(rt.map(\.key), ht.map(\.key)) {
            var eq = false, ri: Int?, hi: Int?
            switch op {
            case let .equal(a, b): eq = true; ri = a; hi = b
            case let .sub(a, b): ri = a; hi = b
            case let .del(a): ri = a
            case let .ins(b): hi = b
            }
            if chunks.isEmpty || chunks[chunks.count - 1].equal != eq { chunks.append((eq, [], [])) }
            if let r = ri { chunks[chunks.count - 1].r.append(r) }
            if let h = hi { chunks[chunks.count - 1].h.append(h) }
        }
        return chunks.map { c in
            let op: Chunk.Op = c.equal ? .equal : c.r.isEmpty ? .insert : c.h.isEmpty ? .delete : .replace
            return Chunk(op, join(c.r.map { rt[$0] }, first: c.r.first == 0), join(c.h.map { ht[$0] }, first: c.h.first == 0))
        }
    }

    static func find(_ needle: [String], in hay: [String], from: Int = 0) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
        for i in from...(hay.count - needle.count) where Array(hay[i..<(i + needle.count)]) == needle { return i }
        return nil
    }

    /// A term is spelled right when its units are there in a row ("T mux" is not tmux); case doesn't matter.
    public static func termHits(_ terms: [String], _ hyp: String) -> (hit: [String], missed: [String]) {
        let h = units(hyp)
        let hit = terms.filter { find(units($0), in: h) != nil }
        return (hit, terms.filter { !hit.contains($0) })
    }

    /// The custom words the ground truth contains, in order (one inside a longer one found there isn't counted).
    public static func expectedTerms(_ truth: String, vocabulary: [String]) -> [String] {
        let k = units(truth)
        var found: [(Int, Int, String)] = []
        let cands = Set(vocabulary.filter { !units($0).isEmpty }).sorted {
            let a = units($0).count, b = units($1).count
            return a != b ? a > b : $0 < $1
        }
        for t in cands {
            let u = units(t)
            var from = 0
            while let i = find(u, in: k, from: from) {
                if !found.contains(where: { $0.0 <= i && i + u.count <= $0.1 }) { found.append((i, i + u.count, t)); break }
                from = i + 1
            }
        }
        return found.sorted { $0.0 < $1.0 }.map(\.2)
    }

    /// nil: no reference to score against.
    public static func score(_ ref: String, _ hyp: String, terms: [String] = []) -> Score? {
        let ru = units(ref), hu = units(hyp)
        guard !ru.isEmpty else { return nil }
        let rc = Array(ru.joined().unicodeScalars), hc = Array(hu.joined().unicodeScalars)
        let rt = tokens(ref), ht = tokens(hyp)
        var pErr = 0
        for op in align(rt.map(\.key), ht.map(\.key)) {
            switch op {
            case .equal: continue
            case let .sub(a, b): if rt[a].kind == .punct || ht[b].kind == .punct { pErr += 1 }
            case let .del(a): if rt[a].kind == .punct { pErr += 1 }
            case let .ins(b): if ht[b].kind == .punct { pErr += 1 }
            }
        }
        let pRef = rt.filter { $0.kind == .punct }.count
        var t: Terms?
        if !terms.isEmpty {
            let r = termHits(terms, hyp)
            t = Terms(expected: terms.count, hit: r.hit.count, missed: r.missed)
        }
        return Score(wer: round4(Double(lev(ru, hu)) / Double(ru.count)), cer: round4(Double(lev(rc, hc)) / Double(max(1, rc.count))),
                     punct: round4(min(1, Double(pErr) / Double(max(1, pRef)))), exact: ru == hu, refUnits: ru.count,
                     hypUnits: hu.count, terms: t)
    }
}

// MARK: - a case

/// case.json (schema 1, docs/design/dictation.md §Lab), kept as its JSON object.
public struct LabCase: Identifiable {
    public static let schema = 1
    /// the error chips, in the order the UI shows them
    public static let errorTags = ["term", "code_switch", "punctuation", "filler", "dropped", "made_up", "segmentation", "clipped", "slow"]

    public var json: [String: Any]

    public init(json: [String: Any]) { self.json = json }

    public init(id: String, source: String, now: Date = Date()) {
        let t = LabStore.iso.string(from: now)
        json = ["schema": LabCase.schema, "id": id, "created": t, "updated": t, "source": source, "audio": NSNull(),
                "duration": NSNull(), "reference": NSNull(), "corrected": NSNull(), "scenario": [String: Any](),
                "errors": [String](), "rating": ["stars": NSNull(), "good": NSNull()], "note": "",
                "app": ["bundle": NSNull()], "context": ["included": false], "config": [String: Any](), "take": NSNull(),
                "expected_terms": [String](), "metrics": NSNull(), "learned": [Any](), "app_version": NSNull(),
                "history_id": NSNull()]
    }

    public var id: String { json["id"] as? String ?? "" }
    public var created: Date { (json["created"] as? String).flatMap { LabStore.iso.date(from: $0) } ?? Date(timeIntervalSince1970: 0) }
    public var source: String { json["source"] as? String ?? "" }
    public var hasAudio: Bool { (json["audio"] as? String)?.isEmpty == false }
    public var duration: Double? {
        get { json["duration"] as? Double }
        set { json["duration"] = newValue ?? NSNull() }
    }

    private func str(_ k: String) -> String? { (json[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    private mutating func setStr(_ k: String, _ v: String?) {
        let t = v?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        json[k] = t.isEmpty ? NSNull() : t
    }

    public var reference: String? { get { str("reference") } set { setStr("reference", newValue) } }
    public var corrected: String? { get { str("corrected") } set { setStr("corrected", newValue) } }
    public var note: String { get { json["note"] as? String ?? "" } set { json["note"] = newValue } }
    /// What the user meant: the corrected text, else the reference.
    public var truth: String? { corrected ?? reference }

    public var errors: [String] {
        get { json["errors"] as? [String] ?? [] }
        set { json["errors"] = LabCase.errorTags.filter { newValue.contains($0) } }
    }
    /// scenario tags: app (wechat, code_editor …), languages (zh, en, mixed), noise, speed
    public var scenario: [String: String] {
        get { json["scenario"] as? [String: String] ?? [:] }
        set { json["scenario"] = newValue.filter { !$0.value.isEmpty } }
    }
    public var stars: Int? {
        get { (json["rating"] as? [String: Any])?["stars"] as? Int }
        set { var r = json["rating"] as? [String: Any] ?? [:]; r["stars"] = newValue.map { min(5, max(1, $0)) as Any } ?? NSNull(); json["rating"] = r }
    }
    public var good: Bool? {
        get { (json["rating"] as? [String: Any])?["good"] as? Bool }
        set { var r = json["rating"] as? [String: Any] ?? [:]; r["good"] = newValue.map { $0 as Any } ?? NSNull(); json["rating"] = r }
    }
    public var bundle: String? {
        get { (json["app"] as? [String: Any])?["bundle"] as? String }
        set { json["app"] = ["bundle": newValue.map { $0 as Any } ?? NSNull()] }
    }
    /// The text around the cursor is stored only when the user ticked "include context".
    public var contextIncluded: Bool { (json["context"] as? [String: Any])?["included"] as? Bool ?? false }
    public mutating func setContext(_ c: [String: String]?) {
        guard let c = c, !c.isEmpty else { json["context"] = ["included": false]; return }
        var o: [String: Any] = ["included": true]
        for (k, v) in c where ["before", "after", "selection", "title", "app"].contains(k) && !v.isEmpty { o[k] = v }
        json["context"] = o
    }
    public var context: [String: String] {
        var o: [String: String] = [:]
        for (k, v) in (json["context"] as? [String: Any]) ?? [:] { if let s = v as? String { o[k] = s } }
        return o
    }
    public var take: [String: Any]? {
        get { json["take"] as? [String: Any] }
        set { json["take"] = newValue ?? NSNull() }
    }
    /// What the pipeline typed (after the fit at the cursor).
    public var finalText: String? { (take?["fitted"] as? String) ?? (take?["text"] as? String) }
    public var expectedTerms: [String] {
        get { json["expected_terms"] as? [String] ?? [] }
        set { json["expected_terms"] = newValue }
    }
    public var metrics: [String: Any]? { json["metrics"] as? [String: Any] }

    /// The take's metrics against the truth (the expected custom words found in it first, when not set yet).
    public mutating func refreshMetrics(vocabulary: [String]) {
        guard let t = truth, let hyp = finalText else { json["metrics"] = NSNull(); return }
        expectedTerms = LabMetrics.expectedTerms(t, vocabulary: vocabulary)
        json["metrics"] = LabMetrics.score(t, hyp, terms: expectedTerms)?.json ?? NSNull()
    }

    /// What is wrong with it (empty: fine) — the same checks as dictation_lab.py's validate.
    public var problems: [String] {
        var out: [String] = []
        if json["schema"] as? Int != LabCase.schema { out.append("schema") }
        for k in ["id", "created", "source"] where !(json[k] is String) { out.append(k) }
        for k in ["errors"] where !(json[k] is [Any]) { out.append(k) }
        for k in ["scenario", "rating", "context", "config", "app"] where !(json[k] is [String: Any]) { out.append(k) }
        if (json["errors"] as? [String] ?? []).contains(where: { !LabCase.errorTags.contains($0) }) {
            out.append("errors: unknown tag")
        }
        if let s = (json["rating"] as? [String: Any])?["stars"], !(s is NSNull), !((s as? Int).map { (1...5).contains($0) } ?? false) {
            out.append("rating.stars")
        }
        if !contextIncluded, ["before", "after", "selection", "title"].contains(where: { context[$0]?.isEmpty == false }) {
            out.append("context: text kept without consent")
        }
        return out
    }
}

// MARK: - the store

public final class LabStore {
    public static let shared = LabStore()
    private let fixedDir: URL?
    public init(dir: URL? = nil) { fixedDir = dir }

    public var dir: URL { fixedDir ?? BlurtPaths.home.appendingPathComponent("dictation/lab/cases") }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    public static func newID(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: d) + "-" + String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(4))
    }

    static func safe(_ id: String) -> Bool {
        !id.isEmpty && !id.hasPrefix(".") && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }
    }

    public func folder(_ id: String) -> URL { dir.appendingPathComponent(id, isDirectory: true) }
    public func audioURL(_ c: LabCase) -> URL? {
        guard let a = c.json["audio"] as? String, !a.isEmpty else { return nil }
        let u = folder(c.id).appendingPathComponent(a)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Newest first.
    public func list() -> [LabCase] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return ids.compactMap(load).sorted { ($0.json["created"] as? String ?? "") > ($1.json["created"] as? String ?? "") }
    }

    public func load(_ id: String) -> LabCase? {
        guard LabStore.safe(id), let d = try? Data(contentsOf: folder(id).appendingPathComponent("case.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return LabCase(json: o)
    }

    /// Writes case.json (keys already in the file that this case doesn't carry are kept).
    @discardableResult
    public func save(_ c: LabCase) -> Bool {
        guard LabStore.safe(c.id) else { return false }
        let d = folder(c.id)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var o = (load(c.id)?.json) ?? [:]
        for (k, v) in c.json { o[k] = v }
        o["updated"] = LabStore.iso.string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? data.write(to: d.appendingPathComponent("case.json"), options: .atomic)) != nil
    }

    /// Moves the audio file in as audio.wav (it must already be 16 kHz mono).
    public func adoptAudio(_ wav: URL, into c: inout LabCase) {
        let d = folder(c.id)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let dst = d.appendingPathComponent("audio.wav")
        try? FileManager.default.removeItem(at: dst)
        if (try? FileManager.default.copyItem(at: wav, to: dst)) != nil { c.json["audio"] = "audio.wav" }
    }

    public func delete(_ id: String) {
        guard LabStore.safe(id) else { return }
        try? FileManager.default.removeItem(at: folder(id))
    }

    /// runs.jsonl: every re-run of this case (the regression runner's history).
    public func runs(_ id: String) -> [[String: Any]] {
        guard LabStore.safe(id), let d = try? Data(contentsOf: folder(id).appendingPathComponent("runs.jsonl")) else { return [] }
        return d.split(separator: 0x0A).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }
}

// MARK: - what learning changed (Undo)

public enum LabVocab {
    /// One term's change: nil before = it was added, nil after = it was removed.
    public struct Change {
        public let term: String
        public let before: [String: Any]?
        public let after: [String: Any]?
        public init(term: String, before: [String: Any]?, after: [String: Any]?) { self.term = term; self.before = before; self.after = after }

        public init?(json o: [String: Any]) {
            guard let t = o["term"] as? String else { return nil }
            term = t; before = o["before"] as? [String: Any]; after = o["after"] as? [String: Any]
        }

        /// "Claude Code (cloud code)", or the new sounds-likes of a known word
        public var summary: String {
            let was = Set(before?["sounds_like"] as? [String] ?? []), now = after?["sounds_like"] as? [String] ?? []
            let added = now.filter { !was.contains($0) }
            return added.isEmpty ? term : "\(term) ← \(added.joined(separator: ", "))"
        }
    }

    static func same(_ a: [String: Any]?, _ b: [String: Any]?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return NSDictionary(dictionary: x).isEqual(to: y)
        default: return false
        }
    }

    /// term → its JSON object, from the vocabulary file.
    public static func snapshot(_ url: URL) -> [String: [String: Any]] {
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        var out: [String: [String: Any]] = [:]
        for t in o["terms"] as? [[String: Any]] ?? [] { if let k = t["term"] as? String { out[k] = t } }
        return out
    }

    public static func changes(before: [String: [String: Any]], after: [String: [String: Any]]) -> [Change] {
        var out: [Change] = []
        for k in after.keys.sorted() where !same(before[k], after[k]) { out.append(Change(term: k, before: before[k], after: after[k])) }
        for k in before.keys.sorted() where after[k] == nil { out.append(Change(term: k, before: before[k], after: nil)) }
        return out
    }

    /// Undo: each changed term goes back to how it was — only while it still is as the learning left it (a later edit
    /// by the user wins). Returns the terms put back.
    @discardableResult
    public static func revert(_ changes: [Change], in vocabulary: DictationVocabulary) -> [String] {
        var done: [String] = []
        vocabulary.editRaw { terms in
            for c in changes {
                let i = terms.firstIndex { $0["term"] as? String == c.term }
                let now = i.map { terms[$0] }
                guard same(now, c.after) else { continue }
                if let b = c.before { if let i = i { terms[i] = b } else { terms.append(b) } } else if let i = i { terms.remove(at: i) }
                done.append(c.term)
            }
        }
        return done
    }
}
