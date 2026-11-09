//! The pointer's arithmetic: scroll points → wheel units, and clicks that Windows must count as the server did. Pure: tested on
//! any OS.

use crate::host::Button;

/// WHEEL_DELTA: one notch of a wheel.
pub const WHEEL_DELTA: f64 = 120.0;

/// Wheel units for one point of scroll. A notch (120) scrolls the user's "lines per notch" (SPI_GETWHEELSCROLLLINES, 3 by
/// default), and browsers and most apps draw a line as 100/3 points, so 100 pt a notch by default: the content then moves as
/// far as the finger did, as on the Mac. `lines` 0 (scrolling off) or WHEEL_PAGESCROLL (a page a notch) fall back to 3.
pub fn units_per_point(lines: u32) -> f64 {
    let lines = if lines == 0 || lines > 100 { 3 } else { lines };
    WHEEL_DELTA / (lines as f64 * 100.0 / 3.0)
}

/// Fractions of a wheel unit kept between events: a slow scroll adds up instead of rounding away, and every event that goes
/// out is a whole number of units (high-resolution: not multiples of 120; apps that only take whole notches add them up
/// themselves, as they do for a precision touchpad).
#[derive(Default, Debug)]
pub struct Wheel {
    rest_x: f64,
    rest_y: f64,
}

impl Wheel {
    /// Points scrolled (host.rs: positive dy = content moves down = scrolls up; positive dx = content moves right = scrolls
    /// left) → (MOUSEEVENTF_HWHEEL, MOUSEEVENTF_WHEEL) units. Windows: a positive WHEEL scrolls up, a positive HWHEEL right.
    pub fn add(&mut self, dx: f64, dy: f64, per_point: f64) -> (i32, i32) {
        let f = |v: f64| if v.is_finite() { v.clamp(-100_000.0, 100_000.0) } else { 0.0 };
        let h = -f(dx) * per_point + self.rest_x;
        let v = f(dy) * per_point + self.rest_y;
        // 100 × 0.36 is a hair under 36 in binary: a unit that's all but there goes now
        let whole = |u: f64| (u + u.signum() * 1e-9).trunc();
        let (hi, vi) = (whole(h), whole(v));
        self.rest_x = h - hi;
        self.rest_y = v - vi;
        (hi as i32, vi as i32)
    }

    /// A new gesture starts from nothing.
    pub fn reset(&mut self) {
        *self = Wheel::default();
    }
}

/// What was last pressed, as Windows saw it.
#[derive(Clone, Copy, Debug)]
pub struct LastDown {
    pub button: Button,
    /// the event's time (GetTickCount, ms)
    pub at: u32,
    /// physical pixels
    pub x: f64,
    pub y: f64,
    /// when it came up again (0: not yet)
    pub up_at: u32,
}

/// How to send a button press so Windows counts it as the server did.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ClickPlan {
    /// put the pointer back where the first click was (Windows counts a second click only within SM_CXDOUBLECLK of it)
    pub move_to: Option<(f64, f64)>,
    /// the event's time stamp (MOUSEINPUT.time) instead of now: within GetDoubleClickTime of the first click
    pub time: Option<u32>,
}

