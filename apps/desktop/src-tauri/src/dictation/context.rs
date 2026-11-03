//! What dictation reads from the text field it types into (docs/design/dictation.md §Context, §Field context; the Mac's
//! DictationContext), read-only and never from a password field: at the take's start, ≈ 500 characters before and after
//! the cursor, the selection and the window's title. They go to polish as context (spelling hints, the sentence the
//! dictation continues) and the text before the cursor to the speech model (`before`, its last 300 characters — a model
//! whose catalogue entry has `field_context_chars` hears it). The history keeps none of it. The UI Automation reads are
//! insert_win.rs (Windows); this is the pure cut, in UTF-16 units as UI Automation counts. Tests below.

use serde_json::{json, Value};

/// characters on either side of the cursor that polish gets
pub const AROUND: usize = 500;
/// characters before the cursor that the speech model gets
pub const ASR_BEFORE: usize = 300;

/// The field's text around the cursor.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Context {
    pub before: String,
    pub after: String,
    pub selection: String,
    pub title: String,
    /// the app's executable, without ".exe"
    pub app: Option<String>,
}

impl Context {
    /// `text` the field's text, `sel_start` / `sel_len` the selection in UTF-16 units (clamped to the text).
    pub fn around(text: &str, sel_start: usize, sel_len: usize) -> Context {
        let u: Vec<u16> = text.encode_utf16().collect();
        let start = sel_start.min(u.len());
        let len = sel_len.min(u.len() - start);
        let s = |a: usize, b: usize| String::from_utf16_lossy(&u[a..b]);
        let before = s(0, start);
        let selection = s(start, start + len);
        let after = s(start + len, u.len());
        Context {
            before: tail(&before, AROUND),
            after: head(&after, AROUND),
            selection: head(&selection, AROUND),
            ..Context::default()
        }
    }

    /// The text before the cursor the speech model hears (`before` in a transcribe request).
    pub fn asr_before(&self) -> String {
        tail(&self.before, ASR_BEFORE)
    }

    /// For the speech model's request (the Mac's DictationContext.hint): the window's title and 300 characters on either
    /// side of the cursor. Only which of the user's words appear in it is used (their order in the model's word list);
    /// none of it goes to the model.
    pub fn hint(&self) -> String {
        [self.title.clone(), tail(&self.before, ASR_BEFORE), self.selection.clone(), head(&self.after, ASR_BEFORE)]
            .into_iter()
            .filter(|x| !x.is_empty())
            .collect::<Vec<_>>()
            .join("\n")
    }

    pub fn is_empty(&self) -> bool {
        self.before.is_empty() && self.after.is_empty() && self.selection.is_empty() && self.title.is_empty()
    }

    /// polish.py's `context` (`{"before","after","selection","title","app"}`): only what is there.
    pub fn polish_json(&self) -> Value {
        let mut o = json!({ "app": self.app });
        for (k, v) in [("before", &self.before), ("after", &self.after), ("selection", &self.selection), ("title", &self.title)] {
            if !v.is_empty() {
                o[k] = json!(v);
            }
        }
        o
    }
}

/// The last `n` characters (never splitting a character).
pub fn tail(s: &str, n: usize) -> String {
    let c = s.chars().count();
    s.chars().skip(c.saturating_sub(n)).collect()
}

/// The first `n` characters.
pub fn head(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_text_around_the_cursor() {
        let c = Context::around("Hello world", 6, 0);
        assert_eq!((c.before.as_str(), c.after.as_str(), c.selection.as_str()), ("Hello ", "world", ""));
        let c = Context::around("send the old text", 9, 3);
        assert_eq!((c.before.as_str(), c.selection.as_str(), c.after.as_str()), ("send the ", "old", " text"));
        // UTF-16 units: an emoji is two
        let c = Context::around("😀 hi", 3, 0); // glyph-ok: text data (an emoji in a field), not an icon
        assert_eq!(c.after, "hi");
        // past the end: clamped
        let c = Context::around("ab", 99, 99);
        assert_eq!((c.before.as_str(), c.after.as_str()), ("ab", ""));
    }

    #[test]
    fn at_most_five_hundred_characters_each_side() {
        let long = "字".repeat(800);
        let text = format!("{long}{long}");
        let c = Context::around(&text, 800, 0);
        assert_eq!(c.before.chars().count(), AROUND);
        assert_eq!(c.after.chars().count(), AROUND);
        assert_eq!(c.asr_before().chars().count(), ASR_BEFORE);
    }

    #[test]
    fn the_speech_models_hint() {
        let mut c = Context::around("git log\n$ ", 10, 0);
        c.title = "Windows PowerShell".into();
        assert_eq!(c.hint(), "Windows PowerShell\ngit log\n$ ");
        assert_eq!(Context::default().hint(), "");
    }

    #[test]
    fn polish_gets_only_what_is_there() {
        let mut c = Context::around("我刚截了", 4, 0);
        c.app = Some("WeChat".into());
        let j = c.polish_json();
        assert_eq!(j["before"], "我刚截了");
        assert_eq!(j["app"], "WeChat");
        assert!(j.get("after").is_none());
        assert!(Context::default().is_empty());
    }
}
