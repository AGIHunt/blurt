//! Global shortcuts: config `record.hotkeys` {"record": "opt+shift+R", "snap": "off", …}, the grammar of
//! `_common.parse_hotkey` / Hotkeys.swift (opt = Alt, cmd = the Windows / Super key here).
//!
//! Windows and X11 register through tauri-plugin-global-shortcut. On Wayland an app can't grab keys: we bind through
//! the xdg-desktop-portal GlobalShortcuts interface (GNOME 48+, KDE), and where there's no portal the settings page
//! guides the user to bind a system shortcut to `blurt blurt://record` (the deep link reaches this instance).
//!
//! Conflicts shown in Settings (C7's HotkeyResult): two of our actions on the same keys (`duplicate`), a known system
//! shortcut (`system`), the OS refused it — usually another app holds it (`taken`).

use std::collections::HashMap;
use std::str::FromStr;
use std::sync::Mutex;

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut};

use crate::settings;

pub const ACTIONS: [&str; 7] = ["record", "menu", "pause", "snap", "marker", "pen", "stop"];
/// Registered whenever the app runs; the others only while recording (they'd steal keys from other apps otherwise).
pub const RESIDENT: [&str; 3] = ["record", "menu", "snap"];

fn default_key(a: &str) -> &'static str {
    match a {
        "record" => "R",
        "menu" => "B",
        "pause" => "P",
        "snap" => "A",
        "marker" => "M",
        "pen" => "D",
        _ => "S",
    }
}

const MOD_ORDER: [&str; 4] = ["ctrl", "opt", "shift", "cmd"];

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Combo {
    pub mods: Vec<String>, // canonical order, subset of MOD_ORDER
    pub key: String,       // "R", "5", "F5", "Space", "Left", "-", …
}

impl Combo {
    pub fn spec(&self) -> String {
        let mut v = self.mods.clone();
        v.push(self.key.clone());
        v.join("+")
    }

    pub fn label(&self) -> String {
        if cfg!(target_os = "macos") {
            let g: String = self
                .mods
                .iter()
                .map(|m| match m.as_str() {
                    "ctrl" => "⌃",
                    "opt" => "⌥",
                    "shift" => "⇧",
                    _ => "⌘",
                })
                .collect();
            return g + &self.key;
        }
        let sup = if cfg!(windows) { "Win" } else { "Super" };
        let mut v: Vec<&str> = self
            .mods
            .iter()
            .map(|m| match m.as_str() {
                "ctrl" => "Ctrl",
                "opt" => "Alt",
                "shift" => "Shift",
                _ => sup,
            })
            .collect();
        v.push(&self.key);
        v.join("+")
    }

    /// XDG "shortcuts" spec trigger for the portal, e.g. "ALT+SHIFT+r".
    pub fn xdg_trigger(&self) -> String {
        let mut v: Vec<String> = self
            .mods
            .iter()
            .map(|m| match m.as_str() {
                "ctrl" => "CTRL",
                "opt" => "ALT",
                "shift" => "SHIFT",
                _ => "LOGO",
            }
            .to_string())
            .collect();
        v.push(if self.key.len() == 1 { self.key.to_lowercase() } else { self.key.clone() });
        v.join("+")
    }

