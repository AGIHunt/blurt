// The translate targets as Settings lists them, for dictation's "⌘ translates into" and ⌥T's "⌥T translates into"
// (docs/design/dictation-translate.md §9): Auto first — named by its pair, global-first (BlurtCore TranslateAutoPair:
// "Auto: 简体中文 ↔ English", "Auto: 日本語 ↔ English", "Auto: English ↔ Deutsch") — then every language by its own name
// (日本語, Español), as the list names them. Auto without a pair (English, and no other language of the list on this
// Mac) says it brings other languages into English, and the row says to pick a language for English text.
import AppKit
import BlurtCore

enum TranslateTargets {
    /// The target popups are wider than a page's other popups (SettingsMetrics.controlWidth, 180): Auto's label names a
    /// pair ("自动：简体中文 ↔ English", "Auto: English ↔ Português") and must not be cut. Right edges still line up.
    static let popupWidth: CGFloat = 240

    /// Auto's pair on this Mac: Blurt's language when the user picked one, else the system's languages (read from the
    /// user's global preferences: an explicit Blurt language replaces AppleLanguages for this process).
    static var pair: TranslateAutoPair {
        let raw = (Loc.setting ?? (Config.shared["lang"] as? String) ?? "auto").lowercased()
        let ui: String? = raw == "auto" ? nil : Loc.normalize(raw)
        let system = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                                            kCFPreferencesAnyHost) as? [String] ?? Locale.preferredLanguages
        return TranslateAutoPair.of(uiLanguage: ui, preferred: system)
    }

    /// "Auto: 简体中文 ↔ English" / "Auto: into English".
    static func autoLabel(_ p: TranslateAutoPair = pair) -> String {
        if let o = p.other { return Loc.t("dictation.translate.target.auto", table: "Dictation", p.home.endonym, o.endonym) }
        return Loc.t("dictation.translate.target.auto_one", table: "Dictation", p.home.endonym)
    }

    /// The popup's choices: Auto, then the languages.
    static func choices() -> [(DictationTranslateTarget, String)] {
        let p = pair
        return DictationTranslateTarget.allCases.map { ($0, $0 == .auto ? autoLabel(p) : $0.endonym) }
    }

    /// The row's line under Auto when it has no pair: pick a language for English text. nil otherwise.
    static func autoNote(_ t: DictationTranslateTarget) -> String? {
        let p = pair
        guard t == .auto, p.other == nil else { return nil }
        return Loc.t("dictation.translate.target.auto_one.note", table: "Dictation", p.home.endonym)
    }
}
