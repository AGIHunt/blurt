import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import ServiceManagement

// MARK: - Workspaces (menu-bar app): where recordings go

let homeDir = FileManager.default.homeDirectoryForCurrentUser
let defaultWorkspace = ProcessInfo.processInfo.environment["BLURT_WORKSPACE"].map { URL(fileURLWithPath: $0) }
    ?? homeDir.appendingPathComponent("Blurt")

func currentWorkspace() -> URL {
    if let p = recordConfig()["workspace"] as? String, FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
    return defaultWorkspace
}

func knownWorkspaces() -> [URL] {
    let list = (recordConfig()["workspaces"] as? [String] ?? []).filter { FileManager.default.fileExists(atPath: $0) }
    return list.map { URL(fileURLWithPath: $0) }
}

/// Default workspace keeps recordings visible (~/Blurt/recordings); a bound project uses <repo>/.blurt/sessions.
func sessionsRoot(for ws: URL) -> URL {
    ws.standardizedFileURL == defaultWorkspace.standardizedFileURL
        ? ws.appendingPathComponent("recordings") : ws.appendingPathComponent(".blurt/sessions")
}

func ensureDefaultWorkspace() {
    let fm = FileManager.default
    try? fm.createDirectory(at: defaultWorkspace.appendingPathComponent("recordings"), withIntermediateDirectories: true)
    let guide = defaultWorkspace.appendingPathComponent("AGENTS.md")
    if !fm.fileExists(atPath: guide.path) {
        let text = """
        # Blurt workspace

        This folder is the default workspace of **blurt** (口喷鸡). Each folder in `recordings/` is one screen
        recording with narration (`recording.mp4`, `events.jsonl`, `meta.json`). Use the `blurt` skill to turn a
        recording into structured output (issues, ideas, notes…) — e.g. "process my latest blurt recording" /
        "处理最新的录屏". Outputs are written next to the recording.
        """
        try? text.write(to: guide, atomically: true, encoding: .utf8)
        try? fm.createSymbolicLink(at: defaultWorkspace.appendingPathComponent("CLAUDE.md"), withDestinationURL: guide)
    }
}

func newSessionDir() -> URL {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    let dir = sessionsRoot(for: currentWorkspace()).appendingPathComponent(f.string(from: Date()))
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func recentSessions(limit: Int = 8) -> [URL] {
    var dirs: [URL] = []
    for ws in Set([defaultWorkspace] + knownWorkspaces() + [currentWorkspace()]) {
        let root = sessionsRoot(for: ws)
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        dirs += items.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("recording.mp4").path) || isShotsSession($0) }
    }
    return Array(dirs.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(limit))
}
