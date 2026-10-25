// BlurtCore/TrashRestore.swift: Storage's Undo puts things back, merges into a folder made again, and reports what
// can't come back.
import XCTest
@testable import BlurtCore

final class TrashRestoreTests: XCTestCase {
    var dir: URL!
    let fm = FileManager.default

    override func setUp() {
        dir = fm.temporaryDirectory.appendingPathComponent("trash-restore-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir.appendingPathComponent("Trash"), withIntermediateDirectories: true)
    }
    override func tearDown() { try? fm.removeItem(at: dir) }

    func make(_ rel: String, _ text: String = "x") -> URL {
        let u = dir.appendingPathComponent(rel)
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    func testItGoesBackWhereItWas() {
        _ = make("Trash/tmp/a.wav")
        let orig = dir.appendingPathComponent("home/tmp"), trashed = dir.appendingPathComponent("Trash/tmp")
        try? fm.createDirectory(at: orig.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r = TrashRestore.restore([orig: trashed])
        XCTAssertEqual(r.back, [orig])
        XCTAssertTrue(r.missing.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: orig.appendingPathComponent("a.wav").path))
    }

    func testAFolderMadeAgainTakesTheOldContentsBack() {
        _ = make("Trash/tmp/a.wav", "old")
        _ = make("home/tmp/new.wav", "new")          // the app made tmp again meanwhile
        let orig = dir.appendingPathComponent("home/tmp"), trashed = dir.appendingPathComponent("Trash/tmp")
        let r = TrashRestore.restore([orig: trashed])
        XCTAssertEqual(r.back, [orig])
        XCTAssertTrue(fm.fileExists(atPath: orig.appendingPathComponent("a.wav").path))
        XCTAssertTrue(fm.fileExists(atPath: orig.appendingPathComponent("new.wav").path))
        XCTAssertFalse(fm.fileExists(atPath: trashed.path))
    }

    func testWhatCannotComeBackIsReported() {
        // the Trash was emptied
        let gone = dir.appendingPathComponent("home/models"), gt = dir.appendingPathComponent("Trash/models")
        // a file whose name is taken again: left in the Trash, nothing overwritten
        let taken = make("home/a.mp4", "new"), tt = make("Trash/a.mp4", "old")
        let r = TrashRestore.restore([gone: gt, taken: tt])
        XCTAssertTrue(r.back.isEmpty)
        XCTAssertEqual(Set(r.missing), [gone, taken])
        XCTAssertEqual(try? String(contentsOf: taken, encoding: .utf8), "new")
        XCTAssertTrue(fm.fileExists(atPath: tt.path))
    }
}
