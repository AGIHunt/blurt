import XCTest
@testable import BlurtCore

@MainActor
final class SerialWorkTests: XCTestCase {
    /// An undo issued while its action is still being written runs after it, never before (one ⌘Z, one step).
    func testRunsInIssueOrderEvenWhenTheFirstIsSlow() async {
        let q = SerialWork()
        var log: [String] = []
        q.run {
            log.append("remove start")
            try? await Task.sleep(nanoseconds: 50_000_000)
            log.append("remove end")
        }
        q.run { log.append("restore") }
        q.run {
            try? await Task.sleep(nanoseconds: 10_000_000)
            log.append("order")
        }
        XCTAssertFalse(q.isIdle)
        await q.drain()
        XCTAssertEqual(log, ["remove start", "remove end", "restore", "order"])
        XCTAssertTrue(q.isIdle)
    }

    func testWorkQueuedFromInsideWorkRunsAfterIt() async {
        let q = SerialWork()
        var log: [Int] = []
        q.run {
            log.append(1)
            q.run { log.append(3) }
            log.append(2)
        }
        await q.drain()
        await q.drain()
        XCTAssertEqual(log, [1, 2, 3])
    }
}

/// The main window's undo steps (UndoStep as NSUndoManager's target): the manager doesn't retain targets, so the
/// handler holds the step; a failed write removes exactly its own step.
final class UndoStepTests: XCTestCase {
    func testAStepRegisteredByItsHandlerSurvivesUntilUndone() {
        let um = UndoManager()
        um.groupsByEvent = false
        var undone: [Int] = []
        func register(_ n: Int) -> UndoStep<Int> {
            let step = UndoStep<Int>()
            step.value = n
            um.beginUndoGrouping()
            um.registerUndo(withTarget: step) { _ in undone.append(step.value ?? -1) }
            um.endUndoGrouping()
            return step
        }
        _ = register(1)
        let failed = register(2)
        _ = register(3)
        um.removeAllActions(withTarget: failed)     // its write failed: ⌘Z skips it
        um.undo()
        um.undo()
        XCTAssertEqual(undone, [3, 1])
        XCTAssertFalse(um.canUndo)
    }
}
