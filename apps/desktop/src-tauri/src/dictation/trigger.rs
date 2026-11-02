//! Dictation's trigger (docs/design/dictation.md §Trigger), ported from the Mac's
//! `skills/blurt/recorder/macos/Sources/BlurtCore/DictationTrigger.swift` (its tests, `DictationTriggerTests.swift`, are
//! ported below). A modifier key alone — right Alt (the default here: Windows has no Fn) or either Alt — which a
//! registered hotkey can't be, read from a low-level keyboard hook (key down / up) and a mouse hook (button down). This
//! is the pure part: events with timestamps in, start / stop / cancel out. No Win32, no timers — the caller asks for a
//! tick at `deadline` (hold's 250 ms, auto's 300 ms) — so every sequence is unit-testable.
//!
//!   auto mode (default) a short tap starts hands-free and the next clean press stops it; held alone past `auto_hold`
//!                       (300 ms) it is push-to-talk instead: it starts then, and letting go stops. Like Typeless.
//!   tap mode            a clean tap starts, the next clean tap stops. Clean = the key went down and up within
//!                       `tap_max` (400 ms) with no other key, modifier or click in between, and no other modifier
//!                       held when it went down — so the key as a modifier (Alt-letter, Alt+V, Alt+←) never triggers.
//!   hold mode           held alone for `hold_min` (250 ms) starts; letting go stops; another key or a click joining
//!                       in cancels (the user is typing a shortcut, not talking).
//!   all                 Esc cancels a dictation in progress; `Arm` on a clean key-down (warm the models, open the mic
//!                       early); `armed_down` says whether that press can still start (else the app closes the mic).
//!   double tap          (`double_tap`, on by default) two clean taps, the second going down within
//!                       `double_tap_window` of the first one's release, say `Send`: the app presses Return. The window
//!                       is the system's double-click time clamped to 0.3–0.5 s (`window(GetDoubleClickTime() / 1000)`;
//!                       0.5 s here by default). The first tap still does what it always did, at once (no waiting for a
//!                       second one):
//!                         • it started a dictation (idle, auto / tap mode) → the second one cancels it (`Cancel`,
//!                           nothing kept) and sends: Return in the app in front;
//!                         • it stopped one (hands-free) → the second one sends: the app presses Return once the
//!                           paste has landed — "dictate, then send";
//!                         • it did nothing (hold mode, a tap right after a take ended by itself, the first tap after
//!                           push-to-talk) → the second one sends.
//!                       Push-to-talk: letting go stops it, and a double tap right after sends (release, tap, tap: a
//!                       tap within the window of the release does nothing by itself) — what the help text says.
//!                       A near miss — the stop tap went down within `near_miss_window` (0.8 s) of the start tap's
//!                       release — sets `quick_stop`: the app sends instead of saying "nothing heard" when nothing was.
//!                       The second press opens no mic when it can only send; held instead, it is push-to-talk as usual.
//!   pending             (`pending`: the app sets it while the last take is still being transcribed, polished or
//!                       pasted) a press is a press as when idle: once the double-tap window of the stop tap has passed,
//!                       a tap starts the next take at once (the app pastes in order); within it, it is the double tap's
//!                       second one and sends after the paste. Esc then cancels the take on its way (`Cancel`).
//!   bounces             a tap within the double-tap window of a send does nothing (a third tap of a quick double tap
//!                       never starts a take); for `LIMIT_GRACE` after a take ended by itself (the 5-minute limit,
//!                       `ended_by_itself`) the next tap does nothing either: it was meant as the stop.
//!   misses              (`miss`) a clean press the mode doesn't use — hold mode let go before `hold_min`, tap mode held
//!                       past `tap_max` — is reported, so the app can say how to start in that mode.
//!   repeats             the key reported down again while it is down (Windows auto-repeats a held key, two hooks) is
//!                       the same press; a modifier's auto-repeat is dropped before anything sees it (the Mac's
//!                       flagsChanged never repeats, and a repeated Shift down would read as a double tap).
//!   style               (docs/design/dictation-styles.md §3.2) Shift double-tapped alone while dictating says
//!                       `Style`: the app toggles Structured for this take (one Shift, or two too far apart, is nothing).
//!                       In push-to-talk too: a lone Shift is the one key that joins in without cancelling (Shift with
//!                       another key still cancels, as any shortcut does).
//!                       A click on Blurt's own island (`IslandClick`: the app tells which clicks land there) is the
//!                       same toggle and never cancels. Shift with the start press (Alt+Shift) is a modifier like any
//!                       other: a shortcut, never a start (Alt+Shift switches the keyboard layout on Windows).
//!   translate           (docs/design/dictation-translate.md) Ctrl — either one; the Mac's ⌘, the key Windows'
//!                       shortcuts are on (Ctrl+V as ⌘V) — double-tapped alone while dictating says `Translate`: the
//!                       app turns translation on or off for this take. Like Shift, it joins push-to-talk without
//!                       cancelling it; Ctrl with a key (Ctrl+V) is a shortcut and cancels as before.
//!                       `record.dictation.modifier_tap` puts both keys on a single tap instead (default: double).
//!                       A click on the island's left half (`IslandTranslateClick`) is the same toggle.
//!
//! What the Mac's event tap gave for free and the hook layer must do here: drop its own injected events (LLKHF_INJECTED:
//! Ctrl+V, Return, a menu-mask key), and drop the fake left Ctrl that AltGr layouts send just before right Alt — or
//! right Alt is never "alone" there. The Windows-only trait of a lone Alt tap (it focuses the menu bar of a Win32 app) is
//! the hook layer's to mask, as is the Start menu for the Win key.

/// Windows virtual-key codes the trigger knows (the sided ones WH_KEYBOARD_LL reports).
pub mod vk {
    pub const ESCAPE: u32 = 0x1B;
    pub const LWIN: u32 = 0x5B;
    pub const RWIN: u32 = 0x5C;
    pub const LSHIFT: u32 = 0xA0;
    pub const RSHIFT: u32 = 0xA1;
    pub const LCONTROL: u32 = 0xA2;
    pub const RCONTROL: u32 = 0xA3;
    pub const LMENU: u32 = 0xA4;
    pub const RMENU: u32 = 0xA5;
}

// The modifiers held, one bit per physical key (the Mac's flags: device bits for the sides, device-independent masks
// for "a Shift / a Ctrl is down").
const B_LSHIFT: u32 = 1 << 0;
const B_RSHIFT: u32 = 1 << 1;
const B_LCTRL: u32 = 1 << 2;
const B_RCTRL: u32 = 1 << 3;
const B_LWIN: u32 = 1 << 4;
const B_RWIN: u32 = 1 << 5;
const B_LALT: u32 = 1 << 6;
const B_RALT: u32 = 1 << 7;
const M_SHIFT: u32 = B_LSHIFT | B_RSHIFT;
const M_CTRL: u32 = B_LCTRL | B_RCTRL;
const M_WIN: u32 = B_LWIN | B_RWIN;

fn mod_bit(code: u32) -> Option<u32> {
    match code {
        vk::LSHIFT => Some(B_LSHIFT),
        vk::RSHIFT => Some(B_RSHIFT),
        vk::LCONTROL => Some(B_LCTRL),
        vk::RCONTROL => Some(B_RCTRL),
        vk::LWIN => Some(B_LWIN),
        vk::RWIN => Some(B_RWIN),
        vk::LMENU => Some(B_LALT),
        vk::RMENU => Some(B_RALT),
        _ => None,
    }
}

/// The dictation key.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Key {
    /// right Alt (the default: Windows keyboards have no Fn the system reports)
    #[default]
    RightAlt,
    /// either Alt — left or right, whichever is tapped alone
    EitherAlt,
}

impl Key {
    /// Pickers list the default first.
    pub const ALL: [Key; 2] = [Key::RightAlt, Key::EitherAlt];

    /// `record.dictation.key`, in the Mac's words so one settings file reads the same on both: `right_option`,
    /// `either_option` (`right_alt` / `either_alt` too). `fn`, the Mac's default, is right Alt here.
    pub fn from_config(s: &str) -> Option<Key> {
        match s {
            "right_option" | "right_alt" | "fn" => Some(Key::RightAlt),
            "either_option" | "either_alt" => Some(Key::EitherAlt),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Key::RightAlt => "right_option",
            Key::EitherAlt => "either_option",
        }
    }

    /// VK_RMENU; VK_LMENU and VK_RMENU
    pub fn codes(self) -> &'static [u32] {
        match self {
            Key::RightAlt => &[vk::RMENU],
            Key::EitherAlt => &[vk::LMENU, vk::RMENU],
        }
    }

    /// The bit that says the key `code` is down.
    fn down_mask(code: u32) -> u32 {
        mod_bit(code).unwrap_or(0)
    }

    /// Other modifiers that make a press of `code` "not alone": Ctrl, Shift, Win and the other Alt.
    fn other_mods(code: u32) -> u32 {
        let common = M_CTRL | M_SHIFT | M_WIN;
        if code == vk::LMENU {
            common | B_RALT
        } else {
            common | B_LALT
        }
    }
}

/// auto (the default): a tap is hands-free, a hold is push-to-talk; tap: tap / tap; hold: push-to-talk only
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Mode {
    #[default]
    Auto,
    Tap,
    Hold,
}

impl Mode {
    pub const ALL: [Mode; 3] = [Mode::Auto, Mode::Tap, Mode::Hold];

