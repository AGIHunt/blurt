// Custom words and learning from the user's fixes (BlurtCore/DictationVocabulary.swift, DictationLearn.swift;
// docs/design/dictation.md §Custom words, §Auto-learn).
import XCTest
@testable import BlurtCore

final class DictationVocabularyTests: XCTestCase {
    var dir: URL!
    var v: DictationVocabulary!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-vocab-\(UUID().uuidString)")
        v = DictationVocabulary(url: dir.appendingPathComponent("vocabulary.json"))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testAddRemoveAndTheFile() throws {
        XCTAssertTrue(v.add("Claude Code", soundsLike: ["cloud code"]))
        XCTAssertFalse(v.add("Claude Code"))                         // already there
        XCTAssertFalse(v.add("   "))
        XCTAssertTrue(v.add("tmux"))
        XCTAssertEqual(v.active().map(\.term).sorted(), ["Claude Code", "tmux"])
        // the file python reads: schema + terms with snake_case keys
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: v.url)) as? [String: Any]
        XCTAssertEqual(o?["schema"] as? Int, 1)
        let first = (o?["terms"] as? [[String: Any]])?.first { $0["term"] as? String == "Claude Code" }
        XCTAssertEqual(first?["sounds_like"] as? [String], ["cloud code"])
        XCTAssertEqual(first?["source"] as? String, "manual")
        XCTAssertEqual(first?["state"] as? String, "active")
        XCTAssertNotNil(first?["added"] as? String)
        v.remove("tmux")                                              // a manual word just goes
        XCTAssertEqual(v.load().map(\.term), ["Claude Code"])
        XCTAssertEqual(v.payload().first?["term"] as? String, "Claude Code")
    }

    func testSeedOnceAndRemovedStaysRemoved() {
        let added = v.seed(projects: [(name: "Bug Agent", key: "BA"), (name: "X", key: "X")])
        XCTAssertEqual(added, ["Claude Code", "Codex", "blurt", "口喷鸡", "Bug Agent", "BA"])   // 1-letter ones skipped
        XCTAssertTrue(v.load().allSatisfy { $0.source == .project })
        XCTAssertEqual(v.load().first { $0.term == "口喷鸡" }?.soundsLike, ["口喷机", "口碰鸡"])
        v.remove("Codex")
        XCTAssertEqual(v.load().first { $0.term == "Codex" }?.state, .removed)
        XCTAssertEqual(v.seed(projects: [(name: "Bug Agent", key: "BA")]), [])   // nothing comes back
        XCTAssertFalse(v.active().map(\.term).contains("Codex"))
        XCTAssertTrue(v.add("Codex"))                                     // unless the user adds it by hand
        XCTAssertEqual(v.load().first { $0.term == "Codex" }?.source, .manual)
    }

    func testLearnSuggestThenAcceptOnTheSecondFix() {
        XCTAssertEqual(v.learn(heard: "cloud", fixed: "Claude"), .suggested("Claude"))
        XCTAssertEqual(v.suggestions().map(\.term), ["Claude"])
        XCTAssertTrue(v.active().isEmpty)
        XCTAssertEqual(v.learn(heard: "cloud", fixed: "Claude"), .learned("Claude"))
        XCTAssertEqual(v.active().first?.soundsLike, ["cloud"])
        XCTAssertEqual(v.active().first?.source, .learned)
        XCTAssertEqual(v.learn(heard: "clawed", fixed: "Claude"), .known("Claude"))   // a known word grows
        XCTAssertEqual(v.active().first?.soundsLike, ["cloud", "clawed"])
    }

    func testCaseOrSpacingFixIsUsedAtOnce() {
        XCTAssertEqual(v.learn(heard: "github", fixed: "GitHub"), .learned("GitHub"))
        XCTAssertEqual(v.active().first?.soundsLike, [])                  // the deterministic pass does case itself
        XCTAssertEqual(v.learn(heard: "Sense Voice", fixed: "SenseVoice"), .learned("SenseVoice"))
    }

    func testRejectedIsNeverSuggestedAgainAndUndoForgets() {
        XCTAssertEqual(v.learn(heard: "op", fixed: "option"), .suggested("option"))
        v.reject("option")
        XCTAssertNil(v.learn(heard: "op", fixed: "option"))
        XCTAssertEqual(v.learn(heard: "claude", fixed: "Claude"), .learned("Claude"))
        v.forget("Claude")                                                 // the island's Undo
        XCTAssertNil(v.load().first { $0.term == "Claude" })
        v.add("Manual")
        v.forget("Manual")                                                 // Undo never removes the user's own words
        XCTAssertNotNil(v.load().first { $0.term == "Manual" })
        XCTAssertNil(v.learn(heard: "same", fixed: "same"))
    }

    func testHitsAndAccept() {
        v.add("tmux")
        v.recordHits(["tmux", "tmux", "unknown"])
        XCTAssertEqual(v.active().first?.hits, 2)
        _ = v.learn(heard: "坤", fixed: "Qwen")
        v.accept("Qwen")
        XCTAssertTrue(v.active().map(\.term).contains("Qwen"))
    }

    func testCorruptFileIsEmpty() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: v.url)
        XCTAssertEqual(v.load(), [])
        XCTAssertTrue(v.add("x1"))
    }
}

