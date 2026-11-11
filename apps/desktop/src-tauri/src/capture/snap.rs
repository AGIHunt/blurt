//! A snap outside a recording, as the Mac takes it (Captures.swift Snapper.pick / capture / present, InkStage,
//! NoteBubble; docs/design/windows-parity/snap-and-note.md):
//!
//!  • the picker (letting go takes it; a click takes the window under the pointer) stays up, frozen, until the note's
//!    stage covers the screen — no flicker; the picture is taken meanwhile (`tk_recorder.py shot`: the stage, like
//!    every overlay, is left out of captures);
//!  • the stage: the picture frozen where it was taken, the pen on it, the note bubble docked beside it — listening at
//!    once (Windows: Blurt's mic and the warm speech server, dictation/snap_voice.rs), the words heard in grey;
//!  • done (↩ / Done / a click outside / the window left for 3 s / Alt+Shift+A for the next one): its note, type,
//!    strokes (burnt into shots/NNN.marked.png), voice (shots/NNN.wav + its words) and place go into shots.jsonl, and it
//!    becomes a card or is filed (capture.rs `captured`); Esc twice (or the bin): discarded, with Undo in the island.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering::SeqCst};
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use blurt_capture::overlay::{self, Card, Kind};
use blurt_capture::Region;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Listener, Manager, WebviewWindow};

use super::{append_line, captured, last_region, overlay_config, toast_error};
use crate::jobs::JobWriter;
use crate::projects::{self, Registry};
use crate::{island, scripts, settings, AppState};

/// every note has its own number: ops for an older one are ignored by the page
static GEN: AtomicU64 = AtomicU64::new(0);
/// the open note's number (Alt+Shift+A again saves it, then takes the next snap)
static OPEN: Mutex<Option<u64>> = Mutex::new(None);
/// the last discarded snap, for the island's Undo (5 s)
static DISCARDED: Mutex<Option<Discarded>> = Mutex::new(None);
/// the snap whose note is still open (its batch's folder name, n): its shots.jsonl line exists from the shot on, but
/// it is no card until the note is done — then it flies from the selection (the Mac's catchCapture on Done), and a
/// discarded one never counts. Set before the shot is taken (`n` None: any capture from `floor` on — the line can be
/// written, and the island refreshed, before the shot's own n comes back), then narrowed to its n.
static NOTING: Mutex<Option<(std::ffi::OsString, u64, Option<u32>)>> = Mutex::new(None);

pub(super) fn set_noting(v: Option<(&Path, u32)>) {
    *NOTING.lock().unwrap() = v.and_then(|(s, n)| Some((s.file_name()?.to_os_string(), u64::from(n), Some(n))));
}

/// A shot is about to be taken into `session`: whatever it writes from `floor` on is the open note's.
pub(super) fn noting_from(session: &Path, floor: u64) {
    *NOTING.lock().unwrap() = session.file_name().map(|s| (s.to_os_string(), floor, None));
}

/// Is this capture a snap still being noted (capture.rs leaves it out of the cards)?
pub fn noting(session: &Path, n: u64) -> bool {
    NOTING.lock().unwrap().as_ref().is_some_and(|(s, floor, exact)| {
        session.file_name() == Some(s.as_os_str()) && exact.map_or(n >= *floor, |e| u64::from(e) == n)
    })
}

struct Discarded {
    session: PathBuf,
    n: u32,
    project: Option<String>,
    card: Card,
    at: Instant,
}

const UNDO: Duration = Duration::from_secs(6);

/// A snap during a recording (the Mac's ⌥A while recording, BA-60…66): the same picker, in-place note and card, but
/// into the take — its session, its project; the picture is the recording engine's (it numbers the take's stills and
/// stamps them with video time). See [`run_in_take`].
pub struct TakeSnap {
    /// the take's session (its shots/ and shots.jsonl)
    pub session: PathBuf,
    /// where the take goes (the note's chip says it; another project files this snap's item there)
    pub project: Option<String>,
    /// takes the still of `region` (desktop px) into the take: (n, "shots/NNN.png") once its line is written, None if
    /// it failed. Runs on a worker thread while the note opens.
    pub shoot: Box<dyn FnOnce(Region) -> Option<(u32, String)> + Send>,
}

/// Outside a recording.
pub fn run(app: &AppHandle) {
    flow(app, None);
}

/// During a recording: the recording side calls this from the snap hotkey (and the island's snap button) instead of
/// its own frame-only snap; the recording goes on. The card hangs on its thread while the take runs (it goes with the
/// recording: never filed on its own); the take ending takes it off.
pub fn run_in_take(app: &AppHandle, take: TakeSnap) {
    flow(app, Some(take));
}

