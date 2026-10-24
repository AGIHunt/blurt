// The setup assistant's "Download recommended models" (docs/design/desktop-app.md §2.2), its pure parts: which models
// make up this Mac's recommended set, how big what is still missing is, and one progress bar over the downloads that
// run one after another. Unit-tested in Tests/BlurtCoreTests/ModelBundleTests.
//
//   the set       dictation's recogniser (`transcribe.py dictation-models` recommended: Qwen3-ASR on Apple Silicon
//                 pro / standard, else the voice-note model), the polish model (`polish.py models` recommended, only
//                 where polish runs) and the voice-note model (`transcribe.py models` recommended note) — each once,
//                 in that order (dictation first: it is what the user tries next).
//   fallback      SenseVoice Small (228 MB): the voice-note model, and what dictation falls back to — offered alone
//                 when the full set didn't download (offline, a slow network).
//   progress      the scripts print "  N/M MB" on stderr; a part's share is N/M of its registry size, so the bar
//                 moves evenly over parts whose own totals differ from the registry's.
import Foundation

public enum ModelBundle {
    public enum Kind: String, Equatable { case dictation, polish, note }

    public struct Part: Equatable {
        public var id: String
        public var kind: Kind
        public var name: String
        public var sizeMB: Double
        public var installed: Bool
        public init(id: String, kind: Kind, name: String, sizeMB: Double, installed: Bool) {
            self.id = id; self.kind = kind; self.name = name; self.sizeMB = sizeMB; self.installed = installed
        }
    }

    /// The voice-note model, and dictation's fallback.
    public static let fallbackID = "sensevoice-small"

    /// The recommended set: dictation, polish, voice notes — nil ones left out, a model already in the set once.
    public static func plan(dictation: Part?, polish: Part?, note: Part?) -> [Part] {
        var out: [Part] = []
        for p in [dictation, polish, note].compactMap({ $0 }) where !out.contains(where: { $0.id == p.id }) { out.append(p) }
        return out
    }

    /// What still has to be downloaded, in order.
    public static func pending(_ parts: [Part]) -> [Part] { parts.filter { !$0.installed } }

    /// The size of what still has to be downloaded.
    public static func totalMB(_ parts: [Part]) -> Double { pending(parts).reduce(0) { $0 + $1.sizeMB } }

    /// One bar over `parts` (the ones being downloaded): the finished ones whole, the current one by its N/M.
    public static func progress(_ parts: [Part], finished: Set<String>, current: String?, line: (done: Double, total: Double)?)
        -> (done: Double, total: Double) {
        let total = parts.reduce(0) { $0 + $1.sizeMB }
        var done = parts.filter { finished.contains($0.id) }.reduce(0) { $0 + $1.sizeMB }
        if let c = current, !finished.contains(c), let p = parts.first(where: { $0.id == c }), let l = line, l.total > 0 {
            done += p.sizeMB * min(max(l.done / l.total, 0), 1)
        }
        return (min(done, total), total)
    }

    /// A download's progress line ("  812/2468 MB") → (812, 2468); anything else nil.
    public static func parseProgress(_ line: String) -> (done: Double, total: Double)? {
        let w = line.split(separator: " ")
        guard w.count >= 2, w[1] == "MB" else { return nil }
        let q = w[0].split(separator: "/")
        guard q.count == 2, let a = Double(q[0]), let b = Double(q[1]), b > 0 else { return nil }
        return (a, b)
    }
}
