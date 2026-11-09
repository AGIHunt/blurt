//! Repairing the picture instead of starting it over (docs/design/remote-realtime.md): the Rust half of RemoteVideoRepair.swift
//! (wire, receiver, history, parity) and RemoteScreenRepair.swift (the host's policy). Before this one piece lost on the way cost the
//! whole frame, every frame after it, and a keyframe of 50–170 KB that took a round trip to ask for. Three repairs, each offered by
//! the phone in its screen request and answered by the host in screenView, so an older phone or host goes on as before:
//!
//!  • nack: the phone says which pieces are missing, the host sends them again from the last second it kept. On a home network
//!    that's back in a few ms, well before the frame is due; the phone holds the frames behind it meanwhile.
//!  • ltr: a frame that's gone for good costs one recovery frame (`Screen::recovery_frame`: a refresh from a reference the phone
//!    acknowledged, or the start of an intra refresh), not a keyframe. Named only when the backend's encoder can make one.
//!  • fec: one parity piece per group of pieces, interleaved, so a single loss in a group is mended without asking. Only where a round
//!    trip is long.
//!
//! Everything here is pure (time is passed in), so the receiver's tests run without a clock and the Rust test phone uses the same
//! receiver the Android port follows.

use std::collections::{BTreeMap, HashMap, VecDeque};

use crate::packets::VideoPacket;

pub const NACK: &str = "nack";
pub const LTR: &str = "ltr";
pub const FEC: &str = "fec";
/// what an Apple phone offers (and the Rust test phone)
pub const ALL: [&str; 3] = [NACK, LTR, FEC];

// ------------------------------------------------------------------ the wire

/// A frame's missing pieces; empty: the whole frame (nothing of it arrived, so its size isn't known).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Missing {
    pub frame: u32,
    pub pieces: Vec<u16>,
}

/// What the phone tells the host about the picture: datagrams of kind `VideoFeedback`, first byte the type, numbers big-endian.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Feedback {
    /// 1: send these again. Repeated: u32 frame, u16 n (0xFFFF = the whole frame), n × u16 index
    Nack(Vec<Missing>),
    /// 2: decoded, of the frames that asked for it: u32 the newest, u32 a bit for each of the 32 before it (bit 0 = newest − 1)
    Ack { newest: u32, earlier: u32 },
    /// 3: the frame after this one is gone for good: a recovery frame (or a keyframe). u32 the last frame decoded
    Lost { after: u32 },
}

impl Feedback {
    pub const MAX_SIZE: usize = 1100;

    pub fn encode(&self) -> Vec<u8> {
        let mut d = vec![];
        match self {
            Feedback::Nack(m) => {
                d.push(1);
                for f in m {
                    d.extend_from_slice(&f.frame.to_be_bytes());
                    let n = if f.pieces.is_empty() { 0xFFFF } else { f.pieces.len() as u16 };
                    d.extend_from_slice(&n.to_be_bytes());
                    for p in &f.pieces {
                        d.extend_from_slice(&p.to_be_bytes());
                    }
                }
            }
            Feedback::Ack { newest, earlier } => {
                d.push(2);
                d.extend_from_slice(&newest.to_be_bytes());
                d.extend_from_slice(&earlier.to_be_bytes());
            }
            Feedback::Lost { after } => {
                d.push(3);
                d.extend_from_slice(&after.to_be_bytes());
            }
        }
        d
    }

    pub fn decode(b: &[u8]) -> Option<Feedback> {
        let mut at = 1;
        let u32_at = |at: &mut usize| -> Option<u32> {
            let v = u32::from_be_bytes(b.get(*at..*at + 4)?.try_into().ok()?);
            *at += 4;
            Some(v)
        };
        let u16_at = |at: &mut usize| -> Option<u16> {
            let v = u16::from_be_bytes(b.get(*at..*at + 2)?.try_into().ok()?);
            *at += 2;
            Some(v)
        };
        Some(match *b.first()? {
            1 => {
                let mut m = vec![];
                while at < b.len() {
                    let frame = u32_at(&mut at)?;
                    let n = u16_at(&mut at)?;
                    if n == 0xFFFF {
                        m.push(Missing { frame, pieces: vec![] });
                        continue;
                    }
                    let pieces = (0..n).map(|_| u16_at(&mut at)).collect::<Option<Vec<_>>>()?;
                    m.push(Missing { frame, pieces });
                }
                if m.is_empty() {
                    return None;
                }
                Feedback::Nack(m)
            }
            2 => Feedback::Ack { newest: u32_at(&mut at)?, earlier: u32_at(&mut at)? },
            3 => Feedback::Lost { after: u32_at(&mut at)? },
            _ => return None,
        })
    }

    /// Several frames' worth, in datagrams that fit.
    pub fn nacks(m: Vec<Missing>) -> Vec<Feedback> {
        let (mut out, mut cur, mut size) = (vec![], vec![], 1);
        for mut f in m {
            f.pieces.truncate(400);
            let n = 6 + 2 * f.pieces.len();
            if size + n > Self::MAX_SIZE && !cur.is_empty() {
                out.push(Feedback::Nack(std::mem::take(&mut cur)));
                size = 1;
            }
            cur.push(f);
            size += n;
        }
        if !cur.is_empty() {
            out.push(Feedback::Nack(cur));
        }
        out
    }
}

// ------------------------------------------------------------------ parity

fn xor_into(x: &mut [u8], payload: &[u8]) {
    let n = payload.len();
    x[0] ^= (n >> 8) as u8;
    x[1] ^= (n & 255) as u8;
    for (i, b) in payload.iter().enumerate() {
        x[2 + i] ^= b;
    }
}

