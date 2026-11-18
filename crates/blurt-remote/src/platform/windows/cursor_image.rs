//! A Windows cursor's bitmaps (GetIconInfo, read back by GetDIBits as 32-bit top-down BGRA) → straight RGBA for a PNG.
//!
//! * Colour cursors with alpha (every modern arrow, the Fluent ones): the colour bitmap as it is.
//! * Colour without alpha (old .cur files): the AND mask says what is transparent.
//! * Monochrome (the I-beam on many systems, the classic set): one bitmap twice as tall, AND mask over XOR mask. AND 0 → the XOR
//!   bit's black or white; AND 1, XOR 0 → transparent; AND 1, XOR 1 → "invert the screen", which a picture can't do: drawn
//!   black with a white outline, so it reads on light and dark alike (the I-beam over a terminal).
//!
//! Pure: tested on any OS.

/// RGBA pixels, row by row.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Image {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

fn bit(px: &[u8], i: usize) -> bool {
    // a 1-bpp bitmap read back as 32 bpp: white (FFFFFF) is 1, black is 0
    px.get(i * 4..i * 4 + 3).is_some_and(|c| c.iter().any(|v| *v >= 0x80))
}

/// A colour cursor: `color` w×h BGRA, `mask` w×h (the AND mask as 32 bpp), if it has one.
pub fn from_color(width: u32, height: u32, color: &[u8], mask: Option<&[u8]>) -> Option<Image> {
    let n = (width * height) as usize;
    if n == 0 || color.len() < n * 4 {
        return None;
    }
    let has_alpha = color[..n * 4].chunks(4).any(|c| c[3] != 0);
    let mut rgba = vec![0u8; n * 4];
    let mut invert = vec![false; n];
    for i in 0..n {
        let c = &color[i * 4..i * 4 + 4];
        let o = &mut rgba[i * 4..i * 4 + 4];
        o[0] = c[2];
        o[1] = c[1];
        o[2] = c[0];
        o[3] = if has_alpha {
            c[3]
        } else {
            match mask {
                Some(m) if bit(m, i) => {
                    // AND 1: transparent, unless the colour inverts what's under it
                    if c[..3].iter().any(|v| *v != 0) {
                        invert[i] = true;
                    }
                    0
                }
                _ => 255,
            }
        };
    }
    paint_inverted(width, height, &mut rgba, &invert);
    Some(Image { width, height, rgba })
}

/// A monochrome cursor: `mask` is w × 2h, the AND mask above the XOR mask.
pub fn from_mono(width: u32, double_height: u32, mask: &[u8]) -> Option<Image> {
    let height = double_height / 2;
    let n = (width * height) as usize;
    if n == 0 || mask.len() < n * 8 {
        return None;
    }
    let mut rgba = vec![0u8; n * 4];
    let mut invert = vec![false; n];
    for i in 0..n {
        let and = bit(mask, i);
        let xor = bit(mask, i + n);
        let o = &mut rgba[i * 4..i * 4 + 4];
        match (and, xor) {
            (false, false) => o.copy_from_slice(&[0, 0, 0, 255]),
            (false, true) => o.copy_from_slice(&[255, 255, 255, 255]),
            (true, false) => o.copy_from_slice(&[0, 0, 0, 0]),
            (true, true) => invert[i] = true,
        }
    }
    paint_inverted(width, height, &mut rgba, &invert);
    Some(Image { width, height, rgba })
}

/// Inverting pixels as opaque black, and a white outline on the transparent pixels around them.
fn paint_inverted(width: u32, height: u32, rgba: &mut [u8], invert: &[bool]) {
    if !invert.iter().any(|v| *v) {
        return;
    }
    let (w, h) = (width as i32, height as i32);
    for y in 0..h {
        for x in 0..w {
            let i = (y * w + x) as usize;
            if invert[i] {
                rgba[i * 4..i * 4 + 4].copy_from_slice(&[0, 0, 0, 255]);
            }
        }
    }
    for y in 0..h {
        for x in 0..w {
            let i = (y * w + x) as usize;
            if invert[i] || rgba[i * 4 + 3] != 0 {
                continue;
            }
            let near = (-1..=1).any(|dy| {
                (-1..=1).any(|dx| {
                    let (nx, ny) = (x + dx, y + dy);
                    nx >= 0 && ny >= 0 && nx < w && ny < h && invert[(ny * w + nx) as usize]
                })
            });
            if near {
                rgba[i * 4..i * 4 + 4].copy_from_slice(&[255, 255, 255, 255]);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const W: [u8; 4] = [255, 255, 255, 0];
    const B: [u8; 4] = [0, 0, 0, 0];

    #[test]
    fn color_with_alpha_is_taken_as_it_is() {
        // BGRA: one red half-transparent pixel, one blue opaque
        let img = from_color(2, 1, &[0, 0, 255, 128, 255, 0, 0, 255], None).unwrap();
        assert_eq!(img.rgba, vec![255, 0, 0, 128, 0, 0, 255, 255]);
    }

    #[test]
    fn color_without_alpha_uses_the_mask() {
        let color = [[0, 0, 0, 0], [10, 20, 30, 0], [0, 0, 0, 0]].concat();
        let mask = [W, B, B].concat();
        let img = from_color(3, 1, &color, Some(&mask)).unwrap();
        assert_eq!(img.rgba, vec![0, 0, 0, 0, 30, 20, 10, 255, 0, 0, 0, 255]);
    }

    #[test]
    fn mono_cursor_four_cases() {
        // 4×1: AND over XOR. pixels: black, white, transparent, invert
        let and = [B, B, W, W].concat();
        let xor = [B, W, B, W].concat();
        let img = from_mono(4, 2, &[and, xor].concat()).unwrap();
        assert_eq!((img.width, img.height), (4, 1));
        let px: Vec<&[u8]> = img.rgba.chunks(4).collect();
        assert_eq!(px[0], &[0, 0, 0, 255]);
        assert_eq!(px[1], &[255, 255, 255, 255]);
        // transparent but next to the inverting pixel: the outline
        assert_eq!(px[2], &[255, 255, 255, 255]);
        assert_eq!(px[3], &[0, 0, 0, 255]);
    }

    #[test]
    fn an_ibeam_gets_an_outline_and_the_rest_stays_clear() {
        // 5×3, a vertical inverting line in the middle column
        let (w, h) = (5usize, 3usize);
        let mut and = Vec::new();
        let mut xor = Vec::new();
        for _y in 0..h {
            for x in 0..w {
                and.extend(W);
                xor.extend(if x == 2 { W } else { B });
            }
        }
        let img = from_mono(w as u32, (h * 2) as u32, &[and, xor].concat()).unwrap();
        let a = |x: usize, y: usize| img.rgba[(y * w + x) * 4 + 3];
        let r = |x: usize, y: usize| img.rgba[(y * w + x) * 4];
        for y in 0..h {
            assert_eq!((a(2, y), r(2, y)), (255, 0), "the line is black");
            assert_eq!((a(1, y), r(1, y)), (255, 255), "outlined white");
            assert_eq!((a(3, y), r(3, y)), (255, 255));
            assert_eq!(a(0, y), 0, "clear");
            assert_eq!(a(4, y), 0);
        }
    }

    #[test]
    fn too_short_is_none() {
        assert!(from_color(2, 2, &[0; 8], None).is_none());
        assert!(from_mono(2, 2, &[0; 8]).is_none());
        assert!(from_color(0, 0, &[], None).is_none());
    }
}
