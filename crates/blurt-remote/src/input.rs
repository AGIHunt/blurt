//! The phone's hands on this computer, platform-neutral (the policy half of RemoteInput.swift; the backends only press).
//!
//!  • modifiers: everything that holds one is kept here — the phone's sticky ones (`mods`), keys held across messages (⌘ during
//!    ⌘Tab, Alt during Alt+Tab here) — and the backend is told the union with `set_held`, each time it changes. A chord is the
//!    union with its own modifiers, the key down and up (`key(name, 0, None)`), then the union again: the real sequence a keyboard
//!    makes, which the OS's own shortcuts read. A chord with no key (or a name the table doesn't have) is its modifiers tapped.
//!  • `releaseAll` lets go of all of it: a phone that drops off the Wi-Fi with Ctrl down must not leave the computer stuck on Ctrl.
//!  • clicks are counted here (double / triple: same button, within the double-click time, within 6 points), a drag's press has a
//!    count of its own, and a scroll keeps its phases. After a fling the coast runs here at 120 Hz (`coast_step`), not on the
//!    phone, where Wi-Fi gaps would show as hitches; its steps are `ScrollPhase::Momentum`, and one Momentum (0, 0) ends it.
//!  • sequences run here in one go (Esc Esc's timing can't depend on Wi-Fi): at most 32 steps and 3 s of waits (the server
//!    checks), each wait at most 2 s.
//!  • the phone numbers its pointer instructions, and is told how far the host has got with them (`Told`): the number goes out
//!    with the cursor's place (screen.rs), once that place is sure to include the move.

use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::host::{Backend, Button, Input, ScrollPhase as Phase, SystemMove};
use crate::packets::{covers, PointerPacket, ScrollPhase};
use crate::wire::{Chord, MouseButton, Step};

/// The backend, shared by the input thread, the screen and the server (one call at a time).
pub type Shared = Arc<Mutex<Box<dyn Backend>>>;

/// The names RemoteKey.all has (RemoteKeys.swift): anything else in a chord is its modifiers alone, as on the Mac.
pub fn known_key(name: &str) -> bool {
    const NAMED: [&str; 25] = [
        "Return", "Tab", "Space", "Delete", "Escape", "ForwardDelete", "Left", "Right", "Down", "Up", "Home", "End", "PageUp",
        "PageDown", "-", "=", "[", "]", ";", "'", ",", ".", "/", "\\", "`",
    ];
    let b = name.as_bytes();
    (b.len() == 1 && (b[0].is_ascii_uppercase() || b[0].is_ascii_digit()))
        || name.strip_prefix('F').and_then(|n| n.parse::<u8>().ok()).is_some_and(|n| (1..=12).contains(&n) && !name.starts_with("F0"))
        || NAMED.contains(&name)
}

/// The modifiers as the host names them (Ctrl+C here, ⌘C on a Mac), for a HUD.
pub fn label(c: &Chord, windows: bool) -> String {
    let mut parts: Vec<&str> = vec![];
    for (bit, name) in [(8u8, "Ctrl"), (4, "Alt"), (2, "Shift"), (1, if windows { "Win" } else { "Super" })] {
        if c.mods & bit != 0 {
            parts.push(name);
        }
    }
    let key = match c.key.as_str() {
        "Return" => "Enter",
        "Delete" => "Backspace",
        "Escape" => "Esc",
        "ForwardDelete" => "Delete",
        k => k,
    };
    if !key.is_empty() {
        parts.push(key);
    }
    parts.join("+")
}

/// How long the OS may take to report a pointer just moved (RemoteInput.swift allows the Mac the same).
pub const REPORT_LAG: Duration = Duration::from_millis(150);

/// How far the host has got with the phone's pointer instructions (`PointerPacket::Move`, `ToMac::PointerTo`: the phone numbers
/// them, one count for both), for the cursor's place: screen.rs sends the number with it, and the phone takes a place whose number
/// covers everything it sent as the last word on where the pointer is. The input thread says when one is made (`Cmd::Made`); the
/// screen's ticker asks which number the place it is about to send includes. RemoteInput.swift: `made`, `forgetPhone`, `forPhone`.
///
///  • a place sent with a number must already include that move, or the phone's pointer jumps back to where it was. The place is the
///    OS's word (GetCursorPos on Windows, the screen stream's cursor metadata on Wayland), and that takes a moment to follow a move.
///    The Mac sends where it put the pointer itself for 150 ms instead; here a relative move ends where the backend or the
///    compositor puts it, which this layer doesn't know. So a number counts only once it is `REPORT_LAG` old: until then the phone
///    gets the number before it (or none) and keeps its own guess, as it does while a move is still on its way.
///  • the numbers are one session's: a new session forgets them, so a phone that sends none (before 1.0.17) keeps getting the
///    8-byte place it can read, and what still arrives from the phone it replaced doesn't count.
#[derive(Default)]
pub struct Told(Mutex<Numbers>);

