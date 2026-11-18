//! The arithmetic of the Linux backend, pure so it's tested anywhere: output size, crops in pixels, damage, pointer and
//! scroll units, discrete-step fallback, and which encoder serves which codec.
//!
//! Spaces: a monitor stream has a *logical* size (the portal's `size`, what GNOME calls compositor coordinates, = points in
//! host.rs) and a *pixel* size (the PipeWire frames; larger by the monitor's scale, 2 at 200 %, 1.25 at 125 %).

use crate::host::Crop;

/// Pixel rectangle in the stream's frames.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rect {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

/// The smallest crop side in pixels (the phone zooms to a few lines of text, never to a pixel).
pub const MIN_CROP: u32 = 32;

fn even_down(v: f64) -> u32 {
    ((v.max(0.0) as u32) / 2) * 2
}

/// The encoder's picture: the monitor's shape, as large as the phone asked and no larger than the monitor has pixels,
/// even sides (RemoteScreen.swift does the same with ScreenCaptureKit). The crop is scaled to this whatever it is.
pub fn fit_output(want_w: u32, want_h: u32, src_w: u32, src_h: u32) -> (u32, u32) {
    let (ww, wh) = (want_w.max(16) as u64, want_h.max(16) as u64);
    if src_w == 0 || src_h == 0 {
        return (ww as u32 / 2 * 2, wh as u32 / 2 * 2);
    }
    let (sw, sh) = (src_w as u64, src_h as u64);
    // in whole numbers: 2042 / 3840 × 3840 must stay 2042
    let (w, h) = if ww * sh <= wh * sw {
        let w = ww.min(sw);
        (w, w * sh / sw)
    } else {
        let h = wh.min(sh);
        (h * sw / sh, h)
    };
    ((w as u32 / 2 * 2).max(16), (h as u32 / 2 * 2).max(16))
}

/// A crop from the phone, made safe: finite, inside 0…1, not empty.
pub fn sane(c: Crop) -> Crop {
    let f = |v: f32, d: f32| if v.is_finite() { v } else { d };
    let w = f(c.w, 1.0).clamp(0.001, 1.0);
    let h = f(c.h, 1.0).clamp(0.001, 1.0);
    let x = f(c.x, 0.0).clamp(0.0, 1.0 - w);
    let y = f(c.y, 0.0).clamp(0.0, 1.0 - h);
    Crop { x, y, w, h }
}

/// The crop in the frame's pixels: even origin and sides (4:2:0 chroma), at least `MIN_CROP`, inside the frame.
pub fn crop_rect(c: Crop, src_w: u32, src_h: u32) -> Rect {
    let c = sane(c);
    let side = |v: f32, n: u32| -> u32 {
        let px = (v as f64 * n as f64).round() as u32;
        let lo = MIN_CROP.min(n / 2 * 2);
        (px / 2 * 2).clamp(lo, n / 2 * 2)
    };
    let w = side(c.w, src_w);
    let h = side(c.h, src_h);
    let x = even_down(c.x as f64 * src_w as f64).min((src_w - w) / 2 * 2);
    let y = even_down(c.y as f64 * src_h as f64).min((src_h - h) / 2 * 2);
    Rect { x, y, w, h }
}

/// What a frame cut at `r` really shows, 0…1: the label the phone places it by (exact, so the picture never twitches).
pub fn rect_crop(r: Rect, src_w: u32, src_h: u32) -> Crop {
    if src_w == 0 || src_h == 0 {
        return Crop::WHOLE;
    }
    Crop {
        x: r.x as f32 / src_w as f32,
        y: r.y as f32 / src_h as f32,
        w: r.w as f32 / src_w as f32,
        h: r.h as f32 / src_h as f32,
    }
}

/// Whether any damaged region (PipeWire's video damage meta, frame pixels) touches the crop. None: the compositor didn't say,
/// so assume it does.
pub fn damage_hits(regions: Option<&[Rect]>, r: Rect) -> bool {
    let Some(regions) = regions else { return true };
    regions.iter().any(|d| d.w > 0 && d.h > 0 && d.x < r.x + r.w && r.x < d.x + d.w && d.y < r.y + r.h && r.y < d.y + d.h)
}

