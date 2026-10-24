// Dictation styles (BlurtCore/DictationStyle.swift, DictationList.swift; docs/design/dictation-styles.md §3): the list
// renderer against the fixture the Python port is checked against too, what it must never turn into a list, that it
// only ever takes marker words out, the router's precedence, the category variants, and that instructions stay content.
import XCTest
@testable import BlurtCore

final class DictationStyleTests: XCTestCase {
    /// tests/fixtures/dictation_lists.jsonl, from the repository root
    static var fixture: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("tests/fixtures/dictation_lists.jsonl")
    }

    static func rows() throws -> [[String: Any]] {
        try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n")
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    // MARK: the renderer

    func testListsMatchTheSharedFixture() throws {
        let rows = try DictationStyleTests.rows()
        XCTAssertGreaterThanOrEqual(rows.count, 30)
        for r in rows {
            let name = r["name"] as! String, text = r["text"] as! String, min = r["min"] as! Int
            XCTAssertEqual(DictationList.markers(text), r["markers"] as? Int, name)
            XCTAssertEqual(DictationList.render(text, minMarkers: min), r["expect"] as? String, name)
        }
    }

    func testOnlyMarkerWordsGo() throws {
        // every unit of the input that isn't a marker word is in the list, in order; the only units added are the
        // items' numbers ("1. " at a line start)
        var checked = 0
        for r in try DictationStyleTests.rows() {
            let text = r["text"] as! String
            guard let out = DictationList.render(text), let d = DictationList.detect(text) else { continue }
            let ns = NSMutableString(string: text)
            for range in d.removedRanges.reversed() { ns.deleteCharacters(in: range) }
            let unnumbered = out.components(separatedBy: "\n")
                .map { $0.replacingOccurrences(of: #"^[0-9]+\. "#, with: "", options: .regularExpression) }.joined(separator: "\n")
            XCTAssertEqual(DictationStitch.units(unnumbered).map(\.value), DictationStitch.units(ns as String).map(\.value), r["name"] as! String)
            XCTAssertEqual(d.removed.count, d.markers)
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 14)
    }

    func testEnumerationWordsInNormalSpeechStayProse() {
        // the words that make Typeless over-fire: never a list on their own, under any style
        for t in ["以及我们的其他同事", "然后呢，然后我们就走了", "另外，还有一个问题", "这是第一次，也是第一天",
                  "一是一，二是二", "一是一是，对对对", "We also need this, and then that.", "Then we left, and then we came back."] {
            XCTAssertNil(DictationList.render(t, minMarkers: 2), t)
            XCTAssertNil(DictationList.render(t, minMarkers: 3), t)
        }
    }

    func testRendererIsFast() {
        let long = String(repeating: "明天要做三件事。第一，把测试全部跑完。第二，把文档更新一下。第三，提交代码。", count: 20)
        let t0 = Date()
        for _ in 0..<20 { _ = DictationList.render(long) }
        XCTAssertLessThan(Date().timeIntervalSince(t0) / 20, 0.005)      // < 5 ms for a long take
    }

    // MARK: the router

    func testPrecedenceExplicitThenAppThenCategoryThenDefault() {
        var c = DictationStyleConfig()
        let notes = "com.apple.Notes"
        XCTAssertEqual(DictationStyleRouter.decide(config: c, bundle: notes).style, .light)
        XCTAssertEqual(DictationStyleRouter.decide(config: c, bundle: notes).source, .default)
        c.categories[.notes] = .auto
        XCTAssertEqual(DictationStyleRouter.decide(config: c, bundle: notes), .init(style: .auto, source: .category, category: .notes, base: .auto))
        c.apps[notes] = .verbatim
        XCTAssertEqual(DictationStyleRouter.decide(config: c, bundle: notes).style, .verbatim)
        XCTAssertEqual(DictationStyleRouter.decide(config: c, bundle: notes).source, .app)
        let shift = DictationStyleRouter.decide(explicit: (.light, .shift), config: c, bundle: notes)
        XCTAssertEqual(shift.style, .light)
        XCTAssertEqual(shift.source, .shift)
        // another app falls through to its own category, then the default
        XCTAssertEqual(DictationStyleRouter.decide(config: c, bundle: "com.tencent.xinWeChat").style, .light)
        XCTAssertEqual(DictationStyleRouter.decide(config: c, bundle: "com.tencent.xinWeChat").category, .chat)
        c.fallback = .verbatim
        XCTAssertEqual(DictationStyleRouter.decide(config: c, bundle: "com.example.thing").style, .verbatim)
        XCTAssertEqual(DictationStyleRouter.decide(config: c, bundle: nil).category, .other)
    }

    func testShiftTogglesToStructuredAndBack() {
        XCTAssertEqual(DictationStyleRouter.toggled(.light, base: .light), .structured)
        XCTAssertEqual(DictationStyleRouter.toggled(.structured, base: .light), .light)
        XCTAssertEqual(DictationStyleRouter.toggled(.verbatim, base: .verbatim), .structured)
        XCTAssertEqual(DictationStyleRouter.toggled(.structured, base: .verbatim), .verbatim)
        XCTAssertEqual(DictationStyleRouter.toggled(.auto, base: .auto), .structured)
        XCTAssertEqual(DictationStyleRouter.toggled(.structured, base: .auto), .light)
        XCTAssertEqual(DictationStyleRouter.toggled(.structured, base: .structured), .light)
    }

    func testDefaultsAreLightEverywhere() {
        let c = DictationStyleConfig(json: nil)
        for cat in DictationAppCategory.allCases { XCTAssertEqual(c.style(for: cat), .light) }
        XCTAssertNil(c.json)
    }

    func testConfigRoundTrip() {
        var c = DictationStyleConfig()
        c.categories[.notes] = .auto
        c.apps["com.apple.Notes"] = .structured
        c.learned = ["com.apple.Notes", "gone.app"]
        let back = DictationStyleConfig(json: c.json)
        XCTAssertEqual(back.categories, [.notes: .auto])
        XCTAssertEqual(back.apps, ["com.apple.Notes": .structured])
        XCTAssertEqual(back.learned, ["com.apple.Notes"])           // a learned mark without its app goes
        XCTAssertEqual(DictationStyleConfig(json: ["chat": "nonsense", "apps": ["x": 3]]).json == nil, true)
    }

    func testCategories() {
        XCTAssertEqual(DictationAppCategory.of(bundle: "com.tencent.xinWeChat"), .chat)
        XCTAssertEqual(DictationAppCategory.of(bundle: "com.bytedance.macos.feishu"), .chat)
        XCTAssertEqual(DictationAppCategory.of(bundle: "com.tinyspeck.slackmacgap"), .chat)
        XCTAssertEqual(DictationAppCategory.of(bundle: "com.googlecode.iterm2"), .code)
        XCTAssertEqual(DictationAppCategory.of(bundle: "com.jetbrains.pycharm"), .code)
        XCTAssertEqual(DictationAppCategory.of(bundle: "com.todesktop.230313mzl4w4u92"), .code)     // Cursor
        XCTAssertEqual(DictationAppCategory.of(bundle: "com.apple.mail"), .mail)
        XCTAssertEqual(DictationAppCategory.of(bundle: "md.obsidian"), .notes)
        XCTAssertEqual(DictationAppCategory.of(bundle: "com.1password.1password"), .other)          // not "word"
        XCTAssertEqual(DictationAppCategory.of(bundle: "com.apple.Safari"), .other)
        XCTAssertEqual(DictationAppCategory.of(bundle: nil), .other)
    }

    func testReformatCycle() {
        XCTAssertEqual(DictationStyle.verbatim.next, .light)
        XCTAssertEqual(DictationStyle.light.next, .structured)
        XCTAssertEqual(DictationStyle.structured.next, .verbatim)
        XCTAssertEqual(DictationStyle.auto.next, .verbatim)
        XCTAssertFalse(DictationStyle.verbatim.polishes)
        XCTAssertNil(DictationStyle.light.listMarkers)
        XCTAssertEqual(DictationStyle.structured.listMarkers, 2)
        XCTAssertEqual(DictationStyle.auto.listMarkers, 3)
    }

    // MARK: the category variants of light

    func testChatDropsTheFullStopOfOneSentence() {
        XCTAssertEqual(DictationStyleVariant.apply("好的，那我们晚上七点见吧。", category: .chat, structured: false).text, "好的，那我们晚上七点见吧")
        XCTAssertEqual(DictationStyleVariant.apply("OK, see you at seven.", category: .chat, structured: false).text, "OK, see you at seven")
        // two sentences, a question, an ellipsis, a decimal: as they were
        XCTAssertEqual(DictationStyleVariant.apply("好的。晚上见。", category: .chat, structured: false).text, "好的。晚上见。")
        XCTAssertEqual(DictationStyleVariant.apply("你来吗？", category: .chat, structured: false).text, "你来吗？")
        XCTAssertEqual(DictationStyleVariant.apply("Well...", category: .chat, structured: false).text, "Well...")
        XCTAssertEqual(DictationStyleVariant.apply("It costs 3.5 dollars.", category: .chat, structured: false).text, "It costs 3.5 dollars")
        XCTAssertEqual(DictationStyleVariant.apply("第一段。\n\n第二段。", category: .chat, structured: false).text, "第一段。\n第二段。")
        XCTAssertEqual(DictationStyleVariant.apply("好的。", category: .chat, structured: false).changes, ["final_stop"])
        // other apps keep it
        XCTAssertEqual(DictationStyleVariant.apply("好的。", category: .notes, structured: false).text, "好的。")
        XCTAssertEqual(DictationStyleVariant.apply("好的。", category: .mail, structured: false).text, "好的。")
    }

    func testCodeGetsOneLine() {
        XCTAssertEqual(DictationStyleVariant.apply("Run the tests.\n\nThen push.", category: .code, structured: false).text, "Run the tests. Then push.")
        XCTAssertEqual(DictationStyleVariant.apply("先跑测试。\n再推上去。", category: .code, structured: false).text, "先跑测试。再推上去。")
        XCTAssertEqual(DictationStyleVariant.apply("先跑 tests\nthen push", category: .code, structured: false).text, "先跑 tests then push")
        // a list the user asked for keeps its lines
        XCTAssertEqual(DictationStyleVariant.apply("1. A\n2. B", category: .code, structured: true).text, "1. A\n2. B")
        XCTAssertEqual(DictationStyleVariant.apply("One line.", category: .code, structured: false).changes, [])
    }

    // MARK: instructions to an AI agent are content, never a command (no spoken triggers: dictation-styles.md §3.6)

    func testInstructionsStayContent() {
        for t in ["帮我列个清单，把这周要做的事情整理一下。", "列个清单：买牛奶，取快递。", "写成邮件发给小王。",
                  "Make a list of the files that changed.", "分点说一下这个方案的优缺点。"] {
            XCTAssertNil(DictationList.render(t), t)                                              // no list made of it
            XCTAssertEqual(DictationStyleVariant.apply(t, category: .notes, structured: false).text, t)
            XCTAssertEqual(DictationStyleVariant.apply(t, category: .code, structured: false).text, t)
        }
    }
}