#[derive(Default)]
struct Numbers {
    /// the session whose numbers count
    session: Option<u64>,
    /// the newest one the OS's word on the pointer includes by now
    settled: Option<u32>,
    /// a newer one and when it was made: the OS may not have caught up with it yet
    fresh: Option<(u32, Instant)>,
}

impl Told {
    /// A new session: no numbers until this phone sends one.
    pub fn forget(&self, session: u64) {
        *self.0.lock().unwrap() = Numbers { session: Some(session), settled: None, fresh: None };
    }

    /// The phone's instruction with this number is made. Later ones count; one that came late (datagrams) changes nothing; one far
    /// behind is a phone that started over.
    pub fn made(&self, session: u64, seq: u32, at: Instant) {
        let mut s = self.0.lock().unwrap();
        if s.session != Some(session) {
            return;
        }
        match s.fresh.map(|f| f.0).or(s.settled) {
            Some(newest) if covers(newest, seq) => {
                if newest.wrapping_sub(seq) < 1 << 16 {
                    return;
                }
                s.settled = None;
            }
            _ => {
                // the one before it, if the OS has had its time with it; else it's passed over
                if let Some((n, _)) = s.fresh.filter(|f| at.saturating_duration_since(f.1) >= REPORT_LAG) {
                    s.settled = Some(n);
                }
            }
        }
        s.fresh = Some((seq, at));
    }

    /// The newest of the phone's instructions that a place read from the OS at `now` includes. None: it has sent no numbers (or none
    /// old enough yet), and its cursor is the 8 bytes every phone reads.
    pub fn number(&self, now: Instant) -> Option<u32> {
        let s = self.0.lock().unwrap();
        match s.fresh {
            Some((n, at)) if now.saturating_duration_since(at) >= REPORT_LAG => Some(n),
            _ => s.settled,
        }
    }
}

#[derive(Default)]
pub struct Hands {
    sticky: u8,
    /// held key ids ("Tab", or "mods:<bits>" for modifiers alone), in the order they went down, with their chord's modifiers
    held: Vec<(String, u8)>,
    /// what the backend has been told is down
    down: u8,
    buttons: Vec<Button>,
    /// button, when, count, and how far the pointer went since (points)
    last_click: Option<(Button, f64, u32, (f64, f64))>,
    scrolling: bool,
    coast: Option<Coast>,
    /// seconds; Windows' default double-click time
    pub double_click: f64,
}

struct Coast {
    vx: f64,
    vy: f64,
    last: f64,
}

pub const COAST_HZ: f64 = 120.0;

impl Hands {
    pub fn new() -> Hands {
        Hands { double_click: 0.5, ..Default::default() }
    }

    fn all_held(&self) -> u8 {
        self.held.iter().fold(self.sticky, |m, (_, x)| m | x)
    }

    fn sync(&mut self, i: &mut dyn Input, want: u8) {
        if want != self.down {
            self.down = want;
            i.set_held(want);
        }
    }

    pub fn press(&mut self, i: &mut dyn Input, c: &Chord) {
        let keep = self.all_held();
        self.sync(i, keep | c.mods);
        if known_key(&c.key) {
            i.key(&c.key, 0, None);
        }
        self.sync(i, keep);
    }

    pub fn hold(&mut self, i: &mut dyn Input, c: &Chord, down: bool) {
        let id = if c.key.is_empty() { format!("mods:{}", c.mods) } else { c.key.clone() };
        if down {
            if self.held.iter().any(|(k, _)| *k == id) {
                return;
            }
            self.held.push((id, c.mods));
            let all = self.all_held();
            self.sync(i, all);
            if known_key(&c.key) {
                i.key(&c.key, 0, Some(true));
            }
        } else {
            let Some(n) = self.held.iter().position(|(k, _)| *k == id) else { return };
            self.held.remove(n);
            if known_key(&c.key) {
                i.key(&c.key, 0, Some(false));
            }
            let all = self.all_held();
            self.sync(i, all);
        }
    }