    pub fn to_shortcut(&self) -> Option<Shortcut> {
        let mut m = Modifiers::empty();
        for x in &self.mods {
            m |= match x.as_str() {
                "ctrl" => Modifiers::CONTROL,
                "opt" => Modifiers::ALT,
                "shift" => Modifiers::SHIFT,
                _ => Modifiers::SUPER,
            };
        }
        let k = self.key.as_str();
        let code = match k {
            _ if k.len() == 1 && k.as_bytes()[0].is_ascii_uppercase() => format!("Key{k}"),
            _ if k.len() == 1 && k.as_bytes()[0].is_ascii_digit() => format!("Digit{k}"),
            "Space" | "Tab" => k.to_string(),
            "Return" => "Enter".into(),
            "Left" | "Right" | "Up" | "Down" => format!("Arrow{k}"),
            "-" => "Minus".into(),
            "=" => "Equal".into(),
            "[" => "BracketLeft".into(),
            "]" => "BracketRight".into(),
            ";" => "Semicolon".into(),
            "'" => "Quote".into(),
            "," => "Comma".into(),
            "." => "Period".into(),
            "/" => "Slash".into(),
            "\\" => "Backslash".into(),
            "`" => "Backquote".into(),
            _ => k.to_string(), // F1…F20
        };
        let code = Code::from_str(&code).ok()?;
        Some(Shortcut::new(if m.is_empty() { None } else { Some(m) }, code))
    }
}

fn mod_alias(t: &str) -> Option<&'static str> {
    Some(match t {
        "ctrl" | "control" | "⌃" | "^" => "ctrl",
        "opt" | "option" | "alt" | "⌥" => "opt",
        "shift" | "⇧" => "shift",
        "cmd" | "command" | "⌘" | "win" | "super" | "meta" => "cmd",
        _ => return None,
    })
}

fn key_name(tok: &str) -> Option<String> {
    let mut ch = tok.chars();
    if let (Some(c), None) = (ch.next(), ch.next()) {
        if c.is_ascii_alphanumeric() || "-=[];',./\\`".contains(c) {
            return Some(c.to_ascii_uppercase().to_string());
        }
        return None;
    }
    let low = tok.to_lowercase();
    let named = match low.as_str() {
        "space" | "spacebar" => Some("Space"),
        "tab" => Some("Tab"),
        "return" | "enter" => Some("Return"),
        "left" | "←" => Some("Left"),
        "right" | "→" => Some("Right"),
        "up" | "↑" => Some("Up"),
        "down" | "↓" => Some("Down"),
        _ => None,
    };
    if let Some(n) = named {
        return Some(n.into());
    }
    if let Some(n) = low.strip_prefix('f').and_then(|d| d.parse::<u8>().ok()) {
        if (1..=20).contains(&n) {
            return Some(format!("F{n}"));
        }
    }
    None
}

/// `_common.parse_hotkey`: None for off / empty / unparseable; needs ctrl/opt/cmd unless it's an F-key.
pub fn parse(spec: &str) -> Option<Combo> {
    let s = spec.trim();
    if ["off", "none", "disabled", "-", ""].contains(&s.to_lowercase().as_str()) {
        return None;
    }
    let mut mods: Vec<&str> = Vec::new();
    let mut rest = s;
    while let Some(c) = rest.chars().next() {
        if "⌃⌥⇧⌘^".contains(c) {
            mods.push(mod_alias(&c.to_string())?);
            rest = &rest[c.len_utf8()..];
        } else {
            break;
        }
    }
    let mut key: Option<String> = None;
    for tok in rest.replace(' ', "").split('+') {
        if tok.is_empty() {
            continue;
        }
        let low = tok.to_lowercase();
        let m = mod_alias(&low).filter(|_| tok.chars().count() > 1 || "⌃⌥⇧⌘".contains(tok));
        if let Some(m) = m {
            mods.push(m);
        } else if key.is_none() && key_name(tok).is_some() {
            key = key_name(tok);
        } else {
            return None;
        }
    }
    let key = key?;
    let strong = mods.iter().any(|m| *m != "shift");
    if !(strong || key.starts_with('F') && key.len() > 1) {
        return None;
    }
    Some(Combo { mods: MOD_ORDER.iter().filter(|m| mods.contains(m)).map(|m| m.to_string()).collect(), key })
}

