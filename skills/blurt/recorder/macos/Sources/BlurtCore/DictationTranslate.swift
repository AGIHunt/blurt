// Dictation's translate mode (docs/design/dictation-translate.md): what you say is typed in another language (for
// chats with people abroad, and for instructions to Codex / Claude Code, which do better in English). Pure:
// DictationTranslateTests.
//
// Two features translate, usually in opposite directions (the founder, 2026-10-30: "think from use"): dictation's ⌘
// turns your own speech into another language (writing), ⌥T turns foreign text on the screen into yours (reading). So
// each has its own target and its own cloud switch (record.dictation.translate, record.screen_text.translate:
// ScreenTranslateConfig); the cloud model and its key are set up once, for both.
//
//  • on for a take: ⌘ alone while talking, or a click on the island's left half (DictationTrigger `.translate`); on
//    from the start in the apps the user listed (record.dictation.translate.apps). Never on by default anywhere.
//  • into what: Settings' target — Auto (TranslateAutoPair, global-first: your own language ↔ the other one; the
//    language the speech model heard decides, never a word list), or one language. A take already in the fixed
//    target isn't sent at all (typed as said); ⌥T copies such a text as it is.
//  • by what: the user's cloud model when it is set up and "use the cloud" is on (it scored 8.2 / 10 on real takes,
//    the local Gemma 4 E2B 6.5), else the local polish model, else nothing — then ⌘ says what translation needs and
//    the take is typed as said. One pass at key-up over the text in its style (polish.py `translate`, the same prompt
//    as ⌥T's), after Structured's.
//  • learning: ⌘ turned on in an app keeps it on there, ⌘ turned off removes the app (DictationRemember, v1.0.6); with
//    that switched off, an app where the user keeps turning it on is suggested once (DictationTranslateLearn: 3 of the
//    last takes, ≥ 70 % of them).
//
// record.dictation.translate = {"target": "auto" | "en" | "zh" | …, "cloud": true, "apps": [bundle ids],
//                               "asked": [bundle ids]}  (one dictionary: bundle ids have dots)
import Foundation

/// A translate target in Settings (dictation's "⌘ translates into", ⌥T's "⌥T translates into"): Auto — your own
/// language ↔ the other one (TranslateAutoPair), the model picks the direction — or one language.
public enum DictationTranslateTarget: String, CaseIterable, Hashable {
    case auto, en, zh, zhHant = "zh-Hant", ja, ko, fr, de, es, pt, it, ru

    /// The language in its own words, as Settings lists it ("日本語", "Español").
    public var endonym: String {
        switch self {
        case .auto: return ""
        case .en: return "English"
        case .zh: return "简体中文"
        case .zhHant: return "繁體中文"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .es: return "Español"
        case .pt: return "Português"
        case .it: return "Italiano"
        case .ru: return "Русский"
        }
    }

    /// What polish.py's `translate` takes when the text's language isn't known beforehand (⌥T can't know what it will
    /// read; a dictation whose language the speech model didn't say): Auto → the pair's request ("auto:ja|en"); a
    /// language → "X|keep" — into X, and a text already in X given back as it is. A fixed language always gives that
    /// language (the founder, 2026-10-30): v1.0.6 sent "X|home" and ⌥T with English set turned English into Chinese.
    public func request(auto pair: TranslateAutoPair) -> String { self == .auto ? pair.request : rawValue + "|keep" }

    /// A language code or name as the system, the speech model or a list gives it, in this list: "zh-Hans-CN", "zh",
    /// "cmn", "Chinese" → zh; "zh-Hant-TW", "zh-HK" → zh-Hant; "en-GB", "English" → en; "ja_JP", "Japanese" → ja …;
    /// nil for a language the list doesn't have. (Codes and names, never the text itself.)
    public static func of(_ code: String) -> DictationTranslateTarget? {
        let c = code.lowercased().replacingOccurrences(of: "_", with: "-")
        let base = String(c.prefix { $0 != "-" })
        switch base {
        case "zh", "cmn", "yue", "chinese", "mandarin", "cantonese":
            let parts = c.split(separator: "-").map(String.init)
            return parts.contains("hant") || (!parts.contains("hans") && ["tw", "hk", "mo"].contains { parts.contains($0) }) ? .zhHant : .zh
        case "en", "english": return .en
        case "ja", "japanese": return .ja
        case "ko", "korean": return .ko
        case "fr", "french": return .fr
        case "de", "german": return .de
        case "es", "spanish": return .es
        case "pt", "portuguese": return .pt
        case "it", "italian": return .it
        case "ru", "russian": return .ru
        default: return nil
        }
    }

