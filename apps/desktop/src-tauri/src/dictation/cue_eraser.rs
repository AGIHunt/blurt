//! Takes Blurt's own start cue (Peep's peep, `sounds/start.wav`) back out of the microphone's audio — the Mac's
//! BlurtCore `CueEraser`, ported (docs/design/dictation.md §Sounds, "Start cue out of the take").
//!
//! The peep plays when the take's first audio arrives ("talk now", engine.rs `frame`), so on speakers the mic records
//! it: on the Mac it was in 203 of the founder's last 300 kept takes, 0.20 s in, around −30 dBFS. It is in every kept
//! recording, in the audio a personal model is trained on, and in what the endpointer and the stream hear.
//!
//! The app knows what it played and roughly when. From `arm()` the samples are held for `search_seconds` + the cue's
//! length (about 0.85 s, once a take): the cue is found by normalized cross-correlation (or, under speech, by how
//! sharply the raw correlation peaks), a short FIR from the clip to the recording (the speaker, the room, the mic) is
//! fitted by least squares over the cue's window and subtracted, and what is left there is turned down unless it is
//! loud enough to be the speaker already talking. With headphones (no match) the samples go on unchanged. Signal
//! processing only: nothing here interprets speech.

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CueResult {
    /// where the cue started, samples after the arming point
    pub offset: usize,
    pub matched: f32,
    /// the cue window's level before and after (dBFS)
    pub before_db: f32,
    pub after_db: f32,
    /// true: the window was turned down after the subtraction; false: speech was there too, only subtracted
    pub muted: bool,
}

pub struct CueEraser {
    pub sample_rate: f64,
    /// how long after the cue was started it may appear in the recording (output + input latency, buffering)
    pub search_seconds: f64,
    /// a correlation below this is no cue (headphones, or the volume down)
    pub min_match: f32,
    /// …or this, when the peak stands `min_prominence` times above the correlation's median (the speaker already
    /// talking)
    pub min_match_under_speech: f32,
    pub min_prominence: f32,
    /// after the subtraction, a window quieter than this (or followed by 0.2 s quieter than this) holds only the cue's
    /// remains and is turned down; louder, with talk after it, is speech that began during the peep
    pub speech_db: f32,
    /// the turned-down window's gain (≈ −30 dB: room tone stays, no hole of digital silence)
    pub floor_gain: f32,
    cue: Vec<f32>,
    held: Vec<f32>,
    holding: bool,
    result: Option<CueResult>,
}

const TAPS: usize = 48;

impl CueEraser {
    /// `cue`: the clip as played, mono, at `sample_rate` (`sounds/start.wav`, resampled: `clip_from_wav`)
    pub fn new(cue: Vec<f32>, sample_rate: f64) -> Self {
        CueEraser {
            sample_rate,
            search_seconds: 0.6,
            min_match: 0.5,
            min_match_under_speech: 0.12,
            min_prominence: 12.0,
            speech_db: -38.0,
            floor_gain: 0.03,
            cue,
            held: vec![],
            holding: false,
            result: None,
        }
    }

    /// The cue just started playing: samples from now on are held until it has been found (or not). Once a take.
    pub fn arm(&mut self) {
        if self.cue.is_empty() || self.result.is_some() || self.holding {
            return;
        }
        self.holding = true;
        self.held.clear();
    }

    pub fn is_holding(&self) -> bool {
        self.holding
    }

    pub fn result(&self) -> Option<CueResult> {
        self.result
    }

    /// Samples in, samples out: the same ones while nothing is armed; while armed, nothing until the search window is
    /// in, then all of it with the cue taken out.
    pub fn process(&mut self, x: Vec<f32>) -> Vec<f32> {
        if !self.holding {
            return x;
        }
        self.held.extend_from_slice(&x);
        if self.held.len() < (self.search_seconds * self.sample_rate) as usize + self.cue.len() + self.tail() {
            return vec![];
        }
        self.release()
    }

    /// The take ends while samples are held: they go out now, cue taken out if it is in them.
    pub fn flush(&mut self) -> Vec<f32> {
        if !self.holding {
            return vec![];
        }
        self.release()
    }

    fn pre(&self) -> usize {
        (0.01 * self.sample_rate) as usize
    }

    /// the room's ring after the clip ends
    fn tail(&self) -> usize {
        (0.04 * self.sample_rate) as usize
    }

    fn release(&mut self) -> Vec<f32> {
        self.holding = false;
        let mut y = std::mem::take(&mut self.held);
        if let Some(r) = self.erase(&mut y) {
            self.result = Some(r);
        }
        y
    }

