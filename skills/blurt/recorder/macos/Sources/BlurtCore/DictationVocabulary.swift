// Dictation's custom words (docs/design/dictation.md §Custom words): $BLURT_HOME/dictation/vocabulary.json. The app
// owns the file (the Dictation page's Words tab adds and removes, the learner suggests, the seed adds the obvious
// ones); scripts/dictation_vocab.py reads it. The words are hints to the models — the speech model's context / prompt /
// hotwords and polish's word list — never rules: nothing replaces one string with another.
//
//   {"schema": 2, "terms": [{"term", "sounds_like": [...], "source": manual|learned|project|default,
//                            "state": active|suggested|rejected|removed, "added", "hits", "seen"}]}
//
//   sounds_like what a speech model wrote instead (learned from the user's fixes): it only says when a word is
//               relevant (dictation_vocab.ranked / relevant), so it is one the models are told about
//   active      used (the models get it)
//   suggested   learned once from a fix (the after-typing watch, or a saved correction); accepted by the user, or by
//               itself the second time the same fix is seen. A term never has sentence punctuation in it.
//   rejected    a learned word the user turned down: never suggested again
//   removed     a seeded word the user removed: never seeded again
//
// Schema 2 (`migrate`, run once by `seed`): the seed is a short list of product names; a word of the older, longer seed
// the user never touched goes (people's names among them; one they used or corrected stays as theirs), and the
// sounds-likes the old seed shipped are dropped.
import Foundation

public struct VocabTerm: Equatable, Identifiable, Hashable {
    /// manual (the user's own), learned (from a fix), project (the projects' names and keys), default (built in: the
    /// product names nearly every user says, `DictationVocabulary.builtIn`) — both seeds, removable
    public enum Source: String { case manual, learned, project, builtIn = "default" }
    public enum State: String { case active, suggested, rejected, removed }

    public var term: String
    public var soundsLike: [String]
    public var source: Source
    public var state: State
    public var added: Date
    public var hits: Int
    /// learned: how many times the user made this fix
    public var seen: Int
    public var id: String { term }

    public init(term: String, soundsLike: [String] = [], source: Source = .manual, state: State = .active,
                added: Date = Date(), hits: Int = 0, seen: Int = 0) {
        self.term = term; self.soundsLike = soundsLike; self.source = source; self.state = state
        self.added = added; self.hits = hits; self.seen = seen
    }

    var json: [String: Any] {
        ["term": term, "sounds_like": soundsLike, "source": source.rawValue, "state": state.rawValue,
         "added": DictationEntry.iso.string(from: added), "hits": hits, "seen": seen]
    }

