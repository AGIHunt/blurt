//! Copy text from the screen (⌥C, docs/design/screen-text.md), Windows: the area the user drew → the text in it, the
//! way it would read if they had selected and copied it. A port of the Mac's `BlurtCore/ScreenText.swift` (same
//! thresholds, same rules). The OCR (`Windows.Media.Ocr`) reads the words; everything after that is geometry, never
//! language rules:
//!
//!  • what the edge cut — a line whose glyphs reach the top or bottom row of the picture and that shows less than a
//!    whole line's height (Vision reads the top half of 两类数据采集方案 as 网关数掂米果力条…), and a character narrower
//!    than its neighbours whose ink touches the left or right column (半个「生」→ 三);
//!  • rows — the pieces on one baseline, a gap wider than a line's height between two of them is a column (a tab);
//!  • blocks — rows closer than a line's height; a block with two or more multi-column rows is a table;
//!  • wrapping — a row continues the one before when the first word of it would not have fit at the end of that one
//!    (the classic reflow test): a wrapped paragraph or list item is one line again, a path broken at a hyphen too;
//!  • preformatted blocks — rows starting at different x (code) or mostly not wrapped (a terminal) keep their lines,
//!    indented by the block's character pitch;
//!  • list markers — a lone symbol and a space at a row's start (•, ◎ for a check icon, 。 for a hollow bullet) is
//!    "- ", nested by x; "2.ordo" gets its space back;
//!  • spacing — CJK and Latin are joined with a space only when the capture itself does so; full-width punctuation
//!    with no CJK on either side is ASCII again (Vision writes "（etl_nightly_v2）" and "：：" in code).
//!
//! What differs from the Mac is only the input: Vision gives a line's text with a box per character, Windows gives a
//! line as words (one per character for Chinese and Japanese) with a box per word and no spaces. [`pieces`] turns a
//! Windows line into the Mac's pieces (the words spelled with [`join_words`], split where a gap is a column), and from
//! there [`layout`] is the Mac's code. All coordinates are pixels of the captured picture, top-left origin.
//!
//! The one call the app makes: [`compose`].

use std::cmp::Ordering;

/// A box in pixels, top-left origin (Vision's normalized bottom-left boxes are converted before they get here).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub fn new(x: f64, y: f64, w: f64, h: f64) -> Rect {
        Rect { x, y, w, h }
    }
    pub fn min_x(&self) -> f64 {
        self.x
    }
    pub fn max_x(&self) -> f64 {
        self.x + self.w
    }
    pub fn min_y(&self) -> f64 {
        self.y
    }
    pub fn max_y(&self) -> f64 {
        self.y + self.h
    }
    pub fn mid_y(&self) -> f64 {
        self.y + self.h / 2.0
    }
    pub fn union(&self, o: &Rect) -> Rect {
        let (x0, y0) = (self.min_x().min(o.min_x()), self.min_y().min(o.min_y()));
        let (x1, y1) = (self.max_x().max(o.max_x()), self.max_y().max(o.max_y()));
        Rect::new(x0, y0, x1 - x0, y1 - y0)
    }
}

/// One word `Windows.Media.Ocr` read (`OcrWord`: `Text`, `BoundingRect`). For Chinese and Japanese a word is one
/// character.
#[derive(Clone, Debug, PartialEq)]
pub struct Word {
    pub text: String,
    pub rect: Rect,
}

/// One line it read (`OcrLine`): its words left to right and their union box.
#[derive(Clone, Debug, PartialEq)]
pub struct Line {
    pub words: Vec<Word>,
    pub rect: Rect,
}

impl Line {
    /// A line from its words; the box is their union (an `OcrLine` has none of its own).
    pub fn new(words: Vec<Word>) -> Line {
        let rect = words
            .iter()
            .map(|w| w.rect)
            .reduce(|a, b| a.union(&b))
            .unwrap_or_default();
        Line { words, rect }
    }
}

/// One line as the Mac's rules see it: its text, its box and each character's box (pixels, top-left origin; None =
/// none given). Vision gives these directly; on Windows [`pieces`] makes them from a line's words.
#[derive(Clone, Debug, PartialEq)]
pub struct Piece {
    pub text: String,
    pub rect: Rect,
    pub chars: Vec<Option<Rect>>,
}

/// What the app gets back: the text for the clipboard and how many non-empty lines it has (the Mac's `lines` in the
/// `screen_text` event).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Composed {
    pub text: String,
    pub line_count: usize,
}

/// The picture's pixels as grey levels, for the edge tests (which pixels are ink, which are the background). The
/// picture is the area the user drew: its width and height are the selection's.
#[derive(Clone, Debug)]
pub struct Gray {
    pub width: usize,
    pub height: usize,
    px: Vec<u8>,
    /// The background: the median of the border's pixels.
    pub background: i32,
}

impl Gray {
    /// From grey levels, one byte per pixel, row by row. None for an empty picture or the wrong number of bytes.
    pub fn new(width: usize, height: usize, px: Vec<u8>) -> Option<Gray> {
        if width == 0 || height == 0 || px.len() != width * height {
            return None;
        }
        let (w, h) = (width, height);
        let mut border: Vec<u8> = Vec::with_capacity(2 * (w + h));
        for x in 0..w {
            border.push(px[x]);
            border.push(px[(h - 1) * w + x]);
        }
        for y in 0..h {
            border.push(px[y * w]);
            border.push(px[y * w + w - 1]);
        }
        border.sort_unstable();
        let background = border[border.len() / 2] as i32;
        Some(Gray {
            width,
            height,
            px,
            background,
        })
    }

    /// From a BGRA8 bitmap (what a Windows capture / `SoftwareBitmap` holds), `stride` bytes per row. Drawn over
    /// white, as the Mac draws the capture into a white grey context.
    pub fn from_bgra8(width: usize, height: usize, stride: usize, data: &[u8]) -> Option<Gray> {
        if stride < width * 4 || data.len() < stride * height.saturating_sub(1) + width * 4 {
            return None;
        }
        let mut px = Vec::with_capacity(width * height);
        for y in 0..height {
            let row = &data[y * stride..y * stride + width * 4];
            for p in row.chunks_exact(4) {
                px.push(over_white(luma(p[2], p[1], p[0]), p[3]));
            }
        }
        Gray::new(width, height, px)
    }

    fn ink(&self, x: usize, y: usize) -> bool {
        (self.px[y * self.width + x] as i32 - self.background).abs() > 60
    }

    /// The share of row y's pixels between x0 and x1 that are ink.
    fn row(&self, y: i64, x0: f64, x1: f64) -> f64 {
        let (a, b) = (0.max(x0 as i64), (self.width as i64).min(x1 as i64));
        if b <= a || y < 0 || y >= self.height as i64 {
            return 0.0;
        }
        let n = (a..b).filter(|&x| self.ink(x as usize, y as usize)).count();
        n as f64 / (b - a) as f64
    }

