//! How much to send, from what the network lets through (RemoteRate in RemoteVideo.swift; docs/design/remote.md §What it costs).
//! The phone's request is the ceiling. Away from home it starts at half and climbs. Down fast when frames pile up on the way or
//! are lost in numbers, to a little under what's really getting through; one lost frame on Wi-Fi says nothing. Back up slowly,
//! and only while the picture uses what it has: so a rate that fell stayed where it fell for as long as the screen was read. A
//! still picture's resends (sharpen.rs) are the one thing sent then, so they find out: while there is room above the rate they go
//! half as fast again (`probe`, the encoder's rate with them), and if all of that arrives with no sign of trouble the rate goes to
//! nine tenths of the rate they really went at (`Probe`). If it doesn't, nothing is cut for a question, and none is asked again
//! for a while. Each frame gets at least 30 kbit: with little to spend there are fewer frames.

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
    /// reports since resends that went faster than the rate met trouble: none go faster again until `PATIENCE`
    since_probe: i64,
}

/// How fast a still picture's resends really went while they went faster than the rate (`Rate::probe`): their bytes over the time
/// each was given to get through. Short of the pace when resends were small or the encoder dropped some, never more than it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Probe {
    bytes: usize,
    time: f64,
}

impl Probe {
    /// A resend of this size went, and the next waits this long for it.
    pub fn sent(&mut self, bytes: usize, wait: f64) {
        self.bytes += bytes;
        self.time += wait;
    }

