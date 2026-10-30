// Dictation's translate mode (docs/design/dictation-translate.md): the founder speaks Chinese and English is typed (for
// chats with people abroad, and for instructions to Codex / Claude Code, which do better in English) — or the other
// way round. Pure: DictationTranslateTests.
//
//  • on for a take: ⌘ alone while talking, or a click on the island's left half (DictationTrigger `.translate`); on
//    from the start in the apps the user listed (record.dictation.translate.apps). Never on by default anywhere.
//  • into what: Settings' target — auto (the other of zh / en: the language the speech model heard decides, never a
//    word list), English, or Chinese. A take already in the fixed target isn't sent at all.
//  • by what: the user's cloud model when it is set up and "use the cloud" is on (it scored 8.2 / 10 on real takes,
//    the local Gemma 4 E2B 6.5), else the local polish model, else nothing — then ⌘ says what translation needs and
//    the take is typed as said. One pass at key-up over the text in its style (polish.py `translate`, the same prompt
//    as ⌥T's), after Structured's.
//  • learning only suggests: turned on by hand in 3 of an app's last takes (≥ 70 % of the toggles) → asked once.
//
// record.dictation.translate = {"target": "auto" | "en" | "zh", "cloud": true, "apps": [bundle ids],
//                               "asked": [bundle ids]}  (one dictionary: bundle ids have dots)
import Foundation

/// Settings' "Translate into" (dictation and ⌥T share it): auto = Chinese ↔ English, the model picks the direction;
/// else one language (v1.0.6: the cloud models translate any of these; before, English or Chinese only).
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

    /// What polish.py's `translate` takes: "auto"; or "X|Y" — into X, and into `home` (the user's own language) when
    /// the text is in X already (⌥T can't know what it will read; a dictation whose language wasn't heard).
    public func request(home: String) -> String {
        guard self != .auto else { return "auto" }
        let h = DictationTranslateRoute.family(home)
        let y = h == DictationTranslateRoute.family(rawValue) && self != .zhHant ? (h == "en" ? "zh" : "en") : h
        return rawValue + "|" + y
    }
}

public struct DictationTranslateConfig: Equatable {
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

public enum DictationTranslateRoute {
    /// What the take is translated into, given the setting, the language the speech model heard it in ("zh", "en",
    /// nil when it said none) and `home`, the user's own language (the system's first): auto → the other of Chinese
    /// and English ("auto" when nothing was heard: the model decides); a fixed X → X, or `home` when the take is in X
    /// already (the founder, v1.0.6) — nil when that is X too; nothing heard → "X|home" (polish.py: X, or home if it
    /// was X).
    public static func target(_ setting: DictationTranslateTarget, spoken: String?, home: String = "zh") -> String? {
        let heard = spoken.map(family)
        switch setting {
        case .auto:
            switch heard {
            case "zh"?: return "en"
            case "en"?: return "zh"
            default: return "auto"
            }
        default:
            guard let h = heard else { return setting.request(home: home) }
            // Chinese speech into Traditional is still a translation (the script changes)
            guard setting != .zhHant, h == family(setting.rawValue) else { return setting.rawValue }
            let mine = family(home)
            return mine == h ? nil : mine
        }
    }

    /// The user's own language from the system's list ("zh-Hans-CN" → "zh", "en-US" → "en", "ja-JP" → "ja").
    public static func home(_ preferred: [String]) -> String {
        let c = family(preferred.first ?? "zh")
        return String(c.prefix(while: { $0 != "-" && $0 != "_" }))
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
