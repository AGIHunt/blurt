//! A copy of the monitor kept up to date from PipeWire's frames, so the crop can be cut from it at any time.
//!
//! GNOME sends a frame only when something changed, and says what (video damage). A new crop on a still screen has no new frame
//! to come from, so the picture is cut from this copy instead; each frame only copies its damaged rectangles in (a keystroke
//! in a terminal is a few kilobytes, not the whole screen). The cut is what's encoded, so a change outside the phone's view
//! costs nothing, and an unchanged cut (the same pixels again) is skipped. Pure: tested on any OS.

use super::math::Rect;

const BPP: usize = 4;

#[derive(Default)]
pub struct Mirror {
    pub width: u32,
    pub height: u32,
    /// the frames' pixel format as GStreamer names it (BGRx, RGBA…)
    pub format: &'static str,
    px: Vec<u8>,
    /// a whole frame has been copied in: until then a cut would show black
    pub ready: bool,
}

impl Mirror {
    /// Copy a frame in: `damage` rectangles only (None: all of it). A new size or format starts over.
    pub fn apply(&mut self, src: &[u8], stride: usize, width: u32, height: u32, format: &'static str, damage: Option<&[Rect]>) -> bool {
        let row = width as usize * BPP;
        if width == 0 || height == 0 || stride < row || src.len() < stride * (height as usize - 1) + row {
            return false;
        }
        let mut damage = damage;
        if width != self.width || height != self.height || format != self.format {
            self.width = width;
            self.height = height;
            self.format = format;
            self.px = vec![0; row * height as usize];
            self.ready = false;
        }
        if !self.ready {
            damage = None;
        }
        let whole = [Rect { x: 0, y: 0, w: width, h: height }];
        for d in damage.unwrap_or(&whole) {
            let x0 = d.x.min(width) as usize;
            let y0 = d.y.min(height) as usize;
            let x1 = (d.x.saturating_add(d.w)).min(width) as usize;
            let y1 = (d.y.saturating_add(d.h)).min(height) as usize;
            if x1 <= x0 || y1 <= y0 {
                continue;
            }
            for y in y0..y1 {
                let s = y * stride + x0 * BPP;
                let t = y * row + x0 * BPP;
                let n = (x1 - x0) * BPP;
                self.px[t..t + n].copy_from_slice(&src[s..s + n]);
            }
        }
        self.ready = true;
        true
    }

    /// The pixels of `r`, packed (stride = width × 4). `same_as`: the last cut of the same rectangle; Some(None) back when
    /// nothing differs.
    pub fn cut(&self, r: Rect, same_as: Option<&[u8]>) -> Option<Option<Vec<u8>>> {
        if !self.ready || r.x + r.w > self.width || r.y + r.h > self.height || r.w == 0 || r.h == 0 {
            return None;
        }
        let row = self.width as usize * BPP;
        let n = r.w as usize * BPP;
        let mut out = Vec::with_capacity(n * r.h as usize);
        let mut differs = same_as.is_none_or(|p| p.len() != n * r.h as usize);
        for y in r.y as usize..(r.y + r.h) as usize {
            let s = y * row + r.x as usize * BPP;
            let line = &self.px[s..s + n];
            if !differs {
                let o = (y - r.y as usize) * n;
                differs = same_as.is_some_and(|p| &p[o..o + n] != line);
            }
            out.extend_from_slice(line);
        }
        Some(differs.then_some(out))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(w: u32, h: u32, stride: usize, f: impl Fn(u32, u32) -> u8) -> Vec<u8> {
        let mut v = vec![0xEE; stride * h as usize];
        for y in 0..h {
            for x in 0..w {
                for c in 0..4 {
                    v[y as usize * stride + x as usize * 4 + c] = f(x, y).wrapping_add(c as u8);
                }
            }
        }
        v
    }

    #[test]
    fn cuts_follow_damage_and_stride() {
        let mut m = Mirror::default();
        let a = frame(8, 4, 40, |x, y| (x + 10 * y) as u8);
        assert!(m.cut(Rect { x: 0, y: 0, w: 2, h: 2 }, None).is_none(), "nothing in yet");
        assert!(m.apply(&a, 40, 8, 4, "BGRx", Some(&[])), "the first frame is copied whole whatever the damage");
        let r = Rect { x: 2, y: 1, w: 4, h: 2 };
        let first = m.cut(r, None).unwrap().unwrap();
        assert_eq!(first.len(), 4 * 2 * 4);
        assert_eq!(first[0], 12, "pixel (2,1)");
        // a frame that changed everywhere, but only says (0,0)-(1,1): only that is taken
        let b = frame(8, 4, 40, |x, y| (x + 10 * y + 100) as u8);
        m.apply(&b, 40, 8, 4, "BGRx", Some(&[Rect { x: 0, y: 0, w: 1, h: 1 }]));
        assert_eq!(m.cut(r, Some(&first)).unwrap(), None, "outside the crop: the same cut");
        m.apply(&b, 40, 8, 4, "BGRx", Some(&[Rect { x: 5, y: 2, w: 9, h: 9 }]));
        let second = m.cut(r, Some(&first)).unwrap().expect("changed inside");
        assert_eq!(second[(4 + 3) * 4], 5 + 20 + 100, "pixel (5,2) is new");
        assert_eq!(second[0], 12, "pixel (2,1) is not");
    }

    #[test]
    fn a_new_size_starts_over_and_bad_input_is_refused() {
        let mut m = Mirror::default();
        m.apply(&frame(4, 4, 16, |_, _| 1), 16, 4, 4, "BGRx", None);
        m.apply(&frame(6, 2, 24, |_, _| 2), 24, 6, 2, "BGRx", Some(&[]));
        assert_eq!((m.width, m.height), (6, 2));
        assert_eq!(m.cut(Rect { x: 0, y: 0, w: 6, h: 2 }, None).unwrap().unwrap()[0], 2);
        assert!(!m.apply(&[0; 10], 16, 4, 4, "BGRx", None));
        assert!(m.cut(Rect { x: 4, y: 0, w: 4, h: 2 }, None).is_none(), "past the edge");
    }
}
