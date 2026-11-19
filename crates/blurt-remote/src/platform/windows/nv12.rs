//! The video processor's job on the CPU, for a PC without one (WARP, Microsoft's Basic Render adapter: a VM or cloud desktop with
//! no GPU): a crop of the held picture (BGRA, top-down) scaled to the output size and turned into NV12, BT.709 limited range, as
//! convert.rs writes it and the encoder's VUI says. Pure: unit-tested on any OS.
//!
//! * Scaling is a tent filter as wide as the scale (bilinear going up, every source pixel counted going down, as Pillow's
//!   BILINEAR): small text shrunk 1.5× stays readable instead of losing every other column. Taps stay inside the crop.
//! * Chroma is the mean of each 2×2 block.
//! * Integer only (14-bit weights and coefficients), in bands of output rows on a few threads: 1920×1080 → 1280×720 is a few
//!   milliseconds, next to the software encoder's own.

use super::geometry::Rect;

/// Weights and coefficients are fixed point with this many fraction bits.
const BITS: u32 = 14;
const ONE: i32 = 1 << BITS;

/// BT.709 from full-range R'G'B' to limited range: Y = 16 + 219/255 (Kr R + Kg G + Kb B), Cb/Cr = 128 + 224/255 · (B − Y)/1.8556,
/// (R − Y)/1.5748. Fixed point, `BITS` fraction bits.
const fn fx(v: f64) -> i32 {
    (v * ONE as f64 + if v < 0.0 { -0.5 } else { 0.5 }) as i32
}
const KR: f64 = 0.2126;
const KB: f64 = 0.0722;
const KG: f64 = 1.0 - KR - KB;
const YS: f64 = 219.0 / 255.0;
const CS: f64 = 224.0 / 255.0;
const Y_R: i32 = fx(KR * YS);
const Y_G: i32 = fx(KG * YS);
const Y_B: i32 = fx(KB * YS);
const U_R: i32 = fx(-KR / (2.0 * (1.0 - KB)) * CS);
const U_G: i32 = fx(-KG / (2.0 * (1.0 - KB)) * CS);
const U_B: i32 = fx(0.5 * CS);
const V_R: i32 = fx(0.5 * CS);
const V_G: i32 = fx(-KG / (2.0 * (1.0 - KR)) * CS);
const V_B: i32 = fx(-KB / (2.0 * (1.0 - KR)) * CS);

/// One axis: for each output pixel, `n` weights (summing to `ONE`) from source pixel `start[i]` on (crop-relative).
#[derive(Debug, Default)]
struct Taps {
    start: Vec<usize>,
    n: usize,
    w: Vec<i32>,
}

impl Taps {
    fn new(src: usize, out: usize) -> Taps {
        let scale = src as f64 / out as f64;
        let support = scale.max(1.0);
        let n = ((support * 2.0).ceil() as usize + 1).min(src);
        let mut t = Taps { start: Vec::with_capacity(out), n, w: vec![0; out * n] };
        let mut ws = Vec::with_capacity(n + 2);
        for i in 0..out {
            let centre = (i as f64 + 0.5) * scale - 0.5;
            let lo = ((centre - support).floor() + 1.0).max(0.0) as usize;
            let hi = ((centre + support).ceil() as usize).min(src);
            ws.clear();
            for j in lo..hi.max(lo + 1) {
                ws.push((1.0 - (j as f64 - centre).abs() / support).max(0.0));
            }
            let sum: f64 = ws.iter().sum();
            // the window starts where the first weight is, and never runs off the end
            let start = lo.min(src - n);
            let row = &mut t.w[i * n..i * n + n];
            let mut total = 0;
            for (k, w) in ws.iter().enumerate() {
                let q = if sum > 0.0 { (w / sum * ONE as f64).round() as i32 } else { 0 };
                row[lo - start + k] = q;
                total += q;
            }
            // the rounding's remainder to the largest weight: exactly ONE, so flat colour stays exact
            let big = (0..n).max_by_key(|&k| row[k]).unwrap_or(0);
            row[big] += ONE - total;
            t.start.push(start);
        }
        t
    }
}

