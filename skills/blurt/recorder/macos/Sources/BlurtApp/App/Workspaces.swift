// Where captures go (K2): the current project's store (<folder>/.blurt), or the inbox store ($BLURT_WORKSPACE/inbox)
// while the current project is "auto". ProjectStore (BlurtCore/Projects) is the source; these are the names the
// capture code has always used. A current project whose folder is gone (moved, renamed, a drive that isn't there) is
// never written into — a session there would make the old folder again (BlurtCore MissingFolder): its captures and
// recordings go to the inbox meanwhile, and the island's project chip says the folder is missing.
import AppKit
import BlurtCore

let homeDir = FileManager.default.homeDirectoryForCurrentUser
/// ~/Blurt (Blurt's own folder: the inbox store lives in it)
let defaultWorkspace = BlurtPaths.workspace

/// The current project, when captures may go into it: nil with none, or while its folder is gone.
func currentCaptureProject() -> Project? {
    guard let c = ProjectStore.shared.current,
          MissingFolder.filing(project: c.id, exists: c.exists) == .file else { return nil }
    return c
}

/// The current project's folder, else the inbox store (also while the current project's folder is gone).
func currentWorkspace() -> URL { currentCaptureProject()?.path ?? ProjectStore.shared.inbox.store }

/// The opened projects' folders.
func knownWorkspaces() -> [URL] { ProjectStore.shared.projects.filter(\.exists).map(\.path) }

/// <store>/sessions for a project folder or the inbox (v0.6's ~/Blurt/recordings is only read, by the index).
func sessionsRoot(for ws: URL) -> URL {
    let p = ws.standardizedFileURL
    if p == defaultWorkspace.standardizedFileURL || p == ProjectStore.shared.inbox.store.standardizedFileURL {
        return ProjectStore.shared.inbox.store.appendingPathComponent("sessions")
    }
    return ws.appendingPathComponent(".blurt/sessions")
}

/// ~/Blurt/inbox and the guide agents read when they are started in ~/Blurt.
func ensureDefaultWorkspace() {
    let fm = FileManager.default
    try? fm.createDirectory(at: ProjectStore.shared.inbox.store.appendingPathComponent("items"), withIntermediateDirectories: true)
    let guide = defaultWorkspace.appendingPathComponent("AGENTS.md")
    if !fm.fileExists(atPath: guide.path) {
        let text = """
        # Blurt workspace

        This folder belongs to **blurt** (口喷鸡). `inbox/` holds captures that aren't filed under a project yet:
        `inbox/items/*.md` are the items (one Markdown file each), `inbox/sessions/` the raw recordings and snap batches.
        Projects keep theirs in `<project>/.blurt/`. Use the `blurt` skill to work with them — e.g. "process my latest
        blurt recording" / "处理最新的录屏".
        """
        try? text.write(to: guide, atomically: true, encoding: .utf8)
        try? fm.createSymbolicLink(at: defaultWorkspace.appendingPathComponent("CLAUDE.md"), withDestinationURL: guide)
    }
}

/// A new recording's session dir in the current store.
func newSessionDir() -> URL { ProjectStore.shared.newSessionDir(.video) }
