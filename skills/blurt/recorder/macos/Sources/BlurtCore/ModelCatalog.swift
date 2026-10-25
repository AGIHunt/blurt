// The models' names for people, read straight from the skill's own catalogs (scripts/asr_models.json,
// polish_models.json: {"models": [{"id", "name"}]}) — so a model's id ("qwen3-asr-1.7b-mlx") never shows where its name
// belongs, also before `transcribe.py dictation-models` has answered, when it failed, or for a model no longer listed
// there (v0.9 raw-identifier audit #12). Pure: ModelCatalogTests.
import Foundation

public enum ModelCatalog {
    /// id → name from one catalog file's JSON; empty when it can't be read.
    public static func names(json: Data) -> [String: String] {
        guard let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let ms = o["models"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for m in ms {
            if let id = m["id"] as? String, let n = m["name"] as? String, !n.isEmpty { out[id] = n }
        }
        return out
    }

    /// The catalogs in a scripts folder (asr_models.json, polish_models.json), merged.
    public static func load(scripts: URL) -> [String: String] {
        var out: [String: String] = [:]
        for f in ["asr_models.json", "polish_models.json"] {
            if let d = try? Data(contentsOf: scripts.appendingPathComponent(f)) { out.merge(names(json: d)) { a, _ in a } }
        }
        return out
    }

    /// The scripts the app runs: read once.
    public static let bundled: [String: String] = load(scripts: BlurtPaths.scripts)

    /// A name for `id`: the live list's, else the catalog's; nil when neither knows it (the caller says "another
    /// model" in words, never the id).
    public static func name(_ id: String, live: String?, catalog: [String: String] = bundled) -> String? {
        if let l = live, !l.isEmpty { return l }
        return catalog[id]
    }
}
