//! Jobs — everything that is happening (contract K4): recordings, snaps, voice notes, sorting, filing, agent sessions.
//! `$BLURT_HOME/jobs/<id>.json` is written only by the job's owner; anyone else appends to `<id>.events.jsonl`, and
//! every reader folds those events over the json the same way (here, `jobs.py`, and the macOS JobStore), so a job's
//! state is current even while its owner isn't running.
//!
//! The app owns record / snap / voice / process jobs ([`JobWriter`]); sessions.py owns agent jobs, projects.py route
//! jobs. [`transitions`] turns two snapshots into what deserves a word to the user (the K4 reminder rules are applied
//! by the caller: never open anything, system notifications only when Blurt isn't in front).

use std::collections::{BTreeSet, HashMap};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

use crate::{paths, projects};

/// `j-YYYYMMDD-HHMMSS-xxxx` (4 lowercase base32 characters).
pub fn new_id() -> String {
    const B32: &[u8] = b"abcdefghijklmnopqrstuvwxyz234567";
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0) as u64;
    // splitmix64 over the clock and the pid: distinct across the app's threads and processes
    let mut z = nanos ^ (u64::from(std::process::id()) << 32);
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    z ^= z >> 31;
    let tail: String = (0..4).map(|i| B32[((z >> (i * 5)) & 31) as usize] as char).collect();
    format!("j-{}-{tail}", projects::timestamp())
}

/// `<jobs>/<id>.json` is a job; `<id>.claude-settings.json`, `.events.jsonl`, … are its attachments.
pub fn is_job_file(p: &Path) -> bool {
    let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    name.starts_with("j-") && name.ends_with(".json") && name.matches('.').count() == 1
}

/// The job id a path in `jobs/` belongs to (`j-…-ab12.events.jsonl` → `j-…-ab12`).
pub fn id_of(p: &Path) -> Option<String> {
    let name = p.file_name()?.to_string_lossy().into_owned();
    name.starts_with("j-").then(|| name.split('.').next().unwrap_or("").to_string()).filter(|s| !s.is_empty())
}

/// K4's fold: events in order; a step replaces the one with its id, `status` goes to agent.status / status_at /
/// status_source, `state` and `progress` replace, `items` are added to the set.
pub fn fold(mut job: Value, events: &str) -> Value {
    for line in events.lines() {
        let Ok(e) = serde_json::from_str::<Value>(line.trim()) else { continue };
        let t = e.get("t").cloned().unwrap_or(Value::Null);
        if let Some(step) = e.get("step").filter(|s| s.get("id").is_some()) {
            let steps = job.get_mut("steps").and_then(Value::as_array_mut);
            match steps {
                Some(list) => match list.iter_mut().find(|s| s.get("id") == step.get("id")) {
                    Some(cur) => {
                        if let (Some(c), Some(n)) = (cur.as_object_mut(), step.as_object()) {
                            for (k, v) in n {
                                c.insert(k.clone(), v.clone());
                            }
                        }
                    }
                    None => list.push(step.clone()),
                },
                None => job["steps"] = json!([step]),
            }
        }
        if let Some(st) = e.get("status") {
            if !job.get("agent").is_some_and(Value::is_object) {
                job["agent"] = json!({});
            }
            job["agent"]["status"] = st.clone();
            job["agent"]["status_at"] = t.clone();
            job["agent"]["status_source"] = e.get("source").cloned().unwrap_or(Value::Null);
        }
        if let Some(s) = e.get("state") {
            job["state"] = s.clone();
        }
        if let Some(p) = e.get("progress") {
            job["progress"] = p.clone();
        }
        if let Some(items) = e.get("items").and_then(Value::as_array) {
            let mut have: Vec<Value> = job.get("items").and_then(Value::as_array).cloned().unwrap_or_default();
            for i in items {
                if !have.contains(i) {
                    have.push(i.clone());
                }
            }
            job["items"] = Value::Array(have);
        }
        if t.is_string() {
            job["updated"] = t;
        }
    }
    job
}

fn read_events(id: &str, offset: u64) -> String {
    let p = paths::jobs_dir().join(format!("{id}.events.jsonl"));
    let Ok(mut f) = std::fs::File::open(&p) else { return String::new() };
    let mut s = String::new();
    if f.seek(SeekFrom::Start(offset)).is_ok() {
        let _ = f.read_to_string(&mut s);
    }
    s
}

