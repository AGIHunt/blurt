//! Putting the text in on Linux (GNOME Wayland; docs/design/linux-port.md §Putting the text in, §Which app): the same
//! functions engine.rs calls on insert_win.rs, made of what Wayland lets an app do.
//!
//! * The clipboard: XWayland's. The app runs under XWayland (lib.rs), where an X client sets the clipboard without
//!   focus and GNOME hands it to Wayland apps — a native Wayland window that isn't focused can't, and mutter has no
//!   data-control protocol.
//! * The keys: the RemoteDesktop portal's keyboard sends Ctrl+V — Ctrl+Shift+V into a terminal. The first session
//!   shows GNOME's dialog ("Allow Remote Interaction" must be on), asked from Blurt's window (`request_access`): GNOME
//!   opens it unparented behind the app in front otherwise. Its restore token, kept in
//!   `~/.blurt/portal/remote-desktop.token`, skips the dialog after that. A session is opened when a take starts
//!   (`prepare`, 8 ms with the token) and closed a few seconds after the paste: GNOME's orange chip shows while Blurt
//!   listens, never at rest.
//! * Which app, which field: AT-SPI. A listener follows `object:state-changed:focused` from launch; the focused object
//!   gives the app's pid, its role (`terminal`, `password text`), and through its Text interface the field's text and
//!   caret. Blurt turns `org.a11y.Status.IsEnabled` on (as Orca does) so Firefox / Chromium / Electron apps started
//!   afterwards join. An app without accessibility leaves the last focus standing; `front()` then can't tell.
//! * Offsets: AT-SPI counts characters, engine.rs (context.rs, landing) counts UTF-16 units as UI Automation does:
//!   converted here both ways.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use ashpd::desktop::remote_desktop::{DeviceType, KeyState, NotifyKeyboardKeycodeOptions, RemoteDesktop, SelectDevicesOptions, StartOptions};
use ashpd::desktop::{CreateSessionOptions, PersistMode, Session};
use futures_util::StreamExt;
use zbus::zvariant::{OwnedObjectPath, OwnedValue};

// evdev key codes (linux/input-event-codes.h)
const KEY_LEFTCTRL: i32 = 29;
const KEY_LEFTSHIFT: i32 = 42;
const KEY_V: i32 = 47;
const KEY_ENTER: i32 = 28;
const KEY_F24: i32 = 194;

// AT-SPI roles and states (atspi-constants.h)
const ROLE_FRAME: u32 = 23;
const ROLE_DIALOG: u32 = 16;
const ROLE_WINDOW: u32 = 69;
const ROLE_PASSWORD_TEXT: u32 = 40;
const ROLE_TERMINAL: u32 = 60;
const STATE_EDITABLE: u32 = 7;

/// The longest field read whole (as insert_win's FIELD_MAX).
const FIELD_MAX: i32 = 20_000;
/// How long a session stays open after its last use.
const IDLE_CLOSE: Duration = Duration::from_millis(2500);
/// A take that never pasted (cancelled, no speech) lets its session go after this.
const HOLD_MAX: Duration = Duration::from_secs(330);

// ------------------------------------------------------------------ the runtime the portals and AT-SPI run on

/// One small runtime of our own: the engine's threads call in synchronously (`block`), from anywhere — also from a
/// thread of Tauri's runtime, where its own `block_on` would panic.
pub(crate) fn rt() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("blurt-desk")
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

pub(crate) fn block<T: Send + 'static>(limit: Duration, f: impl std::future::Future<Output = T> + Send + 'static) -> Option<T> {
    let (tx, rx) = std::sync::mpsc::channel();
    rt().spawn(async move {
        let _ = tx.send(f.await);
    });
    rx.recv_timeout(limit).ok()
}

// ------------------------------------------------------------------ the RemoteDesktop session

struct Desk {
    rd: RemoteDesktop,
    session: Session<RemoteDesktop>,
}

struct DeskState {
    desk: Option<Arc<Desk>>,
    last_use: Option<Instant>,
    hold_until: Option<Instant>,
}

static DESK: tokio::sync::Mutex<DeskState> = tokio::sync::Mutex::const_new(DeskState { desk: None, last_use: None, hold_until: None });