    init?(json o: [String: Any]) {
        guard let t = (o["term"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        term = t
        soundsLike = (o["sounds_like"] as? [String]) ?? []
        source = Source(rawValue: o["source"] as? String ?? "") ?? .manual
        state = State(rawValue: o["state"] as? String ?? "") ?? .active
        added = (o["added"] as? String).flatMap { DictationEntry.iso.date(from: $0) } ?? Date(timeIntervalSince1970: 0)
        hits = o["hits"] as? Int ?? 0
        seen = o["seen"] as? Int ?? 0
    }
}

public final class DictationVocabulary {
    public static let shared = DictationVocabulary()
    public static var defaultURL: URL { BlurtPaths.home.appendingPathComponent("dictation/vocabulary.json") }

    private let fixedURL: URL?
    private let lock = NSLock()
    public init(url: URL? = nil) { fixedURL = url }
    public var url: URL { fixedURL ?? DictationVocabulary.defaultURL }

    /// The built-in words (source `default`): the agents, editors, AI labs and models this app's users dictate about
    /// all day, and the app's own name. Short on purpose — no people, no sounds-likes: the speech model is told the
    /// names (docs/design/dictation.md §Custom words). Removable: a removed one is never seeded again.
    public static let builtIn: [String] = [
        "Claude Code", "Claude", "Codex", "Cursor", "Typeless", "MCP", "GitHub", "worktree", "tmux",
        "OpenAI", "Anthropic", "ChatGPT", "DeepSeek", "Qwen", "Gemini", "Kimi", "Ollama", "blurt", "口喷鸡",
    ]

    /// The file format this code writes; an older file is migrated once by `seed`.
    public static let schema = 2

    /// What the schema-1 seed added that `builtIn` no longer has, and the sounds-likes it shipped. Migration data
    /// only: an untouched retired word goes, a shipped sounds-like is dropped.
    static let retiredSeed: Set<String> = [
        "GPT", "Grok", "xAI", "Llama", "Gemma", "Mistral", "Hugging Face", "Perplexity", "Copilot", "Windsurf",
        "Midjourney", "Sora", "MiniMax", "Nvidia", "Wispr Flow", "OpenClaw", "PR", "Sam Altman", "Dario", "Musk",
    ]
    static let retiredSoundsLikes: [String: [String]] = [
        "Claude Code": ["cloud code", "clock code", "claude co"], "Codex": ["codec", "codecs", "kodex"],
        "blurt": ["blurred", "blurr"], "口喷鸡": ["口喷机", "口碰鸡"], "ChatGPT": ["chat gpt"],
        "Typeless": ["type less", "TypePlus"], "OpenClaw": ["open claw"], "tmux": ["t mux"], "GitHub": ["git hub"],
        "worktree": ["work tree"],
    ]

    // MARK: reading

    public func load() -> [VocabTerm] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    private func read() -> [VocabTerm] { readFile().terms }

    /// The file's schema (nil: no file yet) and its terms.
    private func readFile() -> (schema: Int?, terms: [VocabTerm]) {
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return (nil, []) }
        return (o["schema"] as? Int ?? 1, (o["terms"] as? [[String: Any]] ?? []).compactMap(VocabTerm.init(json:)))
    }

    private func write(_ terms: [VocabTerm], schema: Int) {
        let o: [String: Any] = ["schema": schema, "terms": terms.map(\.json)]
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }

    /// Read, change, write — under the lock. Returns what `change` returned. A new file is written in this schema; an
    /// older one keeps its own until `seed` migrates it.
    @discardableResult
    private func edit<T>(_ change: (inout [VocabTerm]) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        let file = readFile()
        var all = file.terms
        let r = change(&all)
        if all != file.terms { write(all, schema: file.schema ?? DictationVocabulary.schema) }
        return r
    }

    /// The file's terms as JSON objects, changed under the lock (the Dictation Lab's Undo of what a correction taught:
    /// every key of a term is kept, also ones this app doesn't know).
    public func editRaw(_ change: (inout [[String: Any]]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        let o = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var terms = o["terms"] as? [[String: Any]] ?? []
        change(&terms)
        var out = o
        out["schema"] = o["schema"] ?? DictationVocabulary.schema
        out["terms"] = terms
        guard let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }

    /// The words in use (what ASR and polish get), most used first.
    public func active() -> [VocabTerm] { load().filter { $0.state == .active }.sorted { $0.hits > $1.hits } }
    /// Learned once, waiting for the user (or a second sighting).
    public func suggestions() -> [VocabTerm] { load().filter { $0.state == .suggested } }
    /// The active words the user sees as theirs (added, learned, their projects'), in the file's order.
    public func userWords() -> [VocabTerm] { load().filter { $0.state == .active && $0.source != .builtIn } }
    /// The active built-in words (the Words tab shows them on one folded line).
    public func builtInWords() -> [VocabTerm] { load().filter { $0.state == .active && $0.source == .builtIn } }

    /// What a request to the speech / polish server carries: [{"term","sounds_like"}].
    public func payload() -> [[String: Any]] { active().map { ["term": $0.term, "sounds_like": $0.soundsLike] } }

    static func key(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-_.·"))).joined()
    }

    private static func index(_ all: [VocabTerm], _ term: String) -> Int? {
        all.firstIndex { $0.term == term } ?? all.firstIndex { key($0.term) == key(term) && $0.term.lowercased() == term.lowercased() }
    }

    // MARK: the user's edits (the Words tab)

    /// Adds (or brings back) a word. false = empty, or already there and active.
    @discardableResult
    public func add(_ term: String, soundsLike: [String] = [], source: VocabTerm.Source = .manual) -> Bool {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return edit { all in
            if let i = DictationVocabulary.index(all, t) {
                if all[i].state == .active && soundsLike.allSatisfy(all[i].soundsLike.contains) { return false }
                all[i].term = t
                all[i].state = .active
                if source == .manual { all[i].source = .manual }
                for s in soundsLike where !all[i].soundsLike.contains(s) && s != t { all[i].soundsLike.append(s) }
                return true
            }
            all.append(VocabTerm(term: t, soundsLike: soundsLike.filter { $0 != t }, source: source))
            return true
        }
    }

    /// Removes a word: a manual one goes; a seeded one is remembered as removed (never seeded again); a learned one as
    /// rejected (never suggested again).
    public func remove(_ term: String) {
        edit { all in
            guard let i = DictationVocabulary.index(all, term) else { return }
            switch all[i].source {
            case .manual: all.remove(at: i)
            case .project, .builtIn: all[i].state = .removed
            case .learned: all[i].state = .rejected
            }
        }
    }

    public func accept(_ term: String) {
        edit { all in if let i = DictationVocabulary.index(all, term) { all[i].state = .active } }
    }

    public func reject(_ term: String) {
        edit { all in if let i = DictationVocabulary.index(all, term) { all[i].state = .rejected } }
    }

    /// The words the Words tab's add field holds: one per comma, 、, semicolon or line ("Claude, Codex、tmux" → three),
    /// trimmed, each once. (The user's own list punctuation — this reads input, not speech.)
    public static func entries(_ s: String) -> [String] {
        var out: [String] = []
        for p in s.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n")) {
            let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !out.contains(t) { out.append(t) }
        }
        return out
    }

    /// The word is already in use (the add field says so instead of adding it twice).
    public func isActive(_ term: String) -> Bool {
        let all = load()
        return DictationVocabulary.index(all, term.trimmingCharacters(in: .whitespacesAndNewlines)).map { all[$0].state == .active } ?? false
    }

    /// Puts a word back exactly as it was (the Words tab's Undo of a remove, an accept, an ignore, a rename).
    public func restore(_ t: VocabTerm) {
        edit { all in
            if let i = all.firstIndex(where: { $0.term == t.term }) { all[i] = t } else { all.append(t) }
        }
    }

    /// A word spelled differently (the Words tab's double-click): its history stays, under the new spelling. false: empty,
    /// unknown, or the new spelling is already another word.
    @discardableResult
    public func rename(_ term: String, to new: String) -> Bool {
        let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != term, !DictationVocabulary.hasSentencePunctuation(n) else { return false }
        return edit { all in
            guard let i = all.firstIndex(where: { $0.term == term }), !all.contains(where: { $0.term == n }) else { return false }
            all[i].term = n
            all[i].soundsLike.removeAll { $0 == n }
            return true
        }
    }

    /// The island's "Undo" right after a word was learned: as if it never happened (a later fix may learn it again).
    public func forget(_ term: String) {
        edit { all in if let i = DictationVocabulary.index(all, term), all[i].source == .learned { all.remove(at: i) } }
    }

    /// A dictation used these words (history and ranking).
    public func recordHits(_ terms: [String]) {
        guard !terms.isEmpty else { return }
        edit { all in for t in terms { if let i = DictationVocabulary.index(all, t) { all[i].hits += 1 } } }
    }

    // MARK: the seed

    /// Adds the obvious words once: each project's name and key (source `project`; at most three words), then the
    /// built-in ones (source `default`). A word the user removed stays removed; nothing already there is touched. An
    /// older file is migrated first. Returns the words added.
    @discardableResult
    public func seed(projects: [(name: String, key: String)]) -> [String] {
        var want: [(term: String, source: VocabTerm.Source)] = []
        for p in projects {
            for t in [p.name, p.key] where DictationVocabulary.seedable(project: t) { want.append((t, .project)) }
        }
        want += DictationVocabulary.builtIn.map { (term: $0, source: VocabTerm.Source.builtIn) }
        lock.lock(); defer { lock.unlock() }
        let file = readFile()
        var all = file.terms
        if let s = file.schema, s < DictationVocabulary.schema { DictationVocabulary.migrate(&all) }
        var added: [String] = []
        for (t, source) in want where DictationVocabulary.index(all, t) == nil && !added.contains(t) {
            all.append(VocabTerm(term: t, source: source))
            added.append(t)
        }
        if all != file.terms || file.schema != DictationVocabulary.schema { write(all, schema: DictationVocabulary.schema) }
        return added
    }

    /// A project's name or key worth seeding: 2–40 characters, at most three words, and at most 12 CJK characters
    /// (Chinese doesn't space its words, so a long name is a sentence, not a term).
    static func seedable(project t: String) -> Bool {
        let words = t.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        let cjk = t.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }.count
        return t.count >= 2 && t.count <= 40 && !words.isEmpty && words.count <= 3 && cjk <= 12
    }

