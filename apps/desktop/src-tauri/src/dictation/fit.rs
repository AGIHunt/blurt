//! Fitting a dictation into the text around the cursor (docs/design/dictation.md §Insert: fitting at the cursor),
//! ported from the Mac's BlurtCore `DictationFit.swift` (tests: `DictationFitTests`, below), like Typeless. The field
//! holds 「我知道你就是▮的。」 and the user says 「就是从老家回来的。」: pasted as it is, that gives
//! 「我知道你就是就是从老家回来的。。」; fitted, only 「从老家回来」 goes in → 「我知道你就是从老家回来的。」.
//!
//!  • overlap before: the dictation's start repeats the end of the text before the cursor → that start goes. At least
//!    2 CJK characters (or 2 digits), or 1 Latin word, so a coincidental single character isn't eaten.
//!  • overlap after: the dictation's end repeats the start of the text after the cursor → that end goes, with its
//!    punctuation. At least 2 units, or 1 when both end the same way (「的。」 before 「的。」).
//!  • punctuation: the text after the cursor starts with punctuation → the insertion ends without any; it continues the
//!    sentence (a CJK character, a lower-case word, a digit) while the text before ends mid-sentence → no closing
//!    。.!?！？. The text before ends mid-sentence → no leading 「，」.
//!  • spacing: a space between two Latin words at either seam; between CJK and Latin the way the field already does it
//!    (else the way the dictation does, else spaced, as polish writes).
//! Only the inserted text is trimmed — nothing in the field is touched — and a fit that would leave nothing isn't made.
//! The engine calls it right before the paste, only when UI Automation could read the field.

use super::stitch::{self, is_cjk, is_word_char, Unit};

const TERMINATORS: &[char] = &['。', '.', '!', '?', '！', '？'];
const PUNCT: &str = "。.!?！？，,、；;：:…）)」』”’\"'";
const LEADING_COMMAS: &[char] = &['，', ',', '、', '；', ';'];
const CLOSERS: &str = "）)」』”\"";

