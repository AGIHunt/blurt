// BlurtCore/DictationAccess.swift: when the dictation key can't be heard — the menu row, asking macOS at launch, the
// island's reminder (about once a day) and the "dictation is on" word once the tap comes up.
import XCTest
@testable import BlurtCore

final class DictationAccessTests: XCTestCase {
    private let off = DictationAccess(enabled: false, tapInstalled: false)
    private let deaf = DictationAccess(enabled: true, tapInstalled: false)
    private let ok = DictationAccess(enabled: true, tapInstalled: true)

    func testNeedsSetupFollowsTheTapNotThePermission() {
        XCTAssertTrue(deaf.needsSetup)
        XCTAssertFalse(ok.needsSetup)
        XCTAssertFalse(off.needsSetup)                          // dictation turned off: no cue at all
    }

    func testAsksMacOSOncePerVersionAndNotOverTheAssistant() {
        XCTAssertTrue(deaf.askAtLaunch(assistantShowing: false, askedVersion: nil, version: "0.8.0"))
        XCTAssertFalse(deaf.askAtLaunch(assistantShowing: false, askedVersion: "0.8.0", version: "0.8.0"))
        XCTAssertTrue(deaf.askAtLaunch(assistantShowing: false, askedVersion: "0.7.2", version: "0.8.0"))   // an update asks again
        XCTAssertFalse(deaf.askAtLaunch(assistantShowing: true, askedVersion: nil, version: "0.8.0"))
        XCTAssertFalse(ok.askAtLaunch(assistantShowing: false, askedVersion: nil, version: "0.8.0"))
        XCTAssertFalse(off.askAtLaunch(assistantShowing: false, askedVersion: nil, version: "0.8.0"))
    }

    func testNudgeAboutOnceADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(deaf.nudge(lastNudge: nil, now: now))
        XCTAssertFalse(deaf.nudge(lastNudge: now.addingTimeInterval(-3600), now: now))
        XCTAssertFalse(deaf.nudge(lastNudge: now.addingTimeInterval(-19 * 3600), now: now))
        XCTAssertTrue(deaf.nudge(lastNudge: now.addingTimeInterval(-21 * 3600), now: now))
        XCTAssertTrue(deaf.nudge(lastNudge: now.addingTimeInterval(3600), now: now))      // clock set back
        XCTAssertFalse(ok.nudge(lastNudge: nil, now: now))
        XCTAssertFalse(off.nudge(lastNudge: nil, now: now))
        XCTAssertTrue(deaf.nudge(lastNudge: now.addingTimeInterval(-10), now: now, every: 5))
    }

    func testConfirmOnlyWhenTheTapComesUp() {
        XCTAssertTrue(DictationAccess.confirm(before: deaf, after: ok))
        XCTAssertFalse(DictationAccess.confirm(before: ok, after: ok))
        XCTAssertFalse(DictationAccess.confirm(before: deaf, after: deaf))
        XCTAssertFalse(DictationAccess.confirm(before: off, after: ok))     // turning it on with the permission there: no "now on"
    }
}