/// action → combo (None = off), with the defaults (⌥⇧ + key, or $BLURT_HOTKEY_MODS) for missing / bad entries.
pub fn from_config(cfg: &Value) -> Vec<(&'static str, Option<Combo>)> {
    let user = cfg.pointer("/record/hotkeys").and_then(Value::as_object).cloned().unwrap_or_default();
    let env = std::env::var("BLURT_HOTKEY_MODS").unwrap_or_default();
    let want: Vec<&str> = env.split('+').filter_map(|t| mod_alias(t.trim().to_lowercase().as_str())).collect();
    let mut dmods: Vec<String> = MOD_ORDER.iter().filter(|m| want.contains(m)).map(|m| m.to_string()).collect();
    if dmods.is_empty() {
        dmods = vec!["opt".into(), "shift".into()];
    }
    ACTIONS
        .iter()
        .map(|a| {
            let v = user.get(*a);
            let off = v == Some(&Value::Bool(false))
                || v.and_then(Value::as_str).is_some_and(|s| ["off", "none", "disabled", "-", ""].contains(&s.trim().to_lowercase().as_str()));
            let c = if off {
                None
            } else if let Some(c) = v.and_then(Value::as_str).and_then(parse) {
                Some(c)
            } else {
                Some(Combo { mods: dmods.clone(), key: default_key(a).into() })
            };
            (*a, c)
        })
        .collect()
}

/// Shortcuts the OS (or the desktop) already uses; registering them would fail or break the system one.
pub fn system_conflict(c: &Combo) -> Option<&'static str> {
    let s = c.spec();
    let table: &[(&str, &str)] = if cfg!(windows) {
        &[
            ("shift+cmd+S", "Snipping Tool"),
            ("cmd+L", "Lock screen"),
            ("cmd+D", "Show desktop"),
            ("cmd+E", "File Explorer"),
            ("cmd+R", "Run"),
            ("cmd+V", "Clipboard history"),
            ("cmd+.", "Emoji panel"),
            ("cmd+G", "Game Bar"),
            ("opt+cmd+R", "Game Bar: record"),
            ("cmd+I", "Settings"),
            ("cmd+A", "Quick Settings"),
            ("cmd+N", "Notifications"),
            ("cmd+Tab", "Task View"),
            ("opt+Tab", "Switch windows"),
            ("opt+F4", "Close window"),
            ("ctrl+shift+Esc", "Task Manager"),
        ]
    } else if cfg!(target_os = "macos") {
        &[
            ("shift+cmd+3", "Screenshot"),
            ("shift+cmd+4", "Screenshot (area)"),
            ("shift+cmd+5", "Screenshot toolbar"),
            ("cmd+Space", "Spotlight"),
            ("cmd+Tab", "App switcher"),
        ]
    } else {
        &[
            ("opt+Tab", "Switch windows"),
            ("opt+F2", "Run command"),
            ("opt+F4", "Close window"),
            ("cmd+L", "Lock screen"),
            ("cmd+A", "Show apps"),
            ("cmd+V", "Notification list"),
            ("cmd+D", "Hide all windows"),
            ("cmd+Space", "Switch input source"),
            ("ctrl+opt+T", "Terminal"),
            ("ctrl+opt+Delete", "Log out"),
            ("ctrl+opt+shift+R", "GNOME screencast"),
            ("ctrl+opt+Left", "Workspace left"),
            ("ctrl+opt+Right", "Workspace right"),
        ]
    };
    table.iter().find(|(k, _)| *k == s).map(|(_, n)| *n)
}

pub fn is_wayland() -> bool {
    cfg!(target_os = "linux")
        && (std::env::var("XDG_SESSION_TYPE").is_ok_and(|v| v.eq_ignore_ascii_case("wayland")) || std::env::var_os("WAYLAND_DISPLAY").is_some())
}

#[derive(Default)]
pub struct Hotkeys {
    /// action → what we registered with the plugin
    registered: Mutex<HashMap<String, Shortcut>>,
    /// action → status row shown in Settings
    status: Mutex<HashMap<String, Value>>,
    /// "plugin" | "portal" | "portal-pending" | "manual" (Wayland without portal)
    pub mode: Mutex<String>,
    recording: Mutex<bool>,
}

