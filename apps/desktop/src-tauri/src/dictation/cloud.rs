//! Cloud services on Windows / Linux (the Mac's CloudStore; docs/design/dictation.md §Cloud polish): `record.cloud`
//! {"v": 2, "services": [{"id", "preset", "region"?, "base_url"?, "name"?}], "jobs": {"polish" | "translate" |
//! "vision": {"service", "model"?} | "local"}} — the same file and shape as the Mac — and each service's key in the
//! system's own store, never in a file: Windows Credential Manager ("Blurt Cloud Polish/<service id>"). The key goes
//! to the local polish server with each request (`payload`), which sends it on to the service.
//!
//! A job left on Auto uses the first connected service with a key and that preset's measured default
//! (CloudCurated.measuredDefault): DeepSeek V4.1 Flash — `deepseek-flash` on deepseek.com, `deepseek-v4.1-flash` on
//! Model Studio — and Model Studio's `qwen3.6-flash` for reading screens.

use serde_json::{json, Value};

use crate::settings;

pub const JOBS: [&str; 3] = ["polish", "translate", "vision"];
#[cfg(windows)]
const TARGET: &str = "Blurt Cloud Polish";

/// preset → (base URL, protocol): polish_cloud.PRESETS
fn preset(id: &str) -> Option<(&'static str, &'static str)> {
    match id {
        "deepseek" => Some(("https://api.deepseek.com", "openai")),
        "dashscope" => Some((
            "https://dashscope.aliyuncs.com/compatible-mode/v1",
            "openai",
        )),
        "openai" => Some(("https://api.openai.com/v1", "openai")),
        "anthropic" => Some(("https://api.anthropic.com", "anthropic")),
        _ => None,
    }
}

pub fn measured_default(preset: &str, job: &str) -> Option<&'static str> {
    match (preset, job) {
        ("deepseek", "vision") => None, // DeepSeek reads no pictures
        ("deepseek", _) => Some("deepseek-flash"),
        ("dashscope", "vision") => Some("qwen3.6-flash"),
        ("dashscope", _) => Some("deepseek-v4.1-flash"),
        _ => None,
    }
}

pub fn setup() -> Value {
    settings::read_config()
        .pointer("/record/cloud")
        .cloned()
        .unwrap_or_else(|| json!({"v": 2, "services": [], "jobs": {}}))
}

fn save(cloud: Value) -> Result<(), String> {
    // read-modify-write under the config lock (settings::update: an unparseable config.json is never overwritten)
    settings::update(|cfg| {
        if cfg.get("record").and_then(Value::as_object).is_none() {
            cfg["record"] = json!({});
        }
        cfg["record"]["cloud"] = cloud;
    })
    .map(|_| ())
}

/// The service and model a job runs on, or None (local / nothing connected).
pub fn route(job: &str) -> Option<(Value, String)> {
    let s = setup();
    let services: Vec<Value> = s["services"].as_array().cloned().unwrap_or_default();
    let find = |id: &str| services.iter().find(|x| x["id"] == json!(id)).cloned();
    match s.pointer(&format!("/jobs/{job}")) {
        Some(Value::String(x)) if x == "local" => None,
        Some(Value::Object(o)) => {
            let svc = find(o.get("service")?.as_str()?)?;
            let model = o
                .get("model")
                .and_then(Value::as_str)
                .filter(|m| !m.trim().is_empty())
                .map(String::from)
                .or_else(|| {
                    measured_default(svc["preset"].as_str().unwrap_or(""), job).map(String::from)
                })?;
            key(svc["id"].as_str()?).map(|_| (svc, model))
        }
        _ => services.into_iter().find_map(|svc| {
            let m = measured_default(svc["preset"].as_str().unwrap_or(""), job)?;
            key(svc["id"].as_str()?).map(|_| (svc.clone(), m.to_string()))
        }),
    }
}

/// The request's `cloud` object for polish.py (polish_cloud.settings), with the key; None: the job stays local.
pub fn payload(job: &str) -> Option<Value> {
    let (svc, model) = route(job)?;
    let id = svc["id"].as_str()?;
    let p = svc["preset"].as_str().unwrap_or("custom");
    let (base, proto) = preset(p).unwrap_or(("", "openai"));
    let base_url = svc["base_url"]
        .as_str()
        .filter(|b| !b.trim().is_empty())
        .unwrap_or(base);
    Some(
        json!({"provider": p, "service": id, "base_url": base_url, "model": model, "protocol": proto,
                "key": key(id)?, "translate_model": model, "vision_model": model}),
    )
}

