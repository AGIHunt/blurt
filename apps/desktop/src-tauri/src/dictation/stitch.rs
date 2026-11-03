//! Putting a streamed dictation back together (docs/design/dictation.md §Streaming, §Punctuation at the seams), ported
//! from the Mac's `skills/blurt/recorder/macos/Sources/BlurtCore/DictationStitch.swift` (tests: `DictationStitchTests`,
//! ported below, with `tests/fixtures/dictation_seams.jsonl`, shared with the Swift and Python ports). The pieces the
//! segmenter cut were transcribed (and polished) one by one; this joins their texts without doubling or losing words
//! at the seams.
//!
//!  • join: Chinese / Japanese runs are joined as they are; a space only between two Latin words or numbers (and after
//!    Latin punctuation before a letter), the way the speech model writes one whole utterance.
//!  • a hard cut (no pause; the pieces overlap by ~0.8 s of audio): the words both pieces heard are dropped from the
//!    second — the longest run of ≥ 2 units at the end of the first that the second starts with (allowing 1
//!    half-heard unit in front of it, a word cut in half, when ≥ 3 units match). Units as polish.py's guard counts
//!    them: each CJK character, each Latin word, each digit; case, spaces and punctuation ignored.
//!  • a seam is a pause, not a sentence end: each piece was transcribed (and polished) as if it were a whole utterance,
//!    so it ended in 。 and the next began with a capital — a full stop at every breath. `seam` takes the piece's
//!    trailing punctuation off after a breath and keeps the speech model's own mark after a long pause (`LONG_PAUSE`,
//!    1.2 s) — for the transcript as said (polish off, a fall-back, the speech model's prior). With polish on no pause
//!    leaves a mark: a window's input is the carried clause + the piece with nothing between them (`window_input`).
//!    Mechanical only (docs/design/dictation.md §Rules vs model): no stop words, no list of ordinary words, no
//!    correction markers — whether a sentence is complete, a capital belongs to a name, or a piece corrects the one
//!    before is the polish model's call, made over a window that spans the seam (`commit_split` keeps the last,
//!    unfinished clause of a window to be polished again with the next piece).
//!
//! Swift works on Characters (grapheme clusters), this on `char`s (scalars): the same for the speech models' NFC text;
//! a decomposed accent (e + U+0301) would end a Latin word here.

use std::ops::Range;

/// One unit: what it is (lower case) and where it is in the text (byte range).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Unit {
    pub value: String,
    pub range: Range<usize>,
}

pub fn is_cjk(c: char) -> bool {
    matches!(c as u32, 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF | 0x3040..=0x30FF | 0xAC00..=0xD7AF)
}

fn is_letter(c: char) -> bool {
    c.is_alphabetic()
}

fn is_number(c: char) -> bool {
    c.is_numeric()
}

pub fn is_word_char(c: char) -> bool {
    !is_cjk(c) && (is_letter(c) || is_number(c)) && !c.is_whitespace()
}

/// Foundation's `.whitespacesAndNewlines` trimmed.
fn trim_ws_nl(s: &str) -> &str {
    s.trim_matches(char::is_whitespace)
}

/// Foundation's `.whitespaces` (Unicode Zs and tab — no line breaks) trimmed.
fn trim_ws(s: &str) -> &str {
    s.trim_matches(|c: char| {
        c == '\t'
            || matches!(
                c,
                ' ' | '\u{A0}' | '\u{1680}' | '\u{2000}'
                    ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
            )
    })
}

/// Too short for polish to tidy ("OK", 「好的」): polish.py answers "short" without its model (`len(units) <= 2`), so the
/// app doesn't ask — a one-word reply after the polish server's idle exit waited ~2 s for a model load it didn't use
/// (v0.9 dogfood).
pub const POLISH_MIN_UNITS: usize = 3;

pub fn nothing_to_polish(text: &str) -> bool {
    units(text).len() < POLISH_MIN_UNITS
}

/// Long enough to hold a list worth suggesting (the ≡ chip's structuring pass after the paste): 24 Chinese characters,
/// or 12 Latin words — a word carries about what two characters do. Counting both alike, a 22-word English list of
/// three points never got the chip Chinese got for the same three points (v0.9 dogfood).
pub const LIST_MIN_CONTENT: usize = 24;

pub fn may_hold_list(text: &str) -> bool {
    let us = units(text);
    let cjk = us
        .iter()
        .filter(|u| u.value.chars().next().is_some_and(is_cjk))
        .count();
    cjk + 2 * (us.len() - cjk) >= LIST_MIN_CONTENT
}

