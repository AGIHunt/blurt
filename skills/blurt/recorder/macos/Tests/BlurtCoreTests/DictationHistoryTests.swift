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
}
