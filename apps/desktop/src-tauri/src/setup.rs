//! First run on Windows / Linux (the Mac's UVSetup and ModelSetup.startAtInstall; docs/design/desktop-app.md §2.2):
//! nothing to install by hand.
//!
//!  • uv: the scripts run through it, and a fresh PC has neither uv nor Python. It comes from PyPI, where uv ships as a
//!    wheel with uv.exe inside — so the mainland's PyPI mirrors bring it where GitHub (astral's own installer) doesn't
//!    load — into `$BLURT_HOME/bin`. uv then fetches Python and each script's pinned packages.
//!  • mirrors (the Mac's ModelBundle.mirror): `asr.hf_mirror` when set, else on for the mainland (region CN or the
//!    China time zone). Children then get Alibaba Cloud's PyPI mirror, npmmirror's Python builds and
//!    `BLURT_HF_MIRROR=1` (the scripts take hf-mirror / ModelScope first).
//!  • the speech model: dictation's recommended model starts downloading by itself once, at the first launch while
//!    dictation is automatic (`record.dictation.first_download`); a Stop or a failure is final — Settings → Dictation
//!    offers it again.

use std::path::PathBuf;
use std::process::Command;
use std::sync::OnceLock;
use std::time::Duration;

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};

use crate::{paths, settings, AppState};

const PYPI_MIRROR: &str = "https://mirrors.aliyun.com/pypi/simple/";
const PYPI: &str = "https://pypi.org/simple/";
const PYTHON_MIRROR: &str = "https://registry.npmmirror.com/-/binary/python-build-standalone";

pub fn mirror() -> bool {
    static M: OnceLock<bool> = OnceLock::new();
    *M.get_or_init(|| {
        if let Some(b) = settings::read_config()
            .pointer("/asr/hf_mirror")
            .and_then(Value::as_bool)
        {
            return b;
        }
        let region_cn = sys_locale::get_locale()
            .is_some_and(|l| l.ends_with("-CN") || l.eq_ignore_ascii_case("zh-hans-cn"));
        region_cn || china_time_zone()
    })
}

#[cfg(windows)]
fn china_time_zone() -> bool {
    use windows::Win32::System::Time::{
        GetDynamicTimeZoneInformation, DYNAMIC_TIME_ZONE_INFORMATION,
    };
    let mut z = DYNAMIC_TIME_ZONE_INFORMATION::default();
    unsafe { GetDynamicTimeZoneInformation(&mut z) };
    let key = String::from_utf16_lossy(&z.TimeZoneKeyName);
    key.trim_end_matches('\0') == "China Standard Time"
}

#[cfg(not(windows))]
fn china_time_zone() -> bool {
    std::fs::read_link("/etc/localtime")
        .map(|p| {
            [
                "Asia/Shanghai",
                "Asia/Chongqing",
                "Asia/Harbin",
                "Asia/Urumqi",
                "PRC",
            ]
            .iter()
            .any(|z| p.to_string_lossy().ends_with(z))
        })
        .unwrap_or(false)
}

/// What children get on top of our environment when the mirrors are on (scripts::agent_environment). A variable the
/// user set themselves wins.
pub fn mirror_env() -> Vec<(&'static str, &'static str)> {
    if !mirror() {
        return vec![];
    }
    [
        ("UV_DEFAULT_INDEX", PYPI_MIRROR),
        ("UV_INDEX_URL", PYPI_MIRROR),
        ("UV_PYTHON_INSTALL_MIRROR", PYTHON_MIRROR),
        ("BLURT_HF_MIRROR", "1"),
    ]
    .into_iter()
    .filter(|(k, _)| std::env::var_os(k).is_none())
    .collect()
}

fn no_window(c: &mut Command) -> &mut Command {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000);
    }
    c
}

