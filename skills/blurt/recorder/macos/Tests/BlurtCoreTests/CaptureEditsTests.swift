// BlurtCore/CaptureEdits.swift: editing a capture's note, re-recording its voice note, and which batches still hold
// cards. The reports (v0.8.7 capture audit): Esc after a re-record lost the original voice note for good; a voice
// card's words could not be corrected; cards older than 30 days vanished after a restart.
import XCTest
@testable import BlurtCore

final class CaptureEditsTests: XCTestCase {

    // MARK: NoteEdit

    func testTheEditFieldShowsTheWholeNote() {
        XCTAssertEqual(NoteEdit.field(typed: nil, said: "the checkout bot overlaps the price"), "the checkout bot overlaps the price")
        XCTAssertEqual(NoteEdit.field(typed: "header", said: "the logo is cut off"), "header\nthe logo is cut off")
        XCTAssertEqual(NoteEdit.field(typed: "just typed", said: nil), "just typed")
        XCTAssertEqual(NoteEdit.field(typed: nil, said: nil), "")
    }

    func testAnUnchangedFieldLeavesTheNoteAsItWas() {
        let r = NoteEdit.apply(openedTyped: "header", openedSaid: "the logo", currentSaid: "the logo", field: "header\nthe logo ",
                               retaken: false)
        XCTAssertEqual(r.typed, "header")
        XCTAssertEqual(r.said, "the logo")
    }

    func testCorrectedWordsReplaceWhatWasHeard() {
        // a voice card: the correction is its words now, and nothing is said twice
        let v = NoteEdit.apply(openedTyped: nil, openedSaid: "the checkout bot overlaps", currentSaid: "the checkout bot overlaps",
                               field: "the checkout button overlaps", retaken: false)
        XCTAssertNil(v.typed)
        XCTAssertEqual(v.said, "the checkout button overlaps")
        XCTAssertEqual(CardNote.merged(typed: v.typed, said: v.said), "the checkout button overlaps")
        // a shot with typed text and spoken words: the whole edited note replaces both
        let s = NoteEdit.apply(openedTyped: "header", openedSaid: "logo cut of", currentSaid: "logo cut of",
                               field: "header\nlogo cut off", retaken: false)
        XCTAssertNil(s.typed)
        XCTAssertEqual(s.said, "header\nlogo cut off")
    }

    func testAnEmptiedFieldNeverErasesSpokenWords() {
        let r = NoteEdit.apply(openedTyped: "header", openedSaid: "the logo", currentSaid: "the logo", field: "  ", retaken: false)
        XCTAssertNil(r.typed)
        XCTAssertEqual(r.said, "the logo")
    }

    func testWithoutWordsTheFieldIsTheTypedNote() {
        let r = NoteEdit.apply(openedTyped: "old", openedSaid: nil, currentSaid: nil, field: "new", retaken: false)
        XCTAssertEqual(r.typed, "new")
        XCTAssertNil(r.said)
        // words that arrived while the bubble was open are kept
        let w = NoteEdit.apply(openedTyped: nil, openedSaid: nil, currentSaid: "arrived meanwhile", field: "typed", retaken: false)
        XCTAssertEqual(w.typed, "typed")
        XCTAssertEqual(w.said, "arrived meanwhile")
    }

    func testAKeptReRecordWaitsForItsWords() {
        let r = NoteEdit.apply(openedTyped: "header", openedSaid: "old words", currentSaid: "old words", field: "header", retaken: true)
        XCTAssertEqual(r.typed, "header")
        XCTAssertNil(r.said, "the new take is transcribed")
        XCTAssertNil(NoteEdit.apply(openedTyped: nil, openedSaid: "old", currentSaid: "old", field: "", retaken: true).typed)
    }

    // MARK: VoiceRetake

    func testTheRetakeGoesNextToTheOriginal() {
        XCTAssertEqual(VoiceRetake.path(for: "shots/005.wav"), "shots/005.retake.wav")
        XCTAssertEqual(VoiceRetake.path(for: "shots/012"), "shots/012.retake")
    }

    func testCancellingAReRecordKeepsTheOriginalByteForByte() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-retake-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("shots"), withIntermediateDirectories: true)
        let original = dir.appendingPathComponent("shots/005.wav")
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        try bytes.write(to: original)
        // the edit bubble records the retake next to it (never over it), then Esc
        let retake = dir.appendingPathComponent(VoiceRetake.path(for: "shots/005.wav"))
        try Data(repeating: 1, count: 64).write(to: retake)
        VoiceRetake.discard(retake)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retake.path))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    func testAKeptReRecordReplacesTheOriginal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-retake-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = dir.appendingPathComponent("005.wav"), retake = dir.appendingPathComponent("005.retake.wav")
        try Data([1, 2, 3]).write(to: original)
        try Data([9, 9]).write(to: retake)
        XCTAssertTrue(VoiceRetake.commit(retake, over: original))
        XCTAssertEqual(try Data(contentsOf: original), Data([9, 9]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: retake.path))
        // a shot that had no voice note yet: the retake becomes it
        let fresh = dir.appendingPathComponent("006.wav"), take = dir.appendingPathComponent("006.retake.wav")
        try Data([7]).write(to: take)
        XCTAssertTrue(VoiceRetake.commit(take, over: fresh))
        XCTAssertEqual(try Data(contentsOf: fresh), Data([7]))
        XCTAssertFalse(VoiceRetake.commit(take, over: fresh), "nothing to commit twice")
    }

    // MARK: CardBatches

    func testABatchWithAnUnfiledCardIsLoadedHoweverOld() {
        let lines = [
            #"{"n":1,"type":"shot","wall":1600000000,"project":null}"#,
            #"{"n":2,"type":"voice","wall":1600000001,"project":null}"#,
            #"{"n":1,"project":"p1","assigned_by":"user"}"#,
        ].joined(separator: "\n")
        XCTAssertTrue(CardBatches.holdsCards(jsonl: lines), "n=2 still hangs as a card")
    }

    func testABatchWithNothingLeftHangingIsSkipped() {
        let lines = [
            #"{"n":1,"type":"shot","project":null}"#,
            #"{"n":2,"type":"shot","project":null}"#,
            #"{"n":3,"type":"shot","project":null}"#,
            #"{"n":1,"project":"p1","assigned_by":"user"}"#,
            #"{"n":2,"deleted":true}"#,
            #"{"n":3,"project":null,"assigned_by":"ai"}"#,
        ].joined(separator: "\n")
        XCTAssertFalse(CardBatches.holdsCards(jsonl: lines))
        XCTAssertFalse(CardBatches.holdsCards(jsonl: ""))
    }

    func testADraggedOutCaptureKeepsItsBatch() {
        XCTAssertTrue(CardBatches.holdsCards(jsonl: #"{"n":1,"type":"shot","project":null}"# + "\n" + #"{"n":1,"taken":1600000000.5}"#))
        // put back: a card again
        XCTAssertTrue(CardBatches.holdsCards(jsonl: #"{"n":1,"type":"shot","project":null}"# + "\n" + #"{"n":1,"taken":null}"#))
        // undeleted after a discard's Undo
        XCTAssertTrue(CardBatches.holdsCards(jsonl: #"{"n":1,"deleted":true}"# + "\n" + #"{"n":1,"deleted":false}"#))
    }
}
