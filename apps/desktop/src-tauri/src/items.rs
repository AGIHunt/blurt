//! The review component's host (protocol v3) over `items.py` v3 (contract K1): `doc` builds the document from the
//! Markdown items of one session or one project, `poll` answers "changed since this etag?", `user-ops` applies the
//! user's edits. A scope is `{"session": abs}` or `{"project": id | "inbox", "status"?, "work"?, "kind"?}`.
//!
//! The component polls every couple of seconds. Each poll would start Python, so we answer from a cache instead
//! while nothing under a store changed: the watcher bumps [`bump`] on every change in a store's `items/` or
//! `sessions/`, and a poll whose etag is the one we last handed out for that scope returns unchanged at once.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use serde_json::{json, Value};

use crate::scripts::Runner;

static GENERATION: AtomicU64 = AtomicU64::new(1);

/// A store changed (the watcher calls this): cached etags are stale.
pub fn bump() {
    GENERATION.fetch_add(1, Ordering::SeqCst);
}

#[derive(Default)]
pub struct DocCache {
    /// scope key → (etag, generation it was computed at)
    last: Mutex<HashMap<String, (String, u64)>>,
}

impl DocCache {
    fn remember(&self, scope: &Value, etag: &str, generation: u64) {
        self.last.lock().unwrap().insert(scope_key(scope), (etag.to_string(), generation));
    }

    fn fresh(&self, scope: &Value, etag: &str) -> bool {
        let now = GENERATION.load(Ordering::SeqCst);
        self.last.lock().unwrap().get(&scope_key(scope)).is_some_and(|(e, g)| e == etag && *g == now)
    }
}

fn scope_key(scope: &Value) -> String {
    serde_json::to_string(scope).unwrap_or_default()
}

/// `{"session": "/abs"}` → [SESSION]; `{"project": "p", "status": ["draft"], …}` → [--project p --status draft …].
pub fn scope_args(scope: &Value) -> Result<Vec<String>, String> {
    if let Some(s) = scope.get("session").and_then(Value::as_str) {
        return Ok(vec![s.to_string()]);
    }
    let p = scope.get("project").and_then(Value::as_str).ok_or("scope needs a session or a project")?;
    let mut out = vec!["--project".to_string(), p.to_string()];
    for (key, flag) in [("status", "--status"), ("work", "--work"), ("kind", "--kind")] {
        for v in scope.get(key).and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str) {
            out.push(flag.into());
            out.push(v.into());
        }
    }
    Ok(out)
}

/// → {doc, etag}
pub fn doc(runner: &Runner, cache: &DocCache, scope: &Value) -> Result<Value, String> {
    let generation = GENERATION.load(Ordering::SeqCst);
    let mut args = vec!["doc".to_string()];
    args.extend(scope_args(scope)?);
    let r = runner.run("items.py", &args, None, Duration::from_secs(30)).map_err(String::from)?;
    let etag = r.get("etag").and_then(Value::as_str).unwrap_or("").to_string();
    cache.remember(scope, &etag, generation);
    Ok(json!({"doc": r.get("doc").cloned().unwrap_or(Value::Null), "etag": etag}))
}

/// → {etag} when unchanged, {doc, etag} otherwise
pub fn poll(runner: &Runner, cache: &DocCache, scope: &Value, etag: &str) -> Result<Value, String> {
    if cache.fresh(scope, etag) {
        return Ok(json!({"etag": etag}));
    }
    let generation = GENERATION.load(Ordering::SeqCst);
    let mut args = vec!["poll".to_string()];
    args.extend(scope_args(scope)?);
    args.extend(["--etag".to_string(), etag.to_string()]);
    let r = runner.run("items.py", &args, None, Duration::from_secs(30)).map_err(String::from)?;
    let now = r.get("etag").and_then(Value::as_str).unwrap_or(etag).to_string();
    cache.remember(scope, &now, generation);
    Ok(match r.get("doc") {
        Some(d) if !d.is_null() => json!({"doc": d, "etag": now}),
        _ => json!({"etag": now}),
    })
}

/// → {ok, etag, doc}; ops as `items.py user-ops` takes them (set / remove / add / work, ids are uids).
pub fn ops(runner: &Runner, cache: &DocCache, scope: &Value, ops: &Value, confirm: bool) -> Result<Value, String> {
    let body = json!({"ops": ops}).to_string();
    let mut args = vec!["user-ops".to_string()];
    args.extend(scope_args(scope)?);
    args.push("--stdin".into());
    if confirm {
        args.push("--confirm".into());
    }
    let r = runner.run("items.py", &args, Some(body.as_bytes()), Duration::from_secs(30)).map_err(String::from)?;
    bump(); // our own write: every other scope may show these items too
    if let Some(e) = r.get("etag").and_then(Value::as_str) {
        cache.remember(scope, e, GENERATION.load(Ordering::SeqCst));
    }
    Ok(r)
}

/// `items.py work` for the list's own buttons (confirm done, reopen, won't do) — K3 says only the user sets done.
pub fn work(runner: &Runner, uids: &[String], state: &str, note: Option<&str>) -> Result<Value, String> {
    let mut args = vec!["work".to_string()];
    args.extend(uids.iter().cloned());
    args.extend(["--state".into(), state.into(), "--by".into(), "user".into()]);
    if let Some(n) = note.filter(|n| !n.is_empty()) {
        args.extend(["--note".into(), n.into()]);
    }
    let r = runner.run("items.py", &args, None, Duration::from_secs(30)).map_err(String::from)?;
    bump();
    Ok(r)
}

/// `items.py move` — the user drags items onto a project (K2: a user's choice is never overridden by the AI).
pub fn move_items(runner: &Runner, uids: &[String], project: &str) -> Result<Value, String> {
    let mut args = vec!["move".to_string()];
    args.extend(uids.iter().cloned());
    args.extend(["--project".into(), project.into(), "--by".into(), "user".into()]);
    let r = runner.run("items.py", &args, None, Duration::from_secs(30)).map_err(String::from)?;
    bump();
    Ok(r)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scopes() {
        assert_eq!(scope_args(&json!({"session": "/s/x"})).unwrap(), ["/s/x"]);
        assert_eq!(
            scope_args(&json!({"project": "inbox", "status": ["draft"], "work": ["todo", "to_verify"]})).unwrap(),
            ["--project", "inbox", "--status", "draft", "--work", "todo", "--work", "to_verify"]
        );
        assert!(scope_args(&json!({})).is_err());
    }

    #[test]
    fn cache_follows_generation() {
        let c = DocCache::default();
        let s = json!({"project": "p"});
        c.remember(&s, "\"e1\"", GENERATION.load(Ordering::SeqCst));
        assert!(c.fresh(&s, "\"e1\""));
        assert!(!c.fresh(&s, "\"e0\""));
        assert!(!c.fresh(&json!({"project": "q"}), "\"e1\""));
        bump();
        assert!(!c.fresh(&s, "\"e1\""));
    }
}
