// A project whose folder can't be found — moved, renamed or deleted on disk (dogfood v0.9-2: a snap filed into one
// made its folder again at the old path, with BA-1 there next to the moved folder's BA-1…). Nothing is written to it:
//  • captures go to Unassigned meanwhile (ProjectStore.captureTarget): a snap or a voice note hangs as a card, a
//    recording goes to Unassigned; the island says so, with Locate… (`warn`);
//  • filing into it — a card dropped on it, Move To ▸, the note's "Goes to" chip — is refused before anything is
//    written (Snapper.file); captures.py / items.py refuse too (folder_missing), and never make the folder again;
//  • the island's switcher and the note's chip show it with a question-mark folder and "folder not found"; picking it
//    there asks where it is now.
// Locate… asks for the folder: one that holds this project's store (`.blurt/store.json`) reconnects it — projects.py
// add relocates a store whose registered folder is gone, so the id, key and items stay; a folder with another
// project's store is refused; a folder with no store yet (the project never had an item) is opened and made current.
import AppKit
import BlurtCore

enum MissingFolder {
    static let toastKey = "missing-folder"

    /// "Can't find billing-api's folder — kept as a card · Locate…" (or "— recording to Unassigned").
    static func warn(_ p: Project, recording: Bool = false) {
        emit(["event": "project_missing", "project": p.id, "recording": recording])
        var t = Island.Toast(text: Loc.t(recording ? "capture.project.missing_rec" : "capture.project.missing_card",
                                         table: "Capture", p.name),
                             actionTitle: Loc.t("capture.project.locate", table: "Capture")) { locate(p) }
        t.key = toastKey
        t.seconds = 8
        island.toast(t)
    }

    /// The current project's folder is gone: say so (captures go to Unassigned meanwhile). True when it was.
    @discardableResult
    static func warnIfCurrentMissing(recording: Bool = false) -> Bool {
        guard let p = ProjectStore.shared.missingCurrent else { return false }
        warn(p, recording: recording)
        return true
    }

    /// Where is `p`'s folder now? An open panel near where it was; the folder picked is opened (relocated).
    static func locate(_ p: Project) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = Loc.t("capture.drawer.open_prompt", table: "Capture")
        panel.message = Loc.t("capture.project.locate_message", table: "Capture", p.name)
        var up = p.path.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: up.path), up.path != "/" { up.deleteLastPathComponent() }
        panel.directoryURL = up
        activateApp()
        guard panel.runModal() == .OK, let u = panel.url else { return }
        let pick = ProjectStore.locatePick(u, projectID: p.id)
        emit(["event": "project_locate", "project": p.id, "pick": pick.rawValue])
        guard pick != .other else {
            island.toast(Loc.t("capture.project.not_this", table: "Capture", p.name), actionTitle: nil, action: nil)
            return
        }
        let wasCurrent = ProjectStore.shared.currentID == p.id
        Task {
            do {
                let found = try await ProjectStore.shared.open(folder: u)
                if wasCurrent && found.id != p.id { try await ProjectStore.shared.use(found.id) }
                await MainActor.run {
                    island.dropToasts(key: toastKey)
                    island.projectChanged()
                    island.toast(Loc.t("capture.project.found", table: "Capture", found.name), actionTitle: nil, action: nil)
                }
            } catch {
                emit(["event": "project_locate_failed", "project": p.id, "error": "\(error)"])
                await MainActor.run {
                    island.toast(Loc.t("capture.drawer.open_failed", table: "Capture"), actionTitle: nil, action: nil)
                }
            }
        }
    }
}