    /// The language without its script: Simplified and Traditional Chinese are one (the speech model hears no script).
    public var family: String { self == .zhHant ? "zh" : rawValue }
}

/// What Auto means, the same for dictation and ⌥T (the founder, 2026-10-30: global-first — Chinese users are one
/// audience among many, nothing hard-codes Chinese ↔ English). `home`: the user's own language — Blurt's own when they
/// picked one, else the system's first preferred language that the list has (English when none is). `other`: English
/// when home isn't English; when it is, the user's next system language in the list — or none: then Auto only brings
/// other languages into English, and Settings says to pick a language for English text. Auto translates text in home
/// into other, and anything else into home; the model decides which the text is.
public struct TranslateAutoPair: Equatable {
    public let home: DictationTranslateTarget
    public let other: DictationTranslateTarget?

    public init(home: DictationTranslateTarget, other: DictationTranslateTarget?) { self.home = home; self.other = other }

    /// `uiLanguage`: Blurt's language when the user set one (nil: it follows the system); `preferred`: the system's
    /// languages, first first.
    public static func of(uiLanguage: String?, preferred: [String]) -> TranslateAutoPair {
        let langs = ([uiLanguage].compactMap { $0 } + preferred).compactMap(DictationTranslateTarget.of)
        let home = langs.first ?? .en
        if home != .en { return TranslateAutoPair(home: home, other: .en) }
        return TranslateAutoPair(home: .en, other: langs.first { $0 != .en })
    }

    /// polish.py's target: "auto:H|O" (text in H into O, anything else into H); without a pair, "H|keep" (into H, a
    /// text in H as it is).
    public var request: String { other.map { "auto:\(home.rawValue)|\($0.rawValue)" } ?? home.rawValue + "|keep" }
}

public struct DictationTranslateConfig: Equatable {
    /// "⌘ translates into" (dictation's own; ⌥T has ScreenTranslateConfig)
    public var target: DictationTranslateTarget = .auto
    /// the cloud model translates when one is set up (the founder: cloud first, with a switch)
    public var cloud = true
    /// every take is translated in these apps (the user's choice, or a suggestion they accepted)
    public var apps: Set<String> = []
    /// apps asked about once already, whatever the answer
    public var asked: Set<String> = []

    public init() {}

    public init(json: [String: Any]?) {
        guard let o = json else { return }
        target = (o["target"] as? String).flatMap(DictationTranslateTarget.init) ?? .auto
        cloud = o["cloud"] as? Bool ?? true
        apps = Set(o["apps"] as? [String] ?? [])
        asked = Set(o["asked"] as? [String] ?? [])
    }

    /// nil when everything is the default (the key goes away)
    public var json: [String: Any]? {
        var o: [String: Any] = [:]
        if target != .auto { o["target"] = target.rawValue }
        if !cloud { o["cloud"] = false }
        if !apps.isEmpty { o["apps"] = apps.sorted() }
        if !asked.isEmpty { o["asked"] = asked.sorted() }
        return o.isEmpty ? nil : o
    }

    /// A take into `bundle` starts translated.
    public func startsOn(bundle: String?) -> Bool { bundle.map(apps.contains) ?? false }
}

/// ⌥T's own settings (record.screen_text.translate, 2026-10-30): "⌥T translates into" and its cloud switch — reading
/// usually goes the other way from writing, so they aren't dictation's.
public struct ScreenTranslateConfig: Equatable {
    public var target: DictationTranslateTarget = .auto
    /// the cloud model translates when one is set up
    public var cloud = true

