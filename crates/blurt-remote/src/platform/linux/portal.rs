//! One xdg-desktop-portal session for everything the phone does: RemoteDesktop (keyboard + pointer) with ScreenCast attached
//! (one monitor, the pointer as metadata, not drawn in), so GNOME asks once, in one dialog, and pointer moves and the picture
//! are about the same monitor. `persist_mode` 2 and the restore token kept in the state dir: after the first yes, every
//! later session starts without a dialog (each Start hands out a new single-use token; the latest is kept).
//!
//! Started lazily, by the first input or screen request. It's a separate session from the desktop app's own RemoteDesktop
//! session for paste (dictation/insert_linux.rs): the two don't share state, and GNOME is fine with both.
//!
//! The Notify* calls each wait for a D-Bus reply, so they run on one task in order, fed by a queue: the server's thread never
//! waits on D-Bus, and relative moves that pile up behind a slow reply are summed into one.

use std::os::fd::OwnedFd;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

use ashpd::desktop::remote_desktop::{
    Axis, DeviceType, KeyState, NotifyKeyboardKeycodeOptions, NotifyKeyboardKeysymOptions, NotifyPointerAxisDiscreteOptions,
    NotifyPointerAxisOptions, NotifyPointerButtonOptions, NotifyPointerMotionAbsoluteOptions, NotifyPointerMotionOptions, RemoteDesktop,
    SelectDevicesOptions, StartOptions,
};
use ashpd::desktop::screencast::{CursorMode, Screencast, SelectSourcesOptions, SourceType};
use ashpd::desktop::{CreateSessionOptions, PersistMode, Session};
use tokio::sync::mpsc;

use super::math::{Carry, PX_PER_STEP};

pub fn rt() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("blurt-remote")
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

/// Runs a future on our runtime from any thread (also from inside another runtime, where block_on would panic).
pub fn block<T: Send + 'static>(limit: Duration, f: impl std::future::Future<Output = T> + Send + 'static) -> Option<T> {
    let (tx, rx) = std::sync::mpsc::channel();
    rt().spawn(async move {
        let _ = tx.send(f.await);
    });
    rx.recv_timeout(limit).ok()
}

static STATE_DIR: Mutex<Option<PathBuf>> = Mutex::new(None);
static PARENT: Mutex<Option<u64>> = Mutex::new(None);

/// Where the restore token lives: what the app gives (`set_state_dir`), else $XDG_STATE_HOME/blurt/remote.
pub fn state_dir() -> PathBuf {
    if let Some(d) = STATE_DIR.lock().unwrap().clone() {
        return d;
    }
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/state"));
    base.join("blurt").join("remote")
}

pub fn set_state_dir(dir: PathBuf) {
    *STATE_DIR.lock().unwrap() = Some(dir);
}

/// An X11 window (the app runs under XWayland) GNOME's dialog opens over; without one it can open behind the app in front.
pub fn set_dialog_parent(xid: Option<u64>) {
    *PARENT.lock().unwrap() = xid;
}

fn token_path() -> PathBuf {
    state_dir().join("portal-remote.token")
}

/// What the session shows: the monitor's stream.
#[derive(Clone, Debug)]
pub struct StreamInfo {
    pub node: u32,
    /// logical size (points)
    pub size: (i32, i32),
}

pub enum Cmd {
    Keys(Vec<(i32, bool)>),
    Keysym(i32),
    Motion(f64, f64),
    /// 0…1 of the monitor, turned into the stream's space by the worker (it knows the node)
    Absolute(f64, f64, (f64, f64)),
    Button(i32, bool),
    /// axis values (Wayland's sense); `end`: the gesture is over (a finish follows unless more comes)
    Axis(f64, f64),
    AxisEnd { wait_ms: u64 },
    /// a sync point: answered when everything before it went out
    Flush(std::sync::mpsc::Sender<()>),
}

enum State {
    Idle,
    Opening,
    Open { tx: mpsc::UnboundedSender<Cmd>, stream: Option<StreamInfo>, session: Arc<Session<RemoteDesktop>> },
    Failed(String, Instant),
}

pub struct Portal {
    state: Mutex<State>,
    changed: Condvar,
    controls: AtomicBool,
    inhibit: Mutex<Option<ashpd::desktop::Request<()>>>,
}

/// A refusal is remembered this long, so a phone tapping keys doesn't bring the dialog back at once.
const REFUSED_FOR: Duration = Duration::from_secs(20);

fn words(e: &ashpd::Error) -> String {
    match e {
        ashpd::Error::Response(_) => "Access to this computer was refused in its Remote Desktop dialog.".into(),
        ashpd::Error::Portal(p) => format!("The desktop's portal said no: {p}"),
        e => format!("The desktop's portal failed: {e}"),
    }
}