/// Download uv's wheel from PyPI (the mirror first where it is on) and take uv(.exe) out of it.
pub fn install_uv(progress: impl Fn(f64, f64)) -> Result<PathBuf, String> {
    let bin = paths::blurt_home().join("bin");
    std::fs::create_dir_all(&bin).map_err(|e| e.to_string())?;
    let exe = if cfg!(windows) { "uv.exe" } else { "uv" };
    let tag = if cfg!(windows) {
        if cfg!(target_arch = "aarch64") {
            "win_arm64"
        } else {
            "win_amd64"
        }
    } else if cfg!(target_arch = "aarch64") {
        "manylinux_2_17_aarch64"
    } else {
        "manylinux_2_17_x86_64"
    };
    let indexes = if mirror() {
        [PYPI_MIRROR, PYPI]
    } else {
        [PYPI, PYPI_MIRROR]
    };
    let tmp = std::env::temp_dir().join(format!("blurt-uv-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(&tmp).map_err(|e| e.to_string())?;
    let mut last = String::new();
    for idx in indexes {
        // no_window: in the release build (a GUI exe) a bare console would pop over the welcome for the whole fetch
        let page = match no_window(Command::new("curl").args(["-sfL", "--connect-timeout", "10", "--max-time", "30", &format!("{idx}uv/")]))
            .output()
        {
            Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).into_owned(),
            _ => {
                last = format!("{idx} unreachable");
                continue;
            }
        };
        // the newest wheel for this platform: the simple index lists them oldest first
        let Some(href) = page
            .split("href=\"")
            .skip(1)
            .filter_map(|x| x.split('"').next())
            .filter(|h| h.contains(tag) && h.split('#').next().is_some_and(|f| f.ends_with(".whl")))
            .last()
        else {
            last = format!("no uv wheel for {tag} at {idx}");
            continue;
        };
        let url = if href.starts_with("http") {
            href.to_string()
        } else {
            format!("{idx}uv/{href}")
        };
        let url = url.split('#').next().unwrap_or(&url).to_string();
        let whl = tmp.join("uv.zip");
        // its size first (the last Content-Length after redirects), so the step can show a bar, not a bare spinner
        let total = no_window(Command::new("curl").args(["-sIL", "--connect-timeout", "10", "--max-time", "15"]).arg(&url))
            .output()
            .ok()
            .and_then(|o| {
                String::from_utf8_lossy(&o.stdout)
                    .lines()
                    .filter_map(|l| l.split_once(':').filter(|(k, _)| k.eq_ignore_ascii_case("content-length")).and_then(|(_, v)| v.trim().parse::<f64>().ok()))
                    .last()
            })
            .unwrap_or(0.0)
            / 1e6;
        let child = no_window(
            Command::new("curl")
                // a mirror that stalls (under 20 KB/s for 20 s) gives way to the other index instead of holding the
                // step for ten minutes
                .args(["-sfL", "--connect-timeout", "10", "--speed-limit", "20000", "--speed-time", "20", "--max-time", "600", "-o"])
                .arg(&whl)
                .arg(&url),
        )
        .spawn();
        let ok = match child {
            Ok(mut c) => loop {
                if let Ok(Some(st)) = c.try_wait() {
                    break st.success();
                }
                let done = std::fs::metadata(&whl).map(|m| m.len() as f64 / 1e6).unwrap_or(0.0);
                progress(done, total);
                std::thread::sleep(std::time::Duration::from_millis(500));
            },
            Err(_) => false,
        };
        if !ok {
            last = format!("download failed: {url}");
            continue;
        }
        // a wheel is a zip: Windows 10+ has bsdtar, which reads zip; GNU tar (Linux) doesn't — the system's Python
        // (every Ubuntu desktop has one) or unzip does
        let ok = if cfg!(windows) {
            no_window(Command::new("tar").arg("-xf").arg(&whl).arg("-C").arg(&tmp)).status().is_ok_and(|s| s.success())
        } else {
            Command::new("python3").args(["-m", "zipfile", "-e"]).arg(&whl).arg(&tmp).status().is_ok_and(|s| s.success())
                || Command::new("unzip").arg("-q").arg("-o").arg(&whl).arg("-d").arg(&tmp).status().is_ok_and(|s| s.success())
        };
        if !ok {
            last = "couldn't unpack the uv wheel".into();
            continue;
        }
        let found = walk(&tmp).into_iter().find(|p| {
            p.file_name().is_some_and(|n| n == exe) && p.to_string_lossy().contains(".data")
        });
        if let Some(src) = found {
            let dest = bin.join(exe);
            std::fs::copy(&src, &dest).map_err(|e| e.to_string())?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(&dest, std::fs::Permissions::from_mode(0o755));
            }
            let _ = std::fs::remove_dir_all(&tmp);
            return Ok(dest);
        }
        last = "uv not found in its wheel".into();
    }
    let _ = std::fs::remove_dir_all(&tmp);
    Err(last)
}

fn walk(d: &std::path::Path) -> Vec<PathBuf> {
    let mut out = vec![];
    if let Ok(rd) = std::fs::read_dir(d) {
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                out.extend(walk(&p));
            } else {
                out.push(p);
            }
        }
    }
    out
}