    public init() {}

    public init(json: [String: Any]?) {
        guard let o = json else { return }
        target = (o["target"] as? String).flatMap(DictationTranslateTarget.init) ?? .auto
        cloud = o["cloud"] as? Bool ?? true
    }

    /// Always written (the key's presence says the migration happened): {"cloud": …} and the target when not Auto.
    public var json: [String: Any] {
        var o: [String: Any] = ["cloud": cloud]
        if target != .auto { o["target"] = target.rawValue }
        return o
    }

    /// The first launch with ⌥T's own settings: before, ⌥T used dictation's target. Dictation keeps its target and
    /// switch; ⌥T starts at Auto (reading foreign text into your own language — dictation's fixed target was chosen
    /// for writing), with the cloud as dictation's switch was.
    public static func migrated(from d: DictationTranslateConfig) -> ScreenTranslateConfig {
        var c = ScreenTranslateConfig()
        c.cloud = d.cloud
        return c
    }
}

public enum DictationTranslateRoute {
    /// What the take is translated into, given the setting, Auto's pair and the language the speech model heard it in
    /// (a code or a name; nil when it said none). Auto: heard in home → other (nil when there is none: typed as said),
    /// heard in another language of the list → home, not heard (or one the list hasn't) → the pair's request (the
    /// model decides). A fixed X → X, and nil (nothing sent, typed as said) when the take is in X already — ⌥T's rule
    /// too (2026-10-30; v1.0.6 translated it into the system's language instead); nothing heard → "X|keep".
    public static func target(_ setting: DictationTranslateTarget, spoken: String?, auto pair: TranslateAutoPair) -> String? {
        let heard = spoken.flatMap(DictationTranslateTarget.of)
        switch setting {
        case .auto:
            guard let h = heard else { return pair.request }
            if h.family == pair.home.family { return pair.other?.rawValue }
            return pair.home.rawValue
        default:
            guard let h = heard else { return setting.request(auto: pair) }
            // Chinese speech into Traditional is still a translation (the script changes)
            guard setting != .zhHant, h.family == setting.family else { return setting.rawValue }
            return nil
        }
    }

    /// The model gave the text back as it was, line breaks and spacing aside, to a request that keeps a text already in
    /// its language ("X|keep": a fixed language, or Auto without a pair) → X, the language it is in already; else nil.
    /// The model decided the language; this only compares the answer with the question. A plain Auto never says so (a
    /// command or a name comes back as it is: there was nothing to translate).
    public static func keptAsIs(request: String, source: String, output: String) -> DictationTranslateTarget? {
        guard request.hasSuffix("|keep"), let x = DictationTranslateTarget(rawValue: String(request.dropLast(5))) else { return nil }
        let squash = { (s: String) in s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ") }
        let a = squash(source), b = squash(output)
        return !a.isEmpty && a == b ? x : nil
    }

    /// "zh-Hans", "zh_CN", "yue", "Chinese" → "zh"; "en-US", "English" → "en"; anything else as it is
    public static func family(_ code: String) -> String {
        let c = code.lowercased()
        if c.hasPrefix("zh") || c == "yue" || c == "cmn" || c == "chinese" || c == "cantonese" { return "zh" }
        if c.hasPrefix("en") || c == "english" { return "en" }
        return c
    }

    /// What translates a take: the cloud, the local polish model, or nothing.
    public enum Engine: String, Equatable {
        case cloud, local, none
    }

    /// `cloudReady`: a cloud model with a key is set up; `useCloud`: Settings' "use the cloud model to translate";
    /// `localModel`: the local polish model is installed (and this Mac can run it).
    public static func engine(cloudReady: Bool, useCloud: Bool, localModel: Bool) -> Engine {
        if cloudReady && useCloud { return .cloud }
        return localModel ? .local : .none
    }

    /// The first time a take is translated by the local model with no cloud set up, the island says once that the
    /// cloud translates better (8.2 vs 6.5 on the founder's takes); never when the user turned the cloud off on purpose.
    public static func suggestsCloud(engine: Engine, cloudReady: Bool, useCloud: Bool, alreadySaid: Bool) -> Bool {
        engine == .local && !cloudReady && useCloud && !alreadySaid
    }
}

/// ⌘ / the island while listening: the first `explainTimes` toggles on ever say what it does, then only the ear's
/// glyph tells (as Structured's line: DictationStyleToggleHint).
public enum DictationTranslateHint {
    public static let explainTimes = 2
    public static func says(shown: Int) -> Bool { shown < explainTimes }