/// Each CJK character, each Latin word, each digit — with its range.
pub fn units(text: &str) -> Vec<Unit> {
    let cs: Vec<(usize, char)> = text.char_indices().collect();
    let at = |k: usize| if k < cs.len() { cs[k].0 } else { text.len() };
    let latin_letter = |k: usize| k < cs.len() && is_letter(cs[k].1) && !is_cjk(cs[k].1);
    let mut out = vec![];
    let mut i = 0;
    while i < cs.len() {
        let c = cs[i].1;
        if is_cjk(c) {
            out.push(Unit {
                value: c.to_string(),
                range: at(i)..at(i + 1),
            });
            i += 1;
        } else if is_number(c) {
            out.push(Unit {
                value: c.to_lowercase().collect(),
                range: at(i)..at(i + 1),
            });
            i += 1;
        } else if is_letter(c) {
            let mut j = i + 1;
            while latin_letter(j) {
                j += 1;
            }
            // an apostrophe inside a word (don't, it's)
            if j < cs.len() && (cs[j].1 == '\'' || cs[j].1 == '’') && latin_letter(j + 1) {
                j += 1;
                while latin_letter(j) {
                    j += 1;
                }
            }
            out.push(Unit {
                value: text[at(i)..at(j)].to_lowercase(),
                range: at(i)..at(j),
            });
            i = j;
        } else {
            i += 1;
        }
    }
    out
}

/// Two pieces' texts as one: a space only where two Latin words (or numbers) meet.
pub fn join(a: &str, b: &str) -> String {
    let (a, b) = (trim_ws_nl(a), trim_ws_nl(b));
    if a.is_empty() {
        return b.to_string();
    }
    if b.is_empty() {
        return a.to_string();
    }
    let (last, first) = (a.chars().next_back().unwrap(), b.chars().next().unwrap());
    let latin_end = is_word_char(last) || ".,;:!?)”\"".contains(last);
    let space = latin_end && is_word_char(first);
    format!("{a}{}{b}", if space { " " } else { "" })
}

/// Joins every piece in order (empty ones skipped).
pub fn join_all<S: AsRef<str>>(parts: &[S]) -> String {
    parts
        .iter()
        .fold(String::new(), |acc, p| join(&acc, p.as_ref()))
}

/// The second piece of a hard cut without the words the first already has (`max_units` 12, `slack` 1 on the Mac).
pub fn drop_overlap(previous: &str, next: &str) -> String {
    drop_overlap_with(previous, next, 12, 1)
}

pub fn drop_overlap_with(previous: &str, next: &str, max_units: usize, slack: usize) -> String {
    let (p, n) = (units(previous), units(next));
    if p.len() < 2 || n.len() < 2 {
        return next.to_string();
    }
    let longest = max_units.min(p.len()).min(n.len());
    if longest < 2 {
        return next.to_string();
    }
    for k in (2..=longest).rev() {
        let tail: Vec<&str> = p[p.len() - k..].iter().map(|u| u.value.as_str()).collect();
        for off in 0..=slack.min(n.len() - k) {
            if !(off == 0 || k >= 3) {
                continue;
            }
            if n[off..off + k]
                .iter()
                .map(|u| u.value.as_str())
                .eq(tail.iter().copied())
            {
                let cut = n[off + k - 1].range.end;
                // the punctuation that followed the dropped words goes with them
                let rest = next[cut..]
                    .trim_start_matches(|c: char| !is_letter(c) && !is_number(c) && !is_cjk(c));
                return rest.to_string();
            }
        }
    }
    next.to_string()
}

// MARK: seams are pauses, not sentence ends

/// A pause at least this long may have ended a sentence; anything shorter is a breath.
pub const LONG_PAUSE: f64 = 1.2;
/// What a pause leaves at the end of a piece: the sentence ends and commas the speech model or polish put there.
const TRAILING: &[char] = &[
    '。', '.', '!', '?', '！', '？', '，', ',', '、', '；', ';', '…',
];
const TERMINATORS: &[char] = &['。', '.', '!', '?', '！', '？'];
const CLOSERS: &[char] = &['”', '’', '"', '\'', '」', '』', '）', ')'];

/// The text without the punctuation at its end, and that punctuation.
pub fn split_trailing(text: &str) -> (String, String) {
    let mut core = trim_ws_nl(text);
    let mut end = String::new();
    while let Some(c) = core.chars().next_back() {
        if !(TRAILING.contains(&c) || c.is_whitespace()) {
            break;
        }
        if !c.is_whitespace() {
            end.insert(0, c);
        }
        core = &core[..core.len() - c.len_utf8()];
    }
    (core.to_string(), end)
}