fn flow(app: &AppHandle, take: Option<TakeSnap>) {
    let cap = &app.state::<AppState>().capture;
    // a note still open: it is saved, then the next snap
    if OPEN.lock().unwrap().is_some() {
        let _ = app.emit_to(Kind::Note.label(), overlay::ev::NOTE, json!({"op": "commit"}));
        let t0 = Instant::now();
        while OPEN.lock().unwrap().is_some() && t0.elapsed() < Duration::from_secs(2) {
            std::thread::sleep(Duration::from_millis(30));
        }
    }
    if !cap.claim() {
        return;
    }
    // the island steps back while the picker and the note are up (its waiting lines hold until after)
    island::busy(app, true);
    let cfg = overlay_config();
    let (region, picker) = match overlay::pick_region_with(app, &cfg, last_snap_region(), overlay::Purpose::Screenshot, true) {
        Ok(Some(p)) => p,
        _ => {
            cap.release();
            island::busy(app, false);
            return;
        }
    };
    let g = GEN.fetch_add(1, SeqCst) + 1;
    *OPEN.lock().unwrap() = Some(g);
    let reg = Registry::load();
    let in_take = take.is_some();
    let (project, session, shoot_in_take) = match take {
        Some(t) => (t.project, t.session, Some(t.shoot)),
        None => {
            let (p, s) = projects::shots_session(&reg);
            (p, s, None)
        }
    };
    let _ = app.asset_protocol_scope().allow_directory(&session, true);

    // the picture, while the stage opens over the frozen picker
    let (stx, srx) = channel::<Option<(u32, String)>>();
    noting_from(&session, super::next_shot_n(&session));
    {
        let (app, session, project) = (app.clone(), session.clone(), project.clone());
        std::thread::spawn(move || {
            let r = match shoot_in_take {
                Some(f) => f(region),
                None => shoot(&app, &session, project.as_deref(), region),
            };
            if let Some((n, _)) = &r {
                set_noting(Some((&session, *n)));
            }
            let _ = stx.send(r);
        });
    }
    // tests (overlays capturable): the stage would be in the picture, so it waits for it
    let mut shot: Option<(u32, String)> = None;
    if cfg.capturable {
        shot = srx.recv().ok().flatten();
        if shot.is_none() {
            return failed(app, g, None);
        }
    }

    let voice = voice_state();
    let first = ink_hint();
    let mut params: BTreeMap<&'static str, String> = BTreeMap::new();
    params.insert("g", g.to_string());
    params.insert("place", project.clone().unwrap_or_default());
    params.insert("projects", projects_json(&reg));
    params.insert("voice", voice.into());
    params.insert("hint", if first { "1" } else { "0" }.into());
    params.insert("first", if first { "1" } else { "0" }.into());
    if let Some((n, file)) = &shot {
        params.insert("n", n.to_string());
        params.insert("src", overlay::file_src(&session.join(file)));
    } else if let Some((still, mon)) = STILL.lock().unwrap().clone().filter(|(p, m)| p.is_file() && m.contains(region.x, region.y)) {
        // no picture yet: the picker's still of this monitor stands in (the note's window covers the same monitor)
        let _ = mon;
        params.insert("still", overlay::file_src(&still));
    }

    let label = Kind::Note.label();
    let (dtx, drx) = channel::<Option<Value>>();
    let mic: Arc<Mutex<Option<MicHandle>>> = Arc::default();
    let picker = Arc::new(Mutex::new(picker));
    let mut ids = vec![];
    {
        let dtx = dtx.clone();
        ids.push(overlay::listen_from(app, overlay::ev::NOTE_DONE, label, move |v| {
            if v["g"].as_u64() == Some(g) {
                let _ = dtx.send(Some(v));
            }
        }));
    }
    {
        let mic = mic.clone();
        ids.push(overlay::listen_from(app, overlay::ev::ACTION, label, move |v| {
            if v["g"].as_u64() != Some(g) {
                return;
            }
            if let Some(m) = mic.lock().unwrap().as_ref() {
                match v["action"].as_str() {
                    Some("note.mic") => mic_stop(m, v["keep"] == true),
                    Some("note.activity") => mic_activity(m),
                    _ => {}
                }
            }
        }));
    }
    {
        // the stage is drawn: the frozen picker under it goes
        let picker = picker.clone();
        ids.push(overlay::listen_from(app, overlay::ev::READY, label, move |_| {
            if let Some(w) = picker.lock().unwrap().take() {
                let _ = w.destroy();
            }
        }));
    }
    let close_picker = {
        let picker = picker.clone();
        move || {
            if let Some(w) = picker.lock().unwrap().take() {
                let _ = w.destroy();
            }
        }
    };
    let w = match overlay::snap_note(app, &cfg, region, params) {
        Ok(w) => w,
        Err(e) => {
            eprintln!("blurt: snap note: {e}");
            close_picker();
            for id in ids {
                app.unlisten(id);
            }
            // no note: the snap is kept as it is
            let shot = shot.or_else(|| srx.recv().ok().flatten());
            *OPEN.lock().unwrap() = None;
            set_noting(None);
            cap.release();
            island::busy(app, false);
            if let Some((n, file)) = shot {
                island::shutter(app);
                captured(app, &session, project.clone(), Card::from_shot(&session, n, &file, None));
            } else {
                toast_error(app, "snap");
            }
            return;
        }
    };
    {
        let dtx = dtx.clone();
        w.on_window_event(move |e| {
            if matches!(e, tauri::WindowEvent::Destroyed) {
                let _ = dtx.send(None);
            }
        });
    }
    {
        // never longer than a moment: a page that doesn't say it is ready still gets the screen back
        let close_picker = close_picker.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(1500));
            close_picker();
        });
    }
    if voice == "listen" {
        *mic.lock().unwrap() = mic_start(app, g);
    }

    // the picture
    if shot.is_none() {
        shot = srx.recv_timeout(Duration::from_secs(35)).ok().flatten();
    }
    let Some((n, file)) = shot else {
        if let Some(m) = mic.lock().unwrap().take() {
            mic_stop(&m, false);
        }
        for id in ids {
            app.unlisten(id);
        }
        close_picker();
        return failed(app, g, Some(w));
    };
    // the frame is on disk: the shutter (record.snap_sound) and the island's flash
    island::shutter(app);
    let _ = app.emit_to(label, overlay::ev::NOTE, json!({"op": "shot", "n": n, "src": overlay::file_src(&session.join(&file)), "g": g}));
    // "L last area" next time: only an area that gave a picture (LastArea)
    let _ = settings::merge(json!({"record": {"last_snap_px": [region.x, region.y, region.w, region.h]}}));

    // the note
    let done = drx.recv().ok().flatten();
    for id in ids {
        app.unlisten(id);
    }
    close_picker();
    *OPEN.lock().unwrap() = None;
    cap.release();
    island::busy(app, false);
    // a window gone without an answer (replaced, closed by the system): the snap is kept as it is
    let d = done.unwrap_or_else(|| json!({"save": true, "voice": "keep"}));
    {
        let flash = d["flash"] == true;
        std::thread::spawn(move || {
            // after its "Saved" moment, or its fade
            std::thread::sleep(Duration::from_millis(if flash { 650 } else { 220 }));
            let _ = w.destroy();
        });
    }
    let m = mic.lock().unwrap().take();
    settle(app, &session, n, &file, project, &d, m, in_take, region);
}

