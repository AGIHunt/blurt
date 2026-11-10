//! Media Foundation's video encoders, set up as VideoToolbox is on the Mac: low latency (CODECAPI_AVLowLatencyMode: one frame in,
//! one out), no B-frames, CBR at `bitrate` with a one-second buffer, a GOP as long as the encoder takes (keyframes when asked:
//! CODECAPI_AVEncVideoForceKeyFrame), bitrate changed on the fly. BT.709 limited range, as the video processor writes it.
//!
//! * Hardware first (NVENC, Quick Sync, AMF, Qualcomm's: their MFTs are asynchronous and read the NV12 texture on the GPU through
//!   the DXGI device manager). HEVC when the phone asks for it first and such an encoder exists, else H.264.
//! * No hardware encoder: Microsoft's software H.264 encoder (synchronous, NV12 in memory), at a lower size (screen.rs).
//! * Output is Annex B; annexb.rs turns it into the wire's form. Encoders that hand over a frame later than they took it are
//!   handled: each output is matched to its input's tag in order.
//! * Recovery frames (docs/design/remote-realtime.md §2): where an H.264 encoder takes CODECAPI_AVEncVideoLTRBufferControl, two
//!   long-term reference slots (ltr.rs); a frame the phone gave up is answered with one that refers only to a slot the phone has
//!   acknowledged (CODECAPI_AVEncVideoUseLTRFrame) instead of a keyframe. Elsewhere a recovery is a keyframe. Measured on blurt-win
//!   (frames dropped, the rest decoded and compared with the stream without the drop): NVIDIA's H.264 MFT and Microsoft's software
//!   H.264 MFT recover bit-exact; NVIDIA's HEVC MFT takes the controls but its "recovery" frame still predicts from the short-term
//!   picture before it (the lost one), so HEVC gets no LTR. BLURT_REMOTE_LTR=0 turns it off, =hevc tries it on HEVC too.
//! * A still picture made sharp (sharpen.rs): none of these encoders honours a quantiser ceiling (`CODECAPI_AVEncVideoMaxQP` is
//!   accepted and ignored), so a step of the ladder is that one resend's rate raised instead (`boost`), where that was measured to
//!   work: NVIDIA's HEVC MFT. Elsewhere `caps_quantiser` is false and the server sends eight plain resends.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

use ::windows::core::{Interface, GUID};
use ::windows::Win32::Graphics::Direct3D11::{ID3D11Device, ID3D11Texture2D};
use ::windows::Win32::Media::MediaFoundation::*;
use ::windows::Win32::System::Com::{CoCreateInstance, CoTaskMemFree, CLSCTX_INPROC_SERVER};
use ::windows::Win32::System::Variant::VARIANT;

use super::annexb::Codec;
use super::ltr::{self, Ltr, Plan};
use crate::sharpen::NO_CEILING;

/// The rate a step's resend gets doubles every this many steps of the quantiser below 40 (`Encoder::boost_for`). Measured on NVIDIA
/// HEVC (remote-windows.md §2026-11-11): 6 (what a quantiser 6 finer costs) ends the ladder at 39 dB of 55; 3 at 45–50 dB, the
/// largest resend about 1.2 × 0.4 s of the rate at 2 Mbps; 2 at 48–53 dB but resends of 0.5 s and 5 s to finish at 700 kbps.
const BOOST_PER_DOUBLING: f64 = 3.0;

/// One encoded access unit (Annex B) and the tag its input carried.
pub struct Output<T> {
    pub annexb: Vec<u8>,
    pub keyframe: bool,
    pub tag: T,
    /// a recovery frame: it refers only to references the phone acknowledged
    pub refresh: bool,
    /// in an LTR slot: the number the phone's acknowledgement brings back
    pub reference: Option<u64>,
}

/// Each encoder's reference numbers are its own.
static GENERATION: AtomicU64 = AtomicU64::new(1);