/// One band's work: its number, its Y rows and UV rows, its scratch rows.
type Band<'a> = (usize, ((&'a mut [u8], &'a mut [u8]), &'a mut Vec<u16>));

/// BGRA → NV12, keeping the filter for the crop and size it last had.
#[derive(Debug, Default)]
pub struct ToNv12 {
    key: Option<(usize, usize, u32, u32)>,
    xs: Taps,
    ys: Taps,
    bands: Vec<Vec<u16>>,
}

impl ToNv12 {
    pub fn new() -> Self {
        Self::default()
    }

    /// `crop` of `bgra` (`stride` bytes a row) at `out_w`×`out_h` (even), into `out`: `out_w` bytes a row of Y, then the
    /// interleaved UV rows (what `Converter::read` gives).
    pub fn convert(&mut self, bgra: &[u8], stride: usize, crop: &Rect, out_w: u32, out_h: u32, out: &mut Vec<u8>) {
        let (cw, ch) = (crop.width().max(1) as usize, crop.height().max(1) as usize);
        let (w, h) = (out_w as usize & !1, out_h as usize & !1);
        out.resize(w * h * 3 / 2, 0);
        if w == 0 || h == 0 {
            return;
        }
        if self.key != Some((cw, ch, out_w, out_h)) {
            self.xs = Taps::new(cw, w);
            self.ys = Taps::new(ch, h);
            self.key = Some((cw, ch, out_w, out_h));
        }
        let (x0, y0) = (crop.left.max(0) as usize, crop.top.max(0) as usize);
        // bands of even rows, one a thread; small pictures on this thread
        let threads = if w * h >= 256 * 256 { std::thread::available_parallelism().map_or(1, |n| n.get()).clamp(1, 4) } else { 1 };
        let band = (h.div_ceil(threads) + 1) & !1;
        self.bands.resize_with(threads, Vec::new);
        let (luma, chroma) = out.split_at_mut(w * h);
        let (xs, ys) = (&self.xs, &self.ys);
        let job = |(k, ((yrows, uvrows), buf)): Band| {
            let first = k * band;
            band_rows(bgra, stride, x0, y0, xs, ys, w, first, first + yrows.len() / w, yrows, uvrows, buf);
        };
        let parts = luma.chunks_mut(band * w).zip(chroma.chunks_mut(band / 2 * w)).zip(self.bands.iter_mut()).enumerate();
        if threads == 1 {
            parts.for_each(job);
        } else {
            std::thread::scope(|s| {
                let job = &job;
                for p in parts {
                    s.spawn(move || job(p));
                }
            });
        }
    }
}

