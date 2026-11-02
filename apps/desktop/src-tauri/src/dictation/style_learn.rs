//! Learning the user's style preference from what they do (docs/design/dictation-styles.md §3.5; the Mac's BlurtCore
//! `DictationStyleLearn` and `DictationReformat.reverted`): suggest, never switch silently. Each take can leave one
//! signal for its app — Shift / the island made it Structured (or back), a reformat kept (its style) or undone (the
//! style it had), a list the user took apart in the field (Light), a take that sounded like a list left as prose (the
//! "Sounds like a list" chip ignored: Light). ≥ 3 signals, ≥ 70 % one way, among the app's last 10 → the island asks once
//! ("Format spoken lists in WeChat from now on?"); the answer is remembered either way (`style_asked`).
//! The Mac reads the signals from its history entries' style records; Windows keeps them apart, in
//! `$BLURT_HOME/dictation/style_signals.json` ({app: [{"id", "style"}]}, the newest last). Pure: tests below.

use serde_json::{json, Value};

use super::prefs::Style;
use super::stitch;

pub const MIN_SIGNALS: usize = 3;
pub const SHARE: f64 = 0.7;
/// the last this-many signals of an app count
pub const WINDOW: usize = 10;

/// Lists (structured / auto) count as one wish.
fn norm(s: Style) -> Style {
    if s == Style::Auto {
        Style::Structured
    } else {
        s
    }
}

/// Take `id` in `app` says `style`: its signal (a later one for the same take — an Undo, a second reformat —
/// replaces it), the app's last `WINDOW` kept.
pub fn record(store: &mut Value, app: &str, id: &str, style: Style) {
    if !store.is_object() {
        *store = json!({});
    }
    if !store[app].is_array() {
        store[app] = json!([]);
    }
    let list = store[app].as_array_mut().unwrap();
    list.retain(|x| x["id"] != id);
    list.push(json!({"id": id, "style": norm(style).as_str()}));
    let over = list.len().saturating_sub(WINDOW);
    list.drain(..over);
}

/// The app's signals, newest first.
pub fn signals(store: &Value, app: &str) -> Vec<Style> {
    store[app]
        .as_array()
        .map(|a| a.iter().rev().filter_map(|x| x["style"].as_str().and_then(Style::from_config)).collect())
        .unwrap_or_default()
}

/// What to suggest for `app` now (the app's style becomes it), if its signals agree and it wasn't asked: auto for
/// lists (lists when confident), light or verbatim. `current`: the app's style today.
pub fn suggest(signals: &[Style], current: Style, asked: &[String], app: &str) -> Option<Style> {
    let s: Vec<Style> = signals.iter().take(WINDOW).map(|&x| norm(x)).collect();
    if s.len() < MIN_SIGNALS {
        return None;
    }
    let mut best: Option<(Style, usize)> = None;
    for c in [Style::Verbatim, Style::Light, Style::Structured] {
        let n = s.iter().filter(|&&x| x == c).count();
        if best.is_none_or(|(_, m)| n > m) {
            best = Some((c, n));
        }
    }
    let (top, n) = best?;
    if n < MIN_SIGNALS || (n as f64) / (s.len() as f64) < SHARE || top == norm(current) {
        return None;
    }
    let target = if top == Style::Structured { Style::Auto } else { top };
    (!asked.iter().any(|k| *k == ask_key(app, target))).then_some(target)
}

/// "app|style": asked once, whatever the answer.
pub fn ask_key(app: &str, style: Style) -> String {
    format!("{app}|{}", style.as_str())
}

/// The numbered lines of a rendered list ("1. …" at a line start).
fn numbered_lines(s: &str) -> usize {
    s.split('\n')
        .filter(|l| {
            let t = l.trim_start();
            let digits = t.chars().take_while(char::is_ascii_digit).count();
            (1..=2).contains(&digits) && t[digits..].starts_with(". ") && t[digits + 2..].chars().next().is_some_and(|c| !c.is_whitespace())
        })
        .count()
}

/// The user took the list apart in the field (the watch saw it): the typed text had ≥ 2 numbered lines, the edited
/// one has fewer, and most of the words are still there (a deleted paragraph is not a revert).
pub fn reverted(typed: &str, edited: &str) -> bool {
    if numbered_lines(typed) < 2 || numbered_lines(edited) >= 2 {
        return false;
    }
    let a: Vec<String> = stitch::units(typed).into_iter().map(|u| u.value).filter(|v| !v.chars().all(|c| c.is_numeric())).collect();
    let mut b: Vec<String> = stitch::units(edited).into_iter().map(|u| u.value).collect();
    let mut kept = 0;
    for u in &a {
        if let Some(i) = b.iter().position(|x| x == u) {
            b.remove(i);
            kept += 1;
        }
    }
    !a.is_empty() && kept as f64 / a.len() as f64 >= 0.7
}

#[cfg(test)]
mod tests {
    //! DictationStyleLearnTests
    use super::*;

    #[test]
    fn three_agreeing_signals_ask_once() {
        let mut st = json!({});
        for (i, s) in [Style::Structured, Style::Auto, Style::Structured].iter().enumerate() {
            record(&mut st, "notes", &format!("d{i}"), *s);
        }
        let sig = signals(&st, "notes");
        assert_eq!(sig.len(), 3);
        assert_eq!(suggest(&sig, Style::Light, &[], "notes"), Some(Style::Auto));
        // asked already
        assert_eq!(suggest(&sig, Style::Light, &[ask_key("notes", Style::Auto)], "notes"), None);
        // already the app's style
        assert_eq!(suggest(&sig, Style::Auto, &[], "notes"), None);
        // two are not enough
        assert_eq!(suggest(&sig[..2], Style::Light, &[], "notes"), None);
    }

    #[test]
    fn a_split_vote_asks_nothing() {
        let sig = [Style::Structured, Style::Light, Style::Structured, Style::Light, Style::Structured];
        assert_eq!(suggest(&sig, Style::Light, &[], "x"), None); // 60 %
        let sig = [Style::Verbatim, Style::Verbatim, Style::Verbatim, Style::Light];
        assert_eq!(suggest(&sig, Style::Light, &[], "x"), Some(Style::Verbatim));
    }

    #[test]
    fn a_later_signal_for_the_same_take_replaces_it_and_only_ten_count() {
        let mut st = json!({});
        record(&mut st, "a", "d1", Style::Structured);
        record(&mut st, "a", "d1", Style::Light); // undone
        assert_eq!(signals(&st, "a"), vec![Style::Light]);
        for i in 0..15 {
            record(&mut st, "a", &format!("e{i}"), Style::Verbatim);
        }
        assert_eq!(signals(&st, "a").len(), WINDOW);
    }

    #[test]
    fn a_list_taken_apart() {
        let typed = "1. 修好登录页面\n2. 改价格页的文案\n3. 更新文档";
        assert!(reverted(typed, "修好登录页面，改价格页的文案，更新文档"));
        assert!(!reverted(typed, typed));
        assert!(!reverted(typed, "修好")); // deleted, not reverted
        assert!(!reverted("修好登录页面", "修好登录"));
    }
}
