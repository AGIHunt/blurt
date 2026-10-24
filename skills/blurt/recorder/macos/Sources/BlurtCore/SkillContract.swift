// The handshake between the app and the skill scripts it runs. The app updates itself (Sparkle) but runs the Python
// in the installed skill (config skill_dir, else ~/.claude/skills/blurt), so the two can drift apart: items.py's
// documents, the jobs files, the serve protocols. The skill says which contract it speaks in scripts/_common.py
// (`CONTRACT = n`, also in `doctor.py`'s report); the app knows which one it expects. At launch the menu-bar app reads
// that line (no Python) and, when the two differ, says once which side to update (Housekeeping.checkSkillContract).
import Foundation

public enum SkillContract {
    /// The contract this app speaks — bump together with _common.CONTRACT.
    public static let expected = 1

    public enum Mismatch: Equatable {
        /// The skill predates what this app needs: update the skill.
        case skillOlder(skill: Int)
        /// The skill is newer than this app understands: update the app.
        case appOlder(skill: Int)
    }

    /// The skill's contract from its _common.py: nil = no skill there; 0 = a skill from before the handshake.
    public static func skillVersion(scripts: URL = BlurtPaths.scripts) -> Int? {
        guard let text = try? String(contentsOf: scripts.appendingPathComponent("_common.py"), encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// The `CONTRACT = n` line of _common.py (a plain constant at the start of a line), 0 when there is none.
    public static func parse(_ source: String) -> Int {
        for line in source.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix("CONTRACT") {
            let rest = line.dropFirst("CONTRACT".count).drop { $0 == " " }
            guard rest.first == "=" else { continue }
            let digits = rest.dropFirst().drop { $0 == " " }.prefix { $0.isNumber }
            if let n = Int(digits) { return n }
        }
        return 0
    }

    public static func check(skill: Int?, app: Int = expected) -> Mismatch? {
        guard let s = skill, s != app else { return nil }
        return s < app ? .skillOlder(skill: s) : .appOlder(skill: s)
    }
}
