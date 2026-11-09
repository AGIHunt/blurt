//! Where things are, in numbers: monitors in physical pixels (this process is per-monitor DPI aware), points (the phone's
//! unit: physical ÷ the monitor's scale, so 1 pt is what Windows calls a device-independent pixel), crops in 0…1 of the
//! monitor shown, and SendInput's absolute 0…65535 over the virtual desktop. Pure: unit-tested on any OS.

use crate::host::Crop;

/// A rectangle in physical pixels on the virtual desktop (RECT: right and bottom exclusive).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Rect {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

impl Rect {
    pub fn width(&self) -> i32 {
        self.right - self.left
    }
    pub fn height(&self) -> i32 {
        self.bottom - self.top
    }
    pub fn contains(&self, x: f64, y: f64) -> bool {
        x >= self.left as f64 && x < self.right as f64 && y >= self.top as f64 && y < self.bottom as f64
    }
    pub fn union(&self, o: &Rect) -> Rect {
        Rect { left: self.left.min(o.left), top: self.top.min(o.top), right: self.right.max(o.right), bottom: self.bottom.max(o.bottom) }
    }
    pub fn intersects(&self, o: &Rect) -> bool {
        self.left < o.right && o.left < self.right && self.top < o.bottom && o.top < self.bottom
    }
    /// The nearest point inside (the last pixel, not the exclusive edge).
    pub fn clamp(&self, x: f64, y: f64) -> (f64, f64) {
        (x.clamp(self.left as f64, (self.right - 1) as f64), y.clamp(self.top as f64, (self.bottom - 1) as f64))
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Monitor {
    /// physical pixels on the virtual desktop
    pub rect: Rect,
    /// effective DPI ÷ 96 (1.5 at 150 %)
    pub scale: f64,
    pub primary: bool,
    /// HMONITOR, to find it again (0 in tests)
    pub handle: isize,
}

impl Monitor {
    /// Its size in points (ToPhone.screenView, RemoteSessionInfo.displayAspect).
    pub fn points(&self) -> (f64, f64) {
        let s = if self.scale > 0.0 { self.scale } else { 1.0 };
        (self.rect.width() as f64 / s, self.rect.height() as f64 / s)
    }

    /// 0…1 of this monitor (outside 0…1 when the point is on another).
    pub fn normalise(&self, x: f64, y: f64) -> (f64, f64) {
        ((x - self.rect.left as f64) / self.rect.width().max(1) as f64, (y - self.rect.top as f64) / self.rect.height().max(1) as f64)
    }

    /// A point on this monitor from 0…1 (clamped onto it).
    pub fn place(&self, nx: f64, ny: f64) -> (f64, f64) {
        let nx = if nx.is_finite() { nx.clamp(0.0, 1.0) } else { 0.5 };
        let ny = if ny.is_finite() { ny.clamp(0.0, 1.0) } else { 0.5 };
        self.rect.clamp(self.rect.left as f64 + nx * self.rect.width() as f64, self.rect.top as f64 + ny * self.rect.height() as f64)
    }
}

/// The monitor a point is on.
pub fn monitor_at(monitors: &[Monitor], x: f64, y: f64) -> Option<&Monitor> {
    monitors.iter().find(|m| m.rect.contains(x, y))
}

/// The point itself when it's on a monitor, else the nearest point of the nearest one: a move off the edge of one lands on the
/// edge, unless another monitor is there (the Mac's `clamp`).
pub fn clamp_to_monitors(monitors: &[Monitor], x: f64, y: f64) -> (f64, f64) {
    if monitors.is_empty() || monitor_at(monitors, x, y).is_some() {
        return (x, y);
    }
    let mut best = (x, y);
    let mut dist = f64::INFINITY;
    for m in monitors {
        let q = m.rect.clamp(x, y);
        let d = (q.0 - x).hypot(q.1 - y);
        if d < dist {
            dist = d;
            best = q;
        }
    }
    best
}

/// A relative move in points from where the pointer is (fractions kept by the caller): the points are the monitor's it starts
/// on, so 10 pt is 15 px on a 150 % monitor and 10 px on a 100 % one beside it.
pub fn move_by(monitors: &[Monitor], from: (f64, f64), dx: f64, dy: f64) -> (f64, f64) {
    let scale = monitor_at(monitors, from.0, from.1).map_or(1.0, |m| m.scale);
    let (dx, dy) = (finite(dx) * scale, finite(dy) * scale);
    clamp_to_monitors(monitors, from.0 + dx, from.1 + dy)
}

fn finite(v: f64) -> f64 {
    if v.is_finite() {
        v
    } else {
        0.0
    }
}

/// The virtual desktop: every monitor.
pub fn virtual_desktop(monitors: &[Monitor]) -> Rect {
    monitors.iter().map(|m| m.rect).reduce(|a, b| a.union(&b)).unwrap_or(Rect { left: 0, top: 0, right: 1, bottom: 1 })
}

/// SendInput's MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK coordinates for a physical pixel: 0…65535 over the virtual desktop.
/// Windows maps n back to the pixel ⌊n · width / 65536⌋, so the pixel's middle is aimed at and it lands exactly there.
pub fn to_absolute(desk: &Rect, x: f64, y: f64) -> (i32, i32) {
    let f = |v: f64, lo: i32, len: i32| -> i32 {
        let len = len.max(1) as f64;
        let px = (v.floor() - lo as f64).clamp(0.0, len - 1.0);
        (((px + 0.5) * 65536.0 / len).floor() as i32).clamp(0, 65535)
    };
    (f(x, desk.left, desk.width()), f(y, desk.top, desk.height()))
}

/// Inside the source and not absurdly small, whatever arrived (RemoteCrop.valid).
pub fn valid_crop(c: Crop) -> Crop {
    if ![c.x, c.y, c.w, c.h].iter().all(|v| v.is_finite()) {
        return Crop::WHOLE;
    }
    let w = c.w.clamp(0.1, 1.0);
    let h = c.h.clamp(0.1, 1.0);
    Crop { x: c.x.clamp(0.0, 1.0 - w), y: c.y.clamp(0.0, 1.0 - h), w, h }
}

/// A crop's pixels in a source `sw`×`sh` (the captured monitor), rounded to whole pixels, at least 2×2. With the crop
/// those pixels really are (0…1), which is what the frame is tagged with: the phone places it exactly. Whole stays exactly whole.
pub fn crop_rect(c: Crop, sw: u32, sh: u32) -> (Rect, Crop) {
    let c = valid_crop(c);
    let (sw, sh) = (sw.max(2) as f64, sh.max(2) as f64);
    let left = (c.x as f64 * sw).round().clamp(0.0, sw - 2.0);
    let top = (c.y as f64 * sh).round().clamp(0.0, sh - 2.0);
    let right = ((c.x + c.w) as f64 * sw).round().clamp(left + 2.0, sw);
    let bottom = ((c.y + c.h) as f64 * sh).round().clamp(top + 2.0, sh);
    let r = Rect { left: left as i32, top: top as i32, right: right as i32, bottom: bottom as i32 };
    let shown = Crop {
        x: (left / sw) as f32,
        y: (top / sh) as f32,
        w: ((right - left) / sw) as f32,
        h: ((bottom - top) / sh) as f32,
    };
    (r, shown)
}

/// The output size: the source's shape, as large as asked for and no larger than the source has pixels, even numbers (the Mac's
/// RemoteScreen.start). `longest`: a cap on the longer side (the software encoder's lower size).
pub fn output_size(want_w: u32, want_h: u32, sw: u32, sh: u32, longest: Option<u32>) -> (u32, u32) {
    let (sw, sh) = (sw.max(2) as f64, sh.max(2) as f64);
    let (ww, wh) = (want_w.clamp(64, 8192) as f64, want_h.clamp(64, 8192) as f64);
    let mut k = (ww / sw).min(wh / sh).min(1.0);
    if let Some(l) = longest {
        k = k.min(l as f64 / sw.max(sh));
    }
    // 2400 · (1150 / 2400) may come out a hair under 1150
    let even = |v: f64| (((v + 1e-6).floor() as u32) / 2 * 2).max(16);
    (even(sw * k), even(sh * k))
}

/// A rectangle (dirty region) in source pixels touches the part being shown.
pub fn touches(dirty: &[Rect], shown: &Rect) -> bool {
    dirty.iter().any(|d| d.intersects(shown))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mon(left: i32, top: i32, w: i32, h: i32, scale: f64) -> Monitor {
        Monitor { rect: Rect { left, top, right: left + w, bottom: top + h }, scale, primary: left == 0 && top == 0, handle: 0 }
    }

    /// A 4K at 150 % on the left, a 1080p at 100 % to its right, lower down.
    fn desk() -> Vec<Monitor> {
        vec![mon(0, 0, 3840, 2160, 1.5), mon(3840, 400, 1920, 1080, 1.0)]
    }

    #[test]
    fn points_are_physical_over_scale() {
        assert_eq!(desk()[0].points(), (2560.0, 1440.0));
        assert_eq!(desk()[1].points(), (1920.0, 1080.0));
        assert_eq!(mon(0, 0, 2880, 1800, 2.0).points(), (1440.0, 900.0));
    }

    #[test]
    fn relative_moves_use_the_monitor_they_start_on() {
        let d = desk();
        assert_eq!(move_by(&d, (100.0, 100.0), 10.0, -4.0), (115.0, 94.0));
        assert_eq!(move_by(&d, (4000.0, 500.0), 10.0, -4.0), (4010.0, 496.0));
        // across into the other monitor
        assert_eq!(move_by(&d, (3830.0, 500.0), 20.0, 0.0), (3860.0, 500.0));
        // off the top-right of the 1080p (y 0…400 there is nothing): lands on its edge
        assert_eq!(move_by(&d, (5000.0, 410.0), 0.0, -100.0), (5000.0, 400.0));
        // off the far right
        assert_eq!(move_by(&d, (5900.0, 500.0), 100.0, 0.0), (5759.0, 500.0));
        // NaN from the wire doesn't move it
        assert_eq!(move_by(&d, (10.0, 10.0), f64::NAN, f64::INFINITY), (10.0, 10.0));
    }

    #[test]
    fn sub_pixel_moves_add_up_in_the_caller() {
        // the caller keeps the f64 position: forty 0.1 pt moves on a 150 % monitor are 6 px
        let d = desk();
        let mut p = (100.0, 100.0);
        for _ in 0..40 {
            p = move_by(&d, p, 0.1, 0.0);
        }
        assert!((p.0 - 106.0).abs() < 1e-9);
    }

    #[test]
    fn absolute_lands_on_the_pixel() {
        let d = desk();
        let v = virtual_desktop(&d);
        assert_eq!(v, Rect { left: 0, top: 0, right: 5760, bottom: 2160 });
        for &(x, y) in &[(0.0, 0.0), (1.0, 1.0), (2559.7, 1439.2), (3839.0, 2159.0), (3840.0, 400.0), (5759.0, 1479.0)] {
            let (nx, ny) = to_absolute(&v, x, y);
            // what Windows does with them
            let bx = (nx as i64 * v.width() as i64) >> 16;
            let by = (ny as i64 * v.height() as i64) >> 16;
            assert_eq!((bx, by), (x.floor() as i64, y.floor() as i64), "{x},{y}");
        }
        // with a monitor left of the primary (negative coordinates)
        let d2 = vec![mon(-1920, 0, 1920, 1080, 1.0), mon(0, 0, 2560, 1440, 1.25)];
        let v2 = virtual_desktop(&d2);
        let (nx, _) = to_absolute(&v2, -1920.0, 0.0);
        assert_eq!(nx, 7);
        let (nx, _) = to_absolute(&v2, 0.0, 0.0);
        assert_eq!((nx as i64 * v2.width() as i64) >> 16, 1920);
    }

    #[test]
    fn normalise_and_place() {
        let m = desk()[1];
        assert_eq!(m.normalise(3840.0 + 960.0, 400.0 + 540.0), (0.5, 0.5));
        assert_eq!(m.place(0.5, 0.5), (4800.0, 940.0));
        assert_eq!(m.place(1.0, 1.0), (5759.0, 1479.0));
        assert_eq!(m.place(-3.0, f64::NAN), (3840.0, 940.0));
        // on another monitor: outside 0…1
        assert!(m.normalise(10.0, 10.0).0 < 0.0);
    }

    #[test]
    fn crops_round_to_pixels_and_say_so() {
        let (r, shown) = crop_rect(Crop::WHOLE, 3840, 2160);
        assert_eq!(r, Rect { left: 0, top: 0, right: 3840, bottom: 2160 });
        assert_eq!(shown, Crop::WHOLE);
        let (r, shown) = crop_rect(Crop { x: 0.25, y: 0.25, w: 0.5, h: 0.5 }, 3840, 2160);
        assert_eq!(r, Rect { left: 960, top: 540, right: 2880, bottom: 1620 });
        assert_eq!(shown, Crop { x: 0.25, y: 0.25, w: 0.5, h: 0.5 });
        // a crop between pixels says where it really is
        let (r, shown) = crop_rect(Crop { x: 0.1234, y: 0.0, w: 0.3333, h: 0.3333 }, 1366, 768);
        assert_eq!(r.left, 169);
        assert!((shown.x - 169.0 / 1366.0).abs() < 1e-7);
        assert!((shown.x - 0.1234).abs() < 0.5 / 1366.0 + 1e-6);
        // outside, absurdly small, NaN
        assert_eq!(crop_rect(Crop { x: 0.95, y: -1.0, w: 0.5, h: 0.01 }, 1000, 1000).0, Rect { left: 500, top: 0, right: 1000, bottom: 100 });
        assert_eq!(crop_rect(Crop { x: f32::NAN, y: 0.0, w: 1.0, h: 1.0 }, 1000, 1000).1, Crop::WHOLE);
    }

    #[test]
    fn output_keeps_the_source_shape() {
        // a phone asking for 2042×1150 of a 16:10 4K-wide monitor: the monitor's shape, 2042 wide at most
        assert_eq!(output_size(2042, 1150, 3840, 2400, None), (1840, 1150));
        // never more pixels than the source has
        assert_eq!(output_size(4000, 4000, 1920, 1080, None), (1920, 1080));
        // the software encoder's cap
        assert_eq!(output_size(2042, 1150, 2560, 1440, Some(1280)), (1280, 720));
        // odd numbers become even
        assert_eq!(output_size(1001, 1001, 1366, 768, None), (1000, 562));
    }

    #[test]
    fn dirty_regions_against_the_crop() {
        let shown = Rect { left: 100, top: 100, right: 200, bottom: 200 };
        assert!(!touches(&[], &shown));
        assert!(!touches(&[Rect { left: 0, top: 0, right: 100, bottom: 100 }], &shown));
        assert!(touches(&[Rect { left: 0, top: 0, right: 101, bottom: 101 }], &shown));
        assert!(touches(&[Rect { left: 150, top: 150, right: 151, bottom: 151 }], &shown));
    }
}
