//! Hearing again (docs/design/dictation.md §Hearing again; the Mac's DictationStream + `DictationStitch.closesWindow`):
//! a piece is 3–8 s of a sentence, and the speech model hears it without the rest of it (德宝 for 豆包, 巨幅 for GIF). So
//! the pieces are heard once more in windows of several pieces, with the windows' text so far as context, while the
//! user still talks; what is typed comes from the windows, the live text stays the pieces'.
//!
//! Windows' speech model is Fun-ASR-Nano (sherpa-onnx, int8 on the CPU): it decodes at most 512 tokens — about 25 s of
//! speech with the words list — so a window here never spans more than `cap` (20 s, `record.dictation.rehear_window_s`
//! lowers it). The Mac closes a window once it spans its length (Qwen3-ASR's 30 s windows can run past it); here a
//! window closes at a pause once it spans `cap / 2`, or — when the next piece would take it past `cap` — at the pause
//! before that piece. Never at a hard cut (no pause found within the longest piece): windows never share audio, so
//! nothing has to be dropped twice.
//!
//!   • a window of one piece is that piece: its own transcript is kept, nothing is heard again;
//!   • at key-up the open window (the pieces since the last window, the last piece in it) is what is left — the last
//!     piece is heard only there (`covered`), or alone when the window is just that piece;
//!   • a window the model fails on keeps its pieces' transcripts; a covered last piece in a failed window sends the
//!     take down the safety path (the whole recording), as a failed piece does.
//! Pure: tests below.

use std::ops::RangeInclusive;

use super::stitch;

/// The longest window (seconds): Fun-ASR-Nano's 512 tokens.
pub const CAP: f64 = 20.0;
/// No window shorter than this is configured (the Mac's floor for `rehear_window_s`).
pub const MIN_CAP: f64 = 4.0;

/// A window to hear again: pieces `first..=last`, audio `start..end` (samples).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Window {
    pub first: usize,
    pub last: usize,
    pub start: usize,
    pub end: usize,
}

impl Window {
    pub fn pieces(&self) -> RangeInclusive<usize> {
        self.first..=self.last
    }
    pub fn len(&self) -> usize {
        self.last + 1 - self.first
    }
    pub fn is_empty(&self) -> bool {
        false
    }
}

/// Where the windows close, piece by piece as they are cut.
#[derive(Clone, Debug)]
pub struct Planner {
    cap: usize,
    close_at: usize,
    /// the open window: its first piece and where its audio starts; None before the first piece
    open: Option<(usize, usize)>,
    /// the last piece seen: (index, start, end, the cut after it was hard)
    last: Option<(usize, usize, usize, bool)>,
}

impl Planner {
    /// `cap_seconds`: the longest window; `sample_rate`: of the samples the pieces are counted in.
    pub fn new(cap_seconds: f64, sample_rate: f64) -> Self {
        let cap = cap_seconds.clamp(MIN_CAP, CAP);
        Planner {
            cap: (cap * sample_rate) as usize,
            close_at: (cap / 2.0 * sample_rate) as usize,
            open: None,
            last: None,
        }
    }

    /// Piece `i` (audio `start..end`) was cut; `hard_after`: the cut that ended it was hard. → the windows that close
    /// now, oldest first (none, one, or — when this piece takes the open window past `cap` — the one before it, then
    /// perhaps this piece's own). Windows of one piece come back too: the caller keeps that piece's transcript.
    pub fn piece(&mut self, i: usize, start: usize, end: usize, hard_after: bool) -> Vec<Window> {
        let mut out = vec![];
        match self.open {
            None => self.open = Some((i, start)),
            Some((first, wstart)) => {
                // past the cap with this piece: close before it — only at a pause (the cut before this piece)
                let seam_is_pause = self.last.is_some_and(|(_, _, _, hard)| !hard);
                if end.saturating_sub(wstart) > self.cap && seam_is_pause && first < i {
                    let (pi, _, pend, _) = self.last.unwrap();
                    out.push(Window { first, last: pi, start: wstart, end: pend });
                    self.open = Some((i, start));
                }
            }
        }
        self.last = Some((i, start, end, hard_after));
        let (first, wstart) = self.open.unwrap();
        if !hard_after && end.saturating_sub(wstart) >= self.close_at {
            out.push(Window { first, last: i, start: wstart, end });
            self.open = None;
        }
        out
    }

    /// At key-up, the final piece `i` (audio `start..end`) ends the take: the open window with it (possibly just it).
    pub fn finish(&mut self, i: usize, start: usize, end: usize) -> Window {
        let w = match self.open {
            Some((first, wstart)) if first <= i && end.saturating_sub(wstart) <= self.cap => {
                Window { first, last: i, start: wstart, end }
            }
            // nothing open, or the open window and this piece together pass the cap: the piece alone (the pieces
            // before it keep their transcripts)
            _ => Window { first: i, last: i, start, end },
        };
        self.open = None;
        w
    }

    /// The open window's first piece (None: no piece since the last window closed).
    pub fn open_first(&self) -> Option<usize> {
        self.open.map(|(f, _)| f)
    }
}

