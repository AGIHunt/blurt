// "Filed to X · Change" (K2, v0.9): the moment something is captured, the island says where it went, and Change puts
// it somewhere else — the user's call, cheap, right there. Change opens the island's project switcher in its pick form
// (Island.Pick: the same rows, type to filter; the current project stays as it is). Nothing ever moves on Blurt's own.
//
//   a recording, as it ends   "Filed to Atlas Web · Change" (or "Filed to Unassigned · Change"). Its meta.json
//                             "project" changes — the organizing run writes the items there — and the items it
//                             already has move (items.py move --from: only the ones still where the recording put
//                             them; one the user has moved by hand since stays where they put it). If it is still
//                             being organized, the run's end moves any item that landed in an earlier place
//                             (organized(_:)); a run that fails forgets it (runEnded(_:)).
//   a capture filed           "Filed to Atlas Web · AW-14 · Change" (a snap with a note, a card dropped on a project):
//                             its items are moved, the same way.
// Either way the island then says "Moved to Y · Undo" ("3 items moved to Y" for several); Undo moves exactly the
// items that moved back where they were — the ones still in Y — the same way the main window's ⌘Z does.
import AppKit
import BlurtCore

enum Refile {
    /// Recordings re-filed while they were still being organized: session path → where the user wants it now, and the
    /// places it was filed to before (the run may have written its items to one of them).
    private static var pending: [String: RefileTrail] = [:]
    /// Test hook (SnapApp `refilerun`): sessions to treat as being organized.
    static var testRunning = Set<String>()

    static func name(_ id: String) -> String {
        id == "inbox" ? Loc.t("project.inbox") : ProjectStore.shared.project(id: id)?.name ?? id
    }

    static func badge(_ id: String) -> (text: String, color: NSColor)? {
        guard id != "inbox", let p = ProjectStore.shared.project(id: id) else { return nil }
        return (p.key, ProjectLook.color(p))
    }

    // MARK: a recording

    /// The line a recording leaves as it ends and goes off to be organized: where its items will be, and Change.
    static func offerRecording(_ dir: URL, project: String?) {
        let where_ = project ?? "inbox"
        emit(["event": "recording_filed", "session": dir.path, "project": where_])
        var t = Island.Toast(text: Loc.t("capture.recording.filed", table: "Capture", name(where_)),
                             actionTitle: Loc.t("capture.change", table: "Capture")) {
            pick(title: Loc.t("capture.drawer.pick_title", table: "Capture"), current: where_) { to in
                recording(dir, to: to, from: where_)
            }
        }
        t.badge = badge(where_)
        t.seconds = 8
        t.key = "refile.\(dir.path)"
        island.toast(t)
    }

    /// The recording `dir` now goes to `to` (a project id or "inbox"), from `from`. `only`: the items to move (Undo:
    /// the ones the Change moved); nil = every item the recording has.
    static func recording(_ dir: URL, to: String, from: String, only: [String]? = nil) {
        guard to != from else { return }
        updateMeta(dir) { $0["project"] = to == "inbox" ? NSNull() : to }
        let uids = only ?? batchItems(dir)
        let running = testRunning.contains(dir.path)
            || JobStore.shared.active.contains { $0.type == .process && $0.session?.standardizedFileURL.path == dir.standardizedFileURL.path }
        emit(["event": "refile_recording", "session": dir.path, "to": to, "from": from, "items": uids.count, "running": running])
        if running {
            var p = pending[dir.path] ?? RefileTrail(to: from)
            p.refiled(to: to, from: from)
            pending[dir.path] = p
        }
        shift(uids, to: to, from: from) { moved in recording(dir, to: from, from: to, only: moved) }
    }

    /// An organizing run is over (AgentHub): a recording re-filed while it ran gets its items where the user said —
    /// the ones the run wrote to a place it was filed to before; any the user has moved since stay.
    static func organized(_ dir: URL) {
        guard let p = pending.removeValue(forKey: dir.path), !p.movesFrom.isEmpty else { return }
        let uids = batchItems(dir)
        emit(["event": "refile_after_run", "session": dir.path, "to": p.to, "from": p.movesFrom, "items": uids.count])
        guard !uids.isEmpty else { return }
        move(uids, to: p.to, from: p.movesFrom) { _ in }
    }

    /// The run ended without items (failed, no agent, never started): nothing to put anywhere. Its meta.json already
    /// names the user's choice for the next run.
    static func runEnded(_ dir: URL) {
        if pending.removeValue(forKey: dir.path) != nil { emit(["event": "refile_forgotten", "session": dir.path]) }
    }

    /// The uids batch.json lists (the items organizing wrote, wherever they are now).
    static func batchItems(_ dir: URL) -> [String] {
        let o = (try? Data(contentsOf: dir.appendingPathComponent("batch.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return o?["items"] as? [String] ?? []
    }

    // MARK: items just filed

    /// "Filed to X · AW-14 · Change": these items to another project.
    static func items(_ uids: [String], from: String) {
        pick(title: Loc.t("capture.drawer.pick_title", table: "Capture"), current: from) { to in move(uids, to: to, from: from) }
    }

    private static func move(_ uids: [String], to: String, from: String) {
        guard to != from, !uids.isEmpty else { return }
        emit(["event": "refile_items", "items": uids.count, "to": to, "from": from])
        shift(uids, to: to, from: from) { moved in move(moved, to: from, from: to) }
    }

    // MARK: the parts

    private static func pick(title: String, current: String, choose: @escaping (String) -> Void) {
        island.showPicker(Island.Pick(title: title, current: current, choose: choose))
    }

    /// The `uids` still in `from` go to `to`; then "Moved to Y · Undo", whose Undo gets the uids that moved.
    private static func shift(_ uids: [String], to: String, from: String, undo: @escaping ([String]) -> Void) {
        guard !uids.isEmpty else { return said(0, to: to) { undo([]) } }
        move(uids, to: to, from: [from]) { moved in said(moved.count, to: to) { undo(moved) } }
    }

    /// items.py move --from: the uids that moved (the others stayed where the user had put them).
    private static func move(_ uids: [String], to: String, from: [String], then: @escaping ([String]) -> Void) {
        Scripts.move(uids, to: to, from: from) { r in
            switch r {
            case .success(let o):
                let moved = (o["moved"] as? [[String: Any]] ?? []).compactMap { $0["uid"] as? String }
                let kept = (o["kept"] as? [Any])?.count ?? 0
                emit(["event": "refile_moved", "to": to, "moved": moved.count, "kept": kept])
                then(moved)
            case .failure(let f):
                emit(["event": "refile_failed", "to": to, "error": f.localized])
                island.toast(Loc.t("capture.move_failed", table: "Capture"), actionTitle: nil, action: nil)
            }
        }
    }

    /// "Moved to Y · Undo", or "3 items moved to Y" when several moved (the main window's words).
    private static func said(_ n: Int, to: String, undo: @escaping () -> Void) {
        moved(n > 1 ? TP("main.move.done", n, name(to)) : Loc.t("capture.moved", table: "Capture", name(to)), to: to, undo: undo)
    }

    private static func moved(_ text: String, to: String, undo: @escaping () -> Void) {
        var t = Island.Toast(text: text, actionTitle: Loc.t("capture.undo", table: "Capture"), action: undo)
        t.badge = badge(to)
        t.seconds = 6
        island.toast(t)
    }
}
