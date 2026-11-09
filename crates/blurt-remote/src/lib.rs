//! Blurt's remote host for Windows and Linux: what the Mac app does in Sources/BlurtApp/Remote, for the phone apps
//! (apps/ios, apps/android). Wire format: docs/design/remote-protocol.md, checked against tests/remote-vectors/vectors.json.
//! Notes on this host: docs/design/remote-hosts.md.
//!
//! Layout:
//!   host.rs           the contract between the platform-neutral server and each OS (screen, encoder, input)
//!   platform/windows  Windows: capture, hardware H.264/HEVC, SendInput
//!   platform/linux    Linux (Wayland first): xdg-desktop-portal ScreenCast + RemoteDesktop, PipeWire, GStreamer
//!   everything else   the protocol, crypto, session server: the same on both
//!     wire.rs         control messages (ToMac / ToPhone) in Swift's JSON shape
//!     crypto.rs       handshake, six digits, seals
//!     packets.rs      framing, pointer / video / cursor packets
//!     pairing.rs      the QR code's link
//!     relay.rs        the owner's relay, STUN, this machine's addresses
//!     rate.rs         the picture's rate control
//!     input.rs        clicks, drags, scroll phases and the coast, held keys: what the backend is told to press
//!     screen.rs       the stream: packets, pacing, back-pressure, refresh, cursor
//!     store.rs        paired devices, the host's settings, keys (through the app's secret store)
//!     mic.rs          the phone's microphone as dictation's source
//!     server.rs       listeners, pairing, sessions, the relay: the Host the app starts

pub mod host;
pub mod platform;

pub mod crypto;
// pub mod input;
// pub mod mic;
pub mod packets;
pub mod pairing;
pub mod rate;
pub mod relay;
// pub mod screen;
// pub mod server;
// pub mod store;
pub mod wire;

