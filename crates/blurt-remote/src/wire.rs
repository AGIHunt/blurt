//! Control messages in Swift's synthesized `Codable` shape (docs/design/remote-protocol.md §Messages): an object with one key,
//! the case name; labelled values by label, unlabelled ones as `_0`; a case without values is `{"name":{}}`; optional values
//! left out when nil; `Data` as standard base64. Reading is lenient where Swift's decoder is (unknown keys ignored) and drops
//! what Swift's would refuse: a case this side doesn't know (a newer peer) is `None`, never an error that ends the session.
//!
//! The reference is skills/blurt/recorder/macos/Sources/BlurtRemoteKit/RemoteMessages.swift; tests/remote-vectors/vectors.json
//! holds every case, and tests/vectors.rs checks both directions against it.

use base64::Engine as _;
use serde_json::{json, Map, Value};

/// RemoteModifiers bits (host.rs `mods`).
pub type Mods = u8;

/// A key and its modifiers: ⌘C is {command, "C"}. An empty key is the modifiers alone.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Chord {
    pub mods: Mods,
    pub key: String,
}

impl Chord {
    pub fn new(mods: Mods, key: &str) -> Chord {
        Chord { mods, key: key.to_string() }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Step {
    Key(Chord),
    Text(String),
    /// ms
    Wait(i64),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MouseButton {
    Left = 0,
    Right = 1,
    Middle = 2,
}

/// Blurt's own commands: the same actions as the computer's hotkeys, whatever keys the user gave them there.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BlurtCommand {
    Snap,
    Record,
    VoiceNote,
    CopyText,
    Translate,
    Cards,
    DictationCancel,
    DictationStructured,
    DictationTranslate,
    DictationSend,
}

impl BlurtCommand {
    pub const ALL: [BlurtCommand; 10] = [
        BlurtCommand::Snap,
        BlurtCommand::Record,
        BlurtCommand::VoiceNote,
        BlurtCommand::CopyText,
        BlurtCommand::Translate,
        BlurtCommand::Cards,
        BlurtCommand::DictationCancel,
        BlurtCommand::DictationStructured,
        BlurtCommand::DictationTranslate,
        BlurtCommand::DictationSend,
    ];
    pub fn name(self) -> &'static str {
        match self {
            BlurtCommand::Snap => "snap",
            BlurtCommand::Record => "record",
            BlurtCommand::VoiceNote => "voiceNote",
            BlurtCommand::CopyText => "copyText",
            BlurtCommand::Translate => "translate",
            BlurtCommand::Cards => "cards",
            BlurtCommand::DictationCancel => "dictationCancel",
            BlurtCommand::DictationStructured => "dictationStructured",
            BlurtCommand::DictationTranslate => "dictationTranslate",
            BlurtCommand::DictationSend => "dictationSend",
        }
    }
    pub fn from_name(s: &str) -> Option<BlurtCommand> {
        Self::ALL.into_iter().find(|c| c.name() == s)
    }
}

pub use crate::host::SystemMove;

fn system_name(m: SystemMove) -> &'static str {
    match m {
        SystemMove::MissionControl => "missionControl",
        SystemMove::AppExpose => "appExpose",
        SystemMove::SpaceLeft => "spaceLeft",
        SystemMove::SpaceRight => "spaceRight",
        SystemMove::ZoomIn => "zoomIn",
        SystemMove::ZoomOut => "zoomOut",
        SystemMove::FindCursor => "findCursor",
    }
}

fn system_from(s: &str) -> Option<SystemMove> {
    Some(match s {
        "missionControl" => SystemMove::MissionControl,
        "appExpose" => SystemMove::AppExpose,
        "spaceLeft" => SystemMove::SpaceLeft,
        "spaceRight" => SystemMove::SpaceRight,
        "zoomIn" => SystemMove::ZoomIn,
        "zoomOut" => SystemMove::ZoomOut,
        "findCursor" => SystemMove::FindCursor,
        _ => return None,
    })
}

