// BlurtCore CaptureExclusion: Blurt's own windows are captured like any app's; a recording leaves out only the
// countdown, the frame round the area and (with "Don't record the notch") the island and its caption; a snap leaves
// out only its own chrome (the picker's overlay, the flash / flight windows).
import XCTest
@testable import BlurtCore

final class CaptureExclusionTests: XCTestCase {
    func testARecordingKeepsBlurtAndLeavesOutOnlyItsOwnMarks() {
        for w in OwnWindow.allCases {
            let out = CaptureExclusion.leftOutOfRecording(w, hideNotch: false)
            switch w {
            case .countdown, .recordingFrame: XCTAssertTrue(out, "\(w)")
            case .island, .islandCaption, .snapChrome, .other: XCTAssertFalse(out, "\(w) is recorded")
            }
        }
    }

    func testDontRecordTheNotchLeavesOutTheIslandAndItsCaptionOnly() {
        let out = OwnWindow.allCases.filter { CaptureExclusion.leftOutOfRecording($0, hideNotch: true) }
        XCTAssertEqual(Set(out), [.countdown, .recordingFrame, .island, .islandCaption])
        // the snap flow during a take is part of the video either way
        XCTAssertFalse(CaptureExclusion.leftOutOfRecording(.snapChrome, hideNotch: true))
    }

    func testASnapShowsTheIslandCardsAndWindowsAndLeavesOutOnlyThePicker() {
        XCTAssertEqual(OwnWindow.allCases.filter(CaptureExclusion.leftOutOfSnap), [.snapChrome])
        // the notch setting is about recordings only: a snap never reads it
        XCTAssertFalse(CaptureExclusion.leftOutOfSnap(.island))
        XCTAssertFalse(CaptureExclusion.leftOutOfSnap(.countdown))
    }

    func testWindowIdSets() {
        let ws: [(id: UInt32, kind: OwnWindow)] = [(1, .other), (2, .island), (3, .countdown), (4, .recordingFrame), (5, .snapChrome),
                                                   (6, .islandCaption), (7, .other)]
        XCTAssertEqual(CaptureExclusion.recordingExclusions(ws, hideNotch: false), [3, 4])
        XCTAssertEqual(CaptureExclusion.recordingExclusions(ws, hideNotch: true), [2, 3, 4, 6])
        XCTAssertEqual(CaptureExclusion.snapExclusions(ws), [5])
        XCTAssertEqual(CaptureExclusion.snapExclusions(ws, keep: [5]), [])
    }

    func testIdentifiersAreDistinct() {
        XCTAssertEqual(Set(OwnWindow.allCases.map(\.rawValue)).count, OwnWindow.allCases.count)
        XCTAssertEqual(OwnWindow(rawValue: "blurt.countdown"), .countdown)
        XCTAssertNil(OwnWindow(rawValue: "NSWindow"))
    }
}

/// Clicks reach a recording's log from two monitors now (other apps, Blurt's own windows): each once.
final class ClickLogTests: XCTestCase {
    func testTheSameEventIsLoggedOnce() {
        var c = ClickLog()
        XCTAssertTrue(c.fresh(time: 10.0, button: "left"))
        XCTAssertFalse(c.fresh(time: 10.0, button: "left"))        // seen by the other monitor too
        XCTAssertTrue(c.fresh(time: 10.0, button: "right"))
        XCTAssertTrue(c.fresh(time: 10.3, button: "right"))        // a second click
        XCTAssertTrue(c.fresh(time: 10.6, button: "left"))
    }
}
