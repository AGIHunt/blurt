//! A recording on its way to being organized (recording.md §6.2): how long that usually takes here (the Mac's
//! OrganizeProgress / BlurtCore OrganizeEstimate) and "Change" — the take's items to another project (the Mac's
//! Refile.recording: meta.json now, the items once the run has written them).

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tauri::{AppHandle, Manager};

use crate::projects::Registry;
use crate::{island, jobs, l10n, AppState};

/// Past runs below this many say nothing: one or two runs are anecdotes.
const MIN_RUNS: usize = 3;

fn median(xs: &mut [f64]) -> f64 {
    xs.sort_by(|a, b| a.total_cmp(b));
    let n = xs.len();
    if n == 0 {
        0.0
    } else if n % 2 == 1 {
        xs[n / 2]
    } else {
        (xs[n / 2 - 1] + xs[n / 2]) / 2.0
    }
}

/// The usual run for a video this long, in seconds (OrganizeEstimate.seconds): a robust line through the past runs
/// (video s, took s) — Theil–Sen: the median of the pairwise slopes, never below 0; the median intercept — never
/// shorter than the quickest run seen. None: fewer than MIN_RUNS usable runs (a video and a run of at least 5 s each).
pub fn usual_seconds(video: f64, past: &[(f64, f64)]) -> Option<f64> {
    let runs: Vec<(f64, f64)> = past.iter().copied().filter(|(v, t)| *v >= 5.0 && *t >= 5.0 && v.is_finite() && t.is_finite()).collect();
    if runs.len() < MIN_RUNS || video <= 0.0 {
        return None;
    }
    let mut slopes = Vec::new();
    for i in 0..runs.len() {
        for j in i + 1..runs.len() {
            if (runs[j].0 - runs[i].0).abs() >= 1.0 {
                slopes.push((runs[j].1 - runs[i].1) / (runs[j].0 - runs[i].0));
            }
        }
    }
    let slope = if slopes.is_empty() { 0.0 } else { median(&mut slopes).max(0.0) };
    let mut icepts: Vec<f64> = runs.iter().map(|(v, t)| t - slope * v).collect();
    let quickest = runs.iter().map(|r| r.1).fold(f64::INFINITY, f64::min);
    Some(quickest.max(median(&mut icepts) + slope * video))
}

/// Whole minutes to say ("about 4 min"): rounded, at least 1.
pub fn minutes(seconds: f64) -> u64 {
    ((seconds / 60.0).round() as u64).max(1)
}

fn video_length(session: &Path) -> Option<f64> {
    let m: Value = serde_json::from_slice(&std::fs::read(session.join("meta.json")).ok()?).ok()?;
    m["duration"].as_f64().filter(|d| *d > 0.0)
}

fn secs_between(a: &Value, b: &Value) -> Option<f64> {
    let p = |v: &Value| v.as_str().and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok());
    Some((p(b)? - p(a)?).num_milliseconds() as f64 / 1000.0)
}

/// The runs this PC has made: whole recordings (no capture list), done, with a start and an end.
fn past_runs() -> Vec<(f64, f64)> {
    jobs::list(false, 400)
        .iter()
        .filter(|j| j["type"] == "process" && j["state"] == "done" && j["captures"].as_array().is_none_or(|c| c.is_empty()))
        .filter_map(|j| {
            let s = PathBuf::from(j["session"].as_str()?);
            s.join("recording.mp4").is_file().then_some(())?;
            Some((video_length(&s)?, secs_between(&j["started"], &j["ended"])?))
        })
        .collect()
}

/// The usual length of organizing a video this long here (None: not enough runs measured yet).
pub fn usual(video: f64) -> Option<f64> {
    usual_seconds(video, &past_runs())
}

/// A project's name; "Unassigned" for the inbox.
pub fn name(project: Option<&str>) -> String {
    project
        .filter(|p| *p != "inbox")
        .and_then(|p| Registry::load().project(p).and_then(|x| x["name"].as_str().map(str::to_owned)))
        .unwrap_or_else(|| l10n::t("tray.project.inbox"))
}