    /// `record.dictation.mode`
    pub fn from_config(s: &str) -> Option<Mode> {
        match s {
            "auto" => Some(Mode::Auto),
            "tap" => Some(Mode::Tap),
            "hold" => Some(Mode::Hold),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Auto => "auto",
            Mode::Tap => "tap",
            Mode::Hold => "hold",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Output {
    /// a clean key-down that may still become a start: open the mic, warm the models
    Arm,
    Start,
    Stop,
    Cancel,
    /// a double tap: press Return in the app in front (after the paste, when a dictation just stopped)
    Send,
    /// Shift double-tapped alone (or a click on the island) while dictating: toggle Structured for this take
    Style,
    /// Ctrl double-tapped alone (or a click on the island's left half) while dictating: translation on or off (one tap
    /// when the setting says single)
    Translate,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Event {
    /// A key went down or up (WH_KEYBOARD_LL, every key): its sided virtual-key code (`vk`) and the event's own time.
    /// Modifiers are tracked from these (the Mac's flags); other keys' ups are ignored, as the Mac never listened to them.
    Key {
        code: u32,
        down: bool,
        time: f64,
    },
    MouseDown {
        time: f64,
    },
    /// a click on Blurt's own island (the app checks where a mouse-down landed): never cancels push-to-talk
    IslandClick {
        time: f64,
    },
    /// …on its left half (Peep's ear): the translate toggle
    IslandTranslateClick {
        time: f64,
    },
    /// the caller's timer, at or after `deadline`
    Tick {
        time: f64,
    },
}

/// How a modifier alone while dictating asks for its toggle (structured / translate): a double tap (the default) or a
/// single tap (record.dictation.modifier_tap; per-key override modifier_tap_shift / modifier_tap_command).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ModifierTap {
    Single,
    Double,
}

impl ModifierTap {
    pub fn from_config(s: &str) -> Option<ModifierTap> {
        match s {
            "single" => Some(ModifierTap::Single),
            "double" => Some(ModifierTap::Double),
            _ => None,
        }
    }
}

/// A press the mode doesn't use, set when it comes up: the app says how this mode starts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Miss {
    /// hold mode: let go before `hold_min` (a tap) — this mode is push-to-talk
    TappedInHoldMode,
    /// tap mode: held past `tap_max` — this mode starts with a tap
    HeldInTapMode,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum State {
    Idle,
    Down {
        at: f64,
        clean: bool,
        code: u32,
    },
    Holding,
    /// push-to-talk cancelled while still held: ignore until the key comes up
    WaitRelease,
}

/// What the last clean tap did (or that push-to-talk was let go), and when it came up: a tap soon after it is a double
/// tap's second one (after a release: its first one).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TapDid {
    Started,
    Stopped,
    Released,
    Nothing,
    Sent,
}

/// The two modifiers that toggle while dictating.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Toggle {
    Shift,
    Command,
}

#[derive(Clone, Debug)]
pub struct DictationTrigger {
    pub key: Key,
    pub mode: Mode,
    pub tap_max: f64,
    pub hold_min: f64,
    /// auto mode: shorter than this is a tap (hands-free); held alone this long is push-to-talk
    pub auto_hold: f64,
    /// Two quick taps press Return (record.dictation.double_tap_send, on by default).
    pub double_tap: bool,
    /// the second tap must go down within this long of the first one's release (the app sets the system's double-click
    /// time, clamped: `window`)
    pub double_tap_window: f64,
    /// a stop tap going down this soon after the start tap's release is a near miss of a double tap (`quick_stop`)
    pub near_miss_window: f64,
    /// The last take is still on its way (transcribing, polishing, pasting; the app sets it): Esc cancels it. A press
    /// starts the next take as usual.
    pub pending: bool,
    /// a lone Shift held longer than this is not a toggle (a finger resting on it); a lone Ctrl the same
    pub shift_tap_max: f64,
    /// the second tap must go down within this long of the first one's (350 ms: the double-click interval × 0.7, quick
    /// enough to feel instant, wide enough for a deliberate double tap)
    pub modifier_double_tap_window: f64,
    /// after a toggle fires, this long before the same key can ask again (a held key's repeat, a nervous double tap)
    pub modifier_cooldown: f64,
    /// the mode for each key (the app sets these; the struct itself defaults both to Single, the old behaviour, so a
    /// bare trigger in a test means the pre-double-tap one)
    pub modifier_tap_shift: ModifierTap,
    pub modifier_tap_command: ModifierTap,

    miss: Option<Miss>,
    state: State,
    /// the key code that went down last (either Alt: which side)
    holding_code: u32,
    last_tap: Option<(TapDid, f64)>,
    /// The press now down is the second tap of a double tap (if it comes up quickly): what the first one did.
    second: Option<TapDid>,
    /// the press now down only ends a bounce (soon after a send, or after a take ended by itself): a tap of it does
    /// nothing
    press_quiet: bool,
    /// …because a take had just ended by itself (its tap can still be a double tap's first one)
    press_after_end: bool,
    /// a take ended by itself (`ended_by_itself`): a tap before this does nothing
    quiet_until: Option<f64>,
    /// when the tap that started the dictation in progress came up (hands-free): the near-miss window counts from it
    start_tap_up: Option<f64>,
    /// Shift went down while dictating, alone so far: its release toggles the style
    shift_down_at: Option<f64>,
    /// Ctrl went down while dictating, alone so far: its release toggles translation
    command_down_at: Option<f64>,
    /// modifier double-tap state: which key tapped first and when, and when the cooldown after a fire ends
    modifier_last_tap: Option<(Toggle, f64)>,
    modifier_cooldown_until: f64,
    active: bool,
    push_to_talk: bool,
    quick_stop: bool,
    /// this press's `HeldInTapMode` was already reported while it was down (not again when it comes up)
    held_miss_said: bool,
    /// the modifiers down (B_* bits), from the key events
    held: u32,
}

impl Default for DictationTrigger {
    fn default() -> Self {
        DictationTrigger::new(Key::default(), Mode::default())
    }
}

impl DictationTrigger {
    /// What Blurt ships with for both Shift (Structured) and Ctrl (Translate) — a double tap 350 ms wide with a 500 ms
    /// cooldown. One gesture for both keys: one key on a tap and the other on a double tap is what confuses people. A
    /// lone tap was too easy to hit during a take. record.dictation.modifier_tap puts both back on "single".
    pub const SHIPPED_MODIFIER_TAP: ModifierTap = ModifierTap::Double;
    pub const SHIPPED_DOUBLE_TAP_WINDOW: f64 = 0.35;
    pub const SHIPPED_MODIFIER_COOLDOWN: f64 = 0.5;
    /// How long after the time limit a tap is the late stop: as long as the island's line about it shows.
    pub const LIMIT_GRACE: f64 = 4.0;

    pub fn new(key: Key, mode: Mode) -> Self {
        DictationTrigger {
            key,
            mode,
            tap_max: 0.4,
            hold_min: 0.25,
            auto_hold: 0.3,
            double_tap: true,
            double_tap_window: 0.5,
            near_miss_window: 0.8,
            pending: false,
            shift_tap_max: 1.0,
            modifier_double_tap_window: Self::SHIPPED_DOUBLE_TAP_WINDOW,
            modifier_cooldown: Self::SHIPPED_MODIFIER_COOLDOWN,
            modifier_tap_shift: ModifierTap::Single,
            modifier_tap_command: ModifierTap::Single,
            miss: None,
            state: State::Idle,
            holding_code: 0,
            last_tap: None,
            second: None,
            press_quiet: false,
            press_after_end: false,
            quiet_until: None,
            start_tap_up: None,
            shift_down_at: None,
            command_down_at: None,
            modifier_last_tap: None,
            modifier_cooldown_until: 0.0,
            active: false,
            push_to_talk: false,
            quick_stop: false,
            held_miss_said: false,
            held: 0,
        }
    }

    /// The system's double-click time (GetDoubleClickTime, in seconds) as the double-tap window: an Alt tap with the
    /// thumb is slower than a click, so never under 0.3 s; never over 0.5 s, where two separate taps (stop, then start
    /// the next one) would start to read as one double tap.
    pub fn window(double_click_interval: f64) -> f64 {
        double_click_interval.clamp(0.3, 0.5)
    }

    /// Dictating, as far as the trigger knows (the app calls `reset` when it ends one itself).
    pub fn active(&self) -> bool {
        self.active
    }

    /// The dictation in progress was started by holding the key (hold mode, or auto held past `auto_hold`): it ends
    /// when the key comes up, so it has no "nothing said" timeout.
    pub fn push_to_talk(&self) -> bool {
        self.push_to_talk
    }

    /// The `Stop` just given came from a tap soon after the start tap (`near_miss_window`): a double tap that was a
    /// little slow. The app sends Return instead when nothing was heard.
    pub fn quick_stop(&self) -> bool {
        self.quick_stop
    }

    /// A press the mode doesn't use, set when it comes up (None: none).
    pub fn miss(&self) -> Option<Miss> {
        self.miss
    }

    /// The miss, once: read and cleared together, so the keys and clicks that follow don't report it again.
    pub fn take_miss(&mut self) -> Option<Miss> {
        self.miss.take()
    }

    /// How long the key must be held alone to start push-to-talk (None: tap mode has no hold).
    fn hold_threshold(&self) -> Option<f64> {
        match self.mode {
            Mode::Hold => Some(self.hold_min),
            Mode::Auto => Some(self.auto_hold),
            Mode::Tap => None,
        }
    }

    /// When hold / auto mode wants a `Tick` (the key has been down alone this long), None otherwise. Tap mode wants one
    /// at `tap_max` too: a press held past it is said while the key is still down (`HeldInTapMode`), so the user lets go
    /// before talking into a take that won't start.
    pub fn deadline(&self) -> Option<f64> {
        if let (
            Some(h),
            State::Down {
                at, clean: true, ..
            },
        ) = (self.hold_threshold(), self.state)
        {
            if !self.active {
                return Some(at + h);
            }
        }
        if self.mode == Mode::Tap && !self.held_miss_said {
            if let State::Down {
                at, clean: true, ..
            } = self.state
            {
                if !self.active && !self.press_quiet {
                    return Some(at + self.tap_max);
                }
            }
        }
        None
    }

    /// The key is down alone and nothing has started yet: what `Arm` said may still become a `Start`. The app opens the
    /// microphone on `Arm` (so the first words aren't lost while the trigger waits for the key to come up) and closes it
    /// again as soon as this turns false without a start — the press became a shortcut (Alt+←, Alt+A), a click joined
    /// in, or it was let go too early or too late.
    pub fn armed_down(&self) -> bool {
        match self.state {
            State::Down { clean, .. } => clean && !self.active && !self.press_quiet,
            _ => false,
        }
    }

    /// The dictation ended or was started some other way (a menu, the island, a time limit), or the app couldn't start
    /// the one the trigger asked for. `keep_tap`: the tap that asked is still the first of a double tap (a start refused
    /// because a recording has the mic still lets the second tap send — Return needs no mic).
    pub fn reset(&mut self, active: bool, keep_tap: bool) {
        self.active = active;
        self.push_to_talk = false;
        self.shift_down_at = None;
        self.command_down_at = None;
        self.modifier_last_tap = None;
        self.modifier_cooldown_until = 0.0;
        self.quick_stop = false;
        self.start_tap_up = None;
        if !keep_tap {
            self.last_tap = None;
        }
        self.second = None;
        self.quiet_until = None;
        if !active {
            self.settle();
        }
    }

    /// The take ended by itself (the time limit) at `t`: the user's next tap, while the island still says so, was meant
    /// as its stop — it does nothing instead of starting a new take (v0.9 dogfood: a tap 2–4 s later started one under
    /// "dictation ended", listening ears and that line at once).
    pub fn ended_by_itself(&mut self, t: f64) {
        self.reset(false, false);
        self.quiet_until = Some(t + Self::LIMIT_GRACE);
    }

    /// The modifiers the system says are down (GetAsyncKeyState, VK codes), for when the hook may have missed a key-up
    /// (the secure desktop after Win+L or a UAC prompt takes the keyboard): a modifier the trigger still thinks is
    /// held would make every press "not alone". The Mac's flags carried this with every event.
    pub fn sync_modifiers(&mut self, down: &[u32]) {
        self.held = down
            .iter()
            .filter_map(|&c| mod_bit(c))
            .fold(0, |a, b| a | b);
    }

    /// A cancel that is a shortcut, not a cancelled dictation: another key (not Esc) or a click joined push-to-talk
    /// within its first second, before any piece of it was cut for transcription — said quietly (no "Cancelled").
    pub fn joined_early(esc: bool, listening: bool, elapsed: f64, final_pieces: usize) -> bool {
        !esc && listening && elapsed < 1.0 && final_pieces == 0
    }

    /// Not dictating any more: a key still held is waited out (its release must not start or stop anything).
    fn settle(&mut self) {
        if self.state == State::Holding {
            self.state = State::WaitRelease;
        } else if let State::Down { .. } = self.state {
            self.state = State::Idle;
        }
    }

    pub fn handle(&mut self, e: Event) -> Vec<Output> {
        match e {
            Event::Key {
                code,
                down,
                time: t,
            } => {
                if let Some(bit) = mod_bit(code) {
                    // a modifier's auto-repeat: nothing changed (the Mac's flagsChanged comes only on a change)
                    if down && self.held & bit != 0 {
                        return vec![];
                    }
                    if down {
                        self.held |= bit;
                    } else {
                        self.held &= !bit;
                    }
                    return self.flags_changed(code, t);
                }
                if !down {
                    return vec![];
                }
                self.key_down_other(code, t)
            }
            Event::MouseDown { time } => self.other_input(time),
            Event::IslandClick { .. } => {
                if self.active {
                    vec![Output::Style]
                } else {
                    vec![]
                }
            }
            Event::IslandTranslateClick { .. } => {
                if self.active {
                    vec![Output::Translate]
                } else {
                    vec![]
                }
            }
            Event::Tick { time } => self.tick(time),
        }
    }

