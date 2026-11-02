//! What happens to a dictation take between the stop and the text being in, and what the island says about it —
//! ported from the Mac's BlurtCore (`DictationTakeFlow.swift`, `DictationASRLine.swift`, `DictationSendRule.swift`,
//! `DictationAccess.swift`'s `DictationFnClash`, `IslandToasts.swift`'s `DictationToastKeys`, `NothingHeard.swift`).
//! Their tests (`DictationTakeFlowTests`, `DictationASRLineTests`, `DictationSendRuleTests`, …) are ported below. Pure:
//! the engine (engine.rs, Windows) acts on them.
//!
//!   Runaway        a hands-free take nobody stopped: a reminder after 20 s without speech, the clock counting down
//!                  from 4:30, and the 5-minute limit said when it ends the take
//!   Tip            one quiet line after a take, for the first few: double-tap to send (chat apps, up to 5), Shift
//!                  for a list (elsewhere, once) — each until shown enough or used
//!   AsrFailure     why a take's words couldn't be recognised, in the user's terms, and which button helps
//!   TakeDeadline   a take never waits for its words forever
//!   DeliveredLine  one line about where the text went, never two that replace each other
//!   CopiedGuard    a double tap right after a take that was only copied holds its Return
//!   KeptText       the start of a text the island keeps (no field found)
//!   SendRule       a double tap presses Return only right after a take typed into the app still in front
//!   Clash          another dictation app running beside Blurt (Typeless, Wispr Flow)
//!   toast_keys     which island lines a new take, or the end of listening, drops
//!   nothing_heard  "No sound from <mic>" vs "No speech detected (<mic>)"

use std::collections::HashMap;

// ------------------------------------------------------------------ the runaway take

/// A hands-free take that goes on without anyone talking — started by mistake, or the stop tap missed. While it
/// listens the engine feeds it the take's time and whether speech is heard; it says when to remind and when to warn.
#[derive(Clone, Debug, Default)]
pub struct Runaway {
    last_speech: f64,
    reminded: bool,
    warned: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RunawayNotice {
    /// 20 s without speech: still listening · Right Alt to finish · Esc to cancel
    StillListening,
    /// 4:30: the countdown starts on the clock
    EndsSoon,
}

impl Runaway {
    /// dictation stops by itself here (seconds)
    pub const LIMIT: f64 = 300.0;
    /// the clock counts down from here
    pub const COUNTDOWN_FROM: f64 = 270.0;
    /// this long without speech: "Still listening"
    pub const QUIET_AFTER: f64 = 20.0;

    pub fn new() -> Self {
        Self::default()
    }

    /// Each stretch of audio: `elapsed` (s), whether speech is heard now, and whether the take is hands-free
    /// (push-to-talk ends when the key comes up: no reminder). One notice at most per quiet stretch, one warning per
    /// take.
    pub fn feed(&mut self, elapsed: f64, speaking: bool, hands_free: bool) -> Option<RunawayNotice> {
        if speaking {
            self.last_speech = elapsed;
            self.reminded = false;
        }
        if elapsed >= Self::COUNTDOWN_FROM && !self.warned {
            self.warned = true;
            return Some(RunawayNotice::EndsSoon);
        }
        if hands_free && !self.reminded && elapsed - self.last_speech >= Self::QUIET_AFTER {
            self.reminded = true;
            return Some(RunawayNotice::StillListening);
        }
        None
    }

    /// The clock: the time so far, then — from 4:30 — the time left, with a minus ("−0:29").
    pub fn clock(elapsed: f64) -> (String, bool) {
        let mmss = |t: i64| format!("{}:{:02}", t / 60, t % 60);
        if elapsed < Self::COUNTDOWN_FROM {
            return (mmss(elapsed.max(0.0) as i64), false);
        }
        (format!("\u{2212}{}", mmss((Self::LIMIT - elapsed).max(0.0).ceil() as i64)), true)
    }
}

// ------------------------------------------------------------------ the first takes' tips

/// The quiet line after a take, for the first few (`app.dictation_tips` counts each one shown).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tip {
    /// "Double-tap Right Alt to send" — chat apps, the first five takes there
    Send,
    /// "Double-tap Shift while you talk for a list"
    List,
    /// "<hotkey> switches style" — only where a reformat hotkey exists
    Reformat,
}

impl Tip {
    pub fn as_str(self) -> &'static str {
        match self {
            Tip::Send => "send",
            Tip::List => "list",
            Tip::Reformat => "reformat",
        }
    }

    /// how many times each is shown at most
    pub fn times(self) -> i64 {
        if self == Tip::Send {
            5
        } else {
            1
        }
    }

    /// The tip for a take that just went in, or None. `chat`: it went into a chat app; `send_on`: double-tap to send
    /// is on; `sent`: this take was sent already (the user knows); `shown`: how often each was shown (a tip the user
    /// has used counts as shown out).
    pub fn next(chat: bool, send_on: bool, sent: bool, shown: &HashMap<String, i64>) -> Option<Tip> {
        let left = |t: Tip| shown.get(t.as_str()).copied().unwrap_or(0) < t.times();
        if chat {
            return (send_on && !sent && left(Tip::Send)).then_some(Tip::Send);
        }
        // elsewhere: from the first take, one each — Shift for a list, then the reformat key (a chat app's takes
        // teach sending first)
        [Tip::List, Tip::Reformat].into_iter().find(|&t| left(t))
    }
}

