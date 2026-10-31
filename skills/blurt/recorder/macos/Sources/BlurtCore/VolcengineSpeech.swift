// Volcengine Speech (火山引擎豆包语音), the cloud recogniser dictation streams to while the user talks (docs/design/
// dictation.md §Cloud recognition; dictation-eval-2026-10-31.md §2.1, §5, §6.3 B′: Seed-ASR 2.0 `bigmodel_nostream`
// 2.18 % on the founder's 95 takes, ~0.5 s after key-up however long the take). It is a curated service for the speech
// job only, in mainland China (CloudPreset "volcengine-speech"; curated_models.json). Unlike the other services it
// takes two credentials — an App ID and an Access Token from the Volcengine Speech console — kept together as one
// Keychain item ("<App ID>:<Access Token>", account "volcengine-speech", service "Blurt Cloud Polish" like every other
// key) and handed to the scripts as VOLC_APP_ID and VOLC_ACCESS_TOKEN (CloudSpeech.environment). Pure: the pair's
// shape and checks (VolcengineSpeechTests).
import Foundation

public enum VolcengineSpeech {
    /// the preset (CloudPreset.all) and the Keychain account of its service
    public static let preset = "volcengine-speech"
    /// the recogniser's id in asr_models.json
    public static let modelID = "volcengine-seedasr"
    /// the variables transcribe.py's Volcengine backend reads
    public static let appIDVariable = "VOLC_APP_ID"
    public static let tokenVariable = "VOLC_ACCESS_TOKEN"

    /// The Keychain item for the pair. An App ID never has a ":"; a token may, so it goes last.
    public static func credential(appID: String, token: String) -> String {
        appID.trimmingCharacters(in: .whitespacesAndNewlines) + ":" + token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The pair back from the Keychain item; nil when it isn't one (an older or a stray value).
    public static func split(_ credential: String?) -> (appID: String, token: String)? {
        guard let c = credential, let i = c.firstIndex(of: ":") else { return nil }
        let a = String(c[..<i]), t = String(c[c.index(after: i)...])
        guard validAppID(a), !t.isEmpty else { return nil }
        return (a, t)
    }

    /// An App ID as the console shows it: letters and digits (it is a number today), up to 64.
    public static func validAppID(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil
    }

    /// Add Service offers it to people it can serve: a Mac set to mainland China, or someone who speaks Chinese (its
    /// accounts need mainland verification; it is a dictation option for Chinese speakers: DictationChoices.choices).
    public static func offered(regionCode: String?, languages: [String]) -> Bool {
        regionCode == "CN" || languages.contains { ["zh", "yue"].contains(String($0.lowercased().prefix(while: { $0.isLetter }))) }
    }

    public enum Problem: Hashable { case appID, token(CloudKeyCheck.Problem) }

    /// What keeps the pair from being saved or tested: the App ID's shape, then the token's (the same check as any
    /// key: no spaces, printable ASCII). nil: both look right.
    public static func problem(appID: String, token: String) -> Problem? {
        if !validAppID(appID.trimmingCharacters(in: .whitespacesAndNewlines)) { return .appID }
        return CloudKeyCheck.problem(token).map(Problem.token)
    }
}
