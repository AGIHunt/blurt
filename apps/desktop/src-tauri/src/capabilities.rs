//! The five things Blurt does, as one list the whole app is arranged by (docs/design/capabilities.md; the Mac's
//! BlurtCore/Capabilities.swift): the tray menu, the island, the hotkeys, the phone host and the main window (which
//! reads `capabilities_get` / `capabilities://changed`) all follow it — and each can be turned off as a whole. Off
//! means gone: its shortcuts aren't registered and can't be fired (not from the tray, a deep link or a paired phone
//! either: `crate::dispatch` asks `allows`), its menu rows, island buttons and counts don't show, and nothing of it
//! runs in the background (the phone host doesn't listen; dictation's engine reads its own switch).
//!
//!   dictation    the dictation key → text at the cursor                 record.dictation.enabled (as before)
//!   cards        snap and voice note → cards at the top of the screen   app.capabilities.cards
//!   screen_text  copy / translate text from the screen                  app.capabilities.screen_text
//!   recording    screen recording → items, and the projects they go in  app.capabilities.recording
//!   phone        the phone as trackpad, keys, mic and screen            app.capabilities.phone
//!
//! Every one is on unless config.json says `false` (an install from before the switches keeps everything it had).
//! config.json is shared with the scripts and the Mac app: the same keys on every platform.
//!
//! Whoever changes a switch — the main window (`capability_set`), Settings' own dictation switch (`settings_set`), or
//! config.json edited by hand or by an agent (the watcher, within a second) — `changed` runs once and the app follows.

use std::collections::BTreeSet;
use std::sync::Mutex;
use std::time::Duration;

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter};

use crate::settings;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Capability {
    Dictation,
    Cards,
    ScreenText,
    Recording,
    Phone,
}

pub const ALL: [Capability; 5] = [Capability::Dictation, Capability::Cards, Capability::ScreenText, Capability::Recording, Capability::Phone];

/// The shortcuts that only mean something while a recording runs: registered only then (hotkeys.rs RESIDENT).
pub const WHILE_RECORDING: [&str; 3] = ["pause", "pen", "stop"];

impl Capability {
    pub fn id(self) -> &'static str {
        match self {
            Capability::Dictation => "dictation",
            Capability::Cards => "cards",
            Capability::ScreenText => "screen_text",
            Capability::Recording => "recording",
            Capability::Phone => "phone",
        }
    }

    pub fn from_id(id: &str) -> Option<Capability> {
        ALL.into_iter().find(|c| c.id() == id)
    }

    /// Where its switch lives in config.json, as a JSON pointer. Dictation keeps the key it always had.
    pub fn pointer(self) -> String {
        match self {
            Capability::Dictation => "/record/dictation/enabled".into(),
            c => format!("/app/capabilities/{}", c.id()),
        }
    }

    /// The global shortcuts that are this capability's (hotkeys.rs action names). "menu" (Open Blurt) is nobody's.
    pub fn hotkeys(self) -> &'static [&'static str] {
        match self {
            Capability::Dictation => &["reformat"],
            Capability::Cards => &["snap", "voice", "cards"],
            Capability::ScreenText => &["text", "translate"],
            Capability::Recording => &["record", "pause", "pen", "stop", "project"],
            Capability::Phone => &[],
        }
    }
}

pub fn is_on(c: Capability, cfg: &Value) -> bool {
    cfg.pointer(&c.pointer()).and_then(Value::as_bool) != Some(false)
}

/// The capabilities turned off in this config.
pub fn off(cfg: &Value) -> BTreeSet<Capability> {
    ALL.into_iter().filter(|c| !is_on(*c, cfg)).collect()
}

pub fn off_now() -> BTreeSet<Capability> {
    off(&settings::read_config())
}

pub fn on_now(c: Capability) -> bool {
    !off_now().contains(&c)
}

pub fn ids(off: &BTreeSet<Capability>) -> Vec<&'static str> {
    let mut v: Vec<&'static str> = off.iter().map(|c| c.id()).collect();
    v.sort_unstable();
    v
}

pub fn owner(action: &str) -> Option<Capability> {
    ALL.into_iter().find(|c| c.hotkeys().contains(&action))
}

/// The shortcuts that are off with their capabilities. While a recording runs the snap key marks a moment in it, so
/// Snap stays for its length even with Cards off.
pub fn disabled_hotkeys(off: &BTreeSet<Capability>, recording: bool) -> BTreeSet<&'static str> {
    let mut out: BTreeSet<&'static str> = off.iter().flat_map(|c| c.hotkeys().iter().copied()).collect();
    if recording && !off.contains(&Capability::Recording) {
        out.remove("snap");
    }
    out
}

/// Whether an action — a key pressed, a tray row, a deep link, a paired phone's command — may act now.
pub fn allows(action: &str, off: &BTreeSet<Capability>, recording: bool) -> bool {
    !disabled_hotkeys(off, recording).contains(action)
}

/// The switch written into a config: on = the key removed (the default), off = `false`.
pub fn apply_switch(cfg: &mut Value, c: Capability, on: bool) {
    if !cfg.is_object() {
        *cfg = json!({});
    }
    let (outer, inner, key) = match c {
        Capability::Dictation => ("record", "dictation", "enabled"),
        c => ("app", "capabilities", c.id()),
    };
    let o = cfg.as_object_mut().unwrap();
    let a = o.entry(outer).or_insert_with(|| json!({}));
    if !a.is_object() {
        *a = json!({});
    }
    let b = a.as_object_mut().unwrap().entry(inner).or_insert_with(|| json!({}));
    if !b.is_object() {
        *b = json!({});
    }
    let m = b.as_object_mut().unwrap();
    if on {
        m.remove(key);
    } else {
        m.insert(key.into(), json!(false));
    }
    // an empty app.capabilities isn't left behind
    if c != Capability::Dictation && m.is_empty() {
        cfg["app"].as_object_mut().unwrap().remove("capabilities");
    }
}

