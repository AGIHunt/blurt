//! Blurt's remote host for Windows and Linux: what the Mac app does in Sources/BlurtApp/Remote, for the phone apps
//! (apps/ios, apps/android). Wire format: docs/design/remote-protocol.md, checked against tests/remote-vectors/vectors.json.
//!
//! Layout:
//!   host.rs           the contract between the platform-neutral server and each OS (screen, encoder, input)
//!   platform/windows  Windows: capture, hardware H.264/HEVC, SendInput
//!   platform/linux    Linux (Wayland first): xdg-desktop-portal ScreenCast + RemoteDesktop, PipeWire, GStreamer
//!   everything else   the protocol, crypto, session server: the same on both

pub mod host;
pub mod platform;
