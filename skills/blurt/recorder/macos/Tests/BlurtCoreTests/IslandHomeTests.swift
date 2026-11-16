// BlurtCore/IslandHome.swift: what the island under the notch shows for a set of capability switches — off means
// gone: no project, no Organize and no Inbox without Recording & Items; no snap or voice button and no cards without
// Cards; and nothing to open when neither is on.
import XCTest
@testable import BlurtCore

final class IslandHomeTests: XCTestCase {
    func testEverythingOnIsTheIslandAsItWas() {
        let idle = IslandHome.rows(off: [], jobs: 0, cards: 0, review: 0)
        XCTAssertTrue(idle.projectChip)
        XCTAssertEqual(idle.buttons, [.record, .snap, .voice])
        XCTAssertEqual(idle.hints, [.snap, .voice, .project])
        let busy = IslandHome.rows(off: [], jobs: 2, cards: 3, review: 8)
        XCTAssertEqual(busy.jobs, 2)
        XCTAssertEqual(busy.cards, 3)
        XCTAssertTrue(busy.organize)
        XCTAssertEqual(busy.inbox, 8)
        XCTAssertEqual(busy.hints, [], "the keys are said only when nothing is going on")
    }

    func testRecordingOffLeavesNoProjectNoOrganizeNoInbox() {
        let r = IslandHome.rows(off: [.recording], jobs: 2, cards: 3, review: 8)
        XCTAssertFalse(r.projectChip)
        XCTAssertEqual(r.buttons, [.snap, .voice])
        XCTAssertEqual(r.jobs, 0)
        XCTAssertEqual(r.cards, 3, "the cards still hang")
        XCTAssertFalse(r.organize)
        XCTAssertEqual(r.inbox, 0)
        // items waiting and jobs listed from before don't keep the keys' line away
        let idle = IslandHome.rows(off: [.recording], jobs: 1, cards: 0, review: 8)
        XCTAssertTrue(idle.isIdle)
        XCTAssertEqual(idle.hints, [.snap, .voice])
    }

    func testCardsOffLeavesNoSnapNoVoiceNoCards() {
        let r = IslandHome.rows(off: [.cards], jobs: 1, cards: 3, review: 8)
        XCTAssertTrue(r.projectChip)
        XCTAssertEqual(r.buttons, [.record])
        XCTAssertEqual(r.jobs, 1)
        XCTAssertEqual(r.cards, 0, "cards hung before stay stored, but not here")
        XCTAssertFalse(r.organize)
        XCTAssertEqual(r.inbox, 8)
        let idle = IslandHome.rows(off: [.cards], jobs: 0, cards: 3, review: 0)
        XCTAssertEqual(idle.hints, [.record, .project])
    }

    func testDictationScreenTextAndPhoneHaveNothingOnTheHome() {
        let all = IslandHome.rows(off: [], jobs: 1, cards: 2, review: 3)
        XCTAssertEqual(IslandHome.rows(off: [.dictation, .screenText, .phone], jobs: 1, cards: 2, review: 3), all)
    }

    func testWithNeitherRecordingNorCardsTheIslandDoesNotOpen() {
        for off: Set<Capability> in [[.recording, .cards], [.recording, .cards, .screenText, .phone], Set(Capability.allCases)] {
            XCTAssertFalse(IslandHome.opens(off: off), "\(off)")
            let r = IslandHome.rows(off: off, jobs: 3, cards: 4, review: 5)
            XCTAssertFalse(r.projectChip)
            XCTAssertEqual(r.buttons, [])
            XCTAssertTrue(r.isIdle)
            XCTAssertEqual(r.hints, [])
        }
        XCTAssertTrue(IslandHome.opens(off: []))
        XCTAssertTrue(IslandHome.opens(off: [.recording]))
        XCTAssertTrue(IslandHome.opens(off: [.cards]))
        XCTAssertTrue(IslandHome.opens(off: [.dictation, .screenText, .phone]))
    }

    func testTheDropDrawer() {
        XCTAssertTrue(IslandHome.drop(off: []).hang)
        XCTAssertTrue(IslandHome.drop(off: []).projects)
        // Recording off: another app's files still hang as cards, but there is no project to drop anything on
        XCTAssertTrue(IslandHome.drop(off: [.recording]).hang)
        XCTAssertFalse(IslandHome.drop(off: [.recording]).projects)
        // Cards off: the notch takes no drag from another app
        XCTAssertFalse(IslandHome.drop(off: [.cards]).hang)
    }

    func testNegativeCountsAreNothing() {
        let r = IslandHome.rows(off: [], jobs: -1, cards: -2, review: -3)
        XCTAssertEqual([r.jobs, r.cards, r.inbox], [0, 0, 0])
        XCTAssertTrue(r.isIdle)
    }
}