fn ends_cjk(text: &str) -> bool {
    text.chars()
        .rev()
        .find(|&c| is_letter(c) || is_number(c))
        .is_some_and(is_cjk)
}

/// The sentence end to write after `text`: the one in `end` (a full stop when it had none), in the text's script.
pub fn terminator(end: &str, after: &str) -> String {
    let c = end.chars().find(|c| TERMINATORS.contains(c)).unwrap_or('.');
    let cjk = ends_cjk(after);
    let t = match c {
        '!' | '！' => {
            if cjk {
                "！"
            } else {
                "!"
            }
        }
        '?' | '？' => {
            if cjk {
                "？"
            } else {
                "?"
            }
        }
        _ => {
            if cjk {
                "。"
            } else {
                "."
            }
        }
    };
    t.to_string()
}

/// The one mark a pause leaves: the sentence end in `end` (in the text's script), else its semicolon or comma.
pub fn mark(end: &str, after: &str) -> String {
    if end.chars().any(|c| TERMINATORS.contains(&c)) {
        return terminator(end, after);
    }
    if end.is_empty() {
        return String::new();
    }
    if end.chars().any(|c| c == '；' || c == ';') {
        return if ends_cjk(after) { "；" } else { ";" }.to_string();
    }
    let comma = if ends_cjk(after) { "，" } else { "," };
    comma.to_string()
}

/// What a pause between two pieces leaves. Mechanical — the pause's length and the speech model's own mark, no word
/// lists: after a long pause (≥ `LONG_PAUSE`) the mark the speech model ended the piece with stays; after a breath (or a
/// pause not known) it goes. Words and case are left as they are; with polish on, the model decides over a window that
/// spans the seam.
pub fn seam(previous: &str, next: &str, pause: Option<f64>) -> (String, String) {
    let (core, end) = split_trailing(previous);
    if core.is_empty() {
        return (previous.to_string(), next.to_string());
    }
    if let Some(p) = pause {
        if p >= LONG_PAUSE && !end.is_empty() {
            let m = mark(&end, &core);
            return (core + &m, next.to_string());
        }
    }
    (core, next.to_string())
}

/// The pieces' texts joined with the seam rule. `pauses[i]`: the pause after piece i (None: not known — a short one).
/// The last piece keeps its ending: that is where the dictation ended.
pub fn join_pieces<S: AsRef<str>>(texts: &[S], pauses: &[Option<f64>]) -> String {
    let mut acc = String::new();
    let mut after: Option<f64> = None;
    for (i, t) in texts.iter().enumerate() {
        let pause = pauses.get(i).copied().flatten();
        let t = trim_ws_nl(t.as_ref());
        if t.is_empty() {
            // a piece with no words: its pause adds to the one before it
            if let (Some(a), Some(p)) = (after, pause) {
                after = Some(a + p);
            }
            continue;
        }
        if acc.is_empty() {
            acc = t.to_string();
        } else {
            let (a, b) = seam(&acc, t, after);
            acc = join(&a, &b);
        }
        after = pause;
    }
    acc
}

/// Where a polish window fell back to the transcript, its seam (the pause before the piece) still gets punctuation:
/// after a long pause the seam rule's; after a short one a comma where the speech model heard a boundary (`heard_end`:
/// the mark it ended the piece with). Without it a fall-back read 「…跑完第二，把文档…」.
pub fn fallback_seam(previous: &str, next: &str, pause: Option<f64>, heard_end: &str) -> String {
    let (core, end) = split_trailing(previous);
    if core.is_empty() {
        return join(previous, next);
    }
    let m = if end.is_empty() {
        heard_end
    } else {
        end.as_str()
    };
    if let Some(p) = pause {
        if p >= LONG_PAUSE {
            let (a, b) = seam(&format!("{core}{m}"), next, Some(p));
            return join(&a, &b);
        }
    }
    let rest = trim_ws_nl(next);
    if !m.is_empty() {
        return format!("{core}{}{rest}", if ends_cjk(&core) { "，" } else { ", " });
    }
    join(&core, rest)
}

/// The pieces' texts joined as a fall-back types them: `join_pieces`, with `fallback_seam` at every seam.
pub fn join_pieces_for_fallback<S: AsRef<str>>(texts: &[S], pauses: &[Option<f64>]) -> String {
    let mut acc = String::new();
    let mut after: Option<f64> = None;
    let mut after_end = String::new();
    for (i, t) in texts.iter().enumerate() {
        let pause = pauses.get(i).copied().flatten();
        let t = trim_ws_nl(t.as_ref());
        if t.is_empty() {
            if let (Some(a), Some(p)) = (after, pause) {
                after = Some(a + p);
            }
            continue;
        }
        acc = if acc.is_empty() {
            t.to_string()
        } else {
            fallback_seam(&acc, t, after, &after_end)
        };
        after = pause;
        after_end = split_trailing(t).1;
    }
    acc
}

