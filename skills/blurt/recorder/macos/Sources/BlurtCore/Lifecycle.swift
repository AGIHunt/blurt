// K3 (docs/design/next-round.md): an item's one lifecycle — eight states, the user's actions between them, the groups
// every count uses, and the migration from the old two axes (review `status` + `work.state`, v2 `fix`). The same
// table is in Python (_common.LIFECYCLE) and the web (@blurt/ui lifecycle.ts); all three are tested against
// tests/fixtures/lifecycle.json (Tests/BlurtCoreTests/LifecycleTests.swift).
//
// The app never writes a state itself: an action goes to `items.py state UID… --action A --by user`. hand_off is the
// exception — it opens the dispatch panel or copies an instruction, and those flows write the state.
import Foundation

public enum Lifecycle {
    public static let states = ["new", "todo", "handed_off", "in_progress", "to_verify", "done", "wontfix", "discarded"]

    /// "Needs you": the inbox, the sidebar and menu-bar badges, the island
    public static let inbox: Set<String> = ["new", "to_verify"]
    /// not finished (MCP open_items, a project's open count)
    public static let open: Set<String> = ["new", "todo", "handed_off", "in_progress"]
    /// with an agent, or back from one (the In Progress place)
    public static let active: Set<String> = ["handed_off", "in_progress", "to_verify"]
    public static let closed: Set<String> = ["done", "wontfix"]
    /// everything a list shows unless it asks for the Discarded filter
    public static let live: [String] = states.filter { $0 != "discarded" }

    public struct Transition: Equatable {
        public let from: [String]
        /// nil: restore goes back to the item's `restore_to` (new when it has none)
        public let to: String?
        /// "a", "d", "r", "w", "x", "cmd+enter"
        public let key: String
    }

    /// In the order the fixture lists them.
    public static let actions = ["keep", "hand_off", "done", "send_back", "take_back", "reopen", "restore", "wontfix", "discard"]

    public static let transitions: [String: Transition] = [
        "keep": Transition(from: ["new"], to: "todo", key: "a"),
        "hand_off": Transition(from: ["new", "todo"], to: "handed_off", key: "cmd+enter"),
        "done": Transition(from: ["todo", "handed_off", "in_progress", "to_verify"], to: "done", key: "d"),
        "send_back": Transition(from: ["to_verify"], to: "todo", key: "r"),
        "take_back": Transition(from: ["handed_off", "in_progress"], to: "todo", key: "r"),
        "reopen": Transition(from: ["done", "wontfix"], to: "todo", key: "r"),
        "restore": Transition(from: ["discarded"], to: nil, key: "r"),
        "wontfix": Transition(from: ["new", "todo", "handed_off", "in_progress", "to_verify"], to: "wontfix", key: "w"),
        "discard": Transition(from: live, to: "discarded", key: "x"),
    ]

    /// What clicking a state offers, in order.
    public static let menus: [String: [String]] = [
        "new": ["keep", "hand_off", "wontfix", "discard"],
        "todo": ["hand_off", "done", "wontfix", "discard"],
        "handed_off": ["done", "take_back", "wontfix", "discard"],
        "in_progress": ["done", "take_back", "wontfix", "discard"],
        "to_verify": ["done", "send_back", "wontfix", "discard"],
        "done": ["reopen", "discard"],
        "wontfix": ["reopen", "discard"],
        "discarded": ["restore"],
    ]

    /// The "back" actions: each state has at most one, so R is never ambiguous.
    public static let backActions = ["send_back", "take_back", "reopen", "restore"]

    public static func isState(_ s: String?) -> Bool { s.map(states.contains) ?? false }

    /// The menu for a state. `hand_off` only where the host can dispatch or hand off.
    public static func menu(for state: String, canHandOff: Bool) -> [String] {
        (menus[state] ?? []).filter { $0 != "hand_off" || canHandOff }
    }

    public static func canDo(_ action: String, _ state: String) -> Bool { transitions[action]?.from.contains(state) ?? false }

    /// Where an action takes an item; nil when the action isn't valid from its state.
    public static func target(of action: String, state: String, restoreTo: String? = nil) -> String? {
        guard canDo(action, state), let t = transitions[action] else { return nil }
        if let to = t.to { return to }
        return isState(restoreTo) && restoreTo != "discarded" ? restoreTo : "new"
    }

    /// The one back action of a state (send back / take back / reopen / restore): what R does.
    public static func backAction(_ state: String) -> String? { backActions.first { canDo($0, state) } }

    /// A list key → the action it means for this state, or nil. A keep, D done, R back, W won't do, X / ⌫ / ⌦ discard
    /// ("delete"), ⌘↩ hand off ("cmd+enter").
    public static func action(forKey key: String, state: String) -> String? {
        let a: String?
        switch key.lowercased() {
        case "a": a = "keep"
        case "d": a = "done"
        case "w": a = "wontfix"
        case "x", "delete", "backspace": a = "discard"
        case "r": return backAction(state)
        case "cmd+enter": a = "hand_off"
        default: a = nil
        }
        return a.flatMap { canDo($0, state) ? $0 : nil }
    }

    /// The key an action shows in menus ("A", "D", "R", "W", "X", "⌘↩").
    public static func keyLabel(_ action: String) -> String {
        guard let k = transitions[action]?.key else { return "" }
        return k == "cmd+enter" ? "⌘↩" : k.uppercased()
    }

    // MARK: reading items, old and new

    /// v2 `fix` → the K3 state
    static func fixState(_ fix: [String: Any]?) -> String? {
        switch fix?["state"] as? String {
        case "fixing": return "in_progress"
        case "fixed": return "to_verify"
        case "wontfix":         // your own decision (no agent, or "human") vs an agent's suggestion
            let a = fix?["agent"] as? String
            return a == nil || a == "" || a == "human" ? "wontfix" : "to_verify"
        case "reopened": return "todo"
        default: return nil
        }
    }

    /// The state of an item (its front-matter or JSON), and where a discarded one goes back to. A known `state` wins;
    /// otherwise: status deleted → discarded (restore_to from the rest); a work state other than to do → it;
    /// draft → new, confirmed → to do.
    public static func migrate(_ item: [String: Any]) -> (state: String, restoreTo: String?) {
        if let s = item["state"] as? String, isState(s) {
            guard s == "discarded" else { return (s, nil) }
            let r = item["restore_to"] as? String
            return ("discarded", isState(r) && r != "discarded" ? r : "new")
        }
        let ws = (item["work"] as? [String: Any])?["state"] as? String
        let work = ws.flatMap { isState($0) && $0 != "new" && $0 != "discarded" ? $0 : nil } ?? fixState(item["fix"] as? [String: Any])
        let status = item["status"] as? String
        let live = work.flatMap { $0 != "todo" ? $0 : nil } ?? (status == "confirmed" ? "todo" : "new")
        return status == "deleted" ? ("discarded", live) : (live, nil)
    }

    public static func state(of item: [String: Any]) -> String { migrate(item).state }

    /// The old query vocabulary (review status, work state) as states — for callers that still speak it.
    /// status draft → new, confirmed → todo … wontfix, deleted → discarded; work todo → new + todo, others as named.
    public static func states(fromStatus status: String) -> [String] {
        switch status {
        case "draft": return ["new"]
        case "confirmed": return ["todo", "handed_off", "in_progress", "to_verify", "done", "wontfix"]
        case "deleted": return ["discarded"]
        default: return isState(status) ? [status] : []
        }
    }

    public static func states(fromWork work: String) -> [String] {
        work == "todo" ? ["new", "todo"] : isState(work) ? [work] : []
    }
}
