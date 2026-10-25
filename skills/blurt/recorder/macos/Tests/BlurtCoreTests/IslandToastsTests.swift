// BlurtCore/IslandToasts.swift: dictation's toasts end with what they describe, one line for "copied, not sent", what a
// discarded recording takes with it, and a card's name.
import XCTest
@testable import BlurtCore

final class IslandToastsTests: XCTestCase {
    /// The dogfood: the 5-minute limit over a new take that listens, the last take's tip over the next one, and
    /// "⇧ to go back" after ⇧ stopped meaning anything.
    func testANewTakeDropsWhatWasSaidAboutTheLastOne() {
        let start = Set(DictationToastKeys.droppedAtStart)
        XCTAssertTrue(start.isSuperset(of: [DictationToastKeys.take, DictationToastKeys.tip, DictationToastKeys.listening]))
        // still true across a new take: a failed take's Retry, "Cancelled · Undo", the model's Download…, and the
        // once-a-day notices (their day is spent when posted: dropped, they wouldn't come back until tomorrow)
        XCTAssertFalse(start.contains(DictationToastKeys.notice))
        XCTAssertNotEqual(DictationToastKeys.tip, DictationToastKeys.notice)
        XCTAssertFalse(start.contains(DictationToastKeys.cancel))
        XCTAssertFalse(start.contains(DictationToastKeys.model))
        XCTAssertFalse(start.contains { $0.hasPrefix("dictation.failed.") })
        XCTAssertEqual(DictationToastKeys.droppedWhenListeningEnds, [DictationToastKeys.style])
        XCTAssertFalse(start.contains(DictationToastKeys.style), "⇧'s line belongs to the take that listens")
    }

    /// "No polish model yet · Download…" waits behind "Copied"; the user starts the next take at once. The tip goes,
    /// the notice is still there when the island is free.
    func testAOnceADayNoticeWaitingBehindAReplySurvivesTheNextTake() {
        let q = ToastQueue<Int>()
        _ = q.post(.init(1, text: "Copied", key: DictationToastKeys.take, seconds: 5), now: 0)
        _ = q.post(.init(2, text: "No polish model yet", key: DictationToastKeys.notice, kind: .passive, seconds: 6,
                         actionable: true), now: 0.1)
        _ = q.post(.init(3, text: "Double-tap ⌥ to send", key: DictationToastKeys.tip, kind: .passive, seconds: 3), now: 0.2)
        DictationToastKeys.droppedAtStart.forEach { q.drop(key: $0) }
        let left = ([q.current].compactMap { $0 } + q.waiting).map(\.key)
        XCTAssertEqual(left, [DictationToastKeys.notice])
    }

    /// A double tap after the app changed: "Not sent" was replaced in the same frame by "Copied — paste with ⌘V".
    func testCopiedAndNotSentIsOneLine() {
        XCTAssertEqual(DictationCopyToast.key(copied: true, appChanged: true, sendWanted: true), "dictation.toast.not_sent.copied")
        XCTAssertEqual(DictationCopyToast.key(copied: true, appChanged: true, sendWanted: false), "dictation.toast.copied_app")
        XCTAssertEqual(DictationCopyToast.key(copied: true, appChanged: false, sendWanted: false), "dictation.toast.copied")
        XCTAssertNil(DictationCopyToast.key(copied: false, appChanged: false, sendWanted: true))
        XCTAssertTrue(DictationCopyToast.checked("dictation.toast.copied"), "a done line carries the ok check")
        XCTAssertFalse(DictationCopyToast.checked("dictation.toast.not_sent.copied"))
    }

    /// "Discard this recording and its 3 snaps?" for one still and two markers.
    func testADiscardedRecordingCountsSnapsAndMarkersApart() {
        XCTAssertEqual(RecordingDiscard.lost(stills: 1, markers: 2), [.snaps(1), .markers(2)])
        XCTAssertEqual(RecordingDiscard.lost(stills: 0, markers: 2), [.markers(2)])
        XCTAssertEqual(RecordingDiscard.lost(stills: 0, markers: 0), [])
    }

    func testACardIsNamedByItsWordsNeverACounter() {
        XCTAssertEqual(CardName.words("Price is wrong\nsecond line"), "Price is wrong")
        XCTAssertNil(CardName.words(nil))
        XCTAssertNil(CardName.words("  \n"))
        let long = String(repeating: "a", count: 80)
        XCTAssertEqual(CardName.words(long)?.count, CardName.maxLength)
        XCTAssertEqual(CardName.words(long)?.last, "…")
    }

    /// The review: "Snap · 19:03" ignored a 12-hour clock and an older card (cards hang until used) had no day.
    func testACardsTimeFollowsTheUsersClockAndSaysItsDayOnceItIsntToday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()                  // (a relative day is said against the real today)
        let start = cal.startOfDay(for: now)
        let today = start.addingTimeInterval(19 * 3600 + 3 * 60)          // 19:03 that day
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(CardName.when(taken: today, now: now, locale: en, uses24Hour: true, calendar: cal), "19:03")
        XCTAssertTrue(CardName.when(taken: today, now: now, locale: en, uses24Hour: false, calendar: cal).hasPrefix("7:03"))
        let yesterday = today.addingTimeInterval(-86400)
        XCTAssertTrue(CardName.showsDay(taken: yesterday, now: now, calendar: cal))
        XCTAssertFalse(CardName.showsDay(taken: today, now: now, calendar: cal))
        XCTAssertEqual(CardName.when(taken: yesterday, now: now, locale: en, uses24Hour: true, calendar: cal), "Yesterday 19:03")
        XCTAssertEqual(CardName.when(taken: yesterday, now: now, locale: Locale(identifier: "zh-Hans_CN"), uses24Hour: true, calendar: cal),
                       "昨天 19:03")
    }

    /// Recently Dragged Out: "kept 7 more days" on every row repeated the footer — only the last day says it.
    func testATakenRowSaysHowLongItIsKeptOnlyOnItsLastDay() {
        XCTAssertFalse(TakenCaptures.showsDaysLeft(7))
        XCTAssertFalse(TakenCaptures.showsDaysLeft(2))
        XCTAssertTrue(TakenCaptures.showsDaysLeft(1))
    }
}
