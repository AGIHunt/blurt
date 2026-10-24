// BlurtCore/DictationHistory.swift: the append-only log and its edit lines, read back in order.
import Foundation
import XCTest
@testable import BlurtCore

final class DictationHistoryTests: XCTestCase {
    func entry(_ id: String, _ text: String, _ t: TimeInterval) -> DictationEntry {
        DictationEntry(id: id, time: Date(timeIntervalSince1970: t), app: "Notes", bundle: nil, duration: 2, raw: text,
                       polished: nil, text: text, model: nil, fellBack: false, reason: nil, insert: "pasted")
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
}