/// The picture couldn't be had: the stage goes, the island says so.
fn failed(app: &AppHandle, g: u64, w: Option<WebviewWindow>) {
    let _ = app.emit_to(Kind::Note.label(), overlay::ev::NOTE, json!({"op": "failed", "g": g}));
    if let Some(w) = w {
        let _ = w.destroy();
    }
    *OPEN.lock().unwrap() = None;
    set_noting(None);
    app.state::<AppState>().capture.release();
    island::busy(app, false);
    toast_error(app, "snap");
}

/// One frame of the region into the open shots batch → (n, "shots/NNN.png").
fn shoot(app: &AppHandle, session: &Path, project: Option<&str>, region: Region) -> Option<(u32, String)> {
    let runner = app.state::<AppState>().runner();
    let mut args = vec!["shot".to_string(), scripts::s(session), "--region".into(), format!("{},{},{},{}", region.x, region.y, region.w, region.h)];
    if let Some(p) = project {
        args.extend(["--project".into(), p.to_string()]);
    }
    // Linux: the picker's picture, cut to the area (x11grab would see only XWayland windows; a portal picture taken now
    // would hold the frozen picker); without one (GNOME refused), x11grab as before
    #[cfg(target_os = "linux")]
    let image = crate::screen_text::grab_linux::cut(region).and_then(|g| {
        let p = crate::paths::blurt_home().join("run").join(format!("snap-{}.png", std::process::id()));
        let _ = std::fs::create_dir_all(p.parent()?);
        crate::screen_text::grab::write_png(&p, &g).ok().map(|_| p)
    });
    #[cfg(not(target_os = "linux"))]
    let image: Option<PathBuf> = None;
    if let Some(p) = &image {
        args.extend(["--image".into(), scripts::s(p)]);
    }
    let job = JobWriter::new("snap", project, Some(session), None, None, &["capture"]);
    job.step("capture", "running", None);
    let ran = runner.run("tk_recorder.py", &args, None, Duration::from_secs(30));
    if let Some(p) = &image {
        let _ = std::fs::remove_file(p);
    }
    match ran {
        Ok(r) => {
            let n = r["n"].as_u64().unwrap_or(0);
            job.set_captures(&[n]);
            job.finish("done", None);
            Some((n as u32, r["file"].as_str().unwrap_or("").to_string()))
        }
        Err(_) => {
            job.finish("failed", Some(("io", "no frame")));
            None
        }
    }
}

/// What the note decided (note.ts `SnapDone`) goes into shots.jsonl; then the snap is a card, filed, or discarded.
#[allow(clippy::too_many_arguments)]
fn settle(
    app: &AppHandle,
    session: &Path,
    n: u32,
    file: &str,
    shot_project: Option<String>,
    d: &Value,
    mic: Option<MicHandle>,
    in_take: bool,
    region: Region,
) {
    let save = d["save"] != false;
    if !save {
        // Esc on a fresh snap: said at once (the Mac posts its Undo line at once) — nothing below waits for it
        append_line(session, &json!({"n": n, "deleted": true}));
        set_noting(None);
        island::send(
            app,
            json!({"op": "toast", "kind": "capture", "msg": "snap.discarded", "action": {"a": "snap.undo", "label": "snap.undo"}, "ms": 5000}),
        );
        island::refresh_cards(app);
    }
    let rel = format!("shots/{n:03}.wav");
    let keep_voice = d["voice"] == "keep";
    // the recording: kept as the snap's voice with its words (the page's, when the words were taken and edited); a
    // discarded snap's words come in on their own thread, for its Undo
    let (said, voice_thread) = if save {
        (mic.and_then(|m| mic_finish(&m, keep_voice, &session.join(&rel))), None)
    } else {
        let (s, rel, wav) = (session.to_path_buf(), rel.clone(), session.join(&rel));
        let t = mic.map(|m| {
            std::thread::spawn(move || {
                if let Some(words) = mic_finish(&m, keep_voice, &wav) {
                    append_line(&s, &json!({"n": n, "voice": rel, "said": words}));
                }
            })
        });
        (None, t)
    };
    let text = d["text"].as_str().map(str::trim).filter(|t| !t.is_empty()).map(str::to_owned);
    let mut line = json!({"n": n, "text": text, "kind": d.get("kind").cloned().unwrap_or(Value::Null)});
    let mut said_now: Option<String> = None;
    if let Some(auto) = said {
        said_now = d["said"].as_str().map(str::to_owned).or(auto);
        line["voice"] = json!(rel);
        line["said"] = json!(said_now);
    }
    let strokes: Vec<Vec<[f64; 2]>> = serde_json::from_value(d["strokes"].clone()).unwrap_or_default();
    let mut shown = file.to_string();
    if !strokes.is_empty() {
        line["strokes"] = json!(strokes);
        let marked = format!("shots/{n:03}.marked.png");
        let lw = d["lw"].as_f64().unwrap_or(4.0);
        let sel_w = d["selW"].as_f64().unwrap_or(0.0);
        if ink::burn(&session.join(file), &session.join(&marked), &strokes, lw, sel_w) {
            line["marked"] = json!(marked);
            shown = marked;
        }
    }
    append_line(session, &line);
    // the place the chip chose: this snap goes there (the island's current project stays)
    let place = match &d["place"] {
        Value::String(p) if !p.is_empty() => Some(p.clone()),
        Value::Null => None,
        _ => shot_project.clone(),
    };
    if place != shot_project {
        match &place {
            Some(p) => append_line(session, &json!({"n": n, "project": p, "assigned_by": "capture"})),
            None => append_line(session, &json!({"n": n, "project": null, "assigned_by": null})),
        }
    }
    let card = Card::from_shot(session, n, &shown, merged(text.as_deref(), said_now.as_deref()));
    // the card flies from where the picture was taken (the Mac's catchCapture from the selection)
    let from = island::screen_to_css(app, region);
    // the card exists from here (not from the shot): it flies from the selection into the island — once the stage's
    // window is gone: while that full-screen window covers it, WebView2 holds the island's animation frames (an
    // occluded page), and the card would only appear at the end of its flight
    if save {
        note_gone(app);
    }
    if save && in_take {
        // a take's snap hangs while the take runs; it goes with the recording (its organizing run makes its item)
        island::send(app, json!({"op": "card", "card": card, "pull": false, "from": from}));
        set_noting(None);
        return;
    }
    if save {
        match place {
            Some(p) => {
                island::send(app, json!({"op": "card", "card": card, "pull": true, "from": from}));
                set_noting(None);
                // filed at once: captures.py, no agent (the Mac's Snapper.settled → file)
                super::file_now(app, session, vec![u64::from(n)], &p, None);
            }
            None => {
                island::send(app, json!({"op": "card", "card": card, "pull": false, "from": from}));
                set_noting(None);
                island::refresh_cards(app);
            }
        }
        return;
    }
    // discarded (said above); what was said, typed and drawn comes back with Undo
    let at = Instant::now();
    *DISCARDED.lock().unwrap() = Some(Discarded { session: session.to_path_buf(), n, project: place, card, at });
    // its files stay while Undo can bring it back, then go to the Recycle Bin (the Mac's Trash: recoverable)
    let (session, base) = (session.to_path_buf(), format!("shots/{n:03}"));
    std::thread::spawn(move || {
        std::thread::sleep(UNDO);
        // (its voice written first: never a wav left behind)
        if let Some(t) = voice_thread {
            let _ = t.join();
        }
        let mine = DISCARDED.lock().unwrap().as_ref().is_some_and(|d| d.n == n && d.session == session && d.at == at);
        if !mine {
            return;
        }
        *DISCARDED.lock().unwrap() = None;
        let files: Vec<PathBuf> = ["png", "marked.png", "wav"].iter().map(|x| session.join(format!("{base}.{x}"))).filter(|p| p.is_file()).collect();
        recycle(&files);
    });
}

