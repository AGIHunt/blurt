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

/// A service's preset (the Mac's CloudPreset.all, CloudServices.swift): its protocol and its address per region —
/// one address, a mainland-China and an international one, or none (the user's own: custom-openai / custom-anthropic,
/// whose service keeps its `base_url`). The addresses are the only hosts a key ever goes to.
pub struct Preset {
    pub id: &'static str,
    pub protocol: &'static str,
    /// (region "china" | "global" | None, base URL)
    pub endpoints: &'static [(Option<&'static str>, &'static str)],
}

impl Preset {
    /// the user's own address (no preset address)
    pub fn custom(&self) -> bool {
        self.endpoints.is_empty()
    }
    /// two addresses: the service keeps its region
    pub fn regional(&self) -> bool {
        self.endpoints.len() > 1
    }
    /// The address for a region: that region's, else the first (a service saved without a region).
    pub fn base(&self, region: Option<&str>) -> Option<&'static str> {
        self.endpoints
            .iter()
            .find(|(r, _)| region.is_some() && *r == region)
            .or_else(|| self.endpoints.first())
            .map(|(_, b)| *b)
    }
}

const CN: Option<&str> = Some("china");
const GL: Option<&str> = Some("global");

/// In the Mac's order. Volcengine Speech (speech only, a websocket) isn't here: it has no text models.
pub const PRESETS: &[Preset] = &[
    Preset { id: "deepseek", protocol: "openai", endpoints: &[(None, "https://api.deepseek.com")] },
    Preset {
        id: "dashscope",
        protocol: "openai",
        endpoints: &[
            (CN, "https://dashscope.aliyuncs.com/compatible-mode/v1"),
            (GL, "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"),
        ],
    },
    Preset {
        id: "volcengine",
        protocol: "openai",
        endpoints: &[(CN, "https://ark.cn-beijing.volces.com/api/v3"), (GL, "https://ark.ap-southeast.bytepluses.com/api/v3")],
    },
    Preset { id: "moonshot", protocol: "openai", endpoints: &[(CN, "https://api.moonshot.cn/v1"), (GL, "https://api.moonshot.ai/v1")] },
    Preset {
        id: "zhipu",
        protocol: "openai",
        endpoints: &[(CN, "https://open.bigmodel.cn/api/paas/v4"), (GL, "https://api.z.ai/api/paas/v4")],
    },
    // a Token Plan (subscription) key — sk-cp- — works on the same addresses as a pay-as-you-go one
    Preset { id: "minimax", protocol: "openai", endpoints: &[(CN, "https://api.minimax.cn/v1"), (GL, "https://api.minimax.io/v1")] },
    Preset { id: "xiaomi", protocol: "openai", endpoints: &[(None, "https://api.xiaomimimo.com/v1")] },
    Preset { id: "openai", protocol: "openai", endpoints: &[(None, "https://api.openai.com/v1")] },
    Preset { id: "anthropic", protocol: "anthropic", endpoints: &[(None, "https://api.anthropic.com")] },
    Preset { id: "gemini", protocol: "openai", endpoints: &[(None, "https://generativelanguage.googleapis.com/v1beta/openai")] },
    Preset { id: "openrouter", protocol: "openai", endpoints: &[(None, "https://openrouter.ai/api/v1")] },
    Preset { id: "custom-openai", protocol: "openai", endpoints: &[] },
    Preset { id: "custom-anthropic", protocol: "anthropic", endpoints: &[] },
];

pub fn preset(id: &str) -> Option<&'static Preset> {
    PRESETS.iter().find(|p| p.id == id)
}

