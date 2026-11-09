//! host.rs Input on the RemoteDesktop portal: keys by evdev code (keys.rs keeps what's held), text as keysyms or pasted,
//! the pointer in logical pixels, smooth scrolling with a finish at the end of each gesture, the pointer's place and look from
//! the screen stream's cursor metadata.

use std::collections::BTreeSet;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::capture::Shared;
use super::keys::{self, Keyboard, TextStep};
use super::math;
use super::portal::{Cmd, Portal};
use crate::host::{Button, CursorShape, Input, ScrollPhase, SystemMove};

/// Text the app puts in its own way (the desktop app's dictation insert: clipboard kept, Ctrl+Shift+V into terminals).
/// True: done.
pub type Paste = Arc<dyn Fn(&str) -> bool + Send + Sync>;

pub(crate) static PASTE: Mutex<Option<Paste>> = Mutex::new(None);

pub struct LinuxInput {
    portal: Arc<Portal>,
    shared: Arc<Shared>,
    kb: Keyboard,
    buttons: BTreeSet<i32>,
    scrolling: bool,
    natural: Option<bool>,
    ime: (Instant, bool),
}

fn gsettings(schema: &str, key: &str) -> Option<String> {
    let out = std::process::Command::new("gsettings").args(["get", schema, key]).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
}

impl LinuxInput {
    pub fn new(portal: Arc<Portal>, shared: Arc<Shared>) -> Self {
        LinuxInput { portal, shared, kb: Keyboard::default(), buttons: BTreeSet::new(), scrolling: false, natural: None, ime: (Instant::now() - Duration::from_secs(60), false) }
    }

    /// Key events out, if the session is open. Not open: nothing changes here either (the phone will send again; what isn't
    /// pressed needn't be released).
    fn keys(&mut self, f: impl FnOnce(&mut Keyboard) -> Vec<keys::KeyEvent>) {
        if !self.portal.is_open() {
            self.portal.ensure();
            return;
        }
        let ev = f(&mut self.kb);
        if !ev.is_empty() {
            self.portal.send(Cmd::Keys(ev));
        }
    }

    /// An input method (IBus Pinyin…) is what GNOME types with now: keys would go into its composition. Read at most once a second.
    fn input_method(&mut self) -> bool {
        if self.ime.0.elapsed() > Duration::from_secs(1) {
            let mru = gsettings("org.gnome.desktop.input-sources", "mru-sources").unwrap_or_default();
            let src = gsettings("org.gnome.desktop.input-sources", "sources").unwrap_or_default();
            self.ime = (Instant::now(), keys::input_method_active(&mru, &src));
        }
        self.ime.1
    }

    fn natural(&mut self) -> bool {
        *self.natural.get_or_insert_with(|| gsettings("org.gnome.desktop.peripherals.touchpad", "natural-scroll").is_none_or(|v| v != "false"))
    }

    fn paste(&mut self, text: &str) {
        let hook = PASTE.lock().unwrap().clone();
        // what was typed before goes first
        self.portal.flush(Duration::from_secs(1));
        if let Some(h) = hook {
            if h(text) {
                return;
            }
        }
        paste_with_clipboard(&self.portal, text);
    }

    /// Where the stream is in absolute moves: GNOME reads them in frame pixels, KDE in logical ones.
    fn absolute_space(&self) -> (f64, f64) {
        let logical = self.portal.stream().map(|s| (s.size.0 as f64, s.size.1 as f64)).unwrap_or((0.0, 0.0));
        let gnome = std::env::var("XDG_CURRENT_DESKTOP").map(|d| d.to_uppercase().contains("GNOME")).unwrap_or(true);
        let m = self.shared.mirror.lock().unwrap();
        if gnome && m.width > 0 {
            (m.width as f64, m.height as f64)
        } else {
            logical
        }
    }
}

/// The clipboard way, when the app gave nothing better: XWayland's clipboard (what the desktop app uses; mutter has no
/// data-control protocol), Ctrl+V, and the old text back once the app has had time to take it.
fn paste_with_clipboard(portal: &Arc<Portal>, text: &str) {
    static CB: Mutex<Option<arboard::Clipboard>> = Mutex::new(None);
    let mut g = CB.lock().unwrap();
    if g.is_none() {
        *g = arboard::Clipboard::new().map_err(|e| eprintln!("blurt-remote: clipboard: {e}")).ok();
    }
    let Some(cb) = g.as_mut() else { return };
    let old = cb.get_text().ok();
    if cb.set_text(text.to_string()).is_err() {
        return;
    }
    drop(g);
    let seq = vec![(keys::KEY_LEFTCTRL, true), (keys::KEY_V, true), (keys::KEY_V, false), (keys::KEY_LEFTCTRL, false)];
    portal.send(Cmd::Keys(seq));
    portal.flush(Duration::from_secs(1));
    let text = text.to_string();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(800));
        let mut g = CB.lock().unwrap();
        if let (Some(cb), Some(old)) = (g.as_mut(), old) {
            // only if it still holds ours: the user may have copied something since
            if cb.get_text().ok().as_deref() == Some(text.as_str()) {
                let _ = cb.set_text(old);
            }
        }
    });
}

