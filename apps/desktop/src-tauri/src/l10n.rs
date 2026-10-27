//! Localisation for what Rust shows itself — the tray and system notifications (contract K10). Catalogues are
//! `locales/{en,zh-Hans}.json`: flat keys, `{name}` placeholders, plurals as `key_one` / `key_other`. The pages
//! (main window, island) localise with their own catalogues; they get the language from `app_status`.
//!
//! Language: `$BLURT_LANG` (tests) → config `lang` (`auto` | `en` | `zh` | `zh-Hans`) → the system's preferred
//! language (`zh-*` → zh-Hans, anything else → en).

use std::collections::HashMap;
use std::sync::OnceLock;

use serde_json::Value;

use crate::settings;

const EN: &str = include_str!("../locales/en.json");
const ZH: &str = include_str!("../locales/zh-Hans.json");

fn catalog(lang: &str) -> &'static HashMap<String, String> {
    static EN_C: OnceLock<HashMap<String, String>> = OnceLock::new();
    static ZH_C: OnceLock<HashMap<String, String>> = OnceLock::new();
    let (cell, src) = if lang == "zh-Hans" { (&ZH_C, ZH) } else { (&EN_C, EN) };
    cell.get_or_init(|| serde_json::from_str(src).unwrap_or_default())
}

/// `"en"` or `"zh-Hans"`.
pub fn lang() -> &'static str {
    let pick = |s: &str| if s.to_lowercase().starts_with("zh") { "zh-Hans" } else { "en" };
    if let Ok(l) = std::env::var("BLURT_LANG") {
        if !l.is_empty() {
            return pick(&l);
        }
    }
    match settings::read_config().get("lang").and_then(Value::as_str) {
        Some(l) if !l.is_empty() && l != "auto" => pick(l),
        _ => pick(&sys_locale::get_locale().unwrap_or_default()),
    }
}

/// `en` | `zh` — the short form the Python CLIs take (`--lang`).
pub fn short_lang() -> &'static str {
    if lang() == "zh-Hans" {
        "zh"
    } else {
        "en"
    }
}

fn fill(s: &str, params: &[(&str, String)]) -> String {
    let mut out = s.to_string();
    for (k, v) in params {
        out = out.replace(&format!("{{{k}}}"), v);
    }
    out
}

/// The string for `key` in the UI language (falls back to English, then to the key itself).
pub fn t(key: &str) -> String {
    tf(key, &[])
}

pub fn tf(key: &str, params: &[(&str, String)]) -> String {
    let s = catalog(lang()).get(key).or_else(|| catalog("en").get(key)).map(String::as_str).unwrap_or(key);
    fill(s, params)
}

/// `key_one` / `key_other` by the language's plural rule (both languages here: one = exactly 1 in English, and
/// Chinese has no grammatical plural so `_other` and `_one` carry the same words); `{n}` is filled in.
pub fn plural(key: &str, n: i64, params: &[(&str, String)]) -> String {
    let form = if n == 1 && lang() == "en" { "one" } else { "other" };
    let mut p: Vec<(&str, String)> = params.to_vec();
    p.push(("n", n.to_string()));
    tf(&format!("{key}_{form}"), &p)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    fn placeholders(s: &str) -> BTreeSet<String> {
        let mut out = BTreeSet::new();
        let mut rest = s;
        while let Some(i) = rest.find('{') {
            let Some(j) = rest[i..].find('}') else { break };
            out.insert(rest[i + 1..i + j].to_string());
            rest = &rest[i + j + 1..];
        }
        out
    }

    /// K10: en and zh-Hans have exactly the same keys and the same placeholders.
    #[test]
    fn catalogues_match() {
        let en: HashMap<String, String> = serde_json::from_str(EN).unwrap();
        let zh: HashMap<String, String> = serde_json::from_str(ZH).unwrap();
        let ke: BTreeSet<_> = en.keys().collect();
        let kz: BTreeSet<_> = zh.keys().collect();
        assert_eq!(ke, kz, "en and zh-Hans keys differ");
        for (k, v) in &en {
            assert_eq!(placeholders(v), placeholders(&zh[k]), "placeholders differ for {k}");
            assert!(!v.trim().is_empty() && !zh[k].trim().is_empty(), "{k} is empty");
        }
        // K4: every job type and step has a name
        for t in ["record", "snap", "voice", "process", "route", "agent"] {
            assert!(en.contains_key(&format!("job.type.{t}")), "job.type.{t}");
        }
        for s in ["capture", "finalize", "listen", "transcribe", "file", "prepare", "write", "frames", "route", "launch", "work", "finish"] {
            assert!(en.contains_key(&format!("job.step.{s}")), "job.step.{s}");
        }
    }

    #[test]
    fn fills_and_plurals() {
        assert_eq!(fill("{agent} needs {n}", &[("agent", "Codex".into()), ("n", "2".into())]), "Codex needs 2");
        std::env::set_var("BLURT_LANG", "en");
        assert_eq!(plural("notify.sorted.body", 1, &[]), "1 item to review");
        assert_eq!(plural("notify.sorted.body", 3, &[]), "3 items to review");
        assert_eq!(t("no.such.key"), "no.such.key");
    }
}