/// Output rows `from..to` (even): the source rows they reach scaled across into `buf` (R, G, B ×256), then down and into Y and UV.
#[allow(clippy::too_many_arguments)]
fn band_rows(
    bgra: &[u8],
    stride: usize,
    x0: usize,
    y0: usize,
    xs: &Taps,
    ys: &Taps,
    w: usize,
    from: usize,
    to: usize,
    luma: &mut [u8],
    chroma: &mut [u8],
    buf: &mut Vec<u16>,
) {
    if from >= to {
        return;
    }
    let s0 = ys.start[from];
    let s1 = ys.start[to - 1] + ys.n;
    buf.resize((s1 - s0) * w * 3 + w * 6, 0);
    let (rows, pair) = buf.split_at_mut((s1 - s0) * w * 3);
    let nx = xs.n;
    for (r, line) in rows.chunks_exact_mut(w * 3).enumerate() {
        let src = &bgra[(y0 + s0 + r) * stride..];
        for (x, px) in line.as_chunks_mut::<3>().0.iter_mut().enumerate() {
            let at = (x0 + xs.start[x]) * 4;
            let (mut b, mut g, mut rr) = (0i32, 0i32, 0i32);
            for (k, &wt) in xs.w[x * nx..x * nx + nx].iter().enumerate() {
                let p = at + k * 4;
                b += src[p] as i32 * wt;
                g += src[p + 1] as i32 * wt;
                rr += src[p + 2] as i32 * wt;
            }
            // 8 fraction bits kept for the vertical pass
            let keep = |v: i32| ((v + (1 << (BITS - 9))) >> (BITS - 8)) as u16;
            px[0] = keep(rr);
            px[1] = keep(g);
            px[2] = keep(b);
        }
    }
    let ny = ys.n;
    let (top, bottom) = pair.split_at_mut(w * 3);
    for y in (from..to).step_by(2) {
        for (yy, dst) in [(y, &mut *top), (y + 1, &mut *bottom)] {
            let base = (ys.start[yy] - s0) * w * 3;
            let wts = &ys.w[yy * ny..yy * ny + ny];
            for (i, d) in dst.iter_mut().enumerate() {
                let mut acc = 0u32;
                for (k, &wt) in wts.iter().enumerate() {
                    acc += rows[base + k * w * 3 + i] as u32 * wt as u32;
                }
                *d = ((acc + (1 << (BITS - 1))) >> BITS) as u16;
            }
        }
        let r = y - from;
        let (ya, yb) = luma[r * w..(r + 2) * w].split_at_mut(w);
        let uv = &mut chroma[r / 2 * w..(r / 2 + 1) * w];
        for x in (0..w).step_by(2) {
            let p = |row: &[u16], i: usize| (row[i * 3] as i32, row[i * 3 + 1] as i32, row[i * 3 + 2] as i32);
            let quad = [p(top, x), p(top, x + 1), p(bottom, x), p(bottom, x + 1)];
            ya[x] = luma_of(quad[0]);
            ya[x + 1] = luma_of(quad[1]);
            yb[x] = luma_of(quad[2]);
            yb[x + 1] = luma_of(quad[3]);
            let sum = quad.iter().fold((0, 0, 0), |a, q| (a.0 + q.0, a.1 + q.1, a.2 + q.2));
            let mean = ((sum.0 + 2) >> 2, (sum.1 + 2) >> 2, (sum.2 + 2) >> 2);
            let (u, v) = chroma_of(mean);
            uv[x] = u;
            uv[x + 1] = v;
        }
    }
}

/// R, G, B ×256 (0…65280) → Y.
fn luma_of((r, g, b): (i32, i32, i32)) -> u8 {
    let y = (Y_R * r + Y_G * g + Y_B * b + (1 << (BITS + 7))) >> (BITS + 8);
    (16 + y).clamp(16, 235) as u8
}

