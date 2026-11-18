//! The recordings as the main window lists them (Home's Recent, the items' places; docs/design/capabilities.md §4):
//! every video session the index knows, newest first, with what its folder says besides — whether recording.mp4 is
//! still there (housekeeping deletes organised recordings' videos after a while), the first line said in it
//! (live/transcript.jsonl, else transcript.json), and whether it was saved as video only. Which job organises it, and
//! so its state (未整理 / 整理中 / 未完成 / N 个事项 / 仅保存视频), the window works out from `jobs_list`
//! (web/apps/desktop/src/recordings.ts) — the same rules as record.py's `take_state`.

use std::path::{Path, PathBuf};

use serde_json::{json, Value};

use crate::index::{Index, SessionQuery};

/// The longest first line kept (the row cuts it further).
const LINE_MAX: usize = 160;

/// The first thing said in a take: the first line of live/transcript.jsonl with text, else the first segment of
/// transcript.json; whitespace folded, cut at LINE_MAX characters.
pub fn first_line(session: &Path) -> Option<String> {
    let live = std::fs::read_to_string(session.join("live").join("transcript.jsonl")).unwrap_or_default();
    let from_live = live
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .find_map(|v| v["text"].as_str().map(fold).filter(|t| !t.is_empty()));
    let found = from_live.or_else(|| {
        let doc: Value = std::fs::read(session.join("transcript.json")).ok().and_then(|b| serde_json::from_slice(&b).ok())?;
        doc["segments"].as_array()?.iter().find_map(|s| s["text"].as_str().map(fold).filter(|t| !t.is_empty()))
    })?;
    Some(if found.chars().count() > LINE_MAX { found.chars().take(LINE_MAX).collect::<String>() + "…" } else { found })
}

fn fold(t: &str) -> String {
    t.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// One index session row with the folder's facts added (None: not a recording — shots, voice, a legacy session — or
/// the take being recorded now).
pub fn recording(row: &Value, live: Option<&Path>) -> Option<Value> {
    if row["mode"] != "video" || row["legacy"].as_i64().unwrap_or(0) != 0 {
        return None;
    }
    let dir = PathBuf::from(row["dir"].as_str()?);
    if live.is_some_and(|l| same_dir(l, &dir)) {
        return None;
    }
    let meta: Value = std::fs::read(dir.join("meta.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or(Value::Null);
    let video = dir.join("recording.mp4");
    let mut out = row.clone();
    out["video"] = if video.is_file() { json!(crate::scripts::s(&video)) } else { Value::Null };
    out["first_line"] = json!(first_line(&dir));
    out["video_only"] = json!(meta["video_only"].as_bool().unwrap_or(false));
    if out["duration"].is_null() {
        out["duration"] = meta["duration"].clone();
    }
    Some(out)
}

fn same_dir(a: &Path, b: &Path) -> bool {
    let n = |p: &Path| std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf());
    a == b || n(a) == n(b)
}

/// The newest `limit` recordings.
pub fn list(index: &Index, live: Option<&Path>, limit: usize) -> Result<Vec<Value>, String> {
    // shots and voice sessions are in the same table: ask for more and keep the videos
    let rows = index.sessions(&SessionQuery { limit: Some((limit * 4).clamp(50, 2000) as i64), ..Default::default() })?;
    Ok(rows.iter().filter_map(|r| recording(r, live)).take(limit).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("blurt-rec-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("live")).unwrap();
        d
    }

    #[test]
    fn first_line_from_live_then_transcript() {
        let d = tmp("line");
        assert_eq!(first_line(&d), None);
        std::fs::write(d.join("transcript.json"), r#"{"segments":[{"text":"  "},{"text":"from the  whole file"}]}"#).unwrap();
        assert_eq!(first_line(&d).as_deref(), Some("from the whole file"));
        std::fs::write(d.join("live/transcript.jsonl"), "{\"start\":0,\"end\":1,\"text\":\"\"}\nnot json\n{\"text\":\" 登录页\\n 按钮没反应 \"}\n").unwrap();
        assert_eq!(first_line(&d).as_deref(), Some("登录页 按钮没反应"));
        std::fs::write(d.join("live/transcript.jsonl"), format!("{{\"text\":\"{}\"}}\n", "字".repeat(200))).unwrap();
        let l = first_line(&d).unwrap();
        assert_eq!(l.chars().count(), LINE_MAX + 1);
        assert!(l.ends_with('…'));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn recording_rows() {
        let d = tmp("row");
        let row = json!({"id": "inbox:s", "mode": "video", "legacy": 0, "dir": crate::scripts::s(&d), "duration": null, "item_count": 0});
        // shots / legacy / the take being recorded: not listed
        assert!(recording(&json!({"mode": "shots", "dir": "/x"}), None).is_none());
        assert!(recording(&json!({"mode": "video", "legacy": 1, "dir": "/x"}), None).is_none());
        assert!(recording(&row, Some(&d)).is_none());
        // the video gone (retention), a duration from meta.json, Save Video Only
        std::fs::write(d.join("meta.json"), r#"{"duration": 42.5, "video_only": true}"#).unwrap();
        let r = recording(&row, None).unwrap();
        assert!(r["video"].is_null());
        assert_eq!(r["duration"], json!(42.5));
        assert_eq!(r["video_only"], json!(true));
        assert!(r["first_line"].is_null());
        std::fs::write(d.join("recording.mp4"), b"x").unwrap();
        let r = recording(&row, None).unwrap();
        assert_eq!(r["video"], json!(crate::scripts::s(&d.join("recording.mp4"))));
        let _ = std::fs::remove_dir_all(&d);
    }
}
