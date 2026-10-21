// The notch island (K7, P5): installed after the other modules (AppEnvironment.installModules) in the menu-bar app;
// sets AppEnvironment.island. A recording started from the chat (no menu-bar app) starts the island on its own.
import AppKit
import BlurtCore

enum IslandModule {
    static func install() {
        AppEnvironment.island = island
        if AppEnvironment.process == nil { AppEnvironment.process = LegacyProcess.run }
        island.start()
        snapper.restore()
    }
}

/// Until AgentHub writes process jobs itself (P4, K4): processing a shots session the v0.6 way — App.process(dir),
/// which runs the whole batch — wrapped in a process job, so the island hatches and cracks the same way. AgentHub
/// reports through `perch.hatch` / `perch.hatched` (its v0.6 calls); those land here. Delete with the old AgentHub.
enum LegacyProcess {
    static var jobs: [String: JobWriter] = [:]

    static func run(_ session: URL, _ captures: [Int]?, _ project: String?) {
        let j = JobWriter(type: .process, project: project, session: session)
        j.setCaptures(captures ?? [])
        j.step("prepare", .running)
        jobs[session.path] = j
        ShotBatch.load(session)?.writeMeta(state: "processing")
        (NSApp.delegate as? App)?.process(session)
    }

    static func finished(_ session: String, ok: Bool) {
        guard let j = jobs.removeValue(forKey: session) else { return }
        j.step("write", ok ? .done : .failed)
        j.finish(ok ? .done : .failed, error: ok ? nil : JobError(code: "unknown", message: "processing failed", hintKey: nil))
    }
}

/// AgentHub's v0.6 calls (`perch.hatch(id:kinds:)`, `perch.hatched(id:ok:)`) — the perch is gone; the island hatches
/// from process jobs now.
struct PerchCalls {
    func hatch(id: String, kinds: [String]) { LegacyProcess.jobs[id]?.step("write", .running) }
    func hatched(id: String, ok: Bool) { LegacyProcess.finished(id, ok: ok) }
}
let perch = PerchCalls()
