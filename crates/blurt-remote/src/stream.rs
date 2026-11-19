//! The stream after the move (docs/design/remote-go-between.md §Moving the stream): once the direct UDP path works, each end
//! writes what it would have written to TCP or the go-between's WebSocket (length-prefixed, channel-0-sealed frames with their
//! implicit counters) into kind-7 datagrams, `u64 BE offset ∥ ≤ 1,100 bytes`, and the receiver acks with kind 8, `u64 BE next`.
//! Ordered and reliable, nothing more: no congestion control beyond a fixed window, since what goes this way is control and
//! audio (the picture stays plain datagrams).
//!
//! Both halves are plain state machines on a clock the caller gives (seconds as f64), so tests run on a fake one: they say which
//! chunks to send now; the caller seals and sends them, and calls `tick` when `deadline` comes.

use std::collections::{BTreeMap, VecDeque};

/// bytes after the offset field, at most
pub const CHUNK: usize = 1100;
/// unacknowledged bytes in flight, at most; and how far past `next` a receiver keeps what came early
pub const WINDOW: u64 = 256 * 1024;
pub const MIN_RTO: f64 = 0.2;
pub const MAX_RTO: f64 = 2.0;
/// chunks sent again on a timeout, from the acked offset
pub const RESEND: usize = 8;
/// acks at most this often, unless the packet filled a gap
pub const ACK_EVERY: f64 = 0.020;

/// A chunk to send: its offset and bytes.
pub type Chunk = (u64, Vec<u8>);

/// kind 7's body
pub fn encode_chunk(offset: u64, bytes: &[u8]) -> Vec<u8> {
    let mut b = Vec::with_capacity(8 + bytes.len());
    b.extend_from_slice(&offset.to_be_bytes());
    b.extend_from_slice(bytes);
    b
}

/// kind 7's body, read: None if it's too short or carries more than a chunk
pub fn decode_chunk(body: &[u8]) -> Option<(u64, &[u8])> {
    if body.len() < 8 || body.len() > 8 + CHUNK {
        return None;
    }
    Some((u64::from_be_bytes(body[..8].try_into().ok()?), &body[8..]))
}

/// kind 8's body
pub fn encode_ack(next: u64) -> Vec<u8> {
    next.to_be_bytes().to_vec()
}

pub fn decode_ack(body: &[u8]) -> Option<u64> {
    (body.len() == 8).then(|| u64::from_be_bytes(body.try_into().unwrap()))
}

/// The sending half.
#[derive(Debug)]
pub struct StreamOut {
    /// the first byte not acknowledged
    acked: u64,
    /// every byte from `acked` on: in flight, then queued
    buf: VecDeque<u8>,
    /// the end of what has been sent at least once
    sent: u64,
    srtt: Option<f64>,
    /// doubles on each timeout without progress; back to 1 on progress
    backoff: f64,
    /// when the retransmission timer started (progress, or the first byte in flight)
    since: f64,
    /// acks in a row with the same `next`
    same: u32,
    last_ack: u64,
    /// first sends not yet acked, (end, when): round-trip samples. A resent range's entries go (Karn).
    timing: VecDeque<(u64, f64)>,
    pub resent_chunks: u64,
    pub timeouts: u64,
}

impl Default for StreamOut {
    fn default() -> Self {
        StreamOut::new()
    }
}

impl StreamOut {
    pub fn new() -> StreamOut {
        StreamOut {
            acked: 0,
            buf: VecDeque::new(),
            sent: 0,
            srtt: None,
            backoff: 1.0,
            since: 0.0,
            same: 0,
            last_ack: 0,
            timing: VecDeque::new(),
            resent_chunks: 0,
            timeouts: 0,
        }
    }

    pub fn in_flight(&self) -> u64 {
        self.sent - self.acked
    }

    /// bytes written and not yet sent once
    pub fn queued(&self) -> usize {
        self.buf.len() - self.in_flight() as usize
    }

    pub fn acked(&self) -> u64 {
        self.acked
    }

    pub fn srtt(&self) -> Option<f64> {
        self.srtt
    }

    /// max(200 ms, 2 × smoothed RTT), doubled per timeout, at most 2 s
    pub fn rto(&self) -> f64 {
        let base = self.srtt.map_or(MIN_RTO, |r| (2.0 * r).max(MIN_RTO));
        (base * self.backoff).min(MAX_RTO)
    }