/// The cloud speech keys for the speech server (transcribe.py reads them from its environment, as the Mac's app sets
/// them from the Keychain): a connected Model Studio service is Qwen3-ASR Flash's key (`DASHSCOPE_API_KEY`, its own
/// address when one was set), an OpenAI one the OpenAI-compatible recogniser's. Only for transcribe.py — never in the
/// environment of anything else Blurt starts.
pub fn speech_env() -> Vec<(&'static str, String)> {
    let mut out = vec![];
    for svc in setup()["services"].as_array().cloned().unwrap_or_default() {
        let (Some(id), Some(p)) = (svc["id"].as_str(), svc["preset"].as_str()) else { continue };
        let Some(k) = key(id) else { continue };
        let base = svc["base_url"].as_str().filter(|b| !b.trim().is_empty()).map(|b| b.trim().to_string());
        match p {
            "dashscope" if !out.iter().any(|(n, _)| *n == "DASHSCOPE_API_KEY") => {
                out.push(("DASHSCOPE_API_KEY", k));
                if let Some(b) = base {
                    out.push(("DASHSCOPE_BASE_URL", b));
                }
            }
            // Volcengine Speech: one stored item "<App ID>:<Access Token>" (the Mac's VolcengineSpeech.credential);
            // the Mac's preset is "volcengine-speech" ("volcengine" alone is its Ark text service)
            "volcengine-speech" | "volcengine" if !out.iter().any(|(n, _)| *n == "VOLC_APP_ID") => {
                if let Some((app_id, token)) = volc_split(&k) {
                    out.push(("VOLC_APP_ID", app_id));
                    out.push(("VOLC_ACCESS_TOKEN", token));
                }
            }
            "openai" if !out.iter().any(|(n, _)| *n == "BLURT_ASR_API_KEY") => {
                out.push(("BLURT_ASR_API_KEY", k));
                if let Some(b) = base {
                    out.push(("BLURT_ASR_BASE_URL", b));
                }
            }
            _ => {}
        }
    }
    out
}

/// The Volcengine pair from its stored item: "<App ID>:<Access Token>" — an App ID never has a ":", a token may, so it
/// goes last (the Mac's VolcengineSpeech.split). None: not a pair.
pub fn volc_split(credential: &str) -> Option<(String, String)> {
    let (a, t) = credential.trim().split_once(':')?;
    let (a, t) = (a.trim(), t.trim());
    (!a.is_empty() && !t.is_empty()).then(|| (a.to_string(), t.to_string()))
}

/// Connect a service (or replace its key): the service goes into record.cloud, the key into the system store.
pub fn connect(
    preset_id: &str,
    key_value: &str,
    base_url: Option<&str>,
    name: Option<&str>,
) -> Result<String, String> {
    if key_value.trim().is_empty() {
        return Err("empty key".into());
    }
    let mut s = setup();
    let id = preset_id.to_string();
    let mut services: Vec<Value> = s["services"].as_array().cloned().unwrap_or_default();
    services.retain(|x| x["id"] != json!(id));
    let mut svc = json!({"id": id, "preset": preset_id});
    if let Some(b) = base_url.filter(|b| !b.trim().is_empty()) {
        svc["base_url"] = json!(b.trim());
    }
    if let Some(n) = name.filter(|n| !n.trim().is_empty()) {
        svc["name"] = json!(n.trim());
    }
    services.push(svc);
    s["services"] = json!(services);
    s["v"] = json!(2);
    if s.get("jobs").is_none() {
        s["jobs"] = json!({});
    }
    store_key(&id, key_value.trim())?;
    save(s)?;
    Ok(id)
}

pub fn disconnect(id: &str) -> Result<(), String> {
    let mut s = setup();
    let mut services: Vec<Value> = s["services"].as_array().cloned().unwrap_or_default();
    services.retain(|x| x["id"] != json!(id));
    s["services"] = json!(services);
    if let Some(jobs) = s["jobs"].as_object_mut() {
        jobs.retain(|_, v| v.get("service").and_then(Value::as_str) != Some(id));
    }
    delete_key(id);
    save(s)
}

