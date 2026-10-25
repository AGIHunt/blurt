// BlurtCore/SpeechSetup.swift: an offline (or blocked-network) first run is one state everywhere — one sentence and one
// Try Again on the models step, Skip for Now instead of a green Next, no Download button that has nothing to download
// on Try it, a menu row that says dictation isn't set up, and a retry when the Mac comes back online (never a loop).
import Foundation
import XCTest
@testable import BlurtCore

final class SpeechSetupTests: XCTestCase {
    func step(uv: Bool = true, warm: String? = "done", loaded: Bool = true, listRead: Bool = true, downloading: Bool = false,
              failed: Bool = false, ready: Bool = false) -> SpeechSetup.Step {
        SpeechSetup.step(uv: uv, warm: warm, loaded: loaded, listRead: listRead, downloading: downloading, failed: failed, ready: ready)
    }

    func testOfflineIsOneBlockedState() {
        // the speech tools didn't install AND the list couldn't be read (and a download failed): one state, not two errors
        XCTAssertEqual(step(warm: "failed", listRead: false, failed: true), .blocked)
        XCTAssertEqual(step(warm: "failed"), .blocked, "the downloads need the same tools")
        XCTAssertEqual(step(listRead: false), .blocked)
        XCTAssertEqual(step(warm: "running", listRead: false), .blocked)
        // the tools are fine and only a download stopped: its own state (Try Again, or the small model)
        XCTAssertEqual(step(failed: true), .failed)
    }

    func testTheOtherStates() {
        XCTAssertEqual(step(uv: false, warm: "failed", listRead: false), .needsUV)
        XCTAssertEqual(step(warm: "running", loaded: false), .checking)
        XCTAssertEqual(step(warm: "failed", downloading: true), .downloading, "a download running: the network works")
        XCTAssertEqual(step(ready: true), .ready)
        XCTAssertEqual(step(), .offer)
    }

    func testBlockedNeverShowsAGreenNext() {
        for s in [SpeechSetup.Step.needsUV, .blocked, .failed] { XCTAssertTrue(SpeechSetup.pending(s, settled: false), "\(s)") }
        XCTAssertTrue(SpeechSetup.pending(.offer, settled: false))
        XCTAssertFalse(SpeechSetup.pending(.offer, settled: true), "the small model alone came down: the step is done")
        for s in [SpeechSetup.Step.checking, .downloading, .ready] { XCTAssertFalse(SpeechSetup.pending(s, settled: false), "\(s)") }
        // Try Again running: the footer keeps Skip for Now (no flash to Next and back)
        XCTAssertTrue(SpeechSetup.pending(.checking, settled: false, retrying: true))
        XCTAssertGreaterThanOrEqual(SpeechSetup.minimumCheck, 0.8, "an offline retry is seen to run")
    }

    func testTheBlockedSentenceBlamesTheNetworkOnlyWhenOffline() {
        XCTAssertEqual(SpeechSetup.cause(online: false), .offline)
        XCTAssertEqual(SpeechSetup.cause(online: true), .error, "online and still failing: a proxy, a script error — not 'connect'")
        XCTAssertEqual(SpeechSetup.cause(online: nil), .error, "no answer yet is not offline")
    }

    func testOnlyAListThatCantRunStopsDictation() {
        XCTAssertEqual(SpeechSetup.listFailure(timedOut: true, online: false), .timeout)
        XCTAssertEqual(SpeechSetup.listFailure(timedOut: false, online: false), .offline)
        XCTAssertEqual(SpeechSetup.listFailure(timedOut: false, online: true), .error)
        XCTAssertFalse(SpeechSetup.refusesDictation(.timeout), "a cold uv sync after an update: the take goes ahead")
        XCTAssertFalse(SpeechSetup.refusesDictation(nil))
        XCTAssertTrue(SpeechSetup.refusesDictation(.offline))
        XCTAssertTrue(SpeechSetup.refusesDictation(.error))
    }

    func testTryItNeverOffersADownloadThatDoesNothing() {
        XCTAssertEqual(SpeechSetup.tryState(dictationReady: false, dictationDownloading: false, step: .blocked, pendingDownloads: false), .blocked)
        // the list couldn't be read: no set to download, even if the step looks fine
        XCTAssertEqual(SpeechSetup.tryState(dictationReady: false, dictationDownloading: false, step: .offer, pendingDownloads: false), .blocked)
        XCTAssertEqual(SpeechSetup.tryState(dictationReady: false, dictationDownloading: false, step: .offer, pendingDownloads: true), .download)
        XCTAssertEqual(SpeechSetup.tryState(dictationReady: false, dictationDownloading: true, step: .downloading, pendingDownloads: true), .downloading)
        XCTAssertEqual(SpeechSetup.tryState(dictationReady: true, dictationDownloading: false, step: .blocked, pendingDownloads: false), .works)
    }

    func testTheMenuSaysWhyDictationCantWork() {
        func row(enabled: Bool = true, deferred: Bool = false, perms: Bool = false, ready: Bool? = true, readable: Bool = true,
                 downloading: Bool = false) -> SpeechSetup.MenuRow? {
            SpeechSetup.menuRow(enabled: enabled, deferred: deferred, needsPermissions: perms, ready: ready, readable: readable,
                                downloading: downloading)
        }
        XCTAssertNil(row())
        XCTAssertEqual(row(perms: true, ready: false), .turnOn, "the most urgent first")
        XCTAssertEqual(row(ready: nil, readable: false), .setUp)
        XCTAssertEqual(row(ready: false), .getModel)
        XCTAssertNil(row(ready: nil), "not read yet: nothing claimed")
        XCTAssertNil(row(ready: false, downloading: true), "the download's own row says how far")
        XCTAssertNil(row(enabled: false, ready: false))
        XCTAssertNil(row(deferred: true, ready: false), "another Blurt has the key")
    }

    func testRetryOnlyWhenTheMacComesBackOnline() {
        var r = NetworkRetry()
        XCTAssertFalse(r.update(online: true), "starting online is not a change")
        XCTAssertFalse(r.update(online: true))
        XCTAssertFalse(r.update(online: false))
        XCTAssertTrue(r.update(online: true), "offline → online: retry")
        XCTAssertFalse(r.update(online: true), "once")
        var s = NetworkRetry()
        XCTAssertFalse(s.update(online: false))
        XCTAssertTrue(s.update(online: true))
    }
}