    /// A modifier changed: the Mac's flagsChanged.
    fn flags_changed(&mut self, code: u32, t: f64) -> Vec<Output> {
        if code == vk::LSHIFT || code == vk::RSHIFT {
            return self.shift_changed(self.held & M_SHIFT != 0, t);
        }
        if (code == vk::LCONTROL || code == vk::RCONTROL)
            && self.active
            && (self.state == State::Holding || self.state == State::Idle)
        {
            return self.command_changed(self.held & M_CTRL != 0, t);
        }
        if self.key.codes().contains(&code) {
            // either Alt: the other side going down or up while one is held is another key, not this one
            if let State::Down { code: held, .. } = self.state {
                if held != code {
                    return self.other_input(t);
                }
            }
            if self.state == State::Holding && self.holding_code != code {
                return self.other_input(t);
            }
            return if self.held & Key::down_mask(code) != 0 {
                self.key_down(code, t)
            } else {
                self.key_up(t)
            };
        }
        self.other_input(t)
    }

    /// A key that isn't a modifier went down.
    fn key_down_other(&mut self, code: u32, t: f64) -> Vec<Output> {
        if code == vk::ESCAPE && self.active {
            self.active = false;
            self.push_to_talk = false;
            self.last_tap = None;
            self.start_tap_up = None;
            self.settle();
            return vec![Output::Cancel];
        }
        // the take on its way (transcribing, polishing, pasting): Esc throws it away
        if code == vk::ESCAPE && self.pending && self.state == State::Idle {
            self.last_tap = None;
            return vec![Output::Cancel];
        }
        self.other_input(t)
    }

    fn key_down(&mut self, code: u32, t: f64) -> Vec<Output> {
        if self.state == State::Holding || self.state == State::WaitRelease {
            return vec![]; // a repeat of what we know
        }
        if let State::Down { code: held, .. } = self.state {
            if held == code {
                return vec![]; // the same press reported again
            }
        }
        let alone = self.held & Key::other_mods(code) == 0;
        self.state = State::Down {
            at: t,
            clean: alone,
            code,
        };
        self.held_miss_said = false;
        self.holding_code = code;
        self.second = None;
        self.shift_down_at = None; // the key joined a Shift that was down: no toggle when Shift comes up
        self.command_down_at = None; // … nor a Ctrl
        self.modifier_last_tap = None;
        self.miss = None;
        let bounce = self
            .last_tap
            .is_some_and(|(did, up)| did == TapDid::Sent && t - up <= self.double_tap_window);
        let after_end = self.quiet_until.is_some_and(|q| t < q);
        self.quiet_until = None;
        self.press_quiet = alone && !self.active && (bounce || after_end);
        self.press_after_end = self.press_quiet && after_end;
        if self.double_tap && alone && !self.press_quiet {
            if let Some((did, up)) = self.last_tap {
                if t - up <= self.double_tap_window {
                    self.second = Some(did);
                }
            }
        }
        self.last_tap = None;
        // a second tap can only send (or cancel the dictation the first one started): no mic for it; nor for a press
        // that only ends a bounce
        if self.second.is_some() || self.press_quiet {
            return vec![];
        }
        if alone && !self.active {
            vec![Output::Arm]
        } else {
            vec![]
        }
    }

    /// How long a press may last and still be a tap.
    fn tap_limit(&self) -> f64 {
        match self.mode {
            Mode::Tap => self.tap_max,
            Mode::Auto => self.auto_hold,
            Mode::Hold => self.hold_min,
        }
    }

    fn key_up(&mut self, t: f64) -> Vec<Output> {
        let was = self.state;
        self.state = State::Idle;
        let first = self.second.take();
        let (quiet, after_end) = (self.press_quiet, self.press_after_end);
        self.press_quiet = false;
        self.press_after_end = false;
        self.quick_stop = false;
        let clean_tap =
            matches!(was, State::Down { at, clean: true, .. } if t - at <= self.tap_limit());
        // the second tap of a double tap: send (cancelling the dictation the first one started)
        if let Some(f) = first {
            if clean_tap {
                if f == TapDid::Started && self.active {
                    self.active = false;
                    self.push_to_talk = false;
                    self.start_tap_up = None;
                    self.last_tap = Some((TapDid::Sent, t));
                    return vec![Output::Cancel, Output::Send];
                }
                // push-to-talk was just let go: this is the double tap's first tap
                if f == TapDid::Released {
                    self.last_tap = Some((TapDid::Nothing, t));
                    return vec![];
                }
                self.last_tap = Some((TapDid::Sent, t));
                return vec![Output::Send];
            }
        }
        // a tap soon after a send, or right after a take ended by itself: nothing (after the end it can still be a
        // double tap's first one)
        if quiet && clean_tap {
            if after_end {
                self.last_tap = Some((TapDid::Nothing, t));
            }
            return vec![];
        }
        match (self.mode, was) {
            (Mode::Tap, State::Down { at, clean, .. }) => {
                if !(clean && t - at <= self.tap_max) {
                    if clean && !self.active && !self.held_miss_said {
                        self.miss = Some(Miss::HeldInTapMode);
                    }
                    return vec![];
                }
                self.active = !self.active;
                self.last_tap = Some((
                    if self.active {
                        TapDid::Started
                    } else {
                        TapDid::Stopped
                    },
                    t,
                ));
                if self.active {
                    self.start_tap_up = Some(t);
                } else {
                    self.stopped(at);
                }
                vec![if self.active {
                    Output::Start
                } else {
                    Output::Stop
                }]
            }
            (Mode::Auto, State::Down { at, clean, .. }) => {
                if !clean {
                    return vec![];
                }
                if self.active {
                    // hands-free: the next clean press stops it, however long
                    self.active = false;
                    self.push_to_talk = false;
                    self.last_tap = Some((TapDid::Stopped, t));
                    if t - at <= self.tap_limit() {
                        self.stopped(at);
                    } else {
                        self.start_tap_up = None;
                        self.shift_down_at = None;
                    }
                    return vec![Output::Stop];
                }
                if t - at >= self.auto_hold {
                    return vec![]; // held past the threshold with no tick: never started
                }
                self.active = true;
                self.push_to_talk = false;
                self.start_tap_up = Some(t);
                self.last_tap = Some((TapDid::Started, t));
                vec![Output::Start]
            }
            (Mode::Hold, State::Holding) | (Mode::Auto, State::Holding) => {
                self.active = false;
                self.push_to_talk = false;
                self.shift_down_at = None;
                self.start_tap_up = None;
                self.last_tap = Some((TapDid::Released, t));
                vec![Output::Stop]
            }
            (Mode::Hold, State::Down { at, clean, .. }) => {
                // let go before 250 ms: nothing said — but it can be the first tap of a double tap
                if clean && t - at < self.hold_min {
                    self.last_tap = Some((TapDid::Nothing, t));
                    self.miss = Some(Miss::TappedInHoldMode);
                }
                vec![]
            }
            _ => vec![], // a dirty tap, a release we wait out
        }
    }

    /// A hands-free dictation stopped by a tap that went down at `at`: a near miss of a double tap when that was soon
    /// after the start tap came up.
    fn stopped(&mut self, at: f64) {
        self.shift_down_at = None;
        if let Some(up) = self.start_tap_up {
            if at - up <= self.near_miss_window && self.double_tap {
                self.quick_stop = true;
            }
        }
        self.start_tap_up = None;
    }

    /// Another key, modifier or click: a tap in progress is no longer clean; push-to-talk is cancelled. Nor is the next
    /// tap the second of a double tap (or a near miss of one).
    fn other_input(&mut self, t: f64) -> Vec<Output> {
        self.last_tap = None;
        self.start_tap_up = None;
        self.shift_down_at = None; // Shift with another key: a shortcut (or a capital), not the style toggle
        self.command_down_at = None; // Ctrl with another key (Ctrl+V): a shortcut, not the translate toggle
        self.modifier_last_tap = None;
        match self.state {
            State::Down { at, code, .. } => {
                if self.hold_threshold().is_some() {
                    if let Some(mut out) = self.hold_if_due(at, t) {
                        // held long enough: started, and now joined
                        out.extend(self.other_input(t));
                        return out;
                    }
                }
                self.state = State::Down {
                    at,
                    clean: false,
                    code,
                };
                vec![]
            }
            State::Holding => {
                self.state = State::WaitRelease;
                self.active = false;
                self.push_to_talk = false;
                vec![Output::Cancel]
            }
            _ => vec![],
        }
    }

    fn tick(&mut self, t: f64) -> Vec<Output> {
        if self.mode == Mode::Tap && !self.held_miss_said && !self.press_quiet {
            if let State::Down {
                at, clean: true, ..
            } = self.state
            {
                if !self.active && t - at > self.tap_max {
                    self.held_miss_said = true;
                    self.miss = Some(Miss::HeldInTapMode);
                    return vec![];
                }
            }
        }
        match (self.hold_threshold(), self.state) {
            (
                Some(_),
                State::Down {
                    at, clean: true, ..
                },
            ) if !self.active => self.hold_if_due(at, t).unwrap_or_default(),
            _ => vec![],
        }
    }

    /// Hold / auto mode: the key has been down alone for the threshold by `t` → push-to-talk starts (the other input,
    /// if any, came later).
    fn hold_if_due(&mut self, at: f64, t: f64) -> Option<Vec<Output>> {
        let h = self.hold_threshold()?;
        let State::Down { clean: true, .. } = self.state else {
            return None;
        };
        if self.active || t - at < h {
            return None;
        }
        self.state = State::Holding;
        self.press_quiet = false;
        self.active = true;
        self.push_to_talk = true;
        self.second = None;
        Some(vec![Output::Start])
    }

    /// Shift went down or up. While dictating, alone (`modifier_changed`): the style toggle (push-to-talk is not
    /// cancelled by it). Otherwise Shift is any other modifier.
    fn shift_changed(&mut self, down: bool, t: f64) -> Vec<Output> {
        if self.active && (self.state == State::Holding || self.state == State::Idle) {
            return self.modifier_changed(
                Toggle::Shift,
                down,
                t,
                Output::Style,
                self.modifier_tap_shift,
            );
        }
        if self.state == State::WaitRelease {
            return vec![];
        }
        self.other_input(t)
    }

    /// Ctrl went down or up while dictating (hands-free or push-to-talk): alone and let go within `shift_tap_max`, the
    /// translate toggle. A key while it is down makes it a shortcut (`other_input`).
    fn command_changed(&mut self, down: bool, t: f64) -> Vec<Output> {
        if self.active && (self.state == State::Holding || self.state == State::Idle) {
            return self.modifier_changed(
                Toggle::Command,
                down,
                t,
                Output::Translate,
                self.modifier_tap_command,
            );
        }
        if self.state == State::WaitRelease {
            return vec![];
        }
        self.other_input(t)
    }

