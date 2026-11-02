//! Where to cut a dictation while the user is still talking (docs/design/dictation.md §Streaming), so each piece is
//! transcribed and polished as soon as it is complete and only the last one is left when the key comes up. Ported from
//! the Mac's `skills/blurt/recorder/macos/Sources/BlurtCore/DictationSegmenter.swift` (tests: `DictationSegmenterTests`,
//! ported below).
//!
//!  • 20 ms frames; the room's level is the 10th percentile of the last 3 s (the mic's first 0.25 s left out; digital
//!    silence counts as −90 dBFS), rising at most 2 dB/s while someone talks, as in NoteEndpointer; a frame is speech
//!    above floor + 10 dB (and above −62 dBFS).
//!  • a cut goes in the middle of a pause of `pause` (0.5 s) once the piece is at least `min_segment` (3 s) long and has
//!    speech in it — between words, never inside one (Chinese has no spaces to find a word boundary in the text).
//!  • a piece that reaches `max_segment` (20 s) without such a pause is cut anyway, at the quietest 100 ms of its last
//!    2 s. When even that was loud (no real gap), the cut is `hard`: the next piece starts `overlap` (0.8 s) earlier, so
//!    a word under the cut is heard whole at least once, and `stitch::drop_overlap` drops the words both pieces heard.
//! Pure (samples in, cuts out): the tests feed it synthetic speech and pauses.

use std::collections::VecDeque;

/// One cut, in sample indices of the take.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cut {
    /// the piece ends here (sample index, exclusive)
    pub end: usize,
    /// the next piece starts here: `end`, or `overlap` earlier for a hard cut
    pub next_start: usize,
    /// cut without a pause: the pieces overlap and the text needs `stitch::drop_overlap`
    pub hard: bool,
}

/// A frame's level in dBFS (RMS; −120 for an empty frame): NoteEndpointer.level on the Mac.
pub fn level(frame: &[f32]) -> f32 {
    if frame.is_empty() {
        return -120.0;
    }
    let mut sum: f32 = 0.0;
    for x in frame {
        sum += x * x;
    }
    20.0 * (sum / frame.len() as f32).sqrt().max(1e-6).log10()
}

#[derive(Clone, Debug)]
pub struct DictationSegmenter {
    sample_rate: f64,
    pub pause: f64,
    pub min_segment: f64,
    pub max_segment: f64,
    pub overlap: f64,
    pub on_delta: f32,
    pub min_loud_db: f32,
    pub warmup: f64,

    piece_start: usize,
    piece_speech: usize,
    samples: usize,
    floor_db: f32,
    pauses: Vec<Option<f64>>,

    frame_length: usize,
    carry: Vec<f32>,
    /// every frame's level (dBFS): the quietest-point search looks back 2 s
    levels: Vec<f32>,
    /// ring for the floor
    history: Vec<f32>,
    history_at: usize,
    /// frames since the last speech frame
    quiet_run: usize,
    /// the last 12 frames
    recent_loud: VecDeque<bool>,
    /// 6 of them loud
    talking: bool,
    last_loud_frame: i64,
    /// the cut whose pause ends at the next speech frame
    pause_open: Option<usize>,
}

impl Default for DictationSegmenter {
    fn default() -> Self {
        DictationSegmenter::new(16000.0)
    }
}

impl DictationSegmenter {
    pub const FRAME_SECONDS: f64 = 0.02;
    /// a piece needs this much speech (0.2 s) to be worth a request
    pub const SPEECH_FRAMES_MIN: usize = 10;

    pub fn new(sample_rate: f64) -> Self {
        DictationSegmenter {
            sample_rate,
            pause: 0.5,
            min_segment: 3.0,
            max_segment: 20.0,
            overlap: 0.8,
            on_delta: 10.0,
            min_loud_db: -62.0,
            warmup: 0.25,
            piece_start: 0,
            piece_speech: 0,
            samples: 0,
            floor_db: -90.0,
            pauses: vec![],
            frame_length: ((sample_rate * Self::FRAME_SECONDS).round() as usize).max(1),
            carry: vec![],
            levels: vec![],
            history: vec![],
            history_at: 0,
            quiet_run: 0,
            recent_loud: VecDeque::new(),
            talking: false,
            last_loud_frame: -1,
            pause_open: None,
        }
    }

