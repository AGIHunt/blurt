// What the island says when a take's words couldn't be recognised, and how long a take may wait for its words at all
// (2026-10-31, the founder). Unit-tested in Tests/BlurtCoreTests/DictationASRLineTests.
//
//   DictationASRFailure.line   the plain reason: a cloud key that was refused or can't be sent (Settings… — Retry
//                              would only fail the same way), a service that can't be reached or is rate-limited
//                              (Retry), the model too slow (Retry), anything else (Retry)
//   DictationASRFailure.definite  an answer the CLI fallback would only repeat (no model, a bad key, local-only on):
//                              the take doesn't wait for a second run of it
//   DictationTakeDeadline      a take never waits for its words forever: after key-up, at most this long, then "the
//                              speech model didn't answer · Retry" with the recording kept. Before, a server that was
//                              restarting sent every piece to a cold CLI run (up to 2 min each, one after another):
//                              the island showed dots for minutes.
//   CloudSpeechCheck           Settings' Test for a cloud speech service (`transcribe.py check-cloud`): its answer as
//                              one line, and a key's characters checked before it is saved
import Foundation

extension DictationASRFailure {
    /// What the island shows, and which button.
    public enum Line: Equatable {
        /// "Couldn't recognize that · Retry"
        case failed
        /// "The speech model didn't answer · Retry"
        case slow
        /// "The cloud speech key didn't work · Settings…": Retry would only fail again
        case cloudKey
        /// "Couldn't reach the cloud speech service · Retry"
        case cloudOffline
        /// "The cloud speech service refused: too many requests or no quota left · Retry"
        case cloudQuota

        /// Dictation.strings key
        public var key: String {
            switch self {
            case .failed: return "dictation.toast.asr_failed"
            case .slow: return "dictation.toast.asr_slow"
            case .cloudKey: return "dictation.toast.asr_cloud_key"
            case .cloudOffline: return "dictation.toast.asr_cloud_offline"
            case .cloudQuota: return "dictation.toast.asr_cloud_quota"
            }
        }
        /// Retry can help (else the button opens Settings)
        public var retryHelps: Bool { self != .cloudKey }
    }

    /// The line for this failure. transcribe.py's codes: auth (401/403, or a key with characters a key can't have),
    /// quota (429), network (unreachable, timed out), bad_response, privacy (local-only recognition is on), …
    public var line: Line {
        switch self {
        case .noModel: return .failed           // the island offers the download instead (noSpeechModel)
        case .timedOut: return .slow
        case .failed(let c):
            switch c {
            case "auth": return .cloudKey
            case "network": return .cloudOffline
            case "quota": return .cloudQuota
            default: return .failed
            }
        }
    }

    /// The speech server's answer is final: the CLI would say the same (no model here, a key the service refused or
    /// that can't be sent, local-only recognition on). Not worth a second, cold run while the user waits.
    public static func definite(_ code: String?) -> Bool {
        ["model_missing", "auth", "privacy"].contains(code ?? "")
    }
}

/// How long a take may wait for its words after key-up before it is called too slow (the recording stays: Retry).
/// Generous for a model loaded cold from disk (Whisper large-v3-turbo: ~30 s on the first load) plus the decode of
/// what is still left, never open-ended.
public enum DictationTakeDeadline {
    public static let base = 45.0
    public static let cap = 180.0
    public static func seconds(audioSeconds: Double) -> Double { min(cap, base + 0.5 * max(0, audioSeconds)) }
}

/// Settings' Test for a cloud speech service: `transcribe.py check-cloud`'s answer, and the key's own check.
public enum CloudSpeechCheck {
    public enum Result: Equatable {
        /// it answered in `ms`; `heard`: the test clip's words came back
        case ok(ms: Int, heard: Bool)
        /// a Dictation.strings key for the plain sentence
        case failed(String)
    }

    /// The answer's JSON → the result (nil JSON: the script couldn't run).
    public static func result(_ o: [String: Any]?) -> Result {
        guard let o else { return .failed("speech.cloud.check.other") }
        if o["ok"] as? Bool == true { return .ok(ms: o["ms"] as? Int ?? 0, heard: o["heard"] as? Bool ?? true) }
        return .failed(sentence(o["code"] as? String))
    }

    public static func sentence(_ code: String?) -> String {
        switch code {
        case "auth": return "speech.cloud.check.auth"
        case "network", "timeout": return "speech.cloud.check.network"
        case "quota": return "speech.cloud.check.quota"
        case "privacy": return "speech.cloud.check.privacy"
        case "no_key": return "speech.cloud.check.no_key"
        case "bad_key": return "speech.cloud.check.bad_key"
        default: return "speech.cloud.check.other"
        }
    }

    /// A key as typed → the key to keep, or nil when it has a character no API key has (what ⌥C types, "ç", came
    /// after the founder's key: every take then failed). Spaces and line breaks around it go; inside it they don't
    /// belong either.
    public static func clean(_ typed: String) -> String? {
        let k = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return "" }
        return k.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F } ? k : nil
    }
}
