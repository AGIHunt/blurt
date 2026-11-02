//! `record.dictation.*` as the engine reads it (the Mac's Dictation.swift settings accessors, DictationSound,
//! BlurtCore DictationStyle), the same keys on both so one settings file reads the same: the key and how it starts,
//! the cancel key, double-tap send, the microphone, the sounds, the style per app / category / by default, keeping
//! the recordings, the field's context. The engine reloads them whenever the config file changes (no relaunch: the
//! Mac's `reloadIfChanged`). Pure: tests below.

use serde_json::Value;

use super::apps::{self, Category};
use super::trigger::{Key, Mode, ModifierTap};

/// The key that cancels a take (`cancel_key`): Esc, or Ctrl+Esc / Shift+Esc for people whose Esc means something in
/// the app they dictate into (Claude Code: Esc stops the running turn). Plain Esc is then any other key.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum CancelKey {
    #[default]
    Esc,
    CtrlEsc,
    ShiftEsc,
}

impl CancelKey {
    pub fn from_config(s: &str) -> Option<CancelKey> {
        match s {
            "esc" => Some(CancelKey::Esc),
            "ctrl_esc" => Some(CancelKey::CtrlEsc),
            "shift_esc" => Some(CancelKey::ShiftEsc),
            _ => None,
        }
    }
    /// An Esc with these modifiers held is the cancel key.
    pub fn matches(self, ctrl: bool, shift: bool) -> bool {
        match self {
            CancelKey::Esc => true,
            CancelKey::CtrlEsc => ctrl,
            CancelKey::ShiftEsc => shift,
        }
    }
    /// For the island's lines ("Esc to cancel")
    pub fn label(self) -> &'static str {
        match self {
            CancelKey::Esc => "Esc",
            CancelKey::CtrlEsc => "Ctrl+Esc",
            CancelKey::ShiftEsc => "Shift+Esc",
        }
    }
}

/// A take's style (BlurtCore DictationStyle).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Style {
    /// what the speech model wrote: no polish
    Verbatim,
    Light,
    /// one structuring pass over the whole take at key-up
    Structured,
    /// the structuring pass, typed only when it made a list; else light
    Auto,
}

impl Style {
    pub fn from_config(s: &str) -> Option<Style> {
        match s {
            "verbatim" => Some(Style::Verbatim),
            "light" => Some(Style::Light),
            "structured" => Some(Style::Structured),
            "auto" => Some(Style::Auto),
            _ => None,
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Style::Verbatim => "verbatim",
            Style::Light => "light",
            Style::Structured => "structured",
            Style::Auto => "auto",
        }
    }
    pub fn polishes(self) -> bool {
        self != Style::Verbatim
    }
    pub fn structures(self) -> bool {
        matches!(self, Style::Structured | Style::Auto)
    }
    /// Reformat-last's cycle: verbatim → light → structured → verbatim (auto reformats as structured).
    pub fn next(self) -> Style {
        match self {
            Style::Verbatim => Style::Light,
            Style::Light => Style::Structured,
            Style::Structured | Style::Auto => Style::Verbatim,
        }
    }
    pub fn name_key(self) -> &'static str {
        match self {
            Style::Verbatim => "dictation.style.verbatim",
            Style::Light => "dictation.style.light",
            Style::Structured | Style::Auto => "dictation.style.structured",
        }
    }
    /// Shift (or the island): Structured, or back from it to the take's own style (light when that was a list style).
    pub fn toggled(self, base: Style) -> Style {
        if self != Style::Structured {
            return Style::Structured;
        }
        if base.structures() {
            Style::Light
        } else {
            base
        }
    }
    /// The text this style types, given Light's text and the structuring pass's (None: it refused, or didn't run):
    /// Structured types the structured text; Auto only when it is a list (2 list lines or more); else Light's.
    pub fn pick(self, light: &str, structured: Option<&str>) -> (String, bool) {
        let s = structured.map(str::trim).filter(|s| !s.is_empty());
        match (self.structures(), s) {
            (true, Some(s)) => {
                let list = super::stitch::list_lines(s) >= 2;
                if self == Style::Auto && !list {
                    (light.to_string(), false)
                } else {
                    (s.to_string(), list)
                }
            }
            _ => (light.to_string(), false),
        }
    }
}

