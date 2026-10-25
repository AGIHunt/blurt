// Where a hand-off runs: Blurt's own terminal (the default, and the one recommended: live status, hooks, the
// embedded window) or the agent's desktop app (Claude: agents.json interactive.desktop). Remembered per agent in
// config sessions.target ({"claude": "desktop"}); the hand-off sheet and Settings → Agents read and write the same key.
// Only an agent with a desktop app that is installed can be sent there; otherwise it is the terminal, whatever was
// saved.
import Foundation

public enum HandoffTarget: String, CaseIterable {
    case terminal, desktop

    public static let configKey = "sessions.target"

    /// `saved` = config sessions.target; `available` = the agent has a desktop app and it is installed.
    public static func resolve(_ saved: Any?, agent: String, available: Bool) -> HandoffTarget {
        guard available, let m = saved as? [String: Any], let s = m[agent] as? String else { return .terminal }
        return HandoffTarget(rawValue: s) ?? .terminal
    }

    /// The new sessions.target with `agent` set to `target` (the terminal, the default, is stored as nothing).
    public static func store(_ saved: Any?, agent: String, target: HandoffTarget) -> [String: Any] {
        var m = saved as? [String: Any] ?? [:]
        m[agent] = target == .terminal ? nil : target.rawValue
        return m
    }
}

/// Continue in Claude Desktop, on a session running in Blurt's terminal: offered only where it can work — the agent
/// has a desktop app (`supported`), the session is alive in tmux and has told us its conversation id, and
/// `sessions.py desktop-check` said yes (CLI new enough, logged in with a subscription). Unknown = hidden.
public enum DesktopContinue {
    public static func offered(_ a: AgentInfo, alive: Bool, supported: Bool, check: DesktopContinueCheck?) -> Bool {
        supported && alive && a.runner == "tmux" && !(a.agentSessionID ?? "").isEmpty && check?.available == true
    }
}