/// Where a recording goes now (meta.json `project`; null = Unassigned).
fn filed_to(session: &Path) -> String {
    std::fs::read(session.join("meta.json"))
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|m| m["project"].as_str().map(str::to_owned))
        .unwrap_or_else(|| "inbox".into())
}

/// "Change" on "Organizing into X": the island's project picker, titled Move To, the current place checked.
pub fn offer_change(app: &AppHandle, session: &Path) {
    let cur = filed_to(session);
    island::send(app, json!({"op": "pick", "title": "rec.move_to", "current": if cur == "inbox" { Value::Null } else { json!(cur) },
        "token": crate::scripts::s(session)}));
}

/// The recording `session` now goes to `to` (a project id or "inbox"): meta.json at once (a run that starts later
/// files there); the items its run wrote move once the run is over (still in the place they were filed to: the ones
/// the user moved by hand since stay). Then "Moved to Y · Undo".
pub fn refile(app: &AppHandle, session: &Path, to: &str) {
    let from = filed_to(session);
    if from == to {
        return;
    }
    let meta = session.join("meta.json");
    let mut m: Value = std::fs::read(&meta).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_else(|| json!({}));
    m["project"] = if to == "inbox" { Value::Null } else { json!(to) };
    let _ = std::fs::write(&meta, serde_json::to_string_pretty(&m).unwrap_or_default());
    let (app, session, to) = (app.clone(), session.to_path_buf(), to.to_string());
    std::thread::spawn(move || {
        // a run still writing: its items move once it is over
        let s = crate::scripts::s(&session);
        let t0 = Instant::now();
        while t0.elapsed() < Duration::from_secs(3 * 3600)
            && jobs::list(true, 60).iter().any(|j| j["type"] == "process" && j["session"].as_str() == Some(s.as_str()))
        {
            std::thread::sleep(Duration::from_secs(2));
        }
        let uids: Vec<String> = std::fs::read(session.join("batch.json"))
            .ok()
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
            .and_then(|o| o["items"].as_array().map(|a| a.iter().filter_map(|u| u.as_str().map(str::to_owned)).collect()))
            .unwrap_or_default();
        if !uids.is_empty() {
            let mut args = vec!["move".to_string()];
            args.extend(uids);
            args.extend(["--project".into(), to.clone(), "--from".into(), from.clone()]);
            let runner = app.state::<AppState>().runner();
            if runner.run("items.py", &args, None, Duration::from_secs(60)).is_err() {
                island::send(&app, json!({"op": "toast", "kind": "capture", "msg": "rec.move_failed", "ms": 6000, "mark": "warning"}));
                return;
            }
            crate::items::bump();
        }
        island::send(&app, json!({"op": "toast", "kind": "capture", "msg": "rec.moved", "vars": {"project": name(Some(&to))},
            "key": format!("refile.{s}"), "ms": 6000, "mark": "check", "project": to,
            "action": {"a": format!("rec.move:{from}|{s}"), "label": "island.undo"}}));
        island::refresh(&app);
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_usual_run_is_a_robust_line_through_the_past_ones() {
        assert_eq!(usual_seconds(60.0, &[(60.0, 90.0), (120.0, 150.0)]), None, "two runs are anecdotes");
        // took = 30 + video, one outlier: the line holds
        let past = [(60.0, 90.0), (120.0, 150.0), (300.0, 330.0), (200.0, 900.0)];
        let u = usual_seconds(600.0, &past).unwrap();
        assert!((u - 630.0).abs() < 1.0, "{u}");
        // never shorter than the quickest run
        assert_eq!(usual_seconds(6.0, &past).unwrap(), 90.0);
        assert_eq!((minutes(20.0), minutes(150.0)), (1, 3));
    }
}