/// ffmpeg and ffprobe for recordings and frames (record.py, frames.py find them on PATH; children get
/// `$BLURT_HOME/bin` on theirs). Windows only: ffmpeg-static's build (b6.1.1, gzipped, ~29 MB each), from npmmirror
/// in the mainland, else from its GitHub release.
#[cfg(windows)]
pub fn ensure_ffmpeg() -> Result<(), String> {
    let bin = paths::blurt_home().join("bin");
    let on_path = |exe: &str| {
        std::env::var_os("PATH").is_some_and(|p| std::env::split_paths(&p).any(|d| d.join(exe).is_file())) || bin.join(exe).is_file()
    };
    std::fs::create_dir_all(&bin).map_err(|e| e.to_string())?;
    for name in ["ffmpeg", "ffprobe"] {
        let exe = format!("{name}.exe");
        if on_path(&exe) {
            continue;
        }
        let file = format!("{name}-win32-x64.gz");
        let urls = [
            format!("https://registry.npmmirror.com/-/binary/ffmpeg-static/b6.1.1/{file}"),
            format!("https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/{file}"),
        ];
        let order: Vec<&String> = if mirror() { urls.iter().collect() } else { urls.iter().rev().collect() };
        let gz = bin.join(format!("{name}.exe.gz.part"));
        let got = order.iter().any(|u| {
            no_window(Command::new("curl").args(["-sfL", "--connect-timeout", "10", "--speed-limit", "20000", "--speed-time", "20", "--max-time", "900", "-o"]).arg(&gz).arg(u.as_str())).status().is_ok_and(|s| s.success())
        });
        if !got {
            let _ = std::fs::remove_file(&gz);
            return Err(format!("couldn't download {name}"));
        }
        let out = bin.join(format!("{exe}.part"));
        let ps = format!(
            "$i=[IO.File]::OpenRead('{}');$g=New-Object IO.Compression.GZipStream($i,[IO.Compression.CompressionMode]::Decompress);$o=[IO.File]::Create('{}');$g.CopyTo($o);$o.Close();$g.Close();$i.Close()",
            gz.display(),
            out.display()
        );
        let ok = no_window(Command::new("powershell").args(["-NoProfile", "-Command", &ps])).status().is_ok_and(|s| s.success());
        let _ = std::fs::remove_file(&gz);
        if !ok {
            return Err(format!("couldn't unpack {name}"));
        }
        std::fs::rename(&out, bin.join(&exe)).map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// At launch, off the main thread: uv when it is missing, then the first speech-model download.
pub fn start(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        let st = app.state::<AppState>();
        if st.runner().uv.is_none() {
            let _ = app.emit("setup", json!({"step": "uv", "state": "running"}));
            let a2 = app.clone();
            let shown = std::sync::Mutex::new(-1.0_f64);
            let progress = move |done: f64, total: f64| {
                // a line per tenth of a MB that came in (the file grows in bursts)
                let mut last = shown.lock().unwrap();
                if (done - *last).abs() >= 0.1 {
                    *last = done;
                    let _ = a2.emit("setup", json!({"step": "uv", "state": "running", "done_mb": done, "total_mb": total}));
                }
            };
            match install_uv(progress) {
                Ok(p) => {
                    st.refresh_runner(&app);
                    let _ = app.emit("setup", json!({"step": "uv", "state": "done", "path": p}));
                }
                Err(e) => {
                    eprintln!("blurt: uv not installed: {e}");
                    let _ = app.emit(
                        "setup",
                        json!({"step": "uv", "state": "failed", "message": e}),
                    );
                    return;
                }
            }
        }
        first_download(&app);
        #[cfg(windows)]
        if let Err(e) = ensure_ffmpeg() {
            eprintln!("blurt: ffmpeg not installed: {e}");
        }
    });
}

fn first_download(app: &AppHandle) {
    let cfg = settings::read_config();
    let d = cfg
        .pointer("/record/dictation")
        .cloned()
        .unwrap_or(json!({}));
    if d.get("first_download").is_some()
        || d.get("asr_model").is_some_and(|m| !m.is_null())
        || d.get("enabled") == Some(&json!(false))
    {
        return;
    }
    let runner = app.state::<AppState>().runner();
    let Ok(m) = runner.run(
        "transcribe.py",
        &["dictation-models".into()],
        None,
        Duration::from_secs(300),
    ) else {
        return;
    };
    let rec = m["recommended"].as_str().unwrap_or_default().to_string();
    let installed = m["models"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|x| x["id"] == json!(rec) && x["installed"] == json!(true));
    let _ = settings::merge(
        json!({"record": {"dictation": {"first_download": chrono::Utc::now().to_rfc3339()}}}),
    );
    if rec.is_empty() || installed {
        return;
    }
    if crate::dictation::commands::model_download(app.clone(), rec).is_ok() {
        crate::island::send(
            app,
            json!({"op": "toast", "kind": "dictation", "msg": "dictation.toast.first_download", "ms": 6000}),
        );
    }
}
