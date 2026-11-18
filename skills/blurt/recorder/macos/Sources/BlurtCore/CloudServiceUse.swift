// Settings → Models from the top (2026-11-16, a Windows user: "I can't set it at the top, only down in each feature";
// docs/design/system.md §3.4): Add Cloud Model offers every service — the curated ones first, then every other text
// service and the compatible endpoints, which ask for a model ID and the features to use it for —, a connected
// service's line says what uses it, and a service that recognises speech offers dictation by an explicit click (the
// recording never leaves the Mac by itself). Pure, so the rules are unit-tested (CloudServiceUseTests).
import Foundation

public enum CloudServiceUse {
    /// The services Add Cloud Model offers, in order: the curated ones not added yet (`curated` in its order), then
    /// every other text service not added yet, then the user's own compatible endpoints (always: one may add several).
    /// `keep`: a preset shown however it stands (the one picked now).
    public static func offered(curated: [String], taken: Set<String>, keep: String? = nil) -> [CloudPreset] {
        let cur = Set(curated)
        let free = { (p: CloudPreset) in !taken.contains(p.id) || p.id == keep }
        let first = curated.compactMap { id in CloudPreset.preset(id).flatMap { free($0) ? $0 : nil } }
        let rest = CloudPreset.all.filter { !cur.contains($0.id) && !$0.custom && !$0.speechOnly && free($0) }
        return first + rest + CloudPreset.all.filter(\.custom)
    }

    /// Where the pop-up's dividers go: after the curated services, before the compatible endpoints.
    public static func dividers(_ list: [CloudPreset], curated: [String]) -> Set<Int> {
        var d = Set<Int>()
        let n = list.prefix { curated.contains($0.id) }.count
        if n > 0, n < list.count { d.insert(n) }
        if let i = list.firstIndex(where: \.custom), i > 0 { d.insert(i) }
        return d
    }

    /// A service Blurt never measured needs a model ID and the features it is for.
    public static func needsModel(_ preset: String, curated: [String]) -> Bool { !curated.contains(preset) }

    /// The features a new untested service starts checked for: Polish and Translate — not Copy Text from Screen (most
    /// text models can't read images, and it sends screenshots).
    public static let defaultJobs: Set<CloudJob> = [.polish, .translate]

    /// Dictation's recogniser a connected service gives (nil: it recognises nothing Blurt measured): Model Studio's
    /// Qwen3-ASR Flash, Volcengine's Seed-ASR. OpenAI's is Advanced only.
    public static func recognizer(preset: String) -> String? {
        switch preset {
        case "dashscope": return "qwen3-asr-flash"
        case VolcengineSpeech.preset: return VolcengineSpeech.modelID
        default: return nil
        }
    }

    /// Whether dictation's recogniser now is this service's.
    public static func dictates(preset: String, recognizer now: String?) -> Bool {
        guard let r = recognizer(preset: preset), let now else { return false }
        return now == r
    }

    /// The row offers Use for Dictation: the service recognises speech, Privacy lets recognition leave the Mac, and
    /// dictation isn't on it already.
    public static func offersDictation(preset: String, recognizer now: String?, localOnly: Bool) -> Bool {
        recognizer(preset: preset) != nil && !localOnly && !dictates(preset: preset, recognizer: now)
    }

    /// What a connected service is used for, in the rows' order: Dictation (its recogniser), then the text jobs on it.
    public enum Use: Hashable { case dictation, job(CloudJob) }

    public static func uses(serviceID: String, preset: String, routes: [CloudJob: CloudRoute], recognizer now: String?) -> [Use] {
        var out: [Use] = dictates(preset: preset, recognizer: now) ? [.dictation] : []
        for j in CloudJob.allCases {
            if case .cloud(let id, _)? = routes[j], id == serviceID { out.append(.job(j)) }
        }
        return out
    }

    /// "听写润色、翻译" / "Polish, Translation".
    public static func list(_ names: [String], chinese: Bool) -> String { names.joined(separator: chinese ? "、" : ", ") }
}
