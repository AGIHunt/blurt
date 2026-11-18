// The Agents string table (K10 table "Agents": Settings → Agents, the organising run's job rows and fixes) and the
// display names agents.json gives the agent ids.
import AppKit
import BlurtCore

/// Agents-table lookup. Arguments are passed through Loc.t's own variadic signature (≤ 3).
func AL(_ key: String, _ a: CVarArg...) -> String {
    switch a.count {
    case 0: return Loc.t(key, table: "Agents")
    case 1: return Loc.t(key, table: "Agents", a[0])
    case 2: return Loc.t(key, table: "Agents", a[0], a[1])
    default: return Loc.t(key, table: "Agents", a[0], a[1], a[2])
    }
}

/// agents.json display names ("claude" → "Claude Code").
enum AgentNames {
    private static var cache: [String: String]?
    static func name(_ id: String) -> String {
        if cache == nil {
            var m: [String: String] = [:]
            var urls = [BlurtPaths.scripts.appendingPathComponent("agents.json")]
            if let u = Bundle.main.url(forResource: "agents", withExtension: "json") { urls.append(u) }
            for u in urls {
                guard let d = try? Data(contentsOf: u), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                for a in o["agents"] as? [[String: Any]] ?? [] {
                    if let i = a["id"] as? String, let n = a["name"] as? String { m[i] = n }
                }
                break
            }
            cache = m
        }
        let custom = ((Config.shared["record.agent_defs"] as? [String: Any])?[id] as? [String: Any])?["name"] as? String
        return custom ?? cache?[id] ?? (id == "human" ? AL("agent.you") : id.capitalized)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
