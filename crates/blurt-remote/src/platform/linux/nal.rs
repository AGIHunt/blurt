//! An encoder's access unit (Annex B: start codes, parameter sets in-band on keyframes, as h264parse / h265parse give it with
//! `config-interval=-1`) → what host.rs EncodedFrame carries: the picture's NAL units with 4-byte big-endian lengths, and on
//! keyframes the parameter sets as bare NAL units. Access unit delimiters and SEI are dropped: the phone's decoder needs
//! neither, and x264 writes ~600 bytes of its settings into the first SEI.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Codec {
    H264,
    Hevc,
}

impl Codec {
    pub fn from_name(s: &str) -> Codec {
        if s == "hevc" {
            Codec::Hevc
        } else {
            Codec::H264
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Codec::H264 => "h264",
            Codec::Hevc => "hevc",
        }
    }
}

enum Kind {
    ParameterSet,
    Drop,
    Key,
    Slice,
}

fn kind(codec: Codec, nal: &[u8]) -> Kind {
    let Some(&b) = nal.first() else { return Kind::Drop };
    match codec {
        Codec::H264 => match b & 0x1f {
            7 | 8 => Kind::ParameterSet, // SPS, PPS
            6 | 9 | 10 | 11 | 12 => Kind::Drop, // SEI, AUD, end of sequence / stream, filler
            5 => Kind::Key,             // IDR slice
            _ => Kind::Slice,
        },
        Codec::Hevc => match (b >> 1) & 0x3f {
            32..=34 => Kind::ParameterSet, // VPS, SPS, PPS
            35..=40 => Kind::Drop,         // AUD, EOS, EOB, filler, SEI prefix / suffix
            16..=23 => Kind::Key,          // IRAP: BLA, IDR, CRA
            _ => Kind::Slice,
        },
    }
}

/// The NAL units of an Annex B buffer, without start codes or trailing zero bytes.
pub fn split_annexb(data: &[u8]) -> Vec<&[u8]> {
    let mut out = vec![];
    let mut i = 0;
    let n = data.len();
    let mut start: Option<usize> = None;
    while i + 2 < n {
        if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
            if let Some(s) = start {
                out.push(&data[s..i]);
            }
            i += 3;
            start = Some(i);
        } else {
            i += 1;
        }
    }
    if let Some(s) = start {
        out.push(&data[s..]);
    }
    // a 4-byte start code's leading zero, and trailing_zero_8bits, end the NAL before them: a NAL never ends in 0x00
    out.into_iter()
        .map(|nal| {
            let mut e = nal.len();
            while e > 0 && nal[e - 1] == 0 {
                e -= 1;
            }
            &nal[..e]
        })
        .filter(|nal| !nal.is_empty())
        .collect()
}

/// One access unit, ready for host.rs.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Unit {
    pub picture: Vec<u8>,
    pub keyframe: bool,
    pub parameter_sets: Vec<Vec<u8>>,
}

/// Annex B → length-prefixed picture + parameter sets. `last_sets`: the parameter sets seen last, used for a keyframe that
/// came without them (and updated by one that has them). None: nothing to send (no slice in it).
pub fn to_unit(codec: Codec, annexb: &[u8], last_sets: &mut Vec<Vec<u8>>) -> Option<Unit> {
    let mut u = Unit::default();
    let mut sets = vec![];
    for nal in split_annexb(annexb) {
        match kind(codec, nal) {
            Kind::ParameterSet => sets.push(nal.to_vec()),
            Kind::Drop => {}
            k => {
                u.keyframe |= matches!(k, Kind::Key);
                u.picture.extend_from_slice(&(nal.len() as u32).to_be_bytes());
                u.picture.extend_from_slice(nal);
            }
        }
    }
    if u.picture.is_empty() {
        if !sets.is_empty() {
            *last_sets = sets;
        }
        return None;
    }
    if !sets.is_empty() {
        *last_sets = sets;
    }
    if u.keyframe {
        u.parameter_sets = last_sets.clone();
    }
    Some(u)
}

/// The length-prefixed form back to its NAL units (tests, and the smoke tool writing an .h264 file).
pub fn split_lengths(data: &[u8]) -> Option<Vec<&[u8]>> {
    let mut out = vec![];
    let mut i = 0;
    while i < data.len() {
        let len = u32::from_be_bytes(data.get(i..i + 4)?.try_into().ok()?) as usize;
        out.push(data.get(i + 4..i + 4 + len)?);
        i += 4 + len;
    }
    Some(out)
}

