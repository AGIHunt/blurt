// Which model and effort an unattended organizing run uses (same rules as agents.py processing). Two kinds, each the
// user's to change in Settings → Agents:
//   recording   organizing a recording — the CLI's own model at low effort: a recording is long and its items need
//               judgement
//   cards       a batch of cards (snaps, voice notes), AI fill-in and other small runs — the cheapest model, low effort
// agents.json `processing` = {"recording": {model, effort}, "cards": {model, effort}}; config
// record.agent_processing.<agent id> the same shape, over it. model: an id | "cheapest" | "default" (the CLI's own
// setting); effort: a level | "default". v0.8's shape — one {model, effort} — still stands for both kinds.
import Foundation

public enum ProcessingKind: String, CaseIterable {
    case recording, cards

    /// What Blurt ships with, when neither agents.json nor the user says otherwise.
    public var shippedModel: String { self == .recording ? "default" : "cheapest" }
    public static let shippedEffort = "low"
}

public enum ProcessingSpec {
    /// One kind's {model, effort} out of a processing spec (per kind, or v0.8's one {model, effort}).
    public static func of(_ spec: Any?, _ kind: ProcessingKind) -> [String: String] {
        guard let d = spec as? [String: Any] else { return [:] }
        if let k = d[kind.rawValue] as? [String: Any] { return k.compactMapValues { $0 as? String } }
        var out: [String: String] = [:]
        for f in ["model", "effort"] { if let v = d[f] as? String { out[f] = v } }
        return out
    }

    /// What a run of `kind` asks for: the user's setting over agents.json's, over what Blurt ships with.
    public static func wanted(base: Any?, over: Any?, kind: ProcessingKind) -> (model: String, effort: String) {
        let b = of(base, kind), o = of(over, kind)
        return (o["model"] ?? b["model"] ?? kind.shippedModel, o["effort"] ?? b["effort"] ?? ProcessingKind.shippedEffort)
    }

    /// The user's record.agent_processing.<id> with one kind changed (nil model / effort = back to the default).
    /// Always written per kind: a v0.8 {model, effort} becomes that for both kinds first, so changing one leaves
    /// the other as the user had it. nil = nothing of the user's left.
    public static func setting(_ over: Any?, kind: ProcessingKind, model: String?, effort: String?) -> [String: Any]? {
        var out: [String: Any] = [:]
        for k in ProcessingKind.allCases {
            let cur = of(over, k)
            if !cur.isEmpty { out[k.rawValue] = cur }
        }
        var mine = of(over, kind)
        mine["model"] = model
        mine["effort"] = effort
        out[kind.rawValue] = mine.isEmpty ? nil : mine
        return out.isEmpty ? nil : out
    }

    /// The kind of run that organizes a session: a recording, or a batch of cards (a -shots / -voice session).
    public static func kind(forSession dir: URL, isShots: Bool) -> ProcessingKind {
        isShots || dir.lastPathComponent.hasSuffix("-voice") ? .cards : .recording
    }
}
