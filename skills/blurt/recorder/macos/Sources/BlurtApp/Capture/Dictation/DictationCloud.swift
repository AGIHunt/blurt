// Cloud polish (docs/design/dictation.md §Cloud polish): Light's windows and Structured's pass at key-up done by the
// model Settings → Models gives the Polish job — a connected cloud service's (CloudStore: DeepSeek, Model Studio, Kimi,
// …, or the user's own OpenAI- or Anthropic-compatible API) — instead of the local one, which stays the fall-back for
// every failure (polish.py `cloud_polish`). Auto: the best connected service, else this Mac.
//
// What goes to the service: the dictation's text, the custom words, the app's name, the text around the cursor (when
// Settings → Dictation reads it) and the last few dictations in the same app (§Cloud polish: they named what the
// speaker was talking about: 豆宝 → 豆包). Never the recording. The key travels with each request to the local polish
// server (127.0.0.1, its token) — never written to a file or a log.
//
// The reminder: while nothing polishes in the cloud, once ever — after 10 dictations, into a quiet island, a timed
// line with Set Up… (BlurtCore DictationCloudReminder; record.dictation.cloud_hint_shown once it was seen). An older
// "Don't remind me" (record.dictation.cloud_hint = false) still counts as seen.
//
// Until v1.0.7 this held one service of its own (record.dictation.cloud_polish, kept as it was for an older version);
// CloudMigration carried it into record.cloud.
import Foundation
import BlurtCore

enum DictationCloud {
    /// The old providers' Keychain accounts (CloudSpeech still asks for Model Studio's by this name).
    enum Provider: String { case deepseek, dashscope, openai, anthropic }

    /// The request's `cloud` for polish.py — nil while Polish runs on this Mac (or its service has no key).
    static func payload() -> [String: Any]? { CloudStore.payload(.polish) }

    /// polish runs in the cloud: what the reminder and the rows ask
    static var ready: Bool { payload() != nil }

    /// How much longer than the local model's limit the app waits for an answer: polish.py's cloud limit (4 s and
    /// 6 ms a character, polish_cloud) — after it the local model answers instead.
    static func requestBudget(chars: Int) -> Double { 4 + 0.006 * Double(chars) }

    // MARK: the key (login Keychain): CloudStore's, by the old provider's account

    enum Key {
        static func read(_ p: Provider) -> String? { CloudStore.Key.read(p.rawValue) }
        static func has(_ p: Provider) -> Bool { read(p) != nil }
    }

    // MARK: what the cloud model is told besides the dictation

    static let recentCount = 3
    static let recentWindow: TimeInterval = 30 * 60

    /// The last few dictations typed into the same app in the last half hour (their final text), oldest first: they
    /// name what the speaker is talking about. Only for cloud polish (the local prompt has no room for them).
    static func recent(bundle: String?, before: Date = Date()) -> [String] {
        guard let b = bundle, !b.isEmpty else { return [] }
        let since = before.addingTimeInterval(-recentWindow)
        let mine = DictationHistory.shared.load().filter { $0.bundle == b && $0.time >= since && $0.time < before }
        return mine.sorted { $0.time < $1.time }.suffix(recentCount).map { $0.finalText }.filter { !$0.isEmpty }
    }

    // MARK: days

    static func dayString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
