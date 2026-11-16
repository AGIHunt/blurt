//! Alt+Shift+T's direction from the text itself (the Mac's BlurtCore TranslateDirection, 2026-11-16;
//! docs/design/screen-text.md §1g). Asking the model to pick the direction ("text in H into O, anything else into H")
//! failed on the Mac's local model — it gave English back as English and put Japanese into English — while the same
//! model asked for one language was right every time. So the text's language is identified first, by a statistical
//! language identifier (whatlang: the script, then trigram profiles over the whole text — no word lists), and polish.py
//! is asked for one language:
//!
//!  • Auto (your language ↔ the other one): text in your language → the other one; text in ANY other language → yours;
//!    not sure → the pair's request, `auto:H|O`, as before (the model decides);
//!  • a fixed X: text already in X → nothing is sent ("Already in X · original copied"); else `X` — or `X|keep` when
//!    the language isn't known (into X, a text already in X given back as it is).
//!
//! Sure means one of two things. The identifier's confidence is at least `SURE` — whatlang's confidence is the lead
//! over the runner-up against the lead it counts as certain for a text that long, not a probability as Apple's is,
//! and a plain English sentence often scores 0.35–0.5 against the other Latin-script languages (measured 2026-11-16: no
//! wrong answer at 0.6 or more; English read as French at 0.32). Or none of the text's letters is in a script the
//! language is written in (whatlang's own script → languages table, letter by letter): an English or Thai text is
//! surely not Chinese or Japanese, whichever Latin or Thai language it is — which settles Auto whenever your own
//! language has a script of its own, where the question is only "yours or not".
//!
//! whatlang reads only the script most letters are in, and a Chinese sentence with a few English names in it has more
//! Latin letters than Han characters ("用 Claude Code 跑一下测试" read as Romanian): a Latin-script answer over a text
//! with at least `MIXED` of its letters in another script doesn't count — the model decides, as before.
//!
//! What Auto means is the user's own (the Mac's TranslateAutoPair, global-first: nothing hard-codes Chinese ↔ English):
//! `Pair::of` — home is Blurt's language when the user picked one, else the system's first preferred language the list
//! has (English when none is); other is English when home isn't, else the system's next language in the list, else
//! none (Auto then only brings other languages into English, and Settings says to pick a language for English text).
//! The system's languages: Windows' GetUserPreferredUILanguages, Linux's LANGUAGE / LC_ALL / LC_MESSAGES / LANG
//! (sys-locale reads both). Dictation's Auto (dictation/engine.rs) goes by the same pair and the same plan.

/// The confidence at which the identifier's answer is taken (on whatlang's scale; see above).
pub const SURE: f64 = 0.6;
/// The share of letters in another script that makes a Latin-script answer unsure (a Han character is a word).
pub const MIXED: f64 = 0.1;

/// What Auto means: text in `home` → `other`; anything else → `home`. `other` None: Auto only brings other languages
/// into `home` (a text in `home` is kept as it is).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pair {
    pub home: String,
    pub other: Option<String>,
}

impl Pair {
    pub fn new(home: &str, other: Option<&str>) -> Pair {
        Pair { home: home.to_string(), other: other.map(str::to_string) }
    }

    /// polish.py's target when the direction is the model's: "auto:H|O"; without a pair "H|keep".
    pub fn request(&self) -> String {
        match &self.other {
            Some(o) => format!("auto:{}|{o}", self.home),
            None => format!("{}|keep", self.home),
        }
    }
}

impl Pair {
    /// `ui`: Blurt's language when the user picked one (None: it follows the system); `preferred`: the system's
    /// languages, first first (the Mac's TranslateAutoPair.of(uiLanguage:preferred:)).
    pub fn of(ui: Option<&str>, preferred: &[String]) -> Pair {
        let langs: Vec<&'static str> = ui.into_iter().chain(preferred.iter().map(String::as_str)).filter_map(target_of).collect();
        let home = langs.first().copied().unwrap_or("en");
        if home != "en" {
            return Pair::new(home, Some("en"));
        }
        Pair::new("en", langs.iter().copied().find(|l| *l != "en"))
    }
}

/// The settings' translate targets, in Settings' order (the Mac's DictationTranslateTarget, Auto aside).
pub const TARGETS: [&str; 11] = ["en", "zh", "zh-Hant", "ja", "ko", "fr", "de", "es", "pt", "it", "ru"];

