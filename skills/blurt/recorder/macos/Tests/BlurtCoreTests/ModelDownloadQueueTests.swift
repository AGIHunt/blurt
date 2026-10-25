// BlurtCore/ModelDownloadQueue.swift: the one model download queue every surface uses — no model twice, one bar over
// the batch, Stop and SIGTERM (15 / uv's 143) are never "failed", and what is left survives a quit or a crash.
import XCTest
@testable import BlurtCore

final class ModelDownloadQueueTests: XCTestCase {
    typealias Job = ModelDownloadQueue.Job
    let asr = Job(id: "qwen3-asr-1.7b-mlx", kind: .dictation, name: "Qwen3-ASR 1.7B", sizeMB: 2468)
    let polish = Job(id: "gemma4-e2b", kind: .polish, name: "Gemma 4 E2B", sizeMB: 3415)
    let note = Job(id: "sensevoice-small", kind: .note, name: "SenseVoice Small", sizeMB: 228)

    func testAModelIsNeverQueuedTwice() {
        var q = ModelDownloadQueue()
        XCTAssertEqual(q.add([asr, polish, note]).map(\.id), [asr.id, polish.id, note.id])
        // Settings → Speech asks for the recogniser the assistant is already fetching: nothing new
        XCTAssertEqual(q.add([asr]), [])
        XCTAssertEqual(q.pending.map(\.id), [asr.id, polish.id, note.id])
        // …asked again "to use it": that sticks to the queued job
        var use = asr
        use.select = true
        XCTAssertEqual(q.add([use]), [])
        XCTAssertTrue(q.pending[0].select)
        XCTAssertEqual(q.next?.id, asr.id)
    }

    func testOneBarOverTheBatch() {
        var q = ModelDownloadQueue()
        q.add([asr, polish])
        var p = q.progress(current: asr.id, line: (1234, 2468))
        XCTAssertEqual(p.total, 2468 + 3415)
        XCTAssertEqual(p.done, 1234, accuracy: 0.5)
        q.finish(asr.id)
        XCTAssertEqual(q.next?.id, polish.id)
        p = q.progress(current: polish.id, line: nil)
        XCTAssertEqual(p.done, 2468)
        XCTAssertEqual(q.remainingMB, 3415)
        // a request while the batch runs joins it (the bar grows)
        q.add([note])
        XCTAssertEqual(q.progress(current: polish.id, line: nil).total, 2468 + 3415 + 228)
        q.finish(polish.id)
        q.finish(note.id)
        XCTAssertFalse(q.active)
        XCTAssertTrue(q.jobs.isEmpty)       // the batch ended: the next request starts a new bar
    }

    func testStopOneOrAll() {
        var q = ModelDownloadQueue()
        q.add([asr, polish, note])
        q.remove(polish.id)
        XCTAssertEqual(q.pending.map(\.id), [asr.id, note.id])
        q.clear()
        XCTAssertFalse(q.active)
    }

    func testAModelRemovedSinceCanComeDownAgain() {
        var q = ModelDownloadQueue()
        q.add([asr, polish])
        q.finish(asr.id)
        XCTAssertEqual(q.add([asr]).map(\.id), [asr.id])
        XCTAssertEqual(q.pending.map(\.id), [polish.id, asr.id])
    }

    func testStopIsNeverAFailure() {
        XCTAssertEqual(ModelDownloadQueue.outcome(status: 0, stopping: false), .done)
        XCTAssertEqual(ModelDownloadQueue.outcome(status: 0, stopping: true), .done)       // it came in anyway
        XCTAssertEqual(ModelDownloadQueue.outcome(status: 15, stopping: false), .stopped)
        XCTAssertEqual(ModelDownloadQueue.outcome(status: 143, stopping: false), .stopped) // uv run passing SIGTERM on
        XCTAssertEqual(ModelDownloadQueue.outcome(status: 1, stopping: true), .stopped)
        XCTAssertEqual(ModelDownloadQueue.outcome(status: 1, stopping: false), .failed)
        XCTAssertEqual(ModelDownloadQueue.outcome(status: 4, stopping: false), .failed)
    }

    func testWhatIsLeftSurvivesAQuit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mdq-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let u = dir.appendingPathComponent("model-downloads.json")
        var q = ModelDownloadQueue()
        q.add([asr, polish], now: 1000)
        q.finish(asr.id)
        q.save(to: u)
        let back = try XCTUnwrap(ModelDownloadQueue.load(from: u))
        XCTAssertEqual(back.pending.map(\.id), [polish.id])
        XCTAssertEqual(back.finished, [asr.id])
        XCTAssertEqual(back.startedAt, 1000)
        // nothing left: the file goes
        q.finish(polish.id)
        q.save(to: u)
        XCTAssertFalse(FileManager.default.fileExists(atPath: u.path))
        XCTAssertNil(ModelDownloadQueue.load(from: u))
    }
}