/// What Settings shows: the services (with whether a key is stored, never the key) and each job's route.
pub fn summary() -> Value {
    let s = setup();
    let services: Vec<Value> = s["services"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .map(|mut x| {
            let has = x["id"].as_str().and_then(key).is_some();
            x["has_key"] = json!(has);
            x
        })
        .collect();
    let jobs: serde_json::Map<String, Value> = JOBS
        .iter()
        .map(|j| {
            (
                j.to_string(),
                route(j)
                    .map(|(svc, m)| json!({"service": svc["id"], "model": m}))
                    .unwrap_or(Value::Null),
            )
        })
        .collect();
    json!({"services": services, "routes": jobs, "jobs": s["jobs"]})
}

// ------------------------------------------------------------------ the key store

#[cfg(windows)]
fn target(id: &str) -> Vec<u16> {
    format!("{TARGET}/{id}")
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect()
}

/// A test build never touches the user's store: BLURT_TEST_CLOUD_KEY (as the Mac's BLURT_TEST_COMMANDS builds).
fn test_key() -> Option<String> {
    std::env::var("BLURT_TEST_CLOUD_KEY")
        .ok()
        .filter(|k| !k.is_empty())
}

#[cfg(windows)]
pub fn key(id: &str) -> Option<String> {
    if let Some(k) = test_key() {
        return Some(k);
    }
    use windows::Win32::Security::Credentials::{
        CredFree, CredReadW, CREDENTIALW, CRED_TYPE_GENERIC,
    };
    let t = target(id);
    unsafe {
        let mut p: *mut CREDENTIALW = std::ptr::null_mut();
        CredReadW(
            windows::core::PCWSTR(t.as_ptr()),
            CRED_TYPE_GENERIC,
            None,
            &mut p,
        )
        .ok()?;
        let c = &*p;
        let bytes =
            std::slice::from_raw_parts(c.CredentialBlob, c.CredentialBlobSize as usize).to_vec();
        CredFree(p as *const _);
        String::from_utf8(bytes).ok().filter(|k| !k.is_empty())
    }
}

#[cfg(windows)]
fn store_key(id: &str, k: &str) -> Result<(), String> {
    use windows::Win32::Security::Credentials::{
        CredWriteW, CREDENTIALW, CRED_FLAGS, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC,
    };
    let mut t = target(id);
    let mut user: Vec<u16> = id.encode_utf16().chain(std::iter::once(0)).collect();
    let mut blob = k.as_bytes().to_vec();
    let c = CREDENTIALW {
        Flags: CRED_FLAGS(0),
        Type: CRED_TYPE_GENERIC,
        TargetName: windows::core::PWSTR(t.as_mut_ptr()),
        CredentialBlobSize: blob.len() as u32,
        CredentialBlob: blob.as_mut_ptr(),
        Persist: CRED_PERSIST_LOCAL_MACHINE,
        UserName: windows::core::PWSTR(user.as_mut_ptr()),
        ..Default::default()
    };
    unsafe { CredWriteW(&c, 0) }.map_err(|e| e.to_string())
}

#[cfg(windows)]
fn delete_key(id: &str) {
    use windows::Win32::Security::Credentials::{CredDeleteW, CRED_TYPE_GENERIC};
    let t = target(id);
    unsafe {
        let _ = CredDeleteW(windows::core::PCWSTR(t.as_ptr()), CRED_TYPE_GENERIC, None);
    }
}

// Linux: the Secret Service comes with the Linux round; until then only the test key.
#[cfg(not(windows))]
pub fn key(_id: &str) -> Option<String> {
    test_key()
}

#[cfg(not(windows))]
fn store_key(_id: &str, _k: &str) -> Result<(), String> {
    Err("no key store on this system yet".into())
}

#[cfg(not(windows))]
fn delete_key(_id: &str) {}

#[cfg(test)]
mod tests {
    #[test]
    fn the_volcengine_pair() {
        assert_eq!(super::volc_split(" 123:abc:def "), Some(("123".into(), "abc:def".into())));
        assert_eq!(super::volc_split("nopair"), None);
        assert_eq!(super::volc_split(":x"), None);
    }
}
