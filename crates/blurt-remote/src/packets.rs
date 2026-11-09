//! The binary parts of the wire (docs/design/remote-protocol.md §Layers, §Messages): stream framing, the frame kinds, the pointer
//! packet, video pieces and their payload, the cursor. References: RemoteCrypto.swift (RemoteFrameReader), RemoteMessages.swift
//! (RemotePointerPacket), RemoteVideo.swift (RemoteVideoPacket, RemoteVideoPayload, RemoteVideoAssembler).

use crate::wire::Crop;

/// A frame's first byte says what follows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// JSON
    Control = 0,
    /// 16 kHz mono PCM16 little-endian
    Audio = 1,
    Pointer = 2,
    /// a video piece, datagrams (or the relay's stream)
    Video = 3,
    /// 8 bytes the other side sends straight back
    Probe = 4,
    /// x, y as f32 LE, 0…1 of the source
    Cursor = 5,
}

impl Kind {
    pub fn from_byte(b: u8) -> Option<Kind> {
        Some(match b {
            0 => Kind::Control,
            1 => Kind::Audio,
            2 => Kind::Pointer,
            3 => Kind::Video,
            4 => Kind::Probe,
            5 => Kind::Cursor,
            _ => return None,
        })
    }
}

/// Length-prefixed frames over a byte stream: 4 bytes big-endian, then the frame. Until the first sealed frame `limit` is 1 KB.
pub struct FrameReader {
    pub limit: usize,
    buffer: Vec<u8>,
    head: usize,
}

pub const MAX_FRAME: usize = 1 << 20;
pub const MAX_HELLO: usize = 1024;

#[derive(Debug, PartialEq, Eq)]
pub struct BadLength;

impl Default for FrameReader {
    fn default() -> Self {
        FrameReader { limit: MAX_HELLO, buffer: Vec::new(), head: 0 }
    }
}

impl FrameReader {
    pub fn framed(d: &[u8]) -> Vec<u8> {
        let mut o = Vec::with_capacity(4 + d.len());
        o.extend_from_slice(&(d.len() as u32).to_be_bytes());
        o.extend_from_slice(d);
        o
    }

    pub fn feed(&mut self, d: &[u8]) {
        if self.head > 0 {
            self.buffer.drain(..self.head);
            self.head = 0;
        }
        self.buffer.extend_from_slice(d);
    }

    /// The next whole frame, or None when more bytes are needed. Err: a length that can't be ours (close the connection).
    pub fn next_frame(&mut self) -> Result<Option<Vec<u8>>, BadLength> {
        let rest = &self.buffer[self.head..];
        if rest.len() < 4 {
            return Ok(None);
        }
        let n = u32::from_be_bytes([rest[0], rest[1], rest[2], rest[3]]) as usize;
        if n == 0 || n > self.limit {
            return Err(BadLength);
        }
        if rest.len() < 4 + n {
            return Ok(None);
        }
        let f = rest[4..4 + n].to_vec();
        self.head += 4 + n;
        if self.head == self.buffer.len() {
            self.buffer.clear();
            self.head = 0;
        }
        Ok(Some(f))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScrollPhase {
    Began = 1,
    Changed = 2,
    Ended = 3,
}

/// The pointer and scroll, one packet per display frame at most.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum PointerPacket {
    /// points on the host, after the phone's acceleration
    Move { dx: f32, dy: f32 },
    Scroll { dx: f32, dy: f32, phase: ScrollPhase },
    /// the fingers left with this speed (points/s): the host coasts on from there
    Fling { vx: f32, vy: f32 },
    Stop,
}

impl PointerPacket {
    pub fn encode(&self) -> Vec<u8> {
        let mut d = Vec::with_capacity(10);
        let f = |d: &mut Vec<u8>, v: f32| d.extend_from_slice(&v.to_le_bytes());
        match *self {
            PointerPacket::Move { dx, dy } => {
                d.push(0);
                f(&mut d, dx);
                f(&mut d, dy);
            }
            PointerPacket::Scroll { dx, dy, phase } => {
                d.push(1);
                d.push(phase as u8);
                f(&mut d, dx);
                f(&mut d, dy);
            }
            PointerPacket::Fling { vx, vy } => {
                d.push(2);
                f(&mut d, vx);
                f(&mut d, vy);
            }
            PointerPacket::Stop => d.push(3),
        }
        d
    }