/// A free id for a new service of a preset (the Mac's CloudService.newID): the preset's own, else "<preset>-2", "-3"…;
/// the user's own services "custom-1", "custom-2"…
pub fn new_id(preset_id: &str, taken: &[String]) -> String {
    let custom = preset_id.starts_with("custom");
    let stem = if custom { "custom" } else { preset_id };
    if !custom && !taken.iter().any(|t| t == stem) {
        return stem.to_string();
    }
    let mut n = if custom { 1 } else { 2 };
    while taken.iter().any(|t| *t == format!("{stem}-{n}")) {
        n += 1;
    }
    format!("{stem}-{n}")
}

/// A service's address and protocol: its own base URL when it has one, else its preset's for its region. An unknown
/// preset (an older or newer Blurt's) is sent as OpenAI-compatible to its own address.
pub fn address(svc: &Value) -> (String, &'static str) {
    let p = preset(svc["preset"].as_str().unwrap_or(""));
    let own = svc["base_url"].as_str().map(str::trim).filter(|b| !b.is_empty());
    let base = own
        .map(str::to_string)
        .or_else(|| p.and_then(|p| p.base(svc["region"].as_str())).map(str::to_string))
        .unwrap_or_default();
    (base, p.map_or("openai", |p| p.protocol))
}

/// The request's `cloud` object for polish.py / polish_cloud.py (polish_cloud.settings) for one service and model.
pub fn request(svc: &Value, model: &str, key: &str) -> Value {
    let (base_url, proto) = address(svc);
    json!({"provider": svc["preset"].as_str().unwrap_or("custom"), "service": svc["id"], "base_url": base_url,
           "model": model, "protocol": proto, "key": key, "translate_model": model, "vision_model": model})
}

/// What keeps a Custom Model's Save from even testing (the Mac's CloudCustom.problem), as the failure's code: the
/// address (https, or http only to this computer), the model id, the key (none typed and none saved, or one no key can
/// be). None: Save may test.
pub fn custom_problem(base_url: &str, model: &str, typed_key: &str, key_saved: bool) -> Option<&'static str> {
    if !valid_address(base_url) {
        return Some("address");
    }
    if !valid_model_id(model.trim()) {
        return Some("model_id");
    }
    let k = typed_key.trim();
    if k.is_empty() {
        return (!key_saved).then_some("no_key");
    }
    if k.chars().any(char::is_whitespace) {
        return Some("key_spaces");
    }
    // printable ASCII only: an HTTP header can't carry anything else
    if k.chars().any(|c| !c.is_ascii_graphic()) {
        return Some("key_characters");
    }
    None
}

/// An address a key may go to: https, or http only to this computer (a local server).
pub fn valid_address(s: &str) -> bool {
    let s = s.trim();
    let (scheme, rest) = match s.split_once("://") {
        Some(x) => x,
        None => return false,
    };
    let host_port = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host = if host_port.starts_with('[') {
        host_port.split(']').next().map(|h| format!("{h}]")).unwrap_or_default()
    } else {
        host_port.split(':').next().unwrap_or("").to_string()
    };
    if host.is_empty() || host.contains('@') || host.contains(' ') {
        return false;
    }
    match scheme.to_ascii_lowercase().as_str() {
        "https" => true,
        "http" => ["localhost", "127.0.0.1", "[::1]"].contains(&host.as_str()),
        _ => false,
    }
}

