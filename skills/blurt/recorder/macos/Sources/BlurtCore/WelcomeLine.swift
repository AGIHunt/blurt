// The first launch's one line in the island (App.postWelcome, outside the setup assistant): where Blurt lives and the
// keys to try first — only keys that work right now. Dictation's key only when dictation hears it and has a speech
// model (else the line says how to get there, with the button for it); the snap / record keys only when they are
// registered (a shortcut macOS or another app holds is left out, and named as not working on that same line instead
// of in a second message later). Unit-tested in Tests/BlurtCoreTests/WelcomeLineTests. Strings: Main table.
import Foundation

public enum WelcomeLine {
    /// Where dictation stands at that launch.
    public enum Dictation: Equatable { case works, needsSetup, noModel, off }
    /// The line's button.
    public enum Action: String, Equatable { case turnOnDictation, downloadModel, changeShortcut }

    public struct Line: Equatable {
        public var key: String
        public var args: [String]
        /// " · shortcut ⇧⌘3 won't work" after the line (the labels of keys that don't work)
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
        case .off:
            if let s = snap, let r = record { line = Line(key: "app.toast.welcome_no_dictation", args: [s, r], conflicts: [], action: nil) }
            else if let s = snap { line = Line(key: "app.toast.welcome_snap_only", args: [s], conflicts: [], action: nil) }
            else { line = Line(key: "app.toast.welcome_plain", args: [], conflicts: [], action: nil) }
        }
        line.conflicts = conflicts
        if line.action == nil && !conflicts.isEmpty { line.action = .changeShortcut }
        return line
    }
}
