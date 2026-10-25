// "Filed to X · Change" (K2, v0.9): the moment something is captured, the island says where it went, and Change puts
// it somewhere else — the user's call, cheap, right there. Change opens the island's project switcher in its pick form
// (Island.Pick: the same rows, type to filter; the current project stays as it is). Nothing ever moves on Blurt's own.
//
//   a recording, as it ends   "Filed to Atlas Web · Change" (or "Filed to Unassigned · Change"). While it is still
//                             being organized only its meta.json "project" changes — the items are written there —
//                             and the organizing run's end moves any that landed elsewhere (organized(_:)); once
//                             its items exist they are moved (items.py move, the user's own move).
//   a capture filed           "Filed to Atlas Web · AW-14 · Change" (a snap with a note, a card dropped on a project):
//                             its items are moved.
// Either way the island then says "Moved to Y · Undo"; Undo puts it back where it was, the same way.
import AppKit
import BlurtCore

enum Refile {
    /// Recordings whose project was changed while they were still being organized: session path → project id | inbox
    private static var pending: [String: String] = [:]

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
            pick(title: Loc.t("capture.drawer.refile_recording", table: "Capture"), current: where_) { to in
                recording(dir, to: to, from: where_)
            }
        }
        t.badge = badge(where_)
        t.seconds = 8
        t.key = "refile.\(dir.path)"
        island.toast(t)
    }

    /// The recording `dir` now goes to `to` (a project id or "inbox"), from `from`.
    static func recording(_ dir: URL, to: String, from: String) {
        guard to != from else { return }
        updateMeta(dir) { $0["project"] = to == "inbox" ? NSNull() : to }
        let uids = batchItems(dir)
        let running = JobStore.shared.active.contains { $0.type == .process && $0.session?.standardizedFileURL.path == dir.standardizedFileURL.path }
        emit(["event": "refile_recording", "session": dir.path, "to": to, "from": from, "items": uids.count, "running": running])
        if running { pending[dir.path] = to }
        let done = { moved(Loc.t("capture.moved", table: "Capture", name(to)), to: to) { recording(dir, to: from, from: to) } }
        guard !uids.isEmpty else { return done() }
        move(uids, to: to, then: done)
    }

    /// An organizing run is over (AgentHub): a recording re-filed while it ran gets its items where the user said.
    static func organized(_ dir: URL) {
        guard let to = pending.removeValue(forKey: dir.path) else { return }
        let uids = batchItems(dir)
        let here = Set(((try? IndexReader(url: BlurtPaths.indexDB)).flatMap { try? $0.items(uids: uids) } ?? [])
            .filter { $0.projectID == to }.map(\.uid))
        let off = uids.filter { !here.contains($0) }
        emit(["event": "refile_after_run", "session": dir.path, "to": to, "moving": off.count])
        if !off.isEmpty { move(off, to: to) {} }
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
        pick(title: Loc.t("capture.drawer.refile_items", table: "Capture"), current: from) { to in move(uids, to: to, from: from) }
    }

    private static func move(_ uids: [String], to: String, from: String) {
        guard to != from, !uids.isEmpty else { return }
        emit(["event": "refile_items", "items": uids.count, "to": to, "from": from])
        move(uids, to: to) {
            moved(Loc.t("capture.moved", table: "Capture", name(to)), to: to) { move(uids, to: from, from: to) }
        }
    }

    // MARK: the parts

    private static func pick(title: String, current: String, choose: @escaping (String) -> Void) {
        island.showPicker(Island.Pick(title: title, current: current, choose: choose))
    }

    private static func move(_ uids: [String], to: String, then: @escaping () -> Void) {
        Scripts.move(uids, to: to) { r in
            switch r {
            case .success: then()
            case .failure(let f):
                emit(["event": "refile_failed", "to": to, "error": f.localized])
                island.toast(Loc.t("capture.move_failed", table: "Capture"), actionTitle: nil, action: nil)
            }
        }
    }

    private static func moved(_ text: String, to: String, undo: @escaping () -> Void) {
        var t = Island.Toast(text: text, actionTitle: Loc.t("capture.undo", table: "Capture"), action: undo)
        t.badge = badge(to)
        t.seconds = 6
        island.toast(t)
    }
}
