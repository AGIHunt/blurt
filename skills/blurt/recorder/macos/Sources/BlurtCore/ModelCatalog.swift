// Speech and polish models' names, straight from the catalogues the skill ships (scripts/asr_models.json,
// polish_models.json: {"models": [{"id", "name", …}]}): read once, in-process, no script run. What Settings, the
// Dictation page and Storage show while a script's list is loading, can't be read (the speech tools aren't set up) or
// no longer has that model — never its id ("qwen3-asr-1.7b-mlx", v0.9 raw-identifier audit #12) or its folder
// ("sherpa-onnx-ced-mini-audio-tagging-2024-04-19"). Unit-tested in Tests/BlurtCoreTests/ModelCatalogTests.
import Foundation

public enum ModelCatalog {
    public struct Entry: Equatable {
        public var id: String
        public var name: String
        /// the folder (or Hugging Face repo's last part) the model's files land in, for Storage's rows
        public var folders: [String]
        public var sizeMB: Double
        /// a polish model (polish_models.json), else speech recognition
        public var polish: Bool
        /// the speech backend that runs it ("openai", "sensevoice"…)
        public var backend: String? = nil
    }

    private static let lock = NSLock()
    private static var cached: [Entry]?

    /// Every model of both catalogues (`dir`: the scripts folder; tests pass their own).
    public static func entries(dir: URL = BlurtPaths.scripts) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        if dir == BlurtPaths.scripts, let c = cached { return c }
        var out: [Entry] = []
        for file in ["asr_models.json", "polish_models.json"] {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(file)) else { continue }
            out += entries(json: d, polish: file.hasPrefix("polish"))
        }
        if dir == BlurtPaths.scripts { cached = out }
        return out
    }

    /// The models of one catalogue file's JSON (a model without a name is left out); empty when it can't be read.
    public static func entries(json: Data, polish: Bool) -> [Entry] {
        guard let o = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let models = o["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { m in
            guard let id = m["id"] as? String, let name = m["name"] as? String, !name.isEmpty else { return nil }
            return Entry(id: id, name: name, folders: folders(m), sizeMB: (m["size_mb"] as? Double) ?? 0,
                         polish: polish, backend: m["backend"] as? String)
        }
    }

    /// id → name from one catalogue file's JSON; empty when it can't be read.
    public static func names(json: Data) -> [String: String] {
        Dictionary(entries(json: json, polish: false).map { ($0.id, $0.name) }) { a, _ in a }
    }

    /// The catalogues in a scripts folder (asr_models.json, polish_models.json), merged: id → name.
    public static func load(scripts: URL) -> [String: String] {
        Dictionary(entries(dir: scripts).map { ($0.id, $0.name) }) { a, _ in a }
    }

    /// A name for `id`: the live list's (`transcribe.py dictation-models`), else the catalogues' (`catalog`: id →
    /// name, tests; else the shipped ones, `name(_:dir:)`); nil when neither knows it — the caller says "a model no
    /// longer listed" in words, never the id.
    public static func name(_ id: String, live: String?, catalog: [String: String]? = nil) -> String? {
        if let l = live, !l.isEmpty { return l }
        if let c = catalog { return c[id] }
        return name(id)
    }

    /// The model's name; nil when no catalogue has it. A `backend:model` id — what the scripts make up for a model
    /// set by backend and name (a cloud API's "openai:whisper-1") — is named by its backend's catalogue entry and the
    /// model: "OpenAI-compatible API · whisper-1" (the backend's alone for ":default").
    public static func name(_ id: String, dir: URL = BlurtPaths.scripts) -> String? {
        let all = entries(dir: dir)
        if let e = all.first(where: { $0.id == id }) { return e.name }
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let e = all.first(where: { $0.backend == parts[0] && !$0.polish }) else { return nil }
        return parts[1].isEmpty || parts[1] == "default" ? e.name : "\(e.name) · \(parts[1])"
    }

    /// The model whose files are in this folder (Storage's rows: a folder name → the model's name).
    public static func entry(folder: String, dir: URL = BlurtPaths.scripts) -> Entry? {
        entries(dir: dir).first { $0.folders.contains(folder) || $0.id == folder }
    }

    /// What of a model not yet installed is already on disk (bytes) — the partial files a stopped or cut-short download
    /// keeps and the next one continues (the scripts resume `<name>.part` and Hugging Face's `*.incomplete`): every file
    /// under its folders in `models` (asr/, polish/, the top) and in the Hugging Face cache (`hfCache`), plus a
    /// `<folder>….part` beside them (an archive on its way). Counted as the scripts count it (_common.landed_bytes):
    /// the blocks written, not a size set up front. Links are not followed.
    public static func keptBytes(_ id: String, models: URL, hfCache: URL? = nil, dir: URL = BlurtPaths.scripts) -> Int64 {
        guard let e = entries(dir: dir).first(where: { $0.id == id }) else { return 0 }
        let fm = FileManager.default
        func landed(_ u: URL) -> Int64 {
            guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .fileAllocatedSizeKey]),
                  v.isRegularFile == true, v.isSymbolicLink != true else { return 0 }
            return Int64(min(v.fileSize ?? 0, v.fileAllocatedSize ?? v.fileSize ?? 0))
        }
        func walk(_ d: URL) -> Int64 {
            guard let en = fm.enumerator(at: d, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                                                             .fileSizeKey, .fileAllocatedSizeKey]) else { return 0 }
            var t: Int64 = 0
            for case let u as URL in en { t += landed(u) }
            return t
        }
        var roots = [models, models.appendingPathComponent("asr"), models.appendingPathComponent("polish")]
        if let h = hfCache { roots.append(h) }
        var total: Int64 = 0
        var seen = Set<String>()
        for r in roots {
            let names = (try? fm.contentsOfDirectory(atPath: r.path)) ?? []
            for f in e.folders {
                for n in names where n == f || (n.hasPrefix(f) && n.hasSuffix(".part")) {
                    let u = r.appendingPathComponent(n)
                    guard seen.insert(u.standardizedFileURL.path).inserted else { continue }
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: u.path, isDirectory: &isDir)
                    total += isDir.boolValue ? walk(u) : landed(u)
                }
            }
        }
        return total
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