/// A unit as Annex B again, parameter sets first: what a file or ffmpeg reads.
pub fn annexb(u: &Unit) -> Vec<u8> {
    let mut out = vec![];
    for nal in u.parameter_sets.iter().map(|s| s.as_slice()).chain(split_lengths(&u.picture).unwrap_or_default()) {
        out.extend_from_slice(&[0, 0, 0, 1]);
        out.extend_from_slice(nal);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const SPS: &[u8] = &[0x67, 0x42, 0xc0, 0x1f, 0x8c];
    const PPS: &[u8] = &[0x68, 0xce, 0x3c, 0x80];
    const SEI: &[u8] = &[0x06, 0x05, 0x10, 0xaa];
    const AUD: &[u8] = &[0x09, 0xf0];
    const IDR: &[u8] = &[0x65, 0x88, 0x84, 0x00, 0x03, 0x01, 0x20];
    const P: &[u8] = &[0x41, 0x9a, 0x00, 0x00, 0x03, 0x00, 0x10];

    fn au(nals: &[&[u8]], four: bool) -> Vec<u8> {
        let mut v = vec![];
        for n in nals {
            v.extend_from_slice(if four { &[0, 0, 0, 1] } else { &[0, 0, 1] });
            v.extend_from_slice(n);
        }
        v
    }

    #[test]
    fn a_keyframe_carries_its_parameter_sets_and_lengths() {
        let mut last = vec![];
        let u = to_unit(Codec::H264, &au(&[AUD, SPS, PPS, SEI, IDR], true), &mut last).unwrap();
        assert!(u.keyframe);
        assert_eq!(u.parameter_sets, vec![SPS.to_vec(), PPS.to_vec()]);
        let mut want = (IDR.len() as u32).to_be_bytes().to_vec();
        want.extend_from_slice(IDR);
        assert_eq!(u.picture, want, "AUD and SEI dropped, no start codes, emulation prevention kept");
        assert_eq!(split_lengths(&u.picture).unwrap(), vec![IDR]);
    }

    #[test]
    fn a_p_frame_has_no_parameter_sets_and_several_slices_stay() {
        let mut last = vec![SPS.to_vec(), PPS.to_vec()];
        let u = to_unit(Codec::H264, &au(&[P, P], false), &mut last).unwrap();
        assert!(!u.keyframe);
        assert!(u.parameter_sets.is_empty());
        assert_eq!(split_lengths(&u.picture).unwrap(), vec![P, P]);
    }

    #[test]
    fn a_keyframe_without_in_band_sets_reuses_the_last() {
        let mut last = vec![SPS.to_vec(), PPS.to_vec()];
        let u = to_unit(Codec::H264, &au(&[IDR], true), &mut last).unwrap();
        assert_eq!(u.parameter_sets, vec![SPS.to_vec(), PPS.to_vec()]);
        assert_eq!(to_unit(Codec::H264, &au(&[SPS, PPS], true), &mut last), None, "no picture, nothing to send");
    }

    #[test]
    fn trailing_zeros_and_mixed_start_codes() {
        let mut data = vec![0, 0, 0, 1];
        data.extend_from_slice(SPS);
        data.extend_from_slice(&[0, 0]); // trailing_zero_8bits
        data.extend_from_slice(&[0, 0, 1]);
        data.extend_from_slice(IDR);
        assert_eq!(split_annexb(&data), vec![SPS, IDR]);
        assert!(split_annexb(&[0, 0, 0]).is_empty());
        assert!(split_annexb(&[]).is_empty());
    }

    #[test]
    fn hevc_types() {
        let vps: &[u8] = &[0x40, 0x01, 0x0c];
        let sps: &[u8] = &[0x42, 0x01, 0x01];
        let pps: &[u8] = &[0x44, 0x01, 0xc1];
        let sei: &[u8] = &[0x4e, 0x01, 0x05];
        let idr: &[u8] = &[0x26, 0x01, 0xaf]; // IDR_W_RADL (19)
        let trail: &[u8] = &[0x02, 0x01, 0xd0]; // TRAIL_R (1)
        let mut last = vec![];
        let u = to_unit(Codec::Hevc, &au(&[vps, sps, pps, sei, idr], true), &mut last).unwrap();
        assert!(u.keyframe);
        assert_eq!(u.parameter_sets, vec![vps.to_vec(), sps.to_vec(), pps.to_vec()]);
        let u = to_unit(Codec::Hevc, &au(&[trail], true), &mut last).unwrap();
        assert!(!u.keyframe && u.parameter_sets.is_empty());
    }

    #[test]
    fn back_to_annexb() {
        let mut last = vec![];
        let u = to_unit(Codec::H264, &au(&[SPS, PPS, IDR], false), &mut last).unwrap();
        assert_eq!(annexb(&u), au(&[SPS, PPS, IDR], true));
    }
}