    fn column(&self, x: i64, y0: f64, y1: f64) -> f64 {
        let (a, b) = (0.max(y0 as i64), (self.height as i64).min(y1 as i64));
        if b <= a || x < 0 || x >= self.width as i64 {
            return 0.0;
        }
        let n = (a..b).filter(|&y| self.ink(x as usize, y as usize)).count();
        n as f64 / (b - a) as f64
    }
}

/// Rec. 601 luma (the Mac lets CoreGraphics convert to device grey; the ink test only asks for a difference of 60
/// levels from the background, which either conversion gives the same answer to for text).
fn luma(r: u8, g: u8, b: u8) -> u8 {
    ((299 * r as u32 + 587 * g as u32 + 114 * b as u32 + 500) / 1000) as u8
}

fn over_white(v: u8, a: u8) -> u8 {
    ((v as u32 * a as u32 + 255 * (255 - a as u32) + 127) / 255) as u8
}

// MARK: - The one call

/// The text in the area the user drew: `lines` as `Windows.Media.Ocr` read them (pixels of `ink`, top-left origin),
/// `ink` the captured picture of that area.
pub fn compose(lines: &[Line], ink: &Gray) -> Composed {
    let ps: Vec<Piece> = lines.iter().flat_map(pieces).collect();
    let text = layout(&ps, ink);
    let line_count = text.split('\n').filter(|l| !l.is_empty()).count();
    Composed { text, line_count }
}

// MARK: - Windows words → the Mac's pieces

/// The gap between a CJK character and a Latin word, as a share of the line's height, above which the capture has a
/// space there (Windows gives no spaces; Vision wrote the ones it saw). On the fixture's words (Vision's character
/// boxes narrowed to their ink, the way Windows boxes a word) a space is 0.29–0.42 of the height, no space −0.06–0.0;
/// a gap Vision called tight at 0.37–0.40 ("约1秒", "Nginx日志") is a space in the expected text. Not on the Mac:
/// Vision spells the line itself.
pub const CJK_LATIN_SPACE: f64 = 0.2;

/// The same for a full-width bracket next to a Latin word ("job （etl", "） can"), higher because Vision reads ASCII
/// brackets in code as full-width ones: there a space is 0.27–1.06 of the height, no space up to 0.25.
pub const BRACKET_LATIN_SPACE: f64 = 0.26;

fn is_bracket(c: char) -> bool {
    "（［｛〔【「『〈《）］｝〕】」』〉》".contains(c)
}

/// A line's words as one string: no space between two CJK characters (CJK punctuation counts as CJK), a space between
/// two Latin words (Windows splits those at spaces), and between CJK and Latin a space only where the gap between
/// their boxes is one ([`CJK_LATIN_SPACE`]): "不要落 Nginx 日志" stays spaced, "落Nginx" stays tight, and the
/// capture-wide vote in [`layout`] then decides as on the Mac. Next to CJK punctuation other than a bracket there is
/// never a space, as in the Mac's joiner (its gap is the punctuation's own half-em, or a code span's padding:
/// "/telemetry，"). One exception, where the Mac's rules need Vision's space: a list mark that starts the line and
/// has a gap after it ("。 需要", a hollow bullet: CJK typesetting never starts a line with 。).
pub fn join_words(line: &Line) -> String {
    spell(&line.words, line.rect.h).0
}

/// [`join_words`] with a box per character: a one-character word's own box, a longer word's box split evenly (Windows
/// boxes words, not letters), None for the spaces put in (Vision gives a space no width either).
fn spell(words: &[Word], line_h: f64) -> (String, Vec<Option<Rect>>) {
    let mut s = String::new();
    let mut chars: Vec<Option<Rect>> = Vec::new();
    let mut prev: Option<&Word> = None;
    for w in words {
        let t: Vec<char> = w.text.chars().filter(|c| !c.is_whitespace()).collect();
        if t.is_empty() {
            continue;
        }
        if let (Some(p), Some(x)) = (prev, s.chars().last()) {
            let (y, gap) = (t[0], w.rect.min_x() - p.rect.max_x());
            let leading_mark = chars.len() == 1 && BULLET_MARKS.contains(x);
            let space = if leading_mark {
                gap > CJK_LATIN_SPACE * line_h
            } else {
                match (is_cjk(x), is_cjk(y)) {
                    (true, true) => false,
                    (false, false) => true,
                    _ if is_bracket(x) || is_bracket(y) => gap > BRACKET_LATIN_SPACE * line_h,
                    _ if is_cjk_punct(x) || is_cjk_punct(y) => false,
                    _ => gap > CJK_LATIN_SPACE * line_h,
                }
            };
            if space {
                s.push(' ');
                chars.push(None);
            }
        }
        let n = t.len() as f64;
        for (i, c) in t.iter().enumerate() {
            s.push(*c);
            chars.push(Some(if t.len() == 1 {
                w.rect
            } else {
                Rect::new(
                    w.rect.x + w.rect.w * i as f64 / n,
                    w.rect.y,
                    w.rect.w / n,
                    w.rect.h,
                )
            }));
        }
        prev = Some(w);
    }
    (s, chars)
}

/// A Windows line as the Mac's pieces. Vision reads the cells of a table row as separate lines and Windows may read
/// them as one; the row rule below puts a tab where two pieces are further apart than 0.9 of the row's height, so a
/// line is split at exactly such gaps and the same rule finds the columns again.
pub fn pieces(line: &Line) -> Vec<Piece> {
    let mut out = Vec::new();
    let mut group: Vec<Word> = Vec::new();
    let flush = |g: &mut Vec<Word>, out: &mut Vec<Piece>| {
        let ws: Vec<Word> = g
            .drain(..)
            .filter(|w| w.text.chars().any(|c| !c.is_whitespace()))
            .collect();
        if ws.is_empty() {
            return;
        }
        let rect = ws
            .iter()
            .map(|w| w.rect)
            .reduce(|a, b| a.union(&b))
            .unwrap();
        let (text, chars) = spell(&ws, line.rect.h);
        out.push(Piece { text, rect, chars });
    };
    for w in &line.words {
        let column = group
            .last()
            .is_some_and(|p| w.rect.min_x() - p.rect.max_x() > 0.9 * line.rect.h);
        if column {
            flush(&mut group, &mut out);
        }
        group.push(w.clone());
    }
    flush(&mut group, &mut out);
    out
}

// MARK: - Layout (ScreenText.swift)

fn is_cjk(c: char) -> bool {
    let v = c as u32;
    (0x2E80..=0x9FFF).contains(&v)
        || (0xFF00..=0xFFEF).contains(&v)
        || (0xF900..=0xFAFF).contains(&v)
}

fn is_cjk_punct(c: char) -> bool {
    let v = c as u32;
    (0x3000..=0x303F).contains(&v) || (0xFF00..=0xFF65).contains(&v)
}

