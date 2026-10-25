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
        XCTAssertEqual(o?["schema"] as? Int, DictationVocabulary.schema)
        let first = (o?["terms"] as? [[String: Any]])?.first { $0["term"] as? String == "Claude Code" }
        XCTAssertEqual(first?["sounds_like"] as? [String], ["cloud code"])
        XCTAssertEqual(first?["source"] as? String, "manual")
        XCTAssertEqual(first?["state"] as? String, "active")
        XCTAssertNotNil(first?["added"] as? String)
        v.remove("tmux")                                              // a manual word just goes
        XCTAssertEqual(v.load().map(\.term), ["Claude Code"])
        XCTAssertEqual(v.payload().first?["term"] as? String, "Claude Code")
        // the request carries what the file says (source, hits): the server ranks the app's words exactly as it ranks
        // the file's own (the Dictation Lab), so both send the speech model the same words in the same order
        XCTAssertEqual(v.payload().first?["source"] as? String, "manual")
        XCTAssertEqual(v.payload().first?["hits"] as? Int, 0)
    }

    func testSeedOnceAndRemovedStaysRemoved() {
        let added = v.seed(projects: [(name: "Bug Agent", key: "BA"), (name: "X", key: "X"),
                                      (name: "e2e test project with a long name", key: "e2e-test-project-long")])
        let builtIn = DictationVocabulary.builtIn
        XCTAssertEqual(added, ["Bug Agent", "BA"] + builtIn)        // 1-letter and > 3-word project names skipped
        XCTAssertEqual(v.userWords().map(\.term), ["Bug Agent", "BA"])
        XCTAssertTrue(v.userWords().allSatisfy { $0.source == .project })
        XCTAssertEqual(v.builtInWords().map(\.term), builtIn)
        // built-in words are their own source ("default"), removable like the rest, and carry no sounds-likes
        XCTAssertTrue(v.load().allSatisfy { $0.soundsLike.isEmpty })
        XCTAssertTrue(String(data: try! Data(contentsOf: v.url), encoding: .utf8)!.contains("\"source\" : \"default\""))
        v.remove("Typeless")
        XCTAssertEqual(v.load().first { $0.term == "Typeless" }?.state, .removed)
        XCTAssertFalse(v.payload().contains { $0["term"] as? String == "Typeless" })
        XCTAssertFalse(v.builtInWords().map(\.term).contains("Typeless"))
        v.remove("Codex")
        XCTAssertEqual(v.load().first { $0.term == "Codex" }?.state, .removed)
        XCTAssertEqual(v.seed(projects: [(name: "Bug Agent", key: "BA")]), [])   // nothing comes back
        XCTAssertFalse(v.active().map(\.term).contains("Codex"))
        XCTAssertTrue(v.add("Codex"))                                     // unless the user adds it by hand
        XCTAssertEqual(v.load().first { $0.term == "Codex" }?.source, .manual)
    }

    func testTheSeedIsAShortListOfProductNames() {
        let d = DictationVocabulary.builtIn
        for t in ["Claude Code", "Codex", "Cursor", "Typeless", "MCP", "GitHub", "OpenAI", "Anthropic", "DeepSeek", "Qwen"] {
            XCTAssertTrue(d.contains(t), t)
        }
        XCTAssertEqual(Set(d).count, d.count)                               // no duplicates
        XCTAssertLessThanOrEqual(d.count, 20)
        XCTAssertTrue(DictationVocabulary.retiredSeed.isDisjoint(with: d))
    }

    /// An install seeded by schema 1 (the long seed with people's names and shipped sounds-likes) is migrated once:
    /// untouched retired words go, the user's own words and what they taught stay.
    func testSchemaOneIsMigrated() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func t(_ term: String, _ sl: [String], _ source: String, _ state: String = "active", hits: Int = 0) -> [String: Any] {
            ["term": term, "sounds_like": sl, "source": source, "state": state, "hits": hits, "seen": 0, "added": "2026-10-01T10:00:00Z"]
        }
        let old: [String: Any] = ["schema": 1, "terms": [
            t("Claude Code", ["cloud code", "clock code", "claude co", "clod code"], "project", hits: 4),
            t("Codex", ["codec", "codecs", "kodex"], "project"),
            t("Typeless", ["type less", "TypePlus"], "default"),
            t("Musk", [], "default"), t("Sam Altman", [], "default"), t("Sora", [], "default", "removed"),
            t("Grok", [], "manual"),                                          // the user added it: theirs
            t("Bug Agent", [], "project"), t("Asopic", [], "learned"),
            t("e2e test project with a long name", [], "project"),         // seeded before the three-word limit
            // retired seeds the user touched: a sounds-like taught by a correction, used, or both
            t("Mistral", ["mistrial"], "default"), t("Nvidia", [], "default", hits: 2),
            t("OpenClaw", ["open claw", "open clore"], "default"),
            t("a long project name the user dictates", [], "project", hits: 3),
            t("Midjourney", [], "default", "removed", hits: 1),             // removed by the user: stays gone
        ]]
        try JSONSerialization.data(withJSONObject: old).write(to: v.url)
        v.seed(projects: [(name: "Bug Agent", key: "BA")])
        let all = v.load()
        let names = all.map(\.term)
        for gone in ["Musk", "Sam Altman", "Sora", "e2e test project with a long name", "Midjourney"] {
            XCTAssertFalse(names.contains(gone), gone)
        }
        for kept in ["Grok", "Bug Agent", "Asopic", "BA"] { XCTAssertTrue(names.contains(kept), kept) }
        // what the user taught stays, as their own word, with its hints and hits (only the shipped sounds-like goes)
        let mistral = all.first { $0.term == "Mistral" }
        XCTAssertEqual(mistral?.source, .learned)
        XCTAssertEqual(mistral?.state, .active)
        XCTAssertEqual(mistral?.soundsLike, ["mistrial"])
        XCTAssertEqual(all.first { $0.term == "Nvidia" }?.hits, 2)
        XCTAssertEqual(all.first { $0.term == "Nvidia" }?.source, .learned)
        XCTAssertEqual(all.first { $0.term == "OpenClaw" }?.soundsLike, ["open clore"])
        XCTAssertEqual(all.first { $0.term == "a long project name the user dictates" }?.source, .learned)
        let cc = all.first { $0.term == "Claude Code" }
        XCTAssertEqual(cc?.soundsLike, ["clod code"])                       // only what the user's fixes taught
        XCTAssertEqual(cc?.source, .builtIn)
        XCTAssertEqual(cc?.hits, 4)
        XCTAssertEqual(all.first { $0.term == "Codex" }?.soundsLike, [])
        XCTAssertEqual(all.first { $0.term == "Typeless" }?.soundsLike, [])
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: v.url)) as? [String: Any]
        XCTAssertEqual(o?["schema"] as? Int, 2)
        // once: a sounds-like learned after the migration stays
        _ = v.learn(heard: "codec", fixed: "Codex")
        v.seed(projects: [])
        XCTAssertEqual(v.load().first { $0.term == "Codex" }?.soundsLike, ["codec"])
    }

    func testASavedCorrectionSuggestsAndAnExplicitOneIsUsedAtOnce() {
        // the Dictation page's "Save correction": the words found are offered (its note adds them with one click)
        let r = v.learnCorrection(typed: "后来他去了Tipless做产品", corrected: "后来他去了Typeless做产品")
        XCTAssertEqual(r.map(\.fix.heard), ["Tipless"])
        XCTAssertEqual(r.first?.result, .suggested("Typeless"))
        XCTAssertFalse(v.active().map(\.term).contains("Typeless"))
        XCTAssertEqual(v.suggestions().map(\.term), ["Typeless"])
        // the note's "Add": in use at once
        XCTAssertEqual(v.learnCorrection(typed: "后来他去了Tipless做产品", corrected: "后来他去了Typeless做产品", activate: true)
            .first?.result, .learned("Typeless"))
        XCTAssertTrue(v.active().map(\.term).contains("Typeless"))
        XCTAssertEqual(v.learn(heard: "Asopic", fixed: "Anthropic", explicit: true), .learned("Anthropic"))
        XCTAssertEqual(v.active().first { $0.term == "Anthropic" }?.soundsLike, ["Asopic"])
        // a rewrite teaches nothing
        XCTAssertTrue(v.learnCorrection(typed: "今天下午开会", corrected: "明天上午我们一起去公司吃饭然后开会").isEmpty)
        // a suggestion waiting for its second sighting is taken by an explicit one
        XCTAssertEqual(v.learn(heard: "Kimmi", fixed: "Kimi"), .suggested("Kimi"))
        XCTAssertEqual(v.learn(heard: "Kimmi", fixed: "Kimi", explicit: true), .learned("Kimi"))
        // a word the user rejected stays rejected
        v.reject("Kimi")
        XCTAssertNil(v.learn(heard: "Kimmy", fixed: "Kimi", explicit: true))
    }

    func testTheWordsTabsEdits() {
        // pasting "a, b, c" adds three; a word already there is flagged, not added twice
        XCTAssertEqual(DictationVocabulary.entries("Claude Code, tmux、Kimi；\n tmux"), ["Claude Code", "tmux", "Kimi"])
        v.add("tmux")
        XCTAssertTrue(v.isActive("tmux"))
        XCTAssertFalse(v.isActive("Kimi"))
        // remove → Undo puts it back exactly (source, sounds-likes, hits)
        _ = v.learn(heard: "cloud", fixed: "Claude", explicit: true)
        v.recordHits(["Claude"])
        let before = v.load().first { $0.term == "Claude" }!
        v.remove("Claude")
        XCTAssertEqual(v.load().first { $0.term == "Claude" }?.state, .rejected)
        v.restore(before)
        XCTAssertEqual(v.load().first { $0.term == "Claude" }, before)
        // double-click → a new spelling keeps the word's history
        XCTAssertTrue(v.rename("Claude", to: "Claude AI"))
        XCTAssertEqual(v.load().first { $0.term == "Claude AI" }?.hits, before.hits)
        XCTAssertFalse(v.rename("Claude AI", to: "tmux"))                  // another word already
        XCTAssertFalse(v.rename("Claude AI", to: "a, b"))
    }

    func testTwoFixesSideBySideAreTwoWordsNeverOneWithAComma() {
        // dogfood d54: 绘画 BA 三 → 会话，BA-3 learned "会话，BA-3" as one active word
        let r = v.learnCorrection(typed: "我们先看绘画 BA 三的进度", corrected: "我们先看会话，BA-3的进度", activate: true)
        XCTAssertFalse(r.contains { DictationVocabulary.hasSentencePunctuation($0.fix.fixed) })
        XCTAssertEqual(r.map(\.fix.fixed), ["会话"])
        XCTAssertFalse(v.load().contains { $0.term.contains("，") })
        // and the store refuses one whatever asks
        XCTAssertNil(v.learn(heard: "a b", fixed: "Alpha, Beta", explicit: true))
        XCTAssertTrue(DictationVocabulary.hasSentencePunctuation("会话，BA-3"))
        XCTAssertFalse(DictationVocabulary.hasSentencePunctuation("BA-3"))
        XCTAssertFalse(DictationVocabulary.hasSentencePunctuation("Node.js"))
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
        XCTAssertEqual(v.active().first?.soundsLike, [])                  // a case fix teaches the spelling, nothing more
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

    func testOrdinaryWordIsLearnedAsAPhrase() {
        let f = DictationLearn.fixes(typed: "review the pool request before lunch", edited: "review the pull request before lunch",
                                     isCommonWord: { ["pull", "pool", "request", "the"].contains($0) })
        XCTAssertEqual(f, [.init(heard: "pool request", fixed: "pull request", kind: .spelling)])
        // no plain neighbour to anchor it: nothing
        XCTAssertEqual(DictationLearn.fixes(typed: "the pool", edited: "the pull", isCommonWord: { _ in true }), [])
    }

    func testChineseFixes() {
        // one changed character is learned with the unchanged ones before it
        XCTAssertEqual(fixes("口喷机现在支持了", "口喷鸡现在支持了"), [.init(heard: "口喷机", fixed: "口喷鸡", kind: .sound)])
        XCTAssertEqual(fixes("我用克劳德写代码", "我用Claude写代码").first?.fixed, "Claude")
    }

    func testTheWatchLearnsTheFinalEditNotAPauseInIt() {
        // dogfood d48: Kubernetes → Kuberneetes (a pause) → K8s taught "Kuberneetes" and never K8s
        var w = DictationLearn.EditWatch(typed: "deploy it to cooper netties today")
        w.saw("deploy it to Kuberneetes today")          // a still tick mid-edit: nothing learned yet
        w.saw("deploy it to Kubernetes today")
        let e = try? XCTUnwrap(w.end())
        XCTAssertEqual(e?.typed, "deploy it to cooper netties today")   // always from what was typed
        XCTAssertEqual(e?.edited, "deploy it to Kubernetes today")
        XCTAssertNil(DictationLearn.EditWatch(typed: "same").end())     // untouched: nothing
    }

    func testARunIsCutAtPunctuationAndScript() {
        // two fixes side by side: each part pairs with what sounds like it, the comma never inside a term
        XCTAssertEqual(fixes("先看绘画 BA 三的进度", "先看会话，BA-3的进度"), [.init(heard: "绘画", fixed: "会话", kind: .sound)])
        XCTAssertEqual(fixes("ask cloud, code it", "ask Claude; Codex it").map(\.fixed), ["Claude", "Codex"])
        // a name with a space or a hyphen stays one run
        XCTAssertEqual(fixes("open cloud code in tmux", "open Claude Code in tmux").map(\.fixed), ["Claude Code"])
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

    func testLongChineseProjectNamesAreNotSeeded() {
        XCTAssertTrue(DictationVocabulary.seedable(project: "口喷鸡"))
        XCTAssertTrue(DictationVocabulary.seedable(project: "Bug Agent"))
        XCTAssertFalse(DictationVocabulary.seedable(project: "口喷鸡 iOS 客户端（第二版重构和设计稿整理）"))
    }
}