struct SendCom<T>(T);
// Media Foundation's objects are free-threaded (MTA): the event generator is read on the pump thread only
unsafe impl<T> Send for SendCom<T> {}

pub struct Encoder<T> {
    mft: IMFTransform,
    api: Option<ICodecAPI>,
    pub codec: Codec,
    pub hardware: bool,
    pub name: String,
    events: Option<Receiver<u32>>,
    need_input: u32,
    provides_samples: bool,
    out_size: u32,
    width: u32,
    height: u32,
    /// the frame rate in the media type, and the one frames really come at (the rate control spends per frame by the first)
    type_fps: u32,
    fps: u32,
    bitrate: u32,
    tags: VecDeque<(T, Plan)>,
    /// parameter sets from the output type, for an encoder that doesn't repeat them before each keyframe
    pub header: Vec<u8>,
    /// long-term references, where the encoder took LTRBufferControl
    ltr: Option<Ltr>,
    ltr_taken: bool,
    /// the step the rate is raised for (`NO_CEILING`: none, the rate `set_rate` gave), and whether this encoder answers to it
    cap: u8,
    caps: bool,
    _manager: Option<IMFDXGIDeviceManager>,
}

fn attr_u64(hi: u32, lo: u32) -> u64 {
    ((hi as u64) << 32) | lo as u64
}

/// The encoders this PC has for NV12 → `codec`, hardware ones (best first, as Media Foundation sorts them).
pub fn hardware_encoders(codec: Codec) -> Vec<(String, IMFActivate)> {
    let sub = match codec {
        Codec::H264 => MFVideoFormat_H264,
        Codec::Hevc => MFVideoFormat_HEVC,
    };
    let input = MFT_REGISTER_TYPE_INFO { guidMajorType: MFMediaType_Video, guidSubtype: MFVideoFormat_NV12 };
    let output = MFT_REGISTER_TYPE_INFO { guidMajorType: MFMediaType_Video, guidSubtype: sub };
    let mut out = Vec::new();
    unsafe {
        let mut list: *mut Option<IMFActivate> = std::ptr::null_mut();
        let mut n = 0u32;
        if MFTEnumEx(
            MFT_CATEGORY_VIDEO_ENCODER,
            MFT_ENUM_FLAG(MFT_ENUM_FLAG_HARDWARE.0 | MFT_ENUM_FLAG_SORTANDFILTER.0),
            Some(&input),
            Some(&output),
            &mut list,
            &mut n,
        )
        .is_err()
            || list.is_null()
        {
            return out;
        }
        for i in 0..n as usize {
            if let Some(a) = (*list.add(i)).take() {
                out.push((friendly_name(&a), a));
            }
        }
        CoTaskMemFree(Some(list as *const _));
    }
    out
}

fn friendly_name(a: &IMFActivate) -> String {
    unsafe {
        let mut p = ::windows::core::PWSTR::null();
        let mut len = 0u32;
        if a.GetAllocatedString(&MFT_FRIENDLY_NAME_Attribute, &mut p, &mut len).is_ok() && !p.is_null() {
            let s = p.to_string().unwrap_or_default();
            CoTaskMemFree(Some(p.0 as *const _));
            return s;
        }
    }
    "?".into()
}

impl<T> Encoder<T> {
    /// The first hardware encoder for `codec` that takes these settings.
    pub fn hardware(device: &ID3D11Device, codec: Codec, w: u32, h: u32, fps: u32, bitrate: u32) -> Result<Encoder<T>, String> {
        let list = hardware_encoders(codec);
        if list.is_empty() {
            return Err(format!("no hardware {} encoder", codec.wire_name()));
        }
        let mut errors = Vec::new();
        for (name, a) in list {
            let mft: IMFTransform = match unsafe { a.ActivateObject() } {
                Ok(m) => m,
                Err(e) => {
                    errors.push(format!("{name}: {e}"));
                    continue;
                }
            };
            match Self::setup(mft, Some(device), codec, w, h, fps, bitrate, name.clone(), true) {
                Ok(e) => return Ok(e),
                Err(e) => {
                    let _ = unsafe { a.ShutdownObject() };
                    errors.push(format!("{name}: {e}"))
                }
            }
        }
        Err(errors.join("; "))
    }

