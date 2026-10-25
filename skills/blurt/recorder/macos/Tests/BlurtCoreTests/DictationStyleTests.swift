// Dictation styles (BlurtCore/DictationStyle.swift; docs/design/dictation-styles.md §3): which text a style types
// (Structured: the polish model's structuring pass; Auto: only when it is a list), the router's precedence, the
// category variants, and that instructions stay content. No rule-based list renderer: whether and how a take is
// structured is the model's call (polish.py `structure`, tests/test_polish.py).
import XCTest
@testable import BlurtCore

final class DictationStyleTests: XCTestCase {
    // MARK: which text a style types

    /// Terminals get polish's "terminal" variant (a command said there stays a command); chat apps "chat"; others none.
    func testPolishVariantByApp() {
        XCTAssertEqual(DictationAppCategory.polishVariant(bundle: "com.apple.Terminal"), "terminal")
        XCTAssertEqual(DictationAppCategory.polishVariant(bundle: "com.googlecode.iterm2"), "terminal")
        XCTAssertEqual(DictationAppCategory.polishVariant(bundle: "com.mitchellh.ghostty"), "terminal")
        XCTAssertEqual(DictationAppCategory.polishVariant(bundle: "com.microsoft.VSCode"), nil)      // an editor: sentences
        XCTAssertEqual(DictationAppCategory.polishVariant(bundle: "com.tencent.xinWeChat"), "chat")
        XCTAssertNil(DictationAppCategory.polishVariant(bundle: nil))
        // mid-sentence in the field: the transcript's own case comes back over a capital polish gave (names keep theirs)
        XCTAssertTrue(DictationStitch.midSentence("I think "))
        XCTAssertEqual(DictationStitch.keepCase(input: "the new layout is fine", output: "The new layout is fine."),
                       "the new layout is fine.")
        XCTAssertEqual(DictationStitch.keepCase(input: "Thursday after the review", output: "Thursday after the review."),
                       "Thursday after the review.")
    }

    func testPick() {
        let light = "明天要做三件事，第一跑测试，第二更新文档。"
        let listed = "明天要做三件事：\n1. 跑测试\n2. 更新文档"
        XCTAssertEqual(DictationStyle.light.pick(light: light, structured: listed).text, light)          // never a list
        XCTAssertEqual(DictationStyle.verbatim.pick(light: light, structured: listed).text, light)
        let s = DictationStyle.structured.pick(light: light, structured: listed)
        XCTAssertEqual(s.text, listed)
        XCTAssertTrue(s.list)
        // Structured that stayed a paragraph (a correction resolved): typed as the model wrote it
        let p = DictationStyle.structured.pick(light: "我们周五交，哦不，下周一交。", structured: "我们下周一交。")
        XCTAssertEqual(p.text, "我们下周一交。")
        XCTAssertFalse(p.list)
        // Auto: only a list
        XCTAssertEqual(DictationStyle.auto.pick(light: light, structured: listed).text, listed)
        XCTAssertEqual(DictationStyle.auto.pick(light: "我们周五交，哦不，下周一交。", structured: "我们下周一交。").text, "我们周五交，哦不，下周一交。")
        // no structured text (the pass refused, or never ran): Light's
        XCTAssertEqual(DictationStyle.structured.pick(light: light, structured: nil).text, light)
        XCTAssertEqual(DictationStyle.structured.pick(light: light, structured: "  ").text, light)
        XCTAssertTrue(DictationStyle.structured.structures && DictationStyle.auto.structures)
        XCTAssertFalse(DictationStyle.light.structures || DictationStyle.verbatim.structures)
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
            XCTAssertEqual(DictationStyle.light.pick(light: t, structured: nil).text, t)
            XCTAssertEqual(DictationStyleVariant.apply(t, category: .notes, structured: false).text, t)
            XCTAssertEqual(DictationStyleVariant.apply(t, category: .code, structured: false).text, t)
        }
    }

    /// ⇧'s line explains Structured the first two times ever, then the ear's chip alone says it (dogfood #22).
    func testTheStyleToggleExplainsItselfOnlyAtFirst() {
        XCTAssertTrue(DictationStyleToggleHint.says(shown: 0))
        XCTAssertTrue(DictationStyleToggleHint.says(shown: 1))
        XCTAssertFalse(DictationStyleToggleHint.says(shown: 2))
        XCTAssertFalse(DictationStyleToggleHint.says(shown: 40))
    }
}