/// `\p{Han}` (Script=Han), for the spacing vote.
fn is_han(c: char) -> bool {
    let v = c as u32;
    matches!(v,
        0x2E80..=0x2E99 | 0x2E9B..=0x2EF3 | 0x2F00..=0x2FD5 | 0x3005 | 0x3007 | 0x3021..=0x3029 | 0x3038..=0x303B
        | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFA6D | 0xFA70..=0xFAD9 | 0x16FE2..=0x16FE3
        | 0x16FF0..=0x16FF1 | 0x20000..=0x2A6DF | 0x2A700..=0x2EE5D | 0x2F800..=0x2FA1D | 0x30000..=0x323AF)
}

/// Letters Swift's `Character.isNumber` also counts (Unihan numeric values: 一, 两, 万, 壹 …), so "1. 一个" reads as
/// a number the way it does on the Mac.
const NUMERIC_LETTERS: &str = "㐅㒃㠪㭍一七万三两九二五亖京亿什仟仨伍佰俩倆億兆兩八六十千卄卅卌叁参參叄四壱壹幺廾廿弌弍弎弐拐拾捌柒洞漆玖百皕秭肆萬貮貳贰鈎钩阡陆陌陸零參拾兩零六陸什𒀸𒀹𒁹𒈦𒈫𒌋𒌍𒎙𠀁𠁤𠃢𠄡𠤪𠦃𠦌𠦜𠫪𠫽𠬙𢎐𢦘𣬛𦉭廾";

fn is_number(c: char) -> bool {
    c.is_numeric() || NUMERIC_LETTERS.contains(c)
}

/// Foundation's `.whitespaces`: tab and the space separators (not line breaks).
fn is_hspace(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    )
}

fn trim_hspace(s: &[char]) -> String {
    let a = s.iter().position(|c| !is_hspace(*c)).unwrap_or(s.len());
    let b = s.iter().rposition(|c| !is_hspace(*c)).map_or(a, |i| i + 1);
    s[a..b.max(a)].iter().collect()
}

/// What goes between the end of `a` and the start of `b` when a line wrapped (or two pieces sit side by side).
fn joiner(a: &str, b: &str, cjk_space: bool) -> &'static str {
    let (Some(x), Some(y)) = (a.chars().last(), b.chars().next()) else {
        return "";
    };
    if "-/_".contains(x) || is_cjk_punct(x) || is_cjk_punct(y) || ",.;:!?)]}%".contains(y) {
        return "";
    }
    if is_cjk(x) && is_cjk(y) {
        return "";
    }
    if is_cjk(x) || is_cjk(y) {
        return if cjk_space { " " } else { "" };
    }
    " "
}

/// the marks that are never a word's start: a bullet even with no space after it ("-", "*", "–", "。", "·" are)
const SOLID_BULLETS: &str = "•◦○◎▪■●◆◇►▸✓✔☐☑"; // glyph-ok: text data (OCR marks, emoji in a field), not an icon
/// what Vision reads a list's bullet or check icon as (OCR input, never shown)
const BULLET_MARKS: &str = "•◦○◎。·▪■●◆◇►▸✓✔☐☑*–-"; // glyph-ok: text data (OCR marks, emoji in a field), not an icon

/// "- rest" for a lone symbol and a space at the start, "N. rest" for a number or letter with . ) 、 (its space put
/// back); None when the row starts with neither. The bool is true for a bullet.
fn marker(s: &str) -> Option<(String, bool)> {
    let a: Vec<char> = s.chars().collect();
    if a.len() >= 3 && BULLET_MARKS.contains(a[0]) && a[1] == ' ' {
        return Some((format!("- {}", trim_hspace(&a[2..])), true));
    }
    // a bullet glyph that is never text is one even when Vision dropped the space after it ("•日志已经附在工单里")
    if a.len() >= 2 && SOLID_BULLETS.contains(a[0]) && !a[1].is_whitespace() {
        return Some((format!("- {}", trim_hspace(&a[1..])), true));
    }
    let mut i = 0;
    while i < a.len() && i < 3 && a[i].is_ascii_digit() {
        i += 1;
    }
    // "a. x", never "e.g."
    if i == 0 && a.len() > 3 && a[0].is_ascii_alphabetic() && ".)".contains(a[1]) && a[2] == ' ' {
        i = 1;
    }
    if i == 0 || i >= a.len() || !".)、".contains(a[i]) {
        return None;
    }
    let rest = trim_hspace(&a[i + 1..]);
    // 10.5, 1.2.3: a number, not a list
    match rest.chars().next() {
        Some(f) if !is_number(f) => {}
        _ => return None,
    }
    Some((
        format!("{} {}", a[..=i].iter().collect::<String>(), rest),
        false,
    ))
}

#[derive(Clone, Debug)]
struct Row {
    pieces: Vec<Piece>,
    text: String,
    cols: usize,
    x: f64,
    right: f64,
    top: f64,
    bottom: f64,
    h: f64,
    bullet: bool,
    numbered: bool,
}

impl Row {
    fn center(&self) -> f64 {
        (self.top + self.bottom) / 2.0
    }
}

/// The width of the first word of a piece (its first character for CJK), from the character boxes.
fn first_word_width(p: &Piece) -> f64 {
    let t: Vec<char> = p.text.chars().collect();
    if t.is_empty() || p.chars.len() != t.len() {
        return p.rect.h;
    }
    let mut i = 1;
    if !is_cjk(t[0]) {
        while i < t.len() && !t[i].is_whitespace() && !is_cjk(t[i]) {
            i += 1;
        }
    }
    match (p.chars[0], p.chars[i - 1]) {
        (Some(a), Some(b)) => b.max_x() - a.min_x(),
        _ => p.rect.h,
    }
}

/// Non-overlapping matches, left to right, of either alternative (what NSRegularExpression counts).
fn count_matches(a: &[char], alts: &[&dyn Fn(&[char]) -> bool], len: usize) -> usize {
    let (mut i, mut n) = (0, 0);
    while i + len <= a.len() {
        if alts.iter().any(|f| f(&a[i..i + len])) {
            n += 1;
            i += len;
        } else {
            i += 1;
        }
    }
    n
}

fn median(v: &[f64]) -> f64 {
    v[v.len() / 2]
}

fn sorted(mut v: Vec<f64>) -> Vec<f64> {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(Ordering::Equal));
    v
}