/// Why the last session couldn't start: "denied" (the dialog was cancelled), "no_keyboard" (interaction left off), …
pub static LAST_ERROR: Mutex<Option<String>> = Mutex::new(None);
static CLOSER: AtomicBool = AtomicBool::new(false);

fn token_path() -> std::path::PathBuf {
    crate::paths::blurt_home().join("portal").join("remote-desktop.token")
}

async fn register() {
    crate::hotkeys::portal::register_host_app().await;
}

fn trace(step: &str) {
    if std::env::var_os("BLURT_DEBUG_KEYS").is_some() {
        eprintln!("dictation: remote desktop: {step}");
    }
}

async fn open(parent: Option<u64>) -> Result<Arc<Desk>, String> {
    trace("register");
    register().await;
    trace("create session");
    let rd = RemoteDesktop::new().await.map_err(|e| e.to_string())?;
    let session = rd.create_session(CreateSessionOptions::default()).await.map_err(|e| e.to_string())?;
    let token = std::fs::read_to_string(token_path()).ok().map(|t| t.trim().to_string()).filter(|t| !t.is_empty());
    let opts = SelectDevicesOptions::default()
        .set_devices(ashpd::enumflags2::BitFlags::from(DeviceType::Keyboard))
        .set_persist_mode(PersistMode::ExplicitlyRevoked)
        .set_restore_token(token.as_deref());
    rd.select_devices(&session, opts).await.map_err(|e| e.to_string())?;
    trace("start (the dialog, the first time)");
    let parent = parent.map(|x| ashpd::WindowIdentifier::from_xid(x as std::os::raw::c_ulong));
    let started = rd
        .start(&session, parent.as_ref(), StartOptions::default())
        .await
        .map_err(|e| e.to_string())?
        .response()
        .map_err(|e| match e {
            ashpd::Error::Response(_) => "denied".to_string(),
            e => e.to_string(),
        })?;
    trace(&format!("started: {:?}", started.devices()));
    if let Some(t) = started.restore_token() {
        let p = token_path();
        if let Some(d) = p.parent() {
            let _ = std::fs::create_dir_all(d);
        }
        let _ = std::fs::write(&p, t);
    }
    if !started.devices().contains(DeviceType::Keyboard) {
        let _ = session.close().await;
        return Err("no_keyboard".into());
    }
    Ok(Arc::new(Desk { rd, session }))
}

/// Remote Desktop access was given once (its restore token is kept): sessions start without a dialog.
pub fn has_access() -> bool {
    token_path().is_file()
}

/// The open session. Without access only `request_access` may start one: GNOME opens the dialog unparented, behind
/// the app in front, where a take would wait on it unseen.
async fn desk(hold: bool) -> Result<Arc<Desk>, String> {
    desk_with(hold, false, None).await
}

async fn desk_with(hold: bool, dialog: bool, parent: Option<u64>) -> Result<Arc<Desk>, String> {
    if !dialog && !has_access() {
        return Err("no_access".into());
    }
    let mut st = DESK.lock().await;
    st.last_use = Some(Instant::now());
    if hold {
        st.hold_until = Some(Instant::now() + HOLD_MAX);
    }
    if let Some(d) = &st.desk {
        return Ok(d.clone());
    }
    match open(parent).await {
        Ok(d) => {
            *LAST_ERROR.lock().unwrap() = None;
            st.desk = Some(d.clone());
            st.last_use = Some(Instant::now());
            if !CLOSER.swap(true, SeqCst) {
                tokio::spawn(closer());
            }
            Ok(d)
        }
        Err(e) => {
            eprintln!("blurt: remote desktop session: {e}");
            *LAST_ERROR.lock().unwrap() = Some(e.clone());
            Err(e)
        }
    }
}

/// Closes a session once it's idle (and no take holds it).
async fn closer() {
    loop {
        tokio::time::sleep(Duration::from_millis(500)).await;
        let mut st = DESK.lock().await;
        let held = st.hold_until.is_some_and(|t| Instant::now() < t);
        if st.desk.is_some() && !held && st.last_use.is_none_or(|t| t.elapsed() > IDLE_CLOSE) {
            if let Some(d) = st.desk.take() {
                let _ = d.session.close().await;
            }
        }
    }
}