/// `record.dictation.styles`: {"default", "chat" | "code" | "mail" | "notes" | "other", "apps": {app: style}}. Missing
/// = light everywhere (the category only changes light's variant). Apps are keyed by their executable's stem here
/// ("wechat"; the Mac keys them by bundle id).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Styles {
    pub fallback: Option<Style>,
    pub categories: Vec<(Category, Style)>,
    pub apps: Vec<(String, Style)>,
}

impl Styles {
    pub fn from_json(v: Option<&Value>) -> Styles {
        let Some(o) = v.and_then(Value::as_object) else {
            return Styles::default();
        };
        let st = |x: &Value| x.as_str().and_then(Style::from_config);
        let mut s = Styles { fallback: o.get("default").and_then(st), ..Styles::default() };
        for c in [Category::Chat, Category::Code, Category::Mail, Category::Notes, Category::Other] {
            if let Some(x) = o.get(c.as_str()).and_then(st) {
                s.categories.push((c, x));
            }
        }
        if let Some(a) = o.get("apps").and_then(Value::as_object) {
            for (k, x) in a {
                if let Some(x) = st(x) {
                    s.apps.push((apps::stem(k), x));
                }
            }
        }
        s
    }

    /// The take's base style for the app it goes into: the app's, its category's, the default, light.
    pub fn base(&self, exe: Option<&str>) -> Style {
        if let Some(stem) = exe.map(apps::stem) {
            if let Some((_, s)) = self.apps.iter().find(|(a, _)| *a == stem) {
                return *s;
            }
        }
        let c = apps::category(exe);
        self.categories
            .iter()
            .find(|(x, _)| *x == c)
            .map(|(_, s)| *s)
            .or(self.fallback)
            .unwrap_or(Style::Light)
    }
}

/// What the engine reads of `record.dictation`.
#[derive(Clone, Debug, PartialEq)]
pub struct Prefs {
    pub enabled: bool,
    pub key: Key,
    pub mode: Mode,
    pub cancel_key: CancelKey,
    pub double_tap_send: bool,
    pub modifier_tap_shift: ModifierTap,
    pub modifier_tap_command: ModifierTap,
    /// the start's sound (`sounds`, on unless turned off); the stop's and the cancel's (`stop_sound`, off unless on)
    pub start_sound: bool,
    pub stop_sound: bool,
    /// the input device by name (`mic`; None: the system's default input)
    pub mic: Option<String>,
    pub keep_audio: bool,
    pub context: bool,
    pub rehear: bool,
    pub rehear_window: f64,
    pub styles: Styles,
}

impl Prefs {
    /// From `record.dictation` (any shape; missing keys are the Mac's defaults).
    pub fn from_json(d: &Value) -> Prefs {
        let b = |k: &str, def: bool| d.get(k).and_then(Value::as_bool).unwrap_or(def);
        let s = |k: &str| d.get(k).and_then(Value::as_str);
        let tap = s("modifier_tap").and_then(ModifierTap::from_config).unwrap_or(super::trigger::DictationTrigger::SHIPPED_MODIFIER_TAP);
        Prefs {
            enabled: b("enabled", true),
            key: s("key").and_then(Key::from_config).unwrap_or(Key::RightAlt),
            mode: s("mode").and_then(Mode::from_config).unwrap_or(Mode::Auto),
            cancel_key: s("cancel_key").and_then(CancelKey::from_config).unwrap_or_default(),
            double_tap_send: b("double_tap_send", true),
            modifier_tap_shift: s("modifier_tap_shift").and_then(ModifierTap::from_config).unwrap_or(tap),
            modifier_tap_command: s("modifier_tap_command").and_then(ModifierTap::from_config).unwrap_or(tap),
            start_sound: b("sounds", true),
            stop_sound: b("stop_sound", false),
            mic: s("mic").map(str::trim).filter(|m| !m.is_empty()).map(String::from),
            keep_audio: b("keep_audio", true),
            context: b("context", true),
            rehear: b("rehear", true),
            rehear_window: d.get("rehear_window_s").and_then(Value::as_f64).unwrap_or(super::rehear::CAP),
            styles: Styles::from_json(d.get("styles")),
        }
    }

    /// The key or how it starts changed: the trigger is made again (a take listening is stopped first when the key
    /// changed — the key it started with no longer stops it; the Mac's `DictationFnClash.keyChangeEndsTake`).
    pub fn trigger_changed(&self, before: &Prefs) -> bool {
        self.key != before.key
            || self.mode != before.mode
            || self.double_tap_send != before.double_tap_send
            || self.modifier_tap_shift != before.modifier_tap_shift
            || self.modifier_tap_command != before.modifier_tap_command
    }
}