/// The Mac's layout: pieces (pixels of `ink`) → the text.
pub fn layout(input: &[Piece], ink: &Gray) -> String {
    let (w_px, h_px) = (ink.width as f64, ink.height as f64);
    if input.is_empty() {
        return String::new();
    }
    // a line's height: the median over characters of the lines the edges don't touch (short labels count less)
    let inner: Vec<&Piece> = input
        .iter()
        .filter(|p| p.rect.min_y() > 3.0 && p.rect.max_y() < h_px - 3.0)
        .collect();
    let base: Vec<&Piece> = if inner.is_empty() {
        input.iter().collect()
    } else {
        inner.clone()
    };
    let hs = sorted(
        base.iter()
            .flat_map(|p| std::iter::repeat(p.rect.h).take(p.text.chars().count().max(1)))
            .collect(),
    );
    let line_h = median(&hs);
    // a line's ink height (rows with ink in its x-span, a little above and below its box): what an edge cut
    // takes away, whatever box Vision guessed for the part it saw
    let ink_height = |b: &Rect, edge_top: Option<bool>| -> f64 {
        let pad = 0.3 * line_h;
        let y0 = if edge_top == Some(true) {
            0
        } else {
            0.max((b.min_y() - pad) as i64)
        };
        let y1 = if edge_top == Some(false) {
            ink.height as i64
        } else {
            (ink.height as i64).min((b.max_y() + pad) as i64)
        };
        let rows: Vec<i64> = (y0..y0.max(y1))
            .filter(|&y| ink.row(y, b.min_x(), b.max_x()) > 0.01)
            .collect();
        match (rows.first(), rows.last()) {
            (Some(f), Some(l)) => (l - f + 1) as f64,
            _ => 0.0,
        }
    };
    let full_ink: Option<f64> = {
        let h = sorted(
            inner
                .iter()
                .map(|p| ink_height(&p.rect, None))
                .filter(|&h| h > 0.0)
                .collect(),
        );
        if h.is_empty() {
            None
        } else {
            Some(median(&h))
        }
    };

    let mut kept: Vec<Piece> = Vec::new();
    for p in input {
        let b = p.rect;
        // 1. cut by the top or bottom edge
        // near an edge (Vision's box may stop short of it) with glyphs on the edge row
        let top_cut = b.min_y() <= 0.5 * line_h && ink.row(0, b.min_x(), b.max_x()) > 0.02;
        let bottom_cut = b.max_y() >= h_px - 0.5 * line_h
            && ink.row(ink.height as i64 - 1, b.min_x(), b.max_x()) > 0.02;
        if top_cut || bottom_cut {
            if let Some(full) = full_ink {
                if ink_height(&b, Some(top_cut)) < 0.9 * full {
                    continue;
                }
            } else if b.h < 0.9 * line_h {
                continue;
            }
        }
        // 2. a character cut by the left or right edge
        let mut t: Vec<char> = p.text.chars().collect();
        let mut ch = p.chars.clone();
        if ch.len() == t.len() && !t.is_empty() {
            let narrow = |t: &[char], ch: &[Option<Rect>], i: usize| -> bool {
                let same = sorted(
                    t.iter()
                        .zip(ch)
                        .filter_map(|(a, c)| c.filter(|_| is_cjk(*a) == is_cjk(t[i])).map(|r| r.w))
                        .collect(),
                );
                match ch[i] {
                    Some(c) if same.len() >= 3 => c.w < 0.8 * median(&same),
                    _ => true,
                }
            };
            if let Some(c) = ch[0] {
                if c.min_x() <= 6.0
                    && ink.column(0, b.min_y(), b.max_y()) > 0.02
                    && narrow(&t, &ch, 0)
                {
                    t.remove(0);
                    ch.remove(0);
                }
            }
            if let Some(Some(c)) = ch.last().copied() {
                if !t.is_empty()
                    && c.max_x() >= w_px - 6.0
                    && ink.column(ink.width as i64 - 1, b.min_y(), b.max_y()) > 0.02
                    && narrow(&t, &ch, t.len() - 1)
                {
                    t.pop();
                    ch.pop();
                }
            }
        }
        let lead = t.iter().take_while(|c| c.is_whitespace()).count();
        let trail = t.iter().rev().take_while(|c| c.is_whitespace()).count();
        if t.len() as i64 - lead as i64 - trail as i64 <= 0 {
            continue;
        }
        let core: String = t[lead..t.len() - trail].iter().collect();
        let core_chars = if ch.len() == t.len() {
            ch[lead..t.len() - trail].to_vec()
        } else {
            Vec::new()
        };
        kept.push(Piece {
            text: core,
            rect: b,
            chars: core_chars,
        });
    }
    if kept.is_empty() {
        return String::new();
    }

    // 3. CJK ↔ Latin spacing as the capture itself writes it
    let all: Vec<char> = kept
        .iter()
        .map(|p| p.text.as_str())
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .collect();
    let latin = |c: char| c.is_ascii_alphanumeric() || c == '/';
    let spaced = count_matches(
        &all,
        &[
            &|s: &[char]| is_han(s[0]) && s[1] == ' ' && latin(s[2]),
            &|s: &[char]| s[0].is_ascii_alphanumeric() && s[1] == ' ' && is_han(s[2]),
        ],
        3,
    );
    let tight = count_matches(
        &all,
        &[
            &|s: &[char]| is_han(s[0]) && latin(s[1]),
            &|s: &[char]| s[0].is_ascii_alphanumeric() && is_han(s[1]),
        ],
        2,
    );
    let cjk_space = spaced >= tight;

    // 4. rows
    kept.sort_by(|a, b| {
        (a.rect.mid_y(), a.rect.min_x())
            .partial_cmp(&(b.rect.mid_y(), b.rect.min_x()))
            .unwrap_or(Ordering::Equal)
    });
    let mut rows: Vec<Row> = Vec::new();
    for p in kept {
        if let Some(last) = rows.last_mut() {
            if (p.rect.mid_y() - last.center()).abs() < 0.5 * p.rect.h.min(last.h) {
                last.pieces.push(p);
                continue;
            }
        }
        let r = p.rect;
        rows.push(Row {
            pieces: vec![p],
            text: String::new(),
            cols: 1,
            x: 0.0,
            right: 0.0,
            top: r.min_y(),
            bottom: r.max_y(),
            h: r.h,
            bullet: false,
            numbered: false,
        });
    }
    for r in rows.iter_mut() {
        r.pieces.sort_by(|a, b| {
            a.rect
                .min_x()
                .partial_cmp(&b.rect.min_x())
                .unwrap_or(Ordering::Equal)
        });
        r.top = r
            .pieces
            .iter()
            .map(|p| p.rect.min_y())
            .fold(f64::INFINITY, f64::min);
        r.bottom = r
            .pieces
            .iter()
            .map(|p| p.rect.max_y())
            .fold(f64::NEG_INFINITY, f64::max);
        r.h = r
            .pieces
            .iter()
            .map(|p| p.rect.h)
            .fold(f64::NEG_INFINITY, f64::max);
        let mut s = r.pieces[0].text.clone();
        for (a, b) in r.pieces.iter().zip(r.pieces.iter().skip(1)) {
            if b.rect.min_x() - a.rect.max_x() > 0.9 * r.h {
                s.push('\t');
                s.push_str(&b.text);
                r.cols += 1;
            } else {
                let j = joiner(&s, &b.text, cjk_space);
                s.push_str(j);
                s.push_str(&b.text);
            }
        }
        r.x = r.pieces[0].rect.min_x();
        r.right = r.pieces.last().unwrap().rect.max_x();
        if r.cols == 1 {
            if let Some((t, bullet)) = marker(&s) {
                s = t;
                r.bullet = bullet;
                r.numbered = !bullet;
            }
        }
        r.text = s;
    }

    // 5. blocks
    let mut blocks: Vec<Vec<Row>> = vec![vec![rows[0].clone()]];
    for (p, r) in rows.iter().zip(rows.iter().skip(1)) {
        let table_row = p.cols > 1 && r.cols == p.cols;
        if r.top - p.bottom > 0.9 * p.h.max(r.h) && !table_row {
            blocks.push(vec![r.clone()]);
        } else {
            blocks.last_mut().unwrap().push(r.clone());
        }
    }
    let right = rows
        .iter()
        .map(|r| r.right)
        .fold(f64::NEG_INFINITY, f64::max);
    let mut out: Vec<String> = Vec::new();
    for b in &blocks {
        if b.iter().filter(|r| r.cols > 1).count() >= 2 {
            out.push(
                b.iter()
                    .map(|r| r.text.as_str())
                    .collect::<Vec<_>>()
                    .join("\n"),
            );
            continue;
        }
        let wrapped: Vec<bool> = b
            .iter()
            .zip(b.iter().skip(1))
            .map(|(p, r)| p.right + first_word_width(&r.pieces[0]) + 0.3 * p.h >= right)
            .collect();
        let xs: Vec<f64> = b.iter().map(|r| r.x).collect();
        let min_x = xs.iter().copied().fold(f64::INFINITY, f64::min);
        let max_x = xs.iter().copied().fold(f64::NEG_INFINITY, f64::max);
        // a list is never preformatted (its items are new rows, not unwrapped ones; Vision may miss one marker)
        let list = b.iter().any(|r| r.bullet || r.numbered);
        let varied = max_x - min_x > 1.2 * line_h;
        let n_wrapped = wrapped.iter().filter(|w| **w).count();
        let pre = !list
            && b.len() >= 2
            && (varied || (b.len() >= 3 && (n_wrapped as f64) < 0.5 * wrapped.len() as f64));
        if pre {
            let widths = sorted(b.iter().map(|r| r.right - r.x).collect());
            let counts = sorted(b.iter().map(|r| r.text.chars().count() as f64).collect());
            let pitch = median(&widths) / median(&counts).max(1.0);
            let ls: Vec<String> = b
                .iter()
                .map(|r| {
                    " ".repeat((((r.x - min_x) / pitch).round() as i64).max(0) as usize) + &r.text
                })
                .collect();
            out.push(ls.join("\n"));
            continue;
        }
        let bullet_x = b.iter().filter(|r| r.bullet).map(|r| r.x).reduce(f64::min);
        let mut lines: Vec<String> = Vec::new();
        for (i, r) in b.iter().enumerate() {
            let mut t = r.text.clone();
            if let Some(bx) = bullet_x {
                if r.bullet && r.x > bx + 0.8 * r.h {
                    t = format!("  {t}");
                }
            }
            match lines.last_mut() {
                Some(last)
                    if i > 0 && !r.bullet && !r.numbered && wrapped[i - 1] && r.cols == 1 =>
                {
                    let j = joiner(last, &t, cjk_space);
                    last.push_str(j);
                    last.push_str(&t);
                }
                _ => lines.push(t),
            }
        }
        out.push(fill_missing_numbers(&lines).join("\n"));
    }
    ascii_punctuation(&out.join("\n\n"))
}