async fn release_hold() {
    let mut st = DESK.lock().await;
    st.hold_until = None;
    st.last_use = Some(Instant::now());
}

/// A take started: open the session now so the paste doesn't wait (and the dialog, the first time, comes while the
/// user is still talking). Never blocks.
pub fn prepare() {
    if !has_access() {
        return;
    }
    rt().spawn(async {
        if let Ok(d) = desk(true).await {
            // right Alt still held (the take started on a hold): mask it now that keys can be sent
            if super::keys_linux::held(0xA5) {
                keys(&d, &[(KEY_F24, true), (KEY_F24, false)]).await;
            }
        }
    });
}

/// Asks for Remote Desktop access once, over Blurt's window `parent` (its X11 id): Ok when keys can be sent. Blocks
/// up to 2 minutes (the user answers GNOME's dialog).
pub fn request_access(parent: Option<u64>) -> Result<(), String> {
    block(Duration::from_secs(120), async move {
        let r = desk_with(false, true, parent).await.map(|_| ());
        release_hold().await;
        r
    })
    .unwrap_or_else(|| Err("timeout".into()))
}

async fn keys(d: &Desk, seq: &[(i32, bool)]) -> bool {
    for &(code, down) in seq {
        let st = if down { KeyState::Pressed } else { KeyState::Released };
        if d.rd.notify_keyboard_keycode(&d.session, code, st, NotifyKeyboardKeycodeOptions::default()).await.is_err() {
            return false;
        }
    }
    true
}

// ------------------------------------------------------------------ the clipboard

/// What the clipboard held, to put back (its text; other kinds of content aren't read).
pub struct Saved {
    text: Option<String>,
}

fn clipboard<T>(f: impl FnOnce(&mut arboard::Clipboard) -> Option<T>) -> Option<T> {
    // one clipboard object for the app's life: on X11 it serves what it holds for as long as it lives
    static CB: Mutex<Option<arboard::Clipboard>> = Mutex::new(None);
    let mut g = CB.lock().unwrap();
    if g.is_none() {
        *g = arboard::Clipboard::new().map_err(|e| eprintln!("blurt: clipboard: {e}")).ok();
    }
    g.as_mut().and_then(f)
}

pub fn save() -> Saved {
    Saved { text: clipboard(|c| c.get_text().ok()) }
}

pub fn set_text(text: &str) -> bool {
    clipboard(|c| c.set_text(text.to_string()).ok()).is_some()
}

/// Puts the saved text back. Nothing was saved (empty, or an image): our text stays — an empty clipboard helps nobody.
pub fn restore(s: &Saved) {
    if let Some(t) = &s.text {
        set_text(t);
    }
}

/// insert_win's GetClipboardSequenceNumber: what the clipboard holds now, hashed — the user copying something else
/// after our paste changes it.
pub fn sequence() -> u32 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    clipboard(|c| c.get_text().ok()).hash(&mut h);
    h.finish() as u32
}

// ------------------------------------------------------------------ the keys

/// Ctrl+V into the focused app; Ctrl+Shift+V when it is a terminal (VTE's role, or a terminal by name).
pub fn paste_keys() -> bool {
    let terminal = focused().is_some_and(|f| f.role == ROLE_TERMINAL || super::apps::is_terminal(Some(&exe_of(f.pid))));
    let seq: Vec<(i32, bool)> = if terminal {
        vec![(KEY_LEFTCTRL, true), (KEY_LEFTSHIFT, true), (KEY_V, true), (KEY_V, false), (KEY_LEFTSHIFT, false), (KEY_LEFTCTRL, false)]
    } else {
        vec![(KEY_LEFTCTRL, true), (KEY_V, true), (KEY_V, false), (KEY_LEFTCTRL, false)]
    };
    let ok = block(Duration::from_secs(120), async move {
        let Ok(d) = desk(false).await else { return false };
        let ok = keys(&d, &seq).await;
        release_hold().await;
        ok
    })
    .unwrap_or(false);
    ok
}

