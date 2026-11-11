//! A grabbed area of the screen, whatever read it (Windows: GDI, ocr_win; Linux: GNOME's Screenshot portal,
//! grab_linux): BGRA, top-down rows — what the reader (screen_ocr.py) and the rules' ink (rules::Gray) take.

/// A grabbed area: BGRA, top-down rows.
pub struct Grab {
    pub w: u32,
    pub h: u32,
    pub bgra: Vec<u8>,
}

/// 24-bit BMP (bottom-up), what screen_ocr.py reads: no image crate needed.
pub fn write_bmp(path: &std::path::Path, g: &Grab) -> std::io::Result<()> {
    use std::io::Write;
    let row = (g.w as usize * 3 + 3) & !3;
    let size = 54 + row * g.h as usize;
    let mut f = std::io::BufWriter::new(std::fs::File::create(path)?);
    f.write_all(b"BM")?;
    f.write_all(&(size as u32).to_le_bytes())?;
    f.write_all(&0u32.to_le_bytes())?;
    f.write_all(&54u32.to_le_bytes())?;
    f.write_all(&40u32.to_le_bytes())?;
    f.write_all(&(g.w as i32).to_le_bytes())?;
    f.write_all(&(g.h as i32).to_le_bytes())?;
    f.write_all(&1u16.to_le_bytes())?;
    f.write_all(&24u16.to_le_bytes())?;
    f.write_all(&[0u8; 24])?;
    let pad = vec![0u8; row - g.w as usize * 3];
    for y in (0..g.h as usize).rev() {
        for x in 0..g.w as usize {
            let i = (y * g.w as usize + x) * 4;
            f.write_all(&g.bgra[i..i + 3])?;
        }
        f.write_all(&pad)?;
    }
    f.flush()
}

/// The grab as an 8-bit RGBA PNG (a snap's shots/NNN.png, Copy Text's debug picture).
pub fn write_png(path: &std::path::Path, g: &Grab) -> Result<(), String> {
    let mut rgba = Vec::with_capacity(g.bgra.len());
    for p in g.bgra.chunks_exact(4) {
        rgba.extend_from_slice(&[p[2], p[1], p[0], 255]);
    }
    let f = std::fs::File::create(path).map_err(|e| e.to_string())?;
    let mut e = png::Encoder::new(std::io::BufWriter::new(f), g.w, g.h);
    e.set_color(png::ColorType::Rgba);
    e.set_depth(png::BitDepth::Eight);
    e.write_header().and_then(|mut w| w.write_image_data(&rgba)).map_err(|e| e.to_string())
}

/// A PNG (the Screenshot portal's file) as BGRA: any colour type and depth the png crate reads, expanded to 8 bits.
pub fn decode_png(path: &std::path::Path) -> Result<Grab, String> {
    let f = std::fs::File::open(path).map_err(|e| e.to_string())?;
    let mut d = png::Decoder::new(std::io::BufReader::new(f));
    d.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut r = d.read_info().map_err(|e| e.to_string())?;
    let mut buf = vec![0u8; r.output_buffer_size()];
    let info = r.next_frame(&mut buf).map_err(|e| e.to_string())?;
    let (w, h) = (info.width, info.height);
    let n = (w * h) as usize;
    let mut bgra = Vec::with_capacity(n * 4);
    let px = &buf[..info.buffer_size()];
    match info.color_type {
        png::ColorType::Rgba => px.chunks_exact(4).for_each(|p| bgra.extend_from_slice(&[p[2], p[1], p[0], p[3]])),
        png::ColorType::Rgb => px.chunks_exact(3).for_each(|p| bgra.extend_from_slice(&[p[2], p[1], p[0], 255])),
        png::ColorType::GrayscaleAlpha => px.chunks_exact(2).for_each(|p| bgra.extend_from_slice(&[p[0], p[0], p[0], p[1]])),
        png::ColorType::Grayscale => px.iter().for_each(|&g| bgra.extend_from_slice(&[g, g, g, 255])),
        png::ColorType::Indexed => return Err("indexed PNG left unexpanded".into()),
    }
    if bgra.len() != n * 4 {
        return Err("PNG size doesn't match its pixels".into());
    }
    Ok(Grab { w, h, bgra })
}