    /// When `tick` has work: the retransmission timer, while anything is in flight.
    pub fn deadline(&self) -> Option<f64> {
        (self.in_flight() > 0).then(|| self.since + self.rto())
    }

    fn bytes(&self, from: u64, n: usize) -> Vec<u8> {
        let at = (from - self.acked) as usize;
        self.buf.range(at..at + n).copied().collect()
    }

    /// New bytes from the queue while the window allows.
    fn fresh(&mut self, now: f64) -> Vec<Chunk> {
        let mut out = vec![];
        let end = self.acked + self.buf.len() as u64;
        while self.sent < end && self.in_flight() < WINDOW {
            let n = (end - self.sent).min(CHUNK as u64).min(WINDOW - self.in_flight()) as usize;
            if self.in_flight() == 0 {
                self.since = now;
            }
            let c = (self.sent, self.bytes(self.sent, n));
            self.sent += n as u64;
            self.timing.push_back((self.sent, now));
            out.push(c);
        }
        out
    }

    /// More of the stream: the chunks to send now (the rest waits for the window).
    pub fn write(&mut self, d: &[u8], now: f64) -> Vec<Chunk> {
        self.buf.extend(d);
        self.fresh(now)
    }

    /// An ack: what it frees, and the chunks to send now (new ones the window allows, or one sent again after three of the same).
    pub fn ack(&mut self, next: u64, now: f64) -> Vec<Chunk> {
        // past what was sent (a confused peer: it's sealed, so not forged), or an old one overtaken by a newer: nothing to do
        if next > self.sent || next < self.acked {
            return vec![];
        }
        let mut out = vec![];
        if next > self.acked {
            let n = (next - self.acked) as usize;
            self.buf.drain(..n);
            self.acked = next;
            self.backoff = 1.0;
            self.since = now;
            let mut sample = None;
            while self.timing.front().is_some_and(|(end, _)| *end <= next) {
                sample = self.timing.pop_front().map(|(_, at)| now - at);
            }
            if let Some(r) = sample {
                self.srtt = Some(match self.srtt {
                    Some(s) => 0.875 * s + 0.125 * r,
                    None => r,
                });
            }
            self.same = 1;
            self.last_ack = next;
        } else if next == self.last_ack {
            self.same += 1;
            if self.same >= 3 && self.in_flight() > 0 {
                self.same = 0;
                out.extend(self.resend(1));
            }
        } else {
            self.same = 1;
            self.last_ack = next;
        }
        out.extend(self.fresh(now));
        out
    }

    /// From the acked offset again, up to `chunks` chunks of what was sent.
    fn resend(&mut self, chunks: usize) -> Vec<Chunk> {
        let mut out = vec![];
        let mut at = self.acked;
        while at < self.sent && out.len() < chunks {
            let n = (self.sent - at).min(CHUNK as u64) as usize;
            out.push((at, self.bytes(at, n)));
            at += n as u64;
        }
        // nothing sent again times a round trip
        self.timing.retain(|(end, _)| *end > at);
        self.resent_chunks += out.len() as u64;
        out
    }

    /// The timer: no progress for an RTO sends again from the acked offset, up to 8 chunks, and the RTO doubles.
    pub fn tick(&mut self, now: f64) -> Vec<Chunk> {
        match self.deadline() {
            Some(d) if now >= d => {
                self.timeouts += 1;
                self.backoff = (self.backoff * 2.0).min(MAX_RTO / MIN_RTO);
                self.since = now;
                self.resend(RESEND)
            }
            _ => vec![],
        }
    }
}

/// The receiving half.
#[derive(Debug, Default)]
pub struct StreamIn {
    next: u64,
    /// what came early, by offset (may overlap; trimmed as `next` passes it)
    early: BTreeMap<u64, Vec<u8>>,
    early_bytes: usize,
    last_ack: Option<f64>,
    owed: bool,
}

/// What a packet did: bytes now in order, and an ack to send now.
#[derive(Debug, Default, PartialEq)]
pub struct Received {
    pub bytes: Vec<u8>,
    pub ack: Option<u64>,
}