/// The window's output with the case its first word had in the input: polish capitalises a window as a sentence of its
/// own (「…, update the docs」 → "Update the docs") when it continues one.
pub fn keep_case(input: &str, output: &str) -> String {
    let (i, o) = (trim_ws(input), trim_ws(output));
    let (Some(a), Some(b)) = (i.chars().next(), o.chars().next()) else {
        return output.to_string();
    };
    if !(a.is_lowercase() && b.is_uppercase() && is_word_char(b)) {
        return output.to_string();
    }
    let word = |s: &str| -> String {
        s.chars()
            .take_while(|&c| is_letter(c) || c == '\'' || c == '’')
            .collect()
    };
    let (wi, wo) = (word(i), word(o));
    let n = wi.chars().count();
    if wi.is_empty()
        || n != wo.chars().count()
        || wi.to_lowercase() != wo.to_lowercase()
        || !wo.chars().skip(1).eq(wi.chars().skip(1))
    {
        return output.to_string();
    }
    let rest: String = o.chars().skip(n).collect();
    wi + &rest
}

/// A polish window's input: the clause carried from the window before + the new piece (its ending taken off), with no
/// mark between them whatever the pause was. A pause is not punctuation: after a long one (≥ `LONG_PAUSE`) the carried
/// clause used to go in with the mark the window before had ended it with — a mark polish wrote without seeing what came
/// next, nearly always 。 — and the model kept a mark there (turning 。 into ，): on real spontaneous speech 5 of 15
/// mid-clause thinking pauses ≥ 1.2 s at a cut got one (「报过绘画班但是，我报的是」), none without it. Whether the clause
/// ended is the model's call from the words on both sides (docs/design/dictation.md §Thinking pauses on real speech).
pub fn window_input(carry: &str, piece: &str) -> String {
    join(carry, piece)
}

/// The text stops inside a sentence (no sentence end, no line break at its end).
pub fn mid_sentence(text: &str) -> bool {
    match trim_ws(text).chars().next_back() {
        Some(last) => !TERMINATORS.contains(&last) && last != '\n',
        None => false,
    }
}

/// A polish window's output split for committing: everything up to its last sentence end — or, with `at_clauses` (the
/// Mac's default; `commit_split` here), its last comma — is final; the last, unfinished clause (`carry`) is polished
/// again together with the next piece, so polish decides the punctuation across the pause. Only the window's very end
/// was written without knowing what came next; every comma inside it was decided with the words on both sides in view.
/// Carrying a clause rather than a whole sentence keeps each window — and the one left at key-up — small: a long
/// sentence carried whole made the last polish ~2× slower. `end` is the punctuation the window ended in (taken off the
/// carry: a pause is not a sentence end). Returns (commit, carry, end).
pub fn commit_split(text: &str) -> (String, String, String) {
    commit_split_with(text, true)
}

pub fn commit_split_with(text: &str, at_clauses: bool) -> (String, String, String) {
    let (core, end) = split_trailing(text);
    let clause: &[char] = if at_clauses {
        &['，', '；', '、', '：', ',', ';', ':']
    } else {
        &[]
    };
    let cs: Vec<(usize, char)> = core.char_indices().collect();
    let at = |k: usize| if k < cs.len() { cs[k].0 } else { core.len() };
    let mut cut: Option<usize> = None;
    let mut i = 0;
    while i < cs.len() {
        let c = cs[i].1;
        let mut j = i + 1;
        if TERMINATORS.contains(&c) || clause.contains(&c) {
            while j < cs.len() && CLOSERS.contains(&cs[j].1) {
                j += 1;
            }
            // Latin punctuation counts only before a space or a CJK character (not 3.5, v0.8, 1,000, 10:30)
            let latin = c.is_ascii();
            if !latin || j == cs.len() || cs[j].1.is_whitespace() || is_cjk(cs[j].1) {
                cut = Some(at(j));
            }
        }
        i = j;
    }
    let commit_end = cut.unwrap_or(0);
    (
        trim_ws(&core[..commit_end]).to_string(),
        trim_ws(&core[commit_end..]).to_string(),
        end,
    )
}

/// Hearing again (docs/design/dictation.md §Hearing again): the pieces are heard once more in windows of about
/// `REHEAR_WINDOW` seconds, with the text so far as context — a 3–8 s piece hears half a sentence, a window the whole of
/// it (巨幅 → GIF, 强势了 → 尝试了 on the user's own takes). A window closes after a piece once it is that long and the cut
/// after the piece was a pause: never at a hard cut, so two windows never share audio and nothing is dropped twice.
pub const REHEAR_WINDOW: f64 = 10.0;