pub fn press_return() -> bool {
    block(Duration::from_secs(5), async {
        let Ok(d) = desk(false).await else { return false };
        keys(&d, &[(KEY_ENTER, true), (KEY_ENTER, false)]).await
    })
    .unwrap_or(false)
}

/// Right Alt pressed alone opens the menu bar of some apps (Firefox): a harmless F24 while it is still down makes it
/// "Alt + something" (keys_linux.rs, evdev mode). Only when a session is open already — never opens one for this.
pub fn mask_alt() {
    rt().spawn(async {
        let d = DESK.lock().await.desk.clone();
        if let Some(d) = d {
            keys(&d, &[(KEY_F24, true), (KEY_F24, false)]).await;
        }
    });
}

// ------------------------------------------------------------------ which app, which field (AT-SPI)

/// The window in front and its process. `hwnd` is unused here (0); `exe` is the executable's file name.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Front {
    pub pid: u32,
    pub hwnd: isize,
    pub exe: String,
}

#[derive(Clone, Debug)]
struct Focus {
    bus: String,
    path: OwnedObjectPath,
    pid: u32,
    role: u32,
    states: u64,
    text: bool,
}

static FOCUS: Mutex<Option<Focus>> = Mutex::new(None);
static A11Y: OnceLock<zbus::Connection> = OnceLock::new();

/// Start following the focus (once, at launch; keys_linux::start).
pub fn watch() {
    static STARTED: AtomicBool = AtomicBool::new(false);
    if STARTED.swap(true, SeqCst) {
        return;
    }
    rt().spawn(async {
        if let Err(e) = follow_focus().await {
            eprintln!("blurt: at-spi: {e}");
        }
    });
}

async fn follow_focus() -> zbus::Result<()> {
    let session = zbus::Connection::session().await?;
    // apps started from now on expose themselves (Firefox, Chromium and Electron check this at launch)
    let _ = session
        .call_method(
            Some("org.a11y.Bus"),
            "/org/a11y/bus",
            Some("org.freedesktop.DBus.Properties"),
            "Set",
            &("org.a11y.Status", "IsEnabled", zbus::zvariant::Value::from(true)),
        )
        .await;
    let addr: String = session
        .call_method(Some("org.a11y.Bus"), "/org/a11y/bus", Some("org.a11y.Bus"), "GetAddress", &())
        .await?
        .body()
        .deserialize()?;
    let conn = zbus::connection::Builder::address(addr.as_str())?.build().await?;
    let _ = A11Y.set(conn.clone());
    // apps only send events someone registered for
    let _ = conn
        .call_method(
            Some("org.a11y.atspi.Registry"),
            "/org/a11y/atspi/registry",
            Some("org.a11y.atspi.Registry"),
            "RegisterEvent",
            &("object:state-changed:focused", Vec::<String>::new(), ""),
        )
        .await;
    let rule = zbus::MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .interface("org.a11y.atspi.Event.Object")?
        .member("StateChanged")?
        .build();
    let mut stream = zbus::MessageStream::for_match_rule(rule, &conn, Some(64)).await?;
    while let Some(Ok(msg)) = stream.next().await {
        let h = msg.header();
        let (Some(sender), Some(path)) = (h.sender().map(|s| s.to_string()), h.path().map(|p| OwnedObjectPath::from(p.clone()))) else {
            continue;
        };
        let body = msg.body();
        let Ok((kind, detail1)) = body.deserialize::<(String, i32, i32, OwnedValue, HashMap<String, OwnedValue>)>().map(|b| (b.0, b.1)).or_else(|_| {
            body.deserialize::<(String, i32, i32, OwnedValue, (String, OwnedObjectPath))>().map(|b| (b.0, b.1))
        }) else {
            continue;
        };
        if kind != "focused" || detail1 != 1 {
            continue;
        }
        if let Some(f) = describe(&conn, &sender, path).await {
            // gnome-shell's own focus (the panel, Alt+Tab's switcher) passes through on the way: not an app
            if exe_of(f.pid) != "gnome-shell" {
                *FOCUS.lock().unwrap() = Some(f);
            }
        }
    }
    Ok(())
}

