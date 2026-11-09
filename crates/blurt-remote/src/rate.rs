//! How much to send, from what the network lets through (RemoteRate in RemoteVideo.swift; docs/design/remote.md §What it costs).
//! The phone's request is the ceiling. Away from home it starts at half and climbs. Down fast when frames pile up on the way or
//! are lost in numbers, to a little under what's really getting through; one lost frame on Wi-Fi says nothing. Back up slowly,
//! and only while the picture uses what it has. Each frame gets at least 30 kbit: with little to spend there are fewer frames.

#[derive(Clone, Debug)]
pub struct Rate {
    pub cap: i64,
    pub fps_cap: i64,
    pub bitrate: i64,
    pub fps: i64,
    calm: i64,
    best_rtt: f64,
    wait: i64,
    trouble_at: i64,
    since_trouble: i64,
    recent: Vec<(i64, i64)>,
}

const WINDOW: usize = 5;
const PATIENCE: i64 = 30;
const BITS_PER_FRAME: i64 = 30_000;

impl Rate {
    pub fn new(bitrate: i64, fps: i64, away: bool) -> Rate {
        let b = if away { bitrate / 2 } else { bitrate };
        Rate {
            cap: bitrate,
            fps_cap: fps,
            bitrate: b,
            fps: Self::frames(b, fps),
            calm: 0,
            best_rtt: f64::INFINITY,
            wait: 0,
            trouble_at: i64::MAX,
            since_trouble: 0,
            recent: vec![],
        }
    }

    pub fn floor(&self) -> i64 {
        self.cap.min(200_000)
    }

    fn frames(bitrate: i64, cap: i64) -> i64 {
        cap.min((bitrate / BITS_PER_FRAME).max(10))
    }

    /// One report's worth. `busy`: frames skipped because the way out was full. `backed_up`: more on its way than should be.
    /// `sent`, `delivered`: bits a second out of here and into the phone. True if anything changed.
    #[allow(clippy::too_many_arguments)]
    pub fn update(&mut self, frames: i64, lost: i64, busy: i64, backed_up: bool, rtt: Option<f64>, sent: i64, delivered: i64) -> bool {
        let before = (self.bitrate, self.fps);
        if let Some(r) = rtt.filter(|r| *r > 0.0) {
            self.best_rtt = self.best_rtt.min(r);
        }
        self.recent.push((frames, lost));
        if self.recent.len() > WINDOW {
            self.recent.remove(0);
        }
        let seen: i64 = self.recent.iter().map(|r| r.0).sum();
        let missing: i64 = self.recent.iter().map(|r| r.1).sum();
        let queued = rtt.is_some_and(|r| r > self.best_rtt * 3.0 + 0.1);
        let lossy = missing >= 2 && missing * 20 >= seen + missing;
        self.since_trouble += 1;
        if self.since_trouble > PATIENCE {
            self.trouble_at = i64::MAX;
        }
        if self.wait > 0 {
            self.wait -= 1;
        }
        if busy >= 3 || backed_up || lossy || queued {
            self.calm = 0;
            if lossy {
                self.recent.clear(); // each loss is answered once
            }
            // already under what's arriving: what's queued is draining
            if self.wait == 0 && (delivered == 0 || self.bitrate * 100 > delivered * 85) {
                self.trouble_at = self.bitrate;
                self.since_trouble = 0;
                let mut next = self.bitrate * 7 / 10;
                if delivered > 0 {
                    next = next.min((delivered * 85 / 100).max(self.bitrate / 2));
                }
                self.bitrate = self.floor().max(next);
                self.wait = 2;
            }
        } else {
            self.calm += 1;
            let ceiling = self.cap.min(if self.trouble_at == i64::MAX { self.cap } else { self.trouble_at * 9 / 10 });
            if self.calm >= 3 && self.bitrate < ceiling && sent * 10 >= self.bitrate * 6 {
                self.calm = 0;
                self.bitrate = ceiling.min(self.bitrate * 5 / 4);
            }
        }
        self.fps = Self::frames(self.bitrate, self.fps_cap);
        before != (self.bitrate, self.fps)
    }
}

/// Ported from RemoteRateTests.swift.
#[cfg(test)]
mod tests {
    use super::Rate;

    #[test]
    fn at_home_it_starts_at_the_top() {
        let r = Rate::new(12_000_000, 60, false);
        assert_eq!(r.bitrate, 12_000_000);
        assert_eq!(r.fps, 60);
    }

    #[test]
    fn away_it_starts_at_half_and_climbs_when_the_picture_uses_it() {
        let mut r = Rate::new(4_000_000, 30, true);
        assert_eq!(r.bitrate, 2_000_000);
        for _ in 0..30 {
            let b = r.bitrate;
            r.update(30, 0, 0, false, Some(0.05), b, 0);
        }
        assert_eq!(r.bitrate, 4_000_000);
    }

    #[test]
    fn a_still_screen_proves_nothing() {
        let mut r = Rate::new(4_000_000, 30, true);
        for _ in 0..30 {
            assert!(!r.update(0, 0, 0, false, Some(0.05), 0, 0));
        }
        assert_eq!(r.bitrate, 2_000_000);
    }

    #[test]
    fn a_thin_pipe_brings_it_down_to_what_gets_through() {
        let mut r = Rate::new(4_000_000, 30, false);
        for _ in 0..12 {
            let b = r.bitrate;
            r.update(8, 0, 5, true, Some(0.05), b, 480_000);
        }
        assert!(r.bitrate <= 480_000);
        assert!(r.bitrate >= r.floor());
        assert!(r.fps < 20, "fewer frames, each of them sharper");
    }

    #[test]
    fn one_late_frame_is_no_reason_to_give_up() {
        let mut r = Rate::new(4_000_000, 30, false);
        assert!(!r.update(30, 1, 1, false, Some(0.05), 3_000_000, 0));
    }

    #[test]
    fn real_loss_and_a_growing_round_trip_both_count() {
        let mut a = Rate::new(4_000_000, 30, false);
        assert!(a.update(20, 3, 0, false, Some(0.05), 3_000_000, 0));
        let mut b = Rate::new(4_000_000, 30, false);
        b.update(30, 0, 0, false, Some(0.05), 3_000_000, 0);
        assert!(b.update(30, 0, 0, false, Some(0.6), 3_000_000, 0));
    }

    #[test]
    fn it_doesnt_climb_straight_back_into_trouble() {
        let mut r = Rate::new(4_000_000, 30, false);
        r.update(8, 0, 5, true, Some(0.05), 1_000_000, 1_000_000);
        assert_eq!(r.bitrate, 2_000_000);
        for _ in 0..20 {
            let b = r.bitrate;
            r.update(30, 0, 0, false, Some(0.05), b, 0);
        }
        assert!(r.bitrate <= 3_600_000);
        for _ in 0..40 {
            let b = r.bitrate;
            r.update(30, 0, 0, false, Some(0.05), b, 0);
        }
        assert_eq!(r.bitrate, 4_000_000, "and tries again in a while");
    }

    #[test]
    fn never_below_the_floor() {
        let mut r = Rate::new(1_000_000, 15, false);
        for _ in 0..40 {
            r.update(1, 1, 9, false, None, 0, 1000);
        }
        assert_eq!(r.bitrate, 200_000);
        assert_eq!(r.fps, 10);
    }
}