/// Files to the Recycle Bin (recoverable, as the Mac's Trash), quietly: no dialog, no progress.
#[cfg(windows)]
fn recycle(files: &[PathBuf]) {
    use windows::core::PCWSTR;
    use windows::Win32::UI::Shell::{SHFileOperationW, FOF_ALLOWUNDO, FOF_NOCONFIRMATION, FOF_NOERRORUI, FOF_SILENT, FO_DELETE, SHFILEOPSTRUCTW};
    if files.is_empty() {
        return;
    }
    // a list of paths, each ended by a NUL, the whole list by another
    let mut from: Vec<u16> = Vec::new();
    for f in files {
        from.extend(crate::paths::normalize(f).as_os_str().to_string_lossy().encode_utf16());
        from.push(0);
    }
    from.push(0);
    let mut op = SHFILEOPSTRUCTW {
        wFunc: FO_DELETE,
        pFrom: PCWSTR(from.as_ptr()),
        fFlags: (FOF_ALLOWUNDO.0 | FOF_NOCONFIRMATION.0 | FOF_SILENT.0 | FOF_NOERRORUI.0) as u16,
        ..Default::default()
    };
    // SAFETY: `from` outlives the call; the struct is fully initialised
    let r = unsafe { SHFileOperationW(&mut op) };
    if r != 0 {
        eprintln!("blurt: recycle: {r:#x}");
    }
}

/// Linux: the desktop's trash when `gio` is there (else the files stay, the line says deleted).
#[cfg(not(windows))]
fn recycle(files: &[PathBuf]) {
    if !files.is_empty() {
        let _ = std::process::Command::new("gio").arg("trash").args(files).status();
    }
}

// ------------------------------------------------------------------ Edit Note on a card (the Mac's mode .edit)

/// One capture's line in shots.jsonl, later lines winning key by key.
fn line_of(session: &Path, n: u32) -> serde_json::Map<String, Value> {
    let raw = std::fs::read_to_string(session.join("shots.jsonl")).unwrap_or_default();
    let mut m = serde_json::Map::new();
    for l in raw.lines() {
        if let Ok(Value::Object(o)) = serde_json::from_str::<Value>(l) {
            if o.get("n").and_then(Value::as_u64) == Some(u64::from(n)) {
                m.extend(o);
            }
        }
    }
    m
}

