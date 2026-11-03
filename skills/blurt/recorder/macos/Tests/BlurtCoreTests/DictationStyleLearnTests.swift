// Reformat-last's rules and learning from the user's switches (BlurtCore/DictationStyleRecord.swift,
// DictationStyleLearn.swift; docs/design/dictation-styles.md §3.2 E, §3.5), and the style in the history.
import XCTest
@testable import BlurtCore

final class DictationStyleLearnTests: XCTestCase {
    // MARK: reformat-last replaces only untouched text

    func testReplacesOnlyWhileThePastedTextIsUntouched() {
        let typed = "明天要做三件事，第一，跑测试，第二，更新文档。"
        let doc = "会议记录：" + typed + "\n下一段"
        let at = ("会议记录：" as NSString).length
        let prefix = "会议记录：", suffix = "\n下一段"
        // as typed: found where it went
        XCTAssertEqual(DictationReformat.span(in: doc, inserted: typed, prefix: prefix, suffix: suffix, near: at),
                       NSRange(location: at, length: (typed as NSString).length))
        // the user fixed a word inside it: never overwritten
        let edited = doc.replacingOccurrences(of: "跑测试", with: "跑全部测试")
        XCTAssertNil(DictationReformat.span(in: edited, inserted: typed, prefix: prefix, suffix: suffix, near: at))
        // …and what they see now is what reformat-last restyles and copies (v0.9 dogfood: their fix was missing)
        XCTAssertEqual(DictationLearn.locate(in: edited, prefix: prefix, suffix: suffix, near: at, maxLength: 200),
                       typed.replacingOccurrences(of: "跑测试", with: "跑全部测试"))
        // typed right after it, or right before it: the anchors changed — no replacement either
        XCTAssertNil(DictationReformat.span(in: doc.replacingOccurrences(of: "\n下一段", with: "好的\n下一段"), inserted: typed,
                                            prefix: prefix, suffix: suffix, near: at))
        XCTAssertNil(DictationReformat.span(in: "x" + doc.replacingOccurrences(of: "会议记录：", with: "会议纪要："), inserted: typed,
                                            prefix: prefix, suffix: suffix, near: at))
        // text added elsewhere in the document moves it, but it is still untouched
        let moved = "新的一行\n" + doc
        XCTAssertEqual(DictationReformat.span(in: moved, inserted: typed, prefix: prefix, suffix: suffix, near: at)?.location,
                       at + ("新的一行\n" as NSString).length)
        // gone
        XCTAssertNil(DictationReformat.span(in: "会议记录：\n下一段", inserted: typed, prefix: prefix, suffix: suffix, near: at))
        // pasted twice in the same document: the occurrence nearest to where it went
        let twice = "A" + typed + "B\nA" + typed + "B"
        let second = ("A" + typed + "B\nA" as NSString).length
        XCTAssertEqual(DictationReformat.span(in: twice, inserted: typed, prefix: "A", suffix: "B", near: second)?.location, second)
        // an empty field around it (the first thing typed into a chat box)
        XCTAssertEqual(DictationReformat.span(in: typed, inserted: typed, prefix: "", suffix: "", near: 0)?.location, 0)
        XCTAssertNil(DictationReformat.span(in: "", inserted: typed, prefix: "", suffix: "", near: 0))
    }

    func testAListTakenApartIsARevert() {
        let list = "明天要做三件事：\n1. 跑测试\n2. 更新文档\n3. 提交代码"
        XCTAssertTrue(DictationReformat.reverted(typed: list, edited: "明天要做三件事：跑测试，更新文档，提交代码。"))
        XCTAssertTrue(DictationReformat.reverted(typed: "We need:\n1. Run the tests\n2. Update the docs", edited: "We need: run the tests, update the docs."))
        // a fix inside an item is not, nor a deleted list, nor prose that was never a list
        XCTAssertFalse(DictationReformat.reverted(typed: list, edited: list.replacingOccurrences(of: "跑测试", with: "跑全部测试")))
        XCTAssertFalse(DictationReformat.reverted(typed: list, edited: "好"))
        XCTAssertFalse(DictationReformat.reverted(typed: "跑测试，更新文档。", edited: "跑测试。"))
    }

    // MARK: learning: suggest, never switch

