// BlurtCore/ReviewLink.swift: review.py's handshake addresses, and the capped byte ranges the review canvas is served
// with.
import Foundation
import XCTest
@testable import BlurtCore

final class ReviewLinkTests: XCTestCase {
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