/// "Edit Note…" on a card: the same composer in its own window under the island — the whole note as text (typed, then
/// said), the unmarked picture enlarged with its strokes and the pen, the type and the place, the voice to play and
/// Record Again; Save ↩ keeps it (NoteEdit), Esc puts everything back. Blocks until it closes: call on a worker thread.
/// `under`: the card's own rect on the screen (physical px) — the composer opens under that card (else under the island).
pub fn edit_note(app: &AppHandle, session: &Path, n: u32, under: Option<Region>) {
    let line = line_of(session, n);
    if line.is_empty() {
        return;
    }
    let s = |k: &str| line.get(k).and_then(Value::as_str).filter(|v| !v.is_empty()).map(str::to_owned);
    let (file, typed, said, kind, project) = (s("file"), s("text"), s("said"), s("kind"), s("project"));
    let strokes_was = line.get("strokes").cloned().unwrap_or(json!([]));
    let voice_rel = s("voice").unwrap_or_else(|| format!("shots/{n:03}.wav"));
    let has_voice = session.join(&voice_rel).is_file();
    let _ = app.asset_protocol_scope().allow_directory(session, true);
    let g = GEN.fetch_add(1, SeqCst) + 1;
    let reg = Registry::load();
    let mut params: BTreeMap<&'static str, String> = BTreeMap::new();
    params.insert("mode", "edit".into());
    params.insert("g", g.to_string());
    params.insert("n", n.to_string());
    params.insert("text", merged(typed.as_deref(), said.as_deref()).unwrap_or_default());
    params.insert("typed", typed.clone().unwrap_or_default());
    params.insert("said", said.clone().unwrap_or_default());
    params.insert("kind", kind.unwrap_or_default());
    params.insert("place", project.clone().filter(|p| p != "inbox").unwrap_or_default());
    params.insert("projects", projects_json(&reg));
    params.insert("strokes", strokes_was.to_string());
    params.insert("first", "0".into());
    if has_voice {
        params.insert("voiceSrc", overlay::file_src(&session.join(&voice_rel)));
    }
    if let Some(f) = file.as_deref().filter(|f| session.join(f).is_file()) {
        params.insert("src", overlay::file_src(&session.join(f)));
        if let Ok(img) = tauri::image::Image::from_path(session.join(f)) {
            params.insert("pw", img.width().to_string());
            params.insert("ph", img.height().to_string());
        }
        // the region's width as it was on the screen (CSS px): the pen draws as wide as the snap's own line
        if let Some(r) = line.get("region").and_then(Value::as_array).and_then(|r| r.get(2)).and_then(Value::as_f64) {
            params.insert("rw", r.to_string());
        }
    }
    let cfg = overlay_config();
    let anchor = under.map(|r| Region::new(r.x + r.w as i32 / 2 - 1, r.bottom() + 8, 2, 2)).unwrap_or_else(|| super::island_anchor(app));
    let at = Region::new(anchor.x - 300, anchor.y, 600, 480);
    let label = Kind::Note.label();
    let (dtx, drx) = channel::<Option<Value>>();
    let mic: Arc<Mutex<Option<MicHandle>>> = Arc::default();
    let mut ids = vec![];
    {
        let dtx = dtx.clone();
        ids.push(overlay::listen_from(app, overlay::ev::NOTE_DONE, label, move |v| {
            if v["g"].as_u64() == Some(g) {
                let _ = dtx.send(Some(v));
            }
        }));
    }
    {
        let (mic, a) = (mic.clone(), app.clone());
        ids.push(overlay::listen_from(app, overlay::ev::ACTION, label, move |v| {
            if v["g"].as_u64() != Some(g) {
                return;
            }
            match v["action"].as_str() {
                Some("note.size") => {
                    // the window fits the bubble, centred under the island
                    let (Some(w), Some(h)) = (v["w"].as_f64(), v["h"].as_f64()) else { return };
                    if let Some(win) = a.get_webview_window(label) {
                        let sc = win.scale_factor().unwrap_or(1.0);
                        let _ = win.set_size(tauri::LogicalSize::new(w, h));
                        let _ = win.set_position(tauri::PhysicalPosition::new(anchor.x - (w * sc / 2.0) as i32, anchor.y));
                    }
                }
                Some("note.record") => {
                    // Record Again: a retake in progress goes, a new one starts
                    let mut m = mic.lock().unwrap();
                    if let Some(old) = m.take() {
                        mic_stop(&old, false);
                    }
                    *m = mic_start(&a, g);
                    if m.is_none() {
                        let _ = a.emit_to(label, overlay::ev::NOTE, json!({"op": "voice", "state": "nomic", "g": g}));
                    }
                }
                Some("note.mic") => {
                    if let Some(m) = mic.lock().unwrap().as_ref() {
                        mic_stop(m, v["keep"] == true);
                    }
                }
                Some("note.activity") => {
                    if let Some(m) = mic.lock().unwrap().as_ref() {
                        mic_activity(m);
                    }
                }
                _ => {}
            }
        }));
    }
    let Ok(w) = overlay::open(app, Kind::Note, &cfg, at, params) else {
        for id in ids {
            app.unlisten(id);
        }
        return;
    };
    w.on_window_event(move |e| {
        if matches!(e, tauri::WindowEvent::Destroyed) {
            let _ = dtx.send(None);
        }
    });
    // the row stays down while the card is being edited: the bubble's tail keeps pointing at it
    island::send(app, json!({"op": "editing", "on": true}));
    let done = drx.recv().ok().flatten();
    island::send(app, json!({"op": "editing", "on": false}));
    for id in ids {
        app.unlisten(id);
    }
    {
        let flash = done.as_ref().is_some_and(|d| d["flash"] == true);
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(if flash { 650 } else { 220 }));
            let _ = w.destroy();
        });
    }
    let m = mic.lock().unwrap().take();
    let Some(d) = done.filter(|d| d["save"] == true) else {
        // Esc (or the window gone): as it was — a re-record goes, the note it would have replaced was never touched
        if let Some(m) = m {
            let _ = mic_finish(&m, false, &session.join(&voice_rel));
        }
        return;
    };
    let mut out = json!({"n": n, "text": d["text"], "said": d["said"], "kind": d.get("kind").cloned().unwrap_or(Value::Null)});
    // a kept re-record takes the original's place; its words are the note's words now
    if let Some(m) = m {
        if let Some(words) = mic_finish(&m, d["voice"] == "keep", &session.join(&voice_rel)) {
            out["voice"] = json!(voice_rel);
            if d["said"].is_null() {
                out["said"] = json!(words);
            }
        }
    }
    let strokes: Vec<Vec<[f64; 2]>> = serde_json::from_value(d["strokes"].clone()).unwrap_or_default();
    if json!(strokes) != strokes_was {
        out["strokes"] = json!(strokes);
        let marked = format!("shots/{n:03}.marked.png");
        if strokes.is_empty() {
            let _ = std::fs::remove_file(session.join(&marked));
            out["marked"] = Value::Null;
        } else if let Some(f) = &file {
            let ok = ink::burn(&session.join(f), &session.join(&marked), &strokes, d["lw"].as_f64().unwrap_or(4.0), d["selW"].as_f64().unwrap_or(0.0));
            if ok {
                out["marked"] = json!(marked);
            }
        }
    }
    append_line(session, &out);
    // a place picked in its chip: the card goes there now (Move To's own path)
    let place = d["place"].as_str().filter(|p| !p.is_empty()).map(str::to_owned);
    let was = project.filter(|p| p != "inbox");
    if place != was {
        match place {
            // filed there now, no agent (Move To's own path: captures.py)
            Some(p) => super::file_now(app, session, vec![u64::from(n)], &p, Some("user")),
            None => append_line(session, &json!({"n": n, "project": null, "assigned_by": null})),
        }
    }
    island::refresh_cards(app);
}