    /// Finds the cue in `y` and takes it out in place.
    fn erase(&self, y: &mut [f32]) -> Option<CueResult> {
        let cue = &self.cue;
        let n = cue.len();
        if y.len() <= n {
            return None;
        }
        let lags = ((self.search_seconds * self.sample_rate) as usize).min(y.len() - n);
        if lags == 0 {
            return None;
        }
        // normalized cross-correlation: <y[k..k+n], cue> / (|y[k..k+n]| |cue|)
        let corr: Vec<f32> = (0..=lags).map(|k| dot(&y[k..k + n], cue)).collect();
        let cue_norm = cue.iter().map(|v| v * v).sum::<f32>().sqrt();
        let mut energy: f32 = y[..n].iter().map(|v| v * v).sum();
        let (mut best, mut best_match) = (0usize, -1f32);
        for k in 0..=lags {
            if k > 0 {
                energy += y[k + n - 1] * y[k + n - 1] - y[k - 1] * y[k - 1];
            }
            let m = corr[k] / (energy.max(1e-12).sqrt() * cue_norm);
            if m > best_match {
                best_match = m;
                best = k;
            }
        }
        // speech over the cue lowers the normalized match (its energy is in the window too); the clip still stands out
        // as a sharp peak of the raw correlation, far above the correlation with everything else in the search window
        let mut mags: Vec<f32> = corr.iter().map(|v| v.abs()).collect();
        mags.sort_by(f32::total_cmp);
        let prominence = corr[best].abs() / mags[mags.len() / 2].max(1e-9);
        if !(best_match >= self.min_match
            || (best_match >= self.min_match_under_speech && prominence >= self.min_prominence))
        {
            return None;
        }

        let a = best.saturating_sub(self.pre());
        let b = (best + n + self.tail()).min(y.len());
        let cue_end = (best + n).min(y.len());
        let before = db(&y[best..cue_end]);
        // least-squares FIR h (TAPS): y[a..b] ≈ Σ_t h[t] · cue[i − best − t]
        let len = b - a;
        // the clip with room on both sides: row i's regressors (the clip delayed by 0..TAPS) are padded[base − t]
        let front = best - a + TAPS;
        let mut padded = vec![0f64; front + n + len];
        for (j, v) in cue.iter().enumerate() {
            padded[front + j] = *v as f64;
        }
        let row = |i: usize, r: &mut [f64; TAPS]| {
            let base = front + a + i - best; // ≥ TAPS
            for (t, v) in r.iter_mut().enumerate() {
                *v = padded[base - t];
            }
        };
        let mut ata = vec![0f64; TAPS * TAPS];
        let mut atb = [0f64; TAPS];
        let mut r = [0f64; TAPS];
        for i in 0..len {
            row(i, &mut r);
            let yi = y[a + i] as f64;
            for t in 0..TAPS {
                let xt = r[t];
                if xt == 0.0 {
                    continue;
                }
                atb[t] += xt * yi;
                for (acc, xu) in ata[t * TAPS + t..(t + 1) * TAPS].iter_mut().zip(&r[t..]) {
                    *acc += xt * xu;
                }
            }
        }
        for t in 0..TAPS {
            for u in 0..t {
                ata[t * TAPS + u] = ata[u * TAPS + t];
            }
            ata[t * TAPS + t] += 1e-6;
        }
        let h = solve(ata, atb.to_vec(), TAPS)?;
        for i in 0..len {
            row(i, &mut r);
            let fit: f64 = h.iter().zip(&r).map(|(h, x)| h * x).sum();
            y[a + i] -= fit as f32;
        }
        let left = db(&y[best..cue_end]);
        // what is left is only the cue's remains (the subtraction can't follow the speaker's distortion fully) when it
        // is quiet, or when nobody talks in the 0.2 s after it either: speech that started during the peep goes on
        let after = db(&y[b..(b + (0.2 * self.sample_rate) as usize).min(y.len())]);
        let mute = left < self.speech_db || (b < y.len() && after < self.speech_db);
        if mute {
            let fade = ((0.008 * self.sample_rate) as usize).max(1);
            for (k, v) in y[a..b].iter_mut().enumerate() {
                let edge = k.min(len - 1 - k);
                let g = if edge >= fade {
                    self.floor_gain
                } else {
                    1.0 - (1.0 - self.floor_gain) * edge as f32 / fade as f32
                };
                *v *= g;
            }
        }
        Some(CueResult {
            offset: best,
            matched: best_match,
            before_db: before,
            after_db: if mute { db(&y[best..cue_end]) } else { left },
            muted: mute,
        })
    }
}

