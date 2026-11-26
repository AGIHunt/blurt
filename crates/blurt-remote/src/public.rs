//! Blurt's public relay (docs/design/remote-go-between.md §The public relay; RemotePublicRelay in RemoteRelay.swift): where a session
//! goes on when the go-between finds no direct path. Shared and free, with limits: a ticket from the go-between to get in, the picture
//! on a lease from the relay, budgets. This file has its numbers and the small text messages a host trades with the go-between and the
//! relay (never sealed, never passed on); server.rs and viewer.rs do the rest.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;

use serde_json::{json, Value};

use crate::wire::ScreenRequest;

/// The only addresses a host or a phone goes to (wss:// only); the go-between's answer and `ToPhone::PublicRelay` must name one.
pub const ADDRESSES: [&str; 1] = ["wss://relay.blurt.work"];

/// One of `ADDRESSES`, or the one a test build was pointed at (`BLURT_PUBLIC_RELAY`); a release never has one.
pub fn allowed(address: &str, testing: Option<&str>) -> bool {
    ADDRESSES.contains(&address) || testing.is_some_and(|t| !t.is_empty() && t == address)
}

/// How long either end waits for the relay before it gives up and says there's no direct path.
pub const GIVE_UP: Duration = Duration::from_secs(5);
/// The computer's wait for the go-between's tickets.
pub const TICKET_WAIT: Duration = Duration::from_secs(3);
/// A `publicRelay` this old is no longer acted on (the phone's `noDirect` follows it at once).
pub const OFFER_FRESH: Duration = Duration::from_secs(10);
/// The picture on this path: Data Saver's.
pub const MAX_WIDTH: i64 = 1280;
pub const MAX_BITRATE: i64 = 1_000_000;
pub const MAX_FPS: i64 = 15;
/// A lease is renewed this often while frames flow; the relay takes it back after 75 s without.
pub const RENEW_EVERY: Duration = Duration::from_secs(30);
/// Refused: asked again this often while the picture is wanted.
pub const ASK_AGAIN: Duration = Duration::from_secs(30);
/// No touch, key or voice from the device for this long: the picture stops and its lease goes.
pub const UNTOUCHED: Duration = Duration::from_secs(300);
/// Files over this path, per device per UTC day, counted by the sender.
pub const FILES_PER_DAY: i64 = 50_000_000;
/// A file or batch over this is asked about first.
pub const ASK_OVER: i64 = 20_000_000;
/// The relay's close code for a computer nobody came to within 60 s.
pub const NOBODY_CAME: u16 = 4011;
/// `ToPhone::ScreenFailed` when the relay has no picture lease free.
pub const BUSY: &str = "busy";
/// `ToPhone::ScreenFailed` when the picture stopped after `UNTOUCHED` (the device asks again when it's used).
pub const STOPPED: &str = "stopped";

/// `{"lease":true}` asks for a lease or renews it; `{"lease":false}` gives it back.
pub fn lease(on: bool) -> String {
    if on { r#"{"lease":true}"# } else { r#"{"lease":false}"# }.to_string()
}

/// What the computer asks the go-between for: two tickets to this room.
pub fn ticket_ask(room: &str) -> String {
    json!({"ticket": {"room": room}}).to_string()
}

/// A room for one session at the relay: 32 random bytes, base64url (43 characters).
pub fn new_room() -> String {
    crate::crypto::base64url(&crate::crypto::new_key())
}

/// The go-between's answer to `ticket_ask`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Tickets {
    Given { relay: String, room: String, mac: String, phone: String },
    /// "off", "alone", "limit", "bad" (or anything else it says)
    Refused(String),
}

impl Tickets {
    /// None: not a ticket answer at all.
    pub fn parse(text: &str) -> Option<Tickets> {
        let v: Value = serde_json::from_str(text).ok()?;
        let t = v.get("ticket")?.as_object()?;
        if let Some(e) = t.get("error") {
            return Some(Tickets::Refused(e.as_str().unwrap_or("bad").to_string()));
        }
        let s = |k: &str| t.get(k).and_then(Value::as_str).map(str::to_string);
        Some(Tickets::Given { relay: s("relay")?, room: s("room")?, mac: s("mac")?, phone: s("phone")? })
    }
}

/// The relay's word on a lease.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LeaseAnswer {
    Granted { ttl: u64 },
    /// "full", "prefix", "alone"; "expired" when the relay took one back by itself
    Refused(String),
}

impl LeaseAnswer {
    pub fn parse(text: &str) -> Option<LeaseAnswer> {
        let v: Value = serde_json::from_str(text).ok()?;
        let l = v.get("lease")?.as_object()?;
        if l.get("ok")?.as_bool()? {
            Some(LeaseAnswer::Granted { ttl: l.get("ttl").and_then(Value::as_u64).unwrap_or(75) })
        } else {
            Some(LeaseAnswer::Refused(l.get("why").and_then(Value::as_str).unwrap_or("full").to_string()))
        }
    }
}