impl Input for LinuxInput {
    fn can_control(&self) -> bool {
        self.portal.can_control()
    }

    fn key(&mut self, name: &str, mods: u8, down: Option<bool>) {
        match down {
            None => self.keys(|k| k.press(name, mods)),
            Some(d) => self.keys(|k| k.hold(name, mods, d)),
        }
    }

    fn set_held(&mut self, mods: u8) {
        self.keys(|k| k.set_sticky(mods));
    }

    fn text(&mut self, text: &str) {
        if !self.portal.is_open() {
            self.portal.ensure();
            return;
        }
        let ime = self.input_method();
        for step in keys::plan_text(text, ime) {
            match step {
                TextStep::Keysym(s) => {
                    self.portal.send(Cmd::Keysym(s));
                }
                TextStep::Key(c) => {
                    self.portal.send(Cmd::Keys(vec![(c, true), (c, false)]));
                }
                TextStep::Paste(t) => self.paste(&t),
            }
        }
    }

    fn button(&mut self, button: Button, down: bool, _clicks: u32) {
        // double and triple clicks are the compositor's to count, from the timing, as with a real mouse
        let code = keys::button_code(button);
        if down {
            if !self.portal.send(Cmd::Button(code, true)) {
                return;
            }
            self.buttons.insert(code);
        } else if self.buttons.remove(&code) {
            self.portal.send(Cmd::Button(code, false));
        }
    }

    fn move_by(&mut self, dx: f64, dy: f64) {
        if dx.is_finite() && dy.is_finite() && (dx != 0.0 || dy != 0.0) {
            // the portal takes fractions, and mutter keeps them: a slow finger isn't rounded away
            self.portal.send(Cmd::Motion(dx, dy));
        }
    }

    fn move_to(&mut self, x: f64, y: f64) {
        let space = self.absolute_space();
        if let (true, Some(s)) = (space.0 > 0.0, self.portal.stream()) {
            self.portal.send(Cmd::Absolute(x, y, space, s.node));
        }
    }

    fn scroll(&mut self, dx: f64, dy: f64, phase: ScrollPhase) {
        let natural = self.natural();
        let (ax, ay) = math::scroll_axis(dx, dy, natural);
        match phase {
            ScrollPhase::Began | ScrollPhase::Changed => {
                self.scrolling = true;
                if ax != 0.0 || ay != 0.0 {
                    self.portal.send(Cmd::Axis(ax, ay));
                }
            }
            ScrollPhase::Momentum => {
                self.scrolling = true;
                if ax != 0.0 || ay != 0.0 {
                    self.portal.send(Cmd::Axis(ax, ay));
                }
                self.portal.send(Cmd::AxisEnd { wait_ms: 90 });
            }
            ScrollPhase::Ended => {
                if ax != 0.0 || ay != 0.0 {
                    self.portal.send(Cmd::Axis(ax, ay));
                }
                self.scrolling = false;
                self.portal.send(Cmd::AxisEnd { wait_ms: 60 });
            }
        }
    }

    fn system(&mut self, m: SystemMove) {
        let (mods, key) = keys::system_chord(m);
        self.keys(|k| k.press(key, mods));
    }

    fn release_all(&mut self) {
        if self.scrolling {
            self.scrolling = false;
            self.portal.send(Cmd::AxisEnd { wait_ms: 0 });
        }
        for b in std::mem::take(&mut self.buttons).into_iter().rev() {
            self.portal.send(Cmd::Button(b, false));
        }
        let ev = self.kb.release_all();
        if !ev.is_empty() && self.portal.is_open() {
            self.portal.send(Cmd::Keys(ev));
        }
    }

    fn pointer(&self) -> Option<(f64, f64)> {
        let at = self.shared.cursor.lock().unwrap().at?;
        let m = self.shared.mirror.lock().unwrap();
        math::pointer_norm(at.0, at.1, m.width, m.height)
    }

    /// The pointer on the desktop (the monitors' logical layout), while it's on the monitor being shown.
    fn pointer_desktop(&self) -> Option<(f64, f64)> {
        let (x, y) = self.pointer()?;
        if !(0.0..1.0).contains(&x) || !(0.0..1.0).contains(&y) {
            return None;
        }
        let s = self.portal.stream()?;
        Some((s.position.0 as f64 + x * s.size.0 as f64, s.position.1 as f64 + y * s.size.1 as f64))
    }

    fn cursor_shape(&mut self) -> Option<CursorShape> {
        let mut c = self.shared.cursor.lock().unwrap();
        if !c.shape_new {
            return None;
        }
        c.shape_new = false;
        c.shape.clone()
    }
}

impl LinuxInput {
    /// The portal session went away under us: nothing we pressed is down any more.
    pub fn forget(&mut self) {
        self.kb.forget();
        self.buttons.clear();
        self.scrolling = false;
    }
}