/// <a, b> in eight lanes (vectorizes; once a take, 0.6 s × 0.22 s of lags × taps)
fn dot(a: &[f32], b: &[f32]) -> f32 {
    let mut acc = [0f32; 8];
    let (ca, cb) = (a.chunks_exact(8), b.chunks_exact(8));
    let tail: f32 = ca.remainder().iter().zip(cb.remainder()).map(|(x, y)| x * y).sum();
    for (x, y) in ca.zip(cb) {
        let (x, y): (&[f32; 8], &[f32; 8]) = (x.try_into().unwrap(), y.try_into().unwrap());
        for l in 0..8 {
            acc[l] += x[l] * y[l];
        }
    }
    acc.iter().sum::<f32>() + tail
}

/// Mean-square level in dBFS (−120 for nothing).
fn db(s: &[f32]) -> f32 {
    if s.is_empty() {
        return -120.0;
    }
    let sum: f32 = s.iter().map(|v| v * v).sum();
    10.0 * (sum / s.len() as f32).max(1e-12).log10()
}

/// Gaussian elimination with partial pivoting (n×n, n = 48).
fn solve(mut a: Vec<f64>, mut b: Vec<f64>, n: usize) -> Option<Vec<f64>> {
    for c in 0..n {
        let mut p = c;
        for r in c + 1..n {
            if a[r * n + c].abs() > a[p * n + c].abs() {
                p = r;
            }
        }
        if a[p * n + c].abs() <= 1e-12 {
            return None;
        }
        if p != c {
            for k in 0..n {
                a.swap(c * n + k, p * n + k);
            }
            b.swap(c, p);
        }
        for r in c + 1..n {
            let f = a[r * n + c] / a[c * n + c];
            if f == 0.0 {
                continue;
            }
            for k in c..n {
                a[r * n + k] -= f * a[c * n + k];
            }
            b[r] -= f * b[c];
        }
    }
    let mut out = vec![0f64; n];
    for r in (0..n).rev() {
        let mut s = b[r];
        for k in r + 1..n {
            s -= a[r * n + k] * out[k];
        }
        out[r] = s / a[r * n + r];
    }
    Some(out)
}

/// A PCM wav's samples, mixed to mono, at `rate` (windowed-sinc resampling, low-passed below the lower Nyquist).
/// 16-bit integer or 32-bit float; None for anything else.
pub fn clip_from_wav(bytes: &[u8], rate: u32) -> Option<Vec<f32>> {
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return None;
    }
    let (mut fmt, mut data) = (None, None);
    let mut i = 12;
    while i + 8 <= bytes.len() {
        let id = &bytes[i..i + 4];
        let len = u32::from_le_bytes(bytes[i + 4..i + 8].try_into().ok()?) as usize;
        let body = &bytes[i + 8..(i + 8 + len).min(bytes.len())];
        match id {
            b"fmt " if body.len() >= 16 => fmt = Some(body),
            b"data" => data = Some(body),
            _ => {}
        }
        i += 8 + len + (len & 1);
    }
    let (fmt, data) = (fmt?, data?);
    let format = u16::from_le_bytes([fmt[0], fmt[1]]);
    let ch = u16::from_le_bytes([fmt[2], fmt[3]]).max(1) as usize;
    let src = u32::from_le_bytes(fmt[4..8].try_into().ok()?);
    let bits = u16::from_le_bytes([fmt[14], fmt[15]]);
    let raw: Vec<f32> = match (format, bits) {
        (1, 16) => data.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]]) as f32 / 32768.0).collect(),
        (3, 32) => data.chunks_exact(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])).collect(),
        _ => return None,
    };
    let mono: Vec<f32> = raw.chunks_exact(ch).map(|f| f.iter().sum::<f32>() / ch as f32).collect();
    if mono.is_empty() || src == 0 {
        return None;
    }
    Some(resample(&mono, src, rate))
}

