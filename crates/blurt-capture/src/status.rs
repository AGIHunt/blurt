//! `record.py start --status-jsonl` stdout lines (docs/design/desktop-app.md §5 C8). Serialized back unchanged
//! (`{"ev": …}`), which is also what the HUD overlay receives.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "ev", rename_all = "lowercase")]
pub enum StatusEvent {
    /// The grabber delivered its first frame; `t0` = its wall clock (Unix seconds) = video time 0.
    Started { t0: f64 },
    /// Microphone RMS (0..1), ~10 Hz; only with a microphone.
    Level { rms: f64 },
    Paused {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        t: Option<f64>,
    },
    Resumed {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        t: Option<f64>,
    },
    /// A still is on disk: `file` is session-relative (`shots/003.png`); `t` = video time.
    Snap {
        n: u32,
        file: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        t: Option<f64>,
    },
    /// Final line of a kept take (meta.json is written).
    Stopped {
        video: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        duration: Option<f64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        shots: Option<u32>,
    },
    /// Final line of a discarded take.
    Discarded,
    /// Final line on failure — except `code: "snap"` (one still failed; recording goes on).
    Error {
        msg: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        code: Option<String>,
    },
    /// A line this version doesn't know (contracts only add).
    #[serde(skip)]
    Other(serde_json::Value),
}

impl StatusEvent {
    /// Parses one stdout line; `None` for blank / non-JSON lines.
    pub fn parse(line: &str) -> Option<Self> {
        let line = line.trim();
        if line.is_empty() {
            return None;
        }
        let v: serde_json::Value = serde_json::from_str(line).ok()?;
        v.get("ev")?.as_str()?;
        Some(serde_json::from_value(v.clone()).unwrap_or(StatusEvent::Other(v)))
    }

    /// The recorder process ends after this line.
    pub fn is_final(&self) -> bool {
        match self {
            StatusEvent::Stopped { .. } | StatusEvent::Discarded => true,
            StatusEvent::Error { code, .. } => code.as_deref() != Some("snap"),
            _ => false,
        }
    }

    /// As JSON for the overlays (unknown lines pass through as they came).
    pub fn to_json(&self) -> serde_json::Value {
        match self {
            StatusEvent::Other(v) => v.clone(),
            e => serde_json::to_value(e).unwrap_or_default(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_c8_lines() {
        let lines = [
            (r#"{"ev": "started", "t0": 1792573844.3}"#, StatusEvent::Started { t0: 1792573844.3 }),
            (r#"{"ev":"level","rms":0.12}"#, StatusEvent::Level { rms: 0.12 }),
            (r#"{"ev":"paused"}"#, StatusEvent::Paused { t: None }),
            (r#"{"ev":"resumed","t":1.5}"#, StatusEvent::Resumed { t: Some(1.5) }),
            (
                r#"{"ev":"snap","n":3,"file":"shots/003.png"}"#,
                StatusEvent::Snap { n: 3, file: "shots/003.png".into(), t: None },
            ),
            (
                r#"{"ev":"stopped","video":"recording.mp4"}"#,
                StatusEvent::Stopped { video: "recording.mp4".into(), duration: None, shots: None },
            ),
            (r#"{"ev":"discarded"}"#, StatusEvent::Discarded),
            (r#"{"ev":"error","msg":"boom"}"#, StatusEvent::Error { msg: "boom".into(), code: None }),
        ];
        for (l, want) in lines {
            assert_eq!(StatusEvent::parse(l), Some(want), "{l}");
        }
        assert_eq!(StatusEvent::parse("SESSION /x engine=ffmpeg"), None);
        assert_eq!(StatusEvent::parse(r#"{"event":"recording"}"#), None);
        let other = StatusEvent::parse(r#"{"ev":"countdown","n":3}"#).unwrap();
        assert!(matches!(other, StatusEvent::Other(_)));
        assert_eq!(other.to_json()["n"], 3);
    }

    #[test]
    fn final_lines() {
        assert!(StatusEvent::Discarded.is_final());
        assert!(StatusEvent::Error { msg: "x".into(), code: None }.is_final());
        assert!(!StatusEvent::Error { msg: "x".into(), code: Some("snap".into()) }.is_final());
        assert!(!StatusEvent::Paused { t: None }.is_final());
    }

    #[test]
    fn round_trips_for_the_hud() {
        let e = StatusEvent::Snap { n: 1, file: "shots/001.png".into(), t: Some(0.5) };
        assert_eq!(e.to_json(), serde_json::json!({"ev": "snap", "n": 1, "file": "shots/001.png", "t": 0.5}));
    }
}
