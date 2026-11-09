//! The mic for dictation (the Mac's MicEngine / NoteVoice): the default input device through cpal (WASAPI on
//! Windows), mixed to mono and brought to 16 kHz, handed on as 20 ms frames (320 samples) — the segmenter's unit
//! (segmenter.rs). Opened on the clean key-down, before the trigger decides, so the first syllable isn't lost.

use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

pub const SR: u32 = 16_000;
pub const FRAME: usize = 320;

pub struct Mic {
    stream: Option<cpal::Stream>,
    pub device: String,
    /// the test mic (BLURT_TEST_MIC_WAV) stops when this goes
    _stop: Option<std::sync::mpsc::Sender<()>>,
}

/// Linear resampling from the device's rate to 16 kHz, carried across callbacks.
struct Resampler {
    ratio: f64, // input samples per output sample
    pos: f64,
    last: f32,
    out: Vec<f32>,
}

impl Resampler {
    fn push(&mut self, mono: &[f32], tx: &Sender<Vec<f32>>) {
        for &x in mono {
            // emit every output sample whose position falls between the previous input sample and this one
            while self.pos <= 1.0 {
                let y = self.last + (x - self.last) * self.pos as f32;
                self.out.push(y);
                if self.out.len() == FRAME {
                    let _ = tx.send(std::mem::take(&mut self.out));
                    self.out.reserve(FRAME);
                }
                self.pos += self.ratio;
            }
            self.pos -= 1.0;
            self.last = x;
        }
    }
}

impl Mic {
    /// Start capturing; frames go to `tx` until the Mic is dropped.
    pub fn open(tx: Sender<Vec<f32>>) -> Result<Mic, String> {
        Self::open_named(tx, None)
    }

    /// `open` with the input device chosen by name (`record.dictation.mic`); one that isn't there any more (a headset
    /// unplugged): the system's default input.
    pub fn open_named(tx: Sender<Vec<f32>>, name: Option<&str>) -> Result<Mic, String> {
        if let Some(p) = std::env::var_os("BLURT_TEST_MIC_WAV").filter(|p| !p.is_empty()) {
            return Self::test_wav(std::path::PathBuf::from(p), tx);
        }
        let host = cpal::default_host();
        let chosen = name.and_then(|n| {
            host.input_devices().ok()?.find(|d| d.name().ok().as_deref() == Some(n))
        });
        let dev = match chosen {
            Some(d) => d,
            None => host.default_input_device().ok_or("no input device")?,
        };
        let name = dev.name().unwrap_or_default();
        let cfg = dev.default_input_config().map_err(|e| e.to_string())?;
        let ch = cfg.channels() as usize;
        let rate = cfg.sample_rate().0 as f64;
        let rs = Arc::new(Mutex::new(Resampler {
            ratio: rate / SR as f64,
            pos: 0.0,
            last: 0.0,
            out: Vec::with_capacity(FRAME),
        }));
        let err = |e| eprintln!("dictation mic: {e}");
        let stream_cfg: cpal::StreamConfig = cfg.clone().into();
        macro_rules! build {
            ($t:ty, $conv:expr) => {{
                let rs = rs.clone();
                let tx = tx.clone();
                dev.build_input_stream(
                    &stream_cfg,
                    move |data: &[$t], _| {
                        let mono: Vec<f32> = data
                            .chunks(ch)
                            .map(|f| f.iter().map(|&s| $conv(s)).sum::<f32>() / ch as f32)
                            .collect();
                        rs.lock().unwrap().push(&mono, &tx);
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
        Ok(Mic {
            stream: Some(stream),
            device: name,
            _stop: None,
        })
    }

    /// Blurt on the phone (remote.rs): the phone's microphone in this one's place, its 16 kHz pieces as frames, until the Mic
    /// is dropped. None: no phone connected.
    pub fn phone(tx: Sender<Vec<f32>>) -> Option<Mic> {
        let (device, stop) = crate::remote::phone_mic(tx, false)?;
        Some(Mic { stream: None, device, _stop: Some(stop) })
    }

    /// A voice note's mic: the phone's when a note started from it asked for that (remote.rs `voice_note`), else this one.
    pub fn for_note(tx: Sender<Vec<f32>>) -> Result<Mic, String> {
        if let Some((device, stop)) = crate::remote::phone_mic(tx.clone(), true) {
            return Ok(Mic { stream: None, device, _stop: Some(stop) });
        }
        Self::open(tx)
    }

    /// Tests (machines without a mic, the VM): a 16 kHz mono 16-bit wav played as the mic in real time, then silence,
    /// as the Mac's BLURT_TEST_MIC_WAV.
    fn test_wav(path: std::path::PathBuf, tx: Sender<Vec<f32>>) -> Result<Mic, String> {
        let bytes = std::fs::read(&path).map_err(|e| e.to_string())?;
        let data = bytes
            .windows(4)
            .position(|w| w == b"data")
            .ok_or("not a wav")?
            + 8;
        let samples: Vec<f32> = bytes[data..]
            .chunks_exact(2)
            .map(|b| i16::from_le_bytes([b[0], b[1]]) as f32 / 32768.0)
            .collect();
        let (stop_tx, stop_rx) = std::sync::mpsc::channel::<()>();
        std::thread::spawn(move || {
            let mut i = 0;
            let t0 = std::time::Instant::now();
            loop {
                if matches!(
                    stop_rx.try_recv(),
                    Err(std::sync::mpsc::TryRecvError::Disconnected)
                ) {
                    return;
                }
                let f: Vec<f32> = if i < samples.len() {
                    samples[i..(i + FRAME).min(samples.len())].to_vec()
                } else {
                    vec![0.0; FRAME]
                };
                let mut f = f;
                f.resize(FRAME, 0.0);
                i += FRAME;
                if tx.send(f).is_err() {
                    return;
                }
                let due = std::time::Duration::from_secs_f64(i as f64 / SR as f64);
                if let Some(w) = due.checked_sub(t0.elapsed()) {
                    std::thread::sleep(w);
                }
            }
        });
        Ok(Mic {
            stream: None,
            device: "test wav".into(),
            _stop: Some(stop_tx),
        })
    }
}

/// RMS level of a frame in 0…1 on a dB scale (−60 dB → 0), for the island's meter.
pub fn level(frame: &[f32]) -> f32 {
    if frame.is_empty() {
        return 0.0;
    }
    let rms = (frame.iter().map(|x| x * x).sum::<f32>() / frame.len() as f32).sqrt();
    let db = 20.0 * rms.max(1e-6).log10();
    ((db + 60.0) / 60.0).clamp(0.0, 1.0)
}

/// 16-bit mono 16 kHz WAV.
pub fn write_wav(path: &std::path::Path, samples: &[f32]) -> std::io::Result<()> {
    use std::io::Write;
    let n = samples.len() as u32;
    let mut f = std::io::BufWriter::new(std::fs::File::create(path)?);
    f.write_all(b"RIFF")?;
    f.write_all(&(36 + n * 2).to_le_bytes())?;
    f.write_all(b"WAVEfmt ")?;
    f.write_all(&16u32.to_le_bytes())?;
    f.write_all(&1u16.to_le_bytes())?;
    f.write_all(&1u16.to_le_bytes())?;
    f.write_all(&SR.to_le_bytes())?;
    f.write_all(&(SR * 2).to_le_bytes())?;
    f.write_all(&2u16.to_le_bytes())?;
    f.write_all(&16u16.to_le_bytes())?;
    f.write_all(b"data")?;
    f.write_all(&(n * 2).to_le_bytes())?;
    for &s in samples {
        f.write_all(&((s.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes())?;
    }
    f.flush()
}
