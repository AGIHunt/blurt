// A project whose folder can't be found — moved, renamed or deleted on disk, or on a drive that isn't plugged in
// (dogfood v0.9-2: a snap filed into one made its folder again at the old path, with BA-1 there next to the moved
// folder's BA-1…). Nothing is written to it (ProjectStore.filing, captureTarget):
//  • captures go to Unassigned meanwhile (ProjectStore.captureTarget): a snap or a voice note hangs as a card, a
//    recording goes to Unassigned; the island says so, with Locate… (`warn`);
//  • filing into it — a card dropped on it, Move To ▸, VoiceOver's "Move to X", the note's "Goes to" chip,
//    Organize — is refused before anything is written (Snapper.keepAsCards); captures.py / items.py refuse too
//    (folder_missing), and never make the folder again;
//  • the island's switcher, the note's chip and the main window's sidebar show it with a question-mark folder and
//    "folder not found"; choosing it there asks where it is now.
// Locate… (`ask`: the island, the main window's banner and sidebar) asks for the folder: only one that holds this
// project's store (`.blurt/store.json`) is taken, and it reconnects it — projects.py add relocates a store whose
// registered folder is gone, so the id, key and items stay. Any other folder (another project's, or one with no
// store: every registered project has had one since it was opened, so that is the parent or a wrong folder) is
// refused inside the panel, which stays open (`Validator`). Found again, it takes the cards kept back from it.
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
        t.overOpen = true               // a drop on the open island: said at once
        island.toast(t)
    }

    /// The current project's folder is gone: say so (captures go to Unassigned meanwhile). True when it was.
    @discardableResult
    static func warnIfCurrentMissing(recording: Bool = false) -> Bool {
        guard let p = ProjectStore.shared.missingCurrent else { return false }
        warn(p, recording: recording)
        return true
    }

    /// Locate… from the island: where is `p`'s folder now? Found → the cards kept back from it are filed there, it
    /// stays current if it was, and `then` runs (the switcher makes it current, the pick form files its one thing).
    static func locate(_ p: Project, then: ((Project) -> Void)? = nil) {
        let wasCurrent = ProjectStore.shared.currentID == p.id
        ask(p) { r in
            switch r {
            case .found(let found):
                Task {
                    if wasCurrent && found.id != p.id { try? await ProjectStore.shared.use(found.id) }
                    await MainActor.run {
                        island.dropToasts(key: toastKey)
                        island.projectChanged()
                        island.toast(Loc.t("capture.project.found", table: "Capture", found.name), actionTitle: nil, action: nil)
                        snapper.filedKept(from: p, to: found)
                        then?(found)
                    }
                }
            case .failed:
                island.toast(Loc.t("capture.drawer.open_failed", table: "Capture"), actionTitle: nil, action: nil)
            }
        }
    }

    enum Outcome {
        /// the same project, at its new place
        case found(Project)
        /// it couldn't be opened as this project: what to tell the user (the raw error goes to the log)
        case failed(String)
    }

    static func ask(_ p: Project, on window: NSWindow? = nil, done: @escaping (Outcome) -> Void) {
        ask(id: p.id, name: p.name, path: p.path, on: window, done: done)
    }

    /// Asks where the folder of project `id` (`name`, last seen at `path`) is now — a sheet on `window` when it shows,
    /// else a panel of its own — and opens it there. `done` isn't called when the user cancels.
    static func ask(id: String, name: String, path: URL, on window: NSWindow? = nil, done: @escaping (Outcome) -> Void) {
        let open: (URL) -> Void = { u in
            let pick = ProjectStore.locatePick(u, projectID: id)
            emit(["event": "project_locate", "project": id, "pick": pick.rawValue])
            // (the panel refused it already; `locatepick` in tests comes here without the panel)
            guard pick == .same else {
                emit(["event": "project_locate_refused", "project": id, "pick": pick.rawValue])
                return done(.failed(Loc.t("capture.project.not_this", table: "Capture", name)))
            }
            Task { @MainActor in
                do {
                    let found = try await ProjectStore.shared.open(folder: u)
                    emit(["event": "project_located", "project": id, "found": found.id])
                    done(.found(found))
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
        let check = Validator(id: id, name: name)
        panel.delegate = check
        let picked: (NSApplication.ModalResponse) -> Void = { r in
            withExtendedLifetime(check) {}
            guard r == .OK, let u = panel.url else { return }
            open(u)
        }
        if let w = window, w.isVisible { panel.beginSheetModal(for: w, completionHandler: picked) }
        else { activateApp(); picked(panel.runModal()) }
    }

    /// Tests (test command `locatepick PATH`): the folder the next Locate… picks, without its open panel.
    static var testPick: URL?

    /// Keeps the panel open on a folder that isn't this project's, saying so in a sheet over it (AppKit shows it).
    final class Validator: NSObject, NSOpenSavePanelDelegate {
        let id: String, name: String
        init(id: String, name: String) { self.id = id; self.name = name }
        func panel(_ sender: Any, validate url: URL) throws {
            let pick = ProjectStore.locatePick(url, projectID: id)
            guard pick != .same else { return }
            emit(["event": "project_locate_refused", "project": id, "pick": pick.rawValue])
            throw NSError(domain: "Blurt.Locate", code: 1, userInfo: [
                NSLocalizedDescriptionKey: Loc.t("capture.project.not_this", table: "Capture", name),
                NSLocalizedRecoverySuggestionErrorKey: Loc.t("capture.project.not_this_hint", table: "Capture", name),
            ])
        }
    }
}
