// Where things live. Same rules as record.py / _common.py: BLURT_HOME relocates ~/.blurt (tests, CI),
// BLURT_WORKSPACE relocates ~/Blurt.
import Foundation

public enum BlurtPaths {
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// ~/.blurt, or $BLURT_HOME
    public static var home: URL {
        env["BLURT_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".blurt")
    }
    /// ~/.blurt/config.json (shared with record.py)
    public static var config: URL { home.appendingPathComponent("config.json") }
    /// ~/.blurt/index.db (C3; written only by index.py, opened read-only here)
    public static var indexDB: URL { home.appendingPathComponent("index.db") }
    /// The default workspace: ~/Blurt, or $BLURT_WORKSPACE
    public static var workspace: URL {
        env["BLURT_WORKSPACE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Blurt")
    }
    /// The blurt skill (SKILL.md, scripts/, agents.json): config `skill_dir` (record.py writes it on every run), else
    /// the usual install location.
    public static var skillDir: URL {
        if let s = Config.shared["skill_dir"] as? String, !s.isEmpty { return URL(fileURLWithPath: s) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/blurt")
    }
    /// <skill>/scripts — items.py, index.py, agents.py, live.py, transcribe.py, review.py…
    public static var scripts: URL { skillDir.appendingPathComponent("scripts") }
}