/// Parity pieces, about one for every `group` pieces: the frame's n groups are interleaved (piece i is in group i mod n), so a burst
/// of up to n pieces lost in a row, as Wi-Fi loses them, costs each group at most one. Parity piece k (index count + k) is one byte
/// n, then the XOR of each member's length (2 bytes) and payload, zero-padded to the longest. Groups of one piece get none.
pub fn parity(pieces: &[VideoPacket], group: usize) -> Vec<VideoPacket> {
    let Some(first) = pieces.first() else { return vec![] };
    if group < 2 || pieces.len() < 2 {
        return vec![];
    }
    let n = (VideoPacket::MAX_PARITY as usize).min(pieces.len().div_ceil(group));
    (0..n)
        .filter_map(|k| {
            let members: Vec<&VideoPacket> = pieces.iter().skip(k).step_by(n).collect();
            if members.len() < 2 {
                return None;
            }
            let len = members.iter().map(|m| m.payload.len()).max().unwrap_or(0);
            let mut x = vec![0u8; 2 + len];
            for m in &members {
                xor_into(&mut x, &m.payload);
            }
            let mut p = first.clone();
            p.index = first.count + k as u16;
            p.payload = Vec::with_capacity(1 + x.len());
            p.payload.push(n as u8);
            p.payload.extend_from_slice(&x);
            Some(p)
        })
        .collect()
}

/// The one piece missing from a parity piece's group, if exactly one is: (index, payload).
pub fn recover(parity: &[u8], slot: usize, count: usize, have: &HashMap<u16, Vec<u8>>) -> Option<(u16, Vec<u8>)> {
    if parity.len() < 3 {
        return None;
    }
    let n = parity[0] as usize;
    if n < 1 || slot >= n {
        return None;
    }
    let members: Vec<usize> = (slot..count).step_by(n).collect();
    let missing: Vec<usize> = members.iter().copied().filter(|i| !have.contains_key(&(*i as u16))).collect();
    if missing.len() != 1 {
        return None;
    }
    let mut x = parity[1..].to_vec();
    for i in members.iter().filter(|i| **i != missing[0]) {
        let p = have.get(&(*i as u16))?;
        if p.len() + 2 > x.len() {
            return None;
        }
        xor_into(&mut x, p);
    }
    let len = (x[0] as usize) << 8 | x[1] as usize;
    if len + 2 > x.len() {
        return None;
    }
    Some((missing[0] as u16, x[2..2 + len].to_vec()))
}

// ------------------------------------------------------------------ the host's pieces, kept

/// The host's recent pieces, to send again when the phone says they're missing. A second at most, and only what fits.
pub struct History {
    frames: VecDeque<(u32, f64, Vec<Vec<u8>>)>,
    bytes: usize,
    pub max_age: f64,
    pub max_bytes: usize,
}

impl Default for History {
    fn default() -> Self {
        History::new(1.0, 6_000_000)
    }
}

impl History {
    pub fn new(max_age: f64, max_bytes: usize) -> History {
        History { frames: VecDeque::new(), bytes: 0, max_age, max_bytes }
    }

    /// One frame's pieces, encoded (`VideoPacket::encode`), parity pieces left out.
    pub fn add(&mut self, id: u32, packets: Vec<Vec<u8>>, now: f64) {
        self.bytes += packets.iter().map(Vec::len).sum::<usize>();
        self.frames.push_back((id, now, packets));
        while self.frames.len() > 1 {
            let f = &self.frames[0];
            if now - f.1 > self.max_age || self.bytes > self.max_bytes {
                self.bytes -= f.2.iter().map(Vec::len).sum::<usize>();
                self.frames.pop_front();
            } else {
                break;
            }
        }
    }

    /// The pieces asked for (empty: all of them), if the frame is still here.
    pub fn pieces(&self, id: u32, indices: &[u16]) -> Vec<Vec<u8>> {
        let Some(f) = self.frames.iter().rev().find(|f| f.0 == id) else { return vec![] };
        if indices.is_empty() {
            return f.2.clone();
        }
        indices.iter().filter_map(|i| f.2.get(*i as usize).cloned()).collect()
    }

    pub fn clear(&mut self) {
        self.frames.clear();
        self.bytes = 0;
    }
}

// ------------------------------------------------------------------ the phone's side

/// A whole frame, ready for the decoder.
#[derive(Clone, Debug, PartialEq)]
pub struct Frame {
    pub data: Vec<u8>,
    pub id: u32,
    pub keyframe: bool,
    pub refresh: bool,
    pub ack_requested: bool,
    pub captured: f64,
    /// when its first and last pieces arrived, on the phone's clock
    pub first_at: f64,
    pub last_at: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Output {
    Frame(Frame),
    Feedback(Feedback),
    /// ask for a keyframe the old way (ToMac::RequestKeyframe): nothing can be decoded until one comes
    Keyframe,
}

struct Partial {
    count: u16,
    pieces: HashMap<u16, Vec<u8>>,
    parity: BTreeMap<u16, Vec<u8>>,
    key: bool,
    refresh: bool,
    ack: bool,
    captured: f64,
    first_at: f64,
    last_at: f64,
    /// when each missing piece was last asked for, and how often
    asked: HashMap<u16, (f64, u32)>,
    highest: u16,
}

impl Partial {
    fn complete(&self) -> bool {
        self.pieces.len() == self.count as usize
    }
}

/// The phone's side (RemoteVideoReceiver): pieces in, frames out in order, and what to tell the host. Frames behind a missing piece
/// wait for it to be sent again, up to a limit set by the round trip; then the frame is given up and the host asked for a recovery
/// frame (or a keyframe).
pub struct Receiver {
    /// what the host said it does (screenView.features): with neither, nothing waits and a loss asks for a keyframe, as before them
    pub nack: bool,
    pub ltr: bool,
    /// the last measured round trip, seconds
    pub rtt: f64,
    partials: BTreeMap<u32, Partial>,
    /// frames known only from a gap in the numbers: when each was last asked for, and how often
    whole: BTreeMap<u32, (f64, u32)>,
    /// the frame that decodes next; None until the first keyframe
    next: Option<u32>,
    newest: Option<u32>,
    /// nothing can be decoded until a keyframe, or with ltr a refresh, arrives
    pub broken: bool,
    /// the decoder lost its references: only a keyframe will do
    needs_key: bool,
    broken_at: f64,
    asked_at: f64,
    /// when frame `next` was first seen to be late
    late_since: Option<f64>,
    /// when any piece last arrived: nothing at all for a while is a stall, not a loss
    heard_at: f64,
    acks: Vec<u32>,
    acked_at: f64,
    pub dropped: usize,
    pub repaired: usize,
    pub nacked: usize,
    pub refreshes: usize,
}

const QUIET: f64 = 0.02;
/// a stall this long is given up on regardless
const LONGEST: f64 = 0.35;

impl Receiver {
    pub fn new(nack: bool, ltr: bool, now: f64) -> Receiver {
        Receiver {
            nack,
            ltr,
            rtt: 0.01,
            partials: BTreeMap::new(),
            whole: BTreeMap::new(),
            next: None,
            newest: None,
            broken: true,
            needs_key: true,
            broken_at: now,
            asked_at: -1.0,
            late_since: None,
            heard_at: -1.0,
            acks: vec![],
            acked_at: -1.0,
            dropped: 0,
            repaired: 0,
            nacked: 0,
            refreshes: 0,
        }
    }

