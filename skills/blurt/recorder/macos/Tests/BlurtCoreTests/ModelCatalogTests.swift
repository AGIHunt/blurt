// BlurtCore/ModelCatalog.swift: a model's name, never its id or its folder, also before the live list answered
// (raw-identifier audit #12: "qwen3-asr-1.7b-mlx" on the Dictation page's info rows; Storage's model folders).
import Foundation
import XCTest
@testable import BlurtCore

final class ModelCatalogTests: XCTestCase {
    func testNamesComeFromTheCatalog() {
        let json = Data(#"{"schema": 1, "models": [{"id": "qwen3-asr-1.7b-mlx", "name": "Qwen3-ASR 1.7B (MLX)"}, {"id": "x"}]}"#.utf8)
        let c = ModelCatalog.names(json: json)
        XCTAssertEqual(c, ["qwen3-asr-1.7b-mlx": "Qwen3-ASR 1.7B (MLX)"])
        XCTAssertEqual(ModelCatalog.name("qwen3-asr-1.7b-mlx", live: nil, catalog: c), "Qwen3-ASR 1.7B (MLX)")
        XCTAssertEqual(ModelCatalog.name("qwen3-asr-1.7b-mlx", live: "Live name", catalog: c), "Live name")
        XCTAssertNil(ModelCatalog.name("openai:whisper-1", live: nil, catalog: c))      // the caller says it in words
        XCTAssertEqual(ModelCatalog.names(json: Data("nope".utf8)), [:])
    }

    func testTheSkillsOwnCatalogsNameTheDefaults() throws {
        // the repository's scripts: every dictation model the app can show has a name there
        let scripts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../scripts").standardized
        let c = ModelCatalog.load(scripts: scripts)
        XCTAssertEqual(c["qwen3-asr-1.7b-mlx"], "Qwen3-ASR 1.7B")      // no framework tag in a name people read
        XCTAssertNotNil(c["sensevoice-small"])
        XCTAssertFalse(c.isEmpty)
    }

    func testAStoppedDownloadsKeptBytesAreCounted() throws {
        // after Stop the setup says what is on disk (the next download continues it), not the whole size again
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-kept-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let scripts = tmp.appendingPathComponent("scripts"), models = tmp.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data(#"{"models": [{"id": "q", "name": "Q", "install": {"hf": "org/Q-8bit"}}]}"#.utf8)
            .write(to: scripts.appendingPathComponent("asr_models.json"))
        try Data(#"{"models": []}"#.utf8).write(to: scripts.appendingPathComponent("polish_models.json"))
        let dir = models.appendingPathComponent("asr/Q-8bit")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 300_000).write(to: dir.appendingPathComponent("model.safetensors.part"))
        try Data(count: 1_000).write(to: dir.appendingPathComponent("config.json"))
        // a link (another copy's file) isn't counted
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("linked"), withDestinationURL: dir.appendingPathComponent("config.json"))
        let kept = ModelCatalog.keptBytes("q", models: models, dir: scripts)
        XCTAssertGreaterThanOrEqual(kept, 300_000)
        XCTAssertLessThan(kept, 340_000)
        XCTAssertEqual(ModelCatalog.keptBytes("unknown", models: models, dir: scripts), 0)
        XCTAssertEqual(ModelCatalog.keptBytes("q", models: tmp.appendingPathComponent("none"), dir: scripts), 0)
    }

    static let scripts = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../scripts").standardizedFileURL

    /// Hearing again in windows of the model's length (docs/design/dictation.md §Hearing again): the shipped
    /// catalogue's measured values, 10 s for every other model; tests/test_transcribe_field_context.py checks the
    /// Lab's port (dictation_stitch.rehear_window) against the same file.
    func testRehearWindowIsTheModelsOwn() {
        let d = Self.scripts
        XCTAssertEqual(ModelCatalog.rehearWindow("qwen3-asr-1.7b-mlx", dir: d), 30)
        XCTAssertEqual(ModelCatalog.rehearWindow("qwen3-asr-0.6b-mlx", dir: d), 20)
        for id in ["apple-speech", "sensevoice-small", "whisper-large-v3-turbo-mlx", "qwen3-asr-flash", "no-such-model"] {
            XCTAssertEqual(ModelCatalog.rehearWindow(id, dir: d), DictationStitch.rehearWindow, id)
        }
        XCTAssertEqual(ModelCatalog.rehearWindow(nil, dir: d), DictationStitch.rehearWindow)
    }

    func testNamesComeFromTheShippedCatalogues() {
        let d = Self.scripts
        XCTAssertEqual(ModelCatalog.name("qwen3-asr-1.7b-mlx", dir: d), "Qwen3-ASR 1.7B")      // no framework tag in a name people read
        XCTAssertEqual(ModelCatalog.name("sensevoice-small", dir: d), "SenseVoice Small")
        XCTAssertNotNil(ModelCatalog.name("gemma4-e2b", dir: d), "the polish catalogue too")
        // a model the scripts name by backend (a cloud API in use): its backend's entry and the model, never "no
        // longer listed"
        XCTAssertEqual(ModelCatalog.name("openai:whisper-1", dir: d), "OpenAI-compatible API · whisper-1")
        XCTAssertEqual(ModelCatalog.name("openai:default", dir: d), "OpenAI-compatible API")
        XCTAssertNil(ModelCatalog.name("nobackend:x", dir: d))
        XCTAssertNil(ModelCatalog.name("no-such-model", dir: d))
    }

    func testStorageFoldersMapToTheirModel() {
        let d = Self.scripts
        XCTAssertEqual(ModelCatalog.entry(folder: "Qwen3-ASR-1.7B-8bit", dir: d)?.id, "qwen3-asr-1.7b-mlx")
        XCTAssertEqual(ModelCatalog.entry(folder: "models--mlx-community--Qwen3-ASR-0.6B-8bit", dir: d)?.id, "qwen3-asr-0.6b-mlx")
        XCTAssertEqual(ModelCatalog.entry(folder: "sensevoice", dir: d)?.id, "sensevoice-small")
        XCTAssertEqual(ModelCatalog.entry(folder: "qwen3-asr-0.6b-int8", dir: d)?.id, "qwen3-asr-0.6b-onnx")
        XCTAssertNil(ModelCatalog.entry(folder: "sherpa-onnx-ced-mini-audio-tagging-2024-04-19", dir: d))
    }
}
