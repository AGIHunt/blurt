//! The clipboard's image and copied files (docs/design/remote-files.md), on Windows and Linux through arboard, the same crate the
//! desktop app's clipboard plugin uses: Windows reads Explorer's CF_HDROP, the registered "PNG" format or CF_DIBV5 (which Windows
//! makes from CF_DIB), and writes PNG + CF_DIBV5; Linux reads `text/uri-list` and `image/png`, through Wayland's data-control where
//! the compositor has it, else XWayland's clipboard (GNOME: mutter keeps it in step with Wayland apps' copies). One clipboard for the
//! process, kept: on Linux what this process put on it is gone once it is dropped.
use std::sync::Mutex;

use crate::host::Copied;

static CB: Mutex<Option<arboard::Clipboard>> = Mutex::new(None);

fn with<T>(f: impl FnOnce(&mut arboard::Clipboard) -> T) -> Option<T> {
    let mut g = CB.lock().unwrap_or_else(|e| e.into_inner());
    if g.is_none() {
        *g = arboard::Clipboard::new().map_err(|e| eprintln!("blurt-remote: clipboard: {e}")).ok();
    }
    g.as_mut().map(f)
}

/// What's copied: files first (a file manager also offers their paths as text), then an image, then text.
pub fn read() -> Copied {
    with(|cb| {
        let mut failed = false;
        let look = |failed: &mut bool, e: &arboard::Error| *failed |= !matches!(e, arboard::Error::ContentNotAvailable);
        match cb.get().file_list() {
            Ok(l) if !l.is_empty() => return Copied::Files(l),
            Ok(_) => {}
            Err(e) => look(&mut failed, &e),
        }
        match cb.get_image() {
            Ok(img) => {
                if let Some(png) = png(img.width as u32, img.height as u32, img.bytes.into_owned()) {
                    return Copied::Image(png);
                }
                failed = true;
            }
            Err(e) => look(&mut failed, &e),
        }
        match cb.get_text() {
            Ok(t) if !t.is_empty() => return Copied::Text(t),
            Ok(_) => {}
            Err(e) => look(&mut failed, &e),
        }
        if failed {
            Copied::Unsupported
        } else {
            Copied::Empty
        }
    })
    .unwrap_or(Copied::Unsupported)
}

/// An image file's bytes (PNG, JPEG, TIFF, BMP) onto the clipboard. false: not an image this can read, or the clipboard said no.
pub fn set_image(bytes: &[u8]) -> bool {
    let Some((w, h, rgba)) = rgba(bytes) else { return false };
    with(|cb| cb.set_image(arboard::ImageData { width: w as usize, height: h as usize, bytes: rgba.into() }).is_ok()).unwrap_or(false)
}

pub use crate::platform::pixels::{png, rgba};
