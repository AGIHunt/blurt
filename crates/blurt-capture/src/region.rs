//! The recorded area. On Windows and Linux (the platforms this crate is for) a [`Region`] is in physical pixels of
//! the virtual desktop / X screen — what gdigrab and x11grab take — and that is what `record.py --region` receives.

use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Region {
    pub x: i32,
    pub y: i32,
    pub w: u32,
    pub h: u32,
}

/// A rectangle in a window's CSS pixels (what an overlay page reports).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct CssRect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Region {
    pub const fn new(x: i32, y: i32, w: u32, h: u32) -> Self {
        Self { x, y, w, h }
    }

    /// The rectangle spanned by two corners, in any order (a drag).
    pub fn from_corners(a: (i32, i32), b: (i32, i32)) -> Self {
        let (x0, x1) = (a.0.min(b.0), a.0.max(b.0));
        let (y0, y1) = (a.1.min(b.1), a.1.max(b.1));
        Self::new(x0, y0, (x1 - x0) as u32, (y1 - y0) as u32)
    }

    /// A rect from an overlay page (CSS px, relative to its window) on the desktop: `origin` = the window's inner
    /// position in physical px, `scale` = its scale factor.
    pub fn from_css(r: CssRect, origin: (i32, i32), scale: f64) -> Self {
        let x0 = origin.0 + (r.x * scale).round() as i32;
        let y0 = origin.1 + (r.y * scale).round() as i32;
        let x1 = origin.0 + ((r.x + r.w) * scale).round() as i32;
        let y1 = origin.1 + ((r.y + r.h) * scale).round() as i32;
        Self::from_corners((x0, y0), (x1, y1))
    }

    /// Even width and height (yuv420p / H.264 refuse odd sizes); record.py does the same.
    pub fn even(self) -> Self {
        Self { w: self.w & !1, h: self.h & !1, ..self }
    }

    pub fn right(&self) -> i32 {
        self.x + self.w as i32
    }

    pub fn bottom(&self) -> i32 {
        self.y + self.h as i32
    }

    pub fn is_empty(&self) -> bool {
        self.w == 0 || self.h == 0
    }

    pub fn contains(&self, x: i32, y: i32) -> bool {
        x >= self.x && x < self.right() && y >= self.y && y < self.bottom()
    }

    pub fn intersect(&self, o: &Region) -> Option<Region> {
        let (x0, y0) = (self.x.max(o.x), self.y.max(o.y));
        let (x1, y1) = (self.right().min(o.right()), self.bottom().min(o.bottom()));
        (x1 > x0 && y1 > y0).then(|| Region::from_corners((x0, y0), (x1, y1)))
    }

    /// Where a bar of `size` goes so that it is not recorded: centred below the region if the monitor has room,
    /// else above it, else inside along the bottom edge (Linux can't hide windows from x11grab).
    pub fn place_outside(&self, size: (u32, u32), monitor: &Region, gap: i32) -> (i32, i32) {
        let (w, h) = (size.0 as i32, size.1 as i32);
        let x = (self.x + (self.w as i32 - w) / 2).clamp(monitor.x, (monitor.right() - w).max(monitor.x));
        if self.bottom() + gap + h <= monitor.bottom() {
            (x, self.bottom() + gap)
        } else if self.y - gap - h >= monitor.y {
            (x, self.y - gap - h)
        } else {
            (x, (self.bottom() - gap - h).max(monitor.y))
        }
    }
}

impl fmt::Display for Region {
    /// `x,y,w,h` — the `record.py --region` form.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{},{},{},{}", self.x, self.y, self.w, self.h)
    }
}

impl FromStr for Region {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let v: Vec<f64> = s
            .split(',')
            .map(|p| p.trim().parse::<f64>().map_err(|e| format!("{p:?}: {e}")))
            .collect::<Result<_, _>>()?;
        match v[..] {
            [x, y, w, h] if w >= 0.0 && h >= 0.0 => Ok(Region::new(x as i32, y as i32, w as u32, h as u32)),
            _ => Err(format!("region needs x,y,w,h (got {s:?})")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn corners_any_order() {
        assert_eq!(Region::from_corners((50, 80), (10, 20)), Region::new(10, 20, 40, 60));
    }

    #[test]
    fn css_to_physical() {
        let r = Region::from_css(CssRect { x: 10.0, y: 20.0, w: 100.5, h: 50.0 }, (-1920, 0), 1.5);
        assert_eq!(r, Region::new(-1905, 30, 151, 75));
        assert_eq!(r.even(), Region::new(-1905, 30, 150, 74));
    }

    #[test]
    fn parse_and_print() {
        let r: Region = "1, 2,321,241".parse().unwrap();
        assert_eq!(r.to_string(), "1,2,321,241");
        assert!("1,2,3".parse::<Region>().is_err());
        assert!("a,2,3,4".parse::<Region>().is_err());
    }

    #[test]
    fn intersect() {
        let a = Region::new(0, 0, 100, 100);
        assert_eq!(a.intersect(&Region::new(50, 50, 100, 100)), Some(Region::new(50, 50, 50, 50)));
        assert_eq!(a.intersect(&Region::new(100, 0, 10, 10)), None);
    }

    #[test]
    fn bar_goes_outside_the_region() {
        let mon = Region::new(0, 0, 1920, 1080);
        assert_eq!(Region::new(100, 100, 800, 600).place_outside((300, 48), &mon, 10), (350, 710));
        assert_eq!(Region::new(100, 500, 800, 560).place_outside((300, 48), &mon, 10), (350, 442));
        assert_eq!(mon.place_outside((300, 48), &mon, 10), (810, 1022)); // full screen: inside, bottom
        assert_eq!(Region::new(1800, 100, 100, 100).place_outside((300, 48), &mon, 10), (1620, 210));
    }
}
