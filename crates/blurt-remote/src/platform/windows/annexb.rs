//! Media Foundation's encoders write Annex B (start codes, parameter sets inline before a keyframe); the wire wants what
//! VideoToolbox gives the Mac: NAL units each behind a 4-byte big-endian length, and a keyframe's parameter sets apart
//! (host.rs `EncodedFrame`). Access unit delimiters and filler data are dropped: the phone's decoder doesn't need them, and a
//! CBR encoder's filler is bytes the network would carry for nothing.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Codec {
    H264,
    Hevc,
}

impl Codec {
    pub fn wire_name(self) -> &'static str {
        match self {
            Codec::H264 => "h264",
            Codec::Hevc => "hevc",
        }
    }

    pub fn nal_type(self, nal: &[u8]) -> u8 {
        match (self, nal.first()) {
            (_, None) => 0xFF,
            (Codec::H264, Some(b)) => b & 0x1F,
            (Codec::Hevc, Some(b)) => (b >> 1) & 0x3F,
        }
    }

    /// Where a parameter set goes in `parameter_sets` (VPS, SPS, PPS), or None for any other unit.
    fn parameter_rank(self, t: u8) -> Option<u8> {
        match (self, t) {
            (Codec::H264, 7) => Some(1),
            (Codec::H264, 8) => Some(2),
            (Codec::Hevc, 32) => Some(0),
            (Codec::Hevc, 33) => Some(1),
            (Codec::Hevc, 34) => Some(2),
            _ => None,
        }
    }

    /// A picture the decoder can start from.
    fn is_key(self, t: u8) -> bool {
        match self {
            Codec::H264 => t == 5,
            // IRAP: BLA, IDR, CRA (and the two reserved IRAP types)
            Codec::Hevc => (16..=23).contains(&t),
        }
    }

    /// Units with nothing for the phone: delimiters, end of sequence / stream, filler.
    fn is_dropped(self, t: u8) -> bool {
        match self {
            Codec::H264 => matches!(t, 9..=12),
            Codec::Hevc => matches!(t, 35..=38),
        }
    }

    /// A unit that's part of the picture (a slice), not a header or SEI.
    fn is_slice(self, t: u8) -> bool {
        match self {
            Codec::H264 => (1..=5).contains(&t),
            Codec::Hevc => t <= 31,
        }
    }
}

/// The NAL units of an Annex B byte stream, without start codes (3 or 4 bytes) or the zero bytes trailing a unit.
pub fn nal_units(stream: &[u8]) -> Vec<&[u8]> {
    let mut starts = Vec::new(); // (start code begins, unit begins)
    let mut i = 0;
    while i + 3 <= stream.len() {
        if stream[i] == 0 && stream[i + 1] == 0 && stream[i + 2] == 1 {
            starts.push((i, i + 3));
            i += 3;
        } else {
            i += 1;
        }
    }
    let mut out = Vec::with_capacity(starts.len());
    for (n, &(_, begin)) in starts.iter().enumerate() {
        let end = starts.get(n + 1).map_or(stream.len(), |&(code, _)| code);
        let mut unit = &stream[begin..end];
        // the leading zero of a 4-byte start code, and trailing_zero_8bits, belong to no unit
        while let Some((&0, rest)) = unit.split_last() {
            unit = rest;
        }
        if !unit.is_empty() {
            out.push(unit);
        }
    }
    out
}

/// One access unit, as the wire wants it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Split {
    /// the picture's units, each behind its length as 4 bytes big-endian
    pub picture: Vec<u8>,
    /// it holds a picture to start decoding from (IDR / IRAP)
    pub keyframe: bool,
    /// the parameter sets it carried, VPS, SPS, PPS order, bare units
    pub parameter_sets: Vec<Vec<u8>>,
    /// it has a slice at all (an encoder can hand over headers alone)
    pub has_picture: bool,
}

pub fn split(codec: Codec, stream: &[u8]) -> Split {
    let mut s = Split::default();
    let mut sets: Vec<(u8, &[u8])> = Vec::new();
    for unit in nal_units(stream) {
        let t = codec.nal_type(unit);
        if let Some(rank) = codec.parameter_rank(t) {
            if !sets.iter().any(|(_, u)| *u == unit) {
                sets.push((rank, unit));
            }
            continue;
        }
        if codec.is_dropped(t) {
            continue;
        }
        s.keyframe |= codec.is_key(t);
        s.has_picture |= codec.is_slice(t);
        s.picture.extend_from_slice(&(unit.len() as u32).to_be_bytes());
        s.picture.extend_from_slice(unit);
    }
    sets.sort_by_key(|(r, _)| *r); // stable: two SPS keep their order
    s.parameter_sets = sets.into_iter().map(|(_, u)| u.to_vec()).collect();
    s
}