/// The pointer from the stream's cursor meta (frame pixels) as host.rs wants it: 0…1 of the monitor.
pub fn pointer_norm(px: i32, py: i32, src_w: u32, src_h: u32) -> Option<(f64, f64)> {
    (src_w > 0 && src_h > 0).then(|| (px as f64 / src_w as f64, py as f64 / src_h as f64))
}

/// Where NotifyPointerMotionAbsolute's x, y go. GNOME (mutter) reads them in the stream's pixels and divides by the monitor's
/// scale; KDE (kwin) in logical pixels. Clamped inside the monitor.
pub fn absolute_target(x: f64, y: f64, space: (f64, f64)) -> (f64, f64) {
    let f = |v: f64, n: f64| if v.is_finite() { (v * n).clamp(0.0, (n - 1.0).max(0.0)) } else { 0.0 };
    (f(x, space.0), f(y, space.1))
}

/// host.rs scroll (points, positive dy = content moves down, natural direction applied by the phone) → Wayland axis values
/// (logical pixels, positive = down / right, the wheel's sense). `natural`: the user's own setting
/// (org.gnome.desktop.peripherals.touchpad natural-scroll); virtual devices skip it, so it's applied here, as the Mac does.
pub fn scroll_axis(dx: f64, dy: f64, natural: bool) -> (f64, f64) {
    let s = if natural { -1.0 } else { 1.0 };
    let clean = |v: f64| if v.is_finite() { v } else { 0.0 };
    (clean(dx) * s, clean(dy) * s)
}

/// Pixels that make one wheel click when only discrete scrolling exists (old portals): GTK scrolls about this per click.
pub const PX_PER_STEP: f64 = 30.0;

/// Fractions that wait for the next event, so a slow movement adds up instead of rounding away.
#[derive(Default, Debug, Clone, Copy)]
pub struct Carry(f64);

impl Carry {
    /// Whole units in `v / unit` plus what was carried; the rest is kept.
    pub fn take(&mut self, v: f64, unit: f64) -> i32 {
        if !v.is_finite() || unit <= 0.0 {
            return 0;
        }
        let t = self.0 + v / unit;
        let whole = t.trunc();
        self.0 = t - whole;
        whole as i32
    }

    pub fn clear(&mut self) {
        self.0 = 0.0;
    }
}

/// The cursor's size and hot spot in points, from the meta's bitmap (frame pixels).
pub fn cursor_points(w: u32, h: u32, hot_x: i32, hot_y: i32, px_per_point: f64) -> (f64, f64, f64, f64) {
    let k = if px_per_point.is_finite() && px_per_point > 0.0 { px_per_point } else { 1.0 };
    (w as f64 / k, h as f64 / k, hot_x as f64 / k, hot_y as f64 / k)
}

/// Codec → GStreamer encoder elements, hardware first. Each is used only if installed (gst-inspect finds it).
pub const HW_H264: &[&str] = &["vah264enc", "vah264lpenc", "vaapih264enc", "nvh264enc", "nvcudah264enc", "qsvh264enc"];
pub const HW_HEVC: &[&str] = &["vah265enc", "vah265lpenc", "vaapih265enc", "nvh265enc", "nvcudah265enc", "qsvh265enc"];
pub const SW_H264: &[&str] = &["x264enc", "openh264enc"];
pub const SW_HEVC: &[&str] = &["x265enc"];

/// The phone's codecs, best first → (codec, element). The first codec with a hardware encoder wins; else H.264 in
/// software; HEVC in software (x265) only for a phone that decodes nothing else. `force`: BLURT_REMOTE_ENCODER.
pub fn choose_encoder(codecs: &[String], has: &dyn Fn(&str) -> bool, force: Option<&str>) -> Option<(&'static str, String)> {
    let codecs: Vec<&str> = if codecs.is_empty() { vec!["hevc"] } else { codecs.iter().map(|s| s.as_str()).collect() };
    if let Some(f) = force.filter(|f| has(f)) {
        let codec = if f.contains("265") { "hevc" } else { "h264" };
        if codecs.contains(&codec) {
            return Some((codec, f.to_string()));
        }
    }
    for c in &codecs {
        let hw = match *c {
            "h264" => HW_H264,
            "hevc" => HW_HEVC,
            _ => continue,
        };
        if let Some(e) = hw.iter().find(|e| has(e)) {
            return Some((if *c == "h264" { "h264" } else { "hevc" }, e.to_string()));
        }
    }
    if codecs.contains(&"h264") {
        if let Some(e) = SW_H264.iter().find(|e| has(e)) {
            return Some(("h264", e.to_string()));
        }
    }
    if codecs.contains(&"hevc") {
        if let Some(e) = SW_HEVC.iter().find(|e| has(e)) {
            return Some(("hevc", e.to_string()));
        }
    }
    None
}