pub fn closes_window(start: i64, end: i64, hard_cut: bool, sample_rate: f64, window: f64) -> bool {
    !hard_cut && (end - start) as f64 >= window * sample_rate
}

/// One piece of a take for `rehear_groups`: start / end in seconds; `hard`: the piece began at a hard cut.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Piece {
    pub start: f64,
    pub end: f64,
    pub hard: bool,
}

/// The same windows from a take's pieces: ranges of piece indices, the last one ending with the take. The Dictation
/// Lab's port is dictation_stitch.rehear_groups.
pub fn rehear_groups(pieces: &[Piece], window: f64) -> Vec<Range<usize>> {
    let mut out = vec![];
    let mut first = 0;
    for (i, p) in pieces.iter().enumerate() {
        if i + 1 >= pieces.len() {
            break;
        }
        let ms = |s: f64| (s * 1000.0).round() as i64;
        if closes_window(
            ms(pieces[first].start),
            ms(p.end),
            pieces[i + 1].hard,
            1000.0,
            window,
        ) {
            out.push(first..i + 1);
            first = i + 1;
        }
    }
    if first < pieces.len() {
        out.push(first..pieces.len());
    }
    out
}

/// Numbered or bulleted lines ("1. …", "2、…", "- …" at a line start): Light must never write one; a structured text
/// with ≥ 2 of them is a list. (The Mac's regex `^[ \t]*(?:[0-9]{1,2}(?:[.)）](?![0-9])|、)|[-•*](?=[ \t]))[ \t]*\S`,
/// by hand: no regex crate here.)
pub fn list_lines(text: &str) -> usize {
    text.split('\n').filter(|l| is_list_line(l)).count()
}

fn is_list_line(line: &str) -> bool {
    let cs: Vec<char> = line.chars().collect();
    let blank = |c: char| c == ' ' || c == '\t';
    // `[ \t]*\S` from `k`
    let text_follows = |k: usize| {
        let mut k = k;
        while k < cs.len() && blank(cs[k]) {
            k += 1;
        }
        k < cs.len() && !cs[k].is_whitespace()
    };
    let mut i = 0;
    while i < cs.len() && blank(cs[i]) {
        i += 1;
    }
    let digits = cs[i..].iter().take_while(|c| c.is_ascii_digit()).count();
    for n in (1..=digits.min(2)).rev() {
        let j = i + n;
        let Some(&c) = cs.get(j) else { continue };
        if (c == '.' || c == ')' || c == '）')
            && !cs.get(j + 1).is_some_and(|d| d.is_ascii_digit())
            && text_follows(j + 1)
        {
            return true;
        }
        if c == '、' && text_follows(j + 1) {
            return true;
        }
    }
    matches!(cs.get(i), Some('-' | '•' | '*'))
        && cs.get(i + 1).is_some_and(|&c| blank(c))
        && text_follows(i + 1)
}

#[cfg(test)]
mod tests {
    //! Joining a streamed dictation's pieces (docs/design/dictation.md §Streaming): no doubled and no lost words at the
    //! seams, spaces only between Latin words.
    use super::*;

    /// polish.py's own rule (`len(units(raw)) <= 2` → "short", no model): the app doesn't ask for those, so a one-word
    /// reply never waits for a cold polish model.
    #[test]
    fn too_short_to_polish() {
        for s in ["OK", "Okay.", "好的", "好的。", "yes sure", "12"] {
            assert!(nothing_to_polish(s), "{s}");
        }
        for s in ["好的呀", "OK sure thing", "sounds good to me", "123"] {
            assert!(!nothing_to_polish(s), "{s}");
        }
    }

    /// The ≡ chip's length gate: the same three points in English and Chinese both qualify (v0.9 dogfood: the 22-word
    /// English list never got the chip); a short sentence doesn't.
    #[test]
    fn a_list_is_worth_suggesting_in_either_language() {
        assert!(may_hold_list(
            "There are three things to do. First, fix the login button. Second, update the pricing page. Third, write the release notes."
        ));
        assert!(may_hold_list(
            "这次要做三件事。第一，修好登录按钮。第二，改一下价格页面的样式。第三，更新使用文档。"
        ));
        assert!(!may_hold_list("Sounds good, let's ship it tomorrow."));
        assert!(!may_hold_list("好的，明天再说。"));
    }