impl StreamIn {
    pub fn new() -> StreamIn {
        StreamIn::default()
    }

    pub fn next(&self) -> u64 {
        self.next
    }

    /// When `tick` has an ack owed.
    pub fn deadline(&self) -> Option<f64> {
        self.owed.then(|| self.last_ack.map_or(0.0, |t| t + ACK_EVERY))
    }

    /// A kind-7 packet.
    pub fn receive(&mut self, offset: u64, d: &[u8], now: f64) -> Received {
        let had_early = !self.early.is_empty();
        let mut out = vec![];
        let end = offset + d.len() as u64;
        let limit = self.next + WINDOW;
        if end > self.next && offset < limit {
            // what's already had, and what's past the window, are dropped
            let from = offset.max(self.next);
            let to = end.min(limit);
            let part = &d[(from - offset) as usize..(to - offset) as usize];
            if from == self.next {
                out.extend_from_slice(part);
                self.next = to;
            } else {
                let longer = self.early.get(&from).is_none_or(|e| e.len() < part.len());
                if longer && self.early_bytes + part.len() <= 2 * WINDOW as usize {
                    if let Some(old) = self.early.insert(from, part.to_vec()) {
                        self.early_bytes -= old.len();
                    }
                    self.early_bytes += part.len();
                }
            }
            // what came early and now follows on
            while let Some((&at, _)) = self.early.first_key_value() {
                if at > self.next {
                    break;
                }
                let e = self.early.remove(&at).unwrap();
                self.early_bytes -= e.len();
                let e_end = at + e.len() as u64;
                if e_end > self.next {
                    out.extend_from_slice(&e[(self.next - at) as usize..]);
                    self.next = e_end;
                }
            }
        }
        let filled = had_early && !out.is_empty();
        let ack = if filled || self.last_ack.is_none_or(|t| now - t >= ACK_EVERY) {
            self.last_ack = Some(now);
            self.owed = false;
            Some(self.next)
        } else {
            self.owed = true;
            None
        };
        Received { bytes: out, ack }
    }