fn punct(c: char) -> bool {
    PUNCT.contains(c)
}
fn term(c: char) -> bool {
    TERMINATORS.contains(&c)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Fit {
    pub text: String,
    /// what changed: "head" (overlap before), "tail" (overlap after), "punct", "space"
    pub changes: Vec<&'static str>,
}

impl Fit {
    pub fn trimmed(&self) -> bool {
        !self.changes.is_empty()
    }
}

/// The cursor is at the end of a list item ("3. 更新文档▮", nothing after it on the line): what comes next is a new
/// paragraph, not more of that item.
pub fn ends_in_list_item(before: &str, after: &str) -> bool {
    let rest: String = after.chars().take_while(|&c| c != '\n').collect();
    let last = before.split('\n').next_back().unwrap_or("");
    rest.chars().all(char::is_whitespace) && !last.trim().is_empty() && stitch::list_lines(last) == 1
}

/// The engine's call (the Mac's `Dictation.fit`): a structured list starts on its own line; right after a list item a
/// take starts its own paragraph; else `fit`. → (text, changes).
pub fn fit_at_cursor(text: &str, before: &str, after: &str, list: bool) -> (String, Vec<&'static str>) {
    if list {
        let b = before.trim_matches([' ', '\t']);
        return if !b.is_empty() && !b.ends_with('\n') { (format!("\n{text}"), vec!["list_line"]) } else { (text.to_string(), vec![]) };
    }
    if ends_in_list_item(before, after) {
        return (format!("\n\n{text}"), vec!["after_list"]);
    }
    let f = fit(text, before, after);
    if f.trimmed() {
        (f.text, f.changes)
    } else {
        (text.to_string(), vec![])
    }
}

/// `text` fitted between `before` and `after` (the field's text on each side of the cursor or selection).
pub fn fit(text: &str, before: &str, after: &str) -> Fit {
    let mut t = text.trim().to_string();
    let mut changes: Vec<&'static str> = vec![];
    if t.is_empty() {
        return Fit { text: text.to_string(), changes };
    }
    // 1. overlap with the text before the cursor
    if let Some(cut) = head_overlap(&t, before) {
        let rest = t[cut..].trim_start_matches(|c: char| c.is_whitespace() || punct(c)).to_string();
        if !stitch::units(&rest).is_empty() {
            t = rest;
            changes.push("head");
        }
    }
    // 2. overlap with the text after the cursor
    if let Some(cut) = tail_overlap(&t, after) {
        let rest = t[..cut].trim_matches(|c: char| c == ' ' || c == '\t').to_string();
        if !stitch::units(&rest).is_empty() {
            t = rest;
            changes.push("tail");
        }
    }
    let b = before.chars().rev().find(|c| !c.is_whitespace() || *c == '\n');
    let a = after.chars().find(|c| !c.is_whitespace() || *c == '\n');
    let before_ends = match b {
        None => true,
        Some(c) => c == '\n' || term(c) || (CLOSERS.contains(c) && ends_with_terminator(before)),
    };
    let mid = !before_ends;
    // 3. punctuation at the end: what follows the cursor decides
    if let Some(a) = a.filter(|&c| c != '\n') {
        if punct(a) {
            let s = strip_trailing_punct(&t);
            if s != t && !s.is_empty() {
                t = s;
                changes.push("punct");
            }
        } else if (is_cjk(a) || a.is_numeric() || (a.is_alphabetic() && a.is_lowercase())) && mid {
            let s = t.trim_end_matches(term).to_string();
            if s != t && !s.is_empty() {
                t = s;
                changes.push("punct");
            }
        }
    }
    // …and at the start: the text before already ends in punctuation (「安排：▮」): no second mark (「：下午…」)
    if let (Some(b), Some(f)) = (b, t.chars().next()) {
        if punct(b) && punct(f) && !"）)」』”’\"'".contains(f) {
            let s = t.trim_start_matches(|c: char| punct(c) || c.is_whitespace()).to_string();
            if !s.is_empty() {
                t = s;
                changes.push("punct");
            }
        }
    }
    if mid {
        let s = t.trim_start_matches(|c: char| LEADING_COMMAS.contains(&c) || c.is_whitespace()).to_string();
        if s.chars().count() != t.chars().count() && !s.is_empty() {
            t = s;
            if !changes.contains(&"punct") {
                changes.push("punct");
            }
        }
    }
    // 4. spacing at the seams
    let mut lead = "";
    let mut trail = "";
    if let (Some(bc), Some(tc)) = (before.chars().next_back(), t.chars().next()) {
        if !bc.is_whitespace() && needs_space(bc, tc, cjk_latin_spaced(before, &t)) {
            lead = " ";
        }
    }
    if let (Some(ac), Some(tc)) = (after.chars().next(), t.chars().next_back()) {
        if !ac.is_whitespace() && needs_space(tc, ac, cjk_latin_spaced(&format!("{before}{after}"), &t)) {
            trail = " ";
        }
    }
    if !lead.is_empty() || !trail.is_empty() {
        changes.push("space");
    }
    let out = format!("{lead}{t}{trail}");
    if changes.is_empty() && out == text {
        return Fit { text: text.to_string(), changes };
    }
    Fit { text: out, changes }
}

fn ends_with_terminator(s: &str) -> bool {
    let t = s.trim_matches([' ', '\t']).trim_end_matches(|c: char| "）)」』”\"’'".contains(c));
    t.chars().next_back().is_none_or(term)
}

fn strip_trailing_punct(s: &str) -> String {
    let mut t: Vec<char> = s.chars().collect();
    while let Some(&c) = t.last() {
        if (punct(c) || c.is_whitespace()) && !"）)」』”".contains(c) {
            t.pop();
        } else {
            break;
        }
    }
    t.into_iter().collect()
}

/// The last `n` characters of `s`.
fn suffix(s: &str, n: usize) -> &str {
    let k = s.chars().count();
    match s.char_indices().nth(k.saturating_sub(n)) {
        Some((i, _)) if k > n => &s[i..],
        _ => s,
    }
}

fn prefix(s: &str, n: usize) -> &str {
    match s.char_indices().nth(n) {
        Some((i, _)) => &s[..i],
        None => s,
    }
}

/// Where the dictation continues after the words that repeat the end of `before` (byte index into `t`).
fn head_overlap(t: &str, before: &str) -> Option<usize> {
    let tu = stitch::units(t);
    let bs = suffix(before, 200);
    let bu = stitch::units(bs);
    if tu.is_empty() || bu.is_empty() {
        return None;
    }
    // only directly at the end of the text before: no sentence end between its last unit and the cursor
    if bs[bu.last().unwrap().range.end..].chars().any(term) {
        return None;
    }
    let max = 12.min(tu.len() - 1).min(bu.len());
    for k in (1..=max).rev() {
        let bv: Vec<&str> = bu[bu.len() - k..].iter().map(|u| u.value.as_str()).collect();
        let tv: Vec<&str> = tu[..k].iter().map(|u| u.value.as_str()).collect();
        if bv == tv && enough(&tu[..k]) {
            return Some(tu[k - 1].range.end);
        }
    }
    None
}

/// Where the dictation's own end starts if it repeats the start of `after` (byte index into `t`).
fn tail_overlap(t: &str, after: &str) -> Option<usize> {
    let tu = stitch::units(t);
    let a = prefix(after, 200);
    let au = stitch::units(a);
    if tu.len() < 2 || au.is_empty() {
        return None;
    }
    // only directly at the start of the text after
    let gap = &a[..au[0].range.start];
    if gap.chars().any(|c| !c.is_whitespace() && !punct(c)) || gap.chars().any(punct) {
        return None;
    }
    let max = 12.min(tu.len() - 1).min(au.len());
    for k in (1..=max).rev() {
        let tail = &tu[tu.len() - k..];
        let head = &au[..k];
        if tail.iter().map(|u| &u.value).ne(head.iter().map(|u| &u.value)) {
            continue;
        }
        if enough(tail) {
            return Some(tail[0].range.start);
        }
        // one unit: only when both end the same way right after it (「的。」 before 「的。」)
        let t_end = t[tail[k - 1].range.end..].trim_matches([' ', '\t']);
        let a_end = a[head[k - 1].range.end..].chars().find(|c| !c.is_whitespace());
        if t_end.chars().next().is_some_and(term) && a_end.is_some_and(term) {
            return Some(tail[0].range.start);
        }
    }
    None
}

/// An overlap long enough to be more than a coincidence: a Latin word, or two CJK characters / digits.
fn enough(u: &[Unit]) -> bool {
    u.iter().any(|x| x.value.chars().count() > 1 || x.value.chars().next().is_some_and(|c| c.is_alphabetic() && !is_cjk(c)))
        || u.len() >= 2
}

fn needs_space(l: char, r: char, spaced: bool) -> bool {
    let (lw, rw) = (is_word_char(l), is_word_char(r));
    if lw && rw {
        return true;
    }
    if (is_cjk(l) && rw) || (lw && is_cjk(r)) {
        return spaced;
    }
    ".,;:!?".contains(l) && rw
}

/// Does the field (else the dictation) put a space between CJK and Latin? Default: yes, as polish writes.
fn cjk_latin_spaced(field: &str, text: &str) -> bool {
    fn count(s: &str) -> (usize, usize) {
        let cs: Vec<char> = s.chars().collect();
        let (mut sp, mut ti) = (0, 0);
        let mixed = |x: char, y: char| (is_cjk(x) && is_word_char(y)) || (is_word_char(x) && is_cjk(y));
        for i in 0..cs.len().saturating_sub(1) {
            let (x, y) = (cs[i], cs[i + 1]);
            if mixed(x, y) {
                ti += 1;
            }
            if i + 2 < cs.len() && y == ' ' && mixed(x, cs[i + 2]) {
                sp += 1;
            }
        }
        (sp, ti)
    }
    let (fs, ft) = count(field);
    if fs + ft > 0 {
        return fs >= ft;
    }
    let (ts, tt) = count(text);
    if ts + tt > 0 {
        return ts >= tt;
    }
    true
}

#[cfg(test)]
mod tests {
    //! DictationFitTests
    use super::*;

    fn f(text: &str, before: &str, after: &str) -> String {
        fit(text, before, after).text
    }

    #[test]
    fn the_typeless_example() {
        let r = fit("就是从老家回来的。", "我知道你就是", "的。");
        assert_eq!(r.text, "从老家回来");
        assert_eq!(r.changes, vec!["head", "tail"]);
    }

    #[test]
    fn no_overlap_leaves_the_text_alone() {
        let r = fit("下午三点开会。", "今天的安排：", "");
        assert_eq!(r.text, "下午三点开会。");
        assert!(!r.trimmed());
        assert_eq!(f("Let's ship it today.", "", ""), "Let's ship it today.");
        assert_eq!(f("我们明天再看。", "上一段。\n", ""), "我们明天再看。");
    }

    #[test]
    fn one_character_is_not_an_overlap() {
        assert_eq!(f("去公园散步。", "我们明天", ""), "去公园散步。");
        assert_eq!(f("去公园散步。", "我们明天去", ""), "去公园散步。");
        assert_eq!(f("明天去公园散步。", "我们明天", ""), "去公园散步。");
        assert_eq!(f("这是我的", "", "朋友"), "这是我的");
    }

    #[test]
    fn overlap_only_right_at_the_cursor() {
        assert_eq!(f("就是这样。", "就是这样。", ""), "就是这样。");
        assert_eq!(f("就是从老家回来的", "你就是。然后", ""), "就是从老家回来的");
        assert_eq!(f("就是", "我知道你就是", ""), "就是");
    }

    #[test]
    fn english() {
        let r = fit("We should move the meeting.", "I think we should ", " tomorrow.");
        assert_eq!(r.text, "move the meeting");
        assert_eq!(r.changes, vec!["head", "punct"]);
        assert_eq!(f("send the report to the team.", "Please ", " to the team."), "send the report");
        assert_eq!(f("Review the PR before lunch.", "Can you review", ""), " the PR before lunch.");
        assert_eq!(f("Then we deploy.", "Fix the tests and", "on Friday"), " Then we deploy ");
        assert_eq!(f("then we deploy.", "Fix the tests and", "on Friday"), " then we deploy ");
        assert_eq!(f("Then we deploy.", "Fix the tests.", " The rest can wait."), " Then we deploy.");
    }

    #[test]
    fn punctuation_after_the_cursor() {
        assert_eq!(f("我们周五发布。", "计划是", "，大家觉得呢？"), "我们周五发布");
        assert_eq!(f("ship it on Friday.", "The plan is to", ", right?"), " ship it on Friday");
        assert_eq!(f("从老家回来。", "我知道你是", "的那天"), "从老家回来");
        assert_eq!(f("中间再补一句。", "第一句。", "第三句。"), "中间再补一句。");
    }

    #[test]
    fn no_doubled_punctuation_at_the_start() {
        let r = fit("今天的安排：下午三点开会。", "今天的安排：", "");
        assert_eq!(r.text, "下午三点开会。");
        assert_eq!(r.changes, vec!["head"]);
        assert_eq!(f("：下午三点开会。", "今天的安排：", ""), "下午三点开会。");
    }

    #[test]
    fn no_leading_comma_mid_sentence() {
        assert_eq!(f("，然后再部署。", "先跑测试", ""), "然后再部署。");
        assert_eq!(f("，然后再部署。", "先跑测试，", ""), "然后再部署。");
    }

    #[test]
    fn spacing() {
        assert_eq!(f("the release notes", "Please update", "today"), " the release notes ");
        assert_eq!(f("Claude Code 里面跑", "我在", ""), " Claude Code 里面跑");
        assert_eq!(f("Claude Code里面跑", "我用Typeless听写，在", ""), "Claude Code里面跑");
        assert_eq!(f("配置文件", "打开 MCP 的", ""), "配置文件");
        assert_eq!(f("the notes", "Please update ", " today"), "the notes");
    }

    #[test]
    fn mixed() {
        assert_eq!(f("API 的 timeout 改成三十秒。", "把这个 API 的", ""), " timeout 改成三十秒。");
        assert_eq!(fit("API 的 timeout 改成三十秒。", "把这个 API 的", "").changes, vec!["head", "space"]);
    }

    #[test]
    fn long_text_before_does_not_crash() {
        let before = "这是一段很长的文字，包含 emoji 😀 和 English words. ".repeat(20) + "我知道你就是"; // glyph-ok: text data (an emoji in a field), not an icon
        assert_eq!(fit("就是从老家回来的。", &before, "的。").text, "从老家回来");
        let _ = fit("hello world", &"长".repeat(500), &"后".repeat(500));
        let _ = fit("😀😀", &"😀".repeat(300), ""); // glyph-ok: text data (an emoji in a field), not an icon
    }

    #[test]
    fn a_take_after_a_list_item_starts_its_own_paragraph() {
        assert!(ends_in_list_item("这次要做三件事：\n1. 修好登录\n2. 改价格页\n3. 更新文档", ""));
        assert!(ends_in_list_item("- milk\n- eggs", "\nnext"));
        assert!(!ends_in_list_item("1. 修好登录\n然后", ""));
        assert!(!ends_in_list_item("3. 更新", "文档"));
        assert!(!ends_in_list_item("版本 1.2 已经发布", ""));
        assert_eq!(fit_at_cursor("新的一段。", "- milk\n- eggs", "", false), ("\n\n新的一段。".to_string(), vec!["after_list"]));
        assert_eq!(fit_at_cursor("- a\n- b", "前面", "", true), ("\n- a\n- b".to_string(), vec!["list_line"]));
    }
}
