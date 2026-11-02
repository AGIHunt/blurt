//! Learning from the user's own fixes (docs/design/dictation.md §Learning from corrections; the Mac's DictationWatch
//! and BlurtCore `DictationLearn.EditWatch` / `locate`): after a take is typed, the field is read every 1.5 s for a
//! minute (UI Automation, Windows: engine.rs), only a few dozen characters on either side of the typed text held to
//! find it again; when the watch ends — its minute, the focus or the text moved away, the next take — what was typed
//! and what the field says there now go to `dictation_vocab.py learn --suggest`, which finds the recognition fixes
//! (the same rules the Mac's DictationLearn has) and keeps them as words. Once, at the end: a pause in the middle of
//! an edit is never the user's final word. Nothing of the document is kept. Pure: tests below.

/// characters held on each side of the typed text to find it again
pub const ANCHOR: usize = 40;
/// how long and how often the field is watched
pub const SECONDS: f64 = 60.0;
pub const EVERY: f64 = 1.5;

/// The typed text and the field's latest state of it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditWatch {
    pub typed: String,
    latest: String,
}

impl EditWatch {
    pub fn new(typed: &str) -> Self {
        EditWatch { typed: typed.to_string(), latest: typed.to_string() }
    }
    /// A tick saw the typed text's span as `now`.
    pub fn saw(&mut self, now: &str) {
        self.latest = now.to_string();
    }
    /// The watch ends: (typed, edited), or None when nothing changed.
    pub fn end(&self) -> Option<(String, String)> {
        (self.latest != self.typed && !self.latest.is_empty()).then(|| (self.typed.clone(), self.latest.clone()))
    }
}

