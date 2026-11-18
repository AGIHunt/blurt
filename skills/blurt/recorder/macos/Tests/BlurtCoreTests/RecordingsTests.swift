// BlurtCore Recordings: a recording's state from its newest process job, what its row offers, which places list it,
// one row per recording (its job leaves the jobs section), the first thing said in it, the facts from its folder.
// The Windows/Linux app's recordings.test.ts checks the same rules.
import Foundation
import XCTest
@testable import BlurtCore

final class RecordingsTests: XCTestCase {
    private func facts(_ dir: String, project: String = "inbox", created: Double = 100, items: Int = 0, processed: Bool = false,
                       processing: Bool = false, video: Bool = true, videoOnly: Bool = false) -> Recordings.Facts {
        Recordings.Facts(dir: dir, projectID: project, created: created, duration: 60, itemCount: items, processed: processed,
                         processing: processing, video: video ? URL(fileURLWithPath: dir + "/recording.mp4") : nil, videoOnly: videoOnly)
    }

    private func job(_ id: String, _ session: String?, _ state: String, minute: Int, code: String? = nil, items: [String] = [],
                     dismissed: Bool = false, type: String = "process", step: String? = nil) -> Job {
        var o: [String: Any] = ["id": id, "type": type, "state": state, "created": String(format: "2026-11-18T10:%02d:00+08:00", minute),
                                "items": items, "dismissed": dismissed]
        if let session { o["session"] = session }
        if let code { o["error"] = ["code": code, "message": ""] }
        if let step { o["steps"] = [["id": step, "state": "running"]] }
        return JobFold.job(o)!
    }

    func testStateFollowsTheNewestProcessJob() {
        let f = facts("/s/a")
        XCTAssertEqual(Recordings.state(f, jobs: []), .unorganised)
        XCTAssertEqual(Recordings.state(f, jobs: [job("j1", "/s/a", "running", minute: 1, step: "transcribe")]), .organising(job: "j1", step: "transcribe"))
        XCTAssertEqual(Recordings.state(f, jobs: [job("j1", "/s/a", "failed", minute: 1, code: "no_agent")]), .failed(job: "j1", code: "no_agent"))
        // a retry after the failure: the newer run counts
        XCTAssertEqual(Recordings.state(f, jobs: [job("j1", "/s/a", "failed", minute: 1), job("j2", "/s/a", "running", minute: 2)]).name, "organising")
        XCTAssertEqual(Recordings.state(f, jobs: [job("j1", "/s/a", "failed", minute: 1), job("j2", "/s/a", "done", minute: 2, items: ["u1", "u2"])]), .items(2))
        // another folder's job, or a snap job, isn't this recording's
        XCTAssertEqual(Recordings.state(f, jobs: [job("j1", "/s/b", "failed", minute: 1), job("j2", "/s/a", "failed", minute: 2, type: "snap")]), .unorganised)
    }

    func testDismissedVideoOnlyAndWhatTheIndexSays() {
        XCTAssertEqual(Recordings.state(facts("/s/a"), jobs: [job("j1", "/s/a", "failed", minute: 1, dismissed: true)]), .unorganised)
        XCTAssertEqual(Recordings.state(facts("/s/a", videoOnly: true), jobs: []), .videoOnly)
        XCTAssertEqual(Recordings.state(facts("/s/a", processing: true), jobs: []), .organising(job: nil, step: nil))
        XCTAssertEqual(Recordings.state(facts("/s/a", items: 3, processed: true), jobs: []), .items(3))
        XCTAssertEqual(Recordings.state(facts("/s/a", processed: true), jobs: []), .items(0))
    }

    func testWhatARowOffers() {
        let failed = Recordings.rows([facts("/s/a")], jobs: [job("j1", "/s/a", "failed", minute: 1)])[0]
        XCTAssertEqual(Recordings.actions(failed, agent: true), [.retry, .play, .reveal, .progress, .dismiss])
        XCTAssertEqual(Recordings.actions(failed, agent: false), [.setUpAgent, .copyRequest, .play, .reveal, .progress, .dismiss])
        XCTAssertEqual(Recordings.inline(failed, agent: nil), .retry)
        XCTAssertEqual(Recordings.inline(failed, agent: false), .setUpAgent)
        let never = Recordings.rows([facts("/s/a")], jobs: [])[0]
        XCTAssertEqual(Recordings.actions(never, agent: true), [.play, .organise, .reveal])
        XCTAssertEqual(Recordings.inline(never, agent: true), .organise)
        XCTAssertNil(Recordings.inline(never, agent: false))
        let done = Recordings.rows([facts("/s/a", items: 2, processed: true)], jobs: [])[0]
        XCTAssertEqual(Recordings.actions(done, agent: true), [.review, .play, .reveal])
        // the video gone (retention): no Play, nothing to organise
        let gone = Recordings.rows([facts("/s/a", video: false)], jobs: [])[0]
        XCTAssertEqual(Recordings.actions(gone, agent: true), [.reveal])
        XCTAssertNil(Recordings.inline(gone, agent: true))
    }

    func testWhereRecordingsAreListedAndOneRowEach() {
        let fs = [facts("/i/failed", created: 5), facts("/i/never", created: 4), facts("/i/done", created: 3, items: 2, processed: true),
                  facts("/p/running", project: "p1", created: 2), facts("/i/video", created: 1, videoOnly: true)]
        let jobs = [job("j1", "/i/failed", "failed", minute: 1), job("j2", "/p/running", "running", minute: 2), job("j3", "/x/shots", "running", minute: 3)]
        let rows = Recordings.rows(fs, jobs: jobs)
        let dirs = { (p: Recordings.Place) in Recordings.listed(rows, in: p).map(\.facts.dir) }
        XCTAssertEqual(dirs(.needsYou), ["/i/failed", "/p/running"])
        XCTAssertEqual(dirs(.inProgress), ["/p/running"])
        XCTAssertEqual(dirs(.unassigned), ["/i/failed", "/i/never", "/i/video"])
        XCTAssertEqual(dirs(.project("p1")), ["/p/running"])
        XCTAssertEqual(dirs(.other), [])
        XCTAssertEqual(Recordings.jobsBeside(jobs, rows).map(\.id), ["j3"])
    }

    func testFirstLineAndFacts() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d.appendingPathComponent("live"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        XCTAssertNil(Recordings.firstLine(d))
        try #"{"segments":[{"text":" "},{"text":"from the  whole file"}]}"#.write(to: d.appendingPathComponent("transcript.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Recordings.firstLine(d), "from the whole file")
        try "{\"text\":\"\"}\nnot json\n{\"text\":\" 登录页\\n 按钮没反应 \"}\n".write(to: d.appendingPathComponent("live/transcript.jsonl"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Recordings.firstLine(d), "登录页 按钮没反应")

        var s = SessionRow(id: "inbox:x", projectID: "inbox", dir: d.path, mode: "video")
        try #"{"duration": 42.5, "video_only": true}"#.write(to: d.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        let f = try XCTUnwrap(Recordings.facts(s))
        XCTAssertNil(f.video)
        XCTAssertEqual(f.duration, 42.5)
        XCTAssertTrue(f.videoOnly)
        try Data("x".utf8).write(to: d.appendingPathComponent("recording.mp4"))
        XCTAssertNotNil(Recordings.facts(s)?.video)
        // the take being recorded, shots, a legacy session: not recordings
        XCTAssertNil(Recordings.facts(s, live: d))
        s.mode = "shots"
        XCTAssertNil(Recordings.facts(s))
    }
}