/// An item between "1." and "3." with no number of its own: Vision missed its "2." (a small marker in a low-resolution
/// capture); it gets it back. Only a gap of exactly one, so a paragraph between two items is never numbered.
fn fill_missing_numbers(lines: &[String]) -> Vec<String> {
    fn number(s: &str) -> Option<i64> {
        let d: String = s.chars().take_while(|c| c.is_ascii_digit()).collect();
        if d.is_empty() || !s[d.len()..].starts_with(". ") {
            return None;
        }
        d.parse().ok()
    }
    let mut out = lines.to_vec();
    for i in 1..lines.len().saturating_sub(1) {
        if number(&lines[i]).is_none() && marker(&lines[i]).is_none() {
            if let (Some(a), Some(c)) = (number(&lines[i - 1]), number(&lines[i + 1])) {
                if c == a + 2 {
                    out[i] = format!("{}. {}", a + 1, lines[i]);
                }
            }
        }
    }
    out
}

/// Full-width punctuation with no CJK character on either side (spaces skipped) → its ASCII form.
fn ascii_punctuation(s: &str) -> String {
    const FW: &str = "（）［］｛｝：；，！？＂＇";
    let mut a: Vec<char> = s.chars().collect();
    let ok = |a: &[char], i: usize, step: i64| -> bool {
        let mut j = i as i64 + step;
        while j >= 0 && (j as usize) < a.len() && (a[j as usize] == ' ' || a[j as usize] == '\t') {
            j += step;
        }
        j < 0
            || j as usize >= a.len()
            || a[j as usize] == '\n'
            || !is_cjk(a[j as usize])
            || FW.contains(a[j as usize])
    };
    // ("？sort=price": a space before it and ASCII right after — a query string, not a Chinese question)
    let spaced_before_ascii = |a: &[char], i: usize| {
        i > 0
            && a[i - 1] == ' '
            && i + 1 < a.len()
            && a[i + 1].is_ascii()
            && !a[i + 1].is_whitespace()
    };
    for i in 0..a.len() {
        if FW.contains(a[i]) && ((ok(&a, i, -1) && ok(&a, i, 1)) || spaced_before_ascii(&a, i)) {
            if let Some(c) = char::from_u32(a[i] as u32 - 0xFEE0) {
                a[i] = c;
            }
        }
    }
    a.into_iter().collect()
}

