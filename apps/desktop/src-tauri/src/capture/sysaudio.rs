//! What the PC plays, recorded with a take (`record.system_audio`; the Mac's ScreenCaptureKit audio track —
//! docs/design/windows-parity/recording.md §8). Windows: WASAPI loopback, no driver to install — cpal opens it when an
//! input stream is built on an output device. Written to `<session>/system.pcm` (s16le mono at the device's rate) from
//! the wall-clock time in `system.json`, through pauses (record.py cuts each segment's stretch by its first frame's wall
//! clock and puts it in the video as the second audio track).

// Linux has no loopback here yet: the clock is used on Windows (and by the tests)
#![cfg_attr(not(windows), allow(dead_code))]

use std::fs::File;
use std::io::{self, BufWriter, Write};
use std::path::Path;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

/// Places what arrives on the take's wall clock: a byte offset in system.pcm / (2 × rate) = seconds since `t0`.
/// WASAPI loopback sends nothing while nothing plays; the gap is written as silence when sound comes again, and up to
/// the end when the take stops.
pub struct PcmClock {
    out: BufWriter<File>,
    t0: Instant,
    rate: u32,
    written: u64,
}

impl PcmClock {
    pub fn create(session: &Path, rate: u32) -> io::Result<Self> {
        let out = BufWriter::new(File::create(session.join("system.pcm"))?);
        let wall = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64());
        std::fs::write(session.join("system.json"), serde_json::json!({"t0": wall, "rate": rate}).to_string())?;
        Ok(Self { out, t0: Instant::now(), rate, written: 0 })
    }

    /// Samples (mono) that ended at `now`.
    pub fn push(&mut self, mono: &[i16], now: Instant) -> io::Result<()> {
        let end = (now.saturating_duration_since(self.t0).as_secs_f64() * self.rate as f64) as u64;
        let start = end.saturating_sub(mono.len() as u64);
        // a gap of more than 50 ms (nothing was playing): silence up to where these samples belong
        if start > self.written + u64::from(self.rate / 20) {
            self.silence(start - self.written)?;
        }
        let bytes: Vec<u8> = mono.iter().flat_map(|s| s.to_le_bytes()).collect();
        self.out.write_all(&bytes)?;
        self.written += mono.len() as u64;
        Ok(())
    }

    fn silence(&mut self, n: u64) -> io::Result<()> {
        let zeros = vec![0u8; 4096];
        let mut left = n * 2;
        while left > 0 {
            let k = left.min(zeros.len() as u64) as usize;
            self.out.write_all(&zeros[..k])?;
            left -= k as u64;
        }
        self.written += n;
        Ok(())
    }

    /// The take stopped at `now`: silence up to it, flushed.
    pub fn finish(mut self, now: Instant) -> io::Result<()> {
        let end = (now.saturating_duration_since(self.t0).as_secs_f64() * self.rate as f64) as u64;
        if end > self.written {
            self.silence(end - self.written)?;
        }
        self.out.flush()
    }
}

/// The loopback stream of a take: a thread owns it (cpal streams stay on the thread that made them) until `stop`.
#[cfg(windows)]
pub struct Loopback {
    stop: std::sync::mpsc::Sender<()>,
    done: std::sync::mpsc::Receiver<()>,
}