    pub fn decode(b: &[u8]) -> Option<PointerPacket> {
        let f = |at: usize| -> Option<f32> {
            let v = f32::from_le_bytes(b.get(at..at + 4)?.try_into().ok()?);
            (v.is_finite() && v.abs() < 100_000.0).then_some(v)
        };
        Some(match *b.first()? {
            0 => PointerPacket::Move { dx: f(1)?, dy: f(5)? },
            1 => {
                let phase = match *b.get(1)? {
                    1 => ScrollPhase::Began,
                    2 => ScrollPhase::Changed,
                    3 => ScrollPhase::Ended,
                    _ => return None,
                };
                PointerPacket::Scroll { dx: f(2)?, dy: f(6)?, phase }
            }
            2 => PointerPacket::Fling { vx: f(1)?, vy: f(5)? },
            3 => PointerPacket::Stop,
            _ => return None,
        })
    }
}

/// The cursor's place: x, y as f32 LE, 0…1 of the source.
pub fn cursor(x: f32, y: f32) -> [u8; 8] {
    let mut d = [0u8; 8];
    d[..4].copy_from_slice(&x.to_le_bytes());
    d[4..].copy_from_slice(&y.to_le_bytes());
    d
}

/// One piece of an encoded frame: a 17-byte header, then up to `PAYLOAD` bytes.
#[derive(Clone, Debug, PartialEq)]
pub struct VideoPacket {
    pub frame: u32,
    pub index: u16,
    pub count: u16,
    pub keyframe: bool,
    /// when the host composed it, on the host's clock
    pub captured: f64,
    pub payload: Vec<u8>,
}

impl VideoPacket {
    pub const HEADER: usize = 17;
    pub const PAYLOAD: usize = 1180;

    pub fn encode(&self) -> Vec<u8> {
        let mut d = Vec::with_capacity(Self::HEADER + self.payload.len());
        d.extend_from_slice(&self.frame.to_be_bytes());
        d.extend_from_slice(&self.index.to_be_bytes());
        d.extend_from_slice(&self.count.to_be_bytes());
        d.push(self.keyframe as u8);
        d.extend_from_slice(&self.captured.to_bits().to_be_bytes());
        d.extend_from_slice(&self.payload);
        d
    }

    pub fn decode(d: &[u8]) -> Option<VideoPacket> {
        if d.len() < Self::HEADER {
            return None;
        }
        let p = VideoPacket {
            frame: u32::from_be_bytes(d[0..4].try_into().ok()?),
            index: u16::from_be_bytes(d[4..6].try_into().ok()?),
            count: u16::from_be_bytes(d[6..8].try_into().ok()?),
            keyframe: d[8] == 1,
            captured: f64::from_bits(u64::from_be_bytes(d[9..17].try_into().ok()?)),
            payload: d[17..].to_vec(),
        };
        (p.count > 0 && p.index < p.count).then_some(p)
    }

    /// One encoded frame, in pieces of `size`.
    pub fn split(data: &[u8], frame: u32, keyframe: bool, captured: f64, size: usize) -> Vec<VideoPacket> {
        let size = size.max(1);
        let count = data.len().div_ceil(size).max(1);
        (0..count)
            .map(|i| VideoPacket {
                frame,
                index: i as u16,
                count: count as u16,
                keyframe,
                captured,
                payload: data[(i * size).min(data.len())..((i + 1) * size).min(data.len())].to_vec(),
            })
            .collect()
    }
}

/// The part of the source a frame shows, then the keyframe's parameter sets (count, then each with a 2-byte length), then its picture.
pub fn pack_payload(crop: Crop, parameter_sets: &[Vec<u8>], picture: &[u8]) -> Vec<u8> {
    let mut d = Vec::with_capacity(17 + picture.len() + parameter_sets.iter().map(|p| p.len() + 2).sum::<usize>());
    for v in [crop.x, crop.y, crop.w, crop.h] {
        d.extend_from_slice(&v.to_le_bytes());
    }
    d.push(parameter_sets.len() as u8);
    for p in parameter_sets {
        d.push((p.len() >> 8) as u8);
        d.push((p.len() & 255) as u8);
        d.extend_from_slice(p);
    }
    d.extend_from_slice(picture);
    d
}

pub struct Payload {
    pub crop: Crop,
    pub parameter_sets: Vec<Vec<u8>>,
    pub picture: Vec<u8>,
}

pub fn unpack_payload(d: &[u8]) -> Option<Payload> {
    if d.len() < 17 {
        return None;
    }
    let f = |i: usize| f32::from_le_bytes(d[i..i + 4].try_into().unwrap());
    let crop = Crop { x: f(0), y: f(4), w: f(8), h: f(12) }.valid();
    let n = d[16];
    let mut at = 17;
    let mut sets = vec![];
    for _ in 0..n {
        let len = (*d.get(at)? as usize) << 8 | *d.get(at + 1)? as usize;
        at += 2;
        sets.push(d.get(at..at + len)?.to_vec());
        at += len;
    }
    Some(Payload { crop, parameter_sets: sets, picture: d[at..].to_vec() })
}

/// Pieces in, whole frames out, in order, and never a frame the decoder couldn't use (RemoteVideoAssembler; the test phone uses it).
#[derive(Default)]
pub struct VideoAssembler {
    current: Option<u32>,
    pieces: std::collections::HashMap<u16, Vec<u8>>,
    total: u16,
    key: bool,
    captured: f64,
    last_done: Option<u32>,
    last_complete: Option<u32>,
    noted: bool,
    started: bool,
    pub waiting_for_key: bool,
    pub dropped: usize,
}

#[derive(Debug, PartialEq)]
pub struct AssembledFrame {
    pub data: Vec<u8>,
    pub keyframe: bool,
    pub captured: f64,
    pub id: u32,
}

impl VideoAssembler {
    pub fn new() -> VideoAssembler {
        VideoAssembler { waiting_for_key: true, ..Default::default() }
    }