impl Portal {
    pub fn new() -> Arc<Portal> {
        Arc::new(Portal { state: Mutex::new(State::Idle), changed: Condvar::new(), controls: AtomicBool::new(false), inhibit: Mutex::new(None) })
    }

    pub fn can_control(&self) -> bool {
        self.controls.load(SeqCst)
    }

    /// The session is open (or being opened, or recently refused): starts it otherwise. Never blocks.
    pub fn ensure(self: &Arc<Self>) {
        let mut st = self.state.lock().unwrap();
        match &*st {
            State::Open { .. } | State::Opening => return,
            State::Failed(_, at) if at.elapsed() < REFUSED_FOR => return,
            _ => {}
        }
        *st = State::Opening;
        drop(st);
        let me = self.clone();
        rt().spawn(async move {
            let r = me.open().await;
            let mut st = me.state.lock().unwrap();
            *st = match r {
                Ok((tx, stream, session, controls)) => {
                    me.controls.store(controls, SeqCst);
                    State::Open { tx, stream, session }
                }
                Err(e) => {
                    eprintln!("blurt-remote: portal: {e}");
                    me.controls.store(false, SeqCst);
                    State::Failed(e, Instant::now())
                }
            };
            me.changed.notify_all();
        });
    }

    /// Waits until the session is open (up to `limit`: the first time, the user answers GNOME's dialog). Err: why not.
    pub fn wait(self: &Arc<Self>, limit: Duration) -> Result<Option<StreamInfo>, String> {
        self.ensure();
        let deadline = Instant::now() + limit;
        let mut st = self.state.lock().unwrap();
        loop {
            match &*st {
                State::Open { stream, .. } => return Ok(stream.clone()),
                State::Failed(e, _) => return Err(e.clone()),
                State::Idle => {
                    drop(st);
                    self.ensure();
                    st = self.state.lock().unwrap();
                    continue;
                }
                State::Opening => {}
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err("The computer is still waiting for its Remote Desktop dialog to be answered.".into());
            }
            st = self.changed.wait_timeout(st, left).unwrap().0;
        }
    }

    pub fn stream(&self) -> Option<StreamInfo> {
        match &*self.state.lock().unwrap() {
            State::Open { stream, .. } => stream.clone(),
            _ => None,
        }
    }

    /// Queues one input command. Before the session is open it's dropped (a late key is worse than a lost one) and the
    /// session is started. False: dropped.
    pub fn send(self: &Arc<Self>, c: Cmd) -> bool {
        {
            let st = self.state.lock().unwrap();
            if let State::Open { tx, .. } = &*st {
                if tx.send(c).is_ok() {
                    return true;
                }
            }
        }
        self.ensure();
        false
    }

    pub fn is_open(&self) -> bool {
        matches!(&*self.state.lock().unwrap(), State::Open { .. })
    }

    /// Waits until what was queued has gone out (text before a paste's Ctrl+V, …).
    pub fn flush(self: &Arc<Self>, limit: Duration) {
        let (tx, rx) = std::sync::mpsc::channel();
        if self.send(Cmd::Flush(tx)) {
            let _ = rx.recv_timeout(limit);
        }
    }

    /// The PipeWire remote for the screen (a new fd each time: a capture owns its connection).
    pub fn pipewire_fd(self: &Arc<Self>) -> Result<OwnedFd, String> {
        let session = match &*self.state.lock().unwrap() {
            State::Open { session, .. } => session.clone(),
            _ => return Err("no session".into()),
        };
        block(Duration::from_secs(5), async move {
            let sc = Screencast::new().await.map_err(|e| words(&e))?;
            sc.open_pipe_wire_remote(&session, Default::default()).await.map_err(|e| words(&e))
        })
        .unwrap_or_else(|| Err("The screen stream didn't open in time.".into()))
    }

    /// Ends the session (GNOME's chips go away). The next input or screen request opens a new one, without a dialog.
    pub fn close(&self) {
        let st = std::mem::replace(&mut *self.state.lock().unwrap(), State::Idle);
        self.controls.store(false, SeqCst);
        if let State::Open { session, .. } = st {
            rt().spawn(async move {
                let _ = session.close().await;
            });
        }
    }

