// Cloud polish (docs/design/dictation.md §Cloud polish): Light's windows and Structured's pass at key-up done by a model
// the user set up — DeepSeek, or any OpenAI- or Anthropic-compatible API with their own base URL and key — instead of
// the local one, which stays the fall-back for every failure (polish.py `cloud_polish`). Off until the user turns it
// on in Settings → Dictation → Cloud polish.
//
// record.dictation.cloud_polish = {"on", "provider" (deepseek | openai | anthropic), "base_url", "model"}; the key is
// in the login Keychain (service "Blurt Cloud Polish", account = the provider), read here and sent with each request
// to the local polish server (127.0.0.1, its token) — never written to a file or a log. What goes to the service: the
// dictation's text, the custom words, the app's name, the text around the cursor (when Settings → Dictation reads it)
// and the last few dictations in the same app (§Cloud polish: they named what the speaker was talking about: 豆宝 →
// 豆包). Never the recording.
//
// The reminder: while cloud polish isn't on, the first dictation of each day ends with one line in the island
// pointing to the setting, with "Don't remind me" (record.dictation.cloud_hint = false); the day it was shown is
// record.dictation.cloud_hint_day.
import Foundation
import Security
import BlurtCore

enum DictationCloud {
    enum Provider: String, CaseIterable, Identifiable {
        case deepseek, openai, anthropic
        var id: String { rawValue }
        var protocolName: String { self == .anthropic ? "anthropic" : "openai" }
        /// what the fields show until the user types their own
        var defaultBaseURL: String {
            switch self {
            case .deepseek: return "https://api.deepseek.com"
            case .openai: return "https://api.openai.com/v1"
            case .anthropic: return "https://api.anthropic.com"
            }
        }
        var defaultModel: String { self == .deepseek ? "deepseek-flash" : "" }
        /// where to get a key (DeepSeek's own page; the others are the user's own service). Not Model Studio's Qwen
        /// models: with this prompt qwen-flash / qwen-plus rewrote and condensed the takes (15–18 % from what was
        /// typed, against DeepSeek's 9 %; docs/design/first-minute-speech.md §2.5)
        var keyPage: URL? { self == .deepseek ? URL(string: "https://platform.deepseek.com/api_keys") : nil }
    }

    struct Setup: Equatable {
        var on = false
        var provider: Provider = .deepseek
        var baseURL = ""
        var model = ""
        var effectiveBaseURL: String { baseURL.trimmingCharacters(in: .whitespaces).isEmpty ? provider.defaultBaseURL : baseURL.trimmingCharacters(in: .whitespaces) }
        var effectiveModel: String { model.trimmingCharacters(in: .whitespaces).isEmpty ? provider.defaultModel : model.trimmingCharacters(in: .whitespaces) }
    }

    static var setup: Setup {
        let o = Dictation.settings["cloud_polish"] as? [String: Any] ?? [:]
        return Setup(on: o["on"] as? Bool ?? false, provider: Provider(rawValue: o["provider"] as? String ?? "") ?? .deepseek,
                     baseURL: o["base_url"] as? String ?? "", model: o["model"] as? String ?? "")
    }

    static func save(_ s: Setup) {
        var o: [String: Any] = ["on": s.on, "provider": s.provider.rawValue]
        if !s.baseURL.trimmingCharacters(in: .whitespaces).isEmpty { o["base_url"] = s.baseURL.trimmingCharacters(in: .whitespaces) }
        if !s.model.trimmingCharacters(in: .whitespaces).isEmpty { o["model"] = s.model.trimmingCharacters(in: .whitespaces) }
        Dictation.set("cloud_polish", o)
        emit(["event": "dictation_cloud", "action": "save", "on": s.on, "provider": s.provider.rawValue, "custom_url": !s.baseURL.isEmpty])
    }

    /// The request's `cloud` for polish.py — nil while it is off or has no key (then the local model polishes).
    static func payload() -> [String: Any]? {
        let s = setup
        guard s.on, !s.effectiveModel.isEmpty, let key = Key.read(s.provider), !key.isEmpty else { return nil }
        return payload(s, key: key)
    }

    static func payload(_ s: Setup, key: String) -> [String: Any] {
        ["provider": s.provider.rawValue, "base_url": s.effectiveBaseURL, "model": s.effectiveModel,
         "protocol": s.provider.protocolName, "key": key]
    }

    /// on, with a key: what the Settings row and the reminder ask
    static var ready: Bool { payload() != nil }

    /// How much longer than the local model's limit the app waits for an answer: polish.py's cloud limit (4 s and
    /// 6 ms a character, polish_cloud) — after it the local model answers instead.
    static func requestBudget(chars: Int) -> Double { 4 + 0.006 * Double(chars) }

    // MARK: the key (login Keychain)

    enum Key {
        static let service = "Blurt Cloud Polish"

        private static func query(_ p: Provider) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: p.rawValue]
        }

        static func read(_ p: Provider) -> String? {
            // tests (test commands only): a key from the environment, so a test build never touches the login Keychain
            let env = ProcessInfo.processInfo.environment
            if env["BLURT_TEST_COMMANDS"] == "1", let k = env["BLURT_TEST_CLOUD_KEY"] { return k.isEmpty ? nil : k }
            var q = query(p)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }

        @discardableResult
        static func write(_ p: Provider, _ key: String) -> Bool {
            if ProcessInfo.processInfo.environment["BLURT_TEST_CLOUD_KEY"] != nil,
               ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1" { return true }
            let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
            SecItemDelete(query(p) as CFDictionary)
            guard !k.isEmpty else { return true }
            var q = query(p)
            q[kSecValueData as String] = Data(k.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            q[kSecAttrLabel as String] = "Blurt Cloud Polish (\(p.rawValue))"
            return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        }

        static func has(_ p: Provider) -> Bool { !(read(p) ?? "").isEmpty }
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

    // MARK: the daily reminder

    /// Whether this take's end shows the reminder (and marks today as shown): cloud polish isn't on, the user hasn't
    /// said "Don't remind me", and it wasn't shown today.
    static func remindToday(now: Date = Date()) -> Bool {
        guard !ready, Dictation.settings["cloud_hint"] as? Bool != false else { return false }
        let day = dayString(now)
        guard Dictation.settings["cloud_hint_day"] as? String != day else { return false }
        Dictation.set("cloud_hint_day", day)
        return true
    }

    static func dayString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