async fn call<B: serde::Serialize + zbus::zvariant::DynamicType, R: for<'d> serde::Deserialize<'d> + zbus::zvariant::Type>(
    conn: &zbus::Connection,
    bus: &str,
    path: &OwnedObjectPath,
    iface: &str,
    method: &str,
    body: &B,
) -> Option<R> {
    let m = tokio::time::timeout(Duration::from_millis(500), conn.call_method(Some(bus), path.as_str(), Some(iface), method, body))
        .await
        .ok()?
        .ok()?;
    m.body().deserialize::<R>().ok()
}

async fn prop_i32(conn: &zbus::Connection, bus: &str, path: &OwnedObjectPath, iface: &str, name: &str) -> Option<i32> {
    let v: OwnedValue = call(conn, bus, path, "org.freedesktop.DBus.Properties", "Get", &(iface, name)).await?;
    i32::try_from(v).ok()
}

async fn describe(conn: &zbus::Connection, bus: &str, path: OwnedObjectPath) -> Option<Focus> {
    let role: u32 = call(conn, bus, &path, "org.a11y.atspi.Accessible", "GetRole", &()).await?;
    let st: Vec<u32> = call(conn, bus, &path, "org.a11y.atspi.Accessible", "GetState", &()).await.unwrap_or_default();
    let states = st.first().copied().unwrap_or(0) as u64 | (st.get(1).copied().unwrap_or(0) as u64) << 32;
    let ifs: Vec<String> = call(conn, bus, &path, "org.a11y.atspi.Accessible", "GetInterfaces", &()).await.unwrap_or_default();
    let dbus = OwnedObjectPath::try_from("/org/freedesktop/DBus").ok()?;
    let pid: u32 = call(conn, "org.freedesktop.DBus", &dbus, "org.freedesktop.DBus", "GetConnectionUnixProcessID", &(bus,)).await.unwrap_or(0);
    Some(Focus { bus: bus.to_string(), path, pid, role, states, text: ifs.iter().any(|i| i == "org.a11y.atspi.Text") })
}

fn focused() -> Option<Focus> {
    FOCUS.lock().unwrap().clone()
}

/// The executable's file name of a process (`/proc/<pid>/exe`, else its `comm`).
fn exe_of(pid: u32) -> String {
    std::fs::read_link(format!("/proc/{pid}/exe"))
        .ok()
        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
        .or_else(|| std::fs::read_to_string(format!("/proc/{pid}/comm")).ok().map(|s| s.trim().to_string()))
        .unwrap_or_default()
}

pub fn front() -> Option<Front> {
    let f = focused()?;
    (f.pid != 0).then(|| Front { pid: f.pid, hwnd: 0, exe: exe_of(f.pid) })
}

/// The app's name as the desktop shows it: its .desktop file's `Name` (in the user's language), found through the
/// `GIO_LAUNCHED_DESKTOP_FILE` GNOME puts in the environment of what it launches. Cached per executable.
pub fn app_name(f: &Front) -> Option<String> {
    static NAMES: Mutex<Option<HashMap<String, Option<String>>>> = Mutex::new(None);
    if let Some(n) = NAMES.lock().unwrap().as_ref().and_then(|m| m.get(&f.exe)) {
        return n.clone();
    }
    let name = desktop_file(f.pid).and_then(|p| desktop_name(&p));
    NAMES.lock().unwrap().get_or_insert_with(HashMap::new).insert(f.exe.clone(), name.clone());
    name
}

fn desktop_file(pid: u32) -> Option<String> {
    let env = std::fs::read(format!("/proc/{pid}/environ")).ok()?;
    env.split(|b| *b == 0)
        .find_map(|kv| kv.strip_prefix(b"GIO_LAUNCHED_DESKTOP_FILE="))
        .map(|v| String::from_utf8_lossy(v).into_owned())
}

