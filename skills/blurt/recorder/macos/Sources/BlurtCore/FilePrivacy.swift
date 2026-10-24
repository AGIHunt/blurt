// Blurt's own data is the user's alone: what they dictated (dictation/history.jsonl keeps raw and polished text), the
// local model servers' tokens (run/*-serve.json), jobs, captures. On a Mac with several accounts the defaults (0755
// folders, 0644 files) let every other account read them, so:
//   • $BLURT_HOME and the folders that hold that data are 0700 (lockDown, at every launch of the menu-bar app — a
//     folder made by an older build, or by a script, is brought in line; the scripts make theirs 0700 too:
//     _common.private_dir);
//   • the files Blurt writes there with writePrivate are 0600 (config.json; _common.save_json does the same for
//     everything under $BLURT_HOME).
// The default workspace (~/Blurt — recordings, snaps, the Unassigned items) is 0700 like ~/Documents.
import Foundation

public enum FilePrivacy {
    /// The folders under $BLURT_HOME that hold the user's data.
    public static let privateDirs = ["dictation", "run", "jobs", "handoff", "runs", "prompts", "tmp"]

    /// Folders 0700, and the files that are secrets (tokens) or the user's words 0600. Returns the paths it changed.
    @discardableResult
    public static func lockDown(home: URL = BlurtPaths.home, workspace: URL? = BlurtPaths.workspace) -> [String] {
        var changed: [String] = []
        func chmodIf(_ u: URL, _ mode: mode_t) {
            var st = stat()
            guard lstat(u.path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK, st.st_mode & 0o777 != mode else { return }
            if chmod(u.path, mode) == 0 { changed.append(u.path) }
        }
        chmodIf(home, 0o700)
        for d in privateDirs { chmodIf(home.appendingPathComponent(d), 0o700) }
        if let ws = workspace { chmodIf(ws, 0o700) }
        let fm = FileManager.default
        chmodIf(home.appendingPathComponent("config.json"), 0o600)
        chmodIf(home.appendingPathComponent("dictation/history.jsonl"), 0o600)
        for f in (try? fm.contentsOfDirectory(at: home.appendingPathComponent("run"), includingPropertiesForKeys: nil)) ?? []
            where f.pathExtension == "json" { chmodIf(f, 0o600) }
        return changed
    }

    /// An atomic write whose file is 0600 from the start (a temp file next to it, then rename). False when it failed.
    @discardableResult
    public static func writePrivate(_ data: Data, to url: URL) -> Bool {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        let ok = data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        close(fd)
        guard ok, rename(tmp.path, url.path) == 0 else { unlink(tmp.path); return false }
        return true
    }
}