/// One job's effective state.
pub fn load(id: &str) -> Option<Value> {
    let raw = std::fs::read(paths::jobs_dir().join(format!("{id}.json"))).ok()?;
    let job: Value = serde_json::from_slice(&raw).ok().filter(Value::is_object)?;
    let offset = job.get("events_offset").and_then(Value::as_u64).unwrap_or(0);
    Some(fold(job, &read_events(id, offset)))
}

pub fn is_active(j: &Value) -> bool {
    matches!(j.get("state").and_then(Value::as_str), Some("queued" | "running"))
}

/// Effective jobs, newest first (ids embed their start time).
pub fn list(active_only: bool, limit: usize) -> Vec<Value> {
    let mut ids: Vec<String> = std::fs::read_dir(paths::jobs_dir())
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| is_job_file(p))
        .filter_map(|p| id_of(&p))
        .collect();
    ids.sort_unstable_by(|a, b| b.cmp(a));
    ids.iter().filter_map(|id| load(id)).filter(|j| !active_only || is_active(j)).take(limit).collect()
}

/// A job the app owns (record / snap / voice / process). Every change rewrites `<id>.json` atomically, after
/// folding what others appended, so the file always carries the effective state.
pub struct JobWriter {
    pub id: String,
    job: Mutex<Value>,
}

impl JobWriter {
    pub fn new(kind: &str, project: Option<&str>, session: Option<&Path>, parent: Option<&str>, title: Option<&str>, steps: &[&str]) -> Self {
        let now = projects::iso_now();
        let id = new_id();
        let job = json!({
            "schema": 1, "id": id, "type": kind, "state": "running", "owner": "app",
            "project": project, "session": session.map(|s| s.to_string_lossy().into_owned()),
            "parent": parent, "title": title, "items": [], "captures": [],
            "steps": steps.iter().map(|s| json!({"id": s, "state": "pending", "progress": null, "started": null, "ended": null})).collect::<Vec<_>>(),
            "progress": null, "created": now, "started": now, "ended": null, "updated": now,
            "events_offset": 0, "error": null,
        });
        let w = JobWriter { id, job: Mutex::new(job) };
        w.save();
        w
    }

    pub fn snapshot(&self) -> Value {
        self.job.lock().unwrap().clone()
    }

    fn save(&self) {
        let dir = paths::jobs_dir();
        let _ = std::fs::create_dir_all(&dir);
        let mut job = self.job.lock().unwrap();
        // fold what others appended since the last save, and remember how far we got
        let offset = job.get("events_offset").and_then(Value::as_u64).unwrap_or(0);
        let ev = read_events(&self.id, offset);
        if !ev.is_empty() {
            let folded = fold(job.clone(), &ev);
            *job = folded;
            job["events_offset"] = json!(offset + ev.len() as u64);
        }
        job["updated"] = json!(projects::iso_now());
        let p = dir.join(format!("{}.json", self.id));
        let tmp = dir.join(format!(".{}.{}.tmp", self.id, std::process::id()));
        if std::fs::write(&tmp, serde_json::to_vec_pretty(&*job).unwrap_or_default()).is_ok() {
            let _ = std::fs::rename(&tmp, &p);
        }
    }

    pub fn step(&self, id: &str, state: &str, progress: Option<f64>) {
        {
            let mut job = self.job.lock().unwrap();
            let now = projects::iso_now();
            if let Some(list) = job["steps"].as_array_mut() {
                if let Some(s) = list.iter_mut().find(|s| s["id"] == id) {
                    if state == "running" && s["started"].is_null() {
                        s["started"] = json!(now);
                    }
                    if matches!(state, "done" | "failed" | "skipped") {
                        s["ended"] = json!(now);
                    }
                    s["state"] = json!(state);
                    s["progress"] = json!(progress);
                }
            }
        }
        self.save();
    }

    pub fn set_items(&self, uids: &[String]) {
        self.job.lock().unwrap()["items"] = json!(uids);
        self.save();
    }

    pub fn set_captures(&self, n: &[u64]) {
        self.job.lock().unwrap()["captures"] = json!(n);
        self.save();
    }