    /// How long frames wait behind a missing one before it's given up: a few round trips, within reason. Without nack, not at all.
    pub fn patience(&self) -> f64 {
        if self.nack {
            0.15f64.min((self.rtt * 3.0 + 0.02).max(0.04))
        } else {
            0.0
        }
    }

    fn retry(&self) -> f64 {
        (self.rtt * 1.5).max(0.012)
    }

    /// pieces of a frame still arriving: the end of a frame is asked for only after this quiet
    fn tail_wait(&self) -> f64 {
        (self.rtt * 2.0).max(0.03)
    }

    pub fn add(&mut self, p: VideoPacket, now: f64) -> Vec<Output> {
        if self.next.is_some_and(|n| p.frame < n) {
            return vec![]; // decoded already, or given up: a second copy, or late
        }
        // waiting to start over: only what can end the wait is worth keeping
        if self.broken && !p.keyframe && !(p.refresh && self.ltr && !self.needs_key) {
            return vec![];
        }
        if !self.partials.contains_key(&p.frame) {
            if self.partials.len() > 120 {
                if let Some(oldest) = self.partials.keys().next().copied() {
                    self.partials.remove(&oldest);
                }
            }
            self.partials.insert(
                p.frame,
                Partial {
                    count: p.count,
                    pieces: HashMap::new(),
                    parity: BTreeMap::new(),
                    key: p.keyframe,
                    refresh: p.refresh,
                    ack: p.ack_requested,
                    captured: p.captured,
                    first_at: now,
                    last_at: now,
                    asked: HashMap::new(),
                    highest: 0,
                },
            );
            self.whole.remove(&p.frame);
        }
        let mut repaired = 0;
        {
            let f = self.partials.get_mut(&p.frame).unwrap();
            if f.count != p.count {
                return vec![];
            }
            f.last_at = now;
            self.heard_at = now;
            if p.is_parity() {
                f.parity.insert(p.index - p.count, p.payload);
            } else if !f.pieces.contains_key(&p.index) {
                f.asked.remove(&p.index);
                f.highest = f.highest.max(p.index);
                f.pieces.insert(p.index, p.payload);
            }
            if !f.complete() && !f.parity.is_empty() {
                let slots: Vec<(u16, Vec<u8>)> = f.parity.iter().map(|(k, v)| (*k, v.clone())).collect();
                for (slot, par) in slots {
                    if let Some((i, d)) = recover(&par, slot as usize, f.count as usize, &f.pieces) {
                        f.pieces.insert(i, d);
                        f.asked.remove(&i);
                        repaired += 1;
                    }
                }
            }
        }
        self.repaired += repaired;
        if self.newest.is_none_or(|n| p.frame > n) {
            if let Some(n) = self.newest {
                if self.nack && p.frame > n.wrapping_add(1) {
                    for g in n.wrapping_add(1)..p.frame {
                        if !self.partials.contains_key(&g) && !self.whole.contains_key(&g) && self.next.is_some_and(|x| g >= x) {
                            self.whole.insert(g, (0.0, 0));
                        }
                    }
                }
            }
            self.newest = Some(p.frame);
        }
        self.drain()
    }

    /// Frames ready to decode, in order.
    fn drain(&mut self) -> Vec<Output> {
        let mut out = vec![];
        loop {
            // a whole keyframe jumps over anything before it
            let floor = self.next.unwrap_or(0);
            let key = self.partials.iter().find(|(id, f)| f.complete() && f.key && **id >= floor).map(|(id, _)| *id);
            if let Some(k) = key {
                if self.broken || Some(k) != self.next {
                    out.push(Output::Frame(self.release(k)));
                    continue;
                }
            }
            if self.broken {
                // with references acknowledged, a refresh will do
                if self.ltr && !self.needs_key {
                    if let Some(n) = self.next {
                        let r = self.partials.iter().find(|(id, f)| f.complete() && f.refresh && **id >= n).map(|(id, _)| *id);
                        if let Some(r) = r {
                            self.refreshes += 1;
                            out.push(Output::Frame(self.release(r)));
                            continue;
                        }
                    }
                }
                break;
            }
            match self.next {
                Some(n) if self.partials.get(&n).is_some_and(|f| f.complete()) => out.push(Output::Frame(self.release(n))),
                _ => break,
            }
        }
        out
    }

