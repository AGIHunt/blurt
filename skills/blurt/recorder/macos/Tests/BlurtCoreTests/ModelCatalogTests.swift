// BlurtCore/ModelCatalog.swift: a model's name, never its id, also before the live list answered (raw-identifier
// audit #12: "qwen3-asr-1.7b-mlx" on the Dictation page's info rows).
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
        XCTAssertEqual(c["qwen3-asr-1.7b-mlx"], "Qwen3-ASR 1.7B (MLX)")
        XCTAssertNotNil(c["sensevoice-small"])
        XCTAssertFalse(c.isEmpty)
    }
}
