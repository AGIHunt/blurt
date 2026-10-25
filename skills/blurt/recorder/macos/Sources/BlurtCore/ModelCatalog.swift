// Speech and polish models' names, straight from the catalogues the skill ships (scripts/asr_models.json,
// polish_models.json): read once, in-process, no script run. What Settings, the Dictation page and Storage show while
// a script's list is loading, can't be read (the speech tools aren't set up) or no longer has that model — never its id
// ("qwen3-asr-1.7b-mlx") or its folder ("sherpa-onnx-ced-mini-audio-tagging-2024-04-19"). Unit-tested in
// Tests/BlurtCoreTests/ModelCatalogTests.
import Foundation

public enum ModelCatalog {
    public struct Entry: Equatable {
        public var id: String
        public var name: String
        /// the folder (or Hugging Face repo's last part) the model's files land in, for Storage's rows
        public var folders: [String]
        public var sizeMB: Double
    }

    private static let lock = NSLock()
    private static var cached: [Entry]?

    /// Every model of both catalogues (`dir`: the scripts folder; tests pass their own).
    public static func entries(dir: URL = BlurtPaths.scripts) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        if dir == BlurtPaths.scripts, let c = cached { return c }
        var out: [Entry] = []
        for file in ["asr_models.json", "polish_models.json"] {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(file)),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let models = o["models"] as? [[String: Any]] else { continue }
            for m in models {
                guard let id = m["id"] as? String, let name = m["name"] as? String else { continue }
                out.append(Entry(id: id, name: name, folders: folders(m), sizeMB: (m["size_mb"] as? Double) ?? 0))
            }
        }
        if dir == BlurtPaths.scripts { cached = out }
        return out
    }

    /// The model's name; nil when no catalogue has it.
    public static func name(_ id: String, dir: URL = BlurtPaths.scripts) -> String? {
        entries(dir: dir).first { $0.id == id }?.name
    }

    /// The model whose files are in this folder (Storage's rows: a folder name → the model's name).
    public static func entry(folder: String, dir: URL = BlurtPaths.scripts) -> Entry? {
        entries(dir: dir).first { $0.folders.contains(folder) || $0.id == folder }
    }

    /// Where a model's files land: its archive's folder, its file paths' first folder, its Hugging Face repo's
    /// last part (and the HF cache's models--org--name), the polish repo's last part.
    static func folders(_ m: [String: Any]) -> [String] {
        var out: [String] = []
        if let repo = m["repo"] as? String {
            out.append(repo.split(separator: "/").last.map(String.init) ?? repo)
            out.append("models--" + repo.replacingOccurrences(of: "/", with: "--"))
        }
        if let inst = m["install"] as? [String: Any] {
            if let hf = inst["hf"] as? String {
                out.append(hf.split(separator: "/").last.map(String.init) ?? hf)
                out.append("models--" + hf.replacingOccurrences(of: "/", with: "--"))
            }
            if let dir = inst["dir"] as? String { out.append(dir) }
            if let files = inst["files"] as? [String: Any] {
                out += files.keys.compactMap { $0.split(separator: "/").first.map(String.init) }.filter { !$0.contains(".") }
            }
            if let archive = inst["archive"] as? String, let last = archive.split(separator: "/").last {
                var base = String(last)
                for ext in [".tar.bz2", ".tar.gz", ".tgz", ".zip"] where base.hasSuffix(ext) { base = String(base.dropLast(ext.count)) }
                out.append(base)
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
}