// ------------------------------------------------------------------ recognition failed

/// Why a take's words couldn't be recognised (the speech server's error code, or the call timing out).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AsrFailure {
    /// no speech model on this PC (transcribe.py's model_missing): download one
    NoModel,
    /// the model didn't answer in time
    TimedOut,
    /// anything else (the code, for the history)
    Failed(String),
}

/// What the island shows for a failure, and which button.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AsrLine {
    /// "Couldn't recognize that — the recording is kept · Retry"
    Failed,
    /// "The speech model didn't respond — the recording is kept · Retry"
    Slow,
    /// "The cloud speech key isn't valid … · Settings…": Retry would only fail again
    CloudKey,
    /// "Couldn't connect to the cloud speech service … · Retry"
    CloudOffline,
    /// "The cloud speech service is busy or out of quota … · Retry"
    CloudQuota,
}

impl AsrLine {
    /// the localisation key
    pub fn key(self) -> &'static str {
        match self {
            AsrLine::Failed => "dictation.toast.asr_failed",
            AsrLine::Slow => "dictation.toast.asr_slow",
            AsrLine::CloudKey => "dictation.toast.asr_cloud_key",
            AsrLine::CloudOffline => "dictation.toast.asr_cloud_offline",
            AsrLine::CloudQuota => "dictation.toast.asr_cloud_quota",
        }
    }
    /// Retry can help (else the button opens Settings)
    pub fn retry_helps(self) -> bool {
        self != AsrLine::CloudKey
    }
}

impl AsrFailure {
    /// From the server's code. Windows' own "asr_slow" (no answer in time, engine.rs `recognise`) is the Mac's
    /// "timeout".
    pub fn from_code(code: Option<&str>) -> AsrFailure {
        match code {
            Some("model_missing") => AsrFailure::NoModel,
            Some("timeout") | Some("asr_slow") => AsrFailure::TimedOut,
            other => AsrFailure::Failed(other.unwrap_or("error").to_string()),
        }
    }

    /// For the history's reason ("asr_failed:model_missing").
    pub fn code(&self) -> String {
        match self {
            AsrFailure::NoModel => "model_missing".into(),
            AsrFailure::TimedOut => "timeout".into(),
            AsrFailure::Failed(c) => c.clone(),
        }
    }

    /// The line for this failure. transcribe.py's codes: auth (401/403, or a key with characters a key can't have),
    /// quota (429), network (unreachable, timed out), bad_response, privacy (local-only recognition is on), …
    pub fn line(&self) -> AsrLine {
        match self {
            AsrFailure::NoModel => AsrLine::Failed, // the island offers the download instead
            AsrFailure::TimedOut => AsrLine::Slow,
            AsrFailure::Failed(c) => match c.as_str() {
                "auth" => AsrLine::CloudKey,
                "network" => AsrLine::CloudOffline,
                "quota" => AsrLine::CloudQuota,
                _ => AsrLine::Failed,
            },
        }
    }

    /// The speech server's answer is final: a second run would say the same (no model here, a key the service
    /// refused, local-only recognition on). Not worth hearing the whole recording again while the user waits.
    pub fn definite(code: Option<&str>) -> bool {
        matches!(code, Some("model_missing" | "auth" | "privacy"))
    }

    /// How long a speech-server call may take for this much audio at most: a model load (cold, from disk) plus 1.5×
    /// the audio — a piece of 20 s gets 45 s. A hung server is told well before that (server.rs `hung`).
    pub fn server_timeout(audio_seconds: f64) -> f64 {
        15.0 + 1.5 * audio_seconds.max(0.0)
    }
}

/// A speech model's repetition loop: far more characters than anyone says in that time (the fastest dictation is ~5
/// CJK or ~18 Latin characters a second; a Fun-ASR-Nano loop typed 2,123 for 6 s). Structural — a count, no reading.
/// transcribe.py already cuts a loop it sees (FunAsrOnnx `LOOP_CPS`); this keeps a double tap from sending one.
pub struct SpeechLoop;

impl SpeechLoop {
    pub const CPS: f64 = 30.0;
    pub const SLACK: f64 = 40.0;

    pub fn looped(chars: usize, seconds: f64) -> bool {
        chars as f64 > Self::SLACK + Self::CPS * seconds.max(0.0)
    }
}

/// The translate target as the listening ear shows it beside the translate glyph (the Mac's DictationTranslateHint
/// .earTarget): "EN", "中", "繁", "日", "한", "FR"…, "⇄" for Auto (either way). `target` is record.dictation
/// .translate_target ("auto", "en", "zh|en" …: the first part is where it goes).
pub fn ear_target(target: &str) -> String {
    match target.split('|').next().unwrap_or("auto") {
        "auto" | "" => "⇄".into(),
        "en" => "EN".into(),
        "zh" | "zh-Hans" => "中".into(),
        "zh-Hant" => "繁".into(),
        "ja" => "日".into(),
        "ko" => "한".into(),
        other => other.to_uppercase(),
    }
}

/// How long a take may wait for its words after key-up before it is called too slow (the recording stays: Retry).
pub struct TakeDeadline;

impl TakeDeadline {
    pub const BASE: f64 = 45.0;
    pub const CAP: f64 = 180.0;
    pub fn seconds(audio_seconds: f64) -> f64 {
        Self::CAP.min(Self::BASE + 0.5 * audio_seconds.max(0.0))
    }
}

