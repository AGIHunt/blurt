//! Copy Text from Screen on Windows / Linux (the Mac's ScreenText + ScreenTextCopy; docs/design/screen-text.md):
//! `rules` is the Mac's geometry, ported; `ocr_win` reads the screen; `flow` is the key's whole path.

pub mod rules;

#[cfg(windows)]
pub mod flow;
#[cfg(windows)]
pub mod ocr_win;

#[cfg(windows)]
pub use flow::start;

/// A line read whole (RapidOCR: its text and box) as the rules' words: split at its spaces, each word's box its share
/// of the line by characters — a space keeps its width, so the rules see the gap and put the space back.
pub fn line_from_text(text: &str, r: rules::Rect) -> rules::Line {
    let chars: Vec<char> = text.chars().collect();
    let n = chars.len().max(1) as f64;
    let cw = r.w / n;
    let mut words = vec![];
    let mut i = 0;
    while i < chars.len() {
        if chars[i].is_whitespace() {
            i += 1;
            continue;
        }
        let start = i;
        while i < chars.len() && !chars[i].is_whitespace() {
            i += 1;
        }
        words.push(rules::Word {
            text: chars[start..i].iter().collect(),
            rect: rules::Rect::new(r.x + cw * start as f64, r.y, cw * (i - start) as f64, r.h),
        });
    }
    rules::Line::new(words)
}

/// Windows' OCR words → the rules' lines → text (the grab gives the ink the edge rules look at).
#[cfg(windows)]
pub fn compose(lines: &[Vec<ocr_win::Word>], grab: &ocr_win::Grab) -> String {
    let ls: Vec<rules::Line> = lines
        .iter()
        .map(|ws| {
            rules::Line::new(
                ws.iter()
                    .map(|w| rules::Word {
                        text: w.text.clone(),
                        rect: rules::Rect::new(w.x, w.y, w.w, w.h),
                    })
                    .collect(),
            )
        })
        .collect();
    compose_lines(ls, grab)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Three lines as RapidOCR reads them off Notepad (2026-11-02, the VM), on a blank page with ink where the text is.
    #[test]
    fn rapid_lines() {
        let (w, h) = (597usize, 72usize);
        let read = [
            (
                "登录页面周五之前要上线，记得把按钮颜色改深一点。",
                [1.0, 6.0, 371.0, 17.0],
            ),
            (
                "The export to CsV fails when the file name has spaces.",
                [0.0, 26.0, 417.0, 19.0],
            ),
            (
                "用 ClaudeCode 跑一下测试，然后提交 PR。",
                [0.0, 48.0, 315.0, 17.0],
            ),
        ];
        let mut px = vec![255u8; w * h];
        for (_, b) in &read {
            for y in (b[1] as usize + 3)..(b[1] + b[3]) as usize - 3 {
                for x in (b[0] as usize + 1)..(b[0] + b[2]) as usize - 1 {
                    if x % 3 != 0 {
                        px[y * w + x] = 0;
                    }
                }
            }
        }
        let g = rules::Gray::new(w, h, px).unwrap();
        let lines: Vec<rules::Line> = read
            .iter()
            .map(|(t, b)| line_from_text(t, rules::Rect::new(b[0], b[1], b[2], b[3])))
            .collect();
        let out = rules::compose(&lines, &g).text;
        // the spaces come back from the gaps; the third line joins the second as the Mac's reflow test has it (the
        // longest line is taken as the wrap width, and the next line's first word wouldn't have fitted after it)
        assert_eq!(out, "登录页面周五之前要上线，记得把按钮颜色改深一点。\nThe export to CsV fails when the file name has spaces. 用 ClaudeCode 跑一下测试，然后提交 PR。");
    }
}

#[cfg(windows)]
pub fn compose_lines(ls: Vec<rules::Line>, grab: &ocr_win::Grab) -> String {
    match rules::Gray::from_bgra8(
        grab.w as usize,
        grab.h as usize,
        grab.w as usize * 4,
        &grab.bgra,
    ) {
        Some(g) => rules::compose(&ls, &g).text,
        None => ls
            .iter()
            .map(rules::join_words)
            .collect::<Vec<_>>()
            .join("\n"),
    }
}
