//! An image's bytes ↔ RGBA pixels, for the clipboard (clip.rs). Pure: tested on any OS.

/// RGBA pixels as PNG.
pub fn png(width: u32, height: u32, rgba: Vec<u8>) -> Option<Vec<u8>> {
    let img = image::RgbaImage::from_raw(width, height, rgba)?;
    let mut out = std::io::Cursor::new(Vec::new());
    img.write_to(&mut out, image::ImageFormat::Png).ok()?;
    Some(out.into_inner())
}

/// PNG, JPEG, TIFF or BMP as (width, height, RGBA pixels).
pub fn rgba(bytes: &[u8]) -> Option<(u32, u32, Vec<u8>)> {
    let img = image::load_from_memory(bytes).ok()?.into_rgba8();
    let (w, h) = img.dimensions();
    Some((w, h, img.into_raw()))
}

#[cfg(test)]
mod tests {
    #[test]
    fn pixels_go_round_through_png() {
        let px: Vec<u8> = (0..4 * 3 * 2).map(|i| i as u8).collect();
        let p = super::png(3, 2, px.clone()).unwrap();
        assert_eq!(&p[1..4], b"PNG");
        assert_eq!(super::rgba(&p), Some((3, 2, px)));
        assert_eq!(super::rgba(b"not an image"), None);
    }
}
