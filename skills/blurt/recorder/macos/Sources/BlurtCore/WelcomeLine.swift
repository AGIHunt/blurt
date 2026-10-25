// The first launch's one line in the island (App.postWelcome, outside the setup assistant): where Blurt lives and the
// keys to try first — only keys that work right now. Dictation's key only when dictation hears it and has a speech
// model (else the line says how to get there, with the button for it); the snap / record keys only when they are
// registered. A shortcut macOS or another app holds is named as not working in that same line (with Change…), in
// place of the keys — the island's row has room for one clause beside a button. Every variant fits the island in
// both languages (WelcomeLineWidthTests). Unit-tested in Tests/BlurtCoreTests/WelcomeLineTests. Strings: Main table.
import Foundation

public enum WelcomeLine {
    /// Where dictation stands at that launch. `unknown`: its models couldn't be read (the scripts can't run yet) —
    /// its key isn't advertised, as when it's off.
    public enum Dictation: Equatable { case works, needsSetup, noModel, unknown, off }
    /// The line's button.
    public enum Action: String, Equatable { case turnOnDictation, downloadModel, changeShortcut }

    public struct Line: Equatable {
        public var key: String
        public var args: [String]
        /// the labels of the keys that don't work (said by the line only when its action is .changeShortcut)
        public var conflicts: [String]
        public var action: Action?
    }

    /// `snap` / `record`: the key's label when it works, nil when it is off or doesn't work. `conflicts`: the labels
    /// of shortcuts that don't work.
    public static func compose(dictation: Dictation, dictationKey: String, snap: String?, record: String?,
                               conflicts: [String]) -> Line {
        var line: Line
        switch dictation {
        case .works:
            line = snap.map { Line(key: "app.toast.welcome", args: [dictationKey, $0], conflicts: [], action: nil) }
                ?? Line(key: "app.toast.welcome_dictation_only", args: [dictationKey], conflicts: [], action: nil)
        case .needsSetup:
            line = Line(key: "app.toast.welcome_setup", args: [], conflicts: [], action: .turnOnDictation)
        case .noModel:
            line = Line(key: "app.toast.welcome_no_model", args: [], conflicts: [], action: .downloadModel)
        case .off, .unknown:
            if let s = snap, let r = record { line = Line(key: "app.toast.welcome_no_dictation", args: [s, r], conflicts: [], action: nil) }
            else if let s = snap { line = Line(key: "app.toast.welcome_snap_only", args: [s], conflicts: [], action: nil) }
            else { line = Line(key: "app.toast.welcome_plain", args: [], conflicts: [], action: nil) }
        }
        line.conflicts = conflicts
        // a shortcut that doesn't work: the line says so, with Change… — instead of the keys (the line has room for
        // one clause beside its button). With a more urgent button (turn dictation on, get its model) the conflicts
        // wait for their own line at a later launch.
        if line.action == nil && !conflicts.isEmpty {
            line = conflicts.count == 1
                ? Line(key: "app.toast.welcome_taken", args: conflicts, conflicts: conflicts, action: .changeShortcut)
                : Line(key: "app.toast.welcome_taken_many", args: ["\(conflicts.count)"], conflicts: conflicts, action: .changeShortcut)
        }
        return line
    }
}