    /// The shared logic for Shift and Ctrl while dictating — and for a voice note's Shift (the Mac's `LoneShift` mirrors
    /// it): a single tap (its release fires) or a double tap within `modifier_double_tap_window` (the second press
    /// fires), with a `modifier_cooldown` after a fire. The press time is kept either way so a Shift+Ctrl chord reads as
    /// neither (a chord clears the tap in progress rather than being counted as its first tap).
    fn modifier_changed(
        &mut self,
        which: Toggle,
        down: bool,
        t: f64,
        output: Output,
        tap: ModifierTap,
    ) -> Vec<Output> {
        if down {
            self.last_tap = None;
            self.start_tap_up = None;
            // chord with the other modifier already down: neither toggle
            let other_down = match which {
                Toggle::Shift => self.command_down_at.take().is_some(),
                Toggle::Command => self.shift_down_at.take().is_some(),
            };
            if other_down {
                self.modifier_last_tap = None;
                return vec![];
            }
            match which {
                Toggle::Shift => self.shift_down_at = Some(t),
                Toggle::Command => self.command_down_at = Some(t),
            }
            match tap {
                ModifierTap::Single => self.modifier_last_tap = None,
                ModifierTap::Double => {
                    if t < self.modifier_cooldown_until {
                        self.modifier_last_tap = None;
                        return vec![];
                    }
                    if let Some((k, at)) = self.modifier_last_tap {
                        if k == which && t - at <= self.modifier_double_tap_window {
                            // the second tap's down: fire now (its release will come soon; no need to wait for it)
                            self.modifier_last_tap = None;
                            self.modifier_cooldown_until = t + self.modifier_cooldown;
                            return vec![output];
                        }
                    }
                    self.modifier_last_tap = Some((which, t));
                }
            }
            return vec![];
        }
        // up
        let d = match which {
            Toggle::Shift => self.shift_down_at.take(),
            Toggle::Command => self.command_down_at.take(),
        };
        match d {
            Some(d) if tap == ModifierTap::Single && t - d <= self.shift_tap_max => vec![output],
            _ => vec![],
        }
    }

    /// A compact script of events for tests (and a test hook), one token per event, times in ms:
    /// "ralt-down@0 ralt-up@120", "ralt-down@0 tick@300 ralt-up@900", "ralt-down@0 key:65@50 ralt-up@90", "click@40",
    /// "island@40" (a click on Blurt's island), "island-translate@40" (on its left half), "esc@500",
    /// "shift-down@0 shift-up@10". Modifier tokens: ralt, lalt, shift, rshift, ctrl, rctrl, win, rwin. `key:N` is a
    /// key-down of virtual-key code N (decimal).
    pub fn parse(script: &str) -> Vec<Event> {
        let mut out = vec![];
        for tok in script.split(' ').filter(|s| !s.is_empty()) {
            let parts: Vec<&str> = tok.split('@').collect();
            let [name, ms] = parts[..] else { continue };
            let Ok(ms) = ms.parse::<f64>() else { continue };
            let t = ms / 1000.0;
            match name {
                "tick" => out.push(Event::Tick { time: t }),
                "click" => out.push(Event::MouseDown { time: t }),
                "island" => out.push(Event::IslandClick { time: t }),
                "island-translate" => out.push(Event::IslandTranslateClick { time: t }),
                "esc" => out.push(Event::Key {
                    code: vk::ESCAPE,
                    down: true,
                    time: t,
                }),
                _ => {
                    if let Some(c) = name
                        .strip_prefix("key:")
                        .and_then(|c| c.parse::<u32>().ok())
                    {
                        out.push(Event::Key {
                            code: c,
                            down: true,
                            time: t,
                        });
                        continue;
                    }
                    let mp: Vec<&str> = name.split('-').collect();
                    let [m, dir] = mp[..] else { continue };
                    let code = match m {
                        "ralt" => vk::RMENU,
                        "lalt" => vk::LMENU,
                        "shift" => vk::LSHIFT,
                        "rshift" => vk::RSHIFT,
                        "ctrl" => vk::LCONTROL,
                        "rctrl" => vk::RCONTROL,
                        "win" => vk::LWIN,
                        "rwin" => vk::RWIN,
                        _ => continue,
                    };
                    out.push(Event::Key {
                        code,
                        down: dir == "down",
                        time: t,
                    });
                }
            }
        }
        out
    }

    /// Runs a script; the outputs in order (ticks are delivered only where the script has them).
    pub fn run(&mut self, script: &str) -> Vec<Output> {
        Self::parse(script)
            .into_iter()
            .flat_map(|e| self.handle(e))
            .collect()
    }
}

/// When a hook event happened, on the caller's clock (`now`, seconds), from its own `time` (KBDLLHOOKSTRUCT /
/// MSLLHOOKSTRUCT, GetTickCount milliseconds) and GetTickCount at handling (`now_tick`): the trigger's windows are a few
/// hundred ms, and the thread can get to an event late (the mic opening on the key-down), so the event's own time
/// counts, not when it was handled. The tick wraps every 49.7 days (the difference is taken modulo 2³²). A reading
/// within the last two seconds (or up to 50 ms ahead) is it; otherwise (0, a synthetic event, nonsense) → `now`.
pub fn event_time(tick_ms: u32, now_tick_ms: u32, now: f64) -> f64 {
    if tick_ms == 0 {
        return now;
    }
    let age = now_tick_ms.wrapping_sub(tick_ms) as i32 as f64 / 1000.0;
    if age >= -0.05 && age < 2.0 {
        now - age
    } else {
        now
    }
}

/// The same for a time already in seconds on the caller's clock: used when it is plausible.
pub fn event_time_seconds(seconds: f64, now: f64) -> f64 {
    if seconds > 0.0 && seconds <= now + 0.05 && now - seconds < 2.0 {
        seconds
    } else {
        now
    }
}

#[cfg(test)]
mod tests {
    //! DictationTriggerTests.swift, key for key: Fn → right Alt (the default), right ⌥ → right Alt, left ⌥ → left Alt,
    //! ⌘ → Ctrl, Fn as "another modifier" → Win; key codes: ← 123 → VK_LEFT 37, A 0 → 65, V 9 → 86, H 4 → 72.
    use super::Output::*;
    use super::*;

    fn run_with(script: &str, key: Key, mode: Mode) -> Vec<Output> {
        DictationTrigger::new(key, mode).run(script)
    }
    /// the Swift tests' `run`: right Alt, tap mode
    fn run(script: &str) -> Vec<Output> {
        run_with(script, Key::RightAlt, Mode::Tap)
    }
    fn run_mode(script: &str, mode: Mode) -> Vec<Output> {
        run_with(script, Key::RightAlt, mode)
    }
    fn either(script: &str, mode: Mode) -> Vec<Output> {
        run_with(script, Key::EitherAlt, mode)
    }
    fn auto(script: &str) -> Vec<Output> {
        run_with(script, Key::RightAlt, Mode::Auto)
    }

    // MARK: tap mode

    #[test]
    fn tap_starts_and_tap_stops() {
        assert_eq!(run("ralt-down@0 ralt-up@120"), [Arm, Start]);
        assert_eq!(
            run("ralt-down@0 ralt-up@120 ralt-down@3000 ralt-up@3100"),
            [Arm, Start, Stop]
        );
    }

    #[test]
    fn slow_press_is_not_a_tap() {
        assert_eq!(run("ralt-down@0 ralt-up@450"), [Arm]);
        assert_eq!(run("ralt-down@0 ralt-up@400"), [Arm, Start]);
    }

    #[test]
    fn alt_as_a_modifier_never_triggers() {
        assert_eq!(run("ralt-down@0 key:65@60 ralt-up@120"), [Arm]); // Alt+A
        assert_eq!(
            run("ralt-down@0 shift-down@30 key:86@60 shift-up@80 ralt-up@100"),
            [Arm]
        ); // Alt+Shift+V
        assert_eq!(run("shift-down@0 ralt-down@20 ralt-up@90 shift-up@120"), []); // Shift held first
        assert_eq!(run("ctrl-down@0 ralt-down@20 ralt-up@90 ctrl-up@120"), []);
        assert_eq!(run("ralt-down@0 click@50 ralt-up@100"), [Arm]); // Alt-click
    }

    #[test]
    fn left_alt_does_nothing() {
        assert_eq!(run("lalt-down@0 lalt-up@100"), []);
        assert_eq!(run("lalt-down@0 ralt-down@10 ralt-up@80 lalt-up@90"), []); // both Alts held
    }

    #[test]
    fn escape_cancels() {
        assert_eq!(run("ralt-down@0 ralt-up@100 esc@900"), [Arm, Start, Cancel]);
        assert_eq!(run("esc@100"), []); // not dictating
                                        // after a cancel the next tap starts again
        assert_eq!(
            run("ralt-down@0 ralt-up@100 esc@900 ralt-down@2000 ralt-up@2100"),
            [Arm, Start, Cancel, Arm, Start]
        );
    }

    #[test]
    fn typing_while_dictating_does_not_stop() {
        assert_eq!(
            run("ralt-down@0 ralt-up@100 key:72@500 click@700 ralt-down@900 ralt-up@1000"),
            [Arm, Start, Stop]
        );
    }

    #[test]
    fn reset_from_outside() {
        let mut t = DictationTrigger::new(Key::RightAlt, Mode::Tap);
        assert_eq!(t.run("ralt-down@0 ralt-up@100"), [Arm, Start]);
        t.reset(false, false); // the app ended it (time limit, the island's button)
        assert_eq!(t.run("ralt-down@2000 ralt-up@2100"), [Arm, Start]);
    }

    /// testFnKey, with right Alt as the key (no Fn on Windows): left Alt is "another" key here.
    #[test]
    fn right_alt_key() {
        assert_eq!(run_mode("ralt-down@0 ralt-up@100", Mode::Tap), [Arm, Start]);
        assert_eq!(run_mode("lalt-down@0 lalt-up@100", Mode::Tap), []);
        assert_eq!(
            run_mode("ralt-down@0 key:37@50 ralt-up@100", Mode::Tap),
            [Arm]
        ); // Alt+←
        assert_eq!(
            run_mode("lalt-down@0 ralt-down@10 ralt-up@80 lalt-up@90", Mode::Tap),
            []
        ); // left Alt held
    }

    // MARK: the default: right Alt, auto

    #[test]
    fn default_is_right_alt_auto() {
        assert_eq!(DictationTrigger::default().key, Key::RightAlt);
        assert_eq!(DictationTrigger::default().mode, Mode::Auto);
        assert_eq!(Key::ALL[0], Key::RightAlt); // the default first in every picker
        assert_eq!(Mode::ALL[0], Mode::Auto);
        assert_eq!(Key::from_config("either_option"), Some(Key::EitherAlt));
        assert_eq!(Key::from_config("right_option"), Some(Key::RightAlt)); // an explicit choice stays
        assert_eq!(Key::from_config("fn"), Some(Key::RightAlt)); // the Mac's default: no Fn here
        assert_eq!(
            Key::from_config(Key::EitherAlt.as_str()),
            Some(Key::EitherAlt)
        );
        assert_eq!(Mode::from_config("hold"), Some(Mode::Hold));
    }

    // MARK: auto mode (tap = hands-free, hold = push-to-talk)

    #[test]
    fn auto_tap_is_hands_free() {
        let mut t = DictationTrigger::default();
        assert_eq!(t.run("ralt-down@0"), [Arm]);
        assert_eq!(t.deadline(), Some(0.3)); // asks for a tick at the hold threshold
        assert_eq!(t.run("ralt-up@120"), [Start]);
        assert!(t.active());
        assert!(!t.push_to_talk());
        assert_eq!(t.deadline(), None); // no hold while hands-free
        assert_eq!(t.run("key:72@500 click@700"), []); // typing / clicking doesn't stop it
        assert_eq!(t.run("ralt-down@3000 ralt-up@3100"), [Stop]);
        assert!(!t.active());
    }

