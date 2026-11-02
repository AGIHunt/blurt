//! The first-run Welcome on Windows / Linux (the Mac's Onboarding/Onboarding.swift; docs/design/desktop-app.md §2.2):
//! a view in the main window (web/apps/desktop/src/components/Welcome.tsx). Shown once — config `app.onboarded`, the
//! Mac's key; a config.json that can't be read says nothing about a first run — and again from Settings → General.
//! While it is open the step is kept in `app.onboarding_step`, so a quit brings it back on that step.
//!
//! What the page reads from here: whether it is needed, the speech tools' state (setup.rs installs uv and starts the
//! first model download at launch — the page shows that one, never a second), the dictation key as the hook hears it
//! (`dictation://key` {down}, Windows), the microphone (cpal's default input + the privacy switches in the registry)
//! and "Open Blurt at login": HKCU\…\Run on Windows, an XDG autostart entry on Linux. A login launch carries
//! `--autostart` and starts in the tray.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Listener};

use crate::{paths, settings};

type R<T> = Result<T, String>;

/// The argument a login launch carries (the Run value / the autostart entry).
pub const AUTOSTART_ARG: &str = "--autostart";
/// The Try-it step is the last: a saved step past it is clamped.
const LAST_STEP: u64 = 3;

/// setup.rs's uv step as its `setup` events said: None (not seen), "running", "done", "failed".
static UV: Mutex<Option<String>> = Mutex::new(None);
/// the dictation key's last state sent to the page (key repeats aren't sent again)
static KEY_DOWN: AtomicBool = AtomicBool::new(false);

/// At launch: remember what setup.rs reports, so a page opened later knows whether uv failed.
pub fn init(app: &AppHandle) {
    app.listen_any("setup", |e| {
        if let Ok(v) = serde_json::from_str::<Value>(e.payload()) {
            if v["step"] == "uv" {
                *UV.lock().unwrap() = v["state"].as_str().map(String::from);
            }
        }
    });
}

/// The config says the Welcome is still to show: no `app.onboarded`. No file yet is a first run; a file that can't be
/// read isn't (as on the Mac — a broken config never brings the Welcome back).
pub fn needed_from(raw: Option<&[u8]>) -> bool {
    let Some(raw) = raw else { return true };
    let raw = raw.strip_prefix("\u{feff}".as_bytes()).unwrap_or(raw);
    match serde_json::from_slice::<Value>(raw) {
        Ok(v) if v.is_object() => v.pointer("/app/onboarded").and_then(Value::as_bool) != Some(true),
        _ => false,
    }
}

pub fn needed() -> bool {
    needed_from(std::fs::read(paths::config_file()).ok().as_deref())
}

/// The step a quit left it on (0 when none).
pub fn step_from(cfg: &Value) -> u64 {
    cfg.pointer("/app/onboarding_step").and_then(Value::as_u64).unwrap_or(0).min(LAST_STEP)
}

/// setup.rs is still to start the first download (`record.dictation.first_download` not written yet, the same
/// conditions it checks) — the page waits for it instead of offering a second one. Not when uv failed: setup stops there.
pub fn first_download_pending(cfg: &Value, uv_failed: bool) -> bool {
    let d = cfg.pointer("/record/dictation").cloned().unwrap_or(json!({}));
    !uv_failed
        && d.get("first_download").is_none()
        && !d.get("asr_model").is_some_and(|m| !m.is_null())
        && d.get("enabled") != Some(&json!(false))
}

/// A launch from the login entry: Blurt starts in the tray (unless the Welcome is still to show).
pub fn launched_at_login() -> bool {
    std::env::args().any(|a| a == AUTOSTART_ARG) && !needed()
}

/// The hook saw the dictation key go down / up (engine.rs, Windows): the Welcome's "press it" check.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn dictation_key(app: &AppHandle, down: bool) {
    if KEY_DOWN.swap(down, Ordering::SeqCst) != down {
        let _ = app.emit("dictation://key", json!({ "down": down }));
    }
}

#[tauri::command]
pub fn onboarding_get(app: AppHandle) -> Value {
    use tauri::Manager;
    let cfg = settings::read_config();
    let uv_state = UV.lock().unwrap().clone();
    let uv_failed = uv_state.as_deref() == Some("failed");
    let uv = app.state::<crate::AppState>().runner().uv.is_some();
    let d = cfg.pointer("/record/dictation").cloned().unwrap_or(json!({}));
    json!({
        "needed": needed(),
        "step": step_from(&cfg),
        "uv": uv,
        "uv_state": uv_state,
        "first_download_pending": uv && first_download_pending(&cfg, uv_failed),
        "dictation": {
            "available": cfg!(windows),
            "key": d.get("key").and_then(Value::as_str).unwrap_or("right_option"),
            "mode": d.get("mode").and_then(Value::as_str).unwrap_or("auto"),
            "enabled": d.get("enabled").and_then(Value::as_bool).unwrap_or(true),
        },
    })
}