    /// Bits a second, once there is enough to say (0.3 s of it); None before. Taking it starts over.
    pub fn take(&mut self) -> Option<i64> {
        let p = std::mem::take(self);
        (p.time >= 0.3).then(|| (p.bytes as f64 * 8.0 / p.time) as i64)
    }
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
            since_probe: PATIENCE + 1,
        }
    }

    pub fn floor(&self) -> i64 {
        self.cap.min(200_000)
    }

    fn frames(bitrate: i64, cap: i64) -> i64 {
        cap.min((bitrate / BITS_PER_FRAME).max(10))
    }

    /// As far up as it may go: the phone's ceiling, or a little under where trouble last began.
    fn ceiling(&self) -> i64 {
        self.cap.min(if self.trouble_at == i64::MAX { self.cap } else { self.trouble_at * 9 / 10 })
    }

    /// The rate a still picture's resends go at: the bitrate, or half as much again while there is room above it nothing has tried.
    pub fn probe(&self) -> i64 {
        if self.bitrate < self.ceiling() && self.since_probe > PATIENCE {
            self.ceiling().min(self.bitrate * 3 / 2)
        } else {
            self.bitrate
        }
    }

    /// One report's worth, with no resends having gone faster than the rate.
    #[allow(clippy::too_many_arguments)]
    pub fn update(&mut self, frames: i64, lost: i64, busy: i64, backed_up: bool, rtt: Option<f64>, sent: i64, delivered: i64) -> bool {
        self.update_probed(frames, lost, busy, backed_up, rtt, sent, delivered, None)
    }

    /// One report's worth. `busy`: frames skipped because the way out was full. `backed_up`: more on its way than should be.
    /// `sent`, `delivered`: bits a second out of here and into the phone. `probed`: since the last report a still picture's resends
    /// went faster than the rate, at this many bits a second while they went (`Probe`). True if anything changed.
    #[allow(clippy::too_many_arguments)]
    pub fn update_probed(
        &mut self, frames: i64, lost: i64, busy: i64, backed_up: bool, rtt: Option<f64>, sent: i64, delivered: i64, probed: Option<i64>,
    ) -> bool {
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
        if self.since_probe <= PATIENCE {
            self.since_probe += 1;
        }
        if busy >= 3 || backed_up || lossy || queued {
            self.calm = 0;
            if lossy {
                self.recent.clear(); // each loss is answered once
            }
            if probed.is_some() {
                // more than the rate was sent to see if it would arrive, and this is the answer: the rate stays, and nothing asks
                // again soon
                self.since_probe = 0;
            } else if self.wait == 0 && (delivered == 0 || self.bitrate * 100 > delivered * 85) {
                // (already under what's arriving: what's queued is draining)
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
            let ceiling = self.ceiling();
            if let Some(p) = probed.filter(|p| p * 9 / 10 > self.bitrate && self.bitrate < ceiling && delivered * 10 >= sent * 9) {
                // faster than the rate, all of it arrived, nothing queued: the network carries that much
                self.calm = 0;
                self.bitrate = ceiling.min(p * 9 / 10);
            } else if self.calm >= 3 && self.bitrate < ceiling && sent * 10 >= self.bitrate * 6 {
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
    use super::{Probe, Rate};

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

    #[test]
    fn a_still_pictures_resends_find_the_room_above_a_rate_that_fell() {
        let mut r = Rate::new(8_000_000, 30, true);
        assert_eq!((r.bitrate, r.probe()), (4_000_000, 6_000_000), "away it starts at half: the first still picture asks for more");
        assert!(r.update_probed(6, 0, 0, false, Some(0.05), 2_900_000, 2_800_000, Some(5_800_000)));
        assert_eq!(r.bitrate, 5_220_000, "nine tenths of how fast they went");
        // resends that went no faster than the rate say nothing new; nor does what didn't all arrive
        let mut slow = Rate::new(8_000_000, 30, true);
        assert!(!slow.update_probed(6, 0, 0, false, Some(0.05), 2_000_000, 2_000_000, Some(4_200_000)));
        let mut short = Rate::new(8_000_000, 30, true);
        assert!(!short.update_probed(6, 0, 0, false, Some(0.05), 2_900_000, 2_000_000, Some(5_800_000)));
        // never past the phone's ceiling
        let mut near = Rate::new(5_000_000, 30, true);
        for p in [3_750_000, 5_000_000, 9_000_000] {
            near.update_probed(6, 0, 0, false, Some(0.05), 3_000_000, 3_000_000, Some(p));
        }
        assert_eq!((near.bitrate, near.probe()), (5_000_000, 5_000_000), "at the ceiling there is nothing to ask");
    }

    #[test]
    fn a_question_answered_no_costs_nothing_and_isnt_asked_again_soon() {
        let mut r = Rate::new(8_000_000, 30, true);
        r.update(6, 0, 0, false, Some(0.05), 0, 0);
        assert!(!r.update_probed(6, 0, 0, false, Some(0.4), 3_000_000, 2_100_000, Some(5_800_000)), "no cut for asking");
        assert_eq!((r.bitrate, r.probe()), (4_000_000, 4_000_000), "and the next still picture goes at the rate");
        let mut plain = Rate::new(8_000_000, 30, true);
        plain.update(6, 0, 0, false, Some(0.05), 0, 0);
        assert!(plain.update(6, 0, 0, false, Some(0.4), 4_000_000, 4_000_000), "trouble without a question is still trouble");
        for _ in 0..31 {
            r.update(0, 0, 0, false, Some(0.05), 0, 0);
        }
        assert_eq!(r.probe(), 6_000_000, "after a while it may ask again");
    }

    #[test]
    fn resends_say_how_fast_they_really_went() {
        let mut p = Probe::default();
        assert_eq!(p.take(), None);
        p.sent(50_000, 0.1);
        assert_eq!(p.take(), None, "a tenth of a second says nothing");
        for _ in 0..4 {
            p.sent(75_000, 0.1);
        }
        assert_eq!(p.take(), Some(6_000_000));
        assert_eq!(p.take(), None, "taken");
    }

    #[test]
    fn over_an_hour_of_reading_the_rate_settles_just_under_what_the_network_carries() {
        let carries = 3_000_000;
        let mut r = Rate::new(8_000_000, 30, true);
        r.update(6, 0, 0, false, Some(0.05), 0, 0);
        for _ in 0..12 {
            let b = r.bitrate;
            r.update(6, 0, 5, false, Some(0.05), b, 400_000);
        }
        let fell = r.bitrate;
        assert!(fell < 600_000);
        let (mut lowest, mut back) = (fell, 0);
        for still in 1..=180 {
            for _ in 0..2 {
                let pace = r.probe();
                let went = pace * 9 / 10;
                let probed = (pace > r.bitrate).then_some(went);
                r.update_probed(5, 0, 0, false, Some(if went > carries { 0.5 } else { 0.05 }), went, went.min(carries), probed);
                lowest = lowest.min(r.bitrate);
            }
            for _ in 0..4 {
                r.update(0, 0, 0, false, Some(0.05), 0, 0);
            }
            if back == 0 && r.bitrate > carries * 7 / 10 {
                back = still;
            }
        }
        assert_eq!(lowest, fell, "asking never costs");
        assert!(r.bitrate > carries * 7 / 10 && r.bitrate <= carries * 11 / 10, "{}", r.bitrate);
        assert!(back > 0 && back < 30, "back within some minutes of reading, not never: {back}");
    }
}