/// How long after the stop a take still on its way says so ("Still recognizing… Esc to cancel").
pub const SLOW_AFTER: f64 = 3.0;
/// How long "Cancelled" offers Undo for takes stopped on their way (their audio is kept until then).
pub const UNDO_SECONDS: f64 = 5.0;

// ------------------------------------------------------------------ what the island says once a take is in

/// One line once a take is in (or on the clipboard), never two that replace each other in the same frame (v0.9
/// dogfood: a send asked for, the text only copied — "Copied" showed, "not sent" never did).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeliveredLine {
    /// copied (UIPI, no app in front …)
    Copied,
    /// a double tap asked to send, the text is only on the clipboard: Return was not pressed
    CopiedNotSent,
    /// a double tap asked to send and nothing went in
    NotSent,
    /// pasted into a focus UI Automation couldn't confirm as text (WeChat & co.): "Copy Again"
    PastedUnsure,
    /// pasted, but UI Automation read the focus and it isn't a text field (the desktop, a list): the text most likely
    /// went nowhere, so the island keeps it, with Copy
    NoField,
    /// a password field had the focus: not typed, not copied — "Copy" is the user's call
    Held,
    None,
}

impl DeliveredLine {
    /// `result`: pasted | copied | held | none; `send_asked`: a double tap queued Return for this take and it wasn't
    /// pressed; `no_field`: the focus was read and isn't a text field.
    pub fn line(result: &str, send_asked: bool, confirmed: bool, no_field: bool) -> DeliveredLine {
        match result {
            "held" => DeliveredLine::Held,
            "copied" => {
                if send_asked {
                    DeliveredLine::CopiedNotSent
                } else {
                    DeliveredLine::Copied
                }
            }
            "pasted" => {
                if !confirmed && no_field {
                    DeliveredLine::NoField
                } else if confirmed {
                    DeliveredLine::None
                } else {
                    DeliveredLine::PastedUnsure
                }
            }
            _ => {
                if send_asked {
                    DeliveredLine::NotSent
                } else {
                    DeliveredLine::None
                }
            }
        }
    }

    /// The line's key when the text was left on the clipboard: copied, or copied and not sent — one line that says
    /// both. None for the other lines (they have their own button or wording).
    pub fn copy_key(self) -> Option<&'static str> {
        match self {
            DeliveredLine::CopiedNotSent => Some("dictation.toast.copied.not_sent"),
            DeliveredLine::Copied => Some("dictation.toast.copied"),
            _ => None,
        }
    }

    /// A plain copy is done (the ok check, as every done line); "not sent" isn't.
    pub fn checked(self) -> bool {
        self == DeliveredLine::Copied
    }

    /// How long a copied line stays: longer when there is more to read (it wasn't sent).
    pub fn copy_seconds(self) -> f64 {
        if self == DeliveredLine::Copied {
            2.4
        } else {
            4.0
        }
    }
}

/// A double tap after a take that was only copied: Return would go into an app where nothing was pasted. It is held
/// back while the copy is recent and no key was pressed since (a Ctrl+V, or typing, says the user is in a field again).
pub struct CopiedGuard;

impl CopiedGuard {
    pub const WINDOW: f64 = 15.0;

    /// `copied_at`: when the last take was left on the clipboard (None: it was typed); `key_after`: a key was pressed
    /// since then.
    pub fn holds_return(copied_at: Option<f64>, key_after: bool, now: f64) -> bool {
        match copied_at {
            Some(c) if !key_after => now - c < Self::WINDOW,
            _ => false,
        }
    }
}

/// The text the island keeps after a paste that found no field: the start of it, at most `LIMIT` characters, cut at a
/// word or after punctuation when one is near the end; Copy copies all of it.
pub struct KeptText;

impl KeptText {
    pub const LIMIT: usize = 80;

    pub fn preview(text: &str) -> String {
        Self::preview_with(text, Self::LIMIT)
    }

    pub fn preview_with(text: &str, limit: usize) -> String {
        let t = text.trim().replace('\n', " ");
        let chars: Vec<char> = t.chars().collect();
        if chars.len() <= limit {
            return t;
        }
        let head = &chars[..limit];
        // a break in the last fifth: a space (Latin) or a mark (CJK punctuation, commas)
        const MARKS: &[char] = &[' ', '，', '。', '、', '；', '：', '！', '？', ',', '.', ';', ':', '!', '?'];
        if let Some(i) = head.iter().rposition(|c| MARKS.contains(c)) {
            if limit - i <= limit / 5 {
                let s: String = head[..i].iter().collect();
                return format!("{}…", s.trim());
            }
        }
        format!("{}…", head.iter().collect::<String>())
    }
}

/// When a double tap may press Return (v1.0.6, the founder: a double tap with nothing dictated before it pressed Return
/// in whatever app was in front). Return goes out only for a take still on its way (sent once it has been pasted), or
/// right after a take was typed into the app that is still in front.
pub struct SendRule;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SendVerdict {
    Send,
    Queue,
    NoTake,
}

impl SendRule {
    /// How long after a paste a double tap still sends it.
    pub const WINDOW: f64 = 60.0;

    /// `pending`: takes still on their way; `last_paste`: when (seconds, the same clock as `now`) and into which app
    /// (exe) the last take was typed; `front`: the app in front now.
    pub fn decide(pending: bool, last_paste: Option<(f64, Option<&str>)>, front: Option<&str>, now: f64) -> SendVerdict {
        if pending {
            return SendVerdict::Queue;
        }
        match last_paste {
            Some((at, app)) if now - at <= Self::WINDOW && app == front => SendVerdict::Send,
            _ => SendVerdict::NoTake,
        }
    }
}