/// Which action a pressed shortcut belongs to.
pub fn action_for(app: &AppHandle, sc: &Shortcut) -> Option<String> {
    let h = app.state::<Hotkeys>();
    let reg = h.registered.lock().unwrap();
    reg.iter().find(|(_, s)| s.id() == sc.id()).map(|(a, _)| a.clone())
}

/// (Re)register for the current config and recording state. Returns the status rows.
pub fn apply(app: &AppHandle, recording: Option<bool>) -> Vec<Value> {
    let h = app.state::<Hotkeys>();
    if let Some(r) = recording {
        *h.recording.lock().unwrap() = r;
    }
    let rec = *h.recording.lock().unwrap();
    let cfg = settings::read_config();
    let combos = from_config(&cfg);
    let gs = app.global_shortcut();
    // drop what we hold, then register again in action order (the first of two duplicates wins)
    {
        let mut reg = h.registered.lock().unwrap();
        for (_, s) in reg.drain() {
            let _ = gs.unregister(s);
        }
    }
    let wayland = is_wayland();
    if wayland && h.mode.lock().unwrap().is_empty() {
        *h.mode.lock().unwrap() = "portal-pending".into();
        #[cfg(target_os = "linux")]
        portal::start(app.clone(), combos.clone());
    }
    if !wayland {
        *h.mode.lock().unwrap() = "plugin".into();
    }
    let mode = h.mode.lock().unwrap().clone();
    let mut seen: HashMap<String, &str> = HashMap::new();
    let mut rows = Vec::new();
    let mut status = h.status.lock().unwrap();
    for (a, c) in &combos {
        let active = RESIDENT.contains(a) || rec;
        let mut row = json!({"action": a, "active": active, "default": format!("opt+shift+{}", default_key(a))});
        let Some(c) = c else {
            row["result"] = json!("off");
            row["spec"] = json!("off");
            row["label"] = json!("");
            rows.push(row);
            continue;
        };
        row["spec"] = json!(c.spec());
        row["label"] = json!(c.label());
        if let Some(first) = seen.get(&c.spec()) {
            row["result"] = json!("duplicate");
            row["of"] = json!(first);
        } else if let Some(name) = system_conflict(c) {
            seen.insert(c.spec(), a);
            row["result"] = json!("system");
            row["name"] = json!(name);
        } else {
            seen.insert(c.spec(), a);
            if *a == "pen" {
                row["result"] = json!("unsupported"); // the pen overlay is macOS-only for now (WP8 brings overlays)
            } else if wayland {
                row["result"] = json!(if mode == "portal" { "portal" } else if mode == "manual" { "manual" } else { "pending" });
            } else if !active {
                row["result"] = json!("idle");
            } else {
                match c.to_shortcut() {
                    Some(sc) if gs.register(sc).is_ok() => {
                        h.registered.lock().unwrap().insert(a.to_string(), sc);
                        row["result"] = json!("ok");
                    }
                    Some(_) => row["result"] = json!("taken"),
                    None => row["result"] = json!("invalid"),
                }
            }
        }
        status.insert(a.to_string(), row.clone());
        rows.push(row);
    }
    let _ = app.emit("hotkeys://changed", json!(rows));
    rows
}

pub fn rows(app: &AppHandle) -> Vec<Value> {
    let h = app.state::<Hotkeys>();
    let st = h.status.lock().unwrap();
    ACTIONS.iter().filter_map(|a| st.get(*a).cloned()).collect()
}