/// Turn a capability on or off (config.json, read-modify-write under its lock), then make the app follow at once.
pub fn set(app: &AppHandle, c: Capability, on: bool) -> Result<(), String> {
    settings::update(|cfg| apply_switch(cfg, c, on))?;
    changed(app);
    Ok(())
}

/// The off set the app last followed (None: not looked yet).
static LAST: Mutex<Option<BTreeSet<Capability>>> = Mutex::new(None);

/// The switches may have changed (anyone's write): when they did, the app follows — hotkeys registered again, the tray
/// and the island rebuilt, the phone host listening or not, a dictation model download stopped with dictation, and
/// the main window told (`capabilities://changed` {"off": [ids]}).
pub fn changed(app: &AppHandle) {
    let now = off_now();
    let was = {
        let mut l = LAST.lock().unwrap();
        let was = l.clone();
        if was.as_ref() == Some(&now) {
            return;
        }
        *l = Some(now.clone());
        was
    };
    let flipped = |c: Capability| was.as_ref().is_none_or(|w| w.contains(&c) != now.contains(&c));
    crate::hotkeys::apply(app, None);
    crate::tray::refresh(app);
    crate::island::refresh(app);
    crate::island::refresh_cards(app);
    if flipped(Capability::Phone) {
        crate::remote::capability_changed();
    }
    // dictation turned off: the speech model it was fetching stops with it
    if now.contains(&Capability::Dictation) && was.as_ref().is_some_and(|w| !w.contains(&Capability::Dictation)) {
        crate::dictation::commands::model_download_cancel();
    }
    let _ = app.emit("capabilities://changed", json!({"off": ids(&now)}));
}

/// Watches config.json (its modification time, once a second): a hand edit or an agent's write is followed too.
pub fn watch(app: &AppHandle) {
    *LAST.lock().unwrap() = Some(off_now());
    let app = app.clone();
    std::thread::spawn(move || {
        let stamp = || std::fs::metadata(crate::paths::config_file()).and_then(|m| m.modified()).ok();
        let mut seen = stamp();
        loop {
            std::thread::sleep(Duration::from_secs(1));
            let s = stamp();
            if s != seen {
                seen = s;
                changed(&app);
            }
        }
    });
}

#[tauri::command]
pub fn capabilities_get() -> Value {
    json!({"off": ids(&off_now())})
}

#[tauri::command]
pub fn capability_set(app: AppHandle, id: String, on: bool) -> Result<Value, String> {
    let c = Capability::from_id(&id).ok_or_else(|| format!("unknown capability {id}"))?;
    set(&app, c, on)?;
    Ok(capabilities_get())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_on_by_default_and_only_false_is_off() {
        assert!(off(&json!({})).is_empty());
        let cfg = json!({"record": {"dictation": {"enabled": false}}, "app": {"capabilities": {"cards": false, "phone": true, "recording": "no", "screen_text": null}}});
        assert_eq!(off(&cfg), BTreeSet::from([Capability::Dictation, Capability::Cards]));
        assert_eq!(ids(&off(&cfg)), vec!["cards", "dictation"]);
        assert_eq!(Capability::from_id("screen_text"), Some(Capability::ScreenText));
    }

    #[test]
    fn every_action_has_one_owner_but_open() {
        for a in crate::hotkeys::ACTIONS {
            let n = ALL.iter().filter(|c| c.hotkeys().contains(&a)).count();
            assert_eq!(n, usize::from(a != "menu"), "{a}");
        }
        for c in ALL {
            for a in c.hotkeys() {
                assert!(crate::hotkeys::ACTIONS.contains(a), "{a}");
            }
        }
        for a in WHILE_RECORDING {
            assert_eq!(owner(a), Some(Capability::Recording));
        }
    }

    #[test]
    fn snap_marks_a_recording_with_cards_off() {
        let off = BTreeSet::from([Capability::Cards]);
        assert!(!allows("snap", &off, false));
        assert!(allows("snap", &off, true));
        assert!(!allows("voice", &off, true));
        assert!(allows("record", &off, false));
        assert!(allows("menu", &off, false));
        let both = BTreeSet::from([Capability::Cards, Capability::Recording]);
        assert!(!allows("snap", &both, true));
        assert!(!allows("record", &both, false));
    }

    #[test]
    fn switch_writes_false_or_nothing() {
        let mut cfg = json!({"app": {"editor": "code"}, "record": {"dictation": {"key": "right_option"}}});
        apply_switch(&mut cfg, Capability::Cards, false);
        apply_switch(&mut cfg, Capability::Dictation, false);
        assert_eq!(cfg, json!({"app": {"editor": "code", "capabilities": {"cards": false}}, "record": {"dictation": {"key": "right_option", "enabled": false}}}));
        apply_switch(&mut cfg, Capability::Cards, true);
        apply_switch(&mut cfg, Capability::Dictation, true);
        assert_eq!(cfg, json!({"app": {"editor": "code"}, "record": {"dictation": {"key": "right_option"}}}));
        let mut empty = json!({});
        apply_switch(&mut empty, Capability::Phone, false);
        assert_eq!(off(&empty), BTreeSet::from([Capability::Phone]));
    }
}
