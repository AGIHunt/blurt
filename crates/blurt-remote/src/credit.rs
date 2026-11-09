//! Frames at the phone's rate on average, not at fixed intervals (docs/design/remote-realtime.md §4; RemoteScreen.swift's `turn`).
//! Captured at 120 (or at the display's rate), a 60 Hz scroll's frames come 8 and 25 ms apart, and a fixed minimum gap either drops
//! one in seven or makes them wait. Instead each frame time earns a frame's credit (at most 1.5 saved), a frame may go with 0.45 of
//! one (up to about half a frame early, which the next one pays for), and one that comes earlier still waits for its turn rather
//! than being dropped. Pure: time is passed in. Backends use it where they decide which captured picture to encode.

#[derive(Clone, Debug)]
pub struct FrameCredit {
    gap: f64,
    turns: f64,
    at: f64,
}

/// A frame may go with this much credit.
const EARLY: f64 = 0.45;
/// at most this much saved: a still screen doesn't buy a burst
const SAVED: f64 = 1.5;

impl FrameCredit {
    pub fn new(fps: u32) -> FrameCredit {
        FrameCredit { gap: 1.0 / fps.clamp(1, 120) as f64, turns: 1.0, at: 0.0 }
    }

    pub fn set_fps(&mut self, fps: u32) {
        self.gap = 1.0 / fps.clamp(1, 120) as f64;
    }

    /// The credit at `now`.
    fn turns(&self, now: f64) -> f64 {
        if now > self.at {
            SAVED.min(self.turns + (now - self.at) / self.gap)
        } else {
            self.turns
        }
    }

    /// Seconds until a frame may go: 0 now.
    pub fn wait(&self, now: f64) -> f64 {
        let t = self.turns(now);
        if t >= EARLY {
            0.0
        } else {
            (EARLY - t) * self.gap
        }
    }

    /// A frame went (encoded) at `now`.
    pub fn spend(&mut self, now: f64) {
        self.turns = (self.turns(now) - 1.0).max(-1.0);
        self.at = self.at.max(now);
    }
}

#[cfg(test)]
mod tests {
    use super::FrameCredit;

    /// Frames offered at `times`, each sent at its turn (waiting if early, replaced if a newer one comes first): when each went.
    fn run(fps: u32, times: &[f64]) -> Vec<f64> {
        let mut c = FrameCredit::new(fps);
        let mut sent = vec![];
        let mut pending: Option<f64> = None;
        let mut t = 0.0;
        let end = times.last().copied().unwrap_or(0.0) + 0.1;
        let mut i = 0;
        while t <= end {
            while i < times.len() && times[i] <= t + 1e-9 {
                pending = Some(times[i]);
                i += 1;
            }
            if pending.is_some() && c.wait(t) == 0.0 {
                c.spend(t);
                sent.push(t);
                pending = None;
            }
            t += 0.0005;
        }
        sent
    }

    #[test]
    fn a_60_hz_scroll_captured_at_120_keeps_every_frame() {
        // the app draws every 16.7 ms; captures land 8 and 25 ms apart as the grids beat
        let times: Vec<f64> = (0..120).map(|i| i as f64 / 60.0 + if i % 7 == 3 { 0.008 } else { 0.0 }).collect();
        let sent = run(60, &times);
        assert!(sent.len() >= 118, "{} of 120", sent.len());
        let late = sent.iter().zip(&times).map(|(s, t)| s - t).fold(0.0, f64::max);
        assert!(late < 0.012, "waited {late}");
    }

    #[test]
    fn faster_than_the_rate_is_held_to_it_on_average() {
        let times: Vec<f64> = (0..240).map(|i| i as f64 / 120.0).collect();
        let sent = run(60, &times);
        let rate = sent.len() as f64 / (sent.last().unwrap() - sent[0]);
        assert!((58.0..=62.0).contains(&rate), "{rate}");
    }

    #[test]
    fn a_still_screen_saves_no_more_than_one_and_a_half() {
        let mut c = FrameCredit::new(30);
        assert_eq!(c.wait(10.0), 0.0);
        c.spend(10.0);
        assert_eq!(c.wait(10.0), 0.0, "1.5 saved: one more at once");
        c.spend(10.0);
        assert!(c.wait(10.0) > 0.0, "and then it waits");
    }
}
