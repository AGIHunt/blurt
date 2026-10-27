// The main window's writes, one after another (the reviewer's "one ⌘Z undid two steps"): each piece of work starts
// only when the one before it has finished, so an undo issued while its action's script is still running waits for
// it, and a redo waits for the undo. The undo steps themselves are registered when the action is issued (on the
// window's NSUndoManager, in the key press or click); what runs later goes through here.
import Foundation

@MainActor
public final class SerialWork {
    private var tail: Task<Void, Never>?
    private var pending = 0

    public init() {}

    /// Nothing queued or running.
    public var isIdle: Bool { pending == 0 }

    /// Runs `work` after everything queued before it.
    public func run(_ work: @escaping @MainActor () async -> Void) {
        let before = tail
        pending += 1
        tail = Task { @MainActor [weak self] in
            await before?.value
            await work()
            self?.pending -= 1
        }
    }

    /// Waits until everything queued so far has finished (tests, the self-test hooks).
    public func drain() async {
        await tail?.value
    }
}

/// One undo step's target (NSUndoManager.registerUndo(withTarget:)): an object of its own, so a write that fails can
/// take exactly that step off the stack (removeAllActions(withTarget:)). `value`: what the write found (the states
/// it changed, where the items were), filled in when it runs and read by its undo, which runs after it.
public final class UndoStep<Value> {
    public var value: Value?
    public init() {}
}