    #[test]
    fn join_spaces_only_between_latin_words() {
        assert_eq!(
            join("我们先看一下日志。", "然后再部署。"),
            "我们先看一下日志。然后再部署。"
        );
        assert_eq!(
            join("open the PR", "and merge it"),
            "open the PR and merge it"
        );
        assert_eq!(
            join("Open the PR.", "Then merge it."),
            "Open the PR. Then merge it."
        );
        assert_eq!(
            join("先跑一下 pytest", "然后提交"),
            "先跑一下 pytest然后提交"
        );
        assert_eq!(join("把 MCP 的超时改成 30", "秒"), "把 MCP 的超时改成 30秒");
        assert_eq!(
            join_all(&["", "第一段。", "", "第二段。"]),
            "第一段。第二段。"
        );
        assert_eq!(join("  a  ", "  "), "a");
    }

    #[test]
    fn hard_cut_drops_the_words_both_pieces_heard() {
        // the 0.8 s overlap was heard twice: 「的时候比」 at the end of one and the start of the next
        assert_eq!(
            drop_overlap("我觉得短句的时候比", "的时候比 Typeless 要快一点"),
            "Typeless 要快一点"
        );
        // a half-heard unit in front of the doubled words (the cut went through a syllable)
        assert_eq!(
            drop_overlap("把 worktree 的分支名", "名分支名改成 fix"),
            "改成 fix"
        );
        assert_eq!(
            drop_overlap("we should open the pull", "the pull request today"),
            "request today"
        );
        // case and punctuation don't matter
        assert_eq!(
            drop_overlap("Run it in tmux,", "in TMUX, then detach"),
            "then detach"
        );
    }

    #[test]
    fn no_overlap_leaves_the_text_alone() {
        assert_eq!(drop_overlap("先检查配额", "然后跑评测"), "然后跑评测");
        // one shared unit isn't an overlap (的 is everywhere)
        assert_eq!(drop_overlap("系统的", "的确如此"), "的确如此");
        assert_eq!(drop_overlap("", "hello world"), "hello world");
        // the same words later in the next piece aren't at its start: kept
        assert_eq!(
            drop_overlap("下午三点", "开会，下午三点见"),
            "开会，下午三点见"
        );
    }

    #[test]
    fn units_of_mixed_text() {
        let v: Vec<String> = units("我们的API v2 don't")
            .into_iter()
            .map(|u| u.value)
            .collect();
        assert_eq!(v, ["我", "们", "的", "api", "v", "2", "don't"]);
        // the ranges point into the text
        let t = "我们的API";
        assert_eq!(&t[units(t)[3].range.clone()], "API");
    }

    // MARK: a seam is a pause, not a sentence end (synthetic sentences shaped like the user's reports)

    #[test]
    fn a_breath_leaves_no_full_stop() {
        assert_eq!(
            join_pieces(
                &[
                    "我刚才看了一下日志，好像是因为。",
                    "网络断开以后没有重新连接。",
                    "所以后面的请求都失败了。"
                ],
                &[Some(0.7), Some(0.8)]
            ),
            "我刚才看了一下日志，好像是因为网络断开以后没有重新连接所以后面的请求都失败了。"
        );
        // a comma the cut made goes too (polish puts back the ones that belong)
        assert_eq!(
            join_pieces(
                &["这个新功能确实挺顺手，", "出门的时候不用带电脑了。"],
                &[Some(0.6)]
            ),
            "这个新功能确实挺顺手出门的时候不用带电脑了。"
        );
        // a question mark the cut made, too; the last piece keeps its ending: the dictation ended there
        assert_eq!(
            join_pieces(
                &["你是不是为了让速度更快？", "所以一边录一边处理的？"],
                &[Some(0.7)]
            ),
            "你是不是为了让速度更快所以一边录一边处理的？"
        );
        // not known (still quiet when the next piece was transcribed): a breath
        assert_eq!(
            join_pieces(&["我们先开个短会。", "把内容再过一遍。"], &[None]),
            "我们先开个短会把内容再过一遍。"
        );
        // mixed Chinese and English
        assert_eq!(
            join_pieces(
                &["我在 Claude Code 里面。", "让它写了一个 Python 脚本。"],
                &[Some(0.8)]
            ),
            "我在 Claude Code 里面让它写了一个 Python 脚本。"
        );
    }

