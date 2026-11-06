//! Dictation on Windows and Linux: the Mac's pure BlurtCore rules, ported (docs/design/dictation.md; Linux:
//! docs/design/linux-port.md). `keys` and `insert` are the platform's key source and text insertion.

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
#[cfg(dict)]
pub mod engine;
#[cfg(windows)]
pub mod insert_win;
#[cfg(windows)]
pub mod keys_win;
#[cfg(windows)]
pub use {insert_win as insert, keys_win as keys};
#[cfg(target_os = "linux")]
pub mod insert_linux;
#[cfg(target_os = "linux")]
pub mod keys_linux;
#[cfg(target_os = "linux")]
pub use {insert_linux as insert, keys_linux as keys};
#[cfg(target_os = "linux")]
pub mod secret_linux;
#[cfg(dict)]
pub mod mic;
#[cfg(dict)]
pub mod voice;
/// the snap note's microphone (capture/snap.rs)
#[cfg(dict)]
pub mod snap_voice;
pub mod server;