/// Windows counts double clicks itself, by time (GetDoubleClickTime, 500 ms) and distance (SM_CXDOUBLECLK × SM_CYDOUBLECLK,
/// 4 × 4 px, around the first). The server counts on the phone's side (host.rs `button`): a double click it sends must land as
/// one even when Wi-Fi delayed the second tap past the system's time, or the finger came down a few pixels off.
/// `clicks` 2 / 3 → the plan that makes Windows agree; 1 → nothing to change.
pub fn plan_down(
    last: Option<&LastDown>,
    button: Button,
    clicks: u32,
    now: u32,
    at: (f64, f64),
    double_time: u32,
    double_box: (i32, i32),
) -> ClickPlan {
    let mut plan = ClickPlan { move_to: None, time: None };
    let Some(l) = last.filter(|l| clicks >= 2 && l.button == button) else { return plan };
    let (bx, by) = ((double_box.0.max(1) as f64) / 2.0, (double_box.1.max(1) as f64) / 2.0);
    let (dx, dy) = ((at.0 - l.x).abs(), (at.1 - l.y).abs());
    // the server said same spot; far off is a mistake of its own, not ours to hide
    if (dx > bx || dy > by) && dx.hypot(dy) <= 64.0 {
        plan.move_to = Some((l.x, l.y));
    }
    let gap = now.wrapping_sub(l.at);
    if gap >= double_time.saturating_sub(10) {
        // after the first click came up, and well inside the time Windows allows
        let up = if l.up_at != 0 && l.up_at.wrapping_sub(l.at) < double_time / 2 { l.up_at.wrapping_add(1) } else { l.at.wrapping_add(1) };
        plan.time = Some(up.max(l.at.wrapping_add(1)));
    }
    plan
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_notch_is_100_points_by_default() {
        assert!((units_per_point(3) - 1.2).abs() < 1e-12);
        assert!((units_per_point(0) - 1.2).abs() < 1e-12);
        assert!((units_per_point(u32::MAX) - 1.2).abs() < 1e-12);
        // one line a notch: the content still moves with the finger
        assert!((units_per_point(1) - 3.6).abs() < 1e-12);
    }

    #[test]
    fn directions() {
        let mut w = Wheel::default();
        // content down (scroll up): positive WHEEL; content right (scroll left): negative HWHEEL
        assert_eq!(w.add(0.0, 100.0, 1.2), (0, 120));
        assert_eq!(w.add(100.0, 0.0, 1.2), (-120, 0));
        assert_eq!(w.add(-50.0, -50.0, 1.2), (60, -60));
    }

    #[test]
    fn slow_scrolls_add_up() {
        let mut w = Wheel::default();
        let mut total = 0;
        let mut sent = 0;
        for _ in 0..100 {
            let (_, v) = w.add(0.0, 0.3, 1.2);
            if v != 0 {
                sent += 1;
            }
            total += v;
        }
        // 100 × 0.36 units = 36, none lost, sent as ones
        assert_eq!(total, 36);
        assert_eq!(sent, 36);
        // and backwards
        let mut w = Wheel::default();
        let t: i32 = (0..10).map(|_| w.add(0.0, -0.25, 1.2).1).sum();
        assert_eq!(t, -3);
        w.reset();
        assert_eq!(w.add(0.0, 0.5, 1.2), (0, 0));
    }

    #[test]
    fn nonsense_scrolls_are_nothing() {
        let mut w = Wheel::default();
        assert_eq!(w.add(f64::NAN, f64::INFINITY, 1.2), (0, 0));
    }

    fn last(at: u32, up_at: u32) -> LastDown {
        LastDown { button: Button::Left, at, x: 500.0, y: 300.0, up_at }
    }

    #[test]
    fn a_single_click_changes_nothing() {
        let l = last(1000, 1080);
        assert_eq!(plan_down(Some(&l), Button::Left, 1, 1200, (520.0, 300.0), 500, (4, 4)), ClickPlan { move_to: None, time: None });
    }

    #[test]
    fn a_double_click_in_time_and_place_is_left_alone() {
        let l = last(1000, 1080);
        assert_eq!(plan_down(Some(&l), Button::Left, 2, 1200, (501.0, 301.0), 500, (4, 4)), ClickPlan { move_to: None, time: None });
    }

    #[test]
    fn a_late_or_shifted_second_click_is_made_to_count() {
        let l = last(1000, 1080);
        // a few pixels off: back onto the first
        let p = plan_down(Some(&l), Button::Left, 2, 1200, (506.0, 300.0), 500, (4, 4));
        assert_eq!(p.move_to, Some((500.0, 300.0)));
        assert_eq!(p.time, None);
        // late: stamped just after the first came up
        let p = plan_down(Some(&l), Button::Left, 2, 1700, (500.0, 300.0), 500, (4, 4));
        assert_eq!(p.time, Some(1081));
        // late, and the first's up never seen
        let p = plan_down(Some(&last(1000, 0)), Button::Left, 3, 1900, (500.0, 300.0), 500, (4, 4));
        assert_eq!(p.time, Some(1001));
        // GetTickCount wrapped between them
        let p = plan_down(Some(&last(u32::MAX - 100, 0)), Button::Left, 2, 600, (500.0, 300.0), 500, (4, 4));
        assert_eq!(p.time, Some(u32::MAX - 99));
    }

    #[test]
    fn another_button_or_far_away_is_not_moved() {
        let l = last(1000, 1080);
        assert_eq!(plan_down(Some(&l), Button::Right, 2, 1200, (506.0, 300.0), 500, (4, 4)).move_to, None);
        assert_eq!(plan_down(Some(&l), Button::Left, 2, 1200, (800.0, 300.0), 500, (4, 4)).move_to, None);
        assert_eq!(plan_down(None, Button::Left, 2, 1200, (800.0, 300.0), 500, (4, 4)), ClickPlan { move_to: None, time: None });
    }
}