    pub fn set_sticky(&mut self, i: &mut dyn Input, m: u8) {
        self.sticky = m;
        let all = self.all_held();
        self.sync(i, all);
    }

    pub fn release_all(&mut self, i: &mut dyn Input) {
        self.stop_coast(i);
        if self.scrolling {
            self.scrolling = false;
            i.scroll(0.0, 0.0, Phase::Ended);
        }
        for b in std::mem::take(&mut self.buttons) {
            i.button(b, false, 1);
        }
        for (k, _) in std::mem::take(&mut self.held) {
            if known_key(&k) {
                i.key(&k, 0, Some(false));
            }
        }
        self.sticky = 0;
        self.sync(i, 0);
        i.release_all();
    }

    fn moved(&mut self, dx: f64, dy: f64) {
        if let Some(l) = &mut self.last_click {
            l.3 .0 += dx;
            l.3 .1 += dy;
        }
    }

    pub fn move_by(&mut self, i: &mut dyn Input, dx: f64, dy: f64) {
        self.moved(dx, dy);
        i.move_by(dx, dy);
    }

    /// The phone's view moved away from the pointer (or a hold brought it to the finger): it comes along.
    pub fn move_to(&mut self, i: &mut dyn Input, x: f64, y: f64) {
        self.last_click = None;
        i.move_to(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
    }

    pub fn button(&mut self, i: &mut dyn Input, b: MouseButton, down: bool, now: f64) {
        let b = match b {
            MouseButton::Left => Button::Left,
            MouseButton::Right => Button::Right,
            MouseButton::Middle => Button::Middle,
        };
        let mut count = self.last_click.map_or(1, |l| l.2);
        if down {
            count = 1;
            if let Some((lb, at, n, (dx, dy))) = self.last_click {
                if lb == b && now - at < self.double_click && dx.hypot(dy) < 6.0 {
                    count = n + 1;
                }
            }
            self.last_click = Some((b, now, count, (0.0, 0.0)));
            if !self.buttons.contains(&b) {
                self.buttons.push(b);
            }
        } else {
            self.buttons.retain(|x| *x != b);
        }
        i.button(b, down, count);
    }

    /// The left button down for a drag: a count of its own, so it isn't taken for a double click that selects words.
    pub fn drag_begin(&mut self, i: &mut dyn Input, now: f64) {
        self.last_click = None;
        self.button(i, MouseButton::Left, true, now);
    }

    pub fn scroll(&mut self, i: &mut dyn Input, dx: f64, dy: f64, phase: ScrollPhase) {
        self.stop_coast(i);
        match phase {
            ScrollPhase::Began => {
                self.scrolling = true;
                i.scroll(dx, dy, Phase::Began);
            }
            ScrollPhase::Changed => {
                let p = if self.scrolling { Phase::Changed } else { Phase::Began };
                self.scrolling = true;
                i.scroll(dx, dy, p);
            }
            ScrollPhase::Ended => {
                self.scrolling = false;
                i.scroll(0.0, 0.0, Phase::Ended);
            }
        }
    }

    pub fn fling(&mut self, i: &mut dyn Input, vx: f64, vy: f64, now: f64) {
        self.stop_coast(i);
        if vx.hypot(vy) > 40.0 {
            self.coast = Some(Coast { vx, vy, last: now });
        }
    }

    pub fn coasting(&self) -> bool {
        self.coast.is_some()
    }

    /// One step of the coast (call at COAST_HZ while `coasting`): about the decay of a UIScrollView at normal speed.
    pub fn coast_step(&mut self, i: &mut dyn Input, now: f64) {
        let Some(c) = &mut self.coast else { return };
        let dt = (now - c.last).clamp(0.0, 0.1);
        c.last = now;
        let k = 0.998f64.powf(dt * 1000.0);
        c.vx *= k;
        c.vy *= k;
        if c.vx.hypot(c.vy) < 12.0 {
            return self.stop_coast(i);
        }
        let (dx, dy) = (c.vx * dt, c.vy * dt);
        i.scroll(dx, dy, Phase::Momentum);
    }

    pub fn stop_coast(&mut self, i: &mut dyn Input) {
        if self.coast.take().is_some() {
            i.scroll(0.0, 0.0, Phase::Momentum);
        }
    }

    pub fn pointer(&mut self, i: &mut dyn Input, p: PointerPacket, now: f64) {
        match p {
            // its number, if it has one, is the server's to follow with (`Cmd::Made`)
            PointerPacket::Move { dx, dy, .. } => self.move_by(i, dx as f64, dy as f64),
            PointerPacket::Scroll { dx, dy, phase } => self.scroll(i, dx as f64, dy as f64, phase),
            PointerPacket::Fling { vx, vy } => self.fling(i, vx as f64, vy as f64, now),
            PointerPacket::Stop => self.stop_coast(i),
        }
    }
}

/// What the server asks of the input thread.
#[derive(Debug)]
pub enum Cmd {
    Key(Chord, Option<bool>),
    Mods(u8),
    Run(Vec<Step>),
    Text(String),
    Button(MouseButton, bool),
    DragBegin,
    Pointer(PointerPacket),
    MoveTo(f64, f64),
    /// The session's pointer instruction with this number, sent right behind the move it numbers: made (`Told`). Also for a
    /// `pointerTo` there was no picture to place on: the phone waits for its number all the same.
    Made(u64, u32),
    System(SystemMove),
    ReleaseAll,
}

/// The input thread: one at a time, never the server's own tasks, so a slow backend call or a sequence's wait holds up nothing
/// else. The backend is locked per call, and not during a wait.
pub fn spawn(backend: Shared, told: Arc<Told>) -> Sender<Cmd> {
    let (tx, rx) = std::sync::mpsc::channel::<Cmd>();
    std::thread::Builder::new()
        .name("blurt-remote-input".into())
        .spawn(move || run(backend, told, rx))
        .expect("a thread");
    tx
}

fn run(backend: Shared, told: Arc<Told>, rx: Receiver<Cmd>) {
    let mut h = Hands::new();
    let now = |b: &Shared| b.lock().unwrap().now();
    loop {
        let cmd = if h.coasting() {
            match rx.recv_timeout(Duration::from_secs_f64(1.0 / COAST_HZ)) {
                Ok(c) => Some(c),
                Err(RecvTimeoutError::Timeout) => None,
                Err(RecvTimeoutError::Disconnected) => return,
            }
        } else {
            match rx.recv() {
                Ok(c) => Some(c),
                Err(_) => return,
            }
        };
        let Some(cmd) = cmd else {
            let mut b = backend.lock().unwrap();
            let t = b.now();
            h.coast_step(b.input(), t);
            continue;
        };
        if let Cmd::Run(steps) = cmd {
            for s in steps {
                match s {
                    Step::Key(c) => h.press(backend.lock().unwrap().input(), &c),
                    Step::Text(t) => backend.lock().unwrap().input().text(&t),
                    Step::Wait(ms) => std::thread::sleep(Duration::from_millis(ms.clamp(0, 2000) as u64)),
                }
            }
            continue;
        }
        if let Cmd::Made(session, seq) = cmd {
            // in the queue behind its move, so that is done by now
            told.made(session, seq, Instant::now());
            continue;
        }
        let t = now(&backend);
        let mut b = backend.lock().unwrap();
        let i = b.input();
        match cmd {
            Cmd::Key(c, None) => h.press(i, &c),
            Cmd::Key(c, Some(d)) => h.hold(i, &c, d),
            Cmd::Mods(m) => h.set_sticky(i, m),
            Cmd::Text(t) => i.text(&t),
            Cmd::Button(btn, d) => h.button(i, btn, d, t),
            Cmd::DragBegin => h.drag_begin(i, t),
            Cmd::Pointer(p) => h.pointer(i, p, t),
            Cmd::MoveTo(x, y) => h.move_to(i, x, y),
            Cmd::System(m) => i.system(m),
            Cmd::ReleaseAll => h.release_all(i),
            Cmd::Run(_) | Cmd::Made(..) => {}
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::host::CursorShape;

    /// Every call, as a line.
    #[derive(Default)]
    pub struct Log(pub Vec<String>);

    impl Input for Log {
        fn can_control(&self) -> bool {
            true
        }
        fn key(&mut self, name: &str, mods: u8, down: Option<bool>) {
            self.0.push(format!("key {name} {mods} {down:?}"));
        }
        fn set_held(&mut self, mods: u8) {
            self.0.push(format!("held {mods}"));
        }
        fn text(&mut self, t: &str) {
            self.0.push(format!("text {t}"));
        }
        fn button(&mut self, b: Button, down: bool, clicks: u32) {
            self.0.push(format!("button {b:?} {down} {clicks}"));
        }
        fn move_by(&mut self, dx: f64, dy: f64) {
            self.0.push(format!("move {dx} {dy}"));
        }
        fn move_to(&mut self, x: f64, y: f64) {
            self.0.push(format!("to {x} {y}"));
        }
        fn scroll(&mut self, dx: f64, dy: f64, p: Phase) {
            self.0.push(format!("scroll {dx:.0} {dy:.0} {p:?}"));
        }
        fn system(&mut self, m: SystemMove) {
            self.0.push(format!("system {m:?}"));
        }
        fn release_all(&mut self) {
            self.0.push("release".into());
        }
        fn pointer(&self) -> Option<(f64, f64)> {
            None
        }
        fn cursor_shape(&mut self) -> Option<CursorShape> {
            None
        }
    }

    fn take(l: &mut Log) -> Vec<String> {
        std::mem::take(&mut l.0)
    }

    #[test]
    fn a_chord_presses_its_modifiers_around_the_key() {
        let (mut h, mut l) = (Hands::new(), Log::default());
        h.press(&mut l, &Chord::new(8, "C"));
        assert_eq!(take(&mut l), ["held 8", "key C 0 None", "held 0"]);
        // a sticky Shift stays down through it
        h.set_sticky(&mut l, 2);
        h.press(&mut l, &Chord::new(8, "C"));
        assert_eq!(take(&mut l), ["held 2", "held 10", "key C 0 None", "held 2"]);
        // the Windows key alone: down and up, so Start opens
        h.set_sticky(&mut l, 0);
        h.press(&mut l, &Chord::new(1, ""));
        assert_eq!(take(&mut l), ["held 0", "held 1", "held 0"]);
        // a name the table doesn't have is its modifiers alone
        h.press(&mut l, &Chord::new(4, "Teleport"));
        assert_eq!(take(&mut l), ["held 4", "held 0"]);
    }

    #[test]
    fn alt_tab_held_and_stepped() {
        let (mut h, mut l) = (Hands::new(), Log::default());
        h.hold(&mut l, &Chord::new(4, ""), true);
        h.press(&mut l, &Chord::new(4, "Tab"));
        h.press(&mut l, &Chord::new(4 | 2, "Tab"));
        h.hold(&mut l, &Chord::new(4, ""), true); // repeated: the same press
        h.hold(&mut l, &Chord::new(4, ""), false);
        assert_eq!(take(&mut l), ["held 4", "key Tab 0 None", "held 6", "key Tab 0 None", "held 4", "held 0"]);
        h.hold(&mut l, &Chord::new(4, ""), false);
        assert!(l.0.is_empty(), "nothing held, nothing to let go");
    }

    #[test]
    fn release_all_lets_go_of_everything() {
        let (mut h, mut l) = (Hands::new(), Log::default());
        h.hold(&mut l, &Chord::new(1, "Tab"), true);
        h.set_sticky(&mut l, 8);
        h.button(&mut l, MouseButton::Left, true, 0.0);
        h.scroll(&mut l, 0.0, 5.0, ScrollPhase::Began);
        take(&mut l);
        h.release_all(&mut l);
        assert_eq!(take(&mut l), ["scroll 0 0 Ended", "button Left false 1", "key Tab 0 Some(false)", "held 0", "release"]);
        h.release_all(&mut l);
        assert_eq!(take(&mut l), ["release"], "twice is safe");
    }

    #[test]
    fn clicks_count_at_one_spot_within_the_time() {
        let (mut h, mut l) = (Hands::new(), Log::default());
        for (t, n) in [(0.0, 1), (0.2, 2), (0.4, 3)] {
            h.button(&mut l, MouseButton::Left, true, t);
            h.button(&mut l, MouseButton::Left, false, t + 0.05);
            assert_eq!(l.0[l.0.len() - 2], format!("button Left true {n}"));
            assert_eq!(l.0[l.0.len() - 1], format!("button Left false {n}"));
        }
        h.button(&mut l, MouseButton::Left, true, 2.0);
        assert_eq!(l.0.last().unwrap(), "button Left true 1", "too late");
        h.move_by(&mut l, 10.0, 0.0);
        h.button(&mut l, MouseButton::Left, true, 2.1);
        assert_eq!(l.0.last().unwrap(), "button Left true 1", "moved away");
        h.drag_begin(&mut l, 2.2);
        assert_eq!(l.0.last().unwrap(), "button Left true 1", "a drag is never a double click");
    }

    #[test]
    fn scroll_phases_and_the_coast() {
        let (mut h, mut l) = (Hands::new(), Log::default());
        h.scroll(&mut l, 0.0, 4.0, ScrollPhase::Changed);
        h.scroll(&mut l, 0.0, 4.0, ScrollPhase::Changed);
        h.scroll(&mut l, 0.0, 0.0, ScrollPhase::Ended);
        assert_eq!(take(&mut l), ["scroll 0 4 Began", "scroll 0 4 Changed", "scroll 0 0 Ended"]);
        h.fling(&mut l, 0.0, 20.0, 0.0);
        assert!(!h.coasting(), "too slow to coast");
        h.fling(&mut l, 0.0, 1200.0, 0.0);
        let mut t = 0.0;
        while h.coasting() {
            t += 1.0 / COAST_HZ;
            h.coast_step(&mut l, t);
        }
        let steps = take(&mut l);
        assert!(steps.len() > 100, "about 1.6 s of coast: {}", steps.len());
        assert_eq!(steps.last().unwrap(), "scroll 0 0 Momentum", "and its end");
        assert!(steps[0].ends_with("Momentum"));
        // a finger landing stops it
        h.fling(&mut l, 0.0, 1200.0, 0.0);
        h.pointer(&mut l, PointerPacket::Stop, 0.01);
        assert_eq!(take(&mut l), ["scroll 0 0 Momentum"]);
    }

    #[test]
    fn a_number_counts_once_the_os_has_had_time_to_report_the_move() {
        let (t, ms) = (Told::default(), Duration::from_millis);
        let t0 = Instant::now();
        t.made(1, 5, t0);
        assert_eq!(t.number(t0), None, "no session yet: nobody's numbers count");
        t.forget(1);
        assert_eq!(t.number(t0), None, "a phone that sends none gets none");
        t.made(1, 5, t0);
        assert_eq!(t.number(t0 + ms(100)), None, "the place may still be the one before the move");
        assert_eq!(t.number(t0 + REPORT_LAG), Some(5));
        // a stroke: each move takes the last one's place before it's old enough, and the last one counts once the finger rests
        for n in 6..=20u32 {
            t.made(1, n, t0 + ms(200) + ms(8) * (n - 6));
        }
        let end = t0 + ms(200) + ms(8) * 14;
        assert_eq!(t.number(end + ms(100)), Some(5), "never a number ahead of the place");
        assert_eq!(t.number(end + REPORT_LAG), Some(20));
        // one that arrives late changes nothing, and neither does the same one again
        t.made(1, 18, end + ms(300));
        t.made(1, 20, end + ms(300));
        assert_eq!(t.number(end + ms(301)), Some(20));
        // a slow stroke: the number follows, the lag behind
        t.made(1, 21, end + ms(400));
        t.made(1, 22, end + ms(600));
        assert_eq!(t.number(end + ms(601)), Some(21));
        assert_eq!(t.number(end + ms(750)), Some(22));
    }

    #[test]
    fn numbers_wrap_start_over_and_belong_to_one_session() {
        let (t, ms) = (Told::default(), Duration::from_millis);
        let t0 = Instant::now();
        t.forget(1);
        t.made(1, u32::MAX, t0);
        t.made(1, 2, t0 + ms(200));
        assert_eq!(t.number(t0 + ms(200)), Some(u32::MAX));
        assert_eq!(t.number(t0 + ms(350)), Some(2), "past the wrap is later");
        // far behind: the phone counts from 1 again, and the old count says nothing about its moves
        t.made(1, 70_000, t0 + ms(400));
        t.made(1, 1, t0 + ms(600));
        assert_eq!(t.number(t0 + ms(601)), None);
        assert_eq!(t.number(t0 + ms(750)), Some(1));
        // the phone this one replaced is still sending: not its numbers
        t.forget(2);
        assert_eq!(t.number(t0 + ms(900)), None, "a new session forgets");
        t.made(1, 9, t0 + ms(900));
        assert_eq!(t.number(t0 + ms(1100)), None);
        t.made(2, 1, t0 + ms(1100));
        assert_eq!(t.number(t0 + ms(1250)), Some(1));
    }

    #[test]
    fn key_names() {
        for k in ["A", "Z", "0", "9", "F1", "F12", "Return", "`", "\\", "PageDown"] {
            assert!(known_key(k), "{k}");
        }
        for k in ["", "a", "F0", "F13", "F01", "Enter", "AB"] {
            assert!(!known_key(k), "{k}");
        }
        assert_eq!(label(&Chord::new(8 | 2, "C"), true), "Ctrl+Shift+C");
        assert_eq!(label(&Chord::new(1, ""), false), "Super");
    }
}