/// A language code or name as the system or a list gives it, in the targets: "zh-Hans-CN", "zh", "zh_CN" → zh;
/// "zh-Hant-TW", "zh-HK" → zh-Hant; "en-GB" → en; "ja_JP" → ja …; None for a language the list doesn't have ("C",
/// "th"). Codes and names, never the text itself (the Mac's DictationTranslateTarget.of).
pub fn target_of(code: &str) -> Option<&'static str> {
    let c = code.to_ascii_lowercase().replace('_', "-");
    let c = c.split(['.', '@']).next().unwrap_or("");
    let parts: Vec<&str> = c.split('-').collect();
    Some(match parts[0] {
        "zh" | "cmn" | "yue" | "chinese" | "mandarin" | "cantonese" => {
            let hant = parts.contains(&"hant") || (!parts.contains(&"hans") && ["tw", "hk", "mo"].iter().any(|r| parts.contains(r)));
            if hant {
                "zh-Hant"
            } else {
                "zh"
            }
        }
        "en" | "english" => "en",
        "ja" | "japanese" => "ja",
        "ko" | "korean" => "ko",
        "fr" | "french" => "fr",
        "de" | "german" => "de",
        "es" | "spanish" => "es",
        "pt" | "portuguese" => "pt",
        "it" | "italian" => "it",
        "ru" | "russian" => "ru",
        _ => return None,
    })
}

/// Auto's pair on this computer: Blurt's language when the user picked one (config `lang`, or `$BLURT_LANG` in tests),
/// else the system's languages.
pub fn pair() -> Pair {
    let picked = std::env::var("BLURT_LANG").ok().filter(|l| !l.is_empty()).or_else(|| {
        crate::settings::read_config().get("lang").and_then(serde_json::Value::as_str).filter(|l| !l.is_empty() && *l != "auto").map(str::to_string)
    });
    let system: Vec<String> = sys_locale::get_locales().collect();
    Pair::of(picked.as_deref(), &system)
}

/// What the main window's settings show for Auto (its label, the line under it).
#[tauri::command]
pub fn translate_auto_pair() -> serde_json::Value {
    let p = pair();
    serde_json::json!({"home": p.home, "other": p.other})
}

/// What the identifier made of a text.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Reading {
    /// the language, when the identifier is sure: a target code where the list has it ("en", "zh", "ja", "ko", "fr",
    /// "de", "es", "pt", "it", "ru"), else the ISO 639-3 code ("tha", "vie" …)
    pub lang: Option<String>,
    /// the languages its letters' scripts are written in (families, as `lang`): a language not among them, the text is
    /// surely not in; empty when the scripts say nothing
    pub script: Vec<String>,
}

impl Reading {
    /// The text is surely not in `code`'s language.
    fn surely_not(&self, code: &str) -> bool {
        let f = family(code);
        match &self.lang {
            Some(l) => family(l) != f,
            None => !self.script.is_empty() && !self.script.contains(&f),
        }
    }
}

/// What Alt+Shift+T does with a text: ask polish.py for `Send`'s target, or nothing — the text is in `Already`'s
/// language (a Settings target code) already.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Plan {
    Send(String),
    Already(String),
}

/// The text's language as far as the identifier can tell (its first 2000 characters).
pub fn language(text: &str) -> Reading {
    let s: String = text.chars().take(2000).collect();
    let Some(info) = whatlang::detect(&s) else { return Reading::default() };
    // every letter's script (whatlang's table): the languages the text may be in, and how mixed it is
    let mut scripts: Vec<(whatlang::Script, usize)> = vec![];
    let mut letters = 0usize;
    let mut buf = [0u8; 4];
    for c in s.chars().filter(|c| c.is_alphabetic()) {
        let Some(sc) = whatlang::detect_script(c.encode_utf8(&mut buf)) else { continue };
        letters += 1;
        match scripts.iter_mut().find(|(x, _)| *x == sc) {
            Some(e) => e.1 += 1,
            None => scripts.push((sc, 1)),
        }
    }
    let mut may: Vec<String> = vec![];
    for (sc, _) in &scripts {
        for l in sc.langs() {
            let f = family(code(l.code()));
            if !may.contains(&f) {
                may.push(f);
            }
        }
    }
    let other = scripts.iter().filter(|(x, _)| *x != whatlang::Script::Latin).map(|(_, n)| n).sum::<usize>();
    let mixed = info.script() == whatlang::Script::Latin && letters > 0 && other as f64 / letters as f64 >= MIXED;
    Reading { lang: (info.confidence() >= SURE && !mixed).then(|| code(info.lang().code()).to_string()), script: may }
}

/// ISO 639-3 (whatlang's codes) → the targets' codes; a language the list doesn't have keeps its own code.
fn code(iso3: &str) -> &str {
    match iso3 {
        "eng" => "en",
        "cmn" => "zh",
        "jpn" => "ja",
        "kor" => "ko",
        "fra" => "fr",
        "deu" => "de",
        "spa" => "es",
        "por" => "pt",
        "ita" => "it",
        "rus" => "ru",
        c => c,
    }
}