    fn release(&mut self, id: u32) -> Frame {
        let f = self.partials.remove(&id).unwrap();
        let mut data = Vec::new();
        for i in 0..f.count {
            if let Some(p) = f.pieces.get(&i) {
                data.extend_from_slice(p);
            }
        }
        if let Some(n) = self.next {
            if id > n {
                self.dropped += (id - n) as usize;
            }
        }
        self.partials.retain(|k, _| *k > id);
        self.whole.retain(|k, _| *k > id);
        self.next = Some(id.wrapping_add(1));
        if f.key {
            self.needs_key = false;
        }
        self.broken = false;
        self.late_since = None;
        Frame {
            data,
            id,
            keyframe: f.key,
            refresh: f.refresh,
            ack_requested: f.ack,
            captured: f.captured,
            first_at: f.first_at,
            last_at: f.last_at,
        }
    }

    /// Timers: missing pieces asked for, frames given up, the host asked to start over. Call every few ms while the picture is on.
    pub fn tick(&mut self, now: f64) -> Vec<Output> {
        let mut out = vec![];
        // a frame that can't come: give up on it, and everything behind it waits for a refresh
        if let (false, Some(n)) = (self.broken, self.next) {
            let late = match self.partials.get(&n) {
                Some(f) => !f.complete() && (self.newest.is_some_and(|x| x > n) || now - f.last_at > self.tail_wait()),
                None => self.newest.is_some_and(|x| x >= n),
            };
            if late {
                let since = *self.late_since.get_or_insert(now);
                let stalled = now - self.heard_at > QUIET;
                if now - since >= self.patience() && (!stalled || now - since >= LONGEST) {
                    self.broken = true;
                    self.broken_at = now;
                    self.asked_at = -1.0;
                    self.late_since = None;
                    // what's behind it is no use now, except what could end the wait
                    self.partials.retain(|_, p| p.key || p.refresh);
                    self.whole.clear();
                }
            } else {
                self.late_since = None;
            }
        }
        if self.broken {
            // at the start the first keyframe is on its way: ask only if it doesn't come
            let started = self.next.is_none() && self.asked_at < 0.0;
            if now - self.asked_at >= 0.25 && (!started || now - self.broken_at > 0.3) {
                self.asked_at = now;
                match self.next {
                    Some(n) if self.ltr && !self.needs_key => out.push(Output::Feedback(Feedback::Lost { after: n.wrapping_sub(1) })),
                    _ => out.push(Output::Keyframe),
                }
            }
        }
        if self.nack {
            out.extend(self.missing(now));
        }
        if !self.acks.is_empty() && now - self.acked_at >= 0.02 {
            out.push(Output::Feedback(self.take_ack(now)));
        }
        out
    }

    /// What to ask for again, now.
    fn missing(&mut self, now: f64) -> Vec<Output> {
        let mut want = vec![];
        let floor = self.next.unwrap_or(0);
        let (tail, retry, heard, newest, broken, ltr, needs_key) =
            (self.tail_wait(), self.retry(), self.heard_at, self.newest, self.broken, self.ltr, self.needs_key);
        for (id, f) in self.partials.range_mut(floor..) {
            if f.complete() {
                continue;
            }
            // while broken only what could end it is worth having
            if broken && !(f.key || (f.refresh && ltr && !needs_key)) {
                continue;
            }
            let later = newest.is_some_and(|n| n > *id);
            let mut ask = vec![];
            for i in 0..f.count {
                if f.pieces.contains_key(&i) {
                    continue;
                }
                // a hole before the newest piece of the frame, or the end once it's been quiet (or a later frame has begun)
                if !(i < f.highest || later || now - f.last_at > tail) {
                    continue;
                }
                // asked already: again after a round trip and a half, but not into a stall
                let before = f.asked.get(&i).copied();
                if let Some((at, times)) = before {
                    if times >= 4 || now - at < retry || now - heard > QUIET {
                        continue;
                    }
                }
                ask.push(i);
                f.asked.insert(i, (now, before.map_or(0, |b| b.1) + 1));
            }
            if !ask.is_empty() {
                self.nacked += ask.len();
                want.push(Missing { frame: *id, pieces: ask });
            }
        }
        if !self.broken {
            for (id, a) in self.whole.range_mut(floor..) {
                if a.1 < 4 && now - a.0 >= retry {
                    *a = (now, a.1 + 1);
                    want.push(Missing { frame: *id, pieces: vec![] });
                    self.nacked += 1;
                }
            }
        }
        Feedback::nacks(want).into_iter().map(Output::Feedback).collect()
    }

    /// The decoder took this frame: if the host asked, it hears so (in a batch, every 20 ms at most).
    pub fn decoded(&mut self, f: &Frame, now: f64) -> Vec<Output> {
        if !self.ltr || !f.ack_requested {
            return vec![];
        }
        self.acks.push(f.id);
        if now - self.acked_at < 0.02 {
            return vec![];
        }
        vec![Output::Feedback(self.take_ack(now))]
    }

    fn take_ack(&mut self, now: f64) -> Feedback {
        let n = self.acks.iter().copied().max().unwrap_or(0);
        let mut bits = 0u32;
        for a in &self.acks {
            if *a < n && n - a <= 32 {
                bits |= 1 << (n - a - 1);
            }
        }
        self.acks.clear();
        self.acked_at = now;
        Feedback::Ack { newest: n, earlier: bits }
    }

