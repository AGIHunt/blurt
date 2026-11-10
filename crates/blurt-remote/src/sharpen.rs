//! A still picture, made sharp (RemoteSharpen in RemoteVideo.swift; docs/design/remote-realtime.md §7). While the screen moves the
//! encoder spends what the rate allows and text comes out soft; when it stops, the same frame goes again with the encoder's
//! quantiser held under a ceiling that comes down step by step to `SHARP`, where text reads as it does on the screen itself.
//! Sending it again a fixed number of times (eight, before 1.0.17) left dense text soft on anything under a few Mbps: each resend
//! got one frame's share of the rate, and the count ran out first. A step is sized by what the last one cost, so no resend is
//! much more than 0.4 s of the rate, and each waits until the one before has had time to get through.

/// The quantiser at which a screen of 13 pt text is the source's equal by eye (HEVC and H.264 count alike).
pub const SHARP: u8 = 22;
const FIRST: u8 = 40;
/// Tries for one picture, the ones the rate control dropped included.
const MOST: u32 = 80;
/// What an encoder that takes no ceiling is asked for: its own rate control, eight times, as before.
pub const NO_CEILING: u8 = 51;

#[derive(Clone, Debug, PartialEq)]
pub struct Sharpen {
    pub done: bool,
    cap: u8,
    step: u8,
    tries: u32,
    due: f64,
}

impl Default for Sharpen {
    fn default() -> Self {
        Sharpen { done: false, cap: FIRST, step: 4, tries: 0, due: 0.0 }
    }
}

impl Sharpen {
    /// Nothing to sharpen yet: no picture has gone.
    pub fn finished() -> Sharpen {
        Sharpen { done: true, ..Sharpen::default() }
    }

    /// Resends of this picture have begun and aren't finished.
    pub fn under_way(&self) -> bool {
        !self.done && self.tries > 0
    }

    /// The picture changed, or what the phone has of it did (a keyframe, a recovery frame): from the top.
    pub fn again(&mut self) {
        *self = Sharpen::default();
    }

    /// The quantiser ceiling for a resend now; None: not yet, or done. `capped` false: this encoder takes no ceiling, so it's
    /// eight plain resends as before (`NO_CEILING`).
    pub fn next(&mut self, now: f64, capped: bool) -> Option<u8> {
        if self.done || now < self.due {
            return None;
        }
        self.tries += 1;
        if self.tries > MOST {
            self.done = true;
            return None;
        }
        self.due = now + 0.2; // until it's back from the encoder; one the rate control dropped goes again then
        if !capped {
            if self.tries >= 8 {
                self.done = true;
            }
            return Some(NO_CEILING);
        }
        Some(self.cap)
    }

    /// The resend made under `cap` went, this large. `bitrate`: what a step may cost is measured against it. `pace`: the rate the
    /// resends go at, bits a second: the bitrate, or more while they also find out what the network carries (rate.rs). Returns how
    /// long the next one waits for this one to get through (0 for a resend that isn't this picture's).
    pub fn sent(&mut self, cap: u8, bytes: usize, bitrate: i64, pace: i64, now: f64) -> f64 {
        if self.done || self.tries == 0 || cap != self.cap {
            return 0.0;
        }
        let wait = (bytes as f64 * 8.0 / pace.max(1) as f64).max(0.1);
        if self.cap <= SHARP {
            self.done = true;
            return wait;
        }
        let budget = (bitrate / 20) as usize; // 0.4 s of the rate, in bytes
        if bytes > budget {
            self.step = (self.step / 2).max(1);
        } else if bytes < budget / 3 {
            self.step = (self.step + 2).min(8);
        }
        self.cap = self.cap.saturating_sub(self.step).max(SHARP);
        self.due = now + wait;
        wait
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_still_picture_is_sharpened_in_steps_that_fit_the_rate() {
        let mut s = Sharpen::default();
        let (mut now, mut caps, mut total) = (0.0, vec![], 0usize);
        while !s.done && caps.len() < 50 {
            let Some(cap) = s.next(now, true) else {
                now += 0.05;
                continue;
            };
            caps.push(cap);
            assert_eq!(s.next(now + 0.1, true), None, "one at a time");
            let bytes = if cap > 34 { 45_000 } else if cap > 28 { 90_000 } else { 130_000 };
            total += bytes;
            s.sent(cap, bytes, 2_000_000, 2_000_000, now);
            assert_eq!(s.next(now + bytes as f64 * 8.0 / 2e6 - 0.01, true), None, "not before the last one is through");
        }
        assert_eq!(caps.first(), Some(&40));
        assert_eq!(caps.last(), Some(&SHARP), "it ends sharp, however many steps that takes");
        assert!(caps.windows(2).all(|w| w[0] > w[1]), "only ever finer");
        assert!(caps.len() < 12);
        assert!(total as f64 * 8.0 / 2e6 <= now + 1.0, "never more than the rate");
        assert_eq!(s.next(now + 100.0, true), None);
    }

    #[test]
    fn steps_are_bigger_when_cheap_and_smaller_when_not() {
        let (mut cheap, mut dear) = (Sharpen::default(), Sharpen::default());
        let (mut a, mut b, mut now) = (vec![], vec![], 0.0);
        for _ in 0..30 {
            if let Some(c) = cheap.next(now, true) {
                a.push(c);
                cheap.sent(c, 5_000, 12_000_000, 12_000_000, now);
            }
            if let Some(c) = dear.next(now, true) {
                b.push(c);
                dear.sent(c, 80_000, 700_000, 700_000, now);
            }
            now += 1.0;
        }
        assert_eq!(a, [40, 34, 26, 22]);
        assert_eq!(b[..4], [40, 38, 37, 36]);
        assert_eq!(b.last(), Some(&22));
    }

    #[test]
    fn a_dropped_resend_goes_again_and_a_moving_picture_starts_over() {
        let mut s = Sharpen::default();
        assert_eq!(s.next(0.0, true), Some(40));
        assert_eq!(s.next(0.1, true), None);
        assert_eq!(s.next(0.21, true), Some(40), "nothing came back: the same step again");
        s.sent(40, 1_000, 2_000_000, 2_000_000, 0.22);
        assert_eq!(s.next(0.4, true), Some(34));
        s.again();
        s.sent(34, 1_000, 2_000_000, 2_000_000, 0.41); // a resend of the picture before: says nothing about this one
        assert_eq!(s.next(0.5, true), Some(40));
        // an encoder that takes no ceiling: eight plain resends, as before
        let mut plain = Sharpen::default();
        let n = (0..20).filter(|i| plain.next(*i as f64, false).is_some()).count();
        assert_eq!(n, 8);
        assert!(plain.done);
        assert!(Sharpen::finished().done);
    }

    #[test]
    fn resends_paced_faster_than_the_rate_wait_less() {
        let mut s = Sharpen::default();
        let cap = s.next(0.0, true).unwrap();
        s.sent(cap, 50_000, 2_000_000, 3_000_000, 0.0);
        assert_eq!(s.next(0.13, true), None);
        assert!(s.next(0.14, true).is_some(), "50 KB at 3 Mbps is 0.133 s");
    }
}