    pub fn sample_rate(&self) -> f64 {
        self.sample_rate
    }
    /// where the current piece starts (sample index)
    pub fn piece_start(&self) -> usize {
        self.piece_start
    }
    /// speech frames in the current piece
    pub fn piece_speech(&self) -> usize {
        self.piece_speech
    }
    /// samples fed so far
    pub fn samples(&self) -> usize {
        self.samples
    }
    pub fn floor_db(&self) -> f32 {
        self.floor_db
    }
    /// The pause at each cut: from the last speech frame before it to the first one after it (seconds), filled in once
    /// speech resumes; index k = the pause after piece k. None while not known yet; 0 for a hard cut. The stitch keeps a
    /// sentence end at a seam only after a long one.
    pub fn pauses(&self) -> &[Option<f64>] {
        &self.pauses
    }

    /// How long it has been quiet since the last speech frame (seconds): talking now is under half a second (the
    /// runaway take's watch).
    pub fn quiet_seconds(&self) -> f64 {
        Self::seconds(self.quiet_run as i64)
    }

    /// Whether the current (unfinished) piece has speech in it — the last piece at key-up, or a piece to skip.
    pub fn piece_has_speech(&self) -> bool {
        self.piece_speech >= Self::SPEECH_FRAMES_MIN
    }

    fn frames(&self) -> usize {
        self.levels.len()
    }
    fn seconds(frames: i64) -> f64 {
        frames as f64 * Self::FRAME_SECONDS
    }
    fn sample_at(&self, frame: usize) -> usize {
        frame * self.frame_length
    }

    /// Feeds mono samples (−1…1); returns the cuts they completed (usually none, at most a few).
    pub fn feed(&mut self, x: &[f32]) -> Vec<Cut> {
        let mut out = vec![];
        let fl = self.frame_length;
        let mut i = 0;
        if !self.carry.is_empty() {
            let need = fl - self.carry.len();
            if x.len() < need {
                self.carry.extend_from_slice(x);
                self.samples += x.len();
                return out;
            }
            let mut c = std::mem::take(&mut self.carry);
            c.extend_from_slice(&x[..need]);
            if let Some(cut) = self.frame(&c) {
                out.push(cut);
            }
            c.clear();
            self.carry = c;
            i = need;
        }
        while i + fl <= x.len() {
            if let Some(cut) = self.frame(&x[i..i + fl]) {
                out.push(cut);
            }
            i += fl;
        }
        if i < x.len() {
            self.carry.extend_from_slice(&x[i..]);
        }
        self.samples += x.len();
        out
    }

    fn loud(&self, db: f32) -> bool {
        db > (self.floor_db + self.on_delta).max(self.min_loud_db)
    }

    fn frame(&mut self, f: &[f32]) -> Option<Cut> {
        let db = level(f);
        self.levels.push(db);
        if Self::seconds(self.frames() as i64) > self.warmup + 1e-9 {
            // digital silence (a gap in a test file, a muted mic) counts as a very quiet room, not as nothing: a floor
            // made of speech alone would call the dips between syllables pauses
            let v = db.max(-90.0);
            let cap = ((3.0 / Self::FRAME_SECONDS) as usize).max(1);
            if self.history.len() < cap {
                self.history.push(v);
            } else {
                self.history[self.history_at] = v;
                self.history_at = (self.history_at + 1) % cap;
            }
            let mut sorted = self.history.clone();
            sorted.sort_by(|a, b| a.total_cmp(b));
            let p10 = sorted[(sorted.len() - 1).min(sorted.len() / 10)];
            // while someone talks the floor rises at most 2 dB/s (3 s of continuous speech would otherwise become
            // "the room", and the dips between syllables pauses); it follows the room freely otherwise
            self.floor_db = if self.talking {
                p10.min(self.floor_db + (2.0 * Self::FRAME_SECONDS) as f32)
            } else {
                p10
            };
        }
        let is_loud = self.loud(db);
        self.recent_loud.push_back(is_loud);
        if self.recent_loud.len() > 12 {
            self.recent_loud.pop_front();
        }
        self.talking = self.recent_loud.iter().filter(|&&l| l).count() >= 6;
        let frames = self.frames() as i64;
        if is_loud {
            self.piece_speech += 1;
            self.quiet_run = 0;
            if let Some(k) = self.pause_open.take() {
                self.pauses[k] = Some(Self::seconds(frames - 1 - self.last_loud_frame - 1));
            }
            self.last_loud_frame = frames - 1;
        } else {
            self.quiet_run += 1;
        }
        let piece_frames = frames - (self.piece_start / self.frame_length) as i64;
        let pause_frames = (self.pause / Self::FRAME_SECONDS).round() as i64;
        // a pause long enough, in a piece long enough that has speech: cut in the middle of the pause
        if self.quiet_run as i64 == pause_frames
            && Self::seconds(piece_frames) >= self.min_segment
            && self.piece_has_speech()
        {
            let mid = (frames - pause_frames / 2) as usize;
            return Some(self.cut(self.sample_at(mid), false));
        }
        // too long without one: the quietest 100 ms of the last 2 s
        if Self::seconds(piece_frames) >= self.max_segment {
            let back = (2.0 / Self::FRAME_SECONDS) as i64;
            let w: i64 = 5;
            let lo = ((self.piece_start / self.frame_length) as i64 + 1).max(frames - back);
            let hi = frames - w;
            let (mut best, mut best_db) = (hi, f32::MAX);
            if lo <= hi {
                for s in lo..=hi {
                    let m = self.levels[s as usize..(s + w) as usize]
                        .iter()
                        .sum::<f32>()
                        / w as f32;
                    if m < best_db {
                        best_db = m;
                        best = s;
                    }
                }
            }
            let at = (best + w / 2) as usize;
            // hard unless that moment is as quiet as the room: then the pieces overlap and the stitch drops doubled words
            let hard = best_db > self.floor_db + 6.0;
            return Some(self.cut(self.sample_at(at), hard));
        }
        None
    }