    private func entry(_ n: Int, bundle: String = "com.apple.Notes", style: String = "light", source: String = "default",
                       markers: Int = 0, reformats: [DictationReformatRecord] = []) -> DictationEntry {
        var e = DictationEntry(id: "d-\(n)", time: Date(timeIntervalSince1970: Double(1000 + n)), app: "备忘录", bundle: bundle,
                               duration: 3, raw: "x", polished: nil, text: "x", model: nil, fellBack: false, reason: nil, insert: "pasted")
        var r = DictationStyleRecord(style: style, source: source, category: "notes", base: "light", markers: markers)
        r.reformats = reformats
        e.style = r
        return e
    }

    func testSignals() {
        XCTAssertEqual(DictationStyleLearn.signal(DictationStyleRecord(style: "structured", source: "shift", category: "notes", base: "light")), .structured)
        XCTAssertEqual(DictationStyleLearn.signal(DictationStyleRecord(style: "structured", source: "island", category: "notes", base: "light")), .structured)
        XCTAssertEqual(DictationStyleLearn.signal(DictationStyleRecord(style: "structured", source: "chord", category: "notes", base: "light")), .structured)
        // a list-like take left as prose: a vote for light; a plain take says nothing
        XCTAssertEqual(DictationStyleLearn.signal(DictationStyleRecord(style: "light", source: "default", category: "notes", base: "light", markers: 3)), .light)
        XCTAssertNil(DictationStyleLearn.signal(DictationStyleRecord(style: "light", source: "default", category: "notes", base: "light")))
        // a kept reformat counts as its style, an undone one as the style the take had
        var r = DictationStyleRecord(style: "light", source: "default", category: "notes", base: "light", markers: 2)
        r.reformats = [DictationReformatRecord(action: "reformat", from: "light", to: "structured", replaced: true)]
        XCTAssertEqual(DictationStyleLearn.signal(r), .structured)
        r.reformats.append(DictationReformatRecord(action: "undo", from: "structured", to: "light", replaced: true))
        XCTAssertEqual(DictationStyleLearn.signal(r), .light)
        // auto counts as a wish for lists
        XCTAssertEqual(DictationStyleLearn.signal(DictationStyleRecord(style: "auto", source: "shift", category: "notes", base: "light")), .structured)
        // the island offered a list (the structuring pass found one) and it was left as prose: a vote for light; taken:
        // its style. The offer itself is no choice of the user's.
        var o = DictationStyleRecord(style: "light", source: "default", category: "notes", base: "light")
        o.reformats = [DictationReformatRecord(action: "suggest", from: "light", to: "structured", replaced: false)]
        XCTAssertTrue(o.listLikely)
        XCTAssertEqual(DictationStyleLearn.signal(o), .light)
        o.reformats.append(DictationReformatRecord(action: "reformat", from: "light", to: "structured", replaced: true))
        XCTAssertEqual(DictationStyleLearn.signal(o), .structured)
        // a rendered list taken apart in the field
        var v = DictationStyleRecord(style: "structured", source: "app", category: "notes", base: "structured", markers: 3, rendered: true)
        v.reformats = [DictationReformatRecord(action: "revert", from: "structured", to: "light", replaced: false)]
        XCTAssertEqual(DictationStyleLearn.signal(v), .light)
    }

    func testThreeConsistentSignalsSuggestOnce() {
        // newest first, as the history loads
        var es = [entry(3, style: "structured", source: "shift"), entry(2, style: "structured", source: "shift"),
                  entry(1, style: "light", markers: 0)]
        // two signals: not yet
        XCTAssertNil(DictationStyleLearn.suggest(entries: es, bundle: "com.apple.Notes", current: .light, asked: []))
        es.insert(entry(4, style: "structured", source: "island"), at: 0)
        let s = DictationStyleLearn.suggest(entries: es, bundle: "com.apple.Notes", current: .light, asked: [])
        XCTAssertEqual(s?.style, .auto)                      // lists → Auto (only when confident), never Structured always
        XCTAssertEqual(s?.signals, 3)
        XCTAssertEqual(s?.app, "备忘录")
        // asked once, whatever the answer
        XCTAssertNil(DictationStyleLearn.suggest(entries: es, bundle: "com.apple.Notes", current: .light, asked: [s!.key]))
        // already the app's style: nothing to suggest
        XCTAssertNil(DictationStyleLearn.suggest(entries: es, bundle: "com.apple.Notes", current: .auto, asked: []))
        // another app's switches don't count here
        XCTAssertNil(DictationStyleLearn.suggest(entries: es, bundle: "com.tencent.xinWeChat", current: .light, asked: []))
    }

