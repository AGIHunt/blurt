import XCTest
@testable import BlurtCore

/// Fitting a dictation into the text around the cursor (docs/design/dictation.md §Insert): the words that repeat the
/// field on either side go, punctuation and spacing follow the sentence it lands in, and nothing in the field changes.
final class DictationFitTests: XCTestCase {
    typealias F = DictationFit

    func fit(_ text: String, _ before: String, _ after: String) -> String { F.fit(text, before: before, after: after).text }

    func testTheTypelessExample() {
        // 「我知道你就是▮的。」 + 「就是从老家回来的。」 → 「我知道你就是从老家回来的。」
        let r = F.fit("就是从老家回来的。", before: "我知道你就是", after: "的。")
        XCTAssertEqual(r.text, "从老家回来")
        XCTAssertEqual(r.changes, ["head", "tail"])
        XCTAssertEqual("我知道你就是" + r.text + "的。", "我知道你就是从老家回来的。")
    }

    func testNoOverlapLeavesTheTextAlone() {
        let r = F.fit("下午三点开会。", before: "今天的安排：", after: "")
        XCTAssertEqual(r.text, "下午三点开会。")
        XCTAssertFalse(r.trimmed)
        XCTAssertEqual(fit("Let's ship it today.", "", ""), "Let's ship it today.")
        // an empty field, a new line before the cursor
        XCTAssertEqual(fit("我们明天再看。", "上一段。\n", ""), "我们明天再看。")
    }

    func testOneCharacterIsNotAnOverlap() {
        // 「去」 ends the text before and starts the dictation: a coincidence, kept
        XCTAssertEqual(fit("去公园散步。", "我们明天", ""), "去公园散步。")
        XCTAssertEqual(fit("去公园散步。", "我们明天去", ""), "去公园散步。")
        // two characters are an overlap
        XCTAssertEqual(fit("明天去公园散步。", "我们明天", ""), "去公园散步。")
        // a single trailing 「的」 before different text after the cursor stays
        XCTAssertEqual(fit("这是我的", "", "朋友"), "这是我的")
    }

    func testOverlapOnlyRightAtTheCursor() {
        // the same words earlier in the field, or before a sentence end, aren't an overlap
        XCTAssertEqual(fit("就是这样。", "就是这样。", ""), "就是这样。")
        XCTAssertEqual(fit("就是从老家回来的", "你就是。然后", ""), "就是从老家回来的")
        // never everything: a dictation that only repeats the field is inserted as said
        XCTAssertEqual(fit("就是", "我知道你就是", ""), "就是")
    }

    func testEnglish() {
        // "I think we should ▮ tomorrow." + "We should move the meeting." → "move the meeting"
        let r = F.fit("We should move the meeting.", before: "I think we should ", after: " tomorrow.")
        XCTAssertEqual(r.text, "move the meeting")
        XCTAssertEqual(r.changes, ["head", "punct"])
        // the end repeats the start of what follows
        XCTAssertEqual(fit("send the report to the team.", "Please ", " to the team."), "send the report")
        // one word is an overlap in English
        XCTAssertEqual(fit("Review the PR before lunch.", "Can you review", ""), " the PR before lunch.")
        // mid-sentence: no capital the speech model gave, no closing full stop before a lower-case word
        XCTAssertEqual(fit("Then we deploy.", "Fix the tests and", "on Friday"), " then we deploy ")
        // a new sentence after a full stop keeps its capital and its full stop
        XCTAssertEqual(fit("Then we deploy.", "Fix the tests.", " The rest can wait."), " Then we deploy.")
    }

    func testPunctuationAfterTheCursor() {
        // the text after starts with punctuation: the insertion ends without any
        XCTAssertEqual(fit("我们周五发布。", "计划是", "，大家觉得呢？"), "我们周五发布")
        XCTAssertEqual(fit("ship it on Friday.", "The plan is to", ", right?"), " ship it on Friday")
        // continues the sentence (CJK) while the text before is mid-sentence: no 。
        XCTAssertEqual(fit("从老家回来。", "我知道你是", "的那天"), "从老家回来")
        // between two whole sentences the full stop stays
        XCTAssertEqual(fit("中间再补一句。", "第一句。", "第三句。"), "中间再补一句。")
    }

    func testNoDoubledPunctuationAtTheStart() {
        // seen in the app: polish repeated the field's 「今天的安排：」 — the overlap goes, and its 「：」 with it
        let r = F.fit("今天的安排：下午三点开会。", before: "今天的安排：", after: "")
        XCTAssertEqual(r.text, "下午三点开会。")
        XCTAssertEqual(r.changes, ["head"])
        XCTAssertEqual(fit("：下午三点开会。", "今天的安排：", ""), "下午三点开会。")
    }

    func testNoLeadingCommaMidSentence() {
        XCTAssertEqual(fit("，然后再部署。", "先跑测试", ""), "然后再部署。")
        XCTAssertEqual(fit("，然后再部署。", "先跑测试，", ""), "然后再部署。")
    }

    func testSpacing() {
        // Latin words at either seam
        XCTAssertEqual(fit("the release notes", "Please update", "today"), " the release notes ")
        // CJK and Latin: the field's own way
        XCTAssertEqual(fit("Claude Code 里面跑", "我在", ""), " Claude Code 里面跑")          // spaced, like polish
        XCTAssertEqual(fit("Claude Code里面跑", "我用Typeless听写，在", ""), "Claude Code里面跑")   // the field writes it tight
        XCTAssertEqual(fit("配置文件", "打开 MCP 的", ""), "配置文件")                         // CJK to CJK: none
        // a space already there
        XCTAssertEqual(fit("the notes", "Please update ", " today"), "the notes")
    }

    func testMixed() {
        // 「这个 API 的▮」 + 「API 的 timeout 改成三十秒」 → the repeated 「API 的」 goes
        XCTAssertEqual(fit("API 的 timeout 改成三十秒。", "把这个 API 的", ""), " timeout 改成三十秒。")
        XCTAssertEqual(F.fit("API 的 timeout 改成三十秒。", before: "把这个 API 的", after: "").changes, ["head", "space"])
    }

    /// Regression: a long field (more than 200 characters before the cursor, CJK and emoji) crashed the fit.
    func testLongTextBeforeDoesNotCrash() {
        let before = String(repeating: "这是一段很长的文字，包含 emoji 😀 和 English words. ", count: 20) + "我知道你就是"
        let r = DictationFit.fit("就是从老家回来的。", before: before, after: "的。")
        XCTAssertEqual(r.text, "从老家回来")
        _ = DictationFit.fit("hello world", before: String(repeating: "长", count: 500), after: String(repeating: "后", count: 500))
        _ = DictationFit.fit("😀😀", before: String(repeating: "😀", count: 300), after: "")
    }
}
