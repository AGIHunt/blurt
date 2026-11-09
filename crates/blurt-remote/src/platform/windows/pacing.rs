//! When the screen's worker encodes, as a pure state machine (tested on any OS). The worker keeps the last captured picture of
//! the whole monitor on the GPU, so everything here works from it:
//!
//! * a new picture that changed what's in the crop → encode, at `fps` on average (credit.rs: a frame time earns a frame, up to 1.5
//!   saved, and one may go with 0.45 of one; the latest waits for its turn, never lost);
//! * a new crop → encode the picture already held, at once: on Windows a crop change lands on the very next frame, and on a
//!   still screen it lands without waiting for the screen to change (the Mac waits on ScreenCaptureKit);
//! * `refresh` (the server: the screen stopped, sharpen it) and `keyframe` → encode the held picture again, even unchanged.

/// Why the next encode happens.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Due {
    /// a new picture or crop: skip it if the output comes out the same as the last one sent
    pub changed: bool,
    /// asked for (refresh, keyframe): send it even if nothing changed
    pub forced: bool,
    pub keyframe: bool,
}

#[derive(Debug)]
pub struct Pacer {
    fps: u32,
    credit: crate::credit::FrameCredit,
    due: Due,
    /// a picture has been captured at all
    have_picture: bool,
}

/// What the worker should do now.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Next {
    Encode(Due),
    /// nothing to do before this many seconds (or the next event)
    Wait(f64),
    Idle,
}

impl Pacer {
    pub fn new(fps: u32) -> Self {
        Pacer { fps: fps.clamp(1, 120), credit: crate::credit::FrameCredit::new(fps), due: Due::default(), have_picture: false }
    }

    pub fn set_fps(&mut self, fps: u32) {
        self.fps = fps.clamp(1, 120);
        self.credit.set_fps(self.fps);
    }

    pub fn fps(&self) -> u32 {
        self.fps
    }

    /// A captured picture; `in_crop`: it changed something inside the crop being shown (false: only outside it).
    pub fn picture(&mut self, in_crop: bool) {
        self.have_picture = true;
        self.due.changed |= in_crop;
    }

    pub fn crop_changed(&mut self) {
        self.due.changed = true;
    }

    pub fn refresh(&mut self) {
        self.due.forced = true;
    }

    pub fn keyframe(&mut self) {
        self.due.forced = true;
        self.due.keyframe = true;
    }

    pub fn next(&self, now: f64) -> Next {
        if !self.have_picture || !(self.due.changed || self.due.forced) {
            return Next::Idle;
        }
        match self.credit.wait(now) {
            w if w > 1e-9 => Next::Wait(w),
            _ => Next::Encode(self.due),
        }
    }

    /// The worker encoded (or found nothing new to send): everything due until now is done.
    pub fn done(&mut self, now: f64, sent: bool) {
        if sent {
            self.credit.spend(now);
        }
        self.due = Due::default();
    }

    /// The encoder failed or a picture couldn't be made: the keyframe is still owed.
    pub fn retry_keyframe(&mut self) {
        self.due.keyframe = true;
        self.due.forced = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nothing_before_a_picture() {
        let mut p = Pacer::new(60);
        p.keyframe();
        assert_eq!(p.next(0.0), Next::Idle);
        p.picture(true);
        assert_eq!(p.next(0.0), Next::Encode(Due { changed: true, forced: true, keyframe: true }));
    }

    #[test]
    fn frames_at_fps_on_average_and_the_latest_waits() {
        let mut p = Pacer::new(50);
        p.picture(true);
        assert!(matches!(p.next(1.0), Next::Encode(_)));
        p.done(1.0, true);
        assert_eq!(p.next(1.001), Next::Idle);
        // one 5 ms later goes on the credit saved (a still screen saved 1.5)
        p.picture(true);
        assert!(matches!(p.next(1.005), Next::Encode(_)));
        p.done(1.005, true);
        // the next 5 ms after that waits for its turn: 0.45 of a frame's credit, 20 ms a frame
        p.picture(true);
        match p.next(1.010) {
            Next::Wait(w) => assert!((w - 0.009).abs() < 1e-6, "{w}"),
            n => panic!("{n:?}"),
        }
        assert!(matches!(p.next(1.019), Next::Encode(_)));
    }

    #[test]
    fn a_change_outside_the_crop_is_nothing() {
        let mut p = Pacer::new(60);
        p.picture(true);
        p.done(0.0, true);
        p.picture(false);
        assert_eq!(p.next(1.0), Next::Idle);
        // a crop change shows it
        p.crop_changed();
        assert_eq!(p.next(1.0), Next::Encode(Due { changed: true, forced: false, keyframe: false }));
    }

    #[test]
    fn refresh_forces_without_a_new_picture() {
        let mut p = Pacer::new(60);
        p.picture(true);
        p.done(0.0, true);
        p.refresh();
        assert_eq!(p.next(1.0), Next::Encode(Due { changed: false, forced: true, keyframe: false }));
        p.done(1.0, true);
        assert_eq!(p.next(2.0), Next::Idle);
    }

    #[test]
    fn a_skipped_same_picture_does_not_hold_back_the_next() {
        let mut p = Pacer::new(10);
        p.picture(true);
        p.done(0.0, true);
        p.picture(true);
        // the output came out the same: nothing sent, and the clock isn't moved
        p.done(0.2, false);
        p.picture(true);
        assert!(matches!(p.next(0.21), Next::Encode(_)));
    }

    #[test]
    fn fps_change_and_clamps() {
        let mut p = Pacer::new(0);
        assert_eq!(p.fps(), 1);
        p.set_fps(1000);
        assert_eq!(p.fps(), 120);
    }
}