    fn cut(&mut self, end: usize, hard: bool) -> Cut {
        let next = if hard {
            end.saturating_sub((self.overlap * self.sample_rate) as usize)
                .max(self.piece_start)
        } else {
            end
        };
        let c = Cut {
            end,
            next_start: next,
            hard,
        };
        if hard {
            self.pauses.push(Some(0.0));
            self.pause_open = None;
        } else {
            self.pauses.push(None);
            self.pause_open = Some(self.pauses.len() - 1);
        }
        // speech frames after the cut belong to the next piece
        let first_next_frame = (next / self.frame_length).min(self.levels.len());
        self.piece_speech = self.levels[first_next_frame..]
            .iter()
            .filter(|&&db| self.loud(db))
            .count();
        self.piece_start = next;
        c
    }
}

#[cfg(test)]
mod tests {
    //! Where a streamed dictation is cut (docs/design/dictation.md §Streaming): in pauses, never inside speech, not too
    //! short, and with an overlap when there was no pause for too long.
    use super::*;

    const SR: f64 = 16000.0;

    /// "speech": a 200 Hz tone with a syllable-like envelope at −20 dBFS
    fn speech(s: f64) -> Vec<f32> {
        (0..(s * SR) as usize)
            .map(|i| {
                let t = i as f64 / SR;
                let env = 0.6 + 0.4 * (2.0 * std::f64::consts::PI * 4.0 * t).sin(); // 4 syllables a second, never silent
                (0.1 * env * (2.0 * std::f64::consts::PI * 200.0 * t).sin()) as f32
            })
            .collect()
    }

