// A project whose folder is gone — moved, renamed, or on a drive that isn't plugged in (Project.exists is false).
// Nothing is ever filed into it: filing would make the old folder again, an empty twin whose ids clash with the
// project's own when it is found. Every way a capture gets a project goes through `filing` (BlurtApp Snapper.file /
// assign: a capture taken with that project current, the card's Move To ▸, its VoiceOver "Move to X", the note's
// "Goes to" chip, a drop on the island) — the captures stay cards and the island offers Locate…. Locate… asks where
// the folder is now; opening it there is the same project again (projects.py add relocates) — unless the folder the
// user picked is another project (`located`): then that one is opened, and the missing one is still missing.
import Foundation

public enum MissingFolder {
    public enum Filing: Equatable { case file, keepAsCards }

    /// May captures be filed into `project` now? `exists`: its folder is there (nil: not a known project — the
    /// scripts decide). Unassigned ("inbox") always may.
    public static func filing(project: String, exists: Bool?) -> Filing {
        project == "inbox" || exists != false ? .file : .keepAsCards
    }

    public enum Located: Equatable { case same, other }

    /// The folder picked for a missing project opened as `found`: that project again, or another one.
    public static func located(wanted: String, found: String) -> Located { wanted == found ? .same : .other }
}