    /// Microsoft's software H.264 encoder.
    pub fn software(w: u32, h: u32, fps: u32, bitrate: u32) -> Result<Encoder<T>, String> {
        let mft: IMFTransform =
            unsafe { CoCreateInstance(&CLSID_MSH264EncoderMFT, None, CLSCTX_INPROC_SERVER) }.map_err(|e| format!("H.264 encoder: {e}"))?;
        Self::setup(mft, None, Codec::H264, w, h, fps, bitrate, "Microsoft H.264 (software)".into(), false)
    }

    #[allow(clippy::too_many_arguments)]
    fn setup(
        mft: IMFTransform,
        device: Option<&ID3D11Device>,
        codec: Codec,
        w: u32,
        h: u32,
        fps: u32,
        bitrate: u32,
        name: String,
        hardware: bool,
    ) -> Result<Encoder<T>, String> {
        let e = |what: &str, err: ::windows::core::Error| format!("{what}: {err}");
        let fps = fps.clamp(1, 120);
        unsafe {
            let mut is_async = false;
            if let Ok(attrs) = mft.GetAttributes() {
                if attrs.GetUINT32(&MF_TRANSFORM_ASYNC).unwrap_or(0) != 0 {
                    attrs.SetUINT32(&MF_TRANSFORM_ASYNC_UNLOCK, 1).map_err(|x| e("unlock", x))?;
                    is_async = true;
                }
                let _ = attrs.SetUINT32(&MF_LOW_LATENCY, 1);
            }
            let mut manager = None;
            if let Some(d) = device {
                let mut token = 0u32;
                let mut m: Option<IMFDXGIDeviceManager> = None;
                MFCreateDXGIDeviceManager(&mut token, &mut m).map_err(|x| e("device manager", x))?;
                let m = m.ok_or("no device manager")?;
                m.ResetDevice(d, token).map_err(|x| e("ResetDevice", x))?;
                mft.ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, m.as_raw() as usize).map_err(|x| e("D3D manager", x))?;
                manager = Some(m);
            }
            let api: Option<ICodecAPI> = mft.cast().ok();
            let mut enc = Encoder {
                mft,
                api,
                codec,
                hardware,
                name,
                events: None,
                need_input: 0,
                provides_samples: false,
                out_size: 0,
                width: w,
                height: h,
                type_fps: fps,
                fps,
                bitrate,
                tags: VecDeque::new(),
                header: Vec::new(),
                ltr: None,
                ltr_taken: false,
                cap: NO_CEILING,
                caps: false,
                _manager: manager,
            };
            // some encoders take these only before the media types, some only after: both
            enc.configure();
            enc.set_types().map_err(|x| e("media types", x))?;
            enc.configure();
            if enc.ltr_taken {
                enc.ltr = Some(Ltr::new(GENERATION.fetch_add(1, Ordering::SeqCst)));
            }
            enc.caps = enc.boosts();
            let info = enc.mft.GetOutputStreamInfo(0).map_err(|x| e("stream info", x))?;
            enc.provides_samples = info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 as u32 != 0;
            enc.out_size = info.cbSize.max(w * h * 3 / 2).max(1 << 16);
            if let Ok(t) = enc.mft.GetOutputCurrentType(0) {
                enc.header = blob(&t, &MF_MT_MPEG_SEQUENCE_HEADER);
            }
            enc.mft.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0).map_err(|x| e("begin streaming", x))?;
            enc.mft.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0).map_err(|x| e("start of stream", x))?;
            if is_async {
                let gen: IMFMediaEventGenerator = enc.mft.cast().map_err(|x| e("events", x))?;
                let (tx, rx) = channel();
                let gen = SendCom(gen);
                std::thread::Builder::new()
                    .name("blurt-remote-mft-events".into())
                    .spawn(move || {
                        let gen = gen;
                        let _ = ::windows::Win32::System::Com::CoInitializeEx(None, ::windows::Win32::System::Com::COINIT_MULTITHREADED);
                        // blocks until the next event; ends when the encoder is shut down
                        while let Ok(ev) = gen.0.GetEvent(MEDIA_EVENT_GENERATOR_GET_EVENT_FLAGS(0)) {
                            let t = ev.GetType().unwrap_or(0);
                            if tx.send(t).is_err() {
                                break;
                            }
                        }
                    })
                    .map_err(|x| x.to_string())?;
                enc.events = Some(rx);
            }
            Ok(enc)
        }
    }

    fn set_types(&mut self) -> ::windows::core::Result<()> {
        unsafe {
            let sub = match self.codec {
                Codec::H264 => MFVideoFormat_H264,
                Codec::Hevc => MFVideoFormat_HEVC,
            };
            let colour = |t: &IMFMediaType| {
                let _ = t.SetUINT32(&MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709.0 as u32);
                let _ = t.SetUINT32(&MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235.0 as u32);
                let _ = t.SetUINT32(&MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709.0 as u32);
                let _ = t.SetUINT32(&MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_709.0 as u32);
            };
            let out = MFCreateMediaType()?;
            out.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            out.SetGUID(&MF_MT_SUBTYPE, &sub)?;
            out.SetUINT32(&MF_MT_AVG_BITRATE, self.bitrate)?;
            out.SetUINT64(&MF_MT_FRAME_SIZE, attr_u64(self.width, self.height))?;
            out.SetUINT64(&MF_MT_FRAME_RATE, attr_u64(self.type_fps, 1))?;
            out.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, attr_u64(1, 1))?;
            out.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
            // High for H.264: its 8×8 transform keeps small text sharper at the same rate; HEVC Main
            let profile = match self.codec {
                Codec::H264 => eAVEncH264VProfile_High.0 as u32,
                Codec::Hevc => eAVEncH265VProfile_Main_420_8.0 as u32,
            };
            out.SetUINT32(&MF_MT_MPEG2_PROFILE, profile)?;
            colour(&out);
            if self.mft.SetOutputType(0, &out, 0).is_err() {
                // an encoder without High: its default
                out.DeleteItem(&MF_MT_MPEG2_PROFILE)?;
                self.mft.SetOutputType(0, &out, 0)?;
            }
            let inp = MFCreateMediaType()?;
            inp.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            inp.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_NV12)?;
            inp.SetUINT64(&MF_MT_FRAME_SIZE, attr_u64(self.width, self.height))?;
            inp.SetUINT64(&MF_MT_FRAME_RATE, attr_u64(self.type_fps, 1))?;
            inp.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, attr_u64(1, 1))?;
            inp.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
            colour(&inp);
            self.mft.SetInputType(0, &inp, 0)?;
        }
        Ok(())
    }

    fn set(&self, what: &GUID, v: VARIANT) -> bool {
        self.api.as_ref().is_some_and(|a| unsafe { a.SetValue(what, &v) }.is_ok())
    }

    fn supports(&self, what: &GUID) -> bool {
        self.api.as_ref().is_some_and(|a| unsafe { a.IsSupported(what) }.is_ok())
    }

    /// Whether `sharpen` makes this encoder spend what a finer quantiser takes (`Screen::caps_quantiser`).
    pub fn caps_quantiser(&self) -> bool {
        self.caps
    }

    /// Where raising one resend's rate makes it sharper. Measured on blurt-win-sharpen (docs/design/remote-windows.md §2026-11-11):
    /// NVIDIA's HEVC MFT, yes; NVIDIA's H.264 MFT and Microsoft's software H.264 MFT, no (their resends stay ~1 KB whatever the
    /// rate). None of the three honours `CODECAPI_AVEncVideoMaxQP` (accepted, ignored: CBR or VBR, set before streaming or during
    /// it, min = max, `CODECAPI_AVEncVideoEncodeQP`, `MFSampleExtension_VideoEncodeQP`), so it isn't used. Other MFTs (Quick Sync,
    /// AMF): untested, so no. BLURT_REMOTE_SHARPEN=1 / 0 forces it on / off (measuring).
    fn boosts(&self) -> bool {
        match std::env::var("BLURT_REMOTE_SHARPEN").as_deref() {
            Ok("1") => true,
            Ok("0") => false,
            _ => self.hardware && self.codec == Codec::Hevc && self.name.contains("NVIDIA"),
        }
    }

    /// How many times the rate one resend gets, for a step down to `max_qp`: ×2 at the ladder's first step (40), doubling every
    /// `BOOST_PER_DOUBLING` below it (×128 at 22). The encoder's rate control still decides; `Sharpen` paces what comes out.
    pub fn boost_for(max_qp: u8) -> f64 {
        if max_qp >= NO_CEILING {
            return 1.0;
        }
        2f64.powf(1.0 + (40.0 - max_qp as f64) / BOOST_PER_DOUBLING).clamp(1.0, 256.0)
    }

    /// The rate for the frames from now on: raised for a step of the ladder, or back to what `set_rate` last gave (`NO_CEILING`).
    /// Set only when it changes: once a step, and once when the picture moves again.
    fn boost(&mut self, max_qp: u8) {
        let max_qp = max_qp.min(NO_CEILING);
        if !self.caps || max_qp == self.cap {
            return;
        }
        self.cap = max_qp;
        if max_qp == NO_CEILING {
            self.apply_rate();
            return;
        }
        let mean = (self.mean() as f64 * Self::boost_for(max_qp)).min(u32::MAX as f64 / 4.0) as u32;
        self.set(&CODECAPI_AVEncCommonMeanBitRate, VARIANT::from(mean));
        self.set(&CODECAPI_AVEncCommonBufferSize, VARIANT::from(mean));
        self.set(&CODECAPI_AVEncCommonMaxBitRate, VARIANT::from(mean.saturating_mul(2)));
    }

    /// Recovery frames from long-term references (else a recovery is a keyframe).
    pub fn has_ltr(&self) -> bool {
        self.ltr.is_some()
    }

    /// The phone decoded the frames that carried these references.
    pub fn acknowledged(&mut self, refs: &[u64]) {
        if let Some(l) = &mut self.ltr {
            l.acknowledged(refs);
        }
    }

    /// Low latency, no B-frames, CBR, a long GOP, one slice, speed over the last bit of quality.
    fn configure(&mut self) {
        self.set(&CODECAPI_AVLowLatencyMode, VARIANT::from(true));
        self.set(&CODECAPI_AVEncMPVDefaultBPictureCount, VARIANT::from(0u32));
        self.set(&CODECAPI_AVEncCommonRateControlMode, VARIANT::from(eAVEncCommonRateControlMode_CBR.0 as u32));
        // a keyframe only when asked: the longest GOP the encoder takes
        if !self.set(&CODECAPI_AVEncMPVGOPSize, VARIANT::from(1_000_000u32)) {
            self.set(&CODECAPI_AVEncMPVGOPSize, VARIANT::from(self.type_fps * 600));
        }
        // 0 fastest … 100 best; real-time screen text: a little better than the fastest
        self.set(&CODECAPI_AVEncCommonQualityVsSpeed, VARIANT::from(33u32));
        // two long-term reference slots, for recovery frames (static: before streaming)
        let ltr = std::env::var("BLURT_REMOTE_LTR").unwrap_or_default();
        let codec_ok = self.codec == Codec::H264 || ltr == "hevc";
        if ltr != "0" && codec_ok && self.supports(&CODECAPI_AVEncVideoLTRBufferControl) {
            self.ltr_taken |= self.set(&CODECAPI_AVEncVideoLTRBufferControl, VARIANT::from(ltr::BUFFER_CONTROL));
        }
        // one slice a frame (mode 2: slices per frame)
        if self.set(&CODECAPI_AVEncSliceControlMode, VARIANT::from(2u32)) {
            self.set(&CODECAPI_AVEncSliceControlSize, VARIANT::from(1u32));
        }
        self.apply_rate();
    }

    /// The rate control spends the media type's frame rate's share a frame: when frames come slower (`fps` below it), the mean is
    /// scaled up so each frame still gets bitrate ÷ fps, as VideoToolbox does by timestamps.
    fn mean(&self) -> u32 {
        let k = (self.type_fps as f64 / self.fps.max(1) as f64).clamp(1.0, 8.0);
        ((self.bitrate as f64 * k) as u64).min(u32::MAX as u64 / 2) as u32
    }

    fn apply_rate(&mut self) {
        let mean = self.mean();
        self.set(&CODECAPI_AVEncCommonMeanBitRate, VARIANT::from(mean));
        // a one-second buffer, the Mac's DataRateLimits window: a keyframe can be large, a second can't go far over
        self.set(&CODECAPI_AVEncCommonBufferSize, VARIANT::from(mean));
        self.set(&CODECAPI_AVEncCommonMaxBitRate, VARIANT::from(mean.saturating_mul(2)));
    }

    pub fn set_rate(&mut self, bitrate: u32, fps: u32) {
        self.bitrate = bitrate.max(50_000);
        self.fps = fps.clamp(1, 120);
        self.apply_rate();
        // a step's raised rate is gone with it: the next one raises it from this rate
        self.cap = NO_CEILING;
    }

    /// The next input becomes a keyframe.
    fn force_key(&self) {
        self.set(&CODECAPI_AVEncVideoForceKeyFrame, VARIANT::from(1u32));
    }

    fn sample(&self, buffer: &IMFMediaBuffer, time: i64) -> ::windows::core::Result<IMFSample> {
        unsafe {
            let s = MFCreateSample()?;
            s.AddBuffer(buffer)?;
            s.SetSampleTime(time)?;
            s.SetSampleDuration(10_000_000 / self.fps.max(1) as i64)?;
            Ok(s)
        }
    }

    /// Encode an NV12 texture (hardware). `time`: 100-ns units, increasing. `recover`: a recovery frame (or a keyframe). `max_qp`:
    /// the coarsest quantiser this frame may use (a still picture being sharpened), `NO_CEILING` for the rate control's own.
    pub fn encode_texture(&mut self, nv12: &ID3D11Texture2D, time: i64, keyframe: bool, recover: bool, max_qp: u8, tag: T) -> Result<Vec<Output<T>>, String> {
        let buffer = unsafe { MFCreateDXGISurfaceBuffer(&ID3D11Texture2D::IID, nv12, 0, false) }.map_err(|e| format!("surface buffer: {e}"))?;
        let s = self.sample(&buffer, time).map_err(|e| e.to_string())?;
        self.encode(s, keyframe, recover, max_qp, tag)
    }

    /// Encode NV12 in memory, rows packed (software).
    pub fn encode_memory(&mut self, nv12: &[u8], time: i64, keyframe: bool, recover: bool, max_qp: u8, tag: T) -> Result<Vec<Output<T>>, String> {
        let s = unsafe {
            let b = MFCreateMemoryBuffer(nv12.len() as u32).map_err(|e| e.to_string())?;
            let mut p = std::ptr::null_mut();
            b.Lock(&mut p, None, None).map_err(|e| e.to_string())?;
            std::ptr::copy_nonoverlapping(nv12.as_ptr(), p, nv12.len());
            let _ = b.Unlock();
            b.SetCurrentLength(nv12.len() as u32).map_err(|e| e.to_string())?;
            self.sample(&b, time).map_err(|e| e.to_string())?
        };
        self.encode(s, keyframe, recover, max_qp, tag)
    }

    fn encode(&mut self, sample: IMFSample, keyframe: bool, recover: bool, max_qp: u8, tag: T) -> Result<Vec<Output<T>>, String> {
        let mut outs = Vec::new();
        let plan = match &mut self.ltr {
            Some(l) => l.plan(keyframe, recover),
            None => Plan { keyframe: keyframe || recover, use_slots: 0, mark: None },
        };
        // a keyframe or a recovery frame is never sharpened
        let max_qp = if plan.keyframe || plan.use_slots != 0 { NO_CEILING } else { max_qp };
        self.boost(max_qp);
        if plan.keyframe {
            self.force_key();
            let _ = unsafe { sample.SetUINT32(&MFSampleExtension_VideoEncodePictureType, 1) };
        }
        if plan.use_slots != 0 {
            self.set(&CODECAPI_AVEncVideoUseLTRFrame, VARIANT::from(ltr::use_value(plan.use_slots)));
        }
        if let Some((slot, _)) = plan.mark {
            self.set(&CODECAPI_AVEncVideoMarkLTRFrame, VARIANT::from(slot as u32));
        }
        if self.events.is_some() {
            // asynchronous: wait to be asked for input, then for the output
            let deadline = Instant::now() + Duration::from_millis(500);
            while self.need_input == 0 {
                if !self.pump(deadline, &mut outs)? {
                    return Err("the encoder stopped asking for frames".into());
                }
            }
            unsafe { self.mft.ProcessInput(0, &sample, 0) }.map_err(|e| format!("ProcessInput: {e}"))?;
            self.need_input -= 1;
            self.tags.push_back((tag, plan));
            // low latency: the output follows at once; one that comes later is matched up then
            let deadline = Instant::now() + Duration::from_millis(100);
            let before = outs.len();
            while outs.len() == before {
                if !self.pump(deadline, &mut outs)? {
                    break;
                }
            }
        } else {
            unsafe { self.mft.ProcessInput(0, &sample, 0) }.map_err(|e| format!("ProcessInput: {e}"))?;
            self.tags.push_back((tag, plan));
            while let Some(o) = self.pull()? {
                outs.push(o);
            }
        }
        Ok(outs)
    }

    /// One event from the asynchronous encoder, until `deadline`. false: none came in time.
    fn pump(&mut self, deadline: Instant, outs: &mut Vec<Output<T>>) -> Result<bool, String> {
        let left = deadline.saturating_duration_since(Instant::now());
        let ev = match self.events.as_ref().unwrap().recv_timeout(left) {
            Ok(t) => t,
            Err(RecvTimeoutError::Timeout) => return Ok(false),
            Err(RecvTimeoutError::Disconnected) => return Err("the encoder's events ended".into()),
        };
        if ev == METransformNeedInput.0 as u32 {
            self.need_input += 1;
        } else if ev == METransformHaveOutput.0 as u32 {
            if let Some(o) = self.pull()? {
                outs.push(o);
            }
        }
        Ok(true)
    }

    /// ProcessOutput once. None: it needs more input.
    fn pull(&mut self) -> Result<Option<Output<T>>, String> {
        loop {
            let mine = if self.provides_samples {
                None
            } else {
                unsafe {
                    let b = MFCreateMemoryBuffer(self.out_size).map_err(|e| e.to_string())?;
                    let s = MFCreateSample().map_err(|e| e.to_string())?;
                    s.AddBuffer(&b).map_err(|e| e.to_string())?;
                    Some(s)
                }
            };
            let mut buf = [MFT_OUTPUT_DATA_BUFFER {
                dwStreamID: 0,
                pSample: std::mem::ManuallyDrop::new(mine),
                dwStatus: 0,
                pEvents: std::mem::ManuallyDrop::new(None),
            }];
            let mut status = 0u32;
            let r = unsafe { self.mft.ProcessOutput(0, &mut buf, &mut status) };
            let [mut b] = buf;
            let sample = unsafe { std::mem::ManuallyDrop::take(&mut b.pSample) };
            unsafe { std::mem::ManuallyDrop::drop(&mut b.pEvents) };
            match r {
                Ok(()) => {}
                Err(e) if e.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => return Ok(None),
                Err(e) if e.code() == MF_E_TRANSFORM_STREAM_CHANGE => {
                    // the encoder settled its output type (some do before the first frame): take it and go again
                    unsafe {
                        let t = self.mft.GetOutputAvailableType(0, 0).map_err(|e| e.to_string())?;
                        self.mft.SetOutputType(0, &t, 0).map_err(|e| e.to_string())?;
                        self.header = blob(&t, &MF_MT_MPEG_SEQUENCE_HEADER);
                    }
                    continue;
                }
                Err(e) => return Err(format!("ProcessOutput: {e}")),
            }
            let Some(sample) = sample else { return Ok(None) };
            let (annexb, keyframe, info) = unsafe {
                let b = sample.ConvertToContiguousBuffer().map_err(|e| e.to_string())?;
                let mut p = std::ptr::null_mut();
                let mut len = 0u32;
                b.Lock(&mut p, None, Some(&mut len)).map_err(|e| e.to_string())?;
                let v = std::slice::from_raw_parts(p, len as usize).to_vec();
                let _ = b.Unlock();
                (
                    v,
                    sample.GetUINT32(&MFSampleExtension_CleanPoint).unwrap_or(0) != 0,
                    sample.GetUINT32(&MFSampleExtension_LongTermReferenceFrameInfo).ok(),
                )
            };
            let Some((tag, plan)) = self.tags.pop_front() else { continue };
            let (refresh, reference) = self.checked(&plan, keyframe, info);
            return Ok(Some(Output { annexb, keyframe, tag, refresh, reference }));
        }
    }
}