/// What a switch during a take leaves for the next one in the same app (the Mac's BlurtCore DictationRemember,
/// v1.0.6): Structured (Shift, the island) and Translate (Ctrl) stay on in that app until switched back. A remembered
/// style goes into the app's own style (`styles.apps`, marked `learned`); a remembered translation into
/// `translate.apps`. Switching back removes it. Only a typed take counts, and only into the app it started in.
pub mod remember {
    use serde_json::{json, Value};

    use super::{Style, Styles};

    /// After a typed take in `app` (an executable's stem) whose style was switched `toggles` times and ended as
    /// `final_style`: `record.dictation.styles` with it remembered, or None when nothing changes.
    pub fn style(final_style: Style, toggles: u32, styles: Option<&Value>, app: &str) -> Option<Value> {
        if toggles == 0 || app.is_empty() {
            return None;
        }
        let mut c = styles.cloned().filter(Value::is_object).unwrap_or(json!({}));
        let before = c.clone();
        if let Some(a) = c.get_mut("apps").and_then(Value::as_object_mut) {
            a.retain(|k, _| super::apps::stem(k) != app);
        }
        // the app's style without one of its own
        let own = Styles::from_json(Some(&c)).base(Some(app));
        let mut learned: Vec<String> = c["learned"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
        learned.retain(|x| x != app);
        if final_style != own {
            if !c["apps"].is_object() {
                c["apps"] = json!({});
            }
            c["apps"][app] = json!(final_style.as_str());
            learned.push(app.to_string());
        }
        learned.sort();
        if learned.is_empty() {
            c.as_object_mut().map(|o| o.remove("learned"));
        } else {
            c["learned"] = json!(learned);
        }
        if c["apps"].as_object().is_some_and(|a| a.is_empty()) {
            c.as_object_mut().map(|o| o.remove("apps"));
        }
        (c != before).then_some(c)
    }

    /// After a typed take in `app` whose translation was switched: `record.dictation.translate` with the app in or out
    /// of `apps`, or None.
    pub fn translate(on: bool, toggles: u32, translate: Option<&Value>, app: &str) -> Option<Value> {
        if toggles == 0 || app.is_empty() {
            return None;
        }
        let mut c = translate.cloned().filter(Value::is_object).unwrap_or(json!({}));
        let mut apps: Vec<String> = c["apps"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
        if on == apps.iter().any(|a| a == app) {
            return None;
        }
        if on {
            apps.push(app.to_string());
        } else {
            apps.retain(|a| a != app);
        }
        apps.sort();
        c["apps"] = json!(apps);
        Some(c)
    }

    /// A take starts translated in `app`.
    pub fn translates(translate: Option<&Value>, app: &str) -> bool {
        translate.and_then(|t| t["apps"].as_array()).is_some_and(|a| a.iter().any(|x| x.as_str() == Some(app)))
    }

    /// A take starting with something remembered says so when the app's last take was an hour ago or more (or none
    /// since launch). `since`: seconds since that last take.
    pub const REMIND_AFTER: f64 = 3600.0;
    pub fn remind(since: Option<f64>) -> bool {
        since.is_none_or(|s| s >= REMIND_AFTER)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_macs_defaults() {
        let p = Prefs::from_json(&json!({}));
        assert!(p.enabled && p.double_tap_send && p.start_sound && !p.stop_sound && p.keep_audio && p.context && p.rehear);
        assert_eq!((p.key, p.mode, p.cancel_key), (Key::RightAlt, Mode::Auto, CancelKey::Esc));
        assert_eq!(p.mic, None);
        assert_eq!(p.styles.base(Some("WeChat.exe")), Style::Light);
    }

    #[test]
    fn what_the_settings_write() {
        let p = Prefs::from_json(&json!({"key": "either_option", "mode": "hold", "cancel_key": "ctrl_esc", "double_tap_send": false,
            "sounds": false, "stop_sound": true, "mic": " USB Mic ", "keep_audio": false, "modifier_tap": "single",
            "modifier_tap_command": "double"}));
        assert_eq!((p.key, p.mode, p.cancel_key), (Key::EitherAlt, Mode::Hold, CancelKey::CtrlEsc));
        assert!(!p.double_tap_send && !p.start_sound && p.stop_sound && !p.keep_audio);
        assert_eq!(p.mic.as_deref(), Some("USB Mic"));
        assert_eq!((p.modifier_tap_shift, p.modifier_tap_command), (ModifierTap::Single, ModifierTap::Double));
        assert_eq!(Prefs::from_json(&json!({"mic": ""})).mic, None);
        assert!(p.trigger_changed(&Prefs::from_json(&json!({}))));
        assert!(!Prefs::from_json(&json!({"keep_audio": false})).trigger_changed(&Prefs::from_json(&json!({}))));
    }

    #[test]
    fn the_cancel_key() {
        assert!(CancelKey::Esc.matches(false, false));
        assert!(!CancelKey::CtrlEsc.matches(false, false));
        assert!(CancelKey::CtrlEsc.matches(true, false));
        assert!(CancelKey::ShiftEsc.matches(false, true));
        assert!(!CancelKey::ShiftEsc.matches(true, false));
        assert_eq!(CancelKey::from_config("shift_esc"), Some(CancelKey::ShiftEsc));
        assert_eq!(CancelKey::from_config("nope"), None);
    }

    /// DictationStyleTests: explicit app > category > default > light
    #[test]
    fn styles_by_app_category_default() {
        let s = Styles::from_json(Some(&json!({"default": "auto", "chat": "verbatim", "apps": {"Code.exe": "structured"}})));
        assert_eq!(s.base(Some("WeChat.exe")), Style::Verbatim);
        assert_eq!(s.base(Some("code.exe")), Style::Structured);
        assert_eq!(s.base(Some("notepad.exe")), Style::Auto);
        assert_eq!(s.base(None), Style::Auto);
        assert_eq!(Styles::from_json(Some(&json!({"default": "nope"}))).base(None), Style::Light);
    }

    #[test]
    fn shift_toggles_structured_and_back() {
        assert_eq!(Style::Light.toggled(Style::Light), Style::Structured);
        assert_eq!(Style::Structured.toggled(Style::Light), Style::Light);
        assert_eq!(Style::Structured.toggled(Style::Verbatim), Style::Verbatim);
        assert_eq!(Style::Structured.toggled(Style::Auto), Style::Light);
        assert_eq!(Style::Auto.toggled(Style::Auto), Style::Structured);
        assert!(!Style::Verbatim.polishes());
        assert!(Style::Auto.structures());
    }

    #[test]
    fn what_each_style_types() {
        let list = "- a\n- b";
        assert_eq!(Style::Structured.pick("a b", Some(list)), (list.to_string(), true));
        assert_eq!(Style::Structured.pick("a b", Some("A b.")), ("A b.".to_string(), false));
        assert_eq!(Style::Auto.pick("a b", Some(list)), (list.to_string(), true));
        assert_eq!(Style::Auto.pick("a b", Some("A b.")), ("a b".to_string(), false));
        assert_eq!(Style::Structured.pick("a b", None), ("a b".to_string(), false));
        assert_eq!(Style::Light.pick("a b", Some(list)), ("a b".to_string(), false));
    }

    /// DictationRememberTests
    #[test]
    fn switches_stay_on_in_their_app() {
        use remember::*;
        // Shift made it Structured in WeChat: remembered (learned)
        let c = style(Style::Structured, 1, None, "wechat").unwrap();
        assert_eq!(c["apps"]["wechat"], "structured");
        assert_eq!(c["learned"], json!(["wechat"]));
        assert_eq!(Styles::from_json(Some(&c)).base(Some("WeChat.exe")), Style::Structured);
        // switched back: gone
        let back = style(Style::Light, 2, Some(&c), "wechat").unwrap();
        assert!(back.get("apps").is_none() && back.get("learned").is_none());
        // no switch this take: nothing
        assert!(style(Style::Structured, 0, None, "wechat").is_none());
        // already so: nothing
        assert!(style(Style::Structured, 1, Some(&c), "wechat").is_none());
        // other settings stay
        let d = style(Style::Structured, 1, Some(&json!({"default": "auto"})), "code").unwrap();
        assert_eq!(d["default"], "auto");
        // translate
        let t = translate(true, 1, None, "slack").unwrap();
        assert!(translates(Some(&t), "slack"));
        assert!(translate(true, 1, Some(&t), "slack").is_none());
        assert!(!translates(translate(false, 1, Some(&t), "slack").as_ref(), "slack"));
        assert!(translate(true, 0, None, "slack").is_none());
        assert!(remind(None) && remind(Some(4000.0)) && !remind(Some(60.0)));
    }
}