/// The picked area (desktop px, as the picker gives it) cut out of a picture of the whole desktop `desk` (its x, y,
/// w, h in desktop px). The picture may be at another scale than the desktop's pixels (GNOME's screenshot is in the
/// monitors' own pixels): the area is scaled by the picture's size over the desktop's. None: nothing of it inside.
pub fn crop(shot: &Grab, desk: (i32, i32, u32, u32), area: (i32, i32, u32, u32)) -> Option<Grab> {
    let (dx, dy, dw, dh) = desk;
    let (ax, ay, aw, ah) = area;
    if dw == 0 || dh == 0 {
        return None;
    }
    let (sx, sy) = (shot.w as f64 / dw as f64, shot.h as f64 / dh as f64);
    let x0 = (((ax - dx) as f64 * sx).round().max(0.0) as u32).min(shot.w);
    let y0 = (((ay - dy) as f64 * sy).round().max(0.0) as u32).min(shot.h);
    let x1 = ((((ax - dx) as f64 + aw as f64) * sx).round().max(0.0) as u32).min(shot.w);
    let y1 = ((((ay - dy) as f64 + ah as f64) * sy).round().max(0.0) as u32).min(shot.h);
    if x1 <= x0 || y1 <= y0 {
        return None;
    }
    let (w, h) = (x1 - x0, y1 - y0);
    let mut bgra = Vec::with_capacity((w * h * 4) as usize);
    for y in y0..y1 {
        let i = ((y * shot.w + x0) * 4) as usize;
        bgra.extend_from_slice(&shot.bgra[i..i + (w * 4) as usize]);
    }
    Some(Grab { w, h, bgra })
}

/// file:///home/me/Pictures/Screenshots/Screenshot%20from….png → the path.
pub fn file_path(uri: &str) -> Option<std::path::PathBuf> {
    let raw = uri.strip_prefix("file://")?;
    let b = raw.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(std::str::from_utf8(&b[i + 1..i + 3]).ok()?, 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    Some(std::path::PathBuf::from(String::from_utf8(out).ok()?))
}


#[cfg(test)]
mod tests {
    use super::*;

    fn shot(w: u32, h: u32) -> Grab {
        // each pixel's blue = its x, green = its y (mod 256): where a crop came from is readable
        let mut bgra = vec![];
        for y in 0..h {
            for x in 0..w {
                bgra.extend_from_slice(&[x as u8, y as u8, 0, 255]);
            }
        }
        Grab { w, h, bgra }
    }

    #[test]
    fn crop_at_the_desktops_scale() {
        let g = crop(&shot(200, 100), (0, 0, 200, 100), (10, 20, 30, 40)).unwrap();
        assert_eq!((g.w, g.h), (30, 40));
        assert_eq!(&g.bgra[..2], &[10, 20]);
    }

    #[test]
    fn crop_scales_with_a_hidpi_screenshot_and_a_desktop_that_starts_left_of_zero() {
        // a 2x screenshot of a desktop whose first monitor starts at x = -100
        let g = crop(&shot(400, 200), (-100, 0, 200, 100), (-90, 10, 20, 10)).unwrap();
        assert_eq!((g.w, g.h), (40, 20));
        assert_eq!(&g.bgra[..2], &[20, 20]);
    }

    #[test]
    fn crop_outside_is_none_and_an_edge_is_clipped() {
        assert!(crop(&shot(100, 100), (0, 0, 100, 100), (150, 0, 10, 10)).is_none());
        let g = crop(&shot(100, 100), (0, 0, 100, 100), (90, 90, 30, 30)).unwrap();
        assert_eq!((g.w, g.h), (10, 10));
    }

    #[test]
    fn file_uri_to_path() {
        assert_eq!(
            file_path("file:///home/me/Pictures/Screenshots/Screenshot%20from%202026-11-11.png").unwrap(),
            std::path::PathBuf::from("/home/me/Pictures/Screenshots/Screenshot from 2026-11-11.png")
        );
        assert_eq!(file_path("file:///tmp/%E6%88%AA%E5%9B%BE.png").unwrap(), std::path::PathBuf::from("/tmp/截图.png"));
        assert!(file_path("https://x/y.png").is_none());
    }

    #[test]
    fn png_round_trip() {
        let d = std::env::temp_dir().join(format!("blurt-grab-test-{}.png", std::process::id()));
        {
            let f = std::fs::File::create(&d).unwrap();
            let mut e = png::Encoder::new(std::io::BufWriter::new(f), 2, 1);
            e.set_color(png::ColorType::Rgb);
            e.set_depth(png::BitDepth::Eight);
            e.write_header().unwrap().write_image_data(&[255, 0, 0, 0, 0, 255]).unwrap();
        }
        let g = decode_png(&d).unwrap();
        let _ = std::fs::remove_file(&d);
        assert_eq!((g.w, g.h), (2, 1));
        assert_eq!(g.bgra, vec![0, 0, 255, 255, 255, 0, 0, 255]);
    }
}
