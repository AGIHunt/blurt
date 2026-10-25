// StoreFolders (BlurtCore Projects/StoreFolders.swift): a project folder moved away never comes back at its old path —
// the review's repro: a snap's batch opened in billing-api, the folder moved, Locate… pointed at the new one, and the
// next snap still wrote into the old .blurt/sessions/…-shots, making the old folder and a ghost store again.
import Foundation
import XCTest
@testable import BlurtCore

final class StoreFoldersTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("storefolders-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testMovedFolderThenRelocatedNeverMakesTheOldFolderAgain() throws {
        let fm = FileManager.default
        let old = root.appendingPathComponent("billing-api"), moved = root.appendingPathComponent("billing-api-moved")
        let oldStore = old.appendingPathComponent(".blurt")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)       // the project's folder
        // a snap opens the project's batch
        let batch = oldStore.appendingPathComponent("sessions/20261025-221820-shots")
        XCTAssertTrue(StoreFolders.make(batch.appendingPathComponent("shots")))
        XCTAssertTrue(StoreFolders.stillUsable(batch, store: oldStore))
        // the user moves the folder in Finder, then Locate… points the project (same id) at it
        try fm.moveItem(at: old, to: moved)
        let newStore = moved.appendingPathComponent(".blurt")
        // the batch kept from before is no longer the project's: another key, and not usable under either store
        XCTAssertNotEqual(StoreFolders.batchKey(oldStore), StoreFolders.batchKey(newStore))
        XCTAssertFalse(StoreFolders.stillUsable(batch, store: newStore))
        XCTAssertFalse(StoreFolders.stillUsable(batch, store: oldStore))
        // the next snap's picture: writing into the old batch is refused, and nothing is made at the old path
        XCTAssertFalse(StoreFolders.make(batch.appendingPathComponent("shots")))
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        // its new batch goes into the moved folder
        let fresh = newStore.appendingPathComponent("sessions/20261025-222000-shots")
        XCTAssertTrue(StoreFolders.make(fresh.appendingPathComponent("shots")))
        XCTAssertTrue(StoreFolders.stillUsable(fresh, store: newStore))
        XCTAssertFalse(fm.fileExists(atPath: old.path))
    }

    func testUnassignedStoreIsAlwaysMadeEvenOnAFreshWorkspace() {
        // the inbox store is <workspace>/inbox (no .blurt): a first launch makes the whole path
        let inbox = root.appendingPathComponent("Blurt/inbox")
        let d = inbox.appendingPathComponent("sessions/20261025-222000-shots/shots")
        XCTAssertTrue(StoreFolders.make(d))
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.path))
    }

    func testStoreOfASessionFolder() {
        let s = root.appendingPathComponent("p/.blurt")
        XCTAssertEqual(StoreFolders.store(of: s.appendingPathComponent("sessions/x-shots/shots"))?.path, s.standardizedFileURL.path)
        XCTAssertNil(StoreFolders.store(of: root.appendingPathComponent("tmp/voice")))
        // outside any store: made as asked
        XCTAssertTrue(StoreFolders.make(root.appendingPathComponent("tmp/voice")))
    }
}
