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
//   unreadable    a list that couldn't be read leaves no set (Try Again), never a set without that model.
//   mirror        the China-friendly mirrors first when Settings → Speech says so, or, never set, when the region is
//                 CN — one answer for every download.
//   progress      the scripts print "  N/M MB" on stderr; a part's share is N/M of its registry size, so the bar
//                 moves evenly over parts whose own totals differ from the registry's. A file fetched on the way (the
//                 VAD) prints a named line ("  vad 1.7/1.7 MB") that doesn't parse, and acceptProgress keeps only
//                 lines about the model itself, never moving back.
import Foundation

public enum ModelBundle {
    public enum Kind: String, Equatable, Codable { case dictation, polish, note, screenText = "screen_text" }

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

    /// The recommended set: dictation, polish (where it runs), voice notes — a model already in the set once. nil when
    /// a list couldn't be read (a script failed or timed out): the step says so and offers Try Again, rather than
    /// quietly leaving that model out. `polishRuns` nil = `polish.py models` couldn't be read; false = no polish here.
    public static func plan(dictation: Part?, polish: Part?, polishRuns: Bool?, note: Part?) -> [Part]? {
        guard let dictation = dictation, let note = note, let runs = polishRuns else { return nil }
        if runs && polish == nil { return nil }
        var out: [Part] = []
        for p in [dictation, runs ? polish : nil, note].compactMap({ $0 }) where !out.contains(where: { $0.id == p.id }) { out.append(p) }
        return out
    }

    /// Downloads from the China-friendly mirrors first (BLURT_HF_MIRROR=1): Settings → Speech's choice, else — never
    /// set — a CN region or a mainland-China time zone (v1.0.6: someone in China with an English / US system still
    /// can't reach Hugging Face). Every download (the assistant, Settings → Dictation and → Speech) asks this, so they
    /// agree with the checkbox; a download that fails on one source tries the other.
    public static func mirror(setting: Bool?, region: String?, timeZone: String? = nil) -> Bool {
        setting ?? (region == "CN" || timeZone.map(chinaTimeZones.contains) == true)
    }

    /// The mainland's zones (not Hong Kong, Macau or Taipei: Hugging Face is reachable there).
    static let chinaTimeZones: Set<String> = ["Asia/Shanghai", "Asia/Chongqing", "Asia/Chungking", "Asia/Harbin",
                                              "Asia/Urumqi", "Asia/Kashgar", "PRC"]

    /// `mirror(setting:region:timeZone:)` for this Mac (config asr.hf_mirror, the locale's region, the time zone).
    public static var mirror: Bool {
        mirror(setting: Config.shared["asr.hf_mirror"] as? Bool, region: Locale.current.region?.identifier,
               timeZone: TimeZone.current.identifier)
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

    /// A model's size the same way on every surface (the assistant, Settings, the menu, the toasts): decimal units like
    /// Finder, whole MB below 1 GB, one decimal above — "228 MB", "2.5 GB", "6.1 GB".
    public static func size(_ mb: Double, locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        if mb.rounded() < 1000 {
            f.maximumFractionDigits = 0
            return (f.string(from: max(0, mb).rounded() as NSNumber) ?? "\(Int(mb))") + " MB"
        }
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return (f.string(from: (mb / 1000) as NSNumber) ?? "\(mb / 1000)") + " GB"
    }

    /// A parsed line for the running job (`sizeMB`: its registry size), or nil to ignore it. Only a line about the
    /// model itself counts — its total within half again of the job's size (a small file fetched on the way, the VAD's
    /// "1.7/1.7 MB", once leapt the bar to 2.5 of 6.1 GB and back) — and the bar never moves back within one job
    /// (`previous`: the line it shows now).
    public static func acceptProgress(_ line: (done: Double, total: Double), sizeMB: Double,
                                      previous: (done: Double, total: Double)?) -> (done: Double, total: Double)? {
        guard line.total > 0, sizeMB > 0, line.total >= sizeMB * 0.5, line.total <= sizeMB * 1.5 else { return nil }
        if let p = previous, p.total > 0, line.done / line.total < p.done / p.total { return nil }
        return line
    }

    /// A download's progress line ("  812/2468 MB", "  812.4/2468.0 MB") → (812, 2468); anything else nil — a line
    /// that names what it fetches on the way ("  vad 1.7/1.7 MB") too.
    public static func parseProgress(_ line: String) -> (done: Double, total: Double)? {
        let w = line.split(separator: " ")
        guard w.count >= 2, w[1] == "MB" else { return nil }
        let q = w[0].split(separator: "/")
        guard q.count == 2, let a = Double(q[0]), let b = Double(q[1]), b > 0 else { return nil }
        return (a, b)
    }
}
