// Which installed model is which and whether Blurt uses it, for Settings → Storage — from the scripts' own answers:
// transcribe.py models (speech recognition: the recordings', live captions' and voice notes' picks in "purposes", the
// voice-activity detector every local model needs), transcribe.py dictation-models (the model Fn dictation runs:
// "selected", chosen apart from those purposes) and polish.py models (dictation's clean-up: "selected"). A model in
// use is never offered for the Trash; when the dictation answer is missing (an older skill, a timeout) no speech model
// is, since the one dictation runs can't be told apart.
import Foundation

public enum ModelUsage {
    public enum Kind: Equatable { case asr, vad, polish }

    public struct Use: Equatable {
        public let name: String
        public let kind: Kind
        public let inUse: Bool
        /// May go to the Trash (if Blurt downloaded it): nothing uses it, and we know that for sure.
        public let removable: Bool
    }

    /// Model folder (as `root` spells it) → what it is. `asr`, `dictation`, `polish`: the scripts' JSON (nil = no answer).
    public static func merge(asr: [String: Any]?, dictation: [String: Any]?, polish: [String: Any]?) -> [String: Use] {
        var out: [String: Use] = [:]
        let dictating = dictation?["selected"] as? String
        for m in (asr?["models"] as? [[String: Any]]) ?? [] where m["installed"] as? Bool == true {
            guard let p = m["path"] as? String else { continue }
            let vad = m["role"] as? String == "vad"
            let used = vad || !((m["purposes"] as? [String]) ?? []).isEmpty || (dictating != nil && m["id"] as? String == dictating)
            out[root(p)] = Use(name: m["name"] as? String ?? p, kind: vad ? .vad : .asr, inUse: used,
                               removable: !used && dictating != nil)
        }
        let sel = polish?["selected"] as? String
        for m in (polish?["models"] as? [[String: Any]]) ?? [] where m["installed"] as? Bool == true {
            guard let p = m["path"] as? String else { continue }
            let used = m["id"] as? String == sel
            out[root(p)] = Use(name: m["name"] as? String ?? p, kind: .polish, inUse: used, removable: !used)
        }
        return out
    }

    /// A model's folder as the Storage rows list it: ours as they are; in the Hugging Face cache, the repo folder
    /// (…/hub/models--org--name), not the snapshot inside it.
    public static func root(_ p: String) -> String {
        let u = URL(fileURLWithPath: p).standardizedFileURL
        var c = u
        while c.path != "/" {
            if c.lastPathComponent.hasPrefix("models--") { return c.path }
            c.deleteLastPathComponent()
        }
        return u.path
    }
}
