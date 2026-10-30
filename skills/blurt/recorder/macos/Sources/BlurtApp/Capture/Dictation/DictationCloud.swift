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
// The reminder: while cloud polish isn't on, once ever — after 10 dictations, into a quiet island, a timed line with
// Set Up… (BlurtCore DictationCloudReminder; record.dictation.cloud_hint_shown once it was seen). An older
// "Don't remind me" (record.dictation.cloud_hint = false) still counts as seen.
import Foundation
import Security
import BlurtCore

enum DictationCloud {
    enum Provider: String, CaseIterable, Identifiable {
        case deepseek, dashscope, openai, anthropic
        var id: String { rawValue }
        var protocolName: String { self == .anthropic ? "anthropic" : "openai" }
        /// what the fields show until the user types their own
        var defaultBaseURL: String {
            switch self {
            case .deepseek: return "https://api.deepseek.com"
            case .dashscope: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
            case .openai: return "https://api.openai.com/v1"
            case .anthropic: return "https://api.anthropic.com"
            }
        }
        /// Model Studio (百炼): DeepSeek V4.1 Flash hosted there polishes and translates as DeepSeek's own does (its
        /// older qwen-flash / qwen-plus rewrote the takes); Copy Text from Screen reads with qwen3.6-flash, and the same
        /// key does cloud speech (polish_cloud.py PRESETS; docs/design/first-minute-speech.md §2.5)
        var defaultModel: String {
            switch self {
            case .deepseek: return "deepseek-flash"
            case .dashscope: return "deepseek-v4.1-flash"
            default: return ""
            }
        }
        /// where to get a key (DeepSeek's and Model Studio's own pages; the others are the user's own service)
        var keyPage: URL? {
            switch self {
            case .deepseek: return URL(string: "https://platform.deepseek.com/api_keys")
            case .dashscope: return URL(string: "https://bailian.console.aliyun.com/?tab=model#/api-key")
            default: return nil
            }
        }
        /// polish's recommended service: DeepSeek, everywhere (the founder, 2026-10-29: Aliyun first for speech,
        /// DeepSeek first for polish)
        static var recommended: Provider { .deepseek }
    }

    struct Setup: Equatable {
        var on = false
        var provider: Provider = .deepseek
        var baseURL = ""
        var model = ""
        /// translate's and Copy Text from Screen's model ("" = the provider's default: translate the polish model, Copy
        /// Text from Screen the provider's vision model — CloudModels)
        var translateModel = ""
        var visionModel = ""
        var effectiveBaseURL: String { baseURL.trimmingCharacters(in: .whitespaces).isEmpty ? provider.defaultBaseURL : baseURL.trimmingCharacters(in: .whitespaces) }
        var effectiveModel: String { model.trimmingCharacters(in: .whitespaces).isEmpty ? provider.defaultModel : model.trimmingCharacters(in: .whitespaces) }
        /// Where the text goes, for people: the service's name ("DeepSeek", "阿里云百炼"), or the host of the user's
        /// own endpoint — never a model id.
        var destination: String {
            switch provider {
            case .deepseek: return "DeepSeek"
            case .dashscope: return Loc.t("dictation.cloud.provider.dashscope", table: "Dictation")
            case .openai, .anthropic: return URL(string: effectiveBaseURL)?.host ?? effectiveBaseURL
            }
        }
    }

    static var setup: Setup {
        let o = Dictation.settings["cloud_polish"] as? [String: Any] ?? [:]
        return Setup(on: o["on"] as? Bool ?? false, provider: Provider(rawValue: o["provider"] as? String ?? "") ?? .recommended,
                     baseURL: o["base_url"] as? String ?? "", model: o["model"] as? String ?? "",
                     translateModel: o["translate_model"] as? String ?? "", visionModel: o["vision_model"] as? String ?? "")
    }

    static func save(_ s: Setup) {
        var o: [String: Any] = ["on": s.on, "provider": s.provider.rawValue]
        if !s.baseURL.trimmingCharacters(in: .whitespaces).isEmpty { o["base_url"] = s.baseURL.trimmingCharacters(in: .whitespaces) }
        if !s.model.trimmingCharacters(in: .whitespaces).isEmpty { o["model"] = s.model.trimmingCharacters(in: .whitespaces) }
        for (k, v) in [("translate_model", s.translateModel), ("vision_model", s.visionModel)] {
            let t = v.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { o[k] = t }
        }
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
        var p: [String: Any] = ["provider": s.provider.rawValue, "base_url": s.effectiveBaseURL, "model": s.effectiveModel,
                                "protocol": s.provider.protocolName, "key": key]
        // translate / Copy Text from Screen on their own model when one was picked (polish_cloud.settings fills the
        // provider's default otherwise)
        let t = s.translateModel.trimmingCharacters(in: .whitespaces), v = s.visionModel.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { p["translate_model"] = t }
        if !v.isEmpty { p["vision_model"] = v }
        return p
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

        /// A test build (BLURT_TEST_COMMANDS=1) never touches the login Keychain — never reads the user's real key
        /// (it would go to the provider), never deletes it: BLURT_TEST_CLOUD_KEY, else what this run saved.
        static var testBuild: Bool { ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1" }
        private static var testKeys: [Provider: String] = [:]

        static func read(_ p: Provider) -> String? {
            if testBuild {
                if let k = testKeys[p] { return k.isEmpty ? nil : k }
                return ProcessInfo.processInfo.environment["BLURT_TEST_CLOUD_KEY"].flatMap { $0.isEmpty ? nil : $0 }
            }
            var q = query(p)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }

        @discardableResult
        static func write(_ p: Provider, _ key: String) -> Bool {
            if testBuild { testKeys[p] = key.trimmingCharacters(in: .whitespacesAndNewlines); return true }
            let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
            // an empty key is the one way to remove it; otherwise update in place, and add only when there is none —
            // never delete first (a failed add, a locked Keychain, would lose the key that worked)
            guard !k.isEmpty else {
                let r = SecItemDelete(query(p) as CFDictionary)
                return r == errSecSuccess || r == errSecItemNotFound
            }
            let update = SecItemUpdate(query(p) as CFDictionary, [kSecValueData as String: Data(k.utf8)] as CFDictionary)
            guard update == errSecItemNotFound else { return update == errSecSuccess }
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

    // MARK: days

    static func dayString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