/// A model id as services write them: letters, digits and . _ - : / @ + (OpenRouter's "vendor/model"), up to 100.
pub fn valid_model_id(s: &str) -> bool {
    let mut cs = s.chars();
    matches!(cs.next(), Some(c) if c.is_ascii_alphanumeric())
        && s.len() <= 100
        && cs.all(|c| c.is_ascii_alphanumeric() || "._:/@+-".contains(c))
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

/// Model Studio's speech model for its recogniser (`asr.cloud["qwen3-asr-flash"].model`, the Mac's CloudSpeech
/// storage; None = Qwen3-ASR Flash, the default): one of the measured speech models (curated.json `speech`).
pub fn dashscope_speech_model() -> Option<String> {
    settings::read_config()
        .pointer("/asr/cloud/qwen3-asr-flash/model")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|m| !m.is_empty())
        .map(str::to_string)
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
    let k = key(svc["id"].as_str()?)?;
    Some(request(&svc, &model, &k))
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
                if let Some(m) = dashscope_speech_model() {
                    out.push(("DASHSCOPE_ASR_MODEL", m));
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
    let mut svc = json!({"id": preset_id, "preset": preset_id});
    if let Some(b) = base_url.filter(|b| !b.trim().is_empty()) {
        svc["base_url"] = json!(b.trim());
    }
    if let Some(n) = name.filter(|n| !n.trim().is_empty()) {
        svc["name"] = json!(n.trim());
    }
    connect_service(svc, Some(key_value))
}

/// Save a service as given ({"id", "preset", "region"?, "base_url"?, "name"?}, replacing one with its id) and, when a
/// key comes with it, its key.
pub fn connect_service(svc: Value, key_value: Option<&str>) -> Result<String, String> {
    let id = svc["id"].as_str().filter(|i| !i.is_empty()).ok_or("no service id")?.to_string();
    let k = key_value.map(str::trim);
    if k == Some("") {
        return Err("empty key".into());
    }
    let mut s = setup();
    let mut services: Vec<Value> = s["services"].as_array().cloned().unwrap_or_default();
    services.retain(|x| x["id"] != json!(id));
    services.push(svc);
    s["services"] = json!(services);
    s["v"] = json!(2);
    if s.get("jobs").is_none() {
        s["jobs"] = json!({});
    }
    if let Some(k) = k {
        store_key(&id, k)?;
    }
    save(s)?;
    Ok(id)
}

/// Put a job on a service's model (record.cloud.jobs[job] = {"service", "model"}).
pub fn set_job(job: &str, service: &str, model: &str) -> Result<(), String> {
    let mut s = setup();
    if s.get("jobs").and_then(Value::as_object).is_none() {
        s["jobs"] = json!({});
    }
    s["jobs"][job] = json!({"service": service, "model": model.trim()});
    s["v"] = json!(2);
    save(s)
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

// Linux: the Secret Service (dictation/secret_linux.rs)
#[cfg(target_os = "linux")]
pub fn key(id: &str) -> Option<String> {
    test_key().or_else(|| super::secret_linux::key(id))
}

#[cfg(target_os = "linux")]
fn store_key(id: &str, k: &str) -> Result<(), String> {
    super::secret_linux::store_key(id, k)
}

#[cfg(target_os = "linux")]
fn delete_key(id: &str) {
    super::secret_linux::delete_key(id)
}

#[cfg(not(any(windows, target_os = "linux")))]
pub fn key(_id: &str) -> Option<String> {
    test_key()
}

#[cfg(not(any(windows, target_os = "linux")))]
fn store_key(_id: &str, _k: &str) -> Result<(), String> {
    Err("no key store on this system yet".into())
}

#[cfg(not(any(windows, target_os = "linux")))]
fn delete_key(_id: &str) {}

#[cfg(test)]
mod tests {
    use serde_json::json;

    #[test]
    fn the_presets_addresses_by_region() {
        let mm = super::preset("minimax").unwrap();
        assert!(mm.regional() && !mm.custom());
        assert_eq!(mm.base(Some("china")), Some("https://api.minimax.cn/v1"));
        assert_eq!(mm.base(Some("global")), Some("https://api.minimax.io/v1"));
        // a service saved without a region: the first address (Model Studio's Beijing one, as before regions)
        assert_eq!(super::preset("dashscope").unwrap().base(None), Some("https://dashscope.aliyuncs.com/compatible-mode/v1"));
        assert_eq!(super::preset("deepseek").unwrap().base(Some("global")), Some("https://api.deepseek.com"));
        assert!(super::preset("custom-openai").unwrap().custom());
        assert_eq!(super::preset("custom-anthropic").unwrap().base(None), None);
        assert_eq!(super::preset("anthropic").unwrap().protocol, "anthropic");
        assert!(super::preset("volcengine-speech").is_none());
    }

    #[test]
    fn a_service_is_sent_to_its_address_in_its_protocol() {
        let c = super::request(
            &json!({"id": "custom-1", "preset": "custom-anthropic", "base_url": " https://api.minimax.io/anthropic "}),
            "MiniMax-M3",
            "sk-cp-x",
        );
        assert_eq!(c["protocol"], "anthropic");
        assert_eq!(c["base_url"], "https://api.minimax.io/anthropic");
        assert_eq!(c["model"], "MiniMax-M3");
        assert_eq!(c["service"], "custom-1");
        let c = super::request(&json!({"id": "custom-2", "preset": "custom-openai", "base_url": "https://opencode.ai/zen/go/v1"}), "m", "k");
        assert_eq!((c["protocol"].as_str(), c["base_url"].as_str()), (Some("openai"), Some("https://opencode.ai/zen/go/v1")));
        let c = super::request(&json!({"id": "minimax", "preset": "minimax", "region": "global"}), "MiniMax-M3", "k");
        assert_eq!((c["protocol"].as_str(), c["base_url"].as_str()), (Some("openai"), Some("https://api.minimax.io/v1")));
        let c = super::request(&json!({"id": "moonshot", "preset": "moonshot", "region": "china"}), "kimi", "k");
        assert_eq!(c["base_url"], "https://api.moonshot.cn/v1");
        let c = super::request(&json!({"id": "anthropic", "preset": "anthropic"}), "claude", "k");
        assert_eq!((c["protocol"].as_str(), c["base_url"].as_str()), (Some("anthropic"), Some("https://api.anthropic.com")));
        // a preset this build doesn't know: OpenAI-compatible, at its own address
        let c = super::request(&json!({"id": "x", "preset": "future", "base_url": "https://x.example/v1"}), "m", "k");
        assert_eq!((c["protocol"].as_str(), c["base_url"].as_str()), (Some("openai"), Some("https://x.example/v1")));
    }

    #[test]
    fn a_new_services_id() {
        let taken = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(super::new_id("minimax", &taken(&["deepseek"])), "minimax");
        assert_eq!(super::new_id("minimax", &taken(&["minimax"])), "minimax-2");
        assert_eq!(super::new_id("custom-openai", &taken(&[])), "custom-1");
        assert_eq!(super::new_id("custom-anthropic", &taken(&["custom-1", "custom-2"])), "custom-3");
    }

    #[test]
    fn what_keeps_a_custom_model_from_testing() {
        let p = super::custom_problem;
        assert_eq!(p("https://api.minimax.io/v1", "MiniMax-M3", "sk-cp-abc", false), None);
        assert_eq!(p("http://localhost:11434/v1", "qwen3:8b", "", true), None);
        assert_eq!(p("http://api.example.com/v1", "m", "k", false), Some("address"));
        assert_eq!(p("api.example.com/v1", "m", "k", false), Some("address"));
        assert_eq!(p("https://openrouter.ai/api/v1", "openai/gpt-6-mini", "k", false), None);
        assert_eq!(p("https://x.example/v1", "", "k", false), Some("model_id"));
        assert_eq!(p("https://x.example/v1", "a model", "k", false), Some("model_id"));
        assert_eq!(p("https://x.example/v1", "m", "  ", false), Some("no_key"));
        assert_eq!(p("https://x.example/v1", "m", "sk-a b", false), Some("key_spaces"));
        assert_eq!(p("https://x.example/v1", "m", "sk-\u{e7}", false), Some("key_characters"));
    }

    #[test]
    fn the_volcengine_pair() {
        assert_eq!(super::volc_split(" 123:abc:def "), Some(("123".into(), "abc:def".into())));
        assert_eq!(super::volc_split("nopair"), None);
        assert_eq!(super::volc_split(":x"), None);
    }
}