    pub fn add(&mut self, p: VideoPacket) -> Option<AssembledFrame> {
        if !self.started {
            self.started = true;
            self.waiting_for_key = true;
        }
        if self.last_done.is_some_and(|l| p.frame <= l) {
            return None;
        }
        if self.current != Some(p.frame) {
            if self.current.is_some_and(|c| p.frame < c) {
                return None;
            }
            if self.current.is_some() {
                self.dropped += 1;
                self.waiting_for_key = true;
                self.noted = true;
            }
            self.current = Some(p.frame);
            self.pieces.clear();
            self.total = p.count;
            self.key = p.keyframe;
            self.captured = p.captured;
        }
        self.pieces.insert(p.index, p.payload);
        if self.pieces.len() != self.total as usize {
            return None;
        }
        let mut data = vec![];
        for i in 0..self.total {
            data.extend_from_slice(self.pieces.get(&i).map(Vec::as_slice).unwrap_or(&[]));
        }
        self.last_done = Some(p.frame);
        self.current = None;
        self.pieces.clear();
        if self.last_complete.is_some_and(|prev| p.frame != prev.wrapping_add(1)) {
            self.waiting_for_key = true;
            if !self.noted {
                self.dropped += 1;
            }
        }
        self.noted = false;
        self.last_complete = Some(p.frame);
        if self.key {
            self.waiting_for_key = false;
        }
        (!self.waiting_for_key).then_some(AssembledFrame { data, keyframe: self.key, captured: self.captured, id: p.frame })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_split_across_reads_and_bad_lengths_close() {
        let mut r = FrameReader::default();
        let a = FrameReader::framed(b"hello");
        let b = FrameReader::framed(b"world!");
        let all = [a, b].concat();
        r.feed(&all[..3]);
        assert_eq!(r.next_frame(), Ok(None));
        r.feed(&all[3..12]);
        assert_eq!(r.next_frame(), Ok(Some(b"hello".to_vec())));
        assert_eq!(r.next_frame(), Ok(None));
        r.feed(&all[12..]);
        assert_eq!(r.next_frame(), Ok(Some(b"world!".to_vec())));
        let mut big = FrameReader::default();
        big.feed(&2000u32.to_be_bytes());
        assert_eq!(big.next_frame(), Err(BadLength), "a hello can't be 2 KB");
        big.limit = MAX_FRAME;
        assert_eq!(big.next_frame(), Ok(None));
        let mut zero = FrameReader::default();
        zero.feed(&[0, 0, 0, 0]);
        assert_eq!(zero.next_frame(), Err(BadLength));
    }

    #[test]
    fn a_lost_piece_waits_for_the_next_keyframe() {
        let mut a = VideoAssembler::new();
        let f = |id, key| VideoPacket::split(&[id as u8; 3000], id, key, 0.0, VideoPacket::PAYLOAD);
        for p in f(1, true) {
            if let Some(fr) = a.add(p) {
                assert_eq!(fr.id, 1);
            }
        }
        let mut two = f(2, false);
        two.pop();
        for p in two {
            assert!(a.add(p).is_none());
        }
        for p in f(3, false) {
            assert!(a.add(p).is_none(), "can't decode after a gap");
        }
        assert!(f(4, true).into_iter().filter_map(|p| a.add(p)).count() == 1);
        assert_eq!(a.dropped, 1);
    }

    #[test]
    fn pointer_packets_refuse_nonsense() {
        assert_eq!(PointerPacket::decode(&[9]), None);
        let mut bad = vec![0];
        bad.extend_from_slice(&f32::NAN.to_le_bytes());
        bad.extend_from_slice(&1f32.to_le_bytes());
        assert_eq!(PointerPacket::decode(&bad), None);
        assert_eq!(PointerPacket::decode(&[1, 7, 0, 0, 0, 0, 0, 0, 0, 0]), None, "no such phase");
    }
}
