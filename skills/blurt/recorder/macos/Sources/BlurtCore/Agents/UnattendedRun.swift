// An unattended agent run (organizing a recording, AI fill-in): agents.json `run` with its placeholders filled, and
// the sandbox it gets. The text it works on comes from the user's screen and voice, so it gets the least privilege
// that still files items (agents.json _doc). Same rules as agents.py _fill / writable_dirs / sandbox_env.
//
//   {prompt}    the task text
//   {scripts}   the skill's scripts folder: Claude / Gemini may run only `uv run <scripts>/<name>.py` (the prompt
//               names the same path)
//   {writable}  one `--add-dir` per folder a sandboxed run (Codex) may write besides its cwd
import Foundation

public enum UnattendedRun {
    /// `run` filled in; the prompt text itself is never searched for placeholders.
    public static func args(_ run: [String], prompt: String, scripts: String, writable: [String]) -> [String] {
        run.flatMap { a -> [String] in
            if a == "{writable}" { return writable.flatMap { ["--add-dir", $0] } }
            if a == "{prompt}" { return [prompt] }
            return [a.replacingOccurrences(of: "{scripts}", with: scripts).replacingOccurrences(of: "{prompt}", with: prompt)]
        }
    }

    /// A sandboxed run's own uv cache. The shared one stays read-only to it: an environment planted there would run,
    /// unsandboxed, the next time the app calls a script.
    public static func uvCache(home: URL) -> URL { home.appendingPathComponent("sandbox/uv-cache") }

    /// What an organizing run may write besides its cwd (the session folder): the inbox store and every project's
    /// store that exists (ingest files an item straight into the project the agent is sure of; set-frames and patch
    /// follow it) and its own uv cache. Never Blurt's home — config.json and its agent_defs, the jobs and their hook
    /// settings, index.db — nor the shared uv cache: a write there would run outside the sandbox later.
    public static func writableDirs(inbox: URL, projectStores: [URL], home: URL) -> [String] {
        var seen = Set<String>()
        let stores = ([inbox] + projectStores).filter { u in  // a moved project's old path: nothing to write
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue
        }
        return (stores.map(\.path) + [uvCache(home: home).path]).filter { seen.insert($0).inserted }
    }

    /// The environment a sandboxed run adds (agents.py sandbox_env): its own uv cache, created here since its parent
    /// isn't writable to the run, and no index writes ($BLURT_HOME isn't writable to it; the app re-indexes).
    public static func sandboxEnv(home: URL) -> [String: String] {
        let cache = uvCache(home: home)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return ["UV_CACHE_DIR": cache.path, "BLURT_NO_INDEX": "1"]
    }

    /// The line the prompt adds so the agent calls the scripts the way its permissions allow.
    public static func scriptsHint(_ scripts: String) -> String {
        "\nRun the skill's scripts exactly as `uv run \(scripts)/<name>.py …` (no other form, no other command is allowed)."
    }
}