fn u16s(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

fn find(hay: &[u16], needle: &[u16], from: usize) -> Option<usize> {
    if needle.is_empty() {
        return Some(from.min(hay.len()));
    }
    (from..=hay.len().saturating_sub(needle.len())).find(|&i| hay[i..].starts_with(needle))
}

/// Where the typed text sits in the field when it is first watched: at the cursor (`location`, UTF-16), else the
/// nearest place from 200 before it. → (prefix, suffix, near) to find it again, or None.
pub fn anchors(text: &str, inserted: &str, location: usize) -> Option<(String, String, usize)> {
    let t = u16s(text);
    let ins = u16s(inserted);
    if ins.is_empty() {
        return None;
    }
    let at = if location + ins.len() <= t.len() && t[location..location + ins.len()] == ins[..] {
        location
    } else {
        find(&t, &ins, location.saturating_sub(200))?
    };
    let p0 = at.saturating_sub(ANCHOR);
    let end = at + ins.len();
    let s1 = (end + ANCHOR).min(t.len());
    Some((String::from_utf16_lossy(&t[p0..at]), String::from_utf16_lossy(&t[end..s1]), at))
}

/// The text between `prefix` and `suffix` in `text`, taking the `prefix` that ends nearest `near` (UTF-16). None: they
/// aren't there any more (the user moved on, or rewrote around it), or what is between is longer than `max_len`.
pub fn locate(text: &str, prefix: &str, suffix: &str, near: usize, max_len: usize) -> Option<String> {
    let t = u16s(text);
    let p = u16s(prefix);
    let s = u16s(suffix);
    let mut starts = vec![];
    if p.is_empty() {
        starts.push(0);
    } else {
        let mut from = 0;
        while let Some(i) = find(&t, &p, from) {
            starts.push(i + p.len());
            from = i + 1;
            if from >= t.len() {
                break;
            }
        }
    }
    let start = *starts.iter().min_by_key(|&&x| (x as i64 - near as i64).abs())?;
    let end = if s.is_empty() { t.len() } else { find(&t, &s, start)? };
    if end < start || end - start > max_len {
        return None;
    }
    Some(String::from_utf16_lossy(&t[start..end]))
}

/// Reformat-last (the Mac's DictationReformat.span): where the pasted text still is, untouched — `inserted` with the
/// same text before and after it as when it went in, the occurrence nearest `near` (UTF-16). → (start, length) in
/// UTF-16 units; None: the user edited it (or around it), or it is gone.
pub fn span(text: &str, inserted: &str, prefix: &str, suffix: &str, near: usize) -> Option<(usize, usize)> {
    let t = u16s(text);
    let p = u16s(prefix);
    let ins = u16s(inserted);
    let needle: Vec<u16> = p.iter().chain(&ins).chain(&u16s(suffix)).copied().collect();
    if ins.is_empty() || needle.len() > t.len() {
        return None;
    }
    let mut best: Option<usize> = None;
    let mut from = 0;
    while let Some(i) = find(&t, &needle, from) {
        let at = i + p.len();
        if best.is_none_or(|b| (at as i64 - near as i64).abs() < (b as i64 - near as i64).abs()) {
            best = Some(at);
        }
        from = i + 1;
        if from >= t.len() {
            break;
        }
    }
    best.map(|b| (b, ins.len()))
}

/// How long after the paste reformat-last may still replace the text in the field (later: the clipboard).
pub const REFORMAT_WINDOW: f64 = 300.0;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_watch_learns_once_at_its_end() {
        let mut w = EditWatch::new("用 Kuberneetes 部署");
        assert_eq!(w.end(), None);
        w.saw("用 Kuber 部署"); // mid-edit
        w.saw("用 K8s 部署");
        assert_eq!(w.end(), Some(("用 Kuberneetes 部署".to_string(), "用 K8s 部署".to_string())));
        w.saw("");
        assert_eq!(w.end(), None); // everything deleted: nothing to learn
    }

    #[test]
    fn the_typed_text_is_found_again() {
        let field = "Hello. 我们用德宝写的。 Bye";
        let ins = "我们用德宝写的。";
        let at = field.encode_utf16().position(|_| true).unwrap() + "Hello. ".encode_utf16().count();
        let (p, s, near) = anchors(field, ins, at).unwrap();
        assert_eq!((p.as_str(), s.as_str()), ("Hello. ", " Bye"));
        // the user fixed a word
        let now = "Hello. 我们用豆包写的。 Bye";
        assert_eq!(locate(now, &p, &s, near, 100).as_deref(), Some("我们用豆包写的。"));
        // text typed before it moves it along: still found
        let moved = "Oh. Hello. 我们用豆包写的。 Bye";
        assert_eq!(locate(moved, &p, &s, near, 100).as_deref(), Some("我们用豆包写的。"));
        // the suffix is gone: nothing
        assert_eq!(locate("Hello. 全改了", &p, &s, near, 100), None);
        // too long: a rewrite
        assert_eq!(locate(now, &p, &s, near, 3), None);
        // the cursor was off: found nearby
        assert!(anchors(field, ins, 0).is_some());
        assert!(anchors(field, "不在这里", 0).is_none());
    }

    #[test]
    fn the_nearest_prefix_wins() {
        let text = "a: x. a: y.";
        assert_eq!(locate(text, "a: ", ".", 9, 10).as_deref(), Some("y"));
        assert_eq!(locate(text, "a: ", ".", 0, 10).as_deref(), Some("x"));
        assert_eq!(locate("whole", "", "", 0, 10).as_deref(), Some("whole"));
    }

    /// DictationStyleRecordTests.testSpan
    #[test]
    fn the_pasted_text_is_found_untouched() {
        let text = "Hi. we ship friday. Bye";
        let (p, sfx) = ("Hi. ", ". Bye");
        assert_eq!(span(text, "we ship friday", p, sfx, 4), Some((4, 14)));
        // edited: gone
        assert_eq!(span("Hi. we ship Friday. Bye", "we ship friday", p, sfx, 4), None);
        // two occurrences: the nearest
        let two = "Hi. x. Bye Hi. x. Bye";
        assert_eq!(span(two, "x", "Hi. ", ". Bye", 15), Some((15, 1)));
        assert_eq!(span(two, "x", "Hi. ", ". Bye", 0), Some((4, 1)));
        assert_eq!(span("", "x", "", "", 0), None);
    }
}