    /// What the ear says beside the translate glyph and the clock, so the take's target reads without the line:
    /// "EN", "中", "繁", "日", "한", "FR"…, "⇄" (either way).
    public static func earTarget(_ t: DictationTranslateTarget) -> String {
        switch t {
        case .auto: return "⇄"
        case .en: return "EN"
        case .zh: return "中"
        case .zhHant: return "繁"
        case .ja: return "日"
        case .ko: return "한"
        case .fr, .de, .es, .pt, .it, .ru: return t.rawValue.uppercased()
        }
    }
}

/// The history's `translate`: on for the take, how, into what, by what, and what came of it.
public struct DictationTranslateRecord: Hashable {
    /// command (⌘) | island | app (the app is in the list)
    public var source: String
    /// how often ⌘ / the island switched it during the take
    public var toggles: Int
    /// what was asked ("en", "zh", "auto"); nil: the take was already in the target (nothing sent)
    public var target: String?
    /// cloud | local | none
    public var engine: String
    /// the text in its style before translation (what was said); nil when nothing was translated
    public var said: String?
    /// the translation was refused or failed: the take went in as said (why: the guard's reason, a cloud error code,
    /// model_missing, timeout …)
    public var fellBack: Bool
    public var reason: String?
    /// the cloud failed or was refused first and the local model answered (its code)
    public var cloudError: String?
    public var ms: Int

    public init(source: String, toggles: Int = 0, target: String?, engine: String, sourceText: String? = nil,
                fellBack: Bool = false, reason: String? = nil, cloudError: String? = nil, ms: Int = 0) {
        self.source = source; self.toggles = toggles; self.target = target; self.engine = engine
        self.said = sourceText; self.fellBack = fellBack; self.reason = reason; self.cloudError = cloudError; self.ms = ms
    }

    public var json: [String: Any] {
        var o: [String: Any] = ["source": source, "toggles": toggles, "engine": engine, "fell_back": fellBack, "ms": ms]
        if let t = target { o["target"] = t }
        if let s = said { o["said"] = s }
        if let r = reason { o["reason"] = r }
        if let c = cloudError { o["cloud_error"] = c }
        return o
    }

    public init?(json o: [String: Any]) {
        guard let s = o["source"] as? String, let e = o["engine"] as? String else { return nil }
        source = s; engine = e
        toggles = o["toggles"] as? Int ?? 0
        target = o["target"] as? String
        said = o["said"] as? String
        fellBack = o["fell_back"] as? Bool ?? false
        reason = o["reason"] as? String
        cloudError = o["cloud_error"] as? String
        ms = o["ms"] as? Int ?? 0
    }
}

/// Learning (suggest, never switch): an app whose takes the user keeps translating by hand is offered "translate in
/// this app from now on", once.
public enum DictationTranslateLearn {
    public static let minSignals = 3
    public static let share = 0.7
    public static let window = 10

    /// Ask about `bundle` now? Entries newest first (DictationHistory.load): of the app's last `window` takes, at least
    /// `minSignals` and `share` of them translated by hand (⌘ / the island).
    public static func suggest(entries: [DictationEntry], bundle: String, config: DictationTranslateConfig) -> Bool {
        guard !config.apps.contains(bundle), !config.asked.contains(bundle) else { return false }
        let mine = entries.filter { $0.bundle == bundle }.prefix(window)
        let on = mine.filter { $0.translate.map { $0.source != "app" } ?? false }.count
        guard on >= minSignals else { return false }
        return Double(on) / Double(mine.count) >= share
    }
}
