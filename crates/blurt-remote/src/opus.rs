//! Voice as Opus (frame kind 9) on Blurt's public relay: one packet per 20 ms of 16 kHz mono, about 32 kbps, in PCM's place (256 kbps)
//! there (docs/design/remote-go-between.md §What the devices do on this path). libopus itself, as Rust (`unsafe-libopus`, c2rust):
//! the same bitstream as the phones', and no C toolchain on any of this crate's targets.

use unsafe_libopus as unsafe_ffi;

/// 16 kHz mono, as kind 1.
pub const RATE: i32 = 16_000;
/// Samples in one packet: 20 ms.
pub const FRAME: usize = 320;
pub const BITRATE: i32 = 32_000;

/// Opus packets → 16 kHz mono PCM16 LE, as kind 1 carries it (mic.rs takes either).
pub struct Decoder {
    st: *mut unsafe_ffi::OpusDecoder,
}

// the state is plain memory owned by this value; it's only used under `&mut self`
unsafe impl Send for Decoder {}

impl Decoder {
    pub fn new() -> Option<Decoder> {
        let mut err = 0i32;
        let st = unsafe { unsafe_ffi::opus_decoder_create(RATE, 1, &mut err) };
        (!st.is_null() && err == unsafe_ffi::OPUS_OK).then_some(Decoder { st })
    }

    /// One packet → its samples as PCM16 LE bytes. None: not an Opus packet (dropped, as a damaged frame would be).
    pub fn decode(&mut self, packet: &[u8]) -> Option<Vec<u8>> {
        if packet.is_empty() || packet.len() > 1500 {
            return None;
        }
        // up to 120 ms in one packet, whatever the sender chose
        let mut pcm = vec![0i16; FRAME * 6];
        let n = unsafe { unsafe_ffi::opus_decode(self.st, packet.as_ptr(), packet.len() as i32, pcm.as_mut_ptr(), pcm.len() as i32, 0) };
        if n <= 0 {
            return None;
        }
        Some(pcm[..n as usize].iter().flat_map(|s| s.to_le_bytes()).collect())
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        unsafe { unsafe_ffi::opus_decoder_destroy(self.st) };
    }
}

/// 16 kHz mono PCM16 LE → Opus packets of 20 ms (the test phone's voice; a viewer that sends voice).
pub struct Encoder {
    st: *mut unsafe_ffi::OpusEncoder,
    partial: Vec<i16>,
}

unsafe impl Send for Encoder {}

impl Encoder {
    pub fn new() -> Option<Encoder> {
        let mut err = 0i32;
        let st = unsafe { unsafe_ffi::opus_encoder_create(RATE, 1, unsafe_ffi::OPUS_APPLICATION_VOIP, &mut err) };
        if st.is_null() || err != unsafe_ffi::OPUS_OK {
            return None;
        }
        unsafe { unsafe_ffi::opus_encoder_ctl!(st, unsafe_ffi::OPUS_SET_BITRATE_REQUEST, BITRATE) };
        Some(Encoder { st, partial: Vec::with_capacity(FRAME) })
    }

    /// PCM16 LE bytes in, whole 20 ms packets out (what's left waits for the next call).
    pub fn encode(&mut self, pcm: &[u8]) -> Vec<Vec<u8>> {
        let mut out = vec![];
        for s in pcm.chunks_exact(2) {
            self.partial.push(i16::from_le_bytes([s[0], s[1]]));
            if self.partial.len() == FRAME {
                let mut buf = vec![0u8; 400];
                let n = unsafe { unsafe_ffi::opus_encode(self.st, self.partial.as_ptr(), FRAME as i32, buf.as_mut_ptr(), buf.len() as i32) };
                self.partial.clear();
                if n > 0 {
                    buf.truncate(n as usize);
                    out.push(buf);
                }
            }
        }
        out
    }
}

impl Drop for Encoder {
    fn drop(&mut self) {
        unsafe { unsafe_ffi::opus_encoder_destroy(self.st) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_tone_goes_through_at_about_32_kbps() {
        // one second of 440 Hz
        let pcm: Vec<u8> = (0..RATE as usize)
            .flat_map(|i| (((i as f64 * 440.0 * std::f64::consts::TAU / RATE as f64).sin() * 8000.0) as i16).to_le_bytes())
            .collect();
        let mut e = Encoder::new().unwrap();
        let packets = e.encode(&pcm);
        assert_eq!(packets.len(), 50, "20 ms each");
        let bytes: usize = packets.iter().map(Vec::len).sum();
        assert!(bytes * 8 < 48_000, "{bytes} bytes a second");
        let mut d = Decoder::new().unwrap();
        let out: Vec<u8> = packets.iter().flat_map(|p| d.decode(p).unwrap()).collect();
        assert_eq!(out.len(), pcm.len());
        // the tone survives: energy in the second half about the input's
        let energy = |b: &[u8]| b.chunks_exact(2).map(|s| (i16::from_le_bytes([s[0], s[1]]) as f64).powi(2)).sum::<f64>() / (b.len() / 2) as f64;
        let (a, b) = (energy(&pcm[16000..]), energy(&out[16000..]));
        assert!(b > a * 0.5 && b < a * 1.5, "{a} vs {b}");
        assert_eq!(d.decode(&[]), None);
    }
}
