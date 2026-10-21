//! `$BLURT_HOME/config.json`, shared with record.py and the macOS app. Writes merge like `_common.update_global_config`
//! (a top-level object merges one level deep) and are atomic (tmp + rename).

use std::path::Path;

use serde_json::{json, Map, Value};

use crate::paths;

pub fn read_config() -> Value {
    read_json(&paths::config_file()).unwrap_or_else(|| json!({}))
}

pub fn read_json(p: &Path) -> Option<Value> {
    let raw = std::fs::read(p).ok()?;
    let raw = raw.strip_prefix("\u{feff}".as_bytes()).unwrap_or(&raw);
    serde_json::from_slice(raw).ok().filter(Value::is_object)
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
    let cfg = merged(read_config(), &patch);
    write_config(&cfg)?;
    Ok(cfg)
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
}