fn resample(x: &[f32], from: u32, to: u32) -> Vec<f32> {
    if from == to {
        return x.to_vec();
    }
    let step = from as f64 / to as f64; // input samples per output sample
    let cutoff = (to as f64 / from as f64).min(1.0); // of the input's Nyquist
    let half = (16.0 / cutoff).ceil() as isize; // taps each side
    let out_len = ((x.len() as f64) / step).floor() as usize;
    (0..out_len)
        .map(|k| {
            let p = k as f64 * step;
            let c = p.floor() as isize;
            let mut acc = 0.0f64;
            for j in c - half..=c + half {
                if j < 0 || j as usize >= x.len() {
                    continue;
                }
                let d = p - j as f64;
                let w = d / half as f64;
                if w.abs() >= 1.0 {
                    continue;
                }
                let arg = std::f64::consts::PI * cutoff * d;
                let sinc = if arg.abs() < 1e-9 { 1.0 } else { arg.sin() / arg };
                let hann = 0.5 + 0.5 * (std::f64::consts::PI * w).cos();
                acc += x[j as usize] as f64 * cutoff * sinc * hann;
            }
            acc as f32
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const RATE: f64 = 16000.0;

    /// a chirp-like clip standing in for the peep (0.22 s)
    fn clip() -> Vec<f32> {
        (0..3520)
            .map(|i| {
                let t = i as f32 / 16000.0;
                let phase = 2.0 * std::f32::consts::PI * (1800.0 + 2400.0 * t) * t;
                let env = (i as f32 / 160.0).min((3520 - i) as f32 / 400.0).min(1.0);
                0.5 * phase.sin() * env
            })
            .collect()
    }

    fn noise(n: usize, level: f32, seed: u64) -> Vec<f32> {
        let mut s = seed;
        (0..n)
            .map(|_| {
                s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                level * ((s >> 40) as f32 / (1u32 << 24) as f32 - 0.5)
            })
            .collect()
    }

    /// the clip as a speaker and a room would put it into the mic: delayed, quieter, smeared
    fn recorded(c: &[f32], at: usize, y: &mut [f32], gain: f32) {
        let h = [0.6f32, 0.25, -0.1, 0.05, 0.02];
        for (i, v) in c.iter().enumerate() {
            for (t, w) in h.iter().enumerate() {
                if at + i + t < y.len() {
                    y[at + i + t] += gain * w * v;
                }
            }
        }
    }

    fn run(e: &mut CueEraser, y: &[f32], chunk: usize) -> Vec<f32> {
        let mut out = vec![];
        for c in y.chunks(chunk) {
            out.extend(e.process(c.to_vec()));
        }
        out.extend(e.flush());
        out
    }

    #[test]
    fn passes_through_when_not_armed() {
        let mut e = CueEraser::new(clip(), RATE);
        let y = noise(16000, 0.01, 7);
        assert_eq!(run(&mut e, &y, 800), y);
        assert!(e.result().is_none());
    }

    #[test]
    fn finds_and_removes_the_cue() {
        let mut e = CueEraser::new(clip(), RATE);
        let mut y = noise(32000, 0.002, 7);
        recorded(&clip(), 3200, &mut y, 0.06);
        e.arm();
        // the engine's 20 ms frames
        let out = run(&mut e, &y, 320);
        assert_eq!(out.len(), y.len());
        let r = e.result().expect("found");
        assert!(r.offset.abs_diff(3200) <= 2, "{r:?}");
        assert!(r.muted, "{r:?}");
        assert!(r.after_db < r.before_db - 25.0, "{r:?}");
        // nothing outside the window changed
        assert_eq!(out[..3000], y[..3000]);
        assert_eq!(out[8000..], y[8000..]);
    }

    #[test]
    fn keeps_speech_that_overlaps_the_cue() {
        let mut e = CueEraser::new(clip(), RATE);
        // "speech": a loud low tone starting in the middle of the cue
        let mut y = noise(32000, 0.002, 7);
        for (i, v) in y.iter_mut().enumerate().take(20000).skip(4500) {
            *v += 0.1 * (2.0 * std::f32::consts::PI * 180.0 * i as f32 / 16000.0).sin();
        }
        let speech = y.clone();
        recorded(&clip(), 3200, &mut y, 0.06);
        e.arm();
        let out = run(&mut e, &y, 800);
        let r = e.result().expect("found");
        assert!(!r.muted, "{r:?}");
        // the speech is still there, the cue mostly gone: the output is close to the signal without the cue
        let (mut err, mut sig) = (0f32, 0f32);
        for i in 3200..6800 {
            err += (out[i] - speech[i]).powi(2);
            sig += speech[i].powi(2);
        }
        assert!(err / sig < 0.05, "{}", err / sig);
    }

    #[test]
    fn no_cue_leaves_the_audio_alone() {
        let mut e = CueEraser::new(clip(), RATE);
        let y = noise(32000, 0.01, 7);
        e.arm();
        assert_eq!(run(&mut e, &y, 800), y);
        assert!(e.result().is_none());
    }

    #[test]
    fn short_take_flushes() {
        let mut e = CueEraser::new(clip(), RATE);
        let mut y = noise(8000, 0.002, 7);
        recorded(&clip(), 1600, &mut y, 0.06);
        e.arm();
        let out = run(&mut e, &y, 800);
        assert_eq!(out.len(), y.len());
        assert!(e.result().is_some());
    }

    #[test]
    fn take_shorter_than_the_clip_goes_out_unchanged() {
        let mut e = CueEraser::new(clip(), RATE);
        let y = noise(1000, 0.002, 7);
        e.arm();
        assert_eq!(run(&mut e, &y, 320), y);
        assert!(e.result().is_none());
    }

    #[test]
    fn arms_once_a_take() {
        let mut e = CueEraser::new(clip(), RATE);
        let mut y = noise(32000, 0.002, 7);
        recorded(&clip(), 3200, &mut y, 0.06);
        e.arm();
        let _ = run(&mut e, &y, 320);
        e.arm();
        assert!(!e.is_holding());
        assert_eq!(e.process(vec![0.1; 10]), vec![0.1; 10]);
    }

    /// The bundled peep, read and brought to 16 kHz, then found in a synthetic take the way the app records it.
    #[test]
    fn the_bundled_peep_at_the_mic_rate() {
        let bytes = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/sounds/start.wav")).unwrap();
        let c = clip_from_wav(&bytes, 16000).expect("start.wav");
        // 0.22 s at 48 kHz → 3520 samples at 16 kHz, its level kept (≈ −27 dBFS; the band is 2–4 kHz)
        assert!(c.len().abs_diff(3520) <= 1, "{}", c.len());
        assert!((db(&c) + 27.2).abs() < 1.0, "{}", db(&c));
        let mut e = CueEraser::new(c.clone(), RATE);
        let mut y = noise(24000, 0.002, 3);
        recorded(&c, 3300, &mut y, 1.0);
        e.arm();
        let _ = run(&mut e, &y, 320);
        let r = e.result().expect("found");
        assert!(r.offset.abs_diff(3300) <= 2 && r.muted && r.after_db < r.before_db - 25.0, "{r:?}");
    }

    #[test]
    fn resampling_keeps_a_tone() {
        let x: Vec<f32> = (0..48000).map(|i| (2.0 * std::f32::consts::PI * 3000.0 * i as f32 / 48000.0).sin()).collect();
        let y = resample(&x, 48000, 16000);
        assert_eq!(y.len(), 16000);
        for (k, v) in y.iter().enumerate().take(15000).skip(1000) {
            let want = (2.0 * std::f32::consts::PI * 3000.0 * k as f32 / 16000.0).sin();
            assert!((v - want).abs() < 0.01, "{k}: {v} vs {want}");
        }
    }

    /// The founder's own takes (local only): BLURT_CUE_TAKES=<dir of 16 kHz wavs> [BLURT_CUE_CLIP=<start.wav>].
    #[test]
    fn real_takes() {
        let Ok(dir) = std::env::var("BLURT_CUE_TAKES") else { return };
        let clip_path = std::env::var("BLURT_CUE_CLIP")
            .unwrap_or_else(|_| concat!(env!("CARGO_MANIFEST_DIR"), "/sounds/start.wav").into());
        let cue = clip_from_wav(&std::fs::read(clip_path).unwrap(), 16000).unwrap();
        let mut files: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|x| x == "wav"))
            .collect();
        files.sort();
        let (mut found, mut muted, mut at_ms) = (0, 0, vec![]);
        let mut drops = vec![];
        let mut spent = std::time::Duration::ZERO;
        for f in &files {
            let Some(y) = clip_from_wav(&std::fs::read(f).unwrap(), 16000) else { continue };
            let mut e = CueEraser::new(cue.clone(), RATE);
            e.arm();
            let t0 = std::time::Instant::now();
            let _ = run(&mut e, &y, 320);
            spent += t0.elapsed();
            if let Some(r) = e.result() {
                found += 1;
                muted += r.muted as usize;
                drops.push(r.before_db - r.after_db);
                at_ms.push(r.offset as f64 / 16.0);
            }
        }
        drops.sort_by(f32::total_cmp);
        at_ms.sort_by(f64::total_cmp);
        let mid = |v: &[f32], q: usize| if v.is_empty() { 0.0 } else { v[v.len() / q] };
        println!(
            "CUE takes {} found {found} muted {muted} drop dB median {} p10 {} at_ms median {} · {:.1} ms a take",
            files.len(),
            mid(&drops, 2),
            mid(&drops, 10),
            at_ms.get(at_ms.len() / 2).copied().unwrap_or(0.0),
            spent.as_secs_f64() * 1000.0 / files.len().max(1) as f64
        );
    }
}