// ------------------------------------------------------------------ another dictation app

/// Another dictation app running beside Blurt (Typeless, Wispr Flow): both may react to the same key and the text can
/// go in twice — which looks like Blurt's bug. The Mac says it when Fn is Blurt's key; on Windows there is no Fn and
/// those apps' own keys are theirs to set, so it is said whenever one runs: at a take's start or when one launches,
/// once a day per app, never over a take that is listening (said once that take ends).
pub struct Clash;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClashMoment {
    None,
    Now,
    AfterTake,
}

impl Clash {
    /// The apps to mention now: they run, and each wasn't mentioned today.
    pub fn to_mention(running: &[String], said_today: impl Fn(&str) -> bool) -> Vec<String> {
        running.iter().filter(|a| !said_today(a)).cloned().collect()
    }

    /// When the notice is said: never over a take that is listening, but once that take ends.
    pub fn moment(apps: &[String], listening: bool) -> ClashMoment {
        if apps.is_empty() {
            ClashMoment::None
        } else if listening {
            ClashMoment::AfterTake
        } else {
            ClashMoment::Now
        }
    }
}

// ------------------------------------------------------------------ the island's keys

/// What the island says, by key: a newer line with the same key replaces the one showing.
pub mod toast_keys {
    /// what the island says about the last take: "nothing heard", "copied", the no-field Copy
    pub const TAKE: &str = "dictation";
    /// Shift's style line while a take listens
    pub const STYLE: &str = "dictation.style";
    /// once-a-day notices with a button
    pub const NOTICE: &str = "dictation.notice";
    /// the first takes' tips: about the take just done
    pub const TIP: &str = "dictation.tip";
    /// "still listening" and the 5-minute limit
    pub const LISTENING: &str = "dictation.listening";
    /// "Still recognizing… Esc to cancel": up while a slow take is on its way, gone when it lands or is cancelled
    pub const SLOW: &str = "dictation.slow";
    /// "Cancelled · Undo"
    pub const CANCEL: &str = "dictation.cancel";
    /// "no speech model · Download…"
    pub const MODEL: &str = "dictation.model";
    /// "Typeless is also running …" (once a day per app; said after a listening take, never over it)
    pub const CLASH: &str = "dictation.fn_clash";

    /// "Couldn't recognize that · Retry" for one take: its own key, so two failed takes each keep their Retry.
    pub fn failed(id: &str) -> String {
        format!("dictation.failed.{id}")
    }

    /// The line's leading mark (the Mac's Toast.icon): the attention triangle where something failed or needs the
    /// user (no model, recognition failed, a key refused, translate unavailable, every "Not sent: …", a mic that gives
    /// silence, a clash), the ok check for a done line (copied, learned, reformatted, remembered), the spinner for a line
    /// still at work (the model downloading); None for the rest — the island leads those with the grey Peep, never an
    /// empty slot (windows-parity/island.md).
    pub fn mark(msg: &str) -> Option<&'static str> {
        const WARN: [&str; 16] = [
            "dictation.toast.ends_soon", // "30 seconds left": the 5-minute limit, as the line after it (limit) is
            "dictation.toast.asr_",
            "dictation.toast.no_model",
            "dictation.toast.model_failed",
            "dictation.toast.mic_denied",
            "dictation.toast.polish_", // the key refused, offline, out of quota
            "dictation.toast.not_sent.", // one family: the password field, the admin window, the runaway, no field
            "dictation.toast.nothing.silent",
            "dictation.toast.fn_clash",
            "dictation.toast.recording_busy",
            "dictation.toast.weaker_asr",
            "dictation.toast.limit",
            "dictation.translate.toast.unavailable",
            "dictation.translate.toast.failed",
            "dictation.style.needs_cloud",
            "dictation.toast.secure_held",
        ];
        const CHECK: [&str; 8] = [
            "dictation.toast.copied",
            "dictation.toast.copied.done",
            "dictation.toast.copied.not_sent",
            "dictation.toast.learned",
            "dictation.style.learn.done",
            "dictation.toast.model_ready",
            "dictation.style.reformatted",
            "dictation.remember.saved.",
        ];
        const WORKING: [&str; 2] = ["dictation.toast.model_downloading", "dictation.toast.model_started"];
        if WARN.iter().any(|w| msg.starts_with(w))
            || msg == "dictation.toast.mic"
            || matches!(msg, "dictation.translate.toast.key" | "dictation.translate.toast.quota" | "dictation.translate.toast.offline")
        {
            Some("warning")
        } else if CHECK.iter().any(|c| if c.ends_with('.') { msg.starts_with(c) } else { msg == *c }) {
            Some("check")
        } else if WORKING.iter().any(|w| msg.starts_with(w)) {
            Some("spinner")
        } else {
            None
        }
    }

    /// Dropped when a new take starts: everything about the last take, and the tip it ended with (not the once-a-day
    /// notices, not a failed take's Retry or "Cancelled · Undo": they are still true).
    pub const DROPPED_AT_START: [&str; 4] = [TAKE, TIP, LISTENING, SLOW];
    /// Dropped when a take stops listening: Shift means nothing after that.
    pub const DROPPED_WHEN_LISTENING_ENDS: [&str; 1] = [STYLE];
}

