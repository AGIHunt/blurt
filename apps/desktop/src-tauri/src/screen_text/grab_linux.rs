//! The screen on Linux for Copy Text from Screen (docs/design/linux-port.md §Snaps and Copy Text): `x11grab` sees only
//! XWayland windows under Wayland, so the picture comes from GNOME's Screenshot portal — non-interactive, the whole
//! desktop as a PNG (0.33 s once allowed), cut to the picked area here; the portal's file is removed at once.
//!
//! The portal asks the user once. On 26.04 (2026-11-11) the question came up over the island at the first ⌥C; on the
//! design VM (11-05) GNOME refused to ask while Blurt wasn't the focused app — so a grab refused for any reason comes
//! back as `Failure::Permission`, and Settings → Copy Text from Screen asks again (`allow`, with Blurt's window in front). Allowed is remembered by GNOME's permission store; Blurt
//! keeps `~/.blurt/portal/screenshot.allowed` only to say so in Settings.
//!
//! Every area picker takes its picture before it opens (`picker_still`, the hook snap.rs gives the picker — as the Mac's
//! LoupeStills and Windows' monitor still): GNOME can't leave Blurt's overlays out of a screenshot, so a picture taken
//! after the pick would hold the frozen picker or the snap's stage. The area picked is then cut out of that picture
//! (`grab` for Copy Text, `cut` for a snap); a picker whose picture was refused makes Copy Text say so without asking
//! GNOME a second time.

use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use ashpd::desktop::screenshot::Screenshot;
use blurt_capture::Region;
use tauri::AppHandle;

use super::grab::{crop, decode_png, Grab};
use crate::dictation::insert_linux::block;

pub enum Failure {
    /// GNOME wants to ask first (not asked yet, or Blurt wasn't in front) or the user said no
    Permission,
    Other(String),
}

static APP: OnceLock<AppHandle> = OnceLock::new();

/// At setup: the picker's still hook has no handle of its own.
pub fn init(app: &AppHandle) {
    let _ = APP.set(app.clone());
}

type Desk = (i32, i32, u32, u32);

enum Still {
    Taken(Grab, Desk),
    Refused,
    Failed,
}

/// The picture the open picker was shown over, and when it was taken; one pick uses it (`take`).
static STILL: Mutex<Option<(Instant, Still)>> = Mutex::new(None);
/// A picker left open longer than this (the user walked away) takes no stale picture: the area is shot again.
const STILL_FOR: Duration = Duration::from_secs(120);

fn take() -> Option<Still> {
    STILL.lock().unwrap().take().filter(|(t, _)| t.elapsed() < STILL_FOR).map(|(_, s)| s)
}

/// Before a picker opens: the whole desktop through the portal, kept for the pick; the monitor `mon` (desktop px) out of
/// it for the picker's loupe. None while GNOME refuses (or the portal fails): the picker opens without a loupe.
pub fn picker_still(mon: Region) -> Option<Grab> {
    let app = APP.get()?;
    let t0 = Instant::now();
    let parent = crate::mainwin::x11_id_off_main(app, "blurt-overlay-island").or_else(|| crate::mainwin::x11_id_off_main(app, "main"));
    let (still, out) = match shoot(parent) {
        Ok(shot) => {
            let desk = desktop(app).unwrap_or((0, 0, shot.w, shot.h));
            let m = crop(&shot, desk, (mon.x, mon.y, mon.w, mon.h));
            (Still::Taken(shot, desk), m)
        }
        Err(Failure::Permission) => (Still::Refused, None),
        Err(Failure::Other(e)) => {
            eprintln!("screen still: {e}");
            (Still::Failed, None)
        }
    };
    if std::env::var_os("BLURT_DEBUG_KEYS").is_some() {
        eprintln!("screen still: {} ms", t0.elapsed().as_millis());
    }
    *STILL.lock().unwrap() = Some((Instant::now(), still));
    out
}

/// A snap's area (desktop px) out of its picker's picture; None: no picture (the caller takes it another way).
pub fn cut(r: Region) -> Option<Grab> {
    match take()? {
        Still::Taken(shot, desk) => crop(&shot, desk, (r.x, r.y, r.w, r.h)),
        _ => None,
    }
}

