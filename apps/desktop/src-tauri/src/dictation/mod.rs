//! Dictation on Windows: the Mac's pure BlurtCore rules, ported (docs/design/dictation.md).

pub mod apps;
pub mod context;
pub mod fit;
pub mod flow;
pub mod learn;
pub mod paste_policy;
pub mod prefs;
pub mod rehear;
pub mod segmenter;
pub mod stitch;
pub mod style_learn;
pub mod trigger;
pub mod voice_rules;
pub mod words;

pub mod cloud;
pub mod commands;
pub mod history;
#[cfg(windows)]
pub mod engine;
#[cfg(windows)]
pub mod insert_win;
#[cfg(windows)]
pub mod keys_win;
#[cfg(windows)]
pub mod mic;
#[cfg(windows)]
pub mod voice;
/// the snap note's microphone (capture/snap.rs)
#[cfg(windows)]
pub mod snap_voice;
pub mod server;