    /// The decoder failed: its references are gone, only a keyframe helps.
    pub fn decoder_failed(&mut self, now: f64) {
        self.broken = true;
        self.needs_key = true;
        self.broken_at = now;
        self.asked_at = -1.0;
        self.acks.clear();
    }
}

// ------------------------------------------------------------------ the host's side

/// What the host does with a piece of feedback.
#[derive(Clone, Debug, PartialEq)]
pub enum Answer {
    /// these sealed-ready pieces again, byte for byte
    Resend(Vec<Vec<u8>>),
    /// references the phone has decoded: the encoder may use them (`Screen::acknowledged`)
    Acknowledged(Vec<u64>),
    /// a frame lost for good: a recovery frame (`Screen::recovery_frame`)
    Recover,
    /// the same without ltr: a keyframe
    Keyframe,
}

/// The host's half (RemoteScreenRepair.swift's ScreenRepair): what the phone offered of what this host does, the pieces kept,
/// references acknowledged, and the parity group size.
#[derive(Default)]
pub struct HostRepair {
    pub nack: bool,
    pub ltr: bool,
    pub fec: bool,
    history: History,
    /// frames the encoder may refer back to once the phone has them: frame id → the backend's reference
    references: HashMap<u32, u64>,
    /// pieces per parity piece; 0: none
    pub group: usize,
    /// over the last few reports: pieces sent and asked for again
    window: VecDeque<(usize, usize)>,
    sent_now: usize,
    asked_now: usize,
    budget: (f64, usize),
    forced_group: Option<usize>,
    // for the log, since the last stats line
    pub resent: usize,
    pub recoveries: usize,
    pub parity_sent: usize,
    pub lost_asked: usize,
    pub ignored: usize,
}

impl HostRepair {
    /// A new stream: what the phone offered, of what this host does. `recovery`: the backend's encoder makes recovery frames.
    pub fn negotiate(offered: Option<&[String]>, recovery: bool) -> HostRepair {
        let has = |f: &str| offered.is_some_and(|o| o.iter().any(|x| x == f));
        let off = std::env::var("BLURT_SCREEN_REPAIR").is_ok_and(|v| v == "0"); // for measuring before / after, as on the Mac
        HostRepair {
            nack: has(NACK) && !off,
            ltr: has(LTR) && recovery && !off,
            fec: has(FEC) && !off,
            forced_group: if cfg!(debug_assertions) { std::env::var("BLURT_SCREEN_FEC").ok().and_then(|g| g.parse().ok()) } else { None },
            ..Default::default()
        }
    }

    /// Whether the phone asked for nack or ltr: either way it repairs, so no periodic keyframes.
    pub fn repairs_offered(offered: Option<&[String]>) -> bool {
        offered.is_some_and(|o| o.iter().any(|x| x == NACK || x == LTR)) && !std::env::var("BLURT_SCREEN_REPAIR").is_ok_and(|v| v == "0")
    }

    /// For screenView: sorted, None when none.
    pub fn names(&self) -> Option<Vec<String>> {
        let v: Vec<String> = [(FEC, self.fec), (LTR, self.ltr), (NACK, self.nack)].iter().filter(|x| x.1).map(|x| x.0.to_string()).collect();
        (!v.is_empty()).then_some(v)
    }

    /// The encoder was started again: references from the last one mean nothing to it.
    pub fn new_encoder(&mut self) {
        self.references.clear();
    }

    /// A frame went out: kept for sending again, its reference remembered. Parity pieces for it, if they're worth it now.
    pub fn sent(&mut self, frame: u32, reference: Option<u64>, pieces: &[VideoPacket], encoded: &[Vec<u8>], datagrams: bool, now: f64) -> Vec<VideoPacket> {
        if let (Some(r), true) = (reference, self.ltr) {
            self.references.insert(frame, r);
            if self.references.len() > 600 {
                if let Some(old) = self.references.keys().min().copied() {
                    self.references.remove(&old);
                }
            }
        }
        if !datagrams {
            return vec![];
        }
        self.sent_now += pieces.len();
        if self.nack {
            self.history.add(frame, encoded.to_vec(), now);
        }
        if !self.fec || self.group == 0 {
            return vec![];
        }
        let p = parity(pieces, self.group);
        self.parity_sent += p.len();
        p
    }

    /// What the phone said: pieces to send again, references to use, or a frame to make now. `rate`: the picture's bits a second.
    pub fn feedback(&mut self, d: &[u8], rate: i64, now: f64) -> Option<Answer> {
        match Feedback::decode(d)? {
            Feedback::Nack(missing) => {
                if !self.nack {
                    return None;
                }
                let mut out = vec![];
                for m in &missing {
                    self.asked_now += m.pieces.len().max(1);
                    out.extend(self.history.pieces(m.frame, &m.pieces));
                }
                // a second's budget: half the picture's rate again, at least 300 KB. Past it the network is the trouble, not chance
                if now - self.budget.0 > 1.0 {
                    self.budget = (now, 0);
                }
                let n: usize = out.iter().map(Vec::len).sum();
                if self.budget.1 + n > 300_000usize.max((rate / 16).max(0) as usize) {
                    self.ignored += out.len();
                    return None;
                }
                self.budget.1 += n;
                self.resent += out.len();
                (!out.is_empty()).then_some(Answer::Resend(out))
            }
            Feedback::Ack { newest, earlier } => {
                if !self.ltr {
                    return None;
                }
                let mut ids = vec![newest];
                ids.extend((0..32).filter(|i| earlier & (1 << i) != 0).map(|i| newest.wrapping_sub(i).wrapping_sub(1)));
                let refs: Vec<u64> = ids.iter().filter_map(|id| self.references.remove(id)).collect();
                (!refs.is_empty()).then_some(Answer::Acknowledged(refs))
            }
            Feedback::Lost { .. } => {
                self.lost_asked += 1;
                if !self.ltr {
                    return Some(Answer::Keyframe);
                }
                self.recoveries += 1;
                Some(Answer::Recover)
            }
        }
    }