    /// Schema 1 → 2: the old built-in words (source `project` then) become `default`; the sounds-likes the old seed
    /// shipped go (the ones learned from the user's fixes stay). A retired seed (still source `default`) and a project
    /// name too long to seed now go when the user never touched them; one the user did touch — used it, or taught it
    /// a sounds-like by a correction — stays as their own word (`learned`, with its hints and hits).
    static func migrate(_ all: inout [VocabTerm]) {
        for i in all.indices {
            if all[i].source == .project && builtIn.contains(all[i].term) { all[i].source = .builtIn }
            if let old = retiredSoundsLikes[all[i].term] { all[i].soundsLike.removeAll { old.contains($0) } }
        }
        all = all.compactMap { t in
            let retired = (t.source == .builtIn && retiredSeed.contains(t.term)) || (t.source == .project && !seedable(project: t.term))
            guard retired else { return t }
            guard t.state == .active, t.hits > 0 || !t.soundsLike.isEmpty else { return nil }
            var kept = t
            kept.source = .learned
            return kept
        }
    }

    // MARK: learning (DictationLearn decides what a fix is)

    public enum Learned: Equatable {
        /// a new word, in use now: the island says "Learned …" once
        case learned(String)
        /// a new suggestion (the Words tab shows it), or one seen again but not yet accepted
        case suggested(String)
        /// already a word: its sounds-like list grew or it was used
        case known(String)
    }