/// The step showing, so a quit brings the Welcome back there.
#[tauri::command]
pub fn onboarding_step(step: u64) -> R<()> {
    settings::merge(json!({"app": {"onboarding_step": step.min(LAST_STEP)}})).map(|_| ())
}

/// Done or Skip Setup: shown once from now on. `login`: "Open Blurt at login" as the last step left it.
#[tauri::command]
pub fn onboarding_finish(login: Option<bool>) -> R<Value> {
    settings::merge(json!({"app": {"onboarded": true, "onboarding_step": null}}))?;
    if let Some(on) = login {
        if login_state().1 != on {
            set_login(on)?;
        }
    }
    Ok(login_json())
}

/// The speech tools didn't install (uv): setup.rs once more — uv, then the first download.
#[tauri::command]
pub fn onboarding_retry_setup(app: AppHandle) -> bool {
    let mut uv = UV.lock().unwrap();
    if uv.as_deref() != Some("failed") {
        return false; // still running, or done: nothing to retry
    }
    *uv = Some("running".into());
    drop(uv);
    crate::setup::start(&app);
    true
}

// ------------------------------------------------------------------ the microphone

/// What Windows' privacy switches say (Settings → Privacy & security → Microphone): the device-wide one (HKLM), "Let
/// apps access your microphone" and "Let desktop apps access your microphone" (HKCU). Any "Deny" turns the mic off for
/// Blurt; nothing read is "unknown" (older builds, a policy).
pub fn mic_access(vals: &[Option<String>]) -> &'static str {
    if vals.iter().flatten().any(|v| v.eq_ignore_ascii_case("deny")) {
        "denied"
    } else if !vals.is_empty() && vals.iter().all(|v| v.as_deref().is_some_and(|v| v.eq_ignore_ascii_case("allow"))) {
        "allowed"
    } else {
        "unknown"
    }
}

#[cfg(windows)]
fn mic_state() -> Value {
    use cpal::traits::{DeviceTrait, HostTrait};
    use windows::Win32::System::Registry::{HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE};
    const K: &str = r"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";
    if std::env::var_os("BLURT_TEST_MIC_WAV").is_some() {
        // tests: the wav is the microphone (dictation/mic.rs)
        return json!({"supported": true, "device": "test wav", "access": "allowed"});
    }
    let device = cpal::default_host().default_input_device().and_then(|d| d.name().ok());
    let vals = [
        win::get_string(HKEY_LOCAL_MACHINE, K, "Value"),
        win::get_string(HKEY_CURRENT_USER, K, "Value"),
        win::get_string(HKEY_CURRENT_USER, &format!(r"{K}\NonPackaged"), "Value"),
    ];
    json!({"supported": true, "device": device, "access": mic_access(&vals)})
}

#[cfg(not(windows))]
fn mic_state() -> Value {
    json!({"supported": false, "device": null, "access": "unknown"})
}

/// {supported, device (the default input's name, null: none), access: allowed | denied | unknown}
#[tauri::command(async)]
pub fn onboarding_mic() -> Value {
    mic_state()
}

/// Windows' own microphone page (the privacy switches).
#[tauri::command]
pub fn onboarding_mic_settings(app: AppHandle) -> R<()> {
    use tauri_plugin_opener::OpenerExt;
    if !cfg!(windows) {
        return Err("only on Windows".into());
    }
    app.opener().open_url("ms-settings:privacy-microphone", None::<&str>).map_err(|e| e.to_string())
}

// ------------------------------------------------------------------ open at login

/// The command a login runs: this exe, quoted, then the autostart flag (the Run value's data).
#[cfg_attr(not(windows), allow(dead_code))]
pub fn run_value(exe: &str) -> String {
    format!("\"{exe}\" {AUTOSTART_ARG}")
}

/// One argument of a desktop entry's Exec (the spec's quoting: in double quotes, `"` `` ` `` `$` `\` escaped).
pub fn exec_quote(arg: &str) -> String {
    if !arg.is_empty() && arg.chars().all(|c| c.is_ascii_alphanumeric() || "/._-+=:,@".contains(c)) {
        return arg.to_string();
    }
    let mut s = String::from("\"");
    for c in arg.chars() {
        if matches!(c, '"' | '`' | '$' | '\\') {
            s.push('\\');
        }
        s.push(c);
    }
    s.push('"');
    s
}

