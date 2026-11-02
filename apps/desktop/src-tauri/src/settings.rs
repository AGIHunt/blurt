//! `$BLURT_HOME/config.json`, shared with record.py and the macOS app. Writes merge like `_common.update_global_config`
//! (a top-level object merges one level deep) and are atomic (tmp + rename), read-modify-write under
//! `$BLURT_HOME/.config.lock` — the lock `_common.update_global_config` takes, so neither side loses the other's change —
//! and never over a config.json that doesn't parse (the hand-edited file stays as it is: `config_unreadable`).

use std::path::Path;

use serde_json::{json, Map, Value};

use crate::paths;

pub fn read_config() -> Value {
    read_json(&paths::config_file()).unwrap_or_else(|| json!({}))
}

pub fn read_json(p: &Path) -> Option<Value> {
    parse(&std::fs::read(p).ok()?)
}

/// `_common.parse_config_text`: an object, a BOM and trailing commas allowed.
fn parse(raw: &[u8]) -> Option<Value> {
    let raw = raw.strip_prefix("\u{feff}".as_bytes()).unwrap_or(raw);
    if let Ok(v) = serde_json::from_slice::<Value>(raw) {
        return Some(v).filter(Value::is_object);
    }
    let text = std::str::from_utf8(raw).ok()?;
    serde_json::from_str::<Value>(&drop_trailing_commas(text)).ok().filter(Value::is_object)
}

/// `_common.drop_trailing_commas`: a comma before `}` / `]` (outside strings) left out.
fn drop_trailing_commas(s: &str) -> String {
    let b: Vec<char> = s.chars().collect();
    let (mut out, mut in_str, mut esc) = (String::with_capacity(s.len()), false, false);
    for (i, &c) in b.iter().enumerate() {
        if in_str {
            out.push(c);
            if esc {
                esc = false;
            } else if c == '\\' {
                esc = true;
            } else if c == '"' {
                in_str = false;
            }
            continue;
        }
        if c == '"' {
            in_str = true;
        } else if c == ',' && b[i + 1..].iter().find(|x| !x.is_whitespace()).is_some_and(|x| *x == '}' || *x == ']') {
            continue;
        }
        out.push(c);
    }
    out
}

/// The merge rule of update_global_config, plus `null` deletes a key at either level.
pub fn merged(mut cfg: Value, patch: &Value) -> Value {
    let (Some(c), Some(p)) = (cfg.as_object_mut(), patch.as_object()) else { return cfg };
    for (k, v) in p {
        match (c.get_mut(k), v) {
            (_, Value::Null) => {
                c.remove(k);
            }
            (Some(Value::Object(cur)), Value::Object(nv)) => {
                for (k2, v2) in nv {
                    if v2.is_null() {
                        cur.remove(k2);
                    } else {
                        cur.insert(k2.clone(), v2.clone());
                    }
                }
            }
            _ => {
                c.insert(k.clone(), v.clone());
            }
        }
    }
    cfg
}

pub fn write_config(cfg: &Value) -> Result<(), String> {
    let p = paths::config_file();
    if let Some(d) = p.parent() {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    let tmp = p.with_extension(format!("json.{}.tmp", std::process::id()));
    let body = serde_json::to_string_pretty(cfg).map_err(|e| e.to_string())?;
    std::fs::write(&tmp, body).map_err(|e| format!("{}: {e}", tmp.display()))?;
    let mut last = None;
    for _ in 0..20 {
        match std::fs::rename(&tmp, &p) {
            Ok(()) => return Ok(()),
            Err(e) => {
                last = Some(e);
                std::thread::sleep(std::time::Duration::from_millis(50)); // Windows: a reader holds the file
            }
        }
    }
    Err(format!("{}: {}", p.display(), last.map(|e| e.to_string()).unwrap_or_default()))
}

pub fn merge(patch: Value) -> Result<Value, String> {
    update(|cfg| *cfg = merged(std::mem::take(cfg), &patch))
}

/// Read-modify-write config.json under `.config.lock` (shared with the skill's Python). Err("config_unreadable: …")
/// leaves a config.json that doesn't parse untouched, rather than replacing every setting with this one change.
pub fn update(f: impl FnOnce(&mut Value)) -> Result<Value, String> {
    static IN_PROCESS: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _g = IN_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    let p = paths::config_file();
    let _lock = file_lock(&p.with_file_name(".config.lock"));
    let mut cfg = match std::fs::read(&p) {
        Ok(raw) => parse(&raw).ok_or_else(|| format!("config_unreadable: {} doesn't parse; nothing was saved — fix or remove it", p.display()))?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => json!({}),
        Err(e) => return Err(format!("{}: {e}", p.display())),
    };
    f(&mut cfg);
    write_config(&cfg)?;
    Ok(cfg)
}

/// `_common.file_lock`: an exclusive lock on the lock file (flock / LockFileEx — msvcrt.locking's byte 0 overlaps it),
/// tried for up to 15 s; past that the write goes ahead unlocked rather than losing the user's setting.
fn file_lock(p: &Path) -> Option<std::fs::File> {
    if let Some(d) = p.parent() {
        let _ = std::fs::create_dir_all(d);
    }
    let f = std::fs::OpenOptions::new().create(true).append(true).read(true).open(p).ok()?;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
    loop {
        match f.try_lock() {
            Ok(()) => return Some(f), // unlocked when the file closes
            Err(std::fs::TryLockError::WouldBlock) if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(20))
            }
            Err(_) => return None,
        }
    }
}

/// Export targets the skill knows about (export_local.py / feishu.py), with whether they're configured.
pub fn export_targets(cfg: &Value) -> Value {
    let feishu = cfg.get("feishu").and_then(Value::as_object).cloned().unwrap_or_else(Map::new);
    json!([
        {"id": "markdown", "name": "Markdown", "configured": true},
        {"id": "csv", "name": "CSV", "configured": true},
        {"id": "github", "name": "GitHub Issues", "configured": true, "needs": "gh auth login"},
        {"id": "feishu", "name": "Feishu / Lark Bitable", "configured": !feishu.is_empty()},
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merge_rule() {
        let cfg = json!({"record": {"agents": ["claude"], "hotkeys": {"snap": "off"}}, "asr": {"backend": "x"}});
        let out = merged(cfg, &json!({"record": {"agents": ["codex"], "workspace": null}, "asr": null, "new": 1}));
        assert_eq!(out, json!({"record": {"agents": ["codex"], "hotkeys": {"snap": "off"}}, "new": 1}));
    }

    #[test]
    fn trailing_commas_and_bom_parse_like_common_py() {
        assert_eq!(parse(b"{\"a\": [1, 2,], \"b\": \"x,}\",}"), Some(json!({"a": [1, 2], "b": "x,}"})));
        assert_eq!(parse("\u{feff}{}".as_bytes()), Some(json!({})));
        assert_eq!(parse(b"{\"a\": "), None);
        assert_eq!(parse(b"[1]"), None);
    }
}