/// Annex B again (for a file ffplay plays, examples/win_smoke.rs): the parameter sets, then the length-prefixed units.
pub fn to_annexb(parameter_sets: &[Vec<u8>], picture: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(picture.len() + 64);
    for p in parameter_sets {
        out.extend_from_slice(&[0, 0, 0, 1]);
        out.extend_from_slice(p);
    }
    let mut i = 0;
    while i + 4 <= picture.len() {
        let n = u32::from_be_bytes([picture[i], picture[i + 1], picture[i + 2], picture[i + 3]]) as usize;
        i += 4;
        let end = (i + n).min(picture.len());
        out.extend_from_slice(&[0, 0, 0, 1]);
        out.extend_from_slice(&picture[i..end]);
        i = end;
    }
    out
}

/// The parameter sets out of an MF_MT_MPEG_SEQUENCE_HEADER blob (Annex B, as Microsoft's encoders write it), for an encoder
/// that doesn't repeat them before every keyframe.
pub fn parameter_sets(codec: Codec, header: &[u8]) -> Vec<Vec<u8>> {
    split(codec, header).parameter_sets
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lens(picture: &[u8]) -> Vec<(u8, usize)> {
        let mut out = Vec::new();
        let mut i = 0;
        while i + 4 <= picture.len() {
            let n = u32::from_be_bytes(picture[i..i + 4].try_into().unwrap()) as usize;
            out.push((picture[i + 4], n));
            i += 4 + n;
        }
        assert_eq!(i, picture.len(), "lengths cover the picture exactly");
        out
    }

    #[test]
    fn splits_three_and_four_byte_start_codes() {
        let s = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 0, 1, 0x65, 9, 9, 0, 0];
        let units = nal_units(&s);
        assert_eq!(units, vec![&[0x67, 1, 2][..], &[0x68, 3][..], &[0x65, 9, 9][..]]);
    }

    #[test]
    fn keeps_emulation_prevented_bytes() {
        // 00 00 03 inside a unit is not a start code and stays as it is
        let s = [0, 0, 1, 0x41, 0, 0, 3, 1, 7];
        assert_eq!(nal_units(&s), vec![&[0x41, 0, 0, 3, 1, 7][..]]);
    }

    #[test]
    fn h264_keyframe_by_hand() {
        let s = [
            0, 0, 0, 1, 0x09, 0xF0, // AUD
            0, 0, 0, 1, 0x67, 0x42, 0xC0, 0x1E, // SPS
            0, 0, 0, 1, 0x68, 0xCE, 0x3C, 0x80, // PPS
            0, 0, 0, 1, 0x06, 0x05, 0x01, // SEI
            0, 0, 1, 0x65, 0x88, 0x84, // IDR
            0, 0, 1, 0x0C, 0xFF, 0xFF, // filler
        ];
        let sp = split(Codec::H264, &s);
        assert!(sp.keyframe && sp.has_picture);
        assert_eq!(sp.parameter_sets, vec![vec![0x67, 0x42, 0xC0, 0x1E], vec![0x68, 0xCE, 0x3C, 0x80]]);
        assert_eq!(lens(&sp.picture), vec![(0x06, 3), (0x65, 3)]);
        let back = to_annexb(&sp.parameter_sets, &sp.picture);
        assert_eq!(nal_units(&back).len(), 4);
    }

    #[test]
    fn h264_p_frame_has_no_sets() {
        let sp = split(Codec::H264, &[0, 0, 0, 1, 0x41, 0x9A, 0x02]);
        assert!(!sp.keyframe && sp.has_picture && sp.parameter_sets.is_empty());
        assert_eq!(sp.picture, vec![0, 0, 0, 3, 0x41, 0x9A, 0x02]);
    }

    #[test]
    fn hevc_types() {
        // VPS 32 (0x40), SPS 33 (0x42), PPS 34 (0x44), AUD 35 (0x46), IDR_W_RADL 19 (0x26), TRAIL_R 1 (0x02), CRA 21 (0x2A)
        let s = [
            0, 0, 0, 1, 0x46, 0x01, 0x50, // AUD
            0, 0, 0, 1, 0x44, 0x01, 0xC1, // PPS first: still goes last
            0, 0, 0, 1, 0x40, 0x01, 0x0C, // VPS
            0, 0, 0, 1, 0x42, 0x01, 0x01, // SPS
            0, 0, 0, 1, 0x26, 0x01, 0xAF, // IDR
        ];
        let sp = split(Codec::Hevc, &s);
        assert!(sp.keyframe);
        assert_eq!(sp.parameter_sets.iter().map(|p| p[0]).collect::<Vec<_>>(), vec![0x40, 0x42, 0x44]);
        assert_eq!(lens(&sp.picture), vec![(0x26, 3)]);
        assert!(!split(Codec::Hevc, &[0, 0, 1, 0x02, 0x01, 0xD0]).keyframe);
        assert!(split(Codec::Hevc, &[0, 0, 1, 0x2A, 0x01, 0xD0]).keyframe);
    }

    // Real bitstreams from ffmpeg (brew's, libx264 / libx265), generated by testdata/make-streams.sh: what an
    // encoder writes, and the file that ffprobe reads back after a round trip through the wire's form.
    const H264_STREAM: &[u8] = include_bytes!("testdata/screen.h264");
    const HEVC_STREAM: &[u8] = include_bytes!("testdata/screen.h265");

    /// Access units of a whole stream, cut at each AUD (the streams are made with them) the way the encoder hands them over.
    fn access_units(codec: Codec, stream: &[u8]) -> Vec<Vec<u8>> {
        let aud = match codec {
            Codec::H264 => 9,
            Codec::Hevc => 35,
        };
        let mut out: Vec<Vec<u8>> = Vec::new();
        for unit in nal_units(stream) {
            if codec.nal_type(unit) == aud || out.is_empty() {
                out.push(Vec::new());
            }
            let au = out.last_mut().unwrap();
            au.extend_from_slice(&[0, 0, 0, 1]);
            au.extend_from_slice(unit);
        }
        out
    }

    fn check_real(codec: Codec, stream: &[u8], sets: usize) {
        let aus = access_units(codec, stream);
        assert!(aus.len() >= 30, "{} access units", aus.len());
        let mut keys = 0;
        let mut total_units = 0;
        for (n, au) in aus.iter().enumerate() {
            let sp = split(codec, au);
            assert!(sp.has_picture, "unit {n} has a slice");
            if sp.keyframe {
                keys += 1;
                assert_eq!(sp.parameter_sets.len(), sets, "keyframe {n} carries its sets");
            } else {
                assert!(sp.parameter_sets.is_empty(), "frame {n} carries no sets");
            }
            for (t, len) in lens(&sp.picture) {
                let t = match codec {
                    Codec::H264 => t & 0x1F,
                    Codec::Hevc => (t >> 1) & 0x3F,
                };
                assert!(!codec.is_dropped(t) && codec.parameter_rank(t).is_none());
                assert!(len > 0);
                total_units += 1;
            }
            // and back to the same units, less the delimiter
            let back = to_annexb(&sp.parameter_sets, &sp.picture);
            let want: Vec<&[u8]> = nal_units(au).into_iter().filter(|u| !codec.is_dropped(codec.nal_type(u))).collect();
            let mut got = nal_units(&back);
            let mut want_sorted = want.clone();
            got.sort();
            want_sorted.sort();
            assert_eq!(got, want_sorted, "unit {n}");
        }
        assert!(keys >= 2, "the streams have a keyframe every 30 frames: {keys}");
        assert!(total_units >= aus.len());
    }

    #[test]
    fn real_h264_from_ffmpeg() {
        check_real(Codec::H264, H264_STREAM, 2);
        let sp = split(Codec::H264, &access_units(Codec::H264, H264_STREAM)[0]);
        // a High profile SPS (100) and its PPS
        assert_eq!(sp.parameter_sets[0][0] & 0x1F, 7);
        assert_eq!(sp.parameter_sets[0][1], 100);
        assert_eq!(sp.parameter_sets[1][0] & 0x1F, 8);
    }

    #[test]
    fn real_hevc_from_ffmpeg() {
        check_real(Codec::Hevc, HEVC_STREAM, 3);
    }

    /// The wire's form back to Annex B is what ffplay plays (written for the shell script to read back with ffprobe).
    #[test]
    fn round_trip_file_for_ffprobe() {
        for (codec, stream, name) in [(Codec::H264, H264_STREAM, "roundtrip.h264"), (Codec::Hevc, HEVC_STREAM, "roundtrip.h265")] {
            let mut sets = Vec::new();
            let mut out = Vec::new();
            for au in access_units(codec, stream) {
                let sp = split(codec, &au);
                if sp.keyframe {
                    sets = sp.parameter_sets.clone();
                }
                out.extend(to_annexb(if sp.keyframe { &sets } else { &[] }, &sp.picture));
            }
            assert!(!out.is_empty());
            if let Some(dir) = std::env::var_os("BLURT_REMOTE_ROUNDTRIP_DIR") {
                std::fs::write(std::path::Path::new(&dir).join(name), out).unwrap();
            }
        }
    }
}