    #[test]
    fn auto_hold_is_push_to_talk() {
        let mut t = DictationTrigger::default();
        assert_eq!(t.run("ralt-down@0 tick@300"), [Arm, Start]);
        assert!(t.push_to_talk());
        assert_eq!(t.run("ralt-up@2500"), [Stop]);
        assert!(!t.push_to_talk());
        // the next short tap is hands-free again
        assert_eq!(t.run("ralt-down@4000 ralt-up@4100"), [Arm, Start]);
        assert!(!t.push_to_talk());
    }

    #[test]
    fn auto_boundary() {
        assert_eq!(auto("ralt-down@0 tick@299 ralt-up@299"), [Arm, Start]); // under 300 ms: a tap
        assert_eq!(auto("ralt-down@0 tick@300 ralt-up@310"), [Arm, Start, Stop]); // at 300 ms: push-to-talk
        assert_eq!(auto("ralt-down@0 ralt-up@450"), [Arm]); // long, no tick delivered: nothing
    }

    /// `armed_down`: the app opens the mic on `Arm` and closes it once the press can no longer start a dictation.
    #[test]
    fn armed_down_says_when_the_press_can_still_start() {
        fn states(script: &str, mode: Mode) -> Vec<bool> {
            let mut t = DictationTrigger::new(Key::RightAlt, mode);
            DictationTrigger::parse(script)
                .into_iter()
                .map(|e| {
                    t.handle(e);
                    t.armed_down()
                })
                .collect()
        }
        let a = Mode::Auto;
        assert_eq!(states("ralt-down@0 ralt-up@100", a), [true, false]); // a tap: started at the key-up
        assert_eq!(
            states("ralt-down@0 tick@300 ralt-up@900", a),
            [true, false, false]
        ); // held: started at the tick
        assert_eq!(
            states("ralt-down@0 key:37@50 ralt-up@100", a),
            [true, false, false]
        ); // Alt+←: the mic closes at once
        assert_eq!(
            states("ralt-down@0 click@40 ralt-up@90", a),
            [true, false, false]
        );
        assert_eq!(states("ralt-down@0 ralt-up@450", a), [true, false]); // too long, no tick: closes
        assert_eq!(
            states("ctrl-down@0 ralt-down@10 ralt-up@60 ctrl-up@90", a),
            [false, false, false, false]
        ); // never armed
        assert_eq!(
            states("ralt-down@0 ralt-up@100 ralt-down@1000 ralt-up@1100", a),
            [true, false, false, false]
        ); // the stop press isn't an arm
        assert_eq!(
            states("ralt-down@0 tick@250 ralt-up@400", Mode::Hold),
            [true, false, false]
        );
        assert_eq!(states("ralt-down@0 ralt-up@100", Mode::Hold), [true, false]);
        // let go before 250 ms
    }

    #[test]
    fn auto_stops_hands_free_with_a_long_press_too() {
        assert_eq!(
            auto("ralt-down@0 ralt-up@100 ralt-down@2000 ralt-up@2900"),
            [Arm, Start, Stop]
        );
    }

    #[test]
    fn auto_ignores_shortcuts_and_cancels() {
        assert_eq!(auto("ralt-down@0 key:37@50 ralt-up@100"), [Arm]); // Alt+←
        assert_eq!(
            auto("ralt-down@0 tick@300 key:37@500 ralt-up@600"),
            [Arm, Start, Cancel]
        ); // joined while held
        assert_eq!(auto("ctrl-down@0 ralt-down@10 ralt-up@60 ctrl-up@90"), []); // Ctrl held first
        assert_eq!(
            auto("ralt-down@0 ralt-up@100 esc@900"),
            [Arm, Start, Cancel]
        );
        assert_eq!(
            auto("ralt-down@0 tick@300 esc@600 ralt-up@900"),
            [Arm, Start, Cancel]
        ); // release waited out
           // a stop press that turned into a shortcut doesn't stop
        assert_eq!(
            auto("ralt-down@0 ralt-up@100 ralt-down@1000 key:37@1050 ralt-up@1100"),
            [Arm, Start]
        );
    }

    #[test]
    fn auto_with_right_alt() {
        assert_eq!(auto("ralt-down@0 ralt-up@100"), [Arm, Start]);
        assert_eq!(auto("ralt-down@0 key:65@60 ralt-up@120"), [Arm]); // Alt+A
    }

    #[test]
    fn reset_ends_push_to_talk() {
        let mut t = DictationTrigger::default();
        assert_eq!(t.run("ralt-down@0 tick@300"), [Arm, Start]);
        t.reset(false, false); // the app ended it (time limit)
        assert!(!t.push_to_talk());
        assert_eq!(t.run("ralt-up@900"), []); // its release is waited out
    }

    // MARK: either Alt

    #[test]
    fn either_alt_taps_with_left_or_right() {
        assert_eq!(either("lalt-down@0 lalt-up@100", Mode::Tap), [Arm, Start]);
        assert_eq!(either("ralt-down@0 ralt-up@100", Mode::Tap), [Arm, Start]);
        // start with the left one, stop with the right one
        assert_eq!(
            either(
                "lalt-down@0 lalt-up@100 ralt-down@2000 ralt-up@2100",
                Mode::Tap
            ),
            [Arm, Start, Stop]
        );
    }

    #[test]
    fn either_alt_still_ignores_shortcuts() {
        let m = Mode::Tap;
        assert_eq!(either("lalt-down@0 key:65@60 lalt-up@120", m), [Arm]); // Alt+A
        assert_eq!(
            either(
                "lalt-down@0 shift-down@30 key:86@60 shift-up@80 lalt-up@100",
                m
            ),
            [Arm]
        ); // Alt+Shift+V
        assert_eq!(
            either("ctrl-down@0 lalt-down@20 lalt-up@90 ctrl-up@120", m),
            []
        );
        assert_eq!(either("lalt-down@0 click@50 lalt-up@100", m), [Arm]); // Alt-click
        assert_eq!(
            either("lalt-down@0 win-down@20 win-up@40 lalt-up@90", m),
            [Arm]
        ); // the Mac's Fn: Win here
    }

    #[test]
    fn either_alt_both_sides_at_once_is_not_a_tap() {
        let m = Mode::Tap;
        assert_eq!(
            either("lalt-down@0 ralt-down@10 ralt-up@80 lalt-up@90", m),
            [Arm]
        );
        assert_eq!(
            either("ralt-down@0 lalt-down@10 ralt-up@80 lalt-up@90", m),
            [Arm]
        );
        // and the next clean tap works again
        assert_eq!(
            either(
                "lalt-down@0 ralt-down@10 ralt-up@80 lalt-up@90 lalt-down@500 lalt-up@600",
                m
            ),
            [Arm, Arm, Start]
        );
    }

    #[test]
    fn either_alt_hold() {
        assert_eq!(
            either("lalt-down@0 tick@260 lalt-up@1000", Mode::Hold),
            [Arm, Start, Stop]
        );
        assert_eq!(
            either(
                "lalt-down@0 tick@260 ralt-down@500 ralt-up@550 lalt-up@1000",
                Mode::Hold
            ),
            [Arm, Start, Cancel]
        );
    }

    #[test]
    fn right_alt_still_ignores_left() {
        assert_eq!(run("lalt-down@0 lalt-up@100"), []);
        assert_eq!(auto("lalt-down@0 lalt-up@100"), []);
    }

    // MARK: hold mode

    #[test]
    fn hold_starts_after_threshold_and_release_stops() {
        let mut t = DictationTrigger::new(Key::RightAlt, Mode::Hold);
        assert_eq!(t.run("ralt-down@0"), [Arm]);
        assert_eq!(t.deadline(), Some(0.25));
        assert_eq!(t.run("tick@250"), [Start]);
        assert_eq!(t.deadline(), None);
        assert_eq!(t.run("ralt-up@3000"), [Stop]);
    }

    #[test]
    fn hold_too_short_does_nothing() {
        assert_eq!(
            run_mode("ralt-down@0 tick@100 ralt-up@200", Mode::Hold),
            [Arm]
        );
    }

    #[test]
    fn hold_cancels_when_another_key_joins() {
        let h = Mode::Hold;
        assert_eq!(
            run_mode("ralt-down@0 tick@260 key:65@900 ralt-up@1000", h),
            [Arm, Start, Cancel]
        );
        // Shift with a key is a shortcut: cancelled; Shift alone twice is the style toggle (double_tap_shift)
        assert_eq!(
            run_mode(
                "ralt-down@0 tick@260 shift-down@900 key:65@920 shift-up@950 ralt-up@1000",
                h
            ),
            [Arm, Start, Cancel]
        );
        assert_eq!(
            run_mode(
                "ralt-down@0 tick@260 shift-down@900 shift-up@950 ralt-up@1000",
                h
            ),
            [Arm, Start, Style, Stop]
        );
        // a key before the threshold: a shortcut, never a start
        assert_eq!(
            run_mode("ralt-down@0 key:65@100 tick@260 ralt-up@400", h),
            [Arm]
        );
    }

    #[test]
    fn hold_starts_on_late_input_without_tick() {
        // no tick delivered, but the key was alone for 300 ms when the click came: started, then cancelled by it
        assert_eq!(
            run_mode("ralt-down@0 click@300 ralt-up@500", Mode::Hold),
            [Arm, Start, Cancel]
        );
    }

    #[test]
    fn hold_escape() {
        assert_eq!(
            run_mode("ralt-down@0 tick@260 esc@600 ralt-up@900", Mode::Hold),
            [Arm, Start, Cancel]
        );
    }

    // MARK: double tap = Return (send)

    #[test]
    fn single_tap_still_starts_at_once() {
        // nothing waits for a second tap: the first one starts as it always did
        assert_eq!(auto("ralt-down@0 ralt-up@100"), [Arm, Start]);
        assert_eq!(
            auto("ralt-down@0 ralt-up@100 ralt-down@3000 ralt-up@3100"),
            [Arm, Start, Stop]
        );
    }