// Ported from skills/blurt/recorder/macos/Tests/BlurtCoreTests/ScreenTextTests.swift. The fixture
// (tests/fixtures/screen_text: page.html drawn at 2× by Chrome, cropped the way Bob's ⌥C demo was dragged — half
// lines, half characters, wrapped list items, check icons, a path broken at hyphens — plus code, a terminal, an
// English paragraph, a table and a nested list) runs through Vision on the Mac. There is no OCR here, so the Mac's
// Vision readings are recorded in vision.jsonl (normalized, bottom-left origin, as Vision gives them, with the Mac's
// layout of each) and turned into what Windows gives: pixels, top-left origin, a word per CJK character, a box per
// word.
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::path::PathBuf;

    fn fixtures() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../tests/fixtures/screen_text")
    }

    fn jsonl(name: &str) -> Vec<Value> {
        std::fs::read_to_string(fixtures().join(name))
            .unwrap()
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    }

    /// One recorded Vision reading (vision.jsonl) and the picture it was read from.
    struct Reading {
        rec: Value,
        gray: Gray,
    }

    fn reading(name: &str) -> Reading {
        let rec = jsonl("vision.jsonl")
            .into_iter()
            .find(|r| r["name"] == name)
            .expect(name);
        let gray = image(name);
        assert_eq!(
            (gray.width as u64, gray.height as u64),
            (
                rec["width"].as_u64().unwrap(),
                rec["height"].as_u64().unwrap()
            )
        );
        Reading { rec, gray }
    }

    /// Vision's normalized, bottom-left-origin box → pixels, top-left origin (ScreenText.read's `px`).
    fn vision_px(v: &Value, w: f64, h: f64) -> Rect {
        let f = |i: usize| v[i].as_f64().unwrap();
        let (x, y, bw, bh) = (f(0), f(1), f(2), f(3));
        Rect::new(x * w, (1.0 - (y + bh)) * h, bw * w, bh * h)
    }

    /// The Mac's model: Vision's lines with a box per character.
    fn mac_pieces(r: &Reading) -> Vec<Piece> {
        let (w, h) = (r.gray.width as f64, r.gray.height as f64);
        r.rec["observations"]
            .as_array()
            .unwrap()
            .iter()
            .map(|o| Piece {
                text: o["text"].as_str().unwrap().to_string(),
                rect: vision_px(&o["box"], w, h),
                chars: o["chars"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|c| (!c.is_null()).then(|| vision_px(c, w, h)))
                    .collect(),
            })
            .collect()
    }

    /// The same reading as Windows gives it: a word per CJK character or per run of other characters between spaces,
    /// its box the union of its characters' boxes narrowed to their ink (Vision's character boxes tile the line, spaces
    /// included; Windows boxes a word's glyphs, so the space between two words is a gap).
    fn windows_lines(r: &Reading) -> Vec<Line> {
        let g = &r.gray;
        mac_pieces(r)
            .iter()
            .map(|p| {
                let t: Vec<char> = p.text.chars().collect();
                let n = t.len();
                let mut spans: Vec<(usize, usize)> = Vec::new();
                let mut start: Option<usize> = None;
                for (i, c) in t.iter().enumerate() {
                    if c.is_whitespace() || is_cjk(*c) {
                        if let Some(s) = start.take() {
                            spans.push((s, i));
                        }
                        if is_cjk(*c) {
                            spans.push((i, i + 1));
                        }
                    } else if start.is_none() {
                        start = Some(i);
                    }
                }
                if let Some(s) = start {
                    spans.push((s, n));
                }
                let words = spans
                    .into_iter()
                    .map(|(a, b)| {
                        let boxes: Vec<Rect> = if p.chars.len() == n {
                            p.chars[a..b].iter().flatten().copied().collect()
                        } else {
                            vec![]
                        };
                        let rect =
                            boxes
                                .into_iter()
                                .reduce(|x, y| x.union(&y))
                                .unwrap_or_else(|| {
                                    let cw = p.rect.w / n as f64;
                                    Rect::new(
                                        p.rect.x + cw * a as f64,
                                        p.rect.y,
                                        cw * (b - a) as f64,
                                        p.rect.h,
                                    )
                                });
                        Word {
                            text: t[a..b].iter().collect(),
                            rect: ink_narrowed(g, rect),
                        }
                    })
                    .collect();
                Line::new(words)
            })
            .collect()
    }

    fn ink_narrowed(g: &Gray, r: Rect) -> Rect {
        let (y0, y1) = (
            r.min_y().max(0.0) as usize,
            (r.max_y().ceil() as usize).min(g.height),
        );
        let (x0, x1) = (
            r.min_x().max(0.0) as usize,
            (r.max_x().ceil() as usize).min(g.width),
        );
        let cols: Vec<usize> = (x0..x1)
            .filter(|&x| (y0..y1).any(|y| g.ink(x, y)))
            .collect();
        match (cols.first(), cols.last()) {
            (Some(&a), Some(&b)) => Rect::new(a as f64, r.y, (b + 1 - a) as f64, r.h),
            _ => r,
        }
    }

    fn windows_text(name: &str) -> String {
        let r = reading(name);
        compose(&windows_lines(&r), &r.gray).text
    }

    /// NFKC as far as these texts need it: full-width ASCII, the ideographic and no-break spaces, the ellipsis.
    fn nfkc(s: &str) -> String {
        s.chars()
            .flat_map(|c| match c as u32 {
                0xFF01..=0xFF5E => vec![char::from_u32(c as u32 - 0xFEE0).unwrap()],
                0x3000 | 0xA0 => vec![' '],
                0x2026 => vec!['.', '.', '.'],
                _ => vec![c],
            })
            .collect()
    }

    /// Content: NFKC, bullets as one mark, no whitespace — what was read, not how it was spaced.
    fn content(s: &str) -> Vec<char> {
        let n = nfkc(s);
        let lines: Vec<String> = n
            .split('\n')
            .filter(|l| !l.is_empty())
            .map(|l| {
                let t: Vec<char> = trim_hspace(&l.chars().collect::<Vec<_>>())
                    .chars()
                    .collect();
                // OCR's list marks, text data, not icons
                if t.len() >= 2 && "-•◦○◎。·▪●*".contains(t[0]) && t[1] == ' ' { // glyph-ok
                    return format!("-{}", t[2..].iter().collect::<String>());
                }
                t.into_iter().collect()
            })
            .collect();
        lines
            .concat()
            .chars()
            .filter(|c| !c.is_whitespace())
            .collect()
    }

    fn distance(a: &[char], b: &[char]) -> usize {
        if a.is_empty() {
            return b.len();
        }
        let mut prev: Vec<usize> = (0..=b.len()).collect();
        for (i, ca) in a.iter().enumerate() {
            let mut cur = vec![i + 1];
            for (j, cb) in b.iter().enumerate() {
                cur.push(
                    (prev[j + 1] + 1)
                        .min(cur[j] + 1)
                        .min(prev[j] + usize::from(ca != cb)),
                );
            }
            prev = cur;
        }
        prev[b.len()]
    }

    fn lines(s: &str) -> Vec<String> {
        s.split('\n')
            .map(|l| trim_hspace(&l.chars().collect::<Vec<_>>()))
            .filter(|l| !l.is_empty())
            .collect()
    }

    #[test]
    fn fixture_against_bobs_behaviour() {
        let rows = jsonl("cases.jsonl");
        assert!(rows.len() >= 17);
        let (mut bob_err, mut our_err, mut bob_layout, mut our_layout) = (0.0, 0.0, 0, 0);
        for row in &rows {
            let (name, exp) = (
                row["name"].as_str().unwrap(),
                row["expected"].as_str().unwrap(),
            );
            let r = reading(name);
            let text = compose(&windows_lines(&r), &r.gray).text;
            // Vision's lines as they come: what Bob pastes
            let bob = mac_pieces(&r)
                .iter()
                .map(|p| p.text.as_str())
                .collect::<Vec<_>>()
                .join("\n");
            let e = content(exp);
            let ob = distance(&content(&bob), &e) as f64 / e.len() as f64;
            let oo = distance(&content(&text), &e) as f64 / e.len() as f64;
            bob_err += ob;
            our_err += oo;
            if lines(&bob).len() == lines(exp).len() {
                bob_layout += 1;
            }
            if lines(&text).len() == lines(exp).len() {
                our_layout += 1;
            } else {
                println!("layout {name}:\n{text}\n---");
            }
            assert!(oo <= ob.max(0.06), "{name}: {text}");
        }
        let n = rows.len() as f64;
        println!(
            "screen text: Vision lines {:.1} % wrong, {}/{} laid out; ScreenText {:.1} %, {}/{}",
            100.0 * bob_err / n,
            bob_layout,
            rows.len(),
            100.0 * our_err / n,
            our_layout,
            rows.len()
        );
        assert!(our_err / n < 0.02);
        assert!(our_layout >= rows.len() - 2);
    }

    /// Not on the Mac: the port on the Mac's own input (Vision's lines and character boxes) gives the Mac's text,
    /// fixture by fixture (the `layout` recorded next to each reading).
    #[test]
    fn same_text_as_the_mac_on_the_same_reading() {
        for rec in jsonl("vision.jsonl") {
            let name = rec["name"].as_str().unwrap();
            let r = reading(name);
            assert_eq!(
                layout(&mac_pieces(&r), &r.gray),
                rec["layout"].as_str().unwrap(),
                "{name}"
            );
        }
    }

    #[test]
    fn edge_cuts() {
        // the half line at the top (Vision reads it as 网关数掂米果…) and half 生 / 状 at the sides are left out
        assert_eq!(
            windows_text("both_halfcut"),
            "/telemetry，不要落 Nginx 日志；数据库一路先直接读只读实例的表，不解析 binlog。"
        );
        assert_eq!(windows_text("half_chars"), "产库现");
        // a check icon list: "- " for the ◎ / • Vision reads
        assert_eq!(
            windows_text("checks"),
            "- 整理结论成 Markdown 文件\n- 发送文件给用户"
        );
    }

    #[test]
    fn markers() {
        let t = |s: &str| marker(s).map(|m| m.0);
        assert_eq!(t("2.ordo_ai 的做法").as_deref(), Some("2. ordo_ai 的做法"));
        assert_eq!(t("◎ 发送文件给用户").as_deref(), Some("- 发送文件给用户")); // glyph-ok: text data (OCR marks, emoji in a field), not an icon
        assert_eq!(t("10.5 GB resident"), None);
        assert_eq!(t("e.g. this"), None);
        assert_eq!(t("a. first").as_deref(), Some("a. first"));
    }

    #[test]
    fn joiner_and_punctuation() {
        assert_eq!(joiner("现有的", "/telemetry", true), " ");
        assert_eq!(joiner("a700-", "ecea", true), "");
        assert_eq!(joiner("只读实", "例，", true), "");
        assert_eq!(joiner("If we", "keep", false), " ");
        assert_eq!(
            ascii_punctuation("job （etl_nightly_v2） can"),
            "job (etl_nightly_v2) can"
        );
        assert_eq!(
            ascii_punctuation("不需要 DTS；但前端"),
            "不需要 DTS；但前端"
        );
        assert_eq!(
            ascii_punctuation("test_read_only.py：：test_lag"),
            "test_read_only.py::test_lag"
        );
    }

    #[test]
    fn missing_list_number() {
        let v = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            fill_missing_numbers(&v(&["1. a", "ordo_ai 的做法", "3. c"])),
            v(&["1. a", "2. ordo_ai 的做法", "3. c"])
        );
        assert_eq!(
            fill_missing_numbers(&v(&["1. a", "note", "more", "2. c"])),
            v(&["1. a", "note", "more", "2. c"])
        );
    }

    /// Found making the site demo (2026-10-29): a bullet Vision read with no space after it, a query string's "？".
    #[test]
    fn solid_bullet_without_space_and_query_question_mark() {
        assert_eq!(
            marker("•日志已经附在工单里").map(|m| m.0).as_deref(),
            Some("- 日志已经附在工单里")
        );
        assert_eq!(marker("-1 是默认值"), None);
        assert_eq!(marker("·分隔"), None);
        assert_eq!(
            ascii_punctuation("搜索页不认 ？sort=price"),
            "搜索页不认 ?sort=price"
        );
        assert_eq!(ascii_punctuation("你好？我在"), "你好？我在");
    }

    /// The bottom line cut in half (Vision's box for it stops short of the edge): left out.
    #[test]
    fn bottom_half_line_left_out() {
        let t = windows_text("en_bottom_cut");
        assert!(t.ends_with("- One owner for each item"), "{t}");
    }

    /// Not on the Mac: Windows' words spelled back into a line.
    #[test]
    fn words_joined() {
        let w = |t: &str, x: f64, w: f64| Word {
            text: t.into(),
            rect: Rect::new(x, 0.0, w, 40.0),
        };
        // two CJK characters, CJK and its punctuation: no space; Latin words: a space
        assert_eq!(
            join_words(&Line::new(vec![
                w("只", 0.0, 30.0),
                w("读", 32.0, 30.0),
                w("，", 64.0, 10.0)
            ])),
            "只读，"
        );
        assert_eq!(
            join_words(&Line::new(vec![w("If", 0.0, 20.0), w("we", 22.0, 30.0)])),
            "If we"
        );
        // CJK and Latin: a space only where the capture shows one
        assert_eq!(
            join_words(&Line::new(vec![
                w("落", 0.0, 30.0),
                w("Nginx", 42.0, 80.0),
                w("日", 134.0, 30.0)
            ])),
            "落 Nginx 日"
        );
        assert_eq!(
            join_words(&Line::new(vec![
                w("落", 0.0, 30.0),
                w("Nginx", 32.0, 80.0),
                w("日", 114.0, 30.0)
            ])),
            "落Nginx日"
        );
        // a gap wider than the line's height is a column: two pieces, one tab between them
        let row = Line::new(vec![
            w("方", 0.0, 30.0),
            w("案", 32.0, 30.0),
            w("成", 200.0, 30.0),
            w("本", 232.0, 30.0),
        ]);
        assert_eq!(
            pieces(&row)
                .iter()
                .map(|p| p.text.as_str())
                .collect::<Vec<_>>(),
            ["方案", "成本"]
        );
        let g = Gray::new(300, 40, vec![255; 300 * 40]).unwrap();
        assert_eq!(
            compose(&[row], &g),
            Composed {
                text: "方案\t成本".into(),
                line_count: 1
            }
        );
    }

    // MARK: - PNG (the fixtures), std only

    fn image(name: &str) -> Gray {
        let d = std::fs::read(fixtures().join(format!("{name}.png"))).unwrap();
        let (w, h, ch, px) = png(&d);
        let g: Vec<u8> = px
            .chunks_exact(ch)
            .map(|p| match ch {
                1 => p[0],
                2 => over_white(p[0], p[1]),
                3 => luma(p[0], p[1], p[2]),
                _ => over_white(luma(p[0], p[1], p[2]), p[3]),
            })
            .collect();
        Gray::new(w, h, g).unwrap()
    }

    /// 8-bit, non-interlaced PNG → (width, height, channels, pixels).
    fn png(d: &[u8]) -> (usize, usize, usize, Vec<u8>) {
        assert_eq!(&d[..8], b"\x89PNG\r\n\x1a\n");
        let (mut i, mut idat, mut hdr) = (8, Vec::new(), (0, 0, 0));
        while i + 8 <= d.len() {
            let len = u32::from_be_bytes(d[i..i + 4].try_into().unwrap()) as usize;
            let (kind, body) = (&d[i + 4..i + 8], &d[i + 8..i + 8 + len]);
            match kind {
                b"IHDR" => {
                    let be =
                        |k: usize| u32::from_be_bytes(body[k..k + 4].try_into().unwrap()) as usize;
                    assert_eq!((body[8], body[12]), (8, 0), "8-bit, not interlaced");
                    hdr = (be(0), be(4), [1, 0, 3, 0, 2, 0, 4][body[9] as usize]);
                }
                b"IDAT" => idat.extend_from_slice(body),
                b"IEND" => break,
                _ => {}
            }
            i += 12 + len;
        }
        let (w, h, ch) = hdr;
        assert!(ch > 0, "palette PNGs are not supported");
        let raw = inflate(&idat[2..]);
        let stride = w * ch;
        let mut px = vec![0u8; stride * h];
        for y in 0..h {
            let f = raw[y * (stride + 1)];
            let src = &raw[y * (stride + 1) + 1..(y + 1) * (stride + 1)];
            for x in 0..stride {
                let a = if x >= ch {
                    px[y * stride + x - ch] as i32
                } else {
                    0
                };
                let b = if y > 0 {
                    px[(y - 1) * stride + x] as i32
                } else {
                    0
                };
                let c = if x >= ch && y > 0 {
                    px[(y - 1) * stride + x - ch] as i32
                } else {
                    0
                };
                let pred = match f {
                    0 => 0,
                    1 => a,
                    2 => b,
                    3 => (a + b) / 2,
                    4 => {
                        let p = a + b - c;
                        let (pa, pb, pc) = ((p - a).abs(), (p - b).abs(), (p - c).abs());
                        if pa <= pb && pa <= pc {
                            a
                        } else if pb <= pc {
                            b
                        } else {
                            c
                        }
                    }
                    _ => panic!("filter {f}"),
                };
                px[y * stride + x] = (src[x] as i32 + pred) as u8;
            }
        }
        (w, h, ch, px)
    }

    struct Bits<'a> {
        d: &'a [u8],
        pos: usize,
        buf: u32,
        n: u32,
    }

    impl Bits<'_> {
        fn get(&mut self, k: u32) -> u32 {
            while self.n < k {
                self.buf |= (self.d[self.pos] as u32) << self.n;
                self.pos += 1;
                self.n += 8;
            }
            let v = self.buf & ((1u32 << k) - 1);
            self.buf = if k == 32 { 0 } else { self.buf >> k };
            self.n -= k;
            v
        }
    }

    struct Huff {
        count: [u16; 16],
        sym: Vec<u16>,
    }

    impl Huff {
        fn new(lens: &[u8]) -> Huff {
            let mut count = [0u16; 16];
            for &l in lens {
                count[l as usize] += 1;
            }
            count[0] = 0;
            let mut offs = [0u16; 16];
            for l in 1..16 {
                offs[l] = offs[l - 1] + count[l - 1];
            }
            let mut sym = vec![0u16; lens.len()];
            for (s, &l) in lens.iter().enumerate() {
                if l != 0 {
                    sym[offs[l as usize] as usize] = s as u16;
                    offs[l as usize] += 1;
                }
            }
            Huff { count, sym }
        }

        fn decode(&self, b: &mut Bits) -> usize {
            let (mut code, mut first, mut index) = (0i32, 0i32, 0i32);
            for len in 1..16 {
                code |= b.get(1) as i32;
                let count = self.count[len] as i32;
                if code - count < first {
                    return self.sym[(index + code - first) as usize] as usize;
                }
                index += count;
                first = (first + count) << 1;
                code <<= 1;
            }
            panic!("bad Huffman code")
        }
    }

    /// Raw DEFLATE (RFC 1951).
    fn inflate(d: &[u8]) -> Vec<u8> {
        const LBASE: [usize; 29] = [
            3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99,
            115, 131, 163, 195, 227, 258,
        ];
        const LEXT: [u32; 29] = [
            0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
        ];
        const DBASE: [usize; 30] = [
            1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025,
            1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
        ];
        const DEXT: [u32; 30] = [
            0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12,
            12, 13, 13,
        ];
        let mut b = Bits {
            d,
            pos: 0,
            buf: 0,
            n: 0,
        };
        let mut out: Vec<u8> = Vec::new();
        loop {
            let last = b.get(1);
            match b.get(2) {
                0 => {
                    b.buf = 0;
                    b.n = 0;
                    let len = u16::from_le_bytes([d[b.pos], d[b.pos + 1]]) as usize;
                    out.extend_from_slice(&d[b.pos + 4..b.pos + 4 + len]);
                    b.pos += 4 + len;
                }
                kind => {
                    let (lit, dist) = if kind == 1 {
                        let mut l = [8u8; 288];
                        l[144..256].fill(9);
                        l[256..280].fill(7);
                        (Huff::new(&l), Huff::new(&[5u8; 30]))
                    } else {
                        let (nlen, ndist, ncode) = (
                            b.get(5) as usize + 257,
                            b.get(5) as usize + 1,
                            b.get(4) as usize + 4,
                        );
                        const ORDER: [usize; 19] = [
                            16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
                        ];
                        let mut cl = [0u8; 19];
                        for &o in &ORDER[..ncode] {
                            cl[o] = b.get(3) as u8;
                        }
                        let ch = Huff::new(&cl);
                        let mut lens: Vec<u8> = Vec::new();
                        while lens.len() < nlen + ndist {
                            let s = ch.decode(&mut b);
                            let (v, rep) = match s {
                                0..=15 => (s as u8, 1),
                                16 => (*lens.last().unwrap(), 3 + b.get(2) as usize),
                                17 => (0, 3 + b.get(3) as usize),
                                _ => (0, 11 + b.get(7) as usize),
                            };
                            lens.extend(std::iter::repeat(v).take(rep));
                        }
                        (Huff::new(&lens[..nlen]), Huff::new(&lens[nlen..]))
                    };
                    loop {
                        let s = lit.decode(&mut b);
                        if s < 256 {
                            out.push(s as u8);
                        } else if s == 256 {
                            break;
                        } else {
                            let len = LBASE[s - 257] + b.get(LEXT[s - 257]) as usize;
                            let ds = dist.decode(&mut b);
                            let back = DBASE[ds] + b.get(DEXT[ds]) as usize;
                            let start = out.len() - back;
                            for k in 0..len {
                                out.push(out[start + k]);
                            }
                        }
                    }
                }
            }
            if last == 1 {
                break;
            }
        }
        out
    }
}