final class DictationLearnTests: XCTestCase {
    func fixes(_ a: String, _ b: String) -> [DictationLearn.Fix] {
        DictationLearn.fixes(typed: a, edited: b, isCommonWord: { ["there", "their", "the", "table"].contains($0) })
    }

    func testTokens() {
        XCTAssertEqual(DictationLearn.tokens("我用Claude Code跑BA-12, don't").map(\.text),
                       ["我", "用", "Claude", "Code", "跑", "BA-12", "don't"])
    }

    func testEnglishFixes() {
        XCTAssertEqual(fixes("I asked cloud about it.", "I asked Claude about it."),
                       [.init(heard: "cloud", fixed: "Claude", kind: .spelling)])
        XCTAssertEqual(fixes("open cloud code in tmux", "open Claude Code in tmux"),
                       [.init(heard: "cloud code", fixed: "Claude Code", kind: .spelling)])
        XCTAssertEqual(fixes("press the right op key", "press the right option key"),
                       [.init(heard: "op", fixed: "option", kind: .spelling)])
        XCTAssertEqual(fixes("bl is ready", "blurt is ready"), [.init(heard: "bl", fixed: "blurt", kind: .spelling)])
        XCTAssertEqual(fixes("push it to github now", "push it to GitHub now"),
                       [.init(heard: "github", fixed: "GitHub", kind: .caseOrSpacing)])
    }

    func testChineseFixes() {
        // one changed character is learned with the unchanged ones before it
        XCTAssertEqual(fixes("口喷机现在支持了", "口喷鸡现在支持了"), [.init(heard: "口喷机", fixed: "口喷鸡", kind: .sound)])
        XCTAssertEqual(fixes("我用克劳德写代码", "我用Claude写代码").first?.fixed, "Claude")
    }

    func testNotRecognitionFixes() {
        XCTAssertEqual(fixes("put it on the table", "put it on the desk"), [])          // a different word
        XCTAssertEqual(fixes("I think there car is red", "I think their car is red"), [])  // grammar, a common word
        XCTAssertEqual(fixes("short note", "a completely different sentence about something else"), [])  // a rewrite
        XCTAssertEqual(fixes("same text", "same text"), [])
        XCTAssertEqual(fixes("open cloud", "open cloud and close it"), [])                // only an insertion
        XCTAssertEqual(fixes("a b c d e f", "a x c y e z g"), [])                         // too many changes
    }

    func testSimilarity() {
        XCTAssertEqual(DictationLearn.similarity("claude", "Claude"), .caseOrSpacing)
        XCTAssertEqual(DictationLearn.similarity("kodex", "Codex"), .spelling)
        XCTAssertNil(DictationLearn.similarity("table", "desk"))
        XCTAssertEqual(DictationLearn.pinyin("口喷鸡"), "koupenji")
        XCTAssertEqual(DictationLearn.similarity("口喷机", "口喷鸡"), .sound)
    }

    func testLocateTheTypedText() {
        let doc = "Notes\nI asked Claude about it. Then more text."
        XCTAssertEqual(DictationLearn.locate(in: doc, prefix: "Notes\n", suffix: " Then more", near: 6, maxLength: 200),
                       "I asked Claude about it.")
        XCTAssertNil(DictationLearn.locate(in: "all gone", prefix: "Notes\n", suffix: " Then", near: 6, maxLength: 200))
        XCTAssertEqual(DictationLearn.locate(in: "hello world", prefix: "", suffix: "", near: 0, maxLength: 50), "hello world")
        XCTAssertNil(DictationLearn.locate(in: "x" + String(repeating: "y", count: 300) + "z", prefix: "x", suffix: "z", near: 1, maxLength: 100))
        // the prefix nearest the dictation wins when it occurs twice
        XCTAssertEqual(DictationLearn.locate(in: "a: one. a: two.", prefix: "a: ", suffix: ".", near: 11, maxLength: 50), "two")
    }

    func testCommonWords() {
        XCTAssertTrue(DictationLearn.isCommonWord("cloud"))
        XCTAssertFalse(DictationLearn.isCommonWord("tmux"))
    }
}