/// Waits (at most ~1 s) until the note's window is gone, and a frame more.
fn note_gone(app: &AppHandle) {
    let t0 = Instant::now();
    while app.get_webview_window(Kind::Note.label()).is_some() && t0.elapsed() < Duration::from_millis(1000) {
        std::thread::sleep(Duration::from_millis(20));
    }
    std::thread::sleep(Duration::from_millis(30));
}

/// The island's Undo on "Snap discarded".
pub fn undo(app: &AppHandle) {
    let Some(d) = DISCARDED.lock().unwrap().take().filter(|d| d.at.elapsed() < UNDO) else { return };
    append_line(&d.session, &json!({"n": d.n, "deleted": false}));
    captured(app, &d.session, d.project, d.card);
}

/// The note's text and its words as one (the card's: BlurtCore CardNote.merged).
fn merged(typed: Option<&str>, said: Option<&str>) -> Option<String> {
    let c = |s: Option<&str>| s.map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned);
    match (c(typed), c(said)) {
        (Some(t), Some(s)) if t == s || t.contains(&s) => Some(t),
        (Some(t), Some(s)) if s.contains(&t) => Some(s),
        (Some(t), Some(s)) => Some(format!("{t}\n{s}")),
        (t, s) => t.or(s),
    }
}

/// A snap's "L": its own last area, else the recording's.
fn last_snap_region() -> Option<Region> {
    let v = settings::read_config();
    let r: Vec<i64> = v.pointer("/record/last_snap_px").and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_i64).collect()).unwrap_or_default();
    if r.len() == 4 && r[2] > 0 && r[3] > 0 {
        return Some(Region::new(r[0] as i32, r[1] as i32, r[2] as u32, r[3] as u32));
    }
    last_region()
}

/// The place list's projects, recent first (the registry's order): {id, name, key, missing}.
fn projects_json(reg: &Registry) -> String {
    let v: Vec<Value> = reg
        .projects
        .iter()
        .filter(|p| p["id"].as_str().is_some_and(|id| id != "inbox"))
        .map(|p| {
            let missing = !p["path"].as_str().is_some_and(|x| Path::new(x).is_dir());
            json!({"id": p["id"], "name": p["name"], "key": p["key"], "missing": missing})
        })
        .collect();
    serde_json::to_string(&v).unwrap_or_else(|_| "[]".into())
}

/// The stage's pen hint and the list's keys, the first few snaps only (record.ink_hint_shown; BlurtCore InkHint).
fn ink_hint() -> bool {
    let n = settings::read_config().pointer("/record/ink_hint_shown").and_then(Value::as_u64).unwrap_or(0);
    if n >= 3 {
        return false;
    }
    let _ = settings::merge(json!({"record": {"ink_hint_shown": n + 1}}));
    true
}

/// A teaching line shows the first 3 times (the Mac's HintBudget): record.hints.<key>.
pub fn hint_budget(key: &str) -> bool {
    if std::env::var("BLURT_TEST_HINTS").as_deref() == Ok("always") {
        return true;
    }
    let n = settings::read_config().pointer(&format!("/record/hints/{key}")).and_then(Value::as_u64).unwrap_or(0);
    if n >= 3 {
        return false;
    }
    let _ = settings::merge(json!({"record": {"hints": {key: n + 1}}}));
    true
}

// ------------------------------------------------------------------ the note's microphone

#[cfg(dict)]
type MicHandle = Arc<crate::dictation::snap_voice::NoteMic>;
#[cfg(not(dict))]
type MicHandle = ();

/// listen | busy (a voice note has the mic: typed only) | nomic (dictation is listening; no mic here)
#[cfg(dict)]
fn voice_state() -> &'static str {
    crate::dictation::snap_voice::state()
}
#[cfg(not(dict))]
fn voice_state() -> &'static str {
    "nomic"
}

#[cfg(dict)]
fn mic_start(app: &AppHandle, g: u64) -> Option<MicHandle> {
    let a = app.clone();
    let m = crate::dictation::snap_voice::start(app, move |mut op: Value| {
        op["g"] = json!(g);
        let _ = a.emit_to(Kind::Note.label(), overlay::ev::NOTE, op);
    });
    Some(Arc::new(m))
}
#[cfg(not(dict))]
fn mic_start(_app: &AppHandle, _g: u64) -> Option<MicHandle> {
    None
}

#[cfg(dict)]
fn mic_stop(m: &MicHandle, keep: bool) {
    m.stop(keep);
}
#[cfg(not(dict))]
fn mic_stop(_m: &MicHandle, _keep: bool) {}

#[cfg(dict)]
fn mic_activity(m: &MicHandle) {
    m.activity();
}
#[cfg(not(dict))]
fn mic_activity(_m: &MicHandle) {}

/// The take kept and written to `wav`: Some(its words); None when there is no recording.
#[cfg(dict)]
fn mic_finish(m: &MicHandle, keep: bool, wav: &Path) -> Option<Option<String>> {
    let take = m.finish(keep)?;
    crate::dictation::snap_voice::write(&take, wav).ok()?;
    Some(take.said)
}
#[cfg(not(dict))]
fn mic_finish(_m: &MicHandle, _keep: bool, _wav: &Path) -> Option<Option<String>> {
    None
}

// ------------------------------------------------------------------ the windows a click can take

