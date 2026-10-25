// BlurtCore/DictationAccess.swift: when the dictation key can't be heard — the menu row, never asking macOS at launch, the
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

    func testNeverAsksMacOSAtLaunch() {
        // macOS is asked (and Blurt listed) only when the user clicks Allow / Set Up — the permission guide
        XCTAssertFalse(DictationAccess.asksAtLaunch)
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

    /// Two Blurts running (a dev build beside the release): the other one has the key — no "needs permission" here,
    /// no launch reminder that leads to a pane with everything granted (v0.9 dogfood).
    func testAnotherBlurtWithTheKeyIsNothingToSetUp() {
        let deferred = DictationAccess(enabled: true, tapInstalled: false, deferred: true)
        XCTAssertFalse(deferred.needsSetup)
        XCTAssertFalse(deferred.nudge(lastNudge: nil, now: Date()))
        XCTAssertTrue(DictationAccess(enabled: true, tapInstalled: false).nudge(lastNudge: nil, now: Date()))
    }

    /// v0.9 dogfood: a first run without the speech model read "✓ Dictation is on". The page says the one step in the
    /// way, and "ready" only when both the key and the model are.
    func testThePageSaysTheOneStepInTheWay() {
        XCTAssertEqual(DictationPageStatus.of(enabled: false, needsSetup: false, modelReady: false, download: nil), .off)
        XCTAssertEqual(DictationPageStatus.of(enabled: true, needsSetup: true, modelReady: false, download: nil), .needsPermission)
        XCTAssertEqual(DictationPageStatus.of(enabled: true, needsSetup: false, modelReady: false, download: nil), .noModel)
        XCTAssertEqual(DictationPageStatus.of(enabled: true, needsSetup: false, modelReady: false, download: (done: 300, total: 2468)),
                       .downloading(done: 300, total: 2468))
        XCTAssertEqual(DictationPageStatus.of(enabled: true, needsSetup: false, modelReady: true, download: nil), .ready)
        // not read yet: no claim either way (the key doesn't wait on it either)
        XCTAssertEqual(DictationPageStatus.of(enabled: true, needsSetup: false, modelReady: nil, download: nil), .ready)
    }

    /// Typeless / Wispr Flow also react to Fn: said when a Fn take starts, once a day per app; never for another key.
    func testAnotherFnAppIsMentionedWhenItMatters() {
        var said: Set<String> = []
        let saidToday = { (a: String) in said.contains(a) }
        XCTAssertEqual(DictationFnClash.toMention(key: .fn, running: ["Typeless"], saidToday: saidToday), ["Typeless"])
        said.insert("Typeless")
        XCTAssertEqual(DictationFnClash.toMention(key: .fn, running: ["Typeless", "Wispr Flow"], saidToday: { said.contains($0) }),
                       ["Wispr Flow"])
        XCTAssertEqual(DictationFnClash.toMention(key: .rightOption, running: ["Wispr Flow"], saidToday: { _ in false }), [])
        XCTAssertEqual(DictationFnClash.toMention(key: .fn, running: [], saidToday: { _ in false }), [])
    }
}
