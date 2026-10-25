// Which project a capture goes to (K2, v0.9): the user's call, made cheap — never Blurt's guess.
//
//   • a current project the user set → every capture goes there; none → Unassigned. Nothing looks at the app in
//     front, and nothing moves an item on its own.
//   • organizing an Unassigned capture, the run is told the projects (OrganizerPrompt: `projects.py candidates` —
//     name, description, folder, the newest few titles; no extra model call, no stored profile, nothing learnt) and
//     may leave a suggestion per item (suggested_project). The user accepts one with a click ("Looks like X · Move"),
//     a group of them at once ("Move All (3)"), each undoable.
//   • picking a project anywhere — the island's switcher (⌥⇧O), the main window's Move popover (M), the command
//     palette — filters the same way as you type (ProjectPick).
import Foundation

/// Type-to-filter over projects, best first.
public enum ProjectPick {
    /// The entries matching `query`, best first: the key typed exactly, then names starting with it, then a word of
    /// the name starting with it, then the key starting with it, then the name containing it anywhere (case and
    /// accents ignored). Ties keep the order given (recently used first). Empty query: all, as given.
    public static func filter<T>(_ items: [T], _ query: String, name: (T) -> String, key: (T) -> String) -> [T] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return items }
        var ranked: [(Int, Int, T)] = []
        for (i, it) in items.enumerated() {
            let n = fold(name(it)), k = fold(key(it))
            let words = n.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let rank: Int?
            if k == q { rank = 0 }
            else if n.hasPrefix(q) { rank = 1 }
            else if words.contains(where: { $0.hasPrefix(q) }) { rank = 2 }
            else if k.hasPrefix(q) { rank = 3 }
            else if n.contains(q) { rank = 4 }
            else { rank = nil }
            if let r = rank { ranked.append((r, i, it)) }
        }
        return ranked.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    public static func filter(_ projects: [Project], _ query: String) -> [Project] {
        filter(projects, query, name: \.name, key: \.key)
    }

    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }
}

/// Unassigned items grouped by the project an organizing run suggested for them (the list's "Move All (3)").
public struct SuggestionGroup: Equatable {
    public let project: String
    public let uids: [String]
    public init(project: String, uids: [String]) { self.project = project; self.uids = uids }
}

public enum Suggestions {
    /// (uid, suggested project) of live Unassigned items → one group per project that is still registered (`known`),
    /// in the order `order` lists the projects, uids in the order given. The main window passes them by name — the
    /// order IndexReader's bySuggestion puts the rows below in, so the banner and the list agree.
    public static func groups(_ rows: [(uid: String, project: String)], known order: [String]) -> [SuggestionGroup] {
        var by: [String: [String]] = [:]
        for r in rows { by[r.project, default: []].append(r.uid) }
        return order.compactMap { p in by[p].map { SuggestionGroup(project: p, uids: $0) } }
    }
}

/// "Filed to X · Change" on a recording that is still being organized (Refile.swift): where the user wants it now,
/// and every place it was filed to before — the run may write its items to any of them (it read meta.json once).
/// When the run is over, the items still in one of `before` move to `to`; the user's own moves since stay.
public struct RefileTrail: Equatable {
    public private(set) var to: String
    public private(set) var before: [String]
    public init(to: String) { self.to = to; before = [] }

    /// Changed again, from `from` to `to`.
    public mutating func refiled(to new: String, from: String) {
        if from != new, !before.contains(from) { before.append(from) }
        before.removeAll { $0 == new }
        to = new
    }

    /// The places to move items from when the run ends (none: it ended up where it started, nothing to do).
    public var movesFrom: [String] { before.filter { $0 != to } }
}

/// What an organizing run is told about the projects.
public enum OrganizerPrompt {
    /// Only for a capture with no project: the run itself has none (no "Organize into X"), and its session is in the
    /// inbox store (`sessionProject` "inbox" or unknown). With a project, the items go there — no suggestions.
    public static func wantsCandidates(runProject: String?, sessionProject: String?) -> Bool {
        runProject == nil && (sessionProject == nil || sessionProject == "inbox")
    }

    /// The prompt with the candidates' text (`projects.py candidates` → "text") after it; unchanged without any.
    public static func with(_ prompt: String, candidates: String?) -> String {
        guard let c = candidates?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty else { return prompt }
        return prompt + "\n\n" + c
    }
}