/// The picture on this path, whatever was asked: at most 1280 wide (the height in proportion), 1 Mbps, 15 fps.
pub fn clamp_picture(r: &mut ScreenRequest) {
    let fit = |w: &mut i64, h: &mut i64| {
        if *w > MAX_WIDTH {
            *h = (*h * MAX_WIDTH / (*w).max(1)).max(64);
            *w = MAX_WIDTH;
        }
    };
    fit(&mut r.width, &mut r.height);
    if let Some(w) = r.window.as_mut() {
        fit(&mut w.width, &mut w.height);
    }
    r.bitrate = r.bitrate.min(MAX_BITRATE);
    r.fps = r.fps.min(MAX_FPS);
}

/// The UTC day a time (unix ms) falls on.
pub fn utc_day(ms: i64) -> i64 {
    ms.div_euclid(86_400_000)
}

/// What one sender has sent over this path today, per device (`FILES_PER_DAY`).
#[derive(Default)]
pub struct DayBudget {
    sent: Mutex<HashMap<String, (i64, i64)>>,
}

/// What a send of some bytes over this path needs first.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FilesCheck {
    /// it may go
    Go,
    /// over `ASK_OVER`: asked about first, with its size
    Ask(i64),
    /// past today's `FILES_PER_DAY`
    OverToday,
}

impl DayBudget {
    pub fn used(&self, device: &str, now_ms: i64) -> i64 {
        let day = utc_day(now_ms);
        self.sent.lock().unwrap().get(device).filter(|(d, _)| *d == day).map_or(0, |(_, n)| *n)
    }

    /// `asked`: the person already said yes to this send.
    pub fn check(&self, device: &str, bytes: i64, asked: bool, now_ms: i64) -> FilesCheck {
        if self.used(device, now_ms) + bytes > FILES_PER_DAY {
            FilesCheck::OverToday
        } else if bytes > ASK_OVER && !asked {
            FilesCheck::Ask(bytes)
        } else {
            FilesCheck::Go
        }
    }

    /// Counted as it's sent (or queued to be).
    pub fn spend(&self, device: &str, bytes: i64, now_ms: i64) {
        let day = utc_day(now_ms);
        let mut m = self.sent.lock().unwrap();
        let e = m.entry(device.to_string()).or_insert((day, 0));
        if e.0 != day {
            *e = (day, 0);
        }
        e.1 += bytes.max(0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::{Crop, PixelSize};

    #[test]
    fn addresses_and_tests() {
        assert!(allowed("wss://relay.blurt.work", None));
        assert!(!allowed("wss://relay.blurt.work.evil", None));
        assert!(!allowed("ws://127.0.0.1:9", None));
        assert!(allowed("ws://127.0.0.1:9", Some("ws://127.0.0.1:9")));
        assert!(!allowed("", Some("")));
        assert_eq!(new_room().len(), 43);
    }

    #[test]
    fn answers() {
        assert_eq!(Tickets::parse(r#"{"ticket":{"error":"alone"}}"#), Some(Tickets::Refused("alone".into())));
        assert_eq!(
            Tickets::parse(r#"{"ticket":{"relay":"wss://relay.blurt.work","room":"R","mac":"m","phone":"p"}}"#),
            Some(Tickets::Given { relay: "wss://relay.blurt.work".into(), room: "R".into(), mac: "m".into(), phone: "p".into() })
        );
        assert_eq!(Tickets::parse(r#"{"lease":true}"#), None);
        assert_eq!(LeaseAnswer::parse(r#"{"lease":{"ok":true,"ttl":75}}"#), Some(LeaseAnswer::Granted { ttl: 75 }));
        assert_eq!(LeaseAnswer::parse(r#"{"lease":{"ok":false,"why":"expired"}}"#), Some(LeaseAnswer::Refused("expired".into())));
        assert_eq!(LeaseAnswer::parse("x"), None);
    }

    #[test]
    fn the_picture_is_data_savers() {
        let mut r = ScreenRequest {
            target: "display".into(),
            crop: Crop::WHOLE,
            width: 2560,
            height: 1600,
            bitrate: 8_000_000,
            fps: 60,
            codecs: None,
            display: None,
            features: None,
            window: Some(PixelSize { width: 1920, height: 1200 }),
        };
        clamp_picture(&mut r);
        assert_eq!((r.width, r.height, r.bitrate, r.fps), (1280, 800, 1_000_000, 15));
        assert_eq!(r.window, Some(PixelSize { width: 1280, height: 800 }));
        // smaller already: kept
        let mut s = ScreenRequest { width: 800, height: 600, bitrate: 500_000, fps: 10, window: None, ..r };
        clamp_picture(&mut s);
        assert_eq!((s.width, s.height, s.bitrate, s.fps), (800, 600, 500_000, 10));
    }

    #[test]
    fn files_a_day() {
        let b = DayBudget::default();
        let t = 1_764_000_000_000;
        assert_eq!(b.check("d", 35_000_000, false, t), FilesCheck::Ask(35_000_000));
        assert_eq!(b.check("d", 35_000_000, true, t), FilesCheck::Go);
        b.spend("d", 35_000_000, t);
        assert_eq!(b.check("d", 10_000_000, false, t), FilesCheck::Go);
        assert_eq!(b.check("d", 20_000_000, true, t), FilesCheck::OverToday);
        assert_eq!(b.check("other", 20_000_000, true, t), FilesCheck::Go, "per device");
        // the next UTC day starts again
        assert_eq!(b.check("d", 20_000_000, true, t + 86_400_000), FilesCheck::Go);
    }
}