    #[test]
    fn a_long_pause_keeps_the_speech_models_mark() {
        assert_eq!(
            join_pieces(
                &["回到办公室以后再慢慢整理也来得及。", "下午我们再开会。"],
                &[Some(1.4)]
            ),
            "回到办公室以后再慢慢整理也来得及。下午我们再开会。"
        );
        assert_eq!(
            join_pieces(
                &["The report looks good overall.", "Thanks for your help."],
                &[Some(1.5)]
            ),
            "The report looks good overall. Thanks for your help."
        );
        // no stop words second-guess it (that is polish's call, over a window spanning the seam): the mark as heard
        assert_eq!(
            join_pieces(&["最好在设置页面里也，", "加上一个开关。"], &[Some(1.5)]),
            "最好在设置页面里也，加上一个开关。"
        );
        assert_eq!(
            join_pieces(&["First run the tests;", "then ship it."], &[Some(1.4)]),
            "First run the tests; then ship it."
        );
        // exactly the threshold counts as long; just under it doesn't
        assert_eq!(
            join_pieces(
                &["我们明天上午十点开会。", "下午修问题。"],
                &[Some(LONG_PAUSE)]
            ),
            "我们明天上午十点开会。下午修问题。"
        );
        assert_eq!(
            join_pieces(&["我们明天上午十点开会。", "下午修问题。"], &[Some(1.19)]),
            "我们明天上午十点开会下午修问题。"
        );
        assert_eq!(mark("。", "Done"), ".");
        assert_eq!(mark("，", "好的"), "，");
        assert_eq!(mark("", "好的"), "");
    }

    /// With polish on no pause leaves a mark: the carried clause goes into the next window as it is, and the model
    /// decides from the words whether it ended (a long pause used to add the mark the window before ended in —
    /// polish's own 。 — and a thinking pause came out as 「但是，我报的是」).
    #[test]
    fn a_window_gets_no_mark_from_the_pause() {
        assert_eq!(
            window_input("我小时候报过绘画班，但是", "我报的是一个线上的课"),
            "我小时候报过绘画班，但是我报的是一个线上的课"
        );
        assert_eq!(window_input("", "下午修问题。"), "下午修问题。");
        assert_eq!(
            window_input("we should move the meeting to", "Thursday afternoon."),
            "we should move the meeting to Thursday afternoon."
        );
    }

    #[test]
    fn the_case_is_left_alone() {
        // no list of ordinary words decides whether a capital is a name's: the words stay as the speech model wrote
        // them (polish, when on, fixes the case seeing the sentence)
        assert_eq!(
            join_pieces(
                &["We should move the meeting to.", "Thursday afternoon."],
                &[Some(0.7)]
            ),
            "We should move the meeting to Thursday afternoon."
        );
        assert_eq!(
            join_pieces(&["Yesterday,", "I fixed the login bug."], &[Some(0.7)]),
            "Yesterday I fixed the login bug."
        );
    }

    #[test]
    fn list_lines_counts_numbered_and_bulleted_lines() {
        assert_eq!(list_lines("明天要做三件事：\n1. 跑测试\n2. 写文档"), 2);
        assert_eq!(list_lines("- a\n- b\n3、c"), 3);
        assert_eq!(list_lines("1.5 GB is fine\n第一，跑测试。"), 0);
        // the regex's edges, by hand: two digits at most, a bullet needs a space, a marker needs text after it
        assert_eq!(list_lines("12) x\n123. x\n-x\n1. \n  * y\n4）z"), 3);
    }

    #[test]
    fn commit_split_keeps_the_unfinished_clause() {
        let s = |a: &str, b: &str, c: &str| (a.to_string(), b.to_string(), c.to_string());
        assert_eq!(
            commit_split("明天上午开个短会，把内容再过一遍。下午的时间"),
            s("明天上午开个短会，把内容再过一遍。", "下午的时间", "")
        );
        // a comma inside the window was decided with both sides in view: committed; the clause after it is carried
        assert_eq!(
            commit_split("我刚才看了一下日志，好像是因为网络断开"),
            s("我刚才看了一下日志，", "好像是因为网络断开", "")
        );
        // only sentence ends, when asked
        assert_eq!(
            commit_split_with("我刚才看了一下日志，好像是因为网络断开", false),
            s("", "我刚才看了一下日志，好像是因为网络断开", "")
        );
        // the window's own ending was a pause: carried, its full stop kept aside
        assert_eq!(
            commit_split("我们先开个短会。"),
            s("", "我们先开个短会", "。")
        );
        assert_eq!(
            commit_split("The report looks good. But the numbers in v2.5 don't match."),
            s(
                "The report looks good.",
                "But the numbers in v2.5 don't match",
                "."
            )
        );
        let r = commit_split("It costs 1,000 dollars at 10:30, and then we");
        assert_eq!(
            (r.0.as_str(), r.1.as_str()),
            ("It costs 1,000 dollars at 10:30,", "and then we")
        );
        assert_eq!(
            commit_split("他说：“好的。”然后就走了，"),
            s("他说：“好的。”", "然后就走了", "，")
        );
        assert_eq!(commit_split("").0, "");
    }