/// The text a take types: the windows' text where they were heard again (and answered), the pieces' elsewhere, joined
/// with the seam rule at the pauses between them (`stitch::join_pieces`). `pieces[i]`: piece i's transcript (None: it
/// has none — the covered last piece); `windows`: the windows heard again with their answer (None: not back, or
/// failed); `pauses[i]`: the pause after piece i. None when some piece has no text of its own nor a window's.
pub fn typed(pieces: &[Option<String>], windows: &[(Window, Option<String>)], pauses: &[Option<f64>]) -> Option<String> {
    let mut units: Vec<String> = vec![];
    let mut gaps: Vec<Option<f64>> = vec![];
    let mut i = 0;
    while i < pieces.len() {
        let w = windows.iter().find(|(w, t)| w.first == i && w.len() > 1 && t.is_some());
        if let Some((w, Some(t))) = w {
            units.push(t.clone());
            gaps.push(pauses.get(w.last).copied().flatten());
            i = w.last + 1;
            continue;
        }
        units.push(pieces[i].clone()?);
        gaps.push(pauses.get(i).copied().flatten());
        i += 1;
    }
    Some(stitch::join_pieces(&units, &gaps))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SR: f64 = 1000.0; // samples are milliseconds here

    fn s(x: f64) -> usize {
        (x * SR) as usize
    }

    #[test]
    fn windows_close_at_a_pause_once_half_the_cap_is_spanned() {
        let mut p = Planner::new(20.0, SR);
        assert!(p.piece(0, s(0.0), s(4.0), false).is_empty());
        assert!(p.piece(1, s(4.0), s(8.0), false).is_empty());
        let w = p.piece(2, s(8.0), s(12.5), false);
        assert_eq!(w, vec![Window { first: 0, last: 2, start: 0, end: s(12.5) }]);
        // the next window starts with the next piece
        assert!(p.piece(3, s(12.5), s(17.0), false).is_empty());
        assert_eq!(p.open_first(), Some(3));
    }

    #[test]
    fn never_at_a_hard_cut() {
        let mut p = Planner::new(20.0, SR);
        assert!(p.piece(0, s(0.0), s(6.0), false).is_empty());
        // the cut after piece 1 is hard: the window can't close there however long
        assert!(p.piece(1, s(6.0), s(14.0), true).is_empty());
        // piece 2 starts 0.8 s back (the overlap); its pause closes the window
        let w = p.piece(2, s(13.2), s(17.0), false);
        assert_eq!(w, vec![Window { first: 0, last: 2, start: 0, end: s(17.0) }]);
    }

    #[test]
    fn a_window_never_passes_the_cap() {
        let mut p = Planner::new(20.0, SR);
        assert!(p.piece(0, s(0.0), s(5.0), false).is_empty());
        assert!(p.piece(1, s(5.0), s(9.0), false).is_empty());
        // 9 s open, then a 12 s piece: 21 s together — the window closes before it, and the long piece closes its own
        let w = p.piece(2, s(9.0), s(21.0), false);
        assert_eq!(
            w,
            vec![
                Window { first: 0, last: 1, start: 0, end: s(9.0) },
                Window { first: 2, last: 2, start: s(9.0), end: s(21.0) },
            ]
        );
        for x in &w {
            assert!(x.end - x.start <= s(20.0));
        }
    }

    #[test]
    fn the_cap_is_clamped() {
        let p = Planner::new(60.0, SR);
        assert_eq!(p.cap, s(20.0));
        let q = Planner::new(1.0, SR);
        assert_eq!(q.cap, s(4.0));
    }

    #[test]
    fn at_key_up_the_open_window_takes_the_last_piece() {
        let mut p = Planner::new(20.0, SR);
        p.piece(0, s(0.0), s(4.0), false);
        p.piece(1, s(4.0), s(8.0), false);
        assert_eq!(p.finish(2, s(8.0), s(9.5)), Window { first: 0, last: 2, start: 0, end: s(9.5) });
        // nothing open: the last piece alone
        let mut q = Planner::new(20.0, SR);
        q.piece(0, s(0.0), s(11.0), false); // closes by itself
        assert_eq!(q.finish(1, s(11.0), s(13.0)), Window { first: 1, last: 1, start: s(11.0), end: s(13.0) });
        // the open window plus a long tail would pass the cap: the tail alone
        let mut r = Planner::new(20.0, SR);
        r.piece(0, s(0.0), s(9.0), false);
        assert_eq!(r.finish(1, s(9.0), s(25.0)), Window { first: 1, last: 1, start: s(9.0), end: s(25.0) });
        // a take of one piece
        let mut t = Planner::new(20.0, SR);
        assert_eq!(t.finish(0, 0, s(2.0)), Window { first: 0, last: 0, start: 0, end: s(2.0) });
    }

    #[test]
    fn typed_text_comes_from_the_windows() {
        let w = |first, last| Window { first, last, start: 0, end: 0 };
        let pieces = vec![Some("我刚截了".to_string()), Some("巨幅".to_string()), Some("然后发给你".to_string())];
        let pauses = vec![Some(0.6), Some(0.7), None];
        // no window back yet: the pieces
        let a = typed(&pieces, &[], &pauses).unwrap();
        assert!(a.contains("巨幅"));
        // the window over 0..=1 answered: its text replaces those pieces
        let b = typed(&pieces, &[(w(0, 1), Some("我刚截了一张 GIF".to_string()))], &pauses).unwrap();
        assert!(b.contains("GIF") && !b.contains("巨幅") && b.contains("然后发给你"), "{b}");
        // a failed window keeps the pieces
        assert_eq!(typed(&pieces, &[(w(0, 1), None)], &pauses).unwrap(), a);
        // a window of one piece is that piece
        assert_eq!(typed(&pieces, &[(w(1, 1), Some("x".into()))], &pauses).unwrap(), a);
        // the covered last piece: only its window has it
        let covered = vec![Some("第一句".to_string()), None];
        assert!(typed(&covered, &[], &[Some(0.6), None]).is_none());
        assert_eq!(typed(&covered, &[(w(0, 1), Some("第一句第二句".into()))], &[Some(0.6), None]).unwrap(), "第一句第二句");
    }
}
