// The skill a release app carries (Blurt.app/Contents/Resources/skill: SKILL.md, scripts/, assets/, reference/ —
// scripts/release-mac.sh puts it there, with a `.version` stamp). The app runs its Python, its review page and its
// agents' skill from that copy, so the app downloaded from the website needs nothing else (v1.0.0 needed
// `npx skills add` too, and an older skill there met a newer app). It is copied to ~/.blurt/skill at launch whenever
// that copy's stamp isn't the bundle's: the signed bundle is never written to (Python's caches would break its
// signature), and Settings → Agents links agents to the copy, which every update refreshes in place. A local build
// (`record.py build`) has no bundled skill and keeps BlurtPaths' old rule: config `skill_dir`, else
// ~/.claude/skills/blurt.
import Foundation

public enum BundledSkill {
    static let stampName = ".version"

    /// The bundled skill, when this app has one with its scripts.
    public static var source: URL? { source(in: Bundle.main) }

    static func source(in bundle: Bundle) -> URL? {
        guard let r = bundle.resourceURL?.appendingPathComponent("skill") else { return nil }
        return FileManager.default.fileExists(atPath: r.appendingPathComponent("scripts/_common.py").path) ? r : nil
    }

    /// Where it runs from: ~/.blurt/skill
    public static var installed: URL { BlurtPaths.home.appendingPathComponent("skill") }

    /// The stamp of a skill copy (its `.version`), nil when it has none.
    static func stamp(_ dir: URL) -> String? {
        (try? String(contentsOf: dir.appendingPathComponent(stampName), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Copies `src` to `dest` unless `dest` already is that copy (same stamp, scripts there). The new copy is made
    /// next to it and swapped in, so a script starting meanwhile never sees half a skill. Returns true when copied.
    @discardableResult
    public static func sync(from src: URL, to dest: URL) throws -> Bool {
        let fm = FileManager.default
        let want = stamp(src)
        if want != nil, stamp(dest) == want, fm.fileExists(atPath: dest.appendingPathComponent("scripts/_common.py").path) {
            return false
        }
        let parent = dest.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let tag = UUID().uuidString.prefix(8)
        let fresh = parent.appendingPathComponent(".\(dest.lastPathComponent)-new-\(tag)")
        let old = parent.appendingPathComponent(".\(dest.lastPathComponent)-old-\(tag)")
        try fm.copyItem(at: src, to: fresh)
        if fm.fileExists(atPath: dest.path) || (try? fm.destinationOfSymbolicLink(atPath: dest.path)) != nil {
            try fm.moveItem(at: dest, to: old)
        }
        do { try fm.moveItem(at: fresh, to: dest) } catch {
            try? fm.moveItem(at: old, to: dest)          // put the old copy back rather than leave none
            try? fm.removeItem(at: fresh)
            throw error
        }
        try? fm.removeItem(at: old)
        return true
    }

    /// At launch: the bundled skill copied where it runs. nil without a bundled skill; else whether it was copied,
    /// or the error (the app then runs the bundle's scripts directly — see BlurtPaths.skillDir).
    public static func syncAtLaunch() -> Result<Bool, Error>? {
        guard let src = source else { return nil }
        return Result { try sync(from: src, to: installed) }
    }
}