fn desktop_name(path: &str) -> Option<String> {
    let s = std::fs::read_to_string(path).ok()?;
    let lang = std::env::var("LANG").unwrap_or_default();
    let lang = lang.split('.').next().unwrap_or("");
    let short = lang.split('_').next().unwrap_or("");
    let mut names: HashMap<String, String> = HashMap::new();
    for l in s.lines() {
        if l.starts_with('[') && l != "[Desktop Entry]" {
            break; // actions follow
        }
        if let Some((k, v)) = l.split_once('=') {
            if k == "Name" || k.starts_with("Name[") {
                names.insert(k.to_string(), v.to_string());
            }
        }
    }
    names
        .get(&format!("Name[{lang}]"))
        .or_else(|| names.get(&format!("Name[{short}]")))
        .or_else(|| names.get("Name"))
        .cloned()
}

pub fn exe_full_path(f: &Front) -> Option<String> {
    std::fs::read_link(format!("/proc/{}/exe", f.pid)).ok().map(|p| p.to_string_lossy().into_owned())
}

/// No UIPI on Linux: every app takes the portal's keys — once Remote Desktop access is given. Before, nothing can be
/// typed: the take is copied (engine.rs says so, with "Allow typing").
pub fn blocks_input(_pid: u32) -> bool {
    !has_access()
}

/// (is a password field, is a text field)
pub fn focus() -> Option<(bool, bool)> {
    let f = focus_read(false)?;
    Some((f.password, f.editable == Some(true)))
}

/// A text field's contents: text and selection in UTF-16 units (as insert_win's).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Field {
    pub text: String,
    pub sel_start: usize,
    pub sel_len: usize,
    pub cursor_known: bool,
}

#[derive(Clone, Debug, Default)]
pub struct FocusRead {
    pub pid: u32,
    pub password: bool,
    pub editable: Option<bool>,
    pub field: Option<Field>,
}

/// UTF-16 units in the first `chars` characters of `s`.
fn u16_of(s: &str, chars: usize) -> usize {
    s.chars().take(chars).map(char::len_utf16).sum()
}

/// Characters in the first `units` UTF-16 units of `s`.
fn chars_of(s: &str, units: usize) -> usize {
    let mut n = 0;
    let mut u = 0;
    for c in s.chars() {
        if u >= units {
            break;
        }
        u += c.len_utf16();
        n += 1;
    }
    n
}

pub fn focus_read(read_text: bool) -> Option<FocusRead> {
    let f = focused()?;
    let password = f.role == ROLE_PASSWORD_TEXT;
    let editable = f.states & (1 << STATE_EDITABLE) != 0;
    let mut out = FocusRead {
        pid: f.pid,
        password,
        // a terminal isn't "editable" to AT-SPI but takes typing: a text field to the take
        editable: Some(editable || f.role == ROLE_TERMINAL),
        field: None,
    };
    if read_text && !password && f.text {
        out.field = block(Duration::from_millis(700), read_field(f)).flatten();
    }
    Some(out)
}

async fn read_field(f: Focus) -> Option<Field> {
    let conn = A11Y.get()?.clone();
    let t = "org.a11y.atspi.Text";
    let count = prop_i32(&conn, &f.bus, &f.path, t, "CharacterCount").await?;
    if count > FIELD_MAX {
        return None;
    }
    let caret = prop_i32(&conn, &f.bus, &f.path, t, "CaretOffset").await.unwrap_or(-1);
    let text: String = call(&conn, &f.bus, &f.path, t, "GetText", &(0i32, count)).await?;
    let n_sel: i32 = call(&conn, &f.bus, &f.path, t, "GetNSelections", &()).await.unwrap_or(0);
    let (s, e) = if n_sel > 0 {
        call::<_, (i32, i32)>(&conn, &f.bus, &f.path, t, "GetSelection", &(0i32,)).await.unwrap_or((caret, caret))
    } else {
        (caret, caret)
    };
    if s < 0 {
        return Some(Field { sel_start: u16_of(&text, usize::MAX), text, sel_len: 0, cursor_known: false });
    }
    let (a, b) = (s.min(e).max(0) as usize, s.max(e).max(0) as usize);
    let start = u16_of(&text, a);
    let len = u16_of(&text, b) - start;
    Some(Field { text, sel_start: start, sel_len: len, cursor_known: true })
}