impl<T> Encoder<T> {
    /// What the encoder really did with a frame's plan, where it says (MFSampleExtension_LongTermReferenceFrameInfo): a mark it
    /// didn't make is forgotten; a recovery that used no long-term reference isn't one, and LTR is given up (recoveries are
    /// keyframes from then on). → (refresh, reference)
    fn checked(&mut self, plan: &Plan, keyframe: bool, info: Option<u32>) -> (bool, Option<u64>) {
        let mut reference = plan.mark.map(|m| m.1);
        let mut refresh = plan.use_slots != 0 && !keyframe;
        if let Some((slot, used)) = info.map(ltr::info) {
            if let (Some((want, n)), true) = (plan.mark, slot != plan.mark.map(|m| m.0)) {
                log(&format!("LTR: frame {n} meant for slot {want} went into {slot:?}"));
                if let Some(l) = &mut self.ltr {
                    l.unmarked(n);
                }
                reference = None;
            }
            if refresh && used == 0 {
                log("LTR: the recovery frame used no long-term reference; recoveries are keyframes from now on");
                self.ltr = None;
                refresh = false;
            }
        }
        if self.ltr.is_none() {
            reference = None;
        }
        (refresh, reference)
    }
}

fn log(s: &str) {
    if std::env::var_os("BLURT_REMOTE_LOG").is_some() {
        eprintln!("remote encoder (windows): {s}");
    }
}

fn blob(t: &IMFMediaType, key: &GUID) -> Vec<u8> {
    unsafe {
        let n = t.GetBlobSize(key).unwrap_or(0);
        if n == 0 {
            return Vec::new();
        }
        let mut v = vec![0u8; n as usize];
        if t.GetBlob(key, &mut v, None).is_err() {
            return Vec::new();
        }
        v
    }
}

impl<T> Drop for Encoder<T> {
    fn drop(&mut self) {
        unsafe {
            let _ = self.mft.ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
            let _ = self.mft.ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
            // ends the event pump's GetEvent
            if let Ok(s) = self.mft.cast::<IMFShutdown>() {
                let _ = s.Shutdown();
            }
        }
    }
}