    // MARK: the fixture shared with scripts/dictation_stitch.py (the Dictation Lab's replay of the windows)

    #[test]
    fn shared_seam_fixture() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../tests/fixtures/dictation_seams.jsonl"
        );
        let text = std::fs::read_to_string(path).expect("tests/fixtures/dictation_seams.jsonl");
        let rows: Vec<serde_json::Value> = text
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        assert!(rows.len() >= 30);
        let st = |v: &serde_json::Value| v.as_str().unwrap().to_string();
        let strs = |v: &serde_json::Value| v.as_array().unwrap().iter().map(st).collect::<Vec<_>>();
        for r in &rows {
            let pauses: Vec<Option<f64>> = r["pauses"]
                .as_array()
                .map(|a| a.iter().map(|p| p.as_f64()).collect())
                .unwrap_or_default();
            match r["fn"].as_str().unwrap() {
                "joinPieces" => assert_eq!(
                    join_pieces(&strs(&r["texts"]), &pauses),
                    st(&r["want"]),
                    "{r}"
                ),
                "joinPiecesForFallback" => {
                    assert_eq!(
                        join_pieces_for_fallback(&strs(&r["texts"]), &pauses),
                        st(&r["want"]),
                        "{r}"
                    )
                }
                "fallbackSeam" => assert_eq!(
                    fallback_seam(
                        &st(&r["previous"]),
                        &st(&r["next"]),
                        r["pause"].as_f64(),
                        &st(&r["heard"])
                    ),
                    st(&r["want"]),
                    "{r}"
                ),
                "commitSplit" => {
                    let (a, b, c) = commit_split(&st(&r["text"]));
                    assert_eq!(vec![a, b, c], strs(&r["want"]), "{r}")
                }
                "midSentence" => assert_eq!(
                    mid_sentence(&st(&r["text"])),
                    r["want"].as_bool().unwrap(),
                    "{r}"
                ),
                "keepCase" => assert_eq!(
                    keep_case(&st(&r["input"]), &st(&r["output"])),
                    st(&r["want"]),
                    "{r}"
                ),
                "windowInput" => assert_eq!(
                    window_input(&st(&r["carry"]), &st(&r["piece"])),
                    st(&r["want"]),
                    "{r}"
                ),
                other => panic!("unknown fn {other}"),
            }
        }
    }

    #[test]
    fn a_fall_back_seam_gets_a_comma() {
        // the bug: a refused window typed 「…跑完第二，…」
        assert_eq!(
            fallback_seam(
                "第一，把测试全部跑完",
                "第二把文档更新一下",
                Some(0.7),
                "。"
            ),
            "第一，把测试全部跑完，第二把文档更新一下"
        );
        // no list of words that "bind" to the next: where the speech model heard a boundary, the comma goes in
        assert_eq!(
            fallback_seam("把测试全部跑完", "第二把文档更新一下", Some(0.7), ""),
            "把测试全部跑完第二把文档更新一下"
        );
    }

    #[test]
    fn terminator_follows_the_script() {
        assert_eq!(terminator(".", "我们下午开会"), "。");
        assert_eq!(terminator("？", "Can you check"), "?");
        assert_eq!(terminator("", "Done"), ".");
    }

    /// tests/test_dictation_stitch.py's REHEAR: the same windows in both
    #[test]
    fn rehear_groups_close_at_pauses_only() {
        let p = |v: &[(f64, f64, bool)]| {
            v.iter()
                .map(|&(start, end, hard)| Piece { start, end, hard })
                .collect::<Vec<_>>()
        };
        let cases: Vec<(Vec<Piece>, Vec<Range<usize>>)> = vec![
            (
                p(&[
                    (0.0, 4.0, false),
                    (4.0, 9.0, false),
                    (9.0, 16.0, false),
                    (16.0, 20.0, false),
                ]),
                vec![0..3, 3..4],
            ),
            // never closed at a hard cut: the next window would share 0.8 s of audio with this one
            (
                p(&[
                    (0.0, 8.0, false),
                    (8.0, 20.0, false),
                    (19.2, 24.0, true),
                    (24.0, 30.0, false),
                ]),
                vec![0..3, 3..4],
            ),
            (p(&[(0.0, 3.2, false)]), vec![0..1]),
            (
                p(&[(0.0, 15.0, false), (15.0, 16.0, false)]),
                vec![0..1, 1..2],
            ),
        ];
        for (pieces, want) in cases {
            assert_eq!(rehear_groups(&pieces, REHEAR_WINDOW), want, "{pieces:?}");
        }
    }
}