// ------------------------------------------------------------------ nothing heard

/// A take that heard nothing: whether the mic gave any sound at all decides the words — a level that never left the
/// floor the whole take is a mic that gives silence (muted, the wrong input) — "No sound from <mic>"; anything else is
/// "No speech detected (<mic>)".
pub mod nothing_heard {
    /// the floor on mic.rs `level`'s scale (0 at −60 dBFS, 1 at 0): −55 dBFS, the Mac's floor
    pub const FLOOR: f32 = 5.0 / 60.0;

    /// `peak`: the take's loudest frame level; `frames`: how many frames were heard (a blink tells nothing).
    pub fn silent_mic(peak: f32, frames: usize) -> bool {
        frames >= 5 && peak < FLOOR
    }

    /// The line's key — with a mic name, or the plain line without one.
    pub fn key(silent: bool, has_name: bool) -> &'static str {
        if !has_name {
            "dictation.toast.nothing"
        } else if silent {
            "dictation.toast.nothing.silent"
        } else {
            "dictation.toast.nothing.named"
        }
    }
}

// ------------------------------------------------------------------ the speech models

/// `transcribe.py dictation-models` as the island needs it (the Mac's DictationSpeechModels): what "Download…" gets,
/// and whether a weaker model than the recommended one just ran.
pub mod speech_models {
    use serde_json::Value;

    fn installed(v: &Value, id: &str) -> bool {
        v["models"].as_array().is_some_and(|rows| rows.iter().any(|r| r["id"] == id && r["installed"] == true))
    }

    /// What "Download…" gets: (model id, whether it becomes the choice). Ready: the recommended one when it isn't
    /// here; the model here but only the VAD missing: the selected model's setup (which brings the VAD) without
    /// choosing it; a configured model missing: that one; else the recommended one.
    pub fn to_get(v: &Value) -> Option<(String, bool)> {
        let selected = v["selected"].as_str()?.to_string();
        let rec = v["recommended"].as_str().map(String::from).unwrap_or_else(|| selected.clone());
        let ready = v["ready"].as_bool().unwrap_or(false);
        let sel_in = v["selected_installed"].as_bool().unwrap_or_else(|| installed(v, &selected));
        if ready {
            return (!installed(v, &rec)).then_some((rec, true));
        }
        if sel_in {
            return Some((selected, false));
        }
        if let Some(c) = v["configured"].as_str() {
            if !v["configured_installed"].as_bool().unwrap_or(false) {
                return Some((c.to_string(), true));
            }
        }
        Some((rec, true))
    }

    /// The once-a-day "a weaker model ran" notice after a take recognised by `used`: only when the user didn't pick
    /// that model themselves.
    pub fn weaker_model_ran(v: &Value, used: Option<&str>) -> bool {
        let (Some(used), Some(rec)) = (used, v["recommended"].as_str()) else { return false };
        if installed(v, rec) || used == rec {
            return false;
        }
        !(v["configured"].as_str() == Some(used) && v["configured_installed"].as_bool().unwrap_or(false))
    }

    /// The selected model is a cloud service: the take goes to it whole at key-up (each pass is billed).
    pub fn selected_cloud(v: &Value) -> bool {
        v["selected_cloud"].as_bool().unwrap_or(false)
    }

    /// The cloud speech models (asr_models.json's `local: false` entries).
    pub const CLOUD: [&str; 3] = ["qwen3-asr-flash", "volcengine-seedasr", "openai-compatible"];
    /// Volcengine's: it hears the take while it is said (the server's `stream`)
    pub const STREAMS: &str = "volcengine-seedasr";

    /// A cloud model is the user's choice but can't run (its key isn't there): "Download…" can't help — the way out
    /// is Settings → Speech services.
    pub fn needs_key(v: &Value) -> bool {
        let configured = v["configured"].as_str().filter(|c| CLOUD.contains(c));
        configured.is_some() && !v["configured_installed"].as_bool().unwrap_or(false)
            || (selected_cloud(v) && !v["ready"].as_bool().unwrap_or(false))
    }

    /// The take streams to the selected cloud model while it is said (Volcengine).
    pub fn streams(v: &Value) -> bool {
        selected_cloud(v) && v["selected"].as_str() == Some(STREAMS)
    }
}

/// The cloud-polish reminder (the Mac's DictationCloudReminder): once ever, after `AFTER_TAKES` dictations that went
/// in, only into a quiet island, never in Blurt's own windows, never on a take that has a line of its own.
pub struct CloudReminder;