/// A language without its script: Simplified and Traditional Chinese are one ("zh-Hant", "zh-Hans", "zh" → "zh").
pub fn family(code: &str) -> String {
    let c = code.to_ascii_lowercase().replace('_', "-");
    let base = c.split('-').next().unwrap_or("");
    match base {
        "zh" | "cmn" | "yue" => "zh".to_string(),
        _ => base.to_string(),
    }
}

/// `setting`: Settings' target ("auto", "en", "zh-Hant" …); `r`: `language(text)`.
pub fn plan(setting: &str, r: &Reading, pair: &Pair) -> Plan {
    let is = |x: &str| r.lang.as_deref().is_some_and(|l| family(l) == family(x));
    if setting.is_empty() || setting == "auto" {
        if is(&pair.home) {
            return match &pair.other {
                Some(o) => Plan::Send(o.clone()),
                None => Plan::Already(pair.home.clone()),
            };
        }
        if r.surely_not(&pair.home) {
            return Plan::Send(pair.home.clone());
        }
        return Plan::Send(pair.request());
    }
    // Simplified into Traditional is still a translation
    if is(setting) && setting != "zh-Hant" {
        return Plan::Already(setting.to_string());
    }
    if r.surely_not(setting) || (is(setting) && setting == "zh-Hant") {
        return Plan::Send(setting.to_string());
    }
    Plan::Send(format!("{setting}|keep"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sure(lang: &str) -> Reading {
        Reading { lang: Some(lang.into()), script: vec![family(lang)] }
    }
    fn unsure(script: &[&str]) -> Reading {
        Reading { lang: None, script: script.iter().map(|s| s.to_string()).collect() }
    }

    fn langs(l: &[&str]) -> Vec<String> {
        l.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn auto_is_your_language_and_the_other_one() {
        // a Chinese system: 简体中文 ↔ English
        assert_eq!(Pair::of(None, &langs(&["zh-CN", "en-US"])), Pair::new("zh", Some("en")));
        // a Japanese user: 日本語 ↔ English
        assert_eq!(Pair::of(None, &langs(&["ja-JP"])), Pair::new("ja", Some("en")));
        // Blurt's own language picked: it comes first
        assert_eq!(Pair::of(Some("zh-Hans"), &langs(&["ja-JP", "en-US"])), Pair::new("zh", Some("en")));
        assert_eq!(Pair::of(Some("en"), &langs(&["ja-JP"])), Pair::new("en", Some("ja")));
        // English, then another language of the list: English ↔ it
        assert_eq!(Pair::of(None, &langs(&["en-US", "de-DE"])), Pair::new("en", Some("de")));
        // English only: no pair (Auto brings other languages into English)
        assert_eq!(Pair::of(None, &langs(&["en-GB"])), Pair::new("en", None));
        // languages the list doesn't have are passed over; none at all: English
        assert_eq!(Pair::of(None, &langs(&["th-TH", "C", "fr_FR.UTF-8"])), Pair::new("fr", Some("en")));
        assert_eq!(Pair::of(None, &[]), Pair::new("en", None));
        assert_eq!(Pair::of(None, &langs(&["zh-Hant-TW"])), Pair::new("zh-Hant", Some("en")));
        assert_eq!(Pair::of(None, &langs(&["zh-HK"])).home, "zh-Hant");
        assert_eq!(Pair::new("ja", Some("en")).request(), "auto:ja|en");
    }

    #[test]
    fn a_japanese_users_auto() {
        let ja = Pair::of(None, &langs(&["ja-JP"]));
        assert_eq!(plan("auto", &language("저장 버튼이 작동하지 않습니다."), &ja), Plan::Send("ja".into()));
        assert_eq!(plan("auto", &language("今日はいい天気ですね。散歩に行きましょう。"), &ja), Plan::Send("en".into()));
        assert_eq!(plan("auto", &language("The export to CSV fails when the file name has spaces."), &ja), Plan::Send("ja".into()));
        assert_eq!(plan("auto", &language("我们明天开会之前请先看一下附件。"), &ja), Plan::Send("ja".into()));
    }

    #[test]
    fn an_english_only_users_auto() {
        let en = Pair::of(None, &langs(&["en-US"]));
        assert_eq!(plan("auto", &language("This page is not available right now."), &en), Plan::Already("en".into()));
        assert_eq!(plan("auto", &language("我们明天开会之前请先看一下附件。"), &en), Plan::Send("en".into()));
        assert_eq!(plan("auto", &language("Obrigado pela sua mensagem, respondo amanhã."), &en), Plan::Send("en".into()));
    }

    #[test]
    fn the_identifier_reads_whole_sentences() {
        let l = |s: &str| language(s).lang;
        assert_eq!(l("This page is not available right now.").as_deref(), Some("en"));
        assert_eq!(l("我们明天开会之前请先看一下附件。").as_deref(), Some("zh"));
        assert_eq!(l("今日はいい天気ですね。散歩に行きましょう。").as_deref(), Some("ja"));
        assert_eq!(l("Obrigado pela sua mensagem, respondo amanhã.").as_deref(), Some("pt"));
        // a short English line: not sure which Latin-script language — but surely not Chinese
        let r = language("Copy text from screen");
        assert_eq!(r.lang, None);
        assert!(r.surely_not("zh") && !r.surely_not("en"));
    }

    #[test]
    fn auto_chinese_and_english_each_way_other_languages_into_yours() {
        let zh = Pair::new("zh", Some("en"));
        assert_eq!(plan("auto", &sure("en"), &zh), Plan::Send("zh".into()));
        assert_eq!(plan("auto", &sure("zh"), &zh), Plan::Send("en".into()));
        assert_eq!(plan("auto", &sure("zh-Hant"), &zh), Plan::Send("en".into()));
        assert_eq!(plan("auto", &sure("ja"), &zh), Plan::Send("zh".into()));
        // not in the list: still yours
        assert_eq!(plan("auto", &sure("tha"), &zh), Plan::Send("zh".into()));
        // which Latin-script language isn't known, but it isn't Chinese
        assert_eq!(plan("auto", &unsure(&["en", "fr", "de"]), &zh), Plan::Send("zh".into()));
        // not sure at all: the model decides
        assert_eq!(plan("auto", &unsure(&[]), &zh), Plan::Send("auto:zh|en".into()));
        assert_eq!(plan("auto", &unsure(&["zh"]), &zh), Plan::Send("auto:zh|en".into()));
    }

    #[test]
    fn auto_without_a_pair_keeps_your_own_language() {
        let en = Pair::new("en", None);
        assert_eq!(plan("auto", &sure("en"), &en), Plan::Already("en".into()));
        assert_eq!(plan("auto", &sure("de"), &en), Plan::Send("en".into()));
        assert_eq!(plan("auto", &unsure(&["en", "de"]), &en), Plan::Send("en|keep".into()));
        assert_eq!(en.request(), "en|keep");
    }

    #[test]
    fn a_fixed_language_is_always_that_language() {
        let zh = Pair::new("zh", Some("en"));
        assert_eq!(plan("ja", &sure("en"), &zh), Plan::Send("ja".into()));
        assert_eq!(plan("ja", &sure("ja"), &zh), Plan::Already("ja".into()));
        assert_eq!(plan("ja", &unsure(&[]), &zh), Plan::Send("ja|keep".into()));
        assert_eq!(plan("ja", &unsure(&["en", "fr"]), &zh), Plan::Send("ja".into()));
        // English read unsurely: it might be French, so French keeps a French text
        assert_eq!(plan("fr", &unsure(&["en", "fr"]), &zh), Plan::Send("fr|keep".into()));
        assert_eq!(plan("zh", &sure("zh"), &zh), Plan::Already("zh".into()));
        // Simplified into Traditional is still a translation
        assert_eq!(plan("zh-Hant", &sure("zh"), &zh), Plan::Send("zh-Hant".into()));
    }

    #[test]
    fn the_founders_case_english_under_auto_becomes_chinese() {
        // 2026-11-16: Auto (简体中文 ↔ English), an English paragraph framed → it came back in English
        for text in ["The export to CSV fails when the file name has spaces. Please check it before the release.",
                     "Your password must contain at least eight characters.", "Add to cart"] {
            assert_eq!(plan("auto", &language(text), &Pair::new("zh", Some("en"))), Plan::Send("zh".into()), "{text}");
        }
        assert_eq!(plan("auto", &language("登录页面周五之前要上线，记得把按钮颜色改深一点。"), &Pair::new("zh", Some("en"))), Plan::Send("en".into()));
        assert_eq!(plan("auto", &language("OK 保存按钮"), &Pair::new("zh", Some("en"))), Plan::Send("en".into()));
    }

    #[test]
    fn chinese_with_english_names_is_left_to_the_model() {
        // more Latin letters than Han characters: whatlang reads the Latin part; the model decides, as before
        for text in ["用 Claude Code 跑一下测试，然后提交 PR。", "修复 iOS 上 Safari 的 WebSocket 断连问题", "The 保存 button is broken"] {
            assert_eq!(plan("auto", &language(text), &Pair::new("zh", Some("en"))), Plan::Send("auto:zh|en".into()), "{text}");
        }
        // Japanese is kana and kanji: one language, read whole
        assert_eq!(language("今日はいい天気ですね。散歩に行きましょう。").lang.as_deref(), Some("ja"));
    }
}
