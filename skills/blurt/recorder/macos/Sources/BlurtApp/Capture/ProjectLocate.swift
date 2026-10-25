// Locate… for a project whose folder is gone (BlurtCore MissingFolder): the main window's banner and sidebar, the
// island's switcher and drop drawer, and the "folder not found · the card stays" toast all ask here. Opening the
// folder where it is now is the same project again (projects.py add relocates a store whose registered folder has
// gone). A folder that is another project opens as that one: the caller says so and leaves the missing one as it was
// (never "found" under the wrong project, never made current or filed into in its place).
import AppKit
import BlurtCore

enum ProjectLocate {
    enum Outcome {
        /// the same project, at its new place
        case found(Project)
        /// the picked folder is another project (now opened): the missing one is still missing
        case other(Project)
        /// it couldn't be opened as a project: what to tell the user (the raw error goes to the log)
        case failed(String)
    }

    static func ask(_ p: Project, on window: NSWindow? = nil, done: @escaping (Outcome) -> Void) {
        ask(id: p.id, name: p.name, path: p.path, on: window, done: done)
    }

    /// Asks where the folder of project `id` (`name`, last seen at `path`) is now — a sheet on `window` when it shows,
    /// else a panel of its own — and opens it there. `done` isn't called when the user cancels.
    static func ask(id: String, name: String, path: URL, on window: NSWindow? = nil, done: @escaping (Outcome) -> Void) {
        let open: (URL) -> Void = { u in
            Task { @MainActor in
                do {
                    let found = try await ProjectStore.shared.open(folder: u)
                    let same = MissingFolder.located(wanted: id, found: found.id) == .same
                    emit(["event": "project_locate", "project": id, "found": found.id, "same": same])
                    done(same ? .found(found) : .other(found))
                } catch let e as ProjectError {
                    emit(["event": "project_locate_failed", "project": id, "code": e.code, "error": "\(e)"])
                    done(.failed(Scripts.Failure(code: e.code, message: "\(e)").localized))
                } catch {
                    emit(["event": "project_locate_failed", "project": id, "error": "\(error)"])
                    done(.failed(T("main.error.generic")))
                }
            }
        }
        if let u = testPick { testPick = nil; return open(u) }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = T("main.open.prompt")
        panel.message = T("main.missing.locate.message", name)
        var up = path.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: up.path), up.path != "/" { up.deleteLastPathComponent() }
        panel.directoryURL = up
        let picked: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .OK, let u = panel.url else { return }
            open(u)
        }
        if let w = window, w.isVisible { panel.beginSheetModal(for: w, completionHandler: picked) }
        else { activateApp(); picked(panel.runModal()) }
    }

    /// Tests (test command `locatepick PATH`): the folder the next Locate… picks, without its open panel.
    static var testPick: URL?

    /// "That folder is “site”, not “ordo-platform”".
    static func otherLine(_ found: Project, wanted: String) -> String { T("main.missing.other", found.name, wanted) }
}
