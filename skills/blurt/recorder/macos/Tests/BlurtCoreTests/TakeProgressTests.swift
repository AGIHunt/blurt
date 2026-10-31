// BlurtCore TakeProgress: the recording island's plain counts and where the items go (BA-64), and how long organizing
// usually takes on this Mac, measured from its own past runs (BA-61).
import XCTest
@testable import BlurtCore

final class TakeLineTests: XCTestCase {
    override func tearDown() { Loc.setting = nil }

    func testPartsLeaveOutZeroesInAFixedOrder() {
        XCTAssertEqual(TakeLine.parts(snaps: 0, items: 0), [])
        XCTAssertEqual(TakeLine.parts(snaps: 6, items: 4), [.snaps(6), .items(4)])
        XCTAssertEqual(TakeLine.parts(snaps: 0, items: 1), [.items(1)])
    }

    func testTheLineSaysSnapsAndItemsInPlainWords() {
        Loc.setting = "zh-Hans"
        XCTAssertEqual(TakeLine.text(snaps: 6, items: 4), "截图 6 张 · 已识别 4 个事项")
        XCTAssertEqual(TakeLine.whereTo(project: "Atlas Web", organizes: true, anything: true), "点完成后整理到 Atlas Web")
        Loc.setting = "en"
        XCTAssertEqual(TakeLine.text(snaps: 1, items: 4), "1 snap · 4 items spotted")
        XCTAssertEqual(TakeLine.text(snaps: 0, items: 0), "")
        XCTAssertEqual(TakeLine.whereTo(project: "Atlas Web", organizes: true, anything: true), "Organized into Atlas Web when you finish")
    }

    func testWhereIsSaidOnlyWhenSomethingWillBeOrganized() {
        XCTAssertNil(TakeLine.whereTo(project: "X", organizes: false, anything: true))      // record.process off: only saved
        XCTAssertNil(TakeLine.whereTo(project: "X", organizes: true, anything: false))      // nothing counted yet
    }
}

final class OrganizeEstimateTests: XCTestCase {
    typealias Run = OrganizeEstimate.Run

    func testNoEstimateWithoutThreeMeasuredRuns() {
        XCTAssertNil(OrganizeEstimate.seconds(video: 120, past: []))
        XCTAssertNil(OrganizeEstimate.seconds(video: 120, past: [Run(video: 60, took: 200), Run(video: 300, took: 400)]))
        // runs too short to mean anything don't count
        XCTAssertNil(OrganizeEstimate.seconds(video: 120, past: [Run(video: 60, took: 200), Run(video: 300, took: 400), Run(video: 2, took: 1)]))
    }

    func testALineThroughThePastRuns() throws {
        // 100 s + 1 s per second of video, exactly
        let past = [Run(video: 60, took: 160), Run(video: 300, took: 400), Run(video: 600, took: 700)]
        XCTAssertEqual(try XCTUnwrap(OrganizeEstimate.seconds(video: 120, past: past)), 220, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(OrganizeEstimate.seconds(video: 1200, past: past)), 1300, accuracy: 0.01)
    }

    func testOneOddRunDoesNotMoveIt() throws {
        let past = [Run(video: 60, took: 160), Run(video: 300, took: 400), Run(video: 600, took: 700), Run(video: 200, took: 3000),
                    Run(video: 900, took: 1000)]
        XCTAssertEqual(try XCTUnwrap(OrganizeEstimate.seconds(video: 120, past: past)), 220, accuracy: 30)
    }

    func testNeverBelowTheQuickestRunNorASlopeBelowZero() throws {
        // longer videos took less (noise): no negative slope, and not less than the quickest run seen
        let past = [Run(video: 60, took: 300), Run(video: 300, took: 250), Run(video: 600, took: 200)]
        let e = try XCTUnwrap(OrganizeEstimate.seconds(video: 3000, past: past))
        XCTAssertGreaterThanOrEqual(e, 200)
    }

    func testMinutesAndWhatIsLeft() {
        XCTAssertEqual(OrganizeEstimate.minutes(20), 1)
        XCTAssertEqual(OrganizeEstimate.minutes(250), 4)
        XCTAssertEqual(OrganizeEstimate.minutesLeft(usual: 240, elapsed: 60), 3)
        XCTAssertNil(OrganizeEstimate.minutesLeft(usual: 240, elapsed: 230))        // past it: no made-up figure
        XCTAssertNil(OrganizeEstimate.minutesLeft(usual: 240, elapsed: 400))
    }
}

/// BA-60: an island button's title is centred on its optical middle — CJK titles by their ink, Latin ones on the
/// cap-height band (where they were before).
final class TextOpticalCentreTests: XCTestCase {
    let font = CTFontCreateUIFontForLanguage(.system, 12.5, nil)!

    func testIdeographicTitlesAreCentredByTheirInk() throws {
        let l = try XCTUnwrap(TextImage.line("完成", font: font, color: CGColor(gray: 1, alpha: 1), scale: 2))
        XCTAssertTrue(l.ideographic)
        XCTAssertGreaterThan(l.inkBottom, l.inkTop)
        // in a 28 pt button: as much room above the ink as below it (within a pixel)
        let top = l.top(centredOn: 14, scale: 2)
        let above = top + l.inkTop, below = 28 - (top + l.inkBottom)
        XCTAssertEqual(above, below, accuracy: 0.5)
    }

    func testLatinTitlesStayOnTheCapBand() throws {
        let l = try XCTUnwrap(TextImage.line("Finish", font: font, color: CGColor(gray: 1, alpha: 1), scale: 2))
        XCTAssertFalse(l.ideographic)
        // the cap band's middle is (about) the typographic box's: Latin titles don't move
        XCTAssertEqual(l.opticalMid, l.size.height / 2, accuracy: 1.0)
        let top = l.top(centredOn: 14, scale: 2)
        XCTAssertEqual(top + l.capTop - 0, 28 - (top + l.baseline), accuracy: 0.5)
    }

    func testIdeographDetection() {
        XCTAssertTrue(TextImage.isIdeographic("完成"))
        XCTAssertTrue(TextImage.isIdeographic("Save 视频"))
        XCTAssertFalse(TextImage.isIdeographic("Finish ✓"))
    }
}
