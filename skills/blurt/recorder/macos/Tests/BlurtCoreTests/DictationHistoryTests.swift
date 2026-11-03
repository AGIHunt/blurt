// BlurtCore/DictationHistory.swift: the append-only log and its edit lines, read back in order.
import Foundation
import XCTest
@testable import BlurtCore

final class DictationHistoryTests: XCTestCase {
    func entry(_ id: String, _ text: String, _ t: TimeInterval) -> DictationEntry {
        DictationEntry(id: id, time: Date(timeIntervalSince1970: t), app: "Notes", bundle: nil, duration: 2, raw: text,
                       polished: nil, text: text, model: nil, fellBack: false, reason: nil, insert: "pasted")
    }

    /// v0.9: the speech model's language call is kept per piece, so a take typed in the wrong language shows in the
    /// history and in the Lab (with how close the call was).
    func testTheLanguageTagIsKeptAndACloseCallIsFlagged() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = DictationHistory(url: dir.appendingPathComponent("history.jsonl"))
        var e = entry("d-t", "这个 feature 下周上线。", 1000)
        e.asrTags = [["tag": "Chinese", "p_en": 0.9497, "p_zh": 0.0503, "margin": -2.355, "p_en_words": 0.994],
                     ["tag": "Chinese", "p_en": 0.99, "p_zh": 0.01, "margin": -0.697, "redone": true],
                     ["tag": "English", "p_en": 0.9999, "p_zh": 0.0001, "margin": 3.917]]
            .compactMap(DictationLanguageTag.init(json:))
        h.append(e)
        let back = try XCTUnwrap(h.load().first?.asrTags)
        XCTAssertEqual(back.count, 3)
        XCTAssertEqual(back[0].prefer, "zh")
        XCTAssertEqual(back[0].pPref ?? 0, 0.0503, accuracy: 1e-6)
        XCTAssertEqual(back[0].pEnWords ?? 0, 0.994, accuracy: 1e-6)
        XCTAssertFalse(back[0].fragile)
        XCTAssertTrue(back[1].redone)
        XCTAssertFalse(back[2].fragile)                              // a clear English piece is no close call
        XCTAssertEqual(DictationLanguageTag.closest(back)?.margin ?? 0, -0.697, accuracy: 1e-6)
        XCTAssertTrue(DictationLanguageTag.closest(back)?.fragile ?? false)
        XCTAssertNil(DictationLanguageTag.closest([[String: Any]]()))
        XCTAssertNil(entry("d-old", "x", 1).asrTags)                 // an older entry has none
    }

    /// v1.0.2: a kept take keeps its streamed pieces (cuts, pauses, each polish window), so the Lab can replay it as
    /// it ran — through prune as well.
    func testAKeptTakesPiecesSurviveTheRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = DictationHistory(url: dir.appendingPathComponent("history.jsonl"))
        var e = entry("d-p", "飞书会话里面的消息。", Date().timeIntervalSince1970)
        e.pieces = [["index": 0, "start": 0.0, "end": 1.504, "pause_after": 1.42, "asr_text": "飞书会话。", "raw": "飞书会话。",
                     "polish_in": "飞书会话", "text": "", "polished": "飞书会话", "fell_back": false, "reason": NSNull()],
                    ["index": 1, "start": 1.5, "end": 3.0, "pause_after": NSNull(), "asr_text": "里面的消息。", "raw": "里面的消息。",
                     "polish_in": "飞书会话。里面的消息", "text": "飞书会话里面的消息。", "polished": "飞书会话里面的消息。",
                     "fell_back": false]].compactMap(DictationPieceRecord.init(json:))
        h.append(e)
        XCTAssertEqual(h.prune(days: 30), 0)
        let back = try XCTUnwrap(h.load().first?.pieces)
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[0].end, 1.5, accuracy: 1e-9)
        XCTAssertEqual(back[0].pauseAfter ?? 0, 1.42, accuracy: 1e-9)
        XCTAssertNil(back[1].pauseAfter)
        XCTAssertEqual(back[1].polishIn, "飞书会话。里面的消息")
        XCTAssertEqual(back[1].committed, "飞书会话里面的消息。")
        XCTAssertNil(entry("d-old", "x", 1).pieces)                     // only kept takes carry them
    }

    /// v0.9 dogfood: Undo of a delete brought back a row without its recording (Retry and Add to Lab gone). The
    /// recording now waits aside until Undo is unlikely.
    func testADeletedRecordingComesBackWithUndoAndGoesLater() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = DictationHistory(url: dir.appendingPathComponent("history.jsonl"))
        try FileManager.default.createDirectory(at: h.audioDir, withIntermediateDirectories: true)
        var e = entry("d-a", "kept", 1000)
        e.audio = "audio/d-a.wav"
        let wav = h.resolve("audio/d-a.wav")
        try Data("RIFF".utf8).write(to: wav)
        h.append(e)
        h.delete(["d-a"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.deletedDir.appendingPathComponent("d-a.wav").path))
        // Undo: the recording is back where the entry says
        XCTAssertTrue(h.restoreAudio(e))
        h.append(e)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
        XCTAssertEqual(h.load().first?.audio, "audio/d-a.wav")
        // deleted again and purged: gone for good, Undo can't bring it
        h.delete(["d-a"])
        h.purgeDeleted(["d-a.wav"])
        XCTAssertFalse(h.restoreAudio(e))
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: h.deletedDir.path))?.isEmpty ?? true)
        // the launch prune purges what is left aside
        h.append(e)
        try Data("RIFF".utf8).write(to: wav)
        h.delete(["d-a"])
        h.prune(days: 30)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: h.deletedDir.path))?.isEmpty ?? true)
    }

    func testDeleteThenWriteAgainComesBackOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = DictationHistory(url: dir.appendingPathComponent("history.jsonl"))
        let a = entry("d-a", "first", 1000), b = entry("d-b", "second", 2000)
        h.append(a)
        h.append(b)
        h.markItem("d-a", item: "BA-1", uid: "U1")
        h.delete(["d-a"])
        XCTAssertEqual(h.load().map(\.id), ["d-b"])
        // the window's ⌘Z after a delete writes the entry (and its item link) again
        h.append(a)
        h.markItem("d-a", item: "BA-1", uid: "U1")
        let back = h.load()
        XCTAssertEqual(back.map(\.id), ["d-b", "d-a"])            // newest first, each once
        XCTAssertEqual(back.last?.item, "BA-1")
        h.delete(["d-a", "d-b"])
        XCTAssertTrue(h.load().isEmpty)
    }

    func testClearKeepsTheAudioOfATakeStillOnItsWay() throws {
        // dogfood D57: Clear History during a take deleted its wav, and the take then said "nothing heard"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir); DictationHistory.liveIDs = { [] } }
        let h = DictationHistory(url: dir.appendingPathComponent("history.jsonl"))
        h.append(entry("d-old", "kept audio", 1000))
        try FileManager.default.createDirectory(at: h.audioDir, withIntermediateDirectories: true)
        for n in ["d-old.wav", "d-live.wav", "d-live-p0.wav"] { try Data([1]).write(to: h.audioDir.appendingPathComponent(n)) }
        DictationHistory.liveIDs = { ["d-live"] }
        let cleared = expectation(forNotification: DictationHistory.changed, object: h)
        h.clear()
        wait(for: [cleared], timeout: 1)
        XCTAssertTrue(h.load().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: h.audioDir.path).sorted(), ["d-live-p0.wav", "d-live.wav"])
    }

    func testACorrectionCanBeTakenBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = DictationHistory(url: dir.appendingPathComponent("history.jsonl"))
        h.append(entry("d-u", "绘画 BA 三", 1000))
        h.correct("d-u", text: "会话 BA-3")
        XCTAssertEqual(h.load().first?.finalText, "会话 BA-3")
        h.correct("d-u", text: nil)                                       // ⌘Z
        XCTAssertNil(h.load().first?.corrected)
        XCTAssertEqual(h.load().first?.finalText, "绘画 BA 三")
    }

    func testAReformatInTheFieldIsTheEntrysTextNow() throws {
        // dogfood D52: after a chip reformat the detail still showed the old prose as "typed"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = DictationHistory(url: dir.appendingPathComponent("history.jsonl"))
        h.append(entry("d-r", "first a then b", 1000))
        h.restyle("d-r", DictationReformatRecord(action: "reformat", from: "light", to: "structured", replaced: true,
                                                 text: "1. a\n2. b", before: "first a then b"))
        var e = try XCTUnwrap(h.load().first)
        XCTAssertEqual(e.text, "1. a\n2. b")
        XCTAssertEqual(e.typedFirst, "first a then b")
        // copied instead (the user had edited it): the entry's text stays
        h.restyle("d-r", DictationReformatRecord(action: "reformat", from: "structured", to: "verbatim", replaced: false))
        e = try XCTUnwrap(h.load().first)
        XCTAssertEqual(e.text, "1. a\n2. b")
        XCTAssertEqual(e.style?.reformats.count, 2)
    }

    func testACorrectionIsKeptBesideWhatWasTyped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = DictationHistory(url: dir.appendingPathComponent("history.jsonl"))
        h.append(entry("d-c", "CEO 是 Dario 的 Asopic", Date().timeIntervalSince1970))
        XCTAssertNil(h.load().first?.corrected)
        h.correct("d-c", text: "CEO 是 Dario 的 Anthropic")
        h.correct("d-missing", text: "nothing to correct")              // an unknown id is ignored
        var e = try XCTUnwrap(h.load().first)
        XCTAssertEqual(e.text, "CEO 是 Dario 的 Asopic")
        XCTAssertEqual(e.corrected, "CEO 是 Dario 的 Anthropic")
        XCTAssertEqual(e.finalText, "CEO 是 Dario 的 Anthropic")
        h.correct("d-c", text: "CEO 是 Dario 的 Anthropic。")             // the last correction wins
        XCTAssertEqual(h.load().first?.finalText, "CEO 是 Dario 的 Anthropic。")
        XCTAssertEqual(h.prune(days: 30), 0)                              // prune keeps it on the entry's own line
        e = try XCTUnwrap(h.load().first)
        XCTAssertEqual(e.corrected, "CEO 是 Dario 的 Anthropic。")
        XCTAssertTrue(try String(contentsOf: h.url, encoding: .utf8).contains("\"corrected\""))
    }

    func testVocabularyFieldsSurvivePruneAndOldLinesStillRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = DictationHistory(url: dir.appendingPathComponent("history.jsonl"))
        var e = entry("d-v", "用 Claude Code", Date().timeIntervalSince1970)
        e.termsApplied = ["Claude Code"]
        e.contextUsed = true
        h.append(e)
        h.append(entry("d-old", "old", 1000))                          // prune rewrites the file
        XCTAssertEqual(h.prune(days: 30), 1)
        let back = h.load()
        XCTAssertEqual(back.map(\.id), ["d-v"])
        XCTAssertEqual(back.first?.termsApplied, ["Claude Code"])
        XCTAssertEqual(back.first?.contextUsed, true)
        XCTAssertNil(back.first?.context)                               // never stored unless debugging
        let line = try String(contentsOf: h.url, encoding: .utf8)
        XCTAssertTrue(line.contains("\"terms_applied\":[\"Claude Code\"]"))
        XCTAssertTrue(line.contains("\"context_used\":true"))
        // an entry written before these fields existed reads as nil, not false
        try Data(#"{"id":"d-x","raw":"hi","t":"2026-10-23T10:00:00+08:00"}"#.utf8).write(to: h.url)
        XCTAssertNil(h.load().first?.termsApplied)
        XCTAssertNil(h.load().first?.contextUsed)
        XCTAssertNil(h.load().first?.timing)
    }

    func testStageTimingsAndRepairsAreKept() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = DictationHistory(url: dir.appendingPathComponent("history.jsonl"))
        var e = entry("d-t", "长的一段", Date().timeIntervalSince1970)
        e.timing = ["asr_ms": 180, "polish_ms": 240, "load_ms": 0, "total_ms": 450, "segments": 6, "asr_ms_all": 999]
        e.repaired = ["句子短的时候"]
        e.fitted = ["head", "tail"]
        h.append(e)
        let line = try String(contentsOf: h.url, encoding: .utf8)
        XCTAssertTrue(line.contains("\"total_ms\":450") && line.contains("\"segments\":6") && line.contains("\"asr_ms\":180"))
        XCTAssertFalse(line.contains("asr_ms_all"))                    // only the documented keys
        XCTAssertEqual(h.load().first?.timing?["polish_ms"], 240)
        XCTAssertEqual(h.load().first?.repaired, ["句子短的时候"])
        XCTAssertEqual(h.load().first?.fitted, ["head", "tail"])          // fitted at the cursor
        XCTAssertEqual(h.prune(days: 30), 0)                             // prune keeps them
        XCTAssertEqual(h.load().first?.timing?["load_ms"], 0)
    }

    func testOrphanedAudioGoesAtPrune() throws {
        // dict025: a take dropped or cut short by a quit left its wav (and its streamed pieces) with no entry
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = DictationHistory(url: dir.appendingPathComponent("history.jsonl"))
        let fm = FileManager.default
        try fm.createDirectory(at: h.audioDir, withIntermediateDirectories: true)
        let lab = dir.appendingPathComponent("lab")
        try fm.createDirectory(at: lab, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-2 * 3600)
        func wav(_ name: String, in d: URL? = nil, at t: Date = old) throws {
            let f = (d ?? h.audioDir).appendingPathComponent(name)
            try Data([0, 1, 2]).write(to: f)
            try fm.setAttributes([.modificationDate: t], ofItemAtPath: f.path)
        }
        var kept = entry("d-kept", "kept", Date().timeIntervalSince1970)
        kept.audio = "audio/d-kept.wav"                                   // keep_audio: its entry points at it
        h.append(kept)
        try wav("d-kept.wav")
        try wav("d-lost.wav")                                             // a take whose result was dropped
        try wav("d-lost-p1.wav")                                          // and a piece of it
        try wav("d-now.wav", at: Date())                                  // a take still being recorded
        try wav("lab-take.wav", in: lab)                                  // the Lab's own recordings
        try Data("x".utf8).write(to: h.audioDir.appendingPathComponent("notes.txt"))
        h.prune(days: 30)
        let left = Set(try fm.contentsOfDirectory(atPath: h.audioDir.path))
        XCTAssertEqual(left, ["d-kept.wav", "d-now.wav", "notes.txt"])
        XCTAssertTrue(fm.fileExists(atPath: lab.appendingPathComponent("lab-take.wav").path))
        // without a history file at all, an old wav is an orphan too
        let h2 = DictationHistory(url: dir.appendingPathComponent("other/history.jsonl"))
        try fm.createDirectory(at: h2.audioDir, withIntermediateDirectories: true)
        try Data([0]).write(to: h2.audioDir.appendingPathComponent("d-x.wav"))
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: h2.audioDir.appendingPathComponent("d-x.wav").path)
        XCTAssertEqual(h2.pruneOrphanAudio(), ["d-x.wav"])
    }

    /// Dogfood: quitting during a take left its recording with no entry, and a launch an hour later deleted it.
    func testATakeCutShortByAQuitComesBackAsInterruptedWithItsRecording() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = DictationHistory(url: dir.appendingPathComponent("history.jsonl"))
        let fm = FileManager.default
        try fm.createDirectory(at: h.audioDir, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-2 * 3600)
        func wav(_ name: String, seconds: Double) throws {
            let f = h.audioDir.appendingPathComponent(name)
            try Data(count: 44 + Int(seconds * 32_000)).write(to: f)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: f.path)
        }
        let id = DictationHistory.newID(old)
        try wav("\(id).wav", seconds: 20.8)
        try wav("\(id)-p1.wav", seconds: 5)                 // its piece: an orphan as before
        try wav("\(DictationHistory.newID(old))-dead.wav", seconds: 3)
        try wav(DictationHistory.newID(old) + ".wav", seconds: 0.2)      // under a second: nothing to retry
        h.prune(days: 30)
        let es = h.load()
        XCTAssertEqual(es.map(\.id), [id])
        XCTAssertEqual(es.first?.reason, DictationHistory.interruptedReason)
        XCTAssertEqual(es.first?.audio, "audio/\(id).wav")
        XCTAssertEqual(es.first?.duration ?? 0, 20.8, accuracy: 0.01)
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: h.audioDir.path)), ["\(id).wav"])
        // the next launch finds it kept: no second row
        h.prune(days: 30)
        XCTAssertEqual(h.load().count, 1)
    }

    /// Dogfood: a 213 s take with one window fallen back was labelled "typed as spoken" although most was polished.
    func testSomeWindowsFallingBackIsPartsNotTheWholeTake() {
        XCTAssertTrue(DictationWindowFallback.of([true, true]).all)
        XCTAssertNil(DictationWindowFallback.of([true, true]).parts)
        let some = DictationWindowFallback.of([false, true, false, false])
        XCTAssertFalse(some.all)
        XCTAssertEqual(some.parts, DictationParts(n: 1, of: 4))
        XCTAssertFalse(DictationWindowFallback.of([false]).all)
        XCTAssertNil(DictationWindowFallback.of([]).parts)
        var e = entry("d-1", "x", 0)
        e.fellBackParts = DictationParts(n: 1, of: 4)
        XCTAssertEqual(DictationEntry(json: e.json)?.fellBackParts, DictationParts(n: 1, of: 4))
    }

    /// Dogfood: an append between prune's read and its rewrite was lost. Appends racing a prune all survive.
    func testAppendsDuringAPruneAreKept() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = DictationHistory(url: dir.appendingPathComponent("history.jsonl"))
        for i in 0..<200 { h.append(entry("d-old-\(i)", "x", Date().timeIntervalSince1970)); h.correct("d-old-\(i)", text: "y") }
        let g = DispatchGroup()
        DispatchQueue.global().async(group: g) { for _ in 0..<5 { h.prune(days: 30) } }
        DispatchQueue.global().async(group: g) { for i in 0..<100 { h.append(self.entry("d-new-\(i)", "x", Date().timeIntervalSince1970)) } }
        g.wait()
        XCTAssertEqual(h.load().count, 300)
    }

    /// The page's rows say only the exception, one at a time: the item first, then copied-only, then not polished.
    func testARowShowsOneExceptionAtMost() {
        var e = entry("d-m", "hi", 1)
        XCTAssertNil(e.rowMark)
        e.fellBack = true
        XCTAssertEqual(e.rowMark, .notPolished)
        e.insert = "copied"
        XCTAssertEqual(e.rowMark, .copiedOnly)
        e.item = "BA-42"
        XCTAssertEqual(e.rowMark, .item("BA-42"))
    }

    /// Every row clamps alike: a list typed into Notes previews as one paragraph.
    func testThePreviewIsOneParagraph() {
        XCTAssertEqual(DictationEntry.preview("今天下午要做的：\n1. 把听写\n\n2.  菜单栏 "), "今天下午要做的： 1. 把听写 2. 菜单栏")
        XCTAssertEqual(DictationEntry.preview("  plain  "), "plain")
    }
}