    async fn open(self: &Arc<Self>) -> Result<(mpsc::UnboundedSender<Cmd>, Option<StreamInfo>, Arc<Session<RemoteDesktop>>, bool), String> {
        let rd = RemoteDesktop::new().await.map_err(|e| words(&e))?;
        let session = rd.create_session(CreateSessionOptions::default()).await.map_err(|e| words(&e))?;
        let token = std::fs::read_to_string(token_path()).ok().map(|t| t.trim().to_string()).filter(|t| !t.is_empty());
        rd.select_devices(
            &session,
            SelectDevicesOptions::default()
                .set_devices(DeviceType::Keyboard | DeviceType::Pointer)
                .set_persist_mode(PersistMode::ExplicitlyRevoked)
                .set_restore_token(token.as_deref()),
        )
        .await
        .map_err(|e| words(&e))?;
        // the screen: one monitor, the pointer as metadata (its position and look ride along; the phone draws it)
        let sc = Screencast::new().await.map_err(|e| words(&e))?;
        let modes = sc.available_cursor_modes().await.unwrap_or_default();
        let cursor = if modes.contains(CursorMode::Metadata) { CursorMode::Metadata } else { CursorMode::Embedded };
        let with_screen = sc
            .select_sources(
                &session,
                SelectSourcesOptions::default().set_cursor_mode(cursor).set_sources(ashpd::enumflags2::BitFlags::from(SourceType::Monitor)).set_multiple(false),
            )
            .await
            .is_ok();
        let parent = PARENT.lock().unwrap().map(|x| ashpd::WindowIdentifier::from_xid(x as std::os::raw::c_ulong));
        let started = rd
            .start(&session, parent.as_ref(), StartOptions::default())
            .await
            .map_err(|e| words(&e))?
            .response()
            .map_err(|e| words(&e))?;
        if let Some(t) = started.restore_token() {
            let p = token_path();
            if let Some(d) = p.parent() {
                let _ = std::fs::create_dir_all(d);
            }
            let _ = std::fs::write(&p, t);
        }
        let devices = started.devices();
        let controls = devices.contains(DeviceType::Keyboard) && devices.contains(DeviceType::Pointer);
        if devices.is_empty() {
            let _ = session.close().await;
            return Err("Remote control is off in the computer's Remote Desktop dialog: turn on \"Allow Remote Interaction\".".into());
        }
        let stream = with_screen
            .then(|| started.streams().first())
            .flatten()
            .map(|s| StreamInfo { node: s.pipe_wire_node_id(), size: s.size().unwrap_or((0, 0)) });
        if let Some(s) = &stream {
            if s.size.0 > 0 && s.size.1 > 0 {
                let _ = std::fs::write(state_dir().join("display-aspect"), format!("{}", s.size.0 as f64 / s.size.1 as f64));
            }
        }
        let session = Arc::new(session);
        let (tx, rx) = mpsc::unbounded_channel();
        let node = stream.as_ref().map(|s| s.node);
        tokio::spawn(worker(rd, session.clone(), node, rx));
        // the session ends from the desktop too (the user stops it from GNOME's top bar): next time, open another
        let me = Arc::downgrade(self);
        let s2 = session.clone();
        tokio::spawn(async move {
            use futures_util::StreamExt;
            if let Ok(mut closed) = s2.receive_closed().await {
                let _ = closed.next().await;
                if let Some(me) = me.upgrade() {
                    let mut st = me.state.lock().unwrap();
                    if matches!(&*st, State::Open { session, .. } if Arc::ptr_eq(session, &s2)) {
                        *st = State::Idle;
                        me.controls.store(false, SeqCst);
                    }
                }
            }
        });
        Ok((tx, stream, session, controls))
    }

    /// Keep the computer awake (and with `display`, the screen on) while a phone is connected.
    pub fn keep_awake(self: &Arc<Self>, on: bool, display: bool) {
        let old = self.inhibit.lock().unwrap().take();
        let me = self.clone();
        rt().spawn(async move {
            if let Some(r) = old {
                let _ = r.close().await;
            }
            if !on {
                return;
            }
            use ashpd::desktop::inhibit::{InhibitFlags, InhibitOptions, InhibitProxy};
            let Ok(p) = InhibitProxy::new().await else { return };
            let flags = if display { InhibitFlags::Idle | InhibitFlags::Suspend } else { InhibitFlags::Suspend.into() };
            match p.inhibit(None, flags, InhibitOptions::default().set_reason("A phone is connected to Blurt")).await {
                Ok(r) => *me.inhibit.lock().unwrap() = Some(r),
                Err(e) => eprintln!("blurt-remote: inhibit: {e}"),
            }
        });
    }
}

