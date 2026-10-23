// Dictation's custom words (docs/design/dictation.md §Custom words): $BLURT_HOME/dictation/vocabulary.json. The app
// owns the file (Settings → Dictation adds and removes, the learner suggests, the seed adds the obvious ones);
// scripts/dictation_vocab.py reads it for the speech model's biasing, the deterministic pass and polish.
//
//   {"schema": 1, "terms": [{"term", "sounds_like": [...], "source": manual|learned|project,
//                            "state": active|suggested|rejected|removed, "added", "hits", "seen"}]}
//
//   active      used (ASR biasing, polish, exact sounds-like replacement)
//   suggested   learned once from a fix; accepted by the user, or by itself the second time the same fix is seen
//   rejected    a learned word the user turned down: never suggested again
//   removed     a seeded word the user removed: never seeded again
import Foundation

public struct VocabTerm: Equatable, Identifiable, Hashable {
    public enum Source: String { case manual, learned, project }
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

    /// The seed: what every Blurt user obviously says (the agents, the app's own name), with what speech models
    /// write instead (docs/design/dictation.md §Recognition model, the misses table). Projects are added on top.
    public static let builtIn: [(String, [String])] = [
        ("Claude Code", ["cloud code", "clock code", "claude co"]),
        ("Codex", ["codec", "codecs", "kodex"]),
        ("blurt", ["blurred", "blurr"]),
        ("口喷鸡", ["口喷机", "口碰鸡"]),
    ]

    // MARK: reading

    public func load() -> [VocabTerm] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    private func read() -> [VocabTerm] {
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return (o["terms"] as? [[String: Any]] ?? []).compactMap(VocabTerm.init(json:))
    }

    private func write(_ terms: [VocabTerm]) {
        let o: [String: Any] = ["schema": 1, "terms": terms.map(\.json)]
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }

    /// Read, change, write — under the lock. Returns what `change` returned.
    @discardableResult
    private func edit<T>(_ change: (inout [VocabTerm]) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        var all = read()
        let before = all
        let r = change(&all)
        if all != before { write(all) }
        return r
    }

    /// The words in use (what ASR and polish get), most used first.
    public func active() -> [VocabTerm] { load().filter { $0.state == .active }.sorted { $0.hits > $1.hits } }
    /// Learned once, waiting for the user (or a second sighting).
    public func suggestions() -> [VocabTerm] { load().filter { $0.state == .suggested } }

    /// What a request to the speech / polish server carries: [{"term","sounds_like"}].
    public func payload() -> [[String: Any]] { active().map { ["term": $0.term, "sounds_like": $0.soundsLike] } }

    static func key(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-_.·"))).joined()
    }

    private static func index(_ all: [VocabTerm], _ term: String) -> Int? {
        all.firstIndex { $0.term == term } ?? all.firstIndex { key($0.term) == key(term) && $0.term.lowercased() == term.lowercased() }
    }

    // MARK: the user's edits (Settings)

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
            case .project: all[i].state = .removed
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

    /// Adds the obvious words once, as source `project`: the built-in ones and each project's name and key. A word
    /// the user removed stays removed; nothing already there is touched. Returns the words added.
    @discardableResult
    public func seed(projects: [(name: String, key: String)]) -> [String] {
        var want = DictationVocabulary.builtIn.map { (term: $0.0, sounds: $0.1) }
        for p in projects {
            for t in [p.name, p.key] where t.count >= 2 && t.count <= 40 { want.append((t, [])) }
        }
        return edit { all in
            var added: [String] = []
            for (t, sounds) in want where DictationVocabulary.index(all, t) == nil && !added.contains(t) {
                all.append(VocabTerm(term: t, soundsLike: sounds, source: .project))
                added.append(t)
            }
            return added
        }
    }

    // MARK: learning (DictationLearn decides what a fix is)

    public enum Learned: Equatable {
        /// a new word, in use now: the island says "Learned …" once
        case learned(String)
        /// a new suggestion (Settings shows it), or one seen again but not yet accepted
        case suggested(String)
        /// already a word: its sounds-like list grew or it was used
        case known(String)
    }

    /// The user changed `heard` into `fixed` in a dictation. A known word gets `heard` as a sounds-like; a new one is a
    /// suggestion, used at once when the fix is only case or spacing ("claude" → "Claude") or the second time the same
    /// fix is seen. nil = nothing to learn (a word the user rejected or removed).
    public func learn(heard: String, fixed: String) -> Learned? {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines), f = fixed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !f.isEmpty, h != f else { return nil }
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
                    if all[i].seen >= 2 { all[i].state = .active; return .learned(f) }
                    return .suggested(f)
                }
            }
            all.append(VocabTerm(term: f, soundsLike: spelling ? [] : [h], source: .learned,
                                 state: spelling ? .active : .suggested, seen: 1))
            return spelling ? .learned(f) : .suggested(f)
        }
    }
}