    /// The user saved a corrected version of a dictation (the Dictation page's "Save correction"): every recognition
    /// fix in it (DictationLearn.fixes — small spans that sound or look alike, never a rewrite, never two fixes run
    /// together) is offered. A new word is a suggestion that the page's note adds with one click (and takes back); a
    /// word already on the list gains what was heard. This is how a name gets learned where the after-typing watch
    /// can't see the field (WeChat). It learns words, never replacements. `activate`: in use at once. The same rules
    /// as `dictation_vocab.py learn`.
    @discardableResult
    public func learnCorrection(typed: String, corrected: String, activate: Bool = false,
                                isCommonWord: (String) -> Bool = DictationLearn.isCommonWord) -> [(fix: DictationLearn.Fix, result: Learned?)] {
        DictationLearn.fixes(typed: typed, edited: corrected, isCommonWord: isCommonWord).map {
            ($0, learn(heard: $0.heard, fixed: $0.fixed, explicit: activate))
        }
    }

    /// Sentence or clause punctuation (，。、；：！？ and their ASCII kin): a term never has it — it would be two words
    /// run together ("会话，BA-3"). Hyphens, apostrophes and dots inside a name (BA-3, don't, Node.js) are fine.
    public static func hasSentencePunctuation(_ s: String) -> Bool {
        s.contains { "，。、；：！？,;:!?…".contains($0) }
    }

    /// The user changed `heard` into `fixed` in a dictation. A known word gets `heard` as a sounds-like (a hint that the
    /// word is relevant when it is heard; nothing rewrites it); a new one is a suggestion, used at once when the fix is
    /// only case or spacing ("claude" → "Claude") or the second time the same fix is seen. `explicit`: the user saved
    /// this correction themselves (the Dictation page, the lab) — a new word is used at once. nil = nothing to learn
    /// (a word the user rejected or removed). scripts/dictation_vocab.py `learn` is the same rules for tools outside
    /// the app.
    public func learn(heard: String, fixed: String, explicit: Bool = false) -> Learned? {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines), f = fixed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !f.isEmpty, h != f, !DictationVocabulary.hasSentencePunctuation(f) else { return nil }
        let spelling = DictationVocabulary.key(h) == DictationVocabulary.key(f)
        return edit { all -> Learned? in
            if let i = all.firstIndex(where: { $0.term == f }) {
                switch all[i].state {
                case .rejected, .removed: return nil
                case .active:
                    if !spelling && !all[i].soundsLike.contains(h) { all[i].soundsLike.append(h) }
                    all[i].hits += 1
                    return .known(f)
                case .suggested:
                    all[i].seen += 1
                    if !spelling && !all[i].soundsLike.contains(h) { all[i].soundsLike.append(h) }
                    if all[i].seen >= 2 || explicit { all[i].state = .active; return .learned(f) }
                    return .suggested(f)
                }
            }
            let active = spelling || explicit
            all.append(VocabTerm(term: f, soundsLike: spelling ? [] : [h], source: .learned,
                                 state: active ? .active : .suggested, seen: 1))
            return active ? .learned(f) : .suggested(f)
        }
    }
}
