// BlurtCore/IslandToasts.swift: dictation's toasts end with what they describe, one line for "copied, not sent", what a
// discarded recording takes with it, and a card's name.
import XCTest
@testable import BlurtCore

final class IslandToastsTests: XCTestCase {
    /// The dogfood: the 5-minute limit over a new take that listens, the last take's tip over the next one, and
    /// "⇧ to go back" after ⇧ stopped meaning anything.
    func testANewTakeDropsWhatWasSaidAboutTheLastOne() {
        let start = Set(DictationToastKeys.droppedAtStart)
        XCTAssertTrue(start.isSuperset(of: [DictationToastKeys.take, DictationToastKeys.notice, DictationToastKeys.listening]))
        // still true across a new take: a failed take's Retry, "Cancelled · Undo", the model's Download…
        XCTAssertFalse(start.contains(DictationToastKeys.cancel))
        XCTAssertFalse(start.contains(DictationToastKeys.model))
        XCTAssertFalse(start.contains { $0.hasPrefix("dictation.failed.") })
        XCTAssertEqual(DictationToastKeys.droppedWhenListeningEnds, [DictationToastKeys.style])
        XCTAssertFalse(start.contains(DictationToastKeys.style), "⇧'s line belongs to the take that listens")
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
}
