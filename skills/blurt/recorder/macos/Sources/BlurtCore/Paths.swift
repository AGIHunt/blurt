// Where things live. Same rules as record.py / _common.py: BLURT_HOME relocates ~/.blurt (tests, CI),
// BLURT_WORKSPACE relocates ~/Blurt. Read with getenv on each access — cheap (no copy of the whole environment, which
// the status item's timer used to make twice a second), and a changed variable is still honoured.
import Foundation

public enum BlurtPaths {
    static func env(_ k: String) -> String? { getenv(k).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 } }

    /// ~/.blurt, or $BLURT_HOME
    public static var home: URL {
        env("BLURT_HOME").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".blurt")
    }
    /// ~/.blurt/config.json (shared with record.py)
    public static var config: URL { home.appendingPathComponent("config.json") }
    /// ~/.blurt/index.db (C3; written only by index.py, opened read-only here)
    public static var indexDB: URL { home.appendingPathComponent("index.db") }
    /// The default workspace: ~/Blurt, or $BLURT_WORKSPACE
    public static var workspace: URL {
        env("BLURT_WORKSPACE").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Blurt")
    }
    /// The blurt skill (SKILL.md, scripts/, agents.json). A release app runs its own (BundledSkill: the copy in
    /// ~/.blurt/skill, or the bundle itself when that copy couldn't be made), whatever skill an agent has installed.
    /// A local build: config `skill_dir` (record.py writes it on every run), else the usual install location. A
    /// config.json that doesn't parse must not move the app to another skill copy (or to none: a skill installed for
    /// Codex, at a custom path, a dev checkout): its `skill_dir` is still read from the text when it stands whole, else
    /// the last one a readable file named (kept in the app's defaults) — so the scripts keep running on the defaults
    /// instead of every call failing.
    public static var skillDir: URL {
        if let bundled = BundledSkill.source {
            let copy = BundledSkill.installed
            return FileManager.default.fileExists(atPath: copy.appendingPathComponent("scripts/_common.py").path) ? copy : bundled
        }
        return skillDir(config: .shared, remembered: .standard)
    }

    static let rememberedKey = "BlurtSkillDir"
    static var defaultSkillDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/blurt") }

    static func skillDir(config: Config, remembered: UserDefaults) -> URL {
        if config.readable {
            guard let s = config["skill_dir"] as? String, !s.isEmpty else { return defaultSkillDir }
            if remembered.string(forKey: rememberedKey) != s { remembered.set(s, forKey: rememberedKey) }
            return URL(fileURLWithPath: s)
        }
        let hasScripts = { (p: String) in FileManager.default.fileExists(atPath: URL(fileURLWithPath: p).appendingPathComponent("scripts").path) }
        for s in [config.lenientString("skill_dir"), remembered.string(forKey: rememberedKey)] {
            if let s = s, !s.isEmpty, hasScripts(s) { return URL(fileURLWithPath: s) }
        }
        return defaultSkillDir
    }
    /// <skill>/scripts — items.py, index.py, agents.py, live.py, transcribe.py, review.py…
    public static var scripts: URL { skillDir.appendingPathComponent("scripts") }
}