/// R, G, B ×256 → (Cb, Cr).
fn chroma_of((r, g, b): (i32, i32, i32)) -> (u8, u8) {
    let half = 1 << (BITS + 7);
    let u = (U_R * r + U_G * g + U_B * b + half) >> (BITS + 8);
    let v = (V_R * r + V_G * g + V_B * b + half) >> (BITS + 8);
    ((128 + u).clamp(16, 240) as u8, (128 + v).clamp(16, 240) as u8)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A `w`×`h` BGRA picture, every pixel from `f(x, y)` → (r, g, b), rows `pad` bytes longer than needed (a mapped texture's pitch).
    fn picture(w: usize, h: usize, pad: usize, f: impl Fn(usize, usize) -> (u8, u8, u8)) -> (Vec<u8>, usize) {
        let stride = w * 4 + pad;
        let mut v = vec![0xEE; stride * h];
        for y in 0..h {
            for x in 0..w {
                let (r, g, b) = f(x, y);
                v[y * stride + x * 4..y * stride + x * 4 + 4].copy_from_slice(&[b, g, r, 255]);
            }
        }
        (v, stride)
    }

    fn whole(w: usize, h: usize) -> Rect {
        Rect { left: 0, top: 0, right: w as i32, bottom: h as i32 }
    }

    /// The reference: BT.709 limited range in floating point.
    fn reference(r: u8, g: u8, b: u8) -> (f64, f64, f64) {
        let (r, g, b) = (r as f64 / 255.0, g as f64 / 255.0, b as f64 / 255.0);
        let y = KR * r + KG * g + KB * b;
        (16.0 + 219.0 * y, 128.0 + 224.0 * (b - y) / (2.0 * (1.0 - KB)), 128.0 + 224.0 * (r - y) / (2.0 * (1.0 - KR)))
    }

    fn flat(r: u8, g: u8, b: u8, w: usize, h: usize, ow: u32, oh: u32) -> Vec<u8> {
        let (px, stride) = picture(w, h, 12, |_, _| (r, g, b));
        let mut out = Vec::new();
        ToNv12::new().convert(&px, stride, &whole(w, h), ow, oh, &mut out);
        out
    }

    #[test]
    fn known_colours() {
        // what the encoder's VUI promises: black 16, white 235, neutral chroma 128; the primaries where BT.709 puts them
        for (rgb, want) in [
            ((0, 0, 0), (16, 128, 128)),
            ((255, 255, 255), (235, 128, 128)),
            ((255, 0, 0), (63, 102, 240)),
            ((0, 255, 0), (173, 42, 26)),
            ((0, 0, 255), (32, 240, 118)),
            ((128, 128, 128), (126, 128, 128)),
        ] {
            let out = flat(rgb.0, rgb.1, rgb.2, 32, 32, 32, 32);
            let (y, u, v) = (out[0], out[32 * 32], out[32 * 32 + 1]);
            assert_eq!((y, u, v), want, "{rgb:?}");
            // and every pixel the same
            assert!(out[..32 * 32].iter().all(|&p| p == y));
            assert!(out[32 * 32..].chunks(2).all(|c| c == [u, v]));
        }
    }

    #[test]
    fn matches_the_formula_everywhere() {
        // a spread of colours, each within half a step of the real number
        for r in (0..=255).step_by(51) {
            for g in (0..=255).step_by(51) {
                for b in (0..=255).step_by(17) {
                    let (ry, ru, rv) = reference(r, g, b);
                    let y = luma_of((r as i32 * 256, g as i32 * 256, b as i32 * 256));
                    let (u, v) = chroma_of((r as i32 * 256, g as i32 * 256, b as i32 * 256));
                    assert!((y as f64 - ry).abs() <= 0.51, "Y of {r},{g},{b}: {y} vs {ry}");
                    assert!((u as f64 - ru).abs() <= 0.51, "Cb of {r},{g},{b}: {u} vs {ru}");
                    assert!((v as f64 - rv).abs() <= 0.51, "Cr of {r},{g},{b}: {v} vs {rv}");
                }
            }
        }
    }

    #[test]
    fn flat_colour_survives_any_scale() {
        // exact weights: no drift at the edges, up or down, odd sources
        for (w, h, ow, oh) in [(1920, 1080, 1280, 720), (37, 23, 16, 16), (2, 2, 64, 48), (101, 77, 200, 150), (3840, 2160, 1280, 720)] {
            let out = flat(200, 30, 90, w, h, ow, oh);
            let one = flat(200, 30, 90, 4, 4, 4, 4);
            let (y, uv) = (one[0], [one[16], one[17]]);
            let n = (ow * oh) as usize;
            assert!(out[..n].iter().all(|&p| p == y), "{w}×{h} → {ow}×{oh}");
            assert!(out[n..].chunks(2).all(|c| c == uv), "{w}×{h} → {ow}×{oh}");
        }
    }

    #[test]
    fn one_to_one_is_the_pixels_themselves() {
        // 1:1 is a copy: a one-pixel checkerboard stays one
        let (px, stride) = picture(16, 16, 0, |x, y| if (x + y) % 2 == 0 { (255, 255, 255) } else { (0, 0, 0) });
        let mut out = Vec::new();
        ToNv12::new().convert(&px, stride, &whole(16, 16), 16, 16, &mut out);
        for y in 0..16 {
            for x in 0..16 {
                assert_eq!(out[y * 16 + x], if (x + y) % 2 == 0 { 235 } else { 16 });
            }
        }
        // the 2×2 mean of black and white is grey, no colour
        assert!(out[256..].chunks(2).all(|c| c == [128, 128]));
    }

    #[test]
    fn crop_shows_only_the_crop() {
        // left half red, right half blue: a crop of the right half is all blue, edges included (no taps outside the crop)
        let (px, stride) = picture(101, 60, 8, |x, _| if x < 51 { (255, 0, 0) } else { (0, 0, 255) });
        let crop = Rect { left: 51, top: 7, right: 101, bottom: 53 };
        let mut out = Vec::new();
        ToNv12::new().convert(&px, stride, &crop, 64, 48, &mut out);
        let blue = flat(0, 0, 255, 4, 4, 4, 4);
        assert!(out[..64 * 48].iter().all(|&p| p == blue[0]));
        assert!(out[64 * 48..].chunks(2).all(|c| c == [blue[16], blue[17]]));
    }

    #[test]
    fn scaling_keeps_things_in_place() {
        // a white square on black at (40…60, 20…30) of 200×100, halved: white at (20…30, 10…15), black well away from it
        let (px, stride) = picture(200, 100, 0, |x, y| if (40..60).contains(&x) && (20..30).contains(&y) { (255, 255, 255) } else { (0, 0, 0) });
        let mut out = Vec::new();
        ToNv12::new().convert(&px, stride, &whole(200, 100), 100, 50, &mut out);
        let at = |x: usize, y: usize| out[y * 100 + x];
        assert_eq!(at(25, 12), 235);
        assert_eq!(at(21, 11), 235);
        assert_eq!(at(28, 13), 235);
        assert_eq!(at(10, 12), 16);
        assert_eq!(at(25, 5), 16);
        assert_eq!(at(40, 12), 16);
        // the edge pixel is between (the filter counts both sides)
        assert!(at(19, 12) > 16 && at(19, 12) < 235, "{}", at(19, 12));
        // upscaled 2×: the square at twice the place
        let mut big = Vec::new();
        ToNv12::new().convert(&px, stride, &whole(200, 100), 400, 200, &mut big);
        let at = |x: usize, y: usize| big[y * 400 + x];
        assert_eq!(at(100, 50), 235);
        assert_eq!(at(70, 50), 16);
        assert_eq!(at(100, 70), 16);
    }

    #[test]
    fn bands_join_up() {
        // threads or not, the same bytes: a gradient big enough to be split into bands, compared with one band
        let (px, stride) = picture(1000, 700, 4, |x, y| ((x % 256) as u8, (y % 256) as u8, ((x + y) % 256) as u8));
        let mut many = Vec::new();
        ToNv12::new().convert(&px, stride, &whole(1000, 700), 640, 448, &mut many);
        let mut one = vec![0u8; 640 * 448 * 3 / 2];
        let t = (Taps::new(1000, 640), Taps::new(700, 448));
        let (luma, chroma) = one.split_at_mut(640 * 448);
        band_rows(&px, stride, 0, 0, &t.0, &t.1, 640, 0, 448, luma, chroma, &mut Vec::new());
        assert!(many == one);
    }

    #[test]
    fn taps_sum_to_one() {
        for (src, out) in [(1920, 1280), (2, 64), (3, 16), (3840, 1280), (1281, 1280), (700, 448)] {
            let t = Taps::new(src, out);
            assert_eq!(t.start.len(), out);
            for i in 0..out {
                assert_eq!(t.w[i * t.n..(i + 1) * t.n].iter().sum::<i32>(), ONE, "{src} → {out} at {i}");
                assert!(t.start[i] + t.n <= src);
            }
        }
    }

    /// `cargo test --release nv12::tests::speed -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn speed() {
        let (px, stride) = picture(1920, 1080, 0, |x, y| ((x * 7 % 256) as u8, (y * 3 % 256) as u8, ((x ^ y) % 256) as u8));
        let mut c = ToNv12::new();
        let mut out = Vec::new();
        for (crop, ow, oh) in [(whole(1920, 1080), 1280, 720), (Rect { left: 300, top: 200, right: 940, bottom: 560 }, 1280, 720)] {
            c.convert(&px, stride, &crop, ow, oh, &mut out);
            let t = std::time::Instant::now();
            for _ in 0..50 {
                c.convert(&px, stride, &crop, ow, oh, &mut out);
            }
            eprintln!("{crop:?} → {ow}×{oh}: {:.2} ms", t.elapsed().as_secs_f64() * 1000.0 / 50.0);
        }
    }
}