#[cfg(windows)]
impl Loopback {
    /// Starts recording the default output device into `session`; Err when there is none or it can't be opened.
    pub fn start(session: &Path) -> Result<Loopback, String> {
        use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
        use std::sync::{mpsc, Arc, Mutex};
        let (ok_tx, ok_rx) = mpsc::channel::<Result<(), String>>();
        let (stop, stop_rx) = mpsc::channel::<()>();
        let (done_tx, done) = mpsc::channel::<()>();
        let session = session.to_path_buf();
        std::thread::spawn(move || {
            let open = || -> Result<(cpal::Stream, Arc<Mutex<Option<PcmClock>>>), String> {
                let dev = cpal::default_host().default_output_device().ok_or("no output device")?;
                let cfg = dev.default_output_config().map_err(|e| e.to_string())?;
                let ch = cfg.channels().max(1) as usize;
                let clock = PcmClock::create(&session, cfg.sample_rate().0).map_err(|e| e.to_string())?;
                let clock = Arc::new(Mutex::new(Some(clock)));
                let stream_cfg: cpal::StreamConfig = cfg.clone().into();
                let err = |e| eprintln!("blurt: system audio: {e}");
                macro_rules! build {
                    ($t:ty, $conv:expr) => {{
                        let c = clock.clone();
                        // an input stream on an output device: cpal turns on AUDCLNT_STREAMFLAGS_LOOPBACK
                        dev.build_input_stream(
                            &stream_cfg,
                            move |data: &[$t], _| {
                                let now = Instant::now();
                                let mono: Vec<i16> = data
                                    .chunks(ch)
                                    .map(|f| {
                                        let v = f.iter().map(|&s| $conv(s)).sum::<f32>() / ch as f32;
                                        (v.clamp(-1.0, 1.0) * 32767.0) as i16
                                    })
                                    .collect();
                                if let Some(c) = c.lock().unwrap().as_mut() {
                                    let _ = c.push(&mono, now);
                                }
                            },
                            err,
                            None,
                        )
                    }};
                }
                let stream = match cfg.sample_format() {
                    cpal::SampleFormat::F32 => build!(f32, |s: f32| s),
                    cpal::SampleFormat::I16 => build!(i16, |s: i16| s as f32 / 32768.0),
                    cpal::SampleFormat::U16 => build!(u16, |s: u16| (s as f32 - 32768.0) / 32768.0),
                    cpal::SampleFormat::I32 => build!(i32, |s: i32| s as f32 / 2147483648.0),
                    f => return Err(format!("unsupported sample format {f:?}")),
                }
                .map_err(|e| e.to_string())?;
                stream.play().map_err(|e| e.to_string())?;
                Ok((stream, clock))
            };
            match open() {
                Ok((stream, clock)) => {
                    let _ = ok_tx.send(Ok(()));
                    let _ = stop_rx.recv();
                    drop(stream);
                    if let Some(c) = clock.lock().unwrap().take() {
                        let _ = c.finish(Instant::now());
                    }
                }
                Err(e) => {
                    let _ = ok_tx.send(Err(e));
                }
            }
            let _ = done_tx.send(());
        });
        ok_rx.recv_timeout(std::time::Duration::from_secs(3)).map_err(|_| "system audio did not start".to_string())??;
        Ok(Loopback { stop, done })
    }

    /// Stops and closes system.pcm (before record.py reads it: send this before `stop`).
    pub fn stop(self) {
        let _ = self.stop.send(());
        let _ = self.done.recv_timeout(std::time::Duration::from_secs(2));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn gaps_become_silence_on_the_wall_clock() {
        let d = tempfile::tempdir().unwrap();
        let mut c = PcmClock::create(d.path(), 1000).unwrap();
        let t0 = c.t0;
        c.push(&[1; 100], t0 + Duration::from_millis(100)).unwrap(); // 0–0.1 s
        c.push(&[2; 100], t0 + Duration::from_millis(500)).unwrap(); // nothing played 0.1–0.4 s
        c.finish(t0 + Duration::from_millis(800)).unwrap();
        let pcm = std::fs::read(d.path().join("system.pcm")).unwrap();
        assert_eq!(pcm.len(), 800 * 2, "0.8 s at 1 kHz");
        let at = |i: usize| i16::from_le_bytes([pcm[2 * i], pcm[2 * i + 1]]);
        assert_eq!((at(50), at(250), at(450), at(700)), (1, 0, 2, 0));
        let meta: serde_json::Value = serde_json::from_slice(&std::fs::read(d.path().join("system.json")).unwrap()).unwrap();
        assert_eq!(meta["rate"], 1000);
        assert!(meta["t0"].as_f64().unwrap() > 1.7e9);
    }
}