    func testMixedSignalsSuggestNothing() {
        // 3 for lists, 2 against: 60 %, under 70 %
        let es = [entry(5, style: "structured", source: "shift"), entry(4, style: "light", markers: 2),
                  entry(3, style: "structured", source: "shift"), entry(2, style: "light", markers: 3),
                  entry(1, style: "structured", source: "shift")]
        XCTAssertNil(DictationStyleLearn.suggest(entries: es, bundle: "com.apple.Notes", current: .light, asked: []))
    }

    func testRevertingListsSuggestsLight() {
        let undo = [DictationReformatRecord(action: "reformat", from: "structured", to: "light", replaced: true)]
        let es = (1...3).map { entry($0, style: "auto", source: "app", markers: 3, reformats: undo) }
        XCTAssertEqual(DictationStyleLearn.suggest(entries: es, bundle: "com.apple.Notes", current: .auto, asked: [])?.style, .light)
        let verb = [DictationReformatRecord(action: "reformat", from: "light", to: "verbatim", replaced: true)]
        let vs = (1...4).map { entry($0, reformats: verb) }
        XCTAssertEqual(DictationStyleLearn.suggest(entries: vs, bundle: "com.apple.Notes", current: .light, asked: [])?.style, .verbatim)
    }

    func testOnlyTheRecentSignalsCount() {
        // ten recent light votes outweigh older list votes
        let recent = (11...20).reversed().map { entry($0, style: "light", markers: 2) }
        let old = (1...10).reversed().map { entry($0, style: "structured", source: "shift") }
        XCTAssertNil(DictationStyleLearn.suggest(entries: recent + old, bundle: "com.apple.Notes", current: .light, asked: []))
    }

    // MARK: the history keeps the style, the router's inputs and every reformat

    func testHistoryKeepsTheStyleAndReformats() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-style-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = DictationHistory(url: dir.appendingPathComponent("history.jsonl"))
        var e = DictationEntry(id: "d-1", time: Date(), app: "备忘录", bundle: "com.apple.Notes", duration: 4, raw: "第一跑测试第二提交",
                               polished: "第一，跑测试；第二，提交。", text: "1. 跑测试\n2. 提交", model: "g", fellBack: false, reason: nil,
                               insert: "pasted")
        e.style = DictationStyleRecord(style: "structured", source: "shift", category: "notes", base: "light", explicit: "structured",
                                       toggles: 1, markers: 2, rendered: true, variant: [])
        h.append(e)
        h.restyle("d-1", DictationReformatRecord(action: "reformat", from: "structured", to: "verbatim", replaced: true))
        h.restyle("d-1", DictationReformatRecord(action: "undo", from: "verbatim", to: "structured", replaced: true))
        let back = try XCTUnwrap(h.load().first?.style)
        XCTAssertEqual(back.style, "structured")
        XCTAssertEqual(back.source, "shift")
        XCTAssertEqual(back.base, "light")
        XCTAssertEqual(back.explicit, "structured")
        XCTAssertEqual(back.toggles, 1)
        XCTAssertEqual(back.markers, 2)
        XCTAssertTrue(back.rendered)
        XCTAssertTrue(back.listLikely)
        XCTAssertEqual(back.reformats.map(\.action), ["reformat", "undo"])
        XCTAssertEqual(back.reformats.last?.to, "structured")
        // the line itself: style, style_source, style_router
        let line = try String(contentsOf: h.url, encoding: .utf8).split(separator: "\n").first.map(String.init) ?? ""
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(o["style"] as? String, "structured")
        XCTAssertEqual(o["style_source"] as? String, "shift")
        XCTAssertEqual((o["style_router"] as? [String: Any])?["list_likely"] as? Bool, true)
        // prune folds the reformats into the entry
        h.prune(days: 30)
        XCTAssertEqual(h.load().first?.style?.reformats.count, 2)
        XCTAssertEqual(try String(contentsOf: h.url, encoding: .utf8).split(separator: "\n").count, 1)
        // an older entry has no style
        XCTAssertNil(DictationEntry(json: ["id": "d-0", "raw": "x"])?.style)
    }

    /// Dogfood: "以后在 Safari浏览器 里" spaced the app name unevenly.
    func testAnAppNameSitsInAChineseQuestionWithoutStraySpaces() {
        XCTAssertEqual(DictationStyleLearn.inline("Notes", cjk: true), " Notes ")
        XCTAssertEqual(DictationStyleLearn.inline("Safari浏览器", cjk: true), " Safari浏览器")
        XCTAssertEqual(DictationStyleLearn.inline("微信", cjk: true), "微信")
        XCTAssertEqual(DictationStyleLearn.inline("Notes", cjk: false), "Notes")
    }
}
