//! A grabbed area of the screen, whatever read it (Windows: GDI, ocr_win; Linux: GNOME's Screenshot portal,
//! grab_linux): BGRA, top-down rows — what the reader (screen_ocr.py) and the rules' ink (rules::Gray) take.
//!
//! Also the picker's still (`keep_still` / `cut`): every area picker takes a picture of the screen before it opens
//! (snap.rs `monitor_still`: Windows, the monitor through GDI; Linux, the desktop through the portal). A snap and Copy
//! Text cut the picked area out of it, so the picture kept is the frozen one the user drew on, and never holds the
//! picker, the snap's stage or another overlay — which on Linux would be seen, and on Windows before 2004 would come
//! out black (blurt_capture::winver).

use std::sync::Mutex;
use std::time::{Duration, Instant};

use blurt_capture::Region;

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

/// The picture the open picker was shown over: the grab and the desktop area it shows (desktop px; the grab may be at
/// another scale — GNOME's screenshot is in the monitors' own pixels), or why there is none.
pub enum Still {
    Taken(Grab, Region),
    /// GNOME refused (Copy Text says so rather than asking a second time)
    Refused,
    Failed,
}

/// One picker's still; one pick uses it (`take_still`).
static STILL: Mutex<Option<(Instant, Still)>> = Mutex::new(None);
/// A picker left open longer than this (the user walked away) takes no stale picture: the area is shot again.
const STILL_FOR: Duration = Duration::from_secs(120);

/// Before a picker opens: its still replaces the last one (a failed one too: never an older picture).
pub fn keep_still(s: Still) {
    *STILL.lock().unwrap() = Some((Instant::now(), s));
}

/// The open picker's still, once (fresh only).
pub fn take_still() -> Option<Still> {
    STILL.lock().unwrap().take().filter(|(t, _)| t.elapsed() < STILL_FOR).map(|(_, s)| s)
}

/// The picked area (desktop px) out of its picker's still; None: no still (the caller grabs the screen itself).
pub fn cut(r: Region) -> Option<Grab> {
    match take_still()? {
        Still::Taken(shot, desk) => cut_from(&shot, desk, r),
        _ => None,
    }
}

/// [`crop`] with regions.
pub fn cut_from(shot: &Grab, desk: Region, r: Region) -> Option<Grab> {
    crop(shot, (desk.x, desk.y, desk.w, desk.h), (r.x, r.y, r.w, r.h))
}

/// Near-uniform black: what a capture of a window Windows keeps out of pictures gives before 2004 (WDA_MONITOR), or
/// a grab that failed quietly. At least 98 % of the pixels darker than 24 in every channel (a pointer drawn into a
/// small area is not enough to make a black picture count as content).
pub fn near_black(g: &Grab) -> bool {
    let n = (g.w as usize * g.h as usize).min(g.bgra.len() / 4);
    if n == 0 {
        return false;
    }
    // every pixel of a small grab, a spread sample of a big one
    let step = (n / 250_000).max(1);
    let (mut seen, mut dark) = (0usize, 0usize);
    for i in (0..n).step_by(step) {
        let p = &g.bgra[i * 4..i * 4 + 3];
        seen += 1;
        if p[0] <= 24 && p[1] <= 24 && p[2] <= 24 {
            dark += 1;
        }
    }
    dark * 100 >= seen * 98
}