fn flag() -> std::path::PathBuf {
    crate::paths::blurt_home().join("portal").join("screenshot.allowed")
}

/// Allowed before (as far as Blurt knows).
pub fn allowed() -> bool {
    flag().is_file()
}

/// One screenshot of the whole desktop through the portal; its file removed.
fn shoot(parent: Option<u64>) -> Result<Grab, Failure> {
    let uri = block(Duration::from_secs(120), async move {
        crate::hotkeys::portal::register_host_app().await;
        let parent = parent.map(|x| ashpd::WindowIdentifier::from_xid(x as std::os::raw::c_ulong));
        let req = Screenshot::request().identifier(parent).interactive(false).modal(true).send().await.map_err(classify)?;
        req.response().map(|s| s.uri().as_str().to_string()).map_err(classify)
    })
    .unwrap_or_else(|| Err(Failure::Other("timeout".into())))?;
    let path = super::grab::file_path(&uri).ok_or_else(|| Failure::Other(format!("not a file: {uri}")))?;
    let g = decode_png(&path);
    let _ = std::fs::remove_file(&path);
    let g = g.map_err(Failure::Other)?;
    if let Some(d) = flag().parent() {
        let _ = std::fs::create_dir_all(d);
    }
    let _ = std::fs::write(flag(), b"");
    Ok(g)
}

fn classify(e: ashpd::Error) -> Failure {
    let s = e.to_string();
    let low = s.to_lowercase();
    // "Only the focused app is allowed to show a system access dialog" (asked from the background), a "no" in GNOME's
    // dialog (the request's response: cancelled / other), or a "no" remembered in the permission store
    if matches!(e, ashpd::Error::Response(_)) || low.contains("focused") || low.contains("not allowed") || low.contains("permission") {
        let _ = std::fs::remove_file(flag());
        Failure::Permission
    } else {
        Failure::Other(s)
    }
}

/// The desktop in the picker's pixels: every monitor's box together (the app runs under XWayland: X's pixels).
fn desktop(app: &AppHandle) -> Option<(i32, i32, u32, u32)> {
    let ms = app.available_monitors().ok()?;
    let (mut x0, mut y0, mut x1, mut y1) = (i32::MAX, i32::MAX, i32::MIN, i32::MIN);
    for m in &ms {
        let (p, s) = (m.position(), m.size());
        x0 = x0.min(p.x);
        y0 = y0.min(p.y);
        x1 = x1.max(p.x + s.width as i32);
        y1 = y1.max(p.y + s.height as i32);
    }
    (x1 > x0 && y1 > y0).then(|| (x0, y0, (x1 - x0) as u32, (y1 - y0) as u32))
}

/// The picked area (desktop px), out of the picker's picture when it has one. Otherwise shot now; the portal's dialog,
/// when GNOME asks, opens over the island.
pub fn grab(app: &AppHandle, x: i32, y: i32, w: u32, h: u32) -> Result<Grab, Failure> {
    match take() {
        Some(Still::Taken(shot, desk)) => {
            return crop(&shot, desk, (x, y, w, h)).ok_or_else(|| Failure::Other("the area is off the screen".into()));
        }
        // refused a moment ago, before the picker: not asked a second time
        Some(Still::Refused) => return Err(Failure::Permission),
        Some(Still::Failed) | None => {}
    }
    let parent = crate::mainwin::x11_id_off_main(app, "blurt-overlay-island").or_else(|| crate::mainwin::x11_id_off_main(app, "main"));
    let shot = shoot(parent)?;
    let desk = desktop(app).unwrap_or((0, 0, shot.w, shot.h));
    crop(&shot, desk, (x, y, w, h)).ok_or_else(|| Failure::Other("the area is off the screen".into()))
}

/// Settings' "Allow…": the question asked with Blurt's own window in front (its parent), one picture taken and
/// thrown away. Ok: allowed.
pub fn allow(app: &AppHandle) -> Result<(), String> {
    let parent = crate::mainwin::x11_id_off_main(app, "main");
    match shoot(parent) {
        Ok(_) => Ok(()),
        Err(Failure::Permission) => Err("denied".into()),
        Err(Failure::Other(e)) => Err(e),
    }
}