/// Selects `len` UTF-16 units at `start` in the focused field, if they read `expect`.
pub fn select_range(start: usize, len: usize, expect: &str) -> bool {
    let Some(f) = focused().filter(|f| f.text) else { return false };
    let expect = expect.to_string();
    block(Duration::from_millis(900), async move {
        let conn = A11Y.get()?.clone();
        let fd = read_field(f.clone()).await?;
        let a = chars_of(&fd.text, start);
        let b = chars_of(&fd.text, start + len);
        let have: String = fd.text.chars().skip(a).take(b - a).collect();
        if have != expect {
            return Some(false);
        }
        let ok: bool = call(&conn, &f.bus, &f.path, "org.a11y.atspi.Text", "SetSelection", &(0i32, a as i32, b as i32))
            .await
            .unwrap_or(false);
        let ok = ok || call(&conn, &f.bus, &f.path, "org.a11y.atspi.Text", "AddSelection", &(a as i32, b as i32)).await.unwrap_or(false);
        Some(ok)
    })
    .flatten()
    .unwrap_or(false)
}

pub fn field_text() -> Option<String> {
    focus_read(true)?.field.map(|f| f.text)
}

/// The title of the window holding the focus: the nearest frame / dialog above the focused object.
pub fn window_title(_hwnd: isize) -> String {
    let Some(f) = focused() else { return String::new() };
    block(Duration::from_millis(700), async move {
        let conn = A11Y.get()?.clone();
        let (mut bus, mut path) = (f.bus.clone(), f.path.clone());
        for _ in 0..40 {
            let role: u32 = call(&conn, &bus, &path, "org.a11y.atspi.Accessible", "GetRole", &()).await?;
            if matches!(role, ROLE_FRAME | ROLE_DIALOG | ROLE_WINDOW) {
                let v: OwnedValue = call(&conn, &bus, &path, "org.freedesktop.DBus.Properties", "Get", &("org.a11y.atspi.Accessible", "Name")).await?;
                return String::try_from(v).ok();
            }
            let v: OwnedValue = call(&conn, &bus, &path, "org.freedesktop.DBus.Properties", "Get", &("org.a11y.atspi.Accessible", "Parent")).await?;
            let (b, p): (String, OwnedObjectPath) = v.try_into().ok()?;
            if p.as_str() == "/org/a11y/atspi/null" {
                return None;
            }
            (bus, path) = (b, p);
        }
        None
    })
    .flatten()
    .unwrap_or_default()
}

/// The running programs' names (the other dictation apps' notice).
pub fn running_exes() -> Vec<String> {
    let mut out = vec![];
    if let Ok(rd) = std::fs::read_dir("/proc") {
        for e in rd.flatten() {
            if e.file_name().to_string_lossy().bytes().all(|b| b.is_ascii_digit()) {
                if let Ok(c) = std::fs::read_to_string(e.path().join("comm")) {
                    out.push(c.trim().to_string());
                }
            }
        }
    }
    out.sort();
    out.dedup();
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offsets_between_chars_and_utf16() {
        let s = "a你😀b";
        assert_eq!(u16_of(s, 0), 0);
        assert_eq!(u16_of(s, 2), 2);
        assert_eq!(u16_of(s, 3), 4); // the emoji is two units
        assert_eq!(u16_of(s, 99), 5);
        assert_eq!(chars_of(s, 4), 3);
        assert_eq!(chars_of(s, 5), 4);
    }

    #[test]
    fn desktop_names_follow_the_language() {
        let d = std::env::temp_dir().join(format!("blurt-desk-{}.desktop", std::process::id()));
        std::fs::write(&d, "[Desktop Entry]\nName=Text Editor\nName[zh_CN]=文本编辑器\n[Desktop Action new]\nName=New\n").unwrap();
        std::env::set_var("LANG", "zh_CN.UTF-8");
        assert_eq!(desktop_name(d.to_str().unwrap()).as_deref(), Some("文本编辑器"));
        std::env::set_var("LANG", "en_US.UTF-8");
        assert_eq!(desktop_name(d.to_str().unwrap()).as_deref(), Some("Text Editor"));
        let _ = std::fs::remove_file(d);
    }
}