impl CloudReminder {
    pub const AFTER_TAKES: i64 = 10;
    pub const SECONDS: f64 = 8.0;
    pub fn due(takes: i64, shown: bool, cloud_ready: bool, in_blurt: bool, other_line: bool, idle: bool) -> bool {
        !shown && !cloud_ready && takes >= Self::AFTER_TAKES && !in_blurt && !other_line && idle
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// DictationTakeFlowTests.testRunawayRemindsAfterQuietAndWarnsBeforeTheLimit
    #[test]
    fn ear_targets() {
        assert_eq!(ear_target("auto"), "⇄");
        assert_eq!(ear_target("en"), "EN");
        assert_eq!(ear_target("zh|en"), "中");
        assert_eq!(ear_target("fr"), "FR");
    }

    #[test]
    fn speech_loop() {
        assert!(!SpeechLoop::looped(90, 6.0)); // 6 s of English
        assert!(!SpeechLoop::looped(219, 6.0));
        assert!(SpeechLoop::looped(2123, 6.0)); // the dogfood's loop
        assert!(SpeechLoop::looped(45, 0.0));
        assert!(!SpeechLoop::looped(1500, 180.0)); // a 3-minute take
    }

    #[test]
    fn runaway_reminds_after_quiet_and_warns_before_the_limit() {
        let mut r = Runaway::new();
        assert_eq!(r.feed(1.0, true, true), None);
        assert_eq!(r.feed(20.9, false, true), None);
        assert_eq!(r.feed(21.0, false, true), Some(RunawayNotice::StillListening));
        // once per quiet stretch
        assert_eq!(r.feed(30.0, false, true), None);
        // speech again: a new stretch may remind again
        assert_eq!(r.feed(40.0, true, true), None);
        assert_eq!(r.feed(60.0, false, true), Some(RunawayNotice::StillListening));
        // the warning comes once, at 4:30
        assert_eq!(r.feed(270.0, true, true), Some(RunawayNotice::EndsSoon));
        assert_eq!(r.feed(280.0, true, true), None);
    }

    #[test]
    fn push_to_talk_is_never_reminded_but_still_warned() {
        let mut r = Runaway::new();
        assert_eq!(r.feed(25.0, false, false), None);
        assert_eq!(r.feed(270.0, false, false), Some(RunawayNotice::EndsSoon));
    }

    #[test]
    fn the_clock_counts_down_from_four_thirty() {
        assert_eq!(Runaway::clock(0.0), ("0:00".to_string(), false));
        assert_eq!(Runaway::clock(65.4), ("1:05".to_string(), false));
        assert_eq!(Runaway::clock(269.9), ("4:29".to_string(), false));
        assert_eq!(Runaway::clock(270.0), ("\u{2212}0:30".to_string(), true));
        assert_eq!(Runaway::clock(270.5), ("\u{2212}0:30".to_string(), true));
        assert_eq!(Runaway::clock(299.2), ("\u{2212}0:01".to_string(), true));
        assert_eq!(Runaway::clock(305.0), ("\u{2212}0:00".to_string(), true));
    }

    fn shown(p: &[(&str, i64)]) -> HashMap<String, i64> {
        p.iter().map(|(k, v)| (k.to_string(), *v)).collect()
    }

    /// DictationTakeFlowTests.testTips
    #[test]
    fn tips_for_the_first_takes() {
        // a chat app: send, five times, only with double-tap send on and the take not sent already
        assert_eq!(Tip::next(true, true, false, &shown(&[])), Some(Tip::Send));
        assert_eq!(Tip::next(true, true, false, &shown(&[("send", 4)])), Some(Tip::Send));
        assert_eq!(Tip::next(true, true, false, &shown(&[("send", 5)])), None);
        assert_eq!(Tip::next(true, false, false, &shown(&[])), None);
        assert_eq!(Tip::next(true, true, true, &shown(&[])), None);
        // elsewhere: the list first, then the reformat key, each once
        assert_eq!(Tip::next(false, true, false, &shown(&[])), Some(Tip::List));
        assert_eq!(Tip::next(false, true, false, &shown(&[("list", 1)])), Some(Tip::Reformat));
        assert_eq!(Tip::next(false, true, false, &shown(&[("list", 1), ("reformat", 1)])), None);
        // sending isn't taught outside chat
        assert_ne!(Tip::next(false, true, false, &shown(&[("list", 1), ("reformat", 1)])), Some(Tip::Send));
    }

    /// DictationTakeFlowTests.testASRFailure + DictationASRLineTests
    #[test]
    fn recognition_failures_in_the_users_terms() {
        assert_eq!(AsrFailure::from_code(Some("model_missing")), AsrFailure::NoModel);
        assert_eq!(AsrFailure::from_code(Some("timeout")), AsrFailure::TimedOut);
        assert_eq!(AsrFailure::from_code(Some("asr_slow")), AsrFailure::TimedOut);
        assert_eq!(AsrFailure::from_code(Some("decode")), AsrFailure::Failed("decode".into()));
        assert_eq!(AsrFailure::from_code(None), AsrFailure::Failed("error".into()));
        assert_eq!(AsrFailure::from_code(Some("asr_slow")).code(), "timeout");
        assert_eq!(AsrFailure::NoModel.code(), "model_missing");

        assert_eq!(AsrFailure::NoModel.line(), AsrLine::Failed);
        assert_eq!(AsrFailure::TimedOut.line(), AsrLine::Slow);
        assert_eq!(AsrFailure::Failed("auth".into()).line(), AsrLine::CloudKey);
        assert_eq!(AsrFailure::Failed("network".into()).line(), AsrLine::CloudOffline);
        assert_eq!(AsrFailure::Failed("quota".into()).line(), AsrLine::CloudQuota);
        assert_eq!(AsrFailure::Failed("bad_response".into()).line(), AsrLine::Failed);
        assert!(!AsrLine::CloudKey.retry_helps());
        for l in [AsrLine::Failed, AsrLine::Slow, AsrLine::CloudOffline, AsrLine::CloudQuota] {
            assert!(l.retry_helps());
            assert!(l.key().starts_with("dictation.toast.asr_"));
        }

        assert!(AsrFailure::definite(Some("model_missing")));
        assert!(AsrFailure::definite(Some("auth")));
        assert!(AsrFailure::definite(Some("privacy")));
        assert!(!AsrFailure::definite(Some("timeout")));
        assert!(!AsrFailure::definite(None));

        assert_eq!(AsrFailure::server_timeout(20.0), 45.0);
        assert_eq!(AsrFailure::server_timeout(-1.0), 15.0);
    }

    #[test]
    fn a_take_never_waits_for_its_words_forever() {
        assert_eq!(TakeDeadline::seconds(0.0), 45.0);
        assert_eq!(TakeDeadline::seconds(30.0), 60.0);
        assert_eq!(TakeDeadline::seconds(300.0), 180.0);
    }

    /// DictationTakeFlowTests.testDeliveredLine: one line, never two in the same frame.
    #[test]
    fn delivered_line() {
        use DeliveredLine as L;
        assert_eq!(L::line("held", true, true, false), L::Held);
        assert_eq!(L::line("copied", false, true, false), L::Copied);
        assert_eq!(L::line("copied", true, true, false), L::CopiedNotSent);
        assert_eq!(L::line("pasted", false, true, false), L::None);
        assert_eq!(L::line("pasted", false, false, false), L::PastedUnsure);
        assert_eq!(L::line("pasted", false, false, true), L::NoField);
        assert_eq!(L::line("none", true, true, false), L::NotSent);
        assert_eq!(L::line("none", false, true, false), L::None);
        assert_eq!(L::Copied.copy_key(), Some("dictation.toast.copied"));
        assert_eq!(L::CopiedNotSent.copy_key(), Some("dictation.toast.copied.not_sent"));
        assert_eq!(L::NotSent.copy_key(), None);
        assert!(L::Copied.checked());
        assert!(!L::CopiedNotSent.checked());
        assert!(L::CopiedNotSent.copy_seconds() > L::Copied.copy_seconds());
    }

    #[test]
    fn a_double_tap_after_a_copy_holds_its_return() {
        assert!(CopiedGuard::holds_return(Some(10.0), false, 20.0));
        assert!(!CopiedGuard::holds_return(Some(10.0), false, 25.0));
        assert!(!CopiedGuard::holds_return(Some(10.0), true, 11.0));
        assert!(!CopiedGuard::holds_return(None, false, 11.0));
    }

    #[test]
    fn kept_text_preview() {
        assert_eq!(KeptText::preview("  short\ntext "), "short text");
        let long = "word ".repeat(30);
        let p = KeptText::preview(&long);
        assert!(p.ends_with('…'));
        assert!(p.chars().count() <= KeptText::LIMIT + 1);
        assert!(!p.contains("  "));
        // CJK: cut after a mark near the end, else at the limit
        let zh = format!("{}，{}", "字".repeat(70), "后".repeat(30));
        assert_eq!(KeptText::preview(&zh), format!("{}…", "字".repeat(70)));
        let none = "字".repeat(100);
        assert_eq!(KeptText::preview(&none), format!("{}…", "字".repeat(80)));
    }

    /// DictationSendRuleTests
    #[test]
    fn a_double_tap_sends_only_right_after_a_take() {
        use SendVerdict::*;
        assert_eq!(SendRule::decide(true, None, None, 0.0), Queue);
        assert_eq!(SendRule::decide(false, None, Some("WeChat.exe"), 10.0), NoTake);
        assert_eq!(SendRule::decide(false, Some((5.0, Some("WeChat.exe"))), Some("WeChat.exe"), 10.0), Send);
        assert_eq!(SendRule::decide(false, Some((5.0, Some("WeChat.exe"))), Some("Slack.exe"), 10.0), NoTake);
        assert_eq!(SendRule::decide(false, Some((5.0, Some("WeChat.exe"))), Some("WeChat.exe"), 70.0), NoTake);
    }

    /// DictationAccessTests.testFnClash, without the Fn guard (Windows has no Fn)
    #[test]
    fn clash_notices_once_a_day_never_over_a_listening_take() {
        let running = vec!["Typeless".to_string(), "Wispr Flow".to_string()];
        assert_eq!(Clash::to_mention(&running, |a| a == "Typeless"), vec!["Wispr Flow".to_string()]);
        assert!(Clash::to_mention(&running, |_| true).is_empty());
        assert_eq!(Clash::moment(&[], false), ClashMoment::None);
        assert_eq!(Clash::moment(&running, true), ClashMoment::AfterTake);
        assert_eq!(Clash::moment(&running, false), ClashMoment::Now);
    }

    #[test]
    fn toast_keys() {
        use toast_keys::*;
        assert!(DROPPED_AT_START.contains(&TAKE));
        assert!(DROPPED_AT_START.contains(&SLOW));
        // a failed take's Retry and "Cancelled · Undo" survive a new take
        assert!(!DROPPED_AT_START.contains(&CANCEL));
        assert!(!DROPPED_AT_START.contains(&failed("d-1").as_str()));
        assert!(!DROPPED_AT_START.contains(&NOTICE));
        assert_eq!(DROPPED_WHEN_LISTENING_ENDS, [STYLE]);
        assert_eq!(mark("dictation.toast.asr_slow"), Some("warning"));
        assert_eq!(mark("dictation.toast.no_model.kept"), Some("warning"));
        assert_eq!(mark("dictation.translate.toast.unavailable"), Some("warning"));
        assert_eq!(mark("dictation.toast.copied"), Some("check"));
        assert_eq!(mark("dictation.toast.copied.not_sent"), Some("check"));
        assert_eq!(mark("dictation.toast.not_sent.secure"), Some("warning"));
        assert_eq!(mark("dictation.toast.not_sent.elevated"), Some("warning"));
        assert_eq!(mark("dictation.toast.nothing.silent"), Some("warning"));
        assert_eq!(mark("dictation.toast.nothing.named"), None);
        assert_eq!(mark("dictation.style.reformatted"), Some("check"));
        assert_eq!(mark("dictation.remember.saved.both"), Some("check"));
        assert_eq!(mark("dictation.remember.kept.both"), None);
        assert_eq!(mark("dictation.toast.model_started.size"), Some("spinner"));
        assert_eq!(mark("dictation.toast.no_model.downloading"), Some("warning"));
        assert_eq!(mark("dictation.toast.cancelled"), None);
        assert_eq!(mark("dictation.toast.mic"), Some("warning"));
        assert_eq!(mark("dictation.toast.mic_settings"), None);
        assert_eq!(mark("dictation.toast.ends_soon"), Some("warning"));
    }

    #[test]
    fn nothing_heard_names_a_silent_mic() {
        use nothing_heard::*;
        assert!(silent_mic(0.05, 50)); // −57 dBFS at the loudest: the mic gives nothing
        assert!(!silent_mic(0.05, 3)); // a blink
        assert!(!silent_mic(0.3, 50)); // a room, or speech
        assert_eq!(key(true, true), "dictation.toast.nothing.silent");
        assert_eq!(key(false, true), "dictation.toast.nothing.named");
        assert_eq!(key(true, false), "dictation.toast.nothing");
    }

    /// DictationTakeFlowTests.testSpeechModels
    #[test]
    fn what_download_gets() {
        use serde_json::json;
        use speech_models::*;
        let rows = |sel_in: bool, rec_in: bool| json!([{"id": "fun-asr-nano-onnx", "installed": rec_in}, {"id": "sensevoice-small", "installed": sel_in}]);
        // nothing here: the recommended one, chosen
        let v = json!({"selected": "fun-asr-nano-onnx", "recommended": "fun-asr-nano-onnx", "ready": false, "selected_installed": false, "models": rows(false, false)});
        assert_eq!(to_get(&v), Some(("fun-asr-nano-onnx".into(), true)));
        // only the VAD missing: the selected model's setup, not chosen again
        let v = json!({"selected": "sensevoice-small", "recommended": "fun-asr-nano-onnx", "ready": false, "selected_installed": true, "missing": ["silero-vad"], "models": rows(true, false)});
        assert_eq!(to_get(&v), Some(("sensevoice-small".into(), false)));
        // a configured model missing: that one
        let v = json!({"selected": "fun-asr-nano-onnx", "recommended": "fun-asr-nano-onnx", "configured": "sensevoice-small", "configured_installed": false, "ready": false, "selected_installed": false, "models": rows(false, false)});
        assert_eq!(to_get(&v), Some(("sensevoice-small".into(), true)));
        // ready with a weaker model: the recommended one; with it: nothing
        let v = json!({"selected": "sensevoice-small", "recommended": "fun-asr-nano-onnx", "ready": true, "selected_installed": true, "models": rows(true, false)});
        assert_eq!(to_get(&v), Some(("fun-asr-nano-onnx".into(), true)));
        assert!(weaker_model_ran(&v, Some("sensevoice-small")));
        assert!(!weaker_model_ran(&v, Some("fun-asr-nano-onnx")));
        assert!(!weaker_model_ran(&v, None));
        // the user picked it: not a fallback
        let mine = json!({"selected": "sensevoice-small", "recommended": "fun-asr-nano-onnx", "configured": "sensevoice-small", "configured_installed": true, "ready": true, "models": rows(true, false)});
        assert!(!weaker_model_ran(&mine, Some("sensevoice-small")));
        let all = json!({"selected": "fun-asr-nano-onnx", "recommended": "fun-asr-nano-onnx", "ready": true, "selected_installed": true, "models": rows(true, true)});
        assert_eq!(to_get(&all), None);
        assert!(selected_cloud(&json!({"selected_cloud": true})));
    }

    #[test]
    fn the_cloud_reminder() {
        assert!(CloudReminder::due(10, false, false, false, false, true));
        assert!(!CloudReminder::due(9, false, false, false, false, true));
        assert!(!CloudReminder::due(10, true, false, false, false, true));
        assert!(!CloudReminder::due(10, false, true, false, false, true));
        assert!(!CloudReminder::due(10, false, false, true, false, true));
        assert!(!CloudReminder::due(10, false, false, false, true, true));
        assert!(!CloudReminder::due(10, false, false, false, false, false));
    }

    #[test]
    fn a_cloud_model_without_its_key() {
        use serde_json::json;
        use speech_models::*;
        assert!(needs_key(&json!({"configured": "qwen3-asr-flash", "configured_installed": false, "selected": "fun-asr-nano-onnx"})));
        assert!(!needs_key(&json!({"configured": "qwen3-asr-flash", "configured_installed": true})));
        assert!(!needs_key(&json!({"configured": "fun-asr-nano-onnx", "configured_installed": false})));
        assert!(streams(&json!({"selected": "volcengine-seedasr", "selected_cloud": true})));
        assert!(!streams(&json!({"selected": "qwen3-asr-flash", "selected_cloud": true})));
    }
}
