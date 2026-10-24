// The Dictation Lab's pure parts (BlurtCore/DictationLab.swift; docs/design/dictation.md §Lab): the metrics against
// the fixture the Python runner is checked against too, the case schema and store, and Undo of what learning changed.
import XCTest
@testable import BlurtCore

final class DictationLabTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-lab-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// tests/fixtures/lab_metrics.jsonl, from the repository root
    static var fixture: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { u.deleteLastPathComponent() }   // Tests/BlurtCoreTests/x.swift → macos → recorder → blurt → skills → root
        return u.appendingPathComponent("tests/fixtures/lab_metrics.jsonl")
    }

    func testMetricsMatchTheSharedFixture() throws {
        let rows = try String(contentsOf: DictationLabTests.fixture, encoding: .utf8).split(separator: "\n")
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertGreaterThanOrEqual(rows.count, 8)
        for r in rows {
            let ref = r["ref"] as! String, hyp = r["hyp"] as! String, terms = r["terms"] as? [String] ?? []
            let s = LabMetrics.score(ref, hyp, terms: terms)
            XCTAssertEqual(LabMetrics.units(ref), r["units"] as? [String], ref)
            if r["wer"] is NSNull {
                XCTAssertNil(s, ref)
            } else {
                XCTAssertEqual(s?.wer, r["wer"] as? Double, ref)
                XCTAssertEqual(s?.cer, r["cer"] as? Double, ref)
                XCTAssertEqual(s?.punct, r["punct"] as? Double, ref)
                XCTAssertEqual(s?.exact, r["exact"] as? Bool, ref)
                XCTAssertEqual(s?.terms?.accuracy, r["term_accuracy"] as? Double, ref)
            }
            let d = LabMetrics.diff(ref, hyp).map { [$0.op.rawValue, $0.ref, $0.hyp] }
            XCTAssertEqual(d, r["diff"] as? [[String]], ref)
        }
    }

    func testUnitsAndRates() {
        XCTAssertEqual(LabMetrics.units("用 Claude Code 写的 PR，好吗？"), ["用", "claude", "code", "写", "的", "pr", "好", "吗"])
        XCTAssertEqual(LabMetrics.units("ＡＢＣ１２"), ["abc12"])
        XCTAssertEqual(LabMetrics.score("我们明天开会", "我们后天开会")?.wer, 0.1667)
        XCTAssertEqual(LabMetrics.score("今天开会。", "今天开会，")?.wer, 0)
        XCTAssertEqual(LabMetrics.score("今天开会。", "今天开会，")?.punct, 1)
        XCTAssertNil(LabMetrics.score("", "x"))
        let d = LabMetrics.diff("We should move the meeting.", "we should move meeting, OK")
        XCTAssertEqual(d.map(\.hyp).joined(), "we should move meeting, OK")
        XCTAssertEqual(d.map(\.ref).joined(), "We should move the meeting.")
    }

    func testTermsWantTheSpelling() {
        let r = LabMetrics.termHits(["Claude Code", "tmux", "口喷鸡"], "用 claude code 开 T mux，口喷鸡")
        XCTAssertEqual(r.hit, ["Claude Code", "口喷鸡"])
        XCTAssertEqual(r.missed, ["tmux"])
        XCTAssertEqual(LabMetrics.expectedTerms("在 Claude Code 里用 Claude", vocabulary: ["Claude", "Claude Code", "Codex"]),
                       ["Claude Code", "Claude"])
    }

    func testCaseSchemaAndStore() throws {
        let store = LabStore(dir: dir)
        var c = LabCase(id: LabStore.newID(), source: "take")
        XCTAssertEqual(c.problems, [])
        c.reference = "  今天下午三点开会  "
        c.corrected = ""
        XCTAssertEqual(c.truth, "今天下午三点开会")
        c.errors = ["term", "bogus", "punctuation"]
        XCTAssertEqual(c.errors, ["term", "punctuation"])          // known tags only, in the chips' order
        c.stars = 9
        XCTAssertEqual(c.stars, 5)
        c.good = false
        c.bundle = "com.tencent.xinWeChat"
        c.scenario = ["app": "wechat", "noise": ""]
        XCTAssertEqual(c.scenario, ["app": "wechat"])
        c.take = ["raw": "今天下午三点开会", "text": "今天下午三点开会。", "fitted": "今天下午四点开会。"]
        c.refreshMetrics(vocabulary: [])
        XCTAssertEqual(c.metrics?["wer"] as? Double, 0.125)        // against the fitted text, what was typed
        XCTAssertTrue(store.save(c))
        // a key the CLI (or a newer app) added survives a save from here
        let f = store.folder(c.id).appendingPathComponent("case.json")
        var o = try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as! [String: Any]
        o["future_key"] = 1
        try JSONSerialization.data(withJSONObject: o).write(to: f)
        var back = try XCTUnwrap(store.load(c.id))
        back.note = "说得快"
        store.save(back)
        let again = try XCTUnwrap(store.load(c.id))
        XCTAssertEqual(again.json["future_key"] as? Int, 1)
        XCTAssertEqual(again.note, "说得快")
        XCTAssertEqual(again.good, false)
        XCTAssertEqual(again.problems, [])
        XCTAssertEqual(store.list().map(\.id), [c.id])
        store.delete(c.id)
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertNil(store.load("../etc"))
    }

    func testContextIsKeptOnlyWhenIncluded() {
        var c = LabCase(id: "x", source: "take")
        XCTAssertFalse(c.contextIncluded)
        c.setContext(["before": "我知道你就是", "after": "的。", "junk": "no"])
        XCTAssertTrue(c.contextIncluded)
        XCTAssertEqual(c.context["before"], "我知道你就是")
        XCTAssertNil(c.context["junk"])
        c.setContext(nil)
        XCTAssertEqual(c.context, [:])
        c.json["context"] = ["included": false, "before": "leak"]
        XCTAssertEqual(c.problems, ["context: text kept without consent"])
    }

    func testUndoPutsBackWhatLearningChanged() throws {
        let v = DictationVocabulary(url: dir.appendingPathComponent("vocabulary.json"))
        v.add("tmux")
        let before = LabVocab.snapshot(v.url)
        _ = v.learn(heard: "cloud code", fixed: "Claude Code")          // a new suggestion
        _ = v.learn(heard: "tee mux", fixed: "tmux")                      // a known word gains a sounds-like
        let changes = LabVocab.changes(before: before, after: LabVocab.snapshot(v.url))
        XCTAssertEqual(changes.map(\.term), ["Claude Code", "tmux"])
        XCTAssertNil(changes[0].before)
        XCTAssertEqual(changes[1].summary, "tmux ← tee mux")
        // the user changed "tmux" in Settings meanwhile: that one stays as they left it
        v.editRaw { ts in if let i = ts.firstIndex(where: { $0["term"] as? String == "tmux" }) { ts[i]["hits"] = 42 } }
        XCTAssertEqual(LabVocab.revert(changes, in: v), ["Claude Code"])
        XCTAssertEqual(v.load().map(\.term), ["tmux"])
        XCTAssertEqual(v.load().first?.hits, 42)
        // round trip through JSON (the CLI's changes)
        let c = LabVocab.Change(json: ["term": "x", "before": NSNull(), "after": ["term": "x"]])
        XCTAssertNil(c?.before)
        XCTAssertNotNil(c?.after)
    }
}