/// The XDG autostart entry (Linux): the AppImage when running from one, else this binary.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub fn desktop_entry(exe: &str) -> String {
    format!(
        "[Desktop Entry]\nType=Application\nName=Blurt\nComment=Dictation, snaps and recordings that become work\nExec={} {AUTOSTART_ARG}\nIcon=blurt\nTerminal=false\nX-GNOME-Autostart-enabled=true\n",
        exec_quote(exe)
    )
}

fn exe_path() -> R<String> {
    if let Some(a) = std::env::var_os("APPIMAGE").filter(|_| cfg!(target_os = "linux")) {
        return Ok(a.to_string_lossy().into_owned());
    }
    std::env::current_exe().map(|p| p.to_string_lossy().into_owned()).map_err(|e| e.to_string())
}

#[cfg(target_os = "linux")]
fn autostart_file() -> std::path::PathBuf {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(std::path::PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| dirs::home_dir().unwrap_or_default().join(".config"));
    base.join("autostart").join("blurt.desktop")
}

/// (supported, on)
fn login_state() -> (bool, bool) {
    #[cfg(windows)]
    {
        (true, win::login_enabled())
    }
    #[cfg(target_os = "linux")]
    {
        let on = std::fs::read_to_string(autostart_file())
            .is_ok_and(|s| !s.lines().any(|l| l.trim() == "Hidden=true" || l.trim() == "X-GNOME-Autostart-enabled=false"));
        (true, on)
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        (false, false)
    }
}

fn set_login(on: bool) -> R<()> {
    // test runs never touch the real login items (the Mac's SystemAccess.testMode)
    if std::env::var_os("BLURT_TEST_EVAL").is_some() || std::env::var_os("BLURT_TEST_NO_LOGIN").is_some() {
        eprintln!("blurt: login item → {on} (test run: not registered)");
        return Ok(());
    }
    #[cfg(windows)]
    {
        win::set_login(on, &run_value(&exe_path()?))
    }
    #[cfg(target_os = "linux")]
    {
        let f = autostart_file();
        if on {
            if let Some(d) = f.parent() {
                std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
            }
            std::fs::write(&f, desktop_entry(&exe_path()?)).map_err(|e| e.to_string())
        } else {
            match std::fs::remove_file(&f) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.to_string()),
                _ => Ok(()),
            }
        }
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = (on, exe_path);
        Err("not on this platform".into())
    }
}

fn login_json() -> Value {
    let (supported, enabled) = login_state();
    json!({"supported": supported, "enabled": enabled})
}

/// {supported, enabled}
#[tauri::command]
pub fn login_item_get() -> Value {
    login_json()
}

#[tauri::command]
pub fn login_item_set(on: bool) -> R<Value> {
    set_login(on)?;
    Ok(login_json())
}