/// The visible top-level windows, top first, in physical px (the Mac's PickerView.windowRect): not ours, not
/// minimised, not cloaked (another desktop, a suspended app), not a tool window, not the desktop or the taskbar; their
/// visible frame (DWM's, without the invisible resize border).
#[cfg(windows)]
pub fn visible_windows() -> Option<Vec<Region>> {
    use windows::core::BOOL;
    use windows::Win32::Foundation::{HWND, LPARAM, RECT};
    use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS};
    use windows::Win32::UI::WindowsAndMessaging::{
        EnumWindows, GetClassNameW, GetWindowLongW, GetWindowRect, GetWindowThreadProcessId, IsIconic, IsWindowVisible, GWL_EXSTYLE,
        WS_EX_TOOLWINDOW,
    };

    unsafe extern "system" fn each(h: HWND, l: LPARAM) -> BOOL {
        // SAFETY: `l` is the &mut Vec passed to EnumWindows below, alive for the whole enumeration
        let out = unsafe { &mut *(l.0 as *mut Vec<Region>) };
        unsafe {
            if !IsWindowVisible(h).as_bool() || IsIconic(h).as_bool() {
                return BOOL(1);
            }
            if (GetWindowLongW(h, GWL_EXSTYLE) as u32) & WS_EX_TOOLWINDOW.0 != 0 {
                return BOOL(1);
            }
            let mut cloaked: u32 = 0;
            if DwmGetWindowAttribute(h, DWMWA_CLOAKED, &mut cloaked as *mut u32 as *mut core::ffi::c_void, 4).is_ok() && cloaked != 0 {
                return BOOL(1);
            }
            let mut pid = 0u32;
            GetWindowThreadProcessId(h, Some(&mut pid));
            if pid == std::process::id() {
                return BOOL(1);
            }
            let mut class = [0u16; 64];
            let len = GetClassNameW(h, &mut class).max(0) as usize;
            let class = String::from_utf16_lossy(&class[..len]);
            if matches!(class.as_str(), "Progman" | "WorkerW" | "Shell_TrayWnd" | "Shell_SecondaryTrayWnd") {
                return BOOL(1);
            }
            let mut r = RECT::default();
            let got = DwmGetWindowAttribute(
                h,
                DWMWA_EXTENDED_FRAME_BOUNDS,
                &mut r as *mut RECT as *mut core::ffi::c_void,
                std::mem::size_of::<RECT>() as u32,
            );
            if got.is_err() && GetWindowRect(h, &mut r).is_err() {
                return BOOL(1);
            }
            let (w, ht) = (r.right - r.left, r.bottom - r.top);
            if w > 40 && ht > 40 {
                out.push(Region::new(r.left, r.top, w as u32, ht as u32));
            }
        }
        BOOL(1)
    }

    let mut v: Vec<Region> = Vec::new();
    // SAFETY: the callback only runs during this call and only touches `v` through the pointer
    let _ = unsafe { EnumWindows(Some(each), LPARAM(&mut v as *mut Vec<Region> as isize)) };
    Some(v)
}

/// The loupe's still of a monitor (desktop px), a BMP under $BLURT_HOME/run (inside the asset protocol's scope) — a new
/// name each time (the page's cache), the one before removed.
#[cfg(windows)]
pub fn monitor_still(r: Region) -> Option<PathBuf> {
    keep_still(&crate::screen_text::ocr_win::grab(r.x, r.y, r.w, r.h).ok()?, r)
}

/// Linux: the whole desktop through GNOME's Screenshot portal, kept for the pick (screen_text::grab_linux: the snap and
/// Copy Text are cut out of it, since GNOME can't leave the picker out of a later picture).
#[cfg(target_os = "linux")]
pub fn monitor_still(r: Region) -> Option<PathBuf> {
    keep_still(&crate::screen_text::grab_linux::picker_still(r)?, r)
}

#[cfg(any(windows, target_os = "linux"))]
fn keep_still(g: &crate::screen_text::grab::Grab, r: Region) -> Option<PathBuf> {
    static N: AtomicU64 = AtomicU64::new(0);
    let dir = crate::paths::blurt_home().join("run");
    let _ = std::fs::create_dir_all(&dir);
    let k = N.fetch_add(1, SeqCst);
    if k == 0 {
        // the first picker of this run: stills an earlier run left behind (quit, crash) go
        let mine = format!("loupe-{}-", std::process::id());
        for e in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with("loupe-") && name.ends_with(".bmp") && !name.starts_with(&mine) {
                let _ = std::fs::remove_file(e.path());
            }
        }
    }
    let p = dir.join(format!("loupe-{}-{k}.bmp", std::process::id()));
    crate::screen_text::grab::write_bmp(&p, g).ok()?;
    if let Some(old) = STILL.lock().unwrap().replace((p.clone(), r)) {
        let _ = std::fs::remove_file(old.0);
    }
    Some(p)
}

/// The last picker's still (its file, the monitor it shows in desktop px): the note's stage paints the frozen picture
/// from it the moment it opens, before the snap's own PNG is on disk (the Mac crops LoupeStills the same way).
static STILL: Mutex<Option<(PathBuf, Region)>> = Mutex::new(None);
#[cfg(not(any(windows, target_os = "linux")))]
pub fn monitor_still(_r: Region) -> Option<PathBuf> {
    None
}

/// No window list here: a click in the picker takes the whole screen.
#[cfg(not(windows))]
pub fn visible_windows() -> Option<Vec<Region>> {
    None
}

// ------------------------------------------------------------------ the ink, burnt into the picture

mod ink {
    //! shots/NNN.marked.png: the strokes on a copy of the picture (the Mac's renderMarked) — the markup colour, round
    //! ends, a soft dark shadow; strokes are 0–1 point lists drawn through their midpoints (quadratic curves), a single
    //! point a ring of 4.5 line widths.

    use std::path::Path;

    const MARKUP: [f32; 3] = [255.0, 92.0, 61.0]; // #FF5C3D (BrandColor.markup)

    /// `lw`: the line in the stage's CSS px, `sel_w`: the picture's width there (the line keeps its look at 1:1).
    pub fn burn(src: &Path, out: &Path, strokes: &[Vec<[f64; 2]>], lw: f64, sel_w: f64) -> bool {
        let Ok(img) = tauri::image::Image::from_path(src) else { return false };
        let (w, h) = (img.width() as usize, img.height() as usize);
        let mut px = img.rgba().to_vec();
        let scale = if sel_w > 0.0 { w as f64 / sel_w } else { 1.0 };
        render(&mut px, w, h, strokes, (lw * scale).max(1.0));
        write_png(out, &px, w as u32, h as u32).is_ok()
    }