/// A part of the source, 0…1 (RemoteCrop).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Crop {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl Crop {
    pub const WHOLE: Crop = Crop { x: 0.0, y: 0.0, w: 1.0, h: 1.0 };

    /// Inside the source and not absurdly small, whatever arrived (RemoteCrop.valid).
    pub fn valid(self) -> Crop {
        if ![self.x, self.y, self.w, self.h].iter().all(|v| v.is_finite()) {
            return Crop::WHOLE;
        }
        let w = self.w.clamp(0.1, 1.0);
        let h = self.h.clamp(0.1, 1.0);
        Crop { x: self.x.max(0.0).min(1.0 - w), y: self.y.max(0.0).min(1.0 - h), w, h }
    }

    pub fn to_host(self) -> crate::host::Crop {
        crate::host::Crop { x: self.x, y: self.y, w: self.w, h: self.h }
    }

    pub fn from_host(c: crate::host::Crop) -> Crop {
        Crop { x: c.x, y: c.y, w: c.w, h: c.h }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ScreenRequest {
    /// "display": the screen with the pointer. "window": a test window (Mac only).
    pub target: String,
    pub crop: Crop,
    pub width: i64,
    pub height: i64,
    pub bitrate: i64,
    pub fps: i64,
    /// best first; None = HEVC only (phones before 1.0.15)
    pub codecs: Option<Vec<String>>,
    /// a `Display` id to show; None = the display the pointer is on, following it from display to display (the default)
    pub display: Option<String>,
    /// the picture's repairs the phone implements: "nack", "ltr", "fec" (docs/design/remote-realtime.md). None: none (before 1.0.15)
    pub features: Option<Vec<String>>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ScreenReport {
    pub frames: i64,
    pub lost: i64,
    pub rtt: Option<f64>,
    pub received: i64,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Candidate {
    pub host: String,
    pub port: u16,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ToMac {
    Key { chord: Chord, down: Option<bool> },
    Mods(Mods),
    Run(Vec<Step>),
    Text(String),
    Button { button: MouseButton, down: bool },
    DragBegin,
    DictationKey { down: bool },
    Blurt(BlurtCommand),
    System(SystemMove),
    Activate { bundle: String },
    Hud(String),
    Hello { device: String, mic_on_phone: bool, nonce: Option<Vec<u8>> },
    SetMicOnPhone(bool),
    ReleaseAll,
    KeyStored,
    Screen(Option<ScreenRequest>),
    ScreenCrop(Crop),
    /// the pointer to this place on the screen being shown, 0…1: the view moved away from it. `seq`: its number among this phone's
    /// pointer instructions (`PointerPacket::Move`), echoed with the cursor's place once made. 1.0.17+
    PointerTo { x: f32, y: f32, seq: Option<u32> },
    /// show this display from now on, and put the pointer in its middle (None: follow the pointer, the default)
    ShowDisplay(Option<String>),
    Candidates(Vec<Candidate>),
    RequestKeyframe,
    ScreenReport(ScreenReport),
    ScreenPace { idle: bool },
    Unpair,
    Replaces { device_id: String },
    OfferRelay(String),
    ScreenStats(String),
    ScreenSnapshot { name: String, jpeg: Vec<u8> },
    Ping(f64),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DictationPhase {
    Idle,
    Listening,
    Transcribing,
    Polishing,
    Unavailable,
}

impl DictationPhase {
    pub fn name(self) -> &'static str {
        match self {
            DictationPhase::Idle => "idle",
            DictationPhase::Listening => "listening",
            DictationPhase::Transcribing => "transcribing",
            DictationPhase::Polishing => "polishing",
            DictationPhase::Unavailable => "unavailable",
        }
    }
    pub fn from_name(s: &str) -> Option<DictationPhase> {
        Some(match s {
            "idle" => DictationPhase::Idle,
            "listening" => DictationPhase::Listening,
            "transcribing" => DictationPhase::Transcribing,
            "polishing" => DictationPhase::Polishing,
            "unavailable" => DictationPhase::Unavailable,
            _ => return None,
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct SessionInfo {
    /// the computer's name (the field keeps the Mac's name on the wire)
    pub mac_name: String,
    pub udp_port: u16,
    pub udp_session: u32,
    pub can_control: bool,
    pub version: String,
    pub candidates: Vec<Candidate>,
    pub display_aspect: f64,
    pub relay: Option<String>,
    /// "mac", "windows" or "linux"
    pub platform: Option<String>,
}

/// One of the computer's displays: its frame in points in the desktop's own coordinates (top-left origin, y down, as in the
/// computer's display settings), so the phone can draw the arrangement (RemoteDisplay).
#[derive(Clone, Debug, PartialEq)]
pub struct Display {
    /// stable while the display stays connected (monitor device name on Windows, the portal stream's id on Linux)
    pub id: String,
    pub name: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    /// the primary display
    pub main: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Front {
    pub bundle: String,
    pub name: String,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ToPhone {
    Session(SessionInfo),
    CanControl(bool),
    Front(Front),
    Dictation(DictationPhase),
    Live { committed: String, pending: String },
    Level(f32),
    Typed(String),
    Notice(String),
    Pong(f64),
    UdpOk,
    Removed,
    Relay(Option<String>),
    Replaced,
    PairingWaits,
    Listen(bool),
    NewKey(Vec<u8>),
    Clock { phone: f64, mac: f64 },
    ScreenFailed(String),
    /// `features`: the repairs this stream uses, of those the phone offered (None: none, as from hosts before 1.0.15)
    ScreenView { width: f64, height: f64, codec: Option<String>, display: Option<String>, features: Option<Vec<String>> },
    /// every display the computer has, whenever that changes (and once a session is up)
    Displays(Vec<Display>),
    CursorShape { png: Vec<u8>, hot_x: f64, hot_y: f64, width: f64, height: f64 },
}

// ------------------------------------------------------------------ helpers

pub fn b64(d: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(d)
}

/// Standard base64, padded or not (Swift writes it padded).
pub fn unb64(s: &str) -> Option<Vec<u8>> {
    use base64::engine::{general_purpose::GeneralPurpose, GeneralPurposeConfig, DecodePaddingMode};
    const E: GeneralPurpose = GeneralPurpose::new(
        &base64::alphabet::STANDARD,
        GeneralPurposeConfig::new().with_decode_padding_mode(DecodePaddingMode::Indifferent),
    );
    E.decode(s.trim()).ok()
}

/// A Float as Swift writes it: the shortest decimal that reads back as that f32 (0.1, not 0.10000000149011612).
fn f32v(x: f32) -> Value {
    f64v(format!("{x}").parse().unwrap_or(0.0))
}

/// Whole numbers as Swift's JSONEncoder writes them (1920, not 1920.0).
fn f64v(x: f64) -> Value {
    if x.fract() == 0.0 && x.abs() < 9.0e15 {
        return json!(x as i64);
    }
    serde_json::Number::from_f64(x).map(Value::Number).unwrap_or(Value::Null)
}

fn case(name: &str, fields: Vec<(&str, Value)>) -> Value {
    let mut m = Map::new();
    for (k, v) in fields {
        m.insert(k.to_string(), v);
    }
    let mut o = Map::new();
    o.insert(name.to_string(), Value::Object(m));
    Value::Object(o)
}

fn one(name: &str, v: Value) -> Value {
    case(name, vec![("_0", v)])
}

/// The case name and its fields, if the value is one case.
fn split(v: &Value) -> Option<(&str, &Map<String, Value>)> {
    let o = v.as_object()?;
    if o.len() != 1 {
        return None;
    }
    let (k, f) = o.iter().next()?;
    Some((k.as_str(), f.as_object()?))
}

fn int(v: &Value) -> Option<i64> {
    if let Some(i) = v.as_i64() {
        return Some(i);
    }
    let f = v.as_f64()?;
    (f.fract() == 0.0 && f.abs() < 9.0e15).then_some(f as i64)
}

fn num(v: &Value) -> Option<f64> {
    v.as_f64()
}

fn f32of(v: &Value) -> Option<f32> {
    let x = v.as_f64()? as f32;
    x.is_finite().then_some(x)
}

fn string(v: &Value) -> Option<String> {
    v.as_str().map(str::to_string)
}

fn boolean(v: &Value) -> Option<bool> {
    v.as_bool()
}

fn data(v: &Value) -> Option<Vec<u8>> {
    unb64(v.as_str()?)
}

/// A field that may be missing (or null): Some(None) when it is, None when it is there and wrong.
fn opt<T>(f: &Map<String, Value>, k: &str, read: impl Fn(&Value) -> Option<T>) -> Option<Option<T>> {
    match f.get(k) {
        None | Some(Value::Null) => Some(None),
        Some(v) => read(v).map(Some),
    }
}

fn req<'a>(f: &'a Map<String, Value>, k: &str) -> Option<&'a Value> {
    f.get(k).filter(|v| !v.is_null())
}

fn chord_json(c: &Chord) -> Value {
    json!({"key": c.key, "mods": c.mods})
}

fn chord_from(v: &Value) -> Option<Chord> {
    let o = v.as_object()?;
    let mods = int(req(o, "mods")?)?;
    Some(Chord { mods: u8::try_from(mods).ok()?, key: string(req(o, "key")?)? })
}

fn crop_json(c: &Crop) -> Value {
    json!({"x": f32v(c.x), "y": f32v(c.y), "w": f32v(c.w), "h": f32v(c.h)})
}

fn crop_from(v: &Value) -> Option<Crop> {
    let o = v.as_object()?;
    Some(Crop { x: f32of(req(o, "x")?)?, y: f32of(req(o, "y")?)?, w: f32of(req(o, "w")?)?, h: f32of(req(o, "h")?)? })
}

fn candidate_json(c: &Candidate) -> Value {
    json!({"host": c.host, "port": c.port})
}

fn candidate_from(v: &Value) -> Option<Candidate> {
    let o = v.as_object()?;
    Some(Candidate { host: string(req(o, "host")?)?, port: u16::try_from(int(req(o, "port")?)?).ok()? })
}

fn list<T>(v: &Value, read: impl Fn(&Value) -> Option<T>) -> Option<Vec<T>> {
    v.as_array()?.iter().map(read).collect()
}

fn step_json(s: &Step) -> Value {
    match s {
        Step::Key(c) => one("key", chord_json(c)),
        Step::Text(t) => one("text", json!(t)),
        Step::Wait(ms) => one("wait", json!(ms)),
    }
}

fn step_from(v: &Value) -> Option<Step> {
    let (name, f) = split(v)?;
    let x = req(f, "_0")?;
    Some(match name {
        "key" => Step::Key(chord_from(x)?),
        "text" => Step::Text(string(x)?),
        "wait" => Step::Wait(int(x)?),
        _ => return None,
    })
}

fn request_json(r: &ScreenRequest) -> Value {
    let mut o = json!({"target": r.target, "crop": crop_json(&r.crop), "width": r.width, "height": r.height,
                       "bitrate": r.bitrate, "fps": r.fps});
    if let Some(c) = &r.codecs {
        o["codecs"] = json!(c);
    }
    if let Some(d) = &r.display {
        o["display"] = json!(d);
    }
    if let Some(f) = &r.features {
        o["features"] = json!(f);
    }
    o
}

fn display_json(d: &Display) -> Value {
    json!({"id": d.id, "name": d.name, "x": f64v(d.x), "y": f64v(d.y), "width": f64v(d.width), "height": f64v(d.height), "main": d.main})
}

fn display_from(v: &Value) -> Option<Display> {
    let o = v.as_object()?;
    Some(Display {
        id: string(req(o, "id")?)?,
        name: string(req(o, "name")?)?,
        x: num(req(o, "x")?)?,
        y: num(req(o, "y")?)?,
        width: num(req(o, "width")?)?,
        height: num(req(o, "height")?)?,
        main: boolean(req(o, "main")?)?,
    })
}

fn request_from(v: &Value) -> Option<ScreenRequest> {
    let o = v.as_object()?;
    Some(ScreenRequest {
        target: string(req(o, "target")?)?,
        crop: crop_from(req(o, "crop")?)?,
        width: int(req(o, "width")?)?,
        height: int(req(o, "height")?)?,
        bitrate: int(req(o, "bitrate")?)?,
        fps: int(req(o, "fps")?)?,
        codecs: opt(o, "codecs", |v| list(v, string))?,
        display: opt(o, "display", string)?,
        features: opt(o, "features", |v| list(v, string))?,
    })
}

fn report_json(r: &ScreenReport) -> Value {
    let mut o = json!({"frames": r.frames, "lost": r.lost, "received": r.received});
    if let Some(t) = r.rtt {
        o["rtt"] = f64v(t);
    }
    o
}

fn report_from(v: &Value) -> Option<ScreenReport> {
    let o = v.as_object()?;
    Some(ScreenReport {
        frames: int(req(o, "frames")?)?,
        lost: int(req(o, "lost")?)?,
        rtt: opt(o, "rtt", num)?,
        received: int(req(o, "received")?)?,
    })
}

fn session_json(i: &SessionInfo) -> Value {
    let mut o = json!({
        "macName": i.mac_name, "udpPort": i.udp_port, "udpSession": i.udp_session, "canControl": i.can_control,
        "version": i.version, "candidates": i.candidates.iter().map(candidate_json).collect::<Vec<_>>(),
        "displayAspect": f64v(i.display_aspect),
    });
    if let Some(r) = &i.relay {
        o["relay"] = json!(r);
    }
    if let Some(p) = &i.platform {
        o["platform"] = json!(p);
    }
    o
}

fn session_from(v: &Value) -> Option<SessionInfo> {
    let o = v.as_object()?;
    Some(SessionInfo {
        mac_name: string(req(o, "macName")?)?,
        udp_port: u16::try_from(int(req(o, "udpPort")?)?).ok()?,
        udp_session: u32::try_from(int(req(o, "udpSession")?)?).ok()?,
        can_control: boolean(req(o, "canControl")?)?,
        version: string(req(o, "version")?)?,
        candidates: list(req(o, "candidates")?, candidate_from)?,
        display_aspect: num(req(o, "displayAspect")?)?,
        relay: opt(o, "relay", string)?,
        platform: opt(o, "platform", string)?,
    })
}

// ------------------------------------------------------------------ ToMac

impl ToMac {
    pub fn to_json(&self) -> Value {
        match self {
            ToMac::Key { chord, down } => {
                let mut f = vec![("_0", chord_json(chord))];
                if let Some(d) = down {
                    f.push(("down", json!(d)));
                }
                case("key", f)
            }
            ToMac::Mods(m) => one("mods", json!(m)),
            ToMac::Run(steps) => one("run", Value::Array(steps.iter().map(step_json).collect())),
            ToMac::Text(t) => one("text", json!(t)),
            ToMac::Button { button, down } => case("button", vec![("_0", json!(*button as u8)), ("down", json!(down))]),
            ToMac::DragBegin => case("dragBegin", vec![]),
            ToMac::DictationKey { down } => case("dictationKey", vec![("down", json!(down))]),
            ToMac::Blurt(c) => one("blurt", json!(c.name())),
            ToMac::System(m) => one("system", json!(system_name(*m))),
            ToMac::Activate { bundle } => case("activate", vec![("bundle", json!(bundle))]),
            ToMac::Hud(t) => one("hud", json!(t)),
            ToMac::Hello { device, mic_on_phone, nonce } => {
                let mut f = vec![("device", json!(device)), ("micOnPhone", json!(mic_on_phone))];
                if let Some(n) = nonce {
                    f.push(("nonce", json!(b64(n))));
                }
                case("hello", f)
            }
            ToMac::SetMicOnPhone(on) => one("setMicOnPhone", json!(on)),
            ToMac::ReleaseAll => case("releaseAll", vec![]),
            ToMac::KeyStored => case("keyStored", vec![]),
            ToMac::Screen(r) => case("screen", r.iter().map(|r| ("_0", request_json(r))).collect()),
            ToMac::ScreenCrop(c) => one("screenCrop", crop_json(c)),
            ToMac::PointerTo { x, y, seq } => {
                let mut f = vec![("x", f32v(*x)), ("y", f32v(*y))];
                if let Some(n) = seq {
                    f.push(("seq", json!(n)));
                }
                case("pointerTo", f)
            }
            ToMac::ShowDisplay(d) => case("showDisplay", d.iter().map(|d| ("_0", json!(d))).collect()),
            ToMac::Candidates(l) => one("candidates", Value::Array(l.iter().map(candidate_json).collect())),
            ToMac::RequestKeyframe => case("requestKeyframe", vec![]),
            ToMac::ScreenReport(r) => one("screenReport", report_json(r)),
            ToMac::ScreenPace { idle } => case("screenPace", vec![("idle", json!(idle))]),
            ToMac::Unpair => case("unpair", vec![]),
            ToMac::Replaces { device_id } => case("replaces", vec![("deviceID", json!(device_id))]),
            ToMac::OfferRelay(a) => one("offerRelay", json!(a)),
            ToMac::ScreenStats(s) => one("screenStats", json!(s)),
            ToMac::ScreenSnapshot { name, jpeg } => case("screenSnapshot", vec![("name", json!(name)), ("jpeg", json!(b64(jpeg)))]),
            ToMac::Ping(t) => one("ping", f64v(*t)),
        }
    }

    /// None: not one message, a case this side doesn't know, or one Swift's decoder would refuse (dropped, not fatal).
    pub fn from_json(v: &Value) -> Option<ToMac> {
        let (name, f) = split(v)?;
        let x0 = || req(f, "_0");
        Some(match name {
            "key" => ToMac::Key { chord: chord_from(x0()?)?, down: opt(f, "down", boolean)? },
            "mods" => ToMac::Mods(u8::try_from(int(x0()?)?).ok()?),
            "run" => ToMac::Run(list(x0()?, step_from)?),
            "text" => ToMac::Text(string(x0()?)?),
            "button" => {
                let b = match int(x0()?)? {
                    0 => MouseButton::Left,
                    1 => MouseButton::Right,
                    2 => MouseButton::Middle,
                    _ => return None,
                };
                ToMac::Button { button: b, down: boolean(req(f, "down")?)? }
            }
            "dragBegin" => ToMac::DragBegin,
            "dictationKey" => ToMac::DictationKey { down: boolean(req(f, "down")?)? },
            "blurt" => ToMac::Blurt(BlurtCommand::from_name(x0()?.as_str()?)?),
            "system" => ToMac::System(system_from(x0()?.as_str()?)?),
            "activate" => ToMac::Activate { bundle: string(req(f, "bundle")?)? },
            "hud" => ToMac::Hud(string(x0()?)?),
            "hello" => ToMac::Hello {
                device: string(req(f, "device")?)?,
                mic_on_phone: boolean(req(f, "micOnPhone")?)?,
                nonce: opt(f, "nonce", data)?,
            },
            "setMicOnPhone" => ToMac::SetMicOnPhone(boolean(x0()?)?),
            "releaseAll" => ToMac::ReleaseAll,
            "keyStored" => ToMac::KeyStored,
            "screen" => ToMac::Screen(opt(f, "_0", request_from)?),
            "screenCrop" => ToMac::ScreenCrop(crop_from(x0()?)?),
            "pointerTo" => ToMac::PointerTo {
                x: f32of(req(f, "x")?)?,
                y: f32of(req(f, "y")?)?,
                seq: opt(f, "seq", |v| u32::try_from(int(v)?).ok())?,
            },
            "showDisplay" => ToMac::ShowDisplay(opt(f, "_0", string)?),
            "candidates" => ToMac::Candidates(list(x0()?, candidate_from)?),
            "requestKeyframe" => ToMac::RequestKeyframe,
            "screenReport" => ToMac::ScreenReport(report_from(x0()?)?),
            "screenPace" => ToMac::ScreenPace { idle: boolean(req(f, "idle")?)? },
            "unpair" => ToMac::Unpair,
            "replaces" => ToMac::Replaces { device_id: string(req(f, "deviceID")?)? },
            "offerRelay" => ToMac::OfferRelay(string(x0()?)?),
            "screenStats" => ToMac::ScreenStats(string(x0()?)?),
            "screenSnapshot" => ToMac::ScreenSnapshot { name: string(req(f, "name")?)?, jpeg: data(req(f, "jpeg")?)? },
            "ping" => ToMac::Ping(num(x0()?)?),
            _ => return None,
        })
    }

    pub fn decode(bytes: &[u8]) -> Option<ToMac> {
        serde_json::from_slice::<Value>(bytes).ok().as_ref().and_then(ToMac::from_json)
    }

    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(&self.to_json()).unwrap_or_default()
    }
}

// ------------------------------------------------------------------ ToPhone

impl ToPhone {
    pub fn to_json(&self) -> Value {
        match self {
            ToPhone::Session(i) => one("session", session_json(i)),
            ToPhone::CanControl(b) => one("canControl", json!(b)),
            ToPhone::Front(f) => one("front", json!({"bundle": f.bundle, "name": f.name})),
            ToPhone::Dictation(p) => one("dictation", json!(p.name())),
            ToPhone::Live { committed, pending } => case("live", vec![("committed", json!(committed)), ("pending", json!(pending))]),
            ToPhone::Level(l) => one("level", f32v(*l)),
            ToPhone::Typed(t) => one("typed", json!(t)),
            ToPhone::Notice(t) => one("notice", json!(t)),
            ToPhone::Pong(t) => one("pong", f64v(*t)),
            ToPhone::UdpOk => case("udpOK", vec![]),
            ToPhone::Removed => case("removed", vec![]),
            ToPhone::Relay(a) => case("relay", a.iter().map(|a| ("_0", json!(a))).collect()),
            ToPhone::Replaced => case("replaced", vec![]),
            ToPhone::PairingWaits => case("pairingWaits", vec![]),
            ToPhone::Listen(on) => one("listen", json!(on)),
            ToPhone::NewKey(k) => one("newKey", json!(b64(k))),
            ToPhone::Clock { phone, mac } => case("clock", vec![("phone", f64v(*phone)), ("mac", f64v(*mac))]),
            ToPhone::ScreenFailed(w) => one("screenFailed", json!(w)),
            ToPhone::ScreenView { width, height, codec, display, features } => {
                let mut f = vec![("width", f64v(*width)), ("height", f64v(*height))];
                if let Some(c) = codec {
                    f.push(("codec", json!(c)));
                }
                if let Some(d) = display {
                    f.push(("display", json!(d)));
                }
                if let Some(x) = features {
                    f.push(("features", json!(x)));
                }
                case("screenView", f)
            }
            ToPhone::Displays(l) => one("displays", Value::Array(l.iter().map(display_json).collect())),
            ToPhone::CursorShape { png, hot_x, hot_y, width, height } => case(
                "cursorShape",
                vec![("png", json!(b64(png))), ("hotX", f64v(*hot_x)), ("hotY", f64v(*hot_y)), ("width", f64v(*width)), ("height", f64v(*height))],
            ),
        }
    }

    pub fn from_json(v: &Value) -> Option<ToPhone> {
        let (name, f) = split(v)?;
        let x0 = || req(f, "_0");
        Some(match name {
            "session" => ToPhone::Session(session_from(x0()?)?),
            "canControl" => ToPhone::CanControl(boolean(x0()?)?),
            "front" => {
                let o = x0()?.as_object()?;
                ToPhone::Front(Front { bundle: string(req(o, "bundle")?)?, name: string(req(o, "name")?)? })
            }
            "dictation" => ToPhone::Dictation(DictationPhase::from_name(x0()?.as_str()?)?),
            "live" => ToPhone::Live { committed: string(req(f, "committed")?)?, pending: string(req(f, "pending")?)? },
            "level" => ToPhone::Level(f32of(x0()?)?),
            "typed" => ToPhone::Typed(string(x0()?)?),
            "notice" => ToPhone::Notice(string(x0()?)?),
            "pong" => ToPhone::Pong(num(x0()?)?),
            "udpOK" => ToPhone::UdpOk,
            "removed" => ToPhone::Removed,
            "relay" => ToPhone::Relay(opt(f, "_0", string)?),
            "replaced" => ToPhone::Replaced,
            "pairingWaits" => ToPhone::PairingWaits,
            "listen" => ToPhone::Listen(boolean(x0()?)?),
            "newKey" => ToPhone::NewKey(data(x0()?)?),
            "clock" => ToPhone::Clock { phone: num(req(f, "phone")?)?, mac: num(req(f, "mac")?)? },
            "screenFailed" => ToPhone::ScreenFailed(string(x0()?)?),
            "screenView" => ToPhone::ScreenView {
                width: num(req(f, "width")?)?,
                height: num(req(f, "height")?)?,
                codec: opt(f, "codec", string)?,
                display: opt(f, "display", string)?,
                features: opt(f, "features", |v| list(v, string))?,
            },
            "displays" => ToPhone::Displays(list(x0()?, display_from)?),
            "cursorShape" => ToPhone::CursorShape {
                png: data(req(f, "png")?)?,
                hot_x: num(req(f, "hotX")?)?,
                hot_y: num(req(f, "hotY")?)?,
                width: num(req(f, "width")?)?,
                height: num(req(f, "height")?)?,
            },
            _ => return None,
        })
    }

    pub fn decode(bytes: &[u8]) -> Option<ToPhone> {
        serde_json::from_slice::<Value>(bytes).ok().as_ref().and_then(ToPhone::from_json)
    }

    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(&self.to_json()).unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_cases_and_wrong_shapes_are_dropped() {
        assert_eq!(ToMac::decode(br#"{"teleport":{"_0":1}}"#), None);
        assert_eq!(ToMac::decode(br#"{"key":{"_0":{"key":"C"}}}"#), None, "mods missing");
        assert_eq!(ToMac::decode(br#"{"mods":{"_0":300}}"#), None, "not a UInt8");
        assert_eq!(ToMac::decode(br#"{"releaseAll":{},"keyStored":{}}"#), None, "two cases");
        assert_eq!(ToMac::decode(b"not json"), None);
        // unknown keys inside a case are ignored, as Swift's decoder does
        assert_eq!(ToMac::decode(br#"{"releaseAll":{"later":1}}"#), Some(ToMac::ReleaseAll));
    }

    #[test]
    fn floats_read_as_written() {
        assert_eq!(ToPhone::Level(0.1).to_json().to_string(), r#"{"level":{"_0":0.1}}"#);
    }

    #[test]
    fn crops_are_kept_inside() {
        let c = Crop { x: 0.95, y: -1.0, w: 0.01, h: 2.0 }.valid();
        assert_eq!(c, Crop { x: 0.9, y: 0.0, w: 0.1, h: 1.0 });
        assert_eq!(Crop { x: f32::NAN, y: 0.0, w: 1.0, h: 1.0 }.valid(), Crop::WHOLE);
    }
}