/// shortcut_set(action, combo) → HotkeyResult. A combo that is a duplicate / system / taken isn't saved.
pub fn set(app: &AppHandle, action: &str, combo: &str) -> Value {
    if !ACTIONS.contains(&action) {
        return json!({"result": "invalid", "error": format!("unknown action {action}")});
    }
    let off = ["off", "none", "disabled", "-", ""].contains(&combo.trim().to_lowercase().as_str());
    let parsed = if off { None } else { parse(combo) };
    if !off && parsed.is_none() {
        return json!({"result": "invalid", "error": "needs Ctrl, Alt or Win/Super plus a key (F-keys may stand alone)"});
    }
    if let Some(c) = &parsed {
        let cfg = settings::read_config();
        for (a, other) in from_config(&cfg) {
            if a != action && other.as_ref() == Some(c) {
                return json!({"result": "duplicate", "action": a, "spec": c.spec(), "label": c.label()});
            }
        }
        if let Some(name) = system_conflict(c) {
            return json!({"result": "system", "name": name, "spec": c.spec(), "label": c.label()});
        }
        // probe: can we register it? (skip when it's what we already hold for this action)
        if !is_wayland() {
            let gs = app.global_shortcut();
            let held = app.state::<Hotkeys>().registered.lock().unwrap().get(action).copied();
            if let Some(sc) = c.to_shortcut() {
                if held.map(|h| h.id()) != Some(sc.id()) {
                    if gs.register(sc).is_err() {
                        return json!({"result": "taken", "spec": c.spec(), "label": c.label()});
                    }
                    let _ = gs.unregister(sc);
                }
            }
        }
    }
    let spec = parsed.as_ref().map_or("off".to_string(), Combo::spec);
    // record.hotkeys is replaced as a whole by the merge rule: carry the other actions over
    let mut hk = settings::read_config().pointer("/record/hotkeys").and_then(Value::as_object).cloned().unwrap_or_default();
    hk.insert(action.to_string(), json!(spec));
    if let Err(e) = settings::merge(json!({"record": {"hotkeys": hk}})) {
        return json!({"result": "invalid", "error": e});
    }
    let rows = apply(app, None);
    let row = rows.into_iter().find(|r| r["action"] == action).unwrap_or(json!({}));
    let mut out = json!({"result": "ok", "spec": spec, "label": parsed.as_ref().map(Combo::label).unwrap_or_default()});
    if is_wayland() {
        out["result"] = json!("ok");
        out["hint"] = json!(wayland_hint(action));
    }
    out["row"] = row;
    out
}

pub fn wayland_hint(action: &str) -> String {
    let url = match action {
        "menu" => "blurt://open",
        "snap" => "blurt://snap",
        "pause" => "blurt://pause",
        "stop" => "blurt://stop",
        "marker" => "blurt://marker",
        _ => "blurt://record",
    };
    format!("Wayland: change it in Settings → Keyboard → Shortcuts (Blurt), or add a custom shortcut with the command `blurt {url}`")
}

pub fn fire(app: &AppHandle, action: &str) {
    crate::dispatch(app, action);
}

#[cfg(target_os = "linux")]
mod portal {
    use super::*;
    use ashpd::desktop::global_shortcuts::{BindShortcutsOptions, GlobalShortcuts, NewShortcut};
    use ashpd::desktop::CreateSessionOptions;
    use futures_util::StreamExt;