    /// Each report from the phone (about once a second): parity follows the loss seen and the round trip. At home a piece asked for
    /// is back in a few ms, so parity would only cost; away, asking costs a round trip the frame can't wait for.
    /// Some(new group): it changed.
    pub fn adapt(&mut self, rtt: Option<f64>) -> Option<(usize, f64)> {
        self.window.push_back((self.sent_now, self.asked_now));
        self.sent_now = 0;
        self.asked_now = 0;
        if self.window.len() > 5 {
            self.window.pop_front();
        }
        if !self.fec {
            return None;
        }
        if let Some(g) = self.forced_group {
            self.group = g;
            return None;
        }
        let sent: usize = self.window.iter().map(|w| w.0).sum();
        let asked: usize = self.window.iter().map(|w| w.1).sum();
        let loss = if sent > 0 { asked as f64 / sent as f64 } else { 0.0 };
        let before = self.group;
        self.group = group_for(loss, rtt.unwrap_or(0.0));
        (self.group != before).then_some((self.group, loss))
    }

    /// For the stats line, since the last.
    pub fn take(&mut self) -> serde_json::Value {
        let v = serde_json::json!({"resent": self.resent, "recoveries": self.recoveries, "parity": self.parity_sent,
            "lost_asked": self.lost_asked, "resend_ignored": self.ignored, "fec_group": self.group});
        self.resent = 0;
        self.recoveries = 0;
        self.parity_sent = 0;
        self.lost_asked = 0;
        self.ignored = 0;
        v
    }
}

/// Pieces per parity piece for this loss (pieces asked for ÷ sent) and round trip: WebRTC's line, NACK only when it's short.
pub fn group_for(loss: f64, rtt: f64) -> usize {
    if rtt >= 0.03 {
        if loss > 0.05 {
            4
        } else if loss > 0.01 {
            8
        } else if loss > 0.002 {
            16
        } else {
            0
        }
    } else if loss > 0.1 {
        8
    } else {
        0
    }
}

/// Ported from RemoteVideoRepairTests.swift, plus the host's half.
#[cfg(test)]
mod tests {
    use super::*;

    fn frame(id: u32, size: usize, key: bool, refresh: bool, ack: bool) -> Vec<VideoPacket> {
        let data: Vec<u8> = (0..size).map(|i| (i.wrapping_mul(7).wrapping_add(id as usize)) as u8).collect();
        VideoPacket::split_flagged(&data, id, key, refresh, ack, id as f64, 1000)
    }
    fn plain(id: u32) -> Vec<VideoPacket> {
        frame(id, 3000, false, false, false)
    }
    fn key(id: u32) -> Vec<VideoPacket> {
        frame(id, 3000, true, false, false)
    }
    fn frames(out: &[Output]) -> Vec<u32> {
        out.iter().filter_map(|o| if let Output::Frame(f) = o { Some(f.id) } else { None }).collect()
    }
    fn feedback(out: &[Output]) -> Vec<Feedback> {
        out.iter().filter_map(|o| if let Output::Feedback(f) = o { Some(f.clone()) } else { None }).collect()
    }
    fn feed(r: &mut Receiver, pieces: impl IntoIterator<Item = VideoPacket>, now: f64) -> Vec<Output> {
        pieces.into_iter().flat_map(|p| r.add(VideoPacket::decode(&p.encode()).unwrap(), now)).collect()
    }

    #[test]
    fn feedback_round_trips() {
        let all = [
            Feedback::Nack(vec![Missing { frame: 7, pieces: vec![0, 3, 9] }, Missing { frame: 8, pieces: vec![] }]),
            Feedback::Ack { newest: 1234, earlier: 0b1011 },
            Feedback::Lost { after: 99 },
        ];
        for f in all {
            assert_eq!(Feedback::decode(&f.encode()), Some(f));
        }
        assert_eq!(Feedback::decode(&[9, 1, 2]), None);
        assert_eq!(Feedback::decode(&[1, 0, 0]), None);
        assert_eq!(Feedback::decode(&[1]), None, "a nack of nothing");
        let big = Feedback::nacks((0..300).map(|i| Missing { frame: i, pieces: vec![1, 2, 3] }).collect());
        assert!(big.len() > 1);
        assert!(big.iter().all(|f| f.encode().len() <= Feedback::MAX_SIZE));
    }

    #[test]
    fn the_flags_byte_keeps_the_old_meaning() {
        let p = VideoPacket { frame: 1, index: 0, count: 1, keyframe: true, payload: vec![1], ..Default::default() };
        assert_eq!(p.encode()[8], 1, "what an old phone reads as a keyframe");
        let r = VideoPacket { frame: 1, index: 0, count: 1, refresh: true, ack_requested: true, payload: vec![1], ..Default::default() };
        let back = VideoPacket::decode(&r.encode()).unwrap();
        assert!(back.refresh && back.ack_requested && !back.keyframe);
        let mut far = r.clone();
        far.index = 1 + VideoPacket::MAX_PARITY;
        assert_eq!(VideoPacket::decode(&far.encode()), None, "past the parity pieces: nothing");
    }

    #[test]
    fn parity_rebuilds_any_one_piece() {
        let pieces = frame(3, 9_500, true, false, false); // ten pieces, the last short
        let par = parity(&pieces, 5);
        assert_eq!(par.len(), 2);
        assert!(par.iter().all(VideoPacket::is_parity));
        // an old assembler never takes a parity piece for a piece
        let mut old = crate::packets::VideoAssembler::new();
        for p in &par {
            assert!(old.add(VideoPacket::decode(&p.encode()).unwrap()).is_none());
        }
        let whole: Vec<u8> = pieces.iter().flat_map(|p| p.payload.clone()).collect();
        for lost in [vec![0u16], vec![4], vec![9], vec![3, 4]] {
            let mut r = Receiver::new(false, false, 0.0);
            let out = feed(&mut r, pieces.iter().chain(&par).filter(|p| !lost.contains(&p.index)).cloned(), 0.0);
            let Some(Output::Frame(f)) = out.first() else { panic!("piece {lost:?} not rebuilt") };
            assert_eq!(f.data, whole);
            assert_eq!(r.repaired, lost.len(), "a burst of two lands in two groups");
        }
    }

