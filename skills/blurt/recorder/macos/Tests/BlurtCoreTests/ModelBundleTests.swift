// BlurtCore/ModelBundle.swift: the setup assistant's recommended models — the set, what is still missing and its size,
// one progress bar over downloads that run one after another, the scripts' progress lines, and the download mirror.
import XCTest
@testable import BlurtCore

final class ModelBundleTests: XCTestCase {
    typealias Part = ModelBundle.Part

    let qwen = Part(id: "qwen3-asr-1.7b-mlx", kind: .dictation, name: "Qwen3-ASR 1.7B", sizeMB: 2468, installed: false)
    let gemma = Part(id: "gemma4-e2b", kind: .polish, name: "Gemma 4 E2B", sizeMB: 3415, installed: false)
    let sense = Part(id: "sensevoice-small", kind: .note, name: "SenseVoice Small", sizeMB: 228, installed: false)

    func testPlanKeepsOrderAndEachModelOnce() {
        XCTAssertEqual(ModelBundle.plan(dictation: qwen, polish: gemma, polishRuns: true, note: sense)?.map(\.id),
                       ["qwen3-asr-1.7b-mlx", "gemma4-e2b", "sensevoice-small"])
        // a small Mac: dictation falls back to the voice-note model — it is downloaded once
        var small = sense
        small.kind = .dictation
        XCTAssertEqual(ModelBundle.plan(dictation: small, polish: nil, polishRuns: false, note: sense)?.map(\.id), ["sensevoice-small"])
        XCTAssertEqual(ModelBundle.plan(dictation: small, polish: nil, polishRuns: false, note: sense)?.first?.kind, .dictation)
        // no polish where it doesn't run (Intel): just the speech models
        XCTAssertEqual(ModelBundle.plan(dictation: qwen, polish: nil, polishRuns: false, note: sense)?.map(\.kind), [.dictation, .note])
        XCTAssertEqual(ModelBundle.plan(dictation: qwen, polish: gemma, polishRuns: false, note: sense)?.map(\.kind), [.dictation, .note])
    }

    func testAListThatCouldNotBeReadLeavesNoSet() {
        // polish.py models failed or timed out: not "no polish here" — the step offers Try Again
        XCTAssertNil(ModelBundle.plan(dictation: qwen, polish: nil, polishRuns: nil, note: sense))
        // it runs here, but its recommended model wasn't in the list
        XCTAssertNil(ModelBundle.plan(dictation: qwen, polish: nil, polishRuns: true, note: sense))
        // transcribe.py dictation-models / models failed
        XCTAssertNil(ModelBundle.plan(dictation: nil, polish: gemma, polishRuns: true, note: sense))
        XCTAssertNil(ModelBundle.plan(dictation: qwen, polish: gemma, polishRuns: true, note: nil))
    }

    func testOneSizeFormatEverywhere() {
        // the assistant said 6.11 GB and Settings 5.7 GB for the same set (GB vs GiB): decimal, one decimal, everywhere
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(ModelBundle.size(228, locale: en), "228 MB")
        XCTAssertEqual(ModelBundle.size(2468, locale: en), "2.5 GB")
        XCTAssertEqual(ModelBundle.size(2468 + 3415 + 228, locale: en), "6.1 GB")
        XCTAssertEqual(ModelBundle.size(999.6, locale: en), "1.0 GB")
        XCTAssertEqual(ModelBundle.size(0, locale: en), "0 MB")
    }

    func testMirror() {
        // never set: the region decides
        XCTAssertTrue(ModelBundle.mirror(setting: nil, region: "CN"))
        XCTAssertFalse(ModelBundle.mirror(setting: nil, region: "US"))
        XCTAssertFalse(ModelBundle.mirror(setting: nil, region: nil))
        // the checkbox, either way, wins — turned off in China stays off
        XCTAssertFalse(ModelBundle.mirror(setting: false, region: "CN"))
        XCTAssertTrue(ModelBundle.mirror(setting: true, region: "US"))
    }

    func testPendingAndTotal() {
        var installed = sense
        installed.installed = true
        let parts = [qwen, gemma, installed]
        XCTAssertEqual(ModelBundle.pending(parts).map(\.id), ["qwen3-asr-1.7b-mlx", "gemma4-e2b"])
        XCTAssertEqual(ModelBundle.totalMB(parts), 2468 + 3415)
        XCTAssertEqual(ModelBundle.totalMB([installed]), 0)
    }

    func testOneBarOverTheDownloads() {
        let parts = [qwen, gemma, sense]
        let total = 2468.0 + 3415 + 228
        // nothing yet
        var p = ModelBundle.progress(parts, finished: [], current: qwen.id, line: nil)
        XCTAssertEqual(p.done, 0)
        XCTAssertEqual(p.total, total)
        // halfway through the first: half its registry size, whatever the script's own total says
        p = ModelBundle.progress(parts, finished: [], current: qwen.id, line: (1300, 2600))
        XCTAssertEqual(p.done, 1234, accuracy: 0.01)
        // the first done, a quarter of the second
        p = ModelBundle.progress(parts, finished: [qwen.id], current: gemma.id, line: (100, 400))
        XCTAssertEqual(p.done, 2468 + 3415 / 4, accuracy: 0.01)
        // a line past its total never runs ahead
        p = ModelBundle.progress(parts, finished: [qwen.id, gemma.id], current: sense.id, line: (500, 228))
        XCTAssertEqual(p.done, total, accuracy: 0.01)
        // all finished
        p = ModelBundle.progress(parts, finished: Set(parts.map(\.id)), current: nil, line: nil)
        XCTAssertEqual(p.done, total, accuracy: 0.01)
    }

    func testProgressLines() {
        XCTAssertEqual(ModelBundle.parseProgress("  812/2468 MB")?.done, 812)
        XCTAssertEqual(ModelBundle.parseProgress("  812/2468 MB")?.total, 2468)
        XCTAssertEqual(ModelBundle.parseProgress("12/228 MB")?.total, 228)
        XCTAssertNil(ModelBundle.parseProgress("downloading mlx-community/gemma-4-e2b-it-4bit"))
        XCTAssertNil(ModelBundle.parseProgress("  failed: timed out"))
        XCTAssertNil(ModelBundle.parseProgress("  5/0 MB"))
        XCTAssertNil(ModelBundle.parseProgress("unpacking sensevoice"))
    }
}
