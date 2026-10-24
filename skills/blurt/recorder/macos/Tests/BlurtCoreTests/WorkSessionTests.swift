// BlurtCore/Sessions/WorkSession.swift: an item's session (live / ended / gone), the host bridge's openSession
// payload, review.py's handshake addresses, and the capped byte ranges the review canvas is served with.
import Foundation
import XCTest
@testable import BlurtCore

final class WorkSessionTests: XCTestCase {
    func job(_ id: String, state: String = "running", status: String = "running", type: String = "agent") -> Job {
        JobFold.job(["id": id, "type": type, "state": state, "created": "2026-10-24T10:00:00+08:00",
                     "agent": ["id": "claude", "status": status, "cwd": "/tmp"]])!
    }

    func testStates() {
        let jobs = ["j-live": job("j-live", status: "waiting_input"), "j-exit": job("j-exit", state: "done", status: "exited"),
                    "j-crash": job("j-crash", state: "failed", status: "exited"), "j-stale": job("j-stale", status: "exited"),
                    "j-rec": job("j-rec", type: "record")]
        func of(_ state: String, _ to: String?, _ id: String?) -> WorkSession? {
            WorkSession.of(state: state, to: to, job: id) { jobs[$0] }
        }
        XCTAssertEqual(of("in_progress", "session", "j-live"), .live(.waitingInput))
        XCTAssertEqual(of("in_progress", "session", "j-exit"), .ended(.exited))
        XCTAssertEqual(of("in_progress", nil, "j-crash"), .ended(.error))      // a failed job crashed, whatever the status says
        XCTAssertEqual(of("handed_off", "session", "j-stale"), .ended(.exited))  // the monitor hasn't finished it yet
        XCTAssertEqual(of("in_progress", nil, "r-20261021-212222-xw1r"), .gone)  // a v0.6 run id
        XCTAssertEqual(of("in_progress", "session", nil), .gone)              // the id was forgotten (items.py migrate)
        XCTAssertEqual(of("to_verify", "session", "j-rec"), .gone)              // not an agent session
        XCTAssertNil(of("in_progress", "external", nil))                        // the user's own agent
        XCTAssertNil(of("done", "session", "j-live"))
        XCTAssertNil(of("todo", nil, nil))
        XCTAssertFalse(WorkSession.gone.canOpen)
        XCTAssertTrue(WorkSession.ended(.exited).canOpen)
    }

    /// The exact payload web/packages/review's macos host sends (test/hosts.test.ts asserts the same shape).
    func testOpenSessionPayload() {
        XCTAssertEqual(ReviewHostParams.job(["job": "j-20261022-101500-ab12"]), "j-20261022-101500-ab12")
        XCTAssertEqual(ReviewHostParams.job(["jobId": "j-1"]), "j-1")
        XCTAssertNil(ReviewHostParams.job(["job": ""]))
        XCTAssertNil(ReviewHostParams.job([:]))
    }

    func testReviewLinkOnlyCallsReviewPy() {
        let base = "http://127.0.0.1:51086/r/tok123/"
        XCTAssertEqual(ReviewLink.endpoint(base, "api/attached")?.absoluteString, "http://127.0.0.1:51086/r/tok123/api/attached")
        XCTAssertEqual(ReviewLink.endpoint("http://localhost:9/r/t/", "api/done")?.absoluteString, "http://localhost:9/r/t/api/done")
        for bad in ["https://127.0.0.1:51086/r/tok/", "http://example.com:51086/r/tok/", "http://127.0.0.1/r/tok/",
                    "http://127.0.0.1:51086/", "http://127.0.0.1:51086/r/tok", "http://127.0.0.1:1/r/t/?x=1", "not a url"] {
            XCTAssertNil(ReviewLink.endpoint(bad, "api/done"), bad)
        }
    }

    func testByteRanges() {
        let mb = 1 << 20
        XCTAssertEqual(ByteRange.plan("bytes=2-4", size: 10), 2...4)
        XCTAssertEqual(ByteRange.plan("bytes=0-", size: 400 * mb), 0...(8 * mb - 1))   // open-ended: capped, not 400 MB
        XCTAssertEqual(ByteRange.plan("bytes=0-", size: 10), 0...9)
        XCTAssertEqual(ByteRange.plan("bytes=-3", size: 10), 7...9)
        XCTAssertEqual(ByteRange.plan("bytes=5-100", size: 10), 5...9)
        XCTAssertEqual(ByteRange.plan("bytes=100-", size: 400 * mb), 100...(100 + 8 * mb - 1))
        XCTAssertNil(ByteRange.plan("bytes=10-", size: 10))
        XCTAssertNil(ByteRange.plan("bytes=5-2", size: 10))
        XCTAssertNil(ByteRange.plan("bytes=x-", size: 10))
        XCTAssertNil(ByteRange.plan("bytes=0-", size: 0))
    }
}