    pub fn set_progress(&self, p: Option<f64>) {
        self.job.lock().unwrap()["progress"] = json!(p);
        self.save();
    }

    /// done | failed | cancelled; open steps end as skipped (done) or failed.
    pub fn finish(&self, state: &str, error: Option<(&str, &str)>) {
        {
            let mut job = self.job.lock().unwrap();
            let now = projects::iso_now();
            if let Some(list) = job["steps"].as_array_mut() {
                for s in list.iter_mut().filter(|s| matches!(s["state"].as_str(), Some("pending" | "running"))) {
                    s["state"] = json!(match (state, s["state"].as_str()) {
                        ("done", Some("running")) => "done",
                        ("done", _) => "skipped",
                        _ => "failed",
                    });
                    s["ended"] = json!(now);
                }
            }
            job["state"] = json!(state);
            job["ended"] = json!(now);
            if let Some((code, message)) = error {
                job["error"] = json!({"code": code, "message": message, "hint_key": null});
            }
        }
        self.save();
    }
}

/// Something worth telling the user about (K4 reminders). The caller decides where (island line, system
/// notification) by focus, recording state and settings.
#[derive(Debug, Clone, PartialEq)]
pub enum Notice {
    /// a sorting job finished: n items wait for review
    Sorted { job: String, title: Option<String>, items: usize, long: bool },
    Failed { job: String, kind: String, code: String, long: bool },
    /// an agent session asks for the user / finished a turn / exited
    Agent { job: String, agent: String, status: String, items: Vec<String> },
}

fn secs_between(a: &Value, b: &Value) -> f64 {
    let p = |v: &Value| v.as_str().and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok());
    match (p(a), p(b)) {
        (Some(x), Some(y)) => (y - x).num_milliseconds() as f64 / 1000.0,
        _ => 0.0,
    }
}

/// What changed between the last snapshot (id → job) and these jobs.
pub fn transitions(prev: &HashMap<String, Value>, now: &[Value]) -> Vec<Notice> {
    let mut out = Vec::new();
    for j in now {
        let id = j["id"].as_str().unwrap_or("").to_string();
        let Some(before) = prev.get(&id) else { continue }; // first sight: no news (startup, old jobs)
        let state = j["state"].as_str().unwrap_or("");
        let kind = j["type"].as_str().unwrap_or("").to_string();
        let long = secs_between(&j["started"], &j["ended"]) >= 20.0;
        if before["state"] != j["state"] {
            match (kind.as_str(), state) {
                ("process", "done") => out.push(Notice::Sorted {
                    job: id.clone(),
                    title: j["title"].as_str().map(str::to_owned),
                    items: j["items"].as_array().map_or(0, Vec::len),
                    long,
                }),
                (_, "failed") => out.push(Notice::Failed {
                    job: id.clone(),
                    kind: kind.clone(),
                    code: j.pointer("/error/code").and_then(Value::as_str).unwrap_or("unknown").to_string(),
                    long,
                }),
                _ => {}
            }
        }
        if kind == "agent" {
            let st = j.pointer("/agent/status").and_then(Value::as_str).unwrap_or("");
            let was = before.pointer("/agent/status").and_then(Value::as_str).unwrap_or("");
            if st != was && matches!(st, "waiting_input" | "turn_done" | "exited") {
                out.push(Notice::Agent {
                    job: id.clone(),
                    agent: j.pointer("/agent/id").and_then(Value::as_str).unwrap_or("agent").to_string(),
                    status: st.to_string(),
                    items: window_items(j),
                });
            }
        }
    }
    out
}

/// The item ids an agent window works on (its tmux window name, `BA-12,BA-13`), for notices and the island.
pub fn window_items(j: &Value) -> Vec<String> {
    j.pointer("/agent/tmux/name")
        .and_then(Value::as_str)
        .map(|n| n.split(',').map(str::to_owned).collect())
        .unwrap_or_default()
}