    #[test]
    fn frames_wait_for_a_piece_sent_again() {
        let mut r = Receiver::new(true, false, 0.0);
        r.rtt = 0.004;
        assert_eq!(frames(&feed(&mut r, key(1), 0.0)), [1]);
        let (f2, f3) = (plain(2), plain(3));
        let mut out = feed(&mut r, f2.iter().filter(|p| p.index != 1).cloned(), 0.016);
        out.extend(feed(&mut r, f3, 0.032));
        assert!(frames(&out).is_empty(), "3 waits for 2");
        assert_eq!(feedback(&r.tick(0.033)), [Feedback::Nack(vec![Missing { frame: 2, pieces: vec![1] }])]);
        assert!(feedback(&r.tick(0.034)).is_empty(), "not again within a round trip");
        assert_eq!(frames(&feed(&mut r, [f2[1].clone()], 0.037)), [2, 3]);
        assert_eq!(r.dropped, 0);
    }

    #[test]
    fn a_whole_frame_missing_is_asked_for() {
        let mut r = Receiver::new(true, false, 0.0);
        feed(&mut r, key(1), 0.0);
        feed(&mut r, plain(3), 0.03);
        assert_eq!(feedback(&r.tick(0.031)), [Feedback::Nack(vec![Missing { frame: 2, pieces: vec![] }])]);
        assert_eq!(frames(&feed(&mut r, plain(2), 0.035)), [2, 3]);
    }

    #[test]
    fn the_end_of_a_frame_is_asked_for_once_quiet() {
        let mut r = Receiver::new(true, false, 0.0);
        feed(&mut r, key(1), 0.0);
        let f2 = plain(2);
        feed(&mut r, f2[..f2.len() - 1].to_vec(), 0.016);
        assert!(feedback(&r.tick(0.02)).is_empty(), "its last piece may still be coming");
        assert_eq!(feedback(&r.tick(0.05)), [Feedback::Nack(vec![Missing { frame: 2, pieces: vec![2] }])]);
    }

    #[test]
    fn given_up_then_a_refresh_ends_the_wait() {
        let mut r = Receiver::new(true, true, 0.0);
        r.rtt = 0.004;
        let out = feed(&mut r, frame(1, 3000, true, false, true), 0.0);
        let Output::Frame(f1) = &out[0] else { panic!() };
        assert_eq!(feedback(&r.decoded(f1, 0.01)), [Feedback::Ack { newest: 1, earlier: 0 }]);
        let mut out = feed(&mut r, plain(2).into_iter().filter(|p| p.index != 0), 0.016);
        out.extend(feed(&mut r, plain(3), 0.032));
        assert!(frames(&out).is_empty());
        // frames keep coming (the path works), the piece doesn't
        let (mut t, mut n, mut lost) = (0.033f64, 4u32, false);
        while t < 0.3 && !lost {
            if ((t * 1000.0).round() as i64) % 16 == 0 {
                feed(&mut r, plain(n), t);
                n += 1;
            }
            lost = feedback(&r.tick(t)).contains(&Feedback::Lost { after: 1 });
            t += 0.001;
        }
        assert!(lost, "gave up within its patience");
        assert!(t < 0.09, "{t}");
        assert!(r.broken);
        assert!(frames(&feed(&mut r, plain(n), t + 0.01)).is_empty(), "ordinary frames don't help now");
        assert_eq!(frames(&feed(&mut r, frame(n + 1, 3000, false, true, false), t + 0.02)), [n + 1]);
        assert!(!r.broken);
        assert_eq!(frames(&feed(&mut r, plain(n + 2), t + 0.03)), [n + 2]);
    }

    #[test]
    fn a_stall_is_waited_out_not_given_up() {
        let mut r = Receiver::new(true, true, 0.0);
        r.rtt = 0.004;
        feed(&mut r, key(1), 0.0);
        let f2 = plain(2);
        feed(&mut r, f2[..1].to_vec(), 0.016);
        let mut asked = 0;
        let mut t = 0.02;
        while t < 0.136 {
            let out = r.tick(t);
            assert!(!out.contains(&Output::Keyframe));
            assert!(!feedback(&out).contains(&Feedback::Lost { after: 1 }), "gave up during a stall at {t}");
            asked += feedback(&out).len();
            t += 0.004;
        }
        assert!(asked <= 1, "the end of the frame asked for once, not again into the stall");
        assert_eq!(frames(&feed(&mut r, f2[1..].to_vec(), 0.137)), [2]);
        assert!(!r.broken);
    }

    #[test]
    fn without_ltr_a_loss_asks_for_a_keyframe() {
        let mut r = Receiver::new(true, false, 0.0);
        feed(&mut r, key(1), 0.0);
        feed(&mut r, plain(3), 0.02);
        let (mut t, mut asked) = (0.02, false);
        while t < 0.4 && !asked {
            asked = r.tick(t).contains(&Output::Keyframe);
            t += 0.005;
        }
        assert!(asked);
        assert_eq!(frames(&feed(&mut r, key(9), t)), [9]);
        assert_eq!(r.dropped, 7);
    }

    #[test]
    fn after_the_decoder_fails_only_a_keyframe_will() {
        let mut r = Receiver::new(true, true, 0.0);
        feed(&mut r, key(1), 0.0);
        r.decoder_failed(0.01);
        assert_eq!(r.tick(0.02), [Output::Keyframe]);
        assert!(frames(&feed(&mut r, frame(2, 3000, false, true, false), 0.03)).is_empty());
        assert_eq!(frames(&feed(&mut r, key(3), 0.04)), [3]);
    }

    #[test]
    fn no_asking_at_the_start_while_the_first_keyframe_arrives() {
        let mut r = Receiver::new(true, true, 0.0);
        feed(&mut r, key(1)[..1].to_vec(), 0.001);
        assert!(!r.tick(0.01).contains(&Output::Keyframe));
        assert!(r.tick(0.5).contains(&Output::Keyframe));
    }

