//! The review component's tauri host (C6 → C8): load / poll read items.json directly (with the same ETag as
//! review.py's GET /api/items), every write goes through `items.py user-ops` (the same apply_user_ops as review.py).

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{json, Value};
use sha1::{Digest, Sha1};

use crate::scripts::Runner;

/// `_common.file_etag`: sha1 of the file bytes, 16 hex chars, quoted.
pub fn file_etag(raw: &[u8]) -> String {
    let h = Sha1::digest(raw);
    let hex: String = h.iter().map(|b| format!("{b:02x}")).collect();
    format!("\"{}\"", &hex[..16])
}

fn items_file(session: &str) -> PathBuf {
    Path::new(session).join("items.json")
}

fn read(session: &str) -> Result<(Vec<u8>, String), String> {
    let p = items_file(session);
    let raw = std::fs::read(&p).map_err(|e| format!("{}: {e}", p.display()))?;
    let etag = file_etag(&raw);
    Ok((raw, etag))
}

fn parse(raw: &[u8]) -> Result<Value, String> {
    let raw = raw.strip_prefix("\u{feff}".as_bytes()).unwrap_or(raw); // PowerShell / Notepad BOM, as load_json
    serde_json::from_slice(raw).map_err(|e| format!("items.json: {e}"))
}

/// → {doc, etag, session}
pub fn load(session: &str) -> Result<Value, String> {
    let (raw, etag) = read(session)?;
    Ok(json!({"doc": parse(&raw)?, "etag": etag, "session": session}))
}

/// → {etag} when unchanged, {doc, etag} otherwise
pub fn poll(session: &str, etag: &str) -> Result<Value, String> {
    let (raw, now) = read(session)?;
    if now == etag {
        return Ok(json!({"etag": now}));
    }
    Ok(json!({"doc": parse(&raw)?, "etag": now}))
}

/// → {ok, etag}; ops = [{op:"set"|"remove"|"add", …}] (C2 user-ops)
pub fn ops(runner: &Runner, session: &str, ops: &Value, confirm: bool) -> Result<Value, String> {
    let body = json!({"ops": ops}).to_string();
    let mut args = vec!["user-ops".to_string(), session.to_string(), "--stdin".to_string()];
    if confirm {
        args.push("--confirm".into());
    }
    runner.run("items.py", &args, Some(body.as_bytes()), Duration::from_secs(30)).map_err(String::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn etag_matches_python() {
        // python3 -c 'import hashlib;print(hashlib.sha1(b"{}").hexdigest()[:16])'
        assert_eq!(file_etag(b"{}"), "\"bf21a9e8fbc5a384\"");
    }

    #[test]
    fn load_and_poll() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("items.json"), "\u{feff}{\"items\": []}").unwrap();
        let s = d.path().to_str().unwrap();
        let v = load(s).unwrap();
        let etag = v["etag"].as_str().unwrap().to_string();
        assert!(v["doc"]["items"].is_array());
        assert!(poll(s, &etag).unwrap().get("doc").is_none());
        std::fs::write(d.path().join("items.json"), "{\"items\": [{\"id\": \"I-001\"}]}").unwrap();
        let p = poll(s, &etag).unwrap();
        assert_eq!(p["doc"]["items"][0]["id"], "I-001");
        assert_ne!(p["etag"], etag);
    }
}