/// Ids of jobs whose files changed (the watcher's paths).
pub fn changed_ids(paths: &[PathBuf]) -> BTreeSet<String> {
    paths.iter().filter_map(|p| id_of(p)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_and_files() {
        let id = new_id();
        assert_eq!(id.len(), "j-20261022-101500-ab12".len(), "{id}");
        assert!(id[18..].chars().all(|c| "abcdefghijklmnopqrstuvwxyz234567".contains(c)));
        assert!(is_job_file(Path::new("/j/j-20261022-101500-ab12.json")));
        assert!(!is_job_file(Path::new("/j/j-20261022-101500-ab12.claude-settings.json")));
        assert_eq!(id_of(Path::new("/j/j-20261022-101500-ab12.events.jsonl")).as_deref(), Some("j-20261022-101500-ab12"));
    }

    #[test]
    fn fold_follows_k4() {
        let job = json!({"id": "j", "type": "agent", "state": "running", "items": ["u1"],
            "steps": [{"id": "launch", "state": "done"}, {"id": "work", "state": "pending"}], "agent": {"status": "running"}});
        let ev = [
            r#"{"t":"2026-10-22T10:00:01+08:00","source":"hook","event":"Notification","status":"waiting_input"}"#,
            r#"{"t":"2026-10-22T10:00:02+08:00","source":"items","event":"step","step":{"id":"work","state":"running","progress":0.5},"items":["u2","u1"]}"#,
            "not json",
            r#"{"t":"2026-10-22T10:00:03+08:00","source":"tmux","event":"pane-dead","status":"exited","state":"done","progress":1}"#,
        ]
        .join("\n");
        let f = fold(job, &ev);
        assert_eq!(f["agent"]["status"], "exited");
        assert_eq!(f["agent"]["status_source"], "tmux");
        assert_eq!(f["state"], "done");
        assert_eq!(f["progress"], 1);
        assert_eq!(f["items"], json!(["u1", "u2"]));
        assert_eq!(f["steps"][1], json!({"id": "work", "state": "running", "progress": 0.5}));
        assert_eq!(f["updated"], "2026-10-22T10:00:03+08:00");
    }

    #[test]
    fn notices() {
        let before: HashMap<String, Value> = [
            ("p".to_string(), json!({"id": "p", "type": "process", "state": "running"})),
            ("a".to_string(), json!({"id": "a", "type": "agent", "state": "running", "agent": {"status": "running"}})),
            ("r".to_string(), json!({"id": "r", "type": "record", "state": "running"})),
        ]
        .into();
        let now = vec![
            json!({"id": "p", "type": "process", "state": "done", "items": ["u1", "u2"], "started": "2026-10-22T10:00:00+08:00", "ended": "2026-10-22T10:00:30+08:00"}),
            json!({"id": "a", "type": "agent", "state": "running", "agent": {"id": "claude", "status": "waiting_input", "tmux": {"name": "BA-12,BA-13"}}}),
            json!({"id": "r", "type": "record", "state": "failed", "error": {"code": "io"}}),
            json!({"id": "new", "type": "process", "state": "done"}),
        ];
        let n = transitions(&before, &now);
        assert_eq!(n.len(), 3, "{n:?}");
        assert_eq!(n[0], Notice::Sorted { job: "p".into(), title: None, items: 2, long: true });
        assert!(matches!(&n[1], Notice::Agent { status, items, .. } if status == "waiting_input" && items == &["BA-12", "BA-13"]));
        assert!(matches!(&n[2], Notice::Failed { code, long: false, .. } if code == "io"));
    }

    #[test]
    fn writer_folds_others_events() {
        let d = tempfile::tempdir().unwrap();
        std::env::set_var("BLURT_HOME", d.path());
        let w = JobWriter::new("process", Some("p1"), None, None, None, &["prepare", "write"]);
        w.step("prepare", "running", None);
        let ev = paths::jobs_dir().join(format!("{}.events.jsonl", w.id));
        std::fs::write(&ev, "{\"t\":\"2026-10-22T10:00:00+08:00\",\"source\":\"items\",\"event\":\"write\",\"step\":{\"id\":\"write\",\"state\":\"done\"},\"items\":[\"u9\"]}\n").unwrap();
        w.step("prepare", "done", None);
        w.finish("done", None);
        let j = load(&w.id).unwrap();
        assert_eq!(j["state"], "done");
        assert_eq!(j["items"], json!(["u9"]));
        assert_eq!(j["steps"][1]["state"], "done");
        assert!(j["events_offset"].as_u64().unwrap() > 0);
        assert_eq!(list(false, 10).len(), 1);
        assert!(list(true, 10).is_empty());
    }
}