    #[test]
    fn history_keeps_a_second() {
        let mut h = History::new(1.0, 10_000);
        h.add(1, vec![vec![1], vec![2]], 0.0);
        h.add(2, vec![vec![3]], 0.5);
        assert_eq!(h.pieces(1, &[1]), [vec![2]]);
        assert_eq!(h.pieces(1, &[]).len(), 2);
        h.add(3, vec![vec![4]], 1.2);
        assert!(h.pieces(1, &[0]).is_empty());
        assert_eq!(h.pieces(2, &[0]), [vec![3]]);
        let mut small = History::new(10.0, 3);
        small.add(1, vec![vec![0; 2]], 0.0);
        small.add(2, vec![vec![0; 2]], 0.1);
        assert!(small.pieces(1, &[]).is_empty(), "past its bytes");
        small.add(3, vec![vec![0; 9]], 0.2);
        assert_eq!(small.pieces(3, &[]).len(), 1, "the newest stays, however big");
    }

    fn offered() -> Vec<String> {
        ALL.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn the_host_names_what_it_does_of_what_was_offered() {
        let h = HostRepair::negotiate(Some(&offered()), false);
        assert_eq!(h.names(), Some(vec!["fec".into(), "nack".into()]), "no recovery frames: no ltr");
        let h = HostRepair::negotiate(Some(&offered()), true);
        assert_eq!(h.names(), Some(vec!["fec".into(), "ltr".into(), "nack".into()]));
        assert_eq!(HostRepair::negotiate(None, true).names(), None, "an old phone: nothing");
        assert_eq!(HostRepair::negotiate(Some(&["zstd".to_string()]), true).names(), None);
        assert!(HostRepair::repairs_offered(Some(&["nack".to_string()])));
        assert!(!HostRepair::repairs_offered(Some(&["fec".to_string()])));
    }

    #[test]
    fn the_host_sends_again_what_was_asked_within_a_budget() {
        let mut h = HostRepair::negotiate(Some(&offered()), true);
        let pieces = plain(5);
        let enc: Vec<Vec<u8>> = pieces.iter().map(VideoPacket::encode).collect();
        assert!(h.sent(5, Some(77), &pieces, &enc, true, 0.0).is_empty(), "no parity at home");
        let nack = Feedback::Nack(vec![Missing { frame: 5, pieces: vec![2] }]).encode();
        assert_eq!(h.feedback(&nack, 12_000_000, 0.01), Some(Answer::Resend(vec![enc[2].clone()])));
        let all = Feedback::Nack(vec![Missing { frame: 5, pieces: vec![] }]).encode();
        assert_eq!(h.feedback(&all, 12_000_000, 0.01), Some(Answer::Resend(enc.clone())));
        // the budget: 300 KB a second at least; past it, nothing
        let big: Vec<VideoPacket> = frame(6, 400_000, false, false, false);
        let enc6: Vec<Vec<u8>> = big.iter().map(VideoPacket::encode).collect();
        h.sent(6, None, &big, &enc6, true, 0.02);
        let all6 = Feedback::Nack(vec![Missing { frame: 6, pieces: vec![] }]).encode();
        assert_eq!(h.feedback(&all6, 1_000_000, 0.03), None);
        assert_eq!(h.ignored, enc6.len());
        // acknowledged references, once each
        let ack = Feedback::Ack { newest: 6, earlier: 1 }.encode();
        assert_eq!(h.feedback(&ack, 0, 0.04), Some(Answer::Acknowledged(vec![77])));
        assert_eq!(h.feedback(&ack, 0, 0.05), None);
        assert_eq!(h.feedback(&Feedback::Lost { after: 4 }.encode(), 0, 0.06), Some(Answer::Recover));
        let mut old = HostRepair::negotiate(Some(&["nack".to_string()]), false);
        assert_eq!(old.feedback(&Feedback::Lost { after: 4 }.encode(), 0, 0.0), Some(Answer::Keyframe), "without ltr: a keyframe");
    }

    #[test]
    fn parity_follows_the_loss_and_the_round_trip() {
        assert_eq!(group_for(0.03, 0.005), 0, "at home NACK is cheaper");
        assert_eq!(group_for(0.15, 0.005), 8);
        assert_eq!(group_for(0.001, 0.08), 0);
        assert_eq!(group_for(0.005, 0.08), 16);
        assert_eq!(group_for(0.02, 0.08), 8);
        assert_eq!(group_for(0.08, 0.08), 4);
        let mut h = HostRepair::negotiate(Some(&offered()), false);
        h.forced_group = None;
        let pieces = plain(1);
        let enc: Vec<Vec<u8>> = pieces.iter().map(VideoPacket::encode).collect();
        for i in 0..40 {
            h.sent(i, None, &pieces, &enc, true, i as f64 * 0.016);
        }
        // 120 pieces sent, 6 asked for again: 5 %
        let nack = Feedback::Nack((0..6).map(|i| Missing { frame: i, pieces: vec![0] }).collect()).encode();
        h.feedback(&nack, 12_000_000, 0.7);
        assert_eq!(h.adapt(Some(0.08)), Some((8, 0.05)));
        assert_eq!(h.sent(41, None, &pieces, &enc, true, 0.8).len(), 1, "3 pieces: one group");
        let many = frame(42, 20_000, false, false, false);
        let enc42: Vec<Vec<u8>> = many.iter().map(VideoPacket::encode).collect();
        assert_eq!(h.sent(42, None, &many, &enc42, true, 0.8).len(), 3, "20 pieces in 8s: 3 interleaved groups");
        assert!(!HostRepair::negotiate(Some(&["nack".to_string()]), false).fec);
    }
}