    #[test]
    fn double_tap_when_idle_cancels_and_sends() {
        // the first tap started a dictation; the second, 120 ms after its release, cancels it and sends
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 ralt-down@210 ralt-up@290"),
            [Arm, Start, Cancel, Send]
        );
        assert_eq!(
            run("ralt-down@0 ralt-up@90 ralt-down@200 ralt-up@280"),
            [Arm, Start, Cancel, Send]
        ); // tap mode
           // too slow for a double tap (the default window is 0.5 s): an ordinary stop
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 ralt-down@620 ralt-up@700"),
            [Arm, Start, Stop]
        );
        // the window is from the first release to the second press
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 ralt-down@580 ralt-up@660"),
            [Arm, Start, Cancel, Send]
        );
        // the audit's slow double tap (320 ms between the release and the next press) is one now
        assert_eq!(
            auto("ralt-down@0 ralt-up@120 ralt-down@440 ralt-up@560"),
            [Arm, Start, Cancel, Send]
        );
        // a triple tap: the third starts afresh
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 ralt-down@200 ralt-up@280 ralt-down@1500 ralt-up@1600"),
            [Arm, Start, Cancel, Send, Arm, Start]
        );
    }

    #[test]
    fn double_tap_while_dictating_stops_then_sends() {
        let mut t = DictationTrigger::default();
        assert_eq!(t.run("ralt-down@0 ralt-up@100"), [Arm, Start]);
        // dictating… the first tap stops (the paste starts at once), the second sends — no mic for it
        assert_eq!(t.run("ralt-down@5000 ralt-up@5080"), [Stop]);
        assert_eq!(t.run("ralt-down@5200"), []);
        assert_eq!(t.run("ralt-up@5270"), [Send]);
        assert!(!t.active());
        // a stop press can be long (auto mode): the next quick tap still sends
        assert_eq!(
            auto("ralt-down@0 ralt-up@100 ralt-down@3000 ralt-up@3500 ralt-down@3600 ralt-up@3680"),
            [Arm, Start, Stop, Send]
        );
    }

    #[test]
    fn push_to_talk_then_double_tap_sends() {
        // hold to talk, let go (stop), double-tap at once: the first tap does nothing by itself, the second sends
        assert_eq!(
            auto("ralt-down@0 tick@300 ralt-up@2500 ralt-down@2700 ralt-up@2780"),
            [Arm, Start, Stop]
        );
        assert_eq!(
            auto("ralt-down@0 tick@300 ralt-up@2500 ralt-down@2700 ralt-up@2780 ralt-down@2900 ralt-up@2980"),
            [Arm, Start, Stop, Send]
        );
        // the same in hold mode
        assert_eq!(
            run_mode("ralt-down@0 tick@250 ralt-up@2000 ralt-down@2150 ralt-up@2220 ralt-down@2350 ralt-up@2420", Mode::Hold),
            [Arm, Start, Stop, Send]
        );
        // a tap long after the release is an ordinary start
        assert_eq!(
            auto("ralt-down@0 tick@300 ralt-up@2500 ralt-down@4000 ralt-up@4080"),
            [Arm, Start, Stop, Arm, Start]
        );
    }

    #[test]
    fn hold_mode_double_tap_sends() {
        let h = Mode::Hold;
        // taps start nothing in hold mode; two of them press Return
        assert_eq!(
            run_mode("ralt-down@0 ralt-up@100 ralt-down@250 ralt-up@330", h),
            [Arm, Send]
        );
        assert_eq!(
            run_mode("ralt-down@0 ralt-up@100 ralt-down@700 ralt-up@780", h),
            [Arm, Arm]
        );
        // holding the second press is push-to-talk as usual
        assert_eq!(
            run_mode(
                "ralt-down@0 ralt-up@100 ralt-down@250 tick@500 ralt-up@2000",
                h
            ),
            [Arm, Start, Stop]
        );
    }

    #[test]
    fn second_press_held_is_push_to_talk() {
        // after a stop, a press held past the threshold isn't a tap: it starts push-to-talk
        assert_eq!(
            auto("ralt-down@0 ralt-up@100 ralt-down@3000 ralt-up@3080 ralt-down@3200 tick@3510 ralt-up@5000"),
            [Arm, Start, Stop, Start, Stop]
        );
        // and while dictating, a long second press stops (no send)
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 ralt-down@200 ralt-up@800"),
            [Arm, Start, Stop]
        );
    }

    #[test]
    fn alt_with_another_key_is_never_a_double_tap() {
        // Alt+← between two taps: the second tap is an ordinary one
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 key:37@150 ralt-down@200 ralt-up@280"),
            [Arm, Start, Stop]
        );
        // the second press joined by a key (Alt+←): no send, the dictation goes on
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 ralt-down@200 key:37@230 ralt-up@280"),
            [Arm, Start]
        );
        // Ctrl held for the second press: not alone
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 ctrl-down@150 ralt-down@200 ralt-up@280 ctrl-up@300"),
            [Arm, Start]
        );
        // a click in between
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 click@150 ralt-down@200 ralt-up@280"),
            [Arm, Start, Stop]
        );
    }

    #[test]
    fn escape_between_taps_is_not_a_double_tap() {
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 esc@150 ralt-down@200 ralt-up@280"),
            [Arm, Start, Cancel, Arm, Start]
        );
    }

    #[test]
    fn double_tap_off() {
        let mut t = DictationTrigger::default();
        t.double_tap = false;
        assert_eq!(
            t.run("ralt-down@0 ralt-up@90 ralt-down@210 ralt-up@290"),
            [Arm, Start, Stop]
        );
        let mut h = DictationTrigger::new(Key::RightAlt, Mode::Hold);
        h.double_tap = false;
        assert_eq!(
            h.run("ralt-down@0 ralt-up@100 ralt-down@250 ralt-up@330"),
            [Arm, Arm]
        );
    }

    #[test]
    fn reset_forgets_the_first_tap() {
        let mut t = DictationTrigger::default();
        assert_eq!(t.run("ralt-down@0 ralt-up@90"), [Arm, Start]);
        t.reset(false, false); // the app ended it itself
        assert_eq!(t.run("ralt-down@200 ralt-up@280"), [Arm, Start]);
    }

    #[test]
    fn refused_start_keeps_the_double_tap() {
        // the app couldn't start (a recording has the mic, the mic failed): the second tap still sends — Return needs
        // no mic (dict031)
        let mut t = DictationTrigger::default();
        assert_eq!(t.run("ralt-down@0 ralt-up@90"), [Arm, Start]);
        t.reset(false, true);
        assert!(!t.active());
        assert_eq!(t.run("ralt-down@200 ralt-up@280"), [Send]);
    }

    #[test]
    fn double_tap_window_follows_double_click_interval() {
        assert_eq!(DictationTrigger::window(0.5), 0.5);
        assert_eq!(DictationTrigger::window(0.4), 0.4);
        assert_eq!(DictationTrigger::window(0.15), 0.3); // never under 0.3 s
        assert_eq!(DictationTrigger::window(5.0), 0.5); // never over 0.5 s
        let mut t = DictationTrigger::default();
        t.double_tap_window = 0.3;
        assert_eq!(
            t.run("ralt-down@0 ralt-up@90 ralt-down@420 ralt-up@500"),
            [Arm, Start, Stop]
        );
    }

    // MARK: pending (the last take is still being transcribed, polished or pasted)

    #[test]
    fn tap_while_pending_starts_the_next_take() {
        // dogfood: stop, then a tap 650 ms later (past the double-tap window) to say the next thought - it starts a
        // new take at once (the app pastes in order), instead of being swallowed while the last one is still typed
        let mut t = DictationTrigger::default();
        assert_eq!(t.run("ralt-down@0 ralt-up@80"), [Arm, Start]);
        assert_eq!(t.run("ralt-down@10000 ralt-up@10070"), [Stop]);
        t.pending = true; // the app: transcribing
        assert_eq!(t.run("ralt-down@10720"), [Arm]); // the mic opens on the key-down as usual
        assert!(t.armed_down());
        assert_eq!(t.run("ralt-up@10800"), [Start]);
        assert!(t.active());
        // held instead: push-to-talk, also while pending
        let mut h = DictationTrigger::default();
        h.pending = true;
        assert_eq!(
            h.run("ralt-down@0 tick@310 ralt-up@2000"),
            [Arm, Start, Stop]
        );
        // tap mode too
        let mut m = DictationTrigger::new(Key::RightAlt, Mode::Tap);
        m.pending = true;
        assert_eq!(m.run("ralt-down@0 ralt-up@90"), [Arm, Start]);
    }

    #[test]
    fn double_tap_after_stop_still_sends_while_pending() {
        // the stop tap, then a tap within the window: the double tap's second one - Return once the paste is in
        let mut t = DictationTrigger::default();
        assert_eq!(
            t.run("ralt-down@0 ralt-up@90 ralt-down@42500 ralt-up@42580"),
            [Arm, Start, Stop]
        );
        t.pending = true;
        assert_eq!(t.run("ralt-down@42900 ralt-up@42980"), [Send]);
        assert!(!t.active());
        // two quick taps while pending, outside the stop's window: a take starts and the second tap cancels it and
        // sends (the app queues Return after the paste)
        let mut s = DictationTrigger::default();
        assert_eq!(
            s.run("ralt-down@0 ralt-up@90 ralt-down@42500 ralt-up@42580"),
            [Arm, Start, Stop]
        );
        s.pending = true;
        assert_eq!(
            s.run("ralt-down@43200 ralt-up@43280 ralt-down@43400 ralt-up@43480"),
            [Arm, Start, Cancel, Send]
        );
        assert!(!s.active());
    }

    #[test]
    fn third_tap_of_a_double_tap_is_a_bounce() {
        // dict019: the double tap's second press, then a third 120 ms later - the third never starts a take
        let mut t = DictationTrigger::default();
        assert_eq!(
            t.run("ralt-down@0 ralt-up@90 ralt-down@42500 ralt-up@42580"),
            [Arm, Start, Stop]
        );
        assert_eq!(t.run("ralt-down@42900 ralt-up@42980"), [Send]);
        assert_eq!(t.run("ralt-down@43100 ralt-up@43180"), []);
        assert!(!t.active());
        // idle: tap, tap (send), tap -> nothing; a tap once the window has passed starts as usual
        let mut i = DictationTrigger::default();
        assert_eq!(
            i.run("ralt-down@0 ralt-up@80 ralt-down@200 ralt-up@280 ralt-down@400 ralt-up@480"),
            [Arm, Start, Cancel, Send]
        );
        assert_eq!(i.run("ralt-down@2000 ralt-up@2080"), [Arm, Start]);
    }

    #[test]
    fn esc_cancels_the_take_on_its_way() {
        let mut t = DictationTrigger::default();
        assert_eq!(
            t.run("ralt-down@0 ralt-up@90 ralt-down@5000 ralt-up@5080"),
            [Arm, Start, Stop]
        );
        assert_eq!(t.run("esc@5200"), []); // nothing on its way: Esc is the app's
        t.pending = true;
        assert_eq!(t.run("esc@5300"), [Cancel]);
        assert!(!t.active());
        // a dictation listening: Esc cancels that one, as before
        let mut l = DictationTrigger::default();
        l.pending = true;
        assert_eq!(
            l.run("ralt-down@0 ralt-up@90 esc@900"),
            [Arm, Start, Cancel]
        );
    }

    #[test]
    fn tap_right_after_an_automatic_end_does_nothing() {
        // the 5-minute limit ended the take; the user's "stop" tap a moment later must not start a new one
        let mut t = DictationTrigger::default();
        assert_eq!(t.run("ralt-down@0 ralt-up@90"), [Arm, Start]);
        t.ended_by_itself(300.0);
        assert!(!t.active());
        assert_eq!(t.run("ralt-down@301000 ralt-up@301080"), []);
        assert!(!t.active());
        // the next tap is a new take
        assert_eq!(t.run("ralt-down@302000 ralt-up@302080"), [Arm, Start]);
        // the late stop 3.5 s after the end, while the island still says the take ended, is a stop too (v0.9
        // dogfood: with a 2 s grace it started a new take under that line)
        let mut e = DictationTrigger::default();
        e.run("ralt-down@0 ralt-up@90");
        e.ended_by_itself(300.0);
        assert_eq!(DictationTrigger::LIMIT_GRACE, 4.0);
        assert_eq!(e.run("ralt-down@303500 ralt-up@303580"), []);
        // after the grace a tap starts again
        let mut g = DictationTrigger::default();
        g.run("ralt-down@0 ralt-up@90");
        g.ended_by_itself(300.0);
        assert_eq!(g.run("ralt-down@304500 ralt-up@304580"), [Arm, Start]);
        // a quick double tap right after the end still sends
        let mut d = DictationTrigger::default();
        d.run("ralt-down@0 ralt-up@90");
        d.ended_by_itself(300.0);
        assert_eq!(
            d.run("ralt-down@300500 ralt-up@300580 ralt-down@300700 ralt-up@300780"),
            [Send]
        );
    }

    /// Alt+← within the first second is a shortcut: no "Cancelled" line; Esc, or later, still says it.
    #[test]
    fn a_key_joining_right_away_is_a_shortcut() {
        assert!(DictationTrigger::joined_early(false, true, 0.4, 0));
        assert!(!DictationTrigger::joined_early(true, true, 0.4, 0));
        assert!(!DictationTrigger::joined_early(false, true, 1.5, 0));
        assert!(!DictationTrigger::joined_early(false, true, 0.8, 1));
        assert!(!DictationTrigger::joined_early(false, false, 0.2, 0));
    }

    #[test]
    fn misses_say_what_the_mode_wants() {
        let mut h = DictationTrigger::new(Key::RightAlt, Mode::Hold);
        assert_eq!(h.run("ralt-down@0 ralt-up@90"), [Arm]);
        assert_eq!(h.miss(), Some(Miss::TappedInHoldMode));
        assert_eq!(
            h.run("ralt-down@2000 tick@2250 ralt-up@4000"),
            [Arm, Start, Stop]
        );
        assert_eq!(h.miss(), None);
        let mut t = DictationTrigger::new(Key::RightAlt, Mode::Tap);
        assert_eq!(t.run("ralt-down@0 ralt-up@900"), [Arm]);
        assert_eq!(t.miss(), Some(Miss::HeldInTapMode));
        assert_eq!(t.run("ralt-down@2000 ralt-up@2080"), [Arm, Start]);
        assert_eq!(t.miss(), None);
        // the founder (2026-10-30): said while the key is still down, once the press is past a tap — and once per press
        let mut held = DictationTrigger::new(Key::RightAlt, Mode::Tap);
        held.run("ralt-down@0");
        assert!((held.deadline().unwrap_or(0.0) - 0.4).abs() < 0.001);
        held.run("tick@450");
        assert_eq!(held.take_miss(), Some(Miss::HeldInTapMode));
        assert_eq!(held.deadline(), None);
        assert_eq!(held.run("ralt-up@1500"), []);
        assert_eq!(held.miss(), None);
        // auto mode uses both: never a miss
        let mut a = DictationTrigger::default();
        a.run("ralt-down@0 ralt-up@90 ralt-down@900 ralt-up@990");
        assert_eq!(a.miss(), None);
    }

    /// review: the miss stayed set until the next dictation-key press, so every other key and click re-reported it
    #[test]
    fn a_miss_is_reported_once() {
        let mut h = DictationTrigger::new(Key::RightAlt, Mode::Hold);
        h.run("ralt-down@0 ralt-up@90");
        assert_eq!(h.take_miss(), Some(Miss::TappedInHoldMode));
        assert_eq!(h.take_miss(), None);
        // the keys and the click that follow don't bring it back
        h.run("key:65@500 click@700");
        assert_eq!(h.take_miss(), None);
        assert_eq!(h.miss(), None);
    }

    #[test]
    fn near_miss_double_tap_is_a_quick_stop() {
        // the second press 520 ms after the first release: outside the window, so the first tap's dictation stops —
        // but it was a near miss, and the app sends instead of "nothing heard" when nothing was
        let mut t = DictationTrigger::default();
        assert_eq!(
            t.run("ralt-down@0 ralt-up@120 ralt-down@640 ralt-up@760"),
            [Arm, Start, Stop]
        );
        assert!(t.quick_stop());
        // a real stop seconds later is not
        let mut s = DictationTrigger::default();
        assert_eq!(
            s.run("ralt-down@0 ralt-up@120 ralt-down@3000 ralt-up@3080"),
            [Arm, Start, Stop]
        );
        assert!(!s.quick_stop());
        // nor one with a key between, nor a long stop press, nor with double tap off
        let mut k = DictationTrigger::default();
        assert_eq!(
            k.run("ralt-down@0 ralt-up@120 key:72@300 ralt-down@640 ralt-up@760"),
            [Arm, Start, Stop]
        );
        assert!(!k.quick_stop());
        let mut l = DictationTrigger::default();
        assert_eq!(
            l.run("ralt-down@0 ralt-up@120 ralt-down@640 ralt-up@1400"),
            [Arm, Start, Stop]
        );
        assert!(!l.quick_stop());
        let mut o = DictationTrigger::default();
        o.double_tap = false;
        assert_eq!(
            o.run("ralt-down@0 ralt-up@120 ralt-down@640 ralt-up@760"),
            [Arm, Start, Stop]
        );
        assert!(!o.quick_stop());
        // tap mode the same
        let mut m = DictationTrigger::new(Key::RightAlt, Mode::Tap);
        assert_eq!(
            m.run("ralt-down@0 ralt-up@100 ralt-down@650 ralt-up@740"),
            [Arm, Start, Stop]
        );
        assert!(m.quick_stop());
    }

    // MARK: the physical event stream

    #[test]
    fn repeated_key_down_is_one_press() {
        // the same Alt down reported twice (Windows' auto-repeat, two hooks overlapping): one press, its hold time
        // unchanged
        assert_eq!(auto("ralt-down@0 ralt-down@40 ralt-up@90"), [Arm, Start]);
        assert_eq!(
            auto("ralt-down@0 ralt-down@200 tick@300 ralt-up@2000"),
            [Arm, Start, Stop]
        );
        // a repeat on the double tap's second press keeps it the second tap
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 ralt-down@200 ralt-down@230 ralt-up@280"),
            [Arm, Start, Cancel, Send]
        );
        // a release reported twice: the second one does nothing
        assert_eq!(auto("ralt-down@0 ralt-up@90 ralt-up@100"), [Arm, Start]);
    }

    /// Windows only: a held Shift auto-repeats its key-down; the repeats are not a second tap.
    #[test]
    fn a_held_modifier_repeating_is_not_a_double_tap() {
        let mut t = DictationTrigger::default();
        t.modifier_tap_shift = ModifierTap::Double;
        assert_eq!(t.run("ralt-down@0 ralt-up@90 shift-down@1000 shift-down@1250 shift-down@1283 shift-up@1300"), [Arm, Start]);
        assert!(t.active());
    }

    /// Windows only: a modifier whose key-up the hook never saw (the secure desktop took the keyboard) is put right
    /// from the system's own state.
    #[test]
    fn sync_modifiers_clears_a_stuck_key() {
        let mut t = DictationTrigger::default();
        assert_eq!(t.run("win-down@0"), []); // … Win+L: the up never comes
        assert_eq!(t.run("ralt-down@5000 ralt-up@5080"), []); // Win "held": not alone
        t.sync_modifiers(&[]);
        assert_eq!(t.run("ralt-down@6000 ralt-up@6080"), [Arm, Start]);
    }

    /// testEventTimeUsesTheEventsOwnClock, on the hook's GetTickCount milliseconds instead of CGEventTimestamp.
    #[test]
    fn event_time_uses_the_events_own_clock() {
        let now = 3_516_593.68;
        let now_tick = 1_000_000_000u32;
        // an event 120 ms ago, and 300 ms ago
        assert!((event_time(now_tick - 120, now_tick, now) - (now - 0.12)).abs() < 0.001);
        assert!((event_time(now_tick - 300, now_tick, now) - (now - 0.3)).abs() < 0.001);
        // across the 49.7-day wrap
        assert!((event_time(u32::MAX - 69, 50, now) - (now - 0.12)).abs() < 0.001);
        // a synthetic event (0), or one that makes no sense (5 s ahead, 3 s old): the time it reached us
        assert_eq!(event_time(0, now_tick, now), now);
        assert_eq!(event_time(now_tick + 5000, now_tick, now), now);
        assert_eq!(event_time(now_tick - 3000, now_tick, now), now);
        assert_eq!(event_time_seconds(now - 0.2, now), now - 0.2);
        assert_eq!(event_time_seconds(12.0, now), now);
        // a double tap whose second press was handled 400 ms late still reads as one with the events' own times
        let mut t = DictationTrigger::default();
        t.handle(Event::Key {
            code: vk::RMENU,
            down: true,
            time: 0.0,
        });
        t.handle(Event::Key {
            code: vk::RMENU,
            down: false,
            time: 0.09,
        });
        t.handle(Event::Key {
            code: vk::RMENU,
            down: true,
            time: 0.25,
        }); // stamped 0.25 (the event), not 0.65 (handled)
        assert_eq!(
            t.handle(Event::Key {
                code: vk::RMENU,
                down: false,
                time: 0.33
            }),
            [Cancel, Send]
        );
    }

    /// testGlobeKeyDownIsPartOfTheFnPress, the part that isn't the Mac's Globe key: any other key-down during an Alt
    /// press is another key.
    #[test]
    fn another_key_down_during_the_press_is_another_key() {
        assert_eq!(run("ralt-down@0 key:179@10 ralt-up@90"), [Arm]);
        assert_eq!(auto("ralt-down@0 key:179@10 ralt-up@90"), [Arm]);
    }

    // MARK: the style toggle (dictation-styles.md §3.2): Shift during a take, the island

    #[test]
    fn shift_alone_toggles_the_style() {
        // hands-free (auto tap): Shift tapped twice while talking → two toggles; the dictation goes on and stops normally
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 shift-down@1000 shift-up@1080 shift-down@2000 shift-up@2060 ralt-down@3000 ralt-up@3080"),
            [Arm, Start, Style, Style, Stop]
        );
        // the right Shift too
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 rshift-down@1000 rshift-up@1080"),
            [Arm, Start, Style]
        );
        // tap mode
        assert_eq!(
            run("ralt-down@0 ralt-up@100 shift-down@500 shift-up@560 ralt-down@900 ralt-up@1000"),
            [Arm, Start, Style, Stop]
        );
    }

    #[test]
    fn ctrl_alone_toggles_translation() {
        // hands-free: Ctrl tapped while talking → translate; either Ctrl; the dictation goes on and stops normally
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 ctrl-down@1000 ctrl-up@1080 ralt-down@3000 ralt-up@3080"),
            [Arm, Start, Translate, Stop]
        );
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 rctrl-down@1000 rctrl-up@1080"),
            [Arm, Start, Translate]
        );
        // Shift and Ctrl each their own toggle, in any order
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 shift-down@500 shift-up@560 ctrl-down@800 ctrl-up@860"),
            [Arm, Start, Style, Translate]
        );
        // a resting thumb (held past a second) is no toggle; Ctrl+V is a shortcut, not a toggle; Shift+Ctrl is a
        // chord, neither
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 ctrl-down@1000 ctrl-up@2200"),
            [Arm, Start]
        );
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 ctrl-down@1000 key:86@1040 ctrl-up@1080"),
            [Arm, Start]
        );
        assert_eq!(
            auto(
                "ralt-down@0 ralt-up@90 shift-down@1000 ctrl-down@1020 ctrl-up@1060 shift-up@1080"
            ),
            [Arm, Start]
        );
        // not dictating: Ctrl is any other modifier (Alt+Ctrl is a shortcut: no start)
        assert_eq!(auto("ctrl-down@0 ctrl-up@60"), []);
        assert_eq!(
            auto("ralt-down@0 ctrl-down@20 ctrl-up@60 ralt-up@90"),
            [Arm]
        );
        // the island's left half
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 island-translate@500 island@700"),
            [Arm, Start, Translate, Style]
        );
    }

    #[test]
    fn ctrl_in_push_to_talk_toggles_without_cancelling() {
        let mut t = DictationTrigger::default();
        assert_eq!(t.run("ralt-down@0 tick@300"), [Arm, Start]);
        assert_eq!(t.run("ctrl-down@800 ctrl-up@870"), [Translate]);
        assert!(t.active());
        assert_eq!(t.run("ralt-up@2000"), [Stop]);
        // Ctrl with a key while held: a shortcut — push-to-talk is cancelled, as before
        assert_eq!(
            run_mode(
                "ralt-down@0 tick@260 ctrl-down@600 key:86@640 ctrl-up@660 ralt-up@1500",
                Mode::Hold
            ),
            [Arm, Start, Cancel]
        );
    }

    #[test]
    fn shift_in_push_to_talk_toggles_without_cancelling() {
        // auto held past 300 ms: push-to-talk; a lone Shift while held is the toggle, and letting go still stops
        let mut t = DictationTrigger::default();
        assert_eq!(t.run("ralt-down@0 tick@300"), [Arm, Start]);
        assert!(t.push_to_talk());
        assert_eq!(t.run("shift-down@800 shift-up@870"), [Style]);
        assert!(t.active());
        assert_eq!(t.run("ralt-up@2000"), [Stop]);
        // hold mode the same
        assert_eq!(
            run_mode(
                "ralt-down@0 tick@260 shift-down@600 shift-up@650 ralt-up@1500",
                Mode::Hold
            ),
            [Arm, Start, Style, Stop]
        );
    }

    #[test]
    fn shift_with_another_key_is_no_toggle() {
        // Shift+A (a capital) while hands-free: no toggle, nothing cancelled
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 shift-down@1000 key:65@1050 shift-up@1100"),
            [Arm, Start]
        );
        // Shift with a click
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 shift-down@1000 click@1050 shift-up@1100"),
            [Arm, Start]
        );
        // push-to-talk: Shift + a key is a shortcut → cancelled, as before
        assert_eq!(
            auto("ralt-down@0 tick@300 shift-down@800 key:65@820 shift-up@870 ralt-up@2000"),
            [Arm, Start, Cancel]
        );
        // Shift held for a long time (a resting finger) is no toggle
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 shift-down@1000 shift-up@2500"),
            [Arm, Start]
        );
        // not dictating: Shift is just a key
        assert_eq!(auto("shift-down@0 shift-up@60"), []);
    }

    #[test]
    fn alt_shift_is_a_shortcut_not_a_start() {
        // Shift with the start press is a modifier like any other: no take starts
        assert!(!auto("shift-down@0 ralt-down@20 ralt-up@110 shift-up@150").contains(&Start));
        assert!(
            !auto("ralt-down@0 shift-down@50 shift-up@120 tick@300 ralt-up@900").contains(&Start)
        );
        // Alt+Shift+← is a shortcut, not a start
        assert!(
            !auto("ralt-down@0 shift-down@30 key:37@60 shift-up@90 ralt-up@120").contains(&Start)
        );
        // Shift stays a modifier: Alt+Shift+V and Blurt's Alt+Shift shortcuts never start anything
        assert_eq!(run("shift-down@0 ralt-down@20 ralt-up@90 shift-up@120"), []);
        assert_eq!(
            either(
                "shift-down@0 lalt-down@20 lalt-up@90 shift-up@120",
                Mode::Auto
            ),
            []
        );
        // a plain start still starts
        assert_eq!(auto("ralt-down@0 ralt-up@90"), [Arm, Start]);
        // while dictating, Shift + Alt is neither a stop nor a toggle (a press that turned into a shortcut)
        assert_eq!(
            auto(
                "ralt-down@0 ralt-up@90 shift-down@1000 ralt-down@1050 ralt-up@1120 shift-up@1200"
            ),
            [Arm, Start]
        );
    }

    #[test]
    fn island_click_toggles_and_never_cancels() {
        // push-to-talk: a click elsewhere cancels it, a click on the island is the style chip
        assert_eq!(
            auto("ralt-down@0 tick@300 island@800 ralt-up@2000"),
            [Arm, Start, Style, Stop]
        );
        assert_eq!(
            auto("ralt-down@0 tick@300 click@800 ralt-up@2000"),
            [Arm, Start, Cancel]
        );
        assert_eq!(
            auto("ralt-down@0 ralt-up@90 island@500 island@900"),
            [Arm, Start, Style, Style]
        );
        // not dictating: nothing
        assert_eq!(auto("island@100"), []);
    }

    /// testParseFlags: the script's events (key events here, not the Mac's flags)
    #[test]
    fn parse_keys() {
        let e = DictationTrigger::parse(
            "ralt-down@0 shift-down@10 ralt-up@20 key:65@30 esc@40 click@50 tick@60",
        );
        assert_eq!(
            e,
            [
                Event::Key {
                    code: vk::RMENU,
                    down: true,
                    time: 0.0
                },
                Event::Key {
                    code: vk::LSHIFT,
                    down: true,
                    time: 0.01
                },
                Event::Key {
                    code: vk::RMENU,
                    down: false,
                    time: 0.02
                },
                Event::Key {
                    code: 65,
                    down: true,
                    time: 0.03
                },
                Event::Key {
                    code: vk::ESCAPE,
                    down: true,
                    time: 0.04
                },
                Event::MouseDown { time: 0.05 },
                Event::Tick { time: 0.06 },
            ]
        );
    }

    // MARK: modifier tap modes (structured / translate): single, double

    /// a trigger with the default key/mode but modifier tap modes overridden
    fn mod_tap(script: &str, shift: ModifierTap, command: ModifierTap) -> Vec<Output> {
        let mut t = DictationTrigger::default();
        t.modifier_tap_shift = shift;
        t.modifier_tap_command = command;
        t.run(script)
    }
    use ModifierTap::{Double as D, Single as S};

    #[test]
    fn single_mode_fires_on_one_tap_for_both_keys() {
        // the setting back on "single": one Shift / Ctrl let go while dictating toggles at once
        assert_eq!(
            mod_tap("ralt-down@0 ralt-up@90 shift-down@1000 shift-up@1080", S, S),
            [Arm, Start, Style]
        );
        assert_eq!(
            mod_tap("ralt-down@0 ralt-up@90 ctrl-down@1000 ctrl-up@1080", S, S),
            [Arm, Start, Translate]
        );
        // a hold of either key is still not a toggle (a finger resting on it)
        assert_eq!(
            mod_tap("ralt-down@0 ralt-up@90 shift-down@1000 shift-up@2200", S, S),
            [Arm, Start]
        );
    }

    #[test]
    fn double_tap_ctrl() {
        // a single Ctrl tap does nothing; two quick taps toggle
        assert_eq!(
            mod_tap("ralt-down@0 ralt-up@90 ctrl-down@1000 ctrl-up@1080", S, D),
            [Arm, Start]
        );
        assert_eq!(
            mod_tap(
                "ralt-down@0 ralt-up@90 ctrl-down@1000 ctrl-up@1080 ctrl-down@1200 ctrl-up@1280",
                S,
                D
            ),
            [Arm, Start, Translate]
        );
        // too slow: two single taps, no toggle
        assert_eq!(
            mod_tap(
                "ralt-down@0 ralt-up@90 ctrl-down@1000 ctrl-up@1080 ctrl-down@1500 ctrl-up@1580",
                S,
                D
            ),
            [Arm, Start]
        );
        // three quick taps: one toggle, the third tap starts a new pair (no repeat)
        assert_eq!(
            mod_tap("ralt-down@0 ralt-up@90 ctrl-down@1000 ctrl-up@1080 ctrl-down@1200 ctrl-up@1280 ctrl-down@1400 ctrl-up@1480", S, D),
            [Arm, Start, Translate]
        );
        // after the toggle, a quick tap in the cooldown does nothing
        assert_eq!(
            mod_tap("ralt-down@0 ralt-up@90 ctrl-down@1000 ctrl-up@1080 ctrl-down@1200 ctrl-up@1280 ctrl-down@1350 ctrl-up@1430", S, D),
            [Arm, Start, Translate]
        );
        // Shift+Ctrl chord: neither (either order — Shift first, or Ctrl first)
        assert_eq!(
            mod_tap(
                "ralt-down@0 ralt-up@90 shift-down@1000 ctrl-down@1020 ctrl-up@1060 shift-up@1080",
                S,
                D
            ),
            [Arm, Start]
        );
        assert_eq!(
            mod_tap(
                "ralt-down@0 ralt-up@90 ctrl-down@1000 shift-down@1020 shift-up@1060 ctrl-up@1080",
                S,
                D
            ),
            [Arm, Start]
        );
        // not dictating: Ctrl is any other modifier
        assert_eq!(
            mod_tap("ctrl-down@0 ctrl-up@60 ctrl-down@100 ctrl-up@160", S, D),
            []
        );
    }

    #[test]
    fn double_tap_shift() {
        assert_eq!(
            mod_tap("ralt-down@0 ralt-up@90 shift-down@1000 shift-up@1080 shift-down@1200 shift-up@1280", D, S),
            [Arm, Start, Style]
        );
        assert_eq!(
            mod_tap("ralt-down@0 ralt-up@90 shift-down@1000 shift-up@1080", D, S),
            [Arm, Start]
        );
        // a capital (Shift+A) is still no toggle
        assert_eq!(
            mod_tap(
                "ralt-down@0 ralt-up@90 shift-down@1000 key:65@1050 shift-up@1100",
                D,
                S
            ),
            [Arm, Start]
        );
        // Shift+Ctrl in either order: neither toggle
        assert_eq!(
            mod_tap(
                "ralt-down@0 ralt-up@90 ctrl-down@1000 shift-down@1020 shift-up@1060 ctrl-up@1080",
                D,
                S
            ),
            [Arm, Start]
        );
        // after a fire, a third tap inside the cooldown does nothing
        assert_eq!(
            mod_tap("ralt-down@0 ralt-up@90 shift-down@1000 shift-up@1080 shift-down@1200 shift-up@1280 shift-down@1350 shift-up@1430", D, S),
            [Arm, Start, Style]
        );
    }

    /// What the app ships with: Shift and Ctrl both ask on a double tap — same gesture, no confusion
    #[test]
    fn shipped_default_is_double_for_both_keys() {
        assert_eq!(DictationTrigger::SHIPPED_MODIFIER_TAP, ModifierTap::Double);
        let mut t = DictationTrigger::default();
        t.modifier_tap_shift = DictationTrigger::SHIPPED_MODIFIER_TAP;
        t.modifier_tap_command = DictationTrigger::SHIPPED_MODIFIER_TAP;
        assert_eq!(t.run("ralt-down@0 ralt-up@90"), [Arm, Start]);
        assert_eq!(t.run("shift-down@1000 shift-up@1080"), []); // one Shift tap: nothing (the old style toggle is gone)
        assert_eq!(t.run("shift-down@1200 shift-up@1280"), [Style]); // the second one, inside the window
        assert_eq!(t.run("ctrl-down@2500 ctrl-up@2580"), []);
        assert_eq!(t.run("ctrl-down@2620 ctrl-up@2700"), [Translate]);
    }

    #[test]
    fn modifier_tap_per_key_override() {
        // Shift double, Ctrl single: each key keeps its own mode (the way back for a user who liked one tap)
        let mut t = DictationTrigger::default();
        t.modifier_tap_shift = ModifierTap::Double;
        t.modifier_tap_command = ModifierTap::Single;
        assert_eq!(t.run("ralt-down@0 ralt-up@90"), [Arm, Start]);
        assert_eq!(t.run("ctrl-down@1000 ctrl-up@1080"), [Translate]);
        assert_eq!(t.run("shift-down@2000 shift-up@2080"), []);
        assert_eq!(t.run("shift-down@2200 shift-up@2280"), [Style]);
    }
}