#[cfg(windows)]
mod win {
    use windows::core::PCWSTR;
    use windows::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_SUCCESS};
    use windows::Win32::System::Registry::{
        RegDeleteKeyValueW, RegGetValueW, RegSetKeyValueW, HKEY, HKEY_CURRENT_USER, REG_SZ, RRF_RT_REG_BINARY,
        RRF_RT_REG_SZ,
    };

    const RUN: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
    /// Task Manager's Startup apps switch: a value whose first byte is odd (3) is turned off there
    const APPROVED: &str = r"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    const NAME: &str = "Blurt";

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    pub fn get_string(root: HKEY, key: &str, name: &str) -> Option<String> {
        let (k, n) = (wide(key), wide(name));
        let mut size: u32 = 0;
        let r = unsafe {
            RegGetValueW(root, PCWSTR(k.as_ptr()), PCWSTR(n.as_ptr()), RRF_RT_REG_SZ, None, None, Some(&mut size as *mut u32))
        };
        if r != ERROR_SUCCESS || size == 0 {
            return None;
        }
        let mut buf = vec![0u16; (size as usize).div_ceil(2) + 1];
        let mut size = (buf.len() * 2) as u32;
        let r = unsafe {
            RegGetValueW(
                root,
                PCWSTR(k.as_ptr()),
                PCWSTR(n.as_ptr()),
                RRF_RT_REG_SZ,
                None,
                Some(buf.as_mut_ptr() as *mut core::ffi::c_void),
                Some(&mut size as *mut u32),
            )
        };
        if r != ERROR_SUCCESS {
            return None;
        }
        let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
        Some(String::from_utf16_lossy(&buf[..end]))
    }

    fn first_byte(root: HKEY, key: &str, name: &str) -> Option<u8> {
        let (k, n) = (wide(key), wide(name));
        let mut buf = [0u8; 64];
        let mut size = buf.len() as u32;
        let r = unsafe {
            RegGetValueW(
                root,
                PCWSTR(k.as_ptr()),
                PCWSTR(n.as_ptr()),
                RRF_RT_REG_BINARY,
                None,
                Some(buf.as_mut_ptr() as *mut core::ffi::c_void),
                Some(&mut size as *mut u32),
            )
        };
        (r == ERROR_SUCCESS && size > 0).then_some(buf[0])
    }

    fn delete(key: &str, name: &str) -> Result<(), String> {
        let (k, n) = (wide(key), wide(name));
        let r = unsafe { RegDeleteKeyValueW(HKEY_CURRENT_USER, PCWSTR(k.as_ptr()), PCWSTR(n.as_ptr())) };
        if r == ERROR_SUCCESS || r == ERROR_FILE_NOT_FOUND {
            Ok(())
        } else {
            Err(format!("registry: error {}", r.0))
        }
    }

    pub fn login_enabled() -> bool {
        get_string(HKEY_CURRENT_USER, RUN, NAME).is_some()
            && !first_byte(HKEY_CURRENT_USER, APPROVED, NAME).is_some_and(|b| b & 1 == 1)
    }

    pub fn set_login(on: bool, command: &str) -> Result<(), String> {
        if !on {
            return delete(RUN, NAME);
        }
        let (k, n, data) = (wide(RUN), wide(NAME), wide(command));
        let r = unsafe {
            RegSetKeyValueW(
                HKEY_CURRENT_USER,
                PCWSTR(k.as_ptr()),
                PCWSTR(n.as_ptr()),
                REG_SZ.0,
                Some(data.as_ptr() as *const core::ffi::c_void),
                (data.len() * 2) as u32,
            )
        };
        if r != ERROR_SUCCESS {
            return Err(format!("registry: error {}", r.0));
        }
        // turned off in Task Manager before: on again
        delete(APPROVED, NAME)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn needed_once() {
        assert!(needed_from(None)); // no config yet: a first run
        assert!(needed_from(Some(b"{}")));
        assert!(needed_from(Some(br#"{"app": {"onboarded": false}}"#)));
        assert!(!needed_from(Some(br#"{"app": {"onboarded": true}}"#)));
        assert!(!needed_from(Some("\u{feff}{\"app\": {\"onboarded\": true}}".as_bytes())));
        assert!(!needed_from(Some(b"{not json"))); // unreadable: not a first run
        assert!(!needed_from(Some(b"[]")));
    }

    #[test]
    fn step_kept_and_clamped() {
        assert_eq!(step_from(&json!({})), 0);
        assert_eq!(step_from(&json!({"app": {"onboarding_step": 2}})), 2);
        assert_eq!(step_from(&json!({"app": {"onboarding_step": 9}})), LAST_STEP);
        assert_eq!(step_from(&json!({"app": {"onboarding_step": "x"}})), 0);
    }

    #[test]
    fn first_download_waits_for_setup() {
        assert!(first_download_pending(&json!({}), false));
        assert!(!first_download_pending(&json!({}), true)); // uv failed: setup stopped before it
        assert!(!first_download_pending(&json!({"record": {"dictation": {"first_download": "2026-11-02T08:00:00Z"}}}), false));
        assert!(!first_download_pending(&json!({"record": {"dictation": {"asr_model": "sensevoice-small"}}}), false));
        assert!(first_download_pending(&json!({"record": {"dictation": {"asr_model": null}}}), false));
        assert!(!first_download_pending(&json!({"record": {"dictation": {"enabled": false}}}), false));
    }

    #[test]
    fn mic_switches() {
        let s = |v: &str| Some(v.to_string());
        assert_eq!(mic_access(&[s("Allow"), s("Allow"), s("Allow")]), "allowed");
        assert_eq!(mic_access(&[s("Allow"), s("Allow"), s("Deny")]), "denied"); // desktop apps off
        assert_eq!(mic_access(&[s("Deny"), None, None]), "denied");
        assert_eq!(mic_access(&[s("Allow"), None, s("Allow")]), "unknown");
        assert_eq!(mic_access(&[]), "unknown");
    }

    #[test]
    fn login_commands() {
        assert_eq!(run_value(r"C:\Users\Maya Li\AppData\Local\Blurt\blurt.exe"), r#""C:\Users\Maya Li\AppData\Local\Blurt\blurt.exe" --autostart"#);
        assert_eq!(exec_quote("/opt/blurt/blurt"), "/opt/blurt/blurt");
        assert_eq!(exec_quote("/home/maya/Apps/Blurt 0.7.AppImage"), "\"/home/maya/Apps/Blurt 0.7.AppImage\"");
        assert_eq!(exec_quote(r#"/a/b"c$d"#), r#""/a/b\"c\$d""#);
        let e = desktop_entry("/home/maya/Apps/Blurt.AppImage");
        assert!(e.starts_with("[Desktop Entry]\n"));
        assert!(e.contains("\nExec=/home/maya/Apps/Blurt.AppImage --autostart\n"));
    }
}