/// The raw format the encoder is fed: x264 takes I420 at its fastest; the hardware ones NV12.
pub fn encoder_format(element: &str) -> &'static str {
    if element.starts_with("x26") || element == "openh264enc" {
        "I420"
    } else {
        "NV12"
    }
}

/// x264's VBV in milliseconds for a frame rate: about four frames, never under 120 ms (a text keyframe at a low rate needs
/// room or it comes out mush) nor over 300 ms (what a burst may queue up on a thin link).
pub fn vbv_ms(fps: u32) -> u32 {
    (4000 / fps.max(1)).clamp(120, 300)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn output_keeps_the_monitors_shape_and_never_upscales() {
        assert_eq!(fit_output(1206, 2622, 2560, 1600), (1206, 752));
        assert_eq!(fit_output(4000, 4000, 1920, 1080), (1920, 1080));
        assert_eq!(fit_output(2042, 1276, 3840, 2160), (2042, 1148));
        let (w, h) = fit_output(1279, 799, 2560, 1440);
        assert!(w % 2 == 0 && h % 2 == 0 && w <= 1279 && h <= 799);
    }

    #[test]
    fn crops_are_even_inside_and_labelled_exactly() {
        let r = crop_rect(Crop::WHOLE, 2560, 1600);
        assert_eq!(r, Rect { x: 0, y: 0, w: 2560, h: 1600 });
        let r = crop_rect(Crop { x: 0.25, y: 0.25, w: 0.5, h: 0.5 }, 2560, 1600);
        assert_eq!(r, Rect { x: 640, y: 400, w: 1280, h: 800 });
        // odd numbers come out even, and the label is what was cut
        let r = crop_rect(Crop { x: 0.1234, y: 0.3333, w: 0.3333, h: 0.3333 }, 1919, 1081);
        assert!(r.x.is_multiple_of(2) && r.y.is_multiple_of(2) && r.w.is_multiple_of(2) && r.h.is_multiple_of(2));
        assert!(r.x + r.w <= 1919 && r.y + r.h <= 1081);
        let c = rect_crop(r, 1919, 1081);
        assert!((c.x * 1919.0 - r.x as f32).abs() < 0.01 && (c.w * 1919.0 - r.w as f32).abs() < 0.01);
        // past the edge slides back in, garbage is the whole screen, tiny is the minimum
        let r = crop_rect(Crop { x: 0.9, y: 0.9, w: 0.5, h: 0.5 }, 2000, 1000);
        assert_eq!((r.x + r.w, r.y + r.h), (2000, 1000));
        assert_eq!(crop_rect(Crop { x: f32::NAN, y: 0.0, w: f32::INFINITY, h: 2.0 }, 1000, 800), Rect { x: 0, y: 0, w: 1000, h: 800 });
        let r = crop_rect(Crop { x: 0.5, y: 0.5, w: 0.0, h: 0.0 }, 1000, 800);
        assert_eq!((r.w, r.h), (MIN_CROP, MIN_CROP));
    }

    #[test]
    fn damage_outside_the_crop_costs_nothing() {
        let crop = Rect { x: 100, y: 100, w: 200, h: 200 };
        assert!(damage_hits(None, crop));
        assert!(!damage_hits(Some(&[]), crop));
        assert!(!damage_hits(Some(&[Rect { x: 0, y: 0, w: 100, h: 1000 }]), crop), "touching the edge isn't inside");
        assert!(damage_hits(Some(&[Rect { x: 0, y: 0, w: 101, h: 101 }]), crop));
        assert!(!damage_hits(Some(&[Rect { x: 150, y: 150, w: 0, h: 10 }]), crop));
    }

    #[test]
    fn pointer_and_absolute_moves() {
        assert_eq!(pointer_norm(1280, 400, 2560, 1600), Some((0.5, 0.25)));
        assert_eq!(pointer_norm(1, 1, 0, 0), None);
        assert_eq!(absolute_target(0.5, 0.25, (2560.0, 1600.0)), (1280.0, 400.0));
        assert_eq!(absolute_target(1.5, -1.0, (100.0, 50.0)), (99.0, 0.0));
        assert_eq!(absolute_target(f64::NAN, 0.0, (100.0, 50.0)), (0.0, 0.0));
    }

    #[test]
    fn scroll_direction() {
        // the phone: fingers move down, content moves down = scroll up = a negative axis value
        assert_eq!(scroll_axis(0.0, 10.0, true), (-0.0, -10.0));
        // natural scrolling off: as a wheel, the other way
        assert_eq!(scroll_axis(3.0, 10.0, false), (3.0, 10.0));
        assert_eq!(scroll_axis(f64::NAN, 1.0, true), (-0.0, -1.0));
    }

    #[test]
    fn carry_adds_up_slow_movement() {
        let mut c = Carry::default();
        let steps: i32 = (0..10).map(|_| c.take(10.0, PX_PER_STEP)).sum();
        assert_eq!(steps, 3, "100 px is three steps of 30, 10 px wait");
        assert_eq!(c.take(20.0, PX_PER_STEP), 1);
        let mut c = Carry::default();
        assert_eq!(c.take(-45.0, PX_PER_STEP), -1);
        assert_eq!(c.take(-15.0, PX_PER_STEP), -1);
        assert_eq!(c.take(f64::NAN, PX_PER_STEP), 0);
    }

    #[test]
    fn cursor_in_points() {
        assert_eq!(cursor_points(48, 48, 8, 4, 2.0), (24.0, 24.0, 4.0, 2.0));
        assert_eq!(cursor_points(24, 24, 0, 0, 0.0), (24.0, 24.0, 0.0, 0.0));
    }

    #[test]
    fn encoder_choice() {
        let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        let only = |names: &'static [&'static str]| move |e: &str| names.contains(&e);
        // an Apple phone, Intel graphics: HEVC in hardware
        assert_eq!(choose_encoder(&s(&["hevc", "h264"]), &only(&["vah265enc", "vah264enc", "x264enc"]), None), Some(("hevc", "vah265enc".into())));
        // no hardware HEVC: hardware H.264 before x264
        assert_eq!(choose_encoder(&s(&["hevc", "h264"]), &only(&["vah264enc", "x264enc"]), None), Some(("h264", "vah264enc".into())));
        // no GPU encoder at all: x264, never x265 for a phone that takes H.264
        assert_eq!(choose_encoder(&s(&["hevc", "h264"]), &only(&["x264enc", "x265enc"]), None), Some(("h264", "x264enc".into())));
        // an old phone that only says HEVC
        assert_eq!(choose_encoder(&[], &only(&["x264enc", "x265enc"]), None), Some(("hevc", "x265enc".into())));
        assert_eq!(choose_encoder(&s(&["h264"]), &only(&[]), None), None);
        // forced, when the phone takes it
        assert_eq!(choose_encoder(&s(&["hevc", "h264"]), &only(&["vah265enc", "x264enc"]), Some("x264enc")), Some(("h264", "x264enc".into())));
        assert_eq!(choose_encoder(&s(&["h264"]), &only(&["x265enc", "x264enc"]), Some("x265enc")), Some(("h264", "x264enc".into())));
        assert_eq!(encoder_format("x264enc"), "I420");
        assert_eq!(encoder_format("vah264enc"), "NV12");
    }

    #[test]
    fn vbv_follows_the_frame_rate() {
        assert_eq!(vbv_ms(60), 120);
        assert_eq!(vbv_ms(30), 133);
        assert_eq!(vbv_ms(15), 266);
        assert_eq!(vbv_ms(5), 300);
        assert_eq!(vbv_ms(0), 300);
    }
}
