//! Dictation on Windows: the Mac's pure BlurtCore rules, ported (docs/design/dictation.md).

pub mod paste_policy;
pub mod segmenter;
pub mod stitch;
pub mod trigger;

pub mod cloud;
pub mod commands;
#[cfg(windows)]
pub mod engine;
#[cfg(windows)]
pub mod insert_win;
#[cfg(windows)]
pub mod keys_win;
#[cfg(windows)]
pub mod mic;
pub mod server;