    pub fn render(px: &mut [u8], w: usize, h: usize, strokes: &[Vec<[f64; 2]>], lw: f64) {
        let r = lw / 2.0;
        let blur = (lw * 0.4).max(1.0);
        let mut cov = vec![0f32; w * h];
        let mut shade = vec![0f32; w * h];
        let mut stamp = |cx0: f64, cy0: f64, cx1: f64, cy1: f64, dist: &dyn Fn(f64, f64) -> f64| {
            let pad = r + blur + 1.0;
            let (x0, x1) = (((cx0.min(cx1) - pad).floor().max(0.0)) as usize, ((cx0.max(cx1) + pad).ceil().min(w as f64 - 1.0)).max(0.0) as usize);
            let (y0, y1) = (((cy0.min(cy1) - pad).floor().max(0.0)) as usize, ((cy0.max(cy1) + pad).ceil().min(h as f64 - 1.0)).max(0.0) as usize);
            for y in y0..=y1.min(h.saturating_sub(1)) {
                for x in x0..=x1.min(w.saturating_sub(1)) {
                    let d = dist(x as f64 + 0.5, y as f64 + 0.5);
                    let c = (r + 0.5 - d).clamp(0.0, 1.0) as f32;
                    let s = ((r + blur - d) / (2.0 * blur)).clamp(0.0, 1.0) as f32 * 0.45;
                    let i = y * w + x;
                    cov[i] = cov[i].max(c);
                    shade[i] = shade[i].max(s);
                }
            }
        };
        for s in strokes {
            let pts: Vec<(f64, f64)> = s.iter().map(|p| (p[0] * w as f64, p[1] * h as f64)).collect();
            if pts.is_empty() {
                continue;
            }
            if pts.len() == 1 {
                let (cx, cy) = pts[0];
                let ring = lw * 4.5;
                stamp(cx - ring, cy - ring, cx + ring, cy + ring, &|x, y| ((x - cx).hypot(y - cy) - ring).abs());
                continue;
            }
            for (a, b) in polyline(&pts).windows(2).map(|p| (p[0], p[1])) {
                stamp(a.0, a.1, b.0, b.1, &|x, y| seg_dist((x, y), a, b));
            }
        }
        for i in 0..w * h {
            let (c, s) = (cov[i], shade[i]);
            if c == 0.0 && s == 0.0 {
                continue;
            }
            for k in 0..3 {
                let v = px[i * 4 + k] as f32 * (1.0 - s);
                px[i * 4 + k] = (v * (1.0 - c) + MARKUP[k] * c).round().clamp(0.0, 255.0) as u8;
            }
            px[i * 4 + 3] = px[i * 4 + 3].max((255.0 * c.max(s)) as u8);
        }
    }

    /// The path every renderer draws: from the first point, quadratic curves through the midpoints (each point the
    /// control), a line to the last — sampled into segments.
    fn polyline(p: &[(f64, f64)]) -> Vec<(f64, f64)> {
        let mut out = vec![p[0]];
        let mut cur = p[0];
        for i in 1..p.len().saturating_sub(1) {
            let c = p[i];
            let e = ((p[i].0 + p[i + 1].0) / 2.0, (p[i].1 + p[i + 1].1) / 2.0);
            for k in 1..=8 {
                let t = k as f64 / 8.0;
                let u = 1.0 - t;
                out.push((u * u * cur.0 + 2.0 * u * t * c.0 + t * t * e.0, u * u * cur.1 + 2.0 * u * t * c.1 + t * t * e.1));
            }
            cur = e;
        }
        out.push(p[p.len() - 1]);
        out
    }

    fn seg_dist(p: (f64, f64), a: (f64, f64), b: (f64, f64)) -> f64 {
        let (dx, dy) = (b.0 - a.0, b.1 - a.1);
        let l2 = dx * dx + dy * dy;
        let t = if l2 > 0.0 { (((p.0 - a.0) * dx + (p.1 - a.1) * dy) / l2).clamp(0.0, 1.0) } else { 0.0 };
        (p.0 - a.0 - t * dx).hypot(p.1 - a.1 - t * dy)
    }

    fn write_png(path: &Path, rgba: &[u8], w: u32, h: u32) -> Result<(), String> {
        let f = std::fs::File::create(path).map_err(|e| e.to_string())?;
        let mut e = png::Encoder::new(std::io::BufWriter::new(f), w, h);
        e.set_color(png::ColorType::Rgba);
        e.set_depth(png::BitDepth::Eight);
        let mut wr = e.write_header().map_err(|e| e.to_string())?;
        wr.write_image_data(rgba).map_err(|e| e.to_string())
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn a_stroke_marks_the_picture_and_leaves_the_rest() {
            let (w, h) = (100, 60);
            let mut px = vec![255u8; w * h * 4];
            render(&mut px, w, h, &[vec![[0.1, 0.5], [0.5, 0.5], [0.9, 0.5]]], 4.0);
            let at = |x: usize, y: usize| &px[(y * w + x) * 4..(y * w + x) * 4 + 3];
            assert_eq!(at(50, 30), &[255, 92, 61]);
            assert_eq!(at(50, 5), &[255, 255, 255]);
            // a tap is a ring: its centre is untouched
            let mut px2 = vec![255u8; w * h * 4];
            render(&mut px2, w, h, &[vec![[0.5, 0.5]]], 2.0);
            assert_eq!(&px2[(30 * w + 50) * 4..(30 * w + 50) * 4 + 3], &[255, 255, 255]);
        }

        #[test]
        fn writes_a_png() {
            let d = tempfile::tempdir().unwrap();
            let p = d.path().join("m.png");
            write_png(&p, &[0u8; 4 * 4 * 4], 4, 4).unwrap();
            assert!(tauri::image::Image::from_path(&p).is_ok());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_card_says_the_typed_note_then_the_words() {
        assert_eq!(merged(Some("fix this"), Some("the button")).as_deref(), Some("fix this\nthe button"));
        assert_eq!(merged(Some("the button is faint"), Some("button")).as_deref(), Some("the button is faint"));
        assert_eq!(merged(None, Some(" said ")).as_deref(), Some("said"));
        assert_eq!(merged(Some(" "), None), None);
    }
}
