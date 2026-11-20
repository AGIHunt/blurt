import XCTest
@testable import BlurtCore

/// ⌥T's direction from the text's language, the card's rule, and the screen-text history (2026-11-16).
final class ScreenTextHistoryTests: XCTestCase {
    let zh = TranslateAutoPair(home: .zh, other: .en)

    // MARK: direction

    func testLanguageIdentifierReadsWholeSentences() {
        XCTAssertEqual(TranslateDirection.language(of: "Please review the attached document before the meeting tomorrow."), "en")
        XCTAssertEqual(TranslateDirection.language(of: "我们明天开会之前请先看一下附件。"), "zh-Hans")
        XCTAssertEqual(TranslateDirection.language(of: "今日はいい天気ですね。散歩に行きましょう。"), "ja")
    }

    func testAutoChineseAndEnglishEachWayOtherLanguagesIntoYours() {
        XCTAssertEqual(TranslateDirection.plan(.auto, detected: "en", pair: zh), .send("zh"))
        XCTAssertEqual(TranslateDirection.plan(.auto, detected: "zh-Hans", pair: zh), .send("en"))
        XCTAssertEqual(TranslateDirection.plan(.auto, detected: "zh-Hant", pair: zh), .send("en"))
        XCTAssertEqual(TranslateDirection.plan(.auto, detected: "ja", pair: zh), .send("zh"))
        XCTAssertEqual(TranslateDirection.plan(.auto, detected: "th", pair: zh), .send("zh"))     // not in the list: still yours
        XCTAssertEqual(TranslateDirection.plan(.auto, detected: nil, pair: zh), .send("auto:zh|en"))   // not sure: the model decides
    }

    func testAutoWithoutAPairKeepsYourOwnLanguage() {
        let en = TranslateAutoPair(home: .en, other: nil)
        XCTAssertEqual(TranslateDirection.plan(.auto, detected: "en", pair: en), .already(.en))
        XCTAssertEqual(TranslateDirection.plan(.auto, detected: "de", pair: en), .send("en"))
    }

    func testAFixedLanguageIsAlwaysThatLanguage() {
        XCTAssertEqual(TranslateDirection.plan(.ja, detected: "en", pair: zh), .send("ja"))
        XCTAssertEqual(TranslateDirection.plan(.ja, detected: "ja", pair: zh), .already(.ja))
        XCTAssertEqual(TranslateDirection.plan(.ja, detected: nil, pair: zh), .send("ja|keep"))
        // Simplified into Traditional is still a translation
        XCTAssertEqual(TranslateDirection.plan(.zhHant, detected: "zh-Hans", pair: zh), .send("zh-Hant"))
    }

    // MARK: the card

    func testTheCardShowsOnlyWhenTheTextWentNowhereButTheClipboard() {
        XCTAssertTrue(ScreenTextPaste.showsCard(.copied))
        XCTAssertFalse(ScreenTextPaste.showsCard(.pasted))
        XCTAssertFalse(ScreenTextPaste.showsCard(.unconfirmed))
        XCTAssertFalse(ScreenTextPaste.showsCard(.alreadyInTarget))
    }

    // MARK: history

    private func store() -> ScreenTextHistory {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sth-\(UUID().uuidString)")
        return ScreenTextHistory(url: dir.appendingPathComponent("history.jsonl"))
    }

    func testAppendLoadNewestFirstUpdateAndDelete() {
        let h = store()
        let now = Date()
        h.append(ScreenTextEntry(id: "a", time: now.addingTimeInterval(-60), translated: false, text: "draft"), days: 30)
        h.append(ScreenTextEntry(id: "b", time: now, translated: true, text: "你好", source: "Hello", target: "zh", app: "Safari"), days: 30)
        XCTAssertEqual(h.load().map(\.id), ["b", "a"])
        XCTAssertEqual(h.load().first?.source, "Hello")
        h.update("a", text: "better")
        XCTAssertEqual(h.load().last?.text, "better")
        h.delete(["b"])
        XCTAssertEqual(h.load().map(\.id), ["a"])
    }

    func testNotKeptWritesNothing() {
        let h = store()
        h.append(ScreenTextEntry(translated: false, text: "x"), days: 0)
        XCTAssertTrue(h.load().isEmpty)
    }

    func testPruneByDaysForeverAndOff() {
        let h = store()
        let now = Date()
        h.append(ScreenTextEntry(id: "old", time: now.addingTimeInterval(-40 * 86400), translated: false, text: "old"), days: 30)
        h.append(ScreenTextEntry(id: "new", time: now.addingTimeInterval(-86400), translated: false, text: "new"), days: 30)
        XCTAssertEqual(h.prune(days: -1, now: now), 0)
        XCTAssertEqual(h.load().count, 2)
        XCTAssertEqual(h.prune(days: 30, now: now), 1)
        XCTAssertEqual(h.load().map(\.id), ["new"])
        XCTAssertEqual(h.prune(days: 0, now: now), 1)
        XCTAssertTrue(h.load().isEmpty)
    }

    /// The page's Undo: deleted entries come back, once each, also after a prune dropped the delete line.
    func testDeletedEntriesComeBackOnUndo() {
        let h = store()
        let now = Date()
        let a = ScreenTextEntry(id: "a", time: now.addingTimeInterval(-60), translated: false, text: "one")
        let b = ScreenTextEntry(id: "b", time: now, translated: false, text: "two")
        h.append(a, days: 30); h.append(b, days: 30)
        h.delete(["a", "b"])
        XCTAssertTrue(h.load().isEmpty)
        h.restore([b, a])
        XCTAssertEqual(h.load().map(\.id), ["b", "a"])
        h.restore([a])
        XCTAssertEqual(h.load().map(\.id), ["b", "a"], "written again, still once")
        h.delete(["a"]); h.prune(days: 30, now: now); h.restore([a])
        XCTAssertEqual(h.load().map(\.id), ["b", "a"])
    }

    /// Settings asks before a shorter period deletes: how many would go.
    func testWhatAShorterPeriodWouldDelete() {
        let h = store()
        let now = Date()
        h.append(ScreenTextEntry(id: "old", time: now.addingTimeInterval(-10 * 86400), translated: false, text: "old"), days: 30)
        h.append(ScreenTextEntry(id: "new", time: now.addingTimeInterval(-86400), translated: false, text: "new"), days: 30)
        XCTAssertEqual(h.wouldPrune(days: 30, now: now), 0)
        XCTAssertEqual(h.wouldPrune(days: 7, now: now), 1)
        XCTAssertEqual(h.wouldPrune(days: 0, now: now), 2)
        XCTAssertEqual(h.wouldPrune(days: -1, now: now), 0)
        XCTAssertEqual(h.load().count, 2, "asking deletes nothing")
    }

    func testPreviewIsOneLine() {
        XCTAssertEqual(ScreenTextEntry.preview("a\n\n b \nc"), "a b c")
        XCTAssertEqual(ScreenTextEntry.preview(String(repeating: "x", count: 200), max: 10), "xxxxxxxxxx…")
    }
}