    /// The ack held back by the 20 ms rule, once it's due.
    pub fn tick(&mut self, now: f64) -> Option<u64> {
        match self.deadline() {
            Some(d) if now >= d => {
                self.owed = false;
                self.last_ack = Some(now);
                Some(self.next)
            }
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn data(n: usize) -> Vec<u8> {
        (0..n).map(|i| (i * 7 % 251) as u8).collect()
    }

    /// A made-up path between a sender and a receiver: packets each way with a delay, dropped or duplicated by a rule, on a fake
    /// clock stepped 1 ms at a time. Returns what the receiver got, in order, and the time it took.
    fn run(total: usize, delay: f64, mut lose: impl FnMut(u64, usize) -> bool, dup: bool, reorder: bool) -> (Vec<u8>, f64, StreamOut) {
        let src = data(total);
        let mut tx = StreamOut::new();
        let mut rx = StreamIn::new();
        let mut got = vec![];
        let mut wire: Vec<(f64, Chunk)> = vec![]; // to the receiver
        let mut acks: Vec<(f64, u64)> = vec![];
        let mut now = 0.0;
        let mut written = 0;
        let mut n = 0usize;
        let mut send = |c: Chunk, now: f64, wire: &mut Vec<(f64, Chunk)>, n: &mut usize| {
            *n += 1;
            if lose(c.0, *n) {
                return;
            }
            let extra = if reorder && (*n).is_multiple_of(3) { 0.004 } else { 0.0 };
            if dup {
                wire.push((now + delay + 0.001, c.clone()));
            }
            wire.push((now + delay + extra, c));
        };
        while got.len() < total && now < 120.0 {
            // the writer: 10 KB a millisecond until it's all written
            if written < total {
                let k = (total - written).min(10_000);
                for c in tx.write(&src[written..written + k], now) {
                    send(c, now, &mut wire, &mut n);
                }
                written += k;
            }
            wire.sort_by(|a, b| a.0.total_cmp(&b.0));
            while wire.first().is_some_and(|(t, _)| *t <= now) {
                let (_, (off, b)) = wire.remove(0);
                let r = rx.receive(off, &b, now);
                got.extend(r.bytes);
                if let Some(a) = r.ack {
                    acks.push((now + delay, a));
                }
            }
            if let Some(a) = rx.tick(now) {
                acks.push((now + delay, a));
            }
            while acks.first().is_some_and(|(t, _)| *t <= now) {
                let (_, a) = acks.remove(0);
                for c in tx.ack(a, now) {
                    send(c, now, &mut wire, &mut n);
                }
            }
            for c in tx.tick(now) {
                send(c, now, &mut wire, &mut n);
            }
            now += 0.001;
        }
        assert_eq!(got.len(), total, "everything arrived");
        assert_eq!(got, src, "in order, byte for byte");
        (got, now, tx)
    }

    #[test]
    fn chunks_and_acks_on_the_wire() {
        let b = encode_chunk(0x0102, b"abc");
        assert_eq!(b, [0, 0, 0, 0, 0, 0, 1, 2, b'a', b'b', b'c']);
        assert_eq!(decode_chunk(&b), Some((0x0102, &b"abc"[..])));
        assert_eq!(decode_chunk(&[0; 7]), None);
        assert_eq!(decode_chunk(&vec![0; 8 + CHUNK + 1]), None, "more than a chunk");
        assert_eq!(decode_ack(&encode_ack(77)), Some(77));
        assert_eq!(decode_ack(&[0; 9]), None);
    }

    #[test]
    fn a_clean_path_delivers_in_order() {
        let (_, t, tx) = run(300_000, 0.02, |_, _| false, false, false);
        assert_eq!(tx.resent_chunks, 0);
        assert!(t < 1.0, "{t}");
        let rtt = tx.srtt().unwrap();
        assert!((0.039..0.07).contains(&rtt), "{rtt}");
    }

    #[test]
    fn chunks_are_at_most_1100_bytes_and_the_window_is_256_kib() {
        let mut tx = StreamOut::new();
        let sent = tx.write(&data(400_000), 0.0);
        assert!(sent.iter().all(|(_, b)| b.len() <= CHUNK));
        assert_eq!(tx.in_flight(), WINDOW);
        assert_eq!(tx.queued(), 400_000 - WINDOW as usize);
        // the window full: more written waits
        assert!(tx.write(&data(10), 0.0).is_empty());
        // an ack frees room for as much again
        let more = tx.ack(11_000, 0.05);
        assert_eq!(more.iter().map(|c| c.1.len()).sum::<usize>(), 11_000);
        assert_eq!(more[0].0, WINDOW);
        assert_eq!(tx.in_flight(), WINDOW);
    }

    #[test]
    fn loss_is_repaired() {
        // every 10th packet lost the first time it goes
        let mut seen = std::collections::HashSet::new();
        run(200_000, 0.015, |off, n| n % 10 == 0 && seen.insert(off), false, false);
        // a burst: 30 in a row
        run(200_000, 0.015, |_, n| (50..80).contains(&n), false, false);
        // the last chunk lost: only the timer finds it
        let mut first = true;
        let (_, t, tx) = run(5_000, 0.01, |off, _| off == 4400 && std::mem::take(&mut first), false, false);
        assert!(tx.timeouts >= 1);
        assert!(t >= MIN_RTO, "{t}");
    }

    #[test]
    fn duplicates_and_reordering_change_nothing() {
        run(150_000, 0.01, |_, _| false, true, false);
        run(150_000, 0.01, |_, _| false, false, true);
        let mut seen = std::collections::HashSet::new();
        run(150_000, 0.01, |off, n| n % 7 == 0 && seen.insert(off), true, true);
    }

    #[test]
    fn the_receiver_takes_overlaps_and_keeps_early_bytes_within_the_window() {
        let src = data(5000);
        let mut rx = StreamIn::new();
        // early, then overlapping it, then the start
        assert!(rx.receive(2000, &src[2000..3000], 0.0).bytes.is_empty());
        assert!(rx.receive(1500, &src[1500..2500], 0.1).bytes.is_empty());
        let r = rx.receive(0, &src[0..1600], 0.2);
        assert_eq!(r.bytes, src[0..3000]);
        assert_eq!(r.ack, Some(3000));
        // already had: nothing new, still acked (once the 20 ms are up)
        let r = rx.receive(1000, &src[1000..2000], 0.3);
        assert!(r.bytes.is_empty());
        assert_eq!(r.ack, Some(3000));
        // past the window: dropped
        let far = rx.next() + WINDOW;
        rx.receive(far, &[1, 2, 3], 0.4);
        assert!(rx.early.is_empty());
    }

    #[test]
    fn acks_at_most_every_20_ms_unless_a_gap_is_filled() {
        let src = data(4400);
        let mut rx = StreamIn::new();
        assert_eq!(rx.receive(0, &src[0..1100], 0.0).ack, Some(1100));
        // 5 ms later: held back, owed
        assert_eq!(rx.receive(2200, &src[2200..3300], 0.005).ack, None);
        assert_eq!(rx.deadline(), Some(0.020));
        assert_eq!(rx.tick(0.010), None);
        // the gap filled: at once, whatever the time
        let r = rx.receive(1100, &src[1100..2200], 0.012);
        assert_eq!((r.bytes.len(), r.ack), (2200, Some(3300)));
        assert_eq!(rx.deadline(), None);
        assert_eq!(rx.receive(3300, &src[3300..4400], 0.015).ack, None);
        assert_eq!(rx.tick(0.032), Some(4400), "the owed one goes when its 20 ms are up");
        assert_eq!(rx.tick(0.1), None);
    }

    #[test]
    fn the_timer_backs_off_to_2_s_and_resends_8_chunks_from_the_acked_offset() {
        let mut tx = StreamOut::new();
        tx.write(&data(20 * CHUNK), 0.0);
        assert_eq!(tx.deadline(), Some(MIN_RTO));
        assert!(tx.tick(0.19).is_empty());
        let again = tx.tick(0.2);
        assert_eq!(again.len(), RESEND);
        assert_eq!(again[0].0, 0);
        assert_eq!(again[7].0, 7 * CHUNK as u64);
        let mut t = 0.2;
        let mut waits = vec![];
        for _ in 0..6 {
            let d = tx.deadline().unwrap();
            waits.push(((d - t) * 1000.0).round() as i64);
            t = d;
            assert_eq!(tx.tick(t).len(), RESEND);
        }
        assert_eq!(waits, [400, 800, 1600, 2000, 2000, 2000]);
        // progress: back to the base
        tx.ack(CHUNK as u64, t + 0.1);
        assert_eq!(tx.rto(), tx.srtt().map_or(MIN_RTO, |r| (2.0 * r).max(MIN_RTO)).min(MAX_RTO));
        assert!(tx.srtt().is_none(), "nothing sent once and acked: no sample (Karn)");
    }

    #[test]
    fn the_rto_follows_the_round_trip() {
        let mut tx = StreamOut::new();
        tx.write(&data(CHUNK), 0.0);
        tx.ack(CHUNK as u64, 0.3);
        assert_eq!(tx.srtt(), Some(0.3));
        assert!((tx.rto() - 0.6).abs() < 1e-9);
        tx.write(&data(CHUNK), 1.0);
        tx.ack(2 * CHUNK as u64, 1.1);
        assert!((tx.srtt().unwrap() - (0.875 * 0.3 + 0.125 * 0.1)).abs() < 1e-9);
    }

    #[test]
    fn three_acks_with_the_same_next_resend_one_chunk_at_once() {
        let mut tx = StreamOut::new();
        tx.write(&data(10 * CHUNK), 0.0);
        assert!(tx.ack(CHUNK as u64, 0.01).is_empty(), "progress");
        assert!(tx.ack(CHUNK as u64, 0.02).is_empty(), "two");
        let r = tx.ack(CHUNK as u64, 0.03);
        assert_eq!(r, vec![(CHUNK as u64, data(10 * CHUNK)[CHUNK..2 * CHUNK].to_vec())], "three: the missing one at once");
        assert!(tx.ack(CHUNK as u64, 0.04).is_empty(), "and the count starts again");
        assert!(tx.ack(CHUNK as u64, 0.05).is_empty());
        assert_eq!(tx.ack(CHUNK as u64, 0.06).len(), 1);
        // an old ack overtaken by a newer one changes nothing
        tx.ack(3 * CHUNK as u64, 0.07);
        assert!(tx.ack(CHUNK as u64, 0.08).is_empty());
        assert_eq!(tx.acked(), 3 * CHUNK as u64);
    }
}