    fn describe(a: &str) -> &'static str {
        match a {
            "record" => "Start / finish recording",
            "menu" => "Open Blurt",
            "snap" => "Snap",
            "pause" => "Pause / resume",
            "marker" => "Marker",
            "stop" => "Finish recording",
            _ => "Pen",
        }
    }

    pub fn start(app: AppHandle, combos: Vec<(&'static str, Option<Combo>)>) {
        tauri::async_runtime::spawn(async move {
            let res: Result<(), ashpd::Error> = async {
                let gs = GlobalShortcuts::new().await?;
                let session = gs.create_session(CreateSessionOptions::default()).await?;
                let triggers: Vec<(String, Option<String>)> = combos
                    .iter()
                    .filter(|(a, _)| *a != "pen")
                    .map(|(a, c)| (a.to_string(), c.as_ref().map(Combo::xdg_trigger)))
                    .collect();
                let new: Vec<NewShortcut> = triggers
                    .iter()
                    .map(|(a, t)| NewShortcut::new(a.as_str(), describe(a)).preferred_trigger(t.as_deref()))
                    .collect();
                let bound = gs.bind_shortcuts(&session, &new, None, BindShortcutsOptions::default()).await?.response()?;
                let labels: HashMap<String, String> =
                    bound.shortcuts().iter().map(|s| (s.id().to_string(), s.trigger_description().to_string())).collect();
                *app.state::<Hotkeys>().mode.lock().unwrap() = "portal".into();
                {
                    let h = app.state::<Hotkeys>();
                    let mut st = h.status.lock().unwrap();
                    for (a, l) in &labels {
                        if let Some(r) = st.get_mut(a) {
                            r["result"] = json!("portal");
                            r["label"] = json!(l);
                        }
                    }
                }
                let _ = app.emit("hotkeys://changed", json!(rows(&app)));
                let mut stream = gs.receive_activated().await?;
                let _keep = (&gs, &session);
                while let Some(ev) = stream.next().await {
                    let a = ev.shortcut_id().to_string();
                    let app2 = app.clone();
                    let _ = app.run_on_main_thread(move || fire(&app2, &a));
                }
                Ok(())
            }
            .await;
            if res.is_err() {
                *app.state::<Hotkeys>().mode.lock().unwrap() = "manual".into();
                let h = app.state::<Hotkeys>();
                let mut st = h.status.lock().unwrap();
                for (a, r) in st.iter_mut() {
                    if r["result"] == "pending" {
                        r["result"] = json!("manual");
                        r["hint"] = json!(wayland_hint(a));
                    }
                }
                drop(st);
                let _ = app.emit("hotkeys://changed", json!(rows(&app)));
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(s: &str) -> Option<String> {
        parse(s).map(|c| c.spec())
    }

    #[test]
    fn grammar_matches_common_py() {
        assert_eq!(spec("opt+shift+R").as_deref(), Some("opt+shift+R"));
        assert_eq!(spec("⌥⇧R").as_deref(), Some("opt+shift+R"));
        assert_eq!(spec("Alt+Shift+r").as_deref(), Some("opt+shift+R"));
        assert_eq!(spec("shift+ctrl+F5").as_deref(), Some("ctrl+shift+F5"));
        assert_eq!(spec("F9").as_deref(), Some("F9"));
        assert_eq!(spec("Win+Space").as_deref(), Some("cmd+Space"));
        assert_eq!(spec("shift+R"), None); // shift alone steals typing
        assert_eq!(spec("R"), None);
        assert_eq!(spec("off"), None);
        assert_eq!(spec("alt+R+T"), None);
        assert_eq!(spec("alt+F21"), None);
    }

    #[test]
    fn labels_and_shortcuts() {
        let c = parse("ctrl+alt+shift+Left").unwrap();
        assert!(c.to_shortcut().is_some());
        assert!(parse("alt+shift+-").unwrap().to_shortcut().is_some());
        assert!(parse("alt+F12").unwrap().to_shortcut().is_some());
        assert_eq!(parse("alt+shift+R").unwrap().xdg_trigger(), "ALT+SHIFT+r");
        if !cfg!(target_os = "macos") {
            assert_eq!(parse("opt+shift+R").unwrap().label(), "Alt+Shift+R");
        }
    }

    #[test]
    fn config_defaults_and_off() {
        let cfg = json!({"record": {"hotkeys": {"snap": "off", "pause": "ctrl+alt+P", "stop": "garbage"}}});
        let m: HashMap<_, _> = from_config(&cfg).into_iter().collect();
        assert_eq!(m["record"].as_ref().unwrap().spec(), "opt+shift+R");
        assert!(m["snap"].is_none());
        assert_eq!(m["pause"].as_ref().unwrap().spec(), "ctrl+opt+P");
        assert_eq!(m["stop"].as_ref().unwrap().spec(), "opt+shift+S");
    }
}
