//! Reading the screen on Windows: the chosen area grabbed through GDI (physical pixels, what the user sees) and read
//! by Windows' own OCR (`Windows.Media.Ocr`, the languages of the user's profile — on a Chinese Windows, Chinese and
//! English) — nothing to download, as Apple Vision on the Mac. The geometry rules (rules.rs) then make text of it.

use windows::Graphics::Imaging::{BitmapAlphaMode, BitmapPixelFormat, SoftwareBitmap};
use windows::Media::Ocr::OcrEngine;
use windows::Storage::Streams::DataWriter;
use windows::Win32::Graphics::Gdi::{
    BitBlt, CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, GetDC, ReleaseDC,
    SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, CAPTUREBLT, DIB_RGB_COLORS, SRCCOPY,
};

pub use super::grab::{write_bmp, Grab};

pub fn grab(x: i32, y: i32, w: u32, h: u32) -> Result<Grab, String> {
    unsafe {
        let screen = GetDC(None);
        let mem = CreateCompatibleDC(Some(screen));
        let mut bi = BITMAPINFO::default();
        bi.bmiHeader = BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: w as i32,
            biHeight: -(h as i32), // top-down
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        };
        let mut bits: *mut std::ffi::c_void = std::ptr::null_mut();
        let bmp = CreateDIBSection(Some(mem), &bi, DIB_RGB_COLORS, &mut bits, None, 0)
            .map_err(|e| e.to_string())?;
        let old = SelectObject(mem, bmp.into());
        let ok = BitBlt(
            mem,
            0,
            0,
            w as i32,
            h as i32,
            Some(screen),
            x,
            y,
            SRCCOPY | CAPTUREBLT,
        )
        .is_ok();
        let n = (w * h * 4) as usize;
        let data = if ok && !bits.is_null() {
            std::slice::from_raw_parts(bits as *const u8, n).to_vec()
        } else {
            vec![]
        };
        SelectObject(mem, old);
        let _ = DeleteObject(bmp.into());
        let _ = DeleteDC(mem);
        ReleaseDC(None, screen);
        if data.is_empty() {
            return Err("couldn't grab the screen".into());
        }
        Ok(Grab { w, h, bgra: data })
    }
}

/// One word as Windows' OCR read it: its text and box in the grab's pixels.
pub struct Word {
    pub text: String,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

/// Lines of words, top to bottom as the OCR gives them. Small areas are read at 2× (Windows' OCR misses text under
/// ~10 px tall); the boxes come back in the grab's own pixels.
pub fn read(g: &Grab) -> Result<Vec<Vec<Word>>, String> {
    let max = OcrEngine::MaxImageDimension().map_err(|e| e.to_string())? as u32;
    let want: u32 = std::env::var("BLURT_OCR_SCALE")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(2);
    let scale = if want >= 2 && g.w.max(g.h) * 2 <= max && g.h < 400 {
        2
    } else {
        1
    };
    let (w, h, px) = if scale == 2 {
        (g.w * 2, g.h * 2, upscale2(g))
    } else {
        (g.w.min(max), g.h.min(max), crop(g, max))
    };
    let dw = DataWriter::new().map_err(|e| e.to_string())?;
    dw.WriteBytes(&px).map_err(|e| e.to_string())?;
    let buf = dw.DetachBuffer().map_err(|e| e.to_string())?;
    let bmp = SoftwareBitmap::CreateCopyWithAlphaFromBuffer(
        &buf,
        BitmapPixelFormat::Bgra8,
        w as i32,
        h as i32,
        BitmapAlphaMode::Premultiplied,
    )
    .map_err(|e| e.to_string())?;
    let eng = OcrEngine::TryCreateFromUserProfileLanguages()
        .map_err(|e| format!("no OCR language on this PC: {e}"))?;
    let res = eng
        .RecognizeAsync(&bmp)
        .map_err(|e| e.to_string())?
        .join()
        .map_err(|e| e.to_string())?;
    let s = scale as f64;
    let mut out = vec![];
    for line in res.Lines().map_err(|e| e.to_string())? {
        let mut words = vec![];
        for wd in line.Words().map_err(|e| e.to_string())? {
            let r = wd.BoundingRect().map_err(|e| e.to_string())?;
            words.push(Word {
                text: wd.Text().map_err(|e| e.to_string())?.to_string_lossy(),
                x: r.X as f64 / s,
                y: r.Y as f64 / s,
                w: r.Width as f64 / s,
                h: r.Height as f64 / s,
            });
        }
        if std::env::var_os("BLURT_OCR_DEBUG").is_some() {
            eprintln!(
                "ocr line: {}",
                words
                    .iter()
                    .map(|w| format!("{}@{:.0},{:.0},{:.0}x{:.0}", w.text, w.x, w.y, w.w, w.h))
                    .collect::<Vec<_>>()
                    .join(" | ")
            );
        }
        if !words.is_empty() {
            out.push(words);
        }
    }
    Ok(out)
}

/// 2× with bilinear filtering: nearest-neighbour blocks made Windows' OCR misread small Chinese (用 → 厍).
fn upscale2(g: &Grab) -> Vec<u8> {
    let (w, h) = (g.w as usize, g.h as usize);
    let px =
        |x: usize, y: usize, c: usize| g.bgra[(y.min(h - 1) * w + x.min(w - 1)) * 4 + c] as f32;
    let mut out = vec![0u8; w * h * 16];
    for y in 0..h * 2 {
        let fy = (y as f32 + 0.5) / 2.0 - 0.5;
        let (y0, ty) = (fy.max(0.0).floor() as usize, (fy - fy.floor()).max(0.0));
        for x in 0..w * 2 {
            let fx = (x as f32 + 0.5) / 2.0 - 0.5;
            let (x0, tx) = (fx.max(0.0).floor() as usize, (fx - fx.floor()).max(0.0));
            let d = (y * w * 2 + x) * 4;
            for c in 0..4 {
                let top = px(x0, y0, c) * (1.0 - tx) + px(x0 + 1, y0, c) * tx;
                let bot = px(x0, y0 + 1, c) * (1.0 - tx) + px(x0 + 1, y0 + 1, c) * tx;
                out[d + c] = (top * (1.0 - ty) + bot * ty).round() as u8;
            }
        }
    }
    out
}

fn crop(g: &Grab, max: u32) -> Vec<u8> {
    if g.w <= max && g.h <= max {
        return g.bgra.clone();
    }
    let (w, h) = (g.w.min(max) as usize, g.h.min(max) as usize);
    let mut out = Vec::with_capacity(w * h * 4);
    for y in 0..h {
        let s = y * g.w as usize * 4;
        out.extend_from_slice(&g.bgra[s..s + w * 4]);
    }
    out
}