/// The one task that talks to the portal for input, in order.
async fn worker(rd: RemoteDesktop, s: Arc<Session<RemoteDesktop>>, node: Option<u32>, mut rx: mpsc::UnboundedReceiver<Cmd>) {
    let mut next: Option<Cmd> = None;
    let mut finish_at: Option<tokio::time::Instant> = None;
    // NotifyPointerAxis is version 1, but a backend may still refuse it: then wheel clicks
    let mut smooth = true;
    let (mut cx, mut cy) = (Carry::default(), Carry::default());
    let debug = std::env::var_os("BLURT_REMOTE_DEBUG").is_some();
    loop {
        let c = match next.take() {
            Some(c) => c,
            None => {
                let got = match finish_at {
                    Some(t) => match tokio::time::timeout_at(t, rx.recv()).await {
                        Ok(c) => c,
                        Err(_) => {
                            finish_at = None;
                            if smooth {
                                let _ = rd.notify_pointer_axis(&s, 0.0, 0.0, NotifyPointerAxisOptions::default().set_finish(true)).await;
                            }
                            cx.clear();
                            cy.clear();
                            continue;
                        }
                    },
                    None => rx.recv().await,
                };
                match got {
                    Some(c) => c,
                    None => return,
                }
            }
        };
        let r = match c {
            Cmd::Motion(mut dx, mut dy) => {
                // what piled up behind a slow reply goes as one move
                while let Ok(n) = rx.try_recv() {
                    match n {
                        Cmd::Motion(x, y) => {
                            dx += x;
                            dy += y;
                        }
                        other => {
                            next = Some(other);
                            break;
                        }
                    }
                }
                rd.notify_pointer_motion(&s, dx, dy, NotifyPointerMotionOptions::default()).await
            }
            Cmd::Absolute(mut x, mut y, space) => {
                while let Ok(n) = rx.try_recv() {
                    match n {
                        Cmd::Absolute(a, b, _) => {
                            x = a;
                            y = b;
                        }
                        other => {
                            next = Some(other);
                            break;
                        }
                    }
                }
                let Some(node) = node else { continue };
                let (px, py) = super::math::absolute_target(x, y, space);
                rd.notify_pointer_motion_absolute(&s, node, px, py, NotifyPointerMotionAbsoluteOptions::default()).await
            }
            Cmd::Button(code, down) => {
                let st = if down { KeyState::Pressed } else { KeyState::Released };
                rd.notify_pointer_button(&s, code, st, NotifyPointerButtonOptions::default()).await
            }
            Cmd::Keys(seq) => {
                let mut r = Ok(());
                for (code, down) in seq {
                    let st = if down { KeyState::Pressed } else { KeyState::Released };
                    r = rd.notify_keyboard_keycode(&s, code, st, NotifyKeyboardKeycodeOptions::default()).await;
                    if r.is_err() {
                        break;
                    }
                }
                r
            }
            Cmd::Keysym(sym) => {
                let r = rd.notify_keyboard_keysym(&s, sym, KeyState::Pressed, NotifyKeyboardKeysymOptions::default()).await;
                if r.is_ok() {
                    rd.notify_keyboard_keysym(&s, sym, KeyState::Released, NotifyKeyboardKeysymOptions::default()).await
                } else {
                    r
                }
            }
            Cmd::Axis(mut dx, mut dy) => {
                finish_at = None;
                while let Ok(n) = rx.try_recv() {
                    match n {
                        Cmd::Axis(x, y) => {
                            dx += x;
                            dy += y;
                        }
                        other => {
                            next = Some(other);
                            break;
                        }
                    }
                }
                if smooth {
                    let r = rd.notify_pointer_axis(&s, dx, dy, NotifyPointerAxisOptions::default()).await;
                    if let Err(ashpd::Error::Zbus(_)) = &r {
                        smooth = false;
                    } else {
                        if let Err(e) = r {
                            eprintln!("blurt-remote: axis: {e}");
                        }
                        continue;
                    }
                }
                let (sx, sy) = (cx.take(dx, PX_PER_STEP), cy.take(dy, PX_PER_STEP));
                let mut r = Ok(());
                if sy != 0 {
                    r = rd.notify_pointer_axis_discrete(&s, Axis::Vertical, sy, NotifyPointerAxisDiscreteOptions::default()).await;
                }
                if sx != 0 && r.is_ok() {
                    r = rd.notify_pointer_axis_discrete(&s, Axis::Horizontal, sx, NotifyPointerAxisDiscreteOptions::default()).await;
                }
                r
            }
            Cmd::AxisEnd { wait_ms } => {
                // a fling's coast may follow: the finish waits for it, so GTK doesn't start a coast of its own as well
                finish_at = Some(tokio::time::Instant::now() + Duration::from_millis(wait_ms));
                continue;
            }
            Cmd::Flush(tx) => {
                let _ = tx.send(());
                continue;
            }
        };
        if let Err(e) = r {
            if debug {
                eprintln!("blurt-remote: notify: {e}");
            }
        }
    }
}
