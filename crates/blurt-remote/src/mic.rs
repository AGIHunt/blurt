//! The phone's microphone as the source of a take (RemoteMicFeed in RemoteServer.swift): what dictation takes in place of this
//! computer's mic. The phone sends 16 kHz mono PCM16 LE pieces from the talk key's down; they may come before the take has started,
//! so the last second of them waits here until something attaches. Out go f32 frames of `FRAME` samples (dictation's 20 ms unit).

use std::sync::mpsc::Sender;
use std::sync::Mutex;

pub const RATE: usize = 16_000;
pub const FRAME: usize = 320;

#[derive(Default)]
struct Inner {
    /// frames waiting for a take (at most a second's worth)
    waiting: std::collections::VecDeque<Vec<f32>>,
    /// samples not yet a whole frame
    partial: Vec<f32>,
    sink: Option<Sender<Vec<f32>>>,
}

#[derive(Default)]
pub struct MicFeed {
    inner: Mutex<Inner>,
}

impl MicFeed {
    pub fn new() -> MicFeed {
        MicFeed::default()
    }

    pub fn receive(&self, pcm: &[u8]) {
        let mut g = self.inner.lock().unwrap();
        let i = &mut *g;
        for s in pcm.as_chunks::<2>().0 {
            i.partial.push(i16::from_le_bytes([s[0], s[1]]) as f32 / 32768.0);
            if i.partial.len() == FRAME {
                let f = std::mem::replace(&mut i.partial, Vec::with_capacity(FRAME));
                match &i.sink {
                    Some(tx) => {
                        if tx.send(f).is_err() {
                            i.sink = None; // the take is over
                        }
                    }
                    None => {
                        i.waiting.push_back(f);
                        while i.waiting.len() * FRAME > RATE {
                            i.waiting.pop_front();
                        }
                    }
                }
            }
        }
    }

    /// A take listens: what waited goes first, then everything as it comes, until `tx`'s receiver goes.
    pub fn attach(&self, tx: Sender<Vec<f32>>) {
        let mut i = self.inner.lock().unwrap();
        for f in i.waiting.drain(..) {
            let _ = tx.send(f);
        }
        i.sink = Some(tx);
    }

    pub fn detach(&self) {
        let mut i = self.inner.lock().unwrap();
        i.sink = None;
        i.waiting.clear();
        i.partial.clear();
    }

    pub fn attached(&self) -> bool {
        let i = self.inner.lock().unwrap();
        i.sink.is_some()
    }

    /// The end of the last take isn't the start of this one.
    pub fn clear(&self) {
        let mut i = self.inner.lock().unwrap();
        i.waiting.clear();
        i.partial.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pcm(n: usize, v: i16) -> Vec<u8> {
        (0..n).flat_map(|_| v.to_le_bytes()).collect()
    }

    #[test]
    fn a_second_waits_then_it_flows() {
        let m = MicFeed::new();
        m.receive(&pcm(RATE * 2, 100)); // two seconds before the take starts
        m.receive(&pcm(10, 200)); // a partial frame
        let (tx, rx) = std::sync::mpsc::channel();
        m.attach(tx);
        let held: Vec<Vec<f32>> = rx.try_iter().collect();
        assert_eq!(held.len(), RATE / FRAME, "the last second only");
        m.receive(&pcm(FRAME - 10, 200));
        let f = rx.try_recv().unwrap();
        assert_eq!(f.len(), FRAME);
        assert!((f[0] - 200.0 / 32768.0).abs() < 1e-6);
        drop(rx);
        m.receive(&pcm(FRAME, 1));
        assert!(!m.attached(), "the take went: detached by itself");
    }
}