    /// "quiet": a room at −60 dBFS (uniform noise in ±0.001; a fixed xorshift instead of the system generator)
    fn quiet(s: f64) -> Vec<f32> {
        let mut x: u64 = 0x9E37_79B9_7F4A_7C15 ^ (s.to_bits());
        (0..(s * SR) as usize)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                ((x >> 11) as f64 / (1u64 << 53) as f64 * 0.002 - 0.001) as f32
            })
            .collect()
    }

    fn run_cfg(
        parts: &[Vec<f32>],
        configure: impl FnOnce(&mut DictationSegmenter),
    ) -> (Vec<Cut>, DictationSegmenter) {
        let chunk = 1600;
        let mut s = DictationSegmenter::new(SR);
        configure(&mut s);
        let x: Vec<f32> = parts.concat();
        let mut cuts = vec![];
        for c in x.chunks(chunk) {
            cuts.extend(s.feed(c));
        }
        (cuts, s)
    }

    fn run(parts: &[Vec<f32>]) -> (Vec<Cut>, DictationSegmenter) {
        run_cfg(parts, |_| {})
    }

    #[test]
    fn cuts_in_the_middle_of_a_pause() {
        // 0.3 s room, 4 s talk, 0.8 s pause, 3 s talk
        let (cuts, s) = run(&[quiet(0.3), speech(4.0), quiet(0.8), speech(3.0)]);
        assert_eq!(cuts.len(), 1);
        let c = cuts[0];
        assert!(!c.hard);
        assert_eq!(c.end, c.next_start);
        // inside the pause (4.3 s … 5.1 s), after its first half second
        let at = c.end as f64 / SR;
        assert!(at > 4.3 + 0.2, "{at}");
        assert!(at < 5.1, "{at}");
        assert!(s.piece_has_speech()); // the last piece (the 3 s) is still open
    }

    #[test]
    fn knows_how_long_each_pause_was() {
        // a breath (0.7 s) and a sentence end (1.5 s): the seam rule keeps a full stop only after the long one
        let (cuts, s) = run(&[
            quiet(0.3),
            speech(3.5),
            quiet(0.7),
            speech(3.5),
            quiet(1.5),
            speech(1.0),
        ]);
        assert_eq!(cuts.len(), 2);
        assert_eq!(s.pauses().len(), 2);
        assert!(
            (s.pauses()[0].unwrap_or(0.0) - 0.7).abs() <= 0.1,
            "{:?}",
            s.pauses()
        );
        assert!(
            (s.pauses()[1].unwrap_or(0.0) - 1.5).abs() <= 0.1,
            "{:?}",
            s.pauses()
        );
        // still quiet after the cut: not known yet
        let (_, open) = run(&[speech(3.5), quiet(0.7)]);
        assert_eq!(open.pauses().len(), 1);
        assert_eq!(open.pauses()[0], None);
    }

    #[test]
    fn short_pauses_and_short_pieces_dont_cut() {
        // pauses of 0.3 s never cut; a 0.8 s pause after only 2 s of talk doesn't either (pieces ≥ 3 s)
        assert_eq!(
            run(&[
                speech(2.0),
                quiet(0.3),
                speech(2.0),
                quiet(0.3),
                speech(2.0)
            ])
            .0
            .len(),
            0
        );
        assert_eq!(run(&[speech(2.0), quiet(0.8), speech(2.0)]).0.len(), 0);
    }

    #[test]
    fn every_pause_after_enough_talk_cuts() {
        let parts = [
            speech(3.5),
            quiet(0.7),
            speech(3.5),
            quiet(0.7),
            speech(3.5),
            quiet(0.7),
            speech(1.0),
        ];
        let (cuts, _) = run(&parts);
        assert_eq!(cuts.len(), 3);
        assert!(cuts.iter().all(|c| !c.hard));
        // the pieces cover everything, in order, without a gap
        assert_eq!(
            cuts.windows(2)
                .filter(|w| w[0].next_start > w[1].end)
                .count(),
            0
        );
    }

    #[test]
    fn silence_alone_is_never_a_piece() {
        // a long silence after a cut doesn't cut again (no speech in it)
        let (cuts, s) = run(&[speech(3.5), quiet(5.0)]);
        assert_eq!(cuts.len(), 1);
        assert!(!s.piece_has_speech());
    }

    #[test]
    fn no_pause_for_too_long_is_a_hard_cut_with_overlap() {
        let (cuts, _) = run_cfg(&[speech(25.0)], |s| s.max_segment = 10.0);
        assert!(cuts.len() >= 2);
        let mut start = 0;
        for c in &cuts {
            assert!(c.hard);
            assert_eq!(c.end - c.next_start, (0.8 * SR) as usize); // the next piece hears the last 0.8 s again
            let len = (c.end - start) as f64 / SR;
            assert!(len <= 10.05, "{len}"); // within the last 2 s before the limit
            assert!(len >= 7.9, "{len}");
            start = c.next_start;
        }
    }

    #[test]
    fn a_long_piece_cuts_at_its_quietest_moment_without_overlap_when_it_is_quiet() {
        // 9 s of talk with a 0.3 s breath at 8 s, no 0.5 s pause: cut in the breath, a soft cut
        let (cuts, _) = run_cfg(&[speech(8.0), quiet(0.3), speech(3.0)], |s| {
            s.max_segment = 9.0
        });
        assert_eq!(cuts.len(), 1);
        assert!(!cuts[0].hard);
        let at = cuts[0].end as f64 / SR;
        assert!(at > 8.0, "{at}");
        assert!(at < 8.3, "{at}");
    }

    #[test]
    fn digital_silence_is_quiet() {
        // a test file's gaps are exact zeros: still pauses (not ignored)
        let zeros = vec![0.0f32; (0.8 * SR) as usize];
        assert_eq!(run(&[speech(4.0), zeros, speech(3.0)]).0.len(), 1);
    }

    #[test]
    fn level_of_a_frame() {
        assert_eq!(level(&[]), -120.0);
        assert_eq!(level(&[0.0; 320]), -120.0); // the 1e-6 floor
        assert!((level(&[0.1; 320]) - -20.0).abs() < 1e-3);
    }
}
