// BlurtCore/ModelDownloadNotice.swift: the first run's background download is said wherever the user is — the
// island once as it starts, the assistant's quiet line, Home's Dictation row — with a Stop, and a Stop is remembered.
import XCTest
@testable import BlurtCore

final class ModelDownloadNoticeTests: XCTestCase {
    typealias Job = ModelDownloadQueue.Job
    let asr = Job(id: "qwen3-asr-1.7b-mlx", kind: .dictation, name: "Qwen3-ASR 1.7B", sizeMB: 2468)
    let polish = Job(id: "gemma4-e2b", kind: .polish, name: "Gemma 4 E2B", sizeMB: 3415)

    func testOnlyTheBatchNobodyAskedForGoesUpOnTheIsland() {
        XCTAssertTrue(ModelDownloadNotice.announcesStart(via: "install"))
        // asked for on a surface that shows its own bar
        for via in ["onboarding", "settings", "dictation", "launch", "test"] {
            XCTAssertFalse(ModelDownloadNotice.announcesStart(via: via), via)
        }
        // said at the start: closing the assistant doesn't say it again
        XCTAssertFalse(ModelDownloadNotice.saysCarryOn(startSaid: true))
        XCTAssertTrue(ModelDownloadNotice.saysCarryOn(startSaid: false))
    }

    func testTheAssistantsLineNeverDoublesABar() {
        XCTAssertTrue(ModelDownloadNotice.assistantLine(downloading: true, modelsStep: false, tryShowsBar: false))
        XCTAssertFalse(ModelDownloadNotice.assistantLine(downloading: true, modelsStep: true, tryShowsBar: false), "the models step has its bar")
        XCTAssertFalse(ModelDownloadNotice.assistantLine(downloading: true, modelsStep: false, tryShowsBar: true), "Try it shows the recogniser's bar")
        XCTAssertFalse(ModelDownloadNotice.assistantLine(downloading: false, modelsStep: false, tryShowsBar: false))
    }

    func testWorksNowIsOnlySaidWhenMacOSDictates() {
        XCTAssertTrue(ModelDownloadNotice.saysPurpose(systemReady: true, dictationReady: true))
        XCTAssertTrue(ModelDownloadNotice.saysPurpose(systemReady: true, dictationReady: nil), "the list not read yet")
        // macOS 13–15, a language it doesn't speak, its files still coming, or dictation picked a model still missing
        XCTAssertFalse(ModelDownloadNotice.saysPurpose(systemReady: false, dictationReady: true))
        XCTAssertFalse(ModelDownloadNotice.saysPurpose(systemReady: true, dictationReady: false))
    }

    func testHomesDictationLine() {
        func home(ready: Bool? = true, downloading: Bool = false, unpacking: Bool = false, automatic: Bool = true,
                  betterMissing: Bool = true, missingMB: Double = 5883, failed: Bool = false) -> ModelDownloadNotice.HomeLine {
            ModelDownloadNotice.home(ready: ready, downloading: downloading, unpacking: unpacking, progress: (1200, 5883),
                                     automatic: automatic, betterMissing: betterMissing, missingMB: missingMB, failed: failed)
        }
        // running: the batch's own numbers (the menu row's), Stop
        XCTAssertEqual(home(downloading: true), .downloading(done: 1200, total: 5883))
        XCTAssertEqual(home(downloading: true, unpacking: true), .unpacking)
        // stopped (or never fetched): the offer, with what is left to fetch
        XCTAssertEqual(home(), .offer(mb: 5883))
        // broke off: the retry wording
        XCTAssertEqual(home(failed: true), .interrupted)
        // the recommended recogniser is in, a model chosen by hand, nothing left: what dictation does
        XCTAssertEqual(home(betterMissing: false), .usual)
        XCTAssertEqual(home(automatic: false), .usual)
        XCTAssertEqual(home(missingMB: 0), .usual)
        // dictation itself waits for its model (or isn't read yet): the row's own words, not "more accurate"
        XCTAssertEqual(home(ready: false, downloading: true), .usual)
        XCTAssertEqual(home(ready: nil), .usual)
    }

    func testAStopIsRememberedAtOnceAndAQuitStillResumes() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("notice-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: u) }
        var q = ModelDownloadQueue()
        q.add([asr, polish])
        q.save(to: u)
        // a quit or a crash mid-download: the file stays, the next launch carries on
        XCTAssertEqual(try XCTUnwrap(ModelDownloadQueue.load(from: u)).pending.map(\.id), [asr.id, polish.id])
        // Stop for everything while the recogniser runs: written at once — nothing comes back at the next launch, even
        // when the app quits before the setup has ended
        q.afterStop(.all([polish.id]), running: asr.id).save(to: u)
        XCTAssertNil(ModelDownloadQueue.load(from: u))
        XCTAssertFalse(FileManager.default.fileExists(atPath: u.path))
        // Stop for one model: the rest still carries on after a quit
        q.afterStop(.one(asr.id), running: asr.id).save(to: u)
        XCTAssertEqual(try XCTUnwrap(ModelDownloadQueue.load(from: u)).pending.map(\.id), [polish.id])
        // no Stop: as it is
        XCTAssertEqual(q.afterStop(.none, running: asr.id), q)
    }
}