/// The safety net under a snap's picture: a shot that came out black while the still's cut of the same area has
/// content is a capture that saw our own window (or nothing) — the cut is what the user saw.
pub fn black_where_still_is_not(shot: &Grab, still_cut: &Grab) -> bool {
    near_black(shot) && !near_black(still_cut)
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

    fn solid(w: u32, h: u32, v: u8) -> Grab {
        Grab { w, h, bgra: [v, v, v, 255].repeat((w * h) as usize) }
    }

    #[test]
    fn a_windows_monitor_left_of_and_above_the_primary_is_cut_one_to_one() {
        // the still is the monitor in physical px (GDI, a per-monitor-aware process): 1:1 whatever its scaling —
        // 150 % here (2880×1620 physical), placed left of and above the primary
        let mon = Region::new(-2880, -300, 2880, 1620);
        let still = shot(2880, 1620);
        let g = cut_from(&still, mon, Region::new(-2870, -280, 100, 50)).unwrap();
        assert_eq!((g.w, g.h), (100, 50));
        // its first pixel is the still's (10, 20)
        assert_eq!(&g.bgra[..2], &[10, 20]);
        // and its last row is the still's row 69
        let last = ((g.h - 1) * g.w * 4) as usize;
        assert_eq!(&g.bgra[last..last + 2], &[10, 69]);
    }

    #[test]
    fn dpi_scales_cut_at_their_physical_size() {
        // 125 % and 225 %: the picker's region is physical px already (from_css × scale), so the cut is that size
        for (mon, r) in [
            (Region::new(0, 0, 2400, 1350), Region::new(1001, 333, 625, 375)),
            (Region::new(2400, 0, 3240, 2160), Region::new(2400 + 450, 225, 1350, 900)),
        ] {
            let g = cut_from(&shot(mon.w, mon.h), mon, r).unwrap();
            assert_eq!((g.w, g.h), (r.w, r.h));
            assert_eq!(g.bgra[0], ((r.x - mon.x) % 256) as u8);
            assert_eq!(g.bgra[1], ((r.y - mon.y) % 256) as u8);
        }
    }

    #[test]
    fn a_region_over_the_monitors_edge_is_clipped_to_the_still() {
        let mon = Region::new(-1920, 0, 1920, 1080);
        let g = cut_from(&shot(1920, 1080), mon, Region::new(-100, 1000, 300, 200)).unwrap();
        assert_eq!((g.w, g.h), (100, 80));
        assert!(cut_from(&shot(1920, 1080), mon, Region::new(10, 10, 50, 50)).is_none());
    }

    #[test]
    fn a_still_is_cut_once() {
        keep_still(Still::Taken(shot(200, 100), Region::new(-200, 0, 200, 100)));
        let g = cut(Region::new(-190, 10, 20, 20)).unwrap();
        assert_eq!((g.w, g.h, g.bgra[0], g.bgra[1]), (20, 20, 10, 10));
        assert!(cut(Region::new(-190, 10, 20, 20)).is_none());
        keep_still(Still::Failed);
        assert!(cut(Region::new(-190, 10, 20, 20)).is_none());
    }

    #[test]
    fn near_black_is_black_not_dark() {
        assert!(near_black(&solid(64, 64, 0)));
        assert!(near_black(&solid(64, 64, 12)));
        // a dark theme's background is content
        assert!(!near_black(&solid(64, 64, 30)));
        assert!(!near_black(&solid(64, 64, 255)));
        assert!(!near_black(&Grab { w: 0, h: 0, bgra: vec![] }));
        // a black picture with a pointer drawn in it (gdigrab's -draw_mouse) is still black
        let mut g = solid(200, 200, 0);
        for y in 0..20 {
            for x in 0..12 {
                let i = ((y * 200 + x) * 4) as usize;
                g.bgra[i..i + 3].copy_from_slice(&[255, 255, 255]);
            }
        }
        assert!(near_black(&g));
        // a black terminal with lines of text in it is not
        let mut t = solid(200, 100, 0);
        for y in (0..100).step_by(4) {
            for x in 0..200 {
                let i = ((y * 200 + x) * 4) as usize;
                t.bgra[i..i + 3].copy_from_slice(&[200, 200, 200]);
            }
        }
        assert!(!near_black(&t));
    }

    #[test]
    fn the_safety_net_takes_the_still_only_when_the_shot_alone_is_black() {
        let (black, picture) = (solid(40, 40, 0), shot(40, 40));
        assert!(black_where_still_is_not(&black, &picture));
        // a black area that really is black stays as shot
        assert!(!black_where_still_is_not(&black, &solid(40, 40, 0)));
        assert!(!black_where_still_is_not(&picture, &black));
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
